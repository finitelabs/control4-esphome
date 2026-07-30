--- ESPHome Bluetooth Coordinator Driver
--- Aggregates multiple ESPHome Bluetooth proxies for RSSI-based routing,
--- failover, and presence tracking.

--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_bluetooth_coordinator.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

local log = require("lib.logging")
local persist = require("lib.persist")
local bindings = require("lib.bindings")
local events = require("lib.events")
local values = require("lib.values")

local ProxyScannerNode = require("esphome.ble.coordinator.proxy_scanner_node")

local proxyRegistry = require("esphome.ble.coordinator.proxy_registry")
local deviceRegistry = require("esphome.ble.coordinator.device_registry")
local router = require("esphome.ble.coordinator.router")
local presenceTracker = require("esphome.ble.coordinator.presence_tracker")
local bleScanner = require("esphome.ble.scanner")
local bleScannerProperties = require("esphome.ble.scanner_properties")

--- Update the Driver Status property and the Connected variable so
--- Programming can react to connect/disconnect.
--- @param status string The human-readable connection status.
--- @param connected boolean Whether this status represents a live connection;
--- callers pass it explicitly so rewording a status can never silently flip
--- the Connected variable.
local function updateStatus(status, connected)
  log:trace("updateStatus(%s, %s)", status, connected)
  if type(connected) ~= "boolean" then
    error(string.format("updateStatus(%s): connected must be an explicit boolean", tostring(status)), 2)
  end
  UpdateProperty("Driver Status", status)
  values:update("Connected", connected, "BOOL")
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local BINDINGS_NAMESPACE = "coordinator"

-- Single provider binding for all proxies
local PROXY_BINDING_ID = 5001

-- Persist keys
local PERSIST_SELECTED_DEVICES = "SelectedDevices"
local PERSIST_PRESENCE_DEVICES = "PresenceDevices"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local initialized = false
--- @type table<string, DeviceInfo>
local selectedDevices = {} -- MAC -> DeviceInfo for selected devices
--- @type C4LuaTimer|nil
local awayCheckTimer = nil

--------------------------------------------------------------------------------
-- Property Helpers
--------------------------------------------------------------------------------

local function updateStatusProperties()
  log:trace("updateStatusProperties()")
  local proxyCount = proxyRegistry:getConnectedCount()
  local deviceCount = deviceRegistry:getDeviceCount()

  C4:UpdateProperty("Connected Proxies", tostring(proxyCount))
  C4:UpdateProperty("Selected Devices", tostring(deviceCount))
end

--------------------------------------------------------------------------------
-- Advertisement Filter Management
--------------------------------------------------------------------------------

--- Build the list of MACs that proxies should forward advertisements for.
--- Combines registered devices and presence tracking devices.
--- @return string[] macs List of MAC addresses to filter for
local function buildAdvertisementFilter()
  local macs = {}

  -- Add registered devices
  for mac, _ in pairs(deviceRegistry:getDevices()) do
    macs[mac] = true
  end

  -- Add presence tracking devices
  for mac, _ in pairs(presenceTracker:getPresenceDevices() or {}) do
    macs[mac] = true
  end

  return TableKeys(macs)
end

--- Broadcast the advertisement filter to all connected proxies.
--- Call this when tracked devices or presence devices change.
local function broadcastAdvertisementFilter()
  log:trace("broadcastAdvertisementFilter()")
  local macs = buildAdvertisementFilter()
  log:info("Broadcasting advertisement filter: %d MAC(s)", #macs)
  SendToProxy(PROXY_BINDING_ID, "SET_ADVERTISEMENT_FILTER", {
    macs = SerializeSafe(macs),
  }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Device Binding Management
--------------------------------------------------------------------------------

--- Create a dynamic binding for a BLE device
--- @param device DeviceInfo The device to create a binding for
--- @return integer|nil bindingId The created binding ID
local function createDeviceBinding(device)
  log:trace("createDeviceBinding(%s)", device.mac)
  if IsEmpty(device.bindingClass) then
    log:warn("Cannot create binding for device %s: no binding class", device.mac)
    return nil
  end
  --- @cast device.bindingClass -nil
  if IsEmpty(device.deviceType) then
    log:warn("Cannot create binding for device %s: no device type", device.mac)
    return nil
  end
  --- @cast device.deviceType -nil

  local cleanMac = device.mac:gsub(":", "")
  local displayName = (not IsEmpty(device.name) and device.name or device.deviceType) .. " [" .. cleanMac .. "]"

  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    "bt_" .. device.mac:gsub(":", ""),
    "PROXY",
    true, -- provider
    displayName,
    device.bindingClass
  )

  if binding then
    log:info("Created binding %d for device %s (%s)", binding.bindingId, device.mac, device.bindingClass)

    -- Register command handler for this binding
    RFP[binding.bindingId] = function(idBinding, strCommand, tParams, _args)
      handleDeviceCommand(device.mac, idBinding, strCommand, tParams)
    end

    -- Register binding change handler
    OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
      onDeviceBindingChanged(device.mac, idBinding, bIsBound)
    end

    return binding.bindingId
  end

  return nil
end

--- Remove a device binding
--- @param mac string MAC address
local function removeDeviceBinding(mac)
  log:trace("removeDeviceBinding(%s)", mac)
  local device = deviceRegistry:getDevice(mac)
  if device and device.bindingId then
    RFP[device.bindingId] = nil
    OBC[device.bindingId] = nil
    bindings:deleteBinding(BINDINGS_NAMESPACE, "bt_" .. mac:gsub(":", ""))
    device.bindingId = nil
    log:info("Removed binding for device %s", mac)
  end
end

--- Handle commands from child drivers
--- @param mac string MAC address
--- @param bindingId integer Binding ID
--- @param strCommand string Command name
--- @param tParams table Command parameters
function handleDeviceCommand(mac, bindingId, strCommand, tParams)
  log:trace("handleDeviceCommand(%s, %s, %s, %s)", mac, bindingId, strCommand, tParams)

  local device = deviceRegistry:getDevice(mac)
  if not device then
    log:error("Device not found: %s", mac)
    return
  end

  if strCommand == "CONNECT" then
    -- Use router for failover-enabled connection
    router:connectWithFailover(mac, 3, nil, function(success, result)
      if success then
        SendToProxy(bindingId, "CONNECTED", {
          name = device.name or "",
          mac = mac,
          deviceType = device.deviceType or "",
          services = SerializeSafe(result.services),
        }, "NOTIFY")
      else
        SendToProxy(bindingId, "CONNECTION_FAILED", {
          name = device.name or "",
          mac = mac,
          deviceType = device.deviceType or "",
          error = tostring(result or "Connection failed"),
        }, "NOTIFY")
      end
    end)
  elseif strCommand == "DISCONNECT" then
    router:disconnect(mac)
    SendToProxy(bindingId, "DISCONNECTED", {
      mac = mac,
      reason = "Requested",
    }, "NOTIFY")
  elseif strCommand == "GATT_WRITE" then
    local handle = tointeger(Select(tParams, "handle"))
    if not handle then
      log:warn("GATT_WRITE missing or invalid handle for %s", mac)
      return
    end
    local data = C4:Base64Decode(Select(tParams, "data") or "")
    local needResponse = Select(tParams, "response") == "true"

    router:gattWrite(mac, handle, data, needResponse, function(success, err)
      SendToProxy(bindingId, "GATT_WRITE_RESPONSE", {
        success = success and "true" or "false",
        error = err and tostring(err) or "0",
      }, "NOTIFY")
    end)
  elseif strCommand == "GATT_READ" then
    local handle = tointeger(Select(tParams, "handle"))
    if not handle then
      log:warn("GATT_READ missing or invalid handle for %s", mac)
      return
    end

    router:gattRead(mac, handle, function(success, data, err)
      SendToProxy(bindingId, "GATT_READ_RESPONSE", {
        data = data and C4:Base64Encode(data) or "",
        error = (success and "0") or (err and tostring(err)) or "-1",
      }, "NOTIFY")
    end)
  elseif strCommand == "GATT_NOTIFY" then
    local handle = tointeger(Select(tParams, "handle"))
    if not handle then
      log:warn("GATT_NOTIFY missing or invalid handle for %s", mac)
      return
    end
    local enable = Select(tParams, "enable") == "true"

    router:gattNotify(mac, handle, enable, function(data)
      SendToProxy(bindingId, "GATT_NOTIFY_DATA", {
        handle = tostring(handle),
        data = C4:Base64Encode(data or ""),
      }, "NOTIFY")
    end, function(success, err)
      SendToProxy(bindingId, "GATT_NOTIFY_SUBSCRIBED", {
        handle = tostring(handle),
        success = success and "true" or "false",
        error = err and tostring(err) or "",
      }, "NOTIFY")
    end)
  end
end

--- Handle child driver binding changes
--- @param mac string MAC address
--- @param bindingId integer Binding ID
--- @param bIsBound boolean Whether bound
function onDeviceBindingChanged(mac, bindingId, bIsBound)
  log:debug("Device binding changed: %s, bound=%s", mac, bIsBound)

  local device = deviceRegistry:getDevice(mac)
  if not device then
    return
  end

  if bIsBound then
    -- Child driver bound - start forwarding advertisements
    if device.passive then
      -- For passive devices, just send CONNECTED_PASSIVE
      SendToProxy(bindingId, "CONNECTED_PASSIVE", {
        name = device.name or "",
        mac = mac,
        deviceType = device.deviceType or "",
      }, "NOTIFY")
    end
    -- Active devices will initiate connection via CONNECT command
  else
    -- Child driver unbound - stop tracking
    router:disconnect(mac)
  end
end

--------------------------------------------------------------------------------
-- Proxy Message Handlers
--------------------------------------------------------------------------------

--- Handle messages from proxies
--- @param proxyDeviceId integer Proxy's Control4 device ID
--- @param strCommand string Command/message name
--- @param tParams table Message parameters
local function handleProxyMessage(proxyDeviceId, strCommand, tParams)
  log:trace("handleProxyMessage(%s, %s, %s)", proxyDeviceId, strCommand, tParams)

  proxyRegistry:updateLastSeen(proxyDeviceId)

  if strCommand == "PROXY_CONNECTED" then
    proxyRegistry:onProxyConnected(proxyDeviceId, tParams)
    updateStatusProperties()
    -- Send current filter to newly connected proxy
    broadcastAdvertisementFilter()
  elseif strCommand == "CONNECTION_STATE" then
    proxyRegistry:onConnectionState(proxyDeviceId, tParams)
  elseif strCommand == "BLE_ADVERTISEMENT" then
    -- Deserialize the full BLEAdvertisement from the proxy
    local advertisement = DeserializeSafe(tParams.advertisement)
    if not advertisement or not advertisement.mac then
      return
    end
    --- @cast advertisement BLEAdvertisement

    -- Process advertisement in device registry (only updates registered devices)
    local device, isDuplicate = deviceRegistry:processAdvertisement(proxyDeviceId, advertisement)

    -- Update presence tracking (only needs mac, proxy, rssi)
    presenceTracker:onAdvertisement(advertisement.mac, proxyDeviceId, advertisement.rssi or -999)

    -- Forward to child driver if registered and not duplicate
    if device and device.bindingId and not isDuplicate then
      -- Enrich tParams with device info for child's CONNECTED_PASSIVE handler
      tParams.name = device.name or advertisement.name
      tParams.mac = device.mac
      tParams.deviceType = device.deviceType
      SendToProxy(device.bindingId, "BLE_ADVERTISEMENT", tParams, "NOTIFY")
    end

    -- Route to scanner (handles filtering and accumulation only if scanning)
    bleScanner:onAdvertisement(advertisement, proxyDeviceId)
  elseif strCommand == "GATT_CONNECT_RESPONSE" then
    router:onGattConnectResponse(tParams)
  elseif strCommand == "GATT_WRITE_RESPONSE" then
    router:onGattWriteResponse(tParams)
  elseif strCommand == "GATT_READ_RESPONSE" then
    router:onGattReadResponse(tParams)
  elseif strCommand == "GATT_NOTIFY_SUBSCRIBED" then
    router:onGattNotifySubscribed(tParams)
  elseif strCommand == "GATT_NOTIFY_DATA" then
    router:onGattNotifyData(tParams)
  elseif strCommand == "GATT_DISCONNECT_RESPONSE" then
    router:onGattDisconnectResponse(tParams)
  end
end

--------------------------------------------------------------------------------
-- Action Handlers
--------------------------------------------------------------------------------

function EC.Reset_Driver(tParams)
  if Select(tParams, "Are You Sure?") ~= "Yes" then
    return
  end

  log:warn("Resetting driver...")

  -- Clear all state
  deviceRegistry:clear()
  selectedDevices = {}
  persist:set(PERSIST_SELECTED_DEVICES, {})
  persist:set(PERSIST_PRESENCE_DEVICES, {})

  -- Delete all dynamic bindings
  bindings:deleteAllBindings(BINDINGS_NAMESPACE)

  -- Remove the connection state variables alongside the rest of the state
  values:reset()

  updateStatusProperties()
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

local function restoreState()
  log:trace("restoreState()")
  -- Restore registered devices
  local savedDevices = persist:get(PERSIST_SELECTED_DEVICES) or {}
  for mac, deviceInfo in pairs(savedDevices) do
    -- Re-register device
    local device = deviceRegistry:registerDevice(deviceInfo)
    device.bindingId = createDeviceBinding(device)
    selectedDevices[mac] = device
  end

  -- Restore presence devices
  local presenceDevices = persist:get(PERSIST_PRESENCE_DEVICES) or {}
  for mac, config in pairs(presenceDevices) do
    presenceTracker:trackDevice(mac, config)
  end
end

--- Create a ProxyScannerNode for a proxy and add it to the scanner.
--- @param proxyDeviceId integer The proxy's Control4 device ID
local function addProxyScannerNode(proxyDeviceId)
  log:trace("addProxyScannerNode(%s)", proxyDeviceId)
  if bleScanner:getNode(proxyDeviceId) then
    log:debug("ProxyScannerNode already exists for proxy %d", proxyDeviceId)
    return
  end

  local node = ProxyScannerNode:new(proxyDeviceId, function()
    return proxyRegistry:isProxyConnected(proxyDeviceId)
  end)

  bleScanner:addNode(node)
  log:info("Created ProxyScannerNode for proxy %d", proxyDeviceId)
end

--- Remove a ProxyScannerNode for a proxy.
--- @param proxyDeviceId integer The proxy's Control4 device ID
local function removeProxyScannerNode(proxyDeviceId)
  log:trace("removeProxyScannerNode(%s)", proxyDeviceId)
  if bleScanner:getNode(proxyDeviceId) then
    bleScanner:removeNode(proxyDeviceId)
    log:info("Removed ProxyScannerNode for proxy %d", proxyDeviceId)
  end
end

--- Handle proxy disconnect cleanup
--- @param proxy ProxyInfo The disconnected proxy
local function onProxyDisconnected(proxy)
  log:trace("onProxyDisconnected(%s)", proxy)
  log:info("Cleaning up state for disconnected proxy (device %d)", proxy.deviceId or 0)

  -- Remove the scanner node
  removeProxyScannerNode(proxy.deviceId)

  -- Clear RSSI data from device registry for this proxy
  deviceRegistry:clearProxyRSSI(proxy.deviceId)

  -- Clear RSSI state from presence tracker for this proxy
  presenceTracker:clearProxyRSSI(proxy.deviceId)

  -- Cancel any pending GATT operations that were using this proxy
  router:onProxyDisconnected(proxy.deviceId)
end

local function setupProxyBindings()
  log:trace("setupProxyBindings()")
  -- Register for proxy change callbacks
  proxyRegistry:onProxyChange("driver", function(event, proxyInfo)
    if event == "disconnected" then
      onProxyDisconnected(proxyInfo)
      -- Clean up rooms that are no longer used by any proxy
      presenceTracker:cleanupUnusedRooms()
    elseif event == "updated" then
      -- Proxy room may have changed - recalculate presence for all tracked devices
      presenceTracker:onProxyUpdated(proxyInfo.deviceId)
      -- Clean up rooms that are no longer used after room reassignment
      presenceTracker:cleanupUnusedRooms()
    end
  end)

  -- Single binding handler for all proxies
  RFP[PROXY_BINDING_ID] = function(_idBinding, strCommand, tParams, _args)
    -- Proxy identifies itself via proxyId in params
    local proxyDeviceId = tointeger(tParams.proxyId)
    if proxyDeviceId ~= nil then
      handleProxyMessage(proxyDeviceId, strCommand, tParams)
    else
      log:warn("Received proxy message without proxyId: %s", strCommand)
    end
  end

  OBC[PROXY_BINDING_ID] = function(_idBinding, _strClass, bIsBound, otherDeviceId, _otherBindingId)
    if bIsBound then
      proxyRegistry:onProxyBound(otherDeviceId)
      addProxyScannerNode(otherDeviceId)
    else
      proxyRegistry:onProxyUnbound(otherDeviceId)
      removeProxyScannerNode(otherDeviceId)
    end
    updateStatusProperties()

    -- Request connection state from all proxies (they identify themselves via proxyId)
    -- This broadcasts to all, but each proxy responds with its state
    if bIsBound then
      SendToProxy(PROXY_BINDING_ID, "GET_CONNECTION_STATE", {}, "NOTIFY")
    end
  end

  -- Check for already-bound proxies (consumers bound to our provider binding)
  local myDeviceId = C4:GetDeviceID()
  local boundDevices = C4:GetBoundConsumerDevices(myDeviceId, PROXY_BINDING_ID)
  if not IsEmpty(boundDevices) then
    for consumerId, _ in pairs(boundDevices) do
      proxyRegistry:onProxyBound(consumerId)
      addProxyScannerNode(consumerId)
    end
    -- Request connection state from all proxies
    SendToProxy(PROXY_BINDING_ID, "GET_CONNECTION_STATE", {}, "NOTIFY")
  end
end

local function setupScannerProperties()
  log:trace("setupScannerProperties()")

  -- Register scan lifecycle callbacks to clear/restore advertisement filter
  -- This allows discovery of NEW devices that aren't in the filter yet
  bleScanner:setOnScanStart(function()
    log:info("Scan starting - clearing advertisement filter to discover new devices")
    SendToProxy(PROXY_BINDING_ID, "SET_ADVERTISEMENT_FILTER", {
      macs = SerializeSafe({}), -- Empty = pass all advertisements
    }, "NOTIFY")
  end)

  bleScanner:setOnScanEnd(function()
    log:info("Scan ended - restoring advertisement filter")
    broadcastAdvertisementFilter()
  end)

  -- Register the "Select Bluetooth Devices" property for tracked devices
  bleScannerProperties:registerProperty("Select Bluetooth Devices", {
    persistKey = PERSIST_SELECTED_DEVICES,
    filter = function(device)
      -- Only show devices with a binding class
      return device.bindingClass ~= nil
    end,
    onChanged = function(selected)
      -- Update selected devices and create/remove bindings
      -- Register newly selected devices
      for mac, scannerDevice in pairs(selected) do
        if not selectedDevices[mac] then
          local device = deviceRegistry:registerDevice({
            name = scannerDevice.name,
            mac = mac,
            address = scannerDevice.address,
            addressType = scannerDevice.addressType,
            deviceType = scannerDevice.deviceType,
            bindingClass = scannerDevice.bindingClass,
            passive = scannerDevice.passive,
          })
          device.bindingId = createDeviceBinding(device)
          selectedDevices[mac] = device
        end
      end
      -- Unregister deselected devices
      for mac, _ in pairs(selectedDevices) do
        if not selected[mac] then
          removeDeviceBinding(mac)
          deviceRegistry:unregisterDevice(mac)
          selectedDevices[mac] = nil
        end
      end
      updateStatusProperties()
      -- Update filter to include/exclude changed devices
      broadcastAdvertisementFilter()
    end,
  })

  -- Register the "Select Presence Devices" property for presence tracking
  bleScannerProperties:registerProperty("Select Presence Devices", {
    persistKey = PERSIST_PRESENCE_DEVICES,
    onChanged = function(selected)
      -- Update presence tracking devices
      local currentPresence = presenceTracker:getPresenceDevices() or {}

      -- Add new presence devices
      for mac, device in pairs(selected) do
        if not currentPresence[mac] then
          presenceTracker:trackDevice(mac, {
            mac = mac,
            name = device.name or mac,
            type = "device",
            txPower = -59,
          })
        end
      end

      -- Remove deselected presence devices
      for mac, _ in pairs(currentPresence) do
        if not selected[mac] then
          presenceTracker:untrackDevice(mac)
        end
      end
      -- Update filter to include/exclude changed devices
      broadcastAdvertisementFilter()
    end,
  })

  -- Set scan duration from property
  bleScanner:setScanDuration(tonumber(Properties["Scan Duration (seconds)"]) or 30)
end

local function setupPresenceTracker()
  log:trace("setupPresenceTracker()")
  -- Configure from properties
  presenceTracker:configure({
    smoothingAlpha = tonumber(Properties["RSSI Smoothing Factor"]) or 0.2,
    hysteresisMargin = tonumber(Properties["Room Change Hysteresis (dBm)"]) or 6,
    dwellTime = tonumber(Properties["Room Change Dwell Time (seconds)"]) or 5,
    awayTimeout = tonumber(Properties["Away Timeout (seconds)"]) or 120,
    minRoomRssi = tointeger(Properties["Minimum Room RSSI (dBm)"]) or -100,
  })

  -- Create generic presence events
  presenceTracker:createGenericEvents()

  -- Start away check timer
  awayCheckTimer = SetTimer("AwayCheck", 30 * 1000, function()
    presenceTracker:checkAwayStatus()
  end, true) -- Repeat
end

--------------------------------------------------------------------------------
-- Control4 Callbacks
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif

  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore persisted state
  values:restoreValues()
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if initialized then
    return
  end

  --#ifdef DRIVERCENTRAL
  if DC_X == 0 then
    updateStatus("No active license", false)
    return
  end
  --#endif

  log:info("Initializing Bluetooth Coordinator")
  updateStatus("Initializing...", false)

  -- Restore persisted events (C4:AddEvent is unavailable before OnDriverLateInit)
  events:restoreEvents()

  -- Set up proxy bindings
  setupProxyBindings()

  -- Set up scanner properties for device selection
  setupScannerProperties()

  -- Set up presence tracking
  setupPresenceTracker()

  -- Restore saved state
  restoreState()

  -- Update status
  updateStatusProperties()
  updateStatus("Running", true)

  -- Fire OnPropertyChanged for all properties to initialize OPC handlers
  -- This runs while initialized=false, so handlers that check initialized will skip
  -- But config handlers (scan duration, presence settings) will run since they check object existence
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  initialized = true
  log:info("Bluetooth Coordinator initialized")
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  if awayCheckTimer then
    CancelTimer(awayCheckTimer)
    awayCheckTimer = nil
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

function OPC.Select_Bluetooth_Devices(propertyValue)
  log:trace("OPC.Select_Bluetooth_Devices(%s)", propertyValue)
  if not initialized or not bleScannerProperties then
    return
  end
  bleScannerProperties:handleSelection("Select Bluetooth Devices", propertyValue)
end

function OPC.Select_Presence_Devices(propertyValue)
  log:trace("OPC.Select_Presence_Devices(%s)", propertyValue)
  if not initialized or not bleScannerProperties then
    return
  end
  bleScannerProperties:handleSelection("Select Presence Devices", propertyValue)
end

function OPC.Scan_Duration_seconds(propertyValue)
  log:trace("OPC.Scan_Duration_seconds(%s)", propertyValue)
  bleScanner:setScanDuration(tonumber(propertyValue) or 30)
end

function OPC.RSSI_Smoothing_Factor(propertyValue)
  log:trace("OPC.RSSI_Smoothing_Factor(%s)", propertyValue)
  presenceTracker:configure({ smoothingAlpha = tonumber(propertyValue) })
end

function OPC.Room_Change_Hysteresis_dBm(propertyValue)
  log:trace("OPC.Room_Change_Hysteresis_dBm(%s)", propertyValue)
  presenceTracker:configure({ hysteresisMargin = tonumber(propertyValue) })
end

function OPC.Room_Change_Dwell_Time_seconds(propertyValue)
  log:trace("OPC.Room_Change_Dwell_Time_seconds(%s)", propertyValue)
  presenceTracker:configure({ dwellTime = tonumber(propertyValue) })
end

function OPC.Away_Timeout_seconds(propertyValue)
  log:trace("OPC.Away_Timeout_seconds(%s)", propertyValue)
  presenceTracker:configure({ awayTimeout = tonumber(propertyValue) })
end

function OPC.RSSI_Freshness_seconds(propertyValue)
  log:trace("OPC.RSSI_Freshness_seconds(%s)", propertyValue)
end

function OPC.Minimum_Room_RSSI_dBm(propertyValue)
  log:trace("OPC.Minimum_Room_RSSI_dBm(%s)", propertyValue)
  presenceTracker:configure({ minRoomRssi = tointeger(propertyValue) })
end
