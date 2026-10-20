local log = require("lib.logging")
local bindings = require("lib.bindings")
local events = require("lib.events")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

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

--- The generic user-defined ESPHome action the button LED feedback falls back to
--- when the device has no action for the event type itself (see ledActionName).
--- The device opts in by declaring it under `api: actions:`; any subset of the
--- arguments `event`, `event_type`, `state`, `color`, `on_color` and `off_color`
--- may be declared. Colors are sent as an int (0xRRGGBB, or -1 when the load has
--- not given one) or as a string ("RRGGBB", or empty), whichever the YAML declares.
EventEntity.LED_ACTION = "control4_led"

--- Convert a name to the form ESPHome action names take: lowercase, each run of
--- other characters as one underscore, no underscores at the ends.
--- @param value string
--- @return string
local function slug(value)
  local s = tostring(value or ""):lower():gsub("[^%a%d]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return s
end

--- The per-event-type action the LED feedback for one event type is sent to:
--- `<event name>_<event type>_led`, e.g. "Touch Button 2" + "press" is
--- `touch_button_2_press_led`.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param eventType string The event type name declared by the entity.
--- @return string
function EventEntity.ledActionName(entity, eventType)
  return slug(entity.name) .. "_" .. slug(eventType) .. "_led"
end

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

  local ArgType = ESPHomeProtoSchema.Enum.ServiceArgType
  --- A color in whichever type the action declares it as.
  local function typedColor(hex)
    return function(argType)
      if argType == ArgType.SERVICE_ARG_TYPE_INT or argType == ArgType.SERVICE_ARG_TYPE_FLOAT then
        return hex ~= nil and tonumber(hex, 16) or -1
      end
      return hex or ""
    end
  end

  local args = {
    event = entity.name,
    event_type = eventType,
    state = led.state,
    color = typedColor(color),
    on_color = typedColor(led.onColor),
    off_color = typedColor(led.offColor),
  }
  local signature = table.concat({ tostring(led.state), color or "", led.onColor or "", led.offColor or "" }, "|")
  if not force and led.sent == signature then
    return
  end

  -- The event type's own action first, then the generic one; a device with
  -- neither simply has no LED to drive, so it is skipped without complaint.
  local client = self.client
  local action = nil
  if client ~= nil and type(client.hasService) == "function" then
    local own = self.ledActionName(entity, eventType)
    if client:hasService(own) then
      action = own
    elseif client:hasService(self.LED_ACTION) then
      action = self.LED_ACTION
    end
  end
  if action == nil then
    log:debug(
      "No '%s' or '%s' action on the device; LED feedback for %s %s not sent",
      self.ledActionName(entity, eventType),
      self.LED_ACTION,
      ESPHomeClient.describeEntity(entity),
      eventType
    )
    return
  end

  led.sent = signature
  client:executeServiceWithArgs(action, args):next(function()
    log:debug(
      "LED feedback sent to '%s' for %s %s: state=%s color=%s",
      action,
      ESPHomeClient.describeEntity(entity),
      eventType,
      led.state,
      color or "none"
    )
  end, function(error)
    -- Let the next message (or reconnect) try again.
    led.sent = nil
    log:error(
      "Failed to send LED feedback to '%s' for %s %s; %s",
      action,
      ESPHomeClient.describeEntity(entity),
      eventType,
      error
    )
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

    log:info(
      "LED feedback for %s %s goes to the device action '%s' (or '%s')",
      entity.name,
      eventType,
      self.ledActionName(entity, eventType),
      self.LED_ACTION
    )

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
