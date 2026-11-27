-- Tests the LED feedback each event button link passes on to the device's own
-- user-defined API action, for devices with no light for the button (such as a
-- display) that show the load's state themselves.
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
-- A fake device: which actions it declares and how each argument is typed.
--------------------------------------------------------------------------------

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
    local resolved = {}
    for k, v in pairs(args) do
      if type(v) == "function" then
        v = v(declaredTypes[k] or ArgType.SERVICE_ARG_TYPE_INT)
      end
      resolved[k] = v
    end
    calls[#calls + 1] = { name = name, args = resolved }
    if failNext then
      failNext = false
      return deferred.new():reject("boom")
    end
    return deferred.new():resolve()
  end,
}

local touch2 = {
  entity_type = "event",
  key = 2,
  ref = "2",
  device_id = 0,
  name = "Touch Button 2",
  event_types = { "press", "long_press" },
}
local entities = { a = touch2 }
local leds = ButtonLeds:new(device)
local events = EventEntity:new(device, leds)
events:discovered(touch2)
local press = bindings:getDynamicBinding(EventEntity.TYPE, "event_2:press").bindingId
local long = bindings:getDynamicBinding(EventEntity.TYPE, "event_2:long_press").bindingId
leds:discovered(entities)

local function last()
  return calls[#calls]
end

--------------------------------------------------------------------------------
T.section("Action names")
--------------------------------------------------------------------------------

T.eq("event and type, slugged", ButtonLeds.actionName(touch2, "press"), "touch_button_2_press_led")
T.eq(
  "runs of other characters",
  ButtonLeds.actionName({ name = " Gang #3 / Up " }, "Long Press"),
  "gang_3_up_long_press_led"
)

--------------------------------------------------------------------------------
T.section("A device that declares no action is left alone")
--------------------------------------------------------------------------------

RFP[press](press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("nothing sent", #calls, 0)

--------------------------------------------------------------------------------
T.section("The link's own action gets its state and the keypad's color")
--------------------------------------------------------------------------------

actions.touch_button_2_press_led = true
actions.control4_led = true
RFP[press](press, "BUTTON_COLORS", { ON_COLOR = "ffd166", OFF_COLOR = "#202530" })
T.eq("own action wins over control4_led", last().name, "touch_button_2_press_led")
T.eq("state", last().args.state, true)
T.eq("on: color is the on color", last().args.color, 0xFFD166)
T.eq("on_color", last().args.on_color, 0xFFD166)
T.eq("off_color", last().args.off_color, 0x202530)
T.eq("event_name", last().args.event_name, "Touch Button 2")
T.eq("event_type", last().args.event_type, "press")

RFP[press](press, "MATCH_LED_STATE", { STATE = "0" })
T.eq("off", last().args.state, false)
T.eq("off: color is the off color", last().args.color, 0x202530)

local before = #calls
RFP[press](press, "MATCH_LED_STATE", { STATE = "0" })
T.eq("an unchanged report is not resent", #calls, before)

--------------------------------------------------------------------------------
T.section("Another event type falls back to control4_led")
--------------------------------------------------------------------------------

RFP[long](long, "MATCH_LED_STATE", { STATE = true })
T.eq("generic action", last().name, "control4_led")
T.eq("names its event type", last().args.event_type, "long_press")
T.eq("no colors given: -1", last().args.color, -1)

declaredTypes.color = ArgType.SERVICE_ARG_TYPE_STRING
RFP[long](long, "BUTTON_COLORS", { ON_COLOR = "00ff00" })
T.eq("a string color is hex", last().args.color, "00FF00")
declaredTypes.color = nil

--------------------------------------------------------------------------------
T.section("A failed send is retried by the next report")
--------------------------------------------------------------------------------

failNext = true
RFP[press](press, "MATCH_LED_STATE", { STATE = "1" })
before = #calls
RFP[press](press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("same report sent again after a failure", #calls, before + 1)

--------------------------------------------------------------------------------
T.section("A reconnect replays what is known, and asks the loads again")
--------------------------------------------------------------------------------

leds:disconnected()
connected = false
before = #calls
RFP[press](press, "MATCH_LED_STATE", { STATE = "0" })
T.eq("nothing sent while disconnected", #calls, before)
connected = true
sent = {}
leds:discovered(entities)
local seen = {}
for i = before + 1, #calls do
  seen[calls[i].name .. ":" .. tostring(calls[i].args.state)] = true
end
T.truthy("press replayed (off)", seen["touch_button_2_press_led:false"])
T.truthy("long press replayed", seen["control4_led:true"])
T.contains("asks the press load for its state", table.concat(sent, ","), press .. ":REQUEST_BUTTON_COLORS")

--------------------------------------------------------------------------------
T.section("load_name names what the link is bound to")
--------------------------------------------------------------------------------

-- Two providers: an Advanced Lighting scene binding, and a light's button link.
local AGENT, LIGHT = 501, 502
local names = { [AGENT] = "Advanced Lighting", [LIGHT] = "Dining Pendant" }
local peerBindings = {
  [AGENT] = { { bindingid = 7, name = "Welcome", provider = true } },
  [LIGHT] = { { bindingid = 300, name = "Toggle Button Link", provider = true } },
}
local shimDisplayName, shimBindingsByDevice = C4.GetDeviceDisplayName, C4.GetBindingsByDevice
function C4:GetDeviceDisplayName(id)
  return names[tonumber(id)] or shimDisplayName(self, id)
end
function C4:GetBindingsByDevice(id)
  if peerBindings[tonumber(id)] then
    return { bindings = peerBindings[tonumber(id)] }
  end
  return shimBindingsByDevice(self, id)
end

C4:Bind(AGENT, 7, C4:GetDeviceID(), long, "BUTTON_LINK")
RFP[long](long, "MATCH_LED_STATE", { STATE = false })
T.eq("a scene binding gives its own name", last().args.load_name, "Welcome")

C4:Bind(LIGHT, 300, C4:GetDeviceID(), press, "BUTTON_LINK")
RFP[press](press, "MATCH_LED_STATE", { STATE = true })
T.eq("a light's generic button link gives the device's name", last().args.load_name, "Dining Pendant")

before = #calls
RFP[press](press, "MATCH_LED_STATE", { STATE = true })
T.eq("the name is looked up once and does not resend", #calls, before)

names[LIGHT] = "Renamed Pendant"
leds:discovered(entities)
RFP[press](press, "MATCH_LED_STATE", { STATE = false })
T.eq("a reconnect looks it up again", last().args.load_name, "Renamed Pendant")

C4:Unbind(C4:GetDeviceID(), long)
OBC[long](long, "BUTTON_LINK", false)

--------------------------------------------------------------------------------
T.section("A load that never reports a state still gets its name shown")
--------------------------------------------------------------------------------

-- A scenario button: bound, but it never answers with MATCH_LED_STATE.
local SCENARIO = 503
names[SCENARIO] = "Scenarios"
peerBindings[SCENARIO] = { { bindingid = 9, name = "Arrive Leave Toggle", provider = true } }
C4:Bind(SCENARIO, 9, C4:GetDeviceID(), long, "BUTTON_LINK")
sent = {}
before = #calls
OBC[long](long, "BUTTON_LINK", true)
T.eq("sent on bind", #calls, before + 1)
T.eq("generic words dropped from the binding name", last().args.load_name, "Arrive Leave")
T.eq("shown as off", last().args.state, false)
T.eq("with no color", last().args.color, -1)
T.contains("and the load is asked for its state", table.concat(sent, ","), long .. ":REQUEST_BUTTON_COLORS")

--------------------------------------------------------------------------------
T.section("A load that answers with colors only: its state from its variables")
--------------------------------------------------------------------------------

-- Control4's custom button (uibutton.c4i): answers REQUEST_BUTTON_COLORS with BUTTON_COLORS alone, and keeps its
-- state on its UI button proxy.
OBC[long](long, "BUTTON_LINK", false)
local CUSTOM, CUSTOM_PROXY = 504, 505
names[CUSTOM] = "All AC"
peerBindings[CUSTOM] = {
  {
    bindingid = 5001,
    name = "UIBUTTON",
    provider = true,
    boundconsumers = { { deviceid = CUSTOM_PROXY, bindingid = 5001 } },
  },
  { bindingid = 500, name = "Toggle", provider = true },
}
local customVars = {
  [CUSTOM] = { ["1"] = { name = "COLOR", value = "00c800" } },
  [CUSTOM_PROXY] = { ["1"] = { name = "BUTTON_STATE", value = "1" }, ["2"] = { name = "TEXT", value = "All AC" } },
}
local shimVariables = C4.GetDeviceVariables
function C4:GetDeviceVariables(id)
  return customVars[tonumber(id)] or shimVariables(self, id)
end
C4:Bind(CUSTOM, 500, C4:GetDeviceID(), long, "BUTTON_LINK")
OBC[long](long, "BUTTON_LINK", true)
RFP[long](long, "BUTTON_COLORS", { ON_COLOR = "00c800", OFF_COLOR = "0000ff" })
before = #calls
ShimFireTimers()
T.eq("after the wait, the state comes from the proxy's variable", last().args.state, true)
T.eq("with the on color", last().args.color, 0x00C800)
T.eq("and its name", last().args.load_name, "All AC")

customVars[CUSTOM_PROXY]["1"].value = "0"
RFP[long](long, "MATCH_LED_STATE", { STATE = "1" })
leds:discovered(entities)
ShimFireTimers()
T.eq("a state the load reports wins over its variables", last().args.state, true)
C4:Unbind(C4:GetDeviceID(), long)
OBC[long](long, "BUTTON_LINK", false)

--------------------------------------------------------------------------------
T.section("An unbound link goes dark on the device")
--------------------------------------------------------------------------------

OBC[press](press, "BUTTON_LINK", false)
T.eq("off", last().args.state, false)
T.eq("no color", last().args.color, -1)
T.eq("to its own action", last().name, "touch_button_2_press_led")
T.eq("and no load name", last().args.load_name, "")

T.finish()
