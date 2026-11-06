require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
--#ifndef DRIVERCENTRAL
local mainDriverCatchup = require("esphome.main_driver_catchup")
--#endif

JSON = require("JSON")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local log = require("lib.logging")
--#ifdef DRIVERCENTRAL
local updateSettings = require("lib.update-settings")
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
local values = require("lib.values")

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

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

-- The proxy's LockStatus variable, and the statuses it shows.
local PROXY_STATUS_VARIABLE = 1000
local SHOWN = { locked = true, unlocked = true, fault = true }

local ENTITY
local STATE -- leaving this explicitly nil so we can distinguish driver init from "unknown"
local toldStatus -- the LOCK_STATUS last sent, which an outage leaves standing
local shownRead -- whether the proxy's status was read since the load: what it shows is told it already
local shownStatus -- the status the proxy showed at that read, which the first known status takes as told

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
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
  updateStatus("Disconnected", false)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")

  --#ifndef DRIVERCENTRAL
  mainDriverCatchup.schedule()
  --#endif
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

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

--#ifdef DRIVERCENTRAL
function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end
--#endif

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

OPC.suppressDebug["Lock Code"] = true
function OPC.Lock_Code(propertyValue)
  log:trace("OPC.Lock_Code('%s')", not IsEmpty(propertyValue) and "****" or "")
end

local function unlock()
  log:trace("unlock()")
  local code = not IsEmpty(Properties["Lock Code"]) and Properties["Lock Code"] or nil
  SendSecretToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      command = ESPHomeProtoSchema.Enum.LockCommand.LOCK_UNLOCK,
      has_code = code ~= nil,
      code = code,
    }),
  })
end

local function lock()
  log:trace("lock()")
  local code = not IsEmpty(Properties["Lock Code"]) and Properties["Lock Code"] or nil
  SendSecretToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      command = ESPHomeProtoSchema.Enum.LockCommand.LOCK_LOCK,
      has_code = code ~= nil,
      code = code,
    }),
  })
end

--- Open the latch on locks that support the open action.
local function open()
  log:trace("open()")
  local code = not IsEmpty(Properties["Lock Code"]) and Properties["Lock Code"] or nil
  SendSecretToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      command = ESPHomeProtoSchema.Enum.LockCommand.LOCK_OPEN,
      has_code = code ~= nil,
      code = code,
    }),
  })
end

function EC.Open_Latch()
  log:trace("EC.Open_Latch()")
  local supportsOpen = Select(ENTITY, "supports_open")
  if supportsOpen == nil then
    log:warn("Lock entity has not been discovered yet; cannot verify open support")
    return
  end
  if not toboolean(supportsOpen) then
    log:warn("The lock does not support the open action")
    return
  end
  open()
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
  elseif lockState == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_OPENING then
    return "unlocked"
  elseif lockState == ESPHomeProtoSchema.Enum.LockState.LOCK_STATE_OPEN then
    return "unlocked"
  end
  return "unknown"
end

--- Read what the proxy shows, once a load.
local function readShown()
  shownRead = true
  local ok, status = pcall(function()
    return C4:GetDeviceVariable(C4:GetProxyDevices(), PROXY_STATUS_VARIABLE)
  end)
  if ok and SHOWN[status] then
    shownStatus = status
  end
end

--- Tell the proxy a status. One it does not show initializes it, which fires no lock event or history; after
--- that, only a change is told.
--- @param status string
local function tellStatus(status)
  if not shownRead then
    readShown()
  end
  if toldStatus == nil and status ~= "unknown" then
    toldStatus, shownStatus = shownStatus, nil
    if toldStatus == nil then
      toldStatus = status
      SendToProxy(PROXY_BINDING, "LOCK_STATUS_INITIALIZE", { LOCK_STATUS = status }, "NOTIFY")
      return
    end
  end
  if toldStatus ~= nil and status ~= toldStatus then
    log:debug("Status changed from %s -> %s", toldStatus, status)
    toldStatus = status
    SendToProxy(PROXY_BINDING, "LOCK_STATUS_CHANGED", { LOCK_STATUS = status }, "NOTIFY")
  end
end

function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s)", idBinding, strCommand)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  ENTITY = nil
  STATE = nil
  updateStatus("Disconnected", false)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
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

  -- The first report since a load, bind or disconnect brings the lock online.
  if STATE == nil then
    updateStatus("Connected", true)
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
  end
  tellStatus(convertLockStateToStatus(Select(state, "state")))

  ENTITY = entity
  STATE = state
end

OBC[ESPHOME_BINDING] = function(_idBinding, _strClass, isBound)
  -- When the binding is changed, reset globals to allow for a refresh of the driver state.
  ENTITY = nil
  STATE = nil
  -- Otherwise the proxy stays online with nothing to report to it.
  if not isBound then
    -- The lock bound next may be another: its status initializes the proxy, which still shows this one's.
    toldStatus = nil
    if gInitialized then
      shownRead, shownStatus = true, nil
    end
    updateStatus("Disconnected", false)
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  end
end
