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

local log = require("lib.logging")

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

-- Switchbot Bot Protocol Constants
local SWITCHBOT_SERVICE_UUID_HIGH = 0xcba20d00224d11e6
local SWITCHBOT_SERVICE_UUID_LOW = 0x9fb80002a5d5c51b
local SWITCHBOT_TX_UUID_HIGH = 0xcba20002224d11e6
local SWITCHBOT_TX_UUID_LOW = 0x9fb80002a5d5c51b
local SWITCHBOT_RX_UUID_HIGH = 0xcba20003224d11e6
local SWITCHBOT_RX_UUID_LOW = 0x9fb80002a5d5c51b

-- Switchbot command bytes
local CMD_ON = string.char(0x57, 0x01, 0x01)
local CMD_OFF = string.char(0x57, 0x01, 0x02)

-- Global state
local CONNECTED = false
local TX_HANDLE = nil  -- Write characteristic handle
local RX_HANDLE = nil  -- Read characteristic handle
local SERVICES = nil   -- GATT services from main driver
local CURRENT_STATE = false  -- Current switch state (on/off)

--- Find a GATT characteristic handle by UUID
--- @param services table[] Array of GATT services
--- @param serviceUuidHigh number High 64 bits of service UUID
--- @param serviceUuidLow number Low 64 bits of service UUID
--- @param charUuidHigh number High 64 bits of characteristic UUID
--- @param charUuidLow number Low 64 bits of characteristic UUID
--- @return number|nil handle The characteristic handle, or nil if not found
local function findCharacteristicHandle(services, serviceUuidHigh, serviceUuidLow, charUuidHigh, charUuidLow)
  for _, service in ipairs(services) do
    if service.uuid and #service.uuid >= 2 then
      if service.uuid[1] == serviceUuidHigh and service.uuid[2] == serviceUuidLow then
        -- Found matching service, search characteristics
        for _, characteristic in ipairs(service.characteristics or {}) do
          if characteristic.uuid and #characteristic.uuid >= 2 then
            if characteristic.uuid[1] == charUuidHigh and characteristic.uuid[2] == charUuidLow then
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

  -- Request current state from main driver
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
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

--- Turn the Switchbot on
local function turnOn()
  log:trace("turnOn()")
  if not CONNECTED or not TX_HANDLE then
    log:error("Cannot turn on: not connected")
    return
  end

  -- Send GATT write command to main driver
  SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
    handle = tostring(TX_HANDLE),
    data = Serialize(CMD_ON),
    response = "true",
  }, "NOTIFY")

  CURRENT_STATE = true
  SendToProxy(PROXY_BINDING, "CLOSED", {}, "NOTIFY")
end

--- Turn the Switchbot off
local function turnOff()
  log:trace("turnOff()")
  if not CONNECTED or not TX_HANDLE then
    log:error("Cannot turn off: not connected")
    return
  end

  -- Send GATT write command to main driver
  SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
    handle = tostring(TX_HANDLE),
    data = Serialize(CMD_OFF),
    response = "true",
  }, "NOTIFY")

  CURRENT_STATE = false
  SendToProxy(PROXY_BINDING, "OPENED", {}, "NOTIFY")
end

--- Read the battery level
local function readBattery()
  log:trace("readBattery()")
  if not CONNECTED or not RX_HANDLE then
    log:error("Cannot read battery: not connected")
    return
  end

  -- Send GATT read command to main driver
  SendToProxy(ESPHOME_BINDING, "GATT_READ", {
    handle = tostring(RX_HANDLE),
  }, "NOTIFY")
end

-- RELAY proxy command handlers
function RFP.ON(idBinding, strCommand)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  turnOn()
end

function RFP.OFF(idBinding, strCommand)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  turnOff()
end

function RFP.CLOSE(idBinding, strCommand)
  log:trace("RFP.CLOSE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  turnOn()
end

function RFP.OPEN(idBinding, strCommand)
  log:trace("RFP.OPEN(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  turnOff()
end

function RFP.TOGGLE(idBinding, strCommand)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end

  if CURRENT_STATE then
    turnOff()
  else
    turnOn()
  end
end

--- Handle connection notification from main driver
function RFP.CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local macAddress = Select(tParams, "mac_address")
  local deviceType = Select(tParams, "device_type")
  SERVICES = Deserialize(Select(tParams, "services"))

  log:info("Connected to %s device: %s", deviceType, macAddress)

  if SERVICES then
    -- Find TX and RX handles from services
    TX_HANDLE = findCharacteristicHandle(SERVICES,
      SWITCHBOT_SERVICE_UUID_HIGH, SWITCHBOT_SERVICE_UUID_LOW,
      SWITCHBOT_TX_UUID_HIGH, SWITCHBOT_TX_UUID_LOW)
    RX_HANDLE = findCharacteristicHandle(SERVICES,
      SWITCHBOT_SERVICE_UUID_HIGH, SWITCHBOT_SERVICE_UUID_LOW,
      SWITCHBOT_RX_UUID_HIGH, SWITCHBOT_RX_UUID_LOW)

    if TX_HANDLE and RX_HANDLE then
      CONNECTED = true
      log:info("Found Switchbot characteristics - TX: %s, RX: %s", TX_HANDLE, RX_HANDLE)
      UpdateProperty("Driver Status", "Connected")
      SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")

      -- Read initial battery level
      SetTimer("ReadBattery", 1000, readBattery)

      -- Set up periodic battery reads (every 5 minutes)
      SetTimer("PeriodicBattery", 5 * ONE_MINUTE, readBattery, true)
    else
      log:error("Could not find Switchbot characteristics (TX: %s, RX: %s)", TX_HANDLE, RX_HANDLE)
      CONNECTED = false
      UpdateProperty("Driver Status", "Error: Missing characteristics")
    end
  else
    log:error("No services provided in CONNECTED message")
    CONNECTED = false
  end
end

--- Handle GATT write response from main driver
function RFP.GATT_WRITE_RESPONSE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_WRITE_RESPONSE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local success = Select(tParams, "success") == "true"
  local error = Select(tParams, "error")

  if success then
    log:debug("Write command successful")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")
  else
    log:error("Write command failed: error=%s", error)
  end
end

--- Handle GATT read response from main driver
function RFP.GATT_READ_RESPONSE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_READ_RESPONSE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local data = Deserialize(Select(tParams, "data"))
  local error = Select(tParams, "error")

  if error and error ~= "0" then
    log:error("Read command failed: error=%s", error)
    return
  end

  if data and #data >= 2 then
    -- Battery is at byte index 2 (1-based Lua indexing)
    local batteryByte = string.byte(data, 2)
    if batteryByte then
      local batteryLevel = batteryByte
      log:info("Battery level: %d%%", batteryLevel)
      UpdateProperty("Battery Level", string.format("%d%%", batteryLevel))
    end
  else
    log:warn("Invalid data length in read response: %d bytes", data and #data or 0)
  end
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, reset state
  CONNECTED = false
  TX_HANDLE = nil
  RX_HANDLE = nil
  SERVICES = nil
  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "false" }, "NOTIFY")
end
