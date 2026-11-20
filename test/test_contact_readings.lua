--- Tests what an ESPHome binary sensor's contact reads. On an item added from this build, or one
--- whose Contact When Active is Opened, a door, window, opening, garage door, motion, occupancy,
--- presence or moving sensor reads Opened while on; on an item added before, Closed, as it always
--- has. Any other class reads Closed while on. Also tests how an item is marked as added, and when
--- a change of the reading is told.
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

--- Start an item: `added` as Director adds it, else as an item added before; `property` is its
--- Contact When Active.
local function start(added, property)
  persist:delete("ContactsReadOpened")
  persist:delete("ContactReading")
  Properties["Contact When Active"] = property or "Closed"
  load("esphome.contact_reading").init(added and "DIT_ADDING" or "DIT_UPDATING")
end

for _, item in ipairs({
  { "added from this build", true, "Closed", true },
  { "added before", false, "Closed", false },
  { "added before, set to Opened", false, "Opened", true },
}) do
  T.section("a binary sensor's contact reads by its device class: " .. item[1])
  for _, case in ipairs({
    { "door", true },
    { "window", true },
    { "opening", true },
    { "garage_door", true },
    { "motion", true },
    { "occupancy", true },
    { "presence", true },
    { "moving", true },
    { "smoke", false },
    { "", false },
  }) do
    local class = case[1]
    local onOpens = case[2] and item[4]
    local on, off = onOpens and "OPENED" or "CLOSED", onOpens and "CLOSED" or "OPENED"
    start(item[2], item[3])
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
end

--- What C4:SetPropertyAttribs was called with, as "name=attrib".
local attribs = {}
C4.SetPropertyAttribs = function(_, name, attrib)
  attribs[#attribs + 1] = name .. "=" .. tostring(attrib)
end

T.section("an item Director adds is marked, and its Contact When Active is hidden at every load")
do
  attribs = {}
  start(true)
  T.eq("adding hides it", attribs, { "Contact When Active=1" })
  attribs = {}
  load("esphome.contact_reading").init("DIT_STARTUP")
  T.eq("and so does each start after", attribs, { "Contact When Active=1" })
  attribs = {}
  load("esphome.contact_reading").init("DIT_UPDATING")
  T.eq("and each update", attribs, { "Contact When Active=1" })
end

T.section("an item added before shows its Contact When Active")
do
  attribs = {}
  start(false)
  T.eq("an update leaves it shown", attribs, {})
  load("esphome.contact_reading").init("DIT_STARTUP")
  T.eq("and so does a start", attribs, {})
  T.eq("and nothing marks it added", persist:get("ContactsReadOpened"), nil)
end

T.section("a change of the reading is told; its replay at each load is not")
do
  start(false)
  local ContactReading = load("esphome.contact_reading")
  local retold = 0
  local retell = function()
    retold = retold + 1
  end
  ContactReading.applied(retell)
  T.eq("the first load of this build tells nothing", retold, 0)
  ContactReading.applied(retell)
  T.eq("nor does a later load", retold, 0)
  Properties["Contact When Active"] = "Opened"
  ContactReading.applied(retell)
  T.eq("set to Opened, it is told", retold, 1)
  ContactReading = load("esphome.contact_reading")
  ContactReading.applied(retell)
  T.eq("and not again at the next load", retold, 1)
  Properties["Contact When Active"] = "Closed"
  ContactReading.applied(retell)
  T.eq("set back to Closed, it is told again", retold, 2)
end

T.finish()
