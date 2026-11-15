--- Ledger: weighs each device report against the commands the library sent. It owns one window per aspect,
--- from a command to its deadline, and the deadline timers. It decides what a report means; Light carries out
--- the answer.

local log = require("lib.logging")
local Color = require("lib.light.color")
local Timer = require("lib.light.timer")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

--- @alias LightAspectValue boolean|number|LightColor

--- The aspects, in the order a report is weighed: an on can decide whether a color is news.
--- @type LightAspect[]
local ASPECTS = { "on", "level", "color" }

--- @class LightLedger
--- @field light Light Only for the deadline timers' call back.
--- @field device LightDevice|nil
--- @field windows table<LightAspect, LightWindow> The open window of each aspect.
--- @field unheard table<LightAspect, boolean> The aspects whose first report since construction or reset has
---   not come.
--- @field libraryOn boolean|nil The on the library holds: from Motion at each report and deadline, then from
---   each command that changes the output and each on settled. While another hand's on waits for its level
---   (a learning window), it is on.
--- @field reportedOn boolean|nil The on the device last reported.
--- @field offFrom number|nil Where the newest fade to off started, until a command lights the light again.
--- @field walkUnheard boolean|nil While a report is weighed: it is the first a running walk hears.
--- @field awaiting table<LightAspect, boolean> What the connection's first report left out: a lit light's level
---   and its color, and the level of a light first heard off that a report lights without one. The proxy isn't
---   told them from what the library holds until a report carries them, a command sets them, or the device's
---   wait for them ends.
--- @field levelSet boolean|nil A command has set the level since construction or reset.
local Ledger = {}
Ledger.__index = Ledger

--- @param light Light
--- @return LightLedger
function Ledger.new(light)
  return setmetatable({
    light = light,
    windows = {},
    unheard = { on = true, level = true, color = true },
    awaiting = {},
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
  -- A read under way answers from before this command, and the device may drop that answer: a learning window
  -- asks again once the command is out, unless the command sets the level and so ends what it waits for.
  local relearn
  for _, aspect in ipairs(ASPECTS) do
    local window = self.windows[aspect]
    if window and window.kind == "learning" then
      window.asked, window.extended = false, false
      relearn = relearn or aspect
    end
  end
  -- Without setsLevel the on is only carried: the output is unchanged. An off's level is only the level kept.
  local libraryOn = self:_onHeld(self.libraryOn)
  if cmd.setsLevel and cmd.on ~= libraryOn then
    self:_open("on", cmd.on, libraryOn, landings.on)
  end
  if cmd.setsLevel and cmd.on then
    self:_open("level", cmd.level, cmd.from.level, landings.level)
    self.levelSet = true
  end
  if cmd.setsLevel then
    self.libraryOn = cmd.on
    self.offFrom = (not cmd.on) and cmd.from.level or nil
    self:_heardOf("level")
  end
  if cmd.setsColor then
    self:_heardOf("color")
  end
  if cmd.setsColor and cmd.color then
    self:_open("color", cmd.color, cmd.from.color, landings.color)
  end
  -- A command moves each aspect's landing: a re-time moves the other aspect's, an off the level's, a stop ends
  -- a change early. A command's window waits until its aspect's change lands, then the wait; one asked waits
  -- for its read too, so it only waits longer.
  for _, aspect in ipairs(ASPECTS) do
    local window = self.windows[aspect]
    local landing = landings[aspect]
    if window and window.kind ~= "learning" and landing then
      local deadline = landing + self.device.feedback.waitMs
      if deadline > window.deadline or (window.kind == "command" and deadline < window.deadline) then
        self:_arm(aspect, window, deadline)
      end
    end
  end
  local learning = relearn and self.windows[relearn]
  if learning and learning.kind == "learning" and not cmd.setsLevel then
    self:_arm(relearn, learning, C4:GetTime())
  end
end

--- A device report, weighed per aspect it carries.
--- @param report LightReport
--- @param now LightNow
--- @return LightHeard
function Ledger:heard(report, now)
  local out = { settle = {}, foreign = {}, ask = false, first = {} }
  local opening = self.unheard.on and self.unheard.level and self.unheard.color
  self.libraryOn = self:_onHeld(now.on)
  self.walkUnheard = self:_walkUnheard(now)
  local past = self:_beforeRamp(report, now)
  --- @type LightAspect[]
  local history = {}
  for _, aspect in ipairs(ASPECTS) do
    local value = report[aspect]
    if past and (aspect == "on" or (aspect == "level" and report.on == false)) then
      -- The light as it stood before a running ramp got to move its on: an off's level is only the level kept.
      value = nil
    end
    if
      aspect == "level"
      and value ~= nil
      and history[1] == "on"
      and (report.on == false or (self.device.feedback.shows == "target" and self.windows.level == nil))
    then
      -- An on held as history carries the level of that stale state: history too. An off's is only the level
      -- kept; a lit one from a device that reports its targets, with no command out for the level, came before
      -- our command as well.
      history[#history + 1] = aspect
    elseif
      aspect == "level"
      and value ~= nil
      and (history[1] == "on" or report.on == nil)
      and self:_onItsWayOff(value)
    then
      -- A lit light below where its fade to off started is that fade on its way, held with its on, or alone
      -- from a device that reports one attribute at a time.
      history[#history + 1] = aspect
    elseif
      aspect == "level"
      and value ~= nil
      and (report.on == false or (report.on == nil and self.libraryOn == false))
      and self:_ourOffOut()
    then
      -- Beside an off while one of ours is out, or alone from a device that reports one attribute at a time,
      -- the level is only the one the light keeps for its next on.
      value = nil
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
  self.walkUnheard = false
  if report.on ~= nil then
    self.reportedOn = report.on
  end
  if report.level ~= nil or report.on == false then
    self:_heardOf("level")
  end
  if report.color ~= nil then
    self:_heardOf("color")
  end
  if opening then
    self:_await(report)
  elseif
    report.on == true
    and report.level == nil
    and self.device.dims
    and self.unheard.level
    and not self.levelSet
    and not self.awaiting.level
  then
    -- A light first heard off, lit with no level of its own: no report or command has given its level yet.
    local armed = next(self.awaiting) ~= nil
    self.awaiting.level = true
    if not armed then
      self:_armAwaiting()
    end
  end
  return out
end

--- An intent the library took sets the level or color it carries, sent or held for the next on: neither is
--- waited for any more.
--- @param intent LightIntent
function Ledger:taken(intent)
  if intent.level ~= nil then
    self:_heardOf("level")
  end
  if intent.color ~= nil then
    self:_heardOf("color")
  end
end

--- The wait for what the connection's first report left out ended: each is told as the library holds it.
--- @return LightHeard
function Ledger:awaited()
  local out = { settle = {}, foreign = {}, ask = false, first = {} }
  for _, aspect in ipairs(ASPECTS) do
    if self.awaiting[aspect] then
      out.first[#out.first + 1] = aspect
    end
  end
  self.awaiting = {}
  return out
end

--- An aspect's deadline.
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
  elseif
    aspect == "level"
    and window.kind ~= "learning"
    and (self.libraryOn == false or (window.held ~= nil and self.windows.on ~= nil and self.windows.on.held == false))
  then
    -- An off made the level before it moot: its deadline neither adopts nor asks. So does an off the on's own
    -- deadline settles, for a level held beside it: only the one the light keeps.
    self:_close(aspect)
  elseif aspect == "color" and window.kind ~= "learning" and now.colorHeld == true then
    -- So does an off that holds a color for the next on, for the color before it.
    self:_close(aspect)
  elseif window.held ~= nil and window.landed then
    -- A position no command sent, reported once the change had landed, is where the light landed.
    self:_settle(aspect, window.held, out)
  elseif
    window.held ~= nil
    and feedback.refresh
    and not window.asked
    and not (newest and self:_echoes(aspect, window.held, newest.value))
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

--- The run replaced: every window closes, and each aspect's next report is its first again.
function Ledger:reset()
  self:closeAll()
  self.unheard = { on = true, level = true, color = true }
  self.awaiting = {}
  self.levelSet = nil
  CancelTimer("Light.Awaiting")
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

--- Weigh one aspect of a report.
--- @private
--- @param aspect LightAspect
--- @param value LightAspectValue
--- @param report LightReport
--- @param now LightNow
--- @param out LightHeard
--- @return "history"|nil history The value was held as history.
function Ledger:_weigh(aspect, value, report, now, out)
  -- While a "hold" device is off with a color told but not sent, a report that doesn't say on carries no
  -- color news, nor does a lit one while our off is out, the light on its way down in the color it kept: the
  -- color the proxy shows stands for the next on. The color reported is the one that on lights from.
  if aspect == "color" and now.colorHeld == true and (report.on ~= true or self:_ourOffOut()) then
    out.kept = value
    return
  end
  local window = self.windows[aspect]
  -- The first report carrying the aspect is weighed against what the library holds. With a command
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
  -- A seed after the first fills nothing.
  if report.kind == "seed" then
    return
  end
  if not window then
    return self:_noWindow(aspect, value, report, now, out)
  end
  return self:_inWindow(aspect, window, value, report, now, out)
end

--- A report with no command out for the aspect.
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
  if
    aspect == "color"
    and now.color
    and self:_asKelvin(value --[[@as LightColor]], now.color)
  then
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
  if self.walkUnheard and aspect ~= "on" then
    -- A walk's first poll may read a change made before the walk was asked for: the light's state, told, but
    -- no other hand's move during the walk.
    out.settle[aspect] = value
    return
  end
  self:_foreign(aspect, value, out)
end

--- A report while a command is out for the aspect.
--- @private
--- @param aspect LightAspect
--- @param window LightWindow
--- @param value LightAspectValue
--- @param report LightReport
--- @param now LightNow
--- @param out LightHeard
--- @return "history"|nil history The value was held as history.
function Ledger:_inWindow(aspect, window, value, report, now, out)
  local kind = report.kind
  local feedback = self.device.feedback
  -- A learning window settles on the first report carrying the aspect. Another hand's on waits for its
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
  local newest = window.sent[#window.sent]
  if
    aspect == "color"
    and value ~= nil
    and newest
    and self:_asKelvin(value --[[@as LightColor]], newest.value --[[@as LightColor]])
  then
    -- The color sent, as a device that reports its whites as a Kelvin reads it.
    value = newest.value
  end
  -- After the deadline's ask, the first push or final settles. Under "position" only the read's own answer does, or
  -- an echo: a push may still be the light on its way.
  if
    window.kind == "asked"
    and (
      kind == "final"
      or (kind == "push" and (feedback.shows ~= "position" or self:_echoes(aspect, value, newest and newest.value)))
    )
  then
    if self:_waitForLevel(aspect, window, value, report, now) then
      return
    end
    self:_settle(aspect, value, out)
    return self:_learned(aspect, out)
  end
  -- A final settles, whatever it shows.
  if kind == "final" then
    if self:_waitForLevel(aspect, window, value, report, now) then
      return
    end
    return self:_settle(aspect, value, out)
  end
  -- A moving answer is held. A light on its way to lit is lit from the start, so a moving on against an on sent
  -- is where the light is: the on's echo, or another hand's off.
  if kind == "moving" then
    if aspect == "on" and newest and newest.value == true then
      if value == true then
        window.held, window.heard, window.echoed = nil, true, true
        return self:_settle(aspect, true, out)
      end
      return self:_foreign(aspect, value, out)
    end
    return self:_hold(window, value)
  end
  -- The on rides the level: it is moving while the level's ramp runs.
  local ramping = (aspect ~= "color" and now.levelRamping) or (aspect == "color" and now.colorRamping)
  if aspect == "on" and value ~= window.before then
    window.left = true
  end
  -- An on sent back to where the light stood before the off ahead of it is heard may be the light from before
  -- both: history, until the off's echo or the deadline.
  if aspect == "on" and #window.sent > 1 and value == window.before and newest.value == value and not window.left then
    self:_hold(window, value)
    return "history"
  end
  -- An echo of the newest command is the light's own. One in another form than sent that is, in that form, what
  -- the light showed before may be from before the command: it is history.
  local form = newest ~= nil and not self:_same(aspect, value, newest.value)
  if newest and self:_echoes(aspect, value, newest.value) and not (form and self:_shown(aspect, window, value)) then
    window.held, window.heard, window.echoed = nil, true, true
    if aspect ~= "color" or not ramping then
      -- A color in another form before the change lands is the light on its way, close to the end: the window
      -- waits for the landing.
      if form and feedback.shows == "position" and C4:GetTime() < newest.landing then
        return
      end
      if feedback.shows == "position" then
        -- The light is at the change's end: where the command sent it, not the report's rounding of it. A color
        -- its ramp still runs to is a device that reads the color's target at once: the ramp's end tells it.
        return self:_settle(aspect, newest.value, out)
      elseif form then
        -- A color the light reports in another form than it was sent is told in the light's form.
        return self:_settle(aspect, value, out)
      end
    elseif form and feedback.shows == "target" then
      -- So is the end of a color fade the light echoes in another form while it runs.
      out.form = value
    end
    if not ramping then
      -- Another client's command ended the ramp part way, and the light says it heads to the command's end. An off
      -- light's level is only the level kept, and says nothing.
      local lit = aspect ~= "level" or self.libraryOn ~= false
      if lit and not self:_same(aspect, now[aspect], newest.value) then
        return self:_settle(aspect, newest.value, out)
      end
      self:_close(aspect)
    end
    return
  end
  -- Until the newest command's echo comes, an older command's value, or the value before the window, is
  -- history. Under "target" one that comes while the aspect's ramp runs says nothing of where the light is,
  -- and is dropped, so the deadline can't revert the ramp. Once a walk has been heard, its history is only the
  -- steps it sent: the level or color it started from is news. Before that, a read of it may predate the first
  -- step, so it is where the walk is.
  local walked = self.device.fade.kind == "walk" and ramping and aspect ~= "on" and window.heard
  if
    not window.echoed
    and (self:_older(aspect, window, value) or (not walked and self:_echoes(aspect, value, window.before)))
  then
    -- An off light's level is only the level kept, so an earlier command's level, late, is dropped and its
    -- deadline can't light the light.
    if (feedback.shows == "target" and ramping) or (aspect == "level" and self.libraryOn == false) then
      window.heard = true
      return "history"
    end
    self:_hold(window, value)
    if
      aspect == "on"
      and value == false
      and newest ~= nil
      and newest.value == true
      and feedback.refresh
      and not window.asked
    then
      window.asked = true
      out.ask = true
    end
    return "history"
  end
  -- A value no command sent.
  if feedback.shows == "target" then
    return self:_foreign(aspect, value, out)
  end
  -- Under "position" it may be the light on its way, or, once the change has landed, where it landed.
  self:_hold(window, value)
  window.landed = newest ~= nil and C4:GetTime() >= newest.landing
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
  Timer.arm("Light.Wait." .. aspect, deadline - C4:GetTime(), function()
    self.light:_due(aspect)
  end)
end

--- The connection's first report: a lit light's level and the color it left out wait for a report of their own.
--- @private
--- @param report LightReport
function Ledger:_await(report)
  local device = self.device
  if device.dims and report.level == nil and report.on ~= false then
    self.awaiting.level = true
  end
  if (device.color or device.cct ~= nil) and report.color == nil then
    self.awaiting.color = true
  end
  if next(self.awaiting) ~= nil then
    self:_armAwaiting()
  end
end

--- @private
function Ledger:_armAwaiting()
  Timer.arm("Light.Awaiting", self.device.feedback.waitMs, function()
    self.light:_awaited()
  end)
end

--- An aspect is no longer waited for.
--- @private
--- @param aspect LightAspect
function Ledger:_heardOf(aspect)
  if self.awaiting[aspect] then
    self.awaiting[aspect] = nil
    if next(self.awaiting) == nil then
      CancelTimer("Light.Awaiting")
    end
  end
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

--- Whether a report is the first a running walk hears: no report has come since the walk was asked for.
--- @private
--- @param now LightNow
--- @return boolean
function Ledger:_walkUnheard(now)
  if self.device.fade.kind ~= "walk" then
    return false
  end
  local level, color = self.windows.level, self.windows.color
  return (now.levelRamping == true and level ~= nil and level.kind == "command" and not level.heard)
    or (now.colorRamping == true and color ~= nil and color.kind == "command" and not color.heard)
end

--- Whether the newest command out for the on is an off of ours.
--- @private
--- @return boolean
function Ledger:_ourOffOut()
  local window = self.windows.on
  local newest = window and window.kind ~= "learning" and window.sent[#window.sent]
  return newest and newest.value == false or false
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
  window.held, window.heard, window.landed = value, true, nil
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

--- Whether a report carries a value sent, or held before a command: as _same, but a color in any mode, as a
--- device may report the white it was sent in xy as a Kelvin.
--- @private
--- @param aspect LightAspect
--- @param value LightAspectValue|nil
--- @param sent LightAspectValue|nil
--- @return boolean
function Ledger:_echoes(aspect, value, sent)
  if aspect ~= "color" or value == nil or sent == nil then
    return self:_same(aspect, value, sent)
  end
  --- @cast value LightColor
  --- @cast sent LightColor
  return (math.abs(value.x - sent.x) <= Color.TOLERANCE and math.abs(value.y - sent.y) <= Color.TOLERANCE)
    or self:_asKelvin(value, sent)
end

--- Whether a color reported a little off a full color in the white band is that color as a device without color
--- temperature that reports its whites as a Kelvin gives it: the point on the locus at its Kelvin. On a light with
--- color temperature, a white there is a white.
--- @private
--- @param value LightColor
--- @param color LightColor
--- @return boolean
function Ledger:_asKelvin(value, color)
  local tolerance = Color.TOLERANCE
  if
    self.device.cct
    or color.mode == Color.CCT
    or (math.abs(value.x - color.x) <= tolerance and math.abs(value.y - color.y) <= tolerance)
  then
    return false
  end
  local k = Color.kelvin(color.x, color.y)
  if not k or not Color.onLocus(color.x, color.y, Color.WHITE_MIN_K, Color.WHITE_MAX_K) then
    return false
  end
  local x, y = Color.kelvinToXY(math.max(Color.WHITE_MIN_K, math.min(Color.WHITE_MAX_K, k)))
  return math.abs(value.x - x) <= tolerance and math.abs(value.y - y) <= tolerance
end

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

--- Whether a value is, in its own form, what the light showed before the window or an older command sent.
--- @private
--- @param aspect LightAspect
--- @param window LightWindow
--- @param value LightAspectValue
--- @return boolean
function Ledger:_shown(aspect, window, value)
  for i = #window.sent - 1, 1, -1 do
    if self:_same(aspect, value, window.sent[i].value) then
      return true
    end
  end
  return self:_same(aspect, value, window.before)
end

--- Whether a value matches a command older than the window's newest.
--- @private
--- @param aspect LightAspect
--- @param window LightWindow
--- @param value LightAspectValue
--- @return boolean
function Ledger:_older(aspect, window, value)
  for i = #window.sent - 1, 1, -1 do
    if self:_echoes(aspect, value, window.sent[i].value) then
      return true
    end
  end
  return false
end

return Ledger
