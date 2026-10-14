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

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_WHITE = {
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_WHITE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
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

local PRESET_ORIGIN_DEVICE = 1
local PREVIOUS_ON_PRESET_ID = 10

local SCENE_TIMER_PREFIX = "Scene_"
local SCENE_RAMP_TIMER = "SceneRamp"

local DEFAULT_PRESET_LEVEL = 100
local DEFAULT_CLICK_RATE = 500
local DEFAULT_HOLD_RATE = 3000
local DEFAULT_RATE = 500
-- The time a stop part way through a change of color mode brings the light back up over.
local MODE_STOP_RATE = 500

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

-- Ramp metadata: { startTime, startLevel, targetLevel, durationMs } and, for
-- a ramp a scene step primed, that step. A brightness ramp also keeps the
-- brightness it runs between (from, to), and the place on the range's line
-- of an end outside the range (startAt, targetAt). A color ramp keeps the fade
-- its command began at the light (fade). Cleared when no ramp is in flight.
local brightnessRamp = nil
local colorRamp = nil

-- Snapshot of brightness captured when BUTTON_ACTION PRESS arrives. The proxy
-- sends PRESS on button-down and decides click vs hold ~110ms later. By the
-- time a RELEASE_CLICK arrives, our hold ramp may have stepped 1-2%; the
-- click's ramp starts from this snapshot so a brief hold step never inverts
-- the click outcome.
local prePressBrightness = nil

-- LIGHT_BRIGHTNESS_TARGET_PRESET_ID from the proxy (Daylight Agent integration,
-- spec _2.1). Echoed back as LIGHT_BRIGHTNESS_CURRENT_PRESET_ID on subsequent
-- LIGHT_BRIGHTNESS_CHANGED so the proxy knows the active preset still owns the
-- current level. Cleared by SET_LEVEL / button presses / scene steps that
-- aren't preset-driven.
local currentBrightnessPresetId = nil

-- LIGHT_COLOR_TARGET_PRESET_ID counterpart (spec _3.1).
local currentColorPresetId = nil

-- The brightness and color the light last reported, then those it has been
-- sent since, oldest first: a report of any other is another client's.
local sentBrightness = {}
local sentColors = {}

-- The brightness the light is at, or going to: its last report, or what it
-- has been sent since. nil before it reports.
local lightBrightness = nil

-- What the light is going to, or is at, of its color and its white: its last
-- report, with what it has been sent since.
local lightTarget = {}

-- The fade the light's last command began, as ESPHome runs one: every field of
-- its color and its white from where it was, `from`, over that command's time.
local lightFade = nil

---------------------------------------------------------------------------
-- The proxy's setup
---------------------------------------------------------------------------

--- The attributes of the element in `list` with this id, and this origin
--- where one is given.
local function setupPreset(list, id, origin)
  list = list or {}
  for _, element in ipairs(IsList(list) and list or { list }) do
    local attr = element._attr or {}
    if tointeger(attr.id) == id and (origin == nil or tointeger(attr.origin) == origin) then
      return attr
    end
  end
end

-- The proxy sends its on modes and default rates only when they change, never
-- at start. Its setup holds them, and it is the authority.
local function readProxySetup()
  local ok, setup = pcall(function()
    return Select(ParseXml(SendUIRequest(C4:GetProxyDevices(), "GET_SETUP", {})), "setup")
  end)
  if not ok or type(setup) ~= "table" then
    log:warn("The proxy's setup could not be read: %s", ok and "no setup in its answer" or setup)
    return
  end

  -- A preset id means one preset only with its origin: the device's own and
  -- the Color Agent's both count from 1.
  local colors = Select(setup, "colors", "color")
  local onId, onOrigin =
    tointeger(setup.light_color_on_mode_preset_id), tointeger(setup.light_color_on_mode_preset_origin)
  local fadeId = tointeger(setup.light_color_on_mode_fade_preset_id)
  local fadeOrigin = tointeger(setup.light_color_on_mode_fade_preset_origin)
  local on = onId and onOrigin and setupPreset(colors, onId, onOrigin)
  local fade = fadeId and (fadeOrigin or 0) > 0 and setupPreset(colors, fadeId, fadeOrigin) or nil
  if on and fadeOrigin and (fadeOrigin == 0 or fade) then
    fade = fade or {}
    RFP.UPDATE_COLOR_ON_MODE(PROXY_BINDING, "UPDATE_COLOR_ON_MODE", {
      COLOR_PRESET_ID = onId,
      COLOR_PRESET_ORIGIN = onOrigin,
      COLOR_PRESET_COLOR_X = on.color_x,
      COLOR_PRESET_COLOR_Y = on.color_y,
      COLOR_PRESET_COLOR_MODE = on.color_mode,
      COLOR_FADE_PRESET_ID = fadeId,
      COLOR_FADE_PRESET_ORIGIN = fadeOrigin,
      COLOR_FADE_PRESET_COLOR_X = fade.color_x,
      COLOR_FADE_PRESET_COLOR_Y = fade.color_y,
      COLOR_FADE_PRESET_COLOR_MODE = fade.color_mode,
    })
  end

  local levelId = tointeger(setup.light_brightness_on_mode_preset_id)
  local level = levelId and setupPreset(Select(setup, "brightnesses", "level"), levelId)
  if level and tonumber(level.level) then
    RFP.UPDATE_BRIGHTNESS_ON_MODE(
      PROXY_BINDING,
      "UPDATE_BRIGHTNESS_ON_MODE",
      { BRIGHTNESS_PRESET_ID = levelId, BRIGHTNESS_PRESET_LEVEL = level.level }
    )
  end

  local rate = tointeger(setup.light_brightness_rate_default)
  if rate then
    RFP.UPDATE_BRIGHTNESS_RATE_DEFAULT(PROXY_BINDING, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = rate })
  end
  rate = tointeger(setup.light_color_rate_default)
  if rate then
    RFP.UPDATE_COLOR_RATE_DEFAULT(PROXY_BINDING, "UPDATE_COLOR_RATE_DEFAULT", { RATE = rate })
  end
end

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
  readProxySetup()
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

  -- The color rate bounds ride every send even on a light with no color: the
  -- supports_* flags gate a control's visibility, and bounds relayed as 0/0 are
  -- what makes Composer throw at bind.
  local caps = {
    -- Brightness/dimmer
    dimmer = supportsDimming,
    set_level = supportsDimming,
    supports_target = supportsDimming,
    supports_brightness_stop = supportsDimming,
    ramp_level = supportsDimming,
    has_fixed_ramp_rate = false,
    fixed_ramp_rate = 0,
    brightness_rate_min = 0,
    brightness_rate_max = 65535,
    supports_color = supportsColor,
    supports_color_correlated_temperature = supportsCCT,
    supports_color_stop = supportsColor or supportsCCT,
    color_rate_behavior = 1, -- ESPHome's transition_length applies to all aspects equally
    color_rate_min = 0,
    color_rate_max = 65535,
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
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", caps, "NOTIFY", true)
  -- The proxy lists a light's colors once it is told the light has color: a
  -- new light's setup has none at start, and so no Color On Mode to read.
  readProxySetup()

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

-- xy colors this close are one color: an RGB / HSV round trip drifts 1-2e-3.
local COLOR_TOLERANCE = 5e-3

local function sameColor(x1, y1, mode1, x2, y2, mode2)
  return mode1 == mode2 and math.abs(x1 - x2) <= COLOR_TOLERANCE and math.abs(y1 - y2) <= COLOR_TOLERANCE
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
-- Read as a number: a key never stored reads as an empty table, not nil.
local function getDefaultColorRate()
  return tointeger(persist:get(P_COLOR_RATE_DEFAULT)) or getDefaultRate()
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
-- Helpers: on-level range
---------------------------------------------------------------------------

-- The light's own brightness (percent) the levels 1 to 100 span: Max and Min
-- On Level remap them there, as a Control4 dimmer that remaps its range does
-- (MAX_ON).
local function onRange()
  local lo = math.max(1, tonumber(persist:get(P_MIN_ON_LEVEL, 1)) or 1)
  return lo, math.max(lo, tonumber(persist:get(P_MAX_ON_LEVEL, 100)) or 100)
end

--- The brightness (0 to 1) at a place on the line the range draws through the
--- levels: its 1 to 100 run between the Min and Max On Level (`lo`, `hi`,
--- percent), and past them for a light outside the range.
local function lineBrightness(at, lo, hi)
  return (lo + (at - 1) * (hi - lo) / 99) / 100
end

--- The brightness a level (0 to 100) goes out at: 0 for off.
local function toDevice(level, lo, hi)
  return level > 0 and lineBrightness(level, lo, hi) or 0
end

--- Where a brightness (0 to 1) sits on the same line: nil for a range with no
--- width.
local function linePlace(brightness, lo, hi)
  return hi > lo and 1 + (brightness * 100 - lo) * 99 / (hi - lo) or nil
end

--- The level (1 to 100) a light that is on at a brightness shows: the range's
--- end past it.
local function toLevel(brightness, lo, hi)
  local level = linePlace(brightness, lo, hi) or 100
  return math.max(1, math.min(100, math.floor(level + 0.5)))
end

--- The level a brightness the light reports, or is sent, reads back as: 0 for
--- off.
local function readLevel(brightness)
  return brightness > 0 and toLevel(brightness, onRange()) or 0
end

-- Whether a level read back is the one shown: a range with no width reads
-- every on level back as one.
local function sameLevel(a, b)
  local lo, hi = onRange()
  return a == b or (a > 0 and b > 0 and hi == lo)
end

-- Where off sits on the line, at a brightness of 0: a fade to or from off runs
-- along it, below level 1.
local function offLevel()
  return linePlace(0, onRange()) or 0
end

-- Whether a light at a brightness is on outside the range, as a new one can
-- leave it: it reads back as the range's end, which it is not at. The margin
-- is a float's error.
local function outsideRange(brightness)
  local lo, hi = onRange()
  return brightness > 0 and (brightness < lo / 100 - 1e-5 or brightness > hi / 100 + 1e-5)
end

-- Where a light outside the range sits on the line, past level 1 or 100: nil
-- inside it, or on a range with no width.
local function outsideAt(brightness)
  return outsideRange(brightness) and linePlace(brightness, onRange()) or nil
end

---------------------------------------------------------------------------
-- Helpers: ESPHome light commands
---------------------------------------------------------------------------

local lightColorAt, dimmedAt -- defined with the color ramps below

--- Take a report's fields, or those of a command the light was `sent`, into
--- what the light is going to.
local function aimLight(fields, sent)
  local target = {}
  for field, value in pairs(lightTarget) do
    target[field] = value
  end
  -- A color temperature with no mode named, for a mode that has none, moves
  -- the light to the first of its modes that has one (compute_color_mode_).
  if
    sent
    and fields.color_temperature
    and not fields.color_mode
    and not COLOR_MODES_SUPPORTING_CCT[target.color_mode]
  then
    target.color_mode = false
    for mode in pairs(supportedColorModes) do
      if COLOR_MODES_SUPPORTING_CCT[mode] and (not target.color_mode or mode < target.color_mode) then
        target.color_mode = mode
      end
    end
  end
  for field, value in pairs(fields) do
    target[field] = value
  end
  lightTarget = target
end

-- The mode ESPHome gives a light with none yet, as after a restart with none
-- restored, at a turn-on that names none: its first.
local function firstColorMode()
  local first
  for mode in pairs(supportedColorModes) do
    if mode >= ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_WHITE and (not first or mode < first) then
      first = mode
    end
  end
  return first
end

local function sendLightCommand(opts)
  log:debug("sendLightCommand(%s)", opts)
  -- A light that is not connected reports nothing of what it is sent.
  if STATE and (opts.has_brightness or opts.state == false) then
    -- As UPDATE_STATE takes the light's brightness: 0 for off.
    sentBrightness[#sentBrightness + 1] = opts.state and opts.brightness or 0
    lightBrightness = sentBrightness[#sentBrightness]
  end
  if STATE then
    -- ESPHome starts every channel again from where it is, over the command's
    -- time, and through a fade to off holds the color and white it began in.
    local now = C4:GetTime()
    local from = lightColorAt(now)
    -- Begun with the light dimmed, a fade in one mode brings it back up from there.
    local dimmed = dimmedAt(lightFade, now)
    if opts.has_rgb or opts.has_color_temperature or opts.has_color_mode then
      sentColors[#sentColors + 1] = {
        color_mode = opts.color_mode,
        color_brightness = opts.color_brightness,
        red = opts.red,
        green = opts.green,
        blue = opts.blue,
        white = opts.white,
        color_temperature = opts.color_temperature,
        cold_white = opts.cold_white,
        warm_white = opts.warm_white,
      }
      aimLight(sentColors[#sentColors], true)
    elseif
      opts.state
      and currentBrightness == 0
      and lightTarget.color_mode == ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_UNKNOWN
    then
      -- A turn-on that names no mode gives a light with none its first, as
      -- part of what it was sent.
      local first = firstColorMode()
      if first then
        sentColors[#sentColors + 1] = { color_mode = first }
        aimLight(sentColors[#sentColors])
      end
    end
    local ms = opts.transition_length or 0
    lightFade = ms > 0
        and { from = from, startTime = now, durationMs = ms, holds = opts.state == false, dimmed = dimmed }
      or nil
  end
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe(opts),
  })
end

--- Whether a report `matches` a value in `sent`: the light's last report
--- again, or a value sent since. Either way it is the last from then, kept
--- as `reported`, and what was sent before it is forgotten.
local function isOwnReport(sent, matches, reported)
  local own = false
  for i, value in ipairs(sent) do
    if matches(value) then
      for _ = 2, i do
        table.remove(sent, 1)
      end
      -- A repeat of it sent next adds nothing.
      while sent[2] and matches(sent[2]) do
        table.remove(sent, 2)
      end
      own = true
      break
    end
  end
  sent[1] = reported
  return own
end

--- Whether a light's state holds the fields of a color it was sent, to the
--- tolerance colors are compared at: a fraction of a field above 1, as mireds.
local function holdsColor(state, color)
  for field, value in pairs(color) do
    local tolerance = COLOR_TOLERANCE * math.max(1, math.abs(value))
    if not (math.abs((tofinite(state[field]) or 0) - value) <= tolerance) then
      return false
    end
  end
  return true
end

local takenColor -- defined with the white points below

-- The color a light's fields show, as an xy and its color mode: nil for none.
-- A mode with a color and a white shows the one turned up further, the color
-- while it is at least the white, and the white below that: at its color
-- temperature's point, or for a white with none, at the white's point of the
-- red, green and blue a white is sent beside.
local function shownColor(fields)
  local CM = ESPHomeProtoSchema.Enum.ColorMode
  local mode = fields.color_mode
  local hasColor = mode and COLOR_MODES_SUPPORTING_RGB[mode]
  local white = fields.white
  if mode == CM.COLOR_MODE_RGB_COLD_WARM_WHITE then
    white = math.max(fields.cold_white, fields.warm_white)
  end
  local inWhite = not (hasColor and fields.color_brightness > 0 and fields.color_brightness >= white)
  if inWhite and mode and COLOR_MODES_SUPPORTING_CCT[mode] and fields.color_temperature > 0 then
    local x, y = C4:ColorCCTtoXY(miredsToKelvin(fields.color_temperature))
    return x, y, LIGHT_COLOR_MODE_CCT
  end
  if hasColor and math.max(fields.red, fields.green, fields.blue) > 0 then
    local h, s = rgbToHSV(fields.red, fields.green, fields.blue)
    local x, y = C4:ColorHSVtoXY(h, s, 100)
    if inWhite and mode == CM.COLOR_MODE_RGB_WHITE then
      return takenColor(x, y, LIGHT_COLOR_MODE_CCT)
    end
    return x, y, LIGHT_COLOR_MODE_FULL
  end
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

--- Whether the light gives a range for its color temperature, in mireds.
local function givesMiredsRange()
  return (tonumber(Select(ENTITY, "min_mireds")) or 0) > 0 and (tonumber(Select(ENTITY, "max_mireds")) or 0) > 0
end

-- The mode a color goes out in when it holds a white beside the color, as a
-- light built with no color_interlock has: nil for a light with none.
local function combinedColorMode()
  local mode = pickColorMode("rgb")
  if mode ~= ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB then
    return mode
  end
end

local isLogicallyOn -- defined with the on modes below

-- The mode the light is in, where that has a color temperature and no color,
-- as an RGBCT light has beside its combined mode: nil in any other.
local function whiteOnlyMode()
  local mode = lightTarget.color_mode
  -- A rated on's pre-on, which names none, is yet to go out.
  if mode == ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_UNKNOWN and currentBrightness == 0 and isLogicallyOn() then
    mode = firstColorMode()
  end
  if supportedColorModes[mode] and COLOR_MODES_SUPPORTING_CCT[mode] and not COLOR_MODES_SUPPORTING_RGB[mode] then
    return mode
  end
end

-- A combined mode lights its color and its white side by side, so the one
-- asked for goes out with the other off, in that mode: a change of mode fades through off.
--- @param white number|boolean|nil The white's color temperature, true for a white with none, or nil for the color.
local function combinedFields(fields, mode, white)
  fields.has_color_mode = true
  fields.color_mode = mode
  fields.has_color_brightness = true
  fields.color_brightness = white and 0 or 1
  if mode ~= ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE then
    fields.has_white = true
    fields.white = white and 1 or 0
    return fields
  end
  -- The light works its cold and warm white out from a color temperature, with
  -- its own gamma. One that reports no range for it cannot, and is sent them.
  local cw, ww = 0, 0
  if white then
    if givesMiredsRange() then
      return fields
    end
    cw, ww = kelvinToCoolWarmSplit(white)
  end
  fields.has_cold_white = true
  fields.cold_white = cw
  fields.has_warm_white = true
  fields.warm_white = ww
  return fields
end

-- Convert an XY/mode color into the right ESPHome cmd fields. Returns the
-- partial cmd table or nil if the bulb doesn't support color/CCT or the
-- provided values can't be mapped.
--- @param merged boolean|nil The color a level command carries, whose color temperature names its mode too.
local function buildColorCmdFields(x, y, mode, merged)
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
    local combined = combinedColorMode()
    local pickedMode = pickColorMode("cct")
    if combined and COLOR_MODES_SUPPORTING_CCT[combined] then
      -- In its white-only mode the light is left there, as one whose white is
      -- a mode of its own is: ESPHome fades a change of mode through off.
      pickedMode = whiteOnlyMode()
      if not pickedMode then
        return combinedFields(fields, combined, k)
      end
    end
    -- A light that is on is left to its own mode: ESPHome fades a change of
    -- mode through off. Off, one with a color keeps a mode that cannot hold a
    -- color temperature unless another is named, and drops the color temperature.
    if not merged and (isLogicallyOn() or not supportsColor) then
      return fields
    end
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    -- ESPHome works the cold and warm white out from a color temperature, with
    -- the light's own gamma. A light that gives no range for it cannot, and is sent them.
    local CM = ESPHomeProtoSchema.Enum.ColorMode
    if
      not givesMiredsRange()
      and (supportedColorModes[CM.COLOR_MODE_COLD_WARM_WHITE] or supportedColorModes[CM.COLOR_MODE_RGB_COLD_WARM_WHITE])
    then
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
    local combined = combinedColorMode()
    if combined then
      -- A white that has no color temperature is lit alone, with its point's red,
      -- green and blue beside it for the light's report to be read back at.
      return combinedFields(fields, combined, mode == LIGHT_COLOR_MODE_CCT or nil)
    end
    -- Named, or a light that is off in a mode with no color drops the color.
    local pickedMode = pickColorMode("rgb")
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    return fields
  end
  return nil
end

-- A color temperature as the light takes it: held to the light's own range, or
-- an RGBW white to the default one, as C4 gives even the wheel's rim a color temperature.
local function takenKelvin(k)
  return math.max(miredsToKelvin(maxMireds), math.min(miredsToKelvin(minMireds), k))
end

-- Whether the light has a white for a white's own point: one at a color
-- temperature, or one with none beside its color, as an RGBW light has.
local function hasWhiteForPoints()
  return supportsCCT or combinedColorMode() ~= nil
end

-- Whether a full color is a color temperature's own point, inside the light's
-- range: a light with a white for it shows it in that white.
local function isWhitePoint(x, y)
  local k = hasWhiteForPoints() and tonumber(C4:ColorXYtoCCT(x, y))
  if not k or k <= 0 or k ~= takenKelvin(k) then
    return false
  end
  local whiteX, whiteY = C4:ColorCCTtoXY(k)
  return sameColor(x, y, LIGHT_COLOR_MODE_CCT, whiteX, whiteY, LIGHT_COLOR_MODE_CCT)
end

-- A color as the light takes it, which its reports then read as: a white at its
-- color temperature's point, or a full color on a light with no white.
function takenColor(x, y, mode)
  if mode ~= LIGHT_COLOR_MODE_CCT and not isWhitePoint(x, y) then
    return x, y, mode
  end
  if not hasWhiteForPoints() then
    return x, y, supportsColor and LIGHT_COLOR_MODE_FULL or mode
  end
  local k = tonumber(C4:ColorXYtoCCT(x, y))
  if k and k > 0 then
    x, y = C4:ColorCCTtoXY(takenKelvin(k))
  end
  return x, y, LIGHT_COLOR_MODE_CCT
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
  local x = dimPreset.x + (onPreset.x - dimPreset.x) * b
  local y = dimPreset.y + (onPreset.y - dimPreset.y) * b
  local colorMode = onPreset.mode or LIGHT_COLOR_MODE_FULL
  -- Two full colors that are each a white's point fade between whites. The mix
  -- is not asked: a line between two colors can cross a white's point at one level.
  if isWhitePoint(onPreset.x, onPreset.y) and isWhitePoint(dimPreset.x, dimPreset.y) then
    colorMode = LIGHT_COLOR_MODE_CCT
  end
  if colorMode == LIGHT_COLOR_MODE_CCT then
    x, y, colorMode = takenColor(x, y, colorMode)
  end
  return { x = x, y = y, mode = colorMode }
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
  local onPreset = mode.onPreset
  if onPreset and onPreset.id == PREVIOUS_ON_PRESET_ID and onPreset.origin == PRESET_ORIGIN_DEVICE then
    return COLOR_ON_MODE_PREVIOUS
  end
  if onPreset and onPreset.x then
    return COLOR_ON_MODE_PRESET
  end
  return COLOR_ON_MODE_NONE
end

-- On when a ramp in flight is heading for an on level, or with none in flight when we think it is.
-- A color command sends this state: the other would cancel a fade up, or turn a fade to off full on.
function isLogicallyOn()
  if rampingBrightness and brightnessRamp then
    return (brightnessRamp.targetLevel or 0) > 0
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
  if kind == COLOR_ON_MODE_FADE then
    return computeFadeColor(brightnessLevel)
  end
  if kind == COLOR_ON_MODE_PREVIOUS then
    local prev = persist:get(P_PREVIOUS_COLOR)
    if prev and prev.x and prev.y then
      -- Taken as the proxy's own copy of it after the on will be, or that copy goes out again.
      local x, y, colorMode = takenColor(prev.x, prev.y, prev.mode or LIGHT_COLOR_MODE_FULL)
      return { x = x, y = y, mode = colorMode }
    end
  end
  if kind == COLOR_ON_MODE_PRESET then
    local mode = persist:get(P_COLOR_ON_MODE)
    local onPreset = mode and mode.onPreset
    if onPreset and onPreset.x and onPreset.y then
      local x, y, colorMode = takenColor(onPreset.x, onPreset.y, onPreset.mode or LIGHT_COLOR_MODE_FULL)
      return { x = x, y = y, mode = colorMode }
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

local notifyColorChanged -- defined with the color notifications below

local function endOnCycle()
  -- A color still on its way is the one the bulb is in when it is next seen,
  -- so the proxy hears it ahead of the level, where it takes its Previous On.
  if rampingColor then
    colorRamp.told = true
    notifyColorChanged(colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode)
  end
  -- Snapshot the current color so color_on_mode_previous can restore it on the
  -- next on. Spec _7.4: "the proxy tracks the last color reported by a driver
  -- before a BRIGHTNESS_CHANGED notification occurs with a level of 0." We
  -- mirror that locally for non-proxy paths.
  persist:set(P_PREVIOUS_COLOR, {
    x = currentColorX,
    y = currentColorY,
    mode = currentColorMode,
  })
  -- Drop any color preset id: whatever drove this on-cycle's color does not
  -- apply once the light is off.
  currentColorPresetId = nil
end

local function notifyBrightnessChanged(level)
  if level == 0 and currentBrightness > 0 then
    endOnCycle()
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

-- The proxy of a light whose white has no color temperature has none to be
-- told: a white is a full color to it.
local function toldMode(mode)
  if mode == LIGHT_COLOR_MODE_CCT and not supportsCCT and hasWhiteForPoints() then
    return LIGHT_COLOR_MODE_FULL
  end
  return mode
end

function notifyColorChanged(x, y, mode)
  currentColorX = x
  currentColorY = y
  currentColorMode = mode
  log:debug("LIGHT_COLOR_CHANGED: x=%.4f y=%.4f mode=%s", x, y, mode)
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = toldMode(mode),
    LIGHT_COLOR_CURRENT_PRESET_ID = currentColorPresetId,
  }, "NOTIFY")
end

local function notifyColorChanging(targetX, targetY, mode, rate)
  log:debug("LIGHT_COLOR_CHANGING: x=%.4f y=%.4f mode=%s rate=%s", targetX, targetY, mode, rate)
  SendToProxy(PROXY_BINDING, "LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_CURRENT_X = currentColorX,
    LIGHT_COLOR_CURRENT_Y = currentColorY,
    LIGHT_COLOR_CURRENT_COLOR_MODE = toldMode(currentColorMode),
    LIGHT_COLOR_TARGET_X = targetX,
    LIGHT_COLOR_TARGET_Y = targetY,
    LIGHT_COLOR_TARGET_COLOR_MODE = toldMode(mode),
    -- Spec _10.7 names this LIGHT_COLOR_TARGET_COLOR_RATE; some older docs
    -- and helper code use LIGHT_COLOR_TARGET_RATE so we send both for safety.
    LIGHT_COLOR_TARGET_COLOR_RATE = rate,
    LIGHT_COLOR_TARGET_RATE = rate,
    LIGHT_COLOR_TARGET_PRESET_ID = currentColorPresetId,
  }, "NOTIFY", true)
end

local leaveColorRamp, colorRampFinished -- defined with the color ramps below

-- Track a color the bulb goes on to with no command of its own, for `ms`:
-- its end tells the proxy and sends nothing.
--- @param from table|nil The ramp the color was already in, whose marks it keeps.
--- @param now number|nil When it began, if a command was sent since.
local function carryColor(x, y, mode, ms, from, now)
  local told = from and from.told
  if told then
    -- Told at an off, the color is the one the bulb is in when next seen.
    currentColorX, currentColorY, currentColorMode = x, y, mode
  end
  if ms <= 0 then
    if not told then
      notifyColorChanged(x, y, mode)
    end
    return
  end
  rampingColor = true
  colorRamp = {
    startTime = now or C4:GetTime(),
    startX = currentColorX,
    startY = currentColorY,
    targetX = x,
    targetY = y,
    targetMode = mode,
    durationMs = ms,
    carried = not from or from.carried,
    told = told,
    fade = lightFade,
  }
  SetTimer("ColorRampFinish", ms, function()
    colorRampFinished(x, y, mode)
  end, false)
end

-- ESPHome runs one transition for every channel, so a command with no color
-- moves a color on its way on over its own transition, and at once with none.
--- @param held boolean|nil A stop's hold over the time the color has left: its end stays, and nothing is told.
--- @param now number|nil When the command went out: the bulb starts again then, not once the proxy is told.
local function retimeColor(ms, held, now)
  local ramp = colorRamp
  if not ramp then
    return
  end
  leaveColorRamp(now)
  carryColor(ramp.targetX, ramp.targetY, ramp.targetMode, ms, ramp, now)
  if rampingColor and not ramp.told and not held then
    notifyColorChanging(ramp.targetX, ramp.targetY, ramp.targetMode, ms)
  end
end

-- Two-phase fade-up workaround. ESPHome's light_call short-circuits on
-- state=false: brightness=0 in the same command is dropped, so the bulb's
-- stored brightness stays at whatever it was last set to (often 1.0).
-- When we then send state=true brightness=target with transition_length,
-- ESPHome sees no brightness diff and the LED snaps on instead of fading.
-- Pre-pushing a state=true brightness=ε with transition=0 sets the stored
-- brightness to ~0 so the real ramp has a real diff to interpolate across.
-- 0.0039 = 1/256, the smallest 8-bit PWM step, visually indistinguishable
-- from off. Using literal 0 risks ESPHome converting state=true brightness=0
-- back into state=false.
local function sendPreOn()
  sendLightCommand({
    has_state = true,
    state = true,
    has_brightness = true,
    brightness = 0.0039,
    has_transition_length = true,
    transition_length = 0,
  })
end

-- Caller contract: only invoked when supportsDimming is true (lightOn/Off,
-- rampToBrightness, scene apply, etc. all gate on it). On/off-only entities
-- get a different code path that doesn't touch brightness.
--- @param at number|nil Where on the range's line to hold a light outside it.
local function setESPHomeBrightness(level, rateMs, keepColor, at)
  local hasRate = rateMs and rateMs > 0
  local goingOn = level > 0 and currentBrightness == 0

  if goingOn and hasRate then
    sendPreOn()
  end

  -- Always include both state AND brightness in the command. The brightness
  -- field is dropped by ESPHome when state=false (see workaround above), but
  -- including it for state=true is essential for the transition.
  local cmd = {
    has_state = true,
    state = level > 0,
    has_brightness = true,
    brightness = at and lineBrightness(at, onRange()) or toDevice(level, onRange()),
    has_transition_length = true,
    -- A rate of 0 still gets sent so it cancels any in-flight transition on
    -- the device rather than falling back to its default_transition_length.
    transition_length = hasRate and rateMs or 0,
  }

  -- Merge color into the brightness cmd so brightness+color animate as one
  -- ESPHome transition. Two scenarios:
  --   1. Dim-to-warm during any brightness change while fade mode is active:
  --      recompute via the formula every step. Spec _7.2: a color set with
  --      SET_COLOR_TARGET lasts until the next brightness command.
  --   2. Off→on with any color on-mode (fade/previous/preset) — apply the
  --      configured on-color in the same cmd. The proxy will typically also
  --      send a SET_COLOR_TARGET right after this; mergedColorUntil makes
  --      the SET_COLOR_TARGET handler skip a redundant ESPHome cmd that
  --      would otherwise cancel and restart the in-flight transition.
  local mergedColor = nil
  -- A stop that keeps a color sends the level alone.
  if not keepColor then
    if level > 0 and getColorOnModeKind() == COLOR_ON_MODE_FADE then
      mergedColor = computeFadeColor(level)
    elseif goingOn then
      mergedColor = resolveOnColor(level)
    end
  end
  local mergedColorApplied = false
  if mergedColor then
    local colorFields = buildColorCmdFields(mergedColor.x, mergedColor.y, mergedColor.mode, true)
    if colorFields then
      for k, v in pairs(colorFields) do
        cmd[k] = v
      end
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
  local now = C4:GetTime()
  sendLightCommand(cmd)
  -- Emit color CHANGING/CHANGED to mirror the brightness side: the proxy
  -- doesn't always issue a SET_COLOR_TARGET (e.g. fade mode drives color
  -- from the formula, not from a separate proxy-initiated cmd), so the
  -- driver has to push these notifies for the picker to track.
  if mergedColorApplied then
    -- The color sent last is where the light goes, so a color ramp in flight
    -- ends here: its end would report a color it has left.
    leaveColorRamp(now)
    if hasRate then
      -- CHANGING reports the color left: the ramp's end sets the target.
      notifyColorChanging(mergedColor.x, mergedColor.y, mergedColor.mode, rateMs)
    else
      notifyColorChanged(mergedColor.x, mergedColor.y, mergedColor.mode)
    end
  else
    retimeColor(cmd.transition_length, keepColor, now)
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
-- target. During a ramp we ignore those echoes (rampingBrightness=true): the
-- ramp's end tells the level. A level the bulb reports that we never sent is
-- another client's, and ends the ramp (sentBrightness).

local function cancelBrightnessRampTimers()
  CancelTimer("BrightnessRampFinish")
end

-- ESPHome eases a transition (LightTransformer::smoothed_progress): a ramp
-- is 10 % of its way a quarter through its time, and half way at the half.
local function eased(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

--- The time a ramp has left, in ms.
local function remaining(ramp)
  return math.max(0, ramp.durationMs - (C4:GetTime() - ramp.startTime))
end

--- The level a ramp has the light at, and its place on the range's line where
--- that is outside the range.
--- @param toggle boolean|nil Read as a toggle does: on to half a level from off.
local function interpolatedBrightness(now, toggle)
  local ramp = brightnessRamp
  if not ramp or ramp.durationMs <= 0 then
    return currentBrightness
  end
  local elapsed = (now or C4:GetTime()) - ramp.startTime
  if elapsed <= 0 then
    return ramp.startLevel, ramp.startAt
  end
  if elapsed >= ramp.durationMs then
    return ramp.targetLevel, ramp.targetAt
  end
  local progress = eased(elapsed / ramp.durationMs)
  -- The light fades its brightness, so off is on the range's line: a stop
  -- leaves it off under half way from there to level 1.
  local off = offLevel()
  local from = ramp.startLevel > 0 and (ramp.startAt or ramp.startLevel) or off
  local to = ramp.targetLevel > 0 and (ramp.targetAt or ramp.targetLevel) or off
  local at = from + (to - from) * progress
  local lit = ramp.startLevel > 0 and ramp.targetLevel > 0
  if not lit and at < (toggle and off + 0.5 or (1 + off) / 2) then
    return 0
  end
  -- A light outside the range is held where it has got to; one fading to or
  -- from off, below level 1, at the Min.
  local outside = at > 100 or (lit and at < 1)
  return math.max(1, math.min(100, math.floor(at + 0.5))), outside and at or nil
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

local leaveMergedColor, changingMode, colorRampStopped -- defined below

-- Halt the in-flight ESPHome transition at our interpolated current level.
local function brightnessRampStopped()
  cancelBrightnessRampTimers()
  if not rampingBrightness then
    return
  end
  local now = C4:GetTime()
  local stoppedAt, at = interpolatedBrightness(now)
  -- A color ramping, or set during this ramp, is not the level's to replace.
  -- One a replaced ramp carried is the level's own.
  local keepColor = (rampingColor and not colorRamp.carried) or brightnessRamp.colorSet
  -- Part way through a change of mode, or a fade begun in one, the light is dimmed.
  local dimmed = not keepColor and stoppedAt > 0 and dimmedAt(lightFade, now)
  if dimmed then
    -- The level's own color, handed to a ramp, is held as a color's stop holds
    -- it: in the one the light is in, eased back up to the level stopped at.
    leaveMergedColor()
    if rampingColor then
      rampingBrightness = false
      brightnessRamp = nil
      currentBrightness = stoppedAt
      colorRampStopped(stoppedAt, at)
      notifyBrightnessChanged(stoppedAt)
      return
    end
  end
  -- With no transition the stop would put the color at its target too, so a
  -- color kept on its way has the level held over the time it has left.
  local hold = keepColor and rampingColor and remaining(colorRamp) or 0
  -- Otherwise the level goes alone, over half a second: a color sent at once, as
  -- while the light faded to off, goes on to where it was sent through off.
  if dimmed then
    hold = MODE_STOP_RATE
  end
  rampingBrightness = false
  brightnessRamp = nil
  if hold > 0 and stoppedAt > 0 then
    -- No turn-on, whose pre-on has no transition either.
    currentBrightness = stoppedAt
  end
  setESPHomeBrightness(stoppedAt, hold, keepColor, at)
  notifyBrightnessChanged(stoppedAt)
end

local stopSceneSteps -- defined with the scene support below

-- Hand the color a brightness ramp carries to the color ramp, from where the
-- ramp has got to: the bulb goes on to it whatever replaces the ramp.
function leaveMergedColor()
  local merged = brightnessRamp and brightnessRamp.mergedColor
  if not merged then
    return
  end
  brightnessRamp.mergedColor = nil
  local elapsed = C4:GetTime() - brightnessRamp.startTime
  local progress = eased(math.min(1, elapsed / brightnessRamp.durationMs))
  currentColorX = currentColorX + (merged.x - currentColorX) * progress
  currentColorY = currentColorY + (merged.y - currentColorY) * progress
  carryColor(merged.x, merged.y, merged.mode, remaining(brightnessRamp))
end

-- End a brightness ramp where it has got to, so what replaces it starts there
-- and a later stop interpolates from the right level. Returns the ramp ended,
-- and the light's place on the range's line where it is outside the range.
local function leaveBrightnessRamp(now)
  local ramp = rampingBrightness and brightnessRamp or nil
  local outside = nil
  if rampingBrightness then
    local at
    at, outside = interpolatedBrightness(now)
    if at == 0 and currentBrightness > 0 then
      endOnCycle() -- a fade retargeted as it reaches off ends its on cycle
    end
    currentBrightness = at
    leaveMergedColor()
  elseif supportsDimming then
    outside = outsideAt(lightBrightness or 0)
  end
  cancelBrightnessRampTimers()
  rampingBrightness = false
  brightnessRamp = nil
  return ramp, outside
end

-- The brightness at a ramp's end: off, its level, or its place outside the
-- range.
local function endBrightness(level, at)
  return at and lineBrightness(at, onRange()) or toDevice(level, onRange())
end

-- The same for a level on its way when a command sets a color alone: it goes
-- on to its target over that command's transition.
--- @param held boolean|nil A stop's hold over the time the level has left: its end stays, and nothing is told.
--- @param now number|nil When the command went out: the bulb starts again then, not once the proxy is told.
local function retimeBrightness(ms, held, now)
  local ramp, startAt = leaveBrightnessRamp(now)
  if not ramp then
    return
  end
  -- At its target's level a light outside the range can still be on its way.
  if ms <= 0 or (currentBrightness == ramp.targetLevel and startAt == ramp.targetAt) then
    notifyBrightnessChanged(ramp.targetLevel)
    return
  end
  rampingBrightness = true
  brightnessRamp = {
    startTime = now or C4:GetTime(),
    startLevel = currentBrightness,
    startAt = startAt,
    targetLevel = ramp.targetLevel,
    targetAt = ramp.targetAt,
    from = endBrightness(currentBrightness, startAt),
    to = ramp.to,
    durationMs = ms,
    colorSet = ramp.colorSet,
  }
  if not held then
    notifyBrightnessChanging(ramp.targetLevel, ms)
  end
  SetTimer("BrightnessRampFinish", ms, function()
    brightnessRampFinished(ramp.targetLevel)
  end, false)
end

local function awayFromFadeColor(level)
  local fade = level > 0 and getColorOnModeKind() == COLOR_ON_MODE_FADE and computeFadeColor(level)
  if not fade or not buildColorCmdFields(fade.x, fade.y, fade.mode) then
    return false
  end
  local x, y, mode = currentColorX, currentColorY, currentColorMode
  if colorRamp then
    x, y, mode = colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode
  end
  return not sameColor(x, y, mode, fade.x, fade.y, fade.mode)
end

--- @param replaced table|nil A ramp the caller already ended for this one.
local function rampToBrightness(level, rate, presetId, replaced)
  level = math.max(0, math.min(100, math.floor((level or 0) + 0.5)))
  rate = math.max(0, tointeger(rate) or 0)

  log:debug("rampToBrightness(%s, %s) from %s", level, rate, currentBrightness)

  stopSceneSteps()

  -- Single source of truth for the active brightness preset id. SET_BRIGHTNESS_
  -- TARGET passes the proxy's id through; everywhere else (buttons, scenes,
  -- lightOn, etc.) omits it so the id clears and CHANGED notifies don't echo
  -- a stale value to the Daylight Agent.
  currentBrightnessPresetId = presetId

  local left, startAt = leaveBrightnessRamp()
  if replaced and not left then
    startAt = replaced.startAt -- a click starts where its press's ramp did
  end
  replaced = left or replaced

  local startingLevel = currentBrightness
  -- A light outside the range is not at the level it shows: it ramps there.
  if level == startingLevel and not startAt then
    -- Sent where the bulb is on its way to a replaced ramp's target, outside a
    -- range with no width, or with Dim-To-Warm in a color set since: the
    -- level's own color goes with it.
    if replaced or outsideRange(lightBrightness or 0) or awayFromFadeColor(level) then
      setESPHomeBrightness(level, 0)
    end
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
    startAt = startAt,
    targetLevel = level,
    from = endBrightness(startingLevel, startAt),
    to = toDevice(level, onRange()),
    durationMs = rate,
  }
  -- Single ESPHome command - the bulb handles the physical transition.
  setESPHomeBrightness(level, rate)
  notifyBrightnessChanging(level, rate)
  -- Nothing is sent at the end: the bulb is there, and a level with no
  -- transition would put every other channel at its target too.
  SetTimer("BrightnessRampFinish", rate, function()
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

local FADED_FIELDS =
  { "color_brightness", "red", "green", "blue", "white", "color_temperature", "cold_white", "warm_white" }

--- Whether a fade of the light changes its color mode at `now`, and whether it
--- is half way through. ESPHome fades that through off: up to half way the light
--- is still in the color and mode it left, and from then in those it was sent.
function changingMode(fade, now)
  if
    not fade
    or fade.holds
    or now - fade.startTime >= fade.durationMs
    or fade.from.color_mode == lightTarget.color_mode
  then
    return false, false
  end
  return true, (now - fade.startTime) * 2 >= fade.durationMs
end

--- Whether a fade has the light dimmed at `now`: through off in a change of
--- mode, or on its way back up from where one had it when the fade began.
function dimmedAt(fade, now)
  return changingMode(fade, now) or (fade and fade.dimmed and now - fade.startTime < fade.durationMs) or false
end

-- The light's color and white at `now`, as ESPHome fades them: each field from
-- where the fade began toward what the light was last sent, eased, or one end
-- of a change of color mode.
function lightColorAt(now)
  local to, fade = lightTarget, lightFade
  if not fade or now - fade.startTime >= fade.durationMs then
    return to
  end
  local from = fade.from
  if fade.holds then
    return from
  end
  local changing, past = changingMode(fade, now)
  if changing then
    return past and to or from
  end
  local progress = eased((now - fade.startTime) / fade.durationMs)
  local at = { color_mode = to.color_mode }
  for _, field in ipairs(FADED_FIELDS) do
    at[field] = from[field] + (to[field] - from[field]) * progress
  end
  -- A light that has reported no color temperature, or no color, fades from none.
  if from.color_temperature == 0 then
    at.color_temperature = to.color_temperature
  end
  if math.max(from.red, from.green, from.blue) == 0 then
    at.red, at.green, at.blue = to.red, to.green, to.blue
  end
  return at
end

-- Where the color and the white of a light have got to, as its own fields
-- tell: in its combined mode, which fades the two across each other so part way
-- some of each is lit, short of half way through a change of mode, in the mode
-- it left, or in a fade begun in one, whose mode may not be its ramp's. nil for
-- any other fade, which its ramp's xy is read for.
local function fadedFields(now)
  local _, past = changingMode(lightFade, now)
  local fields = not past and lightColorAt(now)
  local mode = fields and fields.color_mode
  if supportedColorModes[mode] and (dimmedAt(lightFade, now) or mode == combinedColorMode()) then
    return fields
  end
end

--- The color those fields show: nil where there are none.
local function fadedColor(now)
  local fields = fadedFields(now)
  if fields then
    return shownColor(fields)
  end
end

-- The command that holds a light in its mode at `fields`: every one of them
-- that mode has, since a field left out goes on to where it was last sent.
local function holdFields(fields)
  local CM = ESPHomeProtoSchema.Enum.ColorMode
  local mode = fields.color_mode
  local cmd = { has_color_mode = true, color_mode = mode }
  if COLOR_MODES_SUPPORTING_RGB[mode] then
    cmd.has_color_brightness = true
    cmd.color_brightness = fields.color_brightness
    -- The light scales a color it is sent to a full channel, so what its color
    -- is short of one goes to the color brightness.
    local full = math.max(fields.red, fields.green, fields.blue)
    if full > 0 then
      cmd.has_rgb = true
      cmd.red, cmd.green, cmd.blue = fields.red / full, fields.green / full, fields.blue / full
      cmd.color_brightness = fields.color_brightness * full
    end
  end
  if COLOR_MODES_SUPPORTING_CCT[mode] and fields.color_temperature > 0 then
    cmd.has_color_temperature = true
    cmd.color_temperature = fields.color_temperature
  end
  -- A white-only mode's cold and warm white are its color temperature's, which
  -- a light that gives a range for it works out.
  if
    mode == CM.COLOR_MODE_RGB_COLD_WARM_WHITE
    or (mode == CM.COLOR_MODE_COLD_WARM_WHITE and not (givesMiredsRange() and cmd.has_color_temperature))
  then
    cmd.has_cold_white = true
    cmd.cold_white = fields.cold_white
    cmd.has_warm_white = true
    cmd.warm_white = fields.warm_white
  elseif COLOR_MODES_SUPPORTING_WHITE[mode] then
    cmd.has_white = true
    cmd.white = fields.white
  end
  return cmd
end

-- Build and send an ESPHome light_command reflecting the given color state.
--- @param fields table|nil The command's color fields, where they are not those of `x`, `y` and `mode`.
--- @param brightness number|nil A brightness sent with it.
local function sendColor(x, y, mode, rateMs, fields, brightness)
  local cmd = fields or buildColorCmdFields(x, y, mode)
  if not cmd then
    return
  end
  cmd.has_state = true
  cmd.state = isLogicallyOn()
  if brightness then
    cmd.has_brightness = true
    cmd.brightness = brightness
  end
  cmd.has_transition_length = true
  cmd.transition_length = (rateMs and rateMs > 0) and rateMs or 0
  sendLightCommand(cmd)
end

local function interpolatedColor(now)
  if not colorRamp or colorRamp.durationMs <= 0 then
    return currentColorX, currentColorY, currentColorMode
  end
  now = now or C4:GetTime()
  local elapsed = now - colorRamp.startTime
  if elapsed >= colorRamp.durationMs then
    return colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode
  end
  -- A light in its combined mode, short of half way through a change of mode,
  -- or in a fade begun in one, is in the color its own fields show.
  local x, y, mode = fadedColor(now)
  if x then
    return x, y, mode
  end
  -- From half way through the change of mode it began, it is in the one it was
  -- sent, whatever command has gone out since.
  local _, past = changingMode(colorRamp.fade, now)
  if past then
    return colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode
  end
  if elapsed <= 0 then
    return colorRamp.startX, colorRamp.startY, colorRamp.targetMode
  end
  local progress = eased(elapsed / colorRamp.durationMs)
  local x = colorRamp.startX + (colorRamp.targetX - colorRamp.startX) * progress
  local y = colorRamp.startY + (colorRamp.targetY - colorRamp.startY) * progress
  return x, y, colorRamp.targetMode
end

-- End a color ramp where it has got to: what replaces it starts there.
function leaveColorRamp(now)
  currentColorX, currentColorY, currentColorMode = interpolatedColor(now)
  cancelColorRampTimers()
  rampingColor = false
  colorRamp = nil
end

function colorRampFinished(targetX, targetY, targetMode)
  cancelColorRampTimers()
  -- A ramp told at an off went out with the preset id the off then dropped.
  local told = colorRamp and colorRamp.told
  rampingColor = false
  colorRamp = nil
  if not told then
    notifyColorChanged(targetX, targetY, targetMode)
  end
end

--- @param level number|nil A level stopped with the color, which the command that holds it carries.
--- @param at number|nil Where on the range's line that level holds a light outside it.
function colorRampStopped(level, at)
  cancelColorRampTimers()
  if not rampingColor then
    return
  end
  local now = C4:GetTime()
  local x, y, mode = interpolatedColor(now)
  -- A light in its combined mode is held with what it has of its color and of
  -- its white, each as far as it is lit, and one changing mode in the mode it is in.
  local fields = fadedFields(now)
  -- The mirror of a level's stop: held over the time a level ramp has left.
  local hold = rampingBrightness and remaining(brightnessRamp) or 0
  -- Part way through a change of mode, or a fade begun in one, the light is
  -- dimmed: it eases back to its level from there, where at once it would jump.
  if dimmedAt(lightFade, now) then
    hold = math.max(hold, MODE_STOP_RATE)
  end
  rampingColor = false
  colorRamp = nil
  sendColor(x, y, mode, hold, fields and holdFields(fields), level and endBrightness(level, at))
  notifyColorChanged(x, y, mode)
  retimeBrightness(hold, true, now)
end

local function rampToColor(targetX, targetY, targetMode, rate)
  rate = math.max(0, tointeger(rate) or 0)
  local now = C4:GetTime()

  -- Drop the on color a brightness ramp carries, or its end would report it.
  leaveMergedColor()
  leaveColorRamp()
  -- A stop of that ramp keeps this color, whether or not it carried one.
  if brightnessRamp then
    brightnessRamp.colorSet = true
  end

  -- A light that is off, or fading to off, has no color fade to show: this is
  -- the color it next comes on in, sent over what a fade to off has left.
  local off = not isLogicallyOn()
  if off then
    rate = rampingBrightness and remaining(brightnessRamp) or 0
  end

  if rate == 0 or off then
    currentColorX = targetX
    currentColorY = targetY
    currentColorMode = targetMode
    sendColor(targetX, targetY, targetMode, rate)
    notifyColorChanged(targetX, targetY, targetMode)
    retimeBrightness(rate, off, now)
    return
  end

  rampingColor = true
  local ramp = {
    startTime = now,
    startX = currentColorX,
    startY = currentColorY,
    targetX = targetX,
    targetY = targetY,
    targetMode = targetMode,
    durationMs = rate,
  }
  colorRamp = ramp
  sendColor(targetX, targetY, targetMode, rate)
  ramp.fade = lightFade
  notifyColorChanging(targetX, targetY, targetMode, rate)
  -- Mode change is logically instantaneous; mid-ramp we're interpolating XY.
  currentColorMode = targetMode
  SetTimer("ColorRampFinish", rate, function()
    colorRampFinished(targetX, targetY, targetMode)
  end, false)
  retimeBrightness(rate, nil, now)
end

---------------------------------------------------------------------------
-- Helpers: on / off / toggle
---------------------------------------------------------------------------

-- An On/Off-only light switches at once, replacing a ramp in flight.
local function switchLight(on)
  stopSceneSteps()
  cancelBrightnessRampTimers()
  rampingBrightness = false
  brightnessRamp = nil
  sendLightCommand({ has_state = true, state = on })
  notifyBrightnessChanged(on and 100 or 0)
end

local function lightOn(rate)
  local level = getOnBrightness()
  if not supportsDimming then
    switchLight(true)
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
    switchLight(false)
  end
end

local function lightToggle(rate)
  if interpolatedBrightness(nil, true) > 0 then
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
    targetX, targetY = C4:ColorCCTtoXY(takenKelvin(kelvin))
    targetMode = LIGHT_COLOR_MODE_CCT
  elseif incomingMode == LIGHT_COLOR_MODE_CCT and supportsCCT and x and y then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if not k or k <= 0 then
      log:warn("SET_COLOR_TARGET: ColorXYtoCCT(%s, %s) returned %s", x, y, tostring(k))
      return
    end
    targetX, targetY, targetMode = takenColor(x, y, LIGHT_COLOR_MODE_CCT)
  elseif x and y and supportsColor then
    targetX, targetY, targetMode = takenColor(x, y, LIGHT_COLOR_MODE_FULL)
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

  -- Skip the ESPHome cmd if a SET_BRIGHTNESS_TARGET right before us already
  -- merged this color into the brightness ramp cmd. Otherwise we'd send a
  -- second cmd to ESPHome that cancels and restarts the in-flight transition,
  -- making the brightness fade-up snap visually. The earlier merged-color
  -- path already emitted notifyColorChanging, and brightnessRampFinished
  -- will emit notifyColorChanged when the ramp completes - so there is
  -- nothing to notify here, just suppress the redundant ESPHome cmd.
  local now = C4:GetTime()
  local merged = rampingBrightness and brightnessRamp and brightnessRamp.mergedColor
  if now < mergedColorUntil and merged and sameColor(merged.x, merged.y, merged.mode, targetX, targetY, targetMode) then
    log:debug("SET_COLOR_TARGET deduped (%sms remaining in merged-color window)", mergedColorUntil - now)
    brightnessRamp.mergedColor = { x = targetX, y = targetY, mode = targetMode }
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
  stopSceneSteps()
  brightnessRampStopped()
end

-- A new range shows the light where its brightness is on it: at once, or at
-- the end of a ramp in flight. The light is not moved.
local function remapLevel()
  if not supportsDimming then
    return
  end
  local ramp = rampingBrightness and brightnessRamp
  if ramp then
    -- The light fades on between the same brightnesses: their places move.
    ramp.startLevel, ramp.startAt = readLevel(ramp.from), outsideAt(ramp.from)
    ramp.targetLevel, ramp.targetAt = readLevel(ramp.to), outsideAt(ramp.to)
    currentBrightness = ramp.startLevel
    SetTimer("BrightnessRampFinish", math.max(1, remaining(ramp)), function()
      brightnessRampFinished(ramp.targetLevel)
    end, false)
    return
  end
  local level = readLevel(lightBrightness or 0)
  if not sameLevel(level, currentBrightness) then
    notifyBrightnessChanged(level)
  end
end

-- Spec _4 / _5: the on-level range, which every level sent and read back is
-- remapped through (onRange); the echo tells the proxy and Composer the
-- setting.
function RFP.SET_MAX_ON_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_MAX_ON_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 100))
  persist:set(P_MAX_ON_LEVEL, level)
  SendToProxy(PROXY_BINDING, "MAX_ON", tostring(level), "NOTIFY")
  remapLevel()
end

function RFP.SET_MIN_ON_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_MIN_ON_LEVEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 0))
  persist:set(P_MIN_ON_LEVEL, level)
  SendToProxy(PROXY_BINDING, "MIN_ON", tostring(level), "NOTIFY")
  remapLevel()
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

-- A level command takes the light out of a scene, as on Control4's own
-- lights: no later step runs. The step in flight still ends its own ramps.
function stopSceneSteps()
  sceneGeneration = sceneGeneration + 1
end

local function stopAllScenes()
  sceneGeneration = sceneGeneration + 1
  CancelTimer(SCENE_RAMP_TIMER)
  local scenes = getScenes()
  for sceneId, _ in pairs(scenes) do
    CancelTimer(SCENE_TIMER_PREFIX .. tostring(sceneId))
  end
  -- A ramp in flight is left to run, as the bulb does: its own timer ends it.
end

local function applySceneStep(step)
  -- Build one combined light_command so the device transitions atomically when
  -- both brightness and color change in the same step.
  if not step.levelEnabled and not step.colorEnabled then
    return 0
  end
  local cmd = {}
  -- ESPHome takes a single transition_length per cmd, so the bulb interpolates
  -- both brightness and color over the longer of the two requested rates. Use
  -- that unified rate for ramp metadata and notify payloads so the proxy's
  -- picker animation, the local STOP-mid-step interpolation, and the SCENE_
  -- TIMER all agree on when the transition actually completes.
  local rate = math.max(step.brightnessRate or 0, step.colorRate or 0)
  local startTime = C4:GetTime()
  -- A level of 0 means "off"; the color block is metadata for the next on.
  -- Don't send color/RGB fields in that case so the device actually turns off.
  local turningOff = step.levelEnabled and step.level == 0
  local replaced = nil
  -- A color ramp, or the color a brightness ramp carries, that the proxy has
  -- been told is on its way.
  local colorInFlight = rampingColor or (brightnessRamp and brightnessRamp.mergedColor)
  local goingOn = false
  local level = nil
  if step.levelEnabled and step.level ~= nil then
    level = supportsDimming and step.level or (step.level > 0 and 100 or 0)
    cmd.has_state = true
    cmd.state = step.level > 0
    if step.level > 0 and supportsDimming then
      cmd.has_brightness = true
      cmd.brightness = toDevice(step.level, onRange())
    end
    -- Scene step is driving brightness directly; clear any active preset id
    -- so subsequent CHANGED notifies don't echo a stale value. Color-only
    -- steps don't touch this so a brightness preset can survive across them.
    currentBrightnessPresetId = nil
    -- A level ends a ramp in flight where it has got to. A color-only step
    -- re-times it instead, below.
    local startAt
    replaced, startAt = leaveBrightnessRamp()
    goingOn = level > 0 and currentBrightness == 0
    -- Only prime a ramp when the level actually moves, as it does for a light
    -- outside the range; an explicit step at the current level with rate>0
    -- would otherwise queue a pointless picker animation and suppress the
    -- next echo for no reason.
    if supportsDimming and rate > 0 and (level ~= currentBrightness or startAt) then
      rampingBrightness = true
      brightnessRamp = {
        startTime = startTime,
        startLevel = currentBrightness,
        startAt = startAt,
        targetLevel = level,
        from = endBrightness(currentBrightness, startAt),
        to = toDevice(level, onRange()),
        durationMs = rate,
        step = step,
      }
      notifyBrightnessChanging(level, rate)
      -- Ends the ramp when the scene is stopped before the step's timer does.
      SetTimer("BrightnessRampFinish", rate, function()
        brightnessRampFinished(level)
      end, false)
    end
  end
  local color = nil
  if step.colorEnabled and step.colorX and step.colorY then
    local x, y, mode = takenColor(step.colorX, step.colorY, step.colorMode or LIGHT_COLOR_MODE_FULL)
    -- A color the light cannot take is none of the step's: nothing of it is sent or told.
    if buildColorCmdFields(x, y, mode) then
      color = { x = x, y = y, mode = mode }
    end
  end
  local ownColor = color
  -- A color alone, for a light that is off or fading to off, is the color it
  -- next comes on in, as a color command's is: the step does not turn it on.
  if ownColor and level == nil and not isLogicallyOn() then
    currentColorPresetId = nil
    rampToColor(color.x, color.y, color.mode, rate)
    return rate
  end
  -- A step that sets a level alone takes the color a level command would.
  if not color and (level or 0) > 0 then
    if getColorOnModeKind() == COLOR_ON_MODE_FADE then
      color = computeFadeColor(step.level)
    elseif goingOn then
      color = resolveOnColor(step.level)
    end
  end
  local colorAtOnce = nil
  -- An on color the light cannot take builds no fields: the step then sets none.
  local colorFields = nil
  if color and not turningOff then
    colorFields = buildColorCmdFields(color.x, color.y, color.mode or LIGHT_COLOR_MODE_FULL)
  end
  local setsColor = colorFields ~= nil
  if setsColor then
    -- The step's color replaces the on color a brightness ramp carries and a
    -- color ramp in flight, each from where it has got to.
    leaveMergedColor()
    leaveColorRamp()
    -- A stop keeps a color of the step's own, as it keeps a color command's.
    if ownColor and brightnessRamp then
      brightnessRamp.colorSet = true
    end
    local mode = color.mode or LIGHT_COLOR_MODE_FULL
    for k, v in pairs(colorFields) do
      cmd[k] = v
    end
    cmd.has_state = true
    cmd.state = true
    currentColorPresetId = nil
    local colorChanged = math.abs(color.x - currentColorX) > 1e-4
      or math.abs(color.y - currentColorY) > 1e-4
      or mode ~= currentColorMode
    if rate > 0 and colorChanged then
      rampingColor = true
      colorRamp = {
        startTime = startTime,
        startX = currentColorX,
        startY = currentColorY,
        targetX = color.x,
        targetY = color.y,
        targetMode = mode,
        durationMs = rate,
        step = step,
      }
      notifyColorChanging(color.x, color.y, mode, rate)
      SetTimer("ColorRampFinish", rate, function()
        colorRampFinished(color.x, color.y, mode)
      end, false)
    elseif colorChanged or colorInFlight then
      colorAtOnce = { x = color.x, y = color.y, mode = mode }
    end
  end
  if next(cmd) ~= nil then
    -- A rate of 0 is sent too, or the device ramps at its default transition.
    cmd.has_transition_length = true
    cmd.transition_length = rate
    if goingOn and rate > 0 and supportsDimming then
      sendPreOn()
    end
    local now = C4:GetTime()
    sendLightCommand(cmd)
    -- The fade the step sets nothing of goes on over the step's transition.
    if not setsColor then
      retimeColor(rate, nil, now)
    elseif rampingColor then
      colorRamp.fade = lightFade
    end
    if level == nil then
      retimeBrightness(rate, nil, now)
    end
    -- A step taken at once is where the light is: what follows starts there.
    -- One landing where a replaced ramp had got to is told too, as its end.
    if level ~= nil and not rampingBrightness and (level ~= currentBrightness or replaced) then
      notifyBrightnessChanged(level)
    end
    if colorAtOnce then
      notifyColorChanged(colorAtOnce.x, colorAtOnce.y, colorAtOnce.mode)
    end
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

  -- Steps run here without waiting: a flash scene with no delay or rate on
  -- any step ends after one pass, where it would otherwise loop forever.
  local ran = 0
  while true do
    if gen ~= sceneGeneration then
      return
    end
    local idx = scene.state + 1
    if idx > #scene.elements then
      if scene.flash and ran < #scene.elements then
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

    -- At the step's end, finish the ramps it primed so their CHANGED notifies
    -- come before the next step. A ramp it did not prime is left alone.
    local function advanceAfter(rampMs)
      local level = brightnessRamp and brightnessRamp.step == step and brightnessRamp
      local color = colorRamp and colorRamp.step == step and colorRamp
      SetTimer(timerName, rampMs, function()
        if level and brightnessRamp == level then
          brightnessRampFinished(level.targetLevel)
        end
        if color and colorRamp == color then
          colorRampFinished(color.targetX, color.targetY, color.targetMode)
        end
        runScene(sceneId, gen)
      end)
    end

    if delay > 0 then
      SetTimer(timerName, delay, function()
        if gen ~= sceneGeneration then
          return
        end
        local rampMs = applySceneStep(step)
        if rampMs > 0 then
          advanceAfter(rampMs)
        else
          runScene(sceneId, gen)
        end
      end)
      return
    end

    local rampMs = applySceneStep(step)
    if rampMs > 0 then
      advanceAfter(rampMs)
      return
    end
    -- otherwise loop synchronously to the next element
    ran = ran + 1
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
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local scenes = getScenes()
  local scene = sceneId and scenes[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  brightnessRampStopped()
  colorRampStopped()
  stopAllScenes()
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
  -- The preset whose edits the on level follows, as UPDATE_BRIGHTNESS_PRESET
  -- brings them.
  persist:set(P_BRIGHTNESS_ON_MODE_PRESET, presetId)
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
  -- The on and dim colors follow an edit of the preset the on mode names.
  local onMode = persist:get(P_COLOR_ON_MODE)
  if onMode and presets[key] then
    for _, p in ipairs({ onMode.onPreset, onMode.fadePreset }) do
      if p.id == presetId and p.origin == PRESET_ORIGIN_DEVICE then
        p.x, p.y, p.mode = presets[key].x, presets[key].y, presets[key].mode
      end
    end
    persist:set(P_COLOR_ON_MODE, onMode)
  end
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

-- The level a click acts on, and its press's hold ramp, dropped here so the
-- click starts from the level the press found. No press: where the light is.
local function rewindToPrePress()
  local snapshot = prePressBrightness
  prePressBrightness = nil
  if snapshot == nil then
    return (interpolatedBrightness(nil, true))
  end
  local hold = rampingBrightness and brightnessRamp or nil
  cancelBrightnessRampTimers()
  rampingBrightness = false
  brightnessRamp = nil
  return snapshot, hold
end

-- Shared button-action implementation. Used by RFP.BUTTON_ACTION (proxy ->
-- driver path, e.g. on-device buttons or programming) and by DO_CLICK /
-- DO_PUSH / DO_RELEASE (button-link path, e.g. a keypad button bound to one
-- of our BUTTON_LINK connections). Returns nothing.
local function handleButtonAction(buttonId, action)
  if action == constants.ButtonActions.PRESS then
    -- Button-down. Snapshot brightness for the click race, then start a hold
    -- ramp at the persisted hold rate. If the proxy decides this was a click,
    -- a RELEASE_CLICK will arrive ~110ms later and the click's ramp starts
    -- from this snapshot.
    -- currentBrightness lags a ramp in flight, so take the light's own level.
    prePressBrightness = interpolatedBrightness(nil, true)
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
    -- A hold ramps to full or off until released; a click, to the on level.
    if buttonId == constants.ButtonIds.TOP then
      rampToBrightness(100, getHoldRateUp())
    elseif buttonId == constants.ButtonIds.BOTTOM then
      rampToBrightness(0, getHoldRateDown())
    elseif buttonId == constants.ButtonIds.TOGGLE then
      if prePressBrightness > 0 then
        rampToBrightness(0, getHoldRateDown())
      else
        rampToBrightness(100, getHoldRateUp())
      end
    end
  elseif action == constants.ButtonActions.RELEASE_HOLD then
    prePressBrightness = nil
    brightnessRampStopped()
  elseif action == constants.ButtonActions.RELEASE_CLICK then
    local effective, hold = rewindToPrePress()
    if buttonId == constants.ButtonIds.TOP then
      if supportsDimming then
        rampToBrightness(getOnBrightness(), getClickRateUp(), nil, hold)
      else
        lightOn()
      end
    elseif buttonId == constants.ButtonIds.BOTTOM then
      if supportsDimming then
        rampToBrightness(0, getClickRateDown(), nil, hold)
      else
        lightOff()
      end
    elseif buttonId == constants.ButtonIds.TOGGLE then
      if supportsDimming then
        if effective > 0 then
          rampToBrightness(0, getClickRateDown(), nil, hold)
        else
          rampToBrightness(getOnBrightness(), getClickRateUp(), nil, hold)
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
  mergedColorUntil = 0
  currentBrightnessPresetId = nil
  currentColorPresetId = nil
  sentBrightness = {}
  sentColors = {}
  lightBrightness = nil
  lightTarget = {}
  lightFade = nil
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

  -- Map ESPHome brightness (0.0-1.0) to C4 (0-100) through the on-level range
  local newBrightness
  local brightness = 0
  local isOn = Select(state, "state") or false
  if not isOn then
    newBrightness = 0
  elseif supportsDimming then
    -- ESPHome sends NaN for the brightness of a light that has not reported one.
    brightness = tofinite(Select(state, "brightness")) or 1.0
    newBrightness = toLevel(brightness, onRange())
  else
    brightness = 1.0
    newBrightness = 100
  end
  local ownLevel = isOwnReport(sentBrightness, function(sent)
    return readLevel(sent) == newBrightness
  end, brightness)
  lightBrightness = ownLevel and sentBrightness[#sentBrightness] or brightness
  local reported = {
    -- ESPHome leaves out the unknown mode of a light given none yet, as it does
    -- any zero: it is compared as any other is.
    color_mode = tointeger(Select(state, "color_mode")) or ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_UNKNOWN,
    color_brightness = tofinite(Select(state, "color_brightness")) or 0,
    red = tofinite(Select(state, "red")) or 0,
    green = tofinite(Select(state, "green")) or 0,
    blue = tofinite(Select(state, "blue")) or 0,
    white = tofinite(Select(state, "white")) or 0,
    color_temperature = tofinite(Select(state, "color_temperature")) or 0,
    cold_white = tofinite(Select(state, "cold_white")) or 0,
    warm_white = tofinite(Select(state, "warm_white")) or 0,
  }
  local ownColor = isOwnReport(sentColors, function(color)
    return holdsColor(state, color)
  end, reported)
  -- Its own, a report is of a command with others sent since. Another
  -- client's is where the light now goes, whatever it was sent before.
  lightTarget = {}
  for i, color in ipairs(ownColor and sentColors or { reported }) do
    aimLight(color, i > 1)
  end

  -- A level or color the light did not last report and the driver never sent
  -- is another client's command: at the bulb that ends both fades.
  local fading = rampingColor or (rampingBrightness and brightnessRamp and brightnessRamp.mergedColor)
  local taken = not (ownLevel and ownColor)
  if taken then
    -- That command began a fade of the light's own, over a time no report gives.
    lightFade = nil
  end

  -- During a ramp ESPHome's echo confirms the level the ramp is heading for,
  -- not where the bulb is, so it is ignored: the ramp's end tells the level.
  if rampingBrightness and taken then
    leaveBrightnessRamp()
    notifyBrightnessChanged(newBrightness)
  elseif rampingBrightness then
    log:trace("UPDATE_STATE brightness=%s ignored (ramping)", newBrightness)
  elseif isFirstUpdate or not sameLevel(newBrightness, currentBrightness) then
    -- Spec note: LIGHT_BRIGHTNESS_CHANGED should always be sent when the
    -- driver starts and/or when the hardware comes online so the proxy is
    -- seeded with the actual brightness, even if it matches our default.
    notifyBrightnessChanged(newBrightness)
  end

  -- A light keeps its color while off, so read it lit or not. A ramp tells its
  -- color, or the one it carries, at its end, unless another client ended it.
  taken = taken and fading
  if taken then
    leaveColorRamp()
  end
  local merged = rampingBrightness and brightnessRamp and brightnessRamp.mergedColor
  if (supportsColor or supportsCCT) and not rampingColor and not merged then
    local newX, newY, newColorMode = shownColor(reported)
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
        or taken
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
  mergedColorUntil = 0
  currentBrightnessPresetId = nil
  currentColorPresetId = nil
  sentBrightness = {}
  sentColors = {}
  lightBrightness = nil
  lightTarget = {}
  lightFade = nil
  currentColorX = DEFAULT_COLOR_X
  currentColorY = DEFAULT_COLOR_Y
  currentColorMode = LIGHT_COLOR_MODE_CCT
  cancelBrightnessRampTimers()
  cancelColorRampTimers()
  stopAllScenes()
end
