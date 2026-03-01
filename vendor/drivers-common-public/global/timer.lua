-- Copyright 2026 Snap One, LLC. All rights reserved.

COMMON_TIMER_VER = 13

do --Globals
  Timer = Timer or {}
  TimerFunctions = TimerFunctions or {}

  DEBUG_TIMER = false

  --- Global error hook called when a timer pcall fails.
  --- Set this to a function(timerId, error) to capture errors externally.
  --- @type fun(timerId: string|userdata, error: string)|nil
  ON_TIMER_ERROR = ON_TIMER_ERROR
end

do -- Define intervals as ms
  ONE_SECOND = 1000
  ONE_MINUTE = 60 * ONE_SECOND
  ONE_HOUR = 60 * ONE_MINUTE
  ONE_DAY = 24 * ONE_HOUR
end

function KillAllTimers()
  for name, _ in pairs(Timer) do
    CancelTimer(name)
  end

  for _, thisQ in pairs(SongQs or {}) do
    thisQ.ProgressTimer = CancelTimer(thisQ.ProgressTimer)
  end
end

function CancelTimer(timerId)
  local timer
  if type(timerId) == "string" then
    timer = Timer[timerId]
  elseif type(timerId) == "userdata" then
    timer = timerId
  end

  if timer then
    if DEBUG_TIMER then
      print("Timer cancelled: " .. tostring(timerId))
    end

    if timer.Cancel then
      Timer[timerId] = timer:Cancel()
      for k, v in pairs(Timer) do
        if v == timer then
          Timer[k] = nil
        end
      end
    else
      Timer[timerId] = nil
    end
    TimerFunctions[timer] = nil
  end
  return nil
end

--- Creates or replaces a timer.
--- @param timerId string|C4LuaTimer The timer identifier or existing timer to replace.
--- @param delay number The delay in milliseconds.
--- @param timerFunction? function The callback function.
--- @param repeating? boolean Whether the timer repeats.
--- @return C4LuaTimer|nil timer The timer instance.
function SetTimer(timerId, delay, timerFunction, repeating)
  CancelTimer(timerId)

  if type(timerId) == "nil" then
    local output = {
      "SetTimer anonymous timerId",
      tostring(debug.getinfo(2, "n").name),
    }
    dbg(table.concat(output, " : "))
  end

  if type(timerFunction) ~= "function" then
    timerFunction = nil
  end

  if delay > ((2 ^ 31) - 1) then
    print("Timer not created: " .. tostring(timerId), "delay exceeded max value (2^31 - 1)")
    return
  end

  if timerFunction == nil then
    if type(_G[timerId]) == "function" then
      timerFunction = function(timer, skips)
        _G[timerId]()
      end
    else
      timerFunction = function(timer, skips) end
    end
  end

  local _timer = function(timer, skips)
    if TimerFunctions[timer] then
      local timerFn = TimerFunctions[timer]
      local success, ret = xpcall(function()
        return timerFn(timer, skips)
      end, debug.traceback)
      if success == true then
        if DEBUG_TIMER then
          print("Timer completed: ", timerId, ret)
        end
      elseif success == false then
        if DEBUG_TIMER then
          print("Timer Regular Expire Lua error: ", timerId, ret)
        end
        if ON_TIMER_ERROR then
          ON_TIMER_ERROR(timerId, ret)
        end
      end
    end
    if repeating ~= true then
      CancelTimer(timer)
      if Timer[timerId] == timer then
        CancelTimer(timerId)
      end
    end
  end

  if DEBUG_TIMER then
    print("Timer created: " .. tostring(timerId))
  end

  local timer

  local success, ret = pcall(C4.SetTimer, C4, delay, _timer, (repeating == true))
  if success then
    timer = ret
  else
    print("Timer creation Lua error: ", timerId, ret)
    return
  end

  if timer then
    TimerFunctions[timer] = timerFunction

    if type(timerId) == "string" then
      Timer[timerId] = timer
    else
      Timer[timer] = timer
    end
  end
  return timer
end

function ChangeTimer(timerId, delay, timerFunction, repeating)
  local timer
  if type(timerId) == "string" then
    timer = Timer[timerId]
  elseif type(timerId) == "userdata" then
    timer = timerId
  end

  if TimerFunctions[timer] == nil then
    return nil
  end

  if type(timerFunction) ~= "function" then
    timerFunction = TimerFunctions[timer]
  end

  if delay == nil then
    TimerFunctions[timer] = timerFunction
    return timer
  else
    return (SetTimer(timerId, delay, timerFunction, repeating))
  end
end

function ExpireTimer(timerId, keepAlive)
  local timer
  if type(timerId) == "string" then
    timer = Timer[timerId]
  elseif type(timerId) == "userdata" then
    timer = timerId
  end

  if TimerFunctions[timer] then
    local skips = 0
    local timerFn = TimerFunctions[timer]
    local success, ret = xpcall(function()
      return timerFn(timer, skips)
    end, debug.traceback)
    if success == true then
      return ret
    elseif success == false then
      print("Timer Force Expire Lua error: ", timerId, ret)
      if ON_TIMER_ERROR then
        ON_TIMER_ERROR(timerId, ret)
      end
    end
  end

  if keepAlive ~= true then
    CancelTimer(timerId)
  end
end
