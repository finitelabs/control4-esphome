-- A variable that programming sets, which the device does not take, goes back
-- to the device's value.
--
-- Director stores the value programming sets before the driver hears of it. A
-- command to a device the driver is not connected to is rejected, so without a
-- revert the variable kept a value the device never took until its next report.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_variable_write_offline.lua

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers") -- OnVariableChanged
local T = require("testlib")

local deferred = require("deferred")

--- A client that answers each command as `connected` says, counting what it was sent.
local connected = false
local sent = 0
local client = {
  callServiceMethod = function()
    sent = sent + 1
    if connected then
      return deferred.new():resolve(nil)
    end
    return deferred.new():reject("Not connected to ESPHome device")
  end,
}

--- Set a variable as programming does: Director stores the value, then tells the driver.
local function program(name, value)
  Variables[name] = value
  OnVariableChanged(name)
end

for _, case in ipairs({
  { "switch", "Relay", "Relay State", { state = false }, "0", "1" },
  { "number", "Volume", "Volume", { state = 20 }, "20", "35" },
  { "select", "Mode", "Mode", { state = "Eco" }, "Eco", "Boost" },
  { "text", "Label", "Label", { state = "Hall" }, "Hall", "Porch" },
  { "date", "Start Date", "Start Date", { year = 2026, month = 1, day = 2 }, "2026-01-02", "2026-03-04" },
  { "time", "Start Time", "Start Time", { hour = 6, minute = 30, second = 0 }, "06:30:00", "07:45:00" },
  {
    "datetime",
    "Alarm",
    "Alarm",
    { epoch_seconds = os.time({ year = 2026, month = 1, day = 2, hour = 6, min = 30, sec = 0 }) },
    "2026-01-02 06:30:00",
    "2026-03-04 07:45:00",
  },
}) do
  local module, entityName, variable, state, reported, programmed = unpack(case)
  T.section("a " .. module .. " set while its device is offline")
  local Entity = require("esphome.entities." .. module)
  local entity = { key = 1, ref = "1", name = entityName, options = { "Eco", "Boost" } }
  local instance = Entity:new(client)
  if instance.discovered then
    instance:discovered(entity)
  end
  instance:updated(entity, state)
  T.eq("the device's value", Variables[variable], reported)

  connected, sent = false, 0
  program(variable, programmed)
  T.eq("is sent to the device", sent, 1)
  T.eq("and, rejected, goes back to the device's value", Variables[variable], reported)

  connected = true
  program(variable, programmed)
  T.eq("connected, a value sent waits for the device's report", Variables[variable], programmed)
  Variables[variable] = reported
end

T.section("a date, time or datetime set to a value it cannot read")
for _, case in ipairs({
  { "date", "Start Date", { year = 2026, month = 1, day = 2 }, "2026-01-02" },
  { "time", "Start Time", { hour = 6, minute = 30, second = 0 }, "06:30:00" },
  {
    "datetime",
    "Alarm",
    { epoch_seconds = os.time({ year = 2026, month = 1, day = 2, hour = 6, min = 30, sec = 0 }) },
    "2026-01-02 06:30:00",
  },
}) do
  local module, name, state, reported = unpack(case)
  local entity = { key = 1, ref = "1", name = name }
  require("esphome.entities." .. module):new(client):updated(entity, state)
  connected, sent = true, 0
  program(name, "soon")
  T.eq(module .. ": nothing is sent", sent, 0)
  T.eq(module .. ": and it goes back to the device's value", Variables[name], reported)
end

T.finish()
