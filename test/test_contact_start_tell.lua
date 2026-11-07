--- Tests what an ESPHome binary sensor's contact and a cover's Open and Closed
--- contacts tell their bound consumers. OPENED and CLOSED fire the consumer's
--- programming, and ESPHome re-sends every state at each reconnect, so only a
--- change against the state told before (kept across loads) is told that way.
--- Anything else goes silently as STATE_OPENED or STATE_CLOSED, once per load.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_contact_start_tell.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local bindings = require("lib.bindings")

local client = {}

--- Every message sent to a binding, as { binding, command }.
local told = {}
C4.SendToProxy = function(_, idBinding, strCommand)
  told[#told + 1] = { idBinding, strCommand }
end

function RefreshStatus() end

--- The messages told to one binding since the last call, dropping the rest.
local function toldTo(bindingId)
  local got = {}
  for _, message in ipairs(told) do
    if message[1] == bindingId then
      got[#got + 1] = message[2]
    end
  end
  told = {}
  return got
end

--- Load an entity module afresh, as a driver start does; what was persisted stays.
local function load(name)
  package.loaded[name] = nil
  return require(name)
end

T.section("A binary sensor tells a change as one, and nothing else")
do
  local BinarySensorEntity = load("esphome.entities.binary_sensor")
  local sensor = BinarySensorEntity:new(client)
  local entity = { key = 801, ref = "801", name = "Back Door" }
  sensor:discovered(entity)
  local contact = bindings:getDynamicBinding(BinarySensorEntity.TYPE, "binary_sensor_" .. entity.ref).bindingId

  sensor:updated(entity, { state = true })
  T.eq("its first state is told silently", toldTo(contact), { "STATE_CLOSED" })
  sensor:updated(entity, { state = true })
  T.eq("the same state again (a reconnect's resend) tells nothing", toldTo(contact), {})
  sensor:updated(entity, { state = false })
  T.eq("a change is told as one", toldTo(contact), { "OPENED" })
end

T.section("After a restart, a binary sensor's unchanged state fires nothing")
do
  local BinarySensorEntity = load("esphome.entities.binary_sensor")
  local sensor = BinarySensorEntity:new(client)
  local entity = { key = 801, ref = "801", name = "Back Door" }
  sensor:discovered(entity)
  local contact = bindings:getDynamicBinding(BinarySensorEntity.TYPE, "binary_sensor_" .. entity.ref).bindingId

  sensor:updated(entity, { state = false })
  T.eq("the state told before the restart is told silently", toldTo(contact), { "STATE_OPENED" })

  BinarySensorEntity = load("esphome.entities.binary_sensor")
  sensor = BinarySensorEntity:new(client)
  sensor:updated(entity, { state = true })
  T.eq("one that changed while the driver was down is told as a change", toldTo(contact), { "CLOSED" })

  BinarySensorEntity.clearNotifiedState()
  sensor:updated(entity, { state = true })
  T.eq("after Reset Driver, nothing told before: silent", toldTo(contact), { "STATE_CLOSED" })
end

T.section("A binary sensor's new consumer is told its state silently")
do
  local BinarySensorEntity = load("esphome.entities.binary_sensor")
  local sensor = BinarySensorEntity:new(client)
  local entity = { key = 802, ref = "802", name = "Side Gate" }
  sensor:discovered(entity)
  local contact = bindings:getDynamicBinding(BinarySensorEntity.TYPE, "binary_sensor_" .. entity.ref).bindingId

  OBC[contact](contact, "CONTACT_SENSOR", true)
  T.eq("a bind before any state tells nothing", toldTo(contact), {})
  sensor:updated(entity, { state = true })
  toldTo(contact)
  OBC[contact](contact, "CONTACT_SENSOR", true)
  T.eq("a bind after the first state tells it silently", toldTo(contact), { "STATE_CLOSED" })
  OBC[contact](contact, "CONTACT_SENSOR", false)
  T.eq("an unbind tells nothing", toldTo(contact), {})
end

--- What ESPHome sends for a cover open and one closed.
local OPEN, CLOSED = { position = 1.0 }, { position = 0.0 }

--- Discover a cover and return its entity and its Open and Closed contact bindings.
local function newCover(CoverEntity)
  local cover = CoverEntity:new(client)
  local entity = { key = 960, ref = "960", name = "Garage", supports_stop = true }
  cover:discovered(entity)
  local open = bindings:getDynamicBinding(CoverEntity.TYPE, "cover_open_" .. entity.ref).bindingId
  local closed = bindings:getDynamicBinding(CoverEntity.TYPE, "cover_closed_" .. entity.ref).bindingId
  return cover, entity, open, closed
end

T.section("A cover's contacts tell a change as one, and nothing else")
do
  local CoverEntity = load("esphome.entities.cover")
  local cover, entity, open, closed = newCover(CoverEntity)

  cover:updated(entity, OPEN)
  local first = told
  T.eq("its first state is told silently on Open", toldTo(open), { "STATE_CLOSED" })
  told = first
  T.eq("and on Closed", toldTo(closed), { "STATE_OPENED" })

  cover:updated(entity, OPEN)
  T.eq("the same state again tells nothing", told, {})

  cover:updated(entity, CLOSED)
  local change = told
  T.eq("a change is told as one on Open", toldTo(open), { "OPENED" })
  told = change
  T.eq("and on Closed", toldTo(closed), { "CLOSED" })
end

T.section("After a restart, a cover's unchanged state fires nothing, and a bind is told silently")
do
  local CoverEntity = load("esphome.entities.cover")
  local cover, entity, open, closed = newCover(CoverEntity)

  cover:updated(entity, CLOSED)
  local first = told
  T.eq("the state told before the restart is told silently on Open", toldTo(open), { "STATE_OPENED" })
  told = first
  T.eq("and on Closed", toldTo(closed), { "STATE_CLOSED" })

  OBC[open](open, "CONTACT_SENSOR", true)
  T.eq("a new consumer of Open is told its state silently", toldTo(open), { "STATE_OPENED" })
  OBC[closed](closed, "CONTACT_SENSOR", true)
  T.eq("and of Closed", toldTo(closed), { "STATE_CLOSED" })
end

T.finish()
