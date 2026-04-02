--- ESPHome Homedics SereneScent BLE Diffuser Driver
--- Active GATT device. Requires one ESP32 connection slot.
--- Protocol reverse-engineered from:
---   https://github.com/john-k-mcdowell/Homedics-SereneScent

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local UUID = require("esphome.ble.uuid")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Binding IDs
local PROXY_BINDING = 5001 -- custom proxy (no built-in C4 proxy needed)
local ESPHOME_BINDING = 5002 -- ESPHome BLE connection binding

--- GATT UUIDs (from const.py)
local SERVICE_UUID = "53527aa4-29f7-ae11-4e74-997334782568"
local CHAR_TX_UUID = "ee684b1a-1e9b-ed3e-ee55-f894667e92ac" -- write TO device
local CHAR_RX_UUID = "654b749c-e37f-ae1f-ebab-40ca133e3690" -- notify FROM device

--- Protocol framing
local CMD_HEADER = string.char(0xFF, 0xFA)
local RESP_HEADER = string.char(0xFF, 0xFB)

--- Power commands
local CMD_POWER_ON = string.char(0xFF, 0xFA, 0x10, 0x04)
local CMD_POWER_OFF = string.char(0xFF, 0xFA, 0x11, 0x04)

--- Intensity commands
local CMD_INTENSITY = {
  low = string.char(0xFF, 0xFA, 0x17, 0x08, 0x00, 0x0A, 0x00, 0xF0),
  medium = string.char(0xFF, 0xFA, 0x17, 0x08, 0x00, 0x14, 0x00, 0x82),
  high = string.char(0xFF, 0xFA, 0x17, 0x08, 0x00, 0x1E, 0x00, 0x3C),
}

--- Color commands
local CMD_COLOR = {
  off = string.char(0xFF, 0xFA, 0x16, 0x05, 0x00),
  rotating = string.char(0xFF, 0xFA, 0x16, 0x05, 0x01),
  white = string.char(0xFF, 0xFA, 0x16, 0x05, 0x02),
  red = string.char(0xFF, 0xFA, 0x16, 0x05, 0x03),
  blue = string.char(0xFF, 0xFA, 0x16, 0x05, 0x04),
  violet = string.char(0xFF, 0xFA, 0x16, 0x05, 0x05),
  green = string.char(0xFF, 0xFA, 0x16, 0x05, 0x06),
  orange = string.char(0xFF, 0xFA, 0x16, 0x05, 0x07),
}

--- Status query commands
local CMD_STATUS_HOME = string.char(0xFF, 0xFA, 0x40, 0x05, 0x00)
local CMD_MODE_HOME = string.char(0xFF, 0xFA, 0x43, 0x05, 0x00)

--- Status response byte positions (16-byte response, 0-indexed from byte 1 in Lua)
local STATUS_BYTE_INTENSITY = 9 -- byte index 9 (0-indexed: 8) -> 10=low, 20=med, 30=high
local STATUS_BYTE_COLOR = 13 -- byte index 13 (0-indexed: 12) -> 0-7
local STATUS_BYTE_POWER = 15 -- byte index 15 (0-indexed: 14) -> 0=off, 1=on

--- Intensity byte value -> name
local INTENSITY_MAP = { [10] = "low", [20] = "medium", [30] = "high" }

--- Color byte value -> name
local COLOR_MAP = {
  [0] = "off",
  [1] = "rotating",
  [2] = "white",
  [3] = "red",
  [4] = "blue",
  [5] = "violet",
  [6] = "green",
  [7] = "orange",
}

--- Post-command delay before status poll (ms)
local STATUS_POLL_DELAY_MS = 800

--- Disconnect delay after command completion (ms)
local DISCONNECT_DELAY_MS = 3000

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- GATT handle cache
local txHandle = nil
local rxHandle = nil

--- Connection state
local isConnected = false

--- Pending command to send once connected ("power_on","power_off","intensity","color","status")
local pendingCommand = nil
local pendingParam = nil -- "low"/"medium"/"high" or color name

--- Current device state (for variables and toggle logic)
local state = {
  power = false,
  intensity = "low",
  color = "white",
}

--- Forward declaration (defined after schedulePoll)
local initiateCommand

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local findCharacteristicHandle = UUID.findCharacteristicHandle

local function updateLastSeen()
  values:update("Last Seen", tostring(os.date("%Y-%m-%d %H:%M:%S")), "STRING")
end

local function updateRSSI(rssi)
  local n = tonumber(rssi) or -999
  if n > -999 then
    values:update("RSSI", n, "NUMBER", nil, " dBm")
  end
end

--- Push current state into driver variables and properties
local function pushState()
  UpdateProperty("Power", state.power and "On" or "Off")
  UpdateProperty("Intensity", state.intensity)
  UpdateProperty("Color", state.color)
  values:update("Power", state.power and "On" or "Off", "STRING")
  values:update("Intensity", state.intensity, "STRING")
  values:update("Color", state.color, "STRING")
end

--- Send a raw binary command via GATT write
local function gattWrite(data)
  if not txHandle then
    log:warn("gattWrite: TX handle not available")
    return
  end
  log:debug("GATT write: %d bytes to handle %d", #data, txHandle)
  SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
    handle = tostring(txHandle),
    data = C4:Base64Encode(data),
    response = "false", -- write without response (matches HA integration)
  }, "NOTIFY")
end

--- Request GATT connection
local function requestConnection()
  log:trace("requestConnection()")
  SendToProxy(ESPHOME_BINDING, "CONNECT", {}, "NOTIFY")
end

--- Request GATT disconnection
local function requestDisconnect()
  log:trace("requestDisconnect()")
  isConnected = false
  txHandle = nil
  rxHandle = nil
  SendToProxy(ESPHOME_BINDING, "DISCONNECT", {}, "NOTIFY")
end

--- Subscribe to GATT notifications on the RX characteristic
local function subscribeNotifications()
  if not rxHandle then
    log:warn("subscribeNotifications: RX handle not available")
    return
  end
  log:debug("Subscribing to GATT notifications on handle %d", rxHandle)
  SendToProxy(ESPHOME_BINDING, "GATT_NOTIFY", {
    handle = tostring(rxHandle),
    enable = "true",
  }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Polling
--------------------------------------------------------------------------------

--- Schedule next poll cycle.
--- Sets a one-shot timer that connects, queries status, then disconnects.
local function schedulePoll()
  local interval = tointeger(Properties["Polling Interval"]) or 5
  log:info("Scheduling next poll in %d minutes", interval)
  UpdateProperty("Driver Status", string.format("Listening (next poll in %dm)", interval))
  CancelTimer("PollCycle")
  SetTimer("PollCycle", interval * 60 * 1000, function()
    log:info("Poll timer fired - querying status")
    initiateCommand("status")
  end)
end

--------------------------------------------------------------------------------
-- Command Execution
--------------------------------------------------------------------------------

--- Execute the pending command (called once connected and subscribed)
local function executePendingCommand()
  log:trace("executePendingCommand() cmd=%s param=%s", pendingCommand or "nil", pendingParam or "nil")

  if not isConnected then
    log:debug("Not connected - will execute after connection")
    return
  end

  local cmd = pendingCommand
  local param = pendingParam
  pendingCommand = nil
  pendingParam = nil

  if cmd == "power_on" then
    log:info("Sending POWER ON")
    gattWrite(CMD_POWER_ON)
    state.power = true
    pushState()
    SetTimer("StatusPoll", STATUS_POLL_DELAY_MS, function()
      gattWrite(CMD_STATUS_HOME)
    end)
  elseif cmd == "power_off" then
    log:info("Sending POWER OFF")
    gattWrite(CMD_POWER_OFF)
    state.power = false
    pushState()
    SetTimer("StatusPoll", STATUS_POLL_DELAY_MS, function()
      gattWrite(CMD_STATUS_HOME)
    end)
  elseif cmd == "intensity" and param then
    local intensityCmd = CMD_INTENSITY[param]
    if not intensityCmd then
      log:warn("Unknown intensity: %s", param)
      return
    end
    log:info("Sending INTENSITY %s", param)
    gattWrite(intensityCmd)
    state.intensity = param
    pushState()
    SetTimer("StatusPoll", STATUS_POLL_DELAY_MS, function()
      gattWrite(CMD_STATUS_HOME)
    end)
  elseif cmd == "color" and param then
    local colorCmd = CMD_COLOR[param]
    if not colorCmd then
      log:warn("Unknown color: %s", param)
      return
    end
    log:info("Sending COLOR %s", param)
    gattWrite(colorCmd)
    state.color = param
    pushState()
    SetTimer("StatusPoll", STATUS_POLL_DELAY_MS, function()
      gattWrite(CMD_STATUS_HOME)
    end)
  elseif cmd == "status" then
    log:info("Sending STATUS query")
    gattWrite(CMD_STATUS_HOME)
  else
    log:debug("No pending command to execute")
    return
  end

  -- Disconnect after a short delay once the command + status poll are done
  SetTimer("Disconnect", DISCONNECT_DELAY_MS, function()
    log:debug("Disconnect timer fired")
    requestDisconnect()
  end)
end

--- Initiate a command: connect if needed, then execute
initiateCommand = function(cmd, param)
  log:info("Initiating command: %s %s", cmd, param or "")
  CancelTimer("Disconnect")
  CancelTimer("StatusPoll")
  CancelTimer("PollCycle")
  pendingCommand = cmd
  pendingParam = param

  if isConnected then
    executePendingCommand()
  else
    requestConnection()
  end
end

--------------------------------------------------------------------------------
-- Status Response Parser
--------------------------------------------------------------------------------

--- Parse the 16-byte status response from the device.
--- Response format: FF FB 40 ... (see STATUS_BYTE_* constants)
--- @param data string Raw binary response bytes
local function parseStatusResponse(data)
  if #data < 16 then
    log:debug("Status response too short: %d bytes", #data)
    return
  end

  -- Validate header: FF FB and command echo 0x40
  if string.byte(data, 1) ~= 0xFF or string.byte(data, 2) ~= 0xFB or string.byte(data, 3) ~= 0x40 then
    log:debug("Not a status response: %02X %02X %02X", string.byte(data, 1), string.byte(data, 2), string.byte(data, 3))
    return
  end

  local intensityVal = string.byte(data, STATUS_BYTE_INTENSITY)
  local colorVal = string.byte(data, STATUS_BYTE_COLOR)
  local powerVal = string.byte(data, STATUS_BYTE_POWER)

  state.power = powerVal == 1
  state.intensity = INTENSITY_MAP[intensityVal] or "low"
  state.color = COLOR_MAP[colorVal] or "white"

  log:info("Status: power=%s intensity=%s color=%s", tostring(state.power), state.intensity, state.color)

  updateLastSeen()
  pushState()
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
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

  values:restoreValues()

  for p, _ in pairs(Properties) do
    local ok, err = pcall(OnPropertyChanged, p)
    if not ok and err then
      log:error("Error in OnPropertyChanged for '%s': %s", p, err or "unknown")
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Disconnected")
end

--------------------------------------------------------------------------------
-- Property Changed Handlers
--------------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version()
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
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
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
  end
end

function OPC.Polling_Interval(propertyValue)
  log:trace("OPC.Polling_Interval('%s')", propertyValue)
  if not gInitialized then
    return
  end
  -- Reschedule poll timer if currently idle (not connected)
  if not isConnected then
    schedulePoll()
  end
end

--------------------------------------------------------------------------------
-- RFP Handlers - BLE Connection (binding 5002)
--------------------------------------------------------------------------------

--- Called when the GATT connection is established and services are discovered
function RFP.CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED(%s)", idBinding)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local name = Select(tParams, "name")
  local mac = Select(tParams, "mac")
  local services = DeserializeSafe(Select(tParams, "services"))

  log:info("Connected to SereneScent: %s", mac or "unknown")

  if not IsEmpty(name) then
    values:update("Device Name", name, "STRING")
  end
  if mac then
    values:update("MAC Address", mac, "STRING")
    UpdateProperty("MAC Address", mac)
  end

  -- Find GATT characteristic handles from service discovery
  if services then
    txHandle = findCharacteristicHandle(services, SERVICE_UUID, CHAR_TX_UUID)
    rxHandle = findCharacteristicHandle(services, SERVICE_UUID, CHAR_RX_UUID)

    if txHandle and rxHandle then
      log:info("Found SereneScent handles: TX=%d, RX=%d", txHandle, rxHandle)
      isConnected = true
      UpdateProperty("Driver Status", "Connected")
      -- Subscribe to notifications, then execute any pending command
      subscribeNotifications()
    else
      log:error(
        "Could not find SereneScent GATT characteristics (TX=%s, RX=%s)",
        tostring(txHandle),
        tostring(rxHandle)
      )
      UpdateProperty("Driver Status", "Error: Missing characteristics")
      requestDisconnect()
    end
  else
    log:error("No services in CONNECTED message")
    UpdateProperty("Driver Status", "Error: Missing services")
    requestDisconnect()
  end
end

--- Handle incoming BLE advertisement (device presence detection)
function RFP.BLE_ADVERTISEMENT(idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local driverStatus = Properties["Driver Status"]
  if driverStatus == "Disconnected" then
    UpdateProperty("Driver Status", "Listening")
    -- Start the poll cycle on first advertisement
    schedulePoll()
  end

  -- Throttle RSSI / Last Seen updates to once per 30s
  local now = os.time()
  if (now - (lastAdvTime or 0)) < 30 then
    return
  end
  lastAdvTime = now

  local advStr = Select(tParams, "advertisement")
  if not advStr or advStr == "" then
    return
  end

  local advertisement = DeserializeSafe(advStr)
  if not advertisement then
    return
  end

  if advertisement.rssi then
    updateRSSI(advertisement.rssi)
  end
  updateLastSeen()
end

--- Handle GATT disconnection
function RFP.DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.DISCONNECTED(%s)", idBinding)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local reason = Select(tParams, "reason") or "unknown"
  log:info("Disconnected: %s", reason)

  isConnected = false
  txHandle = nil
  rxHandle = nil

  CancelTimer("StatusPoll")
  CancelTimer("Disconnect")

  -- Schedule next poll cycle
  schedulePoll()
end

--- Handle connection failure
function RFP.CONNECTION_FAILED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTION_FAILED(%s)", idBinding)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local errMsg = Select(tParams, "error") or "unknown"
  log:error("Connection failed: %s", errMsg)

  isConnected = false
  txHandle = nil
  rxHandle = nil

  UpdateProperty("Driver Status", "Connection failed: " .. errMsg)

  -- Schedule next poll cycle despite the failure
  schedulePoll()
end

--- Handle GATT notification subscription confirmed
function RFP.GATT_NOTIFY_SUBSCRIBED(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_SUBSCRIBED(%s)", idBinding)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local handle = tointeger(Select(tParams, "handle"))
  local success = Select(tParams, "success") == "true"

  if not success then
    log:error("GATT notification subscription failed on handle %s", handle)
    return
  end

  if handle == rxHandle then
    log:info("RX notifications subscribed - ready for commands")
    executePendingCommand()
  end
end

--- Handle incoming GATT notification (status response from device)
function RFP.GATT_NOTIFY_DATA(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_DATA(%s)", idBinding)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local data = Select(tParams, "data")
  if not data then
    log:debug("GATT_NOTIFY_DATA: no data")
    return
  end

  local binaryData = C4:Base64Decode(data)
  if not binaryData or #binaryData == 0 then
    log:debug("GATT_NOTIFY_DATA: empty after decode")
    return
  end

  -- Ignore all-FF or all-zero filler packets (matches HA integration)
  local allSame = true
  local firstByte = string.byte(binaryData, 1)
  if firstByte == 0xFF or firstByte == 0x00 then
    for i = 2, #binaryData do
      if string.byte(binaryData, i) ~= firstByte then
        allSame = false
        break
      end
    end
    if allSame then
      log:debug("GATT_NOTIFY_DATA: filler packet, ignoring")
      return
    end
  end

  log:debug("GATT_NOTIFY_DATA: %d bytes: %s", #binaryData, C4:Encode(binaryData, "HEX"))
  parseStatusResponse(binaryData)
end

--- Handle GATT write response
function RFP.GATT_WRITE_RESPONSE(idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  local success = Select(tParams, "success") == "true"
  if not success then
    log:warn("GATT write failed: %s", Select(tParams, "error") or "unknown")
  end
end

--------------------------------------------------------------------------------
-- OBC Handler - ESPHome binding changed
--------------------------------------------------------------------------------

OBC[ESPHOME_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId)
  log:trace("OBC[%s](%s, %s, %s)", ESPHOME_BINDING, idBinding, bIsBound, otherDeviceId)
  isConnected = false
  txHandle = nil
  rxHandle = nil
  CancelTimer("PollCycle")

  if bIsBound then
    UpdateProperty("Driver Status", "Waiting for data")
  else
    UpdateProperty("Driver Status", "Disconnected")
  end
end

--------------------------------------------------------------------------------
-- EC Handlers (Programming Actions)
--------------------------------------------------------------------------------

function EC.Power_On()
  log:info("EC.Power_On()")
  initiateCommand("power_on")
end

function EC.Power_Off()
  log:info("EC.Power_Off()")
  initiateCommand("power_off")
end

function EC.Toggle_Power()
  log:info("EC.Toggle_Power()")
  initiateCommand(state.power and "power_off" or "power_on")
end

function EC.Set_Intensity(params)
  local level = Select(params, "Level") or ""
  level = level:lower()
  log:info("EC.Set_Intensity(%s)", level)
  if CMD_INTENSITY[level] then
    initiateCommand("intensity", level)
  else
    log:warn("Invalid intensity level: %s", level)
  end
end

function EC.Set_Color(params)
  local color = Select(params, "Color") or ""
  color = color:lower()
  log:info("EC.Set_Color(%s)", color)
  if CMD_COLOR[color] then
    initiateCommand("color", color)
  else
    log:warn("Invalid color: %s", color)
  end
end

function EC.Request_Status()
  log:info("EC.Request_Status()")
  initiateCommand("status")
end

function EC.Set_Polling_Interval(params)
  local interval = tointeger(Select(params, "Interval"))
  log:info("Polling interval change requested via programming: %s", interval)
  if interval then
    UpdateProperty("Polling Interval", tostring(interval), true)
  end
end

function EC.Reset_Driver(params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting SereneScent driver")

  values:reset()
  isConnected = false
  txHandle = nil
  rxHandle = nil
  pendingCommand = nil
  pendingParam = nil
  state = { power = false, intensity = "low", color = "white" }

  CancelTimer("StatusPoll")
  CancelTimer("Disconnect")
  CancelTimer("PollCycle")

  UpdateProperty("Driver Status", "Disconnected")
  UpdateProperty("Power", "Off")
  UpdateProperty("Intensity", "low")
  UpdateProperty("Color", "white")
end
