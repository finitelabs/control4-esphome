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

--- Preset schedule, as delivered by SET_EVENTS.
--- @type table[] Array of { preset = string, weekday = 0-6, hour = 0-23, minute = 0-59 }
local SCHEDULE = {}
local SCHEDULE_TIMER = nil
--- Assigned with the preset handlers further down, but called from
--- OnDriverLateInit, so it has to be in scope before that function is defined.
local armScheduleTimer

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

--- ESPHome ClimateSwingMode -> display string.
--- thermostatV2 has no swing capability, so swing is surfaced through the Extras
--- section (the same mechanism used for water heater operating modes).
local CLIMATE_SWING_MODE_TO_C4 = {
  [ESPHomeProtoSchema.Enum.ClimateSwingMode.CLIMATE_SWING_OFF] = "Off",
  [ESPHomeProtoSchema.Enum.ClimateSwingMode.CLIMATE_SWING_BOTH] = "Both",
  [ESPHomeProtoSchema.Enum.ClimateSwingMode.CLIMATE_SWING_VERTICAL] = "Vertical",
  [ESPHomeProtoSchema.Enum.ClimateSwingMode.CLIMATE_SWING_HORIZONTAL] = "Horizontal",
}

--- Display string -> ESPHome ClimateSwingMode
local C4_TO_CLIMATE_SWING_MODE = TableReverse(CLIMATE_SWING_MODE_TO_C4)

--- Extras object id for the swing selector.
local SWING_EXTRA_ID = "swingMode"

-- The device's own ESPHome presets are deliberately not mapped into the proxy's
-- preset list. Two facts drive that and neither is recoverable by reading this
-- file: the API publishes which presets exist and which is active but never what
-- a preset DOES, and a device goes on reporting its preset after the user
-- overrides the setpoint or the mode (measured on hardware, both cases).
-- Reasoning in the commit "Do not map the device's own ESPHome presets, and say
-- why".

--- Temperature values are always sent in Celsius - ESPHome uses Celsius natively
--- and the proxy converts to the user's display scale based on the SCALE param.
local SCALE = "C"

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
  -- The entity declares its own setpoint count. supports_two_point_target_temperature
  -- is a field of ListEntitiesClimateResponse, set from the component's traits, and
  -- when it is false the device has exactly one target_temperature - the low/high
  -- fields are meaningless for it in every mode. Honour that declaration rather than
  -- inferring setpoint count from mode support: a mini-split offers HEAT and COOL as
  -- modes yet holds one target (CN105 carries a single temperature byte in its
  -- write-settings packet, with AUTO being just another value of the mode byte).
  -- The SDK requires can_heat, can_cool and can_do_auto to be false when
  -- has_single_setpoint is set. Auto stays available regardless: it is carried by
  -- hvac_modes, which sendCapabilities publishes independently of these capabilities.
  -- Verified on a single-target head - Auto is selectable and holds.
  local single = not entity.supports_two_point_target_temperature
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

--- Build the preset_fields TEMPLATE from what this entity actually supports.
---
--- The static <preset_fields> block in driver.xml is a fallback; the proxy
--- serves UIs from whatever PRESET_FIELDS_CHANGED last pushed, which is the only
--- way a generic bridge can offer the right fields for an arbitrary device.
--- Which setpoint fields appear is decided by the SAME flag the proxy uses:
--- heat/cool when it runs dual, single otherwise.
--- @param entity table The entity data.
--- @param singleSetpoint boolean Whether the proxy is in single-setpoint mode.
--- @return string xml
--- Escape a value for use inside an XML attribute. Custom fan mode names come
--- from the device's own YAML, so an ampersand or a quote in one would
--- otherwise produce markup the proxy cannot parse.
--- @param value any
--- @return string
local function xmlAttr(value)
  local escaped = tostring(value)
  escaped = escaped:gsub("&", "&amp;")
  escaped = escaped:gsub("<", "&lt;")
  escaped = escaped:gsub(">", "&gt;")
  escaped = escaped:gsub('"', "&quot;")
  escaped = escaped:gsub("'", "&apos;")
  return escaped
end

local function buildPresetFieldsXml(entity, singleSetpoint)
  local minC = round(entity.visual_min_temperature or entity.min_temperature or 4)
  local maxC = round(entity.visual_max_temperature or entity.max_temperature or 32)
  local minF = round(c2f(minC))
  local maxF = round(c2f(maxC))

  local parts = { "<preset_fields>" }

  local function numberField(id, label, lo, hi, res)
    parts[#parts + 1] = string.format(
      '<field id="%s" type="number" label="%s" min="%s" max="%s" res="%s"/>',
      id,
      label,
      tostring(lo),
      tostring(hi),
      tostring(res)
    )
  end

  if singleSetpoint then
    numberField("single_setpoint_f", "Setpoint", minF, maxF, 1)
    numberField("single_setpoint_c", "Setpoint", minC, maxC, 0.5)
  else
    -- Only offer a setpoint the device can actually act on. A two-point entity
    -- that reports no HEAT mode has nothing to do with a heat setpoint, and
    -- showing the field invites a preset that silently does nothing.
    local offersHeat, offersCool = false, false
    for _, mode in ipairs(entity.supported_modes or {}) do
      if mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT then
        offersHeat = true
      elseif mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_COOL then
        offersCool = true
      elseif
        mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_HEAT_COOL
        or mode == ESPHomeProtoSchema.Enum.ClimateMode.CLIMATE_MODE_AUTO
      then
        offersHeat = true
        offersCool = true
      end
    end
    if offersHeat then
      numberField("heat_setpoint_f", "Heat Setpoint", minF, maxF, 1)
      numberField("heat_setpoint_c", "Heat Setpoint", minC, maxC, 0.5)
    end
    if offersCool then
      numberField("cool_setpoint_f", "Cool Setpoint", minF, maxF, 1)
      numberField("cool_setpoint_c", "Cool Setpoint", minC, maxC, 0.5)
    end
  end

  local function listField(id, label, values)
    if #values == 0 then
      return
    end
    parts[#parts + 1] = string.format('<field id="%s" type="list" label="%s"><list>', id, label)
    for _, value in ipairs(values) do
      parts[#parts + 1] = string.format('<item text="%s" value="%s"/>', xmlAttr(value), xmlAttr(value))
    end
    parts[#parts + 1] = "</list></field>"
  end

  -- Ordered + de-duplicated: HEAT_COOL and AUTO both map to "Auto".
  local function mapped(list, lookup)
    local out, seen = {}, {}
    for _, raw in ipairs(list or {}) do
      local name = lookup[raw]
      if name ~= nil and not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
    return out
  end

  listField("hvac_mode", "HVAC Mode", mapped(entity.supported_modes, CLIMATE_MODE_TO_C4))

  local fanModes = mapped(entity.supported_fan_modes, CLIMATE_FAN_MODE_TO_C4)
  for _, custom in ipairs(entity.supported_custom_fan_modes or {}) do
    fanModes[#fanModes + 1] = custom
  end
  listField("fan_mode", "Fan Mode", fanModes)

  listField("swing", "Swing", mapped(entity.supported_swing_modes, CLIMATE_SWING_MODE_TO_C4))

  parts[#parts + 1] = "</preset_fields>"
  return table.concat(parts)
end

--- Send capabilities to the thermostat proxy based on entity data.
--- Works for both climate and water heater entities.
--- @param entity table The entity data.
local function sendCapabilities(entity)
  log:trace("sendCapabilities(%s)", entity)

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
  -- can_preset defaults to false in driver.xml and is turned on here, once an
  -- entity is actually attached. can_preset_schedule stays static: the SDK
  -- documents can_preset as changeable through DYNAMIC_CAPABILITIES_CHANGED and
  -- says nothing of the kind for can_preset_schedule.
  setpointCaps.CAN_PRESET = true
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", setpointCaps, "NOTIFY")

  -- The preset template has to agree with the setpoint mode just published. A
  -- heat/cool proxy offered only single_setpoint fields (or the reverse) leaves
  -- the preset editor with nothing to render, so it can be named but never
  -- completed.
  if not entity.is_water_heater then
    local presetFieldsXml = buildPresetFieldsXml(entity, IS_SINGLE_SETPOINT)
    log:debug("Preset fields template: %s", presetFieldsXml)
    SendToProxy(PROXY_BINDING, "PRESET_FIELDS_CHANGED", { XML = presetFieldsXml }, "NOTIFY")
  end

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

  -- Swing modes (climate only) are surfaced as an Extras selector, since
  -- thermostatV2 has no swing capability of its own.
  if not entity.is_water_heater then
    local swingNames = {}
    for _, mode in ipairs(entity.supported_swing_modes or {}) do
      local name = CLIMATE_SWING_MODE_TO_C4[mode]
      if name ~= nil then
        swingNames[#swingNames + 1] = name
      end
    end
    -- A lone "Off" is not a choice; only expose the selector if the device
    -- actually offers somewhere to swing to.
    if #swingNames > 1 then
      SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_EXTRAS = true }, "NOTIFY")
      -- An absent swing_mode means the zero value (OFF), not "unknown" - falling
      -- back to the first advertised option would display the wrong state, since
      -- devices do not necessarily list OFF first.
      local currentSwing = tointeger(Select(STATE, "swing_mode"))
        or ESPHomeProtoSchema.Enum.ClimateSwingMode.CLIMATE_SWING_OFF
      local current = CLIMATE_SWING_MODE_TO_C4[currentSwing] or swingNames[1]
      local parts = {
        '<extras_setup><extra><section label="Swing">',
        '<object type="list" id="',
        SWING_EXTRA_ID,
        '" label="Swing" command="SET_MODE_SWING" value="',
        current,
        '"><list maxselections="1" minselections="1">',
      }
      for _, name in ipairs(swingNames) do
        parts[#parts + 1] = '<item text="' .. name .. '" value="' .. name .. '"/>'
      end
      parts[#parts + 1] = "</list></object></section></extra></extras_setup>"
      SendToProxy(PROXY_BINDING, "EXTRAS_SETUP_CHANGED", { XML = table.concat(parts) }, "NOTIFY")
    end
  end

  -- Water heater extras
  if entity.is_water_heater then
    local whModeNames = buildWaterHeaterPresetNames(entity)
    if #whModeNames > 0 then
      SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_EXTRAS = true }, "NOTIFY")
      -- custom_preset is BORROWED here. A water heater entity publishes no
      -- presets at all, only supported_modes of WaterHeaterMode; the bridge
      -- collapses that to Off/Heat and puts the operating mode in custom_preset
      -- so a climate-shaped driver can carry it (water_heater.lua). The mode is
      -- orthogonal to the setpoint, which is why it is safe as an Extras
      -- selector. The is_water_heater gate around every custom_preset read is
      -- therefore load-bearing: a climate entity may legitimately advertise a
      -- custom preset named "Eco" too, and without the gate the two are
      -- indistinguishable at the point of use.
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

  -- The proxy does not re-send SET_PRESETS / SET_EVENT on startup, so without
  -- this the driver comes up with an empty preset table and every scheduled
  -- event resolves to nothing. Announcing the connection prompts a resend.
  SendToProxy(PROXY_BINDING, "CONNECTION", { CONNECTED = true }, "NOTIFY")
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

  -- The schedule is load-bearing: a reload between events would otherwise leave
  -- the driver with no timer and the schedule would silently stop running until
  -- the proxy next resent it.
  SCHEDULE = persist:get("Schedule") or {}
  if #SCHEDULE > 0 then
    log:info("Restored %d scheduled event(s)", #SCHEDULE)
    armScheduleTimer()
  end

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
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
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

---------------------------------------------------------------------------
-- Presets and preset scheduling
---------------------------------------------------------------------------

--- Preset name -> field table, as delivered by the proxy in SET_PRESETS.
local PRESETS = {}
--- Preset most recently activated by the schedule (SET_EVENT).
local SCHEDULED_PRESET = nil
--- Preset selected directly by the user; holds until the next scheduled event.
local HOLD_PRESET = nil
--- Hold mode last reported, so only real transitions are sent.
local HOLD_MODE = "Off"
--- Preset last reported as active, so only real transitions are sent.
local ACTIVE_PRESET = nil

--- The proxy's own name for "hold until the next scheduled event". Control4's
--- Residential Thermostat V2 handles "Next Event" while other shipping drivers
--- use "Until Next", and the proxy declares no canonical list. Rather than pick
--- one and be wrong, learn it from the first hold the proxy sends and echo that
--- back; the declared hold_modes value is only the starting guess.
local HOLD_UNTIL_NEXT = "Until Next"

--- Seconds from now until an event's next occurrence.
--- Weekday is 0-6 with Sunday 0 (PRESET_EVENT_ADD); Lua's wday is 1-7 with
--- Sunday 1, hence the -1.
--- @param event table A schedule entry.
--- @param now number Unix time to measure from.
--- @return number seconds Always >= 1, so an event due right now fires once.
local function secondsUntilEvent(event, now)
  now = now or os.time()
  local t = os.date("*t", now)

  -- Resolve the occurrence as a real timestamp rather than a wall-clock offset.
  -- os.time applies the DST rules in force on the target date, so an event on
  -- the far side of a boundary still fires at the local time it was scheduled
  -- for. Subtracting wall-clock offsets would arm the timer an hour out until
  -- the next re-arm. os.time normalises an out-of-range day, so no month or
  -- year arithmetic is needed here.
  local function occurrenceAt(daysAhead)
    return os.time({
      year = t.year,
      month = t.month,
      day = t.day + daysAhead,
      hour = event.hour,
      min = event.minute,
      sec = 0,
    })
  end

  local daysAhead = (event.weekday - (t.wday - 1)) % 7
  local delta = occurrenceAt(daysAhead) - now
  if delta < 1 then
    delta = occurrenceAt(daysAhead + 7) - now
  end
  return delta
end

--- The soonest upcoming event, or nil when the schedule is empty.
local function nextScheduledEvent(now)
  local best, bestIn = nil, nil
  for _, event in ipairs(SCHEDULE) do
    local seconds = secondsUntilEvent(event, now)
    if bestIn == nil or seconds < bestIn then
      best, bestIn = event, seconds
    end
  end
  return best, bestIn
end

--- Parse the preset_fields XML fragment carried as an attribute on a preset node.
--- @param raw string|nil The preset_fields XML.
--- @return table<string, string> fields Field id -> value.
local function parsePresetFields(raw)
  if IsEmpty(raw) then
    return {}
  end
  local xml = C4:ParseXml(raw)
  if xml == nil or xml.ChildNodes == nil then
    return {}
  end
  local fields = {}
  for _, field in pairs(xml.ChildNodes) do
    local attrs = field.Attributes
    if attrs ~= nil and attrs["id"] ~= nil and not IsEmpty(attrs["value"]) then
      fields[attrs["id"]] = attrs["value"]
    end
  end
  return fields
end

--- Stable string form of a preset's fields, for detecting a real edit.
--- Keys are sorted so the same values always produce the same signature.
--- @param fields table|nil A preset's field table.
--- @return string|nil signature nil when the preset does not exist.
local function presetSignature(fields)
  if fields == nil then
    return nil
  end
  local keys = {}
  for key in pairs(fields) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. tostring(fields[key])
  end
  return table.concat(parts, ";")
end

--- Resolve one preset setpoint pair to Celsius. ESPHome is Celsius natively, so
--- the Fahrenheit field is only a fallback for projects authored in F.
--- @param preset table The preset field table.
--- @param cKey string Celsius field id.
--- @param fKey string Fahrenheit field id.
--- @return number|nil celsius
local function presetSetpoint(preset, cKey, fKey)
  local celsius = tonumber(preset[cKey])
  if celsius == nil then
    local fahrenheit = tonumber(preset[fKey])
    if fahrenheit ~= nil then
      celsius = f2c(fahrenheit)
    end
  end
  return celsius
end

--- Collapse a preset's setpoint fields to the ONE value a single-setpoint device
--- can accept. Used by both apply and match so the two can never disagree about
--- which setpoint a preset means.
--- @param preset table The preset field table.
--- @return number|nil celsius
local function chooseSingleSetpoint(preset)
  local single = presetSetpoint(preset, "single_setpoint_c", "single_setpoint_f")
  if single ~= nil then
    return single
  end
  local heat = presetSetpoint(preset, "heat_setpoint_c", "heat_setpoint_f")
  local cool = presetSetpoint(preset, "cool_setpoint_c", "cool_setpoint_f")
  if preset.hvac_mode == "Heat" then
    return heat or cool
  end
  -- Cool, Auto, Dry, Fan Only or unspecified: prefer cool rather than inventing
  -- a midpoint the user never chose.
  return cool or heat
end

--- Write a preset's setpoints into a climate command body.
--- Two-point devices always use low/high regardless of mode, matching
--- SET_SETPOINT_HEAT/COOL; single-setpoint devices use target_temperature.
local function applyPresetSetpoints(preset, body)
  if ENTITY ~= nil and ENTITY.supports_two_point_target_temperature then
    -- Field ids are the proxy's, per the DriverWorks thermostat_v2 preset_fields
    -- sample: heat_setpoint_[cf] / cool_setpoint_[cf]. The proxy auto-fills
    -- whichever scale the template omits, so reading either one is enough.
    local heat = presetSetpoint(preset, "heat_setpoint_c", "heat_setpoint_f")
    local cool = presetSetpoint(preset, "cool_setpoint_c", "cool_setpoint_f")
    if heat ~= nil then
      body.has_target_temperature_low = true
      body.target_temperature_low = clampTemperature(heat)
    end
    if cool ~= nil then
      body.has_target_temperature_high = true
      body.target_temperature_high = clampTemperature(cool)
    end
    return
  end

  -- Single target_temperature on the device, but the preset may still carry a
  -- heat/cool pair: presets saved before this driver reported the device as
  -- single-setpoint keep the field ids they were saved with. Collapse them onto
  -- the one target, the same way SET_SETPOINT_HEAT/COOL already do.
  local chosen = chooseSingleSetpoint(preset)
  if chosen ~= nil then
    body.has_target_temperature = true
    body.target_temperature = clampTemperature(chosen)
  end
end

--- Apply every field a preset defines, as one climate command.
--- @param name string Preset name.
--- @return boolean applied
local function applyPreset(name)
  local preset = PRESETS[name]
  if preset == nil then
    log:warn("Asked to apply unknown preset '%s'", tostring(name))
    return false
  end

  local body = {}

  if preset.hvac_mode ~= nil then
    local mode = preset.hvac_mode == "Auto" and getAutoMode() or C4_TO_CLIMATE_MODE[preset.hvac_mode]
    if mode ~= nil then
      body.has_mode = true
      body.mode = mode
      SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = preset.hvac_mode }, "NOTIFY")
    end
  end

  applyPresetSetpoints(preset, body)

  if preset.fan_mode ~= nil then
    local fanMode = C4_TO_CLIMATE_FAN_MODE[preset.fan_mode]
    if fanMode ~= nil then
      body.has_fan_mode = true
      body.fan_mode = fanMode
    else
      body.has_custom_fan_mode = true
      body.custom_fan_mode = preset.fan_mode
    end
  end

  if preset.swing ~= nil then
    local swingMode = C4_TO_CLIMATE_SWING_MODE[preset.swing]
    if swingMode ~= nil then
      body.has_swing_mode = true
      body.swing_mode = swingMode
    end
  end

  if next(body) == nil then
    log:warn("Preset '%s' defines no usable fields", name)
    return false
  end

  log:info("Applying preset '%s'", name)
  sendClimateCommand(body)
  -- No announcement here: matchAnyPreset is the only emitter, so what the device
  -- reports is what the app is told. Announcing on the way out cannot be made
  -- safe, because a device pushes ambient temperature through the same climate
  -- state message and such a report can land between the command and the device
  -- moving.
  return true
end

--- Does current device state match every field this preset defines?
--- Fields the preset leaves unset are not compared.
local function matchPreset(name)
  local preset = name ~= nil and PRESETS[name] or nil
  if preset == nil or IsEmpty(STATE) then
    return false
  end

  -- Protobuf omits zero-valued fields, so an absent enum means its ZERO value
  -- (mode OFF, swing OFF, fan ON) rather than "unknown". Reading absence as
  -- unknown makes a preset that selects one of those values never match, and
  -- the hold it triggered would never release.
  local function stateEnum(key, supported)
    local raw = tointeger(Select(STATE, key))
    if raw ~= nil then
      return raw
    end
    -- Only assume the default for a dimension the device actually has.
    if supported ~= nil and #supported > 0 then
      return 0
    end
    return nil
  end

  if preset.hvac_mode ~= nil then
    if CLIMATE_MODE_TO_C4[stateEnum("mode", ENTITY and ENTITY.supported_modes)] ~= preset.hvac_mode then
      return false
    end
  end

  -- Tolerance, not equality: C4 authors presets in whole/half degrees while the
  -- device reports a float that has been through an F/C round trip.
  local function setpointMatches(expected, stateKey)
    if expected == nil then
      return true
    end
    local actual = tonumber(Select(STATE, stateKey))
    return actual ~= nil and math.abs(actual - expected) <= 0.25
  end

  if ENTITY ~= nil and ENTITY.supports_two_point_target_temperature then
    if not setpointMatches(presetSetpoint(preset, "heat_setpoint_c", "heat_setpoint_f"), "target_temperature_low") then
      return false
    end
    if not setpointMatches(presetSetpoint(preset, "cool_setpoint_c", "cool_setpoint_f"), "target_temperature_high") then
      return false
    end
  elseif not setpointMatches(chooseSingleSetpoint(preset), "target_temperature") then
    return false
  end

  if preset.fan_mode ~= nil then
    local customFan = Select(STATE, "custom_fan_mode")
    local current = (not IsEmpty(customFan)) and customFan
      or CLIMATE_FAN_MODE_TO_C4[stateEnum("fan_mode", ENTITY and ENTITY.supported_fan_modes)]
    if current ~= preset.fan_mode then
      return false
    end
  end

  if preset.swing ~= nil then
    if CLIMATE_SWING_MODE_TO_C4[stateEnum("swing_mode", ENTITY and ENTITY.supported_swing_modes)] ~= preset.swing then
      return false
    end
  end

  return true
end

--- Report a hold transition once.
local function setHoldMode(mode)
  if HOLD_MODE == mode then
    return
  end
  HOLD_MODE = mode
  SendToProxy(PROXY_BINDING, "HOLD_MODE_CHANGED", { MODE = mode }, "NOTIFY")
end

--- Highlight whichever preset current state matches, so a preset the user
--- reached by hand still shows as active. Reported only on a transition, the
--- same shape as setHoldMode: repeating the current preset on every state report
--- is noise, and leaving the last match standing once state moves off it leaves
--- the app highlighting a preset the device has already left.
local function matchAnyPreset()
  local matched = nil
  for name in pairs(PRESETS) do
    if matchPreset(name) then
      matched = name
      break
    end
  end
  if matched == ACTIVE_PRESET then
    return
  end
  ACTIVE_PRESET = matched
  -- "None" rather than an empty name: that is what Control4's own thermostat
  -- sends when no preset is in force.
  SendToProxy(PROXY_BINDING, "PRESET_CHANGED", { NAME = matched or "None" }, "NOTIFY")
end

--- Drop into "Until Next" when the user diverges from the scheduled preset, and
--- release the hold when state drifts back onto it. This is the whole hold UX.
local function reconcileHold()
  if SCHEDULED_PRESET == nil then
    return
  end
  if matchPreset(SCHEDULED_PRESET) then
    setHoldMode("Off")
  else
    setHoldMode(HOLD_UNTIL_NEXT)
  end
end

--- Receive the full preset list. The proxy sends every preset each time, so
--- this rebuilds rather than merges.
function RFP.SET_PRESETS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_PRESETS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local xml = C4:ParseXml(Select(tParams, "XML"))
  if xml == nil or xml.ChildNodes == nil then
    log:warn("SET_PRESETS carried no parsable XML")
    return
  end

  -- Snapshot the active preset's VALUES before the rebuild. SET_PRESETS arrives
  -- whenever the list changes at all - including when a schedule event is added
  -- - so re-applying on every rebuild would run the preset the moment it is
  -- scheduled and undo any manual change on the next list update.
  local activeBefore = HOLD_PRESET or SCHEDULED_PRESET
  local signatureBefore = presetSignature(PRESETS[activeBefore])

  PRESETS = {}
  for _, preset in pairs(xml.ChildNodes) do
    local attrs = preset.Attributes
    local name = attrs and attrs["name"]
    if not IsEmpty(name) then
      PRESETS[name] = parsePresetFields(attrs["preset_fields"])

      -- A rename must carry the tracked names across, or the running schedule
      -- silently detaches from the preset it is holding.
      local previous = attrs["previous_name"]
      if not IsEmpty(previous) then
        if SCHEDULED_PRESET == previous then
          SCHEDULED_PRESET = name
        end
        if HOLD_PRESET == previous then
          HOLD_PRESET = name
        end
      end
    end
  end

  -- Re-apply ONLY when the values of the preset already driving the device
  -- actually changed. Anything else - a new preset, a schedule event, a rename,
  -- an unrelated edit - leaves the device alone; SET_EVENT runs the schedule and
  -- SET_PRESET runs a preset on demand.
  local activeAfter = HOLD_PRESET or SCHEDULED_PRESET
  if activeAfter ~= nil and PRESETS[activeAfter] ~= nil and signatureBefore ~= nil then
    local signatureAfter = presetSignature(PRESETS[activeAfter])
    if signatureAfter ~= signatureBefore then
      log:info("Active preset '%s' was edited; re-applying", activeAfter)
      applyPreset(activeAfter)
    end
  end
end

--- User selected a preset directly; it holds until the next scheduled event.
function RFP.SET_PRESET(idBinding, strCommand, tParams)
  log:trace("RFP.SET_PRESET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local name = Select(tParams, "NAME")
  if IsEmpty(name) then
    -- An empty name clears a held preset rather than naming one.
    HOLD_PRESET = nil
    setHoldMode("Off")
    return
  end
  if applyPreset(name) then
    HOLD_PRESET = name
    SCHEDULED_PRESET = nil
    setHoldMode("Off")
  end
end

--- Run the event that has just come due: adopt it as the scheduled preset,
--- release any hold (that is what "until next event" means), then re-arm.
local function fireScheduledEvent(event)
  log:info("Scheduled event due: '%s'", event.preset)
  if PRESETS[event.preset] == nil then
    log:warn("Scheduled event names an unknown preset '%s'; nothing applied", event.preset)
  else
    SCHEDULED_PRESET = event.preset
    HOLD_PRESET = nil
    applyPreset(event.preset)
    setHoldMode("Off")
  end
  armScheduleTimer()
end

--- Arm a single-shot timer for the next event. Re-armed after every firing and
--- whenever the schedule changes, so only one timer ever exists.
armScheduleTimer = function()
  if SCHEDULE_TIMER then
    SCHEDULE_TIMER:Cancel()
    SCHEDULE_TIMER = nil
  end
  if #SCHEDULE == 0 then
    return
  end
  local event, seconds = nextScheduledEvent(os.time())
  if event == nil then
    return
  end
  log:info("Next scheduled event '%s' in %d seconds", event.preset, seconds)
  SCHEDULE_TIMER = C4:SetTimer(seconds * 1000, function()
    SCHEDULE_TIMER = nil
    fireScheduledEvent(event)
  end, false)
end

--- The full preset schedule. The proxy sends this whenever the schedule changes
--- and expects a driver whose device cannot keep time to run it locally: it
--- emits SET_EVENT only when the ACTIVE scheduled preset changes, so an event
--- that re-selects the preset already in force produces no notification at all.
--- Leaving this unhandled means the schedule silently never runs.
function RFP.SET_EVENTS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_EVENTS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local xml = C4:ParseXml(Select(tParams, "XML"))
  SCHEDULE = {}
  if xml ~= nil and xml.ChildNodes ~= nil then
    for _, node in pairs(xml.ChildNodes) do
      local attrs = node.Attributes or {}
      local preset = attrs["preset"]
      local weekday = tointeger(attrs["weekday"])
      local hour = tointeger(attrs["hour"])
      local minute = tointeger(attrs["minute"])
      if not IsEmpty(preset) and weekday ~= nil and hour ~= nil and minute ~= nil then
        SCHEDULE[#SCHEDULE + 1] = { preset = preset, weekday = weekday, hour = hour, minute = minute }
      else
        log:warn("Skipping malformed schedule event: %s", attrs)
      end
    end
  end
  log:info("Schedule updated: %d event(s)", #SCHEDULE)
  persist:set("Schedule", SCHEDULE)
  armScheduleTimer()
end

--- Sent when the proxy decides which preset should be in force NOW - on a
--- schedule edit as well as at an event boundary. Applying it is correct in
--- both cases; the local timer covers the boundaries the proxy stays quiet for.
function RFP.SET_EVENT(idBinding, strCommand, tParams)
  log:trace("RFP.SET_EVENT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local name = Select(tParams, "PRESET")
  if IsEmpty(name) or PRESETS[name] == nil then
    log:warn("Scheduled event named an undefined preset: %s", tostring(name))
    return
  end
  -- RECORD ONLY - deliberately does not apply, matching Control4's own
  -- Residential Thermostat V2 ("Proxy said we should be in scheduled preset" ->
  -- it just stores the name). The proxy sends this whenever the schedule is
  -- SAVED as well as at a boundary, so applying here changes the device the
  -- instant a schedule is created. The local timer owns every application.
  log:info("Proxy says the schedule's current preset is '%s'", name)
  SCHEDULED_PRESET = name
end

function RFP.SET_MODE_HOLD(idBinding, strCommand, tParams)
  log:trace("RFP.SET_MODE_HOLD(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local mode = Select(tParams, "MODE")
  if IsEmpty(mode) then
    return
  end
  if mode == "Off" then
    -- Releasing a hold returns to whatever the schedule last asked for.
    if SCHEDULED_PRESET ~= nil then
      HOLD_PRESET = nil
      applyPreset(SCHEDULED_PRESET)
    end
  else
    -- Learn the proxy's own wording for a hold so anything this driver raises
    -- later uses the identical string.
    if mode ~= HOLD_UNTIL_NEXT then
      log:info("Proxy calls a hold '%s'; using that from now on", mode)
      HOLD_UNTIL_NEXT = mode
    end
  end
  setHoldMode(mode)
end

--- Handle swing mode selection via extras
function RFP.SET_MODE_SWING(idBinding, strCommand, tParams)
  log:trace("RFP.SET_MODE_SWING(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING or (ENTITY and ENTITY.is_water_heater) then
    return
  end
  -- An extras object can name its parameter via param_name (Control4's own
  -- thermostat does: param_name="TemperatureSensor" arrives as
  -- tParams.TemperatureSensor). Ours does not declare one, so the value comes
  -- through as "value" - accept either rather than depend on that default.
  local mode = Select(tParams, SWING_EXTRA_ID) or Select(tParams, "value")
  if IsEmpty(mode) then
    log:warn("SET_MODE_SWING carried no value: %s", tParams)
    return
  end
  local swingMode = C4_TO_CLIMATE_SWING_MODE[mode]
  if swingMode == nil then
    log:warn("Unknown swing mode: %s", mode)
    return
  end
  sendClimateCommand({
    has_swing_mode = true,
    swing_mode = swingMode,
  })
  -- Echo the selection so the Extras UI settles immediately; the device's own
  -- state report is still authoritative and will overwrite this if it differs.
  SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", {
    XML = '<extras_state><extra><object id="' .. SWING_EXTRA_ID .. '" value="' .. mode .. '"/></extra></extras_state>',
  }, "NOTIFY")
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
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
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
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")

  -- Send capabilities on first state update
  if not CAPABILITIES_SENT then
    sendCapabilities(entity)
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

  -- Presets: highlight whatever the current state matches, then decide whether
  -- the user has diverged from the scheduled preset (hold) or returned to it.
  if not entity.is_water_heater then
    matchAnyPreset()
    reconcileHold()
  end

  -- Swing mode (climate only) - reflected back into the Extras selector
  if not entity.is_water_heater then
    -- Absent means OFF (protobuf drops zero values), so without this default the
    -- selector would never be told the vane had stopped.
    local swingMode = tointeger(Select(state, "swing_mode"))
    if swingMode == nil and entity.supported_swing_modes ~= nil and #entity.supported_swing_modes > 0 then
      swingMode = ESPHomeProtoSchema.Enum.ClimateSwingMode.CLIMATE_SWING_OFF
    end
    if swingMode ~= nil then
      local c4SwingMode = CLIMATE_SWING_MODE_TO_C4[swingMode]
      if c4SwingMode ~= nil then
        SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", {
          XML = '<extras_state><extra><object id="'
            .. SWING_EXTRA_ID
            .. '" value="'
            .. c4SwingMode
            .. '"/></extra></extras_state>',
        }, "NOTIFY")
      end
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

  -- Water heater modes via extras. custom_preset carries the water heater's
  -- operating mode, synthesized by the bridge, NOT a device preset. Keep every
  -- read of it behind is_water_heater: a climate entity can advertise a custom
  -- preset of the same name, and only the gate tells the two apart.
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
