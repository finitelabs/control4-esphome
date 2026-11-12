--- The ESPHome light's wire: the color modes an entity lists, the command fields a color or white takes on each,
--- the white last sent, the fade ESPHome runs between commands, and what a report says. One instance per driver load.

local persist = require("lib.persist")
local ColorMode = require("esphome.proto_schema").Enum.ColorMode

---------------------------------------------------------------------------
-- ESPHome color modes that include brightness control
---------------------------------------------------------------------------

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_BRIGHTNESS = {
  [ColorMode.COLOR_MODE_UNKNOWN] = false,
  [ColorMode.COLOR_MODE_ON_OFF] = false,
  [ColorMode.COLOR_MODE_LEGACY_BRIGHTNESS] = true,
  [ColorMode.COLOR_MODE_BRIGHTNESS] = true,
  [ColorMode.COLOR_MODE_WHITE] = true,
  [ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_RGB = {
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_CCT = {
  [ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local COLOR_MODES_SUPPORTING_WHITE = {
  [ColorMode.COLOR_MODE_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
}

-- xy of the last white sent, and the color it was picked as (or the
-- out-of-range color temperature asked for); no report carries either.
-- Kept through a reload and a disconnect, so the light's report of that white
-- still reads back as the color picked; an unbind forgets it.
local WHITE_POINT = "white_point"

local LIGHT_COLOR_MODE_FULL = 0
local LIGHT_COLOR_MODE_CCT = 1
-- Driver-only: a full color on the white locus, lit as that white and told
-- to the proxy as the color picked.
local LIGHT_COLOR_MODE_PICKED_WHITE = 2

-- D65 whitepoint, used as a sane chromaticity default before any state is known
local DEFAULT_COLOR_X = 0.3127
local DEFAULT_COLOR_Y = 0.3290

-- An RGB / HSV round trip drifts xy by 1-2e-3.
local COLOR_TOLERANCE = 5e-3

-- Max xy distance from a color to its CCT's point (C4 gives the nearest one)
-- to count as a white; holds the wheel's center and picks within 2% in range.
local WHITE_TOLERANCE = 0.012

local FADED_FIELDS =
  { "color_brightness", "red", "green", "blue", "white", "color_temperature", "cold_white", "warm_white" }

--- An ESPHome light command's fields, as ENTITY_COMMAND sends them (`point` is driver-only and never sent).
--- @alias EsphomeLightFields table<string, any>

--- @class EsphomeLightFade
--- @field from EsphomeLightFields Where each field starts.
--- @field startTime number C4:GetTime() when the command went out.
--- @field durationMs number
--- @field holds boolean A fade to off: color and white hold to its end.
--- @field dimmed boolean Begun while dimmed mid mode change, so it brings the light back up.

--- @class EsphomeLightAdapter : LightAdapter
--- @field binding integer The ESPHome connection's binding.
--- @field entity table|nil The entity listing from the latest report.
--- @field dims boolean The entity lists a mode with brightness.
--- @field color boolean It lists an RGB mode.
--- @field cct boolean It lists a color temperature mode.
--- @field modes table<ProtoColorMode, boolean> Its supported_color_modes.
--- @field minMireds number
--- @field maxMireds number
--- @field target EsphomeLightFields Color and white fields the light is heading to: last report plus sends since.
--- @field fade EsphomeLightFade|nil The transition the last command started, as ESPHome runs it.
--- @field wireLevels number[] The brightness last reported, then each sent since (oldest first). Emptied by
---   reset (a disconnect or a bind), so the first report after one is the light's own word.
--- @field wireColors EsphomeLightFields[] The color fields last reported, then each sent since (oldest first),
---   emptied with wireLevels.
---   The white point is not one of these: it is a persisted pick, kept as long as WHITE_POINT says.
local LightAdapter = {}
LightAdapter.__index = LightAdapter

LightAdapter.LIGHT_COLOR_MODE_FULL = LIGHT_COLOR_MODE_FULL
LightAdapter.LIGHT_COLOR_MODE_CCT = LIGHT_COLOR_MODE_CCT
LightAdapter.LIGHT_COLOR_MODE_PICKED_WHITE = LIGHT_COLOR_MODE_PICKED_WHITE
LightAdapter.DEFAULT_COLOR_X = DEFAULT_COLOR_X
LightAdapter.DEFAULT_COLOR_Y = DEFAULT_COLOR_Y
-- Time (ms) a stop mid color-mode change takes to ease the light back up.
LightAdapter.MODE_STOP_RATE = 500

--- @param binding integer The ESPHome connection's binding.
--- @return EsphomeLightAdapter
function LightAdapter.new(binding)
  return setmetatable({
    binding = binding,
    entity = nil,
    dims = false,
    color = false,
    cct = false,
    modes = {},
    minMireds = 153, -- ~6500K (cool)
    maxMireds = 500, -- ~2000K (warm)
    target = {},
    fade = nil,
    wireLevels = {},
    wireColors = {},
  }, LightAdapter)
end

---------------------------------------------------------------------------
-- Color conversions
---------------------------------------------------------------------------

function LightAdapter.miredsToKelvin(m)
  if not m or m <= 0 then
    return 0
  end
  return math.floor(1e6 / m + 0.5)
end

local function kelvinToMireds(k)
  if not k or k <= 0 then
    return 0
  end
  return 1e6 / k
end

-- HSV (h: 0-360, s: 0-100, v: 0-100) -> normalized RGB (each 0-1)
local function hsvToRGB(h, s, v)
  local sf, vf = (s or 0) / 100, (v or 0) / 100
  local c = vf * sf
  local hh = ((h or 0) / 60) % 6
  local x = c * (1 - math.abs((hh % 2) - 1))
  local m = vf - c
  local r, g, b = 0, 0, 0
  if hh < 1 then
    r, g, b = c, x, 0
  elseif hh < 2 then
    r, g, b = x, c, 0
  elseif hh < 3 then
    r, g, b = 0, c, x
  elseif hh < 4 then
    r, g, b = 0, x, c
  elseif hh < 5 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  return r + m, g + m, b + m
end

-- normalized RGB (0-1) -> HSV (h: 0-360, s: 0-100, v: 0-100)
local function rgbToHSV(r, g, b)
  r, g, b = r or 0, g or 0, b or 0
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then
      h = 60 * (((g - b) / d) % 6)
    elseif mx == g then
      h = 60 * ((b - r) / d + 2)
    else
      h = 60 * ((r - g) / d + 4)
    end
  end
  if h < 0 then
    h = h + 360
  end
  local s = mx > 0 and (d / mx) * 100 or 0
  return h, s, mx * 100
end

-- CIE 1931 xy chromaticity -> normalized RGB at full intensity.
-- Brightness is handled separately via the LIGHT_V2 brightness path.
local function xyToRGB(x, y)
  local h, s = C4:ColorXYtoHSV(x, y)
  local r, g, b = hsvToRGB(h or 0, s or 100, 100)
  return r, g, b
end

function LightAdapter.sameColor(x1, y1, mode1, x2, y2, mode2)
  return mode1 == mode2 and math.abs(x1 - x2) <= COLOR_TOLERANCE and math.abs(y1 - y2) <= COLOR_TOLERANCE
end

-- ESPHome's transition easing (LightTransformer::smoothed_progress).
function LightAdapter.eased(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

---------------------------------------------------------------------------
-- The entity's modes
---------------------------------------------------------------------------

local function entitySupportsAnyMode(entity, modeTable)
  local modes = Select(entity, "supported_color_modes")
  if not IsList(modes) then
    return false
  end
  for _, mode in ipairs(modes) do
    if modeTable[mode] then
      return true
    end
  end
  return false
end

--- Read what an entity listing says the light can do.
function LightAdapter:learn(entity)
  self.dims = entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_BRIGHTNESS)
  self.color = entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_RGB)
  self.cct = entitySupportsAnyMode(entity, COLOR_MODES_SUPPORTING_CCT)
  -- We pick the most specific mode per cmd intent (CCT vs RGB) and set color_mode
  -- explicitly so ESPHome doesn't have to infer from which fields we populate.
  self.modes = {}
  local modes = Select(entity, "supported_color_modes")
  if IsList(modes) then
    for _, m in ipairs(modes) do
      self.modes[m] = true
    end
  end
  -- Some ESPHome entities report 0/0 for mireds. Keep our XML defaults in that case
  -- so Composer's dialog doesn't get broken bounds.
  local entityMin = tonumber(Select(entity, "min_mireds"))
  local entityMax = tonumber(Select(entity, "max_mireds"))
  if entityMin and entityMin > 0 then
    self.minMireds = entityMin
  end
  if entityMax and entityMax > 0 then
    self.maxMireds = entityMax
  end
end

--- Forget the connection: its modes, target and fade. An unbind also forgets the white last sent; a bind also fires
--- at controller start, when the stored white is still this light's.
--- @param unbound boolean|nil
function LightAdapter:reset(unbound)
  self.entity = nil
  self.dims = false
  self.color = false
  self.cct = false
  self.modes = {}
  self.target = {}
  self.fade = nil
  self.wireLevels = {}
  self.wireColors = {}
  if unbound then
    persist:delete(WHITE_POINT)
  end
end

-- The mode ESPHome picks at a turn-on naming none, for a light with no mode
-- yet (e.g. after a restart that restored none).
local function firstColorMode(self)
  local first
  for mode in pairs(self.modes) do
    if mode >= ColorMode.COLOR_MODE_WHITE and (not first or mode < first) then
      first = mode
    end
  end
  return first
end

-- COLOR_MODE_WHITE on a color light, i.e. an RGBW light built with
-- color_interlock; nil otherwise.
local function ownWhiteMode(self)
  local white = ColorMode.COLOR_MODE_WHITE
  if self.color and self.modes[white] then
    return white
  end
end

-- Pick the most specific ESPHome color mode the bulb supports for a given
-- intent ("cct" or "rgb"). Order matters: prefer single-purpose modes (RGB,
-- COLD_WARM_WHITE) over combined modes (RGB_COLOR_TEMPERATURE,
-- RGB_COLD_WARM_WHITE) because the bulb's behavior in single-purpose modes
-- is unambiguous. Returns nil if no compatible mode is supported.
local function pickColorMode(self, intent)
  local order
  if intent == "cct" then
    order = {
      ColorMode.COLOR_MODE_COLD_WARM_WHITE,
      ColorMode.COLOR_MODE_COLOR_TEMPERATURE,
      ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE,
      ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE,
    }
  else
    order = {
      ColorMode.COLOR_MODE_RGB,
      ColorMode.COLOR_MODE_RGB_WHITE,
      ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE,
      ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE,
    }
  end
  for _, m in ipairs(order) do
    if self.modes[m] then
      return m
    end
  end
  return nil
end

-- The light's combined color and white mode (built without color_interlock),
-- or nil for a plain RGB light.
local function combinedColorMode(self)
  local mode = pickColorMode(self, "rgb")
  if mode ~= ColorMode.COLOR_MODE_RGB then
    return mode
  end
end

-- The light's current mode if it is CCT-only (e.g. an RGBCT light's white
-- mode), else nil.
local function whiteOnlyMode(self)
  local mode = self.target.color_mode
  if self.modes[mode] and COLOR_MODES_SUPPORTING_CCT[mode] and not COLOR_MODES_SUPPORTING_RGB[mode] then
    return mode
  end
end

local function givesMiredsRange(self)
  return (tonumber(Select(self.entity, "min_mireds")) or 0) > 0
    and (tonumber(Select(self.entity, "max_mireds")) or 0) > 0
end

-- Map a target Kelvin to a (cold_white, warm_white) channel split based on
-- the bulb's reported mireds range. Pure cold = (1, 0) at min_mireds; pure
-- warm = (0, 1) at max_mireds; linear blend between. Returned values are 0-1
-- floats matching ESPHome's per-channel scale.
local function kelvinToCoolWarmSplit(self, kelvin)
  local mireds = kelvinToMireds(kelvin)
  local span = self.maxMireds - self.minMireds
  if span <= 0 then
    return 0.5, 0.5
  end
  local ratio = math.max(0, math.min(1, (mireds - self.minMireds) / span))
  return 1 - ratio, ratio
end

---------------------------------------------------------------------------
-- White points
---------------------------------------------------------------------------

-- Clamp to the light's range (the default one for an RGBW white): C4 gives
-- even the color wheel's rim a color temperature.
local function takenKelvin(self, k)
  local miredsToKelvin = LightAdapter.miredsToKelvin
  return math.max(miredsToKelvin(self.maxMireds), math.min(miredsToKelvin(self.minMireds), k))
end

--- Whether the light has a white channel: CCT, or a plain white (RGBW).
function LightAdapter:hasWhite()
  return self.cct or combinedColorMode(self) ~= nil or ownWhiteMode(self) ~= nil
end

--- Whether a full color sits on the white locus inside the light's range, so
--- the light shows it with its white.
function LightAdapter:isWhitePoint(x, y)
  local k = self:hasWhite() and tonumber(C4:ColorXYtoCCT(x, y))
  if not k or k <= 0 or k ~= takenKelvin(self, k) then
    return false
  end
  local whiteX, whiteY = C4:ColorCCTtoXY(k)
  return math.sqrt((x - whiteX) ^ 2 + (y - whiteY) ^ 2) <= WHITE_TOLERANCE
end

--- Normalize a color to what the light shows and reports back. A color on the
--- white locus is told as picked: the proxy matches scenes by the told color.
function LightAdapter:takenColor(x, y, mode)
  if mode == LIGHT_COLOR_MODE_PICKED_WHITE then
    mode = LIGHT_COLOR_MODE_FULL
  end
  if mode ~= LIGHT_COLOR_MODE_CCT then
    if not self:isWhitePoint(x, y) then
      return x, y, mode
    end
    if self.color then
      return x, y, LIGHT_COLOR_MODE_PICKED_WHITE
    end
  end
  if not self:hasWhite() then
    return x, y, self.color and LIGHT_COLOR_MODE_FULL or mode
  end
  -- A CCT light clamps out-of-range values itself (heldColor): keep as asked.
  local k = tonumber(C4:ColorXYtoCCT(x, y))
  if k and k > 0 then
    x, y = C4:ColorCCTtoXY(self.cct and k or takenKelvin(self, k))
  end
  return x, y, LIGHT_COLOR_MODE_CCT
end

--- Where the light actually ends up: an out-of-range CCT at the range's end.
function LightAdapter:heldColor(x, y, mode)
  local k = mode == LIGHT_COLOR_MODE_CCT and self.cct and tonumber(C4:ColorXYtoCCT(x, y))
  if k and k > 0 and k ~= takenKelvin(self, k) then
    return C4:ColorCCTtoXY(takenKelvin(self, k))
  end
  return x, y
end

-- The color to report for a white at xy: the pick stored with the last
-- white sent, if this is that white, else the white itself.
local function shownWhite(x, y)
  local point = persist:get(WHITE_POINT)
  local picked = point and point.picked
  if
    picked
    and picked.x
    and picked.y
    and point.x
    and point.y
    and LightAdapter.sameColor(x, y, LIGHT_COLOR_MODE_CCT, point.x, point.y, LIGHT_COLOR_MODE_CCT)
  then
    return picked.x, picked.y, picked.mode or LIGHT_COLOR_MODE_PICKED_WHITE
  end
  return x, y, LIGHT_COLOR_MODE_CCT
end

--- xy and mode a light's fields show, or nil. A combined mode shows the
--- color while color_brightness >= white, else the white (shownWhite).
function LightAdapter:shownColor(fields)
  local mode = fields.color_mode
  local hasColor = mode and COLOR_MODES_SUPPORTING_RGB[mode]
  local white = fields.white
  if mode == ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE then
    white = math.max(fields.cold_white, fields.warm_white)
  end
  local inWhite = not (hasColor and fields.color_brightness > 0 and fields.color_brightness >= white)
  if inWhite and mode and COLOR_MODES_SUPPORTING_CCT[mode] and fields.color_temperature > 0 then
    return shownWhite(C4:ColorCCTtoXY(LightAdapter.miredsToKelvin(fields.color_temperature)))
  end
  if hasColor and math.max(fields.red, fields.green, fields.blue) > 0 then
    local h, s = rgbToHSV(fields.red, fields.green, fields.blue)
    local x, y = C4:ColorHSVtoXY(h, s, 100)
    if inWhite and mode == ColorMode.COLOR_MODE_RGB_WHITE then
      x, y = self:takenColor(x, y, LIGHT_COLOR_MODE_CCT)
      return shownWhite(x, y)
    end
    return x, y, LIGHT_COLOR_MODE_FULL
  end
  if mode and mode == ownWhiteMode(self) then
    local point = persist:get(WHITE_POINT)
    if point and point.x and point.y then
      return shownWhite(point.x, point.y)
    end
    local x, y = self:takenColor(DEFAULT_COLOR_X, DEFAULT_COLOR_Y, LIGHT_COLOR_MODE_CCT)
    return x, y, LIGHT_COLOR_MODE_CCT
  end
end

--- Another client's color: a report of the white last sent no longer reads back as the color picked.
function LightAdapter:dropPick()
  local point = persist:get(WHITE_POINT)
  if point and point.picked then
    point.picked = nil
    persist:set(WHITE_POINT, point)
  end
end

---------------------------------------------------------------------------
-- Command fields
---------------------------------------------------------------------------

-- Light one side of the combined mode with the other off; staying in one mode
-- avoids ESPHome fading a mode change through off.
--- @param white number|boolean|nil Kelvin; true: plain white; nil: color.
local function combinedFields(self, fields, mode, white)
  fields.has_color_mode = true
  fields.color_mode = mode
  fields.has_color_brightness = true
  fields.color_brightness = white and 0 or 1
  if mode ~= ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE then
    fields.has_white = true
    fields.white = white and 1 or 0
    return fields
  end
  -- ESPHome derives cold/warm white from a color temperature, with gamma,
  -- only for a light that reports a mireds range; others get them sent.
  local cw, ww = 0, 0
  if white then
    if givesMiredsRange(self) then
      return fields
    end
    cw, ww = kelvinToCoolWarmSplit(self, white)
  end
  fields.has_cold_white = true
  fields.cold_white = cw
  fields.has_warm_white = true
  fields.warm_white = ww
  return fields
end

--- Convert an XY/mode color into the right ESPHome cmd fields. Returns the
--- partial cmd table or nil if the bulb doesn't support color/CCT or the
--- provided values can't be mapped.
--- @param merged boolean|nil Part of a level command: a CCT names its mode too.
--- @param on boolean The light is on or heading on.
--- @return EsphomeLightFields|nil
function LightAdapter:colorFields(x, y, mode, merged, on)
  if not (self.color or self.cct) or x == nil or y == nil then
    return nil
  end
  -- A picked white goes out as its color temperature and an out-of-range one
  -- is clamped; either way the original is kept as the pick.
  local pick = nil
  if mode == LIGHT_COLOR_MODE_PICKED_WHITE then
    pick = { x = x, y = y }
    x, y, mode = self:takenColor(x, y, LIGHT_COLOR_MODE_CCT)
  elseif mode == LIGHT_COLOR_MODE_CCT then
    local heldX, heldY = self:heldColor(x, y, mode)
    if heldX ~= x or heldY ~= y then
      pick = { x = x, y = y, mode = mode }
      x, y = heldX, heldY
    end
  end
  -- Remember the white's xy and pick so reports of it read back as picked.
  local point = mode == LIGHT_COLOR_MODE_CCT and { x = x, y = y, picked = pick } or nil
  if mode == LIGHT_COLOR_MODE_CCT and self.cct then
    local k = tonumber(C4:ColorXYtoCCT(x, y))
    if not k or k <= 0 then
      return nil
    end
    local fields = {
      has_color_temperature = true,
      color_temperature = kelvinToMireds(k),
      point = point,
    }
    local combined = combinedColorMode(self)
    local pickedMode = pickColorMode(self, "cct")
    if combined and COLOR_MODES_SUPPORTING_CCT[combined] then
      -- Stay in the white-only mode if already there: ESPHome fades a change
      -- of mode through off.
      pickedMode = whiteOnlyMode(self)
      if not pickedMode then
        return combinedFields(self, fields, combined, k)
      end
    end
    -- Leave an on light in its mode (a change fades through off). An off color
    -- light needs the mode named, or it keeps one that drops the CCT.
    if not merged and (on or not self.color) then
      return fields
    end
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    -- As in combinedFields: send cold/warm white only without a mireds range.
    if
      not givesMiredsRange(self)
      and (self.modes[ColorMode.COLOR_MODE_COLD_WARM_WHITE] or self.modes[ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE])
    then
      local cw, ww = kelvinToCoolWarmSplit(self, k)
      fields.has_cold_white = true
      fields.cold_white = cw
      fields.has_warm_white = true
      fields.warm_white = ww
    end
    return fields
  end
  if self.color then
    local r, g, b = xyToRGB(x, y)
    local fields = { has_rgb = true, red = r, green = g, blue = b }
    local combined = combinedColorMode(self)
    if combined then
      -- A plain white is sent with its point's RGB for the report to read back.
      fields.point = point
      return combinedFields(self, fields, combined, mode == LIGHT_COLOR_MODE_CCT or nil)
    end
    -- A separate white mode reports no point, so keep the one sent.
    local white = mode == LIGHT_COLOR_MODE_CCT and ownWhiteMode(self)
    if white then
      return { has_color_mode = true, color_mode = white, has_white = true, white = 1, point = point }
    end
    -- Name the mode: an off light in a mode without color would drop it.
    local pickedMode = pickColorMode(self, "rgb")
    if pickedMode then
      fields.has_color_mode = true
      fields.color_mode = pickedMode
    end
    return fields
  end
  return nil
end

--- Two-phase fade-up workaround. ESPHome's light_call short-circuits on
--- state=false: brightness=0 in the same command is dropped, so the bulb's
--- stored brightness stays at whatever it was last set to (often 1.0).
--- When we then send state=true brightness=target with transition_length,
--- ESPHome sees no brightness diff and the LED snaps on instead of fading.
--- Pre-pushing a state=true brightness=ε with transition=0 sets the stored
--- brightness to ~0 so the real ramp has a real diff to interpolate across.
--- 0.0039 = 1/256, the smallest 8-bit PWM step, visually indistinguishable
--- from off. Using literal 0 risks ESPHome converting state=true brightness=0
--- back into state=false. It carries the ramp's color so a mode change happens
--- here rather than fading through off during the ramp.
--- @param fields EsphomeLightFields|nil Color fields of the ramp that follows.
--- @return EsphomeLightFields
function LightAdapter.preOn(fields)
  local cmd = {
    has_state = true,
    state = true,
    has_brightness = true,
    brightness = 0.0039,
    has_transition_length = true,
    transition_length = 0,
  }
  for k, v in pairs(fields or {}) do
    cmd[k] = v
  end
  return cmd
end

--- A command holding the light at `fields` in its mode. It sets every field of
--- the mode: one left out keeps fading to where it was last sent.
--- @return EsphomeLightFields
function LightAdapter:holdFields(fields)
  local mode = fields.color_mode
  local cmd = { has_color_mode = true, color_mode = mode }
  if COLOR_MODES_SUPPORTING_RGB[mode] then
    cmd.has_color_brightness = true
    cmd.color_brightness = fields.color_brightness
    -- ESPHome normalizes RGB to a full channel, so move the scale into
    -- color_brightness.
    local full = math.max(fields.red, fields.green, fields.blue)
    if full > 0 then
      cmd.has_rgb = true
      cmd.red, cmd.green, cmd.blue = fields.red / full, fields.green / full, fields.blue / full
      cmd.color_brightness = fields.color_brightness * full
    end
  end
  if COLOR_MODES_SUPPORTING_CCT[mode] and fields.color_temperature > 0 then
    cmd.has_color_temperature = true
    cmd.color_temperature = fields.color_temperature
  end
  -- Cold/warm white follow the CCT where the light reports a mireds range.
  if
    mode == ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE
    or (mode == ColorMode.COLOR_MODE_COLD_WARM_WHITE and not (givesMiredsRange(self) and cmd.has_color_temperature))
  then
    cmd.has_cold_white = true
    cmd.cold_white = fields.cold_white
    cmd.has_warm_white = true
    cmd.warm_white = fields.warm_white
  elseif COLOR_MODES_SUPPORTING_WHITE[mode] then
    cmd.has_white = true
    cmd.white = fields.white
  end
  return cmd
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

--- Take the driver-only `point` off a command and keep it, so a restart reads
--- the light's white back as the color picked.
function LightAdapter:keepPoint(opts)
  local point = opts.point
  if not point then
    return
  end
  opts.point = nil
  local stored = persist:get(WHITE_POINT, {})
  local picked, was = point.picked or {}, stored.picked or {}
  -- Skip a plain white unless it clears an old pick or the light's reports
  -- carry no point (ownWhiteMode).
  if
    (point.picked or stored.picked or ownWhiteMode(self))
    and not (point.x == stored.x and point.y == stored.y and picked.x == was.x and picked.y == was.y)
  then
    persist:set(WHITE_POINT, point)
  end
end

--- Merge a report's (or a `sent` command's) fields into the target.
local function aimFields(self, fields, sent)
  local target = {}
  for field, value in pairs(self.target) do
    target[field] = value
  end
  -- A color temperature sent with no mode, while the mode has none, moves
  -- ESPHome to its lowest CCT-capable mode (compute_color_mode_).
  if
    sent
    and fields.color_temperature
    and not fields.color_mode
    and not COLOR_MODES_SUPPORTING_CCT[target.color_mode]
  then
    target.color_mode = false
    for mode in pairs(self.modes) do
      if COLOR_MODES_SUPPORTING_CCT[mode] and (not target.color_mode or mode < target.color_mode) then
        target.color_mode = mode
      end
    end
  end
  for field, value in pairs(fields) do
    target[field] = value
  end
  self.target = target
end

--- Aim the light at what a command sends and start the fade it runs. Returns
--- the color fields it sends, if any, and whether the command named them.
--- @param dark boolean The light is at level 0.
--- @return EsphomeLightFields|nil
--- @return boolean
function LightAdapter:aim(opts, dark)
  -- ESPHome restarts every channel from where it is over the new transition,
  -- and holds color and white through a fade to off.
  local now = C4:GetTime()
  local from = self:colorAt(now)
  -- A fade begun while dimmed (mid mode change) brings the light back up.
  local dimmed = self:dimmedAt(now)
  local color, named = nil, false
  if opts.has_rgb or opts.has_color_temperature or opts.has_color_mode then
    color = {
      color_mode = opts.color_mode,
      color_brightness = opts.color_brightness,
      red = opts.red,
      green = opts.green,
      blue = opts.blue,
      white = opts.white,
      color_temperature = opts.color_temperature,
      cold_white = opts.cold_white,
      warm_white = opts.warm_white,
    }
    aimFields(self, color, true)
    named = true
  elseif opts.state and dark and self.target.color_mode == ColorMode.COLOR_MODE_UNKNOWN then
    -- A turn-on naming no mode gives a mode-less light its first mode.
    local first = firstColorMode(self)
    if first then
      color = { color_mode = first }
      aimFields(self, color)
    end
  end
  local ms = opts.transition_length or 0
  self.fade = ms > 0 and { from = from, startTime = now, durationMs = ms, holds = opts.state == false, dimmed = dimmed }
    or nil
  return color, named
end

function LightAdapter:put(opts)
  SendToProxy(self.binding, "ENTITY_COMMAND", {
    body = SerializeSafe(opts),
  })
end

---------------------------------------------------------------------------
-- The fade ESPHome runs
---------------------------------------------------------------------------

--- Whether a fade changes color mode at `now`, and whether it is past half
--- way: ESPHome fades a mode change through off, switching at the midpoint.
function LightAdapter:changingMode(fade, now)
  if
    not fade
    or fade.holds
    or now - fade.startTime >= fade.durationMs
    or fade.from.color_mode == self.target.color_mode
  then
    return false, false
  end
  return true, (now - fade.startTime) * 2 >= fade.durationMs
end

--- Whether the light is dimmed at `now`: mid mode change, or easing back up
--- from one that had it dimmed when this fade began.
function LightAdapter:dimmedAt(now)
  local fade = self.fade
  return self:changingMode(fade, now) or (fade and fade.dimmed and now - fade.startTime < fade.durationMs) or false
end

--- The light's color/white fields at `now`, eased per field as ESPHome does;
--- a mode change shows one end or the other.
function LightAdapter:colorAt(now)
  local to, fade = self.target, self.fade
  if not fade or now - fade.startTime >= fade.durationMs then
    return to
  end
  local from = fade.from
  if fade.holds then
    return from
  end
  local changing, past = self:changingMode(fade, now)
  if changing then
    return past and to or from
  end
  local progress = LightAdapter.eased((now - fade.startTime) / fade.durationMs)
  local at = { color_mode = to.color_mode }
  for _, field in ipairs(FADED_FIELDS) do
    at[field] = from[field] + (to[field] - from[field]) * progress
  end
  -- A light that reported no CCT or no color has nothing to fade those from.
  if from.color_temperature == 0 then
    at.color_temperature = to.color_temperature
  end
  if math.max(from.red, from.green, from.blue) == 0 then
    at.red, at.green, at.blue = to.red, to.green, to.blue
  end
  return at
end

--- The light's own fields where its ramp's xy would mislead: in a combined
--- mode, before the midpoint of a mode change, or in a fade begun dimmed.
function LightAdapter:fadedFields(now)
  local _, past = self:changingMode(self.fade, now)
  local fields = not past and self:colorAt(now)
  local mode = fields and fields.color_mode
  if self.modes[mode] and (self:dimmedAt(now) or mode == combinedColorMode(self)) then
    return fields
  end
end

function LightAdapter:fadedColor(now)
  local fields = self:fadedFields(now)
  if fields then
    return self:shownColor(fields)
  end
end

--- Another client moved the light: its transition time is unknown, so stop modeling the fade.
function LightAdapter:dropFade()
  self.fade = nil
end

---------------------------------------------------------------------------
-- Reports
---------------------------------------------------------------------------

--- What a report says: whether the light is on, its brightness (0-1, 0 while
--- off), and its color and white fields.
--- @return boolean on
--- @return number brightness
--- @return EsphomeLightFields reported
function LightAdapter:read(entity, state)
  self.entity = entity
  local on = Select(state, "state") or false
  local brightness = 0
  if on then
    -- ESPHome sends NaN for the brightness of a light that has not reported one.
    brightness = self.dims and tofinite(Select(state, "brightness")) or 1.0
  end
  local reported = {
    -- ESPHome omits a zero color_mode (UNKNOWN) like any zero field.
    color_mode = tointeger(Select(state, "color_mode")) or ColorMode.COLOR_MODE_UNKNOWN,
    color_brightness = tofinite(Select(state, "color_brightness")) or 0,
    red = tofinite(Select(state, "red")) or 0,
    green = tofinite(Select(state, "green")) or 0,
    blue = tofinite(Select(state, "blue")) or 0,
    white = tofinite(Select(state, "white")) or 0,
    color_temperature = tofinite(Select(state, "color_temperature")) or 0,
    cold_white = tofinite(Select(state, "cold_white")) or 0,
    warm_white = tofinite(Select(state, "warm_white")) or 0,
  }
  return on, brightness, reported
end

--- Whether a state matches a sent color's fields; the tolerance is relative
--- for fields above 1 (mireds). The light keeps its color temperature in a
--- color's state, so one sent with no mode needs a state in a mode that shows it.
function LightAdapter.holds(state, color)
  if color.color_mode == nil and color.color_temperature and not COLOR_MODES_SUPPORTING_CCT[state.color_mode] then
    return false
  end
  for field, value in pairs(color) do
    local tolerance = COLOR_TOLERANCE * math.max(1, math.abs(value))
    if not (math.abs((tofinite(state[field]) or 0) - value) <= tolerance) then
      return false
    end
  end
  return true
end

--- Rebuild the target from a report's fields and each command sent after it, in order.
function LightAdapter:retarget(colors)
  self.target = {}
  for i, color in ipairs(colors) do
    aimFields(self, color, i > 1)
  end
end

---------------------------------------------------------------------------
-- The light library's adapter
---------------------------------------------------------------------------

--- The facts of the connected entity.
--- @return LightDevice
function LightAdapter:device()
  local miredsToKelvin = LightAdapter.miredsToKelvin
  return {
    dims = self.dims,
    color = self.color,
    cct = self.cct and { minK = miredsToKelvin(self.maxMireds), maxK = miredsToKelvin(self.minMireds) } or nil,
    colorWhileOff = "send",
    levelSteps = 255,
    -- ESPHome fades each command over its transition_length, eased, restarting every channel; a fade up from off
    -- starts from the level it kept, so a rated on opens with a pre-on.
    fade = { kind = "device", curve = "smootherstep", preOn = true, retimes = true },
    -- It answers each command with a report of its own, seen within 250 ms, and a refresh re-enumerates it.
    feedback = { shows = "target", waitMs = 1000, refresh = false },
  }
end

-- A command's color as the light's fields take it: a white on the locus inside the range is lit as that white.
local function wireColor(self, color)
  if color.mode == "cct" then
    return color.x, color.y, LIGHT_COLOR_MODE_CCT
  end
  return self:takenColor(color.x, color.y, LIGHT_COLOR_MODE_FULL)
end

--- @return LightColor|nil
local function lightColor(x, y, mode)
  if not (x and y) then
    return nil
  end
  if mode == LIGHT_COLOR_MODE_CCT then
    return { x = x, y = y, mode = "cct", kelvin = math.floor((tonumber(C4:ColorXYtoCCT(x, y)) or 0) + 0.5) }
  end
  return { x = x, y = y, mode = "xy" }
end

-- Keep a command's white point and aim, track the color it sends, and put it on the wire.
local function deliver(self, opts, dark)
  self:keepPoint(opts)
  if opts.has_state and (opts.has_brightness or opts.state == false or not self.dims) then
    self.wireLevels[#self.wireLevels + 1] = opts.state and (opts.brightness or 1.0) or 0
  end
  local color = self:aim(opts, dark)
  if color then
    self.wireColors[#self.wireColors + 1] = color
  end
  self:put(opts)
end

--- Put one command on the wire. A stop the light's own fade has dimmed (mid mode change) or holds in a combined mode
--- is held where that fade has got to, and the color it rests at is returned.
--- @param cmd LightCommand
--- @return LightRest|nil
function LightAdapter:send(cmd)
  local now = C4:GetTime()
  local dark = cmd.from.level == 0
  local x, y, mode
  if cmd.color and cmd.setsColor then
    x, y, mode = wireColor(self, cmd.color)
  end
  if cmd.kind == "preOn" then
    deliver(self, LightAdapter.preOn(x and self:colorFields(x, y, mode, true, true)), dark)
    return nil
  end
  if not self.dims then
    -- An On/Off-only light switches at once.
    deliver(self, { has_state = true, state = cmd.on }, dark)
    return nil
  end
  local opts = { has_state = true, state = cmd.on, has_transition_length = true, transition_length = cmd.transitionMs }
  local colorOpts = x and self:colorFields(x, y, mode, cmd.setsLevel, cmd.on)
  local rest = nil
  if cmd.kind == "stop" then
    -- Dimmed mid mode change: ease back up rather than jump.
    if self:dimmedAt(now) then
      opts.transition_length = math.max(opts.transition_length, LightAdapter.MODE_STOP_RATE)
    end
    -- In a combined mode or mid mode change, hold the light's own fields.
    local faded = cmd.setsColor and self:fadedFields(now)
    if faded then
      colorOpts = self:holdFields(faded)
      rest = { color = lightColor(self:shownColor(faded)) }
    end
  end
  if cmd.setsLevel then
    opts.has_brightness = true
    opts.brightness = cmd.on and cmd.level or 0
  end
  for k, v in pairs(colorOpts or {}) do
    opts[k] = v
  end
  deliver(self, opts, dark)
  return rest
end

--- Ask for the whole state, which comes back as a report.
function LightAdapter:refresh()
  SendToProxy(self.binding, "REFRESH_STATE", {}, "NOTIFY")
end

--- The light has no device page.
--- @param _shown LightShown
function LightAdapter:show(_shown) end

-- Whether a report matches a value on the wire: the last report's, or one sent since. Drops the entries before the
-- match and repeats of it right after, and keeps `reported` as the first entry.
local function onWire(sent, matches, reported)
  local own = false
  for i, value in ipairs(sent) do
    if matches(value) then
      for _ = 2, i do
        table.remove(sent, 1)
      end
      while sent[2] and matches(sent[2]) do
        table.remove(sent, 2)
      end
      own = true
      break
    end
  end
  sent[1] = reported
  return own
end

--- The light's state from an UPDATE_STATE. A report of the white last sent reads back as the color it was picked as.
--- @return LightReport
function LightAdapter:report(entity, state)
  local on, brightness, fields = self:read(entity, state)
  local levelOnWire = onWire(self.wireLevels, function(sent)
    return math.abs(sent - brightness) < 0.5 / 255
  end, brightness)
  local colorOnWire = onWire(self.wireColors, function(color)
    return LightAdapter.holds(state, color)
  end, fields)
  -- A report of a value sent: the light is still heading to what was sent after it. Another value: it is the
  -- light's new target, and its fade is unknown.
  self:retarget(colorOnWire and self.wireColors or { fields })
  if not (levelOnWire and colorOnWire) then
    self:dropFade()
  end
  return {
    kind = "push",
    on = on,
    level = on and brightness or nil,
    color = (self.color or self.cct) and lightColor(self:shownColor(fields)) or nil,
  }
end

return LightAdapter
