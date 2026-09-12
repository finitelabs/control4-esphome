--- ESPHome Homedics SereneScent BLE Diffuser Driver
--- Active GATT device. Requires one ESP32 connection slot.
--- Protocol reverse-engineered from:
---   https://github.com/john-k-mcdowell/Homedics-SereneScent
--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_serenescent.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

local log = require("lib.logging")
local constants = require("constants")
local bindings = require("lib.bindings")
local values = require("lib.values")
local persist = require("lib.persist")
local UUID = require("esphome.ble.uuid")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Binding IDs
local ESPHOME_BINDING = 5002 -- ESPHome BLE connection binding

--- Dynamic bindings namespace
local BINDINGS_NAMESPACE = "SereneScent"

--- Capability group definitions: maps capability name to binding definitions
local CAPABILITY_BINDINGS = {
  power = {
    { key = "on", class = "BUTTON_LINK", name = "On Button Link" },
    { key = "off", class = "BUTTON_LINK", name = "Off Button Link" },
    { key = "toggle", class = "BUTTON_LINK", name = "Toggle Button Link" },
    { key = "relay", class = "RELAY", name = "Power Relay" },
  },
  intensity = {
    { key = "intensity_up", class = "BUTTON_LINK", name = "Intensity Up Button Link" },
    { key = "intensity_down", class = "BUTTON_LINK", name = "Intensity Down Button Link" },
    { key = "set_low", class = "BUTTON_LINK", name = "Set Low Intensity Button Link" },
    { key = "set_medium", class = "BUTTON_LINK", name = "Set Medium Intensity Button Link" },
    { key = "set_high", class = "BUTTON_LINK", name = "Set High Intensity Button Link" },
  },
}

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

--- Last BLE advertisement timestamp (for throttling RSSI updates)
local lastAdvTime = 0

--- Pending command to send once connected ("power_on","power_off","intensity","color","status")
local pendingCommand = nil
local pendingParam = nil -- "low"/"medium"/"high" or color name

--- Current device state (for variables and toggle logic)
local state = {
  power = false,
  intensity = "low",
  color = "white",
}

--- Ordered intensity levels for cycling
local INTENSITY_CYCLE = { "low", "medium", "high" }

--- Whether capability detection is in progress
local detectingCapabilities = false

--- Whether we powered on the device during detection (to restore state after)
local detectionPoweredOn = false

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
  local caps = persist:get("detectedCapabilities")
  local intensityDisplay = (not caps and "Undetected")
    or (not caps.intensity and "N/A")
    or (not state.power and "Off")
    or state.intensity
  local colorDisplay = (not caps and "Undetected")
    or (not caps.color and "N/A")
    or (not state.power and "Off")
    or state.color

  local savedState = persist:get("deviceState")
  local powerDisplay = savedState and (state.power and "On" or "Off") or "N/A"

  UpdateProperty("Power", powerDisplay)
  UpdateProperty("Intensity", intensityDisplay)
  UpdateProperty("Color", colorDisplay)
  values:update("Power", powerDisplay, "STRING")
  values:update("Intensity", intensityDisplay, "STRING")
  values:update("Color", colorDisplay, "STRING")
  persist:set("deviceState", state)

  -- Update relay proxy state (dynamic binding)
  local relayBinding = bindings:getDynamicBinding(BINDINGS_NAMESPACE, "relay")
  if relayBinding then
    SendToProxy(relayBinding.bindingId, state.power and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
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

  -- Handle capability detection flow
  if detectingCapabilities then
    if not state.power then
      -- Device is off; power it on to get valid capability readings
      if not detectionPoweredOn then
        log:info("Device is off during detection - powering on to read capabilities")
        detectionPoweredOn = true
        -- Reset disconnect timer to allow time for power-on + re-query
        CancelTimer("Disconnect")
        SetTimer("Disconnect", DISCONNECT_DELAY_MS, function()
          log:debug("Disconnect timer fired (detection)")
          requestDisconnect()
        end)
        gattWrite(CMD_POWER_ON)
        SetTimer("StatusPoll", STATUS_POLL_DELAY_MS, function()
          gattWrite(CMD_STATUS_HOME)
        end)
        return
      end
    end

    -- We have a valid status response with the device on - infer capabilities
    local caps = { power = true }
    if INTENSITY_MAP[intensityVal] then
      caps.intensity = true
    end
    if COLOR_MAP[colorVal] ~= nil then
      caps.color = true
    end

    persist:set("detectedCapabilities", caps)

    local capsStr = "Power"
    if caps.intensity then
      capsStr = capsStr .. ", Intensity"
    end
    if caps.color then
      capsStr = capsStr .. ", Color"
    end
    UpdateProperty("Detected Capabilities", capsStr)
    log:info("Detected capabilities: %s", capsStr)

    -- Create dynamic bindings for discovered capabilities
    createBindingsForCapabilities(caps)

    -- Restore power state if we turned it on for detection
    if detectionPoweredOn then
      log:info("Restoring power off after capability detection")
      gattWrite(CMD_POWER_OFF)
      state.power = false
    end

    detectingCapabilities = false
    detectionPoweredOn = false
  end

  updateLastSeen()
  pushState()
end

--------------------------------------------------------------------------------
-- Dynamic Bindings & Capability Management
--------------------------------------------------------------------------------

--- Button action map: binding key -> function to execute
local BUTTON_ACTIONS = {
  on = function()
    initiateCommand("power_on")
  end,
  off = function()
    initiateCommand("power_off")
  end,
  toggle = function()
    initiateCommand(state.power and "power_off" or "power_on")
  end,
  intensity_up = function()
    for i, v in ipairs(INTENSITY_CYCLE) do
      if v == state.intensity then
        initiateCommand("intensity", INTENSITY_CYCLE[(i % #INTENSITY_CYCLE) + 1])
        return
      end
    end
    initiateCommand("intensity", "medium")
  end,
  intensity_down = function()
    for i, v in ipairs(INTENSITY_CYCLE) do
      if v == state.intensity then
        initiateCommand("intensity", INTENSITY_CYCLE[((i - 2) % #INTENSITY_CYCLE) + 1])
        return
      end
    end
    initiateCommand("intensity", "medium")
  end,
  set_low = function()
    initiateCommand("intensity", "low")
  end,
  set_medium = function()
    initiateCommand("intensity", "medium")
  end,
  set_high = function()
    initiateCommand("intensity", "high")
  end,
}

--- Register RFP/OBC handlers for a single dynamic binding
--- @param binding Binding The dynamic binding object
--- @param def table The binding definition ({ key, class, name })
local function registerHandlerForBinding(binding, def)
  if def.class == "BUTTON_LINK" then
    local action = BUTTON_ACTIONS[def.key]
    if action then
      RFP[binding.bindingId] = function(idBinding, strCommand, tParams, args)
        if strCommand == "DO_CLICK" or strCommand == "DO_PUSH" then
          action()
        elseif strCommand == "BUTTON_ACTION" then
          local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
          local buttonAction = tointeger(Select(tParams, "ACTION"))
          if buttonAction ~= constants.ButtonActions.PRESS then
            return
          end
          if buttonId == constants.ButtonIds.TOP then
            initiateCommand("power_on")
          elseif buttonId == constants.ButtonIds.BOTTOM then
            initiateCommand("power_off")
          elseif buttonId == constants.ButtonIds.TOGGLE then
            initiateCommand(state.power and "power_off" or "power_on")
          end
        end
      end
    end
  elseif def.class == "RELAY" then
    OBC[binding.bindingId] = function(idBinding, strClass, bIsBound, otherDeviceId)
      log:trace("OBC[relay](%s, %s, %s, %s)", idBinding, strClass, bIsBound, otherDeviceId)
      if bIsBound then
        SendToProxy(binding.bindingId, state.power and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
  end
end

--- Create or remove dynamic bindings based on detected capabilities.
--- @param caps table Capabilities table: { power = bool, intensity = bool, color = bool }
function createBindingsForCapabilities(caps)
  log:info("Creating bindings for capabilities")

  for capName, bindingDefs in pairs(CAPABILITY_BINDINGS) do
    if caps[capName] then
      -- Create bindings for this capability
      for _, def in ipairs(bindingDefs) do
        local binding =
          bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, def.key, "CONTROL", true, def.name, def.class)
        if binding then
          registerHandlerForBinding(binding, def)
        end
      end
    else
      -- Remove bindings for this capability
      for _, def in ipairs(bindingDefs) do
        bindings:deleteBinding(BINDINGS_NAMESPACE, def.key)
      end
    end
  end
end

--- Helper to check if a binding ID matches the dynamic relay binding
--- @param idBinding integer The binding ID to check
--- @return boolean
local function isRelayBinding(idBinding)
  local relayBinding = bindings:getDynamicBinding(BINDINGS_NAMESPACE, "relay")
  return relayBinding ~= nil and relayBinding.bindingId == idBinding
end

--------------------------------------------------------------------------------
-- Dynamic Command Parameter Lists
--------------------------------------------------------------------------------

--- Provides dynamic parameter lists for Set Intensity and Set Color commands.
--- Returns empty list when capability is not detected (effectively disabling the command).
function GetCommandParamList(commandName, paramName)
  local caps = persist:get("detectedCapabilities", {})
  if commandName == "Set Intensity" and paramName == "Level" then
    if caps.intensity then
      return { "low", "medium", "high" }
    end
    return {}
  elseif commandName == "Set Color" and paramName == "Color" then
    if caps.color then
      return { "off", "rotating", "white", "red", "blue", "violet", "green", "orange" }
    end
    return {}
  end
  return {}
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore persisted state and dynamic bindings
  values:restoreValues()
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Restore persisted device state across reboots
  local savedState = persist:get("deviceState")
  if savedState then
    state.power = savedState.power or false
    state.intensity = savedState.intensity or "low"
    state.color = savedState.color or "white"
  end
  pushState()

  -- Always create power bindings; restore intensity bindings if previously detected
  local caps = persist:get("detectedCapabilities", { power = true })
  createBindingsForCapabilities(caps)

  -- Restore Detected Capabilities property display
  local capsStr = "Power"
  if caps.intensity then
    capsStr = capsStr .. ", Intensity"
  end
  if caps.color then
    capsStr = capsStr .. ", Color"
  end
  if persist:get("detectedCapabilities") then
    UpdateProperty("Detected Capabilities", capsStr)
  end

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for '%s': %s", p, err or "unknown")
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Disconnected")

  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
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
-- RFP Handlers - Control Bindings (relay commands use dynamic lookup)
-- NOTE: Button link handlers (DO_CLICK, BUTTON_ACTION) are registered
-- dynamically per-binding in registerHandlerForBinding().
--------------------------------------------------------------------------------

function RFP.CLOSE(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.CLOSE(%s, %s)", idBinding, strCommand)
  if isRelayBinding(idBinding) then
    initiateCommand("power_on")
  end
end

function RFP.OPEN(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.OPEN(%s, %s)", idBinding, strCommand)
  if isRelayBinding(idBinding) then
    initiateCommand("power_off")
  end
end

function RFP.TOGGLE(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if isRelayBinding(idBinding) then
    initiateCommand(state.power and "power_off" or "power_on")
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
  local caps = persist:get("detectedCapabilities", {})
  if not caps.intensity then
    log:warn("Intensity control not supported by this device. Run 'Detect Capabilities' action.")
    return
  end
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
  local caps = persist:get("detectedCapabilities", {})
  if not caps.color then
    log:warn("Color control not supported by this device. Run 'Detect Capabilities' action.")
    return
  end
  local color = Select(params, "Color") or ""
  color = color:lower()
  log:info("EC.Set_Color(%s)", color)
  if CMD_COLOR[color] then
    initiateCommand("color", color)
  else
    log:warn("Invalid color: %s", color)
  end
end

function EC.Detect_Capabilities()
  log:info("EC.Detect_Capabilities()")
  detectingCapabilities = true
  detectionPoweredOn = false
  initiateCommand("status")
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

  bindings:reset()
  values:reset()
  persist:set("deviceState", nil)
  persist:set("detectedCapabilities", nil)
  isConnected = false
  txHandle = nil
  rxHandle = nil
  pendingCommand = nil
  pendingParam = nil
  detectingCapabilities = false
  detectionPoweredOn = false
  state = { power = false, intensity = "low", color = "white" }

  CancelTimer("StatusPoll")
  CancelTimer("Disconnect")
  CancelTimer("PollCycle")

  UpdateProperty("Driver Status", "Disconnected")
  UpdateProperty("Detected Capabilities", "Not detected")
  UpdateProperty("Power", "Off")
  UpdateProperty("Intensity", "low")
  UpdateProperty("Color", "white")

  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end
