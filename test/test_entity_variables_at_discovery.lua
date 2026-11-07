-- A writable entity's variable takes programming's writes from discovery, before the device's first state.
--
-- A text, select, date, time or datetime has its variable from discovery, blank until the device reports. A number
-- or switch whose variable was kept from an earlier load takes writes at once; a new one has no variable until its
-- first state, since a number has no neutral value and a switch would read as off.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_entity_variables_at_discovery.lua

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers") -- OnVariableChanged
local T = require("testlib")

local deferred = require("deferred")
local values = require("lib.values")

--- A client that takes every command, counting them; `connected` false rejects them instead.
local connected = true
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

local nextKey = 100
--- A new entity of `module`, discovered only.
local function discover(module, name)
  nextKey = nextKey + 1
  local Entity = require("esphome.entities." .. module)
  local entity = { key = nextKey, ref = tostring(nextKey), name = name, options = { "Eco", "Boost" } }
  local instance = Entity:new(client)
  if instance.discovered then
    instance:discovered(entity)
  end
  return instance, entity
end

T.section("a text, select, date, time or datetime is writable from discovery, blank until it reports")
for _, case in ipairs({
  { "text", "Label", "Porch" },
  { "select", "Mode", "Boost" },
  { "date", "Start Date", "2026-03-04" },
  { "time", "Start Time", "07:45:00" },
  { "datetime", "Alarm", "2026-03-04 07:45:00" },
}) do
  local module, name, programmed = unpack(case)
  discover(module, name)
  T.eq(module .. ": the variable is there and blank", Variables[name], "")
  sent = 0
  program(name, programmed)
  T.eq(module .. ": a value programming sets reaches the device", sent, 1)
end

T.section("a number or switch kept from an earlier load is writable from discovery")
for _, case in ipairs({
  { "number", "Volume", "Volume", "NUMBER", "20", "35" },
  { "switch", "Relay", "Relay State", "BOOL", "0", "1" },
}) do
  local module, name, variable, varType, kept, programmed = unpack(case)
  -- An earlier load stored the device's value; this load has no handler for the variable yet
  values:update(variable, kept, varType, function() end)
  OVC[variable:gsub("%s+", "_")] = nil
  discover(module, name)
  T.eq(module .. ": the variable keeps its value", Variables[variable], kept)
  sent = 0
  program(variable, programmed)
  T.eq(module .. ": a value programming sets reaches the device", sent, 1)
end

T.section("a new number or switch has no variable until its first state")
discover("number", "Brightness")
T.eq("number", Variables["Brightness"], nil)
discover("switch", "Pump")
T.eq("switch", Variables["Pump State"], nil)

T.section("a value the device rejects before its first state goes back to blank")
discover("text", "Note")
connected, sent = false, 0
program("Note", "Back door")
T.eq("it is sent", sent, 1)
T.eq("and goes back to blank", Variables["Note"], "")
connected = true

T.finish()
