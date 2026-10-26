local log = require("lib.logging")
local bindings = require("lib.bindings")
local events = require("lib.events")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ButtonLeds = require("esphome.button_leds")

--- @class EventEntity:Entity
--- @field buttonLeds ButtonLeds|nil
local EventEntity = {
  TYPE = ESPHomeClient.EntityType.EVENT,
}
EventEntity.__index = EventEntity

local bindingKey = ButtonLeds.bindingKey

--- Create a new instance of the event entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @param buttonLeds? ButtonLeds Where a load's LED feedback over a button link goes.
--- @return EventEntity entity A new instance of the EventEntity entity.
function EventEntity:new(client, buttonLeds)
  local instance = setmetatable({}, self)
  instance.client = client
  instance.buttonLeds = buttonLeds
  return instance
end

--- Handle the discovery of an event entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function EventEntity:discovered(entity)
  log:trace("EventEntity:discovered(%s)", entity)

  local eventTypes = entity.event_types or {}
  for _, eventType in ipairs(eventTypes) do
    local name = entity.name .. ": " .. eventType
    local description = "NAME " .. entity.name .. " " .. eventType .. " event"
    events:getOrAddEvent("event_" .. entity.ref, eventType, name, description)

    -- provider=false is the keypad side: this driver sends button events rather
    -- than receiving them, and each event type drives its own load.
    local key = bindingKey(entity, eventType)
    local binding =
      bindings:getOrAddDynamicBinding(self.TYPE, key, "CONTROL", false, entity.name .. " " .. eventType, "BUTTON_LINK")

    local buttonLeds = self.buttonLeds
    if binding ~= nil and buttonLeds ~= nil then
      -- The load answers over the link with its LED state and colors, as it does a keypad button.
      RFP[binding.bindingId] = function(_idBinding, strCommand, tParams)
        buttonLeds:received(key, strCommand, tParams)
      end
      OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound)
        if toboolean(bIsBound) then
          buttonLeds:requestState(idBinding)
        else
          buttonLeds:linkUnbound(key)
        end
      end
    end
  end

  -- Create the Last Event variable so programming can reference it before the
  -- first event fires. Events have no persistent state, so the initial value is empty.
  values:update(entity.name .. " Last Event", "", "STRING")
end

--- Handle updates to the event entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function EventEntity:updated(entity, state)
  log:trace("EventEntity:updated(%s, %s)", entity, state)

  local eventType = state.event_type or ""
  if IsEmpty(eventType) then
    log:warn("Received event with empty event_type for %s", ESPHomeClient.describeEntity(entity))
    return
  end

  values:update(entity.name .. " Last Event", eventType, "STRING")

  events:fire("event_" .. entity.ref, eventType)
  log:info("Fired event %s for %s", eventType, ESPHomeClient.describeEntity(entity))

  local binding = bindings:getDynamicBinding(self.TYPE, bindingKey(entity, eventType))
  if binding == nil then
    log:warn("No button link for event type %s on %s", eventType, ESPHomeClient.describeEntity(entity))
    return
  end

  -- The pair a keypad sends for a tap. DO_RELEASE ends a hold instead of a click,
  -- so it does not follow. Advanced Lighting scenes ignore these as NOTIFY.
  SendToProxy(binding.bindingId, "DO_PUSH", {}, "COMMAND")
  SendToProxy(binding.bindingId, "DO_CLICK", {}, "COMMAND")
end

return EventEntity
