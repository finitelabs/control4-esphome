require("lib.utils")
require("vendor.drivers-common-public.global.handlers")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")

JSON = require("vendor.JSON")
local ESPHomeProtoSchema = require("esphome.proto-schema")

local log = require("lib.logging")

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

local ENTITY
local STATE -- leaving this explicitly nil so we can distinguish driver init from "unknown"

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

  C4:AllowExecute(true)

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

function OPC.Lock_Code(propertyValue)
  log:trace("OPC.Lock_Code('%s')", propertyValue)
end

local function unlock()
  log:trace("unlock()")
  local code = not IsEmpty(Properties["Lock Code"]) and Properties["Lock Code"] or nil
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = Serialize({
      command = ESPHomeProtoSchema.Enum.LockCommand.LOCK_UNLOCK,
      has_code = code ~= nil,
      code = code,
    }),
  })
end

local function lock()
  log:trace("lock()")
  local code = not IsEmpty(Properties["Lock Code"]) and Properties["Lock Code"] or nil
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = Serialize({
      command = ESPHomeProtoSchema.Enum.LockCommand.LOCK_LOCK,
      has_code = code ~= nil,
      code = code,
    }),
  })
end

local function toggle()
  log:trace("toggle()")
  local state = tointeger(Select(STATE, "state")) or 0
  if state == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_LOCKED then
    unlock()
  else
    lock()
  end
end

function RFP.LOCK(idBinding, strCommand)
  log:trace("RFP.LOCK(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.LOCK called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  lock()
end

function RFP.TOGGLE(idBinding, strCommand)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.TOGGLE called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  toggle()
end

function RFP.UNLOCK(idBinding, strCommand)
  log:trace("RFP.UNLOCK(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.UNLOCK called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  unlock()
end

local function convertLockStateToStatus(lockState)
  log:trace("convertLockStateToStatus(%s)", lockState)
  lockState = tointeger(lockState) or 0
  if lockState == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_LOCKED then
    return "locked"
  elseif lockState == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_UNLOCKED then
    return "unlocked"
  elseif lockState == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_JAMMED then
    return "fault"
  elseif lockState == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_LOCKING then
    return "unlocked"
  elseif lockState == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_UNLOCKING then
    return "locked"
  end
  return "unknown"
end

function RFP.UPDATE_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    log:error("RFP.UPDATE_STATE called with idBinding %s, expected %s", idBinding, ESPHOME_BINDING)
    return
  end

  local entity = Deserialize(Select(tParams, "entity"))
  local state = Deserialize(Select(tParams, "state"))
  if IsEmpty(entity) or IsEmpty(state) then
    log:error("RFP.UPDATE_STATE called with invalid parameters: %s", tParams)
    return
  end

  log:trace("Entity: %s", entity)
  log:trace("State: %s", state)

  -- Pull the state from the state table, or default to false if not set.
  local oldStatus = nil
  if STATE ~= nil then
    oldStatus = convertLockStateToStatus(Select(STATE, "state"))
  end
  local newStatus = convertLockStateToStatus(Select(state, "state"))

  if oldStatus ~= newStatus then
    UpdateProperty("Driver Status", "Connected")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")
    log:debug("State changed from %s -> %s", oldStatus, newStatus)
    SendToProxy(PROXY_BINDING, "LOCK_STATUS_CHANGED", { LOCK_STATUS = newStatus }, "NOTIFY")
  end

  ENTITY = entity
  STATE = state
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, reset globals to allow for a refresh of the driver state.
  ENTITY = nil
  STATE = nil
end
