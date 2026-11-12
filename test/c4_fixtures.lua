-- Reusable Control4 test seams built on c4_shim.
--
-- Separate from c4_shim so the environment mock stays one clean layer and the
-- fixtures a test composes stay another. Generic assertions live in testlib.
--
-- Usage:
--   local F = require("c4_fixtures")

require("c4_shim")

local F = {}

--- Reload c4_shim with luasocket forced present or absent, run body, then put
--- every global the reload touched back.
---
--- The two branches of the shim define C4:SetTimer separately and CI has no
--- luasocket while a developer machine may, so behavior that must hold on both
--- has to be driven on both. When luasocket is faked present, body receives a
--- clock whose advance() moves time forward and fires whatever came due.
---
--- Returns pcall's ok and error.
function F.withShim(opts, body)
  local hasSocket = opts.luasocket and true or false
  local saved = {
    C4 = C4,
    Variables = Variables,
    Properties = Properties,
    socketLoaded = package.loaded["socket"],
    socketPreload = package.preload["socket"],
    shim = package.loaded["c4_shim"],
    Timer = Timer,
    TimerFunctions = TimerFunctions,
    shimAccessors = {},
  }
  for name, value in pairs(_G) do
    if type(name) == "string" and name:find("^Shim") then
      saved.shimAccessors[name] = value
    end
  end

  local now = opts.startTime or 1000
  package.loaded["socket"] = nil
  if hasSocket then
    package.preload["socket"] = function()
      return {
        gettime = function()
          return now
        end,
        sleep = function() end,
        tcp = function()
          return nil
        end,
      }
    end
  else
    package.preload["socket"] = function()
      error("luasocket not installed")
    end
  end

  package.loaded["c4_shim"] = nil
  require("c4_shim")

  -- drivers-common-public/global/timer.lua keeps its registries in globals, so a
  -- fresh shim alone does not give the body a clean timer table.
  Timer, TimerFunctions = {}, {}

  local clock = {
    now = function()
      return now
    end,
    advance = function(seconds)
      now = now + (seconds or 1)
      C4:ProcessTimers()
    end,
  }

  local ok, err = pcall(body, clock)

  package.loaded["socket"] = saved.socketLoaded
  package.preload["socket"] = saved.socketPreload
  package.loaded["c4_shim"] = saved.shim
  -- The id counter and the attribute tables are locals in the shim, so the
  -- reload got its own and restoring C4 restores the originals with it.
  C4, Variables, Properties = saved.C4, saved.Variables, saved.Properties
  Timer, TimerFunctions = saved.Timer, saved.TimerFunctions
  -- The Shim* accessors are free globals, not C4 methods, so restoring C4 leaves
  -- the reload's copies in place, closed over the reload's tables.
  for name, value in pairs(saved.shimAccessors) do
    _G[name] = value
  end

  return ok, err
end

--- Replace C4:CreateTCPClient with one that records what is written, completes
--- the connect synchronously, and answers each read the way Director answers
--- UpdateProjectC4i.
---
--- Returns a handle whose `writes` holds every Write payload in order, and whose
--- `restore()` puts the real constructor back. With `holdReplies`, reads wait
--- until `reply()` answers the oldest one.
--- @param opts? { holdReplies?: boolean }
function F.captureTcpClient(opts)
  local capture = { writes = {}, pendingReplies = {} }
  local real = C4.CreateTCPClient

  C4.CreateTCPClient = function()
    local client = {}
    function client:OnConnect(callback)
      self._onConnect = callback
      return self
    end
    function client:OnRead(callback)
      self._onRead = callback
      return self
    end
    function client:OnError()
      return self
    end
    function client:Write(data)
      table.insert(capture.writes, data)
      return self
    end
    function client:ReadUntil()
      local function answer()
        if self._onRead and not self._closed then
          self._onRead(self, '<c4soap name="UpdateProjectC4i" result="1"/>\0')
        end
      end
      if opts and opts.holdReplies then
        table.insert(capture.pendingReplies, answer)
      else
        answer()
      end
    end
    function client:Close()
      self._closed = true
    end
    function client:Connect()
      if self._onConnect then
        self._onConnect(self)
      end
      return self
    end
    return client
  end

  function capture.reply()
    local answer = table.remove(capture.pendingReplies, 1)
    if answer then
      answer()
    end
  end

  function capture.restore()
    C4.CreateTCPClient = real
  end

  return capture
end

-- The conditions each build's preprocess.py run sets.
local BUILDS = { drivercentral = { DRIVERCENTRAL = true }, oss = { OSS = true } }

--- Run the Lua file at `path` as `build` ("drivercentral" or "oss") compiles it: a line its
--- directives leave out is blanked, so line numbers stay the source's. Raw source runs every arm.
--- @param path string
--- @param build string
--- @return any The file's return value.
function F.dofileBuild(path, build)
  local conditions = assert(BUILDS[build], build)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local ifdef, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if ifdef then
      stack[#stack + 1] = including
      including = including and (conditions[name] == true) == (ifdef == "ifdef")
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    lines[#lines + 1] = including and line or ""
  end
  f:close()
  return assert(load(table.concat(lines, "\n"), "@" .. path))()
end

--- Run C4:SetTimer and C4:GetTime on a virtual clock, so a test plays minutes of timers
--- instantly and in a fixed order. Timers due together fire in the order they were set,
--- and a repeating one is set again before its callback runs. The clock starts at
--- `opts.start` milliseconds, 1000000 by default.
---
--- drivers-common-public and deferred swallow an error in a SetTimer callback or a promise
--- unless ON_TIMER_ERROR and ON_UNHANDLED_REJECTION are set, so the clock sets both and keeps
--- what they get in `errors`. An error in a bare C4:SetTimer callback is raised out of `run`.
---
--- Returns a clock: `now()` in milliseconds, `run(ms)` fires whatever falls due in the next
--- `ms` and ends there, `at(ms, fn)` calls fn that far ahead, `errors`, and `restore()`.
function F.virtualClock(opts)
  opts = opts or {}
  local now = opts.start or 1000000
  local queue, order = {}, 0
  local saved = {
    setTimer = C4.SetTimer,
    onTimerError = ON_TIMER_ERROR,
    onRejection = ON_UNHANDLED_REJECTION,
  }
  local clock = { errors = {} }

  local function schedule(ms, fn)
    order = order + 1
    local entry = { at = now + math.max(0, ms), order = order, fn = fn }
    queue[#queue + 1] = entry
    return entry
  end

  ShimSetClock(function()
    return now
  end)

  function C4:SetTimer(delayMs, callback, repeating)
    local handle = newproxy(true)
    local entry
    local function arm()
      entry = schedule(delayMs, function()
        if repeating then
          arm()
        end
        callback(handle, 0)
      end)
    end
    arm()
    local mt = getmetatable(handle)
    mt.__index = {
      Cancel = function()
        entry.cancelled = true
        -- nil, so global/timer.lua clears its slot
        return nil
      end,
    }
    mt.__tostring = function()
      return "C4LuaTimer (virtual)"
    end
    return handle
  end

  ON_TIMER_ERROR = function(_, err)
    clock.errors[#clock.errors + 1] = tostring(err)
  end
  ON_UNHANDLED_REJECTION = function(err)
    clock.errors[#clock.errors + 1] = tostring(err)
  end

  function clock.now()
    return now
  end

  function clock.at(ms, fn)
    schedule(ms, fn)
  end

  function clock.run(ms)
    local stop = now + ms
    while true do
      local best, index
      for i, entry in ipairs(queue) do
        if
          not entry.cancelled
          and entry.at <= stop
          and (not best or entry.at < best.at or (entry.at == best.at and entry.order < best.order))
        then
          best, index = entry, i
        end
      end
      if not best then
        break
      end
      table.remove(queue, index)
      now = best.at
      best.fn()
    end
    now = stop
  end

  function clock.restore()
    ShimSetClock(nil)
    C4.SetTimer = saved.setTimer
    ON_TIMER_ERROR, ON_UNHANDLED_REJECTION = saved.onTimerError, saved.onRejection
  end

  return clock
end

return F
