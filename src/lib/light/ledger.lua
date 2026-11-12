--- Ledger: weighs each device report against the commands the library sent, by rules J1 to J6 (design v3,
--- section 3). It owns one window per aspect, from a command to its deadline, and the deadline timers. It
--- decides what a report means; Light carries out the answer.

local log = require("lib.logging")
local Color = require("lib.light.color")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

--- @alias LightAspectValue boolean|number|LightColor

--- The aspects, in the order a report is weighed: an on can decide whether a color is news (J1).
--- @type LightAspect[]
local ASPECTS = { "on", "level", "color" }

--- @class LightLedger
--- @field light Light Only for the deadline timers' call back.
--- @field device LightDevice|nil
--- @field windows table<LightAspect, LightWindow> The open window of each aspect.
--- @field unheard table<LightAspect, boolean> The aspects whose first report since construction or reset has
---   not come (J2).
--- @field libraryOn boolean|nil The on the library holds: from Motion at each report and deadline, then from
---   each command that changes the output and each on settled. While another hand's on waits for its level
---   (a learning window), it is on.
--- @field reportedOn boolean|nil The on the device last reported.
--- @field offFrom number|nil Where the newest fade to off started, until a command lights the light again.
local Ledger = {}
Ledger.__index = Ledger

--- @param light Light
--- @return LightLedger
function Ledger.new(light)
  return setmetatable({
    light = light,
    windows = {},
    unheard = { on = true, level = true, color = true },
  }, Ledger)
end

--- @param device LightDevice
function Ledger:declare(device)
  self.device = device
end

--- A command went out: open or extend a window for each aspect it changes.
--- @param cmd LightCommand
--- @param landings table<LightAspect, integer> C4:GetTime() ms when each aspect's change ends.
function Ledger:sent(cmd, landings)
  -- A read under way answers from before this command: a learning window may ask again.
  for _, aspect in ipairs(ASPECTS) do
    local window = self.windows[aspect]
    if window and window.kind == "learning" then
      window.asked, window.extended = false, false
    end
  end
  -- Without setsLevel the on is only carried: the output is unchanged. An off's level is only the level kept.
  local libraryOn = self:_onHeld(self.libraryOn)
  if cmd.setsLevel and cmd.on ~= libraryOn then
    self:_open("on", cmd.on, libraryOn, landings.on)
  end
  if cmd.setsLevel and cmd.on then
    self:_open("level", cmd.level, cmd.from.level, landings.level)
  end
  if cmd.setsLevel then
    self.libraryOn = cmd.on
    self.offFrom = (not cmd.on) and cmd.from.level or nil
  end
  if cmd.setsColor and cmd.color then
    self:_open("color", cmd.color, cmd.from.color, landings.color)
  end
  -- On a device that re-times, a command for one aspect moves the other's landing, and an off moves the level's:
  -- an open window of ours, asked or not, waits for it.
  for _, aspect in ipairs(ASPECTS) do
    local window = self.windows[aspect]
    local landing = landings[aspect]
    if window and window.kind ~= "learning" and landing then
      local deadline = landing + self.device.feedback.waitMs
      if deadline > window.deadline then
        self:_arm(aspect, window, deadline)
      end
    end
  end
end

--- A device report, weighed per aspect it carries.
--- @param report LightReport
--- @param now LightNow
--- @return LightHeard
function Ledger:heard(report, now)
  local out = { settle = {}, foreign = {}, ask = false, first = {} }
  self.libraryOn = self:_onHeld(now.on)
  local past = self:_beforeRamp(report, now)
  --- @type LightAspect[]
  local history = {}
  for _, aspect in ipairs(ASPECTS) do
    local value = report[aspect]
    if past and (aspect == "on" or (aspect == "level" and report.on == false)) then
      -- The light as it stood before a running ramp got to move its on: an off's level is only the level kept.
      value = nil
    end
    if aspect == "level" and value ~= nil and history[1] == "on" and report.on == false then
      -- An off held as history carries the level that stale state kept: history too, never a lit level.
      history[#history + 1] = aspect
    elseif aspect == "level" and value ~= nil and history[1] == "on" and self:_onItsWayOff(value) then
      -- A lit light below where its fade to off started is that fade on its way, held with its on.
      history[#history + 1] = aspect
    elseif value ~= nil and self:_weigh(aspect, value, report, now, out) == "history" then
      history[#history + 1] = aspect
    end
  end
  -- A report another hand made is that hand's state whole: what it held as history is the hand's too. On a
  -- device that re-times, another hand's command restarted every channel, so each aspect the report carries is
  -- where the device now heads, an echo of ours included.
  if #out.foreign > 0 then
    for _, aspect in ipairs(history) do
      self:_foreign(aspect, report[aspect], out)
    end
    if self.device.fade.retimes then
      for _, aspect in ipairs(ASPECTS) do
        if report[aspect] ~= nil and out.settle[aspect] == nil then
          out.settle[aspect] = report[aspect]
          self:_close(aspect)
        end
      end
    end
  end
  self:_keepChangedOn(out, now)
  if out.settle.on ~= nil then
    self.libraryOn = out.settle.on
  end
  self.libraryOn = self:_onHeld(self.libraryOn)
  if report.on ~= nil then
    self.reportedOn = report.on
  end
  return out
end

--- An aspect's deadline (J6).
--- @param aspect LightAspect
--- @param now LightNow
--- @return LightHeard
function Ledger:due(aspect, now)
  local out = { settle = {}, foreign = {}, ask = false, first = {} }
  self.libraryOn = self:_onHeld(now.on)
  local window = self.windows[aspect]
  if not window then
    return out
  end
  local feedback = self.device.feedback
  local newest = window.sent[#window.sent]
  local walking = aspect == "level" and now.levelRamping or aspect == "color" and now.colorRamping
  if self.device.fade.kind == "walk" and walking and window.kind == "command" then
    -- A walk under way sends its next step within a step, and this window waits for it: what it holds came
    -- before the walk.
    self:_arm(aspect, window, C4:GetTime() + feedback.waitMs)
  elseif aspect == "level" and window.kind ~= "learning" and self.libraryOn == false then
    -- An off made the level before it moot: its deadline neither adopts nor asks.
    self:_close(aspect)
  elseif
    window.held ~= nil
    and feedback.refresh
    and not window.asked
    and not (newest and self:_same(aspect, window.held, newest.value))
    and (feedback.shows == "position" or (newest ~= nil and window.kind == "command"))
  then
    -- What was held isn't the newest command's: a position on its way, or a report from before the command,
    -- which a command that landed unheard would leave stale. One read tells where the light is.
    window.kind, window.asked, window.extended = "asked", true, true
    out.ask = true
    self:_arm(aspect, window, C4:GetTime() + feedback.waitMs)
  elseif window.held ~= nil then
    self:_settle(aspect, window.held, out)
  elseif window.heard then
    self:_close(aspect)
  elseif feedback.refresh and not window.asked then
    window.kind, window.asked, window.extended = "asked", true, true
    out.ask = true
    self:_arm(aspect, window, C4:GetTime() + feedback.waitMs)
  else
    self:_close(aspect)
  end
  self:_keepChangedOn(out, now)
  if out.settle.on ~= nil then
    self.libraryOn = out.settle.on
  end
  return out
end

--- Close every window, telling nothing.
function Ledger:closeAll()
  for _, aspect in ipairs(ASPECTS) do
    self:_close(aspect)
  end
end

--- The run replaced: every window closes, and each aspect's next report is its first again (J2).
function Ledger:reset()
  self:closeAll()
  self.unheard = { on = true, level = true, color = true }
  self.reportedOn = nil
  self.offFrom = nil
end

--- Whether another hand's on waits for its level: the light is lit for the commands that follow it.
--- @return boolean
function Ledger:lit()
  return self:_onHeld(nil) == true
end

-----------------------------------------------------------------------------------------------------
-- The rules
-----------------------------------------------------------------------------------------------------

--- J1 to J5 for one aspect of a report.
--- @private
--- @param aspect LightAspect
--- @param value LightAspectValue
--- @param report LightReport
--- @param now LightNow
--- @param out LightHeard
--- @return "history"|nil history The value was held as history (J5d).
function Ledger:_weigh(aspect, value, report, now, out)
  -- J1: while a "hold" device is off with a color told but not sent, a report that doesn't say on carries no
  -- color news: the color the proxy shows stands for the next on.
  if aspect == "color" and now.colorHeld == true and report.on ~= true then
    return
  end
  local window = self.windows[aspect]
  -- J2: the first report carrying the aspect is weighed against what the library holds. With a command
  -- already out for it, the window weighs it instead.
  if self.unheard[aspect] then
    self.unheard[aspect] = false
    out.first[#out.first + 1] = aspect
    if not window then
      if not self:_same(aspect, value, now[aspect]) then
        out.settle[aspect] = value
      end
      return
    end
  end
  -- J3: a seed after the first fills nothing.
  if report.kind == "seed" then
    return
  end
  if not window then
    return self:_noWindow(aspect, value, report, now, out)
  end
  return self:_inWindow(aspect, window, value, report, now, out)
end

--- J4: no command out for the aspect.
--- @private
--- @param aspect LightAspect
--- @param value LightAspectValue
--- @param report LightReport
--- @param now LightNow
--- @param out LightHeard
function Ledger:_noWindow(aspect, value, report, now, out)
  if self:_same(aspect, value, now[aspect]) then
    return
  end
  local feedback = self.device.feedback
  if aspect == "on" and value == true and now.on == false and report.level == nil and feedback.refresh then
    -- Another hand's on with no level: ask, and tell the on with the level it brings (a light that doesn't dim
    -- has none, and the read's on settles alone).
    local deadline = C4:GetTime() + feedback.waitMs
    local on = self:_learn("on", false, deadline)
    on.held, on.heard = true, true
    self:_learn("level", now.level, deadline)
    out.foreign[#out.foreign + 1] = "on"
    out.ask = true
    return
  end
  local level = self.windows.level
  if
    aspect == "on"
    and value == false
    and now.on == true
    and feedback.refresh
    and feedback.shows == "position"
    and level
    and level.kind == "command"
  then
    -- An off while a lit light's level runs may be from before the command: held, and the device read once.
    local window = {
      kind = "command",
      sent = { { value = true, landing = C4:GetTime() } },
      before = true,
      held = false,
      heard = true,
      echoed = false,
      asked = true,
      extended = false,
      deadline = 0,
    }
    self.windows.on = window
    self:_arm("on", window, level.deadline)
    out.ask = true
    return "history"
  end
  self:_foreign(aspect, value, out)
end

--- J5: a command is out for the aspect.
--- @private
--- @param aspect LightAspect
--- @param window LightWindow
--- @param value LightAspectValue
--- @param report LightReport
--- @param now LightNow
--- @param out LightHeard
--- @return "history"|nil history The value was held as history (d).
function Ledger:_inWindow(aspect, window, value, report, now, out)
  local kind = report.kind
  local feedback = self.device.feedback
  -- f: a learning window settles on the first report carrying the aspect. Another hand's on waits for its
  -- level, as a device may answer the read one attribute at a time: the on is told with the level, or at the
  -- deadline. An off instead ends the wait.
  if window.kind == "learning" then
    if aspect == "on" and value == true and self.device.dims then
      return
    end
    self:_settle(aspect, value, out)
    if aspect == "on" then
      self:_close("level")
      return
    end
    return self:_learned(aspect, out)
  end
  -- g: after J6's ask, the first push or final settles. Under "position" only the read's own answer does, or
  -- an echo: a push may still be the light on its way.
  local newest = window.sent[#window.sent]
  if
    window.kind == "asked"
    and (
      kind == "final"
      or (kind == "push" and (feedback.shows ~= "position" or self:_same(aspect, value, newest and newest.value)))
    )
  then
    if self:_waitForLevel(aspect, window, value, report, now) then
      return
    end
    self:_settle(aspect, value, out)
    return self:_learned(aspect, out)
  end
  -- a: a final settles, whatever it shows.
  if kind == "final" then
    if self:_waitForLevel(aspect, window, value, report, now) then
      return
    end
    return self:_settle(aspect, value, out)
  end
  -- b: a moving answer is held.
  if kind == "moving" then
    return self:_hold(window, value)
  end
  -- The on rides the level: it is moving while the level's ramp runs.
  local ramping = (aspect ~= "color" and now.levelRamping) or (aspect == "color" and now.colorRamping)
  -- c: an echo of the newest command is the light's own.
  if newest and self:_same(aspect, value, newest.value) then
    window.held, window.heard, window.echoed = nil, true, true
    if feedback.shows == "position" then
      -- The light is at the change's end: where the command sent it, not the report's rounding of it.
      return self:_settle(aspect, newest.value, out)
    end
    if not ramping then
      self:_close(aspect)
    end
    return
  end
  -- d: until the newest command's echo comes, an older command's value, or the value before the window, is
  -- history. Under "target" one that comes while the aspect's ramp runs says nothing of where the light is,
  -- and is dropped, so the deadline can't revert the ramp.
  if not window.echoed and (self:_older(aspect, window, value) or self:_same(aspect, value, window.before)) then
    -- An off light's level is only the level kept, so an earlier command's level, late, is dropped and its
    -- deadline can't light the light.
    if (feedback.shows == "target" and ramping) or (aspect == "level" and self.libraryOn == false) then
      window.heard = true
      return "history"
    end
    self:_hold(window, value)
    if aspect == "on" and value == false and newest.value == true and feedback.refresh and not window.asked then
      window.asked = true
      out.ask = true
    end
    return "history"
  end
  -- e: a value no command sent.
  if feedback.shows == "target" then
    return self:_foreign(aspect, value, out)
  end
  -- Under "position" it may be the light on its way.
  self:_hold(window, value)
end

-----------------------------------------------------------------------------------------------------
-- Windows
-----------------------------------------------------------------------------------------------------

--- Open the aspect's window, or extend the one open, for a value sent.
--- @private
--- @param aspect LightAspect
--- @param value LightAspectValue
--- @param before LightAspectValue|nil
--- @param landing integer|nil
function Ledger:_open(aspect, value, before, landing)
  local window = self.windows[aspect]
  if not window then
    window = {
      kind = "command",
      sent = {},
      before = before,
      heard = false,
      echoed = false,
      asked = false,
      extended = false,
      deadline = 0,
    }
    self.windows[aspect] = window
  end
  -- A command into a learning or asked window makes it a command's: a read under way predates it.
  window.kind = "command"
  local at = landing or C4:GetTime()
  window.sent[#window.sent + 1] = { value = value, landing = at }
  -- What was held came before this command, whose echo is still to come.
  window.held, window.echoed = nil, false
  self:_arm(aspect, window, at + self.device.feedback.waitMs)
end

--- Open a learning window: one with no value sent, asked already.
--- @private
--- @param aspect LightAspect
--- @param before LightAspectValue|nil
--- @param deadline integer
--- @return LightWindow
function Ledger:_learn(aspect, before, deadline)
  self:_close(aspect)
  local window = {
    kind = "learning",
    sent = {},
    before = before,
    heard = false,
    echoed = false,
    asked = true,
    extended = false,
    deadline = 0,
  }
  self.windows[aspect] = window
  self:_arm(aspect, window, deadline)
  return window
end

--- @private
--- @param aspect LightAspect
--- @param window LightWindow
--- @param deadline integer
function Ledger:_arm(aspect, window, deadline)
  window.deadline = deadline
  SetTimer("Light.Wait." .. aspect, math.max(0, deadline - C4:GetTime()), function()
    self.light:_due(aspect)
  end)
end

--- @private
--- @param aspect LightAspect
function Ledger:_close(aspect)
  if self.windows[aspect] then
    self.windows[aspect] = nil
    CancelTimer("Light.Wait." .. aspect)
  end
end

--- The on the library holds for a report or a deadline: Motion's, or on while another hand's on waits for
--- its level, so the commands that follow treat the light as lit.
--- @private
--- @param on boolean|nil
--- @return boolean|nil
function Ledger:_onHeld(on)
  local window = self.windows.on
  if window and window.kind == "learning" and window.held == true then
    return true
  end
  return on
end

--- Whether a report shows the light as it stood before a running level ramp got to move its on: lit while a
--- ramp to off runs, or off while a ramp from off has lit nothing yet. A light that walks steps there and
--- reports where its steps have got to, so an off report while its walk from off has lit nothing is from
--- before the walk too.
--- @private
--- @param report LightReport
--- @param now LightNow
--- @return boolean
function Ledger:_beforeRamp(report, now)
  if now.levelRamping ~= true or report.on == nil or self.windows.on ~= nil then
    return false
  end
  if self.device.fade.kind == "walk" and report.on == false and now.on == false then
    return true
  end
  return report.on ~= now.on and report.on == self.reportedOn
end

--- An on answered alone while the library holds the light off, by a device that answers a read one
--- attribute at a time: it waits for its level, and is told with it, or at the deadline.
--- @private
--- @param aspect LightAspect
--- @param window LightWindow
--- @param value LightAspectValue
--- @param report LightReport
--- @param now LightNow
--- @return boolean waiting
function Ledger:_waitForLevel(aspect, window, value, report, now)
  if
    aspect ~= "on"
    or value ~= true
    or report.level ~= nil
    or now.on ~= false
    or not self.device.feedback.refresh
    or not self.device.dims
  then
    return false
  end
  local deadline = C4:GetTime() + self.device.feedback.waitMs
  window.kind, window.held, window.heard, window.asked = "learning", true, true, true
  self:_arm("on", window, deadline)
  self:_learn("level", now.level, deadline)
  return true
end

--- Whether a lit level is a fade to off on its way, on a device that reports where its light has got to: no
--- level window is open (the off closed it), and the level is at or below where the fade started.
--- @private
--- @param level number
--- @return boolean
function Ledger:_onItsWayOff(level)
  local from = self.offFrom
  return from ~= nil
    and self.device.feedback.shows == "position"
    and self.windows.level == nil
    and level <= from + 1 / self.device.levelSteps
end

--- An on alone that the library already holds is no news: settling it would only end the level's ramp. With
--- a level or a color beside it, it stays: an off's level is only the level kept.
--- @private
--- @param out LightHeard
--- @param now LightNow
function Ledger:_keepChangedOn(out, now)
  local settle = out.settle
  if settle.on ~= nil and settle.on == now.on and settle.level == nil and settle.color == nil then
    settle.on = nil
  end
end

--- A level came for another hand's on: the on is told with it.
--- @private
--- @param aspect LightAspect
--- @param out LightHeard
function Ledger:_learned(aspect, out)
  local on = self.windows.on
  if aspect == "level" and on and on.kind == "learning" and on.held ~= nil then
    self:_settle("on", on.held, out)
  end
end

--- @private
--- @param window LightWindow
--- @param value LightAspectValue
function Ledger:_hold(window, value)
  window.held, window.heard = value, true
end

--- @private
--- @param aspect LightAspect
--- @param value LightAspectValue
--- @param out LightHeard
function Ledger:_settle(aspect, value, out)
  -- A value that matches the newest sent, in device units, is that command's: not the report's rounding of it.
  local window = self.windows[aspect]
  local newest = window and window.sent[#window.sent]
  if newest and self:_same(aspect, value, newest.value) then
    value = newest.value
  end
  out.settle[aspect] = value
  self:_close(aspect)
end

--- Another hand moved the aspect: adopt it, and say so.
--- @private
--- @param aspect LightAspect
--- @param value LightAspectValue
--- @param out LightHeard
function Ledger:_foreign(aspect, value, out)
  log:debug("Light: another hand's %s", aspect)
  out.foreign[#out.foreign + 1] = aspect
  self:_settle(aspect, value, out)
end

-----------------------------------------------------------------------------------------------------
-- Matching, in device units
-----------------------------------------------------------------------------------------------------

--- Whether two values of an aspect are one: an on exactly, a level at the device's steps, a color in the same
--- mode and within Color.TOLERANCE in xy (a white and a full color at one xy are two).
--- @private
--- @param aspect LightAspect
--- @param a LightAspectValue|nil
--- @param b LightAspectValue|nil
--- @return boolean
function Ledger:_same(aspect, a, b)
  if a == nil or b == nil then
    return false
  end
  if aspect == "on" then
    return a == b
  end
  if aspect == "level" then
    --- @cast a number
    --- @cast b number
    local steps = self.device.levelSteps
    return math.floor(a * steps + 0.5) == math.floor(b * steps + 0.5)
  end
  --- @cast a LightColor
  --- @cast b LightColor
  return a.mode == b.mode and math.abs(a.x - b.x) <= Color.TOLERANCE and math.abs(a.y - b.y) <= Color.TOLERANCE
end

--- Whether a value matches a command older than the window's newest.
--- @private
--- @param aspect LightAspect
--- @param window LightWindow
--- @param value LightAspectValue
--- @return boolean
function Ledger:_older(aspect, window, value)
  for i = #window.sent - 1, 1, -1 do
    if self:_same(aspect, value, window.sent[i].value) then
      return true
    end
  end
  return false
end

return Ledger
