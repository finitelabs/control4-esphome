--- Proxy Registry for Bluetooth Coordinator.
--- Tracks connected ESPHome Bluetooth proxies and their status.

local log = require("lib.logging")

--- @class ProxyInfo
--- @field deviceId integer The Control4 device ID of the ESPHome proxy
--- @field proxyId string|nil String version of device ID (from proxy messages)
--- @field roomId integer|nil The room ID where this proxy is located
--- @field roomName string|nil The room name where this proxy is located
--- @field connectionSlots integer Total BLE connection slots available
--- @field freeSlots integer Currently available BLE connection slots
--- @field featureFlags integer Bluetooth proxy feature flags
--- @field connected boolean Whether the proxy is currently connected
--- @field lastSeen integer Timestamp of last message from proxy
--- @field minRssiOverride integer|nil Per-proxy RSSI threshold override (-100 = use global default)

--- @class ProxyRegistry
--- @field _proxies table<integer, ProxyInfo?> Map of device ID to proxy info
--- @field _proxyByProxyId table<string, ProxyInfo?> Map of proxy ID string to proxy info
--- @field _onProxyChangeCallbacks table<string, fun(event: string, proxyInfo: ProxyInfo)?> Registered callbacks
local ProxyRegistry = {}
ProxyRegistry.__index = ProxyRegistry

--- Create a new ProxyRegistry instance
--- @return ProxyRegistry
function ProxyRegistry:new()
  local instance = setmetatable({}, self)
  instance._proxies = {}
  instance._proxyByProxyId = {}
  instance._onProxyChangeCallbacks = {}
  return instance
end

--- Register a callback to be notified when proxies change
--- @param id string Callback identifier
--- @param callback fun(event: string, proxyInfo: ProxyInfo) Callback function
function ProxyRegistry:onProxyChange(id, callback)
  self._onProxyChangeCallbacks[id] = callback
end

--- Fire proxy change callbacks
--- @param event string Event type ("connected", "disconnected", "updated")
--- @param proxyInfo ProxyInfo The proxy that changed
--- @private
function ProxyRegistry:_fireProxyChange(event, proxyInfo)
  for _, callback in pairs(self._onProxyChangeCallbacks) do
    local ok, err = pcall(callback, event, proxyInfo)
    if not ok then
      log:error("Proxy change callback error: %s", err or "unknown error")
    end
  end
end

--- Handle proxy connection on a binding
--- @param deviceId integer The Control4 device ID that connected
function ProxyRegistry:onProxyBound(deviceId)
  log:info("Proxy bound (device %d)", deviceId)

  local proxy = self._proxies[deviceId]
  if proxy then
    -- Update existing proxy
    proxy.connected = true
    proxy.lastSeen = os.time()
  else
    -- Create new proxy entry
    proxy = {
      deviceId = deviceId,
      proxyId = nil,
      roomId = nil,
      roomName = nil,
      connectionSlots = 0,
      freeSlots = 0,
      featureFlags = 0,
      connected = true,
      lastSeen = os.time(),
    }
    self._proxies[deviceId] = proxy
  end
end

--- Handle proxy disconnection
--- @param deviceId integer The device ID
function ProxyRegistry:onProxyUnbound(deviceId)
  local proxy = self._proxies[deviceId]
  if proxy then
    log:info("Proxy disconnected (device %d)", deviceId)
    proxy.connected = false

    if proxy.proxyId then
      self._proxyByProxyId[proxy.proxyId] = nil
    end

    self:_fireProxyChange("disconnected", proxy)
  end
end

--- Handle PROXY_CONNECTED message from a proxy
--- @param deviceId integer The device ID
--- @param params table Message parameters
function ProxyRegistry:onProxyConnected(deviceId, params)
  local proxy = self._proxies[deviceId]
  if not proxy then
    log:warn("Received PROXY_CONNECTED for unknown device %d", deviceId)
    return
  end

  proxy.proxyId = params.proxyId
  proxy.roomId = tointeger(params.roomId) or nil
  proxy.roomName = params.roomName or nil
  proxy.connectionSlots = tointeger(params.connectionSlots) or 0
  proxy.freeSlots = tointeger(params.freeSlots) or 0
  proxy.featureFlags = tointeger(params.featureFlags) or 0
  proxy.minRssiOverride = tointeger(params.minRssiOverride) or nil
  proxy.lastSeen = os.time()

  -- Index by proxyId for faster lookups
  if proxy.proxyId then
    self._proxyByProxyId[proxy.proxyId] = proxy
  end

  log:info(
    "Proxy %d connected: room=%s, slots=%d/%d",
    deviceId,
    proxy.roomName or "Unknown",
    proxy.freeSlots,
    proxy.connectionSlots
  )

  self:_fireProxyChange("connected", proxy)
end

--- Handle CONNECTION_STATE update from a proxy
--- @param deviceId integer The device ID
--- @param params table Message parameters
function ProxyRegistry:onConnectionState(deviceId, params)
  local proxy = self._proxies[deviceId]
  if not proxy then
    return
  end

  proxy.connectionSlots = tointeger(params.connectionSlots) or proxy.connectionSlots
  proxy.freeSlots = tointeger(params.freeSlots) or proxy.freeSlots
  proxy.lastSeen = os.time()

  -- Update room if provided
  local roomId = tointeger(params.roomId)
  if roomId and not IsEmpty(params.roomName) then
    proxy.roomId = roomId
    proxy.roomName = params.roomName
  end

  -- Update minRssiOverride if provided
  local minRssiOverride = tointeger(params.minRssiOverride)
  if minRssiOverride then
    proxy.minRssiOverride = minRssiOverride
  end

  self:_fireProxyChange("updated", proxy)
end

--- Get a proxy by device ID
--- @param deviceId integer The device ID
--- @return ProxyInfo|nil
function ProxyRegistry:getProxy(deviceId)
  return self._proxies[deviceId]
end

--- Get all connected proxies
--- @return ProxyInfo[]
function ProxyRegistry:getConnectedProxies()
  local result = {}
  for _, proxy in pairs(self._proxies) do
    if proxy.connected then
      table.insert(result, proxy)
    end
  end
  return result
end

--- Get count of connected proxies
--- @return integer
function ProxyRegistry:getConnectedCount()
  local count = 0
  for _, proxy in pairs(self._proxies) do
    if proxy.connected then
      count = count + 1
    end
  end
  return count
end

--- Check if a proxy is connected
--- @param deviceId integer The device ID
--- @return boolean
function ProxyRegistry:isProxyConnected(deviceId)
  local proxy = self._proxies[deviceId]
  return proxy ~= nil and proxy.connected
end

--- Find proxies by room
--- @param roomId integer The room ID
--- @return ProxyInfo[]
function ProxyRegistry:getProxiesByRoom(roomId)
  local result = {}
  for _, proxy in pairs(self._proxies) do
    if proxy.connected and proxy.roomId == roomId then
      table.insert(result, proxy)
    end
  end
  return result
end

--- Update proxy's last seen timestamp
--- @param deviceId integer The device ID
function ProxyRegistry:updateLastSeen(deviceId)
  local proxy = self._proxies[deviceId]
  if proxy then
    proxy.lastSeen = os.time()
  end
end

return ProxyRegistry:new()
