--- A simple HTTP client module for making HTTP requests with Deferred support.

local deferred = require("deferred")

local log = require("lib.logging")
local redact = require("lib.redact")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.url")
require("lib.utils")

--- Maximum timeout for HTTP requests.
--- @type number
local MAX_TIMEOUT = 300

--- Default timeout for HTTP requests.
--- @type number
local DEFAULT_TIMEOUT = 30

--- The options this library reads itself. Any other option is the controller's, passed to it.
local OWN_OPTIONS = { maxBytes = true, onHeaders = true, privateUrl = true, maxRedirects = true }

--- The transfer error the controller reports when a transfer runs out of time (curl's).
local TIMED_OUT = 28

--- @class Http
--- A class representing an HTTP client.
local Http = {}
Http.__index = Http

--- Creates a new instance of the Http class.
--- @return Http http A new instance of the Http class.
function Http:new()
  log:trace("Http:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- @class HTTPOptions
--- @field timeout? number Seconds the whole transfer may take: 30 by default, and the most, 300, for 0 or less.
--- @field connect_timeout? number Seconds to wait for the connection, at most `timeout`.
--- @field maxBytes? integer The largest body taken, in bytes. A longer one stops the transfer as soon as it passes
--- this, or before it starts when its Content-Length says so, and the request rejects with `tooLarge`.
--- @field onHeaders? fun(code: integer, headers: table<string, string>): any Sees the answer's status and headers
--- before its body. A value other than nil or false refuses the answer: the transfer stops, and the request rejects
--- with that value as `refused`.
--- @field privateUrl? boolean Keeps the URL out of every log line and out of what the request settles with, a redirect's
--- Location header included: a URL can carry a login or a token.
--- @field maxRedirects? integer The most redirects followed when the controller hands one back unfollowed, to an http or
--- https address. Each is a transfer of its own with the same options. A 303, or a POST's 301 or 302, is followed with
--- a GET, any other keeps the method and body, and credential headers aren't sent on to another site.

--- @class HTTPResponse
--- @field url? string The URL of the request, or the one a followed redirect led to; absent with `privateUrl`.
--- @field code number The HTTP response code.
--- @field headers table<string, string> The headers of the response.
--- @field body string|table<string, any> The body of the response.

--- @class HTTPErrorResponse
--- @field error string The error message.
--- @field url? string The URL of the request, or the one a followed redirect led to; absent with `privateUrl`.
--- @field code number The HTTP response code.
--- @field headers table<string, string> The headers of the response.
--- @field body string|table<string, any> The body of the response.
--- @field refused? any What `onHeaders` refused the answer with.
--- @field tooLarge? boolean The body passed `maxBytes`.
--- @field timedOut? boolean The transfer ran out of time. Reported only with `maxBytes`, `onHeaders`, `privateUrl` or
--- `maxRedirects`.

--- @param code any
--- @return boolean passing A response on the way to the answer: an interim response or a redirect.
local function passing(code)
  code = tonumber(code) or 0
  return code < 200 or (code >= 300 and code < 400)
end

--- @param headers any
--- @param name string
--- @return string|nil value The header's value, whatever case the server wrote its name in.
local function header(headers, name)
  if type(headers) ~= "table" then
    return nil
  end
  name = name:lower()
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == name then
      return tostring(type(value) == "table" and value[#value] or value)
    end
  end
  return nil
end

--- Where a redirect points, from the URL it came from.
--- @param base string
--- @param location any
--- @return string|nil url An http or https URL, or nil for anything else.
local function resolve(base, location)
  location = tostring(location or ""):match("^%s*(.-)%s*$")
  if location:lower():match("^https?://") then
    return location
  end
  local scheme, authority, path = base:match("^(%a[%w+.-]*:)//([^/?#]*)([^?#]*)")
  if location == "" or location:match("^%a[%w+.-]*:") or not scheme then
    return nil
  end
  if location:sub(1, 2) == "//" then
    return scheme .. location
  end
  if location:sub(1, 1) == "/" then
    return scheme .. "//" .. authority .. location
  end
  if location:sub(1, 1) == "?" then
    return scheme .. "//" .. authority .. path .. location
  end
  return scheme .. "//" .. authority .. (path:match("^(.*/)") or "/") .. location
end

--- The headers an answer to a private URL settles with: those that name a URL are left out.
--- @param headers table<string, string>
--- @return table<string, string> headers
local function withoutUrls(headers)
  local kept = {}
  for name, value in pairs(headers) do
    local lower = type(name) == "string" and name:lower() or ""
    if lower ~= "location" and lower ~= "content-location" then
      kept[name] = value
    end
  end
  return kept
end

--- @param url string
--- @return string origin Its scheme and authority, lower case.
local function origin(url)
  return (url:match("^(%a[%w+.-]*://[^/?#]*)") or ""):lower()
end

--- @return string userAgent The User-Agent urlDo sends, built the same way.
local function userAgent()
  if USER_AGENT == nil then
    USER_AGENT = "Control4/"
      .. C4:GetVersionInfo().version
      .. "/"
      .. C4:GetDriverConfigInfo("model")
      .. "/"
      .. C4:GetDriverConfigInfo("version")
  end
  return USER_AGENT
end

--- Runs a transfer on `C4:url()` itself, for the options urlDo can't apply: their hooks must be set
--- before the transfer starts, and urlDo starts it. Otherwise it sends and decodes as urlDo does,
--- with no ETag cache and no DEBUG_URL print.
--- @param method string
--- @param url string
--- @param data? string|table<string, any>
--- @param headers? table<string, string>
--- @param settings table<string, any> The controller's options.
--- @param options HTTPOptions
--- @param done fun(strError: string|nil, code: number, headers: table, body: any, failure: table, url: string)
--- @param hops integer Redirects still to follow.
local function stream(method, url, data, headers, settings, options, done, hops)
  local callerHeaders, callerData = headers, data
  headers = CopyTable(headers) or {}
  if headers["User-Agent"] == nil then
    headers["User-Agent"] = userAgent()
  end
  data = data or ""
  if type(data) == "table" then
    data = JSON:encode(data)
    headers["Content-Type"] = "application/json"
  end
  if settings.cookies_enable == nil then
    settings.cookies_enable = true
  end
  if settings.fail_on_error == nil then
    settings.fail_on_error = false
  end

  local maxBytes = tonumber(options.maxBytes)
  local parts, bytes, current = {}, 0, nil
  local failure = {}

  local function onHeaders(_, response)
    parts, bytes = {}, 0
    if passing(response.code) then
      return false
    end
    current = response
    local length = tonumber(header(response.headers, "Content-Length"))
    if maxBytes and length and length > maxBytes then
      failure.tooLarge = true
      return true
    end
    if options.onHeaders then
      local ok, refused = pcall(options.onHeaders, response.code, response.headers)
      if not ok then
        failure.hookError = tostring(refused)
        return true
      end
      if refused ~= nil and refused ~= false then
        failure.refused = refused
        return true
      end
    end
    return false
  end

  local function onBodyChunk(_, response, chunk)
    if passing(response.code) then
      return false
    end
    bytes = bytes + #chunk
    if maxBytes and bytes > maxBytes then
      failure.tooLarge = true
      return true
    end
    parts[#parts + 1] = chunk
    return false
  end

  local function onDone(_, responses, errCode, errMsg)
    errCode = tonumber(errCode) or 0
    if errCode ~= 0 then
      failure.errCode, failure.timedOut = errCode, errCode == TIMED_OUT
      -- A refusal keeps the answer it refused; a failed transfer has none, as with urlDo.
      local ownStop = failure.tooLarge or failure.refused ~= nil or failure.hookError
      local response = ownStop and current or {}
      if errCode == -1 and errMsg == nil then
        errMsg = "Transfer cancelled"
      end
      return done(errMsg, response.code or 0, response.headers or {}, "", failure, url)
    end
    local final = type(responses) == "table" and responses[#responses] or {}
    local code = tonumber(final.code) or 0
    local nextUrl = hops > 0 and code >= 300 and code < 400 and resolve(url, header(final.headers, "Location"))
    if nextUrl then
      local nextMethod, nextData = method, callerData
      -- As curl and browsers do: a 303 is fetched with a GET, and so is a POST's 301 or 302.
      if (code == 303 and method ~= "HEAD") or ((code == 301 or code == 302) and method == "POST") then
        nextMethod, nextData = "GET", nil
      end
      local nextHeaders = callerHeaders
      if origin(nextUrl) ~= origin(url) then
        nextHeaders = {}
        for name, value in pairs(callerHeaders or {}) do
          if not redact.isSensitiveKey(name) then
            nextHeaders[name] = value
          end
        end
      end
      return stream(nextMethod, nextUrl, nextData, nextHeaders, settings, options, done, hops - 1)
    end
    --- @type any
    local body = table.concat(parts)
    if (header(final.headers, "Content-Type") or ""):find("application/json", 1, true) then
      -- As urlDo decodes: JSON.lua raises on a body it can't parse.
      local ok, decoded = pcall(JSON.decode, JSON, body)
      if ok and decoded ~= nil then
        body = decoded
      elseif tonumber(header(final.headers, "Content-Length")) ~= 0 then
        body = { body }
      end
    end
    done(nil, final.code, final.headers or {}, body, failure, url)
  end

  local transfer = C4:url():SetOptions(settings):OnHeaders(onHeaders):OnBodyChunk(onBodyChunk):OnDone(onDone)
  method = string.upper(method)
  if method == "GET" then
    transfer:Get(url, headers)
  elseif method == "POST" then
    transfer:Post(url, data, headers)
  elseif method == "PUT" then
    transfer:Put(url, data, headers)
  elseif method == "DELETE" then
    transfer:Delete(url, headers)
  else
    transfer:Custom(url, method, data, headers)
  end
end

--- Why a request failed, for its rejection's `error`, which drivers log at WARN.
--- @param method string
--- @param target string " to <url>", or "" for a private URL.
--- @param code any
--- @param strError string|nil
--- @param failure table
--- @param maxBytes any
--- @return string error
local function describe(method, target, code, strError, failure, maxBytes)
  if failure.tooLarge then
    return string.format("HTTP %s request%s stopped: its body passed %s bytes", method, target, tostring(maxBytes))
  end
  if failure.refused ~= nil then
    local reason = type(failure.refused) == "string" and (": " .. failure.refused) or ""
    return string.format("HTTP %s request%s refused%s", method, target, reason)
  end
  local detail = ""
  if failure.hookError then
    detail = "; onHeaders raised " .. failure.hookError
  elseif target == "" and failure.errCode then
    -- Only the code: the controller's message can carry the URL's host.
    detail = "; transfer error " .. failure.errCode
  elseif not IsEmpty(strError) then
    detail = "; " .. strError
  end
  local status = not IsEmpty(code) and (" with status code " .. code) or ""
  return string.format("HTTP %s request%s failed%s%s", method, target, status, detail)
end

--- Makes an HTTP request.
--- @param method string The HTTP method (e.g., "GET", "POST").
--- @param url string The URL to send the request to.
--- @param data? string|table<string, any> The data to send with the request (optional).
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? HTTPOptions Options for the request; any not listed there is passed to the controller (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
--- @diagnostic disable-next-line: unused
function Http:request(method, url, data, headers, options)
  options = options or {}
  local private = options.privateUrl == true
  -- Redaction deep-copies the request, so skip it entirely unless the line will
  -- actually be emitted. Arguments are evaluated before the level is checked
  -- inside the logger, which would otherwise pay this cost on every request at
  -- the default INFO level.
  if log:isEnabled() and log:getLogLevel() >= log.LogLevel.TRACE then
    local traced = {}
    for key, value in pairs(options) do
      -- The logger encodes tables as JSON, which raises on a function.
      traced[key] = type(value) == "function" and "function" or value
    end
    log:trace(
      "Http:request(%s, %s, %s, %s, %s)",
      method,
      private and "<private URL>" or redact.value(url),
      redact.value(data),
      redact.value(headers),
      redact.value(traced)
    )
  end
  local d = deferred.new()

  local settings = {}
  for key, value in pairs(options) do
    if not OWN_OPTIONS[key] then
      settings[key] = value
    end
  end
  if settings.timeout == nil then
    settings.timeout = DEFAULT_TIMEOUT
  end
  if settings.timeout <= 0 then
    settings.timeout = MAX_TIMEOUT
  end
  settings.timeout = InRange(settings.timeout, 0, MAX_TIMEOUT)
  if settings.connect_timeout ~= nil then
    local connect = tonumber(settings.connect_timeout) or 0
    -- curl reads 0 as its own default, 300 seconds.
    settings.connect_timeout = connect > 0 and math.min(connect, settings.timeout) or nil
  end

  -- Redacted: this string is rejected to the caller and drivers log it at
  -- WARN, which is emitted at the default level with nobody enabling trace.
  -- A URL carrying a token in its query string leaks here otherwise.
  local target = private and "" or (" to " .. redact.value(url))
  local function settle(strError, code, responseHeaders, body, failure, finalUrl)
    local result = {
      url = not private and (finalUrl or url) or nil,
      code = code,
      headers = private and withoutUrls(responseHeaders or {}) or responseHeaders,
      body = body,
    }
    if strError or IsEmpty(code) or code < 200 or code >= 300 then
      result.refused, result.tooLarge, result.timedOut = failure.refused, failure.tooLarge, failure.timedOut
      result.error = describe(method, target, code, strError, failure, options.maxBytes)
      d:reject(result)
    else
      d:resolve(result)
    end
  end

  local hops = tonumber(options.maxRedirects) or 0
  if options.maxBytes ~= nil or options.onHeaders ~= nil or private or hops > 0 then
    stream(method, url, data, headers, settings, options, settle, hops)
  else
    urlDo(method, url, data, headers, function(strError, responseCode, responseHeaders, responseBody)
      settle(strError, responseCode, responseHeaders, responseBody, {})
    end, nil, settings)
  end
  return d
end

--- Makes an HTTP GET request.
--- @param url string The URL to send the request to.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? HTTPOptions Options for the request (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:get(url, headers, options)
  return self:request("GET", url, nil, headers, options)
end

--- Makes an HTTP POST request.
--- @param url string The URL to send the request to.
--- @param data? string|table The data to send with the request (optional).
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? HTTPOptions Options for the request (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:post(url, data, headers, options)
  return self:request("POST", url, data, headers, options)
end

--- Makes an HTTP PUT request.
--- @param url string The URL to send the request to.
--- @param data? string|table The data to send with the request (optional).
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? HTTPOptions Options for the request (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:put(url, data, headers, options)
  return self:request("PUT", url, data, headers, options)
end

--- Makes an HTTP DELETE request.
--- @param url string The URL to send the request to.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? HTTPOptions Options for the request (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:delete(url, headers, options)
  return self:request("DELETE", url, nil, headers, options)
end

return Http:new()
