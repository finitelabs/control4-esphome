local bit32 = require("bitn").bit32

local constants = require("constants")

local log = require("lib.logging")
local bindings = require("lib.bindings")

local ESPHomeProtoSchema = require("esphome.proto_schema")
local BLEAddress = require("esphome.ble.address")
local UUID = require("esphome.ble.uuid")

local bleScannerProperties = require("esphome.ble.scanner_properties")

--- Bluetooth proxy feature flags (from ESPHome API)
local FEATURE_FLAGS = {
  PASSIVE_SCAN = 0x01,
  ACTIVE_CONNECTIONS = 0x02,
  REMOTE_CACHING = 0x04,
  PAIRING = 0x08,
  CACHE_CLEARING = 0x10,
  RAW_ADVERTISEMENTS = 0x20,
  SCANNER_STATE = 0x40,
}

--- Watchdog timeout for stuck scanner detection (in seconds).
--- If no BLE advertisements are received for this duration while scanner should be running,
--- attempt recovery by toggling scanner mode.
local SCANNER_WATCHDOG_TIMEOUT_SECONDS = 90

--- Timer key for the scanner watchdog
local SCANNER_WATCHDOG_TIMER_KEY = "BLEScannerWatchdog"

--- Reverse lookup for BluetoothScannerState enum (value -> display name)
--- States that involve active scanning will have mode appended (e.g., "Scanning (Passive)")
--- @type table<ProtoBluetoothScannerState, string?>
local SCANNER_STATE_NAMES = {
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_IDLE] = "Scanner Idle",
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_STARTING] = "Starting Scan",
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_RUNNING] = "Scanning",
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_FAILED] = "Scan Failed",
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_STOPPING] = "Stopping Scan",
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_STOPPED] = "Scanner Stopped",
}

--- States where scanner mode should be shown
--- @type table<ProtoBluetoothScannerState, boolean?>
local SCANNER_STATE_SHOW_MODE = {
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_STARTING] = true,
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_RUNNING] = true,
  [ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_STOPPING] = true,
}

--- Reverse lookup for BluetoothScannerMode enum (value -> display name)
--- @type table<ProtoBluetoothScannerMode, string?>
local SCANNER_MODE_NAMES = {
  [ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE] = "Passive",
  [ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_ACTIVE] = "Active",
}

--- @class BluetoothProxyCapability : Capability
--- @field _client ESPHomeClient The ESPHome client instance
--- @field _addedDevices table<string, AddedDevice?> Added devices
--- @field _featureFlags integer Bluetooth proxy feature flags
--- @field _previousAllocated table<string, boolean?> Track allocated MACs for disconnect detection
--- @field _coordinatorConnected boolean Whether coordinator is connected
--- @field _coordinatorBindingId number|nil Binding ID for coordinator (5001 if connected)
--- @field _coordinatorCallbackId string|nil Callback ID for coordinator advertisement forwarding
--- @field _advertisementFilter table<string, boolean>|nil MAC filter set (nil = pass all)
--- @field _scannerWatchdogActive boolean Whether the scanner watchdog is active
--- @field _scannerWatchdogSeen boolean Whether any advertisements were received since last watchdog check
--- @field _scannerRecoveryAttempts integer Number of recovery attempts since last successful scan
--- @field _restartButtonKey number|nil The key of the restart button entity (nil if not found)
local BluetoothProxyCapability = {
  TYPE = "bluetooth_proxy",
  LABEL_PROPERTY_NAME = "Bluetooth Proxy Settings",
  PROPERTY_NAME = "Select Bluetooth Devices",
  STATUS_PROPERTY_NAME = "Bluetooth Proxy Status",
  CAPABILITIES_PROPERTY_NAME = "Bluetooth Proxy Capabilities",
  ROOM_PROPERTY_NAME = "Bluetooth Proxy Room",
  SCAN_DURATION_PROPERTY_NAME = "Bluetooth Scan Duration",
  MIN_RSSI_OVERRIDE_PROPERTY_NAME = "Minimum Room RSSI Override (dBm)",
  COORDINATOR_BINDING_KEY = "coordinator", -- Key for dynamic binding
}
BluetoothProxyCapability.__index = BluetoothProxyCapability

--- The key used to persist selected bluetooth devices.
--- @type string
local SELECTED_BLUETOOTH_DEVICES_PERSIST_KEY = "SelectedBluetoothDevices"

--- Default BLE address type (PUBLIC) used when not provided by discovery.
--- Home Assistant/bleak also defaults to PUBLIC for unknown devices.
local DEFAULT_ADDRESS_TYPE = BLEAddress.Type.PUBLIC

--- @class AddedDevice
--- @field name string|nil Device name from advertisement
--- @field addressType BLEAddressType Address type, defaults to PUBLIC (0) if not set
--- @field services table[]|nil GATT services discovered
--- @field deviceType string|nil Device type (e.g., "SwitchBot Bot")
--- @field bindingClass string|nil Control4 binding class (e.g., "ESPHOME_SWITCHBOT")
--- @field bindingId number|nil Control4 binding ID
--- @field passive boolean Whether device uses passive advertisement mode (no GATT connection)

--- Decode feature flags to human-readable capabilities.
--- @param flags integer The feature flags bitmask
--- @return string capabilities Comma-separated list of capabilities
local function decodeFeatureFlags(flags)
  local caps = {}

  if bit32.band(flags, FEATURE_FLAGS.PASSIVE_SCAN) ~= 0 then
    table.insert(caps, "Scan")
  end
  if bit32.band(flags, FEATURE_FLAGS.ACTIVE_CONNECTIONS) ~= 0 then
    table.insert(caps, "Connect")
  end
  if bit32.band(flags, FEATURE_FLAGS.REMOTE_CACHING) ~= 0 then
    table.insert(caps, "Cache")
  end
  if bit32.band(flags, FEATURE_FLAGS.PAIRING) ~= 0 then
    table.insert(caps, "Pair")
  end
  if bit32.band(flags, FEATURE_FLAGS.RAW_ADVERTISEMENTS) ~= 0 then
    table.insert(caps, "Raw")
  end

  return #caps > 0 and table.concat(caps, ", ") or "None"
end

--- Create a new instance of the bluetooth proxy capability.
--- @param client ESPHomeClient The ESPHome client instance
--- @return BluetoothProxyCapability capability A new instance of the BluetoothProxyCapability capability
function BluetoothProxyCapability:new(client)
  local instance = setmetatable({}, self)
  instance._client = client
  instance._addedDevices = {}
  instance._featureFlags = 0
  instance._previousAllocated = {}
  instance._coordinatorConnected = false
  instance._coordinatorCallbackId = nil
  instance._coordinatorBindingId = nil
  instance._advertisementFilter = nil
  instance._scannerWatchdogActive = false
  instance._scannerWatchdogSeen = false
  instance._scannerRecoveryAttempts = 0
  instance._restartButtonKey = nil
  return instance
end

function BluetoothProxyCapability:setPropertiesAttribs(show)
  C4:SetPropertyAttribs(self.LABEL_PROPERTY_NAME, show)
  C4:SetPropertyAttribs(self.STATUS_PROPERTY_NAME, show)
  C4:SetPropertyAttribs(self.CAPABILITIES_PROPERTY_NAME, show)

  -- Device selection and room/minRssiOverride are mutually exclusive based on coordinator connection
  if self._coordinatorConnected then
    -- Coordinator mode: show room selector and minRssiOverride, hide device selection
    C4:SetPropertyAttribs(self.ROOM_PROPERTY_NAME, show)
    C4:SetPropertyAttribs(self.MIN_RSSI_OVERRIDE_PROPERTY_NAME, show)
    C4:SetPropertyAttribs(self.PROPERTY_NAME, constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs(self.SCAN_DURATION_PROPERTY_NAME, constants.HIDE_PROPERTY)
  else
    -- Standalone mode: show device selection, hide room selector and minRssiOverride
    C4:SetPropertyAttribs(self.ROOM_PROPERTY_NAME, constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs(self.MIN_RSSI_OVERRIDE_PROPERTY_NAME, constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs(self.PROPERTY_NAME, show)
    C4:SetPropertyAttribs(self.SCAN_DURATION_PROPERTY_NAME, show)
  end
end

--- Mark that an advertisement was received.
--- Called when advertisements are received to indicate scanner is working.
--- @private
function BluetoothProxyCapability:_onAdvertisementReceived()
  self._scannerWatchdogSeen = true
end

--- Start the scanner watchdog.
--- Only starts if a restart button is available for recovery.
--- @private
function BluetoothProxyCapability:_startScannerWatchdog()
  if self._scannerWatchdogActive then
    return
  end

  -- Only enable watchdog if we have a restart button for recovery
  if not self._restartButtonKey then
    log:debug("Scanner watchdog not started: no restart button available for recovery")
    return
  end

  log:debug("Starting scanner watchdog (interval: %ds)", SCANNER_WATCHDOG_TIMEOUT_SECONDS)
  self._scannerWatchdogActive = true
  self._scannerWatchdogSeen = false
  self._scannerRecoveryAttempts = 0

  -- Start recurring timer that checks if advertisements were received
  SetTimer(SCANNER_WATCHDOG_TIMER_KEY, SCANNER_WATCHDOG_TIMEOUT_SECONDS * ONE_SECOND, function()
    self:_onScannerWatchdogFired()
  end, true) -- recurring
end

--- Set the restart button entity key for scanner recovery.
--- Called by the driver when a restart button entity is discovered.
--- @param key number The button entity key
function BluetoothProxyCapability:setRestartButtonKey(key)
  log:debug("Restart button key set: %s", key)
  self._restartButtonKey = key
end

--- Stop the scanner watchdog.
--- @private
function BluetoothProxyCapability:_stopScannerWatchdog()
  if not self._scannerWatchdogActive then
    return
  end

  log:debug("Stopping scanner watchdog")
  self._scannerWatchdogActive = false
  self._scannerWatchdogSeen = false
  CancelTimer(SCANNER_WATCHDOG_TIMER_KEY)
end

--- Called when the scanner watchdog timer fires.
--- Checks if advertisements were received since last check; if not, attempts recovery.
--- @private
function BluetoothProxyCapability:_onScannerWatchdogFired()
  -- Check if any advertisements were received since last check
  if self._scannerWatchdogSeen then
    -- Scanner is healthy, reset flag for next interval
    if self._scannerRecoveryAttempts > 0 then
      log:info("Scanner watchdog: Advertisements resumed after %d recovery attempts", self._scannerRecoveryAttempts)
      self._scannerRecoveryAttempts = 0
    end
    self._scannerWatchdogSeen = false
    return
  end

  -- No advertisements received - check if scanner should be running
  local scannerState = self._client:getBluetoothScannerState()
  if
    scannerState.state ~= ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_RUNNING
    and scannerState.state ~= ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_STARTING
  then
    log:debug("Scanner watchdog: no advertisements but scanner not running (state=%s), ignoring", scannerState.state)
    return
  end

  -- Safety check - should not happen since watchdog only starts if we have restart button
  if not self._restartButtonKey then
    log:warn("Scanner watchdog fired but no restart button available, stopping watchdog")
    self:_stopScannerWatchdog()
    return
  end

  self._scannerRecoveryAttempts = self._scannerRecoveryAttempts + 1
  log:warn(
    "Scanner watchdog: No BLE advertisements received for %ds (attempt %d), rebooting device to recover",
    SCANNER_WATCHDOG_TIMEOUT_SECONDS,
    self._scannerRecoveryAttempts
  )

  -- Stop watchdog - device will reboot and we'll reinitialize on reconnect
  self:_stopScannerWatchdog()

  -- Attempt recovery by pressing the restart button
  self._client:pressButton(self._restartButtonKey):next(function()
    log:info("Scanner recovery: restart button pressed, device will reboot")
  end, function(err)
    log:error("Scanner recovery: failed to press restart button: %s", err)
    -- Restart the watchdog to try again later
    self:_startScannerWatchdog()
  end)
end

--- Update the read-only status property.
--- @private
function BluetoothProxyCapability:_updateStatusProperty()
  local connState = self._client:getBluetoothConnectionState()
  local scannerState = self._client:getBluetoothScannerState()
  if not connState.initialized or not scannerState.initialized then
    C4:UpdateProperty(self.STATUS_PROPERTY_NAME, "Initializing...")
    return
  end

  -- Format: "Standalone | Scanning (Passive) | 1/4 Active"
  -- or with coordinator: "Coordinator | Scanning (Passive) | 0/3 Active | MAC Filter: 5"
  local parts = {}

  if self._coordinatorConnected then
    table.insert(parts, "Coordinator Mode")
  else
    table.insert(parts, "Standalone Mode")
  end

  -- Build scanner status text (show mode only for active scanning states)
  local stateName = SCANNER_STATE_NAMES[scannerState.state] or "Unknown"
  local modeName = SCANNER_MODE_NAMES[scannerState.mode] or nil
  if modeName and SCANNER_STATE_SHOW_MODE[scannerState.state] then
    table.insert(parts, string.format("%s (%s)", stateName, modeName))
  else
    table.insert(parts, stateName)
  end

  -- Build connection slots text with optional oversubscription warning
  local slotsText = string.format("%d/%d Active", connState.limit - connState.free, connState.limit)
  local selectedActiveCount = bleScannerProperties:getSelectedActiveCount(self.PROPERTY_NAME)
  if selectedActiveCount > connState.limit then
    slotsText = slotsText .. " (Oversubscribed)"
  end
  table.insert(parts, slotsText)

  -- Build MAC filter text if coordinator is connected
  if self._coordinatorConnected then
    if self._advertisementFilter then
      local count = 0
      for _ in pairs(self._advertisementFilter) do
        count = count + 1
      end
      table.insert(parts, string.format("MAC Filter: %d device(s)", count))
    else
      table.insert(parts, "MAC Filter: none")
    end
  end

  C4:UpdateProperty(self.STATUS_PROPERTY_NAME, table.concat(parts, " | "))
  C4:UpdateProperty(self.CAPABILITIES_PROPERTY_NAME, decodeFeatureFlags(self._featureFlags))
end

--- Proceed with GATT service discovery after connection is established.
--- @param mac string MAC address
--- @param callback function|nil Optional callback(success) called when discovery completes
--- @private
function BluetoothProxyCapability:_discoverGattServices(mac, callback)
  local device = self._addedDevices[mac]
  if not device then
    log:error("Device not found for GATT discovery: %s", mac)
    if callback then
      callback(false)
    end
    return
  end

  self._client:bluetoothGattGetServices(mac):next(function(services)
    device.services = services
    log:info("GATT service discovery complete for %s (%d services)", mac, #services)
    if callback then
      callback(true)
    end
  end, function(err)
    log:error("GATT service discovery failed for %s: %s", mac, err)
    if callback then
      callback(false)
    end
  end)
end

--- Connect to a Bluetooth device.
--- Checks if the device is already connected before attempting connection.
--- @param device BLEDiscoveredDevice Device info from scanner
function BluetoothProxyCapability:connectDevice(device)
  local mac = device.mac
  log:trace("BluetoothProxyCapability:connectDevice(%s)", mac)

  -- Check if already tracked and connected
  if self._addedDevices[mac] and self._client:isBluetoothDeviceAllocated(mac) then
    log:info("Device %s already connected", mac)
    return
  end

  log:info("Connecting to Bluetooth device: %s", mac)

  -- Initialize device tracking (keyed by MAC address)
  self._addedDevices[mac] = {
    name = device.name,
    addressType = device.addressType or DEFAULT_ADDRESS_TYPE,
    services = nil,
    deviceType = device.deviceType,
    bindingClass = device.bindingClass,
    bindingId = nil,
    passive = device.passive or false,
  }

  -- Check if device is already connected
  if self._client:isBluetoothDeviceAllocated(mac) then
    log:info("Device %s already connected, using existing connection", mac)
  else
    log:debug("Device %s not currently connected, initiating connection", mac)
    self:_initiateConnection(mac)
  end
end

--- Initiate a new Bluetooth connection to a device.
--- @param mac string MAC address
--- @param callback function|nil Optional callback(success, error) when connection completes
--- @private
function BluetoothProxyCapability:_initiateConnection(mac, callback)
  local device = self._addedDevices[mac]
  if not device then
    log:error("Device not found for connection: %s", mac)
    if callback then
      callback(false, "Device not found")
    end
    return
  end

  local addressType = device.addressType or DEFAULT_ADDRESS_TYPE

  log:debug("Initiating BLE connection to %s (addressType=%d)", mac, addressType)

  self._client:bluetoothDeviceConnect(mac, addressType, false):next(function(result)
    log:debug("Bluetooth connection successful for %s: mtu=%s", mac, result.mtu)
    if callback then
      callback(true)
    end
  end, function(err)
    log:error("Failed to connect to %s: error=%s", mac, err)
    if callback then
      callback(false, err)
    end
  end)
end

--- Connect to a device and notify the child driver when complete.
--- Checks for existing connections, initiates if needed, discovers GATT services, then notifies.
--- @param mac string MAC address
--- @param idBinding number The binding ID to notify
--- @private
function BluetoothProxyCapability:_connectAndNotify(mac, idBinding)
  local device = self._addedDevices[mac]
  if not device then
    log:error("Device not found for connectAndNotify: %s", mac)
    SendToProxy(idBinding, "CONNECTION_FAILED", {
      mac = mac,
      error = "Device not found",
    }, "NOTIFY")
    return
  end

  --- Helper to discover GATT services and notify child driver
  local function discoverAndNotify()
    self:_discoverGattServices(mac, function(success)
      if success then
        SendToProxy(idBinding, "CONNECTED", {
          name = device.name,
          mac = mac,
          deviceType = device.deviceType,
          services = SerializeSafe(device.services or {}),
        }, "NOTIFY")
      else
        SendToProxy(idBinding, "CONNECTION_FAILED", {
          name = device.name,
          mac = mac,
          deviceType = device.deviceType,
          error = "GATT discovery failed",
        }, "NOTIFY")
      end
    end)
  end

  --- Helper to notify child driver of failure
  local function onFailed(error)
    SendToProxy(idBinding, "CONNECTION_FAILED", {
      mac = mac,
      error = tostring(error or "Unknown error"),
    }, "NOTIFY")
  end

  -- Check if device is already connected
  if self._client:isBluetoothDeviceAllocated(mac) then
    log:info("Device %s already connected, using existing connection", mac)
    discoverAndNotify()
    return
  end

  -- Check slot availability from cached state (skip if not initialized yet)
  local state = self._client:getBluetoothConnectionState()
  if state.initialized and state.free <= 0 then
    log:warn("No connection slots available for %s", mac)
    onFailed("No connection slots available")
    return
  end

  -- Initiate connection
  log:debug("Initiating BLE connection to %s", mac)
  self:_initiateConnection(mac, function(success, error)
    if success then
      -- Brief delay before GATT discovery to allow ESPHome to fully establish the connection.
      -- Without this delay, GATT service discovery may return 0 services.
      SetTimer("GattDiscovery_" .. mac:gsub(":", ""), 500, discoverAndNotify)
    else
      onFailed(error)
    end
  end)
end

--- Disconnect from a Bluetooth device.
--- @param mac string MAC address
function BluetoothProxyCapability:disconnectDevice(mac)
  log:trace("BluetoothProxyCapability:disconnectDevice(%s)", mac)

  local device = self._addedDevices[mac]
  if not device then
    return
  end

  -- Delete dynamic binding
  if device.bindingId then
    local bindingKey = "bt_" .. mac:gsub(":", "")
    bindings:deleteBinding(self.TYPE, bindingKey)
  end

  -- Disconnect from device
  self._client:bluetoothDeviceDisconnect(mac)

  self._addedDevices[mac] = nil
  log:info("Disconnected from Bluetooth device: %s", mac)
end

--- Handle commands from sub-driver.
--- @param mac string MAC address
--- @param idBinding number Binding ID
--- @param strCommand string Command string
--- @param tParams table Command parameters
--- @param args table Command arguments
function BluetoothProxyCapability:handleCommand(mac, idBinding, strCommand, tParams, args)
  log:trace("BluetoothProxyCapability:handleCommand(%s, %s, %s, %s, %s)", mac, idBinding, strCommand, tParams, args)

  local device = self._addedDevices[mac]
  if not device then
    log:error("Device not found for command %s: %s", strCommand, mac)
    return
  end

  -- Handle CONNECT command - initiates BLE connection with GATT discovery
  if strCommand == "CONNECT" then
    -- Check if device is already allocated (connected)
    local isAllocated = self._client:isBluetoothDeviceAllocated(mac)

    if isAllocated then
      -- Device already connected - check if we have cached services
      if device.services and #device.services > 0 then
        log:info("Device %s already connected with %d cached services", mac, #device.services)
        SendToProxy(idBinding, "CONNECTED", {
          name = device.name,
          mac = mac,
          deviceType = device.deviceType,
          services = SerializeSafe(device.services),
        }, "NOTIFY")
      else
        -- Connected but no cached services - discover them
        log:info("Device %s connected but no cached services, discovering", mac)
        self:_discoverGattServices(mac, function(success)
          if success then
            SendToProxy(idBinding, "CONNECTED", {
              name = device.name,
              mac = mac,
              deviceType = device.deviceType,
              services = SerializeSafe(device.services or {}),
            }, "NOTIFY")
          else
            SendToProxy(idBinding, "CONNECTION_FAILED", {
              mac = mac,
              error = "GATT discovery failed",
            }, "NOTIFY")
          end
        end)
      end
    else
      -- Device not connected - check if we have a slot available
      local state = self._client:getBluetoothConnectionState()
      if state.initialized and state.free <= 0 then
        log:warn("No connection slots available for %s (0/%d free)", mac, state.limit)
        SendToProxy(idBinding, "CONNECTION_FAILED", {
          mac = mac,
          error = "No connection slots available",
        }, "NOTIFY")
        return
      end

      log:info("Initiating BLE connection for %s", mac)
      self:_connectAndNotify(mac, idBinding)
    end
    return
  end

  -- Handle DISCONNECT command - releases BLE connection slot
  if strCommand == "DISCONNECT" then
    -- Always clear cached services on disconnect request - handles may change after reconnect
    device.services = nil
    if self._client:isBluetoothDeviceAllocated(mac) then
      log:info("Disconnecting from %s (child requested)", mac)
      self._client:bluetoothDeviceDisconnect(mac)
      -- Note: DISCONNECTED will be sent via allocation change callback
    else
      log:debug("Device %s not connected, ignoring DISCONNECT", mac)
    end
    return
  end

  -- GATT commands use client's auto-connect feature - no need to check device.connected
  -- The client will automatically connect if the device is not already connected
  local addressType = device.addressType or DEFAULT_ADDRESS_TYPE

  if strCommand == "GATT_WRITE" then
    local handle = tonumber(Select(tParams, "handle"))
    local data = C4:Base64Decode(Select(tParams, "data") or "") -- Base64 encoded to preserve null bytes
    local needResponse = Select(tParams, "response") == "true"

    if not handle or not data or #data == 0 then
      log:error("Invalid GATT_WRITE parameters: handle=%s, data=%s", handle, data)
      return
    end

    log:debug("GATT write to %s handle %d: %d bytes, response=%s", mac, handle, #data, needResponse)

    self._client:bluetoothGattWrite(mac, handle, data, needResponse, addressType):next(function()
      log:trace("GATT write OK for %s handle %d", mac, handle)
      SendToProxy(idBinding, "GATT_WRITE_RESPONSE", {
        success = "true",
        error = "0",
      }, "NOTIFY")
    end, function(error)
      log:error("GATT write FAILED for %s handle %d: %s", mac, handle, error)
      SendToProxy(idBinding, "GATT_WRITE_RESPONSE", {
        success = "false",
        error = tostring(error or -1),
      }, "NOTIFY")
    end)
  elseif strCommand == "GATT_READ" then
    local handle = tonumber(Select(tParams, "handle"))

    if not handle then
      log:error("Invalid GATT_READ parameters")
      return
    end

    log:debug("GATT read from %s handle %d", mac, handle)

    self._client:bluetoothGattRead(mac, handle, addressType):next(function(data)
      SendToProxy(idBinding, "GATT_READ_RESPONSE", {
        data = C4:Base64Encode(data or ""), -- Base64 encoded to preserve binary data
        error = "0",
      }, "NOTIFY")
    end, function(error)
      SendToProxy(idBinding, "GATT_READ_RESPONSE", {
        data = C4:Base64Encode(""),
        error = tostring(error or -1),
      }, "NOTIFY")
    end)
  elseif strCommand == "GATT_NOTIFY" then
    local handle = tonumber(Select(tParams, "handle"))
    local enable = Select(tParams, "enable") == "true"

    if not handle then
      log:error("Invalid GATT_NOTIFY parameters")
      return
    end

    log:debug("GATT notify for %s handle %d: %s", mac, handle, enable)

    self._client
      :bluetoothGattNotify(mac, handle, enable, function(data)
        log:trace("GATT notify data for %s handle %d: %d bytes", mac, handle, #(data or ""))
        SendToProxy(idBinding, "GATT_NOTIFY_DATA", {
          handle = tostring(handle),
          data = C4:Base64Encode(data or ""),
        }, "NOTIFY")
      end, addressType)
      :next(function()
        log:trace("GATT notify subscription confirmed for %s handle %d", mac, handle)

        -- V3 BLE connections require client to write the CCCD descriptor.
        -- The ESP firmware skips this for V3, expecting the API client to handle it.
        -- We must wait for the CCCD write to complete before notifying the child,
        -- otherwise the child may start writing before notifications are enabled.
        local function notifyChild()
          SendToProxy(idBinding, "GATT_NOTIFY_SUBSCRIBED", {
            handle = tostring(handle),
            success = "true",
          }, "NOTIFY")
        end

        if enable and device.services then
          local cccdHandle, cccdValue = self:_findCccdForHandle(device.services, handle)
          if cccdHandle and cccdValue then
            log:debug("Writing CCCD for handle %d: descriptor handle=%d", handle, cccdHandle)
            self._client:bluetoothGattWriteDescriptor(mac, cccdHandle, cccdValue, addressType):next(function()
              log:trace("CCCD write confirmed for handle %d", handle)
              notifyChild()
            end, function(err)
              log:warn("CCCD write failed for handle %d: %s (notifying child anyway)", handle, err)
              notifyChild()
            end)
            return -- notifyChild called from promise
          else
            log:trace("No CCCD descriptor found for handle %d", handle)
          end
        else
          log:trace("No services cached, skipping CCCD write for handle %d", handle)
        end

        notifyChild()
      end, function(error)
        log:error("GATT notify failed for %s handle %d: %s", mac, handle, error)
        SendToProxy(idBinding, "GATT_NOTIFY_SUBSCRIBED", {
          handle = tostring(handle),
          success = "false",
          error = tostring(error or "unknown"),
        }, "NOTIFY")
      end)
  end
end

--- Set devices from BLEScannerProperties callback.
--- Creates bindings for new devices and removes bindings for deselected ones.
--- Actual BLE connection is deferred until child driver binds.
--- NOTE: This is disabled when a coordinator is connected - the coordinator handles device management.
--- @param selectedDevices table<string, BLEDiscoveredDevice?> Map of MAC to device info
function BluetoothProxyCapability:setDevices(selectedDevices)
  log:trace("BluetoothProxyCapability:setDevices()")

  -- Skip if coordinator is connected - it handles device management
  if self._coordinatorConnected then
    log:debug("setDevices skipped - coordinator is connected")
    return
  end

  local newMacs = {}
  local newCount = 0
  for mac, deviceInfo in pairs(selectedDevices or {}) do
    newMacs[mac] = deviceInfo
    newCount = newCount + 1
  end

  log:info("setDevices called with %d devices", newCount)

  -- Find devices to remove (keys are already MAC addresses)
  for mac in pairs(self._addedDevices) do
    if not newMacs[mac] then
      self:removeDevice(mac)
    end
  end

  -- Add new devices (create bindings, defer connection)
  local addedCount = 0
  for mac, deviceInfo in pairs(newMacs) do
    if not self._addedDevices[mac] then
      log:debug("Adding device: %s (%s)", mac, deviceInfo.deviceType or "unknown")
      self:addDevice(deviceInfo)
      addedCount = addedCount + 1
    end
  end

  log:info("setDevices complete: added %d new devices, total now %d", addedCount, TableLength(self._addedDevices))

  -- Update status to reflect any oversubscription changes
  self:_updateStatusProperty()
end

--- Add a device and create its binding.
--- Actual BLE connection is deferred until child driver binds.
--- NOTE: This is disabled when a coordinator is connected.
--- @param device BLEDiscoveredDevice Device info from scanner
function BluetoothProxyCapability:addDevice(device)
  local mac = device.mac
  local bindingClass = device.bindingClass
  log:trace("BluetoothProxyCapability:addDevice(%s)", mac)

  -- Skip if coordinator is connected - it handles device bindings
  if self._coordinatorConnected then
    log:debug("addDevice skipped for %s - coordinator is connected", mac)
    return
  end

  if not bindingClass then
    log:warn("Device %s has no binding class, skipping", mac)
    return
  end

  -- Initialize device tracking (not connected yet)
  self._addedDevices[mac] = {
    name = device.name,
    addressType = device.addressType or DEFAULT_ADDRESS_TYPE,
    services = nil,
    deviceType = device.deviceType,
    bindingClass = bindingClass,
    bindingId = nil,
    passive = device.passive or false,
  }

  -- Create binding immediately so child driver can be added
  -- Always include MAC address in display name for easy identification
  local cleanMac = mac:gsub(":", "")
  local displayName = (device.name or device.deviceType) .. " [" .. cleanMac .. "]"
  local binding =
    bindings:getOrAddDynamicBinding(self.TYPE, "bt_" .. cleanMac, "PROXY", true, displayName, bindingClass)

  if binding then
    self._addedDevices[mac].bindingId = binding.bindingId

    -- Register RFP handler - connection will happen on first command
    RFP[binding.bindingId] = function(idBinding, strCommand, tParams, args)
      self:handleCommand(mac, idBinding, strCommand, tParams, args)
    end

    -- Register OBC handler for binding changes (when child driver binds/unbinds)
    OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
      self:onBindingChanged(idBinding, bIsBound)
    end

    log:info("Created binding %s for %s (%s) - connection pending", binding.bindingId, mac, bindingClass)
  end
end

--- Remove a device and its binding.
--- @param mac string MAC address
function BluetoothProxyCapability:removeDevice(mac)
  log:trace("BluetoothProxyCapability:removeDevice(%s)", mac)

  local device = mac and self._addedDevices[mac]
  if not device then
    return
  end

  -- Delete dynamic binding
  if device.bindingId then
    local bindingKey = "bt_" .. mac:gsub(":", "")
    bindings:deleteBinding(self.TYPE, bindingKey)
  end

  -- Disconnect if connected (active devices only)
  if not device.passive and self._client:isBluetoothDeviceAllocated(mac) then
    self._client:bluetoothDeviceDisconnect(mac)
  end

  self._addedDevices[mac] = nil
  log:info("Removed device: %s", mac)
end

--- Get list of added devices (may or may not be connected).
--- @return table<string, AddedDevice?> Map of MAC address to device info
function BluetoothProxyCapability:getAddedDevices()
  return self._addedDevices
end

--- Handle binding changes from Control4.
--- When a child driver binds, automatically connect to the BLE device.
--- @param idBinding number The binding ID that changed
--- @param bIsBound boolean Whether a device is now bound
function BluetoothProxyCapability:onBindingChanged(idBinding, bIsBound)
  log:trace("BluetoothProxyCapability:onBindingChanged(%s, %s)", idBinding, bIsBound)

  -- Find the device for this binding
  local mac, device
  for m, d in pairs(self._addedDevices) do
    if d.bindingId == idBinding then
      mac = m
      device = d
      break
    end
  end

  if not mac or not device then
    log:trace("onBindingChanged: binding %s not found in _addedDevices", idBinding)
    return -- Not one of our bindings
  end

  log:debug("onBindingChanged: found device %s for binding %s (passive=%s)", mac, idBinding, device.passive)

  if bIsBound then
    -- Start passive advertisement monitoring for all devices (they parse locally)
    log:info("Child driver bound to %s, starting advertisement monitoring", mac)
    local advOk, advErr = pcall(function()
      self:_startAdvertisementMonitoring(mac, idBinding)
    end)
    if not advOk then
      log:error("Failed to start advertisement monitoring for %s: %s", mac, advErr or "unknown error")
    end

    -- For non-passive devices (like switches), also establish GATT connection
    if not device.passive then
      if self._client:isBluetoothDeviceAllocated(mac) then
        log:info("Device %s already connected, sending CONNECTED", mac)
        SendToProxy(idBinding, "CONNECTED", {
          name = device.name,
          mac = mac,
          deviceType = device.deviceType,
          services = SerializeSafe(device.services or {}),
        }, "NOTIFY")
      else
        log:info("Initiating GATT connection to %s", mac)
        local connOk, connErr = pcall(function()
          self:_connectAndNotify(mac, idBinding)
        end)
        if not connOk then
          log:error("Failed to initiate connection for %s: %s", mac, connErr or "unknown error")
        end
      end
    end
  else
    log:info("Child driver unbound from %s", mac)
    -- Stop advertisement monitoring
    self:_stopAdvertisementMonitoring(mac)

    -- Disconnect GATT if allocated (for non-passive devices)
    if not device.passive and self._client:isBluetoothDeviceAllocated(mac) then
      self._client:bluetoothDeviceDisconnect(mac)
      device.services = nil
    end
  end

  log:trace("onBindingChanged complete for %s", mac)
end

--- Start advertisement monitoring for a device.
--- Forwards parsed advertisement data to child driver.
--- @param mac string MAC address
--- @param idBinding number binding ID
--- @private
function BluetoothProxyCapability:_startAdvertisementMonitoring(mac, idBinding)
  log:trace("_startAdvertisementMonitoring(%s, %s)", mac, idBinding)

  -- Skip if coordinator is connected - it handles advertisement forwarding
  if self._coordinatorConnected then
    log:debug("_startAdvertisementMonitoring skipped for %s - coordinator is connected", mac)
    return
  end

  local device = self._addedDevices[mac]
  if not device then
    log:warn("_startAdvertisementMonitoring: device %s not found in _addedDevices", mac)
    return
  end

  local callbackId = "ble_" .. mac:gsub(":", "")
  log:debug(
    "Registering advertisement callback for %s (callbackId: %s, binding: %s, deviceType: %s)",
    mac,
    callbackId,
    idBinding,
    device.deviceType
  )

  -- Register callback for BLE advertisements from this device
  self._client:addBluetoothAdvertisementCallback(callbackId, function(advertisement)
    -- Filter to only this device's MAC
    if advertisement.mac ~= mac then
      return
    end

    -- Forward serialized advertisement to child driver
    -- Include device info so child can update CONNECTED_PASSIVE state
    SendToProxy(idBinding, "BLE_ADVERTISEMENT", {
      name = device.name,
      mac = mac,
      deviceType = device.deviceType,
      advertisement = SerializeSafe(advertisement),
    }, "NOTIFY")
  end)

  -- Send initial CONNECTED_PASSIVE message to child driver
  SendToProxy(idBinding, "CONNECTED_PASSIVE", {
    name = device.name,
    mac = mac,
    deviceType = device.deviceType,
  }, "NOTIFY")

  log:info("Started advertisement monitoring for %s (callback: %s, binding: %s)", mac, callbackId, idBinding)
end

--- Stop advertisement monitoring for a device.
--- @param mac string MAC address
--- @private
function BluetoothProxyCapability:_stopAdvertisementMonitoring(mac)
  local callbackId = "ble_" .. mac:gsub(":", "")
  self._client:removeBluetoothAdvertisementCallback(callbackId)
  log:info("Stopped advertisement monitoring for %s", mac)
end

--- BLE characteristic property bits
local BLE_PROP_NOTIFY = 0x10
local BLE_PROP_INDICATE = 0x20

--- CCCD UUID (0x2902) as full 128-bit Bluetooth Base UUID
local CCCD_UUID = "00002902-0000-1000-8000-00805F9B34FB"

--- Find the CCCD descriptor handle and appropriate value for a characteristic handle.
--- V3 BLE connections require the client to write the CCCD to enable notifications/indications.
--- Matches by short_uuid or full UUID, same as bleak-esphome's approach.
--- @param services ProtoBluetoothGATTService[]|nil GATT services from device discovery
--- @param charHandle number The characteristic handle to find CCCD for
--- @return number|nil cccdHandle The CCCD descriptor handle, or nil if not found
--- @return string|nil cccdValue The 2-byte LE CCCD value to write, or nil
function BluetoothProxyCapability:_findCccdForHandle(services, charHandle)
  if not services then
    return nil, nil
  end
  for _, svc in ipairs(services) do
    for _, chr in ipairs(svc.characteristics or {}) do
      if chr.handle == charHandle then
        local props = chr.properties or 0
        local hasNotify = math.floor(props / BLE_PROP_NOTIFY) % 2 == 1
        local hasIndicate = math.floor(props / BLE_PROP_INDICATE) % 2 == 1
        if not hasNotify and not hasIndicate then
          return nil, nil -- characteristic doesn't support notifications
        end
        local value = hasIndicate and 0x0002 or 0x0001
        for _, desc in ipairs(chr.descriptors or {}) do
          local descUuid = UUID.fromGattObject(desc)
          if descUuid and UUID.matches(descUuid, CCCD_UUID) then
            return desc.handle, string.char(value % 256, math.floor(value / 256))
          end
        end
        return nil, nil -- characteristic found but no CCCD descriptor
      end
    end
  end
  return nil, nil
end

--- Check if an active device has a GATT connection.
--- Note: Passive devices (BTHome) are never "connected" - they just receive advertisements.
--- @param mac string MAC address
--- @return boolean connected True if device has an active GATT connection
function BluetoothProxyCapability:isConnected(mac)
  local device = mac and self._addedDevices[mac]
  if not device then
    return false
  end
  -- Passive devices don't have GATT connections
  if device.passive then
    return false
  end
  -- Check the authoritative allocated list from ESPHome
  return self._client:isBluetoothDeviceAllocated(mac)
end

--- Handle the discovery of bluetooth proxy capability.
--- Registers the device selection property with BLEScannerProperties.
--- @param deviceInfo ProtoDeviceInfoResponse|nil Device info containing feature flags
function BluetoothProxyCapability:discovered(deviceInfo)
  log:trace("BluetoothProxyCapability:discovered(%s)", deviceInfo)

  self._featureFlags = math.max(0, Select(deviceInfo, "bluetooth_proxy_feature_flags") or 0)
  if self._featureFlags == 0 then
    log:debug("Bluetooth Proxy capability not detected")
    -- Hide Bluetooth Proxy properties
    self:setPropertiesAttribs(constants.HIDE_PROPERTY)
    -- Stop watchdog if running (capability no longer active)
    self:_stopScannerWatchdog()
    return
  end

  log:info("Bluetooth Proxy capability detected (flags: %s)", decodeFeatureFlags(self._featureFlags))

  -- Show Bluetooth Proxy properties
  self:setPropertiesAttribs(constants.SHOW_PROPERTY)

  -- Create dynamic binding for coordinator communication
  self:_createCoordinatorBinding()

  -- Register property with BLEScannerProperties
  bleScannerProperties:registerProperty(self.PROPERTY_NAME, {
    persistKey = SELECTED_BLUETOOTH_DEVICES_PERSIST_KEY,
    filter = function(device)
      return device.bindingClass ~= nil
    end,
    onChanged = function(selectedDevices)
      self:setDevices(selectedDevices)
    end,
  })

  -- Register callback for ongoing connection slot updates
  self._client:addBluetoothConnectionsCallback("bluetooth_proxy_entity", function(state)
    log:debug("BT connection slots: %d/%d free, %d connected", state.free, state.limit, #state.allocated)

    -- Build set of currently allocated MACs
    local currentAllocated = {}
    for _, mac in ipairs(state.allocated) do
      currentAllocated[mac] = true
    end

    -- Detect disconnects: devices that were allocated but no longer are
    for mac in pairs(self._previousAllocated) do
      if not currentAllocated[mac] then
        local device = self._addedDevices[mac]
        if device then
          -- Clear cached services on disconnect - handles may change after reconnect
          device.services = nil
          if device.bindingId then
            log:info("Device %s disconnected (no longer allocated)", mac)
            SendToProxy(device.bindingId, "DISCONNECTED", {
              mac = mac,
              reason = "BLE connection closed",
            }, "NOTIFY")
          end
        end
      end
    end

    -- Update previous allocated for next comparison
    self._previousAllocated = currentAllocated

    -- Set the limit on the property selector
    bleScannerProperties:setLimit(self.PROPERTY_NAME, state.limit)

    -- Update the status property
    self:_updateStatusProperty()
  end)

  -- Register callback for scanner state updates
  self._client:addBluetoothScannerStateCallback("bluetooth_proxy_entity", function(_scannerState)
    -- Re-update status property with new scanner info
    self:_updateStatusProperty()
  end)

  -- Register callback to mark advertisement received for scanner watchdog
  self._client:addBluetoothAdvertisementCallback("scanner_watchdog", function(_advertisement)
    self:_onAdvertisementReceived()
  end)

  -- Clear cached GATT services for active devices - handles may change after reconnect
  for mac, device in pairs(self._addedDevices) do
    if not device.passive and device.services then
      log:debug("Clearing cached services for %s (will rediscover on reconnect)", mac)
      device.services = nil
    end
  end

  -- Initialize Bluetooth proxy, then check for already-bound child drivers
  self._client:initBluetoothProxy():next(function()
    self:_connectBoundDevices()
    -- Start the scanner watchdog to detect stuck scanner
    self:_startScannerWatchdog()
  end, function(err)
    log:error("Failed to initialize Bluetooth proxy: %s", err or "unknown")
  end)
end

--- Check all added devices for already-bound child drivers and notify them.
--- Called after initBluetoothProxy() completes to ensure BLE subsystem is ready.
--- For active devices: initiates connection or sends CONNECTED if already connected.
--- For passive devices: re-registers advertisement callback and sends CONNECTED_PASSIVE.
--- @private
function BluetoothProxyCapability:_connectBoundDevices()
  log:trace("BluetoothProxyCapability:_connectBoundDevices()")
  local deviceId = C4:GetDeviceID()
  local deviceCount = 0
  local boundCount = 0
  local errorCount = 0

  for mac, device in pairs(self._addedDevices) do
    deviceCount = deviceCount + 1
    log:debug("Checking device %s: bindingId=%s, passive=%s", mac, device.bindingId, device.passive)

    if device.bindingId then
      -- Wrap in pcall to catch any errors and continue processing remaining devices
      local ok, err = pcall(function()
        -- C4:GetBoundConsumerDevices may return nil for some bindings (e.g., if child driver not loaded yet)
        local hasBoundDevices = not IsEmpty(C4:GetBoundConsumerDevices(deviceId, device.bindingId))
        log:debug("Device %s binding %s has bound children: %s", mac, device.bindingId, hasBoundDevices)

        if hasBoundDevices then
          boundCount = boundCount + 1
          -- Always notify bound children - they need CONNECTED/CONNECTED_PASSIVE after driver reload
          -- onBindingChanged handles both cases: initiating connection or notifying if already connected
          log:info("Child driver bound to %s, notifying", mac)
          self:onBindingChanged(device.bindingId, true)
        end
      end)

      if not ok then
        errorCount = errorCount + 1
        log:error("Error processing device %s (binding %s): %s", mac, device.bindingId, err or "unknown error")
      end
    else
      log:warn("Device %s has no bindingId", mac)
    end
  end

  log:info("_connectBoundDevices: %d devices, %d with bound children, %d errors", deviceCount, boundCount, errorCount)
end

--- Bluetooth proxy doesn't have state updates like other entities.
--- @param entity table<string, any> The entity data
--- @param state table<string, any> The state data
--- @diagnostic disable-next-line: unused
function BluetoothProxyCapability:updated(entity, state)
  log:trace("BluetoothProxyCapability:updated(%s, %s)", entity, state)
  -- No state updates for bluetooth proxy
end

--------------------------------------------------------------------------------
-- Coordinator Mode Support
--------------------------------------------------------------------------------

--- Check if a Bluetooth Coordinator is connected to this proxy.
--- When a coordinator is connected, advertisements are forwarded to it instead of
--- being handled locally with individual device bindings.
--- @return boolean connected True if coordinator is connected
function BluetoothProxyCapability:isCoordinatorConnected()
  return self._coordinatorConnected
end

--- Get room information for this proxy.
--- Returns the room ID and name from the "Bluetooth Proxy Room" property.
--- @return {roomId: integer, roomName: string, minRssiOverride: integer}|nil roomInfo Table with roomId, roomName, and minRssiOverride, or nil if not set
function BluetoothProxyCapability:getRoomInfo()
  local roomDeviceId = Properties[self.ROOM_PROPERTY_NAME]
  local usingDefault = false

  if IsEmpty(roomDeviceId) or roomDeviceId == "" then
    -- Try to default to the driver's location
    roomDeviceId = C4:RoomGetId()
    usingDefault = true
    log:debug("getRoomInfo: using default room from C4:RoomGetId() = %s", roomDeviceId)
  end

  --- @type integer?
  local roomId = tointeger(roomDeviceId)
  if not roomId then
    log:warn("getRoomInfo: could not convert roomDeviceId '%s' to integer", roomDeviceId)
    return nil
  end

  local roomName = C4:GetDeviceDisplayName(roomId) or "Unknown"
  local minRssiOverride = tointeger(Properties[self.MIN_RSSI_OVERRIDE_PROPERTY_NAME]) or -100
  log:debug(
    "getRoomInfo: roomId=%d, roomName='%s', minRssiOverride=%d, usingDefault=%s",
    roomId,
    roomName,
    minRssiOverride,
    usingDefault
  )

  return {
    roomId = roomId,
    roomName = roomName,
    minRssiOverride = minRssiOverride,
  }
end

--- Handle minRssiOverride property change.
--- Notifies the coordinator of the new threshold if connected.
function BluetoothProxyCapability:onMinRssiOverrideChanged()
  log:trace("BluetoothProxyCapability:onMinRssiOverrideChanged()")

  if not self._coordinatorConnected or not self._coordinatorBindingId then
    log:debug("Not connected to coordinator, skipping minRssiOverride update")
    return
  end

  local roomInfo = self:getRoomInfo()
  local connState = self._client:getBluetoothConnectionState()

  log:info("Sending minRssiOverride update to coordinator: %d", roomInfo and roomInfo.minRssiOverride or -100)

  SendToProxy(self._coordinatorBindingId, "CONNECTION_STATE", {
    proxyId = tostring(C4:GetDeviceID()),
    roomId = roomInfo and tostring(roomInfo.roomId) or "",
    roomName = roomInfo and roomInfo.roomName or "",
    connectionSlots = connState.initialized and tostring(connState.limit) or "0",
    freeSlots = connState.initialized and tostring(connState.free) or "0",
    minRssiOverride = roomInfo and tostring(roomInfo.minRssiOverride) or "-100",
  }, "NOTIFY")
end

--- Handle room property change.
--- Notifies the coordinator of the new room assignment if connected.
function BluetoothProxyCapability:onRoomChanged()
  log:trace("BluetoothProxyCapability:onRoomChanged()")

  if not self._coordinatorConnected or not self._coordinatorBindingId then
    log:debug("Not connected to coordinator, skipping room update")
    return
  end

  local roomInfo = self:getRoomInfo()
  local connState = self._client:getBluetoothConnectionState()

  log:info(
    "Sending room update to coordinator: %s (%s), minRssiOverride=%d",
    roomInfo and roomInfo.roomName or "None",
    roomInfo and roomInfo.roomId or "nil",
    roomInfo and roomInfo.minRssiOverride or -100
  )

  SendToProxy(self._coordinatorBindingId, "CONNECTION_STATE", {
    proxyId = tostring(C4:GetDeviceID()),
    roomId = roomInfo and tostring(roomInfo.roomId) or "",
    roomName = roomInfo and roomInfo.roomName or "",
    connectionSlots = connState.initialized and tostring(connState.limit) or "0",
    freeSlots = connState.initialized and tostring(connState.free) or "0",
    minRssiOverride = roomInfo and tostring(roomInfo.minRssiOverride) or "-100",
  }, "NOTIFY")
end

--- Handle coordinator binding state change.
--- When coordinator connects, start forwarding all advertisements to it and disable local device management.
--- When coordinator disconnects, stop forwarding and re-enable local device management.
--- @param bIsBound boolean Whether coordinator is now bound
function BluetoothProxyCapability:onCoordinatorBindingChanged(bIsBound)
  log:info("Coordinator binding changed: %s", bIsBound)

  if not self._coordinatorBindingId then
    log:warn("Coordinator binding ID not set, ignoring binding change")
    return
  end

  if bIsBound then
    self._coordinatorConnected = true

    -- Switch to coordinator mode properties: show room, hide device selection
    self:setPropertiesAttribs(constants.SHOW_PROPERTY)

    -- Clean up all existing standalone mode state
    -- Collect MACs first to avoid modifying table while iterating
    local macsToRemove = {}
    for mac in pairs(self._addedDevices) do
      table.insert(macsToRemove, mac)
    end

    -- Remove all devices (stops monitoring, disconnects GATT, removes bindings)
    for _, mac in ipairs(macsToRemove) do
      self:removeDevice(mac)
    end

    -- Clear persisted device selection
    bleScannerProperties:clearSelection(self.PROPERTY_NAME)

    -- Start forwarding all advertisements to coordinator
    self:_startCoordinatorForwarding()

    -- Send initial connection info to coordinator
    local roomInfo = self:getRoomInfo()
    local connState = self._client:getBluetoothConnectionState()

    SendToProxy(self._coordinatorBindingId, "PROXY_CONNECTED", {
      proxyId = tostring(C4:GetDeviceID()),
      roomId = roomInfo and tostring(roomInfo.roomId) or "",
      roomName = roomInfo and roomInfo.roomName or "",
      connectionSlots = connState.initialized and tostring(connState.limit) or "0",
      freeSlots = connState.initialized and tostring(connState.free) or "0",
      featureFlags = tostring(self._featureFlags),
      minRssiOverride = roomInfo and tostring(roomInfo.minRssiOverride) or "-100",
    }, "NOTIFY")

    -- Update status to indicate coordinator mode
    self:_updateStatusProperty()
  else
    self._coordinatorConnected = false
    self:_stopCoordinatorForwarding()

    -- Switch back to standalone mode properties: hide room, show device selection
    self:setPropertiesAttribs(constants.SHOW_PROPERTY)

    -- Re-enable local advertisement monitoring for bound devices
    for mac, device in pairs(self._addedDevices) do
      if device.bindingId then
        local deviceId = C4:GetDeviceID()
        local hasBoundDevices = not IsEmpty(C4:GetBoundConsumerDevices(deviceId, device.bindingId))
        if hasBoundDevices then
          self:_startAdvertisementMonitoring(mac, device.bindingId)
        end
      end
    end

    -- Update status property
    self:_updateStatusProperty()
  end
end

--- Start forwarding BLE advertisements to the coordinator.
--- Advertisements are filtered based on _advertisementFilter (nil = pass all).
--- @private
function BluetoothProxyCapability:_startCoordinatorForwarding()
  if self._coordinatorCallbackId then
    return -- Already forwarding
  end

  if not self._coordinatorBindingId then
    log:warn("Cannot start coordinator forwarding: binding ID not set")
    return
  end

  self._coordinatorCallbackId = "coordinator_fwd"
  local bindingId = self._coordinatorBindingId

  -- Register callback for BLE advertisements
  self._client:addBluetoothAdvertisementCallback(self._coordinatorCallbackId, function(advertisement)
    -- Apply filter: nil = pass all, otherwise check if MAC is in filter set
    if self._advertisementFilter and not self._advertisementFilter[advertisement.mac] then
      return -- Not in filter, skip
    end

    -- Forward parsed advertisement to coordinator
    SendToProxy(bindingId, "BLE_ADVERTISEMENT", {
      proxyId = tostring(C4:GetDeviceID()),
      advertisement = SerializeSafe(advertisement),
    }, "NOTIFY")
  end)

  log:info("Started coordinator advertisement forwarding")
end

--- Stop forwarding advertisements to coordinator.
--- @private
function BluetoothProxyCapability:_stopCoordinatorForwarding()
  if not self._coordinatorCallbackId then
    return
  end

  self._client:removeBluetoothAdvertisementCallback(self._coordinatorCallbackId)
  self._coordinatorCallbackId = nil
  log:info("Stopped coordinator advertisement forwarding")
end

--- Handle commands from the Bluetooth Coordinator.
--- The coordinator can request GATT operations to be performed via this proxy.
--- @param strCommand string The command string
--- @param tParams table Command parameters
function BluetoothProxyCapability:handleCoordinatorCommand(strCommand, tParams)
  log:debug("handleCoordinatorCommand(%s, %s)", strCommand, tParams)

  local bindingId = self._coordinatorBindingId
  if not bindingId then
    log:warn("Coordinator command received but binding ID not set")
    return
  end

  local proxyId = tostring(C4:GetDeviceID())

  if strCommand == "GATT_CONNECT" then
    local mac = Select(tParams, "mac")
    local addressType = tointeger(Select(tParams, "addressType")) or DEFAULT_ADDRESS_TYPE
    local requestId = Select(tParams, "requestId")

    if not mac then
      log:error("GATT_CONNECT missing required parameters")
      return
    end

    log:info("Coordinator requested GATT connection to %s", mac)

    self._client:bluetoothDeviceConnect(mac, addressType, false):next(function(result)
      -- Discover GATT services
      self._client:bluetoothGattGetServices(mac):next(function(services)
        SendToProxy(bindingId, "GATT_CONNECT_RESPONSE", {
          proxyId = proxyId,
          mac = mac,
          requestId = requestId or "",
          success = "true",
          services = SerializeSafe(services or {}),
          mtu = tostring(result.mtu or 0),
        }, "NOTIFY")
      end, function(err)
        SendToProxy(bindingId, "GATT_CONNECT_RESPONSE", {
          proxyId = proxyId,
          mac = mac,
          requestId = requestId or "",
          success = "false",
          error = "GATT discovery failed: " .. tostring(err),
        }, "NOTIFY")
      end)
    end, function(err)
      SendToProxy(bindingId, "GATT_CONNECT_RESPONSE", {
        proxyId = proxyId,
        mac = mac,
        requestId = requestId or "",
        success = "false",
        error = tostring(err or "Connection failed"),
      }, "NOTIFY")
    end)
  elseif strCommand == "GATT_DISCONNECT" then
    local mac = Select(tParams, "mac")

    if mac then
      self._client:bluetoothDeviceDisconnect(mac)
      SendToProxy(bindingId, "GATT_DISCONNECT_RESPONSE", {
        proxyId = proxyId,
        mac = mac,
        success = "true",
      }, "NOTIFY")
    end
  elseif strCommand == "GATT_WRITE" then
    local mac = Select(tParams, "mac")
    local addressType = tointeger(Select(tParams, "addressType")) or DEFAULT_ADDRESS_TYPE
    local handle = tointeger(Select(tParams, "handle"))
    local data = C4:Base64Decode(Select(tParams, "data") or "")
    local needResponse = Select(tParams, "response") == "true"
    local requestId = Select(tParams, "requestId")

    if not mac or not handle then
      log:error("GATT_WRITE missing required parameters")
      return
    end

    self._client:bluetoothGattWrite(mac, handle, data, needResponse, addressType):next(function()
      SendToProxy(bindingId, "GATT_WRITE_RESPONSE", {
        proxyId = proxyId,
        mac = mac or "",
        requestId = requestId or "",
        success = "true",
        error = "0",
      }, "NOTIFY")
    end, function(error)
      SendToProxy(bindingId, "GATT_WRITE_RESPONSE", {
        proxyId = proxyId,
        mac = mac or "",
        requestId = requestId or "",
        success = "false",
        error = tostring(error or -1),
      }, "NOTIFY")
    end)
  elseif strCommand == "GATT_READ" then
    local mac = Select(tParams, "mac")
    local addressType = tointeger(Select(tParams, "addressType")) or DEFAULT_ADDRESS_TYPE
    local handle = tointeger(Select(tParams, "handle"))
    local requestId = Select(tParams, "requestId")

    if not mac or not handle then
      log:error("GATT_READ missing required parameters")
      return
    end

    self._client:bluetoothGattRead(mac, handle, addressType):next(function(data)
      SendToProxy(bindingId, "GATT_READ_RESPONSE", {
        proxyId = proxyId,
        mac = mac or "",
        requestId = requestId or "",
        data = C4:Base64Encode(data or ""),
        error = "0",
      }, "NOTIFY")
    end, function(error)
      SendToProxy(bindingId, "GATT_READ_RESPONSE", {
        proxyId = proxyId,
        mac = mac or "",
        requestId = requestId or "",
        data = "",
        error = tostring(error or -1),
      }, "NOTIFY")
    end)
  elseif strCommand == "GATT_NOTIFY" then
    local mac = Select(tParams, "mac")
    local addressType = tointeger(Select(tParams, "addressType")) or DEFAULT_ADDRESS_TYPE
    local handle = tointeger(Select(tParams, "handle"))
    local enable = Select(tParams, "enable") == "true"
    local requestId = Select(tParams, "requestId")

    if not mac or not handle then
      log:error("GATT_NOTIFY missing required parameters")
      return
    end

    self._client
      :bluetoothGattNotify(mac, handle, enable, function(data)
        -- Forward notification data to coordinator
        SendToProxy(bindingId, "GATT_NOTIFY_DATA", {
          proxyId = proxyId,
          mac = mac or "",
          handle = tostring(handle),
          data = C4:Base64Encode(data or ""),
        }, "NOTIFY")
      end, addressType)
      :next(function()
        SendToProxy(bindingId, "GATT_NOTIFY_SUBSCRIBED", {
          proxyId = proxyId,
          mac = mac or "",
          requestId = requestId or "",
          handle = tostring(handle),
          success = "true",
        }, "NOTIFY")
      end, function(error)
        SendToProxy(bindingId, "GATT_NOTIFY_SUBSCRIBED", {
          proxyId = proxyId,
          mac = mac or "",
          requestId = requestId or "",
          handle = tostring(handle),
          success = "false",
          error = tostring(error or "unknown"),
        }, "NOTIFY")
      end)
  elseif strCommand == "GET_CONNECTION_STATE" then
    local connState = self._client:getBluetoothConnectionState()
    local roomInfo = self:getRoomInfo()

    SendToProxy(bindingId, "CONNECTION_STATE", {
      proxyId = proxyId,
      roomId = roomInfo and tostring(roomInfo.roomId) or "",
      roomName = roomInfo and roomInfo.roomName or "",
      connectionSlots = connState.initialized and tostring(connState.limit) or "0",
      freeSlots = connState.initialized and tostring(connState.free) or "0",
      allocated = SerializeSafe(connState.allocated or {}),
    }, "NOTIFY")
  elseif strCommand == "SET_ADVERTISEMENT_FILTER" then
    local macs = DeserializeSafe(tParams.macs)
    if not macs or #macs == 0 then
      -- Empty or nil = pass all advertisements
      self._advertisementFilter = nil
      log:info("Advertisement filter cleared (pass all)")
    else
      -- Convert to set for O(1) lookup
      self._advertisementFilter = {}
      for _, mac in ipairs(macs) do
        self._advertisementFilter[mac] = true
      end
      log:info("Advertisement filter set: %d MAC(s)", #macs)
    end
    -- Update status property to reflect filter state
    self:_updateStatusProperty()
  else
    log:warn("Unknown coordinator command: %s", strCommand)
  end
end

--- Create and register the coordinator binding dynamically.
--- Called when Bluetooth proxy capability is detected.
--- @private
function BluetoothProxyCapability:_createCoordinatorBinding()
  -- Create dynamic binding for coordinator communication
  local binding = bindings:getOrAddDynamicBinding(
    self.TYPE,
    self.COORDINATOR_BINDING_KEY,
    "PROXY",
    false,
    "Bluetooth Coordinator",
    "ESPHOME_BLUETOOTH"
  )

  if not binding then
    log:error("Failed to create coordinator binding")
    return
  end

  self._coordinatorBindingId = binding.bindingId
  log:info("Created coordinator binding on %d", binding.bindingId)

  -- Register RFP handler for coordinator commands
  RFP[binding.bindingId] = function(_idBinding, strCommand, tParams, _args)
    self:handleCoordinatorCommand(strCommand, tParams)
  end

  -- Register OBC handler for coordinator binding lifecycle
  OBC[binding.bindingId] = function(_idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    self:onCoordinatorBindingChanged(bIsBound)
  end

  -- Check if coordinator is already bound (we're a consumer, check for provider)
  local deviceId = C4:GetDeviceID()
  local boundProvider = C4:GetBoundProviderDevice(deviceId, binding.bindingId)
  if boundProvider and boundProvider > 0 then
    log:info("Coordinator already bound on startup (provider device %d), enabling forwarding", boundProvider)
    self:onCoordinatorBindingChanged(true)
  end
end

return BluetoothProxyCapability
