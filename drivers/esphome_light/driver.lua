--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_light.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
local persist = require("lib.persist")
local constants = require("constants")

local ESPHomeProtoSchema = require("esphome.proto_schema")

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

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------

local ON_BINDING = 300
local TOGGLE_BINDING = 301
local OFF_BINDING = 302
local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

---------------------------------------------------------------------------
-- ESPHome color modes that include brightness control
---------------------------------------------------------------------------

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_BRIGHTNESS = {
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_UNKNOWN] = false,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_ON_OFF] = false,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_LEGACY_BRIGHTNESS] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_BRIGHTNESS] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_WHITE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_RGB = {
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_CCT = {
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

---------------------------------------------------------------------------
-- Persist keys and defaults
---------------------------------------------------------------------------

local P_PRESET_LEVEL = "preset_level"
local P_CLICK_RATE_UP = "click_rate_up"
local P_CLICK_RATE_DOWN = "click_rate_down"
local P_HOLD_RATE_UP = "hold_rate_up"
local P_HOLD_RATE_DOWN = "hold_rate_down"
local P_RATE_DEFAULT = "brightness_rate_default"
local P_COLOR_RATE_DEFAULT = "color_rate_default"
local P_ON_MODE = "brightness_on_mode"
local P_BUTTON_COLORS = "button_colors"
local P_SCENES = "scenes"
local P_MAX_ON_LEVEL = "max_on_level"
local P_MIN_ON_LEVEL = "min_on_level"
local P_BRIGHTNESS_PRESETS = "brightness_presets"
local P_COLOR_PRESETS = "color_presets"
local P_COLOR_ON_MODE = "color_on_mode"
local P_PREVIOUS_COLOR = "previous_color"
local P_BRIGHTNESS_ON_MODE_PRESET = "brightness_on_mode_preset"
local P_COLOR_ON_MODE_PRESET = "color_on_mode_preset"

-- Color on-mode kinds. The proxy assigns presets with these origins/IDs to
-- distinguish dim-to-warm pairs from previous-color tracking.
local COLOR_ON_MODE_NONE = 0
local COLOR_ON_MODE_FADE = 1 -- Dim-To-Warm
local COLOR_ON_MODE_PREVIOUS = 2
local COLOR_ON_MODE_PRESET = 3

local SCENE_TIMER_PREFIX = "Scene_"
local SCENE_RAMP_TIMER = "SceneRamp"

local DEFAULT_PRESET_LEVEL = 100
local DEFAULT_CLICK_RATE = 500
local DEFAULT_HOLD_RATE = 3000
local DEFAULT_RATE = 500

local LIGHT_COLOR_MODE_FULL = 0
local LIGHT_COLOR_MODE_CCT = 1

-- D65 whitepoint, used as a sane chromaticity default before any state is known
local DEFAULT_COLOR_X = 0.3127
local DEFAULT_COLOR_Y = 0.3290

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local ENTITY
local STATE
local currentBrightness = 0
local ledState = false
local supportsDimming = false
local supportsColor = false
local supportsCCT = false
-- The bulb's supported_color_modes from ListEntitiesLightResponse. We pick
-- the most specific mode per cmd intent (CCT vs RGB) and set color_mode
-- explicitly so ESPHome doesn't have to infer from which fields we populate.
local supportedColorModes = {}
local minMireds = 153 -- ~6500K (cool)
local maxMireds = 500 -- ~2000K (warm)
local currentColorX = DEFAULT_COLOR_X
local currentColorY = DEFAULT_COLOR_Y
local currentColorMode = LIGHT_COLOR_MODE_CCT
local dynamicCapsSent = false

-- The driver owns brightness/color state during a ramp. ESPHome echoes
-- intermediate brightness values during a transition (one echo per command
-- received - they confirm the target of each command). We delegate the
-- physical ramp to ESPHome's native transition_length and track ramp metadata
-- locally for STOP-mid-ramp interpolation via C4:GetTime() (ms precision).
local rampingBrightness = false
local rampingColor = false

-- Ramp metadata: { startTime, startLevel, targetLevel, durationMs }. Cleared
-- when no ramp is in flight.
local brightnessRamp = nil
local colorRamp = nil

-- Snapshot of brightness captured when BUTTON_ACTION PRESS arrives. The proxy
-- sends PRESS on button-down and decides click vs hold ~110ms later. By the
-- time a RELEASE_CLICK arrives, our hold ramp may have stepped 1-2%; on click
-- we restore to this snapshot before running the click ramp so a brief hold
-- step never inverts the click outcome.
local prePressBrightness = nil

-- Set to true once a SET_COLOR_TARGET arrives during a single on-cycle. While
-- true, color_on_mode_fade does not recompute color from the brightness
-- formula. Cleared whenever brightness reaches 0 (the next on cycle is fresh
-- and should follow the formula again).
local fadeOverride = false

-- LIGHT_BRIGHTNESS_TARGET_PRESET_ID from the proxy (Daylight Agent integration,
-- spec _2.1). Echoed back as LIGHT_BRIGHTNESS_CURRENT_PRESET_ID on subsequent
-- LIGHT_BRIGHTNESS_CHANGED so the proxy knows the active preset still owns the
-- current level. Cleared by SET_LEVEL / button presses / scene steps that
-- aren't preset-driven.
local currentBrightnessPresetId = nil

-- LIGHT_COLOR_TARGET_PRESET_ID counterpart (spec _3.1).
local currentColorPresetId = nil

---------------------------------------------------------------------------
-- Driver lifecycle
---------------------------------------------------------------------------

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
  updateStatus("Disconnected", false)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

---------------------------------------------------------------------------
-- Property handlers
---------------------------------------------------------------------------

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
-- Helpers: entity capabilities
---------------------------------------------------------------------------

local function entitySupportsAnyMode(entity, modeTable)
  local modes = Select(entity, "supported_color_modes")
  if not IsList(modes) then
    return false
  end
  for _, mode in ipairs(modes) do
    if modeTable[mode] then
      return true
    end
  end
  return false
end

local function entitySupportsBrightness(entity)
  return entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_BRIGHTNESS)
end

local function entitySupportsColor(entity)
  return entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_RGB)
end

local function entitySupportsCCT(entity)
  return entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_CCT)
end

local function miredsToKelvin(m)
  if not m or m <= 0 then
    return 0
  end
  return math.floor(1e6 / m + 0.5)
end

local function kelvinToMireds(k)
  if not k or k <= 0 then
    return 0
  end
  return 1e6 / k
end

local function updateDynamicCapabilities(entity)
  if dynamicCapsSent then
    return
  end
  supportsDimming = entitySupportsBrightness(entity)
  supportsColor = entitySupportsColor(entity)
  supportsCCT = entitySupportsCCT(entity)
  supportedColorModes = {}
  local modes = Select(entity, "supported_color_modes")
  if IsList(modes) then
    for _, m in ipairs(modes) do
      supportedColorModes[m] = true
    end
  end
  -- Some ESPHome entities report 0/0 for mireds. Keep our XML defaults in that case
  -- so Composer's dialog doesn't get broken bounds.
  local entityMin = tonumber(Select(entity, "min_mireds"))
  local entityMax = tonumber(Select(entity, "max_mireds"))
  if entityMin and entityMin > 0 then
    minMireds = entityMin
  end
  if entityMax and entityMax > 0 then
    maxMireds = entityMax
  end

  log:info(
    "Entity caps: brightness=%s color=%s cct=%s mireds=[%.1f, %.1f]",
    tostring(supportsDimming),
    tostring(supportsColor),
    tostring(supportsCCT),
    minMireds,
    maxMireds
  )

  -- Emit the FULL set of dynamic capabilities (everything spec'd as
  -- "Dynamic Capability: Yes" in the LIGHT_V2 cap docs, plus dynamic-only
  -- caps from DYNAMIC_CAPABILITIES_CHANGED). Composer reads these at
  -- runtime to gate UI elements; the static driver.xml values are only
  -- the design-time defaults. Emitting the full set ensures Navigators
  -- and Composer test panels reflect the actual bulb's capabilities.
  local caps = {
    -- Brightness/dimmer
    dimmer = supportsDimming,
    set_level = supportsDimming,
    supports_target = supportsDimming,
    supports_brightness_stop = supportsDimming,
    ramp_level = supportsDimming, -- legacy 3.2-era cap; still gates test panel Ramp button
    has_fixed_ramp_rate = false,
    fixed_ramp_rate = 0,
    brightness_rate_min = 0,
    brightness_rate_max = 65535,
    -- Color
    supports_color = supportsColor,
    supports_color_correlated_temperature = supportsCCT,
    -- Misc
    has_extras = false,
    cold_start = false,
    color_trace_tolerance = 2, -- xy round-trip through HSV/RGB drifts ~1; use 2 for margin
  }
  if supportsCCT then
    -- CIE mireds invert vs Kelvin, so swap min/max during conversion.
    caps.color_correlated_temperature_min = miredsToKelvin(maxMireds)
    caps.color_correlated_temperature_max = miredsToKelvin(minMireds)
  end
  if supportsColor or supportsCCT then
    caps.color_rate_behavior = 1 -- ESPHome's transition_length applies to all aspects equally
    caps.color_rate_min = 0
    caps.color_rate_max = 65535
    caps.supports_color_stop = true
  else
    caps.supports_color_stop = false
  end
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", caps, "NOTIFY", true)

  -- Tell the proxy we have three virtual buttons (top/bottom/toggle). Sent as
  -- a string per the LIGHT_V2 NUMBER_BUTTONS notify format. Then emit a
  -- BUTTON_INFO for each so Composer's GET_SETUP can populate names.
  SendToProxy(PROXY_BINDING, "NUMBER_BUTTONS", "3", "NOTIFY")
  local buttonNames = {
    [constants.ButtonIds.TOP] = "Top",
    [constants.ButtonIds.BOTTOM] = "Bottom",
    [constants.ButtonIds.TOGGLE] = "Toggle",
  }
  for buttonId, name in pairs(buttonNames) do
    local colors = persist:get(P_BUTTON_COLORS) or {}
    local saved = colors[tostring(buttonId)] or {}
    SendToProxy(PROXY_BINDING, "BUTTON_INFO", {
      BUTTON_ID = buttonId,
      NAME = name,
      ON_COLOR = saved.on_color or "",
      OFF_COLOR = saved.off_color or "",
    }, "NOTIFY")
  end

  -- Re-emit the persisted preset level so the proxy is seeded after a reload.
  local presetLevel = tointeger(persist:get(P_PRESET_LEVEL))
  if presetLevel and presetLevel > 0 then
    SendToProxy(PROXY_BINDING, "PRESET_LEVEL", tostring(presetLevel), "NOTIFY")
  end

  -- Set last so a mid-function error retries on the next UPDATE_STATE rather
  -- than leaving the proxy with a half-applied capability set.
  dynamicCapsSent = true
end

---------------------------------------------------------------------------
-- Helpers: color conversions
---------------------------------------------------------------------------

-- HSV (h: 0-360, s: 0-100, v: 0-100) -> normalized RGB (each 0-1)
local function hsvToRGB(h, s, v)
  local sf, vf = (s or 0) / 100, (v or 0) / 100
  local c = vf * sf
  local hh = ((h or 0) / 60) % 6
  local x = c * (1 - math.abs((hh % 2) - 1))
  local m = vf - c
  local r, g, b = 0, 0, 0
  if hh < 1 then
    r, g, b = c, x, 0
  elseif hh < 2 then
    r, g, b = x, c, 0
  elseif hh < 3 then
    r, g, b = 0, c, x
  elseif hh < 4 then
    r, g, b = 0, x, c
  elseif hh < 5 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  return r + m, g + m, b + m
end

-- normalized RGB (0-1) -> HSV (h: 0-360, s: 0-100, v: 0-100)
local function rgbToHSV(r, g, b)
  r, g, b = r or 0, g or 0, b or 0
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then
      h = 60 * (((g - b) / d) % 6)
    elseif mx == g then
      h = 60 * ((b - r) / d + 2)
    else
      h = 60 * ((r - g) / d + 4)
    end
  end
  if h < 0 then
    h = h + 360
  end
  local s = mx > 0 and (d / mx) * 100 or 0
  return h, s, mx * 100
end

-- CIE 1931 xy chromaticity -> normalized RGB at full intensity.
-- Brightness is handled separately via the LIGHT_V2 brightness path.
local function xyToRGB(x, y)
  local h, s = C4:ColorXYtoHSV(x, y)
  local r, g, b = hsvToRGB(h or 0, s or 100, 100)
  return r, g, b
end

---------------------------------------------------------------------------
-- Helpers: persistence
---------------------------------------------------------------------------

-- Clamp the persisted preset to a usable on-level. The proxy may send 0 via
-- SET_PRESET_LEVEL during testing; treat anything < 1 as "use the default" so
-- a tap of On/Toggle doesn't end up turning the light off.
local function getPresetLevel()
  local v = tointeger(persist:get(P_PRESET_LEVEL))
  if not v or v < 1 then
    return DEFAULT_PRESET_LEVEL
  end
  return math.min(v, 100)
end

local function getOnBrightness()
  local onMode = persist:get(P_ON_MODE)
  local level = onMode and tointeger(onMode.level)
  if level and level >= 1 then
    return math.min(level, 100)
  end
  return getPresetLevel()
end

local function getDefaultRate()
  return persist:get(P_RATE_DEFAULT, DEFAULT_RATE)
end

-- ESPHome's transition_length applies to all aspects of a light_command
-- (brightness, color, color temperature) at the same time, so we declare
-- color_rate_behavior=1 ("Device only supports one rate for brightness and
-- color"). Composer in turn shows a single "Default Brightness and Color
-- Rate" setting; the brightness and color defaults are the same value. If
-- nothing has been persisted yet for color we fall back to the brightness
-- default rather than the hard-coded constant so the two can never drift.
local function getDefaultColorRate()
  local colorRate = persist:get(P_COLOR_RATE_DEFAULT)
  if colorRate ~= nil then
    return colorRate
  end
  return getDefaultRate()
end

local function getClickRateUp()
  return persist:get(P_CLICK_RATE_UP, DEFAULT_CLICK_RATE)
end

local function getClickRateDown()
  return persist:get(P_CLICK_RATE_DOWN, DEFAULT_CLICK_RATE)
end

local function getHoldRateUp()
  return persist:get(P_HOLD_RATE_UP, DEFAULT_HOLD_RATE)
end

local function getHoldRateDown()
  return persist:get(P_HOLD_RATE_DOWN, DEFAULT_HOLD_RATE)
end

local function getButtonColors(buttonId)
  local colors = persist:get(P_BUTTON_COLORS, {})
  local key = tostring(buttonId)
  if colors[key] then
    return colors[key].on_color or "0000ff", colors[key].off_color or "000000"
  end
  return "0000ff", "000000"
end

local function setButtonColors(buttonId, onColor, offColor)
  local colors = persist:get(P_BUTTON_COLORS, {})
  local key = tostring(buttonId)
  local existing = colors[key] or {}
  colors[key] = {
    on_color = onColor or existing.on_color or "0000ff",
    off_color = offColor or existing.off_color or "000000",
  }
  persist:set(P_BUTTON_COLORS, colors)
end

---------------------------------------------------------------------------
-- Helpers: ESPHome light commands
---------------------------------------------------------------------------

local function sendLightCommand(opts)
  log:debug("sendLightCommand(%s)", opts)
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe(opts),
  })
end

-- Pick the most specific ESPHome color mode the bulb supports for a given
-- intent ("cct" or "rgb"). Order matters: prefer single-purpose modes (RGB,
-- COLD_WARM_WHITE) over combined modes (RGB_COLOR_TEMPERATURE,
-- RGB_COLD_WARM_WHITE) because the bulb's behavior in single-purpose modes
-- is unambiguous. Returns nil if no compatible mode is supported.
local function pickColorMode(intent)
  local CM = ESPHomeProtoSchema.Enum.ColorMode
  local order
  if intent == "cct" then
    order = {
      CM.COLOR_MODE_COLD_WARM_WHITE,
      CM.COLOR_MODE_COLOR_TEMPERATURE,
      CM.COLOR_MODE_RGB_COLD_WARM_WHITE,
      CM.COLOR_MODE_RGB_COLOR_TEMPERATURE,
    }
  else
    order = {
      CM.COLOR_MODE_RGB,
      CM.COLOR_MODE_RGB_WHITE,
      CM.COLOR_MODE_RGB_COLOR_TEMPERATURE,
      CM.COLOR_MODE_RGB_COLD_WARM_WHITE,
    }
  end
  for _, m in ipairs(order) do
    if supportedColorModes[m] then
      return m
    end
  end
  return nil
end

-- Map a target Kelvin to a (cold_white, warm_white) channel split based on
-- the bulb's reported mireds range. Pure cold = (1, 0) at min_mireds; pure
-- warm = (0, 1) at max_mireds; linear blend between. Returned values are 0-1
-- floats matching ESPHome's per-channel scale.
local function kelvinToCoolWarmSplit(kelvin)
  local mireds = kelvinToMireds(kelvin)
  local span = maxMireds - minMireds
  if span <= 0 then
    return 0.5, 0.5
  end
  local ratio = math.max(0, math.min(1, (mireds - minMireds) / span))
  return 1 - ratio, ratio
end

-- Convert an XY/mode color into the right ESPHome cmd fields. Returns the
-- partial cmd table or nil if the bulb doesn't support color/CCT or the
-- provided values can't be mapped.
local function buildColorCmdFields(x, y, mode)
  if not (supportsColor or supportsCCT) or x == nil or y == nil then
    return nil
  end
  if mode == LIGHT_COLOR_MODE_CCT and supportsCCT then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if not k or k <= 0 then
      return nil
    end
    local fields = {
      has_color_temperature = true,
      color_temperature = kelvinToMireds(k),
    }
    -- Set color_mode explicitly so ESPHome doesn't have to infer.
    local pickedMode = pickColorMode("cct")
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    -- For RGBCW / cold-warm-white capable bulbs, also drive the cold/warm
    -- channels directly. ESPHome would compute these internally from
    -- color_temperature, but sending them ourselves removes ambiguity in
    -- min_mireds/max_mireds reading and keeps the channel split exactly
    -- where we expect it.
    local CM = ESPHomeProtoSchema.Enum.ColorMode
    if supportedColorModes[CM.COLOR_MODE_COLD_WARM_WHITE] or supportedColorModes[CM.COLOR_MODE_RGB_COLD_WARM_WHITE] then
      local cw, ww = kelvinToCoolWarmSplit(k)
      fields.has_cold_white = true
      fields.cold_white = cw
      fields.has_warm_white = true
      fields.warm_white = ww
    end
    return fields
  end
  if supportsColor then
    local r, g, b = xyToRGB(x, y)
    local fields = { has_rgb = true, red = r, green = g, blue = b }
    local pickedMode = pickColorMode("rgb")
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    return fields
  end
  return nil
end

-- Apply the dim-to-warm formula from spec _7.2:
--   colorFinal.x = colorDim.x + (colorOn.x - colorDim.x) * brightness*.01
--   colorFinal.y = colorDim.y + (colorOn.y - colorDim.y) * brightness*.01
-- The "On" color is the color at 100%, "Dim" is the color at 1%. We get
-- both via UPDATE_COLOR_ON_MODE (onPreset = on color, fadePreset = dim
-- color). Returns nil if either color is missing or fade mode isn't active.
local function computeFadeColor(brightness)
  local mode = persist:get(P_COLOR_ON_MODE)
  if not mode then
    return nil
  end
  local onPreset = mode.onPreset
  local dimPreset = mode.fadePreset
  if not onPreset or not dimPreset then
    return nil
  end
  if onPreset.x == nil or onPreset.y == nil or dimPreset.x == nil or dimPreset.y == nil then
    return nil
  end
  local b = math.max(0, math.min(100, brightness)) * 0.01
  return {
    x = dimPreset.x + (onPreset.x - dimPreset.x) * b,
    y = dimPreset.y + (onPreset.y - dimPreset.y) * b,
    mode = onPreset.mode or LIGHT_COLOR_MODE_FULL,
  }
end

-- Determine which color on-mode is currently active. Returns one of
-- COLOR_ON_MODE_* constants.
local function getColorOnModeKind()
  if not (supportsColor or supportsCCT) then
    return COLOR_ON_MODE_NONE
  end
  local mode = persist:get(P_COLOR_ON_MODE)
  if not mode or not mode.fadePreset then
    return COLOR_ON_MODE_NONE
  end
  local fadeOrigin = mode.fadePreset.origin
  if fadeOrigin and fadeOrigin > 0 then
    -- Origin > 0 indicates fade is enabled (spec _21: origin 1=device, 2=agent).
    return COLOR_ON_MODE_FADE
  end
  -- If no fade is configured but we have a stored previous color, treat as
  -- previous mode.
  if persist:get(P_PREVIOUS_COLOR) then
    return COLOR_ON_MODE_PREVIOUS
  end
  if mode.onPreset and mode.onPreset.x then
    return COLOR_ON_MODE_PRESET
  end
  return COLOR_ON_MODE_NONE
end

-- The bulb is "logically on" if either we already think it's on or a ramp
-- is in flight targeting an on-state. Used so a SET_COLOR_TARGET arriving
-- mid-ramp from off→on doesn't send state=false (which kills the brightness
-- fade by reverting the bulb to off).
local function isLogicallyOn()
  if rampingBrightness and brightnessRamp and (brightnessRamp.targetLevel or 0) > 0 then
    return true
  end
  return currentBrightness > 0
end

-- Determine the on-color to use when transitioning from off to on, based on
-- the active color on-mode. Returns {x, y, mode} or nil.
local function resolveOnColor(brightnessLevel)
  if not (supportsColor or supportsCCT) then
    return nil
  end
  local kind = getColorOnModeKind()
  if kind == COLOR_ON_MODE_FADE and not fadeOverride then
    return computeFadeColor(brightnessLevel)
  end
  if kind == COLOR_ON_MODE_PREVIOUS then
    local prev = persist:get(P_PREVIOUS_COLOR)
    if prev and prev.x and prev.y then
      return { x = prev.x, y = prev.y, mode = prev.mode or LIGHT_COLOR_MODE_FULL }
    end
  end
  if kind == COLOR_ON_MODE_PRESET then
    local mode = persist:get(P_COLOR_ON_MODE)
    local onPreset = mode and mode.onPreset
    if onPreset and onPreset.x and onPreset.y then
      return { x = onPreset.x, y = onPreset.y, mode = onPreset.mode or LIGHT_COLOR_MODE_FULL }
    end
  end
  return nil
end

-- Tracks a recent off→on cmd that already carried the on-color. The proxy
-- typically follows a SET_BRIGHTNESS_TARGET with a SET_COLOR_TARGET that
-- carries the same color it already set in our brightness cmd; we use this
-- timestamp to deduplicate and avoid sending a redundant ESPHome cmd that
-- would otherwise restart the in-flight transition.
local mergedColorUntil = 0

---------------------------------------------------------------------------
-- Helpers: brightness notifications
---------------------------------------------------------------------------

local function notifyBrightnessChanged(level)
  -- Snapshot the current color before the light goes off so color_on_mode_
  -- previous can restore it on the next on. Spec _7.4: "the proxy tracks the
  -- last color reported by a driver before a BRIGHTNESS_CHANGED notification
  -- occurs with a level of 0." We mirror that locally for non-proxy paths.
  if level == 0 and currentBrightness > 0 then
    persist:set(P_PREVIOUS_COLOR, {
      x = currentColorX,
      y = currentColorY,
      mode = currentColorMode,
    })
    -- A new on cycle is fresh: clear any prior dim-to-warm override so the
    -- formula is re-applied next time the light turns on. Also drop any
    -- color preset id; whatever drove the previous on-cycle's color no
    -- longer applies after the light returns to off.
    fadeOverride = false
    currentColorPresetId = nil
  end
  currentBrightness = level
  log:debug("LIGHT_BRIGHTNESS_CHANGED: %s", level)
  -- Echo back the preset id from the most recent SET_BRIGHTNESS_TARGET so the
  -- proxy / Daylight Agent (spec _10.2 / _2.1) knows the active preset still
  -- owns the current level. Nil keys are dropped from the table at construct
  -- time, so this is equivalent to omitting the field when no preset is set.
  SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGED", {
    LIGHT_BRIGHTNESS_CURRENT = level,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = currentBrightnessPresetId,
  }, "NOTIFY")
  local newLedState = level > 0
  if newLedState ~= ledState then
    ledState = newLedState
    -- MATCH_LED_STATE goes to each BUTTON_LINK binding (the keypad button
    -- LEDs), not to the LIGHT_V2 proxy binding. STATE is a Lua boolean per
    -- spec. Bottom is inverted: its LED lights when the light is OFF.
    SendToProxy(ON_BINDING, "MATCH_LED_STATE", { STATE = newLedState }, "NOTIFY", true)
    SendToProxy(OFF_BINDING, "MATCH_LED_STATE", { STATE = not newLedState }, "NOTIFY", true)
    SendToProxy(TOGGLE_BINDING, "MATCH_LED_STATE", { STATE = newLedState }, "NOTIFY", true)
  end
end

local function notifyBrightnessChanging(target, rate)
  log:debug("LIGHT_BRIGHTNESS_CHANGING: target=%s rate=%s", target, rate)
  SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGING", {
    LIGHT_BRIGHTNESS_CURRENT = currentBrightness,
    LIGHT_BRIGHTNESS_TARGET = target,
    RATE = rate,
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = currentBrightnessPresetId,
  }, "NOTIFY", true)
end

---------------------------------------------------------------------------
-- Helpers: color notifications
---------------------------------------------------------------------------

local function notifyColorChanged(x, y, mode)
  currentColorX = x
  currentColorY = y
  currentColorMode = mode
  log:debug("LIGHT_COLOR_CHANGED: x=%.4f y=%.4f mode=%s", x, y, mode)
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
    LIGHT_COLOR_CURRENT_PRESET_ID = currentColorPresetId,
  }, "NOTIFY")
end

local function notifyColorChanging(targetX, targetY, mode, rate)
  log:debug("LIGHT_COLOR_CHANGING: x=%.4f y=%.4f mode=%s rate=%s", targetX, targetY, mode, rate)
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_CURRENT_X = currentColorX,
    LIGHT_COLOR_CURRENT_Y = currentColorY,
    LIGHT_COLOR_CURRENT_COLOR_MODE = currentColorMode,
    LIGHT_COLOR_TARGET_X = targetX,
    LIGHT_COLOR_TARGET_Y = targetY,
    LIGHT_COLOR_TARGET_COLOR_MODE = mode,
    -- Spec _10.7 names this LIGHT_COLOR_TARGET_COLOR_RATE; some older docs
    -- and helper code use LIGHT_COLOR_TARGET_RATE so we send both for safety.
    LIGHT_COLOR_TARGET_COLOR_RATE = rate,
    LIGHT_COLOR_TARGET_RATE = rate,
    LIGHT_COLOR_TARGET_PRESET_ID = currentColorPresetId,
  }, "NOTIFY", true)
end

-- Caller contract: only invoked when supportsDimming is true (lightOn/Off,
-- rampToBrightness, scene apply, etc. all gate on it). On/off-only entities
-- get a different code path that doesn't touch brightness.
local function setESPHomeBrightness(level, rateMs)
  local hasRate = rateMs and rateMs > 0
  local goingOn = level > 0 and currentBrightness == 0

  -- Two-phase fade-up workaround. ESPHome's light_call short-circuits on
  -- state=false: brightness=0 in the same command is dropped, so the bulb's
  -- stored brightness stays at whatever it was last set to (often 1.0).
  -- When we then send state=true brightness=target with transition_length,
  -- ESPHome sees no brightness diff and the LED snaps on instead of fading.
  -- Pre-pushing a state=true brightness=ε with transition=0 sets the stored
  -- brightness to ~0 so the real ramp has a real diff to interpolate across.
  -- 0.0039 = 1/256 — the smallest 8-bit PWM step, visually indistinguishable
  -- from off. Using literal 0 risks ESPHome converting state=true brightness=0
  -- back into state=false.
  if goingOn and hasRate then
    sendLightCommand({
      has_state = true,
      state = true,
      has_brightness = true,
      brightness = 0.0039,
      has_transition_length = true,
      transition_length = 0,
    })
  end

  -- Always include both state AND brightness in the command. The brightness
  -- field is dropped by ESPHome when state=false (see workaround above), but
  -- including it for state=true is essential for the transition.
  local cmd = {
    has_state = true,
    state = level > 0,
    has_brightness = true,
    brightness = (level > 0) and (level / 100.0) or 0,
    has_transition_length = true,
    -- A rate of 0 still gets sent so it cancels any in-flight transition on
    -- the device rather than falling back to its default_transition_length.
    transition_length = hasRate and rateMs or 0,
  }

  -- Merge color into the brightness cmd so brightness+color animate as one
  -- ESPHome transition. Two scenarios:
  --   1. Dim-to-warm during any brightness change while fade mode is active
  --      and not overridden — recompute via the formula every step.
  --   2. Off→on with any color on-mode (fade/previous/preset) — apply the
  --      configured on-color in the same cmd. The proxy will typically also
  --      send a SET_COLOR_TARGET right after this; mergedColorUntil makes
  --      the SET_COLOR_TARGET handler skip a redundant ESPHome cmd that
  --      would otherwise cancel and restart the in-flight transition.
  local mergedColor = nil
  if level > 0 and not fadeOverride and getColorOnModeKind() == COLOR_ON_MODE_FADE then
    mergedColor = computeFadeColor(level)
  elseif goingOn then
    mergedColor = resolveOnColor(level)
  end
  local mergedColorApplied = false
  if mergedColor then
    local colorFields = buildColorCmdFields(mergedColor.x, mergedColor.y, mergedColor.mode)
    if colorFields then
      for k, v in pairs(colorFields) do
        cmd[k] = v
      end
      currentColorX = mergedColor.x
      currentColorY = mergedColor.y
      currentColorMode = mergedColor.mode
      mergedColorApplied = true
      -- Window during which a follow-up SET_COLOR_TARGET targeting the same
      -- color is treated as already applied. 250ms covers the proxy's
      -- typical inter-cmd gap (~6-50ms) with a margin.
      mergedColorUntil = C4:GetTime() + 250
      -- The merged color is computed from on-mode rules (fade/previous/
      -- on-preset), not from an explicit SET_COLOR_TARGET. Clear any
      -- lingering target-preset id so we don't echo a stale value. If the
      -- proxy follows up with a SET_COLOR_TARGET inside mergedColorUntil,
      -- that handler will set the correct id before brightnessRampFinished
      -- emits the terminal LIGHT_COLOR_CHANGED.
      currentColorPresetId = nil
      -- Stash on the ramp metadata so brightnessRampFinished can emit the
      -- terminal LIGHT_COLOR_CHANGED when the bulb's combined transition
      -- completes. The proxy needs CHANGING (now) + CHANGED (at finish) to
      -- keep its color-picker animation in sync.
      if brightnessRamp then
        brightnessRamp.mergedColor = {
          x = mergedColor.x,
          y = mergedColor.y,
          mode = mergedColor.mode,
        }
      end
    end
  end
  sendLightCommand(cmd)
  -- Emit color CHANGING/CHANGED to mirror the brightness side: the proxy
  -- doesn't always issue a SET_COLOR_TARGET (e.g. fade mode drives color
  -- from the formula, not from a separate proxy-initiated cmd), so the
  -- driver has to push these notifies for the picker to track.
  if mergedColorApplied then
    if hasRate then
      notifyColorChanging(currentColorX, currentColorY, currentColorMode, rateMs)
    else
      notifyColorChanged(currentColorX, currentColorY, currentColorMode)
    end
  end
end

---------------------------------------------------------------------------
-- Helpers: brightness ramping
---------------------------------------------------------------------------
-- ESPHome has native transition_length smoothing on the bulb itself. We send
-- a single light_command with the full rate, ESPHome handles the physical
-- ramp, and we track elapsed time locally so SET_BRIGHTNESS_STOP can
-- interpolate the device's current level mid-ramp using C4:GetTime() (ms).
--
-- ESPHome echoes one UPDATE_STATE per command it receives confirming the
-- target. During a ramp we ignore those echoes (rampingBrightness=true).
-- After the ramp ends we ignore brightness echoes for an additional grace
-- window in case stale echoes from a prior cmd arrive late and would
-- otherwise re-mutate currentBrightness and bounce the UI.

local function cancelBrightnessRampTimers()
  CancelTimer("BrightnessRampFinish")
end

local function interpolatedBrightness()
  if not brightnessRamp or brightnessRamp.durationMs <= 0 then
    return currentBrightness
  end
  local elapsed = C4:GetTime() - brightnessRamp.startTime
  if elapsed <= 0 then
    return brightnessRamp.startLevel
  end
  if elapsed >= brightnessRamp.durationMs then
    return brightnessRamp.targetLevel
  end
  local progress = elapsed / brightnessRamp.durationMs
  local span = brightnessRamp.targetLevel - brightnessRamp.startLevel
  return math.floor(brightnessRamp.startLevel + span * progress + 0.5)
end

local function brightnessRampFinished(targetLevel)
  cancelBrightnessRampTimers()
  -- Capture mergedColor before nilling brightnessRamp so we can emit a
  -- terminal LIGHT_COLOR_CHANGED for the color that piggybacked on this
  -- ramp's transition_length (off→on with a configured on-color).
  local mergedColor = brightnessRamp and brightnessRamp.mergedColor
  rampingBrightness = false
  brightnessRamp = nil
  notifyBrightnessChanged(targetLevel)
  if mergedColor then
    notifyColorChanged(mergedColor.x, mergedColor.y, mergedColor.mode)
  end
end

-- Halt the in-flight ESPHome transition at our interpolated current level.
local function brightnessRampStopped()
  cancelBrightnessRampTimers()
  if not rampingBrightness then
    return
  end
  local stoppedAt = interpolatedBrightness()
  rampingBrightness = false
  brightnessRamp = nil
  -- Cancel ESPHome's in-flight transition by sending a 0-transition cmd at
  -- the interpolated level. The bulb halts here.
  setESPHomeBrightness(stoppedAt, 0)
  currentBrightness = stoppedAt
  notifyBrightnessChanged(stoppedAt)
end

local function rampToBrightness(level, rate, presetId)
  level = math.max(0, math.min(100, math.floor((level or 0) + 0.5)))
  rate = math.max(0, tointeger(rate) or 0)

  log:debug("rampToBrightness(%s, %s) from %s", level, rate, currentBrightness)

  -- Single source of truth for the active brightness preset id. SET_BRIGHTNESS_
  -- TARGET passes the proxy's id through; everywhere else (buttons, scenes,
  -- lightOn, etc.) omits it so the id clears and CHANGED notifies don't echo
  -- a stale value to the Daylight Agent.
  currentBrightnessPresetId = presetId

  -- If a ramp is already running, snapshot the interpolated current level
  -- before starting the new ramp so CHANGING tracks correctly and a future
  -- STOP would interpolate from the right starting point.
  if rampingBrightness then
    currentBrightness = interpolatedBrightness()
  end

  cancelBrightnessRampTimers()
  rampingBrightness = false
  brightnessRamp = nil

  local startingLevel = currentBrightness
  if level == startingLevel then
    notifyBrightnessChanged(level)
    return
  end

  if rate == 0 then
    setESPHomeBrightness(level, 0)
    notifyBrightnessChanged(level)
    return
  end

  rampingBrightness = true
  brightnessRamp = {
    startTime = C4:GetTime(),
    startLevel = startingLevel,
    targetLevel = level,
    durationMs = rate,
  }
  -- Single ESPHome command - the bulb handles the physical transition.
  setESPHomeBrightness(level, rate)
  notifyBrightnessChanging(level, rate)
  SetTimer("BrightnessRampFinish", rate, function()
    -- Belt-and-suspenders: snap state with a 0-transition cmd at target so
    -- our state matches the bulb's even if the transition completed slightly
    -- before/after our timer.
    setESPHomeBrightness(level, 0)
    currentBrightness = level
    brightnessRampFinished(level)
  end, false)
end

---------------------------------------------------------------------------
-- Helpers: color ramping
---------------------------------------------------------------------------
-- Same shape as brightness ramping: send a single ESPHome light_command with
-- transition_length = rateMs so the bulb interpolates the physical color, and
-- track the logical color locally via a startTime/duration ramp record.

local function cancelColorRampTimers()
  CancelTimer("ColorRampFinish")
end

-- Build and send an ESPHome light_command reflecting the given color state.
local function sendColor(x, y, mode, rateMs)
  if not (supportsColor or supportsCCT) then
    return
  end
  -- isLogicallyOn so that a SET_COLOR_TARGET arriving mid-ramp from off→on
  -- doesn't send state=false (which would cancel the brightness transition).
  local cmd = { has_state = true, state = isLogicallyOn() }
  if mode == LIGHT_COLOR_MODE_CCT and supportsCCT then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if k and k > 0 then
      cmd.has_color_temperature = true
      cmd.color_temperature = kelvinToMireds(k)
    end
  elseif supportsColor then
    local r, g, b = xyToRGB(x, y)
    cmd.has_rgb = true
    cmd.red = r
    cmd.green = g
    cmd.blue = b
  end
  cmd.has_transition_length = true
  cmd.transition_length = (rateMs and rateMs > 0) and rateMs or 0
  sendLightCommand(cmd)
end

local function interpolatedColor()
  if not colorRamp or colorRamp.durationMs <= 0 then
    return currentColorX, currentColorY, currentColorMode
  end
  local elapsed = C4:GetTime() - colorRamp.startTime
  if elapsed <= 0 then
    return colorRamp.startX, colorRamp.startY, colorRamp.targetMode
  end
  if elapsed >= colorRamp.durationMs then
    return colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode
  end
  local progress = elapsed / colorRamp.durationMs
  local x = colorRamp.startX + (colorRamp.targetX - colorRamp.startX) * progress
  local y = colorRamp.startY + (colorRamp.targetY - colorRamp.startY) * progress
  return x, y, colorRamp.targetMode
end

local function colorRampFinished(targetX, targetY, targetMode)
  cancelColorRampTimers()
  rampingColor = false
  colorRamp = nil
  notifyColorChanged(targetX, targetY, targetMode)
end

local function colorRampStopped()
  cancelColorRampTimers()
  if not rampingColor then
    return
  end
  local x, y, mode = interpolatedColor()
  rampingColor = false
  colorRamp = nil
  sendColor(x, y, mode, 0)
  currentColorX = x
  currentColorY = y
  currentColorMode = mode
  notifyColorChanged(x, y, mode)
end

local function rampToColor(targetX, targetY, targetMode, rate)
  rate = math.max(0, tointeger(rate) or 0)

  if rampingColor then
    local x, y, _ = interpolatedColor()
    currentColorX = x
    currentColorY = y
  end

  cancelColorRampTimers()
  rampingColor = false
  colorRamp = nil

  if rate == 0 then
    currentColorX = targetX
    currentColorY = targetY
    currentColorMode = targetMode
    sendColor(targetX, targetY, targetMode, 0)
    notifyColorChanged(targetX, targetY, targetMode)
    return
  end

  rampingColor = true
  colorRamp = {
    startTime = C4:GetTime(),
    startX = currentColorX,
    startY = currentColorY,
    targetX = targetX,
    targetY = targetY,
    targetMode = targetMode,
    durationMs = rate,
  }
  -- Mode change is logically instantaneous; mid-ramp we're interpolating XY.
  currentColorMode = targetMode
  sendColor(targetX, targetY, targetMode, rate)
  notifyColorChanging(targetX, targetY, targetMode, rate)
  SetTimer("ColorRampFinish", rate, function()
    sendColor(targetX, targetY, targetMode, 0)
    currentColorX = targetX
    currentColorY = targetY
    currentColorMode = targetMode
    colorRampFinished(targetX, targetY, targetMode)
  end, false)
end

---------------------------------------------------------------------------
-- Helpers: on / off / toggle
---------------------------------------------------------------------------

local function lightOn(rate)
  local level = getOnBrightness()
  if not supportsDimming then
    sendLightCommand({ has_state = true, state = true })
    notifyBrightnessChanged(100)
    return
  end
  -- color_on_mode_previous/preset/fade are all handled by the merged-color
  -- path inside setESPHomeBrightness (via resolveOnColor on goingOn) so the
  -- color rides on the brightness transition as a single ESPHome cmd. Don't
  -- pre-send a separate color cmd here; that would queue two commands and
  -- the second would cancel and restart the in-flight transition.
  rampToBrightness(level, rate or 0)
end

local function lightOff(rate)
  if supportsDimming then
    rampToBrightness(0, rate or 0)
  else
    sendLightCommand({ has_state = true, state = false })
    notifyBrightnessChanged(0)
  end
end

local function lightToggle(rate)
  if currentBrightness > 0 then
    lightOff(rate)
  else
    lightOn(rate)
  end
end

---------------------------------------------------------------------------
-- RFP: LIGHT_V2 proxy commands
---------------------------------------------------------------------------

function RFP.SET_BRIGHTNESS_TARGET(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BRIGHTNESS_TARGET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = tonumber(Select(tParams, "LIGHT_BRIGHTNESS_TARGET")) or 0
  local rate = tointeger(Select(tParams, "RATE")) or getDefaultRate()
  -- spec _2.1: optional LIGHT_BRIGHTNESS_TARGET_PRESET_ID identifies the
  -- preset (e.g. Daylight Agent) driving this target. Pass it through so
  -- subsequent LIGHT_BRIGHTNESS_CHANGED notifies report it as the current
  -- preset id; other rampToBrightness call sites omit it and clear the id.
  local presetId = tointeger(Select(tParams, "LIGHT_BRIGHTNESS_TARGET_PRESET_ID"))
  rampToBrightness(level, rate, presetId)
end

function RFP.ON(idBinding, strCommand, tParams, args)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOn()
end

function RFP.OFF(idBinding, strCommand, tParams, args)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOff()
end

function RFP.TOGGLE(idBinding, strCommand, tParams, args)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightToggle()
end

-- DYNAMIC_ON / DYNAMIC_OFF (spec _1.3 / _1.2): O.S. 3.3.2+ Navigators send
-- these instead of plain ON/OFF for generic on/off interactions, allowing
-- the proxy to apply on-mode behavior (color fade, previous color, etc.).
-- We treat them identically to ON / OFF since lightOn/lightOff already
-- consult on-mode state.
function RFP.DYNAMIC_ON(idBinding, strCommand, tParams, args)
  log:trace("RFP.DYNAMIC_ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOn()
end

function RFP.DYNAMIC_OFF(idBinding, strCommand, tParams, args)
  log:trace("RFP.DYNAMIC_OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  lightOff()
end

function RFP.SET_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = tointeger(Select(tParams, "LEVEL")) or 0
  if supportsDimming then
    rampToBrightness(level, 0)
  elseif level > 0 then
    lightOn()
  else
    lightOff()
  end
end

-- Legacy command, retained for compatibility with older Composer programming
-- and Alexa Voice Scenes (other LIGHT_V2 drivers carry the same forwarder).
function RFP.RAMP_TO_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.RAMP_TO_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  RFP.SET_BRIGHTNESS_TARGET(idBinding, "SET_BRIGHTNESS_TARGET", {
    LIGHT_BRIGHTNESS_TARGET = Select(tParams, "LEVEL"),
    RATE = Select(tParams, "TIME"),
  })
end

function RFP.SET_COLOR_TARGET(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COLOR_TARGET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end

  local kelvin = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE"))
  local x = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_X"))
  local y = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_Y"))
  local incomingMode = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_MODE"))
  local rate = tointeger(
    Select(tParams, "LIGHT_COLOR_TARGET_COLOR_RATE")
      or Select(tParams, "LIGHT_COLOR_TARGET_RATE")
      or Select(tParams, "RATE")
  ) or getDefaultColorRate()

  -- spec _3.1: if the proxy named a color preset and didn't pass explicit
  -- coordinates, look the preset up locally so the bulb still receives
  -- concrete values. Track the preset id either way so subsequent
  -- LIGHT_COLOR_CHANGED notifies report it as the current preset.
  local presetId = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ID"))
  if presetId ~= nil and not (x and y) and not (kelvin and kelvin > 0) then
    local preset = (persist:get(P_COLOR_PRESETS) or {})[tostring(presetId)]
    if preset then
      x = preset.x
      y = preset.y
      incomingMode = preset.mode
    else
      log:warn("SET_COLOR_TARGET: unknown LIGHT_COLOR_TARGET_PRESET_ID=%s", presetId)
      return
    end
  end
  currentColorPresetId = presetId

  local targetX, targetY, targetMode

  if kelvin and kelvin > 0 and supportsCCT then
    targetX, targetY = C4:ColorCCTtoXY(kelvin)
    targetMode = LIGHT_COLOR_MODE_CCT
  elseif incomingMode == LIGHT_COLOR_MODE_CCT and supportsCCT and x and y then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if not k or k <= 0 then
      log:warn("SET_COLOR_TARGET: ColorXYtoCCT(%s, %s) returned %s", x, y, tostring(k))
      return
    end
    targetX, targetY, targetMode = x, y, LIGHT_COLOR_MODE_CCT
  elseif x and y and supportsColor then
    targetX, targetY, targetMode = x, y, LIGHT_COLOR_MODE_FULL
  else
    log:warn(
      "SET_COLOR_TARGET ignored (kelvin=%s x=%s y=%s mode=%s color=%s cct=%s)",
      tostring(kelvin),
      tostring(x),
      tostring(y),
      tostring(incomingMode),
      tostring(supportsColor),
      tostring(supportsCCT)
    )
    return
  end

  -- Spec _7.2: any explicit SET_COLOR_TARGET while in fade mode disables the
  -- formula until the next off→on cycle. We track this so subsequent
  -- SET_BRIGHTNESS_TARGET commands during the same on cycle don't re-apply
  -- dim-to-warm.
  if currentBrightness > 0 then
    fadeOverride = true
  end

  -- Skip the ESPHome cmd if a SET_BRIGHTNESS_TARGET right before us already
  -- merged this color into the brightness ramp cmd. Otherwise we'd send a
  -- second cmd to ESPHome that cancels and restarts the in-flight transition,
  -- making the brightness fade-up snap visually. The earlier merged-color
  -- path already emitted notifyColorChanging, and brightnessRampFinished
  -- will emit notifyColorChanged when the ramp completes - so there is
  -- nothing to notify here, just suppress the redundant ESPHome cmd.
  local now = C4:GetTime()
  if now < mergedColorUntil and rampingBrightness then
    log:debug("SET_COLOR_TARGET deduped (%sms remaining in merged-color window)", mergedColorUntil - now)
    currentColorX = targetX
    currentColorY = targetY
    currentColorMode = targetMode
    return
  end

  rampToColor(targetX, targetY, targetMode, rate)
end

-- Halt an in-flight brightness transition at the current stepped level.
function RFP.SET_BRIGHTNESS_STOP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BRIGHTNESS_STOP(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  brightnessRampStopped()
end

-- Spec _4 / _5: cap the on-level range. Stored in persist; rampToBrightness
-- doesn't enforce them today (ESPHome bulbs natively go 0-100), but we
-- echo the value back per-spec so the proxy and Composer track the setting.
function RFP.SET_MAX_ON_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_MAX_ON_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 100))
  persist:set(P_MAX_ON_LEVEL, level)
  SendToProxy(PROXY_BINDING, "MAX_ON", tostring(level), "NOTIFY")
end

function RFP.SET_MIN_ON_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_MIN_ON_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 0))
  persist:set(P_MIN_ON_LEVEL, level)
  SendToProxy(PROXY_BINDING, "MIN_ON", tostring(level), "NOTIFY")
end

-- Halt an in-flight color transition at the current stepped XY/mode.
function RFP.SET_COLOR_STOP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COLOR_STOP(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  colorRampStopped()
end

function RFP.GET_CONNECTED_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_CONNECTED_STATE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = STATE ~= nil }, "NOTIFY")
end

-- Legacy: re-emit the current brightness when the proxy asks. Modern callers
-- read the cached BRIGHTNESS_PERCENT variable, but the LIGHT_V2 contract
-- includes this command for compatibility.
function RFP.GET_LIGHT_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_LIGHT_LEVEL(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  notifyBrightnessChanged(currentBrightness)
end

---------------------------------------------------------------------------
-- Scene support (Advanced Lighting Scenes)
---------------------------------------------------------------------------

local function getScenes()
  return persist:get(P_SCENES, {})
end

local function saveScenes(scenes)
  persist:set(P_SCENES, scenes)
end

-- Parse the LIGHT_V2 scene <element> XML. The proxy passes a string of one or
-- more <element>...</element> blocks describing what to do at each step.
-- Returns an array of normalized step tables.
local function parseSceneElements(elementsXml)
  local steps = {}
  if IsEmpty(elementsXml) then
    return steps
  end
  local parsed = ParseXml("<root>" .. elementsXml .. "</root>")
  local elementList = Select(parsed, "root", "element") or {}
  if not IsList(elementList) then
    elementList = { elementList }
  end
  for _, el in ipairs(elementList) do
    if type(el) == "table" then
      local rawBrightnessEnabled = Select(el, "brightnessEnabled")
      local rawColorEnabled = Select(el, "colorEnabled")
      local step = {
        delay = tointeger(Select(el, "delay")) or 0,
        brightnessRate = tointeger(Select(el, "brightnessRate") or Select(el, "rate")) or 0,
        colorRate = tointeger(Select(el, "colorRate")) or 0,
        level = tointeger(Select(el, "brightness") or Select(el, "level")),
        levelEnabled = toboolean(rawBrightnessEnabled),
        colorEnabled = toboolean(rawColorEnabled),
        colorX = tonumber(Select(el, "colorX")),
        colorY = tonumber(Select(el, "colorY")),
        colorMode = tointeger(Select(el, "colorMode")),
      }
      -- Legacy schemas put <level> at the element root with no <brightnessEnabled>
      -- wrapper. Only promote when the wrapper is truly absent, not when it's
      -- explicitly false (toboolean collapses nil and "false" to the same value).
      if rawBrightnessEnabled == nil and rawColorEnabled == nil and step.level ~= nil then
        step.levelEnabled = true
      end
      if step.colorRate == 0 and step.brightnessRate > 0 then
        step.colorRate = step.brightnessRate
      end
      if step.levelEnabled or step.colorEnabled or step.delay > 0 then
        table.insert(steps, step)
      end
    end
  end
  log:debug("parseSceneElements: %d step(s) parsed", #steps)
  return steps
end

-- Bumped any time we want to invalidate in-flight scene step callbacks. The
-- timer names alone don't always prevent a callback already queued by SetTimer
-- from running, so each step closure captures the generation it was born under
-- and bails out if it has changed.
local sceneGeneration = 0

local function stopAllScenes()
  sceneGeneration = sceneGeneration + 1
  CancelTimer(SCENE_RAMP_TIMER)
  local scenes = getScenes()
  for sceneId, _ in pairs(scenes) do
    CancelTimer(SCENE_TIMER_PREFIX .. tostring(sceneId))
  end
  -- Drop any ramp state primed by an in-flight scene step so future echoes
  -- don't get suppressed forever. Notify hooks that fired CHANGING are
  -- finalised by the bulb's own state echo when ramping flags are cleared.
  rampingBrightness = false
  rampingColor = false
  brightnessRamp = nil
  colorRamp = nil
end

local function applySceneStep(step)
  -- Build one combined light_command so the device transitions atomically when
  -- both brightness and color change in the same step.
  if not step.levelEnabled and not step.colorEnabled then
    return 0
  end
  -- Cancel any in-flight ramp (whether from a prior step or a non-scene cmd)
  -- and reset the flags so we can re-prime per this step's rates below. The
  -- echo-suppression contract in UPDATE_STATE relies on rampingBrightness/
  -- rampingColor matching the cmd we are about to send.
  cancelBrightnessRampTimers()
  cancelColorRampTimers()
  rampingBrightness = false
  rampingColor = false
  brightnessRamp = nil
  colorRamp = nil
  local cmd = {}
  -- ESPHome takes a single transition_length per cmd, so the bulb interpolates
  -- both brightness and color over the longer of the two requested rates. Use
  -- that unified rate for ramp metadata and notify payloads so the proxy's
  -- picker animation, the local STOP-mid-step interpolation, and the SCENE_
  -- TIMER all agree on when the transition actually completes.
  local rate = math.max(step.brightnessRate or 0, step.colorRate or 0)
  if rate > 0 then
    cmd.has_transition_length = true
    cmd.transition_length = rate
  end
  local startTime = C4:GetTime()
  -- A level of 0 means "off"; the color block is metadata for the next on.
  -- Don't send color/RGB fields in that case so the device actually turns off.
  local turningOff = step.levelEnabled and step.level == 0
  if step.levelEnabled and step.level ~= nil then
    cmd.has_state = true
    cmd.state = step.level > 0
    if step.level > 0 and supportsDimming then
      cmd.has_brightness = true
      cmd.brightness = step.level / 100.0
    end
    -- Scene step is driving brightness directly; clear any active preset id
    -- so subsequent CHANGED notifies don't echo a stale value. Color-only
    -- steps don't touch this so a brightness preset can survive across them.
    currentBrightnessPresetId = nil
    -- Only prime a ramp when the level actually moves; an explicit step at
    -- the current level with rate>0 would otherwise queue a pointless picker
    -- animation and suppress the next echo for no reason.
    if rate > 0 and step.level ~= currentBrightness then
      rampingBrightness = true
      brightnessRamp = {
        startTime = startTime,
        startLevel = currentBrightness,
        targetLevel = step.level,
        durationMs = rate,
      }
      notifyBrightnessChanging(step.level, rate)
    end
  end
  if step.colorEnabled and step.colorX and step.colorY and not turningOff then
    local mode = step.colorMode or LIGHT_COLOR_MODE_FULL
    if mode == LIGHT_COLOR_MODE_CCT and supportsCCT then
      local k = tonumber(C4:ColorXYtoCCT(step.colorX, step.colorY))
      if k and k > 0 then
        cmd.has_color_temperature = true
        cmd.color_temperature = kelvinToMireds(k)
      end
    elseif supportsColor then
      local r, g, b = xyToRGB(step.colorX, step.colorY)
      cmd.has_rgb = true
      cmd.red = r
      cmd.green = g
      cmd.blue = b
    end
    cmd.has_state = true
    cmd.state = true
    currentColorPresetId = nil
    local colorChanged = math.abs(step.colorX - currentColorX) > 1e-4
      or math.abs(step.colorY - currentColorY) > 1e-4
      or mode ~= currentColorMode
    if rate > 0 and colorChanged then
      rampingColor = true
      colorRamp = {
        startTime = startTime,
        startX = currentColorX,
        startY = currentColorY,
        targetX = step.colorX,
        targetY = step.colorY,
        targetMode = mode,
        durationMs = rate,
      }
      notifyColorChanging(step.colorX, step.colorY, mode, rate)
    end
  end
  if next(cmd) ~= nil then
    sendLightCommand(cmd)
  end
  return rate
end

local function runScene(sceneId, generation)
  if generation ~= nil and generation ~= sceneGeneration then
    return
  end
  local gen = generation or sceneGeneration
  local scenes = getScenes()
  local scene = scenes[tostring(sceneId)]
  if not scene then
    log:warn("Scene %s not found", sceneId)
    return
  end
  scene.state = scene.state or 0
  local timerName = SCENE_TIMER_PREFIX .. tostring(sceneId)
  CancelTimer(timerName)

  while true do
    if gen ~= sceneGeneration then
      return
    end
    local idx = scene.state + 1
    if idx > #scene.elements then
      if scene.flash then
        scene.state = 0
        idx = 1
      else
        scene.state = 0
        scenes[tostring(sceneId)] = scene
        saveScenes(scenes)
        return
      end
    end
    local step = scene.elements[idx]
    local delay = math.max(0, step.delay or 0)
    scene.state = idx
    scenes[tostring(sceneId)] = scene
    saveScenes(scenes)

    -- When a step's ramp elapses, finalise any in-flight ramp metadata so
    -- rampingBrightness/rampingColor are cleared and CHANGED notifies fire
    -- before we apply the next step.
    local function finishRampsAndAdvance()
      if brightnessRamp and brightnessRamp.targetLevel ~= nil then
        brightnessRampFinished(brightnessRamp.targetLevel)
      end
      if colorRamp and colorRamp.targetX and colorRamp.targetY and colorRamp.targetMode then
        colorRampFinished(colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode)
      end
      runScene(sceneId, gen)
    end

    if delay > 0 then
      SetTimer(timerName, delay, function()
        if gen ~= sceneGeneration then
          return
        end
        local rampMs = applySceneStep(step)
        if rampMs > 0 then
          SetTimer(timerName, rampMs, finishRampsAndAdvance)
        else
          runScene(sceneId, gen)
        end
      end)
      return
    end

    local rampMs = applySceneStep(step)
    if rampMs > 0 then
      SetTimer(timerName, rampMs, finishRampsAndAdvance)
      return
    end
    -- otherwise loop synchronously to the next element
  end
end

function RFP.PUSH_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.PUSH_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  local elements = Select(tParams, "ELEMENTS")
  local scenes = getScenes()
  scenes[tostring(sceneId)] = {
    elements = parseSceneElements(elements),
    flash = toboolean(Select(tParams, "FLASH")),
    ignoreRamp = toboolean(Select(tParams, "IGNORE_RAMP")),
    fromGroup = toboolean(Select(tParams, "FROM_GROUP")),
    state = 0,
  }
  saveScenes(scenes)
  log:debug("Stored scene %s with %d element(s)", sceneId, #scenes[tostring(sceneId)].elements)
end

function RFP.REMOVE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.REMOVE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  CancelTimer(SCENE_TIMER_PREFIX .. tostring(sceneId))
  local scenes = getScenes()
  scenes[tostring(sceneId)] = nil
  saveScenes(scenes)
end

function RFP.CLEAR_ALL_SCENES(idBinding, strCommand, tParams, args)
  log:trace("RFP.CLEAR_ALL_SCENES(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  stopAllScenes()
  saveScenes({})
end

function RFP.ALL_SCENES_PUSHED(idBinding, strCommand, tParams, args)
  log:trace("RFP.ALL_SCENES_PUSHED(%s, %s)", idBinding, strCommand)
  -- Marker that the proxy has finished pushing scenes; nothing to do.
end

function RFP.ACTIVATE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.ACTIVATE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  stopAllScenes()
  local scenes = getScenes()
  local scene = scenes[tostring(sceneId)]
  if not scene then
    log:warn("ACTIVATE_SCENE: unknown scene id %s", sceneId)
    return
  end
  scene.state = 0
  scenes[tostring(sceneId)] = scene
  saveScenes(scenes)
  runScene(sceneId)
end

function RFP.DEACTIVATE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.DEACTIVATE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- The Advanced Lighting agent uses DEACTIVATE_SCENE to mark a scene "off"
  -- in its own bookkeeping. Our driver doesn't track which scene is currently
  -- "active" (the device just reflects the last commands sent), so we just
  -- stop any running scene playback.
  stopAllScenes()
end

function RFP.RAMP_SCENE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.RAMP_SCENE_UP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local rate = tointeger(Select(tParams, "RATE")) or 0
  local scenes = getScenes()
  local scene = sceneId and scenes[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  stopAllScenes()
  if supportsDimming then
    rampToBrightness(getOnBrightness(), rate)
  else
    lightOn()
  end
end

function RFP.RAMP_SCENE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.RAMP_SCENE_DOWN(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local rate = tointeger(Select(tParams, "RATE")) or 0
  local scenes = getScenes()
  local scene = sceneId and scenes[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  stopAllScenes()
  if supportsDimming then
    rampToBrightness(0, rate)
  else
    lightOff()
  end
end

function RFP.STOP_SCENE_RAMP(idBinding, strCommand, tParams, args)
  log:trace("RFP.STOP_SCENE_RAMP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  stopAllScenes()
  brightnessRampStopped()
  colorRampStopped()
end

-- The published spec calls this command STOP_RAMP_SCENE; older / template code
-- uses STOP_SCENE_RAMP. Register both so the proxy can reach us either way.
RFP.STOP_RAMP_SCENE = RFP.STOP_SCENE_RAMP

function RFP.TOGGLE_SCENE(idBinding, strCommand, tParams, args)
  log:trace("RFP.TOGGLE_SCENE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- We don't track per-scene "active" state on the device side, so we always
  -- activate the requested scene. The agent's own bookkeeping handles toggle
  -- semantics across the project.
  RFP.ACTIVATE_SCENE(idBinding, "ACTIVATE_SCENE", tParams)
end

---------------------------------------------------------------------------
-- RFP: preset and rate management
---------------------------------------------------------------------------

function RFP.SET_PRESET_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_PRESET_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = tointeger(Select(tParams, "LEVEL")) or DEFAULT_PRESET_LEVEL
  persist:set(P_PRESET_LEVEL, level)
  -- PRESET_LEVEL notify takes a single BRIGHTNESS value (1-100) as a plain
  -- string, not a parameter map. Sending it as {BRIGHTNESS=N} causes the
  -- proxy to reject the value and revert the preset to 0 - blocking users
  -- from changing the Default On level in Composer.
  SendToProxy(PROXY_BINDING, "PRESET_LEVEL", tostring(level), "NOTIFY")
end

function RFP.UPDATE_BRIGHTNESS_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local presetId = tointeger(Select(tParams, "BRIGHTNESS_PRESET_ID"))
  local presetLevel = tonumber(Select(tParams, "BRIGHTNESS_PRESET_LEVEL")) or DEFAULT_PRESET_LEVEL
  persist:set(P_ON_MODE, { id = presetId, level = presetLevel })
end

-- Per spec _21.2: SET_BRIGHTNESS_ON_MODE is sent by the proxy to tell the
-- driver which preset ID should be used as the "On" target. When the proxy
-- isn't the initiator (button link, scene), we use this to know what level
-- to ramp to.
function RFP.SET_BRIGHTNESS_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BRIGHTNESS_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local presetId = tointeger(Select(tParams, "PRESET_ID"))
  if presetId == nil then
    return
  end
  persist:set(P_BRIGHTNESS_ON_MODE_PRESET, presetId)
  -- Look up the preset's current level so getOnBrightness uses it immediately.
  local presets = persist:get(P_BRIGHTNESS_PRESETS) or {}
  local preset = presets[tostring(presetId)]
  if preset and preset.level then
    persist:set(P_ON_MODE, { id = presetId, level = preset.level })
  end
end

function RFP.UPDATE_BRIGHTNESS_PRESET(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_PRESET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local command = Select(tParams, "COMMAND")
  local presetId = tointeger(Select(tParams, "ID"))
  local level = tonumber(Select(tParams, "LEVEL"))
  local name = Select(tParams, "NAME")
  if presetId == nil then
    return
  end
  local presets = persist:get(P_BRIGHTNESS_PRESETS) or {}
  local key = tostring(presetId)
  if command == "REMOVED" then
    presets[key] = nil
  else
    presets[key] = { id = presetId, name = name, level = level }
  end
  persist:set(P_BRIGHTNESS_PRESETS, presets)
  -- If this preset is the currently-active on-mode preset, refresh the
  -- on-mode level so getOnBrightness picks up the change immediately.
  local activeId = tointeger(persist:get(P_BRIGHTNESS_ON_MODE_PRESET))
  if activeId ~= nil and activeId == presetId then
    if level == nil then
      persist:delete(P_ON_MODE)
    else
      persist:set(P_ON_MODE, { id = presetId, level = level })
    end
  end
end

-- color_rate_behavior=1: brightness and color share a single default rate.
-- Composer's "Default Brightness and Color Rate" only sets one value; we
-- persist both keys to the same rate so the two getters can't drift.
function RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(P_RATE_DEFAULT, rate)
  persist:set(P_COLOR_RATE_DEFAULT, rate)
end

function RFP.UPDATE_COLOR_RATE_DEFAULT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_RATE_DEFAULT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(P_COLOR_RATE_DEFAULT, rate)
  persist:set(P_RATE_DEFAULT, rate)
end

-- Persist color presets keyed by ID so we can apply them when the proxy is
-- not the initiator (button link, scene, programming, dim-to-warm fade).
function RFP.UPDATE_COLOR_PRESET(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_PRESET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local command = Select(tParams, "COMMAND")
  local presetId = tointeger(Select(tParams, "ID"))
  if presetId == nil then
    return
  end
  local presets = persist:get(P_COLOR_PRESETS) or {}
  local key = tostring(presetId)
  if command == "REMOVED" then
    presets[key] = nil
  else
    presets[key] = {
      id = presetId,
      name = Select(tParams, "NAME"),
      x = tonumber(Select(tParams, "COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_MODE")),
    }
  end
  persist:set(P_COLOR_PRESETS, presets)
end

-- Per spec _20.4: UPDATE_COLOR_ON_MODE carries the active On preset (and a
-- separate Fade pair for Dim-To-Warm). We persist both so we can drive color
-- ourselves on non-proxy on actions and apply the fade formula.
function RFP.UPDATE_COLOR_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_COLOR_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local mode = {
    onPreset = {
      id = tointeger(Select(tParams, "COLOR_PRESET_ID")),
      origin = tointeger(Select(tParams, "COLOR_PRESET_ORIGIN")),
      x = tonumber(Select(tParams, "COLOR_PRESET_COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_PRESET_COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_PRESET_COLOR_MODE")),
    },
    fadePreset = {
      id = tointeger(Select(tParams, "COLOR_FADE_PRESET_ID")),
      origin = tointeger(Select(tParams, "COLOR_FADE_PRESET_ORIGIN")),
      x = tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_FADE_PRESET_COLOR_MODE")),
    },
  }
  persist:set(P_COLOR_ON_MODE, mode)
end

-- SET_COLOR_ON_MODE (spec _9.1): proxy tells the driver which mode is active
-- (preset / fade / previous). We persist the mode kind so we can branch in
-- lightOn and brightness handling.
function RFP.SET_COLOR_ON_MODE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_COLOR_ON_MODE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local presetId = tointeger(Select(tParams, "PRESET_ID"))
  persist:set(P_COLOR_ON_MODE_PRESET, presetId)
  -- A fresh on-mode selection clears any prior fadeOverride so the formula
  -- runs again on the next on cycle.
  fadeOverride = false
end

-- Click/hold rate echo notifies follow the same convention as PRESET_LEVEL:
-- the proxy expects a plain string with the rate value, not a parameter map.
-- Sending {RATE=N} causes the proxy to reject the value and revert the
-- setting to 0, which is why Composer keeps showing 0 after a save.
function RFP.SET_CLICK_RATE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_CLICK_RATE_UP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_CLICK_RATE
  persist:set(P_CLICK_RATE_UP, rate)
  SendToProxy(PROXY_BINDING, "CLICK_RATE_UP", tostring(rate), "NOTIFY")
end

function RFP.SET_CLICK_RATE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_CLICK_RATE_DOWN(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_CLICK_RATE
  persist:set(P_CLICK_RATE_DOWN, rate)
  SendToProxy(PROXY_BINDING, "CLICK_RATE_DOWN", tostring(rate), "NOTIFY")
end

function RFP.SET_HOLD_RATE_UP(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_HOLD_RATE_UP(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_HOLD_RATE
  persist:set(P_HOLD_RATE_UP, rate)
  SendToProxy(PROXY_BINDING, "HOLD_RATE_UP", tostring(rate), "NOTIFY")
end

function RFP.SET_HOLD_RATE_DOWN(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_HOLD_RATE_DOWN(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_HOLD_RATE
  persist:set(P_HOLD_RATE_DOWN, rate)
  SendToProxy(PROXY_BINDING, "HOLD_RATE_DOWN", tostring(rate), "NOTIFY")
end

---------------------------------------------------------------------------
-- RFP: button colors
---------------------------------------------------------------------------

function RFP.REQUEST_BUTTON_COLORS(idBinding, strCommand, tParams, args)
  log:trace("RFP.REQUEST_BUTTON_COLORS(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  for _, buttonId in ipairs({ 0, 1, 2 }) do
    local onColor, offColor = getButtonColors(buttonId)
    SendToProxy(PROXY_BINDING, "BUTTON_COLORS", {
      BUTTON_ID = buttonId,
      ON_COLOR = onColor,
      OFF_COLOR = offColor,
    }, "NOTIFY")
  end
  -- MATCH_LED_STATE per button binding, with bottom inverted (its LED lights
  -- when the light is off so the keypad shows the toggle state correctly).
  local isOn = currentBrightness > 0
  SendToProxy(ON_BINDING, "MATCH_LED_STATE", { STATE = isOn }, "NOTIFY", true)
  SendToProxy(OFF_BINDING, "MATCH_LED_STATE", { STATE = not isOn }, "NOTIFY", true)
  SendToProxy(TOGGLE_BINDING, "MATCH_LED_STATE", { STATE = isOn }, "NOTIFY", true)
end

function RFP.SET_BUTTON_COLOR(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_BUTTON_COLOR(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local onColor = Select(tParams, "ON_COLOR")
  local offColor = Select(tParams, "OFF_COLOR")
  if buttonId == nil then
    return
  end
  setButtonColors(buttonId, onColor, offColor)
  if onColor then
    SendToProxy(PROXY_BINDING, "BUTTON_INFO", { BUTTON_ID = buttonId, ON_COLOR = onColor }, "NOTIFY")
  end
  if offColor then
    SendToProxy(PROXY_BINDING, "BUTTON_INFO", { BUTTON_ID = buttonId, OFF_COLOR = offColor }, "NOTIFY")
  end
end

---------------------------------------------------------------------------
-- RFP: button actions (from proxy)
---------------------------------------------------------------------------

-- Restore brightness to the pre-press snapshot. Called when a RELEASE_CLICK
-- arrives after a brief hold-ramp has already stepped 1-2%. Cancels timers,
-- snaps device + state back to the snapshot, and returns the effective level
-- the click logic should use for direction decisions. If no snapshot exists
-- (e.g. CLICK without preceding PRESS via DO_CLICK), returns currentBrightness.
local function rewindToPrePress()
  local snapshot = prePressBrightness
  prePressBrightness = nil
  cancelBrightnessRampTimers()
  if not rampingBrightness or snapshot == nil then
    rampingBrightness = false
    return snapshot or currentBrightness
  end
  rampingBrightness = false
  if currentBrightness ~= snapshot then
    setESPHomeBrightness(snapshot, 0)
    currentBrightness = snapshot
  end
  return snapshot
end

-- Shared button-action implementation. Used by RFP.BUTTON_ACTION (proxy ->
-- driver path, e.g. on-device buttons or programming) and by DO_CLICK /
-- DO_PUSH / DO_RELEASE (button-link path, e.g. a keypad button bound to one
-- of our BUTTON_LINK connections). Returns nothing.
local function handleButtonAction(buttonId, action)
  if action == constants.ButtonActions.PRESS then
    -- Button-down. Snapshot brightness for the click race, then start a hold
    -- ramp at the persisted hold rate. If the proxy decides this was a click,
    -- a RELEASE_CLICK will arrive ~110ms later and rewindToPrePress() will
    -- undo any partial step before the click ramp runs.
    prePressBrightness = currentBrightness
    if not supportsDimming then
      if buttonId == constants.ButtonIds.TOP then
        lightOn()
      elseif buttonId == constants.ButtonIds.BOTTOM then
        lightOff()
      elseif buttonId == constants.ButtonIds.TOGGLE then
        lightToggle()
      end
      return
    end
    if buttonId == constants.ButtonIds.TOP then
      rampToBrightness(getOnBrightness(), getHoldRateUp())
    elseif buttonId == constants.ButtonIds.BOTTOM then
      rampToBrightness(0, getHoldRateDown())
    elseif buttonId == constants.ButtonIds.TOGGLE then
      if currentBrightness > 0 then
        rampToBrightness(0, getHoldRateDown())
      else
        rampToBrightness(getOnBrightness(), getHoldRateUp())
      end
    end
  elseif action == constants.ButtonActions.RELEASE_HOLD then
    prePressBrightness = nil
    brightnessRampStopped()
  elseif action == constants.ButtonActions.RELEASE_CLICK then
    local effective = rewindToPrePress()
    if buttonId == constants.ButtonIds.TOP then
      if supportsDimming then
        rampToBrightness(getOnBrightness(), getClickRateUp())
      else
        lightOn()
      end
    elseif buttonId == constants.ButtonIds.BOTTOM then
      if supportsDimming then
        rampToBrightness(0, getClickRateDown())
      else
        lightOff()
      end
    elseif buttonId == constants.ButtonIds.TOGGLE then
      if supportsDimming then
        if effective > 0 then
          rampToBrightness(0, getClickRateDown())
        else
          rampToBrightness(getOnBrightness(), getClickRateUp())
        end
      else
        if effective > 0 then
          lightOff()
        else
          lightOn()
        end
      end
    end
  end
end

function RFP.BUTTON_ACTION(idBinding, strCommand, tParams, args)
  log:trace("RFP.BUTTON_ACTION(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end

  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local action = tointeger(Select(tParams, "ACTION"))

  handleButtonAction(buttonId, action)

  -- Echo the button action AFTER the ramp setup. If we send this BEFORE the
  -- LIGHT_BRIGHTNESS_CHANGING notify, the proxy treats it as a state-change
  -- event and snaps the UI to the on/off target, then our CHANGING repositions
  -- back to current and animates - producing a visible jump-and-rewind.
  SendToProxy(PROXY_BINDING, "BUTTON_ACTION", {
    BUTTON_ID = buttonId,
    ACTION = action,
  }, "NOTIFY")
end

---------------------------------------------------------------------------
-- RFP: button link bindings (DO_CLICK, DO_PUSH, DO_RELEASE)
---------------------------------------------------------------------------

local function buttonIdFromBinding(idBinding)
  if idBinding == ON_BINDING then
    return constants.ButtonIds.TOP
  elseif idBinding == OFF_BINDING then
    return constants.ButtonIds.BOTTOM
  elseif idBinding == TOGGLE_BINDING then
    return constants.ButtonIds.TOGGLE
  end
  return nil
end

-- Button-link bindings forward to handleButtonAction directly. Unlike the
-- proxy-initiated BUTTON_ACTION path, we don't send a BUTTON_ACTION echo
-- back to the proxy here: the proxy is the one that sent us DO_*, so it
-- already knows the button fired. Echoing would make the proxy snap the UI
-- to the on/off target before our LIGHT_BRIGHTNESS_CHANGING animates.
function RFP.DO_CLICK(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_CLICK(%s, %s)", idBinding, strCommand)
  local buttonId = buttonIdFromBinding(idBinding)
  if buttonId == nil then
    return
  end
  handleButtonAction(buttonId, constants.ButtonActions.RELEASE_CLICK)
end

function RFP.DO_PUSH(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_PUSH(%s, %s)", idBinding, strCommand)
  local buttonId = buttonIdFromBinding(idBinding)
  if buttonId == nil then
    return
  end
  handleButtonAction(buttonId, constants.ButtonActions.PRESS)
end

function RFP.DO_RELEASE(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_RELEASE(%s, %s)", idBinding, strCommand)
  local buttonId = buttonIdFromBinding(idBinding)
  if buttonId == nil then
    return
  end
  handleButtonAction(buttonId, constants.ButtonActions.RELEASE_HOLD)
end

---------------------------------------------------------------------------
-- RFP: ESPHome state updates
---------------------------------------------------------------------------

function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s)", idBinding, strCommand)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  cancelBrightnessRampTimers()
  cancelColorRampTimers()
  rampingBrightness = false
  rampingColor = false
  brightnessRamp = nil
  colorRamp = nil
  stopAllScenes()
  ENTITY = nil
  STATE = nil
  dynamicCapsSent = false
  supportsDimming = false
  supportsColor = false
  supportsCCT = false
  supportedColorModes = {}
  currentBrightness = 0
  ledState = false
  prePressBrightness = nil
  fadeOverride = false
  mergedColorUntil = 0
  currentBrightnessPresetId = nil
  currentColorPresetId = nil
  updateStatus("Disconnected", false)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  notifyBrightnessChanged(0)
end

function RFP.UPDATE_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s)", idBinding, strCommand, tParams)
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

  local wasConnected = STATE ~= nil
  local isFirstUpdate = ENTITY == nil
  ENTITY = entity
  STATE = state

  -- Connection state must be sent BEFORE dynamic capabilities
  if not wasConnected then
    updateStatus("Connected", true)
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
  end

  -- Send dynamic capabilities after ONLINE_CHANGED
  if isFirstUpdate then
    updateDynamicCapabilities(entity)
  end

  -- Map ESPHome brightness (0.0-1.0) to C4 (0-100)
  local newBrightness
  local isOn = Select(state, "state") or false
  if not isOn then
    newBrightness = 0
  elseif supportsDimming then
    local brightness = tonumber(Select(state, "brightness")) or 1.0
    newBrightness = math.floor(brightness * 100 + 0.5)
    newBrightness = math.max(0, math.min(100, newBrightness))
    if newBrightness == 0 and isOn then
      newBrightness = 1
    end
  else
    newBrightness = 100
  end

  -- During a ramp, ESPHome's echo confirms the target value (not the
  -- interpolated physical value), so we ignore it - rampingBrightness will
  -- be cleared in brightnessRampFinished or brightnessRampStopped, both of
  -- which set currentBrightness to the appropriate value before the snap
  -- cmd's echo can arrive. Outside a ramp, the echo's target equals what
  -- we last set, so processing it is a no-op (newBrightness already
  -- matches currentBrightness).
  if rampingBrightness then
    log:trace("UPDATE_STATE brightness=%s ignored (ramping)", newBrightness)
  elseif isFirstUpdate or newBrightness ~= currentBrightness then
    -- Spec note: LIGHT_BRIGHTNESS_CHANGED should always be sent when the
    -- driver starts and/or when the hardware comes online so the proxy is
    -- seeded with the actual brightness, even if it matches our default.
    notifyBrightnessChanged(newBrightness)
  end

  if isOn and (supportsColor or supportsCCT) and not rampingColor then
    local activeMode = tointeger(Select(state, "color_mode"))
    local newX, newY, newColorMode
    if activeMode and COLOR_MODES_SUPPORTING_CCT[activeMode] and Select(state, "color_temperature") then
      local mireds = tonumber(Select(state, "color_temperature"))
      if mireds and mireds > 0 then
        local k = miredsToKelvin(mireds)
        newX, newY = C4:ColorCCTtoXY(k)
        newColorMode = LIGHT_COLOR_MODE_CCT
      end
    elseif activeMode and COLOR_MODES_SUPPORTING_RGB[activeMode] then
      local r = tonumber(Select(state, "red")) or 0
      local g = tonumber(Select(state, "green")) or 0
      local b = tonumber(Select(state, "blue")) or 0
      if r > 0 or g > 0 or b > 0 then
        local h, s = rgbToHSV(r, g, b)
        newX, newY = C4:ColorHSVtoXY(h, s, 100)
        newColorMode = LIGHT_COLOR_MODE_FULL
      end
    end
    -- Threshold matches xy round-trip drift through RGB / HSV (typically
    -- 1-2e-3 in either coordinate). Tighter than this fires spurious notifies
    -- and clears the active preset id when the bulb just echoes our own cmd
    -- back. Looser than ~1e-2 starts missing visible changes.
    local COLOR_ECHO_TOLERANCE = 5e-3
    if
      newX
      and newY
      and newColorMode
      and (
        isFirstUpdate
        or math.abs(newX - currentColorX) > COLOR_ECHO_TOLERANCE
        or math.abs(newY - currentColorY) > COLOR_ECHO_TOLERANCE
        or newColorMode ~= currentColorMode
      )
    then
      -- Hardware-driven color change (out-of-band update): no preset is
      -- driving this, so don't echo a stale preset id.
      currentColorPresetId = nil
      notifyColorChanged(newX, newY, newColorMode)
    end
  end
end

---------------------------------------------------------------------------
-- Binding change
---------------------------------------------------------------------------

OBC[ESPHOME_BINDING] = function()
  ENTITY = nil
  STATE = nil
  dynamicCapsSent = false
  supportsDimming = false
  supportsColor = false
  supportsCCT = false
  supportedColorModes = {}
  currentBrightness = 0
  ledState = false
  rampingBrightness = false
  rampingColor = false
  brightnessRamp = nil
  colorRamp = nil
  prePressBrightness = nil
  fadeOverride = false
  mergedColorUntil = 0
  currentBrightnessPresetId = nil
  currentColorPresetId = nil
  currentColorX = DEFAULT_COLOR_X
  currentColorY = DEFAULT_COLOR_Y
  currentColorMode = LIGHT_COLOR_MODE_CCT
  cancelBrightnessRampTimers()
  cancelColorRampTimers()
  stopAllScenes()
end
