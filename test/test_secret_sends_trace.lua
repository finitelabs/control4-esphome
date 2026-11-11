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
local shimSendToProxy, shimSendToDevice = C4.SendToProxy, C4.SendToDevice
function C4:SendToProxy(...)
  sent[#sent + 1] = { "SendToProxy", select("#", ...), ... }
  return shimSendToProxy(self, ...)
end
function C4:SendToDevice(...)
  sent[#sent + 1] = { "SendToDevice", select("#", ...), ... }
  return shimSendToDevice(self, ...)
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
T.contains("its device and command", output, "C4:SendToDevice(42, ARM, ***REDACTED***, false, false)")
T.excludes("and never the code", output, CODE)
T.eq("C4 is handed the parameters whole", sent[1][5].UserCode, CODE)
T.eq(
  "and told not to log the command's content, with empty values refused",
  { sent[1][2], sent[1][6], sent[1][7] },
  { 5, false, false }
)
sent = {}
SendSecretToDevice(42, "ARM", { UserCode = CODE }, nil, true)
T.eq("unless the caller asks it to", sent[1][7], true)
sent = {}
SendSecretToDevice(42, "ARM", { UserCode = "" }, true)
T.eq("and empty values allowed when asked for", sent[1][6], true)

T.section("the plain wrappers still trace every argument")
output = traced(function()
  SendToProxy(5001, "LOCK_STATUS_CHANGED", { LOCK_STATUS = "locked" }, "NOTIFY")
end)
T.excludes("nothing is redacted", output, "***REDACTED***")
T.contains("the call is traced", output, "C4:SendToProxy(5001, LOCK_STATUS_CHANGED, ")

T.section("an argument left out before one that is given reaches C4 as its default")
sent = {}
local calls = {
  {
    "SendSecretToDevice, with no flags",
    function()
      SendSecretToDevice(42, "ARM", { UserCode = CODE })
    end,
  },
  {
    "SendToDevice, told only not to log",
    function()
      SendToDevice(42, "REFRESH", {}, nil, false)
    end,
  },
  {
    "SendSecretToProxy, told only to allow empty values",
    function()
      SendSecretToProxy(5001, "USER_ADDED", { PASSCODE = "" }, nil, true)
    end,
  },
  {
    "SendToProxy, told only to allow empty values",
    function()
      SendToProxy(5001, "LOCK_STATUS_CHANGED", { LOCK_STATUS = "" }, nil, true)
    end,
  },
}
for _, call in ipairs(calls) do
  T.truthy("C4 accepts " .. call[1], pcall(call[2]))
end
T.eq("a device command's empty values refused", { sent[1][6], sent[2][6] }, { false, false })
T.eq("a proxy message sent as a command", { sent[3][6], sent[4][6] }, { "COMMAND", "COMMAND" })
sent = {}
SendToDevice(42, "REFRESH", {})
SendToProxy(5001, "LOCK_STATUS_CHANGED", {})
T.eq("and nothing is added when nothing follows", { sent[1][2], sent[2][2] }, { 3, 3 })

T.section("a flag given as something other than a boolean reaches C4 as one")
sent = {}
calls = {
  {
    "SendToProxy, allowing empty values with a string",
    function()
      SendToProxy(5001, "LOCK_STATUS_CHANGED", {}, "NOTIFY", "yes")
    end,
  },
  {
    "SendSecretToProxy, allowing empty values with a number",
    function()
      SendSecretToProxy(5001, "USER_ADDED", {}, "NOTIFY", 1)
    end,
  },
  {
    "SendToDevice, allowing empty values with a string",
    function()
      SendToDevice(42, "REFRESH", {}, "yes")
    end,
  },
  {
    "SendToDevice, asked to log with a number",
    function()
      SendToDevice(42, "REFRESH", {}, true, 0)
    end,
  },
}
for _, call in ipairs(calls) do
  T.truthy("C4 accepts " .. call[1], pcall(call[2]))
end
T.eq(
  "only true allows empty values",
  { Select(sent, 1, 7), Select(sent, 2, 7), Select(sent, 3, 6), Select(sent, 4, 6) },
  { false, false, false, true }
)
T.eq("and only true lets C4 log the command", Select(sent, 4, 7), false)

T.section("a nil before an argument that is given is refused before it reaches C4")
sent = {}
T.raises("SendToProxy with no parameters before a message type", function()
  SendToProxy(5001, "LOCK_STATUS_CHANGED", nil, "NOTIFY")
end, "C4:SendToProxy refused: argument 3 is nil before argument 4")
T.raises("SendSecretToDevice with no parameters", function()
  SendSecretToDevice(42, "ARM", nil)
end, "C4:SendToDevice refused: argument 3 is nil before argument 5")
T.raises("SendToNetwork with no port", function()
  SendToNetwork(6001, nil, "GET / HTTP/1.1")
end, "C4:SendToNetwork refused: argument 2 is nil before argument 3")
T.raises("SendUIRequest with no request", function()
  SendUIRequest(42, nil, {})
end, "C4:SendUIRequest refused: argument 2 is nil before argument 3")
T.eq("and none reaches C4", sent, {})

T.finish()
