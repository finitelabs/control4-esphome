local log = require("lib.logging")
local events = require("lib.events")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")

--- @class EventEntity:Entity
local EventEntity = {
  TYPE = ESPHomeClient.EntityType.EVENT,
}
EventEntity.__index = EventEntity

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

  -- Register a C4 event for each event type
  local eventTypes = entity.event_types or {}
  for _, eventType in ipairs(eventTypes) do
    events:getOrAddEvent(
      "event_" .. entity.key,
      eventType,
      entity.name .. ": " .. eventType,
      entity.name .. " " .. eventType .. " event"
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
    log:warn("Received event with empty event_type for %s.%s", entity.entity_type, entity.object_id)
    return
  end

  -- Update the last event variable
  values:update(entity.name .. " Last Event", eventType, "STRING")

  -- Fire the corresponding C4 event
  events:fire("event_" .. entity.key, eventType)
  log:info("Fired event %s for %s.%s", eventType, entity.entity_type, entity.object_id)
end

return EventEntity
