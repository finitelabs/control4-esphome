-- Tests the LED feedback an event entity's button link passes on to the device.
--
-- A load bound to the link answers the way it would a Control4 keypad button,
-- with its LED state and on/off colors. The event entity forwards those to the
-- device's user-defined `control4_led` action, with arguments built from what
-- the action declares.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_event_led_feedback.lua

require("drivers-common-public.global.lib")
require("c4_shim")

local T = require("testlib")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local EventEntity = require("esphome.entities.event")

local ArgType = ESPHomeProtoSchema.Enum.ServiceArgType

-- Loads send over the link; the driver must not answer on it.
local sent = {}
function C4:SendToProxy(idBinding, strCommand)
  sent[#sent + 1] = tostring(idBinding) .. ":" .. tostring(strCommand)
end

--------------------------------------------------------------------------------
T.section("executeServiceWithArgs builds arguments from the declared list")
--------------------------------------------------------------------------------

local requests = {}
local client = setmetatable({
  userServices = { control4_led = 7 },
  userServiceArgs = {
    control4_led = {
      { name = "state", type = ArgType.SERVICE_ARG_TYPE_BOOL },
      { name = "color", type = ArgType.SERVICE_ARG_TYPE_STRING },
      { name = "event", type = ArgType.SERVICE_ARG_TYPE_STRING },
      { name = "level", type = ArgType.SERVICE_ARG_TYPE_INT },
      { name = "ratio", type = ArgType.SERVICE_ARG_TYPE_FLOAT },
    },
  },
}, ESPHomeClient)
function client:callServiceMethod(method, body)
  requests[#requests + 1] = { method = method, body = body }
  return deferred.new():resolve()
end

local ok = false
client
  :executeServiceWithArgs("control4_led", { color = "FF0000", state = true, event = "Touch", extra = "dropped" })
  :next(function()
    ok = true
  end)
T.eq("resolves", ok, true)
T.eq("one request", #requests, 1)
T.eq("execute_service", requests[1].method, ESPHomeProtoSchema.RPC.APIConnection.execute_service)
T.eq("service key", requests[1].body.key, 7)
-- Declared order, declared types; missing values take their type's zero value.
T.check(
  "args in declared order and type",
  T.deepEqual(requests[1].body.args, {
    { bool_ = true },
    { string_ = "FF0000" },
    { string_ = "Touch" },
    { int_ = 0 },
    { float_ = 0 },
  }),
  T.show(requests[1].body.args)
)

local rejected
client:executeServiceWithArgs("missing", {}):next(nil, function(err)
  rejected = err
end)
T.contains("unknown service rejects", tostring(rejected), "Service not found")
T.eq("hasService true", client:hasService("control4_led"), true)
T.eq("hasService false", client:hasService("missing"), false)

-- An action with no arguments sends none.
requests = {}
client.userServices.no_args = 8
client.userServiceArgs.no_args = {}
client:executeServiceWithArgs("no_args", { state = true })
T.eq("no args field", requests[1].body.args, nil)

--------------------------------------------------------------------------------
-- A fake device for the event entity.
--------------------------------------------------------------------------------

local calls = {}
local hasAction = true
local failNext = false
-- Actions the fake device declares, beyond the generic one.
local deviceActions = {}
-- The type each argument is declared as; strings unless a test says otherwise.
local declaredTypes = {}
local fakeClient = {}
function fakeClient:hasService(name)
  if deviceActions[name] then
    return true
  end
  return hasAction and name == EventEntity.LED_ACTION
end
function fakeClient:executeServiceWithArgs(name, args)
  -- Resolve typed values the way the real client does.
  local resolved = {}
  for k, v in pairs(args) do
    if type(v) == "function" then
      v = v(declaredTypes[k] or ArgType.SERVICE_ARG_TYPE_STRING)
    end
    resolved[k] = v
  end
  calls[#calls + 1] = { name = name, args = resolved }
  if failNext then
    failNext = false
    return deferred.new():reject("boom")
  end
  return deferred.new():resolve()
end

local entity = { key = 42, ref = "42", name = "Touch", event_types = { "press", "long_press" } }
local instance = EventEntity:new(fakeClient)
instance:discovered(entity)

local press = bindings:getDynamicBinding(EventEntity.TYPE, "event_42:press")
local long = bindings:getDynamicBinding(EventEntity.TYPE, "event_42:long_press")

--------------------------------------------------------------------------------
T.section("Discovery registers a handler on each event type's link")
--------------------------------------------------------------------------------

T.eq("press handler", type(RFP[press.bindingId]), "function")
T.eq("long_press handler", type(RFP[long.bindingId]), "function")
T.eq("nothing sent before the load reports", #calls, 0)

--------------------------------------------------------------------------------
T.section("Colors then state: the state picks the on or off color")
--------------------------------------------------------------------------------

-- Through the real dispatcher, with the string values Director delivers.
ReceivedFromProxy(press.bindingId, "BUTTON_COLORS", { ON_COLOR = "00ff00", OFF_COLOR = "#ff0000" })
T.eq("colors alone send nothing (no state yet)", #calls, 0)

ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "true" })
T.eq("one call", #calls, 1)
T.eq("action", calls[1].name, "control4_led")
T.eq("event", calls[1].args.event, "Touch")
T.eq("event_type", calls[1].args.event_type, "press")
T.eq("state on", calls[1].args.state, true)
T.eq("on color shown", calls[1].args.color, "00FF00")
T.eq("on_color", calls[1].args.on_color, "00FF00")
T.eq("off_color normalized", calls[1].args.off_color, "FF0000")
T.eq("LED variable", values:getValue("Touch press LED").value, true)

ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "false" })
T.eq("second call", #calls, 2)
T.eq("state off", calls[2].args.state, false)
T.eq("off color shown", calls[2].args.color, "FF0000")
T.eq("LED variable off", values:getValue("Touch press LED").value, false)

--------------------------------------------------------------------------------
T.section("A repeat of the same feedback is not resent")
--------------------------------------------------------------------------------

ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "0" })
T.eq("no duplicate", #calls, 2)

--------------------------------------------------------------------------------
T.section("A boolean STATE and a color named outright")
--------------------------------------------------------------------------------

ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = true, CURRENT_COLOR = "0000FF" })
T.eq("sent", #calls, 3)
T.eq("explicit color wins", calls[3].args.color, "0000FF")
ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "true" })
-- The same state without an explicit color goes back to the on color.
T.eq("back to on color", calls[4].args.color, "00FF00")

--------------------------------------------------------------------------------
T.section("Event types are independent; no colors means an empty color")
--------------------------------------------------------------------------------

ReceivedFromProxy(long.bindingId, "MATCH_LED_STATE", { STATE = "1" })
T.eq("sent", #calls, 5)
T.eq("long_press type", calls[5].args.event_type, "long_press")
T.eq("no color known", calls[5].args.color, "")
T.eq("press colors untouched", calls[4].args.on_color, "00FF00")

--------------------------------------------------------------------------------
T.section("A failed send is retried by the next message")
--------------------------------------------------------------------------------

failNext = true
ReceivedFromProxy(long.bindingId, "MATCH_LED_STATE", { STATE = "0" })
T.eq("attempted", #calls, 6)
ReceivedFromProxy(long.bindingId, "MATCH_LED_STATE", { STATE = "0" })
T.eq("retried after failure", #calls, 7)

--------------------------------------------------------------------------------
T.section("A device without the action is left alone")
--------------------------------------------------------------------------------

hasAction = false
ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "false" })
T.eq("no call", #calls, 7)
T.eq("variable still tracks", values:getValue("Touch press LED").value, false)
hasAction = true

--------------------------------------------------------------------------------
T.section("A reconnect replays the last feedback")
--------------------------------------------------------------------------------

calls = {}
instance:discovered(entity)
T.eq("both types replayed", #calls, 2)
local replayed = {}
for _, call in ipairs(calls) do
  replayed[call.args.event_type] = call.args
end
T.eq("press replayed off", replayed.press.state, false)
T.eq("press off color", replayed.press.color, "FF0000")
T.eq("long_press replayed off", replayed.long_press.state, false)

--------------------------------------------------------------------------------
T.section("The link never answers back, and a tap still drives the load")
--------------------------------------------------------------------------------

T.eq("nothing sent over the link", table.concat(sent, ","), "")

--------------------------------------------------------------------------------
T.section("Action names follow <event name>_<event type>_led")
--------------------------------------------------------------------------------

T.eq("simple", EventEntity.ledActionName({ name = "Touch Button 2" }, "press"), "touch_button_2_press_led")
T.eq(
  "type with underscore",
  EventEntity.ledActionName({ name = "Gang 3 Paddle Event" }, "double_press"),
  "gang_3_paddle_event_double_press_led"
)
T.eq(
  "punctuation collapses, ends trimmed",
  EventEntity.ledActionName({ name = " Arrive/Leave -- Hall! " }, "press"),
  "arrive_leave_hall_press_led"
)

--------------------------------------------------------------------------------
T.section("The event type's own action wins over the generic one")
--------------------------------------------------------------------------------

calls = {}
deviceActions = { touch_press_led = true }
ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "true" })
T.eq("sent once", #calls, 1)
T.eq("own action", calls[1].name, "touch_press_led")
-- long_press has no action of its own, so it still uses the generic one.
ReceivedFromProxy(long.bindingId, "MATCH_LED_STATE", { STATE = "true" })
T.eq("fallback action", calls[2].name, "control4_led")

T.section("Only the own action, no generic one: the others are skipped quietly")
calls = {}
hasAction = false
ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "false" })
ReceivedFromProxy(long.bindingId, "MATCH_LED_STATE", { STATE = "false" })
T.eq("only the own action is called", #calls, 1)
T.eq("which is press", calls[1].name, "touch_press_led")
hasAction = true
deviceActions = {}

--------------------------------------------------------------------------------
T.section("A color declared as int is sent as 0xRRGGBB, or -1 when unknown")
--------------------------------------------------------------------------------

declaredTypes = {
  color = ArgType.SERVICE_ARG_TYPE_INT,
  on_color = ArgType.SERVICE_ARG_TYPE_INT,
  off_color = ArgType.SERVICE_ARG_TYPE_INT,
}
calls = {}
ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "true" })
T.eq("on color as int", calls[1].args.color, 0x00FF00)
T.eq("on_color as int", calls[1].args.on_color, 0x00FF00)
T.eq("off_color as int", calls[1].args.off_color, 0xFF0000)
ReceivedFromProxy(long.bindingId, "MATCH_LED_STATE", { STATE = "0" })
T.eq("no color known is -1", calls[2].args.color, -1)
T.eq("no on_color known is -1", calls[2].args.on_color, -1)
declaredTypes = {}

--------------------------------------------------------------------------------
T.section("The real client sends an int color as int_")
--------------------------------------------------------------------------------

requests = {}
client.userServices.touch_press_led = 9
client.userServiceArgs.touch_press_led = {
  { name = "state", type = ArgType.SERVICE_ARG_TYPE_BOOL },
  { name = "color", type = ArgType.SERVICE_ARG_TYPE_INT },
}
local realEntity = EventEntity:new(client)
realEntity:discovered(entity)
calls = {}
ReceivedFromProxy(press.bindingId, "MATCH_LED_STATE", { STATE = "false" })
T.eq("one request", #requests >= 1, true)
local last = requests[#requests]
T.eq("to the own action's key", last.body.key, 9)
T.check(
  "state and int color",
  T.deepEqual(last.body.args, { { bool_ = false }, { int_ = 0xFF0000 } }),
  T.show(last.body.args)
)
sent = {}
instance:updated(entity, { event_type = "press" })
T.eq("tap", table.concat(sent, ","), press.bindingId .. ":DO_PUSH," .. press.bindingId .. ":DO_CLICK")

T.finish()
