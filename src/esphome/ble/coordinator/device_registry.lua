--- Device Registry for Bluetooth Coordinator.
--- Tracks registered BLE devices with RSSI tracking per proxy.

local log = require("lib.logging")

--- @class DeviceInfo
--- @field name string? Device name from advertisement
--- @field mac string MAC address in format "AA:BB:CC:DD:EE:FF"
--- @field address number 48-bit Bluetooth address as number
--- @field addressType BLEAddressType? Bluetooth address type
--- @field deviceType string? Derived device type (set by scanner during scans)
--- @field passive boolean Whether device uses passive advertisement mode
--- @field bindingClass string? Control4 binding class (set by scanner during scans)
--- @field bindingId integer? Dynamic binding ID for child driver
--- @field lastSeen integer? Timestamp of last advertisement

--- @class RSSIReading
--- @field rssi number? RSSI in dBm
--- @field timestamp integer When this reading was taken
--- @field smoothedRssi number EMA-smoothed RSSI value

--- @class AdvertisementHistory
--- @field name string? Last device name
--- @field mfgDataStr string Serialized manufacturer data for comparison
--- @field serviceDataStr string Serialized service data for comparison

--- @class DeviceRegistry
--- @field _devices table<string, DeviceInfo?> Map of MAC address to device info
--- @field _rssiMap table<string, table<integer, RSSIReading?>?> Map of MAC -> (proxyDeviceId -> RSSI reading)
--- @field _advHistory table<string, AdvertisementHistory?> Map of MAC -> last advertisement data for deduplication
local DeviceRegistry = {}
DeviceRegistry.__index = DeviceRegistry

--- Create a new DeviceRegistry instance
--- @return DeviceRegistry
function DeviceRegistry:new()
  local instance = setmetatable({}, self)
  instance._devices = {}
  instance._rssiMap = {}
  instance._advHistory = {}
  return instance
end

--- Register a device for tracking
--- @param info DeviceInfo Initial device info (deviceType, bindingClass, name, etc.)
--- @return DeviceInfo device The registered device
function DeviceRegistry:registerDevice(info)
  local device = self._devices[info.mac]
  if device then
    -- Update existing device with new info
    device.name = info.name or device.name
    device.deviceType = info.deviceType or device.deviceType
    device.passive = info.passive or device.passive
    device.bindingClass = info.bindingClass or device.bindingClass
    device.bindingId = info.bindingId or device.bindingId
    log:debug("Updated registered device: %s", info.mac)
  else
    -- Create new device
    --- @type DeviceInfo
    device = {
      name = info.name,
      mac = info.mac,
      address = info.address,
      addressType = info.addressType,
      deviceType = info.deviceType,
      passive = info.passive,
      bindingClass = info.bindingClass,
      bindingId = info.bindingId,
      lastSeen = info.lastSeen,
    }
    self._devices[info.mac] = device
    self._rssiMap[info.mac] = nil
    self._advHistory[info.mac] = nil
    log:info("Registered device: %s (%s)", info.mac, device.deviceType or "unknown")
  end

  return device
end

--- Unregister a device from tracking
--- @param mac string MAC address
function DeviceRegistry:unregisterDevice(mac)
  local device = self._devices[mac]
  if device then
    log:info("Unregistered device: %s", mac)
  end
  self._devices[mac] = nil
  self._rssiMap[mac] = nil
  self._advHistory[mac] = nil
end

--- Process a BLE advertisement from a proxy (only for registered devices)
--- @param proxyDeviceId integer The proxy device ID
--- @param adv BLEAdvertisement Advertisement data from proxy
--- @return DeviceInfo|nil device The device info if registered, nil otherwise
--- @return boolean isDuplicate Whether this is a duplicate advertisement
function DeviceRegistry:processAdvertisement(proxyDeviceId, adv)
  local mac = adv.mac
  local device = mac and self._devices[mac]

  -- Only process advertisements for registered devices
  if not device then
    return nil, false
  end

  -- Always update RSSI
  local rssi = adv.rssi or -999
  self:_updateRSSI(mac, proxyDeviceId, rssi)

  -- Update device info
  device.lastSeen = os.time()
  if not IsEmpty(adv.name) then
    device.name = adv.name
  end
  if adv.addressType then
    device.addressType = adv.addressType
  end

  -- Check for duplicate advertisement (same serviceData, manufacturerData, name)
  local isDuplicate = self:_isDuplicateAdvertisement(mac, adv)

  return device, isDuplicate
end

--- Check if an advertisement is a duplicate
--- Compares serviceData, manufacturerData, and name to detect duplicates.
--- @param mac string MAC address
--- @param adv BLEAdvertisement Advertisement data
--- @return boolean isDuplicate
--- @private
function DeviceRegistry:_isDuplicateAdvertisement(mac, adv)
  local last = self._advHistory[mac]

  -- Serialize for comparison (handles nil gracefully)
  local serviceDataStr = SerializeSafe(adv.serviceData)
  local mfgDataStr = SerializeSafe(adv.manufacturerData)

  local isDup = last ~= nil
    and last.serviceDataStr == serviceDataStr
    and last.mfgDataStr == mfgDataStr
    and last.name == adv.name

  if not isDup then
    self._advHistory[mac] = {
      serviceDataStr = serviceDataStr,
      mfgDataStr = mfgDataStr,
      name = adv.name,
    }
  end

  return isDup
end

--- Update RSSI reading for a device from a specific proxy
--- @param mac string MAC address
--- @param proxyDeviceId integer Proxy device ID
--- @param rssi number RSSI value in dBm
--- @param smoothingAlpha number|nil Smoothing factor (default 0.2)
--- @private
function DeviceRegistry:_updateRSSI(mac, proxyDeviceId, rssi, smoothingAlpha)
  smoothingAlpha = smoothingAlpha or 0.2

  if not self._rssiMap[mac] then
    self._rssiMap[mac] = {}
  end

  --- @type RSSIReading?
  local reading = self._rssiMap[mac][proxyDeviceId]
  local now = os.time()

  if reading then
    -- Apply exponential moving average
    reading.smoothedRssi = smoothingAlpha * rssi + (1 - smoothingAlpha) * reading.smoothedRssi
    reading.rssi = rssi
    reading.timestamp = now
  else
    -- First reading
    self._rssiMap[mac][proxyDeviceId] = {
      rssi = rssi,
      smoothedRssi = rssi,
      timestamp = now,
    }
  end
end

--- Get RSSI readings for a device from all proxies
--- @param mac string MAC address
--- @param maxAge number|nil Maximum age in seconds (default: no limit)
--- @return table<integer, RSSIReading?> Map of device ID to RSSI reading
function DeviceRegistry:getRSSIReadings(mac, maxAge)
  local readings = mac and self._rssiMap[mac]
  if not readings then
    return {}
  end

  if not maxAge then
    return readings
  end

  -- Filter by age
  local now = os.time()
  local result = {}
  for proxyDeviceId, reading in pairs(readings) do
    if (now - reading.timestamp) <= maxAge then
      result[proxyDeviceId] = reading
    end
  end
  return result
end

--- Get the best (highest) RSSI for a device
--- @param mac string MAC address
--- @param maxAge number|nil Maximum age in seconds
--- @return number|nil rssi Best RSSI value
--- @return integer|nil deviceId The proxy device ID with best RSSI
function DeviceRegistry:getBestRSSI(mac, maxAge)
  local readings = self:getRSSIReadings(mac, maxAge)
  local bestRssi = nil
  local bestDeviceId = nil

  for proxyDeviceId, reading in pairs(readings) do
    if not bestRssi or reading.smoothedRssi > bestRssi then
      bestRssi = reading.smoothedRssi
      bestDeviceId = proxyDeviceId
    end
  end

  return bestRssi, bestDeviceId
end

--- Get a device by MAC address
--- @param mac string MAC address
--- @return DeviceInfo|nil
function DeviceRegistry:getDevice(mac)
  return mac and self._devices[mac]
end

--- Get count of registered devices
--- @return integer
function DeviceRegistry:getDeviceCount()
  return TableLength(self._devices)
end

--- Get all registered devices
--- @return table<string, DeviceInfo?> devices Map of MAC to device info
function DeviceRegistry:getDevices()
  return self._devices
end

--- Clear all device data (for reset)
function DeviceRegistry:clear()
  self._devices = {}
  self._rssiMap = {}
  self._advHistory = {}
end

--- Clear RSSI data for a specific proxy (when proxy disconnects)
--- @param proxyDeviceId integer The proxy device ID
function DeviceRegistry:clearProxyRSSI(proxyDeviceId)
  local cleared = 0
  for _, readings in pairs(self._rssiMap) do
    if readings[proxyDeviceId] then
      readings[proxyDeviceId] = nil
      cleared = cleared + 1
    end
  end
  if cleared > 0 then
    log:debug("Cleared RSSI data for proxy device %d from %d devices", proxyDeviceId, cleared)
  end
end

return DeviceRegistry:new()
