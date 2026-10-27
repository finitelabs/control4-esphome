--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_light.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
--#ifndef DRIVERCENTRAL
local mainDriverCatchup = require("esphome.main_driver_catchup")
--#endif

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
-- xy of the last white sent, and the color it was picked as (or the
-- out-of-range color temperature asked for); no report carries either.
local P_WHITE_POINT = "white_point"

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
-- Time (ms) a stop mid color-mode change takes to ease the light back up.
local MODE_STOP_RATE = 500

local LIGHT_COLOR_MODE_FULL = 0
local LIGHT_COLOR_MODE_CCT = 1
-- Driver-only: a full color on the white locus, lit as that white and told
-- to the proxy as the color picked.
local LIGHT_COLOR_MODE_PICKED_WHITE = 2

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

-- Ramp metadata: { startTime, startLevel, targetLevel, durationMs, step };
-- brightness adds from/to/startAt/targetAt, color adds fade. Cleared when no
-- ramp is in flight.
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

-- Last reported value, then each one sent since (oldest first). A report
-- matching none of them came from another client.
local sentBrightness = {}
local sentColors = {}

-- ESPHome answers each command with a report of its own, seen within 250 ms.
local SENT_WAIT = 1000
local sentLevelUntil, sentColorUntil = 0, 0

-- Device brightness (0-1) the light is at or heading to; nil before a report.
local lightBrightness = nil

-- Color/white fields the light is heading to: last report plus sends since.
local lightTarget = {}

-- The transition the last command started: each color/white field fades from
-- `from` toward lightTarget over durationMs, as ESPHome runs it.
local lightFade = nil

-- The main driver dropped the connection itself (UPDATE_DISCONNECT suspended) and the
-- light had a level: it is kept until the device's next report.
local suspended = false

---------------------------------------------------------------------------
-- The proxy's setup
---------------------------------------------------------------------------

--- Attributes of the element in `list` with this id (and origin, if given).
local function setupPreset(list, id, origin)
  list = list or {}
  for _, element in ipairs(IsList(list) and list or { list }) do
    local attr = element._attr or {}
    if tointeger(attr.id) == id and (origin == nil or tointeger(attr.origin) == origin) then
      return attr
    end
  end
end

-- The proxy pushes on modes, brightness presets and default rates only on
-- change, never at start, so read them from its setup.
local function readProxySetup()
  local ok, setup = pcall(function()
    return Select(ParseXml(SendUIRequest(C4:GetProxyDevices(), "GET_SETUP", {})), "setup")
  end)
  if not ok or type(setup) ~= "table" then
    log:warn("The proxy's setup could not be read: %s", ok and "no setup in its answer" or setup)
    return
  end

  -- Match id and origin: device and Color Agent preset ids both start at 1.
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

  local levels = Select(setup, "brightnesses", "level") or {}
  for _, element in ipairs(IsList(levels) and levels or { levels }) do
    local attr = element._attr or {}
    if tointeger(attr.id) and tonumber(attr.level) then
      RFP.UPDATE_BRIGHTNESS_PRESET(
        PROXY_BINDING,
        "UPDATE_BRIGHTNESS_PRESET",
        { ID = attr.id, NAME = attr.name, LEVEL = attr.level }
      )
    end
  end

  local levelId = tointeger(setup.light_brightness_on_mode_preset_id)
  local level = levelId and setupPreset(levels, levelId)
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

  --#ifndef DRIVERCENTRAL
  mainDriverCatchup.schedule()
  --#endif
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
  -- Told only where the proxy's Navigator Dynamic Capabilities (6661) list
  -- another: after a controller start it fires its color variables' events for
  -- any it is told. Whatever it is told, it lists supports_color_stop False
  -- without CCT, and for a light that does not dim supports_brightness_stop
  -- True and brightness_rate_max 0. Before late init the proxy is not read.
  local ok, xml = pcall(function()
    return gInitialized and C4:GetDeviceVariable(C4:GetProxyDevices(), 6661)
  end)
  local shown, same = {}, nil
  for key, value in string.gmatch(ok and tostring(xml or "") or "", "<([%w_]+)>([^<]*)</%1>") do
    shown[key] = value
  end
  local proxyOwn = {
    supports_color_stop = true,
    supports_brightness_stop = not supportsDimming,
    brightness_rate_max = not supportsDimming,
  }
  for key, value in pairs(caps) do
    if shown[key] ~= nil and not proxyOwn[key] then
      local want = type(value) == "boolean" and (value and "True" or "False") or value
      same = same ~= false and (shown[key] == want or tonumber(shown[key]) == want)
    end
  end
  if same then
    log:debug("The proxy shows the light's capabilities")
  else
    SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", caps, "NOTIFY", true)
  end
  -- A new light's setup lists no colors until the proxy hears it has color.
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

-- An RGB / HSV round trip drifts xy by 1-2e-3.
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

-- Device brightness (percent) that levels 1-100 map onto: Min and Max On
-- Level remap the range, as a Control4 dimmer does.
local function onRange()
  local lo = math.max(1, tonumber(persist:get(P_MIN_ON_LEVEL, 1)) or 1)
  return lo, math.max(lo, tonumber(persist:get(P_MAX_ON_LEVEL, 100)) or 100)
end

--- Device brightness (0-1) at level `at` on the line through (1, lo) and
--- (100, hi); extrapolates past either end.
local function lineBrightness(at, lo, hi)
  return (lo + (at - 1) * (hi - lo) / 99) / 100
end

local function toDevice(level, lo, hi)
  return level > 0 and lineBrightness(level, lo, hi) or 0
end

--- Inverse of lineBrightness; nil when the range has no width.
local function linePlace(brightness, lo, hi)
  return hi > lo and 1 + (brightness * 100 - lo) * 99 / (hi - lo) or nil
end

--- Level (1-100) shown for an on brightness, clamped to the range's ends.
local function toLevel(brightness, lo, hi)
  local level = linePlace(brightness, lo, hi) or 100
  return math.max(1, math.min(100, math.floor(level + 0.5)))
end

local function readLevel(brightness)
  return brightness > 0 and toLevel(brightness, onRange()) or 0
end

-- A zero-width range reads every on level back as the same one.
local function sameLevel(a, b)
  local lo, hi = onRange()
  return a == b or (a > 0 and b > 0 and hi == lo)
end

-- Line position of brightness 0: a fade to or from off runs below level 1.
local function offLevel()
  return linePlace(0, onRange()) or 0
end

-- A light left outside the range (e.g. a new one) reads back as the range's
-- end without being there. The 1e-5 margin absorbs float error.
local function outsideRange(brightness)
  local lo, hi = onRange()
  return brightness > 0 and (brightness < lo / 100 - 1e-5 or brightness > hi / 100 + 1e-5)
end

-- Line position of a light outside the range; nil inside it.
local function outsideAt(brightness)
  return outsideRange(brightness) and linePlace(brightness, onRange()) or nil
end

---------------------------------------------------------------------------
-- Helpers: ESPHome light commands
---------------------------------------------------------------------------

local lightColorAt, dimmedAt -- defined with the color ramps below

--- Merge a report's (or a `sent` command's) fields into lightTarget.
local function aimLight(fields, sent)
  local target = {}
  for field, value in pairs(lightTarget) do
    target[field] = value
  end
  -- A color temperature sent with no mode, while the mode has none, moves
  -- ESPHome to its lowest CCT-capable mode (compute_color_mode_).
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

-- The mode ESPHome picks at a turn-on naming none, for a light with no mode
-- yet (e.g. after a restart that restored none).
local function firstColorMode()
  local first
  for mode in pairs(supportedColorModes) do
    if mode >= ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_WHITE and (not first or mode < first) then
      first = mode
    end
  end
  return first
end

-- COLOR_MODE_WHITE on a color light, i.e. an RGBW light built with
-- color_interlock; nil otherwise.
local function ownWhiteMode()
  local white = ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_WHITE
  if supportsColor and supportedColorModes[white] then
    return white
  end
end

local function sendLightCommand(opts)
  -- opts.point is driver-only (never sent); persisting it lets a restart read
  -- the light's white back as the color picked.
  local point = opts.point
  if point then
    opts.point = nil
    local stored = persist:get(P_WHITE_POINT, {})
    local picked, was = point.picked or {}, stored.picked or {}
    -- Skip a plain white unless it clears an old pick or the light's reports
    -- carry no point (ownWhiteMode).
    if
      (point.picked or stored.picked or ownWhiteMode())
      and not (point.x == stored.x and point.y == stored.y and picked.x == was.x and picked.y == was.y)
    then
      persist:set(P_WHITE_POINT, point)
    end
  end
  log:debug("sendLightCommand(%s)", opts)
  -- A disconnected light reports nothing back, so track only when connected.
  -- An On/Off-only light's on carries no brightness and reads back as full.
  if STATE and (opts.has_brightness or opts.state == false or (opts.has_state and not supportsDimming)) then
    sentBrightness[#sentBrightness + 1] = opts.state and (opts.brightness or 1.0) or 0
    lightBrightness = sentBrightness[#sentBrightness]
    sentLevelUntil = C4:GetTime() + SENT_WAIT
    CancelTimer("SentLevel")
  end
  if STATE then
    -- ESPHome restarts every channel from where it is over the new transition,
    -- and holds color and white through a fade to off.
    local now = C4:GetTime()
    local from = lightColorAt(now)
    -- A fade begun while dimmed (mid mode change) brings the light back up.
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
      sentColorUntil = now + SENT_WAIT
      CancelTimer("SentColor")
    elseif
      opts.state
      and currentBrightness == 0
      and lightTarget.color_mode == ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_UNKNOWN
    then
      -- A turn-on naming no mode gives a mode-less light its first mode.
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

--- Whether a report `matches` the last report or a value sent since. Drops
--- the entries before the match and stores `reported` as the first entry.
local function isOwnReport(sent, matches, reported)
  local own = false
  for i, value in ipairs(sent) do
    if matches(value) then
      for _ = 2, i do
        table.remove(sent, 1)
      end
      -- Drop repeats of the matched value sent right after it.
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

--- Whether a state matches a sent color's fields; the tolerance is relative
--- for fields above 1 (mireds).
local function holdsColor(state, color)
  for field, value in pairs(color) do
    local tolerance = COLOR_TOLERANCE * math.max(1, math.abs(value))
    if not (math.abs((tofinite(state[field]) or 0) - value) <= tolerance) then
      return false
    end
  end
  return true
end

local takenColor, heldColor -- defined with the white points below

-- The color to report for a white at xy: the pick stored with the last
-- white sent, if this is that white, else the white itself.
local function shownWhite(x, y)
  local point = persist:get(P_WHITE_POINT)
  local picked = point and point.picked
  if
    picked
    and picked.x
    and picked.y
    and point.x
    and point.y
    and sameColor(x, y, LIGHT_COLOR_MODE_CCT, point.x, point.y, LIGHT_COLOR_MODE_CCT)
  then
    return picked.x, picked.y, picked.mode or LIGHT_COLOR_MODE_PICKED_WHITE
  end
  return x, y, LIGHT_COLOR_MODE_CCT
end

-- xy and mode a light's fields show, or nil. A combined mode shows the
-- color while color_brightness >= white, else the white (shownWhite).
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
    return shownWhite(C4:ColorCCTtoXY(miredsToKelvin(fields.color_temperature)))
  end
  if hasColor and math.max(fields.red, fields.green, fields.blue) > 0 then
    local h, s = rgbToHSV(fields.red, fields.green, fields.blue)
    local x, y = C4:ColorHSVtoXY(h, s, 100)
    if inWhite and mode == CM.COLOR_MODE_RGB_WHITE then
      x, y = takenColor(x, y, LIGHT_COLOR_MODE_CCT)
      return shownWhite(x, y)
    end
    return x, y, LIGHT_COLOR_MODE_FULL
  end
  if mode and mode == ownWhiteMode() then
    local point = persist:get(P_WHITE_POINT)
    if point and point.x and point.y then
      return shownWhite(point.x, point.y)
    end
    local x, y = takenColor(DEFAULT_COLOR_X, DEFAULT_COLOR_Y, LIGHT_COLOR_MODE_CCT)
    return x, y, LIGHT_COLOR_MODE_CCT
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

local function givesMiredsRange()
  return (tonumber(Select(ENTITY, "min_mireds")) or 0) > 0 and (tonumber(Select(ENTITY, "max_mireds")) or 0) > 0
end

-- The light's combined color and white mode (built without color_interlock),
-- or nil for a plain RGB light.
local function combinedColorMode()
  local mode = pickColorMode("rgb")
  if mode ~= ESPHomeProtoSchema.Enum.ColorMode.COLOR_MODE_RGB then
    return mode
  end
end

local isLogicallyOn -- defined with the on modes below

-- The light's current mode if it is CCT-only (e.g. an RGBCT light's white
-- mode), else nil.
local function whiteOnlyMode()
  local mode = lightTarget.color_mode
  if supportedColorModes[mode] and COLOR_MODES_SUPPORTING_CCT[mode] and not COLOR_MODES_SUPPORTING_RGB[mode] then
    return mode
  end
end

-- Light one side of the combined mode with the other off; staying in one mode
-- avoids ESPHome fading a mode change through off.
--- @param white number|boolean|nil Kelvin; true: plain white; nil: color.
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
  -- ESPHome derives cold/warm white from a color temperature, with gamma,
  -- only for a light that reports a mireds range; others get them sent.
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
--- @param merged boolean|nil Part of a level command: a CCT names its mode too.
local function buildColorCmdFields(x, y, mode, merged)
  if not (supportsColor or supportsCCT) or x == nil or y == nil then
    return nil
  end
  -- A picked white goes out as its color temperature and an out-of-range one
  -- is clamped; either way the original is kept as the pick.
  local pick = nil
  if mode == LIGHT_COLOR_MODE_PICKED_WHITE then
    pick = { x = x, y = y }
    x, y, mode = takenColor(x, y, LIGHT_COLOR_MODE_CCT)
  elseif mode == LIGHT_COLOR_MODE_CCT then
    local heldX, heldY = heldColor(x, y, mode)
    if heldX ~= x or heldY ~= y then
      pick = { x = x, y = y, mode = mode }
      x, y = heldX, heldY
    end
  end
  -- Remember the white's xy and pick so reports of it read back as picked.
  local point = mode == LIGHT_COLOR_MODE_CCT and { x = x, y = y, picked = pick } or nil
  if mode == LIGHT_COLOR_MODE_CCT and supportsCCT then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if not k or k <= 0 then
      return nil
    end
    local fields = {
      has_color_temperature = true,
      color_temperature = kelvinToMireds(k),
      point = point,
    }
    local combined = combinedColorMode()
    local pickedMode = pickColorMode("cct")
    if combined and COLOR_MODES_SUPPORTING_CCT[combined] then
      -- Stay in the white-only mode if already there: ESPHome fades a change
      -- of mode through off.
      pickedMode = whiteOnlyMode()
      if not pickedMode then
        return combinedFields(fields, combined, k)
      end
    end
    -- Leave an on light in its mode (a change fades through off). An off color
    -- light needs the mode named, or it keeps one that drops the CCT.
    if not merged and (isLogicallyOn() or not supportsColor) then
      return fields
    end
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    -- As in combinedFields: send cold/warm white only without a mireds range.
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
      -- A plain white is sent with its point's RGB for the report to read back.
      fields.point = point
      return combinedFields(fields, combined, mode == LIGHT_COLOR_MODE_CCT or nil)
    end
    -- A separate white mode reports no point, so keep the one sent.
    local white = mode == LIGHT_COLOR_MODE_CCT and ownWhiteMode()
    if white then
      return { has_color_mode = true, color_mode = white, has_white = true, white = 1, point = point }
    end
    -- Name the mode: an off light in a mode without color would drop it.
    local pickedMode = pickColorMode("rgb")
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    return fields
  end
  return nil
end

-- Clamp to the light's range (the default one for an RGBW white): C4 gives
-- even the color wheel's rim a color temperature.
local function takenKelvin(k)
  return math.max(miredsToKelvin(maxMireds), math.min(miredsToKelvin(minMireds), k))
end

-- Whether the light has a white channel: CCT, or a plain white (RGBW).
local function hasWhiteForPoints()
  return supportsCCT or combinedColorMode() ~= nil or ownWhiteMode() ~= nil
end

-- Max xy distance from a color to its CCT's point (C4 gives the nearest one)
-- to count as a white; holds the wheel's center and picks within 2% in range.
local WHITE_TOLERANCE = 0.012

-- Whether a full color sits on the white locus inside the light's range, so
-- the light shows it with its white.
local function isWhitePoint(x, y)
  local k = hasWhiteForPoints() and tonumber(C4:ColorXYtoCCT(x, y))
  if not k or k <= 0 or k ~= takenKelvin(k) then
    return false
  end
  local whiteX, whiteY = C4:ColorCCTtoXY(k)
  return math.sqrt((x - whiteX) ^ 2 + (y - whiteY) ^ 2) <= WHITE_TOLERANCE
end

-- Normalize a color to what the light shows and reports back. A color on the
-- white locus is told as picked: the proxy matches scenes by the told color.
function takenColor(x, y, mode)
  if mode == LIGHT_COLOR_MODE_PICKED_WHITE then
    mode = LIGHT_COLOR_MODE_FULL
  end
  if mode ~= LIGHT_COLOR_MODE_CCT then
    if not isWhitePoint(x, y) then
      return x, y, mode
    end
    if supportsColor then
      return x, y, LIGHT_COLOR_MODE_PICKED_WHITE
    end
  end
  if not hasWhiteForPoints() then
    return x, y, supportsColor and LIGHT_COLOR_MODE_FULL or mode
  end
  -- A CCT light clamps out-of-range values itself (heldColor): keep as asked.
  local k = tonumber(C4:ColorXYtoCCT(x, y))
  if k and k > 0 then
    x, y = C4:ColorCCTtoXY(supportsCCT and k or takenKelvin(k))
  end
  return x, y, LIGHT_COLOR_MODE_CCT
end

-- Where the light actually ends up: an out-of-range CCT at the range's end.
function heldColor(x, y, mode)
  local k = mode == LIGHT_COLOR_MODE_CCT and supportsCCT and tonumber(C4:ColorXYtoCCT(x, y))
  if k and k > 0 and k ~= takenKelvin(k) then
    return C4:ColorCCTtoXY(takenKelvin(k))
  end
  return x, y
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
  -- Two white-point presets fade between whites. Only the ends decide: a line
  -- between two colors can cross the white locus at one level.
  if isWhitePoint(onPreset.x, onPreset.y) and isWhitePoint(dimPreset.x, dimPreset.y) then
    colorMode = colorMode ~= LIGHT_COLOR_MODE_CCT
        and supportsColor
        and isWhitePoint(x, y)
        and LIGHT_COLOR_MODE_PICKED_WHITE
      or LIGHT_COLOR_MODE_CCT
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

-- The ramp's target state, else ours. A color command sends this so it
-- neither cancels a fade up nor turns a fade to off back on.
function isLogicallyOn()
  if rampingBrightness and brightnessRamp then
    return (brightnessRamp.targetLevel or 0) > 0
  end
  return currentBrightness > 0
end

-- Determine the on-color to use when transitioning from off to on, based on
-- the active color on-mode. Returns {x, y, mode, preset} or nil.
local function resolveOnColor(brightnessLevel)
  if not (supportsColor or supportsCCT) then
    return nil
  end
  local kind = getColorOnModeKind()
  if kind == COLOR_ON_MODE_FADE then
    return computeFadeColor(brightnessLevel)
  end
  local mode = persist:get(P_COLOR_ON_MODE)
  local onPreset = mode and mode.onPreset
  -- The device preset the color is, which the proxy names it by.
  local preset = onPreset and onPreset.origin == PRESET_ORIGIN_DEVICE and onPreset.id or nil
  if kind == COLOR_ON_MODE_PREVIOUS then
    local prev = persist:get(P_PREVIOUS_COLOR)
    if prev and prev.x and prev.y then
      -- Normalize as the proxy's follow-up SET_COLOR_TARGET is, so it dedupes.
      local x, y, colorMode = takenColor(prev.x, prev.y, prev.mode or LIGHT_COLOR_MODE_FULL)
      return { x = x, y = y, mode = colorMode, preset = preset }
    end
  end
  if kind == COLOR_ON_MODE_PRESET and onPreset and onPreset.x and onPreset.y then
    local x, y, colorMode = takenColor(onPreset.x, onPreset.y, onPreset.mode or LIGHT_COLOR_MODE_FULL)
    return { x = x, y = y, mode = colorMode, preset = preset }
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
  -- Tell a color still ramping before the level of 0: the proxy takes its
  -- Previous On color there.
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
  -- The on-cycle's color preset no longer applies once the light is off.
  currentColorPresetId = nil
end

-- Tell the button LEDs whether the light is on, when that has changed.
local function matchLedState(on)
  if on == ledState then
    return
  end
  ledState = on
  -- MATCH_LED_STATE goes to each BUTTON_LINK binding (the keypad button
  -- LEDs), not to the LIGHT_V2 proxy binding. STATE is a Lua boolean per
  -- spec. Bottom is inverted: its LED lights when the light is OFF.
  SendToProxy(ON_BINDING, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
  SendToProxy(OFF_BINDING, "MATCH_LED_STATE", { STATE = not on }, "NOTIFY", true)
  SendToProxy(TOGGLE_BINDING, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
end

-- The last level the proxy was told is a pre-on's 1, not one the light was at.
local preOnTold = false

local function previousOnLevel()
  local preset = (persist:get(P_BRIGHTNESS_PRESETS) or {})[tostring(PREVIOUS_ON_PRESET_ID)]
  return preset and tonumber(preset.level)
end

local function notifyBrightnessChanged(level)
  if level == 0 and currentBrightness > 0 then
    endOnCycle()
  end
  -- The proxy writes Previous On from the last level it was told: where the light got to, or Previous On if unlit.
  if level == 0 and preOnTold then
    local keep = currentBrightness > 0 and currentBrightness or previousOnLevel()
    if keep and keep >= 1 then
      log:debug("LIGHT_BRIGHTNESS_CHANGING: %s to 0, rate=0", keep)
      SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGING", {
        LIGHT_BRIGHTNESS_CURRENT = keep,
        LIGHT_BRIGHTNESS_TARGET = 0,
        RATE = 0,
      }, "NOTIFY", true)
    end
  end
  preOnTold = false
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
  matchLedState(level > 0)
end

--- @param current number|nil The level a ramp in flight has got to.
local function notifyBrightnessChanging(target, rate, current)
  current = current or currentBrightness
  -- The proxy takes the light's state from CURRENT: one on its way up from off is lit by its pre-on.
  preOnTold = target > 0 and current < 1
  current = target > 0 and math.max(1, current) or current
  log:debug("LIGHT_BRIGHTNESS_CHANGING: %s to %s, rate=%s", current, target, rate)
  SendToProxy(PROXY_BINDING, "LIGHT_BRIGHTNESS_CHANGING", {
    LIGHT_BRIGHTNESS_CURRENT = current,
    LIGHT_BRIGHTNESS_TARGET = target,
    RATE = rate,
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = currentBrightnessPresetId,
  }, "NOTIFY", true)
  -- A light on its way up is on from the start of its ramp, as one fading to off is on until its end.
  if target > 0 then
    matchLedState(true)
  end
end

---------------------------------------------------------------------------
-- Helpers: color notifications
---------------------------------------------------------------------------

-- A picked white is told as the color picked, and any white on a light
-- without CCT as a full color: its proxy has no CCT mode.
local function toldMode(mode)
  if
    mode == LIGHT_COLOR_MODE_PICKED_WHITE
    or (mode == LIGHT_COLOR_MODE_CCT and not supportsCCT and hasWhiteForPoints())
  then
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

-- Track a color the bulb is already heading to without a command of its own;
-- the ramp's end only notifies the proxy.
--- @param from table|nil The ramp being carried on (keeps its flags).
--- @param now number|nil When the command that re-timed it went out.
local function carryColor(x, y, mode, ms, from, now)
  local told = from and from.told
  if told then
    -- Already told at an off (endOnCycle), so it is the current color.
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
    startMode = currentColorMode,
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

-- ESPHome runs one transition for every channel: a command without color
-- moves a color in flight over its own transition (at once with none).
--- @param held boolean|nil A stop's hold: keep the end and tell nothing.
--- @param now number|nil When the command went out (the bulb restarts then).
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
-- back into state=false. It carries the ramp's color so a mode change happens
-- here rather than fading through off during the ramp.
--- @param fields table|nil Color fields of the ramp that follows.
local function sendPreOn(fields)
  local cmd = {
    has_state = true,
    state = true,
    has_brightness = true,
    brightness = 0.0039,
    has_transition_length = true,
    transition_length = 0,
  }
  for k, v in pairs(fields or {}) do
    cmd[k] = v
  end
  sendLightCommand(cmd)
end

-- Caller contract: only invoked when supportsDimming is true (lightOn/Off,
-- rampToBrightness, scene apply, etc. all gate on it). On/off-only entities
-- get a different code path that doesn't touch brightness.
--- @param at number|nil Line position for a light held outside the range.
local function setESPHomeBrightness(level, rateMs, keepColor, at)
  local hasRate = rateMs and rateMs > 0
  local goingOn = level > 0 and currentBrightness == 0

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
  local colorFields = nil
  if mergedColor then
    colorFields = buildColorCmdFields(mergedColor.x, mergedColor.y, mergedColor.mode, true)
    if colorFields then
      for k, v in pairs(colorFields) do
        cmd[k] = v
      end
      mergedColorApplied = true
      -- Window during which a follow-up SET_COLOR_TARGET targeting the same
      -- color is treated as already applied. 250ms covers the proxy's
      -- typical inter-cmd gap (~6-50ms) with a margin.
      mergedColorUntil = C4:GetTime() + 250
      -- Told as the device preset the on mode's color is, which the proxy's
      -- follow-up names too; a Dim-To-Warm mix is no preset's.
      currentColorPresetId = mergedColor.preset
      -- Stash on the ramp metadata so brightnessRampFinished can emit the
      -- terminal LIGHT_COLOR_CHANGED when the bulb's combined transition
      -- completes. The proxy needs CHANGING (now) + CHANGED (at finish) to
      -- keep its color-picker animation in sync. A ramped on's pre-on already
      -- lit this color, so onColor only dedupes the proxy's follow-up.
      if brightnessRamp then
        local color = { x = mergedColor.x, y = mergedColor.y, mode = mergedColor.mode, preset = mergedColor.preset }
        if goingOn then
          brightnessRamp.onColor = color
        else
          brightnessRamp.mergedColor = color
        end
      end
    end
  end
  if goingOn and hasRate then
    sendPreOn(colorFields)
  end
  local now = C4:GetTime()
  sendLightCommand(cmd)
  -- Emit color CHANGING/CHANGED to mirror the brightness side: the proxy
  -- doesn't always issue a SET_COLOR_TARGET (e.g. fade mode drives color
  -- from the formula, not from a separate proxy-initiated cmd), so the
  -- driver has to push these notifies for the picker to track.
  if mergedColorApplied then
    -- This color supersedes a color ramp in flight.
    leaveColorRamp(now)
    if hasRate and not goingOn then
      -- currentColor stays the color left until the ramp's end.
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

-- ESPHome's transition easing (LightTransformer::smoothed_progress).
local function eased(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

local function remaining(ramp)
  return math.max(0, ramp.durationMs - (C4:GetTime() - ramp.startTime))
end

--- Level a ramp has the light at, and its line position if outside the range.
--- @param toggle boolean|nil Count as on from half a level above off.
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
  -- Off sits on the line below level 1; under half way to 1 reads as off.
  local off = offLevel()
  local from = ramp.startLevel > 0 and (ramp.startAt or ramp.startLevel) or off
  local to = ramp.targetLevel > 0 and (ramp.targetAt or ramp.targetLevel) or off
  local at = from + (to - from) * progress
  local lit = ramp.startLevel > 0 and ramp.targetLevel > 0
  if not lit and at < (toggle and off + 0.5 or (1 + off) / 2) then
    return 0
  end
  -- Past either end keep the position, except below level 1 on a fade to or
  -- from off, which holds at the Min.
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
  -- Keep a color ramping or set during this ramp; one only carried over from
  -- a replaced ramp belongs to the level.
  local keepColor = (rampingColor and not colorRamp.carried) or brightnessRamp.colorSet
  -- Mid mode change (or a fade begun in one) the light is dimmed.
  local dimmed = not keepColor and stoppedAt > 0 and dimmedAt(lightFade, now)
  if dimmed then
    -- Hold it like a color stop: in its current mode, eased back up to the
    -- level stopped at.
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
  -- A zero-transition stop would snap the color to its target too, so hold
  -- the level over the color's remaining time.
  local hold = keepColor and rampingColor and remaining(colorRamp) or 0
  -- Dimmed without a color ramp: ease the level back up instead of jumping.
  if dimmed then
    hold = MODE_STOP_RATE
  end
  rampingBrightness = false
  brightnessRamp = nil
  if hold > 0 and stoppedAt > 0 then
    -- Not a turn-on: skip setESPHomeBrightness's pre-on.
    currentBrightness = stoppedAt
  end
  setESPHomeBrightness(stoppedAt, hold, keepColor, at)
  notifyBrightnessChanged(stoppedAt)
end

local stopSceneSteps -- defined with the scene support below

-- Move a brightness ramp's merged color to a color ramp from where it has got
-- to: the bulb keeps fading to it whatever replaces the ramp.
function leaveMergedColor()
  local merged = brightnessRamp and brightnessRamp.mergedColor
  if not merged then
    return
  end
  brightnessRamp.mergedColor = nil
  local elapsed = C4:GetTime() - brightnessRamp.startTime
  local progress = eased(math.min(1, elapsed / brightnessRamp.durationMs))
  local fromX, fromY = heldColor(currentColorX, currentColorY, currentColorMode)
  local toX, toY = heldColor(merged.x, merged.y, merged.mode)
  currentColorX = fromX + (toX - fromX) * progress
  currentColorY = fromY + (toY - fromY) * progress
  carryColor(merged.x, merged.y, merged.mode, remaining(brightnessRamp))
end

-- End a brightness ramp where it has got to, so its replacement starts
-- there. Returns the ramp and the light's out-of-range line position.
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

-- Device brightness for a level, or for a line position outside the range.
local function endBrightness(level, at)
  return at and lineBrightness(at, onRange()) or toDevice(level, onRange())
end

-- retimeColor's mirror: a color-only command moves a level in flight on to
-- its target over that command's transition.
--- @param held boolean|nil A stop's hold: keep the end and tell nothing.
--- @param now number|nil When the command went out (the bulb restarts then).
local function retimeBrightness(ms, held, now)
  local ramp, startAt = leaveBrightnessRamp(now)
  if not ramp then
    return
  end
  -- Outside the range a light can show its target level and still be moving.
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

-- With no state from its device (offline, suspended, unbound or not yet heard) the light takes no command, so
-- one that would move it tells the proxy nothing: Control4 keeps what it shows.
local function dropWhileOffline(command)
  if STATE == nil then
    log:debug("%s dropped: the device is offline", command)
  end
  return STATE == nil
end

--- @param replaced table|nil A ramp the caller already ended for this one.
local function rampToBrightness(level, rate, presetId, replaced)
  if dropWhileOffline("Level " .. tostring(level)) then
    return
  end
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
    -- Still send if the bulb is heading elsewhere (a replaced ramp), sits
    -- outside a zero-width range, or is off its Dim-To-Warm color.
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
  -- No final snap: a zero-transition command would jump every other channel
  -- to its target too.
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

--- Whether a fade changes color mode at `now`, and whether it is past half
--- way: ESPHome fades a mode change through off, switching at the midpoint.
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

--- Whether the light is dimmed at `now`: mid mode change, or easing back up
--- from one that had it dimmed when this fade began.
function dimmedAt(fade, now)
  return changingMode(fade, now) or (fade and fade.dimmed and now - fade.startTime < fade.durationMs) or false
end

-- The light's color/white fields at `now`, eased per field as ESPHome does;
-- a mode change shows one end or the other.
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
  -- A light that reported no CCT or no color has nothing to fade those from.
  if from.color_temperature == 0 then
    at.color_temperature = to.color_temperature
  end
  if math.max(from.red, from.green, from.blue) == 0 then
    at.red, at.green, at.blue = to.red, to.green, to.blue
  end
  return at
end

-- The light's own fields where its ramp's xy would mislead: in a combined
-- mode, before the midpoint of a mode change, or in a fade begun dimmed.
local function fadedFields(now)
  local _, past = changingMode(lightFade, now)
  local fields = not past and lightColorAt(now)
  local mode = fields and fields.color_mode
  if supportedColorModes[mode] and (dimmedAt(lightFade, now) or mode == combinedColorMode()) then
    return fields
  end
end

local function fadedColor(now)
  local fields = fadedFields(now)
  if fields then
    return shownColor(fields)
  end
end

-- A command holding the light at `fields` in its mode. It sets every field of
-- the mode: one left out keeps fading to where it was last sent.
local function holdFields(fields)
  local CM = ESPHomeProtoSchema.Enum.ColorMode
  local mode = fields.color_mode
  local cmd = { has_color_mode = true, color_mode = mode }
  if COLOR_MODES_SUPPORTING_RGB[mode] then
    cmd.has_color_brightness = true
    cmd.color_brightness = fields.color_brightness
    -- ESPHome normalizes RGB to a full channel, so move the scale into
    -- color_brightness.
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
  -- Cold/warm white follow the CCT where the light reports a mireds range.
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
--- @param fields table|nil Color fields to send in place of x, y, mode.
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
  -- Read the light's own fields where the xy ramp would mislead (fadedFields).
  local x, y, mode = fadedColor(now)
  if x then
    return x, y, mode
  end
  -- Past the midpoint of the mode change it began, it shows the target.
  local _, past = changingMode(colorRamp.fade, now)
  if past then
    return colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode
  end
  if elapsed <= 0 then
    return colorRamp.startX, colorRamp.startY, colorRamp.targetMode
  end
  local progress = eased(elapsed / colorRamp.durationMs)
  -- Fade between the clamped ends (heldColor).
  local fromX, fromY = heldColor(colorRamp.startX, colorRamp.startY, colorRamp.startMode)
  local toX, toY = heldColor(colorRamp.targetX, colorRamp.targetY, colorRamp.targetMode)
  local x = fromX + (toX - fromX) * progress
  local y = fromY + (toY - fromY) * progress
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
  -- A ramp told at an off is not told again: the off dropped its preset id.
  local told = colorRamp and colorRamp.told
  rampingColor = false
  colorRamp = nil
  if not told then
    notifyColorChanged(targetX, targetY, targetMode)
  end
end

--- @param level number|nil A level stopped with it, sent in the hold command.
--- @param at number|nil That level's line position outside the range.
function colorRampStopped(level, at)
  cancelColorRampTimers()
  if not rampingColor then
    return
  end
  local now = C4:GetTime()
  local x, y, mode = interpolatedColor(now)
  -- Part way to a white the light shows a white; report that white's point.
  if mode == LIGHT_COLOR_MODE_CCT or (mode == LIGHT_COLOR_MODE_PICKED_WHITE and not isWhitePoint(x, y)) then
    x, y, mode = takenColor(x, y, LIGHT_COLOR_MODE_CCT)
  end
  -- In a combined mode or mid mode change, hold the light's own fields.
  local fields = fadedFields(now)
  -- Mirror of brightnessRampStopped: hold over a level ramp's remaining time.
  local hold = rampingBrightness and remaining(brightnessRamp) or 0
  -- Dimmed mid mode change: ease back up rather than jump.
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
  -- A stop of that ramp keeps this color.
  if brightnessRamp then
    brightnessRamp.colorSet = true
  end

  -- Off or fading to off, this is the color for the next on: send it over
  -- what the fade to off has left.
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
    startMode = currentColorMode,
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
  if dropWhileOffline(on and "On" or "Off") then
    return
  end
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
    targetX, targetY = C4:ColorCCTtoXY(kelvin)
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
  -- nothing to notify here, just suppress the redundant ESPHome cmd. A ramped
  -- on's color was told at once; a send naming another preset retells it.
  local now = C4:GetTime()
  local ramp = rampingBrightness and brightnessRamp
  local merged = ramp and (ramp.mergedColor or ramp.onColor)
  if now < mergedColorUntil and merged and sameColor(merged.x, merged.y, merged.mode, targetX, targetY, targetMode) then
    log:debug("SET_COLOR_TARGET deduped (%sms remaining in merged-color window)", mergedColorUntil - now)
    if not ramp.onColor then
      ramp.mergedColor = { x = targetX, y = targetY, mode = targetMode }
    elseif presetId and presetId ~= ramp.onColor.preset then
      notifyColorChanged(targetX, targetY, targetMode)
    end
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

-- Re-read the level through the new range without moving the light; a ramp
-- in flight is re-read at its end.
local function remapLevel()
  if not supportsDimming then
    return
  end
  local ramp = rampingBrightness and brightnessRamp
  if ramp then
    -- The ramp's device brightnesses stay; only their levels move.
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

-- Spec _4 / _5: levels sent and read back are remapped through this range
-- (onRange); the echo keeps the proxy and Composer in step.
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
  -- Until a report is read, only a level a suspend kept is known; a 0 would run Light Off Programming. An on/off
  -- light's proxy asks at a first report's ONLINE_CHANGED, before its level is read: the report tells it.
  if lightBrightness == nil and not suspended then
    return
  end
  -- A CHANGED level is one the light has stopped at: in a ramp, tell where it has got to.
  if rampingBrightness then
    notifyBrightnessChanging(brightnessRamp.targetLevel, remaining(brightnessRamp), (interpolatedBrightness()))
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

-- A level command ends a running scene; the step in flight still finishes its
-- ramps.
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
  -- A color the proxy was told is on its way (color ramp or merged color).
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
    -- End a ramp in flight here (a color-only step re-times it below).
    local startAt
    replaced, startAt = leaveBrightnessRamp()
    goingOn = level > 0 and currentBrightness == 0
    -- Only prime a ramp when the level actually moves (or the light is outside
    -- the range); an explicit step at the current level with rate>0 would
    -- otherwise queue a pointless picker animation and suppress the next echo
    -- for no reason.
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
      -- Ends the ramp even if the scene stops before the step's timer fires.
      SetTimer("BrightnessRampFinish", rate, function()
        brightnessRampFinished(level)
      end, false)
    end
  end
  local color = nil
  if step.colorEnabled and step.colorX and step.colorY then
    local x, y, mode = takenColor(step.colorX, step.colorY, step.colorMode or LIGHT_COLOR_MODE_FULL)
    -- A color the light cannot take is ignored entirely.
    if buildColorCmdFields(x, y, mode) then
      color = { x = x, y = y, mode = mode }
    end
  end
  local ownColor = color
  -- A color-only step on an off light sets the next on's color, like a color
  -- command; it does not turn the light on.
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
  -- A ramped turn-on sends a pre-on first, lighting the step's color at once.
  local preOn = goingOn and rate > 0 and supportsDimming
  local colorFields = nil
  if color and not turningOff then
    colorFields = buildColorCmdFields(color.x, color.y, color.mode or LIGHT_COLOR_MODE_FULL)
  end
  local setsColor = colorFields ~= nil
  if setsColor then
    -- Replace a merged color or color ramp in flight from where it has got to.
    leaveMergedColor()
    leaveColorRamp()
    -- A stop keeps the step's own color, as for a color command.
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
    if rate > 0 and colorChanged and not preOn then
      rampingColor = true
      colorRamp = {
        startTime = startTime,
        startX = currentColorX,
        startY = currentColorY,
        startMode = currentColorMode,
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
    if preOn then
      sendPreOn(colorFields)
    end
    local now = C4:GetTime()
    sendLightCommand(cmd)
    -- Whatever the step does not set keeps fading over its transition.
    if not setsColor then
      retimeColor(rate, nil, now)
    elseif rampingColor then
      colorRamp.fade = lightFade
    end
    if level == nil then
      retimeBrightness(rate, nil, now)
    end
    -- Tell an instant step's level, including one that lands where a replaced
    -- ramp had got to (as that ramp's end).
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

  -- A flash scene with no delay or rate on any step would loop forever here;
  -- stop it after one pass.
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
  if sceneId == nil or dropWhileOffline("Scene " .. sceneId) then
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
  -- So UPDATE_BRIGHTNESS_PRESET edits of this preset move the on level.
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

function RFP.REQUEST_BUTTON_COLORS(idBinding, strCommand, tParams, args)
  log:trace("RFP.REQUEST_BUTTON_COLORS(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    -- A keypad button bound to a button link asks over that link, and is answered on it.
    local buttonId = buttonIdFromBinding(idBinding)
    if buttonId == nil then
      return
    end
    local onColor, offColor = getButtonColors(buttonId)
    SendToProxy(idBinding, "BUTTON_COLORS", { ON_COLOR = onColor, OFF_COLOR = offColor }, "NOTIFY")
    local isOn = ledState
    if idBinding == OFF_BINDING then
      isOn = not isOn
    end
    SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = isOn }, "NOTIFY", true)
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
  -- The MATCH_LED_STATE last sent, per button binding, with bottom inverted (its
  -- LED lights when the light is off so the keypad shows the toggle state correctly).
  local isOn = ledState
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
  -- A keypad button bound to this button's link shows the new colors at once.
  for _, link in ipairs({ ON_BINDING, OFF_BINDING, TOGGLE_BINDING }) do
    if buttonIdFromBinding(link) == buttonId then
      local savedOn, savedOff = getButtonColors(buttonId)
      SendToProxy(link, "BUTTON_COLORS", { ON_COLOR = savedOn, OFF_COLOR = savedOff }, "NOTIFY")
    end
  end
end

---------------------------------------------------------------------------
-- RFP: button actions (from proxy)
---------------------------------------------------------------------------

-- Drop the press's hold ramp; return the level the press found (or the
-- light's level with no press) and that ramp.
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
  -- Before the press's snapshot, which a click after the device is back would start from.
  if dropWhileOffline("Button action " .. tostring(action)) then
    return
  end
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
  -- Here as well as in handleButtonAction: the echo below moves the proxy to the button's on/off target.
  if dropWhileOffline("Button action " .. tostring(action)) then
    return
  end

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

-- Tell the color a report's fields show, if it is not the one told or `force`.
-- A `first` report since a load, bind or disconnect is held against the
-- proxy's Current Color Chromaticity ("x,y,mode") instead, unless its target
-- (a ramp's) is another: it fires Color Changed for any other color it is told.
-- One before late init, when the proxy is not read, is told.
local function tellShownColor(fields, force, first)
  local newX, newY, newColorMode = shownColor(fields)
  if first and newX and newY and newColorMode and not force then
    local ok, value, target = pcall(function()
      if gInitialized then
        local proxy = C4:GetProxyDevices()
        return C4:GetDeviceVariable(proxy, 1200), C4:GetDeviceVariable(proxy, 1210)
      end
    end)
    local x, y, mode = string.match(ok and tostring(value or "") or "", "^([^,]+),([^,]+),([^,]+)$")
    x, y, mode = tonumber(x), tonumber(y), tointeger(mode)
    if x and y and mode and target == value and sameColor(newX, newY, toldMode(newColorMode), x, y, mode) then
      currentColorX, currentColorY, currentColorMode = newX, newY, newColorMode
      return
    end
    force = true
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
      force
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

function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  -- The light runs a fade it was sent to its end, so a suspend keeps the level a ramp in flight is heading to.
  local kept = rampingBrightness and brightnessRamp and brightnessRamp.targetLevel or currentBrightness
  -- A light loaded or bound since its device last reported has no level to keep.
  local known = STATE ~= nil or suspended
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
  -- A device that drops off has usually lost power, so it reads off. A suspended one is as it was: no Light Off
  -- Programming runs, and the device's next report tells its level.
  if toboolean(Select(tParams, "suspended")) then
    suspended = known
    currentBrightness = kept
  else
    suspended = false
    currentBrightness = 0
    notifyBrightnessChanged(0) -- ledState is kept so the button LEDs go off too
  end
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
  suspended = false

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
  -- The light takes commands in order, so a report with a level sent since is
  -- history: it waits for the light's report of that one, as a color's does.
  local levelWait = ownLevel and #sentBrightness > 1 and sentLevelUntil - C4:GetTime() or 0
  if levelWait <= 0 then
    CancelTimer("SentLevel")
  end
  local reported = {
    -- ESPHome omits a zero color_mode (UNKNOWN) like any zero field.
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
  local known = #sentColors > 0
  local ownColor = isOwnReport(sentColors, function(color)
    return holdsColor(state, color)
  end, reported)
  -- Another client's color clears the stored pick; the first report after a
  -- start cannot tell whose it is, so keeps it.
  local point = known and not ownColor and persist:get(P_WHITE_POINT)
  if point and point.picked then
    point.picked = nil
    persist:set(P_WHITE_POINT, point)
  end
  -- Our own report: replay the sends since it. Another client's: it is the
  -- light's new target.
  lightTarget = {}
  for i, color in ipairs(ownColor and sentColors or { reported }) do
    aimLight(color, i > 1)
  end

  -- A level or color we never sent is another client's command, which ends
  -- both fades at the bulb.
  local fading = rampingColor or (rampingBrightness and brightnessRamp and brightnessRamp.mergedColor)
  local taken = not (ownLevel and ownColor)
  if taken then
    -- Its transition time is unknown, so stop modelling the fade.
    lightFade = nil
  end

  -- A first report since a load, bind or disconnect is held against the
  -- proxy's Brightness Percent, unless its target (a ramp's; an on/off light's
  -- proxy has none) is another: after a controller start it fires Brightness
  -- Changed for any level it is told. One told keeps the level a load starts
  -- at, so an off stores no Previous.
  local shownLevel
  if isFirstUpdate then
    local ok, level, target = pcall(function()
      if gInitialized then
        local proxy = C4:GetProxyDevices()
        return C4:GetDeviceVariable(proxy, 1001), C4:GetDeviceVariable(proxy, 1110)
      end
    end)
    level = ok and tointeger(level)
    if level and level >= 0 and level <= 100 and (target == nil or tointeger(target) == level) then
      shownLevel = level
    end
  end

  -- During a ramp ESPHome's echo confirms the level the ramp is heading for,
  -- not where the bulb is, so it is ignored: the ramp's end tells the level.
  if rampingBrightness and taken then
    leaveBrightnessRamp()
    notifyBrightnessChanged(newBrightness)
  elseif rampingBrightness then
    log:trace("UPDATE_STATE brightness=%s ignored (ramping)", newBrightness)
  elseif levelWait > 0 then
    log:trace("UPDATE_STATE brightness=%s held (a level was sent since)", newBrightness)
    SetTimer("SentLevel", levelWait, function()
      if #sentBrightness > 1 and not sameLevel(newBrightness, currentBrightness) then
        notifyBrightnessChanged(newBrightness)
      end
    end)
  elseif shownLevel and sameLevel(newBrightness, shownLevel) then
    currentBrightness = shownLevel
    matchLedState(currentBrightness > 0)
  elseif isFirstUpdate or not sameLevel(newBrightness, currentBrightness) then
    notifyBrightnessChanged(newBrightness)
  end

  -- Read the color even while off (the light keeps it). A ramp tells its own
  -- color at its end unless another client ended it.
  taken = taken and fading
  if taken then
    leaveColorRamp()
  end
  local merged = rampingBrightness and brightnessRamp and brightnessRamp.mergedColor
  if (supportsColor or supportsCCT) and not rampingColor and not merged then
    -- A report from before the color last sent waits up to SENT_WAIT for
    -- the light's report of it; none by then means the light did not take it.
    local wait = ownColor and #sentColors > 1 and sentColorUntil - C4:GetTime() or 0
    if wait > 0 then
      SetTimer("SentColor", wait, function()
        if #sentColors > 1 then
          tellShownColor(reported)
        end
      end)
    else
      CancelTimer("SentColor")
      tellShownColor(reported, taken, isFirstUpdate)
    end
  end
end

---------------------------------------------------------------------------
-- Binding change
---------------------------------------------------------------------------

OBC[ESPHOME_BINDING] = function(_idBinding, _strClass, isBound)
  ENTITY = nil
  STATE = nil
  suspended = false
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
  -- On unbind only: a bind also fires at controller start, when the stored
  -- white is still this light's. The proxy keeps the level it shows.
  if not isBound then
    persist:delete(P_WHITE_POINT)
    updateStatus("Disconnected", false)
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  end
  currentColorX = DEFAULT_COLOR_X
  currentColorY = DEFAULT_COLOR_Y
  currentColorMode = LIGHT_COLOR_MODE_CCT
  cancelBrightnessRampTimers()
  cancelColorRampTimers()
  stopAllScenes()
end
