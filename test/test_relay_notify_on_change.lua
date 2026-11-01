-- Tests what switch and cover RELAY connections tell their bound consumers.
--
-- CLOSED/OPENED fire the bound relay driver's programming, and ESPHome re-sends
-- every state at each reconnect, so a switch tells that form only for a change.
-- A first state that matches the one stored before the load, and the state a
-- new consumer is seeded with, go silently as STATE_CLOSED/STATE_OPENED. A
-- cover's trigger relays always read open and are told so once, at bind. Each
-- switch's TRIGGER pulse has its own timer.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_relay_notify_on_change.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local CoverEntity = require("esphome.entities.cover")
local SwitchEntity = require("esphome.entities.switch")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- Every switch command sent to the device, as { key, state }.
local sent = {}
local client = {
  callServiceMethod = function(_, method, body)
    if method.method == "switch_command" then
      sent[#sent + 1] = { body.key, body.state }
    end
    return deferred.new():resolve(nil)
  end,
}

--- Every message sent to a binding, as { binding, command }.
local told = {}
C4.SendToProxy = function(_, idBinding, strCommand)
  told[#told + 1] = { idBinding, strCommand }
end

local refreshes = 0
function RefreshStatus()
  refreshes = refreshes + 1
end

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

local switch = SwitchEntity:new(client)

--- Discover a switch and return its entity and relay binding.
local function newSwitch(key, name)
  local entity = { key = key, ref = tostring(key), name = name }
  switch:discovered(entity)
  return entity, bindings:getDynamicBinding(SwitchEntity.TYPE, "switch_" .. entity.ref).bindingId
end

T.section("A switch's first state this load")
do
  local fresh, freshRelay = newSwitch(901, "Fresh Relay")
  switch:updated(fresh, { state = true })
  T.eq("nothing stored: told silently", toldTo(freshRelay), { "STATE_CLOSED" })

  SwitchEntity.clearNotifiedState()
  switch:updated(fresh, { state = true })
  T.eq("matches the stored state: told silently", toldTo(freshRelay), { "STATE_CLOSED" })

  SwitchEntity.clearNotifiedState()
  switch:updated(fresh, { state = false })
  T.eq("differs from the stored state: told as a change", toldTo(freshRelay), { "OPENED" })
end

T.section("Later states are told only when they change")
do
  local entity, relay = newSwitch(902, "Porch Relay")
  switch:updated(entity, { state = false })
  toldTo(relay)

  switch:updated(entity, { state = false })
  T.eq("same state again (a reconnect's resend)", toldTo(relay), {})

  switch:updated(entity, { state = true })
  T.eq("on", toldTo(relay), { "CLOSED" })

  switch:updated(entity, { state = true })
  switch:updated(entity, { state = true })
  T.eq("on twice more", toldTo(relay), {})

  switch:updated(entity, { state = false })
  T.eq("off", toldTo(relay), { "OPENED" })
end

T.section("A new consumer is seeded silently")
do
  local entity, relay = newSwitch(903, "Gate Relay")
  local unknown = refreshes
  OBC[relay](relay, "RELAY", true)
  T.eq("bind with nothing stored tells nothing", toldTo(relay), {})
  T.eq("bind still refreshes", refreshes, unknown + 1)

  switch:updated(entity, { state = true })
  toldTo(relay)
  OBC[relay](relay, "RELAY", true)
  T.eq("bind tells the stored state", toldTo(relay), { "STATE_CLOSED" })

  OBC[relay](relay, "RELAY", false)
  T.eq("unbind tells nothing", toldTo(relay), {})
end

T.section("Each switch's TRIGGER pulse ends on its own")
do
  local a, relayA = newSwitch(904, "Pulse A")
  local b, relayB = newSwitch(905, "Pulse B")
  sent = {}
  RFP[relayA](relayA, "TRIGGER", { TIME = "500" })
  RFP[relayB](relayB, "TRIGGER", { TIME = "500" })
  T.eq("both turned on", sent, { { a.key, true }, { b.key, true } })

  sent = {}
  ShimFireTimers()
  local off = {}
  for _, command in ipairs(sent) do
    off[command[1]] = command[2]
  end
  T.eq("both turned off", off, { [a.key] = false, [b.key] = false })
end

T.section("A cover's trigger relays read open, told once at bind")
do
  local cover = CoverEntity:new(client)
  local entity = { key = 950, ref = "950", name = "Garage", supports_stop = true }
  cover:discovered(entity)
  local trigger = {}
  for _, name in ipairs({ "open_cover_", "close_cover_", "stop_cover_" }) do
    trigger[#trigger + 1] = bindings:getDynamicBinding(CoverEntity.TYPE, name .. entity.ref).bindingId
  end

  told = {}
  local Legacy = ESPHomeProtoSchema.Enum.LegacyCoverState
  for _, legacyState in ipairs({ Legacy.LEGACY_COVER_STATE_OPEN, Legacy.LEGACY_COVER_STATE_CLOSED }) do
    cover:updated(entity, { legacy_state = legacyState })
  end
  local updates = told
  for _, relay in ipairs(trigger) do
    told = updates
    T.eq("updates tell trigger relay " .. relay .. " nothing", toldTo(relay), {})
  end

  for _, relay in ipairs(trigger) do
    OBC[relay](relay, "RELAY", true)
    T.eq("bind tells trigger relay " .. relay .. " it is open", toldTo(relay), { "STATE_OPENED" })
  end
end

T.finish()
