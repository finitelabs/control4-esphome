--- The light's three buttons, from BUTTON_ACTION and from the Button Links: presses, holds and clicks as
--- intents for Motion.
---
--- On a light that dims, a press waits 250 ms before its hold ramp starts. A click or release of any button, or
--- another press, ends the wait; a command meanwhile leaves it, as the button is still down. A click is the click
--- action: Top ramps to the on mode's level, else the Default On level, over the click rate up, Bottom to off over
--- the click rate down, and Toggle does Bottom's if lit, else Top's. A release stops a hold or a scene ramp still
--- running, whoever started it, and leaves any other fade. A hold's time is the hold rate scaled by the distance
--- left. Toggle's hold goes down at full and up at off, and otherwise the other way from the last ramp of any
--- source. A light that doesn't dim acts at the press (On, Off, Toggle), and the click or release after it asks
--- nothing.

local Range = require("lib.light.range")
local Timer = require("lib.light.timer")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local GATE_TIMER = "Light.Gate"
local GATE_MS = 250

--- @class LightButtons
--- @field light Light
--- @field settings LightSettings
--- @field press LightPress|nil The press in hand, from its PRESS to its release.
--- @field dims boolean The device dims: presses wait for the gate.
--- @field ramping boolean A hold or a scene ramp runs, which a release stops; any other intent ends it.
--- @field restLit boolean|nil The light was lit where it last rested, before the fade now running: what the
---   proxy was last told Changed, which a click in a fade reads.
--- @field nextRamp LightHoldDirection|nil Where Toggle's next hold goes between full and off: up after a ramp to
---   off, else down; nil until the first event, which takes it from the light: down if lit, up if off.
local Buttons = {}
Buttons.__index = Buttons

--- The proxy's three buttons.
Buttons.TOP = 0
Buttons.BOTTOM = 1
Buttons.TOGGLE = 2

--- The three, in the order the proxy numbers them.
--- @type integer[]
Buttons.ALL = { Buttons.TOP, Buttons.BOTTOM, Buttons.TOGGLE }

--- The actions BUTTON_ACTION and the links report.
Buttons.RELEASE_HOLD = 0
Buttons.PRESS = 1
Buttons.RELEASE_CLICK = 2

--- @alias LightHoldDirection "up"|"down"

--- One button press.
--- @class LightPress
--- @field button integer
--- @field prePress integer The C4 level the press found: a click decides from it.
--- @field direction LightHoldDirection Where a hold goes.
--- @field waiting boolean The 250 ms gate runs.
--- @field acted boolean A light that doesn't dim took the click action at the press: the release asks nothing.

--- @param light Light
--- @param settings LightSettings
--- @return LightButtons
function Buttons.new(light, settings)
  return setmetatable(
    { light = light, settings = settings, press = nil, dims = true, ramping = false, nextRamp = nil },
    Buttons
  )
end

--- The device's facts: whether presses wait for the gate.
--- @param device LightDevice
function Buttons:declare(device)
  self.dims = device.dims
end

--- Every intent, from any source: a ramp sets where Toggle's next hold goes.
--- @param intent LightIntent
--- @param now LightNow
function Buttons:noted(intent, now)
  if not now.levelRamping then
    self.restLit = now.on == true
  end
  self.ramping = intent.ramp == true
  if intent.ramp then
    self.nextRamp = (intent.level or 0) <= 0 and "up" or "down"
  end
end

--- Take Toggle's first hold direction from the light, at the first press no ramp has set it before.
--- @private
--- @param now LightNow
function Buttons:_start(now)
  if self.nextRamp == nil then
    self.nextRamp = now.on == true and "down" or "up"
  end
end

--- The Button Link binding that drives a button.
--- @param links LightLinks|nil
--- @param button integer
--- @return integer|nil idBinding
function Buttons.link(links, button)
  if not links then
    return nil
  elseif button == Buttons.TOP then
    return links.top
  elseif button == Buttons.BOTTOM then
    return links.bottom
  elseif button == Buttons.TOGGLE then
    return links.toggle
  end
  return nil
end

--- The button a Button Link binding drives.
--- @param links LightLinks|nil
--- @param idBinding integer
--- @return integer|nil button
function Buttons.forLink(links, idBinding)
  if not links then
    return nil
  elseif idBinding == links.top then
    return Buttons.TOP
  elseif idBinding == links.bottom then
    return Buttons.BOTTOM
  elseif idBinding == links.toggle then
    return Buttons.TOGGLE
  end
  return nil
end

--- The C4 level a press or a click finds the light at: 0 while off. In a fade, the light as it last rested: one
--- fading up from off is off, one fading to off is lit. Otherwise, with the view, where it has got to, off until
--- half a level above off; without it, where it heads.
--- @private
--- @param now LightNow
--- @param view LightView|nil
--- @return integer
function Buttons:_level(now, view)
  local lo, hi = self.settings:onRange()
  if view and view.levelTarget ~= nil and self.restLit ~= nil then
    -- In a fade the light is as it last rested: one fading up from off is off, one fading to off is lit.
    if not self.restLit then
      return 0
    end
    return math.max(1, Range.toLevel(view.level, lo, hi))
  end
  if view then
    if view.level <= 0 then
      return 0
    end
    local at, off = Range.linePlace(view.level, lo, hi), Range.linePlace(0, lo, hi)
    if at and off and at < off + 0.5 then
      return 0
    end
    return math.max(1, Range.toLevel(view.level, lo, hi))
  end
  if now.on ~= true then
    return 0
  end
  return Range.toLevel(now.level, lo, hi)
end

--- Where a hold of this button goes from this level. Toggle goes down from full and up from off, and
--- otherwise the other way from the last ramp.
--- @private
--- @param button integer
--- @param level integer
--- @return LightHoldDirection
function Buttons:_direction(button, level)
  if button == Buttons.TOP then
    return "up"
  elseif button == Buttons.BOTTOM then
    return "down"
  elseif level >= 100 then
    return "down"
  elseif level <= 0 then
    return "up"
  end
  return self.nextRamp or "down"
end

--- The click action. On a light that dims: Top ramps to the on mode's level, else the Default On level, over
--- the click rate up, Bottom to off over the click rate down, and Toggle does Bottom's if lit, else Top's. On
--- one that doesn't: On, Off and Toggle.
--- @private
--- @param button integer
--- @param level integer The C4 level the light is at.
--- @return LightIntent
function Buttons:_click(button, level)
  if not self.dims then
    local kind = button == Buttons.TOP and "on" or button == Buttons.BOTTOM and "off" or "toggle"
    return { kind = kind, source = "button" }
  end
  local up = button == Buttons.TOP or (button == Buttons.TOGGLE and level <= 0)
  return {
    kind = "level",
    level = up and self.settings:clickLevel() or 0,
    rateMs = self.settings:clickRate(up),
    source = "button",
  }
end

--- End the press in hand and its gate.
--- @private
--- @return LightPress|nil press
function Buttons:_endPress()
  local press = self.press
  self.press = nil
  CancelTimer(GATE_TIMER)
  return press
end

--- A press, a release after a hold, or a release after a click.
--- @param button integer 0 top, 1 bottom, 2 toggle.
--- @param action integer 0 release after a hold, 1 press, 2 release after a click.
--- @param now LightNow
--- @param view LightView|nil Where the light has got to, which a press and a click read.
--- @return LightIntent|nil
function Buttons:action(button, action, now, view)
  if button ~= Buttons.TOP and button ~= Buttons.BOTTOM and button ~= Buttons.TOGGLE then
    return nil
  end
  self:_start(now)
  if action == Buttons.PRESS then
    self:_endPress()
    local level = self:_level(now, view)
    if not self.dims then
      self.press = { button = button, prePress = level, direction = "up", waiting = false, acted = true }
      return self:_click(button, level)
    end
    self.press = {
      button = button,
      prePress = level,
      direction = self:_direction(button, level),
      waiting = true,
      acted = false,
    }
    local light = self.light
    Timer.arm(GATE_TIMER, GATE_MS, function()
      light:_gateEnded()
    end, false)
    return nil
  elseif action == Buttons.RELEASE_HOLD then
    self:_endPress()
    if self.dims and self.ramping then
      self.ramping = false
      return { kind = "stopLevel", source = "button" }
    end
    return nil
  elseif action == Buttons.RELEASE_CLICK then
    local press = self:_endPress()
    if press and press.acted then
      return nil
    end
    return self:_click(button, press and press.prePress or self:_level(now, view))
  end
  return nil
end

--- Where the light has got to, as a C4 level: 0 while off.
--- @private
--- @param view LightView
--- @return integer
function Buttons:_at(view)
  if not view.on or view.level <= 0 then
    return 0
  end
  local lo, hi = self.settings:onRange()
  return math.max(1, Range.toLevel(view.level, lo, hi))
end

--- The gate ended with the button still down: its hold ramp starts, over the hold rate scaled by the
--- distance left from where the light has got to.
--- @param now LightNow
--- @param view LightView
--- @return LightIntent|nil
function Buttons:gateEnded(now, view)
  local press = self.press
  if not press or not press.waiting then
    return nil
  end
  press.waiting = false
  local up = press.direction == "up"
  local level = self:_at(view)
  local distance = up and (100 - level) or level
  local hold = {
    kind = "level",
    level = up and 100 or 0,
    rateMs = math.floor(self.settings:holdRate(up) * math.max(0, distance) / 100 + 0.5),
    source = "button",
    ramp = true,
  }
  self:noted(hold, now)
  return hold
end

--- Another source moved the light: a hold or a scene ramp it replaced no longer runs, so a release stops
--- nothing. A press still in its gate keeps waiting, as the button is still down.
function Buttons:cancel()
  self.ramping = false
end

--- The run is replaced: the light was lost or reset.
function Buttons:reset()
  self:_endPress()
  self.ramping = false
  self.restLit = nil
  self.nextRamp = nil
end

return Buttons
