--- The colors Control4 chose that outlast the command that chose them (DRV-163), and the window in which
--- the proxy's own follow-up of an on is no choice:
--- - the next-on color: one set while the light is off, that the next on comes on in;
--- - the pick: the on cycle's chosen color, which levels keep, with no on mode's color, until the light
---   reaches off. A scene's color-only step is one; a step that sets level and color together is not;
--- - the follow-up window: 250 ms after an on or a level that names a brightness preset (a Navigator On), in
---   which the proxy sends the Color On Mode's preset. It takes one follow-up; any other color in it is a pick and
---   closes it, so an on mode's preset after that is a choice again. Every color outside it is a pick.
--- None of it persists: a reload ends it, as a loss or Reset Driver does.

local OnColor = require("lib.light.oncolor")

-- A proxy follows a Navigator On with the Color On Mode's preset within this window: 250 ms covers its usual gap
-- of 6 to 50 ms.
local FOLLOW_UP_MS = 250

--- @class LightPicks
--- @field nextOn LightPick|nil
--- @field picked LightPick|nil
--- @field followUntil integer|nil C4:GetTime() ms when the follow-up window closes.
--- @field followSpent boolean The window took its follow-up, and closes at the next intent, once the on's
---   choice has read it.
local Picks = {}
Picks.__index = Picks

--- @return LightPicks
function Picks.new()
  return setmetatable({ followSpent = false }, Picks)
end

--- What an on reads.
--- @return LightOnPicks
function Picks:forOn()
  local open = self.followUntil ~= nil and C4:GetTime() < self.followUntil
  return { nextOn = self.nextOn, picked = self.picked, followUp = open }
end

--- Open the window after an on or level that names a brightness preset; any other shuts it.
--- @private
--- @param intent LightIntent
function Picks:_follow(intent)
  self.followUntil = intent.presetId ~= nil and C4:GetTime() + FOLLOW_UP_MS or nil
end

--- Take an intent, before the on's choice reads the picks.
--- @param intent LightIntent
--- @param now LightNow
--- @param settings LightOnSettings|nil Whose on modes decide the proxy's follow-up; nil takes any named preset as the follow-up.
function Picks:noted(intent, now, settings)
  if self.followSpent then
    self.followUntil, self.followSpent = nil, false
  end
  -- A light off and still has reached off since the last intent: the cycle's pick ended there, when the proxy
  -- was told level 0, not at the command that darkened it, so a hold down or a fade that stays lit keeps it.
  if not now.on and not now.levelRamping then
    self.picked = nil
  end
  local kind = intent.kind
  if kind == "color" then
    if not intent.color then
      return
    end
    if OnColor.followUp(intent, self:forOn(), settings) then
      self.followSpent = true
      return
    end
    self.followUntil = nil
    local pick = { color = intent.color, presetId = intent.presetId, presetOrigin = intent.presetOrigin }
    -- A light still lit on its way to off takes it as this cycle's pick, which ends at that off.
    if now.on or now.levelRamping then
      self.picked = pick
    else
      self.nextOn = pick
    end
  elseif OnColor.lights(intent, now) then
    -- The on that takes the held color makes it the cycle's pick.
    local took = self.nextOn
    if took then
      self.picked, self.nextOn = took, nil
    end
    self:_follow(intent)
  elseif OnColor.darkens(intent, now) then
    self.followUntil = nil
  elseif kind == "on" or kind == "level" then
    self:_follow(intent)
  end
end

--- Another hand moved these aspects. Its color voids both picks. Its on or off ends the cycle's pick, and a
--- color held for the next on becomes the pick of a light another hand lit, so no on mode's color follows it.
--- @param aspects LightAspect[]
function Picks:foreign(aspects)
  local on, color = false, false
  for _, aspect in ipairs(aspects) do
    on = on or aspect == "on"
    color = color or aspect == "color"
  end
  if on then
    self.picked, self.nextOn = self.nextOn, nil
  end
  if color then
    self.picked, self.nextOn = nil, nil
  end
end

--- The run replaced: nothing held.
function Picks:reset()
  self.nextOn, self.picked, self.followUntil, self.followSpent = nil, nil, nil, false
end

return Picks
