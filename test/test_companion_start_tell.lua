--- Tests what the lock and fan companions tell their proxy on the first report
--- after a load, a bind or a reconnect. A lock's LOCK_STATUS_CHANGED and a fan's
--- ON or OFF fire the proxy's events, so they go out only for a real change
--- against what the proxy shows. A lock status the proxy does not show yet
--- initializes it with the silent LOCK_STATUS_INITIALIZE.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_companion_start_tell.lua

local T = require("testlib")

require("c4_shim")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local PROXY, ESPHOME = 5001, 5002
local PROXY_DEVICE = 9001

Properties["Driver Status"] = ""
Properties["Driver Version"] = ""

-- Late init stops without a minimum OS version, which the shim lacks.
local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return config(self, section)
end

-- The fan's speed count is filled in by the build.
__FAN_SPEED_COUNT__ = 4

--- The proxy's variables by id: the lock's LockStatus (1000), the fan's CURRENT_SPEED (1001).
local shows = {}

function C4:GetProxyDevices()
  return PROXY_DEVICE
end

function C4:GetDeviceVariable(deviceId, variableId)
  if deviceId == PROXY_DEVICE then
    return shows[variableId]
  end
end

local told = {}

--- Load a companion as a driver update or controller start does, with the proxy showing `variables`.
local function load(name, variables)
  shows = variables
  dofile(HERE .. "/../drivers/" .. name .. "/driver.lua")
  function SendToProxy(idBinding, strCommand)
    if idBinding == PROXY and strCommand ~= "ONLINE_CHANGED" then
      told[#told + 1] = strCommand
    end
  end
  ShimLateInit()
  told = {}
end

--- What the proxy is told, besides online, for one report from the device.
local function report(state)
  told = {}
  RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
    entity = SerializeSafe({ key = 1, name = "Device" }),
    state = SerializeSafe(state),
  })
  local got = {}
  for _, command in ipairs(told) do
    if command:find("^LOCK_STATUS_") or command == "ON" or command == "OFF" then
      got[#got + 1] = command
    end
  end
  return got
end

local LOCKED, UNLOCKED = { state = 1 }, { state = 2 }

T.section("esphome_lock: after a driver update, the status the proxy shows is told nothing")
load("esphome_lock", { [1000] = "locked" })
T.eq("the first report tells nothing", report(LOCKED), {})
T.eq("nor does a repeat", report(LOCKED), {})
T.eq("a change is told once", report(UNLOCKED), { "LOCK_STATUS_CHANGED" })

T.section("esphome_lock: after a controller start, the first status initializes the proxy")
load("esphome_lock", { [1000] = "unknown" })
T.eq("it is told silently", report(LOCKED), { "LOCK_STATUS_INITIALIZE" })
T.eq("and a repeat tells nothing", report(LOCKED), {})

T.section("esphome_lock: after a disconnect, the same status is told nothing")
load("esphome_lock", { [1000] = "locked" })
report(LOCKED)
RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT")
T.eq("the report after it tells nothing", report(LOCKED), {})
RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT")
T.eq("one that changed while it was away is told as a change", report(UNLOCKED), { "LOCK_STATUS_CHANGED" })

T.section("esphome_lock: a bind tells nothing, and the lock bound after a removal initializes the proxy")
load("esphome_lock", { [1000] = "locked" })
report(LOCKED)
OBC[ESPHOME](ESPHOME, "ESPHOME", true)
T.eq("bound again: the same status tells nothing", report(LOCKED), {})
OBC[ESPHOME](ESPHOME, "ESPHOME", false)
OBC[ESPHOME](ESPHOME, "ESPHOME", true)
T.eq("removed and bound: its status initializes the proxy", report(LOCKED), { "LOCK_STATUS_INITIALIZE" })

local ON, OFF = { state = true, speed_level = 2 }, { state = false }

T.section("esphome_fan: an unchanged fan is told nothing after a load or reconnect")
load("esphome_fan", { [1001] = "2" })
T.eq("the first report after a load tells nothing", report(ON), {})
RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT")
T.eq("nor does the report after a reconnect", report(ON), {})
T.eq("a change is told", report(OFF), { "OFF" })

T.section("esphome_fan: a fan that changed while the driver was down is told")
load("esphome_fan", { [1001] = "0" })
T.eq("on, against a proxy that shows it off", report(ON), { "ON" })
load("esphome_fan", { [1001] = "2" })
T.eq("off, against a proxy that shows it on", report(OFF), { "OFF" })

T.section("esphome_fan: a proxy that cannot be read is told the fan's state")
load("esphome_fan", {})
T.eq("its first report is told", report(OFF), { "OFF" })

T.finish()
