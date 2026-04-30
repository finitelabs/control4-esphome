#!/usr/bin/env python3
"""Drive the dummy_lights.yaml ESPHome host from the device side via aioesphomeapi.

Usage:
  light_api_call.py service <service_name> [key=value ...]
  light_api_call.py turn_on <light_name> [brightness=0.5] [transition=2.0]
  light_api_call.py turn_off <light_name>
  light_api_call.py state               # list all light states

Where <light_name> is the human-readable ESPHome light name as known to the
device (e.g., "Test Binary Light", "Test Mono Light"). For service calls,
<service_name> is one of the user-defined services in the YAML
(device_set_on, device_set_off, device_set_level).
"""
import asyncio
import sys
from aioesphomeapi import APIClient


HOST = "127.0.0.1"
PORT = 6053


def parse_kv(args):
    out = {}
    for a in args:
        if "=" not in a:
            continue
        k, v = a.split("=", 1)
        try:
            out[k] = float(v) if "." in v else int(v)
        except ValueError:
            out[k] = v
    return out


async def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    cmd = sys.argv[1]
    client = APIClient(HOST, PORT, password=None)
    await client.connect(login=True)
    try:
        entities, services = await client.list_entities_services()
        lights = [e for e in entities if type(e).__name__ == "LightInfo"]
        by_name = {l.name: l for l in lights}

        if cmd == "state":
            states = {}

            def on_state(state):
                if type(state).__name__ == "LightState":
                    states[state.key] = state

            client.subscribe_states(on_state)
            await asyncio.sleep(1.0)
            for light in lights:
                s = states.get(light.key)
                if s:
                    print(
                        f"{light.name}: state={s.state} brightness={getattr(s, 'brightness', None):.3f}"
                    )
                else:
                    print(f"{light.name}: <no state>")
            return 0

        if cmd == "service":
            svc_name = sys.argv[2]
            kv = parse_kv(sys.argv[3:])
            svc = next((s for s in services if s.name == svc_name), None)
            if not svc:
                print(f"service '{svc_name}' not found; available: {[s.name for s in services]}")
                return 2
            await client.execute_service(svc, kv)
            print(f"called service {svc_name}({kv})")
            await asyncio.sleep(0.5)
            return 0

        if cmd == "turn_on":
            name = sys.argv[2]
            kv = parse_kv(sys.argv[3:])
            light = by_name.get(name)
            if not light:
                print(f"light '{name}' not found; available: {list(by_name.keys())}")
                return 2
            kwargs = {"key": light.key, "state": True}
            if "brightness" in kv:
                kwargs["brightness"] = float(kv["brightness"])
            if "transition" in kv:
                kwargs["transition_length"] = float(kv["transition"])
            if "r" in kv and "g" in kv and "b" in kv:
                kwargs["rgb"] = (float(kv["r"]), float(kv["g"]), float(kv["b"]))
            if "cct_k" in kv:
                # ESPHome takes color_temperature in mireds = 1e6 / kelvin
                kwargs["color_temperature"] = 1_000_000 / float(kv["cct_k"])
            client.light_command(**kwargs)
            print(f"turn_on {name} {kwargs}")
            await asyncio.sleep(0.5)
            return 0

        if cmd == "turn_off":
            name = sys.argv[2]
            light = by_name.get(name)
            if not light:
                print(f"light '{name}' not found; available: {list(by_name.keys())}")
                return 2
            client.light_command(key=light.key, state=False)
            print(f"turn_off {name}")
            await asyncio.sleep(0.5)
            return 0

        print(f"unknown command: {cmd}")
        return 1
    finally:
        await client.disconnect()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))