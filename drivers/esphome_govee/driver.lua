--- ESPHome Govee Driver
--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_govee.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local events = require("lib.events")
local persist = require("lib.persist")
local constants = require("constants")
local Govee = require("esphome.ble.parsers.govee")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Binding IDs
local ESPHOME_BINDING = 5001

--- Namespaces for dynamic bindings
local BINDINGS_NAMESPACE = "Govee"

--- Event namespace for Govee events
local EVENT_NAMESPACE = "Govee"

--- Sensor type constants (for temperature/humidity bindings)
--- @enum GoveeSensorType
local SENSOR_TYPE = {
  TEMPERATURE = "temperature",
  HUMIDITY = "humidity",
}

--- Event definitions for probe alarms and errors
--- @type table<string, {key: string, name: string, description: string}?>
local EVENT_DEFS = {
  probe1_alarm_active = {
    key = "probe1_alarm_active",
    name = "Probe 1 Alarm Active",
    description = "Probe 1 reached alarm temperature",
  },
  probe1_alarm_cleared = {
    key = "probe1_alarm_cleared",
    name = "Probe 1 Alarm Cleared",
    description = "Probe 1 below alarm temperature",
  },
  probe2_alarm_active = {
    key = "probe2_alarm_active",
    name = "Probe 2 Alarm Active",
    description = "Probe 2 reached alarm temperature",
  },
  probe2_alarm_cleared = {
    key = "probe2_alarm_cleared",
    name = "Probe 2 Alarm Cleared",
    description = "Probe 2 below alarm temperature",
  },
  error_detected = { key = "error_detected", name = "Error Detected", description = "Sensor reported an error" },
  error_cleared = { key = "error_cleared", name = "Error Cleared", description = "Sensor error cleared" },
}

--- Map device types to their supported event keys
--- @type table<string, string[]?>
local DEVICE_EVENTS = {
  -- Meat thermometers with probe alarms
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5181]] = {
    "probe1_alarm_active",
    "probe1_alarm_cleared",
    "error_detected",
    "error_cleared",
  },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5182]] = {
    "probe1_alarm_active",
    "probe1_alarm_cleared",
    "probe2_alarm_active",
    "probe2_alarm_cleared",
    "error_detected",
    "error_cleared",
  },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5184]] = {
    "probe1_alarm_active",
    "probe1_alarm_cleared",
    "probe2_alarm_active",
    "probe2_alarm_cleared",
    "error_detected",
    "error_cleared",
  },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5185]] = {
    "probe1_alarm_active",
    "probe1_alarm_cleared",
    "error_detected",
    "error_cleared",
  },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5191]] = {
    "probe1_alarm_active",
    "probe1_alarm_cleared",
    "error_detected",
    "error_cleared",
  },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5198]] = {
    "probe1_alarm_active",
    "probe1_alarm_cleared",
    "probe2_alarm_active",
    "probe2_alarm_cleared",
    "error_detected",
    "error_cleared",
  },
  -- Dual sensors with error flag
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5178]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5112]] = { "error_detected", "error_cleared" },
  -- Standard sensors with error flag (3-byte format includes error bit)
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5074]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5075]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5100]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5101]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5102]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5104]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5108]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5177]] = { "error_detected", "error_cleared" },
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5179]] = { "error_detected", "error_cleared" },
}

--- Sensor binding configurations
--- @type table<GoveeSensorType, {bindingClass: string, scale: string, displayName: string}?>
local SENSOR_BINDINGS = {
  [SENSOR_TYPE.TEMPERATURE] = { bindingClass = "TEMPERATURE_VALUE", scale = "CELSIUS", displayName = "Temperature" },
  [SENSOR_TYPE.HUMIDITY] = { bindingClass = "HUMIDITY_VALUE", scale = "PERCENT", displayName = "Humidity" },
}

--- Optional properties that should be hidden unless we have data
--- @type string[]
local OPTIONAL_PROPERTIES = {
  "Name",
  "Battery",
  "Humidity",
  "PM2.5",
  "RSSI",
  "Temperature C",
  "Temperature F",
  -- Dual sensor properties
  "Sensor ID",
  "Error",
  -- Meat thermometer properties
  "Probe 1 C",
  "Probe 1 F",
  "Probe 1 Alarm",
  "Probe 2 C",
  "Probe 2 F",
  "Probe 2 Alarm",
  "Probe 3 C",
  "Probe 3 F",
  "Probe 4 C",
  "Probe 4 F",
  "Ambient C",
  "Ambient F",
}

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
--- @param rssi string|number|nil RSSI value
local function updateRSSI(rssi)
  local rssiNum = tonumber(rssi) or -999
  if rssiNum > -999 then
    values:update("RSSI", rssiNum, nil, nil, " dBm")
    C4:SetPropertyAttribs("RSSI", constants.SHOW_PROPERTY)
  end
end

--- Check if probe temperature has crossed alarm threshold
--- @param probeTemp number|nil Current probe temperature
--- @param alarmTemp number|nil Alarm threshold temperature
--- @return boolean|nil isActive True if at/above alarm, false if below, nil if can't determine
local function isProbeAlarmActive(probeTemp, alarmTemp)
  if not probeTemp or not alarmTemp then
    return nil
  end
  return probeTemp >= alarmTemp
end

--------------------------------------------------------------------------------
-- Device Initialization
--------------------------------------------------------------------------------

--- Create events for a device based on its type
--- @param deviceType string The device type string (e.g., "Govee H5181")
local function createEventsForDevice(deviceType)
  if not deviceType then
    log:debug("No device type provided for event creation")
    return
  end

  local eventKeys = DEVICE_EVENTS[deviceType]
  if IsEmpty(eventKeys) then
    log:debug("No events defined for device type: %s", deviceType)
    return
  end
  --- @cast eventKeys -nil

  log:info("Creating events for %s: %s", deviceType, table.concat(eventKeys, ", "))
  for _, eventKey in ipairs(eventKeys) do
    local eventDef = EVENT_DEFS[eventKey]
    if eventDef then
      events:getOrAddEvent(EVENT_NAMESPACE, eventDef.key, eventDef.name, eventDef.description)
    end
  end
end

--------------------------------------------------------------------------------
-- Dynamic Binding Creation (Sensor)
--------------------------------------------------------------------------------

--- Get or create a sensor binding (temperature/humidity)
--- @param sensorType GoveeSensorType
--- @return Binding|nil binding
local function getOrCreateSensorBinding(sensorType)
  log:trace("getOrCreateSensorBinding(%s)", sensorType)
  local config = SENSOR_BINDINGS[sensorType]
  if not config then
    return nil
  end

  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    sensorType,
    "CONTROL",
    true,
    config.displayName,
    config.bindingClass
  )

  if binding then
    log:info("Created %s binding for %s (id=%s)", config.bindingClass, config.displayName, binding.bindingId)

    -- Register RFP handler for value requests
    RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
      log:trace("RFP[%s](%s, %s, %s, %s)", binding.bindingId, idBinding, strCommand, _tParams, _args)
      if strCommand == "GET_VALUE" then
        local cachedValue = values:getValue(config.displayName)
        if cachedValue and cachedValue.value then
          SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = cachedValue.value, SCALE = config.scale })
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
        local cachedValue = values:getValue(config.displayName)
        if cachedValue and cachedValue.value then
          SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = cachedValue.value, SCALE = config.scale })
        end
      end
    end
  end

  return binding
end

--- Send sensor value to bound consumers
--- @param sensorType GoveeSensorType
--- @param value number
local function sendSensorValue(sensorType, value)
  log:trace("sendSensorValue(%s, %s)", sensorType, value)
  local config = SENSOR_BINDINGS[sensorType]
  if not config then
    return
  end

  local binding = getOrCreateSensorBinding(sensorType)
  if not binding then
    return
  end

  SendToProxy(binding.bindingId, "VALUE_CHANGED", { VALUE = value, SCALE = config.scale })
end

--------------------------------------------------------------------------------
-- Event Firing (Sensor)
--------------------------------------------------------------------------------

--- Fire an event if state changed
--- @param stateKey string State key for tracking
--- @param currentState boolean
--- @param trueEvent string Event key when state becomes true
--- @param falseEvent string Event key when state becomes false
local function fireStateChangeEvent(stateKey, currentState, trueEvent, falseEvent)
  log:trace("fireStateChangeEvent(%s, %s, %s, %s)", stateKey, currentState, trueEvent, falseEvent)
  local prevState = persist:get("previousState", {})
  local prev = prevState[stateKey]
  if prev == nil then
    -- Don't fire event on initial state load
    prevState[stateKey] = currentState
    persist:set("previousState", prevState)
    return
  end

  if currentState == prev then
    return
  end

  if currentState and not prev then
    events:fire(EVENT_NAMESPACE, trueEvent)
  elseif not currentState and prev then
    events:fire(EVENT_NAMESPACE, falseEvent)
  end

  prevState[stateKey] = currentState
  persist:set("previousState", prevState)
end

--------------------------------------------------------------------------------
-- Data Processing
--------------------------------------------------------------------------------

--- Process incoming Govee data from the parent driver
--- @param data GoveeParsedData Parsed Govee data
--- @param rssi number|nil RSSI value
local function processGoveeData(data, rssi)
  log:trace("processGoveeData()")

  updateLastSeen()
  if rssi then
    updateRSSI(rssi)
  end

  -- Summary parts for "Last Received" property
  local summaryParts = {}

  -- Device type
  if not IsEmpty(data.deviceType) then
    values:update("Device Type", data.deviceType, "STRING")
  end

  -- Battery
  if type(data.battery) == "number" then
    values:update("Battery", data.battery, "NUMBER", nil, " %")
    table.insert(summaryParts, "Battery: " .. data.battery .. "%")
  end

  -- Error flag
  if data.hasError ~= nil then
    values:update("Error", data.hasError and "Yes" or "No", "STRING")
    C4:SetPropertyAttribs("Error", constants.SHOW_PROPERTY)
    fireStateChangeEvent("hasError", data.hasError, "error_detected", "error_cleared")
    if data.hasError then
      table.insert(summaryParts, "Error: Yes")
    end
  end

  -- Sensor ID (H5178 dual sensor, H5112 dual probe)
  if data.sensorId ~= nil then
    values:update("Sensor ID", tostring(data.sensorId), "STRING")
    C4:SetPropertyAttribs("Sensor ID", constants.SHOW_PROPERTY)
  end

  -- Temperature (standard temp/humidity sensors)
  if type(data.temperature) == "number" then
    values:update("Temperature C", data.temperature, "NUMBER", nil, " °C")
    values:update("Temperature F", c2f(data.temperature), "NUMBER", nil, " °F")
    table.insert(summaryParts, "Temp: " .. round(data.temperature, 1) .. "°C")

    sendSensorValue(SENSOR_TYPE.TEMPERATURE, data.temperature)
  end

  -- Humidity
  if type(data.humidity) == "number" then
    values:update("Humidity", data.humidity, "NUMBER", nil, " %")
    table.insert(summaryParts, "Humidity: " .. round(data.humidity, 0) .. "%")

    sendSensorValue(SENSOR_TYPE.HUMIDITY, data.humidity)
  end

  -- PM2.5 (H5106 air quality sensor)
  if type(data.pm25) == "number" then
    values:update("PM2.5", data.pm25, "NUMBER", nil, " µg/m³")
    table.insert(summaryParts, "PM2.5: " .. data.pm25 .. " µg/m³")
  end

  -- Probe 1 temperature (meat thermometers)
  if type(data.probe1Temp) == "number" then
    values:update("Probe 1 C", data.probe1Temp, "NUMBER", nil, " °C")
    values:update("Probe 1 F", c2f(data.probe1Temp), "NUMBER", nil, " °F")
    C4:SetPropertyAttribs("Probe 1 C", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Probe 1 F", constants.SHOW_PROPERTY)
    table.insert(summaryParts, "P1: " .. round(data.probe1Temp, 1) .. "°C")
  end

  -- Probe 1 alarm
  if type(data.probe1Alarm) == "number" then
    values:update("Probe 1 Alarm", data.probe1Alarm, "NUMBER", nil, " °C")
    C4:SetPropertyAttribs("Probe 1 Alarm", constants.SHOW_PROPERTY)

    -- Check if alarm is active
    local alarmActive = isProbeAlarmActive(data.probe1Temp, data.probe1Alarm)
    if alarmActive ~= nil then
      fireStateChangeEvent("probe1Alarm", alarmActive, "probe1_alarm_active", "probe1_alarm_cleared")
      if alarmActive then
        table.insert(summaryParts, "P1 Alarm!")
      end
    end
  end

  -- Probe 2 temperature
  if type(data.probe2Temp) == "number" then
    values:update("Probe 2 C", data.probe2Temp, "NUMBER", nil, " °C")
    values:update("Probe 2 F", c2f(data.probe2Temp), "NUMBER", nil, " °F")
    C4:SetPropertyAttribs("Probe 2 C", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Probe 2 F", constants.SHOW_PROPERTY)
    table.insert(summaryParts, "P2: " .. round(data.probe2Temp, 1) .. "°C")
  end

  -- Probe 2 alarm
  if type(data.probe2Alarm) == "number" then
    values:update("Probe 2 Alarm", data.probe2Alarm, "NUMBER", nil, " °C")
    C4:SetPropertyAttribs("Probe 2 Alarm", constants.SHOW_PROPERTY)

    -- Check if alarm is active
    local alarmActive = isProbeAlarmActive(data.probe2Temp, data.probe2Alarm)
    if alarmActive ~= nil then
      fireStateChangeEvent("probe2Alarm", alarmActive, "probe2_alarm_active", "probe2_alarm_cleared")
      if alarmActive then
        table.insert(summaryParts, "P2 Alarm!")
      end
    end
  end

  -- Probe 3 temperature (H5184 4-probe thermometer)
  if type(data.probe3Temp) == "number" then
    values:update("Probe 3 C", data.probe3Temp, "NUMBER", nil, " °C")
    values:update("Probe 3 F", c2f(data.probe3Temp), "NUMBER", nil, " °F")
    C4:SetPropertyAttribs("Probe 3 C", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Probe 3 F", constants.SHOW_PROPERTY)
    table.insert(summaryParts, "P3: " .. round(data.probe3Temp, 1) .. "°C")
  end

  -- Probe 4 temperature (H5184 4-probe thermometer)
  if type(data.probe4Temp) == "number" then
    values:update("Probe 4 C", data.probe4Temp, "NUMBER", nil, " °C")
    values:update("Probe 4 F", c2f(data.probe4Temp), "NUMBER", nil, " °F")
    C4:SetPropertyAttribs("Probe 4 C", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Probe 4 F", constants.SHOW_PROPERTY)
    table.insert(summaryParts, "P4: " .. round(data.probe4Temp, 1) .. "°C")
  end

  -- Ambient temperature (H5191)
  if type(data.ambientTemp) == "number" then
    values:update("Ambient C", data.ambientTemp, "NUMBER", nil, " °C")
    values:update("Ambient F", c2f(data.ambientTemp), "NUMBER", nil, " °F")
    C4:SetPropertyAttribs("Ambient C", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Ambient F", constants.SHOW_PROPERTY)
    table.insert(summaryParts, "Ambient: " .. round(data.ambientTemp, 1) .. "°C")
  end

  UpdateProperty("Last Received", #summaryParts > 0 and table.concat(summaryParts, ", ") or "No data")
  UpdateProperty("Driver Status", "Listening")
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

  -- Restore persisted state
  values:restoreValues()
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Restore persisted events (C4:AddEvent is unavailable before OnDriverLateInit)
  events:restoreEvents()

  -- Hide all optional properties initially
  hideOptionalProperties()

  -- Restore device type and recreate events
  local storedDeviceType = Select(values:getValue("Device Type"), "value")
  if storedDeviceType then
    createEventsForDevice(storedDeviceType)
  end

  -- Fire OnPropertyChanged for all properties
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

--------------------------------------------------------------------------------
-- RFP Handlers
--------------------------------------------------------------------------------

--- Handle passive connect notification from parent driver
function RFP.CONNECTED_PASSIVE(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED_PASSIVE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local name = Select(tParams, "name")
  local mac = Select(tParams, "mac") or "Unknown"
  local deviceType = Select(tParams, "deviceType") or "Unknown"

  log:info("Govee device in passive mode: %s (%s)", mac, deviceType)

  if not IsEmpty(name) then
    values:update("Name", name, "STRING")
  end
  values:update("Device Type", deviceType, "STRING")
  values:update("MAC Address", mac, "STRING")

  -- Create events based on device model (only creates if not already present)
  createEventsForDevice(deviceType)

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

  -- Use cached device type from CONNECTED_PASSIVE (contains model like "Govee H5074")
  local deviceType = Select(values:getValue("Device Type"), "value")

  -- Parse Govee data from manufacturer data
  local data = Govee.parse(advertisement.manufacturerData, advertisement.serviceData, deviceType)
  if not data then
    return
  end

  processGoveeData(data, advertisement.rssi)
end

--- Handle disconnection notification
function RFP.DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.DISCONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  log:info("Govee device disconnected")
  UpdateProperty("Driver Status", "Waiting for data")
end

--------------------------------------------------------------------------------
-- OBC Handlers
--------------------------------------------------------------------------------

OBC[ESPHOME_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId)
  log:trace("OBC[%s](%s, %s, %s, %s)", ESPHOME_BINDING, idBinding, strClass, bIsBound, otherDeviceId)
  persist:set("previousState", {})

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

  -- Reset all dynamic state
  bindings:reset()
  values:reset()
  events:reset()

  -- Reset sensor state tracking
  persist:set("previousState", {})

  -- Hide optional properties
  hideOptionalProperties()

  -- Reset properties to defaults
  local resetValues = GetPropertyResetValues({})
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end

  -- Request refresh from parent
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end
