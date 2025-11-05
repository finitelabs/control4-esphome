local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")

--- @class BluetoothProxyEntity:Entity
local BluetoothProxyEntity = {
  TYPE = ESPHomeClient.EntityType.BLUETOOTH_PROXY,
}

-- Track connected Bluetooth devices
local connectedDevices = {}

--- Create a new instance of the bluetooth proxy entity.
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

--- Convert a Bluetooth MAC address string to a 48-bit number
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF"
--- @return number|nil address 48-bit address as a number, or nil if invalid
local function macToAddress(mac)
  if IsEmpty(mac) then
    return nil
  end

  -- Remove colons, spaces, and convert to uppercase
  mac = mac:gsub("[:%s]", ""):upper()

  -- Validate length
  if #mac ~= 12 then
    log:error("Invalid MAC address length: %s", mac)
    return nil
  end

  -- Convert hex string to number
  local address = 0
  for i = 1, 12, 2 do
    local byte = tonumber(mac:sub(i, i + 1), 16)
    if not byte then
      log:error("Invalid MAC address format: %s", mac)
      return nil
    end
    address = address * 256 + byte
  end

  return address
end

--- Convert a 48-bit address number back to MAC string
--- @param address number 48-bit address as a number
--- @return string mac MAC address in format "AA:BB:CC:DD:EE:FF"
local function addressToMac(address)
  local bytes = {}
  for i = 1, 6 do
    table.insert(bytes, 1, string.format("%02X", address % 256))
    address = math.floor(address / 256)
  end
  return table.concat(bytes, ":")
end

--- Determine device type from GATT services
--- @param services table[] Array of GATT services
--- @return string|nil deviceType The device type ("switchbot", etc.) or nil if unknown
local function identifyDeviceType(services)
  -- Switchbot service UUID: cba20d00-224d-11e6-9fb8-0002a5d5c51b
  local switchbotServiceHigh = 0xcba20d00224d11e6
  local switchbotServiceLow = 0x9fb80002a5d5c51b

  for _, service in ipairs(services) do
    if service.uuid and #service.uuid >= 2 then
      if service.uuid[1] == switchbotServiceHigh and service.uuid[2] == switchbotServiceLow then
        return "switchbot"
      end
    end
  end

  return nil
end

--- Connect to a Bluetooth device by MAC address
--- @param macAddress string MAC address in format "AA:BB:CC:DD:EE:FF"
function BluetoothProxyEntity:connectDevice(macAddress)
  log:trace("BluetoothProxyEntity:connectDevice(%s)", macAddress)

  local address = macToAddress(macAddress)
  if not address then
    log:error("Invalid MAC address: %s", macAddress)
    return
  end

  -- Check if already connected
  if connectedDevices[address] then
    log:info("Device %s already connected", macAddress)
    return
  end

  log:info("Connecting to Bluetooth device: %s (0x%012X)", macAddress, address)

  -- Initialize device tracking
  connectedDevices[address] = {
    macAddress = macAddress,
    connected = false,
    services = nil,
    deviceType = nil,
    bindingId = nil,
  }

  -- Connect to the device
  self.client:bluetoothDeviceConnect(
    address,
    function(message, schema)
      log:debug("Bluetooth connection response for %s: connected=%s, mtu=%s, error=%s",
        macAddress, message.connected, message.mtu, message.error)

      if message.connected then
        connectedDevices[address].connected = true

        -- Discover GATT services
        self.client:bluetoothGattGetServices(address, function(services, done)
          if done then
            log:info("GATT service discovery complete for %s", macAddress)

            -- Identify device type
            local deviceType = identifyDeviceType(connectedDevices[address].services or {})
            connectedDevices[address].deviceType = deviceType

            if deviceType then
              log:info("Identified device %s as type: %s", macAddress, deviceType)

              -- Create dynamic binding for sub-driver
              local bindingClass = "ESPHOME_" .. deviceType:upper()
              local binding = bindings:getOrAddDynamicBinding(
                self.TYPE,
                "bt_" .. macAddress:gsub(":", ""),
                "PROXY",
                true,
                deviceType:upper() .. " " .. macAddress,
                bindingClass
              )

              if binding then
                connectedDevices[address].bindingId = binding.bindingId

                -- Register RFP handler for this device
                RFP[binding.bindingId] = function(idBinding, strCommand, tParams, args)
                  self:handleCommand(address, idBinding, strCommand, tParams, args)
                end

                -- Send initial connection info to sub-driver
                SendToProxy(binding.bindingId, "CONNECTED", {
                  mac_address = macAddress,
                  device_type = deviceType,
                  services = Serialize(connectedDevices[address].services or {}),
                }, "NOTIFY")

                log:info("Created dynamic binding %s for %s device %s",
                  binding.bindingId, deviceType, macAddress)
              end
            else
              log:warn("Could not identify device type for %s", macAddress)
            end
          else
            -- Accumulate services
            if not connectedDevices[address].services then
              connectedDevices[address].services = {}
            end
            for _, service in ipairs(services) do
              table.insert(connectedDevices[address].services, service)
            end
            log:debug("Received %d GATT services for %s", #services, macAddress)
          end
        end)
      else
        log:error("Failed to connect to %s: error=%s", macAddress, message.error)
        connectedDevices[address] = nil
      end
    end,
    nil,
    true
  )
end

--- Disconnect from a Bluetooth device
--- @param macAddress string MAC address in format "AA:BB:CC:DD:EE:FF"
function BluetoothProxyEntity:disconnectDevice(macAddress)
  log:trace("BluetoothProxyEntity:disconnectDevice(%s)", macAddress)

  local address = macToAddress(macAddress)
  if not address or not connectedDevices[address] then
    return
  end

  -- Delete dynamic binding
  if connectedDevices[address].bindingId then
    local bindingKey = "bt_" .. macAddress:gsub(":", "")
    bindings:deleteBinding(self.TYPE, bindingKey)
  end

  -- Disconnect from device
  self.client:bluetoothDeviceDisconnect(address)

  connectedDevices[address] = nil
  log:info("Disconnected from Bluetooth device: %s", macAddress)
end

--- Handle commands from sub-driver
--- @param address number The 48-bit Bluetooth MAC address as a number
--- @param idBinding number The binding ID
--- @param strCommand string The command string
--- @param tParams table Command parameters
--- @param args table Command arguments
function BluetoothProxyEntity:handleCommand(address, idBinding, strCommand, tParams, args)
  log:trace("BluetoothProxyEntity:handleCommand(%s, %s, %s, %s, %s)",
    address, idBinding, strCommand, tParams, args)

  local device = connectedDevices[address]
  if not device or not device.connected then
    log:error("Device not connected: 0x%012X", address)
    return
  end

  if strCommand == "GATT_WRITE" then
    local handle = tonumber(Select(tParams, "handle"))
    local data = Deserialize(Select(tParams, "data"))
    local needResponse = Select(tParams, "response") == "true"

    if not handle or not data then
      log:error("Invalid GATT_WRITE parameters")
      return
    end

    log:debug("GATT write to 0x%012X handle %d: %d bytes", address, handle, #data)

    self.client:bluetoothGattWrite(address, handle, data, needResponse, function(success, error)
      SendToProxy(idBinding, "GATT_WRITE_RESPONSE", {
        success = success and "true" or "false",
        error = tostring(error or 0),
      }, "NOTIFY")
    end)

  elseif strCommand == "GATT_READ" then
    local handle = tonumber(Select(tParams, "handle"))

    if not handle then
      log:error("Invalid GATT_READ parameters")
      return
    end

    log:debug("GATT read from 0x%012X handle %d", address, handle)

    self.client:bluetoothGattRead(address, handle, function(data, error)
      SendToProxy(idBinding, "GATT_READ_RESPONSE", {
        data = Serialize(data or ""),
        error = tostring(error or 0),
      }, "NOTIFY")
    end)

  elseif strCommand == "GATT_NOTIFY" then
    local handle = tonumber(Select(tParams, "handle"))
    local enable = Select(tParams, "enable") == "true"

    if not handle then
      log:error("Invalid GATT_NOTIFY parameters")
      return
    end

    log:debug("GATT notify for 0x%012X handle %d: %s", address, handle, enable)

    self.client:bluetoothGattNotify(address, handle, enable, function(data)
      SendToProxy(idBinding, "GATT_NOTIFY_DATA", {
        handle = tostring(handle),
        data = Serialize(data),
      }, "NOTIFY")
    end)

  elseif strCommand == "REFRESH_STATE" then
    -- Resend connection info
    SendToProxy(idBinding, "CONNECTED", {
      mac_address = device.macAddress,
      device_type = device.deviceType,
      services = Serialize(device.services or {}),
    }, "NOTIFY")
  end
end

--- Update Bluetooth devices from property
--- @param devicesList string Comma-separated list of MAC addresses
function BluetoothProxyEntity:updateDevices(devicesList)
  log:trace("BluetoothProxyEntity:updateDevices(%s)", devicesList)

  -- Parse MAC addresses
  local newMacs = {}
  if not IsEmpty(devicesList) then
    for mac in string.gmatch(devicesList, "[^,]+") do
      mac = mac:match("^%s*(.-)%s*$")  -- Trim whitespace
      if not IsEmpty(mac) then
        table.insert(newMacs, mac)
      end
    end
  end

  -- Find devices to disconnect
  local currentMacs = {}
  for address, device in pairs(connectedDevices) do
    currentMacs[device.macAddress] = true
  end

  for mac in pairs(currentMacs) do
    local found = false
    for _, newMac in ipairs(newMacs) do
      if mac:upper() == newMac:upper() then
        found = true
        break
      end
    end
    if not found then
      self:disconnectDevice(mac)
    end
  end

  -- Connect to new devices
  for _, mac in ipairs(newMacs) do
    self:connectDevice(mac)
  end
end

--- Handle the discovery of bluetooth proxy capability
--- This is called when the ESPHome device reports bluetooth_proxy capability
--- @param entity table<string, any> The entity data (may be empty for capability detection)
--- @return void
function BluetoothProxyEntity:discovered(entity)
  log:trace("BluetoothProxyEntity:discovered(%s)", entity)
  log:info("Bluetooth Proxy capability detected")

  -- Initial device connection if property already set
  local devicesList = Properties["Bluetooth Devices"]
  if not IsEmpty(devicesList) then
    self:updateDevices(devicesList)
  end
end

--- Bluetooth proxy doesn't have state updates like other entities
--- @param entity table<string, any> The entity data
--- @param state table<string, any> The state data
--- @return void
function BluetoothProxyEntity:updated(entity, state)
  log:trace("BluetoothProxyEntity:updated(%s, %s)", entity, state)
  -- No state updates for bluetooth proxy
end

return BluetoothProxyEntity
