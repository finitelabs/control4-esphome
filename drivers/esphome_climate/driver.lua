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
--- The proxy's own wording for a hold. Learned at runtime and restored from
--- persist in OnDriverLateInit, so it has to be in scope before that function is
--- defined. Its default, and why it is learned at all, live with the hold
--- helpers further down.
local HOLD_UNTIL_NEXT

--- Resolve a float the device may have omitted.
---
--- Protobuf leaves a zero-valued field out of the frame, so an absent float is
--- either "not reported" or "reported as exactly zero". The enums already
--- resolve that ambiguity in stateEnum; the floats did not, so 0.0 C and 0 %
--- were dropped and a preset at zero could never match. Absence means zero for a
--- dimension the device actually has, and nothing for one it does not.
---
--- A field that IS present but non-finite is a placeholder, not a reading: the
--- firmware initialises these to NaN and reports them until a real value
--- arrives. Those still return nil.
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

--- Preset schedule, as delivered by SET_EVENTS. The proxy keeps the clock and
--- announces each event through SET_EVENT; the list is kept here only so the
--- driver knows whether a schedule exists at all - the hold modes are offered
--- while one does - and persisted so a reload can offer them before the proxy
--- resends the list.
--- @type table[] Array of { preset = string, weekday = 0-6, hour = 0-23, minute = 0-59 }
local SCHEDULE = {}
--- Preset the proxy most recently had the schedule apply (SET_EVENT).
--- Declared HERE, beside SCHEDULE, because OnDriverLateInit restores it from
--- persist. Declared any lower and that restore compiles as a write to a
--- GLOBAL of the same name while every consumer reads this nil local.
local SCHEDULED_PRESET = nil
--- Set when the proxy announced a scheduled preset that could not be applied at
--- the time - device absent, or preset not yet delivered - so the next door
--- applies it.
local EVENT_PENDING = false
--- Forward-declared because it is assigned below HOLD_UNTIL_NEXT, which it
--- publishes, and called from sendCapabilities, which is defined long before
--- it.
local publishHoldModes
--- Digest of the schedule as it would be written, and the last digest actually
--- written. Both are forward-declared because OnDriverLateInit seeds the digest
--- from the restored schedule, and the helper that computes it lives with the
--- schedule code far below that function.
local scheduleSignature
local SCHEDULE_SIGNATURE = nil
-- Declared HERE, above OnDriverLateInit, because that is where the persisted
-- list is restored. Declared any lower and the restore compiles as a write to a
-- GLOBAL of the same name while every consumer reads this nil local.
local PRESETS = {}
local PRESETS_SIGNATURE = nil

--- Stable digest of the whole preset list, for the persist dedupe.
--- Names are sorted so an unchanged list always yields the same string
--- regardless of pairs() order. Every token is length-prefixed and each preset
--- carries its field count, so no two lists digest alike: without the count,
--- one preset with fields b,d,f,h read as the same token stream as three
--- presets a={b}, d={e}, g={h}.
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
--- Assigned with the schedule handlers further down, but called from
--- SET_PRESETS, which is defined before them.
local runPendingEvent

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
  -- XMLEncode from drivers-common-public escapes the same five entities in the
  -- same order, and is already required at the top of this file. It returns
  -- non-strings untouched, so coerce before handing it over.
  return XMLEncode(tostring(value))
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

  -- A lone "Off" is not a choice; match the Extras selector, which only
  -- appears when the device offers somewhere to swing to.
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
  -- can_preset defaults to false in driver.xml and is turned on here, once an
  -- entity is actually attached. The SDK marks can_preset and
  -- can_preset_schedule alike as changeable through DYNAMIC_CAPABILITIES_CHANGED,
  -- and both are published from here.
  -- Water heaters are excluded. The preset field template below is climate
  -- shaped and is not published for them, so declaring CAN_PRESET would serve the
  -- static driver.xml template instead: heat/cool setpoints, HVAC modes and swing
  -- on a device that has none of them. Applying one is a wire level no-op, since
  -- the parent defaults a command-less body to water_heater_command and the
  -- climate shaped body serialises with no fields set. Matching is already gated
  -- off for water heaters, so it would never be announced either.
  setpointCaps.CAN_PRESET = not entity.is_water_heater
  -- CAN_PRESET_SCHEDULE has to be published here too, not left to driver.xml.
  -- The static declaration does not reach the proxy: on a live controller the
  -- Schedule UI was absent entirely with can_preset_schedule True in the
  -- manifest, and appeared the moment this notification was sent. Control4's own
  -- KNX thermostat driver pushes both flags together for the same reason. This
  -- is the static-declaration trap that PRESET_FIELDS_CHANGED below already
  -- works around.
  setpointCaps.CAN_PRESET_SCHEDULE = not entity.is_water_heater
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", setpointCaps, "NOTIFY")

  -- The allowed hold modes are the third member of that same family, and were
  -- never published at all: the proxy's HOLD_MODES_LIST read "-" on a live
  -- controller while the HVAC and fan lists beside it, both pushed at runtime,
  -- were populated. Control4's own driver ties them to preset scheduling -
  -- "hold modes only have sence if preset scheduing is enabled" - so a device
  -- that cannot hold a preset is offered none.
  if not entity.is_water_heater then
    publishHoldModes(true)
  end

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

  -- HAS_EXTRAS was only ever published as true, so a node reflashed from a mini
  -- split to a water heater with no operating modes kept the climate Swing
  -- selector until something else cleared it - and SET_MODE_SWING silently
  -- returns for a water heater. Same class as CAN_PRESET: the capability has to
  -- track the device.
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
      extrasPublished = true
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

  if not extrasPublished then
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_EXTRAS = false }, "NOTIFY")
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
  -- persist:get hands back its EMPTY sentinel TABLE for a missing key, never
  -- nil, so this needs an explicit emptiness test. Left bare, a fresh install
  -- gives SET_MODE_HEAT a restoreMode of {} which passes its "~= nil" check,
  -- skips the fallback mode search, and sends a table where an enum belongs:
  -- Heat silently never engages.
  local storedWaterHeaterMode = persist:get("LastWaterHeaterMode")
  if storedWaterHeaterMode == nil or type(storedWaterHeaterMode) == "table" then
    LAST_WATER_HEATER_MODE = nil
  else
    LAST_WATER_HEATER_MODE = storedWaterHeaterMode
  end
  REMOTE_SENSOR_IN_USE = persist:get("RemoteSensorInUse", false) == true

  -- The proxy's hold wording is learned from the first hold it sends, and the
  -- driver echoes it back for every hold it raises itself. Without this restore
  -- a reload republishes the DEFAULT wording, so a proxy that calls a hold
  -- "Next Event" is offered a mode it does not use and the hold control goes
  -- dead until the user raises one by hand.
  -- Stored as a TABLE: Serialize leaves a bare string untouched, and
  -- Deserialize cannot reliably read one back.
  local storedHoldWording = persist:get("HoldWording")
  if type(storedHoldWording) == "table" and type(storedHoldWording.mode) == "string" then
    HOLD_UNTIL_NEXT = storedHoldWording.mode
  end

  -- The schedule decides whether hold modes are offered, and the proxy only
  -- resends it once a device connects; restoring it lets a reload offer them
  -- straight away.
  -- Explicit {} defaults: persist:get with no default returns its shared EMPTY
  -- sentinel BY REFERENCE for a missing key, so inserting into the result would
  -- corrupt every other key in the store.
  SCHEDULE = persist:get("Schedule", {})
  PRESETS = persist:get("Presets", {})
  -- Seed both dedupe digests from what was just restored. Left nil, the first
  -- SET_PRESETS and SET_EVENTS after every reload compare against nothing and
  -- write the same content straight back, so every reload cost two flash writes
  -- for lists that had not changed.
  SCHEDULE_SIGNATURE = scheduleSignature()
  PRESETS_SIGNATURE = presetListSignature(PRESETS)
  -- The preset the proxy last had the schedule apply. Restored so a hold can be
  -- reconciled against it from the first report after a reload, and so the
  -- proxy's re-announcement of that same preset on connect is recognised as
  -- one the device already has. Stored as a TABLE for the same reason
  -- HoldWording is. Cleared by writing an EMPTY table, never by deleting the
  -- key: on a live controller a delete issued from the proxy-command path,
  -- followed by a write of this key from that same path, left the key
  -- unreadable after the write (reproduced twice, OS 3.3.3) while the same
  -- sequence from a timer was fine. An empty marker needs no delete at all.
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

--- Preset name -> field table, as delivered by the proxy in SET_PRESETS.
--- Preset selected directly by the user; holds until the next scheduled event.
local HOLD_PRESET = nil
--- Hold mode last reported, so only real transitions are sent. Starts as nil
--- rather than "Off" so the first reconcile after a load always publishes. On a
--- reload the proxy keeps whatever it was last told while this driver comes up
--- with no view at all; seeding the believed value to "Off" makes the equality
--- guard in setHoldMode swallow the one report that would have corrected it, so
--- a hold that ended during the reload stays on screen until the next
--- transition, which may never come.
local HOLD_MODE = nil
--- Allowed hold modes as last published, so a schedule edit that does not
--- change whether a schedule EXISTS does not re-send an identical list. The
--- proxy resends SET_EVENTS on every reconnect and on every edit.
local HOLD_MODES_PUBLISHED = nil
--- Preset last reported as active, so only real transitions are sent. A
--- distinct sentinel rather than nil, because nil is itself a legitimate
--- reported value - "no preset matches". Seeding this to nil makes the equality
--- guard in matchAnyPreset swallow the first report after a reload, leaving the
--- app highlighting a preset the device has since left. Same reasoning as
--- HOLD_MODE above.
local UNREPORTED = {}
local ACTIVE_PRESET = UNREPORTED
--- A hold the USER asked for through SET_MODE_HOLD, as opposed to one this
--- driver raised because state diverged from the schedule. The two look
--- identical to the proxy but must not be released the same way: a divergence
--- hold ends when state returns to the scheduled preset, while a user hold ends
--- only when the user releases it or the next scheduled event arrives. Without
--- this, raising a hold from the UI without changing anything is cancelled by
--- the very next state report, since state still matches the scheduled preset.
local USER_HOLD = false
--- Signature of the schedule as last written to persistent storage. Every device
--- reconnect makes the proxy resend SET_EVENTS, and persist:set does not dedupe,
--- so without this a flaky device causes one flash write per reconnect for
--- content that never changed.
--- Set while a scheduled preset has been commanded but the device has not yet
--- confirmed it. A report landing in that window still describes the OLD state,
--- so reconciling against it raises a hold and then immediately drops it: two
--- spurious programmable events per boundary. Same race the preset announcement
--- already avoids by only reporting what the device confirms.
local AWAITING_SCHEDULED = false

--- The proxy's own name for "hold until the next scheduled event". Control4's
--- Residential Thermostat V2 handles "Next Event" while other shipping drivers
--- use "Until Next", and the proxy declares no canonical list. Rather than pick
--- one and be wrong, learn it from the first hold the proxy sends and echo that
--- back; the declared hold_modes value is only the starting guess.
HOLD_UNTIL_NEXT = "Until Next"

--- The one hold that is meant to outlive a schedule. Every other hold runs until
--- the next scheduled event, so without a schedule there is nothing to release
--- it; this one is deliberate and is released by the user or by programming.
--- The name is fixed - it is not learned - because the proxy's hold list names
--- it explicitly alongside Off, 2 Hours and Until Next.
local HOLD_PERMANENT = "Permanent"

--- Holds that are NOT "until the next scheduled event". The driver learns the
--- proxy's wording for that one hold from the first hold it is sent, and these
--- are the names that must never be mistaken for it: a proxy that sets a two
--- hour hold would otherwise teach the driver to call every hold it raises
--- itself "2 Hours". Names taken from the proxy's own hold list.
local HOLD_NOT_UNTIL_NEXT = {
  ["Off"] = true,
  [HOLD_PERMANENT] = true,
  ["2 Hours"] = true,
  ["4 Hour"] = true,
  ["24 Hour"] = true,
  ["Hold Until"] = true,
}

--- Publish the hold modes the proxy should offer. With no schedule there is
--- nothing for a hold to be "until": reconcileHold returns at its first line
--- while SCHEDULED_PRESET is nil, so the driver cannot raise or release a hold
--- at all, and offering the modes would be offering a control that does
--- nothing. Control4's own thermostat withdraws them the same way, sending an
--- empty list when its event list is empty.
--- Assigned to the forward declaration up beside scheduleSignature, because
--- sendCapabilities calls it. Assigned any higher and it would not see
--- HOLD_UNTIL_NEXT.
---
--- @param force boolean Publish even if the list has not changed. Set on a new
--- connection, which is the one moment the dedupe must not win: a reload comes
--- up with this state empty and the proxy holding whatever it was last told,
--- and the schedule restored from persist arrives without a SET_EVENTS to
--- announce it. Control4's own thermostat re-asserts its hold state on the same
--- trigger rather than trusting the proxy to have kept it.
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

--- Write a preset's setpoints into a climate command body.
--- Two-point devices always use low/high regardless of mode, matching
--- SET_SETPOINT_HEAT/COOL; single-setpoint devices use target_temperature.
--- Round a preset setpoint onto the entity's own step before sending it.
--- The preset template authors at 0.5 C while a device may quantise to 1 C, so
--- 21.5 goes out and 22 comes back. matchPreset allows only 0.25 C, so the
--- preset never matches again: the hold sticks on permanently and the preset
--- stops highlighting. Snapping to the step the device declared makes the echo
--- match what was asked for.
local function snapToStep(value)
  -- Same fallback the resolution publisher and the setpoint step reader use.
  -- Reading only the visual field would leave a device that reports just
  -- target_temperature_step unsnapped, keeping the quantisation bug alive for it.
  local step = ENTITY ~= nil and tonumber(ENTITY.visual_target_temperature_step or ENTITY.target_temperature_step)
    or nil
  if value == nil or step == nil or step <= 0 then
    return value
  end
  return math.floor(value / step + 0.5) * step
end

local function applyPresetSetpoints(preset, body)
  if ENTITY ~= nil and ENTITY.supports_two_point_target_temperature then
    -- Field ids are the proxy's, per the DriverWorks thermostat_v2 preset_fields
    -- sample: heat_setpoint_[cf] / cool_setpoint_[cf]. The proxy auto-fills
    -- whichever scale the template omits, so reading either one is enough.
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

  -- Single target_temperature on the device, but the preset may still carry a
  -- heat/cool pair: presets saved before this driver reported the device as
  -- single-setpoint keep the field ids they were saved with. Collapse them onto
  -- the one target, the same way SET_SETPOINT_HEAT/COOL already do.
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
  -- Nothing can be applied with the device gone: the bridge rejects
  -- ENTITY_COMMAND while disconnected and only logs it. Saying so here, rather
  -- than firing into the void, is what stops the caller reporting a change that
  -- never happened - a hold against a preset the device never received, and an
  -- HVAC_MODE_CHANGED for a mode it never entered. A scheduled preset already
  -- waits on this same test before it reaches here; a preset chosen by hand has
  -- no equivalent, and the UI withholds its controls while disconnected, so this
  -- path is reached from programming.
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
      -- The rest of the preset still applies. Silence here made a preset that
      -- names Auto on a device offering neither of the two modes Auto maps to
      -- look like it had worked, with the setpoint moving and the mode not.
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

  -- Belt and braces against the water heater path. CAN_PRESET is withheld from
  -- water heaters so the proxy should never ask, but a climate shaped body sent
  -- to one serialises against WaterHeaterCommandRequest with nothing set: a
  -- silent no-op that looks like a working preset. Refuse it out loud instead.
  if ENTITY ~= nil and ENTITY.is_water_heater then
    log:warn("Preset '%s' not applied: presets are not offered for water heaters", name)
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
    -- Same zero-omission rule as the report path: a preset at exactly 0 has to
    -- be able to match. ENTITY is the authority on which dimensions exist.
    local actual = stateFloat(STATE, stateKey, ENTITY ~= nil)
    -- Compare against the SNAPPED value, because that is what was sent. The
    -- preset editor authors at the template's 0.5 resolution while a device may
    -- quantise to 1, so a stored 21.5 goes out as 22 and comes back as 22.
    -- Comparing the raw 21.5 fails by 0.5 against a 0.25 tolerance and the
    -- preset never matches again: the hold sticks on and the preset stops
    -- highlighting. Snapping only the outgoing command does not fix that,
    -- because the symptom lives entirely on this side.
    -- Both transforms applyPresetSetpoints uses outbound, in the same order.
    -- Snapping alone is not enough: a preset outside the device's range is
    -- commanded at the clamp boundary and echoes that value back, so comparing
    -- the unclamped number wedges the hold on exactly the way the unsnapped one
    -- did.
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

--- Highlight whichever preset current state matches, so a preset the user
--- reached by hand still shows as active. Reported only on a transition, the
--- same shape as setHoldMode: repeating the current preset on every state report
--- is noise, and leaving the last match standing once state moves off it leaves
--- the app highlighting a preset the device has already left.
--- How many fields a preset pins down. Two presets can both match the same
--- state when one is a subset of the other - both say Heat 22, one also says fan
--- Quiet - and the one that says more is the one actually in force.
local function presetFieldCount(name)
  local count = 0
  for _ in pairs(PRESETS[name] or {}) do
    count = count + 1
  end
  return count
end

local function matchAnyPreset()
  -- Deliberate order, not hash order. pairs() walks the table in whatever order
  -- the hash lands in, and PRESETS is rebuilt on every SET_PRESETS, so with two
  -- matching presets the winner changed between rebuilds and PRESET_CHANGED
  -- flapped between two names while the device did nothing at all.
  --
  -- The order states what is actually in force: a preset the user is holding,
  -- then the one the schedule put there, then the most specific match, and a
  -- name sort last so even a tie is stable across rebuilds.
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
  local onSchedule = matchPreset(SCHEDULED_PRESET)

  -- Suppress exactly ONE report after a scheduled preset is commanded. That
  -- report is the stale one, describing the state before the device moved;
  -- reconciling against it raises a hold the confirmation drops a moment later,
  -- which is two spurious programmable events per boundary.
  --
  -- The bound matters more than the suppression. Waiting for a report that
  -- MATCHES the scheduled preset looks tighter but wedges: a device that never
  -- lands exactly on the preset (setpoint quantisation is enough) would leave
  -- this set forever and holds would never work again. One report cannot wedge.
  if AWAITING_SCHEDULED then
    AWAITING_SCHEDULED = false
    return
  end

  if onSchedule then
    -- A hold the user asked for outlives a match. They may have raised it
    -- without changing anything, in which case state matches the schedule from
    -- the first report; only the user or the next scheduled event ends it.
    if not USER_HOLD then
      setHoldMode("Off")
    end
  else
    setHoldMode(HOLD_UNTIL_NEXT)
  end
end

--- Receive the full preset list. The proxy sends every preset each time, so
--- this rebuilds rather than merges.
--- Signature of the schedule as it would be written. Extracted from SET_EVENTS
--- so a rename can re-persist through the same dedupe rather than duplicating
--- the encoding.
scheduleSignature = function()
  local parts = {}
  for _, e in ipairs(SCHEDULE) do
    parts[#parts + 1] = string.format("%s|%s|%s|%s", e.weekday, e.hour, e.minute, e.preset)
  end
  return table.concat(parts, ";")
end

--- Write the schedule only when it actually changed. Every device reconnect
--- makes the proxy resend SET_EVENTS and persist:set does not dedupe, so an
--- unconditional write is one flash write per reconnect for content that has
--- not changed.
local function persistSchedule()
  local signature = scheduleSignature()
  if signature ~= SCHEDULE_SIGNATURE then
    SCHEDULE_SIGNATURE = signature
    persist:set("Schedule", SCHEDULE)
  end
end

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

  local scheduleRenamed = false
  PRESETS = {}
  for _, preset in pairs(xml.ChildNodes) do
    local attrs = preset.Attributes
    local name = attrs and attrs["name"]
    if not IsEmpty(name) then
      -- A preset whose fields are all empty, or whose preset_fields will not
      -- parse, constrains nothing. matchPreset skips every nil field and ends in
      -- "return true", so storing one would make it match EVERY state: it would
      -- win PRESET_CHANGED on pairs order, and a schedule holding it could never
      -- see divergence, which silently kills the hold for that schedule.
      -- applyPreset already refuses this shape; refuse to store it as well.
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
          -- The persisted copy is what a reload compares the proxy's next
          -- announcement against; left under the old name, the first
          -- announcement after a reload re-commands a preset already in force.
          if not EVENT_PENDING then
            persist:set("ScheduledPreset", { preset = name })
          end
        end
        if HOLD_PRESET == previous then
          HOLD_PRESET = name
        end
        -- The SCHEDULE entries carry the preset name too. The proxy resends
        -- SET_EVENTS after a rename, but until it does the driver's own copy
        -- names a preset that no longer exists and is persisted that way.
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

  -- A preset that no longer exists cannot be held or scheduled. Left pointing
  -- at a deleted preset, matchPreset returns false forever, so reconcileHold
  -- raises a hold on every state report and releasing it re-applies a preset
  -- the driver does not have - a hold no UI action can clear. The
  -- schedule-emptied branch in SET_EVENTS is the only other clearing path and
  -- it requires the WHOLE schedule to be gone, which is not this case.
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
  -- Only when something was actually forgotten, and only once there is no
  -- scheduled preset left: reconcileHold returns at its first line in that
  -- state, so nothing else can ever take the hold back down.
  if forgot and SCHEDULED_PRESET == nil then
    setHoldMode("Off")
  end

  -- Re-apply ONLY when the values of the preset already driving the device
  -- actually changed. Anything else - a new preset, a schedule event, a rename,
  -- an unrelated edit - leaves the device alone; SET_EVENT runs the schedule and
  -- SET_PRESET runs a preset on demand.
  -- Presets are proxy-owned configuration, and the proxy only resends the list
  -- once a device is attached. Without persisting them, a reload during an
  -- outage came up with an empty preset table, and the preset the proxy
  -- announced on reconnect could not be applied by name.
  -- Compare before writing, for the same reason the schedule write does: the
  -- proxy resends this list on every reconnect and on any schedule edit, and
  -- persist:set does not dedupe, so an unconditional write is one flash write per
  -- reconnect for content that has not changed.
  local presetsSignature = presetListSignature(PRESETS)
  if presetsSignature ~= PRESETS_SIGNATURE then
    PRESETS_SIGNATURE = presetsSignature
    persist:set("Presets", PRESETS)
  end

  -- A preset the proxy announced before the list arrived is applied now that
  -- it has. This is the only retry: the re-apply path below needs
  -- signatureBefore, which cannot exist after a reload.
  if runPendingEvent() then
    return
  end

  local activeAfter = HOLD_PRESET or SCHEDULED_PRESET
  if activeAfter ~= nil and PRESETS[activeAfter] ~= nil and signatureBefore ~= nil then
    local signatureAfter = presetSignature(PRESETS[activeAfter])
    if signatureAfter ~= signatureBefore then
      log:info("Active preset '%s' was edited; re-applying", activeAfter)
      local applied = applyPreset(activeAfter)
      if activeAfter == SCHEDULED_PRESET then
        -- Suppress a report only when a command went out. A refused apply -
        -- the device is down - sends nothing, so the edit is left pending for
        -- the device-back door rather than lost, with the one swallowed report
        -- then hiding the divergence behind a hold the user never raised.
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
    -- An empty name clears a held preset rather than naming one. Releasing the
    -- hold returns to whatever the schedule last asked for, the same restore
    -- SET_MODE_HOLD Off performs: Control4's own thermostat re-applies the
    -- scheduled preset's values when a preset hold is disabled, because the
    -- device sends no change-of-state for the values the hold was masking.
    HOLD_PRESET = nil
    USER_HOLD = false
    setHoldMode("Off")
    if SCHEDULED_PRESET ~= nil then
      applyPreset(SCHEDULED_PRESET)
    end
    return
  end
  if applyPreset(name) then
    -- SCHEDULED_PRESET deliberately survives. A preset chosen by hand is a HOLD
    -- on that preset, not a replacement for the schedule: Control4's own
    -- thermostat writes a preset-hold event and leaves its scheduled preset
    -- alone, then restores it when the hold ends. Clearing it here used to
    -- disable hold reporting altogether, because reconcileHold returns at its
    -- first line while SCHEDULED_PRESET is nil, and left SET_MODE_HOLD Off with
    -- nothing to restore.
    HOLD_PRESET = name
    -- Marked as the user's hold so a state report that happens to match the
    -- scheduled preset does not release it. Selecting the preset the schedule
    -- already has in force is exactly that case, and it must still read as a
    -- hold - Control4's thermostat forces the hold on every preset-hold
    -- acknowledgement for the same reason.
    USER_HOLD = true
    -- Only when there is a schedule to hold against. With no events the hold
    -- modes have been withdrawn, so reporting one would name a mode the proxy
    -- was told it does not have, and there is no "next" for it to run until.
    if #SCHEDULE > 0 then
      setHoldMode(HOLD_UNTIL_NEXT)
    else
      USER_HOLD = false
      setHoldMode("Off")
    end
  end
end

--- Apply the preset the proxy says the schedule has in force. Control4's own
--- thermostat driver reads SET_EVENT as "the proxy said we should be in
--- scheduled preset" and keeps the last name so it can be applied once the
--- hardware is back; this does the same. Releases any hold, because a new
--- event is what "until next event" waits for, then suppresses one stale
--- report the way a commanded change has to. Returns false when it cannot
--- apply yet - device absent, or preset not delivered - and the event stays
--- pending for runPendingEvent.
--- @return boolean applied
local function runScheduledEvent()
  local name = SCHEDULED_PRESET
  if name == nil or ENTITY == nil or PRESETS[name] == nil then
    return false
  end
  if ENTITY.is_water_heater then
    -- A schedule inherited from a climate entity names presets a water heater
    -- is never offered. Drop it rather than command the heater with them.
    log:info("Scheduled preset '%s' does not apply to a water heater; ignoring", name)
    EVENT_PENDING = false
    return true
  end
  EVENT_PENDING = false
  HOLD_PRESET = nil
  USER_HOLD = false
  -- Only suppress a report when a command actually went out. A refused apply
  -- sends nothing, so the next report is not the stale one this suppression
  -- exists for, and swallowing it loses a real divergence.
  AWAITING_SCHEDULED = applyPreset(name)
  setHoldMode("Off")
  persist:set("ScheduledPreset", { preset = name })
  return true
end

--- Apply a scheduled preset that could not be applied when the proxy announced
--- it. Both halves have to be present - the preset list and the device - and
--- either can arrive last, so this is called from both doors: SET_PRESETS when
--- the list lands, and UPDATE_STATE when the device comes back.
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
  -- Parse BEFORE clearing. An unparsable frame is not an empty schedule: read as
  -- one it wipes the stored schedule, forgets the scheduled preset, withdraws
  -- the hold modes, and the driver's copy is wrong until the proxy happens to
  -- resend it. Deleting every event arrives as a
  -- well-formed <events></events>, which still parses, so refusing garbage costs
  -- the user nothing. SET_PRESETS already guards its rebuild this way.
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

  -- With no events there is nothing for a hold to be "until". Forget the preset
  -- the schedule last put in force, or every later divergence raises "Until
  -- Next" against a schedule that no longer exists and releasing the hold
  -- re-applies a preset nobody scheduled. A hold this driver raised ends with
  -- the schedule; one the user asked for is theirs to release.
  if #SCHEDULE == 0 then
    if SCHEDULED_PRESET ~= nil then
      log:info("Schedule emptied; '%s' is no longer the scheduled preset", SCHEDULED_PRESET)
      SCHEDULED_PRESET = nil
      EVENT_PENDING = false
      AWAITING_SCHEDULED = false
      persist:set("ScheduledPreset", {})
    end
    -- Release the hold with the schedule, the user's included. Deleting the last
    -- event removes the only thing that could end it: reconcileHold returns at
    -- its first line without a scheduled preset, and the hold modes are
    -- withdrawn on the next line, so the thermostat shows no control to release
    -- it with. A hold the user raised was still a hold until the NEXT event, and
    -- there is no longer one. Permanent is the deliberate exception, kept
    -- because it never depended on a schedule.
    local holding = USER_HOLD or HOLD_PRESET ~= nil or (HOLD_MODE ~= nil and HOLD_MODE ~= "Off")
    if holding and HOLD_MODE ~= HOLD_PERMANENT then
      log:info("Schedule emptied; releasing the hold that had nothing left to run until")
      USER_HOLD = false
      HOLD_PRESET = nil
      setHoldMode("Off")
    end
  end

  persistSchedule()
  -- The first schedule ever saved is what makes a hold meaningful, and deleting
  -- the last event is what makes it meaningless again. Neither moment produces
  -- a reconnect, so the list has to be re-published here as well as in
  -- sendCapabilities - and gated the same way, since a water heater is never
  -- offered a hold.
  if not (ENTITY and ENTITY.is_water_heater) then
    publishHoldModes()
  end
end

--- The proxy's word on which preset the schedule has in force. It sends this
--- when a schedule is saved, at every boundary where the scheduled preset
--- changes, and again on every connection; it stays silent at a boundary that
--- re-selects the preset already in force. The proxy keeps the clock; this
--- driver applies what it announces. An announcement of the preset already
--- applied - the resend on every connect - is left alone, so a hold the user
--- raised is not undone by a reconnect.
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
    -- Clear the held preset whether or not a schedule exists. Leaving it set
    -- means a later edit to that preset is still pushed to the device through
    -- the activeAfter path in SET_PRESETS, despite the hold having been
    -- released. The empty-NAME path in SET_PRESET already clears it
    -- unconditionally; this branch was the asymmetric one.
    HOLD_PRESET = nil
    -- Releasing a hold returns to whatever the schedule last asked for.
    --
    -- Deliberately NOT one-report-suppressed the way a scheduled boundary is. A
    -- stale push here can flap the hold once, but suppressing a report on this
    -- path also swallows a genuine divergence made immediately after a release,
    -- which is the behaviour three tests assert and which users actually rely
    -- on. The flap self-corrects on the next report; a missed hold does not.
    if SCHEDULED_PRESET ~= nil then
      applyPreset(SCHEDULED_PRESET)
    end
  elseif #SCHEDULE == 0 and mode ~= HOLD_PERMANENT then
    -- Any hold but Permanent runs until the next scheduled event, and with no
    -- events there is no next event to end it: reconcileHold returns at its
    -- first line without a scheduled preset, and the hold modes have been
    -- withdrawn so the UI offers no control either. Accepting it would strand a
    -- hold nothing can clear. SET_PRESET already refuses on the same test.
    log:warn("Refusing hold '%s' with no schedule; nothing could release it", tostring(mode))
    USER_HOLD = false
    setHoldMode("Off")
    return
  else
    -- Remember that this hold came from the user. reconcileHold must not release
    -- it just because state happens to match the scheduled preset.
    USER_HOLD = true
    -- Learn the proxy's own wording for a hold so anything this driver raises
    -- later uses the identical string. Only from a hold that actually means
    -- "until the next event": a timed or permanent hold carries a different
    -- name, and adopting one would have the driver report every hold it raises
    -- as a two hour or permanent hold.
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
  -- A scheduled preset commanded but not yet confirmed when the device dropped
  -- may never have arrived. Its name is already persisted as applied, so the
  -- proxy's re-announcement on reconnect would be read as a repeat; mark it
  -- pending instead and the device-back door sends it again.
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

  -- The device was the missing half of a pending scheduled preset. Apply it
  -- here rather than waiting for a SET_PRESETS that may never come: a reconnect
  -- is not guaranteed to make the proxy resend the preset list.
  runPendingEvent()

  -- tofinite rather than tonumber on every reading below. ESPHome initialises
  -- each climate float to NaN and reports it as-is until the device supplies a
  -- value, so a head in the seconds after boot - or one that never measures
  -- humidity - sends NaN on every frame. JSON turns a NaN into null on its way
  -- over the bridge, but infinity survives, and a direct caller sees both.
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
    -- Unreachable while the invariant holds: sendCapabilities runs a few lines
    -- above this on every connection and sets IS_SINGLE_SETPOINT to exactly
    -- `not supports_two_point_target_temperature`, so one of the two branches
    -- above always takes it. Kept as a named guard rather than dead routing
    -- code, so a future change that breaks the invariant says so instead of
    -- silently reporting no setpoint at all.
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

  -- Swing mode (climate only) - reflected back into the Extras selector.
  -- Gated on MORE THAN ONE mode, matching the condition that publishes the
  -- selector in the first place. A device advertising only CLIMATE_SWING_OFF
  -- gets no selector, so echoing state for it emitted EXTRAS_STATE_CHANGED on
  -- every state push, for an object that was never declared and with no
  -- transition guard.
  -- Counted after mapping, because that is what publishes the selector: the map
  -- drops values it does not know and collapses duplicates, so a raw count can
  -- be greater than one while the selector was never declared. Inlined rather
  -- than calling buildPresetFieldsXml's local "mapped", which is not in scope
  -- here and would resolve to a nil global.
  local swingChoices, seenSwing = {}, {}
  for _, raw in ipairs(entity.supported_swing_modes or {}) do
    local mappedName = CLIMATE_SWING_MODE_TO_C4[raw]
    if mappedName ~= nil and not seenSwing[mappedName] then
      seenSwing[mappedName] = true
      swingChoices[#swingChoices + 1] = mappedName
    end
  end
  if not entity.is_water_heater and #swingChoices > 1 then
    -- Absent means OFF (protobuf drops zero values), so without this default the
    -- selector would never be told the vane had stopped.
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
  -- Presets are deliberately NOT cleared here. They are user configuration owned
  -- by the proxy and attached to this item, not anything derived from the device,
  -- so repointing the driver at a different ESPHome entity leaves them valid. An
  -- earlier version discarded them on rebind, which wiped a user's saved presets
  -- every time the driver was updated, since an update cycles this binding.
  CAPABILITIES_SENT = false
  IS_SINGLE_SETPOINT = false
  LAST_WATER_HEATER_MODE = nil
  USER_SERVICES_DISCOVERED = false
  if isBound then
    SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
  else
    -- Losing the binding is losing the device. Without this the proxy keeps the
    -- IS_CONNECTED it was last given and the UI stays live for hardware that is
    -- now unreachable - the same failure this driver reports on every other
    -- disconnect path, on the one path an installer can trigger from Composer.
    updateStatus("Disconnected", false)
    SendToProxy(PROXY_BINDING, "CONNECTION", { CONNECTED = false }, "NOTIFY")
  end
end
