-- How handlers.lua and timer.lua hand a call to a driver's handler, where our copy
-- differs from Snap One's: OnPropertyChanged's name sanitiser, and the
-- ON_HANDLER_ERROR and ON_TIMER_ERROR hooks with the traceback. home-connect's
-- diagnostics install both hooks, so losing one would turn them off silently.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_dispatch.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")

local function raise()
  error("handler failed")
end

T.section("OnPropertyChanged finds a handler by the name's letters and digits")
local seen = {}
OPC.Scan_Duration_seconds = function(value)
  seen.scan = value
end
OPC.PM2_5 = function(value)
  seen.pm = value
end
Properties["Scan Duration (seconds)"], Properties["PM2.5"] = "30", "12"
OnPropertyChanged("Scan Duration (seconds)")
OnPropertyChanged("PM2.5")
T.eq("a run of spaces and brackets becomes one _", seen.scan, "30")
T.eq("so does a dot", seen.pm, "12")

T.section("A handler that raises reaches ON_HANDLER_ERROR with its traceback")
EC.RAISE, OBC[5001], OCS[5001], OSE.RAISE, OVC.RAISE, RFN[5001], RFP.RAISE, TC.RAISE, UIR.RAISE =
  raise, raise, raise, raise, raise, raise, raise, raise, raise
OPC.Scan_Duration_seconds = raise
RegisterDeviceEvent(2787, 1, raise)
RegisterVariableListener(2787, 1012, raise)

local dispatchers = {
  { "EC.RAISE", ExecuteCommand, "RAISE", {} },
  { "OBC.5001", OnBindingChanged, 5001, "TCP", true, 2787, 1 },
  { "OCS.5001", OnConnectionStatusChanged, 5001, 80, "ONLINE" },
  { "ODE.2787", OnDeviceEvent, 2787, 1 },
  { "OPC.Scan_Duration_seconds", OnPropertyChanged, "Scan Duration (seconds)" },
  { "OSE.RAISE", OnSystemEvent, '<event name="RAISE"/>' },
  { "OVC.RAISE", OnVariableChanged, "RAISE", 1 },
  { "OWVC.2787", OnWatchedVariableChanged, 2787, 1012, "1" },
  { "RFN.5001", ReceivedFromNetwork, 5001, 80, "data" },
  { "RFP.RAISE", ReceivedFromProxy, 5001, "RAISE", {} },
  { "TC.RAISE", TestCondition, "RAISE", {} },
  { "UIR.RAISE", UIRequest, "RAISE", {} },
}
for _, case in ipairs(dispatchers) do
  local source, err
  ON_HANDLER_ERROR = function(hookSource, hookErr)
    source, err = hookSource, hookErr
  end
  T.capture(function()
    case[2](unpack(case, 3))
  end)
  T.check(
    case[1] .. " reports to the hook",
    source == case[1] and tostring(err):find("stack traceback", 1, true) ~= nil,
    tostring(source) .. ": " .. tostring(err)
  )
end
ON_HANDLER_ERROR = nil

T.section("A timer callback that raises reaches ON_TIMER_ERROR with its traceback")
local timerId, timerErr
ON_TIMER_ERROR = function(hookTimerId, hookErr)
  timerId, timerErr = hookTimerId, hookErr
end
SetTimer("RaisingTimer", ONE_SECOND, raise)
T.capture(ShimFireTimers)
T.eq("from SetTimer", timerId, "RaisingTimer")
T.contains("with the traceback", timerErr, "stack traceback")
timerId, timerErr = nil, nil
SetTimer("ExpiredTimer", ONE_SECOND, raise)
T.capture(function()
  ExpireTimer("ExpiredTimer")
end)
T.eq("and from ExpireTimer", timerId, "ExpiredTimer")
T.contains("with the traceback", timerErr, "stack traceback")
ON_TIMER_ERROR = nil

T.section("Upstream's UIRequest reply and Select, which the port took")
UIR.NOTHING = function() end
T.eq("UIRequest replies with XML when its handler returns none", UIRequest("NOTHING", {}), "<result>success</result>")
T.eq("Select returns nil at a nil key, not the table it reached", Select({ a = { b = 1 } }, "a", nil, "b"), nil)

T.finish()
