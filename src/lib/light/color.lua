--- Color helpers for the light library and its adapters: CIE xy, Kelvin, mireds, RGB and HSV, the
--- white-locus test and the Dim-To-Warm formula. Pure: the controller's own C4:Color* conversions do the
--- color science, looked up when called, since a test may stub them at any time.

local Color = {}

--- Full color, a LightColorMode.
--- @type LightColorMode
Color.FULL = "xy"

--- A white on the black-body locus, a LightColorMode.
--- @type LightColorMode
Color.CCT = "cct"

--- D65, the color a light is taken to be in before anything is known.
--- @type LightColor
Color.D65 = { x = 0.3127, y = 0.3290, mode = "cct" }

--- How far apart two xy colors still read as one: a round trip through RGB or HSV drifts 1 to 2e-3.
--- @type number
Color.TOLERANCE = 5e-3

--- The proxy's LIGHT_COLOR_*_MODE as a LightColorMode: 1 is a color temperature, anything else full color.
--- @param mode integer|string|nil
--- @return LightColorMode
function Color.fromProxyMode(mode)
  return tonumber(mode) == 1 and Color.CCT or Color.FULL
end

--- A LightColorMode as the proxy's LIGHT_COLOR_*_MODE: 1 for a color temperature, 0 for full color.
--- @param mode LightColorMode|nil
--- @return integer
function Color.toProxyMode(mode)
  return mode == Color.CCT and 1 or 0
end

--- HSV (h 0 to 360, s and v 0 to 100) to RGB, each 0 to 1.
--- @param h number|nil
--- @param s number|nil
--- @param v number|nil
--- @return number r, number g, number b
function Color.hsvToRGB(h, s, v)
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

--- RGB, each 0 to 1, to HSV (h 0 to 360, s and v 0 to 100).
--- @param r number|nil
--- @param g number|nil
--- @param b number|nil
--- @return number h, number s, number v
function Color.rgbToHSV(r, g, b)
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

--- A CIE xy chromaticity as the brightest RGB that shows it: each channel 0 to 1, the largest 1.
--- Brightness rides the level.
--- @param x number CIE 1931 x.
--- @param y number CIE 1931 y.
--- @return number r, number g, number b
function Color.xyToRGB(x, y)
  local h, s = C4:ColorXYtoHSV(x, y)
  return Color.hsvToRGB(h or 0, s or 100, 100)
end

--- An RGB color as its CIE xy chromaticity. Only the channels' ratio counts, not their brightness.
--- @param r number 0 to 1.
--- @param g number 0 to 1.
--- @param b number 0 to 1.
--- @return number|nil x, number|nil y CIE 1931 xy; nil for black.
function Color.rgbToXY(r, g, b)
  if (r or 0) <= 0 and (g or 0) <= 0 and (b or 0) <= 0 then
    return nil, nil
  end
  local h, s = Color.rgbToHSV(r, g, b)
  return C4:ColorHSVtoXY(h, s, 100)
end

--- Mireds as Kelvin, to the nearest whole Kelvin.
--- @param mireds number|nil
--- @return integer kelvin 0 for none.
function Color.miredsToKelvin(mireds)
  if not mireds or mireds <= 0 then
    return 0
  end
  return math.floor(1e6 / mireds + 0.5)
end

--- Kelvin as mireds, unrounded.
--- @param kelvin number|nil
--- @return number mireds 0 for none.
function Color.kelvinToMireds(kelvin)
  if not kelvin or kelvin <= 0 then
    return 0
  end
  return 1e6 / kelvin
end

--- The nearest color temperature to a CIE xy point, or nil where the controller gives none.
--- @param x number CIE 1931 x.
--- @param y number CIE 1931 y.
--- @return number|nil kelvin In Kelvin.
function Color.kelvin(x, y)
  local k = tonumber(C4:ColorXYtoCCT(x, y))
  return k and k > 0 and k or nil
end

--- The CIE xy point on the black-body locus at a color temperature.
--- @param kelvin number In Kelvin.
--- @return number x, number y CIE 1931 xy.
function Color.kelvinToXY(kelvin)
  return C4:ColorCCTtoXY(kelvin)
end

--- A light's parts added together: a strip that mixes its RGB channels with white LEDs shows their sum. Each part
--- is its own CIE xy and its luminance Y, every Y on one scale the caller picks.
--- @param parts {x: number, y: number, Y: number}[]
--- @return number|nil x, number|nil y CIE 1931 xy; nil when no part gives light.
function Color.mixXY(parts)
  local X, Y, Z = 0, 0, 0
  for _, part in ipairs(parts) do
    if part.Y > 0 and part.y > 0 then
      local scale = part.Y / part.y
      X, Y, Z = X + part.x * scale, Y + part.Y, Z + (1 - part.x - part.y) * scale
    end
  end
  local sum = X + Y + Z
  if sum <= 0 then
    return nil, nil
  end
  return X / sum, Y / sum
end

--- How far from the black-body locus a color still goes to a light's white channels, Euclidean in xy.
--- @type number
Color.WHITE_BAND = 0.012

--- The white range a light with color and no CCT range shows its whites in, in Kelvin.
--- @type integer
Color.WHITE_MIN_K, Color.WHITE_MAX_K = 2000, 6500

--- The white-locus test: whether a CIE xy point lies within Color.WHITE_BAND of the black-body locus
--- between two color temperatures.
--- @param x number CIE 1931 x.
--- @param y number CIE 1931 y.
--- @param minK number The warmest end, in Kelvin.
--- @param maxK number The coolest end, in Kelvin.
--- @return boolean
function Color.onLocus(x, y, minK, maxK)
  local k = Color.kelvin(x, y)
  if not k then
    return false
  end
  local lx, ly = Color.kelvinToXY(math.max(minK, math.min(maxK, k)))
  return math.sqrt((lx - x) ^ 2 + (ly - y) ^ 2) <= Color.WHITE_BAND
end

--- Whether two colors read as one: the same mode, and each coordinate within the tolerance.
--- @param x1 number
--- @param y1 number
--- @param mode1 LightColorMode|nil
--- @param x2 number
--- @param y2 number
--- @param mode2 LightColorMode|nil
--- @param tolerance number|nil Defaults to Color.TOLERANCE.
--- @return boolean
function Color.same(x1, y1, mode1, x2, y2, mode2, tolerance)
  tolerance = tolerance or Color.TOLERANCE
  return mode1 == mode2 and math.abs(x1 - x2) <= tolerance and math.abs(y1 - y2) <= tolerance
end

--- Color.same for two LightColors, either of which may be nil: two nils are alike, one is not.
--- @param a LightColor|nil
--- @param b LightColor|nil
--- @param tolerance number|nil Defaults to Color.TOLERANCE.
--- @return boolean
function Color.alike(a, b, tolerance)
  if a == nil or b == nil then
    return a == b
  end
  return Color.same(a.x, a.y, a.mode, b.x, b.y, b.mode, tolerance)
end

--- A color as a light takes it, by whether it has color and CCT, and so as its reports read. A white goes
--- out at its color temperature's own point on a light with CCT, and on one with color and no CCT as a full
--- color on the locus, its Kelvin held to Color.WHITE_MIN_K and WHITE_MAX_K.
--- @param x number
--- @param y number
--- @param mode LightColorMode
--- @param hasColor boolean
--- @param hasCct boolean
--- @return number x, number y, LightColorMode mode
function Color.taken(x, y, mode, hasColor, hasCct)
  if mode ~= Color.CCT then
    return x, y, mode
  end
  if not hasCct then
    if not hasColor then
      return x, y, mode
    end
    local k = Color.kelvin(x, y)
    if k then
      x, y = Color.kelvinToXY(math.max(Color.WHITE_MIN_K, math.min(Color.WHITE_MAX_K, k)))
    end
    return x, y, Color.FULL
  end
  local k = Color.kelvin(x, y)
  if k then
    x, y = Color.kelvinToXY(k)
  end
  return x, y, mode
end

--- A color in the form a device takes it: Color.taken by its capabilities, and a white given its Kelvin,
--- clamped to the device's range, with x and y on the locus at that Kelvin. A full color on a device with CCT
--- alone is its nearest white. Nil for any color on a device with neither color nor CCT.
--- @param color LightColor
--- @param device LightDevice
--- @param unclamped boolean|nil Keep a Kelvin past the range as given: a color told for the next on, not shown yet.
--- @return LightColor|nil
function Color.forDevice(color, device, unclamped)
  local hasCct = device.cct ~= nil
  local asked = color.mode
  if not device.color and hasCct then
    asked = Color.CCT
  end
  local x, y, mode = Color.taken(color.x, color.y, asked, device.color, hasCct)
  if mode ~= Color.CCT then
    if not device.color then
      return nil
    end
    return { x = x, y = y, mode = mode }
  end
  if not hasCct then
    return nil
  end
  local kelvin = (asked == color.mode and color.kelvin) or Color.kelvin(x, y)
  if not kelvin then
    return nil
  end
  local clamped =
    math.floor((unclamped and kelvin or math.max(device.cct.minK, math.min(device.cct.maxK, kelvin))) + 0.5)
  if clamped ~= kelvin or not color.kelvin then
    x, y = Color.kelvinToXY(clamped)
  end
  return { x = x, y = y, mode = Color.CCT, kelvin = clamped }
end

--- The Dim-To-Warm color at a level (Light V2 _7.2): the Dim color at 0 to the On color at 100, straight
--- across xy for any pair, whites too, in the On color's mode. Color.forDevice gives the form a device takes.
--- @param dim LightColor
--- @param on LightColor
--- @param level number A C4 level.
--- @return LightColor
function Color.dimToWarm(dim, on, level)
  local b = math.max(0, math.min(100, level)) * 0.01
  return { x = dim.x + (on.x - dim.x) * b, y = dim.y + (on.y - dim.y) * b, mode = on.mode or Color.FULL }
end

return Color
