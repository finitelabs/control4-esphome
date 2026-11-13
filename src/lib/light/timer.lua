--- The library's timers. Director refuses a delay under 1 ms, and a timer it refuses never fires, so a delay
--- already due runs on the shortest one Director takes.

require("drivers-common-public.global.timer")

local Timer = {}

--- Arm a named timer at 1 ms or more.
--- @param name string
--- @param ms number The delay; 0 or less runs at 1 ms.
--- @param fn function
--- @param repeating boolean|nil
function Timer.arm(name, ms, fn, repeating)
  SetTimer(name, math.max(1, ms), fn, repeating)
end

return Timer
