--- @module "lib.http"
--- A simple HTTP client module for making HTTP requests with support for Deferreds.

local deferred = require("vendor.deferred")

local log = require("lib.logging")

--- Maximum timeout for HTTP requests.
--- @type number
local MAX_TIMEOUT = 300

--- Default timeout for HTTP requests.
--- @type number
local DEFAULT_TIMEOUT = 30

--- @class Http
--- A class representing an HTTP client.
local Http = {}

--- Creates a new instance of the Http class.
--- @return Http http A new instance of the Http class.
function Http:new()
  log:trace("Http:new()")
  local properties = {}
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties Http
  return properties
end

--- @class HTTPResponse
--- @field url string The URL of the request.
--- @field code number The HTTP response code.
--- @field headers table<string, string> The headers of the response.
--- @field body string|table<string, any> The body of the response.

--- @class HTTPErrorResponse
--- @field error string The error message.
--- @field url string The URL of the request.
--- @field code number The HTTP response code.
--- @field headers table<string, string> The headers of the response.
--- @field body string|table<string, any> The body of the response.

--- Makes an HTTP request.
--- @param method string The HTTP method (e.g., "GET", "POST").
--- @param url string The URL to send the request to.
--- @param data? string|table<string, any> The data to send with the request (optional).
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:request(method, url, data, headers, options)
  log:trace("Http:request(%s, %s, %s, %s, %s)", method, url, data, headers, options)
  local d = deferred.new()

  options = options or {}
  if options.timeout == nil then
    options.timeout = DEFAULT_TIMEOUT
  end
  if options.timeout <= 0 then
    options.timeout = MAX_TIMEOUT
  end
  options.timeout = InRange(options.timeout, 0, MAX_TIMEOUT)

  urlDo(method, url, data, headers, function(strError, responseCode, responseHeaders, responseBody, _, responseUrl)
    local result = {
      url = responseUrl,
      code = responseCode,
      headers = responseHeaders,
      body = responseBody,
    }
    if strError or IsEmpty(responseCode) or responseCode < 200 or responseCode >= 300 then
      result.error = string.format(
        "HTTP %s request to %s failed%s%s",
        method,
        url,
        not IsEmpty(responseCode) and (" with status code " .. responseCode) or "",
        not IsEmpty(strError) and ("; " .. strError) or ""
      )
      d:reject(result)
    else
      d:resolve(result)
    end
  end, nil, options)
  return d
end

--- Makes an HTTP GET request.
--- @param url string The URL to send the request to.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:get(url, headers, options)
  return self:request("GET", url, nil, headers, options)
end

--- Makes an HTTP POST request.
--- @param url string The URL to send the request to.
--- @param data string|table The data to send with the request.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:post(url, data, headers, options)
  return self:request("POST", url, data, headers, options)
end

--- Makes an HTTP PUT request.
--- @param url string The URL to send the request to.
--- @param data string|table The data to send with the request.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:put(url, data, headers, options)
  return self:request("PUT", url, data, headers, options)
end

--- Makes an HTTP DELETE request.
--- @param url string The URL to send the request to.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:delete(url, headers, options)
  return self:request("DELETE", url, nil, headers, options)
end

return Http:new()
