-- Tests the Programming events of an ESPHome event entity: the driver declares
-- them when it loads, and a rename keeps their ids so programming stays attached.
--
-- ESPHome derives the key from the name, so a rename that keeps the key, such as
-- a change of capitals, reaches the driver as the same entity under a new name.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_event_names.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local events = require("lib.events")
local EventEntity = require("esphome.entities.event")

-- Resolved against this file: make test runs from the repo root, run_test.sh from test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/esphome/driver.lua"

-- Stubs the driver's load needs that the shim does not provide.
Properties["Driver Status"] = ""
function C4:GetDriverConfigInfo(section)
  return section == "minimum_os_version" and "3.3.0" or ""
end
function C4:GetDevicesByC4iName()
  return {}
end
function C4:UpdatePropertyList() end

--- Declared events as id -> name.
local function declared()
  local names = {}
  for id, event in pairs(ShimEvents()) do
    names[id] = event.name
  end
  return names
end

local instance = EventEntity:new({})
local function discover(name)
  instance:discovered({ key = 42, ref = "42", name = name, event_types = { "press", "double_press" } })
end

T.section("A rename on the device renames the events in place")
discover("Front door bell")
T.eq("declared", declared(), { [10] = "Front door bell: press", [11] = "Front door bell: double_press" })
discover("Front Door Bell")
T.eq("same ids, new names", declared(), { [10] = "Front Door Bell: press", [11] = "Front Door Bell: double_press" })
T.eq("new description", ShimEvents()[10].description, "Front Door Bell press event")
T.eq("persisted", events:getEvents().event_42.press.name, "Front Door Bell: press")

T.section("The driver declares its events when it loads")
ShimResetEvents()
dofile(DRIVER)
OnDriverLateInit()
T.eq("declared before the device connects", declared(), {
  [10] = "Front Door Bell: press",
  [11] = "Front Door Bell: double_press",
})

T.finish()
