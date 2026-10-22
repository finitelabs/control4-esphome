--- A fan or lock companion whose ESPHome connection is removed has no device to
--- report it, so it shows offline. A bind tells nothing: it also fires at a
--- controller start, before the device reports.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_companion_unbind.lua

local T = require("testlib")

require("c4_shim")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local PROXY, ESPHOME = 5001, 5002

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

local sent = {}

--- The device's report, after which the proxy's record starts over.
local function report(state)
  RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
    entity = SerializeSafe({ key = 1, name = "Device" }),
    state = SerializeSafe(state),
  })
  sent = {}
end

for _, case in ipairs({
  { "esphome_fan", { state = true, speed_level = 2 } },
  { "esphome_lock", { state = 1 } },
}) do
  local name, state = case[1], case[2]
  T.section(name .. ": its ESPHome connection removed, it shows offline")
  dofile(HERE .. "/../drivers/" .. name .. "/driver.lua")
  function SendToProxy(idBinding, strCommand, tParams)
    if idBinding == PROXY then
      sent[#sent + 1] = { command = strCommand, params = tParams or {} }
    end
  end
  OnDriverLateInit()
  report(state)
  OBC[ESPHOME](ESPHOME, "ESPHOME", true)
  T.eq("bound, as at a controller start: the proxy is told nothing", sent, {})
  report(state)
  OBC[ESPHOME](ESPHOME, "ESPHOME", false)
  T.eq("removed: the proxy is told only that it is offline", sent, {
    { command = "ONLINE_CHANGED", params = { STATE = false } },
  })
  T.eq("and its Connected variable is false", Variables["Connected"], "0")
end

T.finish()
