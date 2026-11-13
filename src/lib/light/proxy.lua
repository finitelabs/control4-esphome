--- LightProxy: everything the proxy and the Button Links are told, and the reads of the proxy. It is the
--- only module that talks to them. Each tell is the difference between what Motion's view shows and what
--- was told, so a value the proxy already has is never told again.
---
--- Every send is a literal SendToProxy( call, since a suite may replace the global after it loads.

local log = require("lib.logging")
local values = require("lib.values")
local Buttons = require("lib.light.buttons")
local Caps = require("lib.light.caps")
local Color = require("lib.light.color")
local Range = require("lib.light.range")

require("drivers-common-public.global.lib")
require("lib.utils")

-- The proxy's own variables: the level and its target, and the color and its target.
local VAR_LEVEL, VAR_LEVEL_TARGET = 1001, 1110
local VAR_COLOR, VAR_COLOR_TARGET = 1200, 1210

-- The names the setup gives the proxy's three buttons.
local BUTTON_NAMES = { [Buttons.TOP] = "Top", [Buttons.BOTTOM] = "Bottom", [Buttons.TOGGLE] = "Toggle" }

--- What the proxy was told of the level.
--- @class LightToldLevel
--- @field level integer|nil The C4 level its last CHANGED showed, or the one it showed at start; nil while neither
---   is known, so the first level is told whatever it is.
--- @field preset integer|nil The preset that CHANGED named.
--- @field target integer|nil The target of a CHANGING not yet followed by a CHANGED.
--- @field endsAt integer|nil When that CHANGING's ramp ends, C4:GetTime() ms.
--- @field preOn boolean A CHANGING lit the light from off: at an off the proxy would keep its level 1.
--- @field from number|nil That CHANGING's start, device brightness 0-1.
--- @field to number|nil Its end, device brightness.
--- @field startAt integer|nil When it was told, C4:GetTime() ms.
--- @field ms integer|nil Its time.

--- What the proxy was told of the color.
--- @class LightToldColor
--- @field color LightColor|nil The color its last CHANGED showed, or the one it showed at start.
--- @field preset integer|nil
--- @field origin integer|nil
--- @field target LightColor|nil The ramp's target, while one is told or taken as arrived.
--- @field endsAt integer|nil When that ramp ends.
--- @field changing boolean A CHANGING was sent for that ramp, so its end is told.
--- @field atRead LightColor|nil The color the proxy showed at the read, its ramp finished or not.

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
--- @field suspended boolean The connection was stopped on purpose (lost(true)); it ends at the next online.
--- @field ledsDue boolean The connection's first sync tells the link LEDs, after a load or a suspend.
--- @field ledsSent boolean The link LEDs were told in the sync running now.
--- @field asked integer|nil The C4 level the last level command asked: with Min On at Max On or above, it is told.
--- @field presetNamed boolean A proxy color command named a preset: told even while the light is off.
--- @field readOff boolean A loss read the light off in this outage.
--- @field shownDue boolean The connection's first LightShown is still owed.
--- @field resayDue table<string, boolean> "level" and "color": told at the next sync even where the proxy shows
---   them, once the device has reported them since a start or a loss.
--- @field toldSince table<string, boolean> "level" and "color": told since the connection came online.
--- @field level LightToldLevel
--- @field color LightToldColor
--- @field leds boolean|nil The link LEDs' state told; nil before any.
--- @field caps table<string, boolean|number>|nil The capabilities told or found shown in this load.
--- @field shownTold LightShown|nil
--- @field presses LightPress[]
--- @field echoes table<string, integer> Each setting echo's value as told, by its notify, from the load on.
--- @field setupDue boolean The setup was read and Settings has parsed it since: the next sync takes it as held.
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
    suspended = false,
    ledsDue = false,
    ledsSent = false,
    presetNamed = false,
    shownDue = false,
    setupDue = false,
    resayDue = {},
    toldSince = {},
    level = { preOn = false },
    color = { changing = false },
    presses = {},
    echoes = {},
    buttons = {},
  }, LightProxy)
  self:_holdSettings()
  return self
end

--- The proxy holds the settings this load starts with and those its setup gave: an echo answers a setting
--- command, so only a change after this is echoed.
--- @private
function LightProxy:_holdSettings()
  for _, echo in ipairs(self:_echoValues()) do
    self.echoes[echo.notify] = echo.value
  end
  for _, button in ipairs(Buttons.ALL) do
    local on, off = self.settings:buttonColors(button)
    self.buttons[button] = { on = on, off = off }
  end
end

-----------------------------------------------------------------------------------------------------
-- Reads
-----------------------------------------------------------------------------------------------------

--- The proxy's setup, GET_SETUP's answer, for Settings to parse.
--- @return string|nil
function LightProxy:readSetup()
  self.setupDue = true
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

--- What the proxy shows, read at start and at each connection's first report. A value whose target equals it
--- is what the proxy was told, and goes into the seed; one whose target differs is a ramp the proxy still
--- shows, so it counts as untold, and the first report's value is told, ending that ramp.
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
  self.level.target, self.level.endsAt = nil, nil
  -- An On/Off light's proxy has no target: it is told no ramp.
  if level and level >= 0 and level <= 100 and (levelTarget == nil or tointeger(levelTarget) == level) then
    self.level.level = level
    local lo, hi = self.settings:onRange()
    seed.level = Range.toDevice(level, lo, hi)
  else
    self.level.level = nil
  end
  local shown = parseColor(color)
  self.color.atRead = shown
  self.color.target, self.color.endsAt, self.color.changing = nil, nil, false
  if shown and colorTarget == color then
    self.color.color = shown
    seed.color = shown
  else
    self.color.color = nil
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

--- Tell offline, once per outage. The Connected variable is written false every time, so it exists even after
--- the driver's values were reset while the light was already offline.
function LightProxy:offline()
  self.shownDue = false
  self.suspended = false
  if self.toldOnline ~= false then
    self:_tellOnline(false)
  else
    values:update("Connected", false, "BOOL")
  end
end

--- The connection's first report: online, the capabilities, told at every start and reconnect, and the buttons
--- the proxy is seeded with after a reload.
--- @param device LightDevice
--- @return boolean told The capabilities were told, so the proxy's setup may now list more.
function LightProxy:online(device)
  self.readOff = false
  self.toldSince = {}
  self.shownDue = true
  -- After a load, a bind or a suspend a keypad shows the LEDs it was last told, maybe from before.
  self.ledsDue = self.leds == nil or self.suspended
  self.suspended = false
  self:_tellOnline(true)
  local told = self:capabilities(device, true)
  local proxy, links = self.profile.proxy, self.profile.links
  if links then
    -- The three buttons, a string per the NUMBER_BUTTONS notify, then each one's name and colors.
    SendToProxy(proxy, "NUMBER_BUTTONS", "3", "NOTIFY")
    for _, button in ipairs(Buttons.ALL) do
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
    for _, button in ipairs(Buttons.ALL) do
      self:_tellLinkColors(button)
    end
  end
  return told
end

--- The connection is gone: offline once per outage. A loss, not a suspend, also reads the light off once
--- per outage, its LEDs with it.
--- @param suspended boolean
function LightProxy:lost(suspended)
  self:offline()
  if suspended then
    self.suspended = true
    return
  end
  if self.readOff then
    return
  end
  self.readOff = true
  self:_levelChanged(0, nil)
end

--- Tell the capabilities: at a connection's first report whatever they are, and after it whenever they change.
--- @param device LightDevice
--- @param force boolean|nil Tell them even unchanged.
--- @return boolean told
function LightProxy:capabilities(device, force)
  self.device = device
  local caps = Caps.dynamic(device, self.profile)
  if not force and self.caps and Caps.same(caps, self.caps) then
    return false
  end
  SendToProxy(self.profile.proxy, "DYNAMIC_CAPABILITIES_CHANGED", caps, "NOTIFY", true)
  self.caps = caps
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
  self.ledsSent = true
  self:_sendLeds(on)
end

--- Send each link's LED a state, leaving what was told as it was.
--- @private
--- @param on boolean
function LightProxy:_sendLeds(on)
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
--- @param reached integer|nil At an off, the C4 level a ramp from off had lit the light to; nil before it lit.
function LightProxy:_levelChanged(level, preset, reached)
  self.toldSince.level = true
  local told = self.level
  if level == 0 then
    -- An off ends what the last level command asked.
    self.asked = nil
  end
  -- At an off the proxy writes Previous On with the last level it was told, here a pre-on's 1: it is told
  -- the level to keep first: the one it showed lit, else where the ramp from off had got to, else, before
  -- the light was lit, Previous On's own.
  if level == 0 and told.preOn then
    local keep = (told.level or 0) > 0 and told.level or reached or self.settings:previousOnLevel()
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
  told.from, told.to, told.startAt, told.ms = nil, nil, nil, nil
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
--- @param ramp LightView The view it was told from, whose device brightnesses an off reads.
function LightProxy:_levelChanging(current, target, ms, endsAt, preset, ramp)
  self.toldSince.level = true
  local told = self.level
  told.preOn = told.preOn or (target > 0 and (told.level or 0) < 1)
  if target == 0 and told.preOn and (ramp.level or 0) * 100 >= self.settings:onRange() / 2 then
    -- A fade to off from where a ramp from off had lit the light: the proxy keeps that level at the off.
    told.preOn = false
  end
  told.target, told.endsAt, told.preset = target, endsAt, preset
  told.from, told.to, told.startAt, told.ms = ramp.level, ramp.on and ramp.levelTarget or 0, endsAt - ms, ms
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
  self.toldSince.color = true
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
  self.toldSince.color = true
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
    if same and not self.resayDue.color then
      return
    end
    -- From where the color has got to: a re-timed or replacing ramp starts there, not at the last told. Before any
    -- color or ramp is told, from what the proxy shows: its color at the read, or D65 as a white.
    local from = current
    if told.color == nil and not told.changing then
      from = told.atRead or Color.D65
    end
    self:_colorChanging(target, view.colorMs, endsAt, preset, origin, from)
    return
  end
  -- A preset named while the light is off is told at once: Navigator shows that preset as the light's.
  local presetMoved = (lit or self.presetNamed) and preset ~= nil and (preset ~= told.preset or origin ~= told.origin)
  if told.changing or not Color.alike(current, told.color) or presetMoved or self.resayDue.color then
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
  -- With Min On at Max On or above every level sits at one brightness: the level a command asked is the one
  -- told, and a light lit any other way keeps the level told, or is told full coming on from off.
  local asked = lo >= hi and self.asked or nil
  if asked ~= nil and asked <= 0 then
    asked = nil
  end
  if view.levelTarget ~= nil and view.levelMs > 0 then
    local target = view.on and (asked or shownLevel(view.levelTarget, lo, hi)) or 0
    local endsAt = now + view.levelMs
    if told.target == target and sameEnd(told.endsAt, endsAt) and not self.resayDue.level then
      return
    end
    self:_levelChanging(shownLevel(view.level, lo, hi), target, view.levelMs, endsAt, preset, view)
    return
  end
  local lit = asked
  if lit == nil and lo >= hi and (told.level or 0) > 0 then
    lit = told.level
  end
  local level = view.on and math.max(1, lit or shownLevel(view.level, lo, hi)) or 0
  local presetMoved = level > 0 and preset ~= nil and preset ~= told.preset
  if told.target ~= nil or level ~= told.level or presetMoved or self.resayDue.level then
    self:_levelChanged(level, preset, level == 0 and self:_reached(now, lo, hi) or nil)
  end
end

--- Where the ramp the proxy was told had got to, as a C4 level, when an off ends it part way: lit once past half
--- way to Min On; nil before that, or with no ramp told.
--- @private
--- @param now integer
--- @param lo integer
--- @param hi integer
--- @return integer|nil
function LightProxy:_reached(now, lo, hi)
  local told = self.level
  if told.from == nil or told.to == nil or not told.ms or told.ms <= 0 then
    return nil
  end
  local done = math.max(0, math.min(1, (now - told.startAt) / told.ms))
  local at = told.from + (told.to - told.from) * done
  if at * 100 < lo / 2 then
    return nil
  end
  return shownLevel(at, lo, hi)
end

--- Tell the proxy what differs from what it was told: the color, the level, the button presses, and the
--- settings it echoes.
--- @param view LightView
--- @param awaiting table<LightAspect, boolean>|nil Level and color not to tell yet: the Ledger's awaiting.
--- @param now integer|nil The C4:GetTime() ms the view was read at; now when nil.
function LightProxy:sync(view, awaiting, now)
  awaiting = awaiting or {}
  now = now or C4:GetTime()
  local lo, hi = self.settings:onRange()
  local ramping = view.levelTarget ~= nil and view.levelMs > 0
  local endsOff = not ramping and not view.on and (self.level.level or 0) > 0
  self.ledsSent = false
  if not awaiting.color then
    self:_syncColor(view, now, endsOff)
  end
  if not awaiting.level then
    self:_syncLevel(view, now, lo, hi)
  end
  if self.ledsDue then
    self.ledsDue = false
    if not self.ledsSent then
      self:_leds(view.on or (ramping and (self.level.target or 0) > 0), true)
    end
  end
  self.presetNamed = false
  self.resayDue = {}
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
--- @field key string The setting's persist key.
--- @field value integer

--- The settings the proxy hears back: the preset level, the click and hold rates, and Max and Min On.
--- @return LightEcho[]
function LightProxy:_echoValues()
  local s = self.settings
  local lo, hi = s:onRange()
  return {
    { notify = "PRESET_LEVEL", key = s.P_PRESET_LEVEL, value = s:presetLevel() },
    { notify = "CLICK_RATE_UP", key = s.P_CLICK_RATE_UP, value = s:clickRate(true) },
    { notify = "CLICK_RATE_DOWN", key = s.P_CLICK_RATE_DOWN, value = s:clickRate(false) },
    { notify = "HOLD_RATE_UP", key = s.P_HOLD_RATE_UP, value = s:holdRate(true) },
    { notify = "HOLD_RATE_DOWN", key = s.P_HOLD_RATE_DOWN, value = s:holdRate(false) },
    { notify = "MAX_ON", key = s.P_MAX_ON_LEVEL, value = hi },
    { notify = "MIN_ON", key = s.P_MIN_ON_LEVEL, value = lo },
  }
end

--- Echo each setting that changed since it was told, and the colors of each button that changed.
function LightProxy:_syncSettings()
  local commanded = self.settings:takeCommanded()
  if self.setupDue then
    -- The setup re-read: what it gave the settings is the proxy's own. A setting command taken since the
    -- load, offline or not, is still echoed.
    self.setupDue = false
    for _, echo in ipairs(self:_echoValues()) do
      if not commanded[echo.key] then
        self.echoes[echo.notify] = echo.value
      end
    end
    if not commanded[self.settings.P_BUTTON_COLORS] then
      for _, button in ipairs(Buttons.ALL) do
        local on, off = self.settings:buttonColors(button)
        self.buttons[button] = { on = on, off = off }
      end
    end
  end
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
  for _, button in ipairs(Buttons.ALL) do
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
  return Buttons.link(self.profile.links, button)
end

--- The button a link binding drives, or nil for the proxy binding and any other.
--- @param idBinding integer|nil
--- @return integer|nil
function LightProxy:_button(idBinding)
  if idBinding == nil then
    return nil
  end
  return Buttons.forLink(self.profile.links, idBinding)
end

--- @param button integer
function LightProxy:_tellLinkColors(button)
  local link = self:_link(button)
  if link then
    local on, off = self.settings:buttonColors(button)
    SendToProxy(link, "BUTTON_COLORS", { ON_COLOR = on, OFF_COLOR = off }, "NOTIFY")
  end
end

--- A proxy motion command, for what its tell carries that Motion's view does not: the C4 level a level command
--- asked, which a range with no width tells, and the preset a color command named.
--- @param intent LightIntent
function LightProxy:taken(intent)
  local kind = intent.kind
  if kind == "color" then
    self.presetNamed = intent.presetId ~= nil
  elseif kind == "level" then
    self.asked = intent.level
  elseif kind == "on" or kind == "off" or kind == "toggle" then
    self.asked = nil
  end
end

--- Tell these aspects at the next sync even where the proxy already shows them: each one's first report from the
--- device since a start or a loss, which the light tells whatever it is. One already told since the connection
--- came online is not told again.
--- @param aspects LightAspect[]
function LightProxy:resay(aspects)
  for _, aspect in ipairs(aspects) do
    local key = aspect == "color" and "color" or "level"
    if not self.toldSince[key] then
      self.resayDue[key] = true
    end
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
    -- The Kelvin the proxy shows is its own conversion of the xy it holds.
    kelvin = Color.kelvin(color.x, color.y)
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
--- @param _view LightView
--- @param idBinding integer|nil The binding it came on.
function LightProxy:answer(strCommand, _tParams, _view, idBinding)
  local proxy = self.profile.proxy
  if strCommand == "GET_CONNECTED_STATE" then
    self:_tellOnline(self.toldOnline == true)
  elseif strCommand == "GET_LIGHT_LEVEL" then
    -- The level the light holds, online or not: what the proxy was told last or showed at start, so it is
    -- what the proxy shows. With none held there is nothing to answer.
    if self.level.level ~= nil then
      SendToProxy(proxy, "LIGHT_LEVEL", tostring(self.level.level), "NOTIFY")
    end
  elseif strCommand == "REQUEST_BUTTON_COLORS" then
    local asking = self:_button(idBinding)
    if asking ~= nil then
      -- A keypad button bound to a Button Link asks over that link, and is answered on it.
      local on, off = self.settings:buttonColors(asking)
      SendToProxy(idBinding, "BUTTON_COLORS", { ON_COLOR = on, OFF_COLOR = off }, "NOTIFY")
      SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = self:_ledsHeld() }, "NOTIFY", true)
      return
    end
    for _, button in ipairs(Buttons.ALL) do
      local on, off = self.settings:buttonColors(button)
      SendToProxy(proxy, "BUTTON_COLORS", { BUTTON_ID = button, ON_COLOR = on, OFF_COLOR = off }, "NOTIFY")
    end
    self:_sendLeds(self:_ledsHeld())
  end
end

--- Whether the link LEDs show the light on: as told. Before any were told they show it off, as the light's state
--- isn't known until its first report, which then tells them.
--- @private
--- @return boolean
function LightProxy:_ledsHeld()
  return self.leds == true
end

return LightProxy
