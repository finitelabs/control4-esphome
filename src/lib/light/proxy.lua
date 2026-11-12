--- LightProxy: everything the proxy and the Button Links are told, and the reads of the proxy. It is the
--- only module that talks to them. Each tell is the difference between what Motion's view shows and what
--- was told, so a value the proxy already has is never told again.
---
--- Every send is a literal SendToProxy( call, since a suite may replace the global after it loads.

local log = require("lib.logging")
local persist = require("lib.persist")
local values = require("lib.values")
local Caps = require("lib.light.caps")
local Color = require("lib.light.color")
local Range = require("lib.light.range")

require("drivers-common-public.global.lib")
require("lib.utils")

-- The proxy's own variables: the level and its target, the color and its target, and the Navigator
-- Dynamic Capabilities it holds.
local VAR_LEVEL, VAR_LEVEL_TARGET = 1001, 1110
local VAR_COLOR, VAR_COLOR_TARGET = 1200, 1210
local VAR_CAPABILITIES = 6661

-- The capability keys told last that 6661 does not reflect: the proxy holds its rates apart from it,
-- across a driver update too.
local P_RATE_CAPS = "light_rate_caps"

-- The keys whose change makes the proxy rewrite 6661; it may hold any other at an older value.
local REFLECTED = {
  dimmer = true,
  supports_target = true,
  supports_color = true,
  supports_color_correlated_temperature = true,
  has_extras = true,
  cold_start = true,
  color_rate_behavior = true,
  color_rate_min = true,
  color_rate_max = true,
  color_correlated_temperature_min = true,
  color_correlated_temperature_max = true,
}

-- The proxy's three buttons, by the ids BUTTON_ACTION and the setup name them.
local TOP, BOTTOM, TOGGLE = 0, 1, 2
local BUTTON_NAMES = { [TOP] = "Top", [BOTTOM] = "Bottom", [TOGGLE] = "Toggle" }

--- What the proxy was told of the level.
--- @class LightToldLevel
--- @field level integer|nil The C4 level its last CHANGED showed, or the one it showed at start; nil while neither
---   is known, so the first level is told whatever it is.
--- @field preset integer|nil The preset that CHANGED named.
--- @field target integer|nil The target of a CHANGING not yet followed by a CHANGED.
--- @field endsAt integer|nil When that CHANGING's ramp ends, C4:GetTime() ms.
--- @field preOn boolean A CHANGING lit the light from off: at an off the proxy would keep its level 1.

--- What the proxy was told of the color.
--- @class LightToldColor
--- @field color LightColor|nil The color its last CHANGED showed, or the one it showed at start.
--- @field preset integer|nil
--- @field origin integer|nil
--- @field target LightColor|nil The ramp's target, while one is told or taken as arrived.
--- @field endsAt integer|nil When that ramp ends.
--- @field changing boolean A CHANGING was sent for that ramp, so its end is told.

--- A BUTTON_ACTION to echo after the ramp it starts is told.
--- @class LightPress
--- @field button integer
--- @field action integer

--- One button's colors, as hex strings.
--- @class LightButtonColors
--- @field on string
--- @field off string

--- @class LightProxy
--- @field profile LightProfile
--- @field settings LightSettings
--- @field device LightDevice|nil The facts the capabilities were last worked out from.
--- @field toldOnline boolean|nil nil before the first ONLINE_CHANGED of this load.
--- @field readOff boolean A loss read the light off in this outage.
--- @field shownDue boolean The connection's first LightShown is still owed.
--- @field level LightToldLevel
--- @field color LightToldColor
--- @field leds boolean|nil The link LEDs' state told; nil before any.
--- @field caps table<string, boolean|number>|nil The capabilities told or found shown in this load.
--- @field shownTold LightShown|nil
--- @field presses LightPress[]
--- @field echoes table<string, integer> Each setting echo's value as told, by its notify, from the load on.
--- @field buttons table<integer, LightButtonColors> Each button's colors as told, from the load on.
local LightProxy = {}
LightProxy.__index = LightProxy

--- @param profile LightProfile
--- @param settings LightSettings
--- @return LightProxy
function LightProxy.new(profile, settings)
  local self = setmetatable({
    profile = profile,
    settings = settings,
    readOff = false,
    shownDue = false,
    level = { preOn = false },
    color = { changing = false },
    presses = {},
    echoes = {},
    buttons = {},
  }, LightProxy)
  -- The proxy holds the settings this load starts with: only a change is echoed.
  for _, echo in ipairs(self:_echoValues()) do
    self.echoes[echo.notify] = echo.value
  end
  for _, button in ipairs({ TOP, BOTTOM, TOGGLE }) do
    local on, off = settings:buttonColors(button)
    self.buttons[button] = { on = on, off = off }
  end
  return self
end

-----------------------------------------------------------------------------------------------------
-- Reads
-----------------------------------------------------------------------------------------------------

--- The proxy's setup, GET_SETUP's answer, for Settings to parse.
--- @return string|nil
function LightProxy:readSetup()
  local ok, setup = pcall(SendUIRequest, C4:GetProxyDevices(), "GET_SETUP", {})
  if not ok or type(setup) ~= "string" or setup == "" then
    log:warn("The proxy's setup could not be read: %s", ok and "no answer" or tostring(setup))
    return nil
  end
  return setup
end

--- A "x,y,mode" color variable as a LightColor, or nil.
--- @param text string|nil
--- @return LightColor|nil
local function parseColor(text)
  local x, y, mode = string.match(tostring(text or ""), "^([^,]+),([^,]+),([^,]+)$")
  x, y, mode = tonumber(x), tonumber(y), tointeger(mode)
  if not (x and y and x + y > 0 and (mode == 0 or mode == 1)) then
    return nil
  end
  local color = { x = x, y = y, mode = Color.fromProxyMode(mode) }
  if color.mode == Color.CCT then
    color.kelvin = Color.kelvin(x, y)
  end
  return color
end

--- What the proxy shows at start. Its values are what it was told, so none is told again; each goes into
--- the seed only when its target equals it, since a target that differs is a ramp of an earlier load.
--- @return LightSeed
function LightProxy:read()
  local seed = {}
  local ok, level, levelTarget, color, colorTarget = pcall(function()
    local proxy = C4:GetProxyDevices()
    return C4:GetDeviceVariable(proxy, VAR_LEVEL),
      C4:GetDeviceVariable(proxy, VAR_LEVEL_TARGET),
      C4:GetDeviceVariable(proxy, VAR_COLOR),
      C4:GetDeviceVariable(proxy, VAR_COLOR_TARGET)
  end)
  if not ok then
    log:warn("The proxy's level and color could not be read: %s", tostring(level))
    return seed
  end
  level = tointeger(level)
  if level and level >= 0 and level <= 100 then
    self.level.level = level
    -- An On/Off light's proxy has no target: it is told no ramp.
    if levelTarget == nil or tointeger(levelTarget) == level then
      local lo, hi = self.settings:onRange()
      seed.level = Range.toDevice(level, lo, hi)
    end
  end
  local shown = parseColor(color)
  if shown then
    self.color.color = shown
    if colorTarget == color then
      seed.color = shown
    end
  end
  return seed
end

-----------------------------------------------------------------------------------------------------
-- The connection
-----------------------------------------------------------------------------------------------------

--- @param online boolean
function LightProxy:_tellOnline(online)
  self.toldOnline = online
  SendToProxy(self.profile.proxy, "ONLINE_CHANGED", { STATE = online }, "NOTIFY")
  values:update("Connected", online, "BOOL")
end

--- Tell offline, once per outage.
function LightProxy:offline()
  self.shownDue = false
  if self.toldOnline ~= false then
    self:_tellOnline(false)
  end
end

--- The connection's first report: online, the capabilities, and the buttons and preset level the proxy
--- is seeded with after a reload.
--- @param device LightDevice
--- @return boolean told The capabilities were told, so the proxy's setup may now list more.
function LightProxy:online(device)
  self.readOff = false
  self.shownDue = true
  self:_tellOnline(true)
  local told = self:capabilities(device)
  local proxy, links = self.profile.proxy, self.profile.links
  if links then
    -- The three buttons, a string per the NUMBER_BUTTONS notify, then each one's name and colors.
    SendToProxy(proxy, "NUMBER_BUTTONS", "3", "NOTIFY")
    for _, button in ipairs({ TOP, BOTTOM, TOGGLE }) do
      local on, off = self.settings:buttonColors(button)
      SendToProxy(proxy, "BUTTON_INFO", {
        BUTTON_ID = button,
        NAME = BUTTON_NAMES[button],
        ON_COLOR = on,
        OFF_COLOR = off,
      }, "NOTIFY")
      self.buttons[button] = { on = on, off = off }
    end
    -- A keypad keeps the colors it was last told, which may be from before the proxy's were read.
    for _, button in ipairs({ TOP, BOTTOM, TOGGLE }) do
      self:_tellLinkColors(button)
    end
  end
  local presetLevel = self.settings:presetLevel()
  self.echoes.PRESET_LEVEL = presetLevel
  if presetLevel and presetLevel > 0 then
    SendToProxy(proxy, "PRESET_LEVEL", tostring(presetLevel), "NOTIFY")
  end
  return told
end

--- The connection is gone: offline once per outage. A loss, not a suspend, also reads the light off once
--- per outage, its LEDs with it.
--- @param suspended boolean
function LightProxy:lost(suspended)
  self:offline()
  if suspended or self.readOff then
    return
  end
  self.readOff = true
  self:_levelChanged(0, nil)
end

--- A 6661 or light_rate_caps value as the capability it stands for.
--- @param shown string|number|boolean|nil
--- @param want boolean|number
--- @return boolean
local function capSame(shown, want)
  if type(want) == "boolean" then
    return shown == want or shown == (want and "True" or "False")
  end
  return tonumber(shown) == want
end

--- Whether the proxy already holds every capability: the reflected keys in 6661, the rest as told last.
--- @param caps table<string, boolean|number>
--- @return boolean
function LightProxy:_holds(caps)
  local ok, xml = pcall(function()
    return ParseXml(C4:GetDeviceVariable(C4:GetProxyDevices(), VAR_CAPABILITIES))
  end)
  local shown = ok and Select(xml, "DynamicCapabilities") or nil
  if type(shown) ~= "table" then
    return false
  end
  local rates = persist:get(P_RATE_CAPS)
  if type(rates) ~= "table" then
    return false
  end
  local compared = false
  for key, want in pairs(caps) do
    if REFLECTED[key] then
      if shown[key] ~= nil then
        compared = true
        if not capSame(shown[key], want) then
          return false
        end
      end
    elseif not capSame(rates[key], want) then
      return false
    end
  end
  return compared
end

--- Tell the capabilities when the proxy does not hold them. After a controller start the proxy fires its
--- color variables' events for any it is told, so a change is the only reason to tell.
--- @param device LightDevice
--- @return boolean told
function LightProxy:capabilities(device)
  self.device = device
  local caps = Caps.dynamic(device, self.profile)
  if self.caps then
    if Caps.same(caps, self.caps) then
      return false
    end
  elseif self:_holds(caps) then
    log:debug("The proxy shows the light's capabilities")
    self.caps = caps
    return false
  end
  SendToProxy(self.profile.proxy, "DYNAMIC_CAPABILITIES_CHANGED", caps, "NOTIFY", true)
  self.caps = caps
  local rates = {}
  for key, value in pairs(caps) do
    if not REFLECTED[key] then
      rates[key] = value
    end
  end
  persist:set(P_RATE_CAPS, rates)
  return true
end

-----------------------------------------------------------------------------------------------------
-- The tell
-----------------------------------------------------------------------------------------------------

--- The C4 level a device brightness shows at while lit, 0 for none.
--- @param brightness number|nil
--- @param lo integer
--- @param hi integer
--- @return integer
local function shownLevel(brightness, lo, hi)
  if not brightness or brightness <= 0 then
    return 0
  end
  return Range.toLevel(brightness, lo, hi)
end

--- Tell each link's LED whether the light is on. Every link is told the light's own state, the Off link too:
--- its colors carry the Off look, so its LED shows the light off with no inversion here.
--- @param on boolean
--- @param again boolean|nil Tell even what was told.
function LightProxy:_leds(on, again)
  if on == self.leds and not again then
    return
  end
  self.leds = on
  local links = self.profile.links
  if not links then
    return
  end
  SendToProxy(links.top, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
  SendToProxy(links.bottom, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
  SendToProxy(links.toggle, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
end

--- LIGHT_BRIGHTNESS_CHANGED: the level the light is at.
--- @param level integer
--- @param preset integer|nil
function LightProxy:_levelChanged(level, preset)
  local told = self.level
  -- At an off the proxy writes Previous On with the last level it was told, here a pre-on's 1: it is told
  -- the level to keep first, the one it showed lit or, before the light was lit, Previous On's own.
  if level == 0 and told.preOn then
    local keep = (told.level or 0) > 0 and told.level or self.settings:previousOnLevel()
    if keep and keep >= 1 then
      log:debug("LIGHT_BRIGHTNESS_CHANGING: %s to 0, rate=0", keep)
      SendToProxy(self.profile.proxy, "LIGHT_BRIGHTNESS_CHANGING", {
        LIGHT_BRIGHTNESS_CURRENT = keep,
        LIGHT_BRIGHTNESS_TARGET = 0,
        RATE = 0,
      }, "NOTIFY", true)
    end
  end
  if level == 0 and (told.level or 0) > 0 then
    -- The on cycle ends: the color a Previous color on mode restores at the next on is the last one
    -- the proxy was told, and whatever preset drove it no longer applies.
    if self.color.color then
      self.settings:setPreviousColor(self.color.color)
    end
    self.color.preset, self.color.origin = nil, nil
  end
  told.level, told.preset = level, preset
  told.target, told.endsAt, told.preOn = nil, nil, false
  log:debug("LIGHT_BRIGHTNESS_CHANGED: %s", level)
  -- The preset that set this level, so the proxy knows the preset still owns it (Light V2 _10.2).
  SendToProxy(self.profile.proxy, "LIGHT_BRIGHTNESS_CHANGED", {
    LIGHT_BRIGHTNESS_CURRENT = level,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = preset,
  }, "NOTIFY")
  self:_leds(level > 0)
end

--- LIGHT_BRIGHTNESS_CHANGING: the light is on its way to a level.
--- @param current integer
--- @param target integer
--- @param ms integer
--- @param endsAt integer
--- @param preset integer|nil
function LightProxy:_levelChanging(current, target, ms, endsAt, preset)
  local told = self.level
  told.preOn = told.preOn or (target > 0 and (told.level or 0) < 1)
  told.target, told.endsAt, told.preset = target, endsAt, preset
  -- The proxy takes the light's state from CURRENT: one on its way up from off is lit from the start.
  if target > 0 then
    current = math.max(1, current)
  end
  log:debug("LIGHT_BRIGHTNESS_CHANGING: %s to %s, rate=%s", current, target, ms)
  SendToProxy(self.profile.proxy, "LIGHT_BRIGHTNESS_CHANGING", {
    LIGHT_BRIGHTNESS_CURRENT = current,
    LIGHT_BRIGHTNESS_TARGET = target,
    RATE = ms,
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = preset,
  }, "NOTIFY", true)
  -- A light on its way up is on from the start of its ramp, as one fading to off is on until its end.
  if target > 0 then
    self:_leds(true)
  end
end

--- LIGHT_COLOR_CHANGED: the color the light is in.
--- @param color LightColor
--- @param preset integer|nil
--- @param origin integer|nil
function LightProxy:_colorChanged(color, preset, origin)
  local told = self.color
  told.color, told.preset, told.origin = color, preset, origin
  told.changing = false
  log:debug("LIGHT_COLOR_CHANGED: x=%.4f y=%.4f mode=%s", color.x, color.y, color.mode)
  SendToProxy(self.profile.proxy, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = color.x,
    LIGHT_COLOR_CURRENT_Y = color.y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = Color.toProxyMode(color.mode),
    LIGHT_COLOR_CURRENT_PRESET_ID = preset,
    LIGHT_COLOR_CURRENT_PRESET_ORIGIN = preset and origin or nil,
  }, "NOTIFY")
end

--- LIGHT_COLOR_CHANGING: the light is on its way to a color, from the one the proxy shows.
--- @param target LightColor
--- @param ms integer
--- @param endsAt integer
--- @param preset integer|nil
--- @param origin integer|nil
--- @param from LightColor
function LightProxy:_colorChanging(target, ms, endsAt, preset, origin, from)
  local told = self.color
  told.target, told.endsAt, told.changing = target, endsAt, true
  told.preset, told.origin = preset, origin
  log:debug("LIGHT_COLOR_CHANGING: x=%.4f y=%.4f mode=%s rate=%s", target.x, target.y, target.mode, ms)
  SendToProxy(self.profile.proxy, "LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_CURRENT_X = from.x,
    LIGHT_COLOR_CURRENT_Y = from.y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = Color.toProxyMode(from.mode),
    LIGHT_COLOR_TARGET_X = target.x,
    LIGHT_COLOR_TARGET_Y = target.y,
    LIGHT_COLOR_TARGET_COLOR_MODE = Color.toProxyMode(target.mode),
    -- Light V2 _10.7 names the rate LIGHT_COLOR_TARGET_COLOR_RATE; older pages LIGHT_COLOR_TARGET_RATE.
    LIGHT_COLOR_TARGET_COLOR_RATE = ms,
    LIGHT_COLOR_TARGET_RATE = ms,
    LIGHT_COLOR_TARGET_PRESET_ID = preset,
    LIGHT_COLOR_TARGET_PRESET_ORIGIN = preset and origin or nil,
  }, "NOTIFY", true)
end

--- Whether a view's ramp is the one the proxy was told: the same target, ending at the same time.
--- @param toldEnd integer|nil
--- @param endsAt integer
--- @return boolean
local function sameEnd(toldEnd, endsAt)
  return toldEnd ~= nil and math.abs(toldEnd - endsAt) <= 1
end

--- The color's part of the tell. It goes before the level's: at an off the proxy hears the color the
--- light is in, or the one its fade is heading to, ahead of the level.
--- @param view LightView
--- @param now integer
--- @param endsOff boolean The level's part tells an off now.
function LightProxy:_syncColor(view, now, endsOff)
  local told = self.color
  local current = view.color
  if current == nil then
    return
  end
  local lit = view.on or (view.levelTarget ~= nil and view.levelMs > 0)
  local preset, origin = view.colorPreset, view.colorPresetOrigin
  local target = view.colorTarget
  if target ~= nil and view.colorMs > 0 then
    local endsAt = now + view.colorMs
    local same = told.target and Color.alike(told.target, target) and sameEnd(told.endsAt, endsAt)
    if endsOff then
      -- A color still on its way is the one the light is in when it is next seen.
      if told.changing or not same then
        self:_colorChanged(target, preset, origin)
      end
      told.target, told.endsAt = target, endsAt
      return
    end
    if same then
      return
    end
    self:_colorChanging(target, view.colorMs, endsAt, preset, origin, told.color or current)
    return
  end
  local presetMoved = lit and preset ~= nil and (preset ~= told.preset or origin ~= told.origin)
  if told.changing or not Color.alike(current, told.color) or presetMoved then
    self:_colorChanged(current, preset, origin)
  end
  told.target, told.endsAt = nil, nil
end

--- The level's part of the tell.
--- @param view LightView
--- @param now integer
--- @param lo integer
--- @param hi integer
function LightProxy:_syncLevel(view, now, lo, hi)
  local told = self.level
  local preset = view.levelPreset
  if view.levelTarget ~= nil and view.levelMs > 0 then
    local target = view.on and shownLevel(view.levelTarget, lo, hi) or 0
    local endsAt = now + view.levelMs
    if told.target == target and sameEnd(told.endsAt, endsAt) then
      return
    end
    self:_levelChanging(shownLevel(view.level, lo, hi), target, view.levelMs, endsAt, preset)
    return
  end
  local level = view.on and math.max(1, shownLevel(view.level, lo, hi)) or 0
  local presetMoved = level > 0 and preset ~= nil and preset ~= told.preset
  if told.target ~= nil or level ~= told.level or presetMoved then
    self:_levelChanged(level, preset)
  end
end

--- Tell the proxy what differs from what it was told: the color, the level, the button presses, and the
--- settings it echoes.
--- @param view LightView
function LightProxy:sync(view)
  local now = C4:GetTime()
  local lo, hi = self.settings:onRange()
  local ramping = view.levelTarget ~= nil and view.levelMs > 0
  local endsOff = not ramping and not view.on and (self.level.level or 0) > 0
  self:_syncColor(view, now, endsOff)
  self:_syncLevel(view, now, lo, hi)
  -- Echoed after the ramp it starts: echoed first, the proxy snaps its UI to the on or off target and
  -- the CHANGING after it rewinds, a visible jump.
  local presses = self.presses
  self.presses = {}
  for _, press in ipairs(presses) do
    SendToProxy(self.profile.proxy, "BUTTON_ACTION", { BUTTON_ID = press.button, ACTION = press.action }, "NOTIFY")
  end
  self:_syncSettings()
end

--- A setting the proxy hears back once it changes, in the notify that carries it.
--- @class LightEcho
--- @field notify string
--- @field value integer

--- The settings the proxy hears back: the preset level, the click and hold rates, and Max and Min On.
--- @return LightEcho[]
function LightProxy:_echoValues()
  local s = self.settings
  local lo, hi = s:onRange()
  return {
    { notify = "PRESET_LEVEL", value = s:presetLevel() },
    { notify = "CLICK_RATE_UP", value = s:clickRate(true) },
    { notify = "CLICK_RATE_DOWN", value = s:clickRate(false) },
    { notify = "HOLD_RATE_UP", value = s:holdRate(true) },
    { notify = "HOLD_RATE_DOWN", value = s:holdRate(false) },
    { notify = "MAX_ON", value = hi },
    { notify = "MIN_ON", value = lo },
  }
end

--- Echo each setting that changed since it was told, and the colors of each button that changed.
function LightProxy:_syncSettings()
  local proxy = self.profile.proxy
  for _, echo in ipairs(self:_echoValues()) do
    if echo.value ~= self.echoes[echo.notify] then
      self.echoes[echo.notify] = echo.value
      -- Each takes its value as a plain string: a table makes the proxy revert it to 0.
      SendToProxy(proxy, echo.notify, tostring(echo.value), "NOTIFY")
    end
  end
  if not self.profile.links then
    return
  end
  for _, button in ipairs({ TOP, BOTTOM, TOGGLE }) do
    local on, off = self.settings:buttonColors(button)
    local told = self.buttons[button]
    if on ~= told.on or off ~= told.off then
      if on ~= told.on then
        SendToProxy(proxy, "BUTTON_INFO", { BUTTON_ID = button, ON_COLOR = on }, "NOTIFY")
      end
      if off ~= told.off then
        SendToProxy(proxy, "BUTTON_INFO", { BUTTON_ID = button, OFF_COLOR = off }, "NOTIFY")
      end
      self.buttons[button] = { on = on, off = off }
      -- A keypad button bound to this button's link shows the new colors at once.
      self:_tellLinkColors(button)
    end
  end
end

--- The link binding that drives a button.
--- @param button integer
--- @return integer|nil
function LightProxy:_link(button)
  local links = self.profile.links
  if not links then
    return nil
  end
  if button == TOP then
    return links.top
  elseif button == BOTTOM then
    return links.bottom
  end
  return links.toggle
end

--- The button a link binding drives, or nil for the proxy binding and any other.
--- @param idBinding integer|nil
--- @return integer|nil
function LightProxy:_button(idBinding)
  local links = self.profile.links
  if not links or idBinding == nil then
    return nil
  elseif idBinding == links.top then
    return TOP
  elseif idBinding == links.bottom then
    return BOTTOM
  elseif idBinding == links.toggle then
    return TOGGLE
  end
  return nil
end

--- @param button integer
function LightProxy:_tellLinkColors(button)
  local link = self:_link(button)
  if link then
    local on, off = self.settings:buttonColors(button)
    SendToProxy(link, "BUTTON_COLORS", { ON_COLOR = on, OFF_COLOR = off }, "NOTIFY")
  end
end

--- A button press to echo as BUTTON_ACTION at the next sync, after the CHANGING it starts. A link's own
--- DO_* is never echoed: the proxy sent it, so it already knows the button fired.
--- @param button integer
--- @param action integer
--- @param echo boolean|nil True for the proxy's BUTTON_ACTION.
function LightProxy:pressed(button, action, echo)
  if echo == true then
    self.presses[#self.presses + 1] = { button = button, action = action }
  end
end

--- What the proxy shows that a device page may mirror: at each connection's first sync, then whenever it
--- changes. Nil while offline or unchanged.
--- @return LightShown|nil
function LightProxy:shown()
  if self.toldOnline ~= true then
    return nil
  end
  local lo, hi = self.settings:onRange()
  local color = self.color.color
  local kelvin = nil
  if color and color.mode == Color.CCT and self.device and self.device.cct then
    kelvin = color.kelvin or Color.kelvin(color.x, color.y)
    kelvin = kelvin and math.floor(kelvin + 0.5) or nil
  end
  local told = self.shownTold
  if not self.shownDue and told and told.kelvin == kelvin and told.minOn == lo and told.maxOn == hi then
    return nil
  end
  self.shownDue = false
  self.shownTold = { kelvin = kelvin, minOn = lo, maxOn = hi }
  return { kelvin = kelvin, minOn = lo, maxOn = hi }
end

--- A read the proxy, or a keypad over a Button Link, asks.
--- @param strCommand string
--- @param _tParams table<string, string>|nil
--- @param view LightView
--- @param idBinding integer|nil The binding it came on.
function LightProxy:answer(strCommand, _tParams, view, idBinding)
  local proxy = self.profile.proxy
  if strCommand == "GET_CONNECTED_STATE" then
    self:_tellOnline(self.toldOnline == true)
  elseif strCommand == "GET_LIGHT_LEVEL" then
    local lo, hi = self.settings:onRange()
    if view.levelTarget ~= nil and view.levelMs > 0 then
      -- A CHANGED level is one the light has stopped at: a ramp answers where it has got to.
      SendToProxy(proxy, "LIGHT_BRIGHTNESS_CHANGING", {
        LIGHT_BRIGHTNESS_CURRENT = shownLevel(view.level, lo, hi),
        LIGHT_BRIGHTNESS_TARGET = view.on and shownLevel(view.levelTarget, lo, hi) or 0,
        RATE = view.levelMs,
        LIGHT_BRIGHTNESS_TARGET_PRESET_ID = self.level.preset,
      }, "NOTIFY", true)
      return
    end
    if self.level.level == nil then
      -- Nothing read at start and nothing told since: there is no level to answer.
      return
    end
    SendToProxy(proxy, "LIGHT_BRIGHTNESS_CHANGED", {
      LIGHT_BRIGHTNESS_CURRENT = self.level.level,
      LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = self.level.preset,
    }, "NOTIFY")
  elseif strCommand == "REQUEST_BUTTON_COLORS" then
    local asking = self:_button(idBinding)
    if asking ~= nil then
      -- A keypad button bound to a Button Link asks over that link, and is answered on it.
      local on, off = self.settings:buttonColors(asking)
      SendToProxy(idBinding, "BUTTON_COLORS", { ON_COLOR = on, OFF_COLOR = off }, "NOTIFY")
      SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = self.leds == true }, "NOTIFY", true)
      return
    end
    for _, button in ipairs({ TOP, BOTTOM, TOGGLE }) do
      local on, off = self.settings:buttonColors(button)
      SendToProxy(proxy, "BUTTON_COLORS", { BUTTON_ID = button, ON_COLOR = on, OFF_COLOR = off }, "NOTIFY")
    end
    if self.leds ~= nil then
      self:_leds(self.leds, true)
    end
  end
end

return LightProxy
