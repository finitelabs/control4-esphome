--- Tests that the Govee, BTHome and SwitchBot drivers keep showing the readings they restore at a start in
--- Composer, and still hide the ones the device never reported.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_readings_after_restart.lua

local T = require("testlib")
local F = require("c4_fixtures")
local H = require("ble_driver_harness")
local constants = require("constants")
local values = require("lib.values")
local SwitchBot = require("esphome.ble.parsers.switchbot")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

--- The last visibility each property was given.
local attribs = {}
function C4:SetPropertyAttribs(name, attrib)
  attribs[name] = attrib
end

--- Runs an earlier session of `driver` that stored readings, then starts it again as Director does, open-source
--- build, OnDriverInit then OnDriverLateInit, and returns what Composer shows.
--- @param driver string
--- @param stored? fun() Stores more values in the earlier session.
local function restart(driver, stored)
  H.use(driver)
  H.boot(nil, function()
    values:update("Battery", 87, "NUMBER", nil, " %")
    values:update("Temperature C", 21.5, "NUMBER", nil, " °C")
    if stored then
      stored()
    end
    values:flush()
  end)
  attribs = {}
  F.dofileBuild(HERE .. "/../drivers/" .. driver .. "/driver.lua", "oss")
  OnDriverInit("DIT_STARTUP")
  OnDriverLateInit("DIT_STARTUP")
  return attribs
end

for _, case in ipairs({
  { "esphome_govee" },
  { "esphome_bthome" },
  {
    "esphome_switchbot",
    function()
      values:update("Device Type", SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER], "STRING")
    end,
  },
}) do
  H.test(case[1] .. " shows its restored readings after a restart", function()
    local shown = restart(case[1], case[2])
    T.eq("Battery is shown", shown["Battery"], constants.SHOW_PROPERTY)
    T.eq("Temperature C is shown", shown["Temperature C"], constants.SHOW_PROPERTY)
    T.eq("Humidity, never reported, is hidden", shown["Humidity"], constants.HIDE_PROPERTY)
  end)
end

T.finish()
