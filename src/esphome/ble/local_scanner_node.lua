--- LocalScannerNode - Scanner node for direct ESPHome client connections.
--- Wraps an ESPHomeClient to receive BLE advertisements from a local ESPHome device.

local log = require("lib.logging")
local BLEScannerNode = require("esphome.ble.scanner_node")

--- @class LocalScannerNode : BLEScannerNode
--- @field _client ESPHomeClient The ESPHome client instance
--- @field _callbackId string Unique callback ID for this node
--- @field _registered boolean Whether the advertisement callback is registered
local LocalScannerNode = setmetatable({}, { __index = BLEScannerNode })
LocalScannerNode.__index = LocalScannerNode

--- Create a new LocalScannerNode.
--- @param client ESPHomeClient The ESPHome client to wrap
--- @return LocalScannerNode
function LocalScannerNode:new(client)
  local instance = setmetatable(BLEScannerNode:new("local"), self)
  instance._client = assert(client, "client parameter is required")
  instance._callbackId = "local_scanner_node"
  instance._registered = false
  return instance
end

--- Check if the node is connected.
--- @return boolean
function LocalScannerNode:isConnected()
  return self._client:isConnected()
end

--- Set the callback to receive BLE advertisements.
--- Registers with the ESPHome client's advertisement callback system.
--- @param callback fun(advertisement: BLEAdvertisement, nodeId: string|number)|nil The callback function, or nil to clear
function LocalScannerNode:setAdvertisementCallback(callback)
  -- Call parent to store callback
  BLEScannerNode.setAdvertisementCallback(self, callback)

  if callback then
    -- Register with ESPHome client
    if not self._registered then
      self._client:addBluetoothAdvertisementCallback(self._callbackId, function(message)
        self:onAdvertisement(message)
      end)
      self._registered = true
      log:debug("LocalScannerNode %s: registered advertisement callback", self._id)
    end
  else
    -- Unregister from ESPHome client
    self:clearAdvertisementCallback()
  end
end

--- Clear the advertisement callback.
--- Unregisters from the ESPHome client.
function LocalScannerNode:clearAdvertisementCallback()
  BLEScannerNode.clearAdvertisementCallback(self)

  if self._registered then
    self._client:removeBluetoothAdvertisementCallback(self._callbackId)
    self._registered = false
    log:debug("LocalScannerNode %s: unregistered advertisement callback", self._id)
  end
end

return LocalScannerNode
