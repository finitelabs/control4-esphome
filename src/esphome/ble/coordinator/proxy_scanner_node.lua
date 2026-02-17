--- ProxyScannerNode - Scanner node for coordinator proxy connections.
--- Wraps a remote ESPHome proxy to receive BLE advertisements via the coordinator.
--- Note: ESPHome proxies continuously forward advertisements once connected,
--- so no scan commands are sent - just tracks state for the BLEScanner timing logic.

local BLEScannerNode = require("esphome.ble.scanner_node")

--- @class ProxyScannerNode : BLEScannerNode
--- @field _proxyDeviceId number The Control4 device ID of the proxy
--- @field _isConnectedFn fun(): boolean Function to check if proxy is connected
local ProxyScannerNode = setmetatable({}, { __index = BLEScannerNode })
ProxyScannerNode.__index = ProxyScannerNode

--- Create a new ProxyScannerNode.
--- @param proxyDeviceId number The Control4 device ID of the proxy
--- @param isConnectedFn fun(): boolean Function to check if proxy is connected
--- @return ProxyScannerNode
function ProxyScannerNode:new(proxyDeviceId, isConnectedFn)
  local instance = setmetatable(BLEScannerNode:new(proxyDeviceId), self)
  instance._proxyDeviceId = proxyDeviceId
  instance._isConnectedFn = isConnectedFn
  return instance
end

--- Check if the proxy is connected.
--- @return boolean
function ProxyScannerNode:isConnected()
  return self._isConnectedFn()
end

return ProxyScannerNode
