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
local HUMIDITY_OUTPUT_BINDING = 5011

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
--- The proxy's wording for a hold. Restored in OnDriverLateInit; default and
--- learning logic live with the hold helpers below.
local HOLD_UNTIL_NEXT

--- Resolve a float the device may have omitted. Protobuf leaves a zero-valued
--- field out of the frame, so an absent float means zero for a dimension the
--- entity declares and nothing for one it does not. A present but non-finite
--- value is ESPHome's "not measured yet" placeholder and returns nil.
--- @param source table The state table.
--- @param key string Field name.
--- @param declared boolean Whether the entity says it has this dimension.
--- @return number|nil
local function stateFloat(source, key, declared)
  local value = tofinite(Select(source, key))
  if value ~= nil then
    return value
  end
  if Select(source, key) ~= nil then
    return nil
  end
  if declared then
    return 0
  end
  return nil
end

-- Restored in OnDriverLateInit, so declared above it: a local declared below
-- that function would leave the restore writing a global.
--- Preset schedule from SET_EVENTS. The proxy keeps the clock and announces each
--- event through SET_EVENT; this copy only decides whether hold modes are offered,
--- and is persisted so a reload can offer them before the proxy resends the list.
--- @type table[] Array of { preset = string, weekday = 0-6, hour = 0-23, minute = 0-59 }
local SCHEDULE = {}
--- Preset the proxy most recently had the schedule apply (SET_EVENT).
local SCHEDULED_PRESET = nil
--- A scheduled preset the proxy announced that could not be applied yet (device
--- absent, or preset not yet delivered).
local EVENT_PENDING = false
local SCHEDULE_SIGNATURE = nil
local PRESETS = {}
local PRESETS_SIGNATURE = nil
-- Defined further down, beside the code they belong to.
local publishHoldModes
local scheduleSignature
local runPendingEvent

--- Stable digest of the preset list, for the persist dedupe. Names and keys are
--- sorted, tokens are length-prefixed, and each preset carries its field count
--- so distinct lists cannot digest alike.
--- @param presets table<string, table> The preset table.
--- @return string signature
local function presetListSignature(presets)
  local names = {}
  for name in pairs(presets) do
    names[#names + 1] = name
  end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    local fields = presets[name]
    local keys = {}
    for k in pairs(fields) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    parts[#parts + 1] = #name .. ":" .. name .. "#" .. #keys .. ";"
    for _, k in ipairs(keys) do
      local v = tostring(fields[k])
      parts[#parts + 1] = #k .. ":" .. k .. #v .. ":" .. v
    end
  end
  return table.concat(parts)
end

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

-- The device's own ESPHome presets are not mapped to proxy presets: the API
-- publishes which presets exist and which is active but never what one does,
-- and a device keeps reporting its preset after the user overrides it.

--- Temperature values are always sent in Celsius - ESPHome uses Celsius natively
--- and the proxy converts to the user's display scale based on the SCALE param.
local SCALE = "C"

--- Persist key for an installer's per-thermostat display-scale override.
local P_DISPLAY_SCALE = "DisplayScale"

--- The proxy and C4:GetTemperatureScale() disagree on spelling ("C" vs "Celsius"
--- vs "CELSIUS"), so both are reduced to a letter.
--- @param scale string|nil
--- @return string|nil scale "C", "F", or nil if unrecognized.
local function normalizeScale(scale)
  local first = tostring(scale or ""):sub(1, 1):upper()
  if first == "C" or first == "F" then
    return first
  end
  return nil
end

--- An installer override wins over the project scale. ESPHome is always Celsius
--- internally, so this only affects what Control4 displays.
--- @return string scale "C" or "F".
local function getDisplayScale()
  return normalizeScale(persist:get(P_DISPLAY_SCALE)) or normalizeScale(C4:GetTemperatureScale()) or "F"
end

--- thermostatV2 has no ONLINE_CHANGED. It tracks reachability through
--- CONNECTION/CONNECTED, which drives its IS_CONNECTED variable.
--- @param connected boolean
--- @return void
local function sendConnectionState(connected)
  SendToProxy(PROXY_BINDING, "CONNECTION", { CONNECTED = connected and "true" or "false" }, "NOTIFY")
end

--- @type string|nil
local REPORTED_SCALE = nil

--- The proxy defaults to Fahrenheit and never consults the project setting, so a
--- Celsius project shows Fahrenheit thermostats without this. Called on every
--- state update so a project scale change lands without a reconnect.
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
--- Per C4 docs, can_heat/can_cool/can_do_auto must all be false when has_single_setpoint is true.
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
  -- supports_two_point_target_temperature is the entity's own declaration: when
  -- false it holds exactly one target even if it offers both HEAT and COOL, as a
  -- mini-split does. The SDK requires can_heat, can_cool and can_do_auto to be
  -- false alongside has_single_setpoint; Auto still reaches the UI via hvac_modes.
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

--- Escape device-supplied text (custom fan mode names) for an XML attribute.
--- @param value any
--- @return string
local function xmlAttr(value)
  return XMLEncode(tostring(value))
end

--- Build the preset_fields template from what this entity supports. The proxy
--- serves the editor from whatever PRESET_FIELDS_CHANGED last pushed; the static
--- block in driver.xml is only a fallback. Setpoint fields follow the flag the
--- proxy runs on: heat/cool when dual, single otherwise.
--- @param entity table The entity data.
--- @param singleSetpoint boolean Whether the proxy is in single-setpoint mode.
--- @return string xml
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
    -- Only offer setpoints the device can act on: no heat setpoint without a
    -- HEAT mode.
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

  -- A lone "Off" is not a choice; same gate as the Extras selector.
  local swingNames = mapped(entity.supported_swing_modes, CLIMATE_SWING_MODE_TO_C4)
  if #swingNames > 1 then
    listField("swing", "Swing", swingNames)
  end

  parts[#parts + 1] = "</preset_fields>"
  return table.concat(parts)
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
  -- Preset capabilities are raised here once an entity is attached; the static
  -- driver.xml declarations do not reach the proxy for either flag. Water heaters
  -- get neither: the preset template is climate-shaped and a preset applied to a
  -- water heater serialises to an empty command.
  setpointCaps.CAN_PRESET = not entity.is_water_heater
  setpointCaps.CAN_PRESET_SCHEDULE = not entity.is_water_heater
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", setpointCaps, "NOTIFY")

  -- The static hold_modes list never reaches the proxy either.
  if not entity.is_water_heater then
    publishHoldModes(true)
  end

  -- The template must agree with the setpoint mode just published, or the
  -- preset editor has nothing to render.
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

  -- HAS_EXTRAS must track the device, so it is published false when nothing
  -- below claims it.
  local extrasPublished = false

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
      extrasPublished = true
      SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_EXTRAS = true }, "NOTIFY")
      -- An absent swing_mode is the zero value (OFF), not "unknown".
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
      extrasPublished = true
      SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_EXTRAS = true }, "NOTIFY")
      -- custom_preset is borrowed: a water heater publishes no presets, so the
      -- bridge carries its operating mode there (water_heater.lua). Every read
      -- of it is gated on is_water_heater because a climate entity can advertise
      -- a custom preset of the same name.
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

  if not extrasPublished then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_EXTRAS = false }, "NOTIFY")
  end

  -- The proxy only resends SET_PRESETS / SET_EVENT once the connection is
  -- announced.
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
  -- Restore persisted state. persist:get returns its EMPTY sentinel table for a
  -- missing key, never nil.
  local storedWaterHeaterMode = persist:get("LastWaterHeaterMode")
  if storedWaterHeaterMode == nil or type(storedWaterHeaterMode) == "table" then
    LAST_WATER_HEATER_MODE = nil
  else
    LAST_WATER_HEATER_MODE = storedWaterHeaterMode
  end
  REMOTE_SENSOR_IN_USE = persist:get("RemoteSensorInUse", false) == true

  -- Without this a reload republishes the default hold wording and a proxy that
  -- says "Next Event" is offered a mode it does not use. Stored as a table:
  -- Deserialize cannot reliably read back a bare string.
  local storedHoldWording = persist:get("HoldWording")
  if type(storedHoldWording) == "table" and type(storedHoldWording.mode) == "string" then
    HOLD_UNTIL_NEXT = storedHoldWording.mode
  end

  -- Explicit {} defaults: the shared EMPTY sentinel is returned by reference and
  -- must not be mutated.
  SCHEDULE = persist:get("Schedule", {})
  PRESETS = persist:get("Presets", {})
  -- Seed the dedupe digests so the first resend after a reload does not rewrite
  -- unchanged lists.
  SCHEDULE_SIGNATURE = scheduleSignature()
  PRESETS_SIGNATURE = presetListSignature(PRESETS)
  -- Restored so the first report after a reload can reconcile a hold, and so the
  -- proxy's re-announcement on connect reads as already in force. Cleared by
  -- writing an empty table, never by deleting the key: a delete followed by a
  -- write from the proxy-command path left the key unreadable (OS 3.3.3).
  local storedScheduled = persist:get("ScheduledPreset")
  if type(storedScheduled) == "table" and type(storedScheduled.preset) == "string" then
    SCHEDULED_PRESET = storedScheduled.preset
  end
  if #SCHEDULE > 0 then
    log:info("Restored %d scheduled event(s)", #SCHEDULE)
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
    local current = tofinite(Select(STATE, twoPointField)) or 0
    sendClimateCommand({ [hasTwoPointField] = true, [twoPointField] = clampTemperature(current + step) })
  else
    local current = tofinite(Select(STATE, "target_temperature")) or 0
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

--- Preset selected directly by the user; holds until the next scheduled event.
local HOLD_PRESET = nil
--- Hold mode last reported, so only transitions are sent. nil rather than "Off"
--- so the first reconcile after a reload always publishes: the proxy may still
--- show a hold that ended during the reload.
local HOLD_MODE = nil
--- Allowed hold modes as last published, to skip identical resends.
local HOLD_MODES_PUBLISHED = nil
--- Preset last reported as active, so only transitions are sent. A sentinel
--- rather than nil, since nil ("no preset") is itself a legitimate report that
--- must still publish once after a reload.
local UNREPORTED = {}
local ACTIVE_PRESET = UNREPORTED
--- A hold the user asked for, as opposed to one raised because state diverged
--- from the schedule. A divergence hold ends when state returns to the scheduled
--- preset; a user hold ends only when released or at the next scheduled event.
local USER_HOLD = false
--- Set while a scheduled preset has been commanded but not yet confirmed. The
--- next report still describes the old state and must not raise a hold.
local AWAITING_SCHEDULED = false

--- The proxy's name for "hold until the next scheduled event" varies ("Next
--- Event", "Until Next") and it declares no canonical list, so it is learned from
--- the first hold the proxy sends. The driver.xml hold_modes value is the
--- starting guess.
HOLD_UNTIL_NEXT = "Until Next"

--- The one hold that outlives a schedule; released only by the user or programming.
local HOLD_PERMANENT = "Permanent"

--- Hold names that must never be learned as the "until next" wording.
local HOLD_NOT_UNTIL_NEXT = {
  ["Off"] = true,
  [HOLD_PERMANENT] = true,
  ["2 Hours"] = true,
  ["4 Hour"] = true,
  ["24 Hour"] = true,
  ["Hold Until"] = true,
}

--- Publish the hold modes the proxy should offer. With no schedule there is
--- nothing for a hold to be "until", so none are offered.
--- @param force boolean Publish even if unchanged. Set on a new connection, when
--- the proxy may hold a stale list and the restored schedule arrives with no
--- SET_EVENTS to announce it.
publishHoldModes = function(force)
  local modes = #SCHEDULE > 0 and ("Off," .. HOLD_UNTIL_NEXT) or ""
  if modes == HOLD_MODES_PUBLISHED and not force then
    return
  end
  HOLD_MODES_PUBLISHED = modes
  log:info("Publishing allowed hold modes: '%s'", modes)
  SendToProxy(PROXY_BINDING, "ALLOWED_HOLD_MODES_CHANGED", { MODES = modes }, "NOTIFY")
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

--- Round a setpoint onto the entity's step. The preset editor authors at 0.5 C
--- while a device may quantise to 1 C; unsnapped, the echo never matches the
--- preset within matchPreset's tolerance.
local function snapToStep(value)
  local step = ENTITY ~= nil and tonumber(ENTITY.visual_target_temperature_step or ENTITY.target_temperature_step)
    or nil
  if value == nil or step == nil or step <= 0 then
    return value
  end
  return math.floor(value / step + 0.5) * step
end

--- Write a preset's setpoints into a climate command body. Two-point devices
--- use low/high regardless of mode, matching SET_SETPOINT_HEAT/COOL.
local function applyPresetSetpoints(preset, body)
  if ENTITY ~= nil and ENTITY.supports_two_point_target_temperature then
    -- The proxy auto-fills whichever scale the template omits, so reading either
    -- field is enough.
    local heat = presetSetpoint(preset, "heat_setpoint_c", "heat_setpoint_f")
    local cool = presetSetpoint(preset, "cool_setpoint_c", "cool_setpoint_f")
    if heat ~= nil then
      body.has_target_temperature_low = true
      body.target_temperature_low = clampTemperature(snapToStep(heat))
    end
    if cool ~= nil then
      body.has_target_temperature_high = true
      body.target_temperature_high = clampTemperature(snapToStep(cool))
    end
    return
  end

  -- A preset saved before this device was reported single-setpoint may still
  -- carry a heat/cool pair; collapse it onto the one target.
  local chosen = chooseSingleSetpoint(preset)
  if chosen ~= nil then
    body.has_target_temperature = true
    body.target_temperature = clampTemperature(snapToStep(chosen))
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
  -- The bridge rejects ENTITY_COMMAND while disconnected; refusing here keeps
  -- the caller from reporting a change that never happened.
  if ENTITY == nil then
    log:warn("Cannot apply preset '%s' while the device is disconnected", tostring(name))
    return false
  end

  local body = {}

  if preset.hvac_mode ~= nil then
    local mode = preset.hvac_mode == "Auto" and getAutoMode() or C4_TO_CLIMATE_MODE[preset.hvac_mode]
    if mode ~= nil then
      body.has_mode = true
      body.mode = mode
      SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = preset.hvac_mode }, "NOTIFY")
    else
      -- Apply the rest rather than fail silently.
      log:warn(
        "Preset '%s' asks for HVAC mode '%s', which this device does not offer; applying the rest",
        tostring(name),
        tostring(preset.hvac_mode)
      )
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

  -- CAN_PRESET is withheld from water heaters, and a climate body sent to one
  -- serialises with nothing set; refuse out loud rather than no-op.
  if ENTITY ~= nil and ENTITY.is_water_heater then
    log:warn("Preset '%s' not applied: presets are not offered for water heaters", name)
    return false
  end

  log:info("Applying preset '%s'", name)
  sendClimateCommand(body)
  -- No announcement here: matchAnyPreset is the only emitter. A device pushes
  -- ambient temperature through the same state message, so a report can land
  -- between the command and the device moving.
  return true
end

--- Does current device state match every field this preset defines?
--- Fields the preset leaves unset are not compared.
local function matchPreset(name)
  local preset = name ~= nil and PRESETS[name] or nil
  if preset == nil or IsEmpty(STATE) then
    return false
  end

  -- Protobuf omits zero-valued fields, so an absent enum means its zero value
  -- (mode OFF, swing OFF, fan ON), not "unknown".
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
    local actual = stateFloat(STATE, stateKey, ENTITY ~= nil)
    -- Compare against what was actually sent: the same snap and clamp as
    -- applyPresetSetpoints, or a quantised or out-of-range preset never matches
    -- its own echo.
    return actual ~= nil and math.abs(actual - clampTemperature(snapToStep(expected))) <= 0.25
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

--- How many fields a preset pins down; of two matching presets, the more
--- specific one is the one in force.
local function presetFieldCount(name)
  local count = 0
  for _ in pairs(PRESETS[name] or {}) do
    count = count + 1
  end
  return count
end

--- Highlight whichever preset current state matches, reported on transitions
--- only.
local function matchAnyPreset()
  -- Deliberate order: the held preset, then the scheduled one, then the most
  -- specific match with a name sort as tie-break, so the winner is stable across
  -- SET_PRESETS rebuilds.
  local matched = nil
  if HOLD_PRESET ~= nil and matchPreset(HOLD_PRESET) then
    matched = HOLD_PRESET
  elseif SCHEDULED_PRESET ~= nil and matchPreset(SCHEDULED_PRESET) then
    matched = SCHEDULED_PRESET
  else
    local names = {}
    for name in pairs(PRESETS) do
      names[#names + 1] = name
    end
    table.sort(names, function(a, b)
      local ca, cb = presetFieldCount(a), presetFieldCount(b)
      if ca ~= cb then
        return ca > cb
      end
      return a < b
    end)
    for _, name in ipairs(names) do
      if matchPreset(name) then
        matched = name
        break
      end
    end
  end
  if matched == ACTIVE_PRESET then
    return
  end
  ACTIVE_PRESET = matched
  -- "None" is what the proxy expects when no preset is in force.
  SendToProxy(PROXY_BINDING, "PRESET_CHANGED", { NAME = matched or "None" }, "NOTIFY")
end

--- Drop into "Until Next" when the user diverges from the scheduled preset, and
--- release the hold when state drifts back onto it. This is the whole hold UX.
local function reconcileHold()
  if SCHEDULED_PRESET == nil then
    return
  end
  local onSchedule = matchPreset(SCHEDULED_PRESET)

  -- Suppress exactly one report after a scheduled preset is commanded: it
  -- describes the state before the device moved. One report, not "until it
  -- matches", so a device that never lands exactly on the preset cannot wedge
  -- this.
  if AWAITING_SCHEDULED then
    AWAITING_SCHEDULED = false
    return
  end

  if onSchedule then
    -- A user hold outlives a match; only the user or the next scheduled event
    -- ends it.
    if not USER_HOLD then
      setHoldMode("Off")
    end
  else
    setHoldMode(HOLD_UNTIL_NEXT)
  end
end

--- Digest of the schedule, for the persist dedupe.
scheduleSignature = function()
  local parts = {}
  for _, e in ipairs(SCHEDULE) do
    parts[#parts + 1] = string.format("%s|%s|%s|%s", e.weekday, e.hour, e.minute, e.preset)
  end
  return table.concat(parts, ";")
end

--- Write the schedule only when it changed: the proxy resends SET_EVENTS on
--- every reconnect and persist:set does not dedupe.
local function persistSchedule()
  local signature = scheduleSignature()
  if signature ~= SCHEDULE_SIGNATURE then
    SCHEDULE_SIGNATURE = signature
    persist:set("Schedule", SCHEDULE)
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

  -- Snapshot the active preset's values before the rebuild so only a real edit
  -- re-applies; SET_PRESETS also arrives for unrelated list changes.
  local activeBefore = HOLD_PRESET or SCHEDULED_PRESET
  local signatureBefore = presetSignature(PRESETS[activeBefore])

  local scheduleRenamed = false
  PRESETS = {}
  for _, preset in pairs(xml.ChildNodes) do
    local attrs = preset.Attributes
    local name = attrs and attrs["name"]
    if not IsEmpty(name) then
      -- A preset with no usable fields would match every state; do not store it.
      local fields = parsePresetFields(attrs["preset_fields"])
      if next(fields) == nil then
        log:warn("Preset '%s' defines no usable fields; not stored", name)
      else
        PRESETS[name] = fields
      end

      -- A rename must carry the tracked names across, or the running schedule
      -- silently detaches from the preset it is holding.
      local previous = attrs["previous_name"]
      if not IsEmpty(previous) then
        if SCHEDULED_PRESET == previous then
          SCHEDULED_PRESET = name
          -- Keep the persisted copy under the new name, or the first announcement
          -- after a reload re-commands a preset already in force.
          if not EVENT_PENDING then
            persist:set("ScheduledPreset", { preset = name })
          end
        end
        if HOLD_PRESET == previous then
          HOLD_PRESET = name
        end
        -- The schedule entries carry the name too; until the proxy resends
        -- SET_EVENTS the stored copy would name a missing preset.
        for _, e in ipairs(SCHEDULE) do
          if e.preset == previous then
            e.preset = name
            scheduleRenamed = true
          end
        end
      end
    end
  end

  if scheduleRenamed then
    log:info("Rename reached the schedule; re-persisting it")
    persistSchedule()
  end

  -- A deleted preset cannot stay held or scheduled: matchPreset would fail
  -- forever and the resulting hold could never be cleared.
  local forgot = false
  if SCHEDULED_PRESET ~= nil and PRESETS[SCHEDULED_PRESET] == nil then
    log:info("Scheduled preset '%s' no longer exists; forgetting it", SCHEDULED_PRESET)
    SCHEDULED_PRESET = nil
    EVENT_PENDING = false
    AWAITING_SCHEDULED = false
    persist:set("ScheduledPreset", {})
    forgot = true
  end
  if HOLD_PRESET ~= nil and PRESETS[HOLD_PRESET] == nil then
    log:info("Held preset '%s' no longer exists; releasing the hold", HOLD_PRESET)
    HOLD_PRESET = nil
    USER_HOLD = false
    forgot = true
  end
  -- Only once nothing is scheduled; otherwise reconcileHold owns the hold.
  if forgot and SCHEDULED_PRESET == nil then
    setHoldMode("Off")
  end

  -- Persisted so a reload during an outage can still apply the preset the proxy
  -- announces on reconnect; deduped because the list is resent on every
  -- reconnect.
  local presetsSignature = presetListSignature(PRESETS)
  if presetsSignature ~= PRESETS_SIGNATURE then
    PRESETS_SIGNATURE = presetsSignature
    persist:set("Presets", PRESETS)
  end

  -- A preset the proxy announced before the list arrived is applied now.
  if runPendingEvent() then
    return
  end

  -- Re-apply only when the values of the preset driving the device changed.
  local activeAfter = HOLD_PRESET or SCHEDULED_PRESET
  if activeAfter ~= nil and PRESETS[activeAfter] ~= nil and signatureBefore ~= nil then
    local signatureAfter = presetSignature(PRESETS[activeAfter])
    if signatureAfter ~= signatureBefore then
      log:info("Active preset '%s' was edited; re-applying", activeAfter)
      local applied = applyPreset(activeAfter)
      if activeAfter == SCHEDULED_PRESET then
        -- Suppress a report only when a command went out; a refused apply stays
        -- pending for the device-back door.
        AWAITING_SCHEDULED = applied
        if not applied then
          EVENT_PENDING = true
        end
      end
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
    -- An empty name releases the held preset and returns to the scheduled one,
    -- which sends no change-of-state of its own.
    HOLD_PRESET = nil
    USER_HOLD = false
    setHoldMode("Off")
    if SCHEDULED_PRESET ~= nil then
      applyPreset(SCHEDULED_PRESET)
    end
    return
  end
  if applyPreset(name) then
    -- SCHEDULED_PRESET survives: a preset chosen by hand is a hold on top of the
    -- schedule, restored when the hold ends. It is the user's hold, so a report
    -- that matches the scheduled preset does not release it.
    HOLD_PRESET = name
    USER_HOLD = true
    -- With no schedule the hold modes are withdrawn and there is no "next" to
    -- run until.
    if #SCHEDULE > 0 then
      setHoldMode(HOLD_UNTIL_NEXT)
    else
      USER_HOLD = false
      setHoldMode("Off")
    end
  end
end

--- Apply the preset the proxy says the schedule has in force. Releases any hold
--- (a new event is what "until next" waits for), then suppresses one stale
--- report. Returns false when it cannot apply yet (device absent, or preset not
--- delivered) and leaves the event pending.
--- @return boolean applied
local function runScheduledEvent()
  local name = SCHEDULED_PRESET
  if name == nil or ENTITY == nil or PRESETS[name] == nil then
    return false
  end
  if ENTITY.is_water_heater then
    -- A schedule inherited from a climate entity; water heaters get no presets.
    log:info("Scheduled preset '%s' does not apply to a water heater; ignoring", name)
    EVENT_PENDING = false
    return true
  end
  EVENT_PENDING = false
  HOLD_PRESET = nil
  USER_HOLD = false
  -- Suppress a report only when a command actually went out.
  AWAITING_SCHEDULED = applyPreset(name)
  setHoldMode("Off")
  persist:set("ScheduledPreset", { preset = name })
  return true
end

--- Apply a pending scheduled preset. Called from both SET_PRESETS and
--- UPDATE_STATE, since either the preset list or the device can arrive last.
--- @return boolean true if a pending event was applied.
runPendingEvent = function()
  if not EVENT_PENDING then
    return false
  end
  local name = SCHEDULED_PRESET
  if runScheduledEvent() then
    log:info("Scheduled preset '%s' can be applied now", tostring(name))
    return true
  end
  return false
end

--- The full preset schedule, sent whenever it changes. Kept only to know whether
--- a schedule exists; the proxy runs it and announces each event via SET_EVENT.
function RFP.SET_EVENTS(idBinding, strCommand, tParams)
  log:trace("RFP.SET_EVENTS(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- Parse before clearing: an unparsable frame is not an empty schedule.
  -- Deleting every event arrives as a well-formed empty <events/>.
  local xml = C4:ParseXml(Select(tParams, "XML"))
  if xml == nil then
    log:warn("SET_EVENTS carried no parsable XML; the stored schedule stands")
    return
  end
  SCHEDULE = {}
  if xml.ChildNodes ~= nil then
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

  -- With no events there is nothing for a hold to be "until": forget the
  -- scheduled preset and release any hold but Permanent, which never depended
  -- on a schedule.
  if #SCHEDULE == 0 then
    if SCHEDULED_PRESET ~= nil then
      log:info("Schedule emptied; '%s' is no longer the scheduled preset", SCHEDULED_PRESET)
      SCHEDULED_PRESET = nil
      EVENT_PENDING = false
      AWAITING_SCHEDULED = false
      persist:set("ScheduledPreset", {})
    end
    local holding = USER_HOLD or HOLD_PRESET ~= nil or (HOLD_MODE ~= nil and HOLD_MODE ~= "Off")
    if holding and HOLD_MODE ~= HOLD_PERMANENT then
      log:info("Schedule emptied; releasing the hold that had nothing left to run until")
      USER_HOLD = false
      HOLD_PRESET = nil
      setHoldMode("Off")
    end
  end

  persistSchedule()
  -- Saving the first schedule or deleting the last changes what is offered
  -- without a reconnect, so republish here too.
  if not (ENTITY and ENTITY.is_water_heater) then
    publishHoldModes()
  end
end

--- The proxy's word on which preset the schedule has in force: sent on save, at
--- a boundary where the preset changes, and on every connection. A repeat of
--- the preset already applied is ignored so a reconnect does not undo a hold.
function RFP.SET_EVENT(idBinding, strCommand, tParams)
  log:trace("RFP.SET_EVENT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local name = Select(tParams, "PRESET")
  if IsEmpty(name) then
    log:warn("Scheduled event named no preset")
    return
  end
  if name == SCHEDULED_PRESET and not EVENT_PENDING then
    log:debug("Proxy repeats the scheduled preset '%s'; already in force", name)
    return
  end
  log:info("Proxy says the schedule's current preset is '%s'", name)
  SCHEDULED_PRESET = name
  EVENT_PENDING = true
  if not runScheduledEvent() then
    log:info(
      "Scheduled preset '%s' cannot be applied yet (%s); it will be when it can",
      name,
      ENTITY == nil and "device disconnected" or "preset not yet known"
    )
  end
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
    USER_HOLD = false
    -- Cleared even without a schedule, or a later edit to the preset is still
    -- pushed through SET_PRESETS.
    HOLD_PRESET = nil
    -- Return to whatever the schedule last asked for. Not one-report-suppressed:
    -- a stale push may flap the hold once, but suppression would swallow a real
    -- divergence made right after a release.
    if SCHEDULED_PRESET ~= nil then
      applyPreset(SCHEDULED_PRESET)
    end
  elseif #SCHEDULE == 0 and mode ~= HOLD_PERMANENT then
    -- Any hold but Permanent runs until the next scheduled event; with no events
    -- nothing could release it.
    log:warn("Refusing hold '%s' with no schedule; nothing could release it", tostring(mode))
    USER_HOLD = false
    setHoldMode("Off")
    return
  else
    USER_HOLD = true
    -- Learn the proxy's wording, but only from a hold that means "until next":
    -- a timed or permanent hold carries a different name.
    if mode ~= HOLD_UNTIL_NEXT and not HOLD_NOT_UNTIL_NEXT[mode] then
      log:info("Proxy calls a hold '%s'; using that from now on", mode)
      HOLD_UNTIL_NEXT = mode
      persist:set("HoldWording", { mode = mode })
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
  -- An extras object may name its parameter via param_name; ours does not, so
  -- the value arrives as "value". Accept either.
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

--- ESPHome has no device-side scale to push this to, so record it and report back.
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
  local current = tofinite(Select(STATE, "target_temperature")) or 0
  sendTargetTemperature(clampTemperature(current + step))
end

function RFP.DEC_SETPOINT_SINGLE(idBinding, strCommand)
  log:trace("RFP.DEC_SETPOINT_SINGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING or STATE == nil or ENTITY == nil then
    return
  end
  local step = getEntityTempStep()
  local current = tofinite(Select(STATE, "target_temperature")) or 0
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
  -- A scheduled preset commanded but unconfirmed when the device dropped may
  -- never have arrived; mark it pending so it is sent again on reconnect.
  if AWAITING_SCHEDULED then
    AWAITING_SCHEDULED = false
    if SCHEDULED_PRESET ~= nil then
      EVENT_PENDING = true
    end
  end
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
    sendDisplayScale()
  end

  -- The device may be the missing half of a pending scheduled preset; a
  -- reconnect does not guarantee a SET_PRESETS resend.
  runPendingEvent()

  -- ESPHome reports NaN for a float the device has not supplied yet, so every
  -- reading below goes through stateFloat.
  -- Current temperature
  local currentTemp = stateFloat(state, "current_temperature", entity.supports_current_temperature)
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
    local targetTemp = stateFloat(state, "target_temperature", true)
    if targetTemp ~= nil then
      SendToProxy(PROXY_BINDING, "SINGLE_SETPOINT_CHANGED", {
        SETPOINT = tostring(targetTemp),
        SCALE = SCALE,
      }, "NOTIFY")
    end
  elseif twoPoint then
    local targetLow = stateFloat(state, "target_temperature_low", true)
    local targetHigh = stateFloat(state, "target_temperature_high", true)
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
  elseif not twoPoint then
    -- Unreachable while sendCapabilities derives IS_SINGLE_SETPOINT from the
    -- same flag; kept so a broken invariant is loud.
    log:error("Setpoint mode is neither single nor dual; capabilities did not run before this report")
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

  -- Swing mode, reflected into the Extras selector only when one was published:
  -- more than one mapped mode, the same count sendCapabilities uses.
  local swingChoices, seenSwing = {}, {}
  for _, raw in ipairs(entity.supported_swing_modes or {}) do
    local mappedName = CLIMATE_SWING_MODE_TO_C4[raw]
    if mappedName ~= nil and not seenSwing[mappedName] then
      seenSwing[mappedName] = true
      swingChoices[#swingChoices + 1] = mappedName
    end
  end
  if not entity.is_water_heater and #swingChoices > 1 then
    -- Absent means OFF (protobuf drops zero values).
    local swingMode = tointeger(Select(state, "swing_mode"))
    if swingMode == nil then
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
  local currentHumidity = stateFloat(state, "current_humidity", entity.supports_current_humidity)
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
  local targetHumidity = stateFloat(state, "target_humidity", entity.supports_target_humidity)
  if targetHumidity ~= nil then
    SendToProxy(PROXY_BINDING, "HUMIDIFY_SETPOINT_CHANGED", {
      SETPOINT = tostring(math.floor(targetHumidity + 0.5)),
    }, "NOTIFY")
  end

  -- Water heater modes via extras; custom_preset carries the operating mode
  -- (see sendCapabilities), so keep every read behind is_water_heater.
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
  -- Presets are proxy-owned user configuration, not derived from the device, so
  -- a rebind (which an update cycles) must not clear them.
  CAPABILITIES_SENT = false
  IS_SINGLE_SETPOINT = false
  LAST_WATER_HEATER_MODE = nil
  USER_SERVICES_DISCOVERED = false
  if isBound then
    SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
  else
    -- Losing the binding is losing the device; otherwise the proxy keeps the last
    -- IS_CONNECTED and the UI stays live.
    updateStatus("Disconnected", false)
    SendToProxy(PROXY_BINDING, "CONNECTION", { CONNECTED = false }, "NOTIFY")
  end
end
