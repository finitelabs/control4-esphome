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
  elseif cmd.setsLevel then
    -- An off makes the level before it moot: its window ends, so its deadline can't light the light.
    self:_close("level")
  end
  if cmd.setsLevel then
    self.libraryOn = cmd.on
  end
  if cmd.setsColor and cmd.color then
    self:_open("color", cmd.color, cmd.from.color, landings.color)
  end
end

--- A device report, weighed per aspect it carries.
--- @param report LightReport
--- @param now LightNow
--- @return LightHeard
function Ledger:heard(report, now)
  local out = { settle = {}, foreign = {}, ask = false }
  self.libraryOn = self:_onHeld(now.on)
  --- @type LightAspect[]
  local history = {}
  for _, aspect in ipairs(ASPECTS) do
    local value = report[aspect]
    if aspect == "level" and value ~= nil and history[1] == "on" and report.on == false then
      -- An off held as history carries the level that stale state kept: history too, never a lit level.
      history[#history + 1] = aspect
    elseif value ~= nil and self:_weigh(aspect, value, report, now, out) == "history" then
      history[#history + 1] = aspect
    end
  end
  -- A report another hand made is that hand's state whole: what it held as history is the hand's too.
  if #out.foreign > 0 then
    for _, aspect in ipairs(history) do
      self:_foreign(aspect, report[aspect], out)
    end
  end
  if out.settle.on ~= nil then
    self.libraryOn = out.settle.on
  end
  self.libraryOn = self:_onHeld(self.libraryOn)
  return out
end

--- An aspect's deadline (J6).
--- @param aspect LightAspect
--- @param now LightNow
--- @return LightHeard
function Ledger:due(aspect, now)
  local out = { settle = {}, foreign = {}, ask = false }
  self.libraryOn = self:_onHeld(now.on)
  local window = self.windows[aspect]
  if not window then
    return out
  end
  local feedback = self.device.feedback
  if window.held ~= nil then
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
    -- Another hand's on with no level: ask, and tell the on with the level it brings.
    local deadline = C4:GetTime() + feedback.waitMs
    local on = self:_learn("on", false, deadline)
    on.held, on.heard = true, true
    self:_learn("level", now.level, deadline)
    out.foreign[#out.foreign + 1] = "on"
    out.ask = true
    return
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
    if aspect == "on" and value == true then
      return
    end
    self:_settle(aspect, value, out)
    if aspect == "on" then
      self:_close("level")
      return
    end
    return self:_learned(aspect, out)
  end
  -- g: after J6's ask, the first push or final settles.
  if window.kind == "asked" and (kind == "push" or kind == "final") then
    self:_settle(aspect, value, out)
    return self:_learned(aspect, out)
  end
  -- a: a final settles, whatever it shows.
  if kind == "final" then
    return self:_settle(aspect, value, out)
  end
  -- b: a moving answer is held.
  if kind == "moving" then
    return self:_hold(window, value)
  end
  local ramping = (aspect == "level" and now.levelRamping) or (aspect == "color" and now.colorRamping)
  -- c: an echo of the newest command is the light's own.
  local newest = window.sent[#window.sent]
  if self:_same(aspect, value, newest.value) then
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
    if feedback.shows == "target" and ramping then
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
