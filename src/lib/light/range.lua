--- The Min and Max On Level line of a Light V2 light. The Control4 levels 1 to 100 run between
--- the Min and Max On Level (`lo`, `hi`, percent of the device's brightness), as on a Control4
--- dimmer, and past them for a light outside the range. Pure functions, so a device driver can
--- bundle this module alone to show a level as the proxy does.

local Range = {}

--- The device brightness (0 to 1) at a place on the line the range draws through the levels.
--- @param at number A place on the line: 1 to 100 inside the range, past them outside it.
--- @param lo number The Min On Level.
--- @param hi number The Max On Level.
--- @return number brightness
function Range.lineBrightness(at, lo, hi)
  return (lo + (at - 1) * (hi - lo) / 99) / 100
end

--- Where a device brightness (0 to 1) sits on the same line.
--- @param brightness number
--- @param lo number
--- @param hi number
--- @return number|nil at nil for a range with no width.
function Range.linePlace(brightness, lo, hi)
  return hi > lo and 1 + (brightness * 100 - lo) * 99 / (hi - lo) or nil
end

--- The device brightness (0 to 1) a Control4 level (0 to 100) is sent as.
--- @param level number
--- @param lo number
--- @param hi number
--- @return number brightness 0 for level 0.
function Range.toDevice(level, lo, hi)
  if level <= 0 then
    return 0
  end
  return Range.lineBrightness(level, lo, hi)
end

--- The Control4 level (1 to 100) a light that is on at a device brightness (0 to 1) shows: the
--- range's end past it.
--- @param brightness number|nil nil reads as full.
--- @param lo number
--- @param hi number
--- @return integer level
function Range.toLevel(brightness, lo, hi)
  local level = Range.linePlace(tonumber(brightness) or 1, lo, hi) or 100
  return math.max(1, math.min(100, math.floor(level + 0.5)))
end

--- The device step (of `steps` from off to full) a brightness goes out at.
--- @param brightness number
--- @param steps integer|nil nil is continuous: the brightness itself.
--- @return number step
function Range.step(brightness, steps)
  if not steps then
    return brightness
  end
  return math.floor(brightness * steps + 0.5)
end

--- How far the Control4 level a device reports back can sit from the one sent: half a device step,
--- which a narrow range spreads over several levels.
--- @param lo number
--- @param hi number
--- @param steps integer|nil nil is continuous: no slack inside a range with width.
--- @return integer slack In Control4 levels; 100 for a range with no width.
function Range.slack(lo, hi, steps)
  if hi <= lo then
    return 100
  end
  if not steps then
    return 0
  end
  return math.floor(0.5 + (50 / steps) * 99 / (hi - lo))
end

--- Whether a level read from the device is the level shown: within the slack, and on or off alike.
--- @param a integer
--- @param b integer
--- @param lo number
--- @param hi number
--- @param steps integer|nil
--- @return boolean
function Range.sameLevel(a, b, lo, hi, steps)
  return a == b or (a > 0 and b > 0 and math.abs(a - b) <= Range.slack(lo, hi, steps))
end

return Range
