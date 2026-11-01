-- lib.diagnostics: what an error report keeps of a message, a traceback, a census path and a source, and what it
-- removes before anything leaves the controller.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_diagnostics_scrub.lua

local T = require("testlib")

require("c4_shim")
local Diagnostics = getmetatable(require("lib.diagnostics"))

local scrub = Diagnostics._scrub
local splitError = Diagnostics._splitError
local pathKey = Diagnostics._pathKey
local sourceTag = Diagnostics._sourceTag

local TOKEN = "k7Qz2mXp9VwL4tRb8NcY3hJd6FsG1aE5"

T.section("A Lua runtime error is kept whole")
local runtime = "lib/example.lua:42: attempt to index field 'state' (a nil value)"
T.eq("names and types only, so nothing is removed", scrub(runtime, 200), runtime)
local call = "drivers-common-public/global/handlers.lua:344: attempt to call method 'getCapabilities' (a nil value)"
T.eq("nor from a path through the vendored modules", scrub(call, 200), call)

T.section("JSON.lua's decode errors lose the text they quote")
T.eq(
  "a token response that failed to decode",
  scrub('expected comma or \'}\' at byte 41 of: {"access_token":"' .. TOKEN .. '" "expires_in":3600}', 200),
  "expected comma or '}' at byte 41"
)
T.eq(
  "an HTML page passed to decode",
  scrub("HTML passed to JSON:decode(): <html><body>Sign in as owner@example.com</body></html>", 200),
  "HTML passed to JSON:decode()"
)
T.eq(
  "text that is not UTF-8",
  scrub('lib/example.lua:5: JSON package groks only UTF-8, sorry: \0{"pin":"1234"}', 200),
  "lib/example.lua:5: JSON package groks only UTF-8, sorry"
)
T.eq("text that ends too soon", scrub("unexpected end of string: " .. TOKEN, 200), "unexpected end of string")

T.section("Credentials, addresses and IDs are removed")
local cases = {
  { "a credential pair", "login failed: password=hunter2&user=installer", "hunter2" },
  { "a JSON credential member", 'refresh rejected {"refresh_token":"short","scope":"read"}', "short" },
  { "a bearer token", "upstream said: Bearer " .. TOKEN, TOKEN },
  { "a URL, query and all", "HTTP GET request to https://api.example.com/v1/items?key=abc failed", "api.example.com" },
  { "a local URL", "HTTP POST request to http://192.168.1.50/rpc failed", "192.168.1.50" },
  { "an IPv4 address", "no answer from 10.0.0.23 after 3 tries", "10.0.0.23" },
  { "an IPv6 address", "connect to fe80::1c2b:3cff:fe4d:5e6f failed", "fe80::1c2b" },
  { "an email address", "account owner@example.com is locked", "owner@example.com" },
  { "a MAC address", "device 02:00:00:aa:bb:cc went offline", "02:00:00:aa:bb:cc" },
  { "an EUI-64 with separators", "unbound 00-11-22-ff-fe-33-44-55", "00-11-22-ff-fe-33-44-55" },
  { "an EUI-64 without", "unbound 0x00112233ffee4455", "00112233ffee4455" },
  { "an appliance ID", "appliance EXAMPLE-OV1234567-0123456789AB is busy", "0123456789AB" },
  { "a long token", "token " .. TOKEN .. " expired", TOKEN },
  {
    "a JWT",
    "id eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    "eyJ",
  },
}
for _, case in ipairs(cases) do
  T.excludes(case[1], scrub(case[2], 200), case[3])
end
T.eq("what was removed is marked", scrub("no answer from 10.0.0.23", 200), "no answer from <ip>")
T.eq("a version number is not an address", scrub("needs 4.3.0.12345 or later", 200), "needs 4.3.0.12345 or later")

T.section("Each part is capped")
local long = string.rep("x", 500)
T.eq("a message at 200 bytes", #scrub(long, 200), 200)
T.truthy("ending in an ellipsis", scrub(long, 200):sub(-3) == "...")
local accented = string.rep("é", 150)
local cut = scrub(accented, 200)
T.truthy("never inside a UTF-8 character", cut:sub(1, -4):find("^[\128-\255]*$") and #cut:sub(1, -4) % 2 == 0)

T.section("A traceback is split off at Lua's marker, not the first newline")
local multi = "decode failed: line one\nline two holds " .. TOKEN .. "\nstack traceback:\n\t[C]: in function 'error'"
local message, traceback = splitError(multi)
T.eq("the message is everything before the marker", message, "decode failed: line one\nline two holds " .. TOKEN)
T.eq("the traceback is the frames", traceback, "\t[C]: in function 'error'")
T.excludes("so the message's second line is scrubbed with it", scrub(message, 200), TOKEN)
T.eq("an error with no traceback", select(2, splitError("plain")), "")

T.section("A rejection from lib.http sends its redacted error, not table: 0x")
local rejected = { error = "HTTP GET request to https://api.example.com/x failed with status code 401", code = 401 }
T.eq("the error string", (splitError(rejected)), rejected.error)
T.eq("another table says only that", (splitError({ 1, 2 })), "a table")

T.section("Census paths keep code names and drop data keys")
T.eq("a field", pathKey("devices", "_G"), ".devices")
T.eq("an integer", pathKey(5001, "_G.OBC"), "[5001]")
T.eq(
  "a module name under package.loaded",
  pathKey("drivers-common-public.global.timer", "_G.package.loaded"),
  ".drivers-common-public.global.timer"
)
T.eq("but a dotted key elsewhere is data", pathKey("kitchen.local", "_G.hosts"), "[?]")
for _, key in ipairs({
  "00:11:22:ff:fe:33:44:55",
  "0x00112233ffee4455",
  "10.0.0.23",
  "Living Room",
  "owner@example.com",
  TOKEN,
}) do
  T.eq("a data key: " .. key, pathKey(key, "_G.devices"), "[?]")
end
T.eq("a fractional number", pathKey(1.5, "_G.x"), "[?]")

T.section("Sources keep the dispatcher and a name a driver defines")
T.eq("an action", sourceTag("EC.Diagnostics Snapshot"), "EC.Diagnostics Snapshot")
T.eq("a binding", sourceTag("OBC.5001"), "OBC.5001")
T.eq("a timer named with an address", sourceTag("Timer.Poll 10.0.0.23"), "Timer.?")
T.eq("a timer named with an EUI", sourceTag("Timer.Poll_00112233ffee4455"), "Timer.?")
T.eq("a bare source", sourceTag("UnhandledRejection"), "UnhandledRejection")

T.finish()
