--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_alarm.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local log = require("lib.logging")

local PANEL_BINDING = 5001
local PARTITION_BINDING = 5002
local ESPHOME_BINDING = 5003

local ENTITY
local STATE
local INITIALIZED = false

--- Last partition state notified to the security proxy, as a "state|type" key.
--- In-memory only, so a driver restart always re-notifies. Cleared whenever the
--- ESPHome binding is torn down or the device disconnects.
local lastNotifiedPartitionState

--- ESPHome AlarmControlPanelState → C4 partition state mapping.
--- Returns { state = string, type = string|nil }
local function alarmStateToPartitionState(alarmState)
  alarmState = tointeger(alarmState) or 0
  if alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_DISARMED then
    return { state = "DISARMED_READY" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_ARMED_HOME then
    return { state = "ARMED", type = "Stay" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_ARMED_AWAY then
    return { state = "ARMED", type = "Away" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_ARMED_NIGHT then
    return { state = "ARMED", type = "Night" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_ARMED_VACATION then
    return { state = "ARMED", type = "Vacation" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_ARMED_CUSTOM_BYPASS then
    return { state = "ARMED", type = "Custom Bypass" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_PENDING then
    return { state = "EXIT_DELAY" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_ARMING then
    return { state = "EXIT_DELAY" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_DISARMING then
    return { state = "ENTRY_DELAY" }
  elseif alarmState == ESPHomeProtoSchema.Enum.AlarmControlPanelState.ALARM_STATE_TRIGGERED then
    return { state = "ALARM", type = "Burglary" }
  end
  return { state = "DISARMED_NOT_READY" }
end

--- C4 ArmType → ESPHome AlarmControlPanelStateCommand
local ARM_TYPE_TO_COMMAND = {
  ["Stay"] = ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_ARM_HOME,
  ["Away"] = ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_ARM_AWAY,
  ["Night"] = ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_ARM_NIGHT,
  ["Vacation"] = ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_ARM_VACATION,
  ["Custom Bypass"] = ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_ARM_CUSTOM_BYPASS,
}

--- ESPHome supported_features bitmask constants (from ESPHome source).
--- @see https://esphome.io/components/alarm_control_panel/
local FEATURE_ARM_HOME = 0x01
local FEATURE_ARM_AWAY = 0x02
local FEATURE_ARM_NIGHT = 0x04
local FEATURE_ARM_VACATION = 0x08
local FEATURE_ARM_CUSTOM_BYPASS = 0x10
local FEATURE_TRIGGER = 0x20

--- Build the arm_states capability string from ESPHome supported_features.
--- @param features number The supported_features bitmask.
--- @return string arm_states Comma-separated arm state list.
local function buildArmStates(features)
  features = tointeger(features) or 0
  local states = {}
  if bit.band(features, FEATURE_ARM_HOME) ~= 0 then
    table.insert(states, "Stay")
  end
  if bit.band(features, FEATURE_ARM_AWAY) ~= 0 then
    table.insert(states, "Away")
  end
  if bit.band(features, FEATURE_ARM_NIGHT) ~= 0 then
    table.insert(states, "Night")
  end
  if bit.band(features, FEATURE_ARM_VACATION) ~= 0 then
    table.insert(states, "Vacation")
  end
  if bit.band(features, FEATURE_ARM_CUSTOM_BYPASS) ~= 0 then
    table.insert(states, "Custom Bypass")
  end
  if #states == 0 then
    -- Default to Stay and Away if no features reported
    return "Stay,Away"
  end
  return table.concat(states, ",")
end

--- Notify-memo key for a partition state.
--- @param partitionState table { state = string, type = string|nil }
--- @return string key
local function partitionStateKey(partitionState)
  return partitionState.state .. "|" .. (partitionState.type or "")
end

--- Send a partition state notification to the security proxy.
--- ESPHome re-dumps every entity state on each refresh, and PARTITION_STATE
--- fires Control4 programming, so an unchanged state is suppressed rather than
--- retriggering it.
--- @param partitionState table { state = string, type = string|nil }
local function sendPartitionState(partitionState)
  log:trace("sendPartitionState(%s)", partitionState)
  local key = partitionStateKey(partitionState)
  if lastNotifiedPartitionState == key then
    log:trace("Partition state unchanged (%s), not re-notifying", key)
    return
  end
  lastNotifiedPartitionState = key
  local params = { STATE = partitionState.state }
  if partitionState.type then
    params.TYPE = partitionState.type
  end
  SendToProxy(PARTITION_BINDING, "PARTITION_STATE", params, "NOTIFY")
  -- Also notify the panel binding about partition state
  params.PARTITION_ID = "1"
  SendToProxy(PANEL_BINDING, "PANEL_PARTITION_STATE", params, "NOTIFY")
end

--- Send an alarm command to the ESPHome device via the binding.
--- @param command number The AlarmControlPanelStateCommand enum value.
--- @param code string|nil Optional user code.
local function sendAlarmCommand(command, code)
  log:trace("sendAlarmCommand(%s, %s)", command, code)
  local body = {
    command = command,
  }
  if code ~= nil and code ~= "" then
    body.has_code = true
    body.code = tostring(code)
  end
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe(body),
  })
end

--- Send capabilities to the security proxy based on entity data.
--- @param entity table<string, any> The entity data.
local function sendCapabilities(entity)
  log:trace("sendCapabilities(%s)", entity)

  -- Notify partition enabled
  SendToProxy(PARTITION_BINDING, "PARTITION_ENABLED", { ENABLED = "true" }, "NOTIFY")

  -- Notify code required
  local codeRequired = "false"
  if entity.requires_code then
    codeRequired = "true"
  end
  SendToProxy(PARTITION_BINDING, "CODE_REQUIRED", { CODE_REQUIRED = codeRequired }, "NOTIFY")

  -- Notify panel initialized
  SendToProxy(PANEL_BINDING, "PANEL_INITIALIZED", {}, "NOTIFY")
end

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
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Disconnected")
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

---------------------------------------------------------------------------
-- Security partition proxy commands (RFP handlers)
---------------------------------------------------------------------------

function RFP.PARTITION_ARM(idBinding, strCommand, tParams)
  log:trace("RFP.PARTITION_ARM(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PARTITION_BINDING then
    return
  end
  local armType = Select(tParams, "ArmType") or "Away"
  local userCode = Select(tParams, "UserCode")
  local command = ARM_TYPE_TO_COMMAND[armType]
  if command == nil then
    log:warn("Unknown ArmType '%s', defaulting to ARM_AWAY", armType)
    command = ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_ARM_AWAY
  end
  sendAlarmCommand(command, userCode)
end

function RFP.PARTITION_DISARM(idBinding, strCommand, tParams)
  log:trace("RFP.PARTITION_DISARM(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PARTITION_BINDING then
    return
  end
  local userCode = Select(tParams, "UserCode")
  sendAlarmCommand(ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_DISARM, userCode)
end

function RFP.ARM_CANCEL(idBinding, strCommand, tParams)
  log:trace("RFP.ARM_CANCEL(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PARTITION_BINDING then
    return
  end
  -- No direct ESPHome equivalent; send DISARM
  local userCode = Select(tParams, "UserCode")
  sendAlarmCommand(ESPHomeProtoSchema.Enum.AlarmControlPanelStateCommand.ALARM_CONTROL_PANEL_DISARM, userCode)
end

---------------------------------------------------------------------------
-- State update handler (from ESPHome entity via main driver)
---------------------------------------------------------------------------

function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s)", idBinding, strCommand)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  ENTITY = nil
  STATE = nil
  UpdateProperty("Driver Status", "Disconnected")
  -- Going offline is a real state transition, so let it fire programming. Only
  -- meaningful once the panel has reported at least one state.
  if INITIALIZED then
    sendPartitionState({ state = "OFFLINE" })
  end
  INITIALIZED = false
  lastNotifiedPartitionState = nil
end

function RFP.UPDATE_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    log:error("RFP.UPDATE_STATE called with idBinding %s, expected %s", idBinding, ESPHOME_BINDING)
    return
  end

  local entity = DeserializeSafe(Select(tParams, "entity"))
  local state = DeserializeSafe(Select(tParams, "state"))
  if IsEmpty(entity) or IsEmpty(state) then
    log:error("RFP.UPDATE_STATE called with invalid parameters: %s", tParams)
    return
  end

  log:trace("Entity: %s", entity)
  log:trace("State: %s", state)

  ENTITY = entity
  STATE = state

  -- Update connection status
  UpdateProperty("Driver Status", "Connected")

  -- Send capabilities and initialization on first state update
  if not INITIALIZED then
    sendCapabilities(entity)
    INITIALIZED = true

    -- Seed the initial partition state. PARTITION_STATE_INIT deliberately does
    -- not fire programming, so prime the notify memo alongside it to keep the
    -- next redundant state dump from firing it either.
    local partitionState = alarmStateToPartitionState(Select(state, "state"))
    SendToProxy(PARTITION_BINDING, "PARTITION_STATE_INIT", {
      STATE = partitionState.state,
      TYPE = partitionState.type or "",
    }, "NOTIFY")
    lastNotifiedPartitionState = partitionStateKey(partitionState)
    return
  end

  -- Send partition state update
  local partitionState = alarmStateToPartitionState(Select(state, "state"))
  sendPartitionState(partitionState)
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, reset globals to allow for a refresh of the driver state.
  ENTITY = nil
  STATE = nil
  INITIALIZED = false
  -- Drop the notify memo too, so the re-seed after rebinding is not swallowed.
  lastNotifiedPartitionState = nil
end
