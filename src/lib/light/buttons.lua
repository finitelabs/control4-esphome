--- The light's three buttons, from BUTTON_ACTION and from the Button Links: presses, holds and clicks as
--- intents for Motion.
---
--- A press waits 250 ms before its hold ramp starts. Only that button's click or release, or another press,
--- ends the wait; a command meanwhile leaves it, as the button is still down. So a click tells one CHANGING
--- and sends the device one level. A hold's time is the hold rate scaled by the distance left, and a Toggle
--- hold alternates direction.

local Range = require("lib.light.range")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local GATE_TIMER = "Light.Gate"
local GATE_MS = 250

--- @class LightButtons
--- @field light Light
--- @field settings LightSettings
--- @field press LightPress|nil The press in hand, from its PRESS to its release.
--- @field toggleLast LightHoldDirection|nil The direction of the last Toggle hold.
local Buttons = {}
Buttons.__index = Buttons

--- The proxy's three buttons.
Buttons.TOP = 0
Buttons.BOTTOM = 1
Buttons.TOGGLE = 2

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
--- @field holding boolean The hold ramp runs, and is this press's.

--- @param light Light
--- @param settings LightSettings
--- @return LightButtons
function Buttons.new(light, settings)
  return setmetatable({ light = light, settings = settings, press = nil, toggleLast = nil }, Buttons)
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

--- The C4 level the light is at or heading to: 0 while off.
--- @private
--- @param now LightNow
--- @return integer
function Buttons:_level(now)
  if now.on ~= true then
    return 0
  end
  local lo, hi = self.settings:onRange()
  return Range.toLevel(now.level, lo, hi)
end

--- Where a hold of this button goes from this level. Toggle goes down from full and up from off, and
--- otherwise the other way from its last hold; its first goes down from a lit light.
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
  elseif self.toggleLast then
    return self.toggleLast == "down" and "up" or "down"
  end
  return "down"
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
--- @return LightIntent|nil
function Buttons:action(button, action, now)
  if button ~= Buttons.TOP and button ~= Buttons.BOTTOM and button ~= Buttons.TOGGLE then
    return nil
  end
  if action == Buttons.PRESS then
    self:_endPress()
    local level = self:_level(now)
    self.press = {
      button = button,
      prePress = level,
      direction = self:_direction(button, level),
      waiting = true,
      holding = false,
    }
    local light = self.light
    SetTimer(GATE_TIMER, GATE_MS, function()
      light:_gateEnded()
    end, false)
    return nil
  elseif action == Buttons.RELEASE_HOLD then
    -- A release inside the gate started nothing, so it stops nothing.
    local press = self:_endPress()
    if press and press.holding then
      return { kind = "stopLevel", source = "button" }
    end
    return nil
  elseif action == Buttons.RELEASE_CLICK then
    local press = self:_endPress()
    local up = button == Buttons.TOP
    if button == Buttons.TOGGLE then
      up = (press and press.prePress or self:_level(now)) <= 0
    end
    return { kind = up and "on" or "off", rateMs = self.settings:clickRate(up), source = "button" }
  end
  return nil
end

--- The gate ended with the button still down: its hold ramp starts, over the hold rate scaled by the
--- distance left.
--- @param now LightNow
--- @return LightIntent|nil
function Buttons:gateEnded(now)
  local press = self.press
  if not press or not press.waiting then
    return nil
  end
  press.waiting, press.holding = false, true
  if press.button == Buttons.TOGGLE then
    self.toggleLast = press.direction
  end
  local up = press.direction == "up"
  local level = self:_level(now)
  local distance = up and (100 - level) or level
  return {
    kind = "level",
    level = up and 100 or 0,
    rateMs = math.floor(self.settings:holdRate(up) * math.max(0, distance) / 100 + 0.5),
    source = "button",
  }
end

--- Another source moved the light: a running hold ramp is no longer this press's, so its release stops
--- nothing. A press still in its gate keeps waiting, as the button is still down.
function Buttons:cancel()
  if self.press then
    self.press.holding = false
  end
end

--- The run is replaced: the light was lost or reset.
function Buttons:reset()
  self:_endPress()
  self.toggleLast = nil
end

return Buttons
