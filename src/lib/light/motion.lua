--- Where the light is and where it is heading. Motion owns both ramps and every field on them, turns intents
--- into commands (the pre-on, the change, the stop, the re-time), keeps a color an off "hold" device would
--- drop, writes a LightRest into its state, and walks a change in 0-time steps on a "walk" device.
---
--- Its rest values (on, level, color) are where the light is going. A ramp is only how it moves there: the
--- estimate a stop, the view and the next command start from. Levels are device brightness 0-1; a level
--- ramp's ends are the brightness the light shows, 0 for off.

local log = require("lib.logging")
local Caps = require("lib.light.caps")
local Color = require("lib.light.color")
local Fade = require("lib.light.fade")
local Range = require("lib.light.range")

require("drivers-common-public.global.timer")

local TIMER_LEVEL = "Light.Ramp.level"
local TIMER_COLOR = "Light.Ramp.color"
local TIMER_WALK = "Light.Walk"

-- The fade before the first declare, for an estimate only: no command goes out before it.
--- @type LightFade
local DEFAULT_FADE = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = Caps.RATE_MAX }

--- Where the light is and where it is heading.
--- @class LightMotion
--- @field light Light Only for the timers' calls back.
--- @field device LightDevice|nil
--- @field on boolean Power at the end of the newest change.
--- @field level number|nil Device brightness at its end, or the level kept while off; nil while unknown.
--- @field color LightColor|nil The color at its end; nil while unknown.
--- @field levelRamp LightLevelRamp|nil
--- @field colorRamp LightColorRamp|nil
--- @field walking boolean The walk's step timer is armed.
--- @field walked LightFrom|nil What the walk's last step sent.
--- @field walkKept number|nil The level an off device keeps, for a walk that starts from off.
--- @field walkFrom integer|nil C4:GetTime() ms of the newest command that set the walk's ramps.
--- @field levelSent {at: integer, on: boolean, level: number}|nil The newest command that set the level: when, and
---   the power and level it sent.
--- @field wireOn boolean The power the newest command sent leaves the device in.
--- @field held boolean The light is off with a color told but not sent; LightNow.colorHeld on a "hold" device.
--- @field levelPreset integer|nil
--- @field colorPreset integer|nil
--- @field colorPresetOrigin integer|nil
--- @field ms LightMotionSettings|nil The settings values the newest command came with, for estimates between them.
--- @field assumed boolean Another hand's on waits for its level: commands take the light, and the device, as lit.
local Motion = {}
Motion.__index = Motion

local sameColor = Color.alike

--- @param cmd LightCommand
--- @return LightCommand
local function copy(cmd)
  local out = {}
  for k, v in pairs(cmd) do
    out[k] = v
  end
  return out
end

--- @param light Light
--- @return LightMotion
function Motion.new(light)
  return setmetatable({
    light = light,
    on = false,
    walking = false,
    wireOn = false,
    held = false,
    assumed = false,
  }, Motion)
end

--- @param device LightDevice
function Motion:declare(device)
  self.device = device
end

--- Start from what the proxy shows. An off light's color counts as held: the library can't tell after a
--- restart whether it was, and on a "hold" device the next on carries it, as the proxy shows it.
--- @param seed LightSeed
function Motion:seed(seed)
  if seed.level ~= nil then
    self.on = seed.level > 0
    self.wireOn = self.on
    if seed.level > 0 then
      self.level = seed.level
    end
  end
  if seed.color ~= nil then
    self.color = seed.color
    self.held = not self.on
  end
end

-----------------------------------------------------------------------------------------------------
-- What the other parts read
-----------------------------------------------------------------------------------------------------

--- Where each aspect is going: a ramp's end while one runs. During a walk the device holds only the steps it
--- was sent, so the newest step is where it is going.
--- @return LightNow
function Motion:now()
  local walked = self.walked
  if walked and (self.levelRamp or self.colorRamp) then
    local lit = walked.level > 0
    return {
      on = lit,
      level = lit and walked.level or self.walkKept or self:_kept(walked.level),
      color = walked.color or self.color,
      levelRamping = self.levelRamp ~= nil,
      colorRamping = self.colorRamp ~= nil,
      colorHeld = self:_held(),
    }
  end
  return {
    on = self.on,
    level = self.level,
    color = self.color,
    levelRamping = self.levelRamp ~= nil,
    colorRamping = self.colorRamp ~= nil,
    colorHeld = self:_held(),
  }
end

--- Where the light is now and where it is heading, for LightProxy.
--- @return LightView
function Motion:view()
  local t = C4:GetTime()
  local shown = self:_levelAt(t)
  local view = {
    on = self.on,
    level = shown,
    levelMs = 0,
    color = self:_colorAt(t),
    colorMs = 0,
    levelPreset = self.levelPreset,
    colorPreset = self.colorPreset,
    colorPresetOrigin = self.colorPresetOrigin,
  }
  local lr, cr = self.levelRamp, self.colorRamp
  if lr then
    view.levelTarget = lr.to
    view.levelMs = Fade.left(lr.startMs, lr.ms, t)
  end
  if cr then
    view.colorTarget = cr.to
    view.colorMs = Fade.left(cr.startMs, cr.ms, t)
  end
  return view
end

--- When the newest change of an aspect ends.
--- @param aspect LightAspect
--- @return integer ms C4:GetTime() ms.
function Motion:landing(aspect)
  local ramp = aspect == "color" and self.colorRamp or self.levelRamp
  if ramp then
    return ramp.startMs + ramp.ms
  end
  return C4:GetTime()
end

-----------------------------------------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------------------------------------

--- Whether another hand's on waits for its level. Only command translation reads it: the view and now() keep
--- the light as last settled, so it is told at the level that comes.
--- @param lit boolean
function Motion:assumeLit(lit)
  self.assumed = lit == true
end

--- An intent from the proxy, a link or a scene.
--- @param intent LightIntent
--- @param choice LightOnChoice|nil
--- @param ms LightMotionSettings
--- @return LightCommand[]
function Motion:command(intent, choice, ms)
  local out = {}
  self.ms = ms
  if not self.device then
    return out
  end
  local kind = intent.kind
  if kind == "color" then
    self:_toColor(out, intent, choice, ms)
  elseif kind == "stopLevel" then
    self:_stopLevel(out, ms)
  elseif kind == "stopColor" then
    self:_stopColor(out)
  elseif kind == "stop" then
    self:_stopBoth(out, ms)
  else
    self:_toLevel(out, intent, choice, ms)
  end
  return out
end

--- The adapter sent a command, and says where the device rests if not where the command said.
--- @param cmd LightCommand
--- @param rest LightRest|nil
--- @return LightCommand rested The command with the rest written in.
function Motion:sent(cmd, rest)
  if rest == nil then
    return cmd
  end
  local rested = copy(cmd)
  if rest.level ~= nil then
    rested.level = rest.level
    if cmd.on then
      self.level = rest.level
      if self.levelRamp then
        self.levelRamp.to = rest.level
      end
    end
  end
  if rest.color ~= nil then
    rested.color = rest.color
    self.color = rest.color
    if self.colorRamp then
      self.colorRamp.to = rest.color
    end
  end
  return rested
end

--- Adopt what the device has said; a ramp on that aspect ends there. A value that differs from Motion's
--- drops the preset that set the old one. A power alone says nothing of how far a level ramp has got: it
--- ends only a ramp heading the other way.
--- @param values LightValues
function Motion:settle(values)
  if values.on ~= nil or values.level ~= nil then
    local lr = self.levelRamp
    if values.on ~= nil then
      self.on = values.on
      self.wireOn = values.on
      if values.on then
        self.held = false
      end
    end
    if values.level ~= nil then
      if not self:_sameLevel(values.level, self.level) then
        self.levelPreset = nil
      end
      self.level = values.level
      self:_endLevelRamp()
    elseif lr and values.on ~= (lr.to > 0) then
      self:_endLevelRamp()
    end
  end
  if values.color ~= nil then
    if not sameColor(values.color, self.color) then
      self.colorPreset, self.colorPresetOrigin = nil, nil
      self.held = false
    end
    self.color = values.color
    self:_endColorRamp()
    if self.levelRamp then
      self.levelRamp.merged = nil
    end
  end
  self:_stopWalkIfDone()
end

--- A ramp's timer ran out: the aspect is at its rest value. It sends nothing.
--- @param aspect LightAspect
--- @return LightCommand[]
function Motion:ended(aspect)
  if aspect == "color" then
    self.colorRamp = nil
  else
    self.levelRamp = nil
  end
  return {}
end

--- The walk is due its next step: one 0-time change at the estimate, or the ends once both ramps are done.
--- @param ms LightMotionSettings
--- @return LightCommand[]
function Motion:step(ms)
  local out = {}
  self.ms = ms
  self.walking = false
  local lr, cr = self.levelRamp, self.colorRamp
  if not lr and not cr then
    return out
  end
  local t = C4:GetTime()
  -- A step due in the ms a command set the ramps waits a step: that ms's commands have sent all it moves.
  if self.walkFrom == t then
    self:_walk(self.walked)
    return out
  end
  local done = (lr == nil or t >= lr.startMs + lr.ms) and (cr == nil or t >= cr.startMs + cr.ms)
  local shown, color
  if done then
    shown, color = self:_shown(), self.color
  else
    shown, color = self:_levelAt(t), self:_colorAt(t)
  end
  local last = self.walked or { level = lr and lr.from or self:_shown(), color = cr and cr.from or color }
  local levelMoves = (shown <= 0) ~= (last.level <= 0) or not self:_sameLevel(shown, last.level)
  -- The last step lands a color the walk moved exactly, however little it moved.
  local colorMoves = not sameColor(color, last.color, (done and cr) and 0 or nil)
  if done then
    self.levelRamp, self.colorRamp, self.walked = nil, nil, nil
  else
    if lr then
      lr.stepSent = shown
    end
    if cr then
      cr.stepSent = color
    end
    self:_walk(last)
  end
  if not done and not levelMoves and not colorMoves then
    return out
  end
  if not done then
    -- What the device was sent: an aspect a step leaves alone stays where the last step put it.
    self.walked = { level = levelMoves and shown or last.level, color = colorMoves and color or last.color }
  end
  -- An off goes dark in the color the level carries (Dim-To-Warm's Dim color), and in no other.
  local setsColor = colorMoves and (shown > 0 or (cr ~= nil and cr.carried) or (lr ~= nil and lr.merged ~= nil))
  self:_push(out, {
    kind = "change",
    on = shown > 0,
    level = shown > 0 and shown or self:_kept(last.level),
    color = color,
    setsLevel = levelMoves,
    setsColor = setsColor,
    transitionMs = 0,
    from = last,
    colorUnchosen = (lr ~= nil and lr.unchosen) or (cr ~= nil and cr.unchosen),
  })
  if colorMoves and not setsColor then
    -- The color goes alone after the off: a "hold" device keeps it for the next on.
    self:_push(out, {
      kind = "change",
      on = false,
      level = self:_kept(last.level),
      color = color,
      setsLevel = false,
      setsColor = true,
      transitionMs = 0,
      from = { level = 0, color = last.color },
      colorUnchosen = false,
    })
  end
  return out
end

--- End running ramps at their targets: a changed fade on declare. A walk the device is part way through gets
--- one last 0-time step to the ends, since no step took it there; a device fade got there by itself.
--- @return LightCommand[]
function Motion:finishAll()
  local out = {}
  local lr, cr = self.levelRamp, self.colorRamp
  if self.walked and (lr or cr) and self.ms and self.device then
    local t = C4:GetTime()
    if lr then
      lr.ms = math.max(0, t - lr.startMs)
    end
    if cr then
      cr.ms = math.max(0, t - cr.startMs)
    end
    CancelTimer(TIMER_WALK)
    self.walking = false
    out = self:step(self.ms)
  end
  self:_dropRamps()
  return out
end

--- Every running ramp stops where its estimate has the light, sending nothing: another hand's command on a
--- device that re-times restarts every channel from where it is. A walked light is where its last step put it.
function Motion:haltAll()
  local t = C4:GetTime()
  local walked = self.walked
  if walked and (self.levelRamp or self.colorRamp) then
    self.on = walked.level > 0
    if walked.level > 0 then
      self.level = walked.level
    end
    if walked.color then
      self.color = walked.color
    end
  else
    if self.levelRamp then
      local shown = self:_levelAt(t)
      self.on = shown > 0
      if shown > 0 then
        self.level = shown
      end
    end
    if self.colorRamp then
      self.color = self:_colorAt(t)
    end
  end
  self:_dropRamps()
end

--- No ramp runs and no step waits.
--- @private
function Motion:_dropRamps()
  self:_endLevelRamp()
  self:_endColorRamp()
  CancelTimer(TIMER_WALK)
  self.walking, self.walked, self.walkKept = false, nil, nil
end

--- The run is replaced: ramps stop where the estimate has the light, and nothing waits to go.
function Motion:reset()
  self:haltAll()
end

-----------------------------------------------------------------------------------------------------
-- Intents
-----------------------------------------------------------------------------------------------------

--- On, off, toggle and level: the level aspect, with the color an on mode or Dim-To-Warm has it carry.
--- @private
--- @param out LightCommand[]
--- @param intent LightIntent
--- @param choice LightOnChoice|nil
--- @param ms LightMotionSettings
function Motion:_toLevel(out, intent, choice, ms)
  local t = C4:GetTime()
  local device, fade = self.device, self:_fade()
  local fromShown = self:_levelAt(t)
  -- A walked strip holds only the steps it is sent: a new ramp starts from the last, not under it.
  if fade.kind == "walk" and self.walked and (self.levelRamp or self.colorRamp) then
    fromShown = self.walked.level
  end
  if self.assumed and fromShown <= 0 then
    fromShown = self.level or 1
  end
  local kind = intent.kind
  if kind == "toggle" then
    kind = (self.assumed or self:_levelAt(t, true) > 0) and "off" or "on"
  end
  local target, rate
  if kind == "off" then
    target, rate = 0, intent.rateMs or 0
  elseif kind == "on" then
    target = choice and self:_toDevice(choice.level, ms) or self.level or 1
    rate = intent.rateMs or 0
  else
    target, rate = self:_toDevice(intent.level or 0, ms), intent.rateMs or ms.rate
  end
  if not device.dims then
    target = target > 0 and 1 or 0
  end
  local toOn = target > 0
  -- A scene step's color is its own, set with the level; an on mode's or Dim-To-Warm's rides the level.
  local own = intent.color and self:_take(intent.color) or nil
  local merged = own or (choice and choice.color and self:_take(choice.color)) or nil
  local unchosen = own == nil and merged ~= nil and choice ~= nil and choice.unchosen == true
  local colorMoves = merged ~= nil and not sameColor(merged, self.color)
  -- A scene step's color, and Dim-To-Warm's mix, go with every level, even one the light already shows.
  local withLevel = own ~= nil or (merged ~= nil and unchosen)
  local levelMoves = self.levelRamp ~= nil or toOn ~= self.on or not self:_sameLevel(target, self.level)
  self.levelPreset = kind == "level" and not intent.color and intent.presetId or nil

  -- A light that does not dim takes no level ramp, but a color the command carries still runs over the fade.
  local length = Fade.length(fade, fromShown > 0, toOn, rate)
  local levelLength = device.dims and length or 0
  local fromColor = self:_colorAt(t)
  local from = { level = fromShown, color = fromColor }
  local kept = self:_kept(fromShown)
  self.on = toOn
  self.level = toOn and target or kept

  self:_endLevelRamp()
  local colorRamped = false
  local toShown = toOn and target or 0
  if levelLength > 0 and levelMoves and not self:_sameShown(fromShown, toShown) then
    self.levelRamp = {
      from = fromShown,
      to = toShown,
      startMs = t,
      ms = levelLength,
      set = false,
      merged = merged,
      unchosen = unchosen,
    }
  end
  if merged then
    self.color = merged
    if own then
      self.colorPreset, self.colorPresetOrigin = intent.presetId, intent.presetOrigin
    else
      self.colorPreset, self.colorPresetOrigin = choice.presetId, choice.presetOrigin
    end
    local cr = self.colorRamp
    if cr and sameColor(cr.to, merged) then
      -- The color is on its way there: it keeps going, over this command's time on a device that re-times or
      -- when this command sends the color too.
      if Fade.retimes(fade) or withLevel then
        self:_retimeColor(length, t)
      end
    else
      self:_endColorRamp()
      -- The color goes from the one the light has to the new one over the level's time, from dark too. A light
      -- with no color known is taken to be in D65.
      local start = length > 0 and (fromColor or self:_take(Color.D65)) or nil
      if start ~= nil and not sameColor(start, merged) then
        colorRamped = true
        self.colorRamp = {
          from = start,
          to = merged,
          startMs = t,
          ms = length,
          carried = own == nil,
          unchosen = unchosen,
        }
      end
    end
    if own and self.levelRamp then
      self.levelRamp.merged, self.levelRamp.set = nil, true
    end
  elseif self.colorRamp and Fade.retimes(fade) then
    self:_retimeColor(length, t)
    -- Every channel restarts over this command's time: a color ramp it ends lands now, in this command.
    withLevel = withLevel or self.colorRamp == nil
  end
  self:_armRamps(fade)
  -- An on from off sets the color a held color or an on mode gives it, even one equal to the color kept, and
  -- a pre-on and its change both carry it.
  local carries = toOn and not self.wireOn and (merged ~= nil or (device.colorWhileOff == "hold" and self.held))
  if fade.kind == "walk" and (self.levelRamp or self.colorRamp) then
    local lr = self.levelRamp
    -- A level no ramp walks goes at once, and a walk from off lights the light at once with its first step, unless
    -- a command in this same ms has just sent that power and level.
    if not lr or fromShown <= 0 then
      local level = lr and self:_rawLevelAt(t) or self.level
      local color = self.colorRamp and (self.walked and self.walked.color or fromColor) or self.color
      local sent = self.levelSent
      local already = lr == nil
        and sent ~= nil
        and sent.at == t
        and sent.on == toOn
        and (not toOn or self:_sameLevel(sent.level, level))
      if not already then
        self:_push(out, {
          kind = "change",
          on = toOn,
          level = level,
          color = color,
          setsLevel = true,
          setsColor = self.colorRamp == nil and (colorMoves or carries or withLevel),
          transitionMs = 0,
          from = from,
          colorUnchosen = unchosen,
        })
      end
      if lr then
        lr.stepSent = level
      end
      self.walked = { level = toOn and level or 0, color = color }
    end
    self.walkFrom = t
    self:_walk(from, fromShown <= 0 and kept or nil)
    return
  end
  self:_stopWalkIfDone()
  local transition = Fade.transition(fade, (device.dims or merged ~= nil) and length or 0)
  if fade.kind == "device" and fade.preOn and device.dims and transition > 0 and toOn and fromShown <= 0 then
    local bottom = 1 / self:_steps()
    -- A color that fades with the level starts where the light has it, or, with none known, the pre-on puts it in
    -- the D65 its ramp starts from; one set at once goes with the pre-on.
    local preColor = colorRamped and self.colorRamp.from or self.color
    self:_push(out, {
      kind = "preOn",
      on = true,
      level = bottom,
      color = preColor,
      setsLevel = true,
      setsColor = (colorRamped and fromColor == nil) or (not colorRamped and (colorMoves or carries)),
      transitionMs = 0,
      from = from,
      colorUnchosen = unchosen,
    })
    from = { level = bottom, color = preColor }
    if not colorRamped then
      colorMoves = false
    end
  end
  self:_push(out, {
    kind = "change",
    on = toOn,
    level = self.level,
    color = self.color,
    setsLevel = true,
    setsColor = colorMoves or carries or withLevel,
    transitionMs = transition,
    from = from,
    colorUnchosen = unchosen,
  })
end

--- A color: the light goes to it over the rate, or, off or fading to off, takes it as the next on's.
--- @private
--- @param out LightCommand[]
--- @param intent LightIntent
--- @param choice LightOnChoice|nil
--- @param ms LightMotionSettings
function Motion:_toColor(out, intent, choice, ms)
  if choice and choice.followUp then
    return
  end
  local target = intent.color and self:_take(intent.color)
  if not target then
    log:debug("Motion: a color the device cannot show is dropped")
    return
  end
  local lit = self.on or self.assumed
  -- Off, the color is the next on's: told as asked, while the wire takes it as the device can show it.
  if not lit then
    target = Color.forDevice(intent.color, self.device, true) or target
  end
  self.colorPreset, self.colorPresetOrigin = intent.presetId, intent.presetOrigin
  local t = C4:GetTime()
  local fade = self:_fade()
  local from = { level = self:_levelAt(t), color = self:_colorAt(t) }
  local lr = self.levelRamp
  if lr then
    lr.merged, lr.set = nil, true
  end
  local rate = intent.rateMs or ms.colorRate
  local length = Fade.length(fade, true, true, rate)
  local cr = self.colorRamp
  if lit and cr and sameColor(cr.to, target) and t + length >= cr.startMs + cr.ms then
    -- The color is on its way there already, and no sooner by this: it keeps going, now a color of its own, and
    -- nothing more goes out. The proxy's own copy of an on's color comes this way.
    cr.carried, cr.unchosen = false, false
    return
  end
  self:_endColorRamp()
  self.color = target

  if not lit then
    -- On a "device" fade the color runs over what the fade to off has left, so it is there as the light goes dark.
    if fade.kind == "walk" and self.walking then
      return -- the walk's next step carries it
    end
    local left = (lr and fade.kind == "device") and Fade.left(lr.startMs, lr.ms, t) or 0
    -- On a device that re-times, the level restarts from where it is over the same time left.
    if lr and Fade.retimes(fade) then
      self:_retimeLevel(left, t)
      self:_armRamps(fade)
    end
    self:_push(out, {
      kind = "change",
      on = self.wireOn,
      level = self:_kept(from.level),
      color = target,
      setsLevel = false,
      setsColor = true,
      transitionMs = left,
      from = from,
      colorUnchosen = false,
    })
    return
  end

  -- A light with no color known is taken to be in D65.
  local start = length > 0 and (from.color or self:_take(Color.D65) or target) or target
  if not sameColor(start, target) then
    self.colorRamp = {
      from = start,
      to = target,
      startMs = t,
      ms = length,
      carried = false,
      unchosen = false,
    }
  end
  if lr and Fade.retimes(fade) then
    self:_retimeLevel(length, t)
  end
  self:_armRamps(fade)
  if fade.kind == "walk" and self.colorRamp then
    self.walkFrom = t
    self:_walk(from)
    return
  end
  -- During a walk the strip is at its last step, and an instant color goes at once, so no step repeats it.
  local walked = self.walked
  self:_push(out, {
    kind = "change",
    on = self.wireOn or self.assumed,
    level = walked and walked.level > 0 and walked.level or self.level or 1,
    color = target,
    setsLevel = false,
    setsColor = true,
    transitionMs = Fade.transition(fade, length),
    from = from,
    colorUnchosen = false,
  })
  if walked then
    walked.color = self.color
  end
  self:_stopWalkIfDone()
end

--- SET_BRIGHTNESS_STOP: the light holds where its level ramp has it. Under "own" the device's fade runs out.
--- @private
--- @param out LightCommand[]
--- @param ms LightMotionSettings
function Motion:_stopLevel(out, ms)
  local lr = self.levelRamp
  local fade = self:_fade()
  if not lr or fade.kind == "own" then
    return
  end
  local t = C4:GetTime()
  local shown = self:_stopShown(lr, self:_levelAt(t), ms)
  local cr = self.colorRamp
  -- Before a walk's first step the strip is still where it was: it holds there, and nothing goes out.
  local walked = fade.kind == "walk" and lr.stepSent == nil and self.walked or nil
  if walked then
    shown = walked.level
  end
  -- A color of its own, or one set since the ramp began, runs on; the color the level carried stops with it.
  local keepColor = (cr ~= nil and not cr.carried) or lr.set
  local color, colorMs, unchosen = self.color, 0, lr.unchosen
  if not keepColor then
    if walked then
      color = walked.color or color
    elseif cr then
      color, unchosen = self:_heldColor(cr, t), cr.unchosen
    end
    self:_endColorRamp()
  elseif cr and Fade.retimes(fade) then
    colorMs = Fade.left(cr.startMs, cr.ms, t)
    self:_retimeColor(colorMs, t)
    if not self.colorRamp then
      colorMs = 0
    end
  end
  local colorMoves = not sameColor(color, self.color)
  self:_endLevelRamp()
  self.levelPreset = nil
  self.on = shown > 0
  self.level = shown > 0 and shown or self:_kept(lr.from)
  self.color = color
  self:_stopWalkIfDone()
  if walked then
    return
  end
  self:_push(out, {
    kind = "stop",
    on = shown > 0,
    level = self.level,
    color = color,
    setsLevel = true,
    setsColor = colorMoves,
    transitionMs = colorMs,
    from = { level = shown, color = color },
    colorUnchosen = unchosen == true,
  })
end

--- Where a stop holds the level a ramp has: from off, under the Min it holds at the Min; to off, under the Min
--- it holds at the Min, or off under half way to it; and on a whole C4 level, so the device and the proxy agree on it exactly. A light outside the
--- Min/Max line, left there by a change of it, holds where it is, as does a walk, whose steps stay lit until its off.
--- @private
--- @param lr LightLevelRamp
--- @param shown number
--- @param ms LightMotionSettings
--- @return number
function Motion:_stopShown(lr, shown, ms)
  local minOn = self:_toDevice(1, ms)
  if lr.to > 0 and lr.from <= 0 and shown < minOn then
    shown = minOn -- a light on its way on stops lit
  elseif lr.to <= 0 and shown < minOn and self:_fade().kind ~= "walk" then
    shown = shown < minOn / 2 and 0 or minOn
  end
  local bottom, top = Range.toDevice(1, ms.lo, ms.hi), Range.toDevice(100, ms.lo, ms.hi)
  if shown > 0 and shown >= bottom - 1e-9 and shown <= top + 1e-9 then
    shown = Range.toDevice(Range.toLevel(shown, ms.lo, ms.hi), ms.lo, ms.hi)
  end
  return shown
end

--- A stop of both aspects at once (Stop Scene Ramp): each holds where its estimate is, in one command that
--- names both. Nothing when neither ramps. Under "own" the device's fade runs out.
--- @private
--- @param out LightCommand[]
--- @param ms LightMotionSettings
function Motion:_stopBoth(out, ms)
  local lr, cr = self.levelRamp, self.colorRamp
  if (not lr and not cr) or self:_fade().kind == "own" then
    return
  end
  local t = C4:GetTime()
  local shown = self:_levelAt(t)
  local on, level, before = self.on, self.level, self.color
  if lr then
    shown = self:_stopShown(lr, shown, ms)
    on = shown > 0
    level = shown > 0 and shown or self:_kept(lr.from)
    self.levelPreset = nil
  end
  local color = cr and self:_heldColor(cr, t) or self:_colorAt(t)
  local unchosen = (lr ~= nil and lr.unchosen) or (cr ~= nil and cr.unchosen)
  if cr then
    self.colorPreset, self.colorPresetOrigin = nil, nil
  end
  self:_endLevelRamp()
  self:_endColorRamp()
  self.on, self.level, self.color = on, level, color
  self:_stopWalkIfDone()
  local device = self.device
  self:_push(out, {
    kind = "stop",
    on = on,
    level = level,
    color = color,
    setsLevel = true,
    setsColor = (device.color or device.cct ~= nil) and (cr ~= nil or not sameColor(color, before)),
    transitionMs = 0,
    from = { level = shown, color = color },
    colorUnchosen = unchosen == true,
  })
end

--- SET_COLOR_STOP: the color holds where its ramp has it. Under "own" the device's fade runs out.
--- @private
--- @param out LightCommand[]
function Motion:_stopColor(out)
  local cr = self.colorRamp
  local fade = self:_fade()
  if not cr or fade.kind == "own" then
    return
  end
  local t = C4:GetTime()
  local color = self:_heldColor(cr, t)
  local lr = self.levelRamp
  local shown = self:_levelAt(t)
  self:_endColorRamp()
  self.color = color
  self.colorPreset, self.colorPresetOrigin = nil, nil
  -- A color of its own stops for good; one the level carried still follows the level's Dim-To-Warm.
  if lr and not cr.carried then
    lr.merged, lr.set = nil, true
  end
  local levelMs = 0
  if lr and Fade.retimes(fade) then
    levelMs = Fade.left(lr.startMs, lr.ms, t)
    self:_retimeLevel(levelMs, t)
    if not self.levelRamp then
      levelMs = 0
    end
    self:_armRamps(fade)
  end
  -- A level set at once while the color walked waits on the walk's next step: ending the walk, the color holds
  -- in a change to that level.
  local walked = self.walked
  local owed = fade.kind == "walk"
    and lr == nil
    and walked ~= nil
    and ((shown > 0) ~= (walked.level > 0) or not self:_sameLevel(shown, walked.level))
  local on, level, fromLevel = self.wireOn, self:_kept(shown), shown
  if owed then
    on, level, fromLevel = shown > 0, shown > 0 and shown or self:_kept(walked.level), walked.level
  end
  self:_stopWalkIfDone()
  self:_push(out, {
    kind = owed and "change" or "stop",
    on = on,
    level = level,
    color = color,
    setsLevel = owed,
    setsColor = true,
    transitionMs = levelMs,
    from = { level = fromLevel, color = color },
    colorUnchosen = cr.unchosen == true,
  })
end

-----------------------------------------------------------------------------------------------------
-- Ramps
-----------------------------------------------------------------------------------------------------

--- Where the level ramp has the brightness, as the curve runs. A walk's steps stay on the Min/Max On line: from off
--- it starts at the line's start, and to off it goes down to there, or holds a light already under it, and sends
--- its off at its end.
--- @private
--- @param t integer
--- @return number
function Motion:_rawLevelAt(t)
  local lr = self.levelRamp
  if not lr then
    return self:_shown()
  end
  local fade = self:_fade()
  local p = Fade.progress(fade, lr.startMs, lr.ms, t)
  local from, to = lr.from, lr.to
  if fade.kind == "walk" and p < 1 and self.ms then
    local start = self:_toDevice(1, self.ms)
    if from <= 0 then
      from = start
    end
    if to <= 0 then
      to = math.min(start, from)
    end
  end
  return Fade.between(from, to, p)
end

--- Where the level ramp has the light: the brightness it shows, 0 for off. On a ramp up from off a brightness
--- under half way to Min On reads as off (toggle: under half a level), as the proxy's line has it. A light fading to
--- off is lit until its ramp ends, and a walk's steps are lit until its off.
--- @private
--- @param t integer
--- @param toggle boolean|nil
--- @return number
function Motion:_levelAt(t, toggle)
  local lr = self.levelRamp
  local at = self:_rawLevelAt(t)
  if lr and self:_fade().kind ~= "walk" and lr.from <= 0 and lr.to > 0 and at > 0 and at < self:_unlit(toggle) then
    return 0
  end
  return at
end

--- The brightness under which a ramp up from off reads as off: half way to Min On, or for a toggle half a
--- level, on the newest command's Min/Max On line.
--- @private
--- @param toggle boolean|nil
--- @return number
function Motion:_unlit(toggle)
  local ms = self.ms
  if not ms then
    return 0.5 / self:_steps()
  end
  if toggle then
    return 0.5 * (ms.hi - ms.lo) / 9900
  end
  return Range.toDevice(1, ms.lo, ms.hi) / 2
end

--- Where the color ramp has the light.
--- @private
--- @param t integer
--- @return LightColor|nil
function Motion:_colorAt(t)
  local cr = self.colorRamp
  if not cr then
    return self.color
  end
  local at = Fade.color(cr.from, cr.to, Fade.progress(self:_fade(), cr.startMs, cr.ms, t))
  -- A white on its way between two whites keeps its Kelvin, so it goes out and is told as a white.
  if at.mode == Color.CCT and at.kelvin == nil then
    local k = Color.kelvin(at.x, at.y)
    at = { x = at.x, y = at.y, mode = Color.CCT, kelvin = k and math.floor(k + 0.5) or nil }
  end
  return at
end

--- Where a stop holds the color ramp: a ramp toward a white, stopped on the line of whites the light shows,
--- holds a white there, as a ramp between two whites does. One leaving a white is at a color throughout.
--- @private
--- @param cr LightColorRamp
--- @param t integer
--- @return LightColor
function Motion:_heldColor(cr, t)
  local at = self:_colorAt(t)
  local cct = self.device.cct
  if
    at.mode == Color.CCT
    or cr.to.mode ~= Color.CCT
    or not cct
    or not Color.onLocus(at.x, at.y, cct.minK, cct.maxK)
  then
    return at
  end
  return { x = at.x, y = at.y, mode = Color.CCT, kelvin = math.floor(Color.kelvin(at.x, at.y) + 0.5) }
end

--- A command for the level takes the color on to its target over the command's time.
--- @private
--- @param length integer
--- @param t integer
function Motion:_retimeColor(length, t)
  local cr = self.colorRamp
  local at = self:_colorAt(t)
  if length <= 0 or sameColor(at, cr.to) then
    self:_endColorRamp()
    return
  end
  cr.from, cr.startMs, cr.ms = at, t, length
end

--- A command for the color takes the level on to its target over the command's time.
--- @private
--- @param length integer
--- @param t integer
function Motion:_retimeLevel(length, t)
  local lr = self.levelRamp
  local at = self:_levelAt(t)
  if length <= 0 or self:_sameShown(at, lr.to) then
    self:_endLevelRamp()
    return
  end
  lr.from, lr.startMs, lr.ms = at, t, length
end

--- Set each running ramp's end timer. A walk ends its ramps itself, at its last step.
--- @private
--- @param fade LightFade
function Motion:_armRamps(fade)
  if fade.kind == "walk" then
    return
  end
  local t = C4:GetTime()
  local lr, cr = self.levelRamp, self.colorRamp
  -- Director refuses a 0 ms timer, so a ramp that lands now ends on the shortest one it takes.
  if lr then
    SetTimer(TIMER_LEVEL, math.max(1, Fade.left(lr.startMs, lr.ms, t)), function()
      self.light:_rampEnded("level")
    end)
  end
  if cr then
    SetTimer(TIMER_COLOR, math.max(1, Fade.left(cr.startMs, cr.ms, t)), function()
      self.light:_rampEnded("color")
    end)
  end
end

--- @private
function Motion:_endLevelRamp()
  CancelTimer(TIMER_LEVEL)
  self.levelRamp = nil
end

--- @private
function Motion:_endColorRamp()
  CancelTimer(TIMER_COLOR)
  self.colorRamp = nil
end

--- Arm the walk's next step, unless it is armed. A walk that starts steps from `from`, and from off keeps `kept`.
--- @private
--- @param from LightFrom
--- @param kept number|nil
function Motion:_walk(from, kept)
  if self.walking then
    return
  end
  if self.walked == nil then
    self.walked = from
    self.walkKept = kept
  end
  self.walking = true
  SetTimer(TIMER_WALK, self:_fade().stepMs, function()
    self.light:_walkStep()
  end)
end

--- With no ramp left the walk has nothing to step.
--- @private
function Motion:_stopWalkIfDone()
  if self.levelRamp == nil and self.colorRamp == nil then
    CancelTimer(TIMER_WALK)
    self.walking, self.walked, self.walkKept = false, nil, nil
  end
end

-----------------------------------------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------------------------------------

--- Add a command to out, with the flags the contract fixes: fromOff on the first command that lights a light
--- the library holds off; setsLevel on every off and every fromOff command; setsColor on a fromOff command
--- that carries a held color. A color alone for an off "hold" device is told, not sent, and so held.
--- @private
--- @param out LightCommand[]
--- @param cmd LightCommand
function Motion:_push(out, cmd)
  local hold = self.device.colorWhileOff == "hold"
  local wireOn = self.wireOn or self.assumed
  cmd.fromOff = cmd.kind ~= "stop" and cmd.on and not wireOn
  if cmd.fromOff or cmd.on ~= wireOn then
    cmd.setsLevel = true
  end
  if cmd.fromOff and hold and self.held then
    cmd.setsColor = true
  end
  if not cmd.setsLevel and not cmd.setsColor then
    return
  end
  if hold and not cmd.on and not cmd.setsLevel then
    self.held = true
    return
  end
  if cmd.on or cmd.setsColor then
    self.held = false
  end
  local asked = cmd.color
  cmd.color = self:_wire(cmd.color)
  cmd.colorUnchosen = cmd.colorUnchosen == true
  if not self.device.dims then
    cmd.level = 1
  end
  -- Lit, the light shows the color it rests in as the wire took it: a Kelvin told as asked while off is clamped
  -- now. A walk's step or a pre-on in the color kept leaves the rest color alone.
  if cmd.on and cmd.setsColor and cmd.color and asked and sameColor(asked, self.color, 0) then
    local cr = self.colorRamp
    if cr and sameColor(cr.to, asked, 0) then
      cr.to = cmd.color
    end
    self.color = cmd.color
  end
  self.wireOn = cmd.on
  if cmd.setsLevel then
    self.levelSent = { at = C4:GetTime(), on = cmd.on, level = cmd.level }
  end
  out[#out + 1] = cmd
end

--- A "hold" device is off with a color told but not sent.
--- @private
--- @return boolean
function Motion:_held()
  return self.held and not self.on and self.device ~= nil and self.device.colorWhileOff == "hold"
end

--- A color as the device takes it, or nil where it shows none: Color.forDevice.
--- @private
--- @param color LightColor
--- @return LightColor|nil
function Motion:_take(color)
  return Color.forDevice(color, self.device)
end

--- A color as a command carries it: in the device's form, D65 for a color not yet known, the nearest white
--- on a device with CCT alone, nil on a device with neither color nor CCT.
--- @private
--- @param color LightColor|nil
--- @return LightColor|nil
function Motion:_wire(color)
  local device = self.device
  if not (device.color or device.cct) then
    return nil
  end
  color = color or Color.D65
  local taken = Color.forDevice(color, device)
  if taken then
    return taken
  end
  if device.cct then
    return Color.forDevice({ x = color.x, y = color.y, mode = Color.CCT }, device)
  end
  return { x = color.x, y = color.y, mode = Color.FULL }
end

-----------------------------------------------------------------------------------------------------
-- Levels
-----------------------------------------------------------------------------------------------------

--- @private
--- @return LightFade
function Motion:_fade()
  return self.device and self.device.fade or DEFAULT_FADE
end

--- @private
--- @return integer
function Motion:_steps()
  return self.device and self.device.levelSteps or 255
end

--- The brightness the rest values show: 0 off, 1 on a light that does not dim.
--- @private
--- @return number
function Motion:_shown()
  if not self.on then
    return 0
  end
  if self.device and not self.device.dims then
    return 1
  end
  return self.level or 1
end

--- The level an off keeps: the one known, else where the light was lit, else full.
--- @private
--- @param shown number|nil
--- @return number
function Motion:_kept(shown)
  if self.level ~= nil and not self.on then
    return self.level
  end
  if shown and shown > 0 then
    return shown
  end
  return self.level or 1
end

--- The device brightness a C4 level goes out as, on the Min/Max On line.
--- @private
--- @param level integer
--- @param ms LightMotionSettings
--- @return number
function Motion:_toDevice(level, ms)
  return Range.toDevice(level, ms.lo, ms.hi)
end

--- Two brightnesses the light shows alike: both off, or both lit at one step.
--- @private
--- @param a number
--- @param b number
--- @return boolean
function Motion:_sameShown(a, b)
  return (a > 0) == (b > 0) and (a <= 0 or self:_sameLevel(a, b))
end

--- Two brightnesses the device shows as one step.
--- @private
--- @param a number|nil
--- @param b number|nil
--- @return boolean
function Motion:_sameLevel(a, b)
  if a == nil or b == nil then
    return a == b
  end
  local steps = self:_steps()
  return Range.step(a, steps) == Range.step(b, steps)
end

return Motion
