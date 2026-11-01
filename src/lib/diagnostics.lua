--- Cloud Monitoring: an hourly report of the driver's memory use and its largest tables, and a report of each error
--- the driver hits, written to InfluxDB. Only a DriverCentral build carries the server, its token and the two database
--- names, so an OSS build, or any build missing one of them, reports nothing.
---
--- While enabled it owns ON_HANDLER_ERROR, ON_TIMER_ERROR and ON_UNHANDLED_REJECTION, the hooks the vendored
--- dispatchers, timers and deferred call on an error. A driver adds its own points to each report with onReport.

local log = require("lib.logging")
local http = require("lib.http")
local redact = require("lib.redact")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("lib.utils")

--#ifdef DRIVERCENTRAL
local INFLUXDB_URL = "__INFLUXDB_URL__"
local INFLUXDB_TOKEN = "__INFLUXDB_TOKEN__"
local INFLUXDB_METRICS_DB = "__INFLUXDB_METRICS_DB__"
local INFLUXDB_LOGS_DB = "__INFLUXDB_LOGS_DB__"
--#else
local INFLUXDB_URL = ""
local INFLUXDB_TOKEN = ""
local INFLUXDB_METRICS_DB = ""
local INFLUXDB_LOGS_DB = ""
--#endif

local DEFAULT_CENSUS_INTERVAL = ONE_HOUR
local FIRST_REPORT_DELAY = 30 * ONE_SECOND
--- Every instance of a driver is enabled together at boot, so each waits up to this much longer, by its device ID.
local FIRST_REPORT_SPREAD_SECONDS = 270
local CENSUS_MAX_DEPTH = 15
local CENSUS_TOP_N = 20
local CENSUS_THRESHOLD = 100
local CENSUS_NEW_TABLE_MIN_SIZE = 10
local INFLUXDB_TOP_N = 10

--- Paths that should always be recursed into, even if they exceed the CENSUS_THRESHOLD.
--- @type table<string, boolean?>
local CENSUS_ALWAYS_RECURSE = { ["_G"] = true }

local ERROR_RATE_LIMIT = 10
local ERROR_RATE_WINDOW = 60
local MESSAGE_MAX_BYTES = 200
local TRACEBACK_MAX_BYTES = 2000
local POST_TIMEOUT_SECONDS = 2
--- Most points a driver's onReport callback adds to one report, and the longest string value it may send.
local DRIVER_POINTS_MAX = 200
local DRIVER_VALUE_MAX_BYTES = 256

--- Cloud Monitoring's own measurements, which a driver's point cannot use.
--- @type table<string, boolean>
local RESERVED_MEASUREMENTS = { diagnostics = true, census = true, error_log = true }

--- Tag names every point carries, which a driver's point cannot set.
--- @type table<string, boolean>
local RESERVED_TAGS = {
  mac = true,
  device_id = true,
  driver = true,
  version = true,
  os_version = true,
  license_state = true,
  cloud_status = true,
  update_available = true,
}

--- @alias CensusEntry {path: string, size: number, bytes: number}

--- @class DiagnosticsPoint
--- @field measurement string A name of letters, digits and underscores, other than Cloud Monitoring's own.
--- @field fields table<string, number|boolean|string> At least one. Numbers are sent as floats.
--- @field tags? table<string, string|number|boolean> Sent with the tags every point carries.

--- @class DiagnosticsServer
--- @field url string The InfluxDB origin, with no trailing slash.
--- @field token string A token that can write to both databases.
--- @field metricsDb string The database the hourly reports go to.
--- @field logsDb string The database the error reports go to.

--- @class Diagnostics
--- @field _server DiagnosticsServer
--- @field _available boolean Whether this build carries a whole server.
--- @field _enabled boolean
--- @field _firstReportDone boolean Whether the repeating report timer is running.
--- @field _onReport? fun(): DiagnosticsPoint[]|nil The driver's own points for each report.
--- @field _previousCensus table<string, {count: number, bytes: number}?>|nil Map of path -> {count, bytes} from last census.
--- @field _gcAvailable boolean
--- @field _mac string|nil Cached MAC address.
--- @field _deviceId number|nil Cached device ID.
--- @field _driver string|nil Cached driver filename.
--- @field _version string|nil Cached driver version.
--- @field _osVersion string|nil Cached controller OS version.
--- @field _censusInterval number Census timer interval in milliseconds.
--- @field _errorWriteCount number Number of error writes in the current rate window.
--- @field _errorWindowStart number Start time of the current rate window.
--- @field _errorsDropped number Number of errors dropped due to rate limiting in the current window.
--- @field _intervalErrorsReported number Number of error writes since the last metrics write.
--- @field _intervalErrorsDropped number Number of errors dropped due to rate limiting since the last metrics write.
local Diagnostics = {}
Diagnostics.__index = Diagnostics

--- Whether a build secret has a value: a placeholder the build left in place has none.
--- @param value string
--- @return boolean
local function isSet(value)
  return value ~= "" and not value:find("^__[%u%d_]+__$")
end

--- Creates a new Diagnostics instance.
--- @param server? DiagnosticsServer The server to report to; the one the build substituted unless given.
--- @return Diagnostics
function Diagnostics:new(server)
  local instance = setmetatable({}, self)
  instance._server = server
    or { url = INFLUXDB_URL, token = INFLUXDB_TOKEN, metricsDb = INFLUXDB_METRICS_DB, logsDb = INFLUXDB_LOGS_DB }
  instance._available = isSet(instance._server.url)
    and isSet(instance._server.token)
    and isSet(instance._server.metricsDb)
    and isSet(instance._server.logsDb)
  instance._enabled = false
  instance._firstReportDone = false
  instance._previousCensus = nil
  instance._gcAvailable = false
  instance._mac = nil
  instance._deviceId = nil
  instance._driver = nil
  instance._version = nil
  instance._osVersion = nil
  instance._censusInterval = DEFAULT_CENSUS_INTERVAL
  instance._errorWriteCount = 0
  instance._errorWindowStart = 0
  instance._errorsDropped = 0
  instance._intervalErrorsReported = 0
  instance._intervalErrorsDropped = 0
  return instance
end

--- Enables or disables diagnostics.
--- @param enabled boolean
function Diagnostics:setEnabled(enabled)
  if toboolean(enabled) and not self._available then
    log:warn("[DIAG] Cloud Monitoring is not available in this build")
    return
  end
  self._enabled = toboolean(enabled)
  if self._enabled then
    self:_detectGcAvailability()
    self:_cacheTags()
    self:_installHooks()
    self:_startFirstReport()
    log:info(
      "[DIAG] Cloud Monitoring enabled (interval=%dm, gc=%s)",
      self._censusInterval / ONE_MINUTE,
      self._gcAvailable and "available" or "unavailable"
    )
  else
    CancelTimer("Diagnostics")
    CancelTimer("DiagnosticsFirstReport")
    self._firstReportDone = false
    self._previousCensus = nil
    self:_removeHooks()
    log:info("[DIAG] Cloud Monitoring disabled")
  end
end

--- Returns whether diagnostics is enabled.
--- @return boolean
function Diagnostics:isEnabled()
  return self._enabled
end

--- Sets the census interval. Restarts the timer if monitoring is active.
--- @param interval number Interval in milliseconds (e.g. ONE_MINUTE, ONE_HOUR).
function Diagnostics:setCensusInterval(interval)
  self._censusInterval = interval
  if self._enabled and self._firstReportDone then
    self:_startTimer()
  end
end

--- Prints a snapshot (memory and the largest tables) in the Lua output, and sends it when enabled.
function Diagnostics:dumpSnapshot()
  if not self._enabled then
    self:_detectGcAvailability()
    self:_cacheTags()
  end
  log:print("--- Diagnostics Snapshot ---")
  self:_tick(true)
  log:print("--- End Diagnostics Snapshot ---")
end

--- Calls `callback` each time a report goes out, and sends the points it returns with it. The callback replaces
--- any earlier one. Say in the driver's documentation what the points hold; never a name, an address or a credential.
--- @param callback fun(): DiagnosticsPoint[]|nil
function Diagnostics:onReport(callback)
  self._onReport = callback
end

--- Captures an error and writes it directly to the logs database.
--- Rate-limited to ERROR_RATE_LIMIT writes per ERROR_RATE_WINDOW seconds.
--- @param message string
--- @param traceback string|nil
--- @param source string
function Diagnostics:captureError(message, traceback, source)
  if not self._enabled then
    return
  end

  message = tostring(message or "unknown error")
  traceback = tostring(traceback or "")
  source = tostring(source or "unknown")

  local now = os.time()

  -- Reset rate window if expired
  if now - self._errorWindowStart >= ERROR_RATE_WINDOW then
    if self._errorsDropped > 0 then
      log:warn("[DIAG] Rate limit: dropped %d errors in last window", self._errorsDropped)
    end
    self._errorWriteCount = 0
    self._errorWindowStart = now
    self._errorsDropped = 0
  end

  -- Rate limit
  if self._errorWriteCount >= ERROR_RATE_LIMIT then
    self._errorsDropped = self._errorsDropped + 1
    self._intervalErrorsDropped = self._intervalErrorsDropped + 1
    return
  end
  self._errorWriteCount = self._errorWriteCount + 1
  self._intervalErrorsReported = self._intervalErrorsReported + 1

  self:_writeErrorLog(message, traceback, source, now)
end

--- Splits an error into its message and traceback. An HTTP rejection from lib.http is a table whose `error` is
--- already redacted.
--- @param err any What the dispatcher, timer or rejection passed.
--- @return string message
--- @return string traceback
local function splitError(err)
  if type(err) == "table" then
    err = type(err.error) == "string" and err.error or type(err.message) == "string" and err.message or "a table"
  end
  local text = tostring(err)
  local marker = "\nstack traceback:\n"
  local at = text:find(marker, 1, true)
  if at then
    return text:sub(1, at - 1), text:sub(at + #marker)
  end
  return text, ""
end

--- Packs every value, nils included.
--- @return table
local function pack(...)
  return { n = select("#", ...), ... }
end

--- Wraps a function no dispatcher runs, capturing its errors. The wrapped function returns nothing when `fn` raises.
--- @param fn function
--- @param source string
--- @return function
function Diagnostics:wrap(fn, source)
  return function(...)
    local args = pack(...)
    local results = pack()
    local success = xpcall(function()
      results = pack(fn(unpack(args, 1, args.n)))
    end, function(err)
      local full = debug.traceback(err, 2)
      local message, traceback = splitError(full)
      self:captureError(message, traceback, source)
      log:error("[DIAG] Error in %s: %s", source, tostring(full))
    end)
    if success then
      return unpack(results, 1, results.n)
    end
  end
end

-- Private methods ---------------------------------------------------------

--- Detects whether collectgarbage is available.
--- @private
function Diagnostics:_detectGcAvailability()
  local success, _ = pcall(function()
    return collectgarbage("count")
  end)
  self._gcAvailable = success
end

--- Caches the MAC address and device ID tags.
--- @private
function Diagnostics:_cacheTags()
  local success, mac = pcall(function()
    return C4:GetUniqueMAC()
  end)
  self._mac = success and mac or "unknown"

  local ok, id = pcall(function()
    return C4:GetDeviceID()
  end)
  self._deviceId = ok and tonumber(id) or 0

  local dOk, driver = pcall(function()
    return C4:GetDriverFileName()
  end)
  self._driver = dOk and driver or "unknown"

  local vOk, version = pcall(function()
    return C4:GetDeviceData(C4:GetDeviceID(), "version")
  end)
  self._version = vOk and version or "unknown"

  local osOk, osVersion = pcall(function()
    return Select(C4:GetVersionInfo(), "version")
  end)
  self._osVersion = osOk and osVersion or "unknown"
end

--- Installs global error hooks so handler, timer, and promise errors are captured.
--- @private
function Diagnostics:_installHooks()
  ON_HANDLER_ERROR = function(source, err)
    local message, traceback = splitError(err)
    self:captureError(message, traceback, source)
  end

  ON_TIMER_ERROR = function(timerId, err)
    local message, traceback = splitError(err)
    self:captureError(message, traceback, type(timerId) == "string" and ("Timer." .. timerId) or "Timer")
  end

  ON_UNHANDLED_REJECTION = function(err)
    local message, traceback = splitError(err)
    self:captureError(message, traceback, "UnhandledRejection")
  end
end

--- Removes global error hooks.
--- @private
function Diagnostics:_removeHooks()
  ON_HANDLER_ERROR = nil
  ON_TIMER_ERROR = nil
  ON_UNHANDLED_REJECTION = nil
end

--- Starts the repeating census timer.
--- @private
function Diagnostics:_startTimer()
  SetTimer("Diagnostics", self._censusInterval, function()
    if not self._enabled then
      return
    end
    self:_tick()
  end, true)
end

--- How long after enable the first report waits. Spread by device ID, not math.random: every driver instance's
--- Lua starts from the same random seed.
--- @private
--- @return number delay Milliseconds.
function Diagnostics:_firstReportDelay()
  local spread = math.floor(tonumber(self._deviceId) or 0) * 7919 % FIRST_REPORT_SPREAD_SECONDS
  return FIRST_REPORT_DELAY + spread * ONE_SECOND
end

--- Schedules the first report, which starts the repeating one.
--- @private
function Diagnostics:_startFirstReport()
  CancelTimer("Diagnostics")
  self._firstReportDone = false
  SetTimer("DiagnosticsFirstReport", self:_firstReportDelay(), function()
    if not self._enabled then
      return
    end
    self:_tick()
    self._firstReportDone = true
    self:_startTimer()
  end)
end

--- Runs one full diagnostics tick: census + compare + log, and the report when enabled.
--- @private
--- @param verbose boolean|nil When true, logs at print level (for snapshots). Otherwise uses trace/debug.
function Diagnostics:_tick(verbose)
  local out = verbose and log.LogLevel.PRINT or log.LogLevel.TRACE
  local outWarn = verbose and log.LogLevel.PRINT or log.LogLevel.DEBUG

  -- Memory
  local memoryKB = nil
  if self._gcAvailable then
    local success, count = pcall(collectgarbage, "count")
    if success then
      memoryKB = tonumber(count)
    end
  end

  -- Census
  local census = self:_tableCensus()

  -- Build sorted list by entry count
  local sorted = {} --- @type CensusEntry[]
  for path, info in pairs(census) do
    table.insert(sorted, { path = path, size = info.count, bytes = info.bytes })
  end
  table.sort(sorted, function(a, b)
    return a.size > b.size
  end)

  -- Build sorted list by string bytes
  local sortedByBytes = {} --- @type CensusEntry[]
  for i = 1, #sorted do
    sortedByBytes[i] = sorted[i]
  end
  table.sort(sortedByBytes, function(a, b)
    return a.bytes > b.bytes
  end)

  -- Log top 20 largest by entry count
  log:log(
    out,
    "[CENSUS] Total tables found: %d%s",
    #sorted,
    memoryKB and string.format(", Lua memory: %.1f KB", memoryKB) or ""
  )
  for i = 1, math.min(CENSUS_TOP_N, #sorted) do
    local entry = sorted[i]
    if entry then
      local level = entry.size > CENSUS_THRESHOLD and outWarn or out
      log:log(level, "[CENSUS] #%d %s = %d entries, %d str bytes", i, entry.path, entry.size, entry.bytes)
    end
  end

  -- Log top 10 by string bytes (surfaces large string buffers)
  for i = 1, math.min(INFLUXDB_TOP_N, #sortedByBytes) do
    local entry = sortedByBytes[i]
    if entry and entry.bytes > 0 then
      log:log(out, "[CENSUS:BYTES] #%d %s = %d str bytes (%d entries)", i, entry.path, entry.bytes, entry.size)
    end
  end

  -- Growth detection (compare to previous census)
  if self._previousCensus then
    local growers = {}
    for path, info in pairs(census) do
      local prev = self._previousCensus[path]
      if prev then
        local countDelta = info.count - prev.count
        local bytesDelta = info.bytes - prev.bytes
        if countDelta > 0 or bytesDelta > 0 then
          table.insert(growers, {
            path = path,
            prevCount = prev.count,
            count = info.count,
            countDelta = countDelta,
            prevBytes = prev.bytes,
            bytes = info.bytes,
            bytesDelta = bytesDelta,
          })
        end
      elseif not prev and info.count > CENSUS_NEW_TABLE_MIN_SIZE then
        log:log(out, "[CENSUS] New table: %s = %d entries, %d str bytes", path, info.count, info.bytes)
      end
    end
    if #growers > 0 then
      table.sort(growers, function(a, b)
        return a.bytesDelta > b.bytesDelta
      end)
      for _, g in ipairs(growers) do
        log:log(
          outWarn,
          "[CENSUS] GREW: %s entries %d->%d (+%d), bytes %d->%d (+%d)",
          g.path,
          g.prevCount,
          g.count,
          g.countDelta,
          g.prevBytes,
          g.bytes,
          g.bytesDelta
        )
      end
    end
  end

  local driverLines = self:_driverLines(os.time())
  for _, line in ipairs(driverLines) do
    log:log(out, "[DIAG] %s", line)
  end

  if self._enabled then
    self:_writeMetrics(memoryKB, #sorted, sorted, sortedByBytes, driverLines)
  end

  -- Reset error counters so they act as per-interval counters
  self._intervalErrorsReported = 0
  self._intervalErrorsDropped = 0

  -- Store for next comparison
  self._previousCensus = census
end

--- Whether a name could be a code name rather than data: no run of four digits, and not long with several digits
--- the way a token or a serial is.
--- @param name string
--- @return boolean
local function codeLike(name)
  local _, digits = name:gsub("%d", "")
  return not name:find("%d%d%d%d") and not (#name >= 16 and digits >= 3)
end

--- How a table key reads in a census path. Keys are often data (an EUI, an address, a serial, a room name), so only
--- integers and keys shaped like code names are kept, and any other key reads `[?]`. Tables whose paths read the
--- same are counted together.
--- @param key any
--- @param parentPath string
--- @return string
local function pathKey(key, parentPath)
  if type(key) == "number" then
    return key == math.floor(key) and math.abs(key) < 2 ^ 53 and string.format("[%d]", key) or "[?]"
  end
  if type(key) == "string" and codeLike(key) then
    if #key <= 32 and key:find("^[%a_][%w_]*$") then
      return "." .. key
    end
    -- package.loaded is keyed by module name, e.g. "drivers-common-public.global.timer".
    if parentPath == "_G.package.loaded" and #key <= 64 and key:find("^[%a_][%w_%.%-]*$") then
      return "." .. key
    end
  end
  return "[?]"
end

--- The error's source as sent: a dispatcher prefix such as `OPC` or `Timer`, then a name, kept only when it reads
--- like one a driver defines. A timer's name can carry data.
--- @param source string
--- @return string
local function sourceTag(source)
  local prefix, name = source:match("^([%a_][%w_]*)%.(.+)$")
  if not prefix then
    prefix, name = source, nil
  end
  if #prefix > 32 or not prefix:find("^[%a_][%w_]*$") then
    return "?"
  end
  if name == nil then
    return prefix
  end
  local readable = #name <= 48 and codeLike(name) and name:find("^[%a_][%w_ %-%(%)]*$")
  local binding = #name <= 6 and name:find("^%d+$")
  return prefix .. "." .. ((readable or binding) and name or "?")
end

--- Recursively walks _G and returns a map of path -> {count, bytes} for each table.
--- @private
--- @return table<string, {count: number, bytes: number}>
function Diagnostics:_tableCensus()
  local results = {}
  local seen = { [self] = true }

  local function walk(tbl, path, depth)
    if depth > CENSUS_MAX_DEPTH then
      return
    end
    if seen[tbl] then
      return
    end
    seen[tbl] = true

    local count = 0
    local bytes = 0
    for k, v in pairs(tbl) do
      count = count + 1
      if type(k) == "string" then
        bytes = bytes + #k
      end
      if type(v) == "string" then
        bytes = bytes + #v
      end
    end

    if count > 0 then
      local entry = results[path]
      if entry then
        entry.count = entry.count + count
        entry.bytes = entry.bytes + bytes
      else
        results[path] = { count = count, bytes = bytes }
      end
    end

    -- Don't recurse into large tables unless they're on the allow list
    if count > CENSUS_THRESHOLD and not CENSUS_ALWAYS_RECURSE[path] then
      return
    end

    for k, v in pairs(tbl) do
      if type(v) == "table" and not seen[v] then
        walk(v, path .. pathKey(k, path), depth + 1)
      end
    end
  end

  walk(_G, "_G", 0)
  return results
end

--- Cuts `text` to at most `max` bytes, at a UTF-8 character boundary.
--- @param text string
--- @param max number
--- @return string
local function cap(text, max)
  if #text <= max then
    return text
  end
  local cut = max - 3
  while cut > 0 and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return text:sub(1, cut) .. "..."
end

--- An IPv4 address, or the text unchanged when a part is out of range (a version number, say).
--- @param text string
--- @return string
local function maskIpv4(text)
  for part in text:gmatch("%d+") do
    if #part > 3 or tonumber(part) > 255 then
      return text
    end
  end
  return "<ip>"
end

--- JSON.lua's decode errors that end with the whole text after a colon, with no byte position to cut at.
--- @type string[]
local JSON_QUOTING_ERRORS = {
  "HTML passed to JSON:decode%(%)",
  "JSON package groks only UTF%-8, sorry",
  "unexpected end of string",
}

--- Removes from an error message, or a traceback, what could be a credential, an address or an ID.
--- @param text string
--- @param max number
--- @return string
local function scrub(text, max)
  -- JSON.lua's decode errors end with the whole text that failed to decode.
  text = text:gsub("( at byte %d+) of: .*$", "%1")
  for _, message in ipairs(JSON_QUOTING_ERRORS) do
    text = text:gsub("(" .. message .. "): .*$", "%1")
  end
  text = redact.value(text)
  text = text:gsub("%a[%w+.-]*://[^%s'\"<>]+", "<url>")
  text = text:gsub("[%w._%%+-]+@[%w-]+%.[%w.-]+", "<email>")
  text = text:gsub("%x%x[:-]%x%x[:-]%x%x[:-]%x%x[:-]%x%x[:-]%x%x[%x:-]*", "<id>")
  text = text:gsub("%d+%.%d+%.%d+%.%d+", maskIpv4)
  text = text:gsub("[%x:]+", function(run)
    local _, colons = run:gsub(":", "")
    return (colons >= 3 and run:find("%x")) and "<ip>" or run
  end)
  text = text:gsub("[%w+/=_-]+", function(run)
    local hex = run:match("^0[xX](%x+)$") or run:match("^%x+$")
    if #run >= 20 and run:find("%d") and run:find("%a") then
      return "<redacted>"
    elseif hex and #hex >= 12 then
      return "<id>"
    end
    return run
  end)
  return cap(text, max)
end

--- Escapes a string value for InfluxDB line protocol.
--- @param s string
--- @return string
local function escapeInfluxString(s)
  s = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r")
  return '"' .. s .. '"'
end

--- Escapes a tag value for InfluxDB line protocol.
--- @param s string
--- @return string
local function escapeInfluxTag(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub("[\r\n]", " "):gsub(",", "\\,"):gsub("=", "\\="):gsub(" ", "\\ "))
end

--- Computes the current license_state tag from global DC_X.
--- @return string
local function getLicenseState()
  ---@diagnostic disable-next-line: undefined-global
  local dcx = tonumber(DC_X)
  if dcx == nil then
    return "uninitialized"
  elseif dcx == 1 then
    return "activated"
  elseif dcx < 0 then
    return "trial"
  elseif dcx == 0 then
    return "unlicensed"
  else
    return "unknown"
  end
end

--- Normalizes the Cloud Status property to a tag value.
--- @return string
--- @return boolean
local function getCloudStatus()
  local ok, status = pcall(function()
    return Properties["Cloud Status"]
  end)
  if not ok or status == nil then
    return "unknown", false
  end

  -- "Update Available, " is prepended by the cloud driver's getAS() and only
  -- appears on license/activation states, never on error strings.
  local rest = status:match("^Update Available, (.+)$")
  local updateAvailable = rest ~= nil
  if updateAvailable then
    status = rest
  end

  -- License/activation states (from cloud driver STATES.AS)
  if status == "License Activated" then
    return "activated", updateAvailable
  elseif status:sub(1, 13) == "Trial Running" then
    return "trial_running", updateAvailable
  elseif status == "Showroom License Activated" then
    return "showroom", updateAvailable
  elseif status == "Connected to Cloud" then
    return "free", updateAvailable
  elseif status == "Trial Expired" then
    return "trial_expired", updateAvailable
  elseif status == "Invalid License" then
    return "invalid_license", updateAvailable

  -- Client initialization errors
  elseif status == "Error: missing PID" then
    return "missing_pid", false
  elseif status == "Error: missing DID" then
    return "missing_device_id", false
  elseif status == 'Missing property "Automatic Updates"' then
    return "missing_automatic_updates_property", false
  elseif status == "Error: Could not get OS_VERSION" then
    return "missing_os_version", false
  elseif status == "Error: 6" then
    return "missing_mac_address", false
  elseif status == "Error: 7" then
    return "missing_driver_version", false
  elseif status == "Error: 3" then
    return "encode_failed", false
  elseif status == "Error: 4" then
    return "decode_failed", false

  -- Cloud driver errors
  elseif
    status == "DriverCentral.io Cloud driver not found"
    or status == "Cloud driver removed, please install cloud driver."
  then
    return "cloud_driver_not_found", false
  elseif status == "Error: more than one cloud driver installed" then
    return "too_many_cloud_drivers", false
  elseif status == "Error: no cloud version" then
    return "no_cloud_version", false
  elseif status == "Outdated cloud version" then
    return "outdated_cloud_version", false
  elseif status == "Error: 1" then
    return "unknown_cloud_version", false
  elseif status == "Error: 2" then
    return "unknown_cloud_driver", false
  else
    return "unknown", false
  end
end

--- The tags every point carries.
--- @private
--- @return string
function Diagnostics:_tags()
  local cloudStatus, updateAvailable = getCloudStatus()
  return string.format(
    "mac=%s,device_id=%s,driver=%s,version=%s,os_version=%s,license_state=%s,cloud_status=%s,update_available=%s",
    escapeInfluxTag(self._mac or "unknown"),
    escapeInfluxTag(tostring(self._deviceId or 0)),
    escapeInfluxTag(self._driver or "unknown"),
    escapeInfluxTag(self._version or "unknown"),
    escapeInfluxTag(self._osVersion or "unknown"),
    escapeInfluxTag(getLicenseState()),
    escapeInfluxTag(cloudStatus),
    escapeInfluxTag(tostring(updateAvailable))
  )
end

--- Writes metrics and census data to the metrics database.
--- @private
--- @param memoryKB number|nil
--- @param totalTables number
--- @param sorted CensusEntry[] Sorted by entry count descending.
--- @param sortedByBytes CensusEntry[] Sorted by string bytes descending.
--- @param driverLines string[] The driver's own points, as line protocol.
function Diagnostics:_writeMetrics(memoryKB, totalTables, sorted, sortedByBytes, driverLines)
  local timestamp = os.time()
  local tags = self:_tags()

  -- diagnostics measurement
  local fields = {}
  if memoryKB then
    table.insert(fields, string.format("memory_kb=%.2f", memoryKB))
  end
  table.insert(fields, string.format("global_count=%di", TableLength(_G)))
  table.insert(fields, string.format("total_tables=%di", totalTables))
  table.insert(fields, string.format("errors_reported=%di", self._intervalErrorsReported))
  table.insert(fields, string.format("errors_dropped=%di", self._intervalErrorsDropped))

  local lines = {}
  table.insert(lines, string.format("diagnostics,%s %s %d", tags, table.concat(fields, ","), timestamp))

  -- census measurement: one point per table, path as tag
  -- Top N by entry count
  local reported = {}
  for i = 1, math.min(INFLUXDB_TOP_N, #sorted) do
    local entry = sorted[i]
    if entry then
      reported[entry.path] = true
      table.insert(
        lines,
        string.format(
          "census,%s,path=%s size=%di,bytes=%di,rank=%di %d",
          tags,
          escapeInfluxTag(entry.path),
          entry.size,
          entry.bytes,
          i,
          timestamp
        )
      )
    end
  end

  -- Top N by string bytes (skip already reported)
  for i = 1, math.min(INFLUXDB_TOP_N, #sortedByBytes) do
    local entry = sortedByBytes[i]
    if entry and entry.bytes > 0 and not reported[entry.path] then
      reported[entry.path] = true
      table.insert(
        lines,
        string.format(
          "census,%s,path=%s size=%di,bytes=%di,rank=%di %d",
          tags,
          escapeInfluxTag(entry.path),
          entry.size,
          entry.bytes,
          INFLUXDB_TOP_N + i,
          timestamp
        )
      )
    end
  end

  for _, line in ipairs(driverLines) do
    table.insert(lines, line)
  end

  self:_post(table.concat(lines, "\n"), self._server.metricsDb)
end

--- Whether `name` can be a measurement, tag or field name.
--- @param name any
--- @return boolean
local function isName(name)
  return type(name) == "string" and #name <= 64 and name:find("^[%a_][%w_]*$") ~= nil
end

--- A field value as line protocol, or nil for one that cannot be sent (a non-finite number, a table).
--- @param value any
--- @return string|nil
local function fieldValue(value)
  if type(value) == "boolean" then
    return tostring(value)
  elseif type(value) == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil
    end
    return string.format("%.15g", value)
  elseif type(value) == "string" then
    return escapeInfluxString(cap(value, DRIVER_VALUE_MAX_BYTES))
  end
  return nil
end

--- One of the driver's points as line protocol, or nil and why it is not sent.
--- @param point any
--- @param tags string The tags every point carries.
--- @param timestamp number
--- @return string|nil line
--- @return string|nil why
local function driverLine(point, tags, timestamp)
  if type(point) ~= "table" or not isName(point.measurement) then
    return nil, "a point needs a measurement of letters, digits and underscores"
  end
  if RESERVED_MEASUREMENTS[point.measurement] then
    return nil, point.measurement .. " is one of Cloud Monitoring's own measurements"
  end
  local tagParts = { tags }
  local tagNames = {}
  for name in pairs(type(point.tags) == "table" and point.tags or {}) do
    table.insert(tagNames, name)
  end
  table.sort(tagNames, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, name in ipairs(tagNames) do
    local value = point.tags[name]
    if not isName(name) or RESERVED_TAGS[name] then
      return nil, point.measurement .. ": tag " .. tostring(name) .. " is not one a driver can set"
    end
    local text = type(value) == "string" and value
      or (type(value) == "number" or type(value) == "boolean") and tostring(value)
    if text and text ~= "" then
      table.insert(tagParts, name .. "=" .. escapeInfluxTag(cap(text, DRIVER_VALUE_MAX_BYTES)))
    end
  end
  local fieldParts = {}
  local fieldNames = {}
  for name in pairs(type(point.fields) == "table" and point.fields or {}) do
    table.insert(fieldNames, name)
  end
  table.sort(fieldNames, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, name in ipairs(fieldNames) do
    local value = isName(name) and fieldValue(point.fields[name])
    if not value then
      return nil, point.measurement .. ": field " .. tostring(name) .. " cannot be sent"
    end
    table.insert(fieldParts, name .. "=" .. value)
  end
  if #fieldParts == 0 then
    return nil, point.measurement .. ": a point needs at least one field"
  end
  return string.format(
    "%s,%s %s %d",
    point.measurement,
    table.concat(tagParts, ","),
    table.concat(fieldParts, ","),
    timestamp
  )
end

--- The points the driver's onReport callback returns, as line protocol. A point that cannot be sent is left out
--- with a warning, and so is everything when the callback raises.
--- @private
--- @param timestamp number
--- @return string[]
function Diagnostics:_driverLines(timestamp)
  local lines = {}
  if not self._onReport then
    return lines
  end
  local ok, points = pcall(self._onReport)
  if not ok then
    log:warn("[DIAG] The driver's report callback failed: %s", tostring(points))
    return lines
  end
  if type(points) ~= "table" then
    return lines
  end
  local tags = self:_tags()
  for i, point in ipairs(points) do
    if i > DRIVER_POINTS_MAX then
      log:warn("[DIAG] Sent the first %d of the driver's %d points", DRIVER_POINTS_MAX, #points)
      break
    end
    local line, why = driverLine(point, tags, timestamp)
    if line then
      table.insert(lines, line)
    else
      log:warn("[DIAG] Not sent: %s", why)
    end
  end
  return lines
end

--- Writes a single error log entry to the logs database.
--- @private
--- @param message string
--- @param traceback string
--- @param source string
--- @param timestamp number
function Diagnostics:_writeErrorLog(message, traceback, source, timestamp)
  local line = string.format(
    "error_log,%s,source=%s message=%s,traceback=%s %d",
    self:_tags(),
    escapeInfluxTag(sourceTag(source)),
    escapeInfluxString(scrub(message, MESSAGE_MAX_BYTES)),
    escapeInfluxString(scrub(traceback, TRACEBACK_MAX_BYTES)),
    timestamp
  )
  self:_post(line, self._server.logsDb)
end

--- Posts line protocol to a database. The only place a report leaves the controller.
--- @private
--- @param body string
--- @param database string
function Diagnostics:_post(body, database)
  local url = string.format("%s/api/v2/write?bucket=%s&precision=s", self._server.url, database)

  local success, err = pcall(function()
    http
      :post(url, body, {
        ["Authorization"] = "Bearer " .. self._server.token,
        ["Content-Type"] = "text/plain; charset=utf-8",
      }, { timeout = POST_TIMEOUT_SECONDS })
      :next(function(response)
        log:debug("[DIAG] InfluxDB write OK (%s)", response.code)
      end, function(response)
        log:debug("[DIAG] InfluxDB write failed (%s)", type(response) == "table" and response.code or "no response")
      end)
  end)
  if not success then
    log:debug("[DIAG] InfluxDB post error: %s", tostring(err))
  end
end

--- Internal. Exposed only so the tests can exercise the scrubbing, which is otherwise file-local. Not part of the API.
Diagnostics._scrub = scrub
Diagnostics._splitError = splitError
Diagnostics._pathKey = pathKey
Diagnostics._sourceTag = sourceTag

return Diagnostics:new()
