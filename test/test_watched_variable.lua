-- Tests for handler dispatch when Director will not name the firing device.
--
-- C4:GetDeviceDisplayName returns *no value* (arity 0, not nil) for an id that
-- is not a project item. Director's synthetic delay (100000) and variables
-- (100001) agents are exactly that, and 100001 is where every Composer global
-- lives. OnWatchedVariableChanged used to concatenate that result directly, so
-- the throw landed on the line building the debug string -- above the dispatch
-- to the driver's callback and above the xpcall that would have reported it.
-- The driver saw silence, not an error: watched globals never updated, and a
-- restart appeared to fix it until the next change. OnDeviceEvent had the same
-- unguarded call.
--
-- HandlerDebug returns early unless DEBUGPRINT, but `init` is built before the
-- call, so debug being off did not spare production. Both states are covered.
--
-- Regression test for DRV-95.
--
-- Run from the driver root:
--   make test
-- or:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/src/?/init.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_watched_variable.lua

require("drivers-common-public.global.lib") -- Select, GetDeviceDisplayNameOrId
require("drivers-common-public.global.handlers") -- OWVC, ODE, OnWatchedVariableChanged, OnDeviceEvent

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

-- The shim owns C4:GetDevices / GetDeviceDisplayName / GetDeviceVariables. A
-- device with no deviceName is the nameless case the fix turns on: the shim
-- returns no value at all (arity 0), as the controller does, so code that
-- concatenates the result directly still throws. 100001 is Director's variables
-- agent -- variables, no name -- and 100000 is the delay agent.
require("c4_shim")
ShimSetDevices({
  [2787] = { deviceName = "InfluxDB Data Logger" },
  [2341] = { deviceName = "Master Bathroom Humidity", variables = { ["1012"] = { name = "HUMIDITY" } } },
  [100001] = { variables = { ["2301"] = { name = "MB_HIGH_HUMIDITY_DIFF_THRESHOLD" } } },
})

--- Capture whatever HandlerDebug prints so the debug line itself can be asserted.
local captured
local realPrint = print
local function withCapturedPrint(fn)
  captured = {}
  print = function(...) -- luacheck: ignore
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    table.insert(captured, table.concat(parts, " "))
  end
  local ok, err = pcall(fn)
  print = realPrint -- luacheck: ignore
  return ok, err
end

local function debugOutput()
  return table.concat(captured, "\n")
end

-- ── The regression: a variable on the nameless agent ──────────────────────────

DEBUGPRINT = false

local fired = {}
RegisterVariableListener(100001, 2301, function(idDevice, idVariable, strValue)
  table.insert(fired, { idDevice, idVariable, strValue })
end)

local ok, err = withCapturedPrint(function()
  OnWatchedVariableChanged(100001, 2301, "2")
end)
check("the callback runs for a device Director will not name", ok and #fired == 1, err or ("fired=" .. #fired))
check("it receives the new value", fired[1] and fired[1][3] == "2", fired[1] and fired[1][3])

-- ── The same variable with debug on: the line is built, and it is readable ────

DEBUGPRINT = true
fired = {}
ok, err = withCapturedPrint(function()
  OnWatchedVariableChanged(100001, 2301, "3")
end)
check("debug on does not throw either", ok and #fired == 1, err or ("fired=" .. #fired))
check(
  "the nameless device falls back to its id",
  debugOutput():find("OnWatchedVariableChanged: device 100001 [100001]", 1, true) ~= nil,
  debugOutput()
)
check(
  "the variable name still resolves",
  debugOutput():find("MB_HIGH_HUMIDITY_DIFF_THRESHOLD [2301]", 1, true) ~= nil,
  debugOutput()
)

-- ── A named device is unaffected ──────────────────────────────────────────────

fired = {}
RegisterVariableListener(2341, 1012, function(idDevice, idVariable, strValue)
  table.insert(fired, { idDevice, idVariable, strValue })
end)
ok, err = withCapturedPrint(function()
  OnWatchedVariableChanged(2341, 1012, "54")
end)
check("a named device still dispatches", ok and #fired == 1, err or ("fired=" .. #fired))
check(
  "and still prints its display name, not its id",
  debugOutput():find("OnWatchedVariableChanged: Master Bathroom Humidity [2341]", 1, true) ~= nil,
  debugOutput()
)

-- ── OnDeviceEvent carried the identical bug ───────────────────────────────────

local eventsSeen = {}
RegisterDeviceEvent(100001, 1, function(firingDeviceId, eventId)
  table.insert(eventsSeen, { firingDeviceId, eventId })
end)

ok, err = withCapturedPrint(function()
  OnDeviceEvent(100001, 1)
end)
check("OnDeviceEvent dispatches for a nameless device", ok and #eventsSeen == 1, err or ("seen=" .. #eventsSeen))
check(
  "and falls back to the id in its debug line",
  debugOutput():find("OnDeviceEvent: device 100001 [100001]", 1, true) ~= nil,
  debugOutput()
)

-- ── The helper itself ─────────────────────────────────────────────────────────

check("GetDeviceDisplayNameOrId prefers the real name", GetDeviceDisplayNameOrId(2787) == "InfluxDB Data Logger")
check("GetDeviceDisplayNameOrId falls back for 100001", GetDeviceDisplayNameOrId(100001) == "device 100001")
check("GetDeviceDisplayNameOrId falls back for 100000", GetDeviceDisplayNameOrId(100000) == "device 100000")
check("GetDeviceDisplayNameOrId tolerates a nil id", GetDeviceDisplayNameOrId(nil) == "device nil")

DEBUGPRINT = false

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
