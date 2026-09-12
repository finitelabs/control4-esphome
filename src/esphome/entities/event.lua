local log = require("lib.logging")
local bindings = require("lib.bindings")
local events = require("lib.events")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")

--- @class EventEntity:Entity
local EventEntity = {
  TYPE = ESPHomeClient.EntityType.EVENT,
}
EventEntity.__index = EventEntity

--- Build the binding key for one of an entity's event types.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param eventType string The event type name declared by the entity.
--- @return string key
local function bindingKey(entity, eventType)
  return "event_" .. entity.key .. ":" .. eventType
end

--- Create a new instance of the event entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return EventEntity entity A new instance of the EventEntity entity.
function EventEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of an event entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function EventEntity:discovered(entity)
  log:trace("EventEntity:discovered(%s)", entity)

  local eventTypes = entity.event_types or {}
  for _, eventType in ipairs(eventTypes) do
    events:getOrAddEvent(
      "event_" .. entity.key,
      eventType,
      entity.name .. ": " .. eventType,
      entity.name .. " " .. eventType .. " event"
    )

    -- provider=false is the keypad side: this driver sends button events rather
    -- than receiving them, and each event type drives its own load.
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      bindingKey(entity, eventType),
      "CONTROL",
      false,
      entity.name .. " " .. eventType,
      "BUTTON_LINK"
    )
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

  events:fire("event_" .. entity.key, eventType)
  log:info("Fired event %s for %s", eventType, ESPHomeClient.describeEntity(entity))

  local binding = bindings:getDynamicBinding(self.TYPE, bindingKey(entity, eventType))
  if binding == nil then
    log:warn("No button link for event type %s on %s", eventType, ESPHomeClient.describeEntity(entity))
    return
  end

  -- A gesture the device already finished has no button-down to report. Adding
  -- DO_PUSH starts a hold ramp that the following DO_RELEASE freezes where it
  -- began, undoing the click.
  SendToProxy(binding.bindingId, "DO_CLICK", {}, "NOTIFY")
end

return EventEntity
