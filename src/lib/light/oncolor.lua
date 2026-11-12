--- The on's choice, pure: the level an on goes to, the color it comes on in, the Dim-To-Warm color a level
--- carries, and whether a color is the proxy's follow-up of an on. It reads only the plain values Settings
--- and Picks give it, and gives colors in the form the device takes them.

local Color = require("lib.light.color")
local Range = require("lib.light.range")

--- @alias LightColorOnMode "none"|"fade"|"previous"|"preset"

--- What Settings holds that an on reads.
--- @class LightOnSettings
--- @field defaultOn boolean The profile's defaultOn: an On with no on mode goes to the Default On level.
--- @field onModes boolean The profile offers on modes: a held on's follow-up is the Color On Mode's own preset.
--- @field onLo integer Min On Level, 1-100.
--- @field onHi integer Max On Level, 1-100.
--- @field presetLevel integer The Default On level, 1-100.
--- @field onModeLevel integer|nil The brightness on mode's level, 1-100; nil: none.
--- @field colorOnMode LightColorOnMode
--- @field onColor LightColor|nil The On preset's color: a preset mode's, and Dim-To-Warm's On end.
--- @field dimColor LightColor|nil Dim-To-Warm's Dim end.
--- @field onPresetId integer|nil The On preset the mode names.
--- @field onPresetOrigin integer|nil
--- @field previousColor LightColor|nil The color the light last went off in.

--- A color Control4 chose, with the preset that set it.
--- @class LightPick
--- @field color LightColor
--- @field presetId integer|nil
--- @field presetOrigin integer|nil

--- What Picks holds that an on reads.
--- @class LightOnPicks
--- @field nextOn LightPick|nil A color set while the light was off, or going off: the next on comes on in it.
--- @field picked LightPick|nil The color picked for this on cycle: levels keep it, with no on mode's color, until
---   the light goes off.
--- @field followUp LightFollowUp|nil Open while the proxy may follow the last on or level with its color.

--- @class LightFollowUp
--- @field held boolean The on took the held color and named a brightness preset (a Navigator On): its follow-up
---   names a preset, and is no color to apply.

--- A choice with the preset its color is, told with the color.
--- @class LightOnColorChoice : LightOnChoice
--- @field presetId integer|nil
--- @field presetOrigin integer|nil

local OnColor = {}

--- Whether an intent lights a light the library holds off, or one fading to off.
--- @param intent LightIntent
--- @param now LightNow
--- @return boolean
function OnColor.lights(intent, now)
  if now.on then
    return false
  end
  local kind = intent.kind
  return kind == "on" or kind == "toggle" or (kind == "level" and (intent.level or 0) > 0)
end

--- Whether an intent turns the light off: an off, a toggle while on, or a level of 0.
--- @param intent LightIntent
--- @param now LightNow
--- @return boolean
function OnColor.darkens(intent, now)
  local kind = intent.kind
  return kind == "off" or (kind == "toggle" and now.on == true) or (kind == "level" and (intent.level or 0) <= 0)
end

--- Whether a color intent is the proxy's follow-up of the on or level just before it, or the color the light already
--- heads for, sent back bare or in the Color On Mode's preset. After a Navigator On that took the held color, the
--- follow-up names a preset: on a profile with on modes the Color On Mode's own (zb:2020-2027), as any other is a color
--- someone chose; without on modes any preset, as Hatch's app sends.
--- @param intent LightIntent
--- @param now LightNow
--- @param picks LightOnPicks
--- @param settings LightOnSettings|nil
--- @return boolean
function OnColor.followUp(intent, now, picks, settings)
  local window = picks.followUp
  if intent.kind ~= "color" or not window or not intent.color then
    return false
  end
  if window.held and intent.presetId ~= nil and intent.presetOrigin ~= nil then
    if not (settings and settings.onModes) then
      return true
    end
    if intent.presetId == settings.onPresetId and intent.presetOrigin == settings.onPresetOrigin then
      return true
    end
  end
  -- The color the light heads for, sent back bare or in the Color On Mode's own preset, is the proxy's echo; one
  -- naming another preset is a choice, told in that preset.
  local onModePreset = settings ~= nil
    and intent.presetId == settings.onPresetId
    and intent.presetOrigin == settings.onPresetOrigin
  if intent.presetId ~= nil and not onModePreset then
    return false
  end
  if now.on ~= true then
    return false
  end
  if now.color ~= nil and Color.alike(intent.color, now.color) then
    return true
  end
  -- The proxy sends the on mode's color back as it holds it, which the light may show in its own form: a white
  -- off the locus, or a white on a light with no color temperature.
  return settings ~= nil and Color.alike(intent.color, OnColor.proxyOnColor(now, settings))
end

--- The color the proxy holds for an on in its on mode: the On color, Previous On's color, or the Dim-To-Warm
--- mix at the level the light heads for. Nil when the on mode gives none.
--- @param now LightNow
--- @param settings LightOnSettings
--- @return LightColor|nil
function OnColor.proxyOnColor(now, settings)
  local mode = settings.colorOnMode
  if mode == "preset" then
    return settings.onColor
  elseif mode == "previous" then
    return settings.previousColor
  elseif mode == "fade" and settings.onColor and settings.dimColor and now.level then
    return Color.dimToWarm(settings.dimColor, settings.onColor, Range.toLevel(now.level, settings.onLo, settings.onHi))
  end
  return nil
end

--- The level an On goes to: the on mode's, else the Default On level where the profile has it, else the
--- level the device kept.
--- @param now LightNow
--- @param settings LightOnSettings
--- @return integer level A C4 level, 1-100.
function OnColor.onLevel(now, settings)
  if settings.onModeLevel then
    return settings.onModeLevel
  end
  if not settings.defaultOn and now.level and now.level > 0 then
    return Range.toLevel(now.level, settings.onLo, settings.onHi)
  end
  return settings.presetLevel
end

--- The Dim-To-Warm color at a level, in the device's form; nil without Dim-To-Warm or one of its ends.
--- @param level integer A C4 level.
--- @param device LightDevice
--- @param settings LightOnSettings
--- @return LightColor|nil
function OnColor.dimToWarm(level, device, settings)
  if settings.colorOnMode ~= "fade" or not settings.onColor or not settings.dimColor then
    return nil
  end
  return Color.forDevice(Color.dimToWarm(settings.dimColor, settings.onColor, level), device)
end

--- The color an on from off comes on in, by the color on mode. Previous On's color is no one's choice now.
--- @param level integer The C4 level it comes on at.
--- @param device LightDevice
--- @param settings LightOnSettings
--- @return LightColor|nil color
--- @return boolean unchosen
local function onModeColor(level, device, settings)
  local kind = settings.colorOnMode
  if kind == "fade" then
    return OnColor.dimToWarm(level, device, settings), false
  elseif kind == "previous" and settings.previousColor then
    return Color.forDevice(settings.previousColor, device), true
  elseif kind == "preset" and settings.onColor then
    return Color.forDevice(settings.onColor, device), false
  end
  return nil, false
end

--- The C4 level the light is at now: 0 while off.
--- @param now LightNow
--- @param settings LightOnSettings
--- @return integer
local function levelNow(now, settings)
  if not now.on then
    return 0
  end
  return Range.toLevel(now.level, settings.onLo, settings.onHi)
end

--- The choice for an intent: the level and color an on goes to, the Dim-To-Warm color a level carries, or
--- the proxy's follow-up of an on. Nil for an intent that does none of these.
--- @param intent LightIntent
--- @param inputs LightOnInputs
--- @return LightOnColorChoice|nil
function OnColor.choose(intent, inputs)
  local now, device, settings, picks = inputs.now, inputs.device, inputs.settings, inputs.picks
  if intent.kind == "color" then
    if OnColor.followUp(intent, now, picks, settings) then
      return { level = levelNow(now, settings), color = now.color, unchosen = false, followUp = true }
    end
    return nil
  end

  local lights = OnColor.lights(intent, now)
  local level
  if intent.kind == "level" and (intent.level or 0) > 0 then
    level = intent.level
  elseif intent.kind == "on" or (lights and intent.kind == "toggle") then
    level = OnColor.onLevel(now, settings)
  elseif OnColor.darkens(intent, now) and now.on then
    -- An off under Dim-To-Warm fades to the Dim color, the formula's color at level 0, unless a pick holds.
    local dim = not picks.picked and device ~= nil and OnColor.dimToWarm(0, device, settings) or nil
    if not dim then
      return nil
    end
    return { level = 0, color = dim, unchosen = true, followUp = false }
  else
    return nil
  end

  local hasColor = device ~= nil and (device.color or device.cct ~= nil)
  local color, unchosen, presetId, presetOrigin = nil, false, nil, nil
  if hasColor then
    if lights and picks.picked then
      color = Color.forDevice(picks.picked.color, device)
      presetId, presetOrigin = picks.picked.presetId, picks.picked.presetOrigin
    elseif lights then
      color, unchosen = onModeColor(level, device, settings)
      if color and settings.colorOnMode ~= "fade" then
        presetId, presetOrigin = settings.onPresetId, settings.onPresetOrigin
      end
    elseif not picks.picked then
      -- A level while on carries Dim-To-Warm's color, the light's own choice for no one now.
      color = OnColor.dimToWarm(level, device, settings)
      unchosen = color ~= nil
    end
  end

  if not lights and intent.kind ~= "on" and color == nil then
    return nil
  end
  return {
    level = level,
    color = color,
    unchosen = unchosen,
    followUp = false,
    presetId = presetId,
    presetOrigin = presetOrigin,
  }
end

return OnColor
