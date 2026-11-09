--- Tests a companion whose device reports before the companion's late init, as
--- at a controller start when the ESPHome driver connects first. Late init tells
--- the proxy offline and asks for a fresh report, which must bring it online.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_report_before_late_init.lua

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

function C4:GetProxyDevices()
  return PROXY_DEVICE
end

function C4:GetDeviceVariable() end

-- The light reads the project's LED colors, which the shim has no stub for.
function C4:GetProjectProperty() end

local online, toldEarly

--- Load a companion, hand it `report` before its late init, run late init, then
--- answer its REFRESH_STATE with the same report. Returns whether the proxy was
--- last told online, and whether anything reached the proxy before late init.
local function startWithEarlyReport(name, report)
  online, toldEarly = nil, false
  -- Each driver has a Lua state of its own, where init leaves this false until late init.
  gInitialized = false
  dofile(HERE .. "/../drivers/" .. name .. "/driver.lua")
  local late = false
  function SendToProxy(idBinding, strCommand, tParams)
    if idBinding == PROXY then
      toldEarly = toldEarly or not late
      if strCommand == "ONLINE_CHANGED" then
        online = tParams.STATE
      end
    end
  end
  local function push()
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe(report.entity),
      state = SerializeSafe(report.state),
    })
  end
  push()
  late = true
  ShimLateInit()
  push()
  return online, toldEarly
end

local REPORTS = {
  esphome_light = {
    entity = { key = 1, name = "Light", supported_color_modes = { 3 } },
    state = { state = true, brightness = 1.0 },
  },
  esphome_lock = { entity = { key = 1, name = "Lock" }, state = { state = 1 } },
  esphome_fan = { entity = { key = 1, name = "Fan" }, state = { state = true } },
}

for _, name in ipairs({ "esphome_light", "esphome_lock", "esphome_fan" }) do
  T.section(name .. ": a report before late init, then the one late init asks for")
  local isOnline, early = startWithEarlyReport(name, REPORTS[name])
  T.eq("the proxy is left online", isOnline, true)
  T.eq("nothing reaches the proxy before late init", early, false)
end

T.finish()
