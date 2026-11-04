-- What lib/utils.lua's send wrappers trace for a message that carries a secret. SendToProxy and SendToDevice
-- trace every argument, so a user code sent through them was printed in plain text with Log Mode on at Trace;
-- SendSecretToProxy and SendSecretToDevice send the same and trace the call without its parameters.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_secret_sends_trace.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local log = require("lib.logging")

-- An obviously fake secret: a trace that shows it has leaked it.
local CODE = "FAKE-CODE-0000"

-- What reached C4, as each call handed it over.
local sent = {}
function C4:SendToProxy(...)
  sent[#sent + 1] = { "SendToProxy", select("#", ...), ... }
end
function C4:SendToDevice(...)
  sent[#sent + 1] = { "SendToDevice", select("#", ...), ... }
end

--- Everything lib.logging prints at trace level while fn runs.
local function traced(fn)
  log:setLogLevel("5 - Trace")
  log:setLogMode("Print")
  local ok, err, output = T.capture(fn)
  log:setLogMode("")
  T.truthy("runs without error", ok, err)
  return output
end

T.section("a proxy message that carries a secret traces its binding and command, not its parameters")
local output = traced(function()
  SendSecretToProxy(5001, "USER_ADDED", { USER_ID = 3, PASSCODE = CODE }, "NOTIFY")
  SendSecretToProxy(
    5001,
    "USERS",
    "<lock_users><user><passcode>" .. CODE .. "</passcode></user></lock_users>",
    "NOTIFY"
  )
end)
T.contains("a table of parameters", output, "C4:SendToProxy(5001, USER_ADDED, ***REDACTED***, NOTIFY, nil)")
T.contains("a string of them the same", output, "C4:SendToProxy(5001, USERS, ***REDACTED***, NOTIFY, nil)")
T.excludes("and never the code", output, CODE)
T.eq("C4 is handed the parameters whole", sent[1][5].PASSCODE, CODE)
T.eq("with its trailing nil left off, as SendToProxy does", sent[1][2], 4)

T.section("a command to a device the same")
sent = {}
output = traced(function()
  SendSecretToDevice(42, "ARM", { UserCode = CODE })
end)
T.contains("its device and command", output, "C4:SendToDevice(42, ARM, ***REDACTED***, nil, false)")
T.excludes("and never the code", output, CODE)
T.eq("C4 is handed the parameters whole", sent[1][5].UserCode, CODE)
T.eq("and told not to log the command's content", { sent[1][2], sent[1][7] }, { 5, false })
sent = {}
SendSecretToDevice(42, "ARM", { UserCode = CODE }, nil, true)
T.eq("unless the caller asks it to", sent[1][7], true)

T.section("the plain wrappers still trace every argument")
output = traced(function()
  SendToProxy(5001, "LOCK_STATUS_CHANGED", { LOCK_STATUS = "locked" }, "NOTIFY")
end)
T.excludes("nothing is redacted", output, "***REDACTED***")
T.contains("the call is traced", output, "C4:SendToProxy(5001, LOCK_STATUS_CHANGED, ")

T.finish()
