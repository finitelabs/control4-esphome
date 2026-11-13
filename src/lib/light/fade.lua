--- How a light moves between two states, by its fade kind: how long a change takes, where a change has the
--- light along its curve, and whether a command for one aspect re-times the other. Pure: no state, no timers.
---
--- "device" fades over the time each command asks; with `retimes` every channel runs over that time, so a
--- command that changes one aspect takes the other on to its target with it. "own" takes no time from a
--- command and runs its own lengths. "walk" changes at once, and the library walks the change in 0-time steps.

local Fade = {}

--- The time the library models a change as taking.
--- @param fade LightFade A checked fade: Caps.device filled its defaults.
--- @param fromOn boolean Whether the light is lit as the change starts.
--- @param toOn boolean Whether it is lit at the change's end.
--- @param ms integer The time the command asks.
--- @return integer
function Fade.length(fade, fromOn, toOn, ms)
  if not fromOn and not toOn then
    -- An off for a light already off moves nothing: a timed off lights some lights to fade them out.
    return 0
  end
  if fade.kind == "own" then
    local own = fade.own
    if not toOn then
      return own.offMs
    end
    return fromOn and own.changeMs or own.onMs
  end
  return math.max(0, math.min(math.floor(ms or 0), fade.maxMs))
end

--- The time a command asks of the device for a change of this length: none on "own" and "walk".
--- @param fade LightFade
--- @param length integer
--- @return integer
function Fade.transition(fade, length)
  if fade.kind == "device" then
    return length
  end
  return 0
end

--- Whether a command for one aspect takes the other on to its target over the command's own time: a "device"
--- fade whose wire restarts every channel over one transition.
--- @param fade LightFade
--- @return boolean
function Fade.retimes(fade)
  return fade.kind == "device" and fade.retimes == true
end

--- How far along its path a change has the light at fraction `p` of its time, by the curve.
--- @param fade LightFade
--- @param p number
--- @return number
function Fade.eased(fade, p)
  p = math.max(0, math.min(1, p))
  if fade.curve == "smootherstep" then
    return p * p * p * (p * (p * 6 - 15) + 10)
  end
  return p
end

--- How far along its path a change that started at `startMs` and takes `ms` has the light at `atMs`.
--- @param fade LightFade
--- @param startMs integer
--- @param ms integer
--- @param atMs integer
--- @return number progress 0 to 1.
function Fade.progress(fade, startMs, ms, atMs)
  if ms <= 0 then
    return 1
  end
  return Fade.eased(fade, (atMs - startMs) / ms)
end

--- The time a change has left at `atMs`.
--- @param startMs integer
--- @param ms integer
--- @param atMs integer
--- @return integer
function Fade.left(startMs, ms, atMs)
  return math.max(0, startMs + ms - atMs)
end

--- A level along a change.
--- @param from number
--- @param to number
--- @param p number Progress, 0 to 1.
--- @return number
function Fade.between(from, to, p)
  return from + (to - from) * p
end

--- A color along a change: straight across xy. Between a white and a full color the light passes through
--- colors off the line of whites, so a point short of the end between two modes is a full color.
--- @param from LightColor
--- @param to LightColor
--- @param p number Progress, 0 to 1.
--- @return LightColor
function Fade.color(from, to, p)
  if p >= 1 then
    return to
  end
  if p <= 0 then
    return from
  end
  return {
    x = from.x + (to.x - from.x) * p,
    y = from.y + (to.y - from.y) * p,
    mode = from.mode == to.mode and to.mode or "xy",
  }
end

return Fade
