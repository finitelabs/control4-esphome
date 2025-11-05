--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_bluetooth.c4z"
--#endif
require("lib.utils")
require("vendor.drivers-common-public.global.handlers")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")

JSON = require("vendor.JSON")
local log = require("lib.logging")
local values = require("lib.values")

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

-- Switchbot GATT handles (these are discovered dynamically)
local GATT_HANDLES = {
  SWITCHBOT_PRESS = nil,      -- Handle for switch command
  SWITCHBOT_BATTERY = nil,    -- Handle for battery level
}

-- Device state
local MAC_ADDRESS = nil
local DEVICE_TYPE = nil
local CONNECTED = false
local SERVICES = {}

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("vendor.cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err ~= nil then
      log:error(err)
    end
  end
  gInitialized = true

  -- Create battery variable
  values:update("Battery Level", 0, "NUMBER")
  values:update("RSSI", 0, "NUMBER")

  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "false" }, "NOTIFY")

  -- Register with Bluetooth proxy if MAC address is set
  RegisterDevice()
end

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
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
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
  end
end

function OPC.MAC_Address(propertyValue)
  log:trace("OPC.MAC_Address('%s')", propertyValue)
  MAC_ADDRESS = propertyValue
  RegisterDevice()
end

function OPC.Device_Type(propertyValue)
  log:trace("OPC.Device_Type('%s')", propertyValue)
  DEVICE_TYPE = propertyValue
end

function RegisterDevice()
  if not gInitialized or IsEmpty(MAC_ADDRESS) then
    return
  end

  log:info("Registering Bluetooth device: %s", MAC_ADDRESS)
  SendToProxy(ESPHOME_BINDING, "REGISTER_DEVICE", {
    mac = MAC_ADDRESS,
    binding_id = tostring(C4:GetDeviceID()),
  })
end

function UnregisterDevice()
  if IsEmpty(MAC_ADDRESS) then
    return
  end

  log:info("Unregistering Bluetooth device: %s", MAC_ADDRESS)
  SendToProxy(ESPHOME_BINDING, "UNREGISTER_DEVICE", {
    mac = MAC_ADDRESS,
  })
end

--- Convert hex string to binary data
--- @param hex string Hex string (e.g., "0157")
--- @return string binary Binary data
local function hexToBytes(hex)
  local result = {}
  for i = 1, #hex, 2 do
    local byte = tonumber(hex:sub(i, i + 1), 16)
    table.insert(result, string.char(byte))
  end
  return table.concat(result)
end

--- Convert binary data to hex string
--- @param bytes string Binary data
--- @return string hex Hex string
local function bytesToHex(bytes)
  local result = {}
  for i = 1, #bytes do
    table.insert(result, string.format("%02X", string.byte(bytes, i)))
  end
  return table.concat(result)
end

--- Switchbot: Send press command (toggle on/off)
--- @param press boolean true to press (turn on), false to turn off
function SwitchbotPress(press)
  log:trace("SwitchbotPress(%s)", press)

  if not CONNECTED then
    log:warn("Cannot send command: device not connected")
    return
  end

  -- Switchbot command format: 0x57 0x01 (press/on) or 0x57 0x02 (turn off)
  local command = press and "5701" or "5702"

  -- Find the press handle
  local pressHandle = FindCharacteristicHandleByUUID("cba20002-224d-11e6-9fb8-0002a5d5c51b")

  if pressHandle then
    log:debug("Sending Switchbot press command to handle 0x%04X: %s", pressHandle, command)
    SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
      mac = MAC_ADDRESS,
      handle = tostring(pressHandle),
      data = command,
      response = "true",
    })
  else
    log:error("Could not find Switchbot press characteristic handle")
  end
end

--- Find a characteristic handle by UUID
--- @param uuid string The UUID to search for
--- @return number|nil handle The handle if found, nil otherwise
function FindCharacteristicHandleByUUID(uuid)
  log:trace("FindCharacteristicHandleByUUID(%s)", uuid)

  -- Convert UUID string to the format used in services
  local uuidLower = uuid:lower():gsub("-", "")

  for _, service in ipairs(SERVICES) do
    if service.characteristics then
      for _, char in ipairs(service.characteristics) do
        -- Check if UUID matches (could be in short_uuid or full uuid array)
        if char.short_uuid then
          local shortUuidStr = string.format("%04x", char.short_uuid)
          if uuidLower:find(shortUuidStr) then
            log:debug("Found characteristic with short UUID 0x%04X, handle 0x%04X", char.short_uuid, char.handle)
            return char.handle
          end
        end
        if char.uuid and #char.uuid >= 2 then
          -- UUIDs are stored as 2 uint64 values (128-bit total)
          -- For now, just return the handle if we have a UUID
          log:debug("Found characteristic handle 0x%04X", char.handle)
          return char.handle
        end
      end
    end
  end

  return nil
end

--- Read battery level from Switchbot
function ReadBattery()
  log:trace("ReadBattery()")

  if not CONNECTED then
    log:warn("Cannot read battery: device not connected")
    return
  end

  -- Find the battery handle (standard Battery Level characteristic: 0x2A19)
  local batteryHandle = FindCharacteristicHandleByUUID("00002a19-0000-1000-8000-00805f9b34fb")

  if batteryHandle then
    log:debug("Reading battery from handle 0x%04X", batteryHandle)
    SendToProxy(ESPHOME_BINDING, "GATT_READ", {
      mac = MAC_ADDRESS,
      handle = tostring(batteryHandle),
    })
  else
    log:warn("Could not find battery characteristic handle")
  end
end

--- Control4 Relay Proxy Commands
function RFP.ON(idBinding, strCommand)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.ON called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end

  if DEVICE_TYPE == "Switchbot" then
    SwitchbotPress(true)
    -- Optimistically update state
    SendToProxy(PROXY_BINDING, "SWITCH_STATE_CHANGED", { STATE = "on" }, "NOTIFY")
  end
end

function RFP.OFF(idBinding, strCommand)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.OFF called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end

  if DEVICE_TYPE == "Switchbot" then
    SwitchbotPress(false)
    -- Optimistically update state
    SendToProxy(PROXY_BINDING, "SWITCH_STATE_CHANGED", { STATE = "off" }, "NOTIFY")
  end
end

--- Bluetooth Proxy Messages
function RFP.BLE_ADVERTISEMENT(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_ADVERTISEMENT(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local mac = Select(tParams, "mac")
  local name = Select(tParams, "name")
  local rssi = tointeger(Select(tParams, "rssi")) or 0

  if mac == MAC_ADDRESS then
    log:debug("Received advertisement from %s (RSSI: %d)", mac, rssi)
    values:update("RSSI", rssi, "NUMBER")
  end
end

function RFP.BLE_CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_CONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local mac = Select(tParams, "mac")
  local mtu = tointeger(Select(tParams, "mtu")) or 0

  if mac == MAC_ADDRESS then
    log:info("Connected to Bluetooth device %s (MTU: %d)", mac, mtu)
    CONNECTED = true
    UpdateProperty("Driver Status", "Connected")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")
  end
end

function RFP.BLE_DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_DISCONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local mac = Select(tParams, "mac")
  local error = Select(tParams, "error")

  if mac == MAC_ADDRESS then
    log:warn("Disconnected from Bluetooth device %s (Error: %s)", mac, error)
    CONNECTED = false
    SERVICES = {}
    UpdateProperty("Driver Status", "Disconnected")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "false" }, "NOTIFY")
  end
end

function RFP.BLE_SERVICES_DISCOVERED(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_SERVICES_DISCOVERED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local mac = Select(tParams, "mac")
  local servicesStr = Select(tParams, "services")

  if mac == MAC_ADDRESS and not IsEmpty(servicesStr) then
    SERVICES = Deserialize(servicesStr) or {}
    log:info("Discovered %d GATT services for %s", #SERVICES, mac)

    -- Log all services and characteristics for debugging
    for _, service in ipairs(SERVICES) do
      log:debug("Service handle: 0x%04X", service.handle or 0)
      if service.characteristics then
        for _, char in ipairs(service.characteristics) do
          log:debug("  Characteristic handle: 0x%04X, short_uuid: 0x%04X, properties: 0x%02X",
            char.handle or 0, char.short_uuid or 0, char.properties or 0)
        end
      end
    end

    -- Read battery level after service discovery
    if DEVICE_TYPE == "Switchbot" then
      SetTimer("ReadBattery", 2000, ReadBattery)
    end
  end
end

function RFP.BLE_GATT_READ(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_GATT_READ(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local mac = Select(tParams, "mac")
  local handle = tointeger(Select(tParams, "handle")) or 0
  local data = Select(tParams, "data") or ""

  if mac == MAC_ADDRESS then
    log:debug("GATT Read Response: handle=0x%04X, data=%s", handle, data)

    -- Check if this is battery data
    local batteryHandle = FindCharacteristicHandleByUUID("00002a19-0000-1000-8000-00805f9b34fb")
    if batteryHandle and handle == batteryHandle then
      -- Battery level is a single byte (0-100%)
      if #data >= 2 then
        local batteryLevel = tonumber(data:sub(1, 2), 16) or 0
        log:info("Battery level: %d%%", batteryLevel)
        values:update("Battery Level", batteryLevel, "NUMBER")
      end
    end
  end
end

function RFP.BLE_GATT_WRITE(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_GATT_WRITE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local mac = Select(tParams, "mac")
  local handle = tointeger(Select(tParams, "handle")) or 0

  if mac == MAC_ADDRESS then
    log:debug("GATT Write Response: handle=0x%04X", handle)
  end
end

function RFP.BLE_GATT_NOTIFY(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_GATT_NOTIFY(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local mac = Select(tParams, "mac")
  local handle = tointeger(Select(tParams, "handle")) or 0
  local data = Select(tParams, "data") or ""

  if mac == MAC_ADDRESS then
    log:debug("GATT Notify: handle=0x%04X, data=%s", handle, data)
  end
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, re-register the device
  RegisterDevice()
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  UnregisterDevice()
end
