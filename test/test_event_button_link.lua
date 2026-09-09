-- Tests the button link an event entity publishes for each of its event types.
--
-- The send is one DO_CLICK and nothing else. A DO_PUSH alongside it starts a
-- hold ramp on a bound dimmer, and a following DO_RELEASE freezes that ramp
-- where it began, so the click is undone at the moment it starts. An ESPHome
-- event is a gesture the device has already completed, so there is no
-- button-down to report in the first place.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_event_button_link.lua

require("drivers-common-public.global.lib")
require("c4_shim")

local T = require("testlib")

local bindings = require("lib.bindings")
local EventEntity = require("esphome.entities.event")

-- Captured below lib.utils' SendToProxy wrapper rather than in place of it, so
-- the wrapper stays in the path under test.
local sent = {}
function C4:SendToProxy(idBinding, strCommand)
  sent[#sent + 1] = tostring(idBinding) .. ":" .. tostring(strCommand)
end

local entity = { key = 42, name = "Touch", event_types = { "press", "long_press" } }
local instance = EventEntity:new({})
instance:discovered(entity)

T.section("Discovery publishes one keypad binding per declared event type")

local press = bindings:getDynamicBinding(EventEntity.TYPE, "event_42:press")
local long = bindings:getDynamicBinding(EventEntity.TYPE, "event_42:long_press")

T.eq("press binding exists", press ~= nil, true)
T.eq("long_press binding exists", long ~= nil, true)
T.eq("distinct binding ids", press.bindingId ~= long.bindingId, true)
T.eq("class", press.class, "BUTTON_LINK")
T.eq("type", press.type, "CONTROL")
-- provider=false is the keypad side: it sends button events rather than
-- receiving them, which is what makes the connection an Input in Composer.
T.eq("consumer side", press.provider, false)
T.eq("display name", long.displayName, "Touch long_press")

-- The Control4 events for Programming are published alongside the bindings, so
-- an event type can be used either way.
local declared = {}
for _, event in pairs(ShimEvents()) do
  declared[event.name] = true
end
T.eq("programming event for press", declared["Touch: press"], true)
T.eq("programming event for long_press", declared["Touch: long_press"], true)

T.section("An event sends exactly one DO_CLICK, on its own type's binding")

sent = {}
instance:updated(entity, { event_type = "press" })
T.eq("press", table.concat(sent, ","), press.bindingId .. ":DO_CLICK")

sent = {}
instance:updated(entity, { event_type = "long_press" })
T.eq("long_press", table.concat(sent, ","), long.bindingId .. ":DO_CLICK")

T.section("An undeclared event type sends nothing")

sent = {}
instance:updated(entity, { event_type = "triple_press" })
T.eq("no binding, no send", table.concat(sent, ","), "")

T.finish()
