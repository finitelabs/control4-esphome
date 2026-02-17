--- BLEScannerNode - Base class for BLE scanner nodes.
--- A node represents a single BLE radio that can scan for devices.
--- Implementations include LocalScannerNode (direct ESPHome) and ProxyScannerNode (coordinator).

--- @class BLEScannerNode
--- @field _id string|number Unique identifier for this node
--- @field _advertisementCallback fun(advertisement: BLEAdvertisement, nodeId: string|number)? The callback for received advertisements
local BLEScannerNode = {}
BLEScannerNode.__index = BLEScannerNode

--- Create a new scanner node.
--- @param id string|number Unique identifier for this node
--- @return BLEScannerNode
function BLEScannerNode:new(id)
  local instance = setmetatable({}, self)
  instance._id = id
  instance._advertisementCallback = nil
  return instance
end

--- Get the unique identifier for this node.
--- @return string|number
function BLEScannerNode:getId()
  return self._id
end

--- Check if the node is connected and available for scanning.
--- Subclasses must override this method.
--- @return boolean
--- @diagnostic disable-next-line: unused
function BLEScannerNode:isConnected()
  error("BLEScannerNode:isConnected() must be implemented by subclass")
end

--- Set the callback to receive BLE advertisements.
--- The callback receives (advertisement, nodeId) for each advertisement.
--- @param callback fun(advertisement: BLEAdvertisement, nodeId: string|number)|nil The callback function, or nil to clear
function BLEScannerNode:setAdvertisementCallback(callback)
  self._advertisementCallback = callback
end

--- Clear the advertisement callback.
function BLEScannerNode:clearAdvertisementCallback()
  self._advertisementCallback = nil
end

--- Called by implementations when an advertisement is received.
--- Routes the advertisement to the registered callback.
--- @param advertisement BLEAdvertisement The BLE advertisement data
function BLEScannerNode:onAdvertisement(advertisement)
  if self._advertisementCallback then
    self._advertisementCallback(advertisement, self._id)
  end
end

return BLEScannerNode
