--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_light.c4z"
--#endif
require("lib.utils")
require("vendor.drivers-common-public.global.handlers")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")

JSON = require("vendor.JSON")

local log = require("lib.logging")

local constants = require("constants")

local ON_BINDING = 300
local TOGGLE_BINDING = 301
local OFF_BINDING = 302
local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

local ENTITY
local STATE -- leaving this explicitly nil so we can distinguish driver init from "unknown"

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

local function on()
  log:trace("on()")
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = Serialize({
      has_state = true,
      state = true,
    }),
  })
end

local function off()
  log:trace("off()")
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = Serialize({
      has_state = true,
      state = false,
    }),
  })
end

local function toggle()
  log:trace("toggle()")
  local state = toboolean(Select(STATE, "state"))
  if state then
    off()
  else
    on()
  end
end

function RFP.ON(idBinding, strCommand)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.ON called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  on()
end

function RFP.TOGGLE(idBinding, strCommand)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.TOGGLE called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  toggle()
end

function RFP.OFF(idBinding, strCommand)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.OFF called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  off()
end

function RFP.SET_LEVEL(idBinding, strCommand, tParams, args)
  log:trace("RFP.SET_LEVEL(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= PROXY_BINDING then
    log:error("RFP.SET_LEVEL called with idBinding %s, expected PROXY_BINDING", idBinding)
    return
  end
  local level = tointeger(Select(tParams, "LEVEL"))
  if level > 0 then
    on()
  else
    off()
  end
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

  -- Pull the state from the state table, or default to false if not set.\
  local oldState = nil
  if STATE ~= nil then
    oldState = Select(STATE, "state") or false
  end
  local newState = Select(state, "state") or false

  if oldState ~= newState then
    UpdateProperty("Driver Status", "Connected")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")
    log:debug("State changed from %s -> %s", oldState, newState)
    SendToProxy(
      PROXY_BINDING,
      "LIGHT_BRIGHTNESS_CHANGED",
      { LIGHT_BRIGHTNESS_CURRENT = newState and 100 or 0 },
      "NOTIFY"
    )
  end

  ENTITY = entity
  STATE = state
end

function RFP.DO_CLICK(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_CLICK(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding == ON_BINDING then
    on()
  elseif idBinding == TOGGLE_BINDING then
    toggle()
  elseif idBinding == OFF_BINDING then
    off()
  else
    log:error("RFP.DO_CLICK called with idBinding %s, expected ON_BINDING, TOGGLE_BINDING, or OFF_BINDING", idBinding)
  end
end

function RFP.BUTTON_ACTION(idBinding, strCommand, tParams, args)
  log:trace("RFP.BUTTON_ACTION(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local action = tointeger(Select(tParams, "ACTION"))

  if action ~= constants.ButtonActions.PRESS then
    return
  end
  if buttonId == constants.ButtonIds.TOP then
    on()
  elseif buttonId == constants.ButtonIds.BOTTOM then
    off()
  elseif buttonId == constants.ButtonIds.TOGGLE then
    toggle()
  else
    log:error("RFP.BUTTON_ACTION called with invalid BUTTON_ID %s", buttonId)
  end
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, reset globals to allow for a refresh of the driver state.
  ENTITY = nil
  STATE = nil
end
