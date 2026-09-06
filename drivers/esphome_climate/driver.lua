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
local values = require("lib.values")
local constants = require("constants")
local bindings = require("lib.bindings")
local persist = require("lib.persist")

--- Update the Driver Status property and the Connected variable so
--- Programming can react to connect/disconnect.
--- @param status string The human-readable connection status.
--- @param connected boolean Whether this status represents a live connection;
--- callers pass it explicitly so rewording a status can never silently flip
--- the Connected variable.
local function updateStatus(status, connected)
  log:trace("updateStatus(%s, %s)", status, connected)
  if type(connected) ~= "boolean" then
    error(string.format("updateStatus(%s): connected must be an explicit boolean", tostring(status)), 2)
  end
  UpdateProperty("Driver Status", status)
  values:update("Connected", connected, "BOOL")
end

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002
local TEMPERATURE_OUTPUT_BINDING = 5010
local HUMIDITY_OUTPUT_BINDING = 5012

local SELECT_OPTION = constants.SELECT_OPTION
local NONE_OPTION = "None"
local REMOTE_BINDING_NAMESPACE = "remote_sensor"
local REMOTE_BINDING_KEY = "temperature"

local ENTITY
local STATE
local CAPABILITIES_SENT = false
local REMOTE_SENSOR_IN_USE = false -- cached from proxy SET_REMOTE_SENSOR, persisted
local SENSOR_BINDING = nil
local USER_SERVICES_DISCOVERED = false
local IS_SINGLE_SETPOINT = false
local LAST_WATER_HEATER_MODE = nil -- restored from persist in OnDriverLateInit

--- ESPHome ClimateMode -> C4 HVAC mode string
local CLIMATE_MODE_TO_C4 = {
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_OFF] = "Off",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT] = "Heat",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL] = "Cool",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL] = "Auto",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_AUTO] = "Auto",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_FAN_ONLY] = "Fan Only",
  [ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_DRY] = "Dry",
}

--- C4 HVAC mode string -> ESPHome ClimateMode
local C4_TO_CLIMATE_MODE = TableReverse(CLIMATE_MODE_TO_C4)
C4_TO_CLIMATE_MODE["Auto"] = nil -- resolved at runtime via getAutoMode()

--- Resolve the ESPHome mode for C4 "Auto".
--- Prefers HEAT_COOL (user controls setpoints) over AUTO (device-managed).
--- Returns nil if the entity supports neither.
local function getAutoMode()
  local ClimateMode = ESPHomeProtoSchema.Enum.ClimateMode
  local hasHeatCool, hasAuto = false, false
  for _, m in ipairs(ENTITY and ENTITY.supported_modes or {}) do
    if m == ClimateMode.CLIMATE_MODE_HEAT_COOL then
      hasHeatCool = true
    end
    if m == ClimateMode.CLIMATE_MODE_AUTO then
      hasAuto = true
    end
  end
  if hasHeatCool then
    return ClimateMode.CLIMATE_MODE_HEAT_COOL
  end
  if hasAuto then
    return ClimateMode.CLIMATE_MODE_AUTO
  end
  return nil
end

--- ESPHome ClimateAction -> C4 HVAC state string
local CLIMATE_ACTION_TO_C4 = {
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_OFF] = "Off",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_HEATING] = "Heating",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_COOLING] = "Cooling",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_IDLE] = "Idle",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_DRYING] = "Drying",
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_FAN] = "Fan Only",
  -- Defrost is a heating-cycle sub-state; the C4 proxy has no defrost state
  [ESPHomeProtoSchema.Enum.ClimateAction.CLIMATE_ACTION_DEFROSTING] = "Heating",
}

--- ESPHome ClimateFanMode -> C4 fan mode string
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

--- C4 fan mode string -> ESPHome ClimateFanMode
local C4_TO_CLIMATE_FAN_MODE = TableReverse(CLIMATE_FAN_MODE_TO_C4)

-- ESPHome climate presets (Home, Away, Eco, etc.) are not yet mapped to
-- the C4 preset system. The C4 preset UI requires preset_fields definitions
-- and PRESET_ADD to display correctly. See DRV-36 for implementation.

--- Temperature values are always sent in Celsius - ESPHome uses Celsius natively
--- and the proxy converts to the user's display scale based on the SCALE param.
local SCALE = "C"

--- Persist key for an installer's per-thermostat display-scale override.
local P_DISPLAY_SCALE = "DisplayScale"

--- Normalize any of the scale spellings the proxy uses ("C"/"F",
--- "Celsius"/"Fahrenheit", "CELSIUS"/"FAHRENHEIT") to a single letter.
--- @param scale string|nil
--- @return string|nil scale "C", "F", or nil if unrecognized.
local function normalizeScale(scale)
  local first = tostring(scale or ""):sub(1, 1):upper()
  if first == "C" or first == "F" then
    return first
  end
  return nil
end

--- The scale the thermostat should display in. An installer override set from
--- Composer or programming (SET_SCALE) wins; otherwise follow the project's
--- temperature scale. ESPHome itself is always Celsius, so this is purely a
--- display concern and nothing is pushed to the device.
--- @return string scale "C" or "F".
local function getDisplayScale()
  return normalizeScale(persist:get(P_DISPLAY_SCALE)) or normalizeScale(C4:GetTemperatureScale()) or "F"
end

--- Report the ESPHome device's reachability to the thermostat proxy.
--- thermostatV2 has no ONLINE_CHANGED; it tracks reachability through
--- CONNECTION/CONNECTED, which drives the proxy's IS_CONNECTED variable and the
--- offline indicator Navigator shows on the thermostat.
--- @param connected boolean
--- @return void
local function sendConnectionState(connected)
  SendToProxy(PROXY_BINDING, "CONNECTION", { CONNECTED = connected and "true" or "false" }, "NOTIFY")
end

--- Last scale reported to the proxy, so a change in the project's scale is
--- picked up without waiting for the ESPHome device to reconnect.
--- @type string|nil
local REPORTED_SCALE = nil

--- Tell the proxy which scale to display in, if it has changed. The proxy
--- defaults to Fahrenheit and never consults the project setting on its own, so
--- without this a Celsius project still shows Fahrenheit thermostats. Called on
--- every state update, which is what lets an installer flip the project scale in
--- Composer and see it take effect on an already-connected thermostat.
--- @return void
local function sendDisplayScale()
  local scale = getDisplayScale()
  if scale == REPORTED_SCALE then
    return
  end
  REPORTED_SCALE = scale
  log:debug("Setting thermostat display scale to %s", scale)
  SendToProxy(PROXY_BINDING, "SCALE_CHANGED", { SCALE = scale }, "NOTIFY")
end

--- Extract a Celsius temperature from proxy command params.
--- The proxy sends CELSIUS, FAHRENHEIT, KELVIN, and SETPOINT simultaneously.
--- @param tParams table Proxy command parameters.
--- @return number|nil celsius Temperature in Celsius.
local function getCelsiusFromParams(tParams)
  local celsius = tonumber(Select(tParams, "CELSIUS"))
  if celsius ~= nil then
    return celsius
  end
  local fahrenheit = tonumber(Select(tParams, "FAHRENHEIT"))
  if fahrenheit ~= nil then
    return f2c(fahrenheit)
  end
  -- Fall back to VALUE + SCALE (used by TEMPERATURE_VALUE bindings)
  local value = tonumber(Select(tParams, "VALUE"))
  if value ~= nil then
    local scale = Select(tParams, "SCALE") or "F"
    if scale == "C" or scale == "c" or scale == "CELSIUS" then
      return value
    end
    if scale == "K" or scale == "k" or scale == "KELVIN" then
      return value - 273.15
    end
    return f2c(value)
  end
  return nil
end

--- Get the entity's min/max temperature range in Celsius.
--- Handles both climate (visual_min/max_temperature) and water heater (min/max_temperature) field names.
--- @return number|nil minTemp Minimum temperature in Celsius.
--- @return number|nil maxTemp Maximum temperature in Celsius.
local function getEntityTempRange()
  if ENTITY == nil then
    return nil, nil
  end
  local minTemp = ENTITY.visual_min_temperature or ENTITY.min_temperature
  local maxTemp = ENTITY.visual_max_temperature or ENTITY.max_temperature
  return minTemp, maxTemp
end

--- Get the entity's temperature step in Celsius.
--- @return number step Temperature step in Celsius (default 0.5).
local function getEntityTempStep()
  if ENTITY == nil then
    return 0.5
  end
  return ENTITY.visual_target_temperature_step or ENTITY.target_temperature_step or 0.5
end

--- Valid C4 temperature resolutions per the thermostatV2 proxy docs.
--- F floor is 0.2; C has no documented floor.
local VALID_RESOLUTIONS_C = { 0.1, 0.5, 1, 2, 5 }
local VALID_RESOLUTIONS_F = { 0.2, 0.5, 1, 2, 5 }

--- Snap a resolution value to the nearest valid C4 resolution.
--- @param value number The raw resolution value.
--- @param validValues number[] The list of valid resolutions.
--- @return number The nearest valid resolution.
local function snapResolution(value, validValues)
  if value == nil then
    return 1
  end
  local best = validValues[1]
  local bestDist = math.abs(value - best)
  for _, v in ipairs(validValues) do
    local dist = math.abs(value - v)
    if dist < bestDist then
      best = v
      bestDist = dist
    end
  end
  return best
end

--- Convert a Celsius delta to a Fahrenheit delta.
--- @param value number Temperature delta in Celsius.
--- @return number Temperature delta in Fahrenheit.
local function celsiusDeltaToFahrenheit(value)
  return value * 9 / 5
end

--- Clamp a Celsius temperature to the entity's min/max range.
--- @param celsius number Temperature in Celsius.
--- @return number clamped Clamped temperature in Celsius.
local function clampTemperature(celsius)
  if celsius == nil then
    return celsius
  end
  local minTemp, maxTemp = getEntityTempRange()
  if minTemp ~= nil and celsius < minTemp then
    return minTemp
  end
  if maxTemp ~= nil and celsius > maxTemp then
    return maxTemp
  end
  return celsius
end

--- Send a climate command to the ESPHome device via the binding.
--- @param body table<string, any> The command body.
--- @param command? string RPC method name (default: climate_command).
local function sendClimateCommand(body, command)
  log:trace("sendClimateCommand(%s, %s)", body, command)
  local params = { body = SerializeSafe(body) }
  if command then
    params.command = command
  end
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", params)
end

--- Send a water_heater_command to the ESPHome device.
--- @param hasFields number WaterHeaterCommandHasField bitmask.
--- @param fields table<string, any> Additional fields (mode, target_temperature, etc.).
local function sendWaterHeaterCommand(hasFields, fields)
  local body = { has_fields = hasFields }
  for k, v in pairs(fields) do
    body[k] = v
  end
  sendClimateCommand(body, "water_heater_command")
end

--- Send a target temperature command, routing to water_heater_command or climate_command.
--- @param celsius number Target temperature in Celsius.
local function sendTargetTemperature(celsius)
  if ENTITY and ENTITY.is_water_heater then
    sendWaterHeaterCommand(
      ESPHomeProtoSchema.Enum.WaterHeaterCommandHasField.WATER_HEATER_COMMAND_HAS_TARGET_TEMPERATURE,
      {
        target_temperature = celsius,
      }
    )
  else
    sendClimateCommand({ has_target_temperature = true, target_temperature = celsius })
  end
end

--- C4 hold mode name -> WaterHeaterMode enum
local C4_TO_WATER_HEATER_MODE = {
  ["Off"] = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_OFF,
  ["Eco Mode"] = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_ECO,
  ["Electric"] = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_ELECTRIC,
  ["Performance"] = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_PERFORMANCE,
  ["High Demand"] = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_HIGH_DEMAND,
  ["Heat Pump"] = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_HEAT_PUMP,
  ["Gas"] = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_GAS,
}

--- WaterHeaterMode enum -> C4 hold mode name (reverse lookup)
local C4_TO_WATER_HEATER_MODE_NAMES = {}
for name, enumVal in pairs(C4_TO_WATER_HEATER_MODE) do
  C4_TO_WATER_HEATER_MODE_NAMES[enumVal] = name
end

--- Detect setpoint capabilities from the entity's supported modes.
--- Per C4 docs, can_heat/can_cool/can_auto must all be false when has_single_setpoint is true.
--- @param entity table The entity data.
--- @return table caps Dynamic capability key-value pairs ready for DYNAMIC_CAPABILITIES_CHANGED.
local function detectSetpointCaps(entity)
  -- Water heaters are always single setpoint; their supported_modes are WaterHeaterMode
  -- enum values, not ClimateMode, so the mode loop below doesn't apply
  if entity.is_water_heater then
    return { HAS_SINGLE_SETPOINT = true, CAN_HEAT = false, CAN_COOL = false, CAN_AUTO = false }
  end
  local can_heat = false
  local can_cool = false
  local can_auto = false
  for _, mode in ipairs(entity.supported_modes or {}) do
    if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT then
      can_heat = true
    elseif mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL then
      can_cool = true
    elseif
      mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL
      or mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_AUTO
    then
      can_auto = true
    end
  end
  local single = not entity.supports_two_point_target_temperature and not (can_heat and can_cool)
  if single then
    can_heat = false
    can_cool = false
    can_auto = false
  end
  return { HAS_SINGLE_SETPOINT = single, CAN_HEAT = can_heat, CAN_COOL = can_cool, CAN_AUTO = can_auto }
end

--- Build preset names from the entity's supported WaterHeaterMode values.
--- @param entity table<string, any> The entity data.
--- @return string[] presetNames List of water heater mode names (excluding "Off").
local function buildWaterHeaterPresetNames(entity)
  local modes = {}
  local supported = entity.supported_modes or {}
  for _, whMode in ipairs(supported) do
    if whMode ~= ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_OFF then
      local name = C4_TO_WATER_HEATER_MODE_NAMES[whMode]
      if name then
        table.insert(modes, name)
      end
    end
  end
  return modes
end

--- Send capabilities to the thermostat proxy based on entity data.
--- Works for both climate and water heater entities.
--- @param entity table The entity data.
local function sendCapabilities(entity)
  log:trace("sendCapabilities(%s)", entity)

  sendDisplayScale()

  -- HVAC modes: water heaters only support Off/Heat in C4; climate entities map from ESPHome modes
  if entity.is_water_heater then
    SendToProxy(PROXY_BINDING, "ALLOWED_HVAC_MODES_CHANGED", { MODES = "Off,Heat" }, "NOTIFY")
  else
    local modes = {}
    for _, mode in ipairs(entity.supported_modes or {}) do
      local c4Mode = CLIMATE_MODE_TO_C4[mode]
      if c4Mode ~= nil then
        modes[c4Mode] = true
      end
    end
    if next(modes) then
      SendToProxy(
        PROXY_BINDING,
        "ALLOWED_HVAC_MODES_CHANGED",
        { MODES = table.concat(TableKeys(modes), ",") },
        "NOTIFY"
      )
    end
  end

  -- Fan modes
  local fan_modes = {}
  for _, mode in ipairs(entity.supported_fan_modes or {}) do
    local c4Mode = CLIMATE_FAN_MODE_TO_C4[mode]
    if c4Mode ~= nil then
      fan_modes[c4Mode] = true
    end
  end
  -- Custom fan modes from ESPHome are passed through as-is
  for _, mode in ipairs(entity.supported_custom_fan_modes or {}) do
    fan_modes[mode] = true
  end
  if next(fan_modes) then
    SendToProxy(
      PROXY_BINDING,
      "ALLOWED_FAN_MODES_CHANGED",
      { MODES = table.concat(TableKeys(fan_modes), ",") },
      "NOTIFY"
    )
  end

  -- Setpoint caps from entity modes
  local setpointCaps = detectSetpointCaps(entity)
  IS_SINGLE_SETPOINT = setpointCaps.HAS_SINGLE_SETPOINT
  log:info("Single setpoint mode: %s", tostring(IS_SINGLE_SETPOINT))
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", setpointCaps, "NOTIFY")

  -- Humidity
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    HAS_HUMIDITY = entity.supports_current_humidity == true,
  }, "NOTIFY")

  -- Temperature ranges
  local min_temp = entity.visual_min_temperature or entity.min_temperature
  local max_temp = entity.visual_max_temperature or entity.max_temperature
  if min_temp ~= nil and max_temp ~= nil then
    log:info(
      "Temperature range from ESPHome: min=%.1f°C (%.1f°F), max=%.1f°C (%.1f°F)",
      min_temp,
      c2f(min_temp),
      max_temp,
      c2f(max_temp)
    )
    local min_c = round(min_temp)
    local max_c = round(max_temp)
    local min_f = round(c2f(min_temp))
    local max_f = round(c2f(max_temp))
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      HEAT_SETPOINT_MIN_C = min_c,
      HEAT_SETPOINT_MAX_C = max_c,
      HEAT_SETPOINT_MIN_F = min_f,
      HEAT_SETPOINT_MAX_F = max_f,
      COOL_SETPOINT_MIN_C = min_c,
      COOL_SETPOINT_MAX_C = max_c,
      COOL_SETPOINT_MIN_F = min_f,
      COOL_SETPOINT_MAX_F = max_f,
      SINGLE_SETPOINT_MIN_C = min_c,
      SINGLE_SETPOINT_MAX_C = max_c,
      SINGLE_SETPOINT_MIN_F = min_f,
      SINGLE_SETPOINT_MAX_F = max_f,
    }, "NOTIFY")
  else
    log:warn("No temperature range from ESPHome entity (min=%s, max=%s)", tostring(min_temp), tostring(max_temp))
  end

  -- Resolution
  local step = entity.visual_target_temperature_step or entity.target_temperature_step
  if step ~= nil then
    local res_c = snapResolution(step, VALID_RESOLUTIONS_C)
    local res_f = snapResolution(celsiusDeltaToFahrenheit(step), VALID_RESOLUTIONS_F)
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      HEAT_SETPOINT_RESOLUTION_C = res_c,
      HEAT_SETPOINT_RESOLUTION_F = res_f,
      COOL_SETPOINT_RESOLUTION_C = res_c,
      COOL_SETPOINT_RESOLUTION_F = res_f,
      SINGLE_SETPOINT_RESOLUTION_C = res_c,
      SINGLE_SETPOINT_RESOLUTION_F = res_f,
    }, "NOTIFY")
  end

  local currentStep = entity.visual_current_temperature_step
  if currentStep ~= nil then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      CURRENT_TEMPERATURE_RESOLUTION_C = snapResolution(currentStep, VALID_RESOLUTIONS_C),
      CURRENT_TEMPERATURE_RESOLUTION_F = snapResolution(celsiusDeltaToFahrenheit(currentStep), VALID_RESOLUTIONS_F),
    }, "NOTIFY")
  end

  CAPABILITIES_SENT = true

  -- Water heater extras
  if entity.is_water_heater then
    local whModeNames = buildWaterHeaterPresetNames(entity)
    if #whModeNames > 0 then
      SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_EXTRAS = true }, "NOTIFY")
      local currentMode = Select(STATE, "custom_preset") or whModeNames[1]
      local extrasXml = '<extras_setup><extra><section label="Operating Mode">'
        .. '<object type="list" id="waterHeaterMode" label="Mode" command="SET_MODE_WATER_HEATER" value="'
        .. currentMode
        .. '"><list maxselections="1" minselections="1">'
      for _, name in ipairs(whModeNames) do
        extrasXml = extrasXml .. '<item text="' .. name .. '" value="' .. name .. '"/>'
      end
      extrasXml = extrasXml .. "</list></object></section></extra></extras_setup>"
      SendToProxy(PROXY_BINDING, "EXTRAS_SETUP_CHANGED", { XML = extrasXml }, "NOTIFY")
    end
  end
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

  -- Restore persisted state
  values:restoreValues()
  bindings:restoreBindings()
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
  -- Restore persisted state
  LAST_WATER_HEATER_MODE = persist:get("LastWaterHeaterMode")
  REMOTE_SENSOR_IN_USE = persist:get("RemoteSensorInUse") or false

  -- Hide remote sensor properties until services are discovered
  C4:SetPropertyAttribs("Remote Temperature Service", constants.HIDE_PROPERTY)
  C4:SetPropertyAttribs("Internal Temperature Service", constants.HIDE_PROPERTY)

  -- Restore sensor binding reference if it was persisted
  local sensorBinding = bindings:getDynamicBinding(REMOTE_BINDING_NAMESPACE, REMOTE_BINDING_KEY)
  if sensorBinding then
    SENSOR_BINDING = sensorBinding.bindingId
    registerSensorBindingHandlers(SENSOR_BINDING)
  end

  gInitialized = true
  updateStatus("Disconnected", false)
  sendConnectionState(false)
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

---------------------------------------------------------------------------
-- Thermostat proxy commands (RFP handlers)
---------------------------------------------------------------------------

function RFP.SET_MODE_OFF(idBinding, strCommand)
  log:trace("RFP.SET_MODE_OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = "Off" }, "NOTIFY")
  if ENTITY and ENTITY.is_water_heater then
    local HasField = ESPHomeProtoSchema.Enum.WaterHeaterCommandHasField
    sendWaterHeaterCommand(HasField.WATER_HEATER_COMMAND_HAS_MODE, {
      mode = ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_OFF,
    })
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
  if ENTITY and ENTITY.is_water_heater then
    -- Restore last known water heater mode, or default to first supported non-OFF mode
    local restoreMode = LAST_WATER_HEATER_MODE
    if restoreMode == nil and ENTITY.supported_modes then
      for _, m in ipairs(ENTITY.supported_modes) do
        if m ~= ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_OFF then
          restoreMode = m
          break
        end
      end
    end
    if restoreMode then
      local HasField = ESPHomeProtoSchema.Enum.WaterHeaterCommandHasField
      sendWaterHeaterCommand(HasField.WATER_HEATER_COMMAND_HAS_MODE, { mode = restoreMode })
    end
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT,
  })
end

function RFP.SET_MODE_COOL(idBinding, strCommand)
  log:trace("RFP.SET_MODE_COOL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or (ENTITY and ENTITY.is_water_heater) then
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL,
  })
end

function RFP.SET_MODE_AUTO(idBinding, strCommand)
  log:trace("RFP.SET_MODE_AUTO(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or (ENTITY and ENTITY.is_water_heater) then
    return
  end
  local autoMode = getAutoMode()
  if autoMode == nil then
    log:warn("Entity does not support HEAT_COOL or AUTO mode")
    return
  end
  sendClimateCommand({
    has_mode = true,
    mode = autoMode,
  })
end

function RFP.SET_MODE_FAN_ONLY(idBinding, strCommand)
  log:trace("RFP.SET_MODE_FAN_ONLY(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or (ENTITY and ENTITY.is_water_heater) then
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
  local celsius = getCelsiusFromParams(tParams)
  if celsius == nil then
    return
  end
  -- Devices with two-point target temperature always use low/high, regardless of current mode
  if ENTITY ~= nil and ENTITY.supports_two_point_target_temperature then
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
  local celsius = getCelsiusFromParams(tParams)
  if celsius == nil then
    return
  end
  -- Devices with two-point target temperature always use low/high, regardless of current mode
  if ENTITY ~= nil and ENTITY.supports_two_point_target_temperature then
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

--- Increment or decrement a heat/cool setpoint by the entity's step value.
--- For two-point devices, adjusts low (heat) or high (cool) setpoint.
--- For single-point devices, adjusts the single target temperature.
--- @param twoPointField string "target_temperature_low" or "target_temperature_high"
--- @param hasTwoPointField string "has_target_temperature_low" or "has_target_temperature_high"
--- @param delta number +1 for increment, -1 for decrement
local function adjustSetpoint(twoPointField, hasTwoPointField, delta)
  if STATE == nil or ENTITY == nil then
    return
  end
  local step = getEntityTempStep() * delta
  if ENTITY.supports_two_point_target_temperature then
    local current = tonumber(Select(STATE, twoPointField)) or 0
    sendClimateCommand({ [hasTwoPointField] = true, [twoPointField] = clampTemperature(current + step) })
  else
    local current = tonumber(Select(STATE, "target_temperature")) or 0
    sendClimateCommand({ has_target_temperature = true, target_temperature = clampTemperature(current + step) })
  end
end

function RFP.INC_SETPOINT_HEAT(idBinding, strCommand)
  log:trace("RFP.INC_SETPOINT_HEAT(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  adjustSetpoint("target_temperature_low", "has_target_temperature_low", 1)
end

function RFP.DEC_SETPOINT_HEAT(idBinding, strCommand)
  log:trace("RFP.DEC_SETPOINT_HEAT(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  adjustSetpoint("target_temperature_low", "has_target_temperature_low", -1)
end

function RFP.INC_SETPOINT_COOL(idBinding, strCommand)
  log:trace("RFP.INC_SETPOINT_COOL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  adjustSetpoint("target_temperature_high", "has_target_temperature_high", 1)
end

function RFP.DEC_SETPOINT_COOL(idBinding, strCommand)
  log:trace("RFP.DEC_SETPOINT_COOL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  adjustSetpoint("target_temperature_high", "has_target_temperature_high", -1)
end

function RFP.SET_SETPOINT_HUMIDIFY(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_HUMIDIFY(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING or (ENTITY and ENTITY.is_water_heater) then
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
  if idBinding ~= PROXY_BINDING or (ENTITY and ENTITY.is_water_heater) then
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

function RFP.SET_MODE_FAN(idBinding, strCommand, tParams)
  log:trace("RFP.SET_MODE_FAN(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING or (ENTITY and ENTITY.is_water_heater) then
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

--- Handle water heater mode selection via extras
function RFP.SET_MODE_WATER_HEATER(idBinding, strCommand, tParams)
  log:trace("RFP.SET_MODE_WATER_HEATER(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local mode = Select(tParams, "value")
  if mode == nil then
    return
  end
  local whMode = C4_TO_WATER_HEATER_MODE[mode]
  if whMode ~= nil then
    local HasField = ESPHomeProtoSchema.Enum.WaterHeaterCommandHasField
    sendWaterHeaterCommand(HasField.WATER_HEATER_COMMAND_HAS_MODE, { mode = whMode })
    -- Update extras state to reflect the change
    SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", {
      XML = '<extras_state><extra><object id="waterHeaterMode" value="' .. mode .. '"/></extra></extras_state>',
    }, "NOTIFY")
  else
    log:warn("Unknown water heater mode: %s", mode)
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
  if ENTITY and ENTITY.is_water_heater then
    if mode == "Off" then
      RFP.SET_MODE_OFF(idBinding, "SET_MODE_OFF")
    elseif mode == "Heat" then
      RFP.SET_MODE_HEAT(idBinding, "SET_MODE_HEAT")
    end
    return
  end
  local climateMode = mode == "Auto" and getAutoMode() or C4_TO_CLIMATE_MODE[mode]
  if climateMode == nil then
    log:warn("No supported ESPHome mode for C4 mode '%s'", mode)
    return
  end
  SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = mode }, "NOTIFY")
  sendClimateCommand({
    has_mode = true,
    mode = climateMode,
  })
end

--- The proxy asks the driver to change the displayed units. ESPHome has no
--- device-side scale to push this to, so the driver just records the override
--- and reports the new scale back.
function RFP.SET_SCALE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SCALE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local scale = normalizeScale(Select(tParams, "SCALE"))
  if scale == nil then
    log:warn("Ignoring SET_SCALE with unrecognized scale: %s", Select(tParams, "SCALE"))
    return
  end
  persist:set(P_DISPLAY_SCALE, scale)
  REPORTED_SCALE = nil
  sendDisplayScale()
end

function RFP.SET_SETPOINT_SINGLE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_SINGLE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local celsius = getCelsiusFromParams(tParams)
  if celsius == nil then
    return
  end
  celsius = clampTemperature(celsius)
  sendTargetTemperature(celsius)
end

function RFP.INC_SETPOINT_SINGLE(idBinding, strCommand)
  log:trace("RFP.INC_SETPOINT_SINGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or STATE == nil or ENTITY == nil then
    return
  end
  local step = getEntityTempStep()
  local current = tonumber(Select(STATE, "target_temperature")) or 0
  sendTargetTemperature(clampTemperature(current + step))
end

function RFP.DEC_SETPOINT_SINGLE(idBinding, strCommand)
  log:trace("RFP.DEC_SETPOINT_SINGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or STATE == nil or ENTITY == nil then
    return
  end
  local step = getEntityTempStep()
  local current = tonumber(Select(STATE, "target_temperature")) or 0
  sendTargetTemperature(clampTemperature(current - step))
end

---------------------------------------------------------------------------
-- State update handler
---------------------------------------------------------------------------

function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s)", idBinding, strCommand)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  ENTITY = nil
  STATE = nil
  CAPABILITIES_SENT = false
  -- The bulb's firmware can change while we're disconnected; drop derived
  -- caps so the next UPDATE_STATE re-runs sendCapabilities and re-discovers
  -- user services. LAST_WATER_HEATER_MODE / REMOTE_SENSOR_IN_USE / SENSOR_
  -- BINDING are persisted or proxy-driven and stay across reconnects.
  IS_SINGLE_SETPOINT = false
  USER_SERVICES_DISCOVERED = false
  updateStatus("Disconnected", false)
  REPORTED_SCALE = nil
  sendConnectionState(false)
end

--- Last unmapped mode/action warned about. State pushes repeat every few
--- seconds (temperature changes included), so warn once per value, not per
--- push.
local warnedMode = nil
local warnedAction = nil

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
  updateStatus("Connected", true)
  sendConnectionState(true)

  -- Send capabilities on first state update
  if not CAPABILITIES_SENT then
    sendCapabilities(entity)
  else
    -- Re-reads the persisted override and the project scale, then notifies only
    -- when the value changed. Two director round-trips per state update, which is
    -- what buys picking up a project scale change without a reconnect.
    sendDisplayScale()
  end

  -- Current temperature
  local currentTemp = tonumber(Select(state, "current_temperature"))
  if currentTemp ~= nil then
    SendToProxy(PROXY_BINDING, "TEMPERATURE_CHANGED", {
      TEMPERATURE = tostring(currentTemp),
      SCALE = SCALE,
    }, "NOTIFY")
    -- Forward to temperature output connection
    SendToProxy(TEMPERATURE_OUTPUT_BINDING, "VALUE_CHANGED", {
      CELSIUS = tostring(currentTemp),
      FAHRENHEIT = tostring(c2f(currentTemp)),
    })
  end

  -- HVAC mode
  local mode = tointeger(Select(state, "mode"))
  if mode ~= nil then
    local c4Mode = CLIMATE_MODE_TO_C4[mode]
    if c4Mode ~= nil then
      SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = c4Mode }, "NOTIFY")
    elseif warnedMode ~= mode then
      warnedMode = mode
      log:warn("Unmapped ESPHome climate mode %s; HVAC mode not updated", mode)
    end
  end

  -- HVAC action/state
  local action = tointeger(Select(state, "action"))
  if action ~= nil then
    local c4State = CLIMATE_ACTION_TO_C4[action]
    if c4State ~= nil then
      SendToProxy(PROXY_BINDING, "HVAC_STATE_CHANGED", { STATE = c4State }, "NOTIFY")
    elseif warnedAction ~= action then
      warnedAction = action
      log:warn("Unmapped ESPHome climate action %s; HVAC state not updated", action)
    end
  end

  -- Setpoints: handle single vs dual setpoint
  local twoPoint = entity.supports_two_point_target_temperature
  if IS_SINGLE_SETPOINT then
    -- Single setpoint mode (water heaters, floor heaters, etc.)
    local targetTemp = tonumber(Select(state, "target_temperature"))
    if targetTemp ~= nil then
      SendToProxy(PROXY_BINDING, "SINGLE_SETPOINT_CHANGED", {
        SETPOINT = tostring(targetTemp),
        SCALE = SCALE,
      }, "NOTIFY")
    end
  elseif twoPoint then
    local targetLow = tonumber(Select(state, "target_temperature_low"))
    local targetHigh = tonumber(Select(state, "target_temperature_high"))
    if targetLow ~= nil then
      SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
        SETPOINT = tostring(targetLow),
        SCALE = SCALE,
      }, "NOTIFY")
    end
    if targetHigh ~= nil then
      SendToProxy(PROXY_BINDING, "COOL_SETPOINT_CHANGED", {
        SETPOINT = tostring(targetHigh),
        SCALE = SCALE,
      }, "NOTIFY")
    end
  else
    local targetTemp = tonumber(Select(state, "target_temperature"))
    if targetTemp ~= nil then
      -- Send to the appropriate setpoint based on current mode
      if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL then
        SendToProxy(PROXY_BINDING, "COOL_SETPOINT_CHANGED", {
          SETPOINT = tostring(targetTemp),
          SCALE = SCALE,
        }, "NOTIFY")
      elseif mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT then
        SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
          SETPOINT = tostring(targetTemp),
          SCALE = SCALE,
        }, "NOTIFY")
      else
        -- For other modes, send to both
        SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
          SETPOINT = tostring(targetTemp),
          SCALE = SCALE,
        }, "NOTIFY")
        SendToProxy(PROXY_BINDING, "COOL_SETPOINT_CHANGED", {
          SETPOINT = tostring(targetTemp),
          SCALE = SCALE,
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
    SendToProxy(HUMIDITY_OUTPUT_BINDING, "VALUE_CHANGED", {
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

  -- Water heater modes via extras
  local customPreset = Select(state, "custom_preset")
  if entity.is_water_heater and customPreset ~= nil and customPreset ~= "" then
    SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", {
      XML = '<extras_state><extra><object id="waterHeaterMode" value="' .. customPreset .. '"/></extra></extras_state>',
    }, "NOTIFY")
    if customPreset ~= "Off" then
      local whMode = C4_TO_WATER_HEATER_MODE[customPreset]
      if whMode then
        LAST_WATER_HEATER_MODE = whMode
        persist:set("LastWaterHeaterMode", whMode)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Remote temperature sensor
---------------------------------------------------------------------------

--- Send a remote temperature command via the ESPHome binding.
--- @param serviceName string The ESPHome service name to call.
--- @param celsius number|nil Temperature in Celsius, or nil for no-arg services (e.g. use_internal_temperature).
local function sendRemoteTemperatureCommand(serviceName, celsius)
  log:trace("sendRemoteTemperatureCommand(%s, %s)", serviceName, celsius)
  local params = { service_name = serviceName }
  if celsius ~= nil then
    params.temperature = tostring(celsius)
  end
  SendToProxy(ESPHOME_BINDING, "SET_REMOTE_TEMPERATURE", params)
end

--- Revert the climate device to its internal temperature sensor.
local function revertToInternalTemperature()
  local internalService = Properties["Internal Temperature Service"]
  if IsEmpty(internalService) or internalService == NONE_OPTION then
    log:info("No internal temperature service configured - device will auto-revert")
    return
  end
  sendRemoteTemperatureCommand(internalService, nil)
end

--- Handle a temperature value change from the bound sensor.
--- @param idBinding integer The binding ID.
--- @param tParams table The parameters.
local function handleValueChanged(idBinding, tParams)
  log:trace("handleValueChanged(%s, %s)", idBinding, tParams)
  if not REMOTE_SENSOR_IN_USE then
    return
  end
  local celsius = getCelsiusFromParams(tParams)
  if celsius == nil then
    return
  end
  local serviceName = Properties["Remote Temperature Service"]
  if IsEmpty(serviceName) or serviceName == SELECT_OPTION then
    log:warn("Remote Temperature Service not configured - cannot send remote temperature")
    return
  end
  sendRemoteTemperatureCommand(serviceName, celsius)
end

--- Register RFP and OBC handlers for the sensor binding.
--- @param bindingId integer The sensor binding ID.
function registerSensorBindingHandlers(bindingId)
  RFP[bindingId] = function(idBinding, strCommand, tParams)
    if strCommand == "VALUE_CHANGED" then
      handleValueChanged(idBinding, tParams)
    end
  end
  OBC[bindingId] = function(idBinding, strClass, isBound)
    if not isBound and REMOTE_SENSOR_IN_USE then
      revertToInternalTemperature()
    end
  end
end

--- Dynamically add the TEMPERATURE_VALUE consumer binding and enable remote sensor.
local function configureRemoteSensor()
  log:info("Configuring remote temperature sensor")
  local binding = bindings:getOrAddDynamicBinding(
    REMOTE_BINDING_NAMESPACE,
    REMOTE_BINDING_KEY,
    "CONTROL",
    false,
    "Remote Temperature Sensor",
    "TEMPERATURE_VALUE"
  )
  if binding == nil then
    log:error("Failed to create dynamic binding for remote temperature sensor")
    return
  end
  SENSOR_BINDING = binding.bindingId
  registerSensorBindingHandlers(SENSOR_BINDING)
  log:info("Remote temperature sensor configured (binding %d)", SENSOR_BINDING)
end

--- Remove the TEMPERATURE_VALUE binding and disable remote sensor.
local function unconfigureRemoteSensor()
  log:info("Unconfiguring remote temperature sensor")
  revertToInternalTemperature()
  REMOTE_SENSOR_IN_USE = false
  SENSOR_BINDING = nil
  bindings:deleteBinding(REMOTE_BINDING_NAMESPACE, REMOTE_BINDING_KEY)
  log:info("Remote temperature sensor unconfigured")
end

---------------------------------------------------------------------------
-- User-defined ESPHome services (DYNAMIC_LIST)
---------------------------------------------------------------------------

--- Update a DYNAMIC_LIST property with discovered ESPHome service names.
--- @param propertyName string The property name to update.
--- @param serviceNames string[] The list of discovered service names.
--- @param includeNoneOption boolean Whether to include the "None" option (default for Internal Temperature Service).
local function updateServiceList(propertyName, serviceNames, includeNoneOption)
  local items = {}
  if includeNoneOption then
    table.insert(items, NONE_OPTION)
  else
    table.insert(items, SELECT_OPTION)
  end
  for _, name in ipairs(serviceNames) do
    table.insert(items, name)
  end
  local itemStr = table.concat(items, ",")
  local current = Properties[propertyName]
  local defaultValue = items[1]
  for _, name in ipairs(items) do
    if name == current then
      defaultValue = current
      break
    end
  end
  C4:UpdatePropertyList(propertyName, itemStr, defaultValue)
end

function RFP.UPDATE_USER_SERVICES(idBinding, strCommand, tParams)
  log:trace("RFP.UPDATE_USER_SERVICES(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  local serviceNames = DeserializeSafe(Select(tParams, "service_names")) or {}
  log:info("Discovered %d user-defined ESPHome services: %s", #serviceNames, serviceNames)

  USER_SERVICES_DISCOVERED = (#serviceNames > 0)

  if USER_SERVICES_DISCOVERED then
    C4:SetPropertyAttribs("Remote Temperature Service", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Internal Temperature Service", constants.SHOW_PROPERTY)
  else
    C4:SetPropertyAttribs("Remote Temperature Service", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Internal Temperature Service", constants.HIDE_PROPERTY)
  end

  updateServiceList("Remote Temperature Service", serviceNames, false)
  updateServiceList("Internal Temperature Service", serviceNames, true)

  -- Trigger OPC to evaluate the current property value and configure/unconfigure as needed.
  -- This handles: initial setup, reconnect with valid config, and reconnect where service was removed
  -- (C4:UpdatePropertyList resets the value to (Select) if the old value is no longer in the list).
  OnPropertyChanged("Remote Temperature Service")
end

function OPC.Remote_Temperature_Service(propertyValue)
  log:trace("OPC.Remote_Temperature_Service('%s')", propertyValue)
  if not gInitialized then
    return
  end
  if propertyValue == SELECT_OPTION or IsEmpty(propertyValue) then
    if SENSOR_BINDING ~= nil then
      unconfigureRemoteSensor()
    end
  else
    if SENSOR_BINDING == nil then
      configureRemoteSensor()
    end
  end
end

function OPC.Internal_Temperature_Service(propertyValue)
  log:trace("OPC.Internal_Temperature_Service('%s')", propertyValue)
  if not gInitialized then
    return
  end
  if propertyValue == NONE_OPTION or IsEmpty(propertyValue) then
    log:info("Internal Temperature Service set to None (device will auto-revert)")
  else
    log:info("Internal Temperature Service set to '%s'", propertyValue)
  end
end

function RFP.SET_REMOTE_SENSOR(idBinding, strCommand, tParams)
  log:trace("RFP.SET_REMOTE_SENSOR(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  REMOTE_SENSOR_IN_USE = toboolean(Select(tParams, "IN_USE"))
  persist:set("RemoteSensorInUse", REMOTE_SENSOR_IN_USE)
  log:info("SET_REMOTE_SENSOR IN_USE=%s", tostring(REMOTE_SENSOR_IN_USE))
  if not REMOTE_SENSOR_IN_USE then
    revertToInternalTemperature()
  end
  SendToProxy(PROXY_BINDING, "REMOTE_SENSOR_CHANGED", {
    IN_USE = REMOTE_SENSOR_IN_USE,
  }, "NOTIFY")
end

OBC[ESPHOME_BINDING] = function(_idBinding, _strClass, isBound)
  ENTITY = nil
  STATE = nil
  CAPABILITIES_SENT = false
  IS_SINGLE_SETPOINT = false
  LAST_WATER_HEATER_MODE = nil
  USER_SERVICES_DISCOVERED = false
  if isBound then
    SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
  end
end
