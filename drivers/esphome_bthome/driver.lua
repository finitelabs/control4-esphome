--- ESPHome BTHome Driver
--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_bthome.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
local events = require("lib.events")
local bindings = require("lib.bindings")
local constants = require("constants")
local BTHome = require("bthome")
local UUID = require("esphome.ble.uuid")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Binding IDs
local ESPHOME_BINDING = 5001 -- Inbound binding from parent ESPHome driver

--- Bindings namespace for sensor bindings
local BINDINGS_NAMESPACE = "BTHome"

--- Event namespace for BTHome events
local EVENT_NAMESPACE = "BTHome"

--- @class EventDef
--- @field key string Unique key for the event
--- @field name string Human-readable event name
--- @field description string Event description for programming UI

--- BTHome button event definitions
--- Maps BTHome event names (from vendor/bthome.lua event.BUTTON_NAMES) to C4 event definitions
--- @type table<string, EventDef?>
local BUTTON_EVENT_DEFS = {
  press = { key = "single_press", name = "Single Press", description = "pressed once" },
  double_press = { key = "double_press", name = "Double Press", description = "pressed twice" },
  triple_press = { key = "triple_press", name = "Triple Press", description = "pressed three times" },
  long_press = { key = "long_press", name = "Long Press", description = "held for ~2 seconds" },
  long_double_press = { key = "long_double_press", name = "Long Double Press", description = "held then pressed twice" },
  long_triple_press = {
    key = "long_triple_press",
    name = "Long Triple Press",
    description = "held then pressed three times",
  },
  hold_press = { key = "hold_press", name = "Hold Press", description = "is being held" },
}

--- Dimmer event definitions
--- Maps BTHome dimmer event names (from vendor/bthome.lua event.DIMMER_NAMES) to C4 event definitions
--- @type table<string, EventDef?>
local DIMMER_EVENT_DEFS = {
  rotate_left = { key = "dimmer_left", name = "Rotate Left", description = "rotated counter-clockwise" },
  rotate_right = { key = "dimmer_right", name = "Rotate Right", description = "rotated clockwise" },
}

--- @class SensorBindingConfig
--- @field bindingClass string The binding class for the sensor (e.g., "TEMPERATURE_VALUE")
--- @field scale string? Optional scale for the sensor value (e.g., "PERCENT", "CELSIUS")

--- Sensor binding configurations
--- Maps BTHome sensor names to C4 binding classes
--- @type table<string, SensorBindingConfig?>
local SENSOR_BINDINGS = {
  temperature = {
    bindingClass = "TEMPERATURE_VALUE",
    scale = "CELSIUS",
  },
  humidity = {
    bindingClass = "HUMIDITY_VALUE",
    scale = "PERCENT",
  },
}

--- @class ContactBindingConfig
--- @field openEvent string C4 event to send when BTHome value is true (1)
--- @field closedEvent string C4 event to send when BTHome value is false (0)

--- Binary sensor binding configurations (create CONTACT_SENSOR bindings)
--- Maps BTHome binary sensor names to contact sensor config
--- For "normally closed" sensors (active = closed), swap the events
--- All binary sensors from vendor/bthome.lua OBJECT_IDS are included
--- @type table<string, ContactBindingConfig?>
local CONTACT_BINDINGS = {
  -- Physical open/closed sensors: True (1) = Open, False (0) = Closed
  door = { openEvent = "OPENED", closedEvent = "CLOSED" },
  window = { openEvent = "OPENED", closedEvent = "CLOSED" },
  opening = { openEvent = "OPENED", closedEvent = "CLOSED" },
  garage_door = { openEvent = "OPENED", closedEvent = "CLOSED" },
  lock_unlocked = { openEvent = "OPENED", closedEvent = "CLOSED" },

  -- Detection sensors: True (1) = Detected (non-steady), False (0) = Clear (steady)
  generic_boolean = { openEvent = "OPENED", closedEvent = "CLOSED" },
  motion = { openEvent = "OPENED", closedEvent = "CLOSED" },
  moving = { openEvent = "OPENED", closedEvent = "CLOSED" },
  occupancy = { openEvent = "OPENED", closedEvent = "CLOSED" },
  presence = { openEvent = "OPENED", closedEvent = "CLOSED" },
  vibration_detected = { openEvent = "OPENED", closedEvent = "CLOSED" },
  sound_detected = { openEvent = "OPENED", closedEvent = "CLOSED" },
  light_detected = { openEvent = "OPENED", closedEvent = "CLOSED" },

  -- State sensors: True (1) = Active (non-steady), False (0) = Inactive (steady)
  power_on = { openEvent = "OPENED", closedEvent = "CLOSED" },
  plug = { openEvent = "OPENED", closedEvent = "CLOSED" },
  running = { openEvent = "OPENED", closedEvent = "CLOSED" },
  connectivity = { openEvent = "OPENED", closedEvent = "CLOSED" },
  battery_charging = { openEvent = "OPENED", closedEvent = "CLOSED" },

  -- Alert sensors: True (1) = Alert (non-steady), False (0) = Normal (steady)
  battery_low = { openEvent = "OPENED", closedEvent = "CLOSED" },
  carbon_monoxide_detected = { openEvent = "OPENED", closedEvent = "CLOSED" },
  smoke_detected = { openEvent = "OPENED", closedEvent = "CLOSED" },
  gas_detected = { openEvent = "OPENED", closedEvent = "CLOSED" },
  moisture_detected = { openEvent = "OPENED", closedEvent = "CLOSED" },
  tamper = { openEvent = "OPENED", closedEvent = "CLOSED" },
  cold = { openEvent = "OPENED", closedEvent = "CLOSED" },
  heat = { openEvent = "OPENED", closedEvent = "CLOSED" },
  problem = { openEvent = "OPENED", closedEvent = "CLOSED" },

  -- Safety is inverted: True (1) = Safe (steady), False (0) = Unsafe (alert)
  safety = { openEvent = "CLOSED", closedEvent = "OPENED" },
}

--- @class ObjectVariableDef
--- @field name string User-friendly display name
--- @field type "NUMBER"|"STRING"|"BOOL" Control4 variable type
--- @field hidden boolean? If true, don't create variable or show in summary

--- BTHome object name to variable name mapping
--- Maps BTHome object names to user-friendly Control4 variable/property names
--- Names must match the "name" field in vendor/bthome.lua OBJECT_IDS
--- @type table<string, ObjectVariableDef?>
local OBJECT_VARIABLE_MAP = {
  -- Primary sensors
  battery = { name = "Battery", type = "NUMBER" },
  temperature = { name = "Temperature C", type = "NUMBER" },
  humidity = { name = "Humidity", type = "NUMBER" },
  illuminance = { name = "Illuminance", type = "NUMBER" },
  pressure = { name = "Pressure", type = "NUMBER" },
  dewpoint = { name = "Dew Point", type = "NUMBER" },
  moisture = { name = "Moisture", type = "NUMBER" },

  -- Binary sensors - names must match vendor/bthome.lua OBJECT_IDS
  light_detected = { name = "Light Detected", type = "BOOL" },
  motion = { name = "Motion", type = "BOOL" },
  door = { name = "Door", type = "BOOL" },
  window = { name = "Window", type = "BOOL" },
  opening = { name = "Opening", type = "BOOL" },
  occupancy = { name = "Occupancy", type = "BOOL" },
  presence = { name = "Presence", type = "BOOL" },
  vibration_detected = { name = "Vibration Detected", type = "BOOL" },
  smoke_detected = { name = "Smoke Detected", type = "BOOL" },
  gas_detected = { name = "Gas Detected", type = "BOOL" },
  moisture_detected = { name = "Moisture Detected", type = "BOOL" },
  tamper = { name = "Tamper", type = "BOOL" },
  moving = { name = "Moving", type = "BOOL" },
  lock_unlocked = { name = "Lock Unlocked", type = "BOOL" },
  garage_door = { name = "Garage Door", type = "BOOL" },
  cold = { name = "Cold", type = "BOOL" },
  heat = { name = "Heat", type = "BOOL" },
  running = { name = "Running", type = "BOOL" },
  safety = { name = "Safety", type = "BOOL" },
  problem = { name = "Problem", type = "BOOL" },
  sound_detected = { name = "Sound Detected", type = "BOOL" },
  plug = { name = "Plug", type = "BOOL" },
  power_on = { name = "Power On", type = "BOOL" },
  generic_boolean = { name = "Generic Boolean", type = "BOOL" },
  battery_low = { name = "Battery Low", type = "BOOL" },
  battery_charging = { name = "Battery Charging", type = "BOOL" },
  connectivity = { name = "Connectivity", type = "BOOL" },
  carbon_monoxide_detected = { name = "Carbon Monoxide Detected", type = "BOOL" },

  -- Events
  button = { name = "Button", type = "NUMBER" },
  dimmer = { name = "Dimmer", type = "NUMBER" },

  -- Power/energy sensors
  voltage = { name = "Voltage", type = "NUMBER" },
  current = { name = "Current", type = "NUMBER" },
  power = { name = "Power", type = "NUMBER" },
  energy = { name = "Energy", type = "NUMBER" },

  -- Air quality sensors
  co2 = { name = "CO2", type = "NUMBER" },
  tvoc = { name = "TVOC", type = "NUMBER" },
  pm2_5 = { name = "PM2.5", type = "NUMBER" },
  pm10 = { name = "PM10", type = "NUMBER" },

  -- Distance/volume sensors
  distance_mm = { name = "Distance", type = "NUMBER" },
  distance_m = { name = "Distance", type = "NUMBER" },
  volume = { name = "Volume", type = "NUMBER" },
  volume_ml = { name = "Volume", type = "NUMBER" },
  volume_storage = { name = "Volume Storage", type = "NUMBER" },
  volume_flow_rate = { name = "Volume Flow Rate", type = "NUMBER" },
  water = { name = "Water", type = "NUMBER" },
  gas = { name = "Gas", type = "NUMBER" },

  -- Motion/orientation sensors
  acceleration = { name = "Acceleration", type = "NUMBER" },
  acceleration_signed = { name = "Acceleration", type = "NUMBER" },
  gyroscope = { name = "Gyroscope", type = "NUMBER" },
  speed = { name = "Speed", type = "NUMBER" },
  speed_signed = { name = "Speed", type = "NUMBER" },
  rotational_speed = { name = "Rotational Speed", type = "NUMBER" },
  direction = { name = "Direction", type = "NUMBER" },
  rotation = { name = "Rotation", type = "NUMBER" },

  -- Misc sensors
  count = { name = "Count", type = "NUMBER" },
  duration = { name = "Duration", type = "NUMBER" },
  uv_index = { name = "UV Index", type = "NUMBER" },
  mass_kg = { name = "Mass", type = "NUMBER" },
  mass_lb = { name = "Mass", type = "NUMBER" },
  conductivity = { name = "Conductivity", type = "NUMBER" },
  timestamp = { name = "Timestamp", type = "NUMBER" },
  precipitation = { name = "Precipitation", type = "NUMBER" },
  channel = { name = "Channel", type = "NUMBER", hidden = true },
  text = { name = "Text", type = "STRING" },
  raw = { name = "Raw", type = "STRING", hidden = true },

  -- Device metadata
  device_type_id = { name = "Device Type ID", type = "NUMBER" },
  firmware_version = { name = "Firmware Version", type = "STRING" },

  -- Hidden internal fields
  packet_id = { name = "Packet ID", type = "NUMBER", hidden = true },
}

--- Optional properties that should be hidden unless we have data
--- These are generated dynamically from sensor readings
local OPTIONAL_PROPERTIES = {
  -- Device Info
  "Name",
  "Device Type",
  "Device Type ID",
  "Firmware Version",

  -- Primary sensors
  "Battery",
  "Temperature C",
  "Temperature F",
  "Humidity",
  "Illuminance",
  "Pressure",
  "Dew Point",
  "Moisture",

  -- Binary sensors (names must match OBJECT_VARIABLE_MAP[].name)
  "Light Detected",
  "Motion",
  "Door",
  "Window",
  "Opening",
  "Occupancy",
  "Presence",
  "Vibration Detected",
  "Smoke Detected",
  "Gas Detected",
  "Moisture Detected",
  "Tamper",
  "Moving",
  "Lock Unlocked",
  "Garage Door",
  "Cold",
  "Heat",
  "Running",
  "Safety",
  "Problem",
  "Sound Detected",
  "Plug",
  "Power On",
  "Generic Boolean",
  "Battery Low",
  "Battery Charging",
  "Connectivity",
  "Carbon Monoxide Detected",

  -- Power/energy
  "Voltage",
  "Current",
  "Power",
  "Energy",

  -- Air quality
  "CO2",
  "TVOC",
  "PM2.5",
  "PM10",

  -- Distance/volume
  "Distance",
  "Volume",
  "Volume Storage",
  "Volume Flow Rate",
  "Water",
  "Gas",

  -- Motion/orientation
  "Acceleration",
  "Gyroscope",
  "Speed",
  "Rotational Speed",
  "Direction",
  "Rotation",

  -- Misc
  "Count",
  "Duration",
  "UV Index",
  "Mass",
  "Conductivity",
  "Timestamp",
  "Precipitation",
  "Text",
  "RSSI",
}

--------------------------------------------------------------------------------
-- Global State
--------------------------------------------------------------------------------

--- Track known objects to detect device capability changes
local knownObjects = {}

--- Cached bind key bytes (16 bytes) for encrypted BTHome devices
--- @type string|nil
local cachedBindKey = nil

--- Cached MAC address bytes (6 bytes) for encrypted BTHome devices
--- @type string|nil
local cachedMacBytes = nil

--------------------------------------------------------------------------------
-- Property Management
--------------------------------------------------------------------------------

--- Hide all optional properties
local function hideOptionalProperties()
  log:trace("hideOptionalProperties()")
  for _, propName in ipairs(OPTIONAL_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.HIDE_PROPERTY)
  end
end

--------------------------------------------------------------------------------
-- Value Helpers
--------------------------------------------------------------------------------

--- Update the "Last Seen" timestamp
local function updateLastSeen()
  values:update("Last Seen", tostring(os.date("%Y-%m-%d %H:%M:%S")))
end

--- Update RSSI value
local function updateRSSI(rssi)
  local rssiNum = tonumber(rssi) or -999
  if rssiNum > -999 then
    values:update("RSSI", rssiNum, nil, nil, " dBm")
  end
end

--- Get display name for an entity.
--- @param reading BTHomeReading The BTHome reading with name and index fields
--- @return string displayName Human-readable name
local function getEntityDisplayName(reading)
  local objectDef = BTHome.const.get_object(reading.id)
  assert(objectDef, "Unknown BTHome object ID: " .. tostring(reading.id))

  local displayName = objectDef.display_name
  if type(reading.instance) == "number" and reading.instance > 1 then
    displayName = displayName .. " (" .. reading.instance .. ")"
  end
  return displayName
end

--------------------------------------------------------------------------------
-- Dynamic Event Creation
--------------------------------------------------------------------------------

--- Get or create a dynamic event for a button/dimmer event.
--- @param reading BTHomeReading The BTHome reading with name and index fields
--- @return Event|nil event The event object or nil if creation failed
local function getOrCreateEntityEvent(reading)
  if reading.name ~= "button" and reading.name ~= "dimmer" then
    log:warn("Cannot create event for non-button/dimmer entity: %s", reading.name)
    return nil
  end
  --- @type string|nil
  local eventName = Select(reading.event, "event_name")
  if not eventName then
    log:warn("No event name in reading event for entity: %s", reading.name)
    return nil
  end
  if eventName == "none" then
    return nil
  end
  --- @type EventDef|nil
  local eventDef
  if reading.name == "button" then
    eventDef = BUTTON_EVENT_DEFS[eventName]
  else
    eventDef = DIMMER_EVENT_DEFS[eventName]
  end
  if not eventDef then
    log:warn("No event definition for %s event: %s", reading.name, eventName)
    return nil
  end

  local displayName = getEntityDisplayName(reading)

  -- Create unique event key that includes entity index
  local eventKey = reading.name .. "_" .. reading.instance .. eventDef.key
  local eventDisplayName = displayName .. " " .. eventDef.name
  local eventDescription = displayName .. " " .. eventDef.description
  return events:getOrAddEvent(EVENT_NAMESPACE, eventKey, eventDisplayName, eventDescription)
end

--- Fire a dynamic event for an entity.
--- @param reading BTHomeReading The BTHome reading with name and index fields
local function fireEntityEvent(reading)
  local event = getOrCreateEntityEvent(reading)
  if not event then
    return
  end
  if type(event.eventId) ~= "number" then
    log:warn("Cannot fire event - no ID for event: %s", event.name)
    return
  end
  C4:FireEventByID(event.eventId)
end

--------------------------------------------------------------------------------
-- Dynamic Binding Creation (Sensor)
--------------------------------------------------------------------------------

--- Get or create a sensor binding.
--- @param reading BTHomeReading The BTHome reading with name and index fields
--- @param sensorConfig SensorBindingConfig Sensor configuration with bindingClass, scale
--- @return Binding|nil binding The binding or nil if creation failed
local function getOrCreateSensorBinding(reading, sensorConfig)
  local bindingKey = reading.name .. "_" .. reading.instance
  local displayName = getEntityDisplayName(reading)
  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    bindingKey,
    "CONTROL",
    true, -- provider
    displayName,
    sensorConfig.bindingClass
  )

  if binding then
    log:info("Created %s binding for '%s' (id=%s)", sensorConfig.bindingClass, displayName, binding.bindingId)

    -- Register RFP handler for value requests
    RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
      log:trace("RFP[%s](%s, %s, %s, %s)", binding.bindingId, idBinding, strCommand, _tParams, _args)
      if strCommand == "GET_VALUE" then
        -- Send cached value
        local cachedValue = values:getValue(displayName)
        if cachedValue and cachedValue.value then
          local params = {
            VALUE = cachedValue.value,
            SCALE = sensorConfig.scale,
          }
          SendToProxy(idBinding, "VALUE_CHANGED", params)
        end
      end
    end

    -- Register OBC handler for binding changes
    OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
      log:trace(
        "OBC[%s](%s, %s, %s, %s, %s)",
        binding.bindingId,
        idBinding,
        _strClass,
        bIsBound,
        _otherDeviceId,
        _otherBindingId
      )
      if bIsBound then
        -- Send current value when bound
        local cachedValue = values:getValue(displayName)
        if cachedValue and cachedValue.value then
          local params = {
            VALUE = cachedValue.value,
            SCALE = sensorConfig.scale,
          }
          SendToProxy(idBinding, "VALUE_CHANGED", params)
        end
      end
    end
  end

  return binding
end

--- Send sensor value to bound consumers.
--- @param reading BTHomeReading The BTHome reading with value field
--- @param sensorConfig SensorBindingConfig Sensor configuration with bindingClass, scale
local function sendSensorValue(reading, sensorConfig)
  local binding = getOrCreateSensorBinding(reading, sensorConfig)
  if not binding then
    return
  end

  log:debug("Sending %s value %s to binding %s", reading.name, reading.value, binding.bindingId)
  SendToProxy(binding.bindingId, "VALUE_CHANGED", {
    VALUE = reading.value,
    SCALE = sensorConfig.scale,
  })
end

--- Get or create a contact sensor binding.
--- @param reading BTHomeReading The BTHome reading with name and index fields
--- @return Binding|nil binding The binding or nil if creation failed
local function getOrCreateContactBinding(reading)
  local bindingKey = "contact_" .. reading.name .. "_" .. reading.instance
  local displayName = getEntityDisplayName(reading)
  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    bindingKey,
    "PROXY",
    true, -- provider
    displayName,
    "CONTACT_SENSOR"
  )

  if binding then
    log:info("Created CONTACT_SENSOR binding for '%s' (id=%s)", displayName, binding.bindingId)
  end

  return binding
end

--- Send contact sensor state to bound consumers.
--- @param reading BTHomeReading The BTHome reading with value field
--- @param contactConfig ContactBindingConfig Contact binding configuration
local function sendContactState(reading, contactConfig)
  local binding = getOrCreateContactBinding(reading)
  if not binding then
    return
  end

  local event = toboolean(reading.value) and contactConfig.openEvent or contactConfig.closedEvent
  log:debug("Sending %s to contact binding %s", event, binding.bindingId)
  SendToProxy(binding.bindingId, event, {}, "NOTIFY")
end

--- Get or create a button link binding for a specific event type.
--- Each event type (single, double, long, etc.) gets its own BUTTON_LINK binding.
--- @param reading BTHomeReading The BTHome reading with name and index fields
--- @return Binding|nil binding The binding or nil if creation failed
local function getOrCreateButtonBinding(reading)
  if reading.name ~= "button" then
    log:warn("Cannot create button link binding for non-button entity: %s", reading.name)
    return nil
  end
  --- @type string|nil
  local eventName = Select(reading.event, "event_name")
  if not eventName then
    log:warn("No event name in reading event for entity: %s", reading.name)
    return nil
  end
  if eventName == "none" then
    return nil
  end
  --- @type EventDef|nil
  local eventDef = BUTTON_EVENT_DEFS[eventName]
  if not eventDef then
    log:warn("No event definition for button event: %s", eventName)
    return nil
  end

  local bindingKey = "button_" .. reading.name .. "_" .. reading.instance .. ":" .. eventName
  local displayName = getEntityDisplayName(reading) .. " " .. eventDef.name
  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    bindingKey,
    "CONTROL",
    false, -- consumer (initiates connection to provider, sends events)
    displayName,
    "BUTTON_LINK"
  )

  if binding then
    log:info("Created BUTTON_LINK binding for '%s' (id=%s)", displayName, binding.bindingId)
  end

  return binding
end

--- Send button event to bound consumers.
--- Sends DO_PUSH followed by DO_CLICK to the event-specific binding.
--- @param reading BTHomeReading The BTHome reading with name and index fields
local function sendButtonEvent(reading)
  -- Get or create the binding for this specific event type
  local binding = getOrCreateButtonBinding(reading)
  if not binding then
    return
  end

  log:debug("Sending DO_CLICK and DO_PUSH/DO_RELEASE from binding %s", binding.bindingId)
  SendToProxy(binding.bindingId, "DO_CLICK", {}, "NOTIFY")
  SendToProxy(binding.bindingId, "DO_PUSH", {}, "NOTIFY")
  SendToProxy(binding.bindingId, "DO_RELEASE", {}, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Data Processing
--------------------------------------------------------------------------------

--- Process a BTHome object and update the corresponding variable/property
--- @param reading BTHomeReading The BTHome object with value, unit, event fields
--- @param summaryParts string[] Table to append summary parts to
local function processBTHomeReading(reading, summaryParts)
  local displayName = getEntityDisplayName(reading)

  -- Handle button events - create and fire dynamic events for each button
  if reading.name == "button" and reading.event then
    fireEntityEvent(reading)
    sendButtonEvent(reading)
    local eventName = reading.event.event_name or ""
    local eventDef = BUTTON_EVENT_DEFS[eventName]
    if eventDef then
      table.insert(summaryParts, displayName .. " " .. eventDef.name)
    end
    return
  end

  -- Handle dimmer events - create and fire dynamic events for each dimmer
  if reading.name == "dimmer" and reading.event then
    fireEntityEvent(reading)
    local eventName = reading.event.event_name or ""
    local steps = reading.event.steps or 0
    local eventDef = DIMMER_EVENT_DEFS[eventName]
    if eventDef then
      table.insert(summaryParts, displayName .. " " .. eventDef.name .. " (" .. steps .. " steps)")
    end
    return
  end

  -- Look up variable definition by base name
  local varDef = OBJECT_VARIABLE_MAP[reading.name]
  if not varDef then
    log:warn("Unknown BTHome object: %s (ignoring)", reading.name)
    return
  end

  -- Skip hidden objects
  if varDef.hidden then
    return
  end

  -- Track new objects
  if not knownObjects[reading.name] then
    knownObjects[reading.name] = true
    log:info("Discovered BTHome object: %s", displayName)

    -- Create sensor binding if applicable
    local sensorConfig = SENSOR_BINDINGS[reading.name]
    if sensorConfig then
      getOrCreateSensorBinding(reading, sensorConfig)
    end

    -- Create contact sensor binding if applicable
    local contactConfig = CONTACT_BINDINGS[reading.name]
    if contactConfig then
      getOrCreateContactBinding(reading)
    end
  end

  -- Format the value
  local value = reading.value
  local displayValue = value
  if type(value) == "number" then
    -- Round to 2 decimal places for display
    displayValue = round(value, 2)
  end

  -- Build variable name with index if needed
  local varName = varDef.name
  if type(reading.instance) == "number" and reading.instance > 1 then
    varName = varDef.name .. " (" .. reading.instance .. ")"
  end

  -- Update the variable (and property if applicable via suffix)
  local changed = values:update(varName, displayValue, varDef.type, nil, reading.unit and (" " .. reading.unit) or nil)

  -- Add to summary
  local unit = reading.unit and (" " .. reading.unit) or ""
  table.insert(summaryParts, displayName .. ": " .. tostring(displayValue) .. unit)

  -- FIXME: Hack
  if varName == "Temperature C" and type(value) == "number" then
    values:update("Temperature F", c2f(value), varDef.type, nil, " °F")
  end

  -- Only send to bindings if value changed
  if not changed then
    return
  end

  -- Send to sensor binding if applicable
  local sensorConfig = SENSOR_BINDINGS[reading.name]
  if sensorConfig and type(value) == "number" then
    sendSensorValue(reading, sensorConfig)
  end

  -- Send to contact binding if applicable
  local contactConfig = CONTACT_BINDINGS[reading.name]
  if contactConfig then
    sendContactState(reading, contactConfig)
  end
end

--- Process incoming BTHome data from the parent driver
--- @param readings BTHomeReading[] Array of BTHome readings from bthome
--- @param rssi string|nil RSSI value as string
local function processBTHomeReadings(readings, rssi)
  log:trace("processBTHomeReadings()")

  -- Update timestamps
  updateLastSeen()

  -- Update RSSI
  if rssi then
    updateRSSI(rssi)
  end

  -- Process each reading (summary built inline)
  local summaryParts = {}
  for _, reading in ipairs(readings) do
    processBTHomeReading(reading, summaryParts)
  end

  -- Update "Last Received" property
  UpdateProperty("Last Received", #summaryParts > 0 and table.concat(summaryParts, ", ") or "No data")
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore all persisted values, events, and bindings
  values:restoreValues()
  events:restoreEvents()
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Hide all optional properties initially
  hideOptionalProperties()

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Waiting for data")

  -- Request refresh from parent driver
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

--------------------------------------------------------------------------------
-- OPC Handlers
--------------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

function OPC.Bind_Key(propertyValue)
  log:trace("OPC.Bind_Key('%s')", propertyValue and string.rep("*", #propertyValue) or "nil")
  if not propertyValue or propertyValue == "" then
    cachedBindKey = nil
    return
  end

  -- Ignore error messages (they get cleared by delay)
  if propertyValue:match("^Error:") then
    return
  end

  -- Validate hex string (32 chars = 16 bytes)
  if #propertyValue ~= 32 or not propertyValue:match("^[0-9A-Fa-f]+$") then
    log:warn("Bind key must be 32 hex characters (16 bytes)")
    cachedBindKey = nil
    -- Show error in property field, then clear after delay
    UpdateProperty("Bind Key", "Error: Must be 32 hex chars")
    delay(2 * ONE_SECOND):next(function()
      UpdateProperty("Bind Key", "")
    end)
    return
  end

  -- Convert hex to bytes
  local bytes = {}
  for i = 1, 32, 2 do
    bytes[#bytes + 1] = string.char(tonumber(propertyValue:sub(i, i + 1), 16) or 0)
  end
  cachedBindKey = table.concat(bytes)
  log:info("Bind key configured (%d bytes)", #cachedBindKey)

  UpdateProperty("Driver Status", "Waiting for data")
end

--------------------------------------------------------------------------------
-- RFP Handlers
--------------------------------------------------------------------------------

--- Handle passive connect notification from parent driver
--- BTHome devices use advertisement-based data, no GATT connection
function RFP.CONNECTED_PASSIVE(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED_PASSIVE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local name = Select(tParams, "name")
  local mac = Select(tParams, "mac") or "Unknown"
  local deviceType = Select(tParams, "deviceType") or "Unknown"

  log:debug("BTHome device in passive mode: %s (%s)", mac, deviceType)

  -- Update device info properties
  if not IsEmpty(name) then
    values:update("Name", name, "STRING")
  end
  values:update("Device Type", deviceType, "STRING")
  values:update("MAC Address", mac, "STRING")

  -- Cache MAC bytes for encrypted BTHome decryption
  if mac and mac ~= "Unknown" then
    local bytes = {}
    for octet in mac:gmatch("[0-9A-Fa-f]+") do
      bytes[#bytes + 1] = string.char(tonumber(octet, 16) or 0)
    end
    if #bytes == 6 then
      cachedMacBytes = table.concat(bytes)
    end
  end

  UpdateProperty("Driver Status", "Listening")
end

--- Handle incoming BLE advertisement from parent driver
function RFP.BLE_ADVERTISEMENT(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_ADVERTISEMENT(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)

  -- Call the passive connection to make sure mac and device type are set
  RFP.CONNECTED_PASSIVE(idBinding, strCommand, tParams, args)

  if idBinding ~= ESPHOME_BINDING then
    return
  end

  -- Deserialize the BLEAdvertisement
  local advStr = Select(tParams, "advertisement")
  if not advStr or advStr == "" then
    return
  end

  local advertisement = DeserializeSafe(advStr)
  if not advertisement then
    return
  end
  --- @cast advertisement BLEAdvertisement

  -- Extract BTHome service data
  local serviceData, uuid =
    UUID.findData(advertisement.serviceData, BTHome.UUID_V2, BTHome.UUID_V1_UNENCRYPTED, BTHome.UUID_V1_ENCRYPTED)
  if not serviceData or not uuid then
    return
  end

  -- Parse BTHome data (pass cached bind key and MAC for encrypted devices)
  local result, err = BTHome.parse(uuid, serviceData, cachedBindKey, cachedMacBytes)
  if not result then
    UpdateProperty("Driver Status", "Error: " .. (err or "unknown"))
    return
  end

  -- Device type
  --local deviceType = Select(tParams, "deviceType")
  local version = tointeger(Select(result.device_info, "version"))
  if version ~= nil then
    local deviceType = "BTHome V" .. version
    if toboolean(Select(result.device_info, "encrypted")) then
      deviceType = deviceType .. " (Encrypted)"
    end
    values:update("Device Type", deviceType, "STRING")
  end

  -- Update status
  UpdateProperty("Driver Status", "Listening")

  -- Process the data
  processBTHomeReadings(result.readings, advertisement.rssi)
end

--- Handle disconnection notification from main driver
function RFP.DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.DISCONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local reason = Select(tParams, "reason") or "unknown"
  log:info("BTHome device disconnected: %s", reason)
  UpdateProperty("Driver Status", "Waiting for data")
end

--------------------------------------------------------------------------------
-- OBC Handlers
--------------------------------------------------------------------------------

--- Handle binding changes
OBC[ESPHOME_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId)
  log:trace("OBC[%s](%s, %s, %s, %s)", ESPHOME_BINDING, idBinding, strClass, bIsBound, otherDeviceId)
  -- Reset state when binding changes
  knownObjects = {}

  if bIsBound then
    UpdateProperty("Driver Status", "Waiting for data")
  else
    UpdateProperty("Driver Status", "Disconnected")
  end
end

--------------------------------------------------------------------------------
-- EC Handlers
--------------------------------------------------------------------------------

--- Reset driver to initial state
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  -- Reset all dynamic bindings using library method
  bindings:reset()

  -- Reset all values/variables using library method
  values:reset()

  -- Reset all dynamic events using library method
  events:reset()

  -- Reset local state
  knownObjects = {}
  cachedMacBytes = nil

  -- Reset properties to defaults (excludes user-entered credentials)
  local resetValues = GetPropertyResetValues({ "Bind Key" })
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end

  -- Hide optional properties
  hideOptionalProperties()

  -- Request refresh from parent driver
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end
