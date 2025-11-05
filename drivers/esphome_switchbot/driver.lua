--#ifdef DRIVERCENTRAL
DC_PID = 820
DC_X = nil
DC_FILENAME = "esphome_switchbot.c4z"
--#endif
require("lib.utils")
require("vendor.drivers-common-public.global.handlers")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")

JSON = require("vendor.JSON")
local ESPHomeProtoSchema = require("esphome.proto-schema")

local log = require("lib.logging")

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

-- Switchbot Bot Protocol Constants
local SWITCHBOT_SERVICE_UUID = "cba20d00-224d-11e6-9fb8-0002a5d5c51b"
local SWITCHBOT_TX_UUID = "cba20002-224d-11e6-9fb8-0002a5d5c51b"  -- Write characteristic
local SWITCHBOT_RX_UUID = "cba20003-224d-11e6-9fb8-0002a5d5c51b"  -- Read/Notify characteristic

-- Switchbot command bytes
local CMD_ON = string.char(0x57, 0x01, 0x01)
local CMD_OFF = string.char(0x57, 0x01, 0x02)

-- Global state
local BT_ADDRESS = nil  -- Bluetooth MAC address as a number
local BT_CONNECTED = false
local TX_HANDLE = nil  -- Write characteristic handle
local RX_HANDLE = nil  -- Read characteristic handle
local CURRENT_STATE = false  -- Current switch state (on/off)

--- Convert a Bluetooth MAC address string to a 48-bit number
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF"
--- @return number|nil address 48-bit address as a number, or nil if invalid
local function macToAddress(mac)
  if IsEmpty(mac) then
    return nil
  end

  -- Remove colons and convert to uppercase
  mac = mac:gsub(":", ""):upper()

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

--- Convert UUID string to 128-bit number representation (as two 64-bit numbers)
--- @param uuid string UUID in format "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
--- @return number, number high, low Two 64-bit numbers representing the UUID
local function uuidToNumbers(uuid)
  -- Remove hyphens
  uuid = uuid:gsub("-", ""):upper()

  -- Split into high and low 64-bit parts
  local high = tonumber(uuid:sub(1, 16), 16)
  local low = tonumber(uuid:sub(17, 32), 16)

  return high, low
end

--- Find a GATT characteristic handle by UUID
--- @param services table[] Array of GATT services
--- @param serviceUuid string Service UUID
--- @param charUuid string Characteristic UUID
--- @return number|nil handle The characteristic handle, or nil if not found
local function findCharacteristicHandle(services, serviceUuid, charUuid)
  local svcHigh, svcLow = uuidToNumbers(serviceUuid)
  local charHigh, charLow = uuidToNumbers(charUuid)

  for _, service in ipairs(services) do
    -- Check if service UUID matches
    if service.uuid and #service.uuid >= 2 then
      if service.uuid[1] == svcHigh and service.uuid[2] == svcLow then
        -- Found matching service, search characteristics
        for _, characteristic in ipairs(service.characteristics or {}) do
          if characteristic.uuid and #characteristic.uuid >= 2 then
            if characteristic.uuid[1] == charHigh and characteristic.uuid[2] == charLow then
              return characteristic.handle
            end
          end
        end
      end
    end
  end

  return nil
end

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
  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "false" }, "NOTIFY")

  -- Parse MAC address
  BT_ADDRESS = macToAddress(Properties["Bluetooth MAC Address"])
  if BT_ADDRESS then
    log:info("Bluetooth MAC address: %s (0x%012X)", addressToMac(BT_ADDRESS), BT_ADDRESS)
    SendToProxy(ESPHOME_BINDING, "SWITCHBOT_CONNECT", {
      address = tostring(BT_ADDRESS)
    }, "NOTIFY")
  else
    log:warn("No valid Bluetooth MAC address configured")
  end
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

function OPC.Bluetooth_MAC_Address(propertyValue)
  log:trace("OPC.Bluetooth_MAC_Address('%s')", propertyValue)
  BT_ADDRESS = macToAddress(propertyValue)
  if BT_ADDRESS then
    log:info("Bluetooth MAC address updated: %s (0x%012X)", addressToMac(BT_ADDRESS), BT_ADDRESS)
    -- Reconnect with new address
    BT_CONNECTED = false
    TX_HANDLE = nil
    RX_HANDLE = nil
    SendToProxy(ESPHOME_BINDING, "SWITCHBOT_CONNECT", {
      address = tostring(BT_ADDRESS)
    }, "NOTIFY")
  else
    log:error("Invalid Bluetooth MAC address: %s", propertyValue)
  end
end

--- Turn the Switchbot on
local function turnOn()
  log:trace("turnOn()")
  if not BT_CONNECTED or not TX_HANDLE then
    log:error("Cannot turn on: not connected")
    return
  end

  SendToProxy(ESPHOME_BINDING, "SWITCHBOT_WRITE", {
    address = tostring(BT_ADDRESS),
    handle = tostring(TX_HANDLE),
    data = Serialize(CMD_ON),
  }, "NOTIFY")

  CURRENT_STATE = true
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "CLOSED", {}, "NOTIFY")  -- RELAY proxy uses CLOSED for "on"
end

--- Turn the Switchbot off
local function turnOff()
  log:trace("turnOff()")
  if not BT_CONNECTED or not TX_HANDLE then
    log:error("Cannot turn off: not connected")
    return
  end

  SendToProxy(ESPHOME_BINDING, "SWITCHBOT_WRITE", {
    address = tostring(BT_ADDRESS),
    handle = tostring(TX_HANDLE),
    data = Serialize(CMD_OFF),
  }, "NOTIFY")

  CURRENT_STATE = false
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "OPENED", {}, "NOTIFY")  -- RELAY proxy uses OPENED for "off"
end

--- Read the battery level
local function readBattery()
  log:trace("readBattery()")
  if not BT_CONNECTED or not RX_HANDLE then
    log:error("Cannot read battery: not connected")
    return
  end

  SendToProxy(ESPHOME_BINDING, "SWITCHBOT_READ", {
    address = tostring(BT_ADDRESS),
    handle = tostring(RX_HANDLE),
  }, "NOTIFY")
end

function RFP.ON(idBinding, strCommand)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.ON called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  turnOn()
end

function RFP.OFF(idBinding, strCommand)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.OFF called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  turnOff()
end

function RFP.CLOSE(idBinding, strCommand)
  log:trace("RFP.CLOSE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.CLOSE called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  turnOn()  -- CLOSE = ON for relay
end

function RFP.OPEN(idBinding, strCommand)
  log:trace("RFP.OPEN(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.OPEN called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  turnOff()  -- OPEN = OFF for relay
end

function RFP.TOGGLE(idBinding, strCommand)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.TOGGLE called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end

  if CURRENT_STATE then
    turnOff()
  else
    turnOn()
  end
end

--- Handle connection response from main driver
function RFP.SWITCHBOT_CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.SWITCHBOT_CONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    log:error("RFP.SWITCHBOT_CONNECTED called with idBinding %s, expected %s", idBinding, ESPHOME_BINDING)
    return
  end

  local connected = Select(tParams, "connected") == "true"
  local services = Deserialize(Select(tParams, "services"))

  if connected and services then
    BT_CONNECTED = true

    -- Find TX and RX handles
    TX_HANDLE = findCharacteristicHandle(services, SWITCHBOT_SERVICE_UUID, SWITCHBOT_TX_UUID)
    RX_HANDLE = findCharacteristicHandle(services, SWITCHBOT_SERVICE_UUID, SWITCHBOT_RX_UUID)

    if TX_HANDLE and RX_HANDLE then
      log:info("Connected to Switchbot - TX handle: %s, RX handle: %s", TX_HANDLE, RX_HANDLE)
      UpdateProperty("Driver Status", "Connected")
      SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")

      -- Read initial battery level
      SetTimer("ReadBattery", 1000, readBattery)

      -- Set up periodic battery reads (every 5 minutes)
      SetTimer("PeriodicBattery", 5 * ONE_MINUTE, readBattery, true)
    else
      log:error("Could not find Switchbot characteristics (TX: %s, RX: %s)", TX_HANDLE, RX_HANDLE)
      BT_CONNECTED = false
    end
  else
    log:warn("Switchbot connection failed")
    BT_CONNECTED = false
    TX_HANDLE = nil
    RX_HANDLE = nil
    UpdateProperty("Driver Status", "Disconnected")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "false" }, "NOTIFY")
  end
end

--- Handle read response from main driver
function RFP.SWITCHBOT_READ_RESPONSE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SWITCHBOT_READ_RESPONSE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    log:error("RFP.SWITCHBOT_READ_RESPONSE called with idBinding %s, expected %s", idBinding, ESPHOME_BINDING)
    return
  end

  local data = Deserialize(Select(tParams, "data"))
  if data and #data >= 2 then
    -- Battery is at index 2 (Lua uses 1-based indexing, but we need byte 1 in 0-based)
    local batteryByte = string.byte(data, 2)
    if batteryByte then
      local batteryLevel = batteryByte
      log:info("Battery level: %d%%", batteryLevel)
      UpdateProperty("Battery Level", string.format("%d%%", batteryLevel))
    end
  end
end

--- Handle write response from main driver
function RFP.SWITCHBOT_WRITE_RESPONSE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SWITCHBOT_WRITE_RESPONSE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    log:error("RFP.SWITCHBOT_WRITE_RESPONSE called with idBinding %s, expected %s", idBinding, ESPHOME_BINDING)
    return
  end

  local success = Select(tParams, "success") == "true"
  if success then
    log:debug("Write command successful")
  else
    log:error("Write command failed")
  end
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, reset globals to allow for a refresh of the driver state.
  BT_ADDRESS = macToAddress(Properties["Bluetooth MAC Address"])
  BT_CONNECTED = false
  TX_HANDLE = nil
  RX_HANDLE = nil
end
