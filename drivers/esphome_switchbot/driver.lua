--- ESPHome SwitchBot Driver
--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_switchbot.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local events = require("lib.events")
local persist = require("lib.persist")
local constants = require("constants")
local UUID = require("esphome.ble.uuid")
local SwitchBot = require("esphome.ble.parsers.switchbot")
local http = require("lib.http")

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

--- Binding IDs
local ESPHOME_BINDING = 5001

--- Namespaces for dynamic bindings
local BINDINGS_NAMESPACE = "SwitchBot"

--- Event namespace for SwitchBot events
local EVENT_NAMESPACE = "SwitchBot"

--- SwitchBot BLE UUIDs
--- See: https://github.com/OpenWonderLabs/SwitchBotAPI-BLE/blob/latest/devicetypes/bot.md
--- @enum SwitchBotUUID
local SWITCHBOT_UUID = {
  -- Communication Service (all SwitchBot devices)
  SERVICE = "CBA20D00-224D-11E6-9FB8-0002A5D5C51B",
  -- TX Characteristic - Write commands to device
  TX = "CBA20002-224D-11E6-9FB8-0002A5D5C51B",
  -- RX Characteristic - Read status / receive notifications from device
  RX = "CBA20003-224D-11E6-9FB8-0002A5D5C51B",
}

--- Device category constants
--- @enum DeviceCategory
local DEVICE_CATEGORY = {
  BOT = "bot",
  SWITCH = "switch", -- Plug Mini, Relay switches
  SENSOR = "sensor", -- Meters, Motion, Contact, Leak
}

--- Switch type constants (for SWITCH category devices)
--- @enum SwitchType
local SWITCH_TYPE = {
  PLUG = "plug",
  RELAY = "relay",
  RELAY_1PM = "relay_1pm",
  RELAY_2PM = "relay_2pm",
}

--- Contact sensor type constants
--- @enum ContactType
local CONTACT_TYPE = {
  MOTION = "motion",
  CONTACT = "contact",
  LEAK = "leak",
  TAMPER = "tamper",
}

--- Sensor type constants (for temperature/humidity bindings)
--- @enum SwitchBotSensorType
local SENSOR_TYPE = {
  TEMPERATURE = "temperature",
  HUMIDITY = "humidity",
}

--- Devices requiring encryption
--- @type table<string, boolean?>
local ENCRYPTED_DEVICES = {
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1]] = true,
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1PM]] = true,
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_2PM]] = true,
}

--- Dual channel devices
--- @type table<string, boolean?>
local DUAL_CHANNEL_DEVICES = {
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_2PM]] = true,
}

--- SwitchBot Bot command bytes (for Bot devices)
--- @enum SwitchBotCommand
local SWITCHBOT_CMD = {
  HEADER = 0x57,
  CMD_ACTION = 0x01,
  GET_BASIC_SETTING = 0x02,
  SET_MODE = 0x03,
  ACTION_PRESS = 0x00,
  ACTION_ON = 0x01,
  ACTION_OFF = 0x02,
  ACTION_PUSH_STOP = 0x03,
  ACTION_BACK = 0x04,
}

-- Pre-built Bot commands
local CMD_BOT_PRESS = string.char(SWITCHBOT_CMD.HEADER, SWITCHBOT_CMD.CMD_ACTION, SWITCHBOT_CMD.ACTION_PRESS)
local CMD_BOT_ON = string.char(SWITCHBOT_CMD.HEADER, SWITCHBOT_CMD.CMD_ACTION, SWITCHBOT_CMD.ACTION_ON)
local CMD_BOT_OFF = string.char(SWITCHBOT_CMD.HEADER, SWITCHBOT_CMD.CMD_ACTION, SWITCHBOT_CMD.ACTION_OFF)
local CMD_BOT_GET_SETTINGS = string.char(SWITCHBOT_CMD.HEADER, SWITCHBOT_CMD.GET_BASIC_SETTING)

--- IV Request command prefix (for encrypted devices)
local IV_REQUEST_PREFIX = "\x57\x00\x00\x00\x0f\x21\x03"

--- Event definitions by key
--- @type table<string, {key: string, name: string, description: string}?>
local EVENT_DEFS = {
  motion_detected = { key = "motion_detected", name = "Motion Detected", description = "NAME motion was detected" },
  motion_cleared = { key = "motion_cleared", name = "Motion Cleared", description = "NAME motion cleared" },
  contact_opened = { key = "contact_opened", name = "Contact Opened", description = "NAME contact was opened" },
  contact_closed = { key = "contact_closed", name = "Contact Closed", description = "NAME contact was closed" },
  leak_detected = { key = "leak_detected", name = "Leak Detected", description = "NAME water leak detected" },
  leak_cleared = { key = "leak_cleared", name = "Leak Cleared", description = "NAME water leak cleared" },
  tamper_detected = { key = "tamper_detected", name = "Tamper Detected", description = "NAME tamper detected" },
  tamper_cleared = { key = "tamper_cleared", name = "Tamper Cleared", description = "NAME tamper cleared" },
  button_pressed = { key = "button_pressed", name = "Button Pressed", description = "NAME button was pressed" },
  low_battery = { key = "low_battery", name = "Low Battery", description = "NAME battery is low" },
  battery_ok = { key = "battery_ok", name = "Battery OK", description = "NAME battery is ok" },
}

--- Map device types to their supported event keys
--- @type table<string, string[]?>
local DEVICE_EVENTS = {
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.MOTION]] = { "motion_detected", "motion_cleared" },
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.PRESENCE]] = { "motion_detected", "motion_cleared" },
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.CONTACT]] = { "contact_opened", "contact_closed", "button_pressed" },
  [SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.WATER_LEAK]] = {
    "leak_detected",
    "leak_cleared",
    "tamper_detected",
    "tamper_cleared",
    "low_battery",
    "battery_ok",
  },
}

--- Sensor binding configurations
--- @type table<SwitchBotSensorType, {bindingClass: string, scale: string, displayName: string}?>
local SENSOR_BINDINGS = {
  [SENSOR_TYPE.TEMPERATURE] = { bindingClass = "TEMPERATURE_VALUE", scale = "CELSIUS", displayName = "Temperature" },
  [SENSOR_TYPE.HUMIDITY] = { bindingClass = "HUMIDITY_VALUE", scale = "PERCENT", displayName = "Humidity" },
}

--- Contact sensor binding configurations
--- @type table<ContactType, {openEvent: string, closedEvent: string, displayName: string}?>
local CONTACT_BINDINGS = {
  [CONTACT_TYPE.MOTION] = { openEvent = "OPENED", closedEvent = "CLOSED", displayName = "Motion" },
  [CONTACT_TYPE.CONTACT] = { openEvent = "OPENED", closedEvent = "CLOSED", displayName = "Contact" },
  [CONTACT_TYPE.LEAK] = { openEvent = "CLOSED", closedEvent = "OPENED", displayName = "Leak" },
  [CONTACT_TYPE.TAMPER] = { openEvent = "CLOSED", closedEvent = "OPENED", displayName = "Tamper" },
}

--- SwitchBot Cloud API configuration
local SWITCHBOT_API = {
  CLIENT_ID = "5nnwmhmsa9xxskm14hd85lm9bm",
  BASE_URL = "api.switchbot.net",
  LOGIN_PATH = "/account/api/v1/user/login",
  USERINFO_PATH = "/account/api/v1/user/userinfo",
  KEYS_PATH = "/wonder/keys/v1/communicate",
}

--- Optional properties that should be hidden unless we have data
--- @type string[]
local OPTIONAL_PROPERTIES = {
  "Device Data", -- Label
  "Battery Low",
  "Battery",
  "Channel 1 Power",
  "Channel 1 State",
  "Channel 1",
  "Channel 2 Power",
  "Channel 2 State",
  "Channel 2",
  "CO2",
  "Contact",
  "Humidity",
  "Leak Detected",
  "Light Level",
  "Mode",
  "Motion",
  "Name",
  "RSSI",
  "State",
  "Tamper",
  "Temperature C",
  "Temperature F",
}

--- Bot-only properties
local BOT_PROPERTIES = {
  "Device Data", -- Label
  "Mode",
  "State",
}

--- Encryption-related properties (hidden for devices that don't need encryption)
--- @type string[]
local ENCRYPTION_PROPERTIES = {
  "Encryption Key",
  "Encryption Settings", -- Label
  "Encryption Status",
  "Key ID",
  "SwitchBot Password",
  "SwitchBot Username",
}

--- Switch channel properties
--- @type string[]
local CHANNEL_1_PROPERTIES = {
  "Device Data", -- Label
  "Channel 1 Power",
  "Channel 1 State",
  "Channel 1",
}

--- Channel 2 properties (2PM only)
--- @type string[]
local CHANNEL_2_PROPERTIES = {
  "Device Data", -- Label
  "Channel 2 Power",
  "Channel 2 State",
  "Channel 2",
}

--- Sensor properties
--- @type string[]
local SENSOR_PROPERTIES = {
  "Device Data", -- Label
  "Battery Low",
  "CO2",
  "Contact",
  "Humidity",
  "Leak Detected",
  "Light Level",
  "Motion",
  "Tamper",
  "Temperature C",
  "Temperature F",
}

--------------------------------------------------------------------------------
-- Global State
--------------------------------------------------------------------------------

-- Device identification
--- @type string?
local deviceType = nil -- Full device type string (e.g., "SwitchBot Bot")
--- @type DeviceCategory?
local deviceCategory = nil
--- @type SwitchType?
local switchType = nil
--- @type boolean
local isPassive = false -- True for sensor devices
--- @type boolean
local requiresEncryption = false
--- @type boolean
local isDualChannel = false

-- Connection state (runtime only, not persisted)
--- @type { cmd: string, channel: 1|2|nil, requiresEncryption: boolean, isOn: boolean }|nil
local pendingCommand = nil
--- @type boolean
local awaitingCommandResponse = false
--- @type boolean
local notificationsSubscribed = false
--- @type boolean
local notificationsSubscribing = false
--- @type integer
local DISCONNECT_DELAY_MS = 4000
--- @type integer
local PRESS_REVERT_DELAY_MS = 5000

-- Encryption state (runtime only)
--- @type string|nil
local encryptionIV = nil
--- @type boolean
local pendingIVRequest = false

--------------------------------------------------------------------------------
-- Property Management
--------------------------------------------------------------------------------

--- Hide all optional properties
local function hideOptionalProperties()
  log:trace("hideOptionalProperties()")
  for _, propName in ipairs(OPTIONAL_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.HIDE_PROPERTY)
  end
end

--- Hide encryption properties (for devices that don't need encryption)
local function hideEncryptionProperties()
  log:trace("hideEncryptionProperties()")
  for _, propName in ipairs(ENCRYPTION_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.HIDE_PROPERTY)
  end
end

--- Show encryption properties (for Relay switches which need encryption)
local function showEncryptionProperties()
  log:trace("showEncryptionProperties()")
  for _, propName in ipairs(ENCRYPTION_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.SHOW_PROPERTY)
  end
end

--- Hide switch properties
local function hideSwitchProperties()
  log:trace("hideSwitchProperties()")
  for _, propName in ipairs(CHANNEL_1_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.HIDE_PROPERTY)
  end
  for _, propName in ipairs(CHANNEL_2_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.HIDE_PROPERTY)
  end
end

--- Show channel 1 properties
local function showChannel1Properties()
  log:trace("showChannel1Properties()")
  for _, propName in ipairs(CHANNEL_1_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.SHOW_PROPERTY)
  end
end

--- Show channel 2 properties (for 2PM only)
local function showChannel2Properties()
  log:trace("showChannel2Properties()")
  for _, propName in ipairs(CHANNEL_2_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.SHOW_PROPERTY)
  end
end

--- Show bot properties
local function showBotProperties()
  log:trace("showBotProperties()")
  for _, propName in ipairs(BOT_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.SHOW_PROPERTY)
  end
end

--- Hide bot properties
local function hideBotProperties()
  log:trace("hideBotProperties()")
  for _, propName in ipairs(BOT_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.HIDE_PROPERTY)
  end
end

--- Show sensor properties
local function showSensorProperties()
  log:trace("showSensorProperties()")
  -- Sensor properties are dynamically shown/hidden based on data received, but we need to show the label
  C4:SetPropertyAttribs("Device Data", constants.SHOW_PROPERTY)
end

--- Hide sensor properties
local function hideSensorProperties()
  log:trace("hideSensorProperties()")
  for _, propName in ipairs(SENSOR_PROPERTIES) do
    C4:SetPropertyAttribs(propName, constants.HIDE_PROPERTY)
  end
end

--------------------------------------------------------------------------------
-- Handle Management
--------------------------------------------------------------------------------

--- Get BLE handles from persist
--- @return integer|nil txHandle TX characteristic handle
--- @return integer|nil rxHandle RX characteristic handle
local function getHandles()
  log:trace("getHandles()")
  return tointeger(persist:get("TX_HANDLE")), tointeger(persist:get("RX_HANDLE"))
end

--- Save BLE handles to persist
--- @param txHandle integer|nil TX characteristic handle
--- @param rxHandle integer|nil RX characteristic handle
local function saveHandles(txHandle, rxHandle)
  log:trace("saveHandles(%s, %s)", txHandle, rxHandle)
  persist:set("TX_HANDLE", txHandle)
  persist:set("RX_HANDLE", rxHandle)
end

--- Reset connection state
--- @param clearHandles boolean|nil If true, also clear persisted BLE handles
local function resetConnectionState(clearHandles)
  log:trace("resetConnectionState(%s)", clearHandles)
  -- Connection state
  pendingCommand = nil
  awaitingCommandResponse = false
  notificationsSubscribed = false
  notificationsSubscribing = false

  -- Encryption state
  encryptionIV = nil
  pendingIVRequest = false

  if clearHandles then
    saveHandles(nil, nil)
  end
end

--------------------------------------------------------------------------------
-- Connection Management
--------------------------------------------------------------------------------

--- Request GATT connection from parent driver
local function requestConnection()
  log:trace("requestConnection()")
  SendToProxy(ESPHOME_BINDING, "CONNECT", {}, "NOTIFY")
end

--- Actually perform the GATT disconnection
local function doDisconnect()
  log:trace("doDisconnect()")
  resetConnectionState()
  SendToProxy(ESPHOME_BINDING, "DISCONNECT", {}, "NOTIFY")
end

--- Request GATT disconnection from parent driver (debounced)
local function requestDisconnect()
  log:trace("requestDisconnect()")
  SetTimer("DisconnectDelay", DISCONNECT_DELAY_MS, doDisconnect)
end

--- Cancel any pending disconnect (called when starting a new command)
local function cancelPendingDisconnect()
  log:trace("cancelPendingDisconnect()")
  CancelTimer("DisconnectDelay")
end

--- Subscribe to GATT notifications on RX handle
local function subscribeNotifications()
  log:trace("subscribeNotifications()")
  local _, rxHandle = getHandles()
  if not rxHandle then
    log:warn("Cannot subscribe to notifications: RX handle not discovered")
    return
  end

  if notificationsSubscribed then
    log:debug("Notifications already subscribed")
    return
  end

  if notificationsSubscribing then
    log:debug("Notifications subscription already in progress")
    return
  end

  notificationsSubscribing = true
  log:debug("Subscribing to GATT notifications on handle %s", rxHandle)
  SendToProxy(ESPHOME_BINDING, "GATT_NOTIFY", {
    handle = tostring(rxHandle),
    enable = "true",
  }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Value Helpers
--------------------------------------------------------------------------------

--- Update the "Last Seen" timestamp
local function updateLastSeen()
  log:trace("updateLastSeen()")
  values:update("Last Seen", tostring(os.date("%Y-%m-%d %H:%M:%S")))
end

--- Update RSSI value
--- @param rssi string|number RSSI value
local function updateRSSI(rssi)
  log:trace("updateRSSI(%s)", rssi)
  local rssiNum = tonumber(rssi) or -999
  if rssiNum > -999 then
    values:update("RSSI", rssiNum, nil, nil, " dBm")
  end
end

--- Set battery level
--- @param level number Battery percentage
local function setBatteryLevel(level)
  log:trace("setBatteryLevel(%s)", level)
  local battery = math.max(0, math.min(tointeger(level) or 0, 100))
  values:update("Battery", battery, "NUMBER", nil, " %")
end

--- Get the current Bot state
--- @return boolean isOn True if Bot is on
local function getBotState()
  log:trace("getBotState()")
  return Select(values:getValue("State"), "value") == "On"
end

--- Check if Bot is in switch mode (vs press mode)
--- @return boolean isSwitch True if Bot is in switch mode
local function isBotSwitchMode()
  log:trace("isBotSwitchMode()")
  return Select(values:getValue("Mode"), "value") == "Switch"
end

--- Last Bot state notified this session. In-memory on purpose: a driver
--- restart clears it, so the bound consumer is re-notified.
--- @type boolean|nil
local lastNotifiedBotState = nil

--- Set the Bot state and notify bound consumers
--- @param isOn boolean Whether the Bot is on
local function setBotState(isOn)
  log:trace("setBotState(%s)", isOn)
  values:update("State", isOn and "On" or "Off", "STRING")
  -- Deduped in memory so a driver restart re-notifies the bound consumer.
  if lastNotifiedBotState ~= isOn then
    local binding = bindings:getDynamicBinding(BINDINGS_NAMESPACE, "botRelay")
    if binding then
      lastNotifiedBotState = isOn
      SendToProxy(binding.bindingId, isOn and "CLOSED" or "OPENED", {}, "NOTIFY")
    end
  end

  -- Press mode safety: auto-revert to OFF after a timeout in case the normal
  -- revert path (GATT_WRITE_RESPONSE) is missed due to disconnection or error.
  if isOn and not isBotSwitchMode() then
    SetTimer("PressRevert", PRESS_REVERT_DELAY_MS, function()
      log:debug("Press mode safety revert: setting Bot state to OFF")
      setBotState(false)
    end)
  else
    CancelTimer("PressRevert")
  end
end

--- Set the Bot mode and return whether it changed
--- @param isSwitch boolean Whether the device is in switch mode
--- @return boolean changed True if mode changed
local function setBotMode(isSwitch)
  log:trace("setBotMode(%s)", isSwitch)
  local mode = isSwitch and "Switch" or "Press"
  local changed = values:update("Mode", mode, "STRING")
  if changed then
    log:info("Bot mode changed to %s", mode)
  end
  return changed
end

--- Get the current Channel 1 state
--- @return boolean isOn True if Channel 1 is on
local function getChannel1State()
  log:trace("getChannel1State()")
  return Select(values:getValue("Channel 1 State"), "value") == "On"
end

--- Last channel states notified this session, keyed by binding key. In-memory
--- on purpose: a driver restart clears them, so bound consumers are
--- re-notified even when the state matches the persisted variable.
--- @type table<string, boolean>
local lastNotifiedChannelState = {}

--- Set the Channel 1 state and notify bound consumers
--- @param isOn boolean Whether Channel 1 is on
local function setChannel1State(isOn)
  log:trace("setChannel1State(%s)", isOn)
  values:update("Channel 1 State", isOn and "On" or "Off", "STRING")
  -- Deduped in memory so a driver restart re-notifies the bound consumer.
  if lastNotifiedChannelState.channel1 ~= isOn then
    local binding = bindings:getDynamicBinding(BINDINGS_NAMESPACE, "channel1")
    if binding then
      lastNotifiedChannelState.channel1 = isOn
      SendToProxy(binding.bindingId, isOn and "CLOSED" or "OPENED", {}, "NOTIFY")
    end
  end
end

--- Get the current Channel 2 state
--- @return boolean isOn True if Channel 2 is on
local function getChannel2State()
  log:trace("getChannel2State()")
  return Select(values:getValue("Channel 2 State"), "value") == "On"
end

--- Set the Channel 2 state and notify bound consumers
--- @param isOn boolean Whether Channel 2 is on
local function setChannel2State(isOn)
  log:trace("setChannel2State(%s)", isOn)
  if not isDualChannel then
    return
  end
  values:update("Channel 2 State", isOn and "On" or "Off", "STRING")
  -- Deduped in memory so a driver restart re-notifies the bound consumer.
  if lastNotifiedChannelState.channel2 ~= isOn then
    local binding = bindings:getDynamicBinding(BINDINGS_NAMESPACE, "channel2")
    if binding then
      lastNotifiedChannelState.channel2 = isOn
      SendToProxy(binding.bindingId, isOn and "CLOSED" or "OPENED", {}, "NOTIFY")
    end
  end
end

--- Set the Channel 1 power reading
--- @param power number|nil Power in watts
local function setChannel1Power(power)
  log:trace("setChannel1Power(%s)", power)
  if type(power) == "number" then
    values:update("Channel 1 Power", round(power, 2), "NUMBER", nil, " W")
  end
end

--- Set the Channel 2 power reading
--- @param power number|nil Power in watts
local function setChannel2Power(power)
  log:trace("setChannel2Power(%s)", power)
  if type(power) == "number" then
    values:update("Channel 2 Power", round(power, 2), "NUMBER", nil, " W")
  end
end

--------------------------------------------------------------------------------
-- Device Type Detection
--------------------------------------------------------------------------------

--- Detect device category from device type string
--- @param deviceTypeStr string|nil Device type name
--- @return DeviceCategory?
local function detectDeviceCategory(deviceTypeStr)
  log:trace("detectDeviceCategory(%s)", deviceTypeStr)
  if not deviceTypeStr then
    return nil
  end

  -- Check for Bot
  if SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.BOT] == deviceTypeStr then
    return DEVICE_CATEGORY.BOT
  end

  -- Check for sensor devices (Meter, Motion, Presence, Contact, Leak)
  if
    SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER_PLUS] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER_PRO] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.METER_PRO_CO2] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.INDOOR_OUTDOOR_METER] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.CONTACT] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.MOTION] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.PRESENCE] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.WATER_LEAK] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.REMOTE] == deviceTypeStr
  then
    return DEVICE_CATEGORY.SENSOR
  end

  -- Check for switch devices (Plug Mini, Relay switches)
  if
    SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.PLUG_MINI] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1PM] == deviceTypeStr
    or SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_2PM] == deviceTypeStr
  then
    return DEVICE_CATEGORY.SWITCH
  end

  return nil
end

--- Determine switch subtype from device type string
--- @param deviceTypeStr string Device type name
--- @return SwitchType|nil
local function detectSwitchType(deviceTypeStr)
  log:trace("detectSwitchType(%s)", deviceTypeStr)
  if not deviceTypeStr then
    return nil
  end

  if deviceTypeStr:match("Plug") then
    return SWITCH_TYPE.PLUG
  elseif deviceTypeStr:match("2PM") then
    return SWITCH_TYPE.RELAY_2PM
  elseif deviceTypeStr:match("1PM") then
    return SWITCH_TYPE.RELAY_1PM
  elseif deviceTypeStr:match("Relay") then
    return SWITCH_TYPE.RELAY
  end

  return nil
end

--------------------------------------------------------------------------------
-- Dynamic Binding Creation (Relay)
--------------------------------------------------------------------------------

--- Get or create channel 1 relay binding (for Switch devices)
--- @return Binding|nil binding
local function getOrCreateChannel1Binding()
  log:trace("getOrCreateChannel1Binding()")
  local binding =
    bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "channel1", "CONTROL", true, "Channel 1 Relay", "RELAY")

  if binding then
    log:info("Created RELAY binding for channel 1 (id=%s)", binding.bindingId)

    -- Register OBC handler
    OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
      log:trace(
        "OBC[%s](%s, %s, %s, %s, %s)",
        binding.bindingId,
        idBinding,
        _strClass,
        bIsBound,
        _otherDeviceId,
        _otherBindingId
      )
      if bIsBound then
        SendToProxy(binding.bindingId, getChannel1State() and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
  end

  return binding
end

--- Get or create channel 2 relay binding
--- @return Binding|nil binding
local function getOrCreateChannel2Binding()
  log:trace("getOrCreateChannel2Binding()")
  local binding =
    bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "channel2", "CONTROL", true, "Channel 2 Relay", "RELAY")

  if binding then
    log:info("Created RELAY binding for channel 2 (id=%s)", binding.bindingId)

    -- Register OBC handler
    OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
      log:trace(
        "OBC[%s](%s, %s, %s, %s, %s)",
        binding.bindingId,
        idBinding,
        _strClass,
        bIsBound,
        _otherDeviceId,
        _otherBindingId
      )
      if bIsBound then
        SendToProxy(binding.bindingId, getChannel2State() and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
  end

  return binding
end

--- Get or create Bot relay binding
--- @return Binding|nil binding
local function getOrCreateBotRelayBinding()
  log:trace("getOrCreateBotRelayBinding()")
  local binding = bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "botRelay", "CONTROL", true, "Relay", "RELAY")

  if binding then
    log:info("Created Bot RELAY binding (id=%s)", binding.bindingId)

    -- Register OBC handler
    OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
      log:trace(
        "OBC[%s](%s, %s, %s, %s, %s)",
        binding.bindingId,
        idBinding,
        _strClass,
        bIsBound,
        _otherDeviceId,
        _otherBindingId
      )
      if bIsBound then
        SendToProxy(binding.bindingId, getBotState() and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
      end
    end
  end

  return binding
end

--------------------------------------------------------------------------------
-- Dynamic Binding Creation (Sensor)
--------------------------------------------------------------------------------

--- Get or create a sensor binding (temperature/humidity)
--- @param sensorType SwitchBotSensorType
--- @return Binding|nil binding
local function getOrCreateSensorBinding(sensorType)
  log:trace("getOrCreateSensorBinding(%s)", sensorType)
  local config = SENSOR_BINDINGS[sensorType]
  if not config then
    return nil
  end

  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    sensorType,
    "CONTROL",
    true,
    config.displayName,
    config.bindingClass
  )

  if binding then
    log:info("Created %s binding for %s (id=%s)", config.bindingClass, config.displayName, binding.bindingId)

    -- Register RFP handler for value requests
    RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
      log:trace("RFP[%s](%s, %s, %s, %s)", binding.bindingId, idBinding, strCommand, _tParams, _args)
      if strCommand == "GET_VALUE" then
        local cachedValue = values:getValue(config.displayName)
        if cachedValue and cachedValue.value then
          SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = cachedValue.value, SCALE = config.scale })
        end
      end
    end

    -- Register OBC handler for binding changes
    OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
      log:trace(
        "OBC[%s](%s, %s, %s, %s, %s)",
        binding.bindingId,
        idBinding,
        _strClass,
        bIsBound,
        _otherDeviceId,
        _otherBindingId
      )
      if bIsBound then
        local cachedValue = values:getValue(config.displayName)
        if cachedValue and cachedValue.value then
          SendToProxy(idBinding, "VALUE_CHANGED", { VALUE = cachedValue.value, SCALE = config.scale })
        end
      end
    end
  end

  return binding
end

--- Send sensor value to bound consumers
--- @param sensorType SwitchBotSensorType
--- @param value number
local function sendSensorValue(sensorType, value)
  log:trace("sendSensorValue(%s, %s)", sensorType, value)
  local config = SENSOR_BINDINGS[sensorType]
  if not config then
    return
  end

  local binding = getOrCreateSensorBinding(sensorType)
  if not binding then
    return
  end

  SendToProxy(binding.bindingId, "VALUE_CHANGED", { VALUE = value, SCALE = config.scale })
end

--- Get or create a contact sensor binding
--- @param contactType ContactType
--- @return Binding|nil binding
local function getOrCreateContactBinding(contactType)
  log:trace("getOrCreateContactBinding(%s)", contactType)
  local config = CONTACT_BINDINGS[contactType]
  if not config then
    return nil
  end

  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    "contact_" .. contactType,
    "PROXY",
    true,
    config.displayName,
    "CONTACT_SENSOR"
  )

  if binding then
    log:info("Created CONTACT_SENSOR binding for %s (id=%s)", config.displayName, binding.bindingId)
  end

  return binding
end

--- Last contact states notified this session, keyed by contact type.
--- In-memory on purpose: a driver restart clears them, so bound consumers are
--- re-notified even when the state matches the last persisted reading.
--- @type table<string, boolean>
local lastNotifiedContactState = {}

--- Send contact sensor state (only on state change this session)
--- @param contactType ContactType
--- @param isActive boolean
local function sendContactState(contactType, isActive)
  log:trace("sendContactState(%s, %s)", contactType, isActive)
  local binding = getOrCreateContactBinding(contactType)
  if not binding then
    return
  end

  local config = CONTACT_BINDINGS[contactType]
  if not config then
    return
  end

  -- Deduped in memory so a driver restart re-notifies bound consumers.
  if lastNotifiedContactState[contactType] == isActive then
    return
  end
  lastNotifiedContactState[contactType] = isActive

  local event = isActive and config.closedEvent or config.openEvent
  log:debug("Sending %s to contact binding %s (state changed)", event, binding.bindingId)
  SendToProxy(binding.bindingId, event, {}, "NOTIFY")
end

--- Clear the in-memory notify memos so the next reading re-notifies bound
--- consumers. Called wherever persisted state is cleared to force a resync
--- (ESPHome rebind, driver reset).
local function clearNotifiedState()
  lastNotifiedBotState = nil
  lastNotifiedChannelState = {}
  lastNotifiedContactState = {}
end

--- Get or create a button binding
--- @param key string The binding key (e.g., "contact_button")
--- @param displayName string The display name for the binding
--- @return Binding|nil binding
local function getOrCreateButtonBinding(key, displayName)
  log:trace("getOrCreateButtonBinding(%s, %s)", key, displayName)
  local binding = bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, key, "CONTROL", false, displayName, "BUTTON_LINK")

  if binding then
    log:info("Created BUTTON_LINK binding for %s (id=%s)", displayName, binding.bindingId)
  end

  return binding
end

--- Send button press event to bound consumers
--- @param key string The binding key (e.g., "contact_button")
--- @param displayName string The display name for the binding
local function sendButtonEvent(key, displayName)
  log:trace("sendButtonEvent(%s, %s)", key, displayName)
  local binding = getOrCreateButtonBinding(key, displayName)
  if not binding then
    return
  end

  log:debug("Sending DO_CLICK and DO_PUSH/DO_RELEASE from binding %s", binding.bindingId)
  SendToProxy(binding.bindingId, "DO_CLICK", {}, "NOTIFY")
  SendToProxy(binding.bindingId, "DO_PUSH", {}, "NOTIFY")
  SendToProxy(binding.bindingId, "DO_RELEASE", {}, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Event Firing (Sensor)
--------------------------------------------------------------------------------

--- Fire an event if state changed
--- @param stateKey string State key for tracking
--- @param currentState boolean
--- @param trueEvent string Event key when state becomes true
--- @param falseEvent string Event key when state becomes false
local function fireStateChangeEvent(stateKey, currentState, trueEvent, falseEvent)
  log:trace("fireStateChangeEvent(%s, %s, %s, %s)", stateKey, currentState, trueEvent, falseEvent)
  local prevState = persist:get("previousState", {})
  local prev = prevState[stateKey]
  if prev == nil then
    -- Don't fire event on initial state load
    prevState[stateKey] = currentState
    persist:set("previousState", prevState)
    return
  end

  if currentState == prev then
    return
  end

  if currentState and not prev then
    events:fire(EVENT_NAMESPACE, trueEvent)
  elseif not currentState and prev then
    events:fire(EVENT_NAMESPACE, falseEvent)
  end

  prevState[stateKey] = currentState
  persist:set("previousState", prevState)
end

--------------------------------------------------------------------------------
-- Encryption
--------------------------------------------------------------------------------

--- Check if encryption is configured (key and key_id provided)
--- @return boolean
local function isEncryptionConfigured()
  log:trace("isEncryptionConfigured()")
  local keyId = Properties["Key ID"]
  local key = Properties["Encryption Key"]
  return not IsEmpty(keyId) and not IsEmpty(key)
end

--- Check if encryption is ready (configured and IV retrieved)
--- @return boolean
local function isEncryptionReady()
  log:trace("isEncryptionReady()")
  return isEncryptionConfigured() and encryptionIV ~= nil
end

--- Request IV from device via GATT write
local function requestIV()
  log:trace("requestIV()")
  local txHandle, _rxHandle = getHandles()
  if not txHandle then
    log:error("Cannot request IV: TX handle not discovered")
    return
  end

  if not isEncryptionConfigured() then
    log:debug("Encryption not configured, skipping IV request")
    return
  end

  if pendingIVRequest then
    log:debug("IV request already pending")
    return
  end

  log:info("Requesting IV from device")
  pendingIVRequest = true
  UpdateProperty("Encryption Status", "Requesting IV...")

  local keyId = Properties["Key ID"]
  local keyIdByte = tonumber(keyId, 16)
  if not keyIdByte or keyIdByte < 0 or keyIdByte > 255 then
    log:error("Invalid key ID: %s", keyId or "nil")
    pendingIVRequest = false
    UpdateProperty("Encryption Status", "Error: Invalid Key ID")
    return
  end

  local cmd = IV_REQUEST_PREFIX .. string.char(keyIdByte)
  log:debug("IV request command: %s (%d bytes)", C4:Encode(cmd, "HEX"), #cmd)

  SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
    handle = tostring(txHandle),
    data = C4:Base64Encode(cmd),
    response = "true",
  }, "NOTIFY")
end

--- Process IV response from device
--- @param data string Binary data from GATT notification
--- @return boolean success True if IV was successfully extracted
local function processIVResponse(data)
  log:trace("processIVResponse(%s)", data)

  if not data or #data < 5 then
    log:error("IV response too short: %d bytes (need at least 5)", data and #data or 0)
    return false
  end

  local status = string.byte(data, 1)
  if status ~= 1 then
    log:error("IV request failed: status=%d (expected 1)", status)
    return false
  end

  local ivPart = data:sub(5)
  if #ivPart == 0 then
    log:error("IV response has no IV data after status bytes")
    return false
  end

  local fullIV
  if #ivPart >= 16 then
    fullIV = ivPart:sub(1, 16)
  else
    fullIV = ivPart .. string.rep("\x00", 16 - #ivPart)
  end

  encryptionIV = fullIV
  pendingIVRequest = false

  log:info("IV retrieved successfully (%d bytes)", #ivPart)
  UpdateProperty("Encryption Status", "Ready")

  return true
end

--- Encrypt a command for sending to device
--- @param cmd string Command bytes to encrypt
--- @return string|nil encrypted Encrypted command ready to send
local function encryptCommand(cmd)
  log:trace("encryptCommand(%s)", cmd)
  if not isEncryptionReady() then
    log:error("Cannot encrypt: encryption not ready")
    return nil
  end
  --- @cast Properties["Encryption Key"] -nil
  --- @cast Properties["Key ID"] -nil
  --- @cast encryptionIV -nil

  if #cmd < 2 then
    log:error("Command too short to encrypt: %d bytes", #cmd)
    return nil
  end

  local cmdHeader = cmd:sub(1, 1)
  local cmdPayload = cmd:sub(2)

  --- @type string
  local keyHex = Properties["Encryption Key"]
  local keyBytes = C4:Decode(keyHex, "HEX")
  local encryptedPayload = C4:Encrypt("AES-128-CTR", keyBytes, encryptionIV, cmdPayload, { padding = false })

  --- @type string
  local keyId = Properties["Key ID"]
  local keyIdByte = tonumber(keyId, 16)
  if not keyIdByte then
    log:error("Invalid key ID for encryption: %s", keyId or "nil")
    return nil
  end

  local ivPrefix = encryptionIV:sub(1, 2)
  local packet = cmdHeader .. string.char(keyIdByte) .. ivPrefix .. encryptedPayload

  log:debug("Encrypted command: %s -> %s", C4:Encode(cmd, "HEX"), C4:Encode(packet, "HEX"))

  return packet
end

--- Validate encryption key format
--- @param keyHex string 32-character hex string
--- @return boolean valid
local function validateEncryptionKey(keyHex)
  log:trace("validateEncryptionKey(%s)", keyHex)
  if not keyHex or keyHex == "" then
    return false
  end

  if #keyHex ~= 32 then
    log:error("Encryption key must be 32 hex characters (got %d)", #keyHex)
    return false
  end

  if not keyHex:match("^[0-9a-fA-F]+$") then
    log:error("Encryption key must be hex characters only")
    return false
  end

  local keyBytes = C4:Decode(keyHex, "HEX")
  if #keyBytes ~= 16 then
    log:error("Failed to convert encryption key")
    return false
  end

  log:info("Encryption key validated successfully")
  encryptionIV = nil

  return true
end

--- Validate key ID format
--- @param keyId string 2-character hex key ID
--- @return boolean valid
local function validateKeyId(keyId)
  log:trace("validateKeyId(%s)", keyId)
  if not keyId or keyId == "" then
    return false
  end

  if #keyId ~= 2 then
    log:error("Key ID must be 2 hex characters (got %d)", #keyId)
    return false
  end

  if not keyId:match("^[0-9a-fA-F]+$") then
    log:error("Key ID must be hex characters only")
    return false
  end

  local keyIdByte = tonumber(keyId, 16)
  if not keyIdByte then
    log:error("Failed to convert key ID to number")
    return false
  end

  log:info("Key ID validated: %s", keyId)
  encryptionIV = nil

  return true
end

--- Update encryption status property based on current state
local function updateEncryptionStatus()
  log:trace("updateEncryptionStatus()")
  if not requiresEncryption then
    UpdateProperty("Encryption Status", "Not Required")
    return
  end

  if not isEncryptionConfigured() then
    UpdateProperty("Encryption Status", "Required - Not Configured")
  elseif isEncryptionReady() then
    UpdateProperty("Encryption Status", "Ready")
  elseif pendingIVRequest then
    UpdateProperty("Encryption Status", "Requesting IV...")
  else
    UpdateProperty("Encryption Status", "Configured (IV needed)")
  end
end

--------------------------------------------------------------------------------
-- Command Sending
--------------------------------------------------------------------------------

--- Get the appropriate command for the device type and action
--- @param action string "on", "off", or "press"
--- @param channel 1|2|nil Channel number (1 or 2)
--- @return string|nil cmd Command bytes
local function getCommand(action, channel)
  log:trace("getCommand(%s, %s)", action, channel)
  if deviceCategory == DEVICE_CATEGORY.BOT then
    -- Bot commands
    if action == "press" or (action == "on" and not isBotSwitchMode()) then
      return CMD_BOT_PRESS
    elseif action == "on" then
      return CMD_BOT_ON
    elseif action == "off" then
      -- In press mode, turn off is a no-op
      if not isBotSwitchMode() then
        return nil
      end
      return CMD_BOT_OFF
    end
  elseif deviceCategory == DEVICE_CATEGORY.SWITCH then
    -- Switch commands (Plug Mini, Relay)
    if switchType == SWITCH_TYPE.PLUG then
      if action == "on" then
        return SwitchBot.Commands.PLUG_ON
      else
        return SwitchBot.Commands.PLUG_OFF
      end
    elseif switchType == SWITCH_TYPE.RELAY_2PM then
      if channel == 2 then
        if action == "on" then
          return SwitchBot.Commands.RELAY_2PM_CH2_ON
        else
          return SwitchBot.Commands.RELAY_2PM_CH2_OFF
        end
      else
        if action == "on" then
          return SwitchBot.Commands.RELAY_2PM_CH1_ON
        else
          return SwitchBot.Commands.RELAY_2PM_CH1_OFF
        end
      end
    else
      -- Relay 1 and 1PM
      if action == "on" then
        return SwitchBot.Commands.RELAY_ON
      else
        return SwitchBot.Commands.RELAY_OFF
      end
    end
  end

  log:error("Unknown device category or action: %s/%s", deviceCategory or "nil", action)
  return nil
end

--- Send command to device via GATT write
--- @param cmd string Command bytes to send
--- @param needsEncryption boolean If true, encrypt the command
--- @return boolean success True if command was sent
local function sendCommand(cmd, needsEncryption)
  log:trace("sendCommand(%s, %s)", cmd, needsEncryption)
  local txHandle, _rxHandle = getHandles()
  if not txHandle then
    log:error("Cannot send command: TX handle not discovered")
    return false
  end

  local dataToSend
  if needsEncryption then
    if not isEncryptionConfigured() then
      log:error("Encryption required but keys not configured")
      UpdateProperty("Encryption Status", "Error: Keys not configured")
      return false
    end
    if not isEncryptionReady() then
      log:error("Encryption required but IV not retrieved")
      UpdateProperty("Encryption Status", "Error: IV not retrieved")
      return false
    end
    dataToSend = encryptCommand(cmd)
    if not dataToSend then
      UpdateProperty("Encryption Status", "Error: Command encryption failed")
      return false
    end
  else
    dataToSend = cmd
  end

  awaitingCommandResponse = true

  log:debug("Sending %s command: %s", needsEncryption and "encrypted" or "plain", C4:Encode(dataToSend, "HEX"))

  SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
    handle = tostring(txHandle),
    data = C4:Base64Encode(dataToSend),
    response = "true",
  }, "NOTIFY")

  return true
end

--- Execute pending command if one exists and we're ready
local function executePendingCommand()
  log:trace("executePendingCommand()")
  if not pendingCommand then
    return
  end

  local cmd = pendingCommand
  log:debug("Executing pending command")

  local needsEncryption = cmd.requiresEncryption
  if needsEncryption and not isEncryptionReady() then
    log:debug("Pending command waiting for encryption to be ready")
    return
  end

  if sendCommand(cmd.cmd, needsEncryption) then
    -- Optimistically update state
    if deviceCategory == DEVICE_CATEGORY.BOT then
      setBotState(cmd.isOn)
    elseif deviceCategory == DEVICE_CATEGORY.SWITCH then
      if cmd.channel == 2 then
        setChannel2State(cmd.isOn)
      else
        setChannel1State(cmd.isOn)
      end
    end
  else
    log:error("Failed to execute pending command")
    pendingCommand = nil
    requestDisconnect()
  end

  pendingCommand = nil
end

--- Check if we're ready to send a command
--- @return boolean ready True if we can send commands immediately
local function isReadyToSend()
  log:trace("isReadyToSend()")
  local txHandle, _rxHandle = getHandles()
  if not txHandle then
    return false
  end
  if requiresEncryption and not isEncryptionReady() then
    return false
  end
  return true
end

--- Initiate a command - either send immediately or queue and connect
--- @param cmd string The command bytes
--- @param channel 1|2|nil The channel (1 or 2)
--- @param isOn boolean Whether this is an ON command
local function initiateCommand(cmd, channel, isOn)
  log:trace("initiateCommand(%s, %s, %s)", cmd, channel, isOn)
  cancelPendingDisconnect()

  if isReadyToSend() then
    log:debug("Ready to send, executing command immediately")
    if sendCommand(cmd, requiresEncryption) then
      if deviceCategory == DEVICE_CATEGORY.BOT then
        setBotState(isOn)
      elseif deviceCategory == DEVICE_CATEGORY.SWITCH then
        if channel == 2 then
          setChannel2State(isOn)
        else
          setChannel1State(isOn)
        end
      end
    end
    return
  end

  log:debug("Not ready, queuing command and connecting")
  pendingCommand = {
    cmd = cmd,
    channel = channel,
    requiresEncryption = requiresEncryption,
    isOn = isOn,
  }

  updateStatus("Busy", true)
  requestConnection()
end

--- Turn on (channel 1 or specified channel)
--- @param channel 1|2|nil Channel number (default 1)
local function turnOn(channel)
  log:trace("turnOn(%s)", channel)
  local cmd = getCommand("on", channel)
  if cmd then
    initiateCommand(cmd, channel, true)
  end
end

--- Turn off (channel 1 or specified channel)
--- @param channel 1|2|nil Channel number (default 1)
local function turnOff(channel)
  log:trace("turnOff(%s)", channel)
  local cmd = getCommand("off", channel)
  if cmd then
    initiateCommand(cmd, channel, false)
  end
end

--- Toggle channel
--- @param channel  1|2|nil Channel number (default 1)
local function toggle(channel)
  log:trace("toggle(%s)", channel)

  local currentState
  if deviceCategory == DEVICE_CATEGORY.BOT then
    currentState = getBotState()
  elseif channel == 2 then
    currentState = getChannel2State()
  else
    currentState = getChannel1State()
  end

  if currentState then
    turnOff(channel)
  else
    turnOn(channel)
  end
end

--------------------------------------------------------------------------------
-- Dynamic Binding Creation (Bot)
--------------------------------------------------------------------------------

--- Register RFP handlers for a BUTTON_LINK binding (Bot only).
--- @param binding Binding|nil The binding to register handlers for
--- @param action string The action to perform: "on", "off", "toggle", or "press"
local function registerBotButtonLinkHandler(binding, action)
  log:trace("registerBotButtonLinkHandler(%s, %s)", binding, action)
  if not binding then
    return
  end

  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s, %s, %s) action=%s", binding.bindingId, idBinding, strCommand, _tParams, _args, action)
    if strCommand ~= "DO_CLICK" and strCommand ~= "DO_PUSH" then
      return
    end

    log:info("Button action %s received on '%s' binding", action, binding.displayName)
    if action == "on" or action == "press" then
      turnOn()
    elseif action == "off" then
      turnOff()
    elseif action == "toggle" then
      toggle()
    end
  end
end

--- Get or create BUTTON_LINK bindings based on Bot mode.
--- Press mode: single "Press" binding
--- Switch mode: "On", "Off", "Toggle" bindings
--- @param isSwitch boolean Whether the device is in switch mode
local function getOrCreateBotModeBindings(isSwitch)
  log:trace("getOrCreateBotModeBindings(%s)", isSwitch)

  if isSwitch then
    -- Switch mode: On, Off, Toggle bindings - remove press binding if exists
    bindings:deleteBinding(BINDINGS_NAMESPACE, "press")

    local onBinding =
      bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "on", "CONTROL", true, "Turn On", "BUTTON_LINK")
    local offBinding =
      bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "off", "CONTROL", true, "Turn Off", "BUTTON_LINK")
    local toggleBinding =
      bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "toggle", "CONTROL", true, "Toggle", "BUTTON_LINK")

    registerBotButtonLinkHandler(onBinding, "on")
    registerBotButtonLinkHandler(offBinding, "off")
    registerBotButtonLinkHandler(toggleBinding, "toggle")
  else
    -- Press mode: single Press binding - remove switch mode bindings if exist
    bindings:deleteBinding(BINDINGS_NAMESPACE, "on")
    bindings:deleteBinding(BINDINGS_NAMESPACE, "off")
    bindings:deleteBinding(BINDINGS_NAMESPACE, "toggle")

    local pressBinding =
      bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "press", "CONTROL", true, "Press", "BUTTON_LINK")
    registerBotButtonLinkHandler(pressBinding, "press")
  end
end

--------------------------------------------------------------------------------
-- Device Initialization
--------------------------------------------------------------------------------

--- Create events for a device based on its type
local function createEventsForDevice()
  log:trace("createEventsForDevice()")
  if not deviceType then
    return
  end

  local eventKeys = DEVICE_EVENTS[deviceType]
  if IsEmpty(eventKeys) then
    return
  end
  --- @cast eventKeys -nil

  log:info("Creating events for %s: %s", deviceType, table.concat(eventKeys, ", "))
  for _, eventKey in ipairs(eventKeys) do
    local eventDef = EVENT_DEFS[eventKey]
    if eventDef then
      events:getOrAddEvent(EVENT_NAMESPACE, eventDef.key, eventDef.name, eventDef.description)
    end
  end
end

--- Initialize driver for a specific device type
--- @param deviceTypeStr string Device type name
local function initializeForDeviceType(deviceTypeStr)
  log:trace("initializeForDeviceType(%s)", deviceTypeStr)
  if not deviceTypeStr then
    return
  end

  deviceType = deviceTypeStr
  deviceCategory = detectDeviceCategory(deviceTypeStr)
  if ENCRYPTED_DEVICES[deviceTypeStr] == true then
    requiresEncryption = true
  else
    requiresEncryption = false
  end
  if DUAL_CHANNEL_DEVICES[deviceTypeStr] == true then
    isDualChannel = true
  else
    isDualChannel = false
  end

  if deviceCategory == DEVICE_CATEGORY.BOT then
    -- Bot device
    hideSwitchProperties()
    hideSensorProperties()
    hideEncryptionProperties()
    showBotProperties()
    -- Create relay binding for Bot
    getOrCreateBotRelayBinding()
    -- Create mode bindings based on stored mode
    local mode = Select(values:getValue("Mode"), "value")
    getOrCreateBotModeBindings(mode == "Switch")
  elseif deviceCategory == DEVICE_CATEGORY.SWITCH then
    -- Switch device (Plug Mini, Relay)
    switchType = detectSwitchType(deviceTypeStr)
    hideBotProperties()
    hideSensorProperties()
    showChannel1Properties()

    if requiresEncryption then
      showEncryptionProperties()
    else
      hideEncryptionProperties()
    end

    -- Create relay binding for channel 1
    getOrCreateChannel1Binding()

    if isDualChannel then
      showChannel2Properties()
      -- Create relay binding for channel 2
      getOrCreateChannel2Binding()
    end
  elseif deviceCategory == DEVICE_CATEGORY.SENSOR then
    -- Sensor device (passive)
    hideBotProperties()
    hideSwitchProperties()
    hideEncryptionProperties()
    showSensorProperties()
  else
    -- Unknown device type
    log:warn("Unknown device category for: %s", deviceTypeStr)
    updateStatus("Unknown device type: " .. (deviceTypeStr or "nil"), false)
    hideBotProperties()
    hideSwitchProperties()
    hideSensorProperties()
    hideEncryptionProperties()
  end

  -- Create events for this device type
  createEventsForDevice()

  log:debug(
    "Device category: %s, passive: %s, encryption: %s, dual: %s",
    deviceCategory or "unknown",
    isPassive,
    requiresEncryption,
    isDualChannel
  )
end

--------------------------------------------------------------------------------
-- Data Processing
--------------------------------------------------------------------------------

----- Parse Bot status response from notification
----- @param data string Binary data from notification
--local function parseBotStatusResponse(data)
--  log:trace("parseBotStatusResponse()")
--
--  --- @type integer?
--  local battery = string.byte(data, 2)
--  if battery then
--    log:info("Battery level: %d%%", battery)
--    setBatteryLevel(battery)
--  end
--
--  if #data >= 10 then
--    --- @type integer?
--    local modeFlags = string.byte(data, 10)
--    if modeFlags then
--      local isSwitch = bit32.band(modeFlags, 0x10) ~= 0
--      local modeChanged = setBotMode(isSwitch)
--      if modeChanged then
--        getOrCreateBotModeBindings(isSwitch)
--      end
--      if isSwitch then
--        local isOn = bit32.band(modeFlags, 0x40) ~= 0
--        setBotState(isOn)
--      end
--    end
--  end
--
--  updateLastSeen()
--end

--- Process incoming SwitchBot data from advertisement or GATT
--- @param data SwitchBotParsedData Parsed SwitchBot data
--- @param rssi string|nil RSSI value
local function processSwitchBotData(data, rssi)
  log:trace("processSwitchBotData()")

  updateLastSeen()
  if rssi then
    updateRSSI(rssi)
  end

  -- Summary parts for "Last Received" property
  local summaryParts = {}

  -- Device type
  if not IsEmpty(data.deviceType) then
    --- @cast data.deviceType -nil
    local deviceTypeChanged = values:update("Device Type", data.deviceType, "STRING")
    if deviceTypeChanged then
      initializeForDeviceType(data.deviceType)
    end
  end

  -- Battery
  if type(data.battery) == "number" then
    setBatteryLevel(data.battery)
    table.insert(summaryParts, "Battery: " .. data.battery .. "%")
  end

  -- Bot-specific data
  if deviceCategory == DEVICE_CATEGORY.BOT then
    if data.isSwitchMode ~= nil then
      local modeChanged = setBotMode(data.isSwitchMode)
      if modeChanged then
        getOrCreateBotModeBindings(data.isSwitchMode)
      end
      table.insert(summaryParts, "Mode: " .. (data.isSwitchMode and "Switch" or "Press"))
      if data.isOn ~= nil then
        setBotState(data.isOn)
        table.insert(summaryParts, "State: " .. (data.isOn and "On" or "Off"))
      end
    end
    UpdateProperty("Last Received", #summaryParts > 0 and table.concat(summaryParts, ", ") or "No data")
    updateStatus("Listening", true)
    return
  end

  -- Switch-specific data (Plug Mini, Relay)
  if deviceCategory == DEVICE_CATEGORY.SWITCH then
    if data.channel1On ~= nil then
      setChannel1State(data.channel1On)
      table.insert(summaryParts, "Ch1: " .. (data.channel1On and "On" or "Off"))
    elseif data.isOn ~= nil then
      setChannel1State(data.isOn)
      table.insert(summaryParts, "State: " .. (data.isOn and "On" or "Off"))
    end

    if data.channel1Power ~= nil then
      setChannel1Power(data.channel1Power)
      table.insert(summaryParts, "Ch1 Power: " .. round(data.channel1Power, 1) .. "W")
    elseif data.power ~= nil then
      setChannel1Power(data.power)
      table.insert(summaryParts, "Power: " .. round(data.power, 1) .. "W")
    end

    if data.channel2On ~= nil then
      setChannel2State(data.channel2On)
      table.insert(summaryParts, "Ch2: " .. (data.channel2On and "On" or "Off"))
    end

    if data.channel2Power ~= nil then
      setChannel2Power(data.channel2Power)
      table.insert(summaryParts, "Ch2 Power: " .. round(data.channel2Power, 1) .. "W")
    end

    UpdateProperty("Last Received", #summaryParts > 0 and table.concat(summaryParts, ", ") or "No data")
    updateStatus("Listening", true)
    return
  end

  -- Sensor-specific data
  if deviceCategory == DEVICE_CATEGORY.SENSOR then
    -- Temperature (meters)
    if type(data.temperature) == "number" then
      values:update("Temperature C", data.temperature, "NUMBER", nil, " °C")
      values:update("Temperature F", c2f(data.temperature), "NUMBER", nil, " °F")
      table.insert(summaryParts, "Temp: " .. round(data.temperature, 1) .. "°C")

      sendSensorValue(SENSOR_TYPE.TEMPERATURE, data.temperature)
    end

    -- Humidity (meters)
    if type(data.humidity) == "number" then
      values:update("Humidity", data.humidity, "NUMBER", nil, " %")
      table.insert(summaryParts, "Humidity: " .. round(data.humidity, 0) .. "%")

      sendSensorValue(SENSOR_TYPE.HUMIDITY, data.humidity)
    end

    -- CO2 (Meter Pro CO2)
    if type(data.co2) == "number" then
      values:update("CO2", data.co2, "NUMBER", nil, " ppm")
      table.insert(summaryParts, "CO2: " .. data.co2 .. " ppm")
    end

    -- Motion (motion/presence sensor)
    if data.motionDetected ~= nil then
      local motionStr = data.motionDetected and "Detected" or "Clear"
      values:update("Motion", motionStr, "STRING")
      table.insert(summaryParts, "Motion: " .. motionStr)

      sendContactState(CONTACT_TYPE.MOTION, data.motionDetected)
      fireStateChangeEvent("motion", data.motionDetected, "motion_detected", "motion_cleared")
    end

    -- Light level
    if type(data.lightLevel) == "number" then
      --- Normalize the light level for presence sensor to the 0-3 scale
      local normalizedLevel
      if data.deviceType == SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.PRESENCE] then
        if data.lightLevel <= 2 then
          normalizedLevel = 0
        elseif data.lightLevel <= 6 then
          normalizedLevel = 1
        elseif data.lightLevel <= 17 then
          normalizedLevel = 2
        else
          normalizedLevel = 3
        end
      else
        normalizedLevel = data.lightLevel
      end
      local lightNames = { [0] = "Dark", [1] = "Dim", [2] = "Bright", [3] = "Very Bright" }
      local lightStr = lightNames[normalizedLevel] or "Unknown"
      values:update("Light Level", lightStr, "STRING")
      table.insert(summaryParts, "Light: " .. lightStr)
    end

    -- Contact (contact sensor)
    if data.contactOpen ~= nil then
      local contactStr = data.contactOpen and "Open" or "Closed"
      values:update("Contact", contactStr, "STRING")
      table.insert(summaryParts, "Contact: " .. contactStr)

      sendContactState(CONTACT_TYPE.CONTACT, data.contactOpen)
      fireStateChangeEvent("contact", data.contactOpen, "contact_opened", "contact_closed")

      -- At this point we know the device supports contact button
      getOrCreateButtonBinding("contact_button", "Contact Button")
    end

    -- Leak detected (water leak detector)
    if data.leakDetected ~= nil then
      local leakStr = data.leakDetected and "LEAK DETECTED" or "No Leak"
      values:update("Leak Detected", leakStr, "STRING")
      table.insert(summaryParts, "Leak: " .. (data.leakDetected and "DETECTED" or "No"))

      sendContactState(CONTACT_TYPE.LEAK, data.leakDetected)
      fireStateChangeEvent("leak", data.leakDetected, "leak_detected", "leak_cleared")
    end

    -- Tamper (water leak detector)
    if data.tampered ~= nil then
      local tamperStr = data.tampered and "Yes" or "No"
      values:update("Tamper", tamperStr, "STRING")
      table.insert(summaryParts, "Tamper: " .. tamperStr)

      sendContactState(CONTACT_TYPE.TAMPER, data.tampered)
      fireStateChangeEvent("tamper", data.tampered, "tamper_detected", "tamper_cleared")
    end

    -- Low battery event
    if data.lowBattery ~= nil then
      values:update("Battery Low", data.lowBattery and "Yes" or "No", "STRING")

      fireStateChangeEvent("low_battery", data.lowBattery, "low_battery", "battery_ok")
    end

    -- Button count (contact sensor)
    if data.contactButtonCount ~= nil then
      local prevState = persist:get("previousState", {})
      local prevCount = prevState.contactButtonCount
      if prevCount ~= nil and prevCount ~= data.contactButtonCount then
        log:info("Contact button pressed (count changed: %d -> %d)", prevCount, data.contactButtonCount)
        events:fire(EVENT_NAMESPACE, "button_pressed")
        sendButtonEvent("contact_button", "Contact Button")
        table.insert(summaryParts, "Button Pressed")
      end
      prevState.contactButtonCount = data.contactButtonCount
      persist:set("previousState", prevState)
    end

    UpdateProperty("Last Received", #summaryParts > 0 and table.concat(summaryParts, ", ") or "No data")
    updateStatus("Listening", true)
  end
end

--- Check command result from device response
--- @param data string Binary response data
--- @return boolean success True if command succeeded
local function checkCommandResult(data)
  log:trace("checkCommandResult(%s)", data)
  if not data or #data < 1 then
    log:error("Command result: empty response")
    return false
  end

  local status = string.byte(data, 1)
  log:debug("Command result: status=%d (0x%02X)", status, status)

  if status == 1 then
    log:info("Command executed successfully")
    return true
  elseif status == 0x07 then
    log:error("Command failed: password/encryption required")
    UpdateProperty("Encryption Status", "Error: Encryption required by device")
    return false
  elseif status == 0x09 then
    log:error("Command failed: incorrect encryption key")
    UpdateProperty("Encryption Status", "Error: Incorrect encryption key")
    return false
  else
    log:warn("Command result: unexpected status %d (0x%02X)", status, status)
    return false
  end
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

  -- Restore persisted state
  values:restoreValues()
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Restore persisted events (C4:AddEvent is unavailable before OnDriverLateInit)
  events:restoreEvents()

  -- Hide all optional properties initially
  hideOptionalProperties()
  hideEncryptionProperties()
  hideSwitchProperties()
  hideBotProperties()
  hideSensorProperties()

  -- Reset notification state on boot
  resetConnectionState()

  -- Restore device type and category from stored value
  local storedDeviceType = Select(values:getValue("Device Type"), "value")
  if storedDeviceType then
    initializeForDeviceType(storedDeviceType)
  end

  -- Fire OnPropertyChanged for all properties
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  gInitialized = true
  updateStatus("Waiting for data", false)

  -- Request refresh from parent driver
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

--------------------------------------------------------------------------------
-- OPC Handlers
--------------------------------------------------------------------------------

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

function OPC.Key_ID(propertyValue)
  log:trace("OPC.Key_ID('%s')", propertyValue)
  if IsEmpty(propertyValue) then
    -- Cleared - just update status
    encryptionIV = nil
    updateEncryptionStatus()
  elseif validateKeyId(propertyValue) then
    updateEncryptionStatus()
    if gInitialized and isEncryptionConfigured() then
      subscribeNotifications()
    end
  else
    UpdateProperty("Encryption Status", "Error: Invalid Key ID")
    UpdateProperty("Key ID", "")
    encryptionIV = nil
  end
end

function OPC.Encryption_Key(propertyValue)
  log:trace("OPC.Encryption_Key('%s')", propertyValue)
  if IsEmpty(propertyValue) then
    -- Cleared - just update status
    encryptionIV = nil
    updateEncryptionStatus()
  elseif validateEncryptionKey(propertyValue) then
    updateEncryptionStatus()
    if gInitialized and isEncryptionConfigured() then
      subscribeNotifications()
    end
  else
    UpdateProperty("Encryption Status", "Error: Invalid Encryption Key")
    UpdateProperty("Encryption Key", "")
    encryptionIV = nil
  end
end

--- Fetch encryption keys from SwitchBot cloud
local function fetchEncryptionKeys()
  log:trace("fetchEncryptionKeys()")

  local username = Properties["SwitchBot Username"]
  local password = Properties["SwitchBot Password"]
  local mac = Properties["MAC Address"]

  if not username or username == "" then
    log:error("Cannot fetch keys: SwitchBot Username not set")
    UpdateProperty("Encryption Status", "Error: Username required")
    return
  end

  if not password or password == "" then
    log:error("Cannot fetch keys: SwitchBot Password not set")
    UpdateProperty("Encryption Status", "Error: Password required")
    return
  end

  if not mac or mac == "" or mac == "Unknown" then
    log:error("Cannot fetch keys: MAC Address not known (connect device first)")
    UpdateProperty("Encryption Status", "Error: Connect device first")
    return
  end

  UpdateProperty("Encryption Status", "Logging in...")

  local loginUrl = "https://account." .. SWITCHBOT_API.BASE_URL .. SWITCHBOT_API.LOGIN_PATH
  local loginData = JSON:encode({
    clientId = SWITCHBOT_API.CLIENT_ID,
    username = username,
    password = password,
    grantType = "password",
    verifyCode = "",
  })
  local loginHeaders = { ["Content-Type"] = "application/json" }

  log:debug("SwitchBot API: Logging in as %s", username)

  http
    :post(loginUrl, loginData, loginHeaders)
    :next(function(response)
      --- @cast response HTTPResponse
      --- @type integer
      local statusCode = tointeger(Select(response.body, "statusCode")) or -1
      if statusCode ~= 100 then
        --- @type string?
        local message = Select(response.body, "message")
        error(message or ("Login status " .. statusCode))
      end
      --- @type string?
      local accessToken = Select(response.body, "body", "access_token")
      if IsEmpty(accessToken) then
        error("No access token in response")
      end
      --- @cast accessToken -nil
      log:info("SwitchBot login successful")
      return accessToken
    end)
    :next(function(accessToken)
      UpdateProperty("Encryption Status", "Getting region...")
      log:debug("SwitchBot API: Getting user info")

      local userInfoUrl = "https://account." .. SWITCHBOT_API.BASE_URL .. SWITCHBOT_API.USERINFO_PATH
      local userInfoHeaders = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = accessToken,
      }

      return http:post(userInfoUrl, "{}", userInfoHeaders):next(function(response)
        --- @cast response HTTPResponse
        --- @type integer
        local statusCode = tointeger(Select(response.body, "statusCode")) or -1
        if statusCode ~= 100 then
          local message = Select(response.body, "message")
          error(message or ("User info status " .. statusCode))
        end
        --- @type string?
        local region = Select(response.body, "body", "botRegion")
        if IsEmpty(region) then
          error("No region in response")
        end
        --- @cast region -nil
        log:info("SwitchBot user region: %s", region)
        return { accessToken = accessToken, region = region }
      end)
    end)
    :next(function(ctx)
      --- @cast ctx { accessToken: string, region: string }
      UpdateProperty("Encryption Status", "Fetching keys...")
      log:debug("SwitchBot API: Getting keys for %s", mac)

      local keysUrl = "https://wonderlabs." .. ctx.region .. "." .. SWITCHBOT_API.BASE_URL .. SWITCHBOT_API.KEYS_PATH
      local keysData = {
        device_mac = mac:upper():gsub(":", ""),
        keyType = "user",
      }
      local keysHeaders = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = ctx.accessToken,
      }

      return http:post(keysUrl, keysData, keysHeaders)
    end)
    :next(function(response)
      --- @cast response HTTPResponse
      --- @type integer
      local statusCode = tointeger(Select(response.body, "statusCode")) or -1
      if statusCode ~= 100 then
        local message = Select(response.body, "message")
        error(message or ("Get keys status " .. statusCode))
      end
      --- @type string?
      local keyId = Select(response.body, "body", "communicationKey", "keyId")
      --- @type string?
      local encKey = Select(response.body, "body", "communicationKey", "key")
      if IsEmpty(keyId) or IsEmpty(encKey) then
        error("Missing keys in response")
      end
      --- @cast keyId -nil
      --- @cast encKey -nil
      log:info("SwitchBot keys retrieved: keyId=%s", keyId)

      -- Clear existing keys
      UpdateProperty("Key ID", "")
      UpdateProperty("Encryption Key", "")

      UpdateProperty("Key ID", keyId, true)
      UpdateProperty("Encryption Key", encKey, true)
    end)
    :next(nil, function(err)
      local errorMsg = type(err) == "table" and (err.error or err.message) or tostring(err)
      log:error("SwitchBot API error: %s", errorMsg)
      UpdateProperty("Encryption Status", "Error: " .. errorMsg)
    end)
end

--- Check if we can auto-fetch encryption keys
--- @param force boolean If true, fetch keys even if already configured
local function maybeAutoFetchKeys(force)
  log:trace("maybeAutoFetchKeys(%s)", force)
  local username = Properties["SwitchBot Username"]
  local password = Properties["SwitchBot Password"]
  local mac = Properties["MAC Address"]

  if IsEmpty(username) or IsEmpty(password) then
    return
  end
  if IsEmpty(mac) or mac == "Unknown" then
    log:debug("Cannot auto-fetch keys: MAC address not known yet")
    return
  end

  if not requiresEncryption then
    log:debug("Skipping auto-fetch: device doesn't need encryption")
    return
  end

  if not force and isEncryptionConfigured() then
    log:debug("Skipping auto-fetch: encryption already configured")
    return
  end

  log:info("Auto-fetching encryption keys (credentials provided)")
  fetchEncryptionKeys()
end

function OPC.SwitchBot_Username(propertyValue)
  log:trace("OPC.SwitchBot_Username('%s')", propertyValue and "***" or "nil")
  maybeAutoFetchKeys(gInitialized)
end

function OPC.SwitchBot_Password(propertyValue)
  log:trace("OPC.SwitchBot_Password('%s')", propertyValue and "***" or "nil")
  maybeAutoFetchKeys(gInitialized)
end

--------------------------------------------------------------------------------
-- RFP Handlers - Relay Commands
--------------------------------------------------------------------------------

--- Get channel number from binding ID
--- @param idBinding number The binding ID
--- @return 1|2|nil channel 1, 2, or nil if not a relay binding
local function getChannelForBinding(idBinding)
  log:trace("getChannelForBinding(%s)", idBinding)
  local existingBindings = bindings:getDynamicBindings(BINDINGS_NAMESPACE)
  if not existingBindings then
    return nil
  end

  if idBinding == Select(existingBindings, "botRelay", "bindingId") then
    return 1
  elseif idBinding == Select(existingBindings, "channel1", "bindingId") then
    return 1
  elseif idBinding == Select(existingBindings, "channel2", "bindingId") then
    return 2
  end
  return nil
end

function RFP.ON(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  local channel = getChannelForBinding(idBinding)
  if not channel then
    return
  end
  turnOn(channel)
end

function RFP.OFF(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  local channel = getChannelForBinding(idBinding)
  if not channel then
    return
  end
  turnOff(channel)
end

function RFP.CLOSE(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.CLOSE(%s, %s)", idBinding, strCommand)
  local channel = getChannelForBinding(idBinding)
  if not channel then
    return
  end
  turnOn(channel)
end

function RFP.OPEN(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.OPEN(%s, %s)", idBinding, strCommand)
  local channel = getChannelForBinding(idBinding)
  if not channel then
    return
  end
  turnOff(channel)
end

function RFP.TOGGLE(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  local channel = getChannelForBinding(idBinding)
  if not channel then
    return
  end
  toggle(channel)
end

--------------------------------------------------------------------------------
-- RFP Handlers - Connection
--------------------------------------------------------------------------------

--- Handle connection notification from main driver (active GATT connection)
function RFP.CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local name = Select(tParams, "name")
  local mac = Select(tParams, "mac")
  local devType = Select(tParams, "deviceType")
  local services = DeserializeSafe(Select(tParams, "services"))

  log:info("Connected to %s device: %s", devType or "unknown", mac or "unknown")
  CancelTimer("ConnectionTimeout")

  -- Active GATT connection means this is not a passive device
  isPassive = false

  if not IsEmpty(name) then
    values:update("Name", name, "STRING")
  end
  if mac then
    values:update("MAC Address", mac, "STRING")
  end
  if devType then
    values:update("Device Type", devType, "STRING")
    if not deviceCategory then
      initializeForDeviceType(devType)
    end
  end

  if services then
    local txHandle = UUID.findCharacteristicHandle(services, SWITCHBOT_UUID.SERVICE, SWITCHBOT_UUID.TX)
    local rxHandle = UUID.findCharacteristicHandle(services, SWITCHBOT_UUID.SERVICE, SWITCHBOT_UUID.RX)

    if txHandle and rxHandle then
      log:info("Found SwitchBot TX: %d, RX: %d", txHandle, rxHandle)
      saveHandles(txHandle, rxHandle)

      notificationsSubscribed = false
      notificationsSubscribing = false

      if deviceCategory == DEVICE_CATEGORY.BOT then
        -- Bot: execute command immediately or request status
        if pendingCommand then
          executePendingCommand()
        else
          log:debug("No pending command, requesting device status")
          SendToProxy(ESPHOME_BINDING, "GATT_NOTIFY", {
            handle = tostring(rxHandle),
            enable = "true",
          }, "NOTIFY")
        end
      elseif deviceCategory == DEVICE_CATEGORY.SWITCH then
        -- Switch: check if encryption is needed
        if requiresEncryption then
          if isEncryptionConfigured() then
            subscribeNotifications()
          else
            log:warn("Encryption not configured - control commands will fail")
            UpdateProperty("Encryption Status", "Required - Not Configured")
            pendingCommand = nil
            requestDisconnect()
          end
        else
          -- Non-encrypted device (Plug Mini)
          log:info("Device does not require encryption, executing pending command")
          updateEncryptionStatus()
          executePendingCommand()
        end
      end
    else
      log:error("Could not find SwitchBot characteristics")
      -- Try cached handles
      local cachedTx, cachedRx = getHandles()
      if cachedTx and cachedRx then
        log:warn("Using cached handles as fallback: TX=%d, RX=%d", cachedTx, cachedRx)
        notificationsSubscribed = false
        notificationsSubscribing = false
        if requiresEncryption and isEncryptionConfigured() then
          subscribeNotifications()
        elseif not requiresEncryption then
          updateEncryptionStatus()
          executePendingCommand()
        end
      else
        updateStatus("Error: Missing characteristics", false)
      end
    end
  else
    log:error("No services provided in CONNECTED message")
    updateStatus("Error: Missing services", false)
  end
end

--- Handle passive connect notification from parent driver (sensor devices)
function RFP.CONNECTED_PASSIVE(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED_PASSIVE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local name = Select(tParams, "name")
  local mac = Select(tParams, "mac") or "Unknown"
  local devType = Select(tParams, "deviceType") or "Unknown"

  log:info("SwitchBot device in passive mode: %s [%s]", devType, mac)

  -- Passive connection means this is a sensor/passive device
  isPassive = true

  if not IsEmpty(name) then
    values:update("Name", name, "STRING")
  end
  values:update("Device Type", devType, "STRING")
  values:update("MAC Address", mac, "STRING")

  if not deviceCategory then
    initializeForDeviceType(devType)
  end

  updateStatus("Listening", true)
end

--- Handle incoming BLE advertisement from parent driver
function RFP.BLE_ADVERTISEMENT(idBinding, strCommand, tParams, args)
  log:trace("RFP.BLE_ADVERTISEMENT(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  -- For passive devices, call CONNECTED_PASSIVE to set up device info
  if isPassive or not deviceCategory then
    RFP.CONNECTED_PASSIVE(idBinding, strCommand, tParams, args)
  end

  -- Update device info from tParams
  local mac = Select(tParams, "mac")
  local devType = Select(tParams, "deviceType")
  if mac then
    values:update("MAC Address", mac, "STRING")
  end
  if devType then
    values:update("Device Type", devType, "STRING")
    if not deviceCategory then
      initializeForDeviceType(devType)
    end
  end

  -- Deserialize the BLEAdvertisement
  local advStr = Select(tParams, "advertisement")
  if not advStr or advStr == "" then
    return
  end

  local advertisement = DeserializeSafe(advStr)
  if not advertisement then
    return
  end
  --- @cast advertisement BLEAdvertisement

  -- Parse SwitchBot data from service and manufacturer data
  local data = SwitchBot.parse(advertisement.serviceData, advertisement.manufacturerData)
  if not data then
    return
  end

  processSwitchBotData(data, advertisement.rssi)
end

--- Handle disconnection notification from main driver
function RFP.DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.DISCONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local reason = Select(tParams, "reason") or "unknown"
  log:info("Disconnected from device: %s", reason)

  resetConnectionState()

  -- If we just received a response acknowledging our disconnect, then we are still listening
  updateStatus("Listening", true)
end

--- Handle connection failure notification from main driver
function RFP.CONNECTION_FAILED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTION_FAILED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local error = Select(tParams, "error") or "unknown"
  log:error("Connection failed: %s", error)

  resetConnectionState()
  updateStatus("Connection Failed: " .. error, false)
end

--------------------------------------------------------------------------------
-- RFP Handlers - GATT
--------------------------------------------------------------------------------

--- Handle GATT write response from main driver
function RFP.GATT_WRITE_RESPONSE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_WRITE_RESPONSE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local success = Select(tParams, "success") == "true"
  local errorCode = Select(tParams, "error")

  if success then
    log:debug("Write command successful")
    updateStatus("Busy", true)
    updateLastSeen()

    -- Bot press mode: revert to OPENED
    if deviceCategory == DEVICE_CATEGORY.BOT and not isBotSwitchMode() then
      setBotState(false)
    end
  else
    log:error("Write command failed: error=%s", errorCode)
    -- Bot press mode: revert optimistic state on failure
    if deviceCategory == DEVICE_CATEGORY.BOT and not isBotSwitchMode() then
      setBotState(false)
    end
    if pendingIVRequest then
      pendingIVRequest = false
      UpdateProperty("Encryption Status", "Error: IV request failed")
    end
    if awaitingCommandResponse then
      awaitingCommandResponse = false
      requestDisconnect()
    end
  end

  -- Bot: disconnect after command
  if deviceCategory == DEVICE_CATEGORY.BOT and awaitingCommandResponse then
    awaitingCommandResponse = false
    requestDisconnect()
  end
end

--- Handle GATT notification subscription confirmation
function RFP.GATT_NOTIFY_SUBSCRIBED(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_SUBSCRIBED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local handle = tointeger(Select(tParams, "handle"))
  local success = Select(tParams, "success") == "true"
  local error = Select(tParams, "error")

  notificationsSubscribing = false

  if success then
    log:info("GATT notifications subscribed on handle %d", handle or 0)
    notificationsSubscribed = true

    if deviceCategory == DEVICE_CATEGORY.BOT then
      -- Bot: request device status
      local cmd = CMD_BOT_GET_SETTINGS
      local txHandle, _rxHandle = getHandles()
      SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
        handle = tostring(txHandle),
        data = C4:Base64Encode(cmd),
        response = "false",
      }, "NOTIFY")
    elseif deviceCategory == DEVICE_CATEGORY.SWITCH then
      if requiresEncryption then
        if isEncryptionConfigured() and not isEncryptionReady() then
          log:debug("Requesting IV for encrypted device")
          requestIV()
        elseif isEncryptionReady() then
          log:debug("Encryption already ready, executing pending command")
          executePendingCommand()
        else
          log:error("Encryption required but not configured")
          UpdateProperty("Encryption Status", "Error: Not configured")
          pendingCommand = nil
          requestDisconnect()
        end
      else
        log:debug("Non-encrypted device, executing pending command")
        executePendingCommand()
      end
    end
  else
    log:error("GATT notification subscription failed: %s", error or "unknown")
    notificationsSubscribed = false
    UpdateProperty("Encryption Status", "Error: Notification subscription failed")
  end
end

--- Handle GATT notification data from main driver
function RFP.GATT_NOTIFY_DATA(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_DATA(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local handle = tointeger(Select(tParams, "handle"))
  local data = Select(tParams, "data")

  if not data then
    log:debug("GATT_NOTIFY with no data")
    return
  end

  local binaryData = C4:Base64Decode(data)
  if not binaryData or #binaryData == 0 then
    log:debug("GATT_NOTIFY with empty data after decode")
    return
  end

  log:debug("GATT_NOTIFY_DATA: handle=%s, %d bytes", handle or "nil", #binaryData)

  -- Check if this is an IV response
  if pendingIVRequest then
    if processIVResponse(binaryData) then
      log:info("IV retrieved, encryption ready")
      executePendingCommand()
    else
      log:error("Failed to process IV response")
      pendingIVRequest = false
      UpdateProperty("Encryption Status", "Error: Invalid IV response")
      pendingCommand = nil
      requestDisconnect()
    end
    return
  end

  -- Check if this is a command response
  if awaitingCommandResponse then
    awaitingCommandResponse = false
    checkCommandResult(binaryData)
    requestDisconnect()
    return
  end

  ---- Bot status response
  --local _, rxHandle = getHandles()
  --if deviceCategory == DEVICE_CATEGORY.BOT and handle == rxHandle then
  --  if #binaryData >= 2 then
  --    parseBotStatusResponse(binaryData)
  --    requestDisconnect()
  --    return
  --  end
  --end

  log:debug("Unexpected notification data")
end

--------------------------------------------------------------------------------
-- OBC Handlers
--------------------------------------------------------------------------------

OBC[ESPHOME_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId)
  log:trace("OBC[%s](%s, %s, %s, %s)", ESPHOME_BINDING, idBinding, strClass, bIsBound, otherDeviceId)
  resetConnectionState(true)
  persist:set("previousState", {})
  clearNotifiedState()

  if bIsBound then
    updateStatus("Waiting for data", false)
  else
    updateStatus("Disconnected", false)
  end
end

--------------------------------------------------------------------------------
-- EC Handlers
--------------------------------------------------------------------------------

--- Reset driver to initial state
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  -- Reset all dynamic state
  bindings:reset()
  values:reset()
  events:reset()

  -- Reset sensor state tracking
  persist:set("previousState", {})
  clearNotifiedState()

  -- Reset device identification
  deviceType = nil
  deviceCategory = nil
  switchType = nil
  isPassive = false
  requiresEncryption = false
  isDualChannel = false

  -- Clear handles and connection state
  resetConnectionState(true)

  -- Hide optional properties
  hideOptionalProperties()
  hideEncryptionProperties()
  hideSwitchProperties()
  hideBotProperties()
  hideSensorProperties()

  -- Reset properties to defaults (excludes user-entered credentials)
  local resetValues = GetPropertyResetValues({ "SwitchBot Username", "SwitchBot Password" })
  for propName, defaultValue in pairs(resetValues) do
    UpdateProperty(propName, defaultValue, true)
  end

  -- Request refresh from parent
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end
