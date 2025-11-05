local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")

--- @class BLEProximityEntity:Entity
local BLEProximityEntity = {
  TYPE = "ble_proximity",
}

-- Track proximity devices
local proximityDevices = {}

--- Create a new instance of the BLE proximity entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return BLEProximityEntity entity A new instance of the BLEProximityEntity entity.
function BLEProximityEntity:new(client)
  local properties = {
    client = client,
    subscribed = false,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties BLEProximityEntity
  return properties
end

--- Convert a Bluetooth MAC address string to a 48-bit number
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF"
--- @return number|nil address 48-bit address as number, or nil if invalid
local function macToNumber(mac)
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
  local addr = tonumber(mac, 16)
  if not addr then
    log:error("Invalid MAC address format: %s", mac)
    return nil
  end

  return addr
end

--- Convert a 48-bit address number back to MAC string
--- @param address number The 48-bit Bluetooth MAC address as a number
--- @return string mac MAC address in format "AA:BB:CC:DD:EE:FF"
local function addressToMac(address)
  -- Handle both number and {high, low} table format
  local addr = address
  if type(address) == "table" then
    -- Convert {high_32, low_32} to single number
    addr = address[1] * 0x100000000 + address[2]
  end

  return string.format("%02X:%02X:%02X:%02X:%02X:%02X",
    math.floor(addr / 0x10000000000) % 256,
    math.floor(addr / 0x100000000) % 256,
    math.floor(addr / 0x1000000) % 256,
    math.floor(addr / 0x10000) % 256,
    math.floor(addr / 0x100) % 256,
    addr % 256
  )
end

--- Update a device's presence state
--- @param deviceKey string The device key (e.g., "ble_proximity_myphone")
--- @param present boolean Whether the device is present
local function updatePresence(deviceKey, present)
  local device = proximityDevices[deviceKey]
  if not device then
    return
  end

  -- Only send notification if state changed
  if device.present ~= present then
    device.present = present

    if present then
      log:info("BLE proximity: %s (%s) is now PRESENT", device.name, device.mac)
      SendToProxy(device.bindingId, "CLOSED", {}, "NOTIFY")
    else
      log:info("BLE proximity: %s (%s) is now AWAY", device.name, device.mac)
      SendToProxy(device.bindingId, "OPENED", {}, "NOTIFY")
    end
  end
end

--- Handle device timeout (no advertisement received for configured timeout period)
--- @param deviceKey string The device key (e.g., "ble_proximity_myphone")
local function handleDeviceTimeout(deviceKey)
  log:debug("BLE proximity timeout for device: %s", deviceKey)
  updatePresence(deviceKey, false)
end

--- Parse proximity devices configuration
--- Format: "AA:BB:CC:DD:EE:FF=MyPhone,11:22:33:44:55:66=MyWatch"
--- @param configString string The configuration string
--- @param timeout number Timeout in seconds
--- @return table devices Parsed devices {mac, name, key}
local function parseProximityConfig(configString, timeout)
  local devices = {}

  if IsEmpty(configString) then
    return devices
  end

  -- Split by comma
  for entry in string.gmatch(configString, "[^,]+") do
    entry = entry:match("^%s*(.-)%s*$")  -- Trim whitespace

    -- Split by = to get MAC and name
    local mac, name = entry:match("^([^=]+)=(.+)$")
    if mac and name then
      mac = mac:match("^%s*(.-)%s*$")  -- Trim MAC
      name = name:match("^%s*(.-)%s*$")  -- Trim name

      -- Validate MAC address
      if macToNumber(mac) then
        -- Create safe key for binding (alphanumeric only)
        local safeKey = name:gsub("[^%w]", ""):lower()

        table.insert(devices, {
          mac = mac:upper(),
          name = name,
          key = "ble_proximity_" .. safeKey,
          timeout = timeout,
        })
      else
        log:warn("Invalid MAC address in proximity config: %s", mac)
      end
    else
      log:warn("Invalid proximity device entry format: %s (expected MAC=Name)", entry)
    end
  end

  return devices
end

--- Update proximity devices from property
--- @param devicesList string Comma-separated list of devices (MAC=Name format)
--- @param timeout number Timeout in seconds before marking device as away
function BLEProximityEntity:updateProximityDevices(devicesList, timeout)
  log:trace("BLEProximityEntity:updateProximityDevices(%s, %s)", devicesList, timeout)

  -- Parse new configuration
  local newDevices = parseProximityConfig(devicesList, timeout)

  -- Find devices to remove
  local currentKeys = {}
  for key, device in pairs(proximityDevices) do
    currentKeys[key] = true
  end

  local newKeys = {}
  for _, device in ipairs(newDevices) do
    newKeys[device.key] = true
  end

  -- Remove devices no longer in config
  for key in pairs(currentKeys) do
    if not newKeys[key] then
      local device = proximityDevices[key]
      log:info("Removing BLE proximity device: %s (%s)", device.name, device.mac)

      -- Cancel timeout timer
      if device.timerName then
        CancelTimer(device.timerName)
      end

      -- Delete dynamic binding
      bindings:deleteBinding(self.TYPE, key)

      proximityDevices[key] = nil
    end
  end

  -- Add or update devices
  for _, deviceConfig in ipairs(newDevices) do
    local key = deviceConfig.key

    if not proximityDevices[key] then
      log:info("Adding BLE proximity device: %s (%s)", deviceConfig.name, deviceConfig.mac)

      -- Create dynamic binding for this device
      local binding = bindings:getOrAddDynamicBinding(
        self.TYPE,
        key,
        "CONTACT",
        true,
        deviceConfig.name .. " Proximity",
        "CONTACT"
      )

      if binding then
        proximityDevices[key] = {
          mac = deviceConfig.mac,
          name = deviceConfig.name,
          bindingId = binding.bindingId,
          present = false,
          lastSeen = 0,
          timeout = deviceConfig.timeout,
          timerName = "ble_proximity_timeout_" .. key,
          macNumber = macToNumber(deviceConfig.mac),
        }

        -- Send initial OPENED state (device is away by default)
        SendToProxy(binding.bindingId, "OPENED", {}, "NOTIFY")

        log:info("Created proximity binding %s for %s (%s)",
          binding.bindingId, deviceConfig.name, deviceConfig.mac)
      end
    else
      -- Update timeout if changed
      proximityDevices[key].timeout = deviceConfig.timeout
    end
  end

  -- Subscribe to advertisements if we have devices to track
  if not self.subscribed and next(proximityDevices) ~= nil then
    log:info("Subscribing to BLE advertisements for proximity tracking")
    self:subscribeToAdvertisements()
  elseif self.subscribed and next(proximityDevices) == nil then
    log:info("No proximity devices configured, unsubscribing from advertisements")
    self.client:unsubscribeBluetoothAdvertisements()
    self.subscribed = false
  end
end

--- Subscribe to BLE advertisements for proximity detection
function BLEProximityEntity:subscribeToAdvertisements()
  if self.subscribed then
    log:debug("Already subscribed to BLE advertisements")
    return
  end

  self.client:subscribeBluetoothLEAdvertisements(function(adv)
    -- Check if this advertisement is from one of our tracked devices
    local advMac = addressToMac(adv.address)

    for key, device in pairs(proximityDevices) do
      if advMac:upper() == device.mac:upper() then
        -- Device seen! Update last seen time
        device.lastSeen = os.time()

        -- Mark as present
        updatePresence(key, true)

        -- Reset timeout timer
        CancelTimer(device.timerName)
        SetTimer(device.timerName, device.timeout * 1000, function()
          handleDeviceTimeout(key)
        end)

        log:debug("BLE proximity: Received advertisement from %s (%s), RSSI: %s",
          device.name, device.mac, adv.rssi or "unknown")

        break
      end
    end
  end):catch(function(err)
    log:error("Failed to subscribe to BLE advertisements: %s", tostring(err))
  end)

  self.subscribed = true
end

--- Handle the discovery of bluetooth proxy capability
--- This is called when the ESPHome device reports bluetooth_proxy capability
--- @param entity table<string, any> The entity data (may be empty for capability detection)
--- @return void
function BLEProximityEntity:discovered(entity)
  log:trace("BLEProximityEntity:discovered(%s)", entity)
  log:info("Bluetooth Proxy capability detected - BLE proximity tracking available")

  -- Initial device configuration if property already set
  local devicesList = Properties["BLE Proximity Devices"]
  local timeout = tonumber(Properties["BLE Presence Timeout"]) or 60

  if not IsEmpty(devicesList) then
    self:updateProximityDevices(devicesList, timeout)
  end
end

--- BLE proximity doesn't have state updates like other entities
--- @param entity table<string, any> The entity data
--- @param state table<string, any> The state data
--- @return void
function BLEProximityEntity:updated(entity, state)
  log:trace("BLEProximityEntity:updated(%s, %s)", entity, state)
  -- No state updates for BLE proximity
end

return BLEProximityEntity
