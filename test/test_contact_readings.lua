--- Tests what an ESPHome binary sensor's contact reads: Opened while on for a door, window,
--- opening, garage door, motion, occupancy, presence or moving sensor, Closed while on for any
--- other; and the one-time step that corrects what an earlier build kept.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_contact_readings.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local bindings = require("lib.bindings")
local persist = require("lib.persist")

--- Every message sent to a binding, as { binding, command }.
local sent = {}
C4.SendToProxy = function(_, idBinding, strCommand)
  sent[#sent + 1] = { idBinding, strCommand }
end

--- The messages sent to one binding since the last call, dropping the rest.
local function sentTo(bindingId)
  local got = {}
  for _, message in ipairs(sent) do
    if message[1] == bindingId then
      got[#got + 1] = message[2]
    end
  end
  sent = {}
  return got
end

--- Load a module afresh, as a driver start does; what was persisted stays.
local function load(name)
  package.loaded[name] = nil
  return require(name)
end

T.section("a binary sensor's contact reads by its device class")
for _, case in ipairs({
  { "door", "OPENED", "CLOSED" },
  { "window", "OPENED", "CLOSED" },
  { "opening", "OPENED", "CLOSED" },
  { "garage_door", "OPENED", "CLOSED" },
  { "motion", "OPENED", "CLOSED" },
  { "occupancy", "OPENED", "CLOSED" },
  { "presence", "OPENED", "CLOSED" },
  { "moving", "OPENED", "CLOSED" },
  { "smoke", "CLOSED", "OPENED" },
  { "", "CLOSED", "OPENED" },
}) do
  local class, on, off = case[1], case[2], case[3]
  persist:delete("BinarySensorStates")
  local BinarySensorEntity = load("esphome.entities.binary_sensor")
  local sensor = BinarySensorEntity:new({})
  local entity = { key = 801, ref = "801", name = "Sensor", device_class = class }
  sensor:discovered(entity)
  local contact = bindings:getDynamicBinding(BinarySensorEntity.TYPE, "binary_sensor_801").bindingId
  sentTo(contact)
  local label = class == "" and "no class" or class
  sensor:updated(entity, { state = true })
  T.eq(label .. ": on reads " .. on, sentTo(contact), { "STATE_" .. on })
  OBC[contact](contact, "CONTACT_SENSOR", true)
  T.eq(label .. ": a new bind is told the same", sentTo(contact), { "STATE_" .. on })
  sensor:updated(entity, { state = false })
  T.eq(label .. ": off reads " .. off, sentTo(contact), { off })
end

T.section("a one-time step runs at the first load that has it, and never again")
do
  persist:delete("TestStepDone")
  local runs = 0
  local step = function()
    runs = runs + 1
  end
  local once = load("esphome.once")
  T.eq("it runs at the first load", once("TestStepDone", step), true)
  once = load("esphome.once")
  T.eq("not at the next", once("TestStepDone", step), false)
  T.eq("so it ran once", runs, 1)
end

T.finish()
