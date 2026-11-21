-- Tests the Button LED action: each event button link passes its load's LED state
-- and colors to an API action the device declares, so a display can show both.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_button_led_actions.lua

require("drivers-common-public.global.lib")
require("c4_shim")

local T = require("testlib")
local deferred = require("deferred")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local ButtonLeds = require("esphome.button_leds")
local EventEntity = require("esphome.entities.event")

local ArgType = ESPHomeProtoSchema.Enum.ServiceArgType

local sent = {}
function C4:SendToProxy(idBinding, strCommand)
  sent[#sent + 1] = tostring(idBinding) .. ":" .. tostring(strCommand)
end
function C4:UpdatePropertyList() end
function C4:SetPropertyAttribs() end

T.section("A service's arguments follow its declared order and types")
local requests = {}
local client = ESPHomeClient:new()
client.userServices = { control4_led = 7, no_args = 8 }
client.userServiceArgs = {
  control4_led = {
    { name = "state", type = ArgType.SERVICE_ARG_TYPE_BOOL },
    { name = "color", type = ArgType.SERVICE_ARG_TYPE_STRING },
    { name = "event_name", type = ArgType.SERVICE_ARG_TYPE_STRING },
    { name = "level", type = ArgType.SERVICE_ARG_TYPE_INT },
    { name = "ratio", type = ArgType.SERVICE_ARG_TYPE_FLOAT },
  },
  no_args = {},
}
function client:callServiceMethod(method, body)
  requests[#requests + 1] = { method = method, body = body }
  return deferred.new():resolve()
end

local resolved = false
client
  :executeServiceWithArgs("control4_led", { color = "FF0000", state = true, event_name = "Button", extra = "dropped" })
  :next(function()
    resolved = true
  end)
T.eq("it resolves", resolved, true)
T.eq("one execute_service request", requests[1].method, ESPHomeProtoSchema.RPC.APIConnection.execute_service)
T.eq("for the service's key", requests[1].body.key, 7)
T.check(
  "declared order and types, a missing value as its type's zero",
  T.deepEqual(requests[1].body.args, {
    { bool_ = true },
    { string_ = "FF0000" },
    { string_ = "Button" },
    { int_ = 0 },
    { float_ = 0 },
  }),
  T.show(requests[1].body.args)
)
client:executeServiceWithArgs("no_args", { state = true })
T.eq("a service with no arguments gets none", requests[2].body.args, nil)
local rejected
client:executeServiceWithArgs("missing", {}):next(nil, function(err)
  rejected = err
end)
T.contains("an unknown service is refused", tostring(rejected), "Service not found")
T.eq("hasService knows a declared service", client:hasService("control4_led"), true)
T.eq("and not an undeclared one", client:hasService("missing"), false)

local calls = {}
local connected = true
local actions = {}
local declaredTypes = {}
local failNext = false
local device = {
  isConnected = function()
    return connected
  end,
  getDeviceName = function()
    return "Panel"
  end,
  callServiceMethod = function()
    return deferred.new():resolve()
  end,
  hasService = function(_, name)
    return actions[name] == true
  end,
  executeServiceWithArgs = function(_, name, args)
    local values = {}
    for key, value in pairs(args) do
      if type(value) == "function" then
        value = value(declaredTypes[key] or ArgType.SERVICE_ARG_TYPE_INT)
      end
      values[key] = value
    end
    calls[#calls + 1] = { name = name, args = values }
    if failNext then
      failNext = false
      return deferred.new():reject("refused")
    end
    return deferred.new():resolve()
  end,
}

local button2 = {
  entity_type = "event",
  key = 2,
  ref = "2",
  device_id = 0,
  name = "Button 2",
  event_types = { "press", "long_press" },
}
local entities = { a = button2 }
local leds = ButtonLeds:new(device)
local events = EventEntity:new(device, leds)
events:discovered(button2)
local press = bindings:getDynamicBinding(EventEntity.TYPE, "event_2:press").bindingId
local long = bindings:getDynamicBinding(EventEntity.TYPE, "event_2:long_press").bindingId
leds:discovered(entities)

local function last()
  return calls[#calls]
end

T.section("A link's action is named from its connection")
T.eq("Button 2 press", ButtonLeds.actionName(button2, "press"), "button_2_press_led")
T.eq(
  "other characters as one underscore",
  ButtonLeds.actionName({ name = " Gang #3 / Up " }, "Long Press"),
  "gang_3_up_long_press_led"
)

T.section("A device that declares no action is left alone")
RFP[press](press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("nothing is sent", #calls, 0)

T.section("Nothing is sent before the load reports its state")
actions.button_2_press_led = true
actions.control4_led = true
OBC[long](long, "BUTTON_LINK", true)
T.eq("a bind sends nothing", #calls, 0)
RFP[long](long, "BUTTON_COLORS", { OFF_COLOR = "00ff00" })
T.eq("colors alone send nothing", #calls, 0)
leds:discovered(entities)
T.eq("a connect sends only the link whose load has reported", #calls, 1)
T.eq("press, on", last().args.state, true)

T.section("The link's own action gets its state and the keypad's color")
RFP[press](press, "BUTTON_COLORS", { ON_COLOR = "ffd166", OFF_COLOR = "#202530" })
T.eq("its own action wins over control4_led", last().name, "button_2_press_led")
T.eq("on", last().args.state, true)
T.eq("color is the on color while on", last().args.color, 0xFFD166)
T.eq("on_color", last().args.on_color, 0xFFD166)
T.eq("off_color", last().args.off_color, 0x202530)
T.eq("event_name", last().args.event_name, "Button 2")
T.eq("event_type", last().args.event_type, "press")
local before = #calls
RFP[press](press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("the same report is not sent again", #calls, before)
RFP[press](press, "MATCH_LED_STATE", { STATE = "0" })
T.eq("off", last().args.state, false)
T.eq("color is the off color while off", last().args.color, 0x202530)

T.section("Another event type falls back to control4_led")
RFP[long](long, "MATCH_LED_STATE", { STATE = true })
T.eq("the shared action", last().name, "control4_led")
T.eq("names its event type", last().args.event_type, "long_press")
T.eq("on with no on color: -1, not the off color", last().args.color, -1)
T.eq("the off color still comes through", last().args.off_color, 0x00FF00)
declaredTypes.off_color = ArgType.SERVICE_ARG_TYPE_STRING
RFP[long](long, "BUTTON_COLORS", { OFF_COLOR = "0000ff" })
T.eq("a color declared as a string is hex", last().args.off_color, "0000FF")
declaredTypes.color = ArgType.SERVICE_ARG_TYPE_STRING
RFP[long](long, "BUTTON_COLORS", { OFF_COLOR = "000080" })
T.eq("and none is empty", last().args.color, "")
declaredTypes = {}

T.section("A failed send is retried by the next report")
failNext = true
RFP[press](press, "MATCH_LED_STATE", { STATE = "1" })
before = #calls
RFP[press](press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("the same report is sent again", #calls, before + 1)

T.section("A reconnect replays what is known and asks the loads again")
leds:disconnected()
connected = false
before = #calls
RFP[press](press, "MATCH_LED_STATE", { STATE = "0" })
T.eq("nothing is sent while disconnected", #calls, before)
connected = true
sent = {}
leds:discovered(entities)
local seen = {}
for i = before + 1, #calls do
  seen[calls[i].name .. ":" .. tostring(calls[i].args.state)] = true
end
T.truthy("press is replayed, off", seen["button_2_press_led:false"])
T.truthy("long press is replayed", seen["control4_led:true"])
T.contains("press's load is asked for its state", table.concat(sent, ","), press .. ":REQUEST_BUTTON_COLORS")

T.section("An unbound link goes dark on the device")
OBC[press](press, "BUTTON_LINK", false)
T.eq("to its own action", last().name, "button_2_press_led")
T.eq("off", last().args.state, false)
T.eq("with no color", last().args.color, -1)

T.finish()
