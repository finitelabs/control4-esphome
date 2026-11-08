-- lib.http's request options for a fetch whose answer can't be trusted: a body cap that stops the
-- transfer as the body passes it, a headers hook that refuses an answer before its body, a URL kept
-- out of every log line, and a connect timeout. A request without them still goes through urlDo.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_http_limits.lua

local T = require("testlib")

require("c4_shim")
local http = require("lib.http")
local log = require("lib.logging")

-- urlDo otherwise builds it from driver.xml fields the shim does not model.
USER_AGENT = "test"

--- Each C4:url() transfer made, newest last.
local transfers = {}

--- Answer every C4:url() transfer with `script`: its responses in order, each with code, headers and
--- body chunks, then `script.fail` ({ errCode, errMsg }) or success. Hooks run as the controller runs
--- them, and the first one that returns true stops the transfer. A function gives each URL's script.
local function serve(scripts)
  C4.url = function()
    local t = { hooks = {}, chunks = 0 }
    transfers[#transfers + 1] = t
    function t:SetOptions(options)
      self.options = options
      return self
    end
    function t:OnHeaders(fn)
      self.hooks.headers = fn
      return self
    end
    function t:OnBodyChunk(fn)
      self.hooks.chunk = fn
      return self
    end
    function t:OnDone(fn)
      self.hooks.done = fn
      return self
    end
    local function run(self, method, url, data, headers)
      self.method, self.url, self.data, self.headers = method, url, data, headers
      local script = type(scripts) == "function" and scripts(url) or scripts
      local responses = {}
      for _, r in ipairs(script) do
        local response = { code = r.code, headers = r.headers or {} }
        responses[#responses + 1] = response
        if self.hooks.headers and self.hooks.headers(self, response) then
          return self.hooks.done(self, responses, -1, nil)
        end
        local body = {}
        for _, chunk in ipairs(r.chunks or {}) do
          self.chunks = self.chunks + 1
          if self.hooks.chunk then
            if self.hooks.chunk(self, response, chunk) then
              return self.hooks.done(self, responses, -1, nil)
            end
          else
            body[#body + 1] = chunk
          end
        end
        if not self.hooks.chunk then
          response.body = table.concat(body)
        end
      end
      if script.fail then
        return self.hooks.done(self, responses, script.fail[1], script.fail[2])
      end
      self.hooks.done(self, responses, 0, nil)
    end
    function t:Get(url, headers)
      run(self, "GET", url, nil, headers)
      return self
    end
    function t:Post(url, data, headers)
      run(self, "POST", url, data, headers)
      return self
    end
    function t:Put(url, data, headers)
      run(self, "PUT", url, data, headers)
      return self
    end
    function t:Delete(url, headers)
      run(self, "DELETE", url, nil, headers)
      return self
    end
    function t:Custom(url, method, data, headers)
      run(self, method, url, data, headers)
      return self
    end
    return t
  end
end

--- Send a request and report how it settled.
local function send(method, url, data, options)
  local result = { settled = false }
  http:request(method, url, data, nil, options):next(function(response)
    result.settled, result.ok, result.value = true, true, response
  end, function(err)
    result.settled, result.ok, result.value = true, false, err
  end)
  return result
end

local function get(url, options)
  return send("GET", url, nil, options)
end

local function last()
  return transfers[#transfers]
end

local URL = "https://example.invalid/pictures/cam.jpg"

--- `n` chunks of `size` bytes.
local function chunks(n, size)
  local list = {}
  for i = 1, n do
    list[i] = string.rep(string.char(64 + i), size)
  end
  return list
end

T.section("a request with no new option goes through urlDo, as before")
do
  serve({ { code = 200, headers = { ["Content-Type"] = "text/plain" }, chunks = { "hello" } } })
  local r = get(URL)
  T.truthy("it resolves", r.ok)
  T.eq("with the whole body", r.value.body, "hello")
  T.eq("and its URL", r.value.url, URL)
  T.falsy("no headers hook is set", last().hooks.headers)
  T.falsy("no chunk hook either", last().hooks.chunk)
  T.eq("the timeout defaults to 30", last().options.timeout, 30)

  serve({ { code = 404, chunks = { "missing" } } })
  r = get(URL)
  T.eq(
    "a failure's error reads as it did",
    r.value.error,
    "HTTP GET request to " .. URL .. " failed with status code 404"
  )
  T.eq("and keeps the URL", r.value.url, URL)
end

T.section("connect_timeout reaches the controller, at most the timeout")
do
  serve({ { code = 200, chunks = { "ok" } } })
  get(URL, { timeout = 20, connect_timeout = 10 })
  T.eq("beside the timeout", { last().options.timeout, last().options.connect_timeout }, { 20, 10 })
  get(URL, { timeout = 5, connect_timeout = 10 })
  T.eq("cut to the timeout", last().options.connect_timeout, 5)
  get(URL, { connect_timeout = 0 })
  T.eq("left off for 0, which curl reads as 300 seconds", last().options.connect_timeout, nil)
  get(URL, { connect_timeout = 10, maxBytes = 100 })
  T.eq("and the same on a capped request", last().options.connect_timeout, 10)
  T.eq("which never hands the controller the library's own options", last().options.maxBytes, nil)
end

T.section("maxBytes stops the transfer as soon as the body passes it")
do
  serve({ { code = 200, headers = { ["Content-Type"] = "image/jpeg" }, chunks = chunks(10, 100) } })
  local r = get(URL, { maxBytes = 250 })
  T.falsy("it rejects", r.ok)
  T.truthy("as too large", r.value.tooLarge)
  T.eq("after the chunk that passed it, of ten", last().chunks, 3)
  T.eq("holding none of the body", r.value.body, "")
  T.eq("and says why", r.value.error, "HTTP GET request to " .. URL .. " stopped: its body passed 250 bytes")
  T.eq("with the answer's status", r.value.code, 200)

  r = get(URL, { maxBytes = 1000 })
  T.truthy("a body of exactly the cap is kept", r.ok)
  T.eq("whole, from its chunks", #r.value.body, 1000)

  serve({ { code = 200, headers = { ["Content-Length"] = "5000" }, chunks = chunks(50, 100) } })
  r = get(URL, { maxBytes = 1000 })
  T.truthy("a Content-Length over the cap is refused", r.value.tooLarge)
  T.eq("before any of the body arrives", last().chunks, 0)
end

T.section("a redirect's body doesn't count toward the cap, and onHeaders sees only the answer")
do
  local seen = {}
  serve({
    { code = 302, headers = { Location = "/b.jpg", ["Content-Type"] = "text/html" }, chunks = chunks(3, 100) },
    { code = 200, headers = { ["Content-Type"] = "image/png" }, chunks = chunks(2, 100) },
  })
  local r = get(URL, {
    maxBytes = 250,
    onHeaders = function(code, headers)
      seen[#seen + 1] = { code, headers["Content-Type"] }
    end,
  })
  T.truthy("it resolves", r.ok)
  T.eq("with the answer's body only", #r.value.body, 200)
  T.eq("onHeaders saw the answer, not the redirect", seen, { { 200, "image/png" } })
end

T.section("onHeaders refuses an answer before its body")
do
  local function refuse(code, headers)
    if code >= 400 then
      return "status"
    end
    if (tonumber(headers["Content-Length"]) or 0) > 1000 then
      return { why = "length" }
    end
    if (headers["Content-Type"] or ""):match("^text/html") then
      return true
    end
  end
  serve({ { code = 404, headers = { ["Content-Type"] = "text/html" }, chunks = chunks(5, 100) } })
  local r = get(URL, { onHeaders = refuse })
  T.eq("by its status, rejecting with what the hook returned", r.value.refused, "status")
  T.eq("and the status", r.value.code, 404)
  T.eq("its body never arrives", last().chunks, 0)
  T.eq("the error says so", r.value.error, "HTTP GET request to " .. URL .. " refused: status")

  serve({ { code = 200, headers = { ["Content-Length"] = "4096" }, chunks = chunks(5, 100) } })
  r = get(URL, { onHeaders = refuse })
  T.eq("by its Content-Length", r.value.refused, { why = "length" })
  T.eq("before its body", last().chunks, 0)

  serve({ { code = 200, headers = { ["Content-Type"] = "text/html; charset=utf-8" }, chunks = chunks(5, 100) } })
  r = get(URL, { onHeaders = refuse })
  T.eq("by its Content-Type", r.value.refused, true)
  T.eq("before its body", last().chunks, 0)

  serve({ { code = 200, headers = { ["Content-Type"] = "image/png" }, chunks = { "png" } } })
  r = get(URL, { onHeaders = refuse })
  T.truthy("an answer it returns nothing for resolves", r.ok)
  T.eq("with its body", r.value.body, "png")
  r = get(URL, {
    onHeaders = function()
      return false
    end,
  })
  T.truthy("and false refuses nothing", r.ok)
end

T.section("an onHeaders that raises stops the transfer and fails the request")
do
  serve({ { code = 200, chunks = chunks(5, 100) } })
  local r = get(URL, {
    onHeaders = function()
      error("hook broke", 0)
    end,
  })
  T.falsy("it rejects", r.ok)
  T.eq("before the body", last().chunks, 0)
  T.contains("naming the hook's error", r.value.error, "onHeaders raised hook broke")
end

T.section("a capped request sends and decodes as urlDo does")
do
  serve({ { code = 200, headers = { ["Content-Type"] = "application/json" }, chunks = { '{"a":', "1}" } } })
  local r = send("POST", URL, { b = 2 }, { maxBytes = 100 })
  T.eq("a JSON answer is decoded", r.value.body, { a = 1 })
  T.eq("a table body is sent as JSON", last().data, '{"b":2}')
  T.eq("typed", last().headers["Content-Type"], "application/json")
  T.eq("with the User-Agent", last().headers["User-Agent"], "test")
  T.eq(
    "and the controller's defaults",
    { last().options.cookies_enable, last().options.fail_on_error },
    { true, false }
  )

  serve({ { code = 200, headers = { ["Content-Type"] = "application/json" }, chunks = { "<html>" } } })
  T.eq("a body that isn't JSON is wrapped, as urlDo wraps it", get(URL, { maxBytes = 100 }).value.body, { "<html>" })

  serve({ { code = 200, chunks = { "x" } } })
  send("PATCH", URL, "x", { maxBytes = 100 })
  T.eq("another method is a custom request", last().method, "PATCH")
end

T.section("maxRedirects follows a redirect the controller hands back")
do
  local base = "https://example.invalid/pictures/"
  local function hop(location, code)
    return { { code = code or 302, headers = { Location = location }, chunks = { "<html>moved</html>" } } }
  end
  local jpeg = { { code = 200, headers = { ["Content-Type"] = "image/jpeg" }, chunks = { "\255\216\255\0", "\1\2" } } }
  local routes = {
    [base .. "cam.jpg"] = hop("next.jpg"),
    [base .. "next.jpg"] = hop("/top.jpg"),
    ["https://example.invalid/top.jpg"] = hop("//cdn.example.invalid/a.jpg"),
    ["https://cdn.example.invalid/a.jpg"] = hop("http://cdn.example.invalid/b.jpg", 301),
    ["http://cdn.example.invalid/b.jpg"] = jpeg,
  }
  serve(function(url)
    return routes[url] or hop("ftp://example.invalid/x")
  end)
  local first = #transfers
  local r = send("GET", base .. "cam.jpg", nil, { maxRedirects = 4, maxBytes = 100 })
  T.truthy("it resolves", r.ok)
  T.eq("binary-safe, with the last answer's body", r.value.body, "\255\216\255\0\1\2")
  T.eq("and the URL it came from", r.value.url, "http://cdn.example.invalid/b.jpg")
  local followed = {}
  for i = first + 1, #transfers do
    followed[#followed + 1] = transfers[i].url
  end
  T.eq("relative, root, scheme-relative and absolute locations, each a transfer", followed, {
    base .. "cam.jpg",
    base .. "next.jpg",
    "https://example.invalid/top.jpg",
    "https://cdn.example.invalid/a.jpg",
    "http://cdn.example.invalid/b.jpg",
  })
  T.eq("each with the request's options", last().options.timeout, 30)

  r = send("GET", base .. "cam.jpg", nil, { maxRedirects = 3 })
  T.eq("one more than the limit rejects with the redirect's status", { r.ok, r.value.code }, { false, 301 })
  r = send("GET", base .. "cam.jpg")
  T.eq(
    "without the option nothing is followed, as before",
    { r.ok, r.value.code, #transfers },
    { false, 302, first + 10 }
  )
  r = send("GET", "https://example.invalid/other", nil, { maxRedirects = 4 })
  T.eq(
    "a location that isn't http or https isn't followed",
    { r.value.code, last().url },
    { 302, "https://example.invalid/other" }
  )

  routes["https://example.invalid/form"] = hop("/done", 303)
  routes["https://example.invalid/keep"] = hop("/done", 307)
  routes["https://example.invalid/done"] = jpeg
  send("POST", "https://example.invalid/form", { a = 1 }, { maxRedirects = 1 })
  T.eq("a 303 after a POST is followed with a GET", last().method, "GET")
  T.eq("without the body or the type it added", last().headers["Content-Type"], nil)
  send("POST", "https://example.invalid/keep", "a=1", { maxRedirects = 1 })
  T.eq("a 307 keeps the method and body", { last().method, last().data }, { "POST", "a=1" })
  routes["https://example.invalid/moved"] = hop("/done", 302)
  routes["https://example.invalid/gone"] = hop("/done", 301)
  local r2 = send("PATCH", "https://example.invalid/moved", "a=1", { maxRedirects = 1 })
  T.eq("a PATCH's 302 keeps the method and body", { last().method, last().data, r2.ok }, { "PATCH", "a=1", true })
  send("PUT", "https://example.invalid/gone", "a=1", { maxRedirects = 1 })
  T.eq("a PUT's 301 the same", { last().method, last().data }, { "PUT", "a=1" })
  send("DELETE", "https://example.invalid/form", nil, { maxRedirects = 1 })
  T.eq("a 303 after any method is a GET", last().method, "GET")
  send("HEAD", "https://example.invalid/form", nil, { maxRedirects = 1 })
  T.eq("but HEAD", last().method, "HEAD")
  routes[base .. "page.jpg"] = hop("?page=2")
  routes[base .. "page.jpg?page=2"] = jpeg
  send("GET", base .. "page.jpg", nil, { maxRedirects = 1 })
  T.eq("a query-only location keeps the path", last().url, base .. "page.jpg?page=2")

  local headers = { Authorization = "Bearer SECRET", ["X-Api-Key"] = "KEY", Accept = "image/*" }
  http:request("GET", base .. "next.jpg", nil, headers, { maxRedirects = 1 })
  T.eq("the same site gets the credentials", last().headers.Authorization, "Bearer SECRET")
  http:request("GET", "https://example.invalid/top.jpg", nil, headers, { maxRedirects = 1 })
  T.eq("another site doesn't", { last().headers.Authorization, last().headers["X-Api-Key"] }, { nil, nil })
  T.eq("but gets the rest", last().headers.Accept, "image/*")
end

T.section("a transfer that runs out of time says so")
do
  serve({ { code = 200, chunks = chunks(2, 100) }, fail = { 28, "Operation timed out after 20000 milliseconds" } })
  local r = get(URL, { maxBytes = 1000 })
  T.truthy("timedOut", r.value.timedOut)
  T.eq("holding none of what arrived", r.value.body, "")
  T.contains("with the controller's message", r.value.error, "Operation timed out")

  serve({ { code = 200 }, fail = { 7, "Failed to connect" } })
  T.falsy("another failure doesn't", get(URL, { maxBytes = 1000 }).value.timedOut)
end

T.section("privateUrl keeps the URL out of every log line, at every level")
do
  local login = "SECRET-LOGIN"
  local token = "SECRET-TOKEN"
  local host = "cam.example.invalid"
  local private = "https://admin:" .. login .. "@" .. host .. "/snap.jpg?token=" .. token

  local logged = {}
  local errorLog, debugLog = C4.ErrorLog, C4.DebugLog
  C4.ErrorLog = function(_, message)
    logged[#logged + 1] = message
  end
  C4.DebugLog = function(_, message)
    logged[#logged + 1] = message
  end

  --- Every request shape, logged the way a driver logs a failure; returns all output.
  local function everything(options)
    local runs = {
      { { code = 200, headers = { ["Content-Type"] = "image/jpeg" }, chunks = { "jpg" } } },
      { { code = 500, chunks = { "oops" } } },
      { { code = 200 }, fail = { 6, "Could not resolve host: " .. host } },
      { { code = 200, headers = { ["Content-Length"] = "999999" } } },
      { { code = 200, headers = { ["Content-Type"] = "text/html" } } },
      { { code = 302, headers = { Location = private .. "&hop=" .. token } } },
    }
    local out = {}
    for _, script in ipairs(runs) do
      serve(script)
      local _, _, printed = T.capture(function()
        local r = get(private, options)
        log:warn("fetch settled: %s", r.value)
      end)
      out[#out + 1] = printed
    end
    return table.concat(out, "\n") .. "\n" .. table.concat(logged, "\n")
  end
  local function opts(extra)
    local o = {
      maxBytes = 1000,
      maxRedirects = 2,
      onHeaders = function(_, headers)
        return (headers["Content-Type"] or ""):match("^text/html") and "page" or nil
      end,
    }
    for k, v in pairs(extra or {}) do
      o[k] = v
    end
    return o
  end

  DEBUG_URL = true
  log:setLogMode("Print and Log")
  for level = log.LogLevel.FATAL, log.LogLevel.ULTRA do
    log:setLogLevel(level)
    logged = {}
    local output = everything(opts({ privateUrl = true }))
    local name = log.LevelToName[level]
    T.excludes("no login at " .. name, output, login)
    T.excludes("no token at " .. name, output, token)
    T.excludes("no host at " .. name, output, host)
  end

  -- The control: the same requests without it do print the address, so the capture sees the lines.
  log:setLogLevel(log.LogLevel.TRACE)
  logged = {}
  T.contains("without privateUrl, trace shows the host", everything(opts()), host)
  logged = {}
  serve({ { code = 200, chunks = { "ok" } } })
  local _, _, printed = T.capture(function()
    get(private)
  end)
  T.contains("and urlDo's DEBUG_URL prints the whole URL", printed .. table.concat(logged, "\n"), token)

  DEBUG_URL = false
  log:setLogMode("")
  log:setLogLevel(log.LogLevel.INFO)
  C4.ErrorLog, C4.DebugLog = errorLog, debugLog

  serve({ { code = 200, chunks = { "jpg" } } })
  local r = get(private, { privateUrl = true })
  T.truthy("a private request still resolves", r.ok)
  T.eq("without its URL", r.value.url, nil)
  T.eq("and fetches the whole URL", last().url, private)

  serve({ { code = 200 }, fail = { 28, "Connection timed out after 10001 milliseconds to " .. host } })
  r = get(private, { privateUrl = true })
  T.eq(
    "its error names the transfer error, not the message",
    r.value.error,
    "HTTP GET request failed; transfer error 28"
  )
  T.truthy("and timedOut", r.value.timedOut)
end

T.section("tracing a request whose options hold a function doesn't raise")
do
  log:setLogMode("Print")
  log:setLogLevel(log.LogLevel.TRACE)
  serve({ { code = 200, chunks = { "ok" } } })
  local ok, err, printed = T.capture(function()
    get(URL, {
      onHeaders = function() end,
    })
  end)
  log:setLogMode("")
  log:setLogLevel(log.LogLevel.INFO)
  T.truthy("the request runs", ok, err)
  T.contains("the hook is traced by name", printed, '"onHeaders":"function"')
end

T.finish()
