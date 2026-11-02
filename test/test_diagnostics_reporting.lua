-- lib.diagnostics: when Cloud Monitoring reports, what it posts and where, and the driver's own points; and that
-- each driver's late init goes through wrapLateInit.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_diagnostics_reporting.lua

local T = require("testlib")

require("c4_shim")
local deferred = require("deferred")
local http = require("lib.http")
local Diagnostics = getmetatable(require("lib.diagnostics"))

local SERVER = {
  url = "https://influx.example.test",
  token = "test-token-not-real",
  metricsDb = "test_metrics",
  logsDb = "test_logs",
}

function C4:GetUniqueMAC()
  return "02:00:00:00:00:01"
end

local posts = {}
function http:post(url, body, headers, options)
  table.insert(posts, { url = url, body = body, headers = headers, options = options })
  local d = deferred.new()
  d:resolve({ code = 204 })
  return d
end

--- The posts made while `fn` runs.
local function posted(fn)
  posts = {}
  fn()
  return posts
end

--- A diagnostics instance whose census is one small table, so a report is quick to read.
local function fresh(server)
  local diag = Diagnostics:new(server)
  diag._tableCensus = function()
    return { ["_G.example"] = { count = 3, bytes = 12 } }
  end
  return diag
end

T.section("A build without the whole server never reports")
for _, missing in ipairs({ "url", "token", "metricsDb", "logsDb" }) do
  local server = {}
  for k, v in pairs(SERVER) do
    server[k] = v
  end
  server[missing] = ""
  local diag = fresh(server)
  diag:setEnabled(true)
  T.falsy("without " .. missing .. ", enabling leaves it off", diag:isEnabled())
  T.eq("and no hook is set", ON_HANDLER_ERROR, nil)
end
T.falsy(
  "nor with a placeholder the build left in place",
  fresh({
    url = "__INFLUXDB_URL" .. "__",
    token = SERVER.token,
    metricsDb = SERVER.metricsDb,
    logsDb = SERVER.logsDb,
  })._available
)
T.falsy("and the module's own copy, unbuilt, has none", require("lib.diagnostics")._available)

T.section("Enabling sets the hooks and waits for the first report")
local diag = fresh(SERVER)
local sent = posted(function()
  diag:setEnabled(true)
end)
T.truthy("enabled", diag:isEnabled())
T.eq("nothing is sent at once", #sent, 0)
T.truthy("the handler hook is set", type(ON_HANDLER_ERROR) == "function")
T.truthy("the timer hook is set", type(ON_TIMER_ERROR) == "function")
T.truthy("the rejection hook is set", type(ON_UNHANDLED_REJECTION) == "function")
T.eq(
  "the first report waits 30 s plus a spread by device ID",
  diag:_firstReportDelay(),
  (30 + 12345 * 7919 % 270) * 1000
)
diag._deviceId = 12346
T.neq(
  "so the next device's first report comes at another time",
  diag:_firstReportDelay(),
  (30 + 12345 * 7919 % 270) * 1000
)
diag._deviceId = 12345

T.section("The report goes to the metrics database")
sent = posted(ShimFireTimers)
T.eq("one post", #sent, 1)
local post = sent[1]
T.eq("to the v2 write endpoint", post.url, "https://influx.example.test/api/v2/write?bucket=test_metrics&precision=s")
T.eq("with the token as a bearer", post.headers.Authorization, "Bearer test-token-not-real")
T.eq("as plain text", post.headers["Content-Type"], "text/plain; charset=utf-8")
T.eq("with a short timeout", post.options.timeout, 2)
T.truthy(
  "a diagnostics point",
  post.body:find("^diagnostics,mac=02:00:00:00:00:01,device_id=12345,driver=example.c4z,") ~= nil
)
T.contains("a census point", post.body, "\ncensus,")
T.contains("with its path", post.body, ",path=_G.example size=3i,bytes=12i,rank=1i ")
T.excludes("and no c4_ prefix", post.body, "c4_")
sent = posted(ShimFireTimers)
T.eq("then the repeating report", #sent, 1)

T.section("An error goes to the logs database, scrubbed")
sent = posted(function()
  ON_HANDLER_ERROR(
    "OPC.Example",
    'lib/example.lua:9: login failed: {"password":"hunter2"} from 10.0.0.23\nstack traceback:\n\t[C]: in function \'error\''
  )
end)
T.eq("one post", #sent, 1)
post = sent[1]
T.eq("to the logs database", post.url, "https://influx.example.test/api/v2/write?bucket=test_logs&precision=s")
T.truthy("an error_log point", post.body:find("^error_log,mac=") ~= nil)
T.contains("from its source", post.body, ",source=OPC.Example ")
T.excludes("without the password", post.body, "hunter2")
T.excludes("or the address", post.body, "10.0.0.23")
T.contains("with its traceback", post.body, "traceback=\"\\t[C]: in function 'error'\"")

T.section("A timer's and a rejection's errors are reported too")
sent = posted(function()
  ON_TIMER_ERROR("Poll", "lib/example.lua:3: boom")
  ON_TIMER_ERROR({}, "lib/example.lua:3: boom")
  ON_UNHANDLED_REJECTION({ error = "HTTP GET request to https://api.example.com/x failed", code = 500 })
end)
T.contains("a named timer", sent[1].body, ",source=Timer.Poll ")
T.contains("a timer with a handle for an ID", sent[2].body, ",source=Timer ")
T.contains("a rejection, by its error", sent[3].body, 'message="HTTP GET request to <url> failed"')

T.section("Errors past 10 a minute are counted, not sent")
diag._errorWindowStart = os.time()
diag._errorWriteCount = 0
diag._intervalErrorsReported = 0
sent = posted(function()
  for i = 1, 15 do
    diag:captureError("error " .. i, "", "test")
  end
end)
T.eq("10 sent", #sent, 10)
sent = posted(ShimFireTimers)
T.contains("the report counts them", sent[1].body, "errors_reported=10i,errors_dropped=5i")

T.section("Line protocol escaping")
sent = posted(function()
  diag._errorWindowStart = os.time()
  diag._errorWriteCount = 0
  diag:captureError('ends in a backslash \\ and a "quote"', "", "test")
end)
T.contains("backslashes and quotes are escaped", sent[1].body, 'message="ends in a backslash \\\\ and a \\"quote\\""')

T.section("Disabling clears the hooks and the timers")
diag:setEnabled(false)
T.eq("the handler hook", ON_HANDLER_ERROR, nil)
T.eq("the timer hook", ON_TIMER_ERROR, nil)
T.eq("the rejection hook", ON_UNHANDLED_REJECTION, nil)
sent = posted(ShimFireTimers)
T.eq("no report follows", #sent, 0)
sent = posted(function()
  diag:captureError("ignored", "", "test")
end)
T.eq("and no error is sent", #sent, 0)

T.section("Diagnostics Snapshot sends only while enabled")
local _, _, output
sent = posted(function()
  _, _, output = T.capture(function()
    diag:dumpSnapshot()
  end)
end)
T.contains("disabled, it prints", output, "Diagnostics Snapshot")
T.eq("and sends nothing", #sent, 0)
diag:setEnabled(true)
sent = posted(function()
  T.capture(function()
    diag:dumpSnapshot()
  end)
end)
T.eq("enabled, it sends", #sent, 1)
diag:setEnabled(false)

T.section("wrap keeps every argument and result, and reports a raise")
diag:setEnabled(true)
local wrapped = diag:wrap(function(a, b, c)
  return c, b, a
end, "test")
local r1, r2, r3 = wrapped(1, nil, 3)
T.eq("results in order, a nil included", { r1, r2, r3 }, { 3, nil, 1 })
diag._errorWindowStart = os.time()
diag._errorWriteCount = 0
sent = posted(function()
  T.capture(function()
    T.eq("a raise returns nothing", select("#", diag:wrap(error, "wrapped")("boom")), 0)
  end)
end)
T.contains("and is reported", sent[1].body, ",source=wrapped ")
diag:setEnabled(false)

T.section("A driver adds its own points to each report")
diag:setEnabled(true)
diag:onReport(function()
  return {
    {
      measurement = "example_device",
      tags = { model = "EX-100", brand = "Example Co" },
      fields = { online = true, rssi = -61 },
    },
    { measurement = "census", fields = { value = 1 } },
    { measurement = "example_device", tags = { mac = "spoofed" }, fields = { online = false } },
    { measurement = "example_device", fields = { reading = 0 / 0 } },
    { measurement = "example_device", tags = { model = "EX-200" } },
  }
end)
sent = posted(function()
  T.capture(ShimFireTimers)
end)
local body = sent[1].body
T.contains(
  "with the tags every point carries, then its own",
  body,
  "\nexample_device,mac=02:00:00:00:00:01,device_id=12345,"
)
T.contains("its own tags", body, ",brand=Example\\ Co,model=EX-100 ")
T.contains("its fields", body, " online=true,rssi=-61 ")
T.excludes("not a point named like Cloud Monitoring's own", body, " value=1 ")
T.excludes("not one that sets a tag every point carries", body, "spoofed")
T.excludes("not a non-finite number", body, "reading=")
T.excludes("not one with no field", body, "EX-200")
diag:onReport(function()
  error("driver bug")
end)
sent = posted(function()
  T.capture(ShimFireTimers)
end)
T.eq("a callback that raises costs only its own points", #sent, 1)
diag:onReport(function()
  return { { measurement = "example_device", fields = { online = true } } }
end)
diag:setEnabled(false)
sent = posted(function()
  _, _, output = T.capture(function()
    diag:dumpSnapshot()
  end)
end)
T.contains("a snapshot prints them while disabled", output, "example_device,mac=")
T.eq("and sends nothing", #sent, 0)

T.section("Asking again for what was last asked changes nothing")
local log = require("lib.logging")
local logged = {}
local info, warn = log.info, log.warn
function log:info(text)
  table.insert(logged, text)
end
function log:warn(text)
  table.insert(logged, text)
end
local again = fresh(SERVER)
local starts = 0
local startFirstReport = again._startFirstReport
function again:_startFirstReport()
  starts = starts + 1
  startFirstReport(self)
end
again:setEnabled(true)
again:setEnabled(true)
T.eq("enabled twice, the first report is scheduled once", starts, 1)
T.eq("and logged once", logged, { "[DIAG] Cloud Monitoring enabled (interval=%dm, gc=%s)" })
logged = {}
again:setEnabled(false)
again:setEnabled(false)
T.eq("disabled twice, it is logged once", logged, { "[DIAG] Cloud Monitoring disabled" })
logged = {}
local unavailable = fresh({ url = "", token = "", metricsDb = "", logsDb = "" })
unavailable:setEnabled(true)
unavailable:setEnabled(true)
T.eq("a build without the server says so once", logged, { "[DIAG] Cloud Monitoring is not available in this build" })
log.info, log.warn = info, warn

T.section("A late init through wrapLateInit reports from its first line")
Properties["Cloud Monitoring"] = "Enabled"
local late = fresh(SERVER)
sent = posted(function()
  T.capture(function()
    late:wrapLateInit(function()
      error("early boom")
    end)()
  end)
end)
T.eq("one post", #sent, 1)
T.contains("from the late init", sent[1].body, ",source=OnDriverLateInit ")
T.contains("with its message", sent[1].body, "early boom")
local args = { n = -1 }
late:wrapLateInit(function(...)
  args = { n = select("#", ...), ... }
  late:setEnabled(Properties["Cloud Monitoring"] == "Enabled")
end)("type")
T.eq("it passes Director's argument on", args, { n = 1, "type" })
T.truthy("and the property loop's own call leaves it on", late:isEnabled())
Properties["Cloud Monitoring"] = "Disabled"
sent = posted(function()
  T.capture(function()
    late:wrapLateInit(error)("boom")
  end)
end)
T.falsy("with the property Disabled it turns off", late:isEnabled())
T.eq("and sends nothing", #sent, 0)
Properties["Cloud Monitoring"] = nil

T.section("Each driver that reports wraps its late init with wrapLateInit")
local drivers = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "../drivers/"
local pipe = assert(io.popen(string.format("ls %q 2>/dev/null", drivers)))
for name in pipe:lines() do
  local fh = io.open(drivers .. name .. "/driver.lua", "r")
  local src = fh and fh:read("*a") or ""
  if fh then
    fh:close()
  end
  if src:find('require%("lib%.diagnostics"%)') then
    -- Each open #ifdef/#ifndef: true inside DRIVERCENTRAL, false in its other branch, nil for another symbol.
    local open, defined, wrapped = {}, false, false
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
      local directive, symbol = line:match("^%s*%-%-%s*#(%a+)%s*(%w*)%s*$")
      if directive == "ifdef" or directive == "ifndef" then
        local dc = nil
        if symbol == "DRIVERCENTRAL" then
          dc = directive == "ifdef"
        end
        table.insert(open, { dc = dc })
      elseif directive == "else" and open[#open] and open[#open].dc ~= nil then
        open[#open].dc = not open[#open].dc
      elseif directive == "endif" then
        table.remove(open)
      elseif line:find("^function OnDriverLateInit%(") then
        defined, wrapped = true, false
      elseif defined and line:find("^OnDriverLateInit = .+:wrapLateInit%(OnDriverLateInit%)%s*$") then
        local inDc = false
        for _, level in ipairs(open) do
          if level.dc == false then
            inDc = false
            break
          end
          inDc = inDc or level.dc == true
        end
        wrapped = inDc
      end
    end
    T.truthy(name .. " wraps its late init, in DriverCentral builds only", wrapped)
  end
end
pipe:close()

T.finish()
