--- The `Events` module provides functionality for managing dynamic events, including creating, retrieving, firing, deleting, and restoring events.
--- Events are stored persistently and are associated with unique IDs.

local log = require("lib.logging")
local persist = require("lib.persist")

require("drivers-common-public.global.lib")
require("lib.utils")

--- @class Events
local Events = {}
Events.__index = Events

--- The key used to persist events in storage.
--- @type string
local EVENTS_PERSIST_KEY = "Events"

--- The starting ID for events.
--- @type number
local EVENT_ID_START = 10

--- The ending ID for events.
--- @type number
local EVENT_ID_END = 999

--- @class Event
--- @field eventId number
--- @field name string
--- @field description string

--- Calls `fn` with each saved event that has its ID, and `skipped` with the namespace and key of any other entry.
--- @param saved table<string, table<string, Event>> The saved events.
--- @param fn fun(event: Event)
--- @param skipped? fun(namespace: any, key: any)
local function eachEvent(saved, fn, skipped)
  for namespace, keys in pairs(saved) do
    for key, event in pairs(type(keys) == "table" and keys or {}) do
      if Select(event, "eventId") ~= nil then
        fn(event)
      elseif skipped then
        skipped(namespace, key)
      end
    end
  end
end

--- Creates a new `Events` instance.
--- @return Events events A new `Events` instance.
function Events:new()
  log:trace("Events:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- Retrieves or adds an event. If the event does not exist, it creates a new one with a unique ID.
--- An existing event whose name or description differs is updated under the same ID.
--- @param namespace string The namespace of the event.
--- @param key string The key of the event.
--- @param name string The name of the event.
--- @param description string The description of the event.
--- @return Event|nil event The event object or nil if the event could not be created.
function Events:getOrAddEvent(namespace, key, name, description)
  log:trace("Events:getOrAddEvent(%s, %s, %s, %s)", namespace, key, name, description)
  local events = self:getEvents()
  --- @type Event|nil
  local event = Select(events, namespace, key)
  if Select(event, "eventId") == nil then
    local eventId = self:_getNextEventId()
    -- Declared before it is saved: a declaration C4 refuses must not leave a record that every restart replays.
    C4:AddEvent(eventId, name, description)
    event = {
      eventId = eventId,
      name = name,
      description = description,
    }

    events[namespace] = type(events[namespace]) == "table" and events[namespace] or {}
    events[namespace][key] = event
    self:_saveEvents(events)
  elseif event.name ~= name or event.description ~= description then
    --- @cast event Event
    -- Programming binds to the ID, so changed text keeps it; AddEvent on a known ID updates it.
    C4:AddEvent(event.eventId, name, description)
    event.name = name
    event.description = description
    self:_saveEvents(events)
  end
  return event
end

--- Fires an event by namespace and key.
--- @param namespace string The namespace of the event.
--- @param key string The key of the event.
function Events:fire(namespace, key)
  log:trace("Events:fire(%s, %s)", namespace, key)
  --- @type number|nil
  local eventId = Select(self:getEvents(), namespace, key, "eventId")
  if IsEmpty(eventId) then
    return
  end
  --- @cast eventId -nil
  C4:FireEventByID(eventId)
end

--- Deletes an event by namespace and key. Removes the event from persistent storage and deletes the associated event.
--- @param namespace string The namespace of the event.
--- @param key string The key of the event.
function Events:deleteEvent(namespace, key)
  log:trace("Events:deleteEvent(%s, %s)", namespace, key)
  local events = self:getEvents()
  --- @type number|nil
  local eventId = Select(events, namespace, key, "eventId")
  if IsEmpty(eventId) then
    return
  end
  --- @cast eventId -nil
  C4:DeleteEvent(eventId)

  events[namespace][key] = nil
  if IsEmpty(events[namespace]) then
    events[namespace] = nil
  end
  if IsEmpty(events) then
    --- @diagnostic disable-next-line: assign-type-mismatch
    events = nil
  end

  self:_saveEvents(events)
end

--- Restores all events from persistent storage. Ensures that all events are re-added and removes unknown events.
---
--- Call this from OnDriverLateInit: C4:AddEvent is unavailable earlier.
function Events:restoreEvents()
  log:trace("Events:restoreEvents()")
  --- @type table<number, boolean>
  local usedEventIds = {}
  eachEvent(self:getEvents(), function(event)
    usedEventIds[event.eventId] = true
    C4:AddEvent(event.eventId, event.name, event.description)
  end, function(namespace, key)
    log:warn("Skipping saved event %s/%s: it has no event ID", namespace, key)
  end)
  for id = EVENT_ID_START, EVENT_ID_END do
    if usedEventIds[id] == nil then
      log:trace("Deleting non-configured event %s, if it exists", id)
      C4:DeleteEvent(id)
    end
  end
end

--- Retrieves the next available event ID. Ensures that the ID is unique and within the allowed range.
--- @private
--- @return number eventId The next available event ID.
function Events:_getNextEventId()
  log:trace("Events:_getNextEventId()")
  --- @type table<number, boolean>
  local currentEvents = {}
  eachEvent(self:getEvents(), function(event)
    currentEvents[event.eventId] = true
  end)
  local nextId = EVENT_ID_START
  while currentEvents[nextId] ~= nil do
    nextId = nextId + 1
  end
  return nextId
end

--- Retrieves all events from persistent storage.
--- @return table<string, table<string, Event>> events A table of all events mapped by namespace then key.
--- @diagnostic disable-next-line: unused
function Events:getEvents()
  log:trace("Events:getEvents()")
  return persist:get(EVENTS_PERSIST_KEY, {}) or {}
end

--- Saves the events to persistent storage.
--- @private
--- @param events table<string, table<string, Event>>? The events table to save.
--- @diagnostic disable-next-line: unused
function Events:_saveEvents(events)
  log:trace("Events:_saveEvents(%s)", events)
  persist:set(EVENTS_PERSIST_KEY, not IsEmpty(events) and events or nil)
end

--- Resets all dynamic events, removing them from the system and clearing persisted storage.
function Events:reset()
  log:trace("Events:reset()")
  eachEvent(self:getEvents(), function(event)
    log:debug("Removing event '%s' (id=%s)", event.name, event.eventId)
    C4:DeleteEvent(event.eventId)
  end)
  self:_saveEvents(nil)
end

return Events:new()
