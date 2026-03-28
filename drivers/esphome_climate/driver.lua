--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_climate.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local log = require("lib.logging")

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002
local TEMPERATURE_OUTPUT_BINDING = 5010
local OUTDOOR_TEMPERATURE_OUTPUT_BINDING = 5011
local HUMIDITY_OUTPUT_BINDING = 5012

local ENTITY
local STATE
local CAPABILITIES_SENT = false
local REMOTE_SENSOR_IN_USE = false

--- ESPHome ClimateMode → C4 HVAC mode string
local CLIMATE_MODE_TO_C4 = {
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_OFF] = "Off",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT] = "Heat",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL] = "Cool",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL] = "Auto",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_AUTO] = "Auto",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_FAN_ONLY] = "Fan Only",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_DRY] = "Dry",
}

--- C4 HVAC mode string → ESPHome ClimateMode
local C4_TO_CLIMATE_MODE = {
  ["Off"] = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_OFF,
  ["Heat"] = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT,
  ["Cool"] = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL,
  ["Auto"] = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL,
  ["Fan Only"] = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_FAN_ONLY,
  ["Dry"] = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_DRY,
}

--- ESPHome ClimateAction → C4 HVAC state string
local CLIMATE_ACTION_TO_C4 = {
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_OFF] = "Off",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_HEATING] = "Heating",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_COOLING] = "Cooling",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_IDLE] = "Idle",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_DRYING] = "Drying",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_FAN] = "Fan Only",
}

--- ESPHome ClimateFanMode → C4 fan mode string
local CLIMATE_FAN_MODE_TO_C4 = {
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_ON] = "On",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_OFF] = "Off",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_AUTO] = "Auto",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_LOW] = "Low",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_MEDIUM] = "Medium",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_HIGH] = "High",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_MIDDLE] = "Middle",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_FOCUS] = "Focus",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_DIFFUSE] = "Diffuse",
  [ESPHomeProtoSchema.Enum.ClimateFanMode.CLIMATE_FAN_QUIET] = "Quiet",
}

--- C4 fan mode string → ESPHome ClimateFanMode
local C4_TO_CLIMATE_FAN_MODE = {}
for k, v in pairs(CLIMATE_FAN_MODE_TO_C4) do
  C4_TO_CLIMATE_FAN_MODE[v] = k
end

--- ESPHome ClimatePreset → C4 hold mode string
local CLIMATE_PRESET_TO_C4 = {
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_NONE] = "Off",
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_HOME] = "Home",
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_AWAY] = "Away",
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_BOOST] = "Boost",
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_COMFORT] = "Comfort",
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_ECO] = "Eco",
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_SLEEP] = "Sleep",
  [ESPHomeProtoSchema.Enum.ClimatePreset.CLIMATE_PRESET_ACTIVITY] = "Activity",
}

--- C4 hold mode string → ESPHome ClimatePreset
local C4_TO_CLIMATE_PRESET = {}
for k, v in pairs(CLIMATE_PRESET_TO_C4) do
  C4_TO_CLIMATE_PRESET[v] = k
end

--- Get whether the temperature scale is Fahrenheit.
--- Uses the project-level TemperatureScale setting from the C4 controller.
--- @return boolean isFahrenheit True if Fahrenheit, false if Celsius.
local function isFahrenheit()
  local scale = C4:GetProjectProperty("TemperatureScale")
  if scale ~= nil then
    scale = string.upper(tostring(scale))
    return scale ~= "CELSIUS" and scale ~= "C"
  end
  return true -- Default to Fahrenheit if project property unavailable
end

--- Convert a Celsius temperature to the display scale.
--- @param celsius number Temperature in Celsius.
--- @return number temperature Temperature in the configured display scale.
local function toDisplayTemp(celsius)
  if celsius == nil then
    return nil
  end
  if isFahrenheit() then
    return c2f(celsius)
  end
  return math.floor(celsius * 10 + 0.5) / 10
end

--- Convert a temperature in the display scale to Celsius.
--- @param temp number Temperature in the configured display scale.
--- @return number celsius Temperature in Celsius.
local function fromDisplayTemp(temp)
  if temp == nil then
    return nil
  end
  if isFahrenheit() then
    return f2c(temp)
  end
  return temp
end

--- Get the temperature scale string for notifications.
--- @return string scale "F" or "C"
local function getScale()
  return isFahrenheit() and "F" or "C"
end

--- Send a climate command to the ESPHome device via the binding.
--- @param body table<string, any> The command body.
local function sendClimateCommand(body)
  log:trace("sendClimateCommand(%s)", body)
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe(body),
  })
end

--- Send allowed modes to the thermostat proxy based on entity capabilities.
--- @param entity table<string, any> The entity data.
local function sendCapabilities(entity)
  log:trace("sendCapabilities(%s)", entity)

  -- HVAC modes
  local supported_modes = entity.supported_modes
  if supported_modes ~= nil and #supported_modes > 0 then
    local modes = {}
    for _, mode in ipairs(supported_modes) do
      local c4Mode = CLIMATE_MODE_TO_C4[mode]
      if c4Mode ~= nil then
        table.insert(modes, c4Mode)
      end
    end
    if #modes > 0 then
      SendToProxy(PROXY_BINDING, "ALLOWED_HVAC_MODES_CHANGED", { MODES = table.concat(modes, ",") }, "NOTIFY")
    end
  end

  -- Fan modes
  local supported_fan_modes = entity.supported_fan_modes
  local fan_modes = {}
  if supported_fan_modes ~= nil then
    for _, mode in ipairs(supported_fan_modes) do
      local c4Mode = CLIMATE_FAN_MODE_TO_C4[mode]
      if c4Mode ~= nil then
        table.insert(fan_modes, c4Mode)
      end
    end
  end
  local custom_fan_modes = entity.supported_custom_fan_modes
  if custom_fan_modes ~= nil then
    for _, mode in ipairs(custom_fan_modes) do
      table.insert(fan_modes, mode)
    end
  end
  if #fan_modes > 0 then
    SendToProxy(PROXY_BINDING, "ALLOWED_FAN_MODES_CHANGED", { MODES = table.concat(fan_modes, ",") }, "NOTIFY")
  end

  -- Hold modes (presets)
  local supported_presets = entity.supported_presets
  local hold_modes = {}
  if supported_presets ~= nil then
    for _, preset in ipairs(supported_presets) do
      local c4Mode = CLIMATE_PRESET_TO_C4[preset]
      if c4Mode ~= nil then
        table.insert(hold_modes, c4Mode)
      end
    end
  end
  local custom_presets = entity.supported_custom_presets
  if custom_presets ~= nil then
    for _, preset in ipairs(custom_presets) do
      table.insert(hold_modes, preset)
    end
  end
  if #hold_modes > 0 then
    SendToProxy(PROXY_BINDING, "ALLOWED_HOLD_MODES_CHANGED", { MODES = table.concat(hold_modes, ",") }, "NOTIFY")
  end

  -- Humidity capabilities
  if entity.supports_current_humidity or entity.supports_target_humidity then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      HAS_HUMIDITY = tostring(entity.supports_current_humidity == true),
    }, "NOTIFY")
  end

  -- Temperature range from entity visual settings
  local min_temp = entity.visual_min_temperature
  local max_temp = entity.visual_max_temperature
  if min_temp ~= nil and max_temp ~= nil then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      SETPOINT_HEAT_MIN_C = tostring(min_temp),
      SETPOINT_HEAT_MAX_C = tostring(max_temp),
      SETPOINT_COOL_MIN_C = tostring(min_temp),
      SETPOINT_COOL_MAX_C = tostring(max_temp),
      SETPOINT_HEAT_MIN_F = tostring(c2f(min_temp)),
      SETPOINT_HEAT_MAX_F = tostring(c2f(max_temp)),
      SETPOINT_COOL_MIN_F = tostring(c2f(min_temp)),
      SETPOINT_COOL_MAX_F = tostring(c2f(max_temp)),
    }, "NOTIFY")
  end

  -- Temperature step
  local step = entity.visual_target_temperature_step
  if step ~= nil then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      SETPOINT_RESOLUTION_C = tostring(step),
      SETPOINT_RESOLUTION_F = tostring(c2f(step) - 32),
    }, "NOTIFY")
  end

  -- Scale
  SendToProxy(PROXY_BINDING, "SCALE_CHANGED", { SCALE = getScale() }, "NOTIFY")

  -- Outdoor temperature support (driven by property)
  local outdoorSource = Properties["Outdoor Temperature Source"]
  if outdoorSource == "External" then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      HAS_OUTDOOR_TEMPERATURE = "true",
    }, "NOTIFY")
    if step ~= nil then
      SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
        OUTDOOR_TEMPERATURE_RESOLUTION_C = tostring(step),
        OUTDOOR_TEMPERATURE_RESOLUTION_F = tostring(c2f(step) - 32),
      }, "NOTIFY")
    end
  end

  CAPABILITIES_SENT = true
end

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
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "false" }, "NOTIFY")
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

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

-- Temperature scale is now read from the project-level setting via C4:GetProjectProperty("TemperatureScale")
-- No per-driver property handler needed.

function OPC.Outdoor_Temperature_Source(propertyValue)
  log:trace("OPC.Outdoor_Temperature_Source('%s')", propertyValue)
  local enabled = propertyValue == "External"
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    HAS_OUTDOOR_TEMPERATURE = tostring(enabled),
  }, "NOTIFY")
  if enabled and ENTITY ~= nil then
    -- Send outdoor temperature resolution based on entity step
    local step = ENTITY.visual_target_temperature_step or 0.5
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      OUTDOOR_TEMPERATURE_RESOLUTION_C = tostring(step),
      OUTDOOR_TEMPERATURE_RESOLUTION_F = tostring(c2f(step) - 32),
    }, "NOTIFY")
  end
end

---------------------------------------------------------------------------
-- Thermostat proxy commands (RFP handlers)
---------------------------------------------------------------------------

function RFP.SET_MODE_OFF(idBinding, strCommand)
  log:trace("RFP.SET_MODE_OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_OFF,
  })
end

function RFP.SET_MODE_HEAT(idBinding, strCommand)
  log:trace("RFP.SET_MODE_HEAT(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT,
  })
end

function RFP.SET_MODE_COOL(idBinding, strCommand)
  log:trace("RFP.SET_MODE_COOL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL,
  })
end

function RFP.SET_MODE_AUTO(idBinding, strCommand)
  log:trace("RFP.SET_MODE_AUTO(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL,
  })
end

function RFP.SET_MODE_FAN_ONLY(idBinding, strCommand)
  log:trace("RFP.SET_MODE_FAN_ONLY(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_FAN_ONLY,
  })
end

function RFP.SET_SETPOINT_HEAT(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_HEAT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local setpoint = tonumber(Select(tParams, "SETPOINT"))
  if setpoint == nil then
    return
  end
  local celsius = fromDisplayTemp(setpoint)
  local mode = STATE ~= nil and tointeger(Select(STATE, "mode")) or nil
  -- If in heat_cool mode, use target_temperature_low
  if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL then
    sendClimateCommand({
      has_target_temperature_low = true,
      target_temperature_low = celsius,
    })
  else
    sendClimateCommand({
      has_target_temperature = true,
      target_temperature = celsius,
    })
  end
end

function RFP.SET_SETPOINT_COOL(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_COOL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local setpoint = tonumber(Select(tParams, "SETPOINT"))
  if setpoint == nil then
    return
  end
  local celsius = fromDisplayTemp(setpoint)
  local mode = STATE ~= nil and tointeger(Select(STATE, "mode")) or nil
  -- If in heat_cool mode, use target_temperature_high
  if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL then
    sendClimateCommand({
      has_target_temperature_high = true,
      target_temperature_high = celsius,
    })
  else
    sendClimateCommand({
      has_target_temperature = true,
      target_temperature = celsius,
    })
  end
end

function RFP.INC_SETPOINT_HEAT(idBinding, strCommand)
  log:trace("RFP.INC_SETPOINT_HEAT(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or STATE == nil or ENTITY == nil then
    return
  end
  local step = ENTITY.visual_target_temperature_step or 0.5
  local mode = tointeger(Select(STATE, "mode")) or 0
  if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL then
    local current = tonumber(Select(STATE, "target_temperature_low")) or 0
    sendClimateCommand({
      has_target_temperature_low = true,
      target_temperature_low = current + step,
    })
  else
    local current = tonumber(Select(STATE, "target_temperature")) or 0
    sendClimateCommand({
      has_target_temperature = true,
      target_temperature = current + step,
    })
  end
end

function RFP.DEC_SETPOINT_HEAT(idBinding, strCommand)
  log:trace("RFP.DEC_SETPOINT_HEAT(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or STATE == nil or ENTITY == nil then
    return
  end
  local step = ENTITY.visual_target_temperature_step or 0.5
  local mode = tointeger(Select(STATE, "mode")) or 0
  if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL then
    local current = tonumber(Select(STATE, "target_temperature_low")) or 0
    sendClimateCommand({
      has_target_temperature_low = true,
      target_temperature_low = current - step,
    })
  else
    local current = tonumber(Select(STATE, "target_temperature")) or 0
    sendClimateCommand({
      has_target_temperature = true,
      target_temperature = current - step,
    })
  end
end

function RFP.INC_SETPOINT_COOL(idBinding, strCommand)
  log:trace("RFP.INC_SETPOINT_COOL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or STATE == nil or ENTITY == nil then
    return
  end
  local step = ENTITY.visual_target_temperature_step or 0.5
  local mode = tointeger(Select(STATE, "mode")) or 0
  if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL then
    local current = tonumber(Select(STATE, "target_temperature_high")) or 0
    sendClimateCommand({
      has_target_temperature_high = true,
      target_temperature_high = current + step,
    })
  else
    local current = tonumber(Select(STATE, "target_temperature")) or 0
    sendClimateCommand({
      has_target_temperature = true,
      target_temperature = current + step,
    })
  end
end

function RFP.DEC_SETPOINT_COOL(idBinding, strCommand)
  log:trace("RFP.DEC_SETPOINT_COOL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or STATE == nil or ENTITY == nil then
    return
  end
  local step = ENTITY.visual_target_temperature_step or 0.5
  local mode = tointeger(Select(STATE, "mode")) or 0
  if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL then
    local current = tonumber(Select(STATE, "target_temperature_high")) or 0
    sendClimateCommand({
      has_target_temperature_high = true,
      target_temperature_high = current - step,
    })
  else
    local current = tonumber(Select(STATE, "target_temperature")) or 0
    sendClimateCommand({
      has_target_temperature = true,
      target_temperature = current - step,
    })
  end
end

function RFP.SET_SETPOINT_HUMIDIFY(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_HUMIDIFY(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local setpoint = tonumber(Select(tParams, "SETPOINT"))
  if setpoint == nil then
    return
  end
  sendClimateCommand({
    has_target_humidity = true,
    target_humidity = setpoint,
  })
end

function RFP.SET_SETPOINT_DEHUMIDIFY(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_DEHUMIDIFY(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local setpoint = tonumber(Select(tParams, "SETPOINT"))
  if setpoint == nil then
    return
  end
  sendClimateCommand({
    has_target_humidity = true,
    target_humidity = setpoint,
  })
end

function RFP.SET_FAN_MODE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_FAN_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local mode = Select(tParams, "MODE")
  if mode == nil then
    return
  end
  local fanMode = C4_TO_CLIMATE_FAN_MODE[mode]
  if fanMode ~= nil then
    sendClimateCommand({
      has_fan_mode = true,
      fan_mode = fanMode,
    })
  else
    -- Try as custom fan mode
    sendClimateCommand({
      has_custom_fan_mode = true,
      custom_fan_mode = mode,
    })
  end
end

function RFP.SET_HOLD_MODE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_HOLD_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local mode = Select(tParams, "MODE")
  if mode == nil then
    return
  end
  local preset = C4_TO_CLIMATE_PRESET[mode]
  if preset ~= nil then
    sendClimateCommand({
      has_preset = true,
      preset = preset,
    })
  else
    -- Try as custom preset
    sendClimateCommand({
      has_custom_preset = true,
      custom_preset = mode,
    })
  end
end

function RFP.SET_MODE_HVAC(idBinding, strCommand, tParams)
  log:trace("RFP.SET_MODE_HVAC(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local mode = Select(tParams, "MODE")
  if mode == nil then
    return
  end
  local climateMode = C4_TO_CLIMATE_MODE[mode]
  if climateMode ~= nil then
    sendClimateCommand({
      has_mode = true,
      mode = climateMode,
    })
  end
end

function RFP.SET_REMOTE_SENSOR(idBinding, strCommand, tParams)
  log:trace("RFP.SET_REMOTE_SENSOR(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local inUse = Select(tParams, "IN_USE")
  REMOTE_SENSOR_IN_USE = inUse == "true" or inUse == "1"
  log:info("Remote sensor in use: %s", tostring(REMOTE_SENSOR_IN_USE))
end

---------------------------------------------------------------------------
-- State update handler
---------------------------------------------------------------------------

function RFP.UPDATE_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    log:error("RFP.UPDATE_STATE called with idBinding %s, expected %s", idBinding, ESPHOME_BINDING)
    return
  end

  local entity = DeserializeSafe(Select(tParams, "entity"))
  local state = DeserializeSafe(Select(tParams, "state"))
  if IsEmpty(entity) or IsEmpty(state) then
    log:error("RFP.UPDATE_STATE called with invalid parameters: %s", tParams)
    return
  end

  log:trace("Entity: %s", entity)
  log:trace("State: %s", state)

  ENTITY = entity
  STATE = state

  -- Always update connection status
  UpdateProperty("Driver Status", "Connected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")

  -- Send capabilities on first state update
  if not CAPABILITIES_SENT then
    sendCapabilities(entity)
  end

  -- Current temperature
  local currentTemp = tonumber(Select(state, "current_temperature"))
  if currentTemp ~= nil then
    SendToProxy(PROXY_BINDING, "TEMPERATURE_CHANGED", {
      TEMPERATURE = tostring(toDisplayTemp(currentTemp)),
      SCALE = getScale(),
    }, "NOTIFY")
    -- Forward to temperature output connection (Celsius * 10)
    SendToProxy(TEMPERATURE_OUTPUT_BINDING, "VALUE", {
      VALUE = tostring(math.floor(currentTemp * 10 + 0.5)),
    })
  end

  -- HVAC mode
  local mode = tointeger(Select(state, "mode"))
  if mode ~= nil then
    local c4Mode = CLIMATE_MODE_TO_C4[mode]
    if c4Mode ~= nil then
      SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = c4Mode }, "NOTIFY")
    end
  end

  -- HVAC action/state
  local action = tointeger(Select(state, "action"))
  if action ~= nil then
    local c4State = CLIMATE_ACTION_TO_C4[action]
    if c4State ~= nil then
      SendToProxy(PROXY_BINDING, "HVAC_STATE_CHANGED", { STATE = c4State }, "NOTIFY")
    end
  end

  -- Setpoints: handle single vs dual setpoint
  local twoPoint = entity.supports_two_point_target_temperature
  if twoPoint then
    local targetLow = tonumber(Select(state, "target_temperature_low"))
    local targetHigh = tonumber(Select(state, "target_temperature_high"))
    if targetLow ~= nil then
      SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
        SETPOINT = tostring(toDisplayTemp(targetLow)),
        SCALE = getScale(),
      }, "NOTIFY")
    end
    if targetHigh ~= nil then
      SendToProxy(PROXY_BINDING, "COOL_SETPOINT_CHANGED", {
        SETPOINT = tostring(toDisplayTemp(targetHigh)),
        SCALE = getScale(),
      }, "NOTIFY")
    end
  else
    local targetTemp = tonumber(Select(state, "target_temperature"))
    if targetTemp ~= nil then
      -- Send to the appropriate setpoint based on current mode
      if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL then
        SendToProxy(PROXY_BINDING, "COOL_SETPOINT_CHANGED", {
          SETPOINT = tostring(toDisplayTemp(targetTemp)),
          SCALE = getScale(),
        }, "NOTIFY")
      elseif mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT then
        SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
          SETPOINT = tostring(toDisplayTemp(targetTemp)),
          SCALE = getScale(),
        }, "NOTIFY")
      else
        -- For other modes, send to both
        SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
          SETPOINT = tostring(toDisplayTemp(targetTemp)),
          SCALE = getScale(),
        }, "NOTIFY")
        SendToProxy(PROXY_BINDING, "COOL_SETPOINT_CHANGED", {
          SETPOINT = tostring(toDisplayTemp(targetTemp)),
          SCALE = getScale(),
        }, "NOTIFY")
      end
    end
  end

  -- Fan mode
  local fanMode = tointeger(Select(state, "fan_mode"))
  local customFanMode = Select(state, "custom_fan_mode")
  if customFanMode ~= nil and customFanMode ~= "" then
    SendToProxy(PROXY_BINDING, "FAN_MODE_CHANGED", { MODE = customFanMode }, "NOTIFY")
  elseif fanMode ~= nil then
    local c4FanMode = CLIMATE_FAN_MODE_TO_C4[fanMode]
    if c4FanMode ~= nil then
      SendToProxy(PROXY_BINDING, "FAN_MODE_CHANGED", { MODE = c4FanMode }, "NOTIFY")
    end
  end

  -- Humidity
  local currentHumidity = tonumber(Select(state, "current_humidity"))
  if currentHumidity ~= nil then
    SendToProxy(PROXY_BINDING, "HUMIDITY_CHANGED", {
      HUMIDITY = tostring(math.floor(currentHumidity + 0.5)),
    }, "NOTIFY")
    -- Forward to humidity output connection
    SendToProxy(HUMIDITY_OUTPUT_BINDING, "VALUE", {
      VALUE = tostring(math.floor(currentHumidity + 0.5)),
    })
  end

  -- Target humidity
  local targetHumidity = tonumber(Select(state, "target_humidity"))
  if targetHumidity ~= nil then
    SendToProxy(PROXY_BINDING, "HUMIDIFY_SETPOINT_CHANGED", {
      SETPOINT = tostring(math.floor(targetHumidity + 0.5)),
    }, "NOTIFY")
  end

  -- Preset / hold mode
  local preset = tointeger(Select(state, "preset"))
  local customPreset = Select(state, "custom_preset")
  if customPreset ~= nil and customPreset ~= "" then
    SendToProxy(PROXY_BINDING, "HOLD_MODE_CHANGED", { MODE = customPreset }, "NOTIFY")
  elseif preset ~= nil then
    local c4Preset = CLIMATE_PRESET_TO_C4[preset]
    if c4Preset ~= nil then
      SendToProxy(PROXY_BINDING, "HOLD_MODE_CHANGED", { MODE = c4Preset }, "NOTIFY")
    end
  end
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, reset globals to allow for a refresh of the driver state.
  ENTITY = nil
  STATE = nil
  CAPABILITIES_SENT = false
end
