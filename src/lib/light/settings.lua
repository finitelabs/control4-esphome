--- The proxy's settings a light keeps: presets, on modes, rates, the Min and Max On Level, the Dim-To-Warm
--- presets and the button colors, and the read of the proxy's setup that rebuilds them. Every setting is
--- read through lib.persist at each use, never kept on the instance, so a key deleted under a live light
--- reads as its default next time; only the setup's button colors, read again at every start, live on it.
--- Settings sends nothing: LightProxy tells from these getters.

local log = require("lib.logging")
local persist = require("lib.persist")
local Color = require("lib.light.color")

require("lib.utils")
require("drivers-common-public.global.lib")

--- A preset as UPDATE_COLOR_ON_MODE names it, with the color it holds. The mode is the proxy's own value.
--- @class LightStoredPreset
--- @field id integer|nil
--- @field origin integer|nil
--- @field x number|nil
--- @field y number|nil
--- @field mode integer|nil 0 full color, 1 a color temperature.

--- The persisted color on mode: the On preset, and the Dim one for Dim-To-Warm.
--- @class LightStoredColorOnMode
--- @field onPreset LightStoredPreset
--- @field fadePreset LightStoredPreset

--- The persisted brightness on mode: the preset an On goes to, at its level.
--- @class LightStoredOnMode
--- @field id integer|nil
--- @field level number

--- A brightness preset the proxy sent.
--- @class LightStoredLevelPreset
--- @field id integer
--- @field name string|nil
--- @field level number|nil

--- A color preset the proxy sent.
--- @class LightStoredColorPreset
--- @field id integer
--- @field name string|nil
--- @field x number|nil
--- @field y number|nil
--- @field mode integer|nil

--- A button's saved LED colors, as hex strings.
--- @class LightStoredButtonColors
--- @field on_color string
--- @field off_color string

--- @class LightSettings
--- @field profile LightProfile
--- @field setupColors table<integer, LightButtonColors> Each button's colors in the proxy's setup, by button id,
---   for a button with none saved.
local Settings = {}
Settings.__index = Settings

-- The persisted keys, verbatim, so an existing install keeps its presets and rates. `scenes` is Scenes'.
-- color_presets is kept until v3's open item 6 settles whether a proxy names a preset without coordinates.
Settings.P_PRESET_LEVEL = "preset_level"
Settings.P_CLICK_RATE_UP = "click_rate_up"
Settings.P_CLICK_RATE_DOWN = "click_rate_down"
Settings.P_HOLD_RATE_UP = "hold_rate_up"
Settings.P_HOLD_RATE_DOWN = "hold_rate_down"
Settings.P_RATE_DEFAULT = "brightness_rate_default"
Settings.P_COLOR_RATE_DEFAULT = "color_rate_default"
Settings.P_ON_MODE = "brightness_on_mode"
Settings.P_BUTTON_COLORS = "button_colors"
Settings.P_BRIGHTNESS_PRESETS = "brightness_presets"
Settings.P_COLOR_PRESETS = "color_presets"
Settings.P_COLOR_ON_MODE = "color_on_mode"
Settings.P_PREVIOUS_COLOR = "previous_color"
Settings.P_BRIGHTNESS_ON_MODE_PRESET = "brightness_on_mode_preset"
Settings.P_MAX_ON_LEVEL = "max_on_level"
Settings.P_MIN_ON_LEVEL = "min_on_level"

-- The proxy's own Previous On color and level presets: id 10 among its device presets (origin 1).
Settings.PRESET_ORIGIN_DEVICE = 1
Settings.PREVIOUS_ON_PRESET_ID = 10

local DEFAULT_PRESET_LEVEL = 100
local DEFAULT_CLICK_RATE = 500
local DEFAULT_HOLD_RATE = 3000
local DEFAULT_RATE = 500

--- @param profile LightProfile The checked profile: an on mode counts only where it offers onModes.
--- @return LightSettings
function Settings.new(profile)
  return setmetatable({ profile = profile, setupColors = {} }, Settings)
end

-----------------------------------------------------------------------------------------------------
-- Getters
-----------------------------------------------------------------------------------------------------

--- The Min and Max On Level, percent of the device's brightness; Min is at least 1.
--- @return integer lo
--- @return integer hi
function Settings:onRange()
  local lo = math.max(1, tointeger(persist:get(Settings.P_MIN_ON_LEVEL, 1)) or 1)
  return lo, math.max(lo, tointeger(persist:get(Settings.P_MAX_ON_LEVEL, 100)) or 100)
end

--- The Default On level, as a usable on level: anything under 1 is the default, so an On never turns the
--- light off.
--- @return integer level 1-100.
function Settings:presetLevel()
  local v = tointeger(persist:get(Settings.P_PRESET_LEVEL))
  if not v or v < 1 then
    return DEFAULT_PRESET_LEVEL
  end
  return math.min(v, 100)
end

--- @return integer ms
function Settings:defaultRate()
  return tointeger(persist:get(Settings.P_RATE_DEFAULT, DEFAULT_RATE)) or DEFAULT_RATE
end

--- The color rate default: color_rate_behavior 1 gives one rate for brightness and color.
--- @return integer ms
function Settings:defaultColorRate()
  return tointeger(persist:get(Settings.P_COLOR_RATE_DEFAULT, DEFAULT_RATE)) or DEFAULT_RATE
end

--- @param up boolean
--- @return integer ms
function Settings:clickRate(up)
  local key = up and Settings.P_CLICK_RATE_UP or Settings.P_CLICK_RATE_DOWN
  return tointeger(persist:get(key, DEFAULT_CLICK_RATE)) or DEFAULT_CLICK_RATE
end

--- @param up boolean
--- @return integer ms
function Settings:holdRate(up)
  local key = up and Settings.P_HOLD_RATE_UP or Settings.P_HOLD_RATE_DOWN
  return tointeger(persist:get(key, DEFAULT_HOLD_RATE)) or DEFAULT_HOLD_RATE
end

--- A button's on and off LED colors: saved by SET_BUTTON_COLOR, else the proxy's setup, else empty.
--- @param button integer 0 top, 1 bottom, 2 toggle.
--- @return string onHex
--- @return string offHex
function Settings:buttonColors(button)
  local saved = persist:get(Settings.P_BUTTON_COLORS, {})[tostring(button)]
  local setup = self.setupColors[button]
  -- None invented: a button with neither saved nor setup colors has empty ones, as the copies send.
  local on = saved and saved.on_color or setup and setup.on or ""
  local off = saved and saved.off_color or setup and setup.off or ""
  return on, off
end

--- The level the proxy's Previous On preset holds, as it last sent it.
--- @return number|nil level
function Settings:previousOnLevel()
  local preset = persist:get(Settings.P_BRIGHTNESS_PRESETS, {})[tostring(Settings.PREVIOUS_ON_PRESET_ID)]
  return preset and tonumber(preset.level)
end

--- Keep the color a light went off in, which a Previous color on mode restores at the next on, as the
--- proxy tracks it (Light V2 _7.4). LightProxy calls it when it tells an off.
--- @param color LightColor
function Settings:setPreviousColor(color)
  persist:set(Settings.P_PREVIOUS_COLOR, { x = color.x, y = color.y, mode = Color.toProxyMode(color.mode) })
end

--- A stored preset's color as a LightColor, or nil without both coordinates.
--- @param preset LightStoredPreset|nil
--- @return LightColor|nil
local function presetColor(preset)
  if not preset or preset.x == nil or preset.y == nil then
    return nil
  end
  return { x = preset.x, y = preset.y, mode = Color.fromProxyMode(preset.mode) }
end

--- The color of a color preset the proxy pushed, for a SET_COLOR_TARGET that names only its id.
--- @param id integer
--- @return LightColor|nil
function Settings:colorPreset(id)
  return presetColor(persist:get(Settings.P_COLOR_PRESETS, {})[tostring(id)])
end

--- Which color on mode is in force, as UPDATE_COLOR_ON_MODE's presets tell them apart.
--- @param mode LightStoredColorOnMode|nil
--- @return LightColorOnMode
local function colorOnModeKind(mode)
  if not mode or not mode.fadePreset then
    return "none"
  end
  local fadeOrigin = mode.fadePreset.origin
  if fadeOrigin and fadeOrigin > 0 then
    -- A fade preset with an origin is Dim-To-Warm (origin 1 the device's, 2 an agent's).
    return "fade"
  end
  local onPreset = mode.onPreset
  if
    onPreset
    and onPreset.id == Settings.PREVIOUS_ON_PRESET_ID
    and onPreset.origin == Settings.PRESET_ORIGIN_DEVICE
  then
    return "previous"
  end
  if onPreset and onPreset.x then
    return "preset"
  end
  return "none"
end

--- What an on reads, as plain values for OnColor. Without onModes in the profile no on mode is in force.
--- @return LightOnSettings
function Settings:forOn()
  local lo, hi = self:onRange()
  local on = {
    defaultOn = self.profile.defaultOn == true,
    onModes = self.profile.onModes == true,
    onLo = lo,
    onHi = hi,
    presetLevel = self:presetLevel(),
    colorOnMode = "none",
  }
  if not self.profile.onModes then
    return on
  end
  local onMode = persist:get(Settings.P_ON_MODE)
  local level = onMode and tointeger(onMode.level)
  if level and level >= 1 then
    on.onModeLevel = math.min(level, 100)
  end
  local mode = persist:get(Settings.P_COLOR_ON_MODE)
  on.colorOnMode = colorOnModeKind(mode)
  if on.colorOnMode ~= "none" then
    on.onColor = presetColor(mode.onPreset)
    on.dimColor = presetColor(mode.fadePreset)
    on.onPresetId = mode.onPreset and mode.onPreset.id
    on.onPresetOrigin = mode.onPreset and mode.onPreset.origin
  end
  local previous = persist:get(Settings.P_PREVIOUS_COLOR)
  if previous and previous.x and previous.y then
    on.previousColor = { x = previous.x, y = previous.y, mode = Color.fromProxyMode(previous.mode) }
  end
  return on
end

--- What Motion reads, as plain values passed in with each call that needs them.
--- @return LightMotionSettings
function Settings:forMotion()
  local lo, hi = self:onRange()
  return { lo = lo, hi = hi, rate = self:defaultRate(), colorRate = self:defaultColorRate(), on = self:forOn() }
end

-----------------------------------------------------------------------------------------------------
-- The proxy's setup
-----------------------------------------------------------------------------------------------------

--- The attributes of the element in `list` with this id, and this origin where one is given.
--- @param list table|nil ParseXml's element or list of elements.
--- @param id integer
--- @param origin integer|nil
--- @return table<string, string>|nil attributes
local function setupPreset(list, id, origin)
  list = list or {}
  for _, element in ipairs(IsList(list) and list or { list }) do
    local attr = element._attr or {}
    if tointeger(attr.id) == id and (origin == nil or tointeger(attr.origin) == origin) then
      return attr
    end
  end
end

--- Read the proxy's setup, GET_SETUP's answer. The proxy tells its on modes and default rates only when
--- they change, with no push at start, so a light whose own were never changed has never heard them. An
--- answer that cannot be read leaves what is stored.
--- @param xml string|nil
function Settings:readSetup(xml)
  local ok, setup = pcall(function()
    return Select(ParseXml(xml), "setup")
  end)
  if not ok or type(setup) ~= "table" then
    log:warn("The proxy's setup could not be read: %s", ok and "no setup in its answer" or setup)
    return
  end

  -- A preset id means one preset only with its origin: the device's own and the Color Agent's both count from 1.
  local colors = Select(setup, "colors", "color")
  local onId, onOrigin =
    tointeger(setup.light_color_on_mode_preset_id), tointeger(setup.light_color_on_mode_preset_origin)
  local fadeId = tointeger(setup.light_color_on_mode_fade_preset_id)
  local fadeOrigin = tointeger(setup.light_color_on_mode_fade_preset_origin)
  local on = onId and onOrigin and setupPreset(colors, onId, onOrigin)
  local fade = fadeId and (fadeOrigin or 0) > 0 and setupPreset(colors, fadeId, fadeOrigin) or nil
  if on and fadeOrigin and (fadeOrigin == 0 or fade) then
    fade = fade or {}
    self:_updateColorOnMode({
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
  local levelId = tointeger(setup.light_brightness_on_mode_preset_id)
  local level = levelId and setupPreset(levels, levelId)
  if level and tonumber(level.level) then
    self:_updateBrightnessOnMode({ BRIGHTNESS_PRESET_ID = levelId, BRIGHTNESS_PRESET_LEVEL = level.level })
  end
  -- A preset's level is sent only when it changes, so the setup holds Previous On's, which an unlit ramp's end keeps.
  for _, element in ipairs(IsList(levels) and levels or { levels }) do
    local attr = element._attr or {}
    if tointeger(attr.id) and tonumber(attr.level) then
      self:_updateBrightnessPreset({ ID = attr.id, NAME = attr.name, LEVEL = attr.level })
    end
  end

  -- Each button's colors as the proxy holds them, which a button with none saved shows.
  local buttons = Select(setup, "BUTTON_LIST_INFO", "BUTTON_INFO")
  if type(buttons) == "table" then
    for _, info in ipairs(IsList(buttons) and buttons or { buttons }) do
      local id = tointeger(info.BUTTON_ID)
      if id and type(info.ON_COLOR) == "string" and type(info.OFF_COLOR) == "string" then
        self.setupColors[id] = { on = info.ON_COLOR, off = info.OFF_COLOR }
      end
    end
  end

  local rate = tointeger(setup.light_brightness_rate_default)
  if rate then
    self:_updateBrightnessRateDefault({ RATE = rate })
  end
  rate = tointeger(setup.light_color_rate_default)
  if rate then
    self:_updateColorRateDefault({ RATE = rate })
  end
end

-----------------------------------------------------------------------------------------------------
-- The setting commands
-----------------------------------------------------------------------------------------------------

--- SET_PRESET_LEVEL: the Default On level.
--- @private
--- @param tParams table<string, string>
function Settings:_setPresetLevel(tParams)
  persist:set(Settings.P_PRESET_LEVEL, tointeger(Select(tParams, "LEVEL")) or DEFAULT_PRESET_LEVEL)
end

--- UPDATE_BRIGHTNESS_ON_MODE: the on level, and the preset whose edits it follows.
--- @private
--- @param tParams table<string, string>
function Settings:_updateBrightnessOnMode(tParams)
  local presetId = tointeger(Select(tParams, "BRIGHTNESS_PRESET_ID"))
  local presetLevel = tonumber(Select(tParams, "BRIGHTNESS_PRESET_LEVEL")) or DEFAULT_PRESET_LEVEL
  persist:set(Settings.P_ON_MODE, { id = presetId, level = presetLevel })
  persist:set(Settings.P_BRIGHTNESS_ON_MODE_PRESET, presetId)
end

--- SET_BRIGHTNESS_ON_MODE: the preset an On goes to, at its level as stored.
--- @private
--- @param tParams table<string, string>
function Settings:_setBrightnessOnMode(tParams)
  local presetId = tointeger(Select(tParams, "PRESET_ID"))
  if presetId == nil then
    return
  end
  persist:set(Settings.P_BRIGHTNESS_ON_MODE_PRESET, presetId)
  local preset = persist:get(Settings.P_BRIGHTNESS_PRESETS, {})[tostring(presetId)]
  if preset and preset.level then
    persist:set(Settings.P_ON_MODE, { id = presetId, level = preset.level })
  end
end

--- UPDATE_BRIGHTNESS_PRESET. The on level follows an edit of the preset the on mode names.
--- @private
--- @param tParams table<string, string>
function Settings:_updateBrightnessPreset(tParams)
  local presetId = tointeger(Select(tParams, "ID"))
  if presetId == nil then
    return
  end
  local level = tonumber(Select(tParams, "LEVEL"))
  local presets = persist:get(Settings.P_BRIGHTNESS_PRESETS, {})
  local key = tostring(presetId)
  if Select(tParams, "COMMAND") == "REMOVED" then
    presets[key] = nil
  else
    presets[key] = { id = presetId, name = Select(tParams, "NAME"), level = level }
  end
  persist:set(Settings.P_BRIGHTNESS_PRESETS, presets)
  local activeId = tointeger(persist:get(Settings.P_BRIGHTNESS_ON_MODE_PRESET))
  if activeId ~= nil and activeId == presetId then
    if level == nil then
      persist:delete(Settings.P_ON_MODE)
    else
      persist:set(Settings.P_ON_MODE, { id = presetId, level = level })
    end
  end
end

--- UPDATE_BRIGHTNESS_RATE_DEFAULT. color_rate_behavior 1 shares one rate, so both keys take it.
--- @private
--- @param tParams table<string, string>
function Settings:_updateBrightnessRateDefault(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(Settings.P_RATE_DEFAULT, rate)
  persist:set(Settings.P_COLOR_RATE_DEFAULT, rate)
end

--- UPDATE_COLOR_RATE_DEFAULT, the same shared rate.
--- @private
--- @param tParams table<string, string>
function Settings:_updateColorRateDefault(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(Settings.P_COLOR_RATE_DEFAULT, rate)
  persist:set(Settings.P_RATE_DEFAULT, rate)
end

--- UPDATE_COLOR_PRESET, kept by id for a command the proxy does not start (a link, a scene).
--- @private
--- @param tParams table<string, string>
function Settings:_updateColorPreset(tParams)
  local presetId = tointeger(Select(tParams, "ID"))
  if presetId == nil then
    return
  end
  local presets = persist:get(Settings.P_COLOR_PRESETS, {})
  local key = tostring(presetId)
  if Select(tParams, "COMMAND") == "REMOVED" then
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
  persist:set(Settings.P_COLOR_PRESETS, presets)
  -- The on and dim colors follow an edit of the device preset the on mode names.
  local onMode = persist:get(Settings.P_COLOR_ON_MODE, {})
  if onMode.onPreset and presets[key] then
    for _, p in ipairs({ onMode.onPreset, onMode.fadePreset }) do
      if p.id == presetId and p.origin == Settings.PRESET_ORIGIN_DEVICE then
        p.x, p.y, p.mode = presets[key].x, presets[key].y, presets[key].mode
      end
    end
    persist:set(Settings.P_COLOR_ON_MODE, onMode)
  end
end

--- UPDATE_COLOR_ON_MODE: the On preset, and the Dim one for Dim-To-Warm.
--- @private
--- @param tParams table<string, string|integer|number>
function Settings:_updateColorOnMode(tParams)
  persist:set(Settings.P_COLOR_ON_MODE, {
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
  })
end

--- SET_CLICK_RATE_UP and the three like it: one rate, kept under its key.
--- @private
--- @param key string
--- @param default integer
--- @param tParams table<string, string>
function Settings:_setRate(key, default, tParams)
  persist:set(key, tointeger(Select(tParams, "RATE")) or default)
end

--- SET_MAX_ON_LEVEL and SET_MIN_ON_LEVEL: every level sent and read back maps through the range.
--- @private
--- @param key string
--- @param default integer
--- @param tParams table<string, string>
function Settings:_setOnLevel(key, default, tParams)
  persist:set(key, math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or default)))
end

--- SET_BUTTON_COLOR: a button's on or off LED color, either kept when not named.
--- @private
--- @param tParams table<string, string>
function Settings:_setButtonColor(tParams)
  local button = tointeger(Select(tParams, "BUTTON_ID"))
  if button == nil then
    return
  end
  local colors = persist:get(Settings.P_BUTTON_COLORS, {})
  local key = tostring(button)
  local on, off = self:buttonColors(button)
  colors[key] = {
    on_color = Select(tParams, "ON_COLOR") or on,
    off_color = Select(tParams, "OFF_COLOR") or off,
  }
  persist:set(Settings.P_BUTTON_COLORS, colors)
end

--- Take a setting command.
--- @param strCommand string
--- @param tParams table<string, string>|nil
--- @return boolean taken False for a command that is no setting.
function Settings:apply(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "SET_PRESET_LEVEL" then
    self:_setPresetLevel(tParams)
  elseif strCommand == "UPDATE_BRIGHTNESS_ON_MODE" then
    self:_updateBrightnessOnMode(tParams)
  elseif strCommand == "SET_BRIGHTNESS_ON_MODE" then
    self:_setBrightnessOnMode(tParams)
  elseif strCommand == "UPDATE_BRIGHTNESS_PRESET" then
    self:_updateBrightnessPreset(tParams)
  elseif strCommand == "UPDATE_BRIGHTNESS_RATE_DEFAULT" then
    self:_updateBrightnessRateDefault(tParams)
  elseif strCommand == "UPDATE_COLOR_RATE_DEFAULT" then
    self:_updateColorRateDefault(tParams)
  elseif strCommand == "UPDATE_COLOR_PRESET" then
    self:_updateColorPreset(tParams)
  elseif strCommand == "UPDATE_COLOR_ON_MODE" then
    self:_updateColorOnMode(tParams)
  elseif strCommand == "SET_CLICK_RATE_UP" then
    self:_setRate(Settings.P_CLICK_RATE_UP, DEFAULT_CLICK_RATE, tParams)
  elseif strCommand == "SET_CLICK_RATE_DOWN" then
    self:_setRate(Settings.P_CLICK_RATE_DOWN, DEFAULT_CLICK_RATE, tParams)
  elseif strCommand == "SET_HOLD_RATE_UP" then
    self:_setRate(Settings.P_HOLD_RATE_UP, DEFAULT_HOLD_RATE, tParams)
  elseif strCommand == "SET_HOLD_RATE_DOWN" then
    self:_setRate(Settings.P_HOLD_RATE_DOWN, DEFAULT_HOLD_RATE, tParams)
  elseif strCommand == "SET_MAX_ON_LEVEL" then
    self:_setOnLevel(Settings.P_MAX_ON_LEVEL, 100, tParams)
  elseif strCommand == "SET_MIN_ON_LEVEL" then
    self:_setOnLevel(Settings.P_MIN_ON_LEVEL, 0, tParams)
  elseif strCommand == "SET_BUTTON_COLOR" then
    self:_setButtonColor(tParams)
  else
    return false
  end
  return true
end

return Settings
