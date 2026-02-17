--- Router for Bluetooth Coordinator.
--- Handles RSSI-based proxy selection and failover logic.

local log = require("lib.logging")
local proxyRegistry = require("esphome.ble.coordinator.proxy_registry")
local deviceRegistry = require("esphome.ble.coordinator.device_registry")

--------------------------------------------------------------------------------
-- Response Types
--------------------------------------------------------------------------------

--- @class GattConnectResponse
--- @field requestId string The request ID for correlation
--- @field success string "true" or "false"
--- @field error string|nil Error message if failed
--- @field services string|nil Serialized services list
--- @field mtu string|nil MTU value

--- @class GattWriteResponse
--- @field requestId string The request ID for correlation
--- @field success string "true" or "false"
--- @field error string|nil Error message if failed

--- @class GattReadResponse
--- @field requestId string The request ID for correlation
--- @field data string|nil Base64-encoded data if successful
--- @field error string Error code ("0" for success)

--- @class GattNotifySubscribedResponse
--- @field requestId string The request ID for correlation
--- @field success string "true" or "false"
--- @field error string|nil Error message if failed

--- @class GattNotifyDataResponse
--- @field mac string MAC address of the device
--- @field handle string GATT handle as string
--- @field data string|nil Base64-encoded notification data

--- @class GattDisconnectResponse
--- @field mac string MAC address of the device

--------------------------------------------------------------------------------
-- Router Class
--------------------------------------------------------------------------------

--- @class Router
--- @field _pendingRequests table<string, table?> Map of request ID -> pending request info
--- @field _connectedDevices table<string, integer?> Map of MAC -> connected proxy device ID
--- @field _requestIdCounter integer Counter for generating unique request IDs
local Router = {}
Router.__index = Router

--- Create a new Router instance
--- @return Router
function Router:new()
  local instance = setmetatable({}, self)
  instance._pendingRequests = {} -- Track in-flight GATT requests
  instance._connectedDevices = {} -- Track MAC -> proxy for connected devices
  instance._requestIdCounter = 0
  return instance
end

--- Select the best proxy for a device based on RSSI
--- @param mac string MAC address
--- @param rssiMaxAge number? Maximum age of RSSI readings in seconds (default: 60)
--- @param excludeProxies table<integer, boolean?>? Proxy device IDs to exclude
--- @return ProxyInfo|nil bestProxy The best proxy, or nil if none available
--- @return number|nil rssi The RSSI value from that proxy
--- @private
--- @diagnostic disable-next-line: unused
function Router:_selectBestProxy(mac, rssiMaxAge, excludeProxies)
  rssiMaxAge = rssiMaxAge or 60
  excludeProxies = excludeProxies or {}

  local readings = deviceRegistry:getRSSIReadings(mac, rssiMaxAge)
  --- @type {deviceId: integer, rssi: number, timestamp: number}[]
  local candidates = {}

  for proxyDeviceId, reading in pairs(readings) do
    if not excludeProxies[proxyDeviceId] and proxyRegistry:isProxyConnected(proxyDeviceId) then
      table.insert(candidates, {
        deviceId = proxyDeviceId,
        rssi = reading.smoothedRssi,
        timestamp = reading.timestamp,
      })
    end
  end

  -- Sort by RSSI (highest = best signal)
  table.sort(candidates, function(a, b)
    return a.rssi > b.rssi
  end)

  local best = candidates[1]
  if not best then
    return nil, nil
  end

  local proxy = proxyRegistry:getProxy(best.deviceId)

  return proxy, best.rssi
end

--- Generate a unique request ID for tracking GATT operations
--- @return string
--- @private
function Router:_generateRequestId()
  self._requestIdCounter = self._requestIdCounter + 1
  return string.format("req_%d_%d", os.time(), self._requestIdCounter)
end

--- Get the proxy to use for a device operation.
--- Returns the connected proxy if device has an active connection, otherwise selects by RSSI.
--- @param mac string MAC address
--- @return ProxyInfo|nil proxy The proxy to use
--- @private
function Router:_getProxyForDevice(mac)
  -- First check if device is already connected via a specific proxy
  local connectedProxyId = mac and self._connectedDevices[mac]
  if connectedProxyId and proxyRegistry:isProxyConnected(connectedProxyId) then
    return proxyRegistry:getProxy(connectedProxyId)
  end

  -- Fall back to RSSI-based selection
  return (self:_selectBestProxy(mac))
end

--- Connect to a device with failover support
--- @param mac string MAC address
--- @param maxAttempts integer|nil Maximum connection attempts (default: 3)
--- @param rssiMaxAge number|nil Maximum age of RSSI readings in seconds
--- @param callback fun(success: boolean, result: GattConnectResponse|string) Called with connection result or error message
function Router:connectWithFailover(mac, maxAttempts, rssiMaxAge, callback)
  maxAttempts = maxAttempts or 3
  rssiMaxAge = rssiMaxAge or 60

  local device = deviceRegistry:getDevice(mac)
  if not device then
    callback(false, "Device not found: " .. mac)
    return
  end

  local attempted = {}
  local attempt = 0

  local function tryNextProxy()
    attempt = attempt + 1
    if attempt > maxAttempts then
      callback(false, "All connection attempts failed")
      return
    end

    local best, rssi = self:_selectBestProxy(mac, rssiMaxAge, attempted)
    if not best then
      callback(false, "No available proxy for " .. mac)
      return
    end

    attempted[best.deviceId] = true
    log:info("Attempt %d: Connecting to %s via proxy device %d (RSSI: %d)", attempt, mac, best.deviceId, rssi or -999)

    local requestId = self:_generateRequestId()

    -- Store pending request
    self._pendingRequests[requestId] = {
      mac = mac,
      proxyDeviceId = best.deviceId,
      type = "connect",
      callback = function(success, result)
        if success then
          callback(true, result)
        else
          log:warn("Connection failed via proxy device %d, trying next...", best.deviceId)
          tryNextProxy()
        end
      end,
    }

    -- Send connect command to proxy via C4:SendToDevice
    SendToDevice(best.deviceId, "GATT_CONNECT", {
      mac = mac,
      address = string.format("%.0f", device.address),
      addressType = tostring(device.addressType),
      requestId = requestId,
    })
  end

  tryNextProxy()
end

--- Send a GATT write command
--- Uses the connected proxy if device has an active connection, otherwise selects by RSSI.
--- @param mac string MAC address
--- @param handle number GATT handle
--- @param data string Data to write (raw bytes)
--- @param needResponse boolean Whether to wait for response
--- @param callback fun(success: boolean, error: string|nil) Called with write result
function Router:gattWrite(mac, handle, data, needResponse, callback)
  local device = deviceRegistry:getDevice(mac)
  if not device then
    callback(false, "Device not found")
    return
  end

  local proxy = self:_getProxyForDevice(mac)
  if not proxy then
    callback(false, "No available proxy")
    return
  end

  local requestId = self:_generateRequestId()

  self._pendingRequests[requestId] = {
    mac = mac,
    proxyDeviceId = proxy.deviceId,
    type = "write",
    callback = callback,
  }

  SendToDevice(proxy.deviceId, "GATT_WRITE", {
    mac = mac,
    address = string.format("%.0f", device.address),
    addressType = tostring(device.addressType),
    handle = tostring(handle),
    data = C4:Base64Encode(data),
    response = needResponse and "true" or "false",
    requestId = requestId,
  })
end

--- Send a GATT read command
--- Uses the connected proxy if device has an active connection, otherwise selects by RSSI.
--- @param mac string MAC address
--- @param handle number GATT handle
--- @param callback fun(success: boolean, data: string|nil, error: string|nil) Called with read result
function Router:gattRead(mac, handle, callback)
  local device = deviceRegistry:getDevice(mac)
  if not device then
    callback(false, nil, "Device not found")
    return
  end

  local proxy = self:_getProxyForDevice(mac)
  if not proxy then
    callback(false, nil, "No available proxy")
    return
  end

  local requestId = self:_generateRequestId()

  self._pendingRequests[requestId] = {
    mac = mac,
    proxyDeviceId = proxy.deviceId,
    type = "read",
    callback = callback,
  }

  SendToDevice(proxy.deviceId, "GATT_READ", {
    mac = mac,
    address = string.format("%.0f", device.address),
    addressType = tostring(device.addressType),
    handle = tostring(handle),
    requestId = requestId,
  })
end

--- Subscribe to GATT notifications
--- Uses the connected proxy if device has an active connection, otherwise selects by RSSI.
--- @param mac string MAC address
--- @param handle number GATT handle
--- @param enable boolean Enable or disable notifications
--- @param dataCallback fun(data: string) Called with notification data (raw bytes)
--- @param resultCallback (fun(success: boolean, error: string|nil))? Called with subscription result
function Router:gattNotify(mac, handle, enable, dataCallback, resultCallback)
  local device = deviceRegistry:getDevice(mac)
  if not device then
    if resultCallback then
      resultCallback(false, "Device not found")
    end
    return
  end

  local proxy = self:_getProxyForDevice(mac)
  if not proxy then
    if resultCallback then
      resultCallback(false, "No available proxy")
    end
    return
  end

  local requestId = self:_generateRequestId()

  -- Store both callbacks
  self._pendingRequests[requestId] = {
    mac = mac,
    proxyDeviceId = proxy.deviceId,
    handle = handle,
    type = "notify",
    dataCallback = dataCallback,
    resultCallback = resultCallback,
  }

  SendToDevice(proxy.deviceId, "GATT_NOTIFY", {
    mac = mac,
    address = string.format("%.0f", device.address),
    addressType = tostring(device.addressType),
    handle = tostring(handle),
    enable = enable and "true" or "false",
    requestId = requestId,
  })
end

--- Disconnect from a device
--- Sends disconnect to the proxy where this device is connected.
--- @param mac string MAC address
function Router:disconnect(mac)
  local device = deviceRegistry:getDevice(mac)
  if not device then
    return
  end

  local connectedProxyId = self._connectedDevices[mac]
  if connectedProxyId ~= nil then
    -- Disconnect from the tracked proxy
    SendToDevice(connectedProxyId, "GATT_DISCONNECT", {
      mac = mac,
      address = string.format("%.0f", device.address),
    })
    -- Clear tracking immediately (will also be cleared on response)
    self._connectedDevices[mac] = nil
  end
end

--- Handle GATT_CONNECT_RESPONSE from proxy
--- @param response GattConnectResponse Response from proxy
function Router:onGattConnectResponse(response)
  local requestId = response.requestId
  local request = self._pendingRequests[requestId]

  if not request then
    log:debug("Received GATT_CONNECT_RESPONSE for unknown request: %s", requestId)
    return
  end

  self._pendingRequests[requestId] = nil

  local success = response.success == "true"
  if success then
    -- Track this device as connected via this proxy
    self._connectedDevices[request.mac] = request.proxyDeviceId

    -- Deserialize services if provided
    local services = nil
    if response.services and response.services ~= "" then
      local ok, parsed = pcall(DeserializeSafe, response.services)
      services = ok and parsed or nil
    end

    request.callback(true, {
      services = services,
      mtu = tonumber(response.mtu) or 0,
    })
  else
    request.callback(false, response.error or "Connection failed")
  end
end

--- Handle GATT_WRITE_RESPONSE from proxy
--- @param response GattWriteResponse Response from proxy
function Router:onGattWriteResponse(response)
  local requestId = response.requestId
  local request = self._pendingRequests[requestId]

  if not request then
    return
  end

  self._pendingRequests[requestId] = nil

  local success = response.success == "true"
  request.callback(success, success and nil or (response.error or "Write failed"))
end

--- Handle GATT_READ_RESPONSE from proxy
--- @param response GattReadResponse Response from proxy
function Router:onGattReadResponse(response)
  local requestId = response.requestId
  local request = self._pendingRequests[requestId]

  if not request then
    return
  end

  self._pendingRequests[requestId] = nil

  local success = response.error == "0"
  local data = nil
  if success and response.data then
    data = C4:Base64Decode(response.data)
  end

  request.callback(success, data, success and nil or (response.error or "Read failed"))
end

--- Handle GATT_NOTIFY_SUBSCRIBED from proxy
--- @param response GattNotifySubscribedResponse Response from proxy
function Router:onGattNotifySubscribed(response)
  local requestId = response.requestId
  local request = self._pendingRequests[requestId]

  if not request then
    return
  end

  -- Don't remove request - we need it for data callbacks
  -- But do call the result callback
  local success = response.success == "true"
  if request.resultCallback then
    request.resultCallback(success, success and nil or (response.error or "Subscription failed"))
  end
end

--- Handle GATT_NOTIFY_DATA from proxy
--- @param notification GattNotifyDataResponse Notification data from proxy
function Router:onGattNotifyData(notification)
  local mac = notification.mac
  local handle = tointeger(notification.handle)

  -- Find the matching request by mac and handle
  for _, request in pairs(self._pendingRequests) do
    if request.mac == mac and request.handle == handle and request.type == "notify" then
      if request.dataCallback then
        local data = C4:Base64Decode(notification.data or "")
        request.dataCallback(data)
      end
      return
    end
  end

  log:debug("Received GATT_NOTIFY_DATA for untracked notification: %s handle %d", mac, handle)
end

--- Handle GATT_DISCONNECT_RESPONSE from proxy
--- @param response GattDisconnectResponse Response from proxy
function Router:onGattDisconnectResponse(response)
  local mac = response.mac
  if not mac then
    return
  end

  -- Clear connection tracking
  self._connectedDevices[mac] = nil

  -- Clean up any pending notification requests for this device
  for requestId, request in pairs(self._pendingRequests) do
    if request.mac == mac and request.type == "notify" then
      self._pendingRequests[requestId] = nil
    end
  end
end

--- Handle proxy disconnection - clean up pending requests and tracked devices for that proxy
--- @param proxyDeviceId integer The disconnected proxy's device ID
function Router:onProxyDisconnected(proxyDeviceId)
  -- Clear all devices connected via this proxy
  for mac, connectedProxyId in pairs(self._connectedDevices) do
    if connectedProxyId == proxyDeviceId then
      self._connectedDevices[mac] = nil
    end
  end

  -- Cancel pending requests
  local cancelled = 0
  for requestId, request in pairs(self._pendingRequests) do
    if request.proxyDeviceId == proxyDeviceId then
      cancelled = cancelled + 1

      -- Call callbacks with error
      if request.type == "connect" then
        if request.callback then
          request.callback(false, "Proxy disconnected")
        end
      elseif request.type == "write" then
        if request.callback then
          request.callback(false, "Proxy disconnected")
        end
      elseif request.type == "read" then
        if request.callback then
          request.callback(false, nil, "Proxy disconnected")
        end
      elseif request.type == "notify" then
        if request.resultCallback then
          request.resultCallback(false, "Proxy disconnected")
        end
      end

      self._pendingRequests[requestId] = nil
    end
  end

  if cancelled > 0 then
    log:info("Cancelled %d pending request(s) due to proxy device %d disconnection", cancelled, proxyDeviceId)
  end
end

return Router:new()
