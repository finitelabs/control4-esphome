local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto-schema")

--- @class BluetoothProxyEntity:Entity
local BluetoothProxyEntity = {
  TYPE = ESPHomeClient.EntityType.BLUETOOTH_PROXY,
}

-- Track discovered devices from advertisements
-- @type table<number, table> -- MAC address as key
local _discoveredDevices = {}

-- Track connected devices
-- @type table<number, table> -- MAC address as key, value = {connected, mtu, services, characteristics}
local _connectedDevices = {}

-- Track device bindings (MAC address to binding ID)
-- @type table<number, number> -- MAC address as key, binding ID as value
local _deviceBindings = {}

--- Create a new instance of the bluetooth_proxy entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return BluetoothProxyEntity entity A new instance of the BluetoothProxyEntity entity.
function BluetoothProxyEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties BluetoothProxyEntity
  return properties
end

--- Convert MAC address from uint64 to string format (XX:XX:XX:XX:XX:XX)
--- @param address number The MAC address as uint64
--- @return string mac The MAC address as string
local function macToString(address)
  -- ESPHome sends MAC as uint64, need to convert to hex string
  local mac = {}
  for i = 1, 6 do
    local byte = address % 256
    table.insert(mac, 1, string.format("%02X", byte))
    address = math.floor(address / 256)
  end
  return table.concat(mac, ":")
end

--- Convert MAC address from string format to uint64
--- @param mac string The MAC address as string (XX:XX:XX:XX:XX:XX)
--- @return number address The MAC address as uint64
local function stringToMac(mac)
  -- Remove colons and convert hex string to number
  local cleaned = mac:gsub(":", "")
  local address = 0
  for i = 1, #cleaned, 2 do
    local byte = tonumber(cleaned:sub(i, i + 1), 16)
    address = address * 256 + byte
  end
  return address
end

--- Initialize the Bluetooth proxy by subscribing to advertisements
--- @return void
function BluetoothProxyEntity:initialize()
  log:trace("BluetoothProxyEntity:initialize()")

  -- Register callbacks for Bluetooth messages
  self.client:registerBluetoothCallback(
    ESPHomeProtoSchema.Message.BluetoothLEAdvertisementResponse,
    function(message)
      self:onAdvertisement(message)
    end
  )

  self.client:registerBluetoothCallback(
    ESPHomeProtoSchema.Message.BluetoothDeviceConnectionResponse,
    function(message)
      self:onConnectionResponse(message)
    end
  )

  self.client:registerBluetoothCallback(
    ESPHomeProtoSchema.Message.BluetoothGATTGetServicesResponse,
    function(message)
      self:onServicesResponse(message)
    end
  )

  self.client:registerBluetoothCallback(
    ESPHomeProtoSchema.Message.BluetoothGATTReadResponse,
    function(message)
      self:onGattReadResponse(message)
    end
  )

  self.client:registerBluetoothCallback(
    ESPHomeProtoSchema.Message.BluetoothGATTWriteResponse,
    function(message)
      self:onGattWriteResponse(message)
    end
  )

  self.client:registerBluetoothCallback(
    ESPHomeProtoSchema.Message.BluetoothGATTNotifyDataResponse,
    function(message)
      self:onGattNotifyData(message)
    end
  )

  -- Subscribe to BLE advertisements
  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.subscribe_bluetooth_le_advertisements,
    { flags = 0 }
  ):next(function()
    log:info("Subscribed to Bluetooth LE advertisements")
  end, function(error)
    log:error("Failed to subscribe to Bluetooth LE advertisements: %s", error)
  end)

  -- Set scanner to active mode for better discovery
  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_scanner_set_mode,
    { mode = ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_ACTIVE }
  ):next(function()
    log:info("Set Bluetooth scanner to active mode")
  end, function(error)
    log:error("Failed to set Bluetooth scanner mode: %s", error)
  end)

  log:info("Bluetooth Proxy entity initialized")
end

--- Handle BLE advertisement received
--- @param message table The advertisement message
--- @return void
function BluetoothProxyEntity:onAdvertisement(message)
  local address = message.address
  local name = message.name or ""
  local rssi = message.rssi or 0
  local macStr = macToString(address)

  log:trace("BLE Advertisement: MAC=%s, Name=%s, RSSI=%d", macStr, name, rssi)

  -- Store discovered device
  _discoveredDevices[address] = {
    address = address,
    mac = macStr,
    name = name,
    rssi = rssi,
    service_uuids = message.service_uuids or {},
    last_seen = os.time(),
  }

  -- If this device has a binding (subdriver connected), notify it of the advertisement
  if _deviceBindings[address] then
    local bindingId = _deviceBindings[address]
    SendToProxy(bindingId, "BLE_ADVERTISEMENT", {
      mac = macStr,
      name = name,
      rssi = tostring(rssi),
      service_uuids = Serialize(message.service_uuids or {}),
    }, "NOTIFY")
  end
end

--- Handle device connection response
--- @param message table The connection response message
--- @return void
function BluetoothProxyEntity:onConnectionResponse(message)
  local address = message.address
  local connected = message.connected or false
  local mtu = message.mtu or 0
  local error = message.error or 0
  local macStr = macToString(address)

  log:debug("BLE Connection Response: MAC=%s, Connected=%s, MTU=%d, Error=%d", macStr, connected, mtu, error)

  if connected then
    _connectedDevices[address] = {
      connected = true,
      mtu = mtu,
      services = {},
    }

    -- Notify the subdriver
    if _deviceBindings[address] then
      local bindingId = _deviceBindings[address]
      SendToProxy(bindingId, "BLE_CONNECTED", {
        mac = macStr,
        mtu = tostring(mtu),
      }, "NOTIFY")

      -- Automatically request GATT services
      self:getServices(address)
    end
  else
    _connectedDevices[address] = nil

    -- Notify the subdriver of disconnection
    if _deviceBindings[address] then
      local bindingId = _deviceBindings[address]
      SendToProxy(bindingId, "BLE_DISCONNECTED", {
        mac = macStr,
        error = tostring(error),
      }, "NOTIFY")
    end
  end
end

--- Handle GATT services response
--- @param message table The services response message
--- @return void
function BluetoothProxyEntity:onServicesResponse(message)
  local address = message.address
  local services = message.services or {}
  local macStr = macToString(address)

  log:debug("BLE GATT Services: MAC=%s, Services=%d", macStr, #services)

  if _connectedDevices[address] then
    _connectedDevices[address].services = services

    -- Notify the subdriver with service info
    if _deviceBindings[address] then
      local bindingId = _deviceBindings[address]
      SendToProxy(bindingId, "BLE_SERVICES_DISCOVERED", {
        mac = macStr,
        services = Serialize(services),
      }, "NOTIFY")
    end
  end
end

--- Handle GATT read response
--- @param message table The read response message
--- @return void
function BluetoothProxyEntity:onGattReadResponse(message)
  local address = message.address
  local handle = message.handle
  local data = message.data or ""
  local macStr = macToString(address)

  log:debug("BLE GATT Read Response: MAC=%s, Handle=0x%04X, Data=%s", macStr, handle, to_hex(data))

  -- Notify the subdriver
  if _deviceBindings[address] then
    local bindingId = _deviceBindings[address]
    SendToProxy(bindingId, "BLE_GATT_READ", {
      mac = macStr,
      handle = tostring(handle),
      data = to_hex(data),
    }, "NOTIFY")
  end
end

--- Handle GATT write response
--- @param message table The write response message
--- @return void
function BluetoothProxyEntity:onGattWriteResponse(message)
  local address = message.address
  local handle = message.handle
  local macStr = macToString(address)

  log:debug("BLE GATT Write Response: MAC=%s, Handle=0x%04X", macStr, handle)

  -- Notify the subdriver
  if _deviceBindings[address] then
    local bindingId = _deviceBindings[address]
    SendToProxy(bindingId, "BLE_GATT_WRITE", {
      mac = macStr,
      handle = tostring(handle),
    }, "NOTIFY")
  end
end

--- Handle GATT notify data
--- @param message table The notify data message
--- @return void
function BluetoothProxyEntity:onGattNotifyData(message)
  local address = message.address
  local handle = message.handle
  local data = message.data or ""
  local macStr = macToString(address)

  log:debug("BLE GATT Notify: MAC=%s, Handle=0x%04X, Data=%s", macStr, handle, to_hex(data))

  -- Notify the subdriver
  if _deviceBindings[address] then
    local bindingId = _deviceBindings[address]
    SendToProxy(bindingId, "BLE_GATT_NOTIFY", {
      mac = macStr,
      handle = tostring(handle),
      data = to_hex(data),
    }, "NOTIFY")
  end
end

--- Connect to a Bluetooth device
--- @param address number The MAC address as uint64
--- @return void
function BluetoothProxyEntity:connectDevice(address)
  local macStr = macToString(address)
  log:debug("Connecting to Bluetooth device: %s", macStr)

  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_device_request,
    {
      address = address,
      request_type = ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE,
      has_address_type = false,
    }
  ):next(function()
    log:debug("Bluetooth connect request sent for %s", macStr)
  end, function(error)
    log:error("Failed to send Bluetooth connect request for %s: %s", macStr, error)
  end)
end

--- Disconnect from a Bluetooth device
--- @param address number The MAC address as uint64
--- @return void
function BluetoothProxyEntity:disconnectDevice(address)
  local macStr = macToString(address)
  log:debug("Disconnecting from Bluetooth device: %s", macStr)

  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_device_request,
    {
      address = address,
      request_type = ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT,
      has_address_type = false,
    }
  ):next(function()
    log:debug("Bluetooth disconnect request sent for %s", macStr)
  end, function(error)
    log:error("Failed to send Bluetooth disconnect request for %s: %s", macStr, error)
  end)
end

--- Get GATT services for a connected device
--- @param address number The MAC address as uint64
--- @return void
function BluetoothProxyEntity:getServices(address)
  local macStr = macToString(address)
  log:debug("Requesting GATT services for: %s", macStr)

  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_get_services,
    { address = address }
  ):next(function()
    log:debug("GATT services request sent for %s", macStr)
  end, function(error)
    log:error("Failed to request GATT services for %s: %s", macStr, error)
  end)
end

--- Read a GATT characteristic
--- @param address number The MAC address as uint64
--- @param handle number The characteristic handle
--- @return void
function BluetoothProxyEntity:readCharacteristic(address, handle)
  local macStr = macToString(address)
  log:debug("Reading GATT characteristic: %s, Handle=0x%04X", macStr, handle)

  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_read,
    {
      address = address,
      handle = handle,
    }
  ):next(function()
    log:debug("GATT read request sent for %s, Handle=0x%04X", macStr, handle)
  end, function(error)
    log:error("Failed to send GATT read request for %s, Handle=0x%04X: %s", macStr, handle, error)
  end)
end

--- Write to a GATT characteristic
--- @param address number The MAC address as uint64
--- @param handle number The characteristic handle
--- @param data string The data to write (binary string)
--- @param response boolean Whether to wait for response
--- @return void
function BluetoothProxyEntity:writeCharacteristic(address, handle, data, response)
  local macStr = macToString(address)
  log:debug("Writing GATT characteristic: %s, Handle=0x%04X, Data=%s", macStr, handle, to_hex(data))

  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_write,
    {
      address = address,
      handle = handle,
      response = response or true,
      data = data,
    }
  ):next(function()
    log:debug("GATT write request sent for %s, Handle=0x%04X", macStr, handle)
  end, function(error)
    log:error("Failed to send GATT write request for %s, Handle=0x%04X: %s", macStr, handle, error)
  end)
end

--- Subscribe to GATT notifications
--- @param address number The MAC address as uint64
--- @param handle number The characteristic handle
--- @param enable boolean Whether to enable notifications
--- @return void
function BluetoothProxyEntity:subscribeNotifications(address, handle, enable)
  local macStr = macToString(address)
  log:debug("%s GATT notifications: %s, Handle=0x%04X", enable and "Enabling" or "Disabling", macStr, handle)

  self.client:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_notify,
    {
      address = address,
      handle = handle,
      enable = enable,
    }
  ):next(function()
    log:debug("GATT notify request sent for %s, Handle=0x%04X", macStr, handle)
  end, function(error)
    log:error("Failed to send GATT notify request for %s, Handle=0x%04X: %s", macStr, handle, error)
  end)
end

--- Handle the discovery of a bluetooth_proxy entity (called when device supports Bluetooth)
--- This is called from the main driver when listEntities completes
--- @param entity table<string, any> The entity data (empty for bluetooth_proxy)
--- @return void
function BluetoothProxyEntity:discovered(entity)
  log:trace("BluetoothProxyEntity:discovered(%s)", entity)

  -- Initialize Bluetooth proxy
  self:initialize()

  -- Create a dynamic binding for managing Bluetooth devices
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "bluetooth_proxy",
      "PROXY",
      true,
      "Bluetooth Proxy",
      "BLUETOOTH_PROXY"
    )
  ).bindingId

  -- Set up RFP handler for commands from subdrivers
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)

    if strCommand == "REGISTER_DEVICE" then
      -- Subdriver wants to register for a specific MAC address
      local mac = Select(tParams, "mac")
      local subdriverBindingId = tointeger(Select(tParams, "binding_id"))

      if not IsEmpty(mac) and subdriverBindingId then
        local address = stringToMac(mac)
        _deviceBindings[address] = subdriverBindingId
        log:info("Registered Bluetooth device %s to binding %d", mac, subdriverBindingId)

        -- Automatically connect to the device
        self:connectDevice(address)
      end

    elseif strCommand == "UNREGISTER_DEVICE" then
      -- Subdriver wants to unregister a MAC address
      local mac = Select(tParams, "mac")

      if not IsEmpty(mac) then
        local address = stringToMac(mac)
        _deviceBindings[address] = nil
        log:info("Unregistered Bluetooth device %s", mac)

        -- Disconnect from the device
        self:disconnectDevice(address)
      end

    elseif strCommand == "GATT_READ" then
      -- Subdriver wants to read a characteristic
      local mac = Select(tParams, "mac")
      local handle = tointeger(Select(tParams, "handle"))

      if not IsEmpty(mac) and handle then
        local address = stringToMac(mac)
        self:readCharacteristic(address, handle)
      end

    elseif strCommand == "GATT_WRITE" then
      -- Subdriver wants to write a characteristic
      local mac = Select(tParams, "mac")
      local handle = tointeger(Select(tParams, "handle"))
      local data = Select(tParams, "data")
      local response = Select(tParams, "response") == "true"

      if not IsEmpty(mac) and handle and data then
        local address = stringToMac(mac)
        -- Convert hex string back to binary
        local binary = data:gsub("%s+", ""):gsub("(%x%x)", function(hex)
          return string.char(tonumber(hex, 16))
        end)
        self:writeCharacteristic(address, handle, binary, response)
      end

    elseif strCommand == "GATT_NOTIFY" then
      -- Subdriver wants to subscribe/unsubscribe to notifications
      local mac = Select(tParams, "mac")
      local handle = tointeger(Select(tParams, "handle"))
      local enable = Select(tParams, "enable") == "true"

      if not IsEmpty(mac) and handle then
        local address = stringToMac(mac)
        self:subscribeNotifications(address, handle, enable)
      end
    end
  end

  OBC[bindingId] = RefreshStatus
end

--- This entity doesn't receive state updates like other entities
--- @param entity table<string, any> The entity data
--- @param state table<string, any> The state data
--- @return void
function BluetoothProxyEntity:updated(entity, state)
  log:trace("BluetoothProxyEntity:updated(%s, %s)", entity, state)
  -- Bluetooth proxy doesn't have traditional state updates
  -- State comes through advertisement/connection/GATT messages instead
end

return BluetoothProxyEntity
