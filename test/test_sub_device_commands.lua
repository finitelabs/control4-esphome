-- Tests that a command to an entity on an ESPHome sub-device carries its
-- device_id.
--
-- ESPHome 2025.8.0 and later, built with sub-devices, looks a commanded entity
-- up by key and device_id, and drops a command whose device_id matches no
-- entity. device_id defaults to 0, the main device, so a command without it
-- never reaches a sub-device entity. A main-device command must stay as it was,
-- with no device_id on the wire.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sub_device_commands.lua

local T = require("testlib")
local E = require("esphome_fixtures")

local KITCHEN = 870733615 -- fnv1a_32bit_hash("kitchen")

local function entity(message, key, name, deviceId, extra)
  local body = { key = key, name = name, device_id = deviceId }
  for field, value in pairs(extra or {}) do
    body[field] = value
  end
  return { message = message, body = body }
end

E.wipe()
E.boot()
E.refresh({
  info = { name = "multi", friendly_name = "Multi", devices = { { device_id = KITCHEN, name = "Kitchen" } } },
  entities = {
    entity("ListEntitiesSwitchResponse", 101, "Kitchen Relay", KITCHEN),
    entity("ListEntitiesButtonResponse", 102, "Kitchen Chime", KITCHEN),
    entity("ListEntitiesCoverResponse", 103, "Kitchen Blind", KITCHEN, { supports_stop = true }),
    entity("ListEntitiesSelectResponse", 104, "Kitchen Mode", KITCHEN, { options = { "eco", "boost" } }),
    entity("ListEntitiesNumberResponse", 105, "Kitchen Level", KITCHEN),
    entity("ListEntitiesTextResponse", 106, "Kitchen Note", KITCHEN),
    entity("ListEntitiesDateResponse", 107, "Kitchen Date", KITCHEN),
    entity("ListEntitiesTimeResponse", 108, "Kitchen Time", KITCHEN),
    entity("ListEntitiesDateTimeResponse", 109, "Kitchen Alarm", KITCHEN),
    entity("ListEntitiesLightResponse", 110, "Kitchen Lamp", KITCHEN),
    entity("ListEntitiesFanResponse", 111, "Kitchen Fan", KITCHEN),
    entity("ListEntitiesLockResponse", 112, "Kitchen Lock", KITCHEN),
    entity("ListEntitiesClimateResponse", 113, "Kitchen Heat", KITCHEN),
    entity("ListEntitiesWaterHeaterResponse", 114, "Kitchen Water", KITCHEN),
    entity("ListEntitiesSwitchResponse", 201, "Main Relay"),
    entity("ListEntitiesButtonResponse", 202, "Main Chime"),
    entity("ListEntitiesLightResponse", 210, "Main Lamp"),
  },
  states = {
    { message = "SwitchStateResponse", body = { key = 101, device_id = KITCHEN, state = false } },
    { message = "SelectStateResponse", body = { key = 104, device_id = KITCHEN, state = "eco" } },
    { message = "NumberStateResponse", body = { key = 105, device_id = KITCHEN, state = 1 } },
    { message = "TextStateResponse", body = { key = 106, device_id = KITCHEN, state = "x" } },
    { message = "DateStateResponse", body = { key = 107, device_id = KITCHEN, year = 2026, month = 1, day = 1 } },
    { message = "TimeStateResponse", body = { key = 108, device_id = KITCHEN, hour = 1 } },
    { message = "DateTimeStateResponse", body = { key = 109, device_id = KITCHEN, epoch_seconds = 0 } },
    { message = "SwitchStateResponse", body = { key = 201, state = false } },
  },
})
T.eq("no handler failed", E.errors, {})
E.written()

--- Assert the driver wrote exactly the commands `want` since the last check.
local function sent(label, want)
  local got = {}
  for _, request in ipairs(E.written()) do
    got[#got + 1] = { request.message, request.body.key, request.body.device_id }
  end
  T.eq(label, got, want)
end

local function binding(name)
  return assert(E.bindingNamed(name), name).id
end

local function writeVariable(name, value)
  Variables[name] = value
  OnVariableChanged(name)
end

T.section("A sub-device entity's commands carry its device_id")
do
  local relay = binding("Kitchen Relay")
  ReceivedFromProxy(relay, "ON", {})
  sent("switch on", { { "SwitchCommandRequest", 101, KITCHEN } })
  ReceivedFromProxy(relay, "TOGGLE", {})
  sent("switch toggle", { { "SwitchCommandRequest", 101, KITCHEN } })
  ReceivedFromProxy(relay, "TRIGGER", { TIME = "100" })
  ShimFireTimers() -- the pulse
  sent(
    "switch pulse on, then off",
    { { "SwitchCommandRequest", 101, KITCHEN }, { "SwitchCommandRequest", 101, KITCHEN } }
  )
  writeVariable("Kitchen Relay State", "1")
  sent("switch variable", { { "SwitchCommandRequest", 101, KITCHEN } })

  ReceivedFromProxy(binding("Kitchen Chime"), "DO_CLICK", {})
  sent("button link", { { "ButtonCommandRequest", 102, KITCHEN } })
  EC.Press_Button({ Button = "Kitchen Chime" })
  sent("Press Button", { { "ButtonCommandRequest", 102, KITCHEN } })

  ReceivedFromProxy(binding("Open Kitchen Blind"), "ON", {})
  sent("cover open", { { "CoverCommandRequest", 103, KITCHEN } })
  ReceivedFromProxy(binding("Stop Kitchen Blind"), "ON", {})
  sent("cover stop", { { "CoverCommandRequest", 103, KITCHEN } })

  writeVariable("Kitchen Mode", "boost")
  sent("select variable", { { "SelectCommandRequest", 104, KITCHEN } })
  EC.Set_Select({ Select = "Kitchen Mode", Option = "eco" })
  sent("Set Select", { { "SelectCommandRequest", 104, KITCHEN } })
  writeVariable("Kitchen Level", "7")
  sent("number variable", { { "NumberCommandRequest", 105, KITCHEN } })
  writeVariable("Kitchen Note", "y")
  sent("text variable", { { "TextCommandRequest", 106, KITCHEN } })
  writeVariable("Kitchen Date", "2026-09-24")
  sent("date variable", { { "DateCommandRequest", 107, KITCHEN } })
  writeVariable("Kitchen Time", "07:30:00")
  sent("time variable", { { "TimeCommandRequest", 108, KITCHEN } })
  writeVariable("Kitchen Alarm", "2026-09-24 07:30:00")
  sent("datetime variable", { { "DateTimeCommandRequest", 109, KITCHEN } })

  local body = { body = SerializeSafe({ state = true }) }
  ReceivedFromProxy(binding("Kitchen Lamp"), "ENTITY_COMMAND", body)
  sent("light driver", { { "LightCommandRequest", 110, KITCHEN } })
  ReceivedFromProxy(binding("Kitchen Fan"), "ENTITY_COMMAND", body)
  sent("fan driver", { { "FanCommandRequest", 111, KITCHEN } })
  ReceivedFromProxy(binding("Kitchen Lock"), "ENTITY_COMMAND", { body = SerializeSafe({ command = 1 }) })
  sent("lock driver", { { "LockCommandRequest", 112, KITCHEN } })
  ReceivedFromProxy(binding("Kitchen Heat"), "ENTITY_COMMAND", { body = SerializeSafe({ mode = 1 }) })
  sent("climate driver", { { "ClimateCommandRequest", 113, KITCHEN } })
  ReceivedFromProxy(binding("Kitchen Water"), "ENTITY_COMMAND", { body = SerializeSafe({ mode = 1 }) })
  sent("water heater driver", { { "WaterHeaterCommandRequest", 114, KITCHEN } })
end

T.section("A main-device entity's commands carry no device_id")
do
  ReceivedFromProxy(binding("Main Relay"), "ON", {})
  sent("switch on", { { "SwitchCommandRequest", 201 } })
  writeVariable("Main Relay State", "1")
  sent("switch variable", { { "SwitchCommandRequest", 201 } })
  ReceivedFromProxy(binding("Main Chime"), "DO_CLICK", {})
  sent("button link", { { "ButtonCommandRequest", 202 } })
  EC.Press_Button({ Button = "Main Chime" })
  sent("Press Button", { { "ButtonCommandRequest", 202 } })
  ReceivedFromProxy(binding("Main Lamp"), "ENTITY_COMMAND", { body = SerializeSafe({ state = true }) })
  sent("light driver", { { "LightCommandRequest", 210 } })
end

T.section("On the wire, as api.proto encodes it")
do
  local RELAY = 3551080420 -- fnv1_hash_object_id("Relay")
  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "multi", friendly_name = "Multi", devices = { { device_id = KITCHEN, name = "Kitchen" } } },
    entities = {
      entity("ListEntitiesSwitchResponse", RELAY, "Relay"),
      entity("ListEntitiesSwitchResponse", RELAY, "Relay", KITCHEN),
    },
    states = {},
  })
  E.written()
  local function payloads()
    local got = {}
    for _, request in ipairs(E.written()) do
      got[#got + 1] = E.hex(request.payload)
    end
    return got
  end
  -- From protoc --encode=SwitchCommandRequest with ESPHome 2026.9.0's api.proto.
  ReceivedFromProxy((E.bindingNamed("Kitchen Relay") or {}).id or 0, "ON", {})
  T.eq("sub-device", payloads(), { "0de42fa9d3100118afae999f03" })
  ReceivedFromProxy((E.bindingNamed("Relay") or {}).id or 0, "ON", {})
  T.eq("main device", payloads(), { "0de42fa9d31001" })
end

T.finish()
