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
  return "event_" .. entity.ref .. ":" .. eventType
end

--- The user-defined ESPHome action the button LED feedback is sent to. The device
--- opts in by declaring it under `api: actions:`; any subset of the arguments
--- `event`, `event_type`, `state`, `color`, `on_color` and `off_color` may be declared.
EventEntity.LED_ACTION = "control4_led"

--- LED feedback per binding key, as last told by the connected load.
--- @type table<string, { state: boolean|nil, onColor: string|nil, offColor: string|nil, color: string|nil, sent: string|nil }>
local ledStates = {}

--- Normalize a Control4 color to six uppercase hex digits, or nil.
--- @param value any
--- @return string|nil
local function normalizeColor(value)
  if value == nil then
    return nil
  end
  local hex = tostring(value):gsub("^#", ""):gsub("^0[xX]", ""):upper()
  if hex:match("^%x%x%x%x%x%x$") then
    return hex
  end
  return nil
end

--- Read a parameter case-insensitively, since proxies differ in key case.
--- @param tParams table<string, any>
--- @param name string
--- @return any
local function param(tParams, name)
  if tParams[name] ~= nil then
    return tParams[name]
  end
  local lower = name:lower()
  for k, v in pairs(tParams) do
    if type(k) == "string" and k:lower() == lower then
      return v
    end
  end
  return nil
end

--- Reset the LED feedback held for tests.
function EventEntity._resetLedStates()
  ledStates = {}
end

--- Create a new instance of the event entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return EventEntity entity A new instance of the EventEntity entity.
function EventEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Send one event type's LED feedback to the device's LED action, if it has one.
--- An unchanged send is skipped unless `force` is set (as on a reconnect).
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param eventType string The event type name declared by the entity.
--- @param force boolean|nil Send even if this exact feedback was already sent.
--- @return void
function EventEntity:_forwardLed(entity, eventType, force)
  local key = bindingKey(entity, eventType)
  local led = ledStates[key]
  if led == nil or led.state == nil then
    return
  end

  -- The color the button should show now: one the load names outright, else the
  -- on or off color for the state, the way a Control4 keypad picks its LED color.
  local color = led.color
  if color == nil then
    if led.state then
      color = led.onColor
    else
      color = led.offColor
    end
  end

  local args = {
    event = entity.name,
    event_type = eventType,
    state = led.state,
    color = color or "",
    on_color = led.onColor or "",
    off_color = led.offColor or "",
  }
  local signature = table.concat({ tostring(args.state), args.color, args.on_color, args.off_color }, "|")
  if not force and led.sent == signature then
    return
  end

  local client = self.client
  if client == nil or type(client.hasService) ~= "function" or not client:hasService(self.LED_ACTION) then
    log:debug(
      "No '%s' action on the device; LED feedback for %s %s not sent",
      self.LED_ACTION,
      ESPHomeClient.describeEntity(entity),
      eventType
    )
    return
  end

  led.sent = signature
  client:executeServiceWithArgs(self.LED_ACTION, args):next(function()
    log:debug("LED feedback sent for %s %s: %s", ESPHomeClient.describeEntity(entity), eventType, args)
  end, function(error)
    -- Let the next message (or reconnect) try again.
    led.sent = nil
    log:error("Failed to send LED feedback for %s %s; %s", ESPHomeClient.describeEntity(entity), eventType, error)
  end)
end

--- Handle a message the connected load sends back over an event type's button link.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param eventType string The event type name declared by the entity.
--- @param strCommand string The command received.
--- @param tParams table<string, any>|nil The command parameters.
--- @return void
function EventEntity:_receivedLed(entity, eventType, strCommand, tParams)
  tParams = tParams or {}
  -- Logged at info so a first install shows exactly what the load sends.
  log:info("Button link %s %s received %s %s", entity.name, eventType, strCommand, tParams)

  local key = bindingKey(entity, eventType)
  local led = ledStates[key] or {}
  ledStates[key] = led

  local state = param(tParams, "STATE")
  if state ~= nil then
    led.state = toboolean(state)
  end
  local onColor = normalizeColor(param(tParams, "ON_COLOR"))
  if onColor ~= nil then
    led.onColor = onColor
  end
  local offColor = normalizeColor(param(tParams, "OFF_COLOR"))
  if offColor ~= nil then
    led.offColor = offColor
  end
  -- A color the load names outright for the button's current look.
  local current = param(tParams, "CURRENT_COLOR") or param(tParams, "LED_COLOR") or param(tParams, "COLOR")
  if current ~= nil then
    led.color = normalizeColor(current)
  elseif state ~= nil then
    -- A new state with no explicit color falls back to the on/off colors.
    led.color = nil
  end

  if led.state ~= nil then
    values:update(entity.name .. " " .. eventType .. " LED", led.state, "BOOL")
  end
  self:_forwardLed(entity, eventType, false)
end

--- Handle the discovery of an event entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function EventEntity:discovered(entity)
  log:trace("EventEntity:discovered(%s)", entity)

  local eventTypes = entity.event_types or {}
  for _, eventType in ipairs(eventTypes) do
    local name = entity.name .. ": " .. eventType
    local description = entity.name .. " " .. eventType .. " event"
    local event = events:getOrAddEvent("event_" .. entity.ref, eventType, name, description)
    if event ~= nil and event.name ~= name then
      -- lib.events never renames, but adding a known event id again updates it in place.
      local all = events:getEvents()
      all["event_" .. entity.ref][eventType] = { eventId = event.eventId, name = name, description = description }
      events:_saveEvents(all)
      C4:AddEvent(event.eventId, name, description)
    end

    -- provider=false is the keypad side: this driver sends button events rather
    -- than receiving them, and each event type drives its own load.
    local binding = bindings:getOrAddDynamicBinding(
      self.TYPE,
      bindingKey(entity, eventType),
      "CONTROL",
      false,
      entity.name .. " " .. eventType,
      "BUTTON_LINK"
    )

    if binding ~= nil then
      -- The load answers over the same link with its LED state and colors, as
      -- it would to a Control4 keypad button; pass them on to the device.
      RFP[binding.bindingId] = function(_idBinding, strCommand, tParams, _args)
        self:_receivedLed(entity, eventType, strCommand, tParams)
      end
    end

    -- A (re)connect is a fresh device session: replay the last LED feedback.
    self:_forwardLed(entity, eventType, true)
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
