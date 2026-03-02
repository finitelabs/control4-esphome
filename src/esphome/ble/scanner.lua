--- BLE scanner for discovering Bluetooth devices.
--- Supports multiple scanner nodes (local ESPHome, coordinator proxies, etc.)
--- Pure scanning functionality - no property management.

local log = require("lib.logging")
local persist = require("lib.persist")
local deferred = require("deferred")

local BLEAddress = require("esphome.ble.address")
local BTHome = require("bthome")
local Govee = require("esphome.ble.parsers.govee")
local SwitchBot = require("esphome.ble.parsers.switchbot")
local Yale = require("esphome.ble.parsers.yale")
local UUID = require("esphome.ble.uuid")

--- Persistence key for discovered devices
local DISCOVERED_DEVICES_KEY = "DiscoveredBLEDevices"

--- Scan duration limits (in seconds)
--- @type number
local MIN_SCAN_DURATION = 5
--- @type number
local MAX_SCAN_DURATION = 60
--- @type number
local DEFAULT_SCAN_DURATION = 10

--- Build a display string for a device.
--- Note: Commas are removed since C4 uses them as option separators.
--- @param advertisement BLEAdvertisement The accumulated advertisement data
--- @param deviceType string|nil The derived device type (e.g., "BTHome V2", "SwitchBot Meter")
--- @param isPassive boolean Whether device uses passive mode
--- @return string displayName The formatted display name for device selection UI
local function buildDisplayName(advertisement, deviceType, isPassive)
  local parts = { advertisement.mac }
  if not IsEmpty(advertisement.name) then
    table.insert(parts, advertisement.name)
  else
    table.insert(parts, "Unnamed")
  end
  local info = {}
  if not IsEmpty(deviceType) then
    table.insert(info, deviceType)
  elseif not IsEmpty(advertisement.manufacturer) then
    table.insert(info, advertisement.manufacturer)
  end
  -- Add connection type indicator
  table.insert(info, isPassive and "Passive Connection" or "Active Connection")
  if #info > 0 then
    table.insert(parts, "[" .. table.concat(info, " / ") .. "]")
  end
  return (table.concat(parts, " - "):gsub(",", ""))
end

--- @class BLEScanner
--- @field _nodes table<string|number, BLEScannerNode?> Scanner nodes keyed by ID
--- @field _scanDeferred Deferred<table<string, BLEDiscoveredDevice?>, string>|nil The deferred for the current scan (nil if not scanning)
--- @field _scanDuration number Scan duration in seconds
--- @field _onScanStart fun()|nil Callback invoked when scan starts (before collecting advertisements)
--- @field _onScanEnd fun()|nil Callback invoked when scan ends (after scan completes or is cancelled)
--- @field _accumulatedAdvertisements table<string, BLEAdvertisement?>? Advertisements collected during active scan, keyed by MAC
local BLEScanner = {}
BLEScanner.__index = BLEScanner

--- Device type to Control4 binding class mapping.
--- Maps device type strings to the binding class for sub-drivers.
--- @type table<string, string?>
local BINDING_CLASSES = {
  -- BTHome devices
  ["BTHome V1"] = "ESPHOME_BTHOME",
  ["BTHome V1 (Encrypted)"] = "ESPHOME_BTHOME",
  ["BTHome V2"] = "ESPHOME_BTHOME",
  -- SwitchBot devices
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.BOT]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER_PLUS]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER_PRO]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER_PRO_CO2]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.INDOOR_OUTDOOR_METER]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.MOTION]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.CONTACT]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.PRESENCE]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.WATER_LEAK]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.PLUG_MINI]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1PM]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_2PM]] = "ESPHOME_SWITCHBOT",
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.REMOTE]] = "ESPHOME_SWITCHBOT",
  -- Govee devices (temperature/humidity sensors)
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5051]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5052]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5071]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5072]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5074]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5075]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5100]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5101]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5102]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5103]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5104]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5105]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5106]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5108]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5110]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5112]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5174]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5177]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5178]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5179]] = "ESPHOME_GOVEE",
  -- Govee devices (meat thermometers)
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5055]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5181]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5182]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5183]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5184]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5185]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5191]] = "ESPHOME_GOVEE",
  [Govee.DEVICE_NAMES[Govee.DeviceModel.H5198]] = "ESPHOME_GOVEE",
  -- Yale/August locks
  [Yale.DEVICE_NAMES.LOCK] = "ESPHOME_YALE",
}

--- Device types that require active GATT connections (use a connection slot).
--- All other devices default to passive advertisement mode.
--- @type table<string, boolean?>
local ACTIVE_DEVICES = {
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.BOT]] = true,
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.PLUG_MINI]] = true,
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1]] = true,
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1PM]] = true,
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_2PM]] = true,
  -- Yale/August locks (require GATT connection for control)
  [Yale.DEVICE_NAMES.LOCK] = true,
}

--- Filter functions that determine which BLE advertisements to include in discovery.
--- Each filter is a function that returns true if the advertisement should be INCLUDED.
--- @type table<string, (fun(message: BLEAdvertisement): boolean)?>
local FILTERS = {
  -- Include devices with stable addresses (exclude RPA and Non-Resolvable)
  ["Invalid MAC Address"] = function(message)
    return message.mac ~= nil and message.mac ~= "00:00:00:00:00:00"
  end,
  -- Include devices with stable addresses (exclude RPA and Non-Resolvable)
  ["Random Address"] = function(message)
    local addrType = message.addressType
    if addrType == nil then
      return true -- Include if unknown
    end
    -- Include Public (0) and Random Static (1) addresses only
    return addrType == BLEAddress.Type.PUBLIC or addrType == BLEAddress.Type.RANDOM
  end,
  -- Exclude Apple devices (they use rotating private addresses for privacy)
  ["Apple"] = function(message)
    for _, mfg in ipairs(message.manufacturerData or {}) do
      -- Apple company ID: 0x004C, first byte of data is continuity type
      if mfg.company == 0x004C then
        return false
      end
    end
    return true -- Include non-transient devices
  end,
}

--- @class BLEDiscoveredDevice
--- @field name string? Device name if available
--- @field displayName string Formatted display name for UI
--- @field mac string MAC address in format "AA:BB:CC:DD:EE:FF"
--- @field address number MAC address as 48-bit number
--- @field addressType BLEAddressType? Address type (0=PUBLIC, 1=RANDOM_STATIC, 2=RPA, 3=NON_RESOLVABLE)
--- @field manufacturer string? Manufacturer name from company ID lookup
--- @field deviceType string? Device type derived from service data, service UUIDs, or manufacturer data
--- @field bindingClass string? Control4 binding class if device supports a sub-driver
--- @field passive boolean Whether device uses passive advertisement mode (no connection slot needed)
--- @field lastSeen integer Timestamp of last advertisement

--- Creates a new BLEScanner instance.
--- @return BLEScanner scanner A new scanner instance
function BLEScanner:new()
  log:trace("BLEScanner:new()")
  local instance = setmetatable({}, self)
  instance._nodes = {}
  instance._scanDeferred = nil
  instance._scanDuration = DEFAULT_SCAN_DURATION
  instance._onScanStart = nil
  instance._onScanEnd = nil
  instance._accumulatedAdvertisements = nil

  return instance
end

------------------------------------------------------------
-- Node Management
------------------------------------------------------------

--- Add a scanner node.
--- @param node BLEScannerNode The node to add
function BLEScanner:addNode(node)
  local nodeId = node:getId()
  if self._nodes[nodeId] then
    log:warn("BLEScanner: replacing existing node %s", nodeId)
  end
  self._nodes[nodeId] = node
  log:info("BLEScanner: added node %s (total: %d)", nodeId, self:getNodeCount())
end

--- Remove a scanner node by ID.
--- @param nodeId string|number The node ID to remove
--- @return boolean removed True if a node was removed
function BLEScanner:removeNode(nodeId)
  local node = self._nodes[nodeId]
  if node then
    -- Clear any active callbacks
    node:clearAdvertisementCallback()
    self._nodes[nodeId] = nil
    log:info("BLEScanner: removed node %s (total: %d)", nodeId, self:getNodeCount())
    return true
  end
  return false
end

--- Get a node by ID.
--- @param nodeId string|number The node ID
--- @return BLEScannerNode|nil node The node or nil if not found
function BLEScanner:getNode(nodeId)
  return self._nodes[nodeId]
end

--- Get all nodes.
--- @return table<string|number, BLEScannerNode?> nodes Map of node ID to node
function BLEScanner:getNodes()
  return self._nodes
end

--- Get the count of nodes.
--- @return number count Number of nodes
function BLEScanner:getNodeCount()
  local count = 0
  for _ in pairs(self._nodes) do
    count = count + 1
  end
  return count
end

--- Check if any node is connected.
--- @return boolean hasConnected True if at least one node is connected
function BLEScanner:hasConnectedNodes()
  for _, node in pairs(self._nodes) do
    if node:isConnected() then
      return true
    end
  end
  return false
end

--- Get list of connected nodes.
--- @return BLEScannerNode[] connectedNodes Array of connected nodes
function BLEScanner:getConnectedNodes()
  local connected = {}
  for _, node in pairs(self._nodes) do
    if node:isConnected() then
      table.insert(connected, node)
    end
  end
  return connected
end

------------------------------------------------------------
-- Device type derivers
-- Each entry has:
--   name: string - Human-readable name for logging
--   match: function(message) -> boolean - Returns true if this deriver applies
--   derive: function(message) -> string|nil - Returns device type or nil
------------------------------------------------------------

--- @class DeviceDeriver
--- @field name string Human-readable name for logging
--- @field derive fun(message: BLEAdvertisement): string|nil Returns device type or nil

--- Unified list of device type derivers, checked in order.
--- @type DeviceDeriver[]
local DEVICE_DERIVERS = {
  {
    name = "BTHome",
    derive = function(message)
      local _, uuid =
        UUID.findData(message.serviceData, BTHome.UUID_V2, BTHome.UUID_V1_UNENCRYPTED, BTHome.UUID_V1_ENCRYPTED)
      if BTHome.UUID_V2 == uuid then
        return "BTHome V2"
      elseif BTHome.UUID_V1_UNENCRYPTED == uuid then
        return "BTHome V1"
      elseif BTHome.UUID_V1_ENCRYPTED == uuid then
        return "BTHome V1 (Encrypted)"
      end
      return nil
    end,
  },
  {
    name = "SwitchBot",
    derive = function(message)
      return Select(SwitchBot.parse(message.serviceData, message.manufacturerData), "deviceType")
    end,
  },
  {
    name = "Govee",
    derive = function(message)
      return Select(Govee.parse(message.manufacturerData, message.serviceData, message.name), "deviceType")
    end,
  },
  {
    name = "Yale",
    derive = function(message)
      return Select(Yale.parse(message.serviceData, message.manufacturerData), "deviceType")
    end,
  },
}

--- Set the scan duration.
--- @param duration number Scan duration in seconds (clamped to MIN_SCAN_DURATION-MAX_SCAN_DURATION)
function BLEScanner:setScanDuration(duration)
  log:trace("BLEScanner:setScanDuration(%s)", duration)
  local value = tointeger(duration) or DEFAULT_SCAN_DURATION
  self._scanDuration = math.max(MIN_SCAN_DURATION, math.min(MAX_SCAN_DURATION, value))
end

--- Get the scan duration.
--- @return number duration Scan duration in seconds
function BLEScanner:getScanDuration()
  return self._scanDuration or DEFAULT_SCAN_DURATION
end

--- Set the callback to invoke when a scan starts.
--- Use this to prepare for scanning (e.g., clear advertisement filters).
--- @param callback fun()|nil The callback function or nil to clear
function BLEScanner:setOnScanStart(callback)
  log:trace("BLEScanner:setOnScanStart(%s)", callback and "<fn>" or "nil")
  self._onScanStart = callback
end

--- Set the callback to invoke when a scan ends (completes or is cancelled).
--- Use this to restore state after scanning (e.g., restore advertisement filters).
--- @param callback fun()|nil The callback function or nil to clear
function BLEScanner:setOnScanEnd(callback)
  log:trace("BLEScanner:setOnScanEnd(%s)", callback and "<fn>" or "nil")
  self._onScanEnd = callback
end

--- Check if a scan is currently in progress.
--- @return boolean isScanning True if scanning
function BLEScanner:isScanning()
  return self._scanDeferred ~= nil
end

--- Get discovered devices from persistent storage.
--- @return table<string, BLEDiscoveredDevice?> devices Map of MAC to device info
--- @diagnostic disable-next-line: unused
function BLEScanner:getDiscoveredDevices()
  log:trace("BLEScanner:getDiscoveredDevices()")
  return persist:get(DISCOVERED_DEVICES_KEY, {}) or {}
end

--- Save discovered devices to persistent storage.
--- @private
--- @param devices table<string, BLEDiscoveredDevice?>|nil devices Map of MAC to device info (nil to clear)
--- @diagnostic disable-next-line: unused
function BLEScanner:_setDiscoveredDevices(devices)
  log:trace("BLEScanner:_setDiscoveredDevices()")
  persist:set(DISCOVERED_DEVICES_KEY, not IsEmpty(devices) and devices or nil)
end

--- Derive device type from advertisement data.
--- Iterates through DEVICE_DERIVERS in order, returning the first match, or nil if none match.
--- @param message BLEAdvertisement The accumulated advertisement message
--- @return string|nil deviceType The derived device type or nil
local function deriveDeviceType(message)
  -- Try each deriver in order
  for _, deriver in ipairs(DEVICE_DERIVERS) do
    local deviceType = deriver.derive(message)
    if not IsEmpty(deviceType) then
      log:debug("Device type derived by %s: %s", deriver.name, deviceType)
      return deviceType
    end
  end

  return nil
end

--- Finalize accumulated device data into a BLEDiscoveredDevice.
--- @private
--- @param advertisement BLEAdvertisement The accumulated advertisement data
--- @return BLEDiscoveredDevice device The finalized device info
local function finalizeDevice(advertisement)
  local deviceType = deriveDeviceType(advertisement)
  local bindingClass = deviceType and BINDING_CLASSES[deviceType] or nil
  local isPassive = not (deviceType and ACTIVE_DEVICES[deviceType])

  --- @type BLEDiscoveredDevice
  local device = {
    name = advertisement.name,
    displayName = buildDisplayName(advertisement, deviceType, isPassive),
    mac = advertisement.mac,
    address = advertisement.address,
    addressType = advertisement.addressType,
    manufacturer = advertisement.manufacturer,
    deviceType = deviceType,
    bindingClass = bindingClass,
    passive = isPassive,
    lastSeen = os.time(),
  }

  return device
end

--- Accumulate advertisement data into existing record.
--- @private
--- @param accumulated BLEAdvertisement The accumulated data
--- @param message BLEAdvertisement The new advertisement
local function accumulateAdvertisement(accumulated, message)
  -- Store addressType (0=Public, 1=Random Static, 2=RPA, 3=Non-Resolvable)
  if message.addressType ~= nil and accumulated.addressType == nil then
    accumulated.addressType = message.addressType
  end

  -- Accumulate best RSSI (closest signal)
  if type(message.rssi) == "number" and (type(accumulated.rssi) ~= "number" or message.rssi > accumulated.rssi) then
    accumulated.rssi = message.rssi
  end

  -- Accumulate name (keep first non-nil)
  if not IsEmpty(message.name) and IsEmpty(accumulated.name) then
    accumulated.name = message.name
  end

  -- Accumulate manufacturer (keep first non-nil)
  if not IsEmpty(message.manufacturer) and IsEmpty(accumulated.manufacturer) then
    accumulated.manufacturer = message.manufacturer
  end

  -- Accumulate best TX power (highest power)
  if
    type(message.txPower) == "number"
    and (type(accumulated.txPower) ~= "number" or message.txPower > accumulated.txPower)
  then
    accumulated.txPower = message.txPower
  end

  -- Accumulate service UUIDs (by UUID to avoid duplicates)
  accumulated.serviceUuids = UniqueList(ConcatLists(accumulated.serviceUuids, message.serviceUuids), function(v)
    --- @cast v BLEServiceUUID
    return v.uuid
  end)

  -- Accumulate service data (by UUID to avoid duplicates)
  accumulated.serviceData = UniqueList(ConcatLists(accumulated.serviceData, message.serviceData), function(v)
    --- @cast v BLEServiceData
    return v.uuid
  end)

  -- Accumulate manufacturer data (by company to avoid duplicates)
  accumulated.manufacturerData = UniqueList(
    ConcatLists(accumulated.manufacturerData, message.manufacturerData),
    function(v)
      --- @cast v BLEManufacturerData
      return v.company
    end
  )
end

--- Check if an advertisement should be included.
--- All filters must return true for the advertisement to be included.
--- @param message BLEAdvertisement The enriched advertisement message
--- @return boolean shouldInclude True if this advertisement should be included
local function shouldInclude(message)
  for filterName, filterFunc in pairs(FILTERS) do
    if type(filterFunc) == "function" and not filterFunc(message) then
      log:trace("Excluding device %s (%s)", message.mac, filterName)
      return false
    end
  end
  return true
end

--- Start a BLE scan to discover nearby devices.
--- Scans all connected nodes and aggregates results.
--- @return Deferred<table<string, BLEDiscoveredDevice?>, string> deferred Resolves when scan completes
function BLEScanner:scan()
  log:trace("BLEScanner:scan()")
  --- @type Deferred<table<string, BLEDiscoveredDevice?>, string>
  local d = deferred.new()

  if self:isScanning() then
    log:warn("BLE scan already in progress")
    return d:reject("Scan already in progress")
  end

  local connectedNodes = self:getConnectedNodes()
  if #connectedNodes == 0 then
    log:error("Cannot start BLE scan: no connected nodes")
    return d:reject("No connected nodes")
  end

  self._scanDeferred = d

  -- Invoke onScanStart callback (e.g., to clear advertisement filters)
  if self._onScanStart then
    local ok, err = pcall(self._onScanStart)
    if not ok then
      log:error("onScanStart callback failed: %s", err or "unknown error")
    end
  end

  -- Accumulate raw advertisement data during scan, finalize at end
  -- Stored as instance variable so stopScan() can access it
  self._accumulatedAdvertisements = {}

  log:info("Starting BLE scan for %d seconds on %d node(s)...", self._scanDuration, #connectedNodes)

  -- Register callbacks on all connected nodes
  for _, node in ipairs(connectedNodes) do
    node:setAdvertisementCallback(function(message, nodeId)
      -- Apply filters (skip if not included)
      if not shouldInclude(message) then
        return
      end

      local mac = message.mac
      local existing = self._accumulatedAdvertisements[mac]
      if existing == nil then
        log:debug("Discovered BLE device: %s (via node %s)", mac, nodeId)
        self._accumulatedAdvertisements[mac] = message
      else
        accumulateAdvertisement(existing, message)
      end
    end)
  end

  -- Start scan timer
  SetTimer("BLEScanTimeout", self._scanDuration * ONE_SECOND, function()
    self:_finalizeScan()
  end)

  return d
end

--- Finalize an active scan, optionally saving discovered devices.
--- Called by scan timer, stopScan(), or abortScan().
--- @param save boolean? If true, save discovered devices and resolve; if false, discard and reject (default: true)
function BLEScanner:_finalizeScan(save)
  log:trace("BLEScanner:_finalizeScan(%s)", save)
  if save == nil then
    save = true
  end

  local d = self._scanDeferred
  local accumulatedAdvertisements = self._accumulatedAdvertisements or {}

  self._scanDeferred = nil
  self._accumulatedAdvertisements = nil

  -- Cancel the scan timer (in case called early by stopScan/abortScan)
  CancelTimer("BLEScanTimeout")

  -- Clear callbacks on all nodes
  for _, node in pairs(self._nodes) do
    node:clearAdvertisementCallback()
  end

  -- Finalize accumulated data into device records
  local discoveredDevices = {}
  for mac, accumulatedAdvertisement in pairs(accumulatedAdvertisements) do
    discoveredDevices[mac] = finalizeDevice(accumulatedAdvertisement)
  end

  -- Invoke onScanEnd callback (e.g., to restore advertisement filters)
  if self._onScanEnd then
    local ok, err = pcall(self._onScanEnd)
    if not ok then
      log:error("onScanEnd callback failed: %s", err or "unknown error")
    end
  end

  if save then
    log:info("BLE scan complete. Found %d device(s)", TableLength(discoveredDevices))
    self:_setDiscoveredDevices(discoveredDevices)
    if d then
      d:resolve(discoveredDevices)
    end
  else
    log:info("BLE scan aborted. Discarded %d device(s)", TableLength(discoveredDevices))
    if d then
      d:reject("Scan aborted")
    end
  end
end

--- Resets the scanner, aborting any active scan and clearing discovered devices.
function BLEScanner:reset()
  log:trace("BLEScanner:reset()")
  self:abortScan()
  self:_setDiscoveredDevices(nil)
end

--- Stop an active BLE scan early, keeping devices discovered so far.
--- Finalizes and saves accumulated advertisements, then resolves the deferred.
--- @return boolean stopped True if a scan was stopped, false if no scan was active
function BLEScanner:stopScan()
  log:trace("BLEScanner:stopScan()")

  if not self:isScanning() then
    log:debug("No scan in progress to stop")
    return false
  end

  log:debug("Stopping BLE scan (keeping discovered devices)...")
  self:_finalizeScan(true)
  return true
end

--- Abort an active BLE scan, discarding any devices discovered so far.
--- Stops the scan timer and rejects the scan deferred.
--- @return boolean aborted True if a scan was aborted, false if no scan was active
function BLEScanner:abortScan()
  log:trace("BLEScanner:abortScan()")

  if not self:isScanning() then
    log:debug("No scan in progress to abort")
    return false
  end

  log:debug("Aborting BLE scan (discarding discovered devices)...")
  self:_finalizeScan(false)
  return true
end

--- Route an advertisement to the scanner.
--- This is the main entry point for external advertisement sources (e.g., coordinator bindings).
--- Only processes the advertisement if a scan is active; otherwise does nothing.
--- @param advertisement BLEAdvertisement The pre-parsed advertisement
--- @param nodeId string|number The source node ID
function BLEScanner:onAdvertisement(advertisement, nodeId)
  if not self:isScanning() then
    return
  end

  local node = self._nodes[nodeId]
  if node then
    node:onAdvertisement(advertisement)
  end
end

--- Process an advertisement passively (outside of an active scan).
--- Use this to accumulate devices as they are discovered continuously.
--- Updates the discovered devices in persistent storage.
--- @param advertisement BLEAdvertisement The advertisement message
--- @param nodeId string|number|nil The source node ID (for logging)
--- @return BLEDiscoveredDevice|nil device The discovered device if included, nil if filtered
function BLEScanner:processAdvertisement(advertisement, nodeId)
  -- Apply filters
  if not shouldInclude(advertisement) then
    return nil
  end

  local mac = advertisement.mac
  if not mac then
    return nil
  end

  -- Load existing discovered devices
  local devices = self:getDiscoveredDevices()
  local existing = devices[mac]

  if existing then
    -- Accumulate into existing advertisement data
    -- We need to convert the existing device back to advertisement format
    --- @type BLEAdvertisement
    local accumulated = {
      mac = existing.mac,
      address = existing.address,
      addressType = existing.addressType,
      name = existing.name,
      manufacturer = existing.manufacturer,
      -- Note: we don't have full service/manufacturer data from stored device,
      -- but we can still accumulate new data
      serviceData = advertisement.serviceData,
      manufacturerData = advertisement.manufacturerData,
      serviceUuids = advertisement.serviceUuids,
      rssi = advertisement.rssi,
    }
    accumulateAdvertisement(accumulated, advertisement)
    devices[mac] = finalizeDevice(accumulated)
  else
    -- New device
    log:debug("Passively discovered BLE device: %s (via node %s)", mac, nodeId or "unknown")
    devices[mac] = finalizeDevice(advertisement)
  end

  -- Save updated devices
  self:_setDiscoveredDevices(devices)

  return devices[mac]
end

return BLEScanner:new()
