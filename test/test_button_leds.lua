-- Tests the Button LED mirror: each event's button links ask their loads for
-- their LED state, and the light paired with the button shows the first linked
-- load the way a Control4 keypad lights its button.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_button_leds.lua

require("drivers-common-public.global.lib")
require("c4_shim")

local T = require("testlib")
local deferred = require("deferred")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
local constants = require("constants")
local ButtonLeds = require("esphome.button_leds")
local EventEntity = require("esphome.entities.event")

Properties["Configure Button LED"] = constants.SELECT_OPTION
Properties["Button LED"] = ""

local sent, lists, attribs = {}, {}, {}
function C4:SendToProxy(idBinding, strCommand)
  sent[#sent + 1] = tostring(idBinding) .. ":" .. tostring(strCommand)
end
function C4:UpdatePropertyList(name, items, default)
  lists[name] = { items = items, default = default }
end
function C4:SetPropertyAttribs(name, value)
  attribs[name] = value
end
-- Director writes the Properties table when a driver updates a property.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

local commands = {}
local connected = true
local client = {
  isConnected = function()
    return connected
  end,
  getDeviceName = function(_, deviceId)
    return deviceId == 7 and "Gang 3" or "Dummy Buttons"
  end,
  callServiceMethod = function(_, _, body)
    commands[#commands + 1] = body
    return deferred.new():resolve()
  end,
}

local gang1Event = {
  entity_type = "event",
  key = 10,
  ref = "10",
  device_id = 0,
  name = "Gang 1 Paddle Event",
  event_types = { "press", "long_press" },
}
local gang1Led =
  { entity_type = "light", key = 20, ref = "20", device_id = 0, name = "Gang 1 LED", supported_color_modes = { 35 } }
-- Named as they come from the device: the form adds the sub-device's name.
local gang3Event = {
  entity_type = "event",
  key = 30,
  ref = "30@7",
  device_id = 7,
  name = "Paddle Event",
  event_types = { "press", "double_press" },
}
local gang3Led =
  { entity_type = "light", key = 40, ref = "40@7", device_id = 7, name = "LED", supported_color_modes = { 3 } }
local entities = { a = gang1Event, b = gang1Led, c = gang3Event, d = gang3Led }

local leds = ButtonLeds:new(client)
local events = EventEntity:new(client, leds)
events:discovered(gang1Event)
events:discovered(gang3Event)
local gang1Press = bindings:getDynamicBinding(EventEntity.TYPE, "event_10:press").bindingId
local gang1Long = bindings:getDynamicBinding(EventEntity.TYPE, "event_10:long_press").bindingId
local gang3Press = bindings:getDynamicBinding(EventEntity.TYPE, "event_30@7:press").bindingId
local gang3Double = bindings:getDynamicBinding(EventEntity.TYPE, "event_30@7:double_press").bindingId

local function last()
  return commands[#commands]
end

T.section("A connect asks every link's load for its state and fills in the form")
leds:discovered(entities)
local asked = table.concat(sent, ",")
for name, bindingId in pairs({ press = gang1Press, long = gang1Long, gang3 = gang3Press, double = gang3Double }) do
  T.check(name .. " asked", asked:find(bindingId .. ":REQUEST_BUTTON_COLORS", 1, true) ~= nil, asked)
end
T.eq(
  "one entry per button, with its LED",
  lists["Configure Button LED"].items,
  "(Select),Gang 1 Paddle Event,Gang 3 Paddle Event -> Gang 3 LED"
)
T.eq("the form is shown", attribs["Configure Button LED"], constants.SHOW_PROPERTY)
T.eq("the LED picker waits for a button", attribs["Button LED"], constants.HIDE_PROPERTY)
T.eq("nothing is lit before a load reports", #commands, 0)

T.section("A sub-device with one button and one light is paired already")
T.eq("gang 3 is paired with its LED", persist:get("ButtonLedLights", {})["event_30@7"], "40@7")
T.eq("gang 1 is not paired", persist:get("ButtonLedLights", {})["event_10"], nil)

T.section("A single-color LED follows the load's state")
RFP[gang3Press](gang3Press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("one command", #commands, 1)
T.eq("to gang 3's LED", last().key, 40)
T.eq("on", last().state, true)
T.eq("at full brightness", last().brightness, 1)
T.eq("the button's LED variable follows", Variables["Gang 3 Paddle Event LED"], "1")
RFP[gang3Press](gang3Press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("the same state is not sent again", #commands, 1)
RFP[gang3Press](gang3Press, "MATCH_LED_STATE", { STATE = "False" })
T.eq("off", last().state, false)
T.eq("off has no brightness", last().has_brightness, nil)

T.section("The LED follows the first linked event type")
local before = #commands
RFP[gang3Double](gang3Double, "MATCH_LED_STATE", { STATE = true })
T.eq("double_press's load does not move it while press has one", #commands, before)
OBC[gang3Press](gang3Press, "BUTTON_LINK", false)
T.eq("press unbound, it follows double_press", last().state, true)
OBC[gang3Double](gang3Double, "BUTTON_LINK", false)
T.eq("with no load left it goes dark", last().state, false)

T.section("Pairing a button in the form")
leds:configureChanged("Gang 1 Paddle Event")
T.eq("the LED picker is shown", attribs["Button LED"], constants.SHOW_PROPERTY)
T.eq("it lists the lights", lists["Button LED"].items, "(None),Gang 1 LED,Gang 3 LED")
T.eq("with none chosen", Properties["Button LED"], "(None)")
leds:ledChanged("Gang 1 LED")
T.eq("the pair is saved", persist:get("ButtonLedLights", {})["event_10"], "20")
T.eq("the button shows its LED", Properties["Configure Button LED"], "Gang 1 Paddle Event -> Gang 1 LED")

T.section("An RGB LED is blue while a load that sent no colors is on")
RFP[gang1Press](gang1Press, "MATCH_LED_STATE", { STATE = true })
T.eq("to gang 1's LED", last().key, 20)
T.eq("blue", last().blue, 1)
T.eq("no red", last().red, 0)
RFP[gang1Press](gang1Press, "MATCH_LED_STATE", { STATE = false })
T.eq("and dark while it is off", last().state, false)

T.section("An RGB LED shows the load's on and off colors")
RFP[gang1Press](gang1Press, "BUTTON_COLORS", { ON_COLOR = "ff8000", OFF_COLOR = "000033" })
T.eq("off shows the off color", last().state, true)
T.eq("off color blue", last().blue, 1)
T.check("off color level", math.abs(last().brightness - 0x33 / 255) < 1e-9, tostring(last().brightness))
RFP[gang1Press](gang1Press, "MATCH_LED_STATE", { STATE = "1" })
T.eq("on", last().state, true)
T.eq("red", last().red, 1)
T.check("green", math.abs(last().green - 128 / 255) < 1e-9, tostring(last().green))
T.eq("blue", last().blue, 0)
T.eq("at the color's brightness", last().brightness, 1)
RFP[gang1Press](gang1Press, "BUTTON_COLORS", { ON_COLOR = "000000" })
T.eq("a black on color is dark", last().state, false)
RFP[gang1Press](gang1Press, "BUTTON_COLORS", { ON_COLOR = "00ff00" })
local before = #commands
RFP[gang1Long](gang1Long, "BUTTON_COLORS", { ON_COLOR = "ffffff" })
RFP[gang1Long](gang1Long, "MATCH_LED_STATE", { STATE = true })
T.eq("a link the LED does not follow changes nothing", #commands, before)
T.eq("it still shows press's load color", last().green, 1)

T.section("Binding a link asks its load")
sent = {}
OBC[gang1Long](gang1Long, "BUTTON_LINK", true)
T.eq("bound", table.concat(sent, ","), gang1Long .. ":REQUEST_BUTTON_COLORS")

T.section("A reconnect shows the last known state again")
leds:disconnected()
connected = false
before = #commands
RFP[gang3Press](gang3Press, "MATCH_LED_STATE", { STATE = true })
T.eq("nothing is sent while disconnected", #commands, before)
connected = true
leds:discovered(entities)
T.eq("both LEDs are shown again", #commands, before + 2)

T.section("(None) stops a pre-filled pair from coming back")
leds:configureChanged("Gang 3 Paddle Event -> Gang 3 LED")
leds:ledChanged("(None)")
T.eq("stored as none chosen", persist:get("ButtonLedLights", {})["event_30@7"], "")
leds:discovered(entities)
T.eq("not paired again", persist:get("ButtonLedLights", {})["event_30@7"], "")
before = #commands
RFP[gang3Press](gang3Press, "MATCH_LED_STATE", { STATE = false })
T.eq("an unpaired button lights nothing", #commands, before)

T.section("No lights, no form")
leds:discovered({ a = gang1Event })
T.eq("hidden", attribs["Configure Button LED"], constants.HIDE_PROPERTY)

T.finish()
