--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
--#ifdef FAN_CAN_REVERSE
DC_FILENAME = "esphome_fan___FAN_SPEED_COUNT___speed_reverse.c4z"
--#else
DC_FILENAME = "esphome_fan___FAN_SPEED_COUNT___speed.c4z"
--#endif
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")

local constants = require("constants")

local ON_BINDING = 300
local OFF_BINDING = 301
local TOGGLE_BINDING = 302
local SPEED_UP_BINDING = 303
local SPEED_DOWN_BINDING = 304
local TOGGLE_DIRECTION_BINDING = 305
local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

---@diagnostic disable-next-line: undefined-global
local DISCRETE_LEVELS = __FAN_SPEED_COUNT__

local ENTITY
local STATE
local PRESET_SPEED

--- Get the current speed level from the ESPHome state.
--- @return integer speed Current speed (1..DISCRETE_LEVELS), or 0 if off/unknown
local function getCurrentSpeed()
  if STATE == nil then
    return 0
  end
  local speed_level = tointeger(Select(STATE, "speed_level"))
  if speed_level == nil or speed_level <= 0 then
    return 0
  end
  return math.max(1, math.min(DISCRETE_LEVELS, speed_level))
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

local function on()
  log:trace("on()")
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      has_state = true,
      state = true,
    }),
  })
end

local function off()
  log:trace("off()")
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
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

local function setSpeed(speed)
  log:trace("setSpeed(%s)", speed)
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      has_state = true,
      state = true,
      has_speed_level = true,
      speed_level = speed,
    }),
  })
end

local function cycleSpeedUp()
  log:trace("cycleSpeedUp()")
  local current = getCurrentSpeed()
  local next_speed = math.min(DISCRETE_LEVELS, current + 1)
  setSpeed(next_speed)
end

local function cycleSpeedDown()
  log:trace("cycleSpeedDown()")
  local current = getCurrentSpeed()
  if current <= 1 then
    off()
    return
  end
  setSpeed(current - 1)
end

local function toggleDirection()
  log:trace("toggleDirection()")
  local current_direction = tointeger(Select(STATE, "direction")) or 0
  local new_direction = current_direction == 0 and 1 or 0
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      has_direction = true,
      direction = new_direction,
    }),
  })
end

function RFP.ON(idBinding, strCommand)
  log:trace("RFP.ON(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  on()
end

function RFP.OFF(idBinding, strCommand)
  log:trace("RFP.OFF(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  off()
end

function RFP.TOGGLE(idBinding, strCommand)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  toggle()
end

function RFP.SET_SPEED(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SPEED(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local speed = tointeger(Select(tParams, "SPEED"))
  if speed == nil or speed <= 0 then
    off()
    return
  end
  setSpeed(math.min(DISCRETE_LEVELS, speed))
end

function RFP.CYCLE_SPEED_UP(idBinding, strCommand)
  log:trace("RFP.CYCLE_SPEED_UP(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  cycleSpeedUp()
end

function RFP.CYCLE_SPEED_DOWN(idBinding, strCommand)
  log:trace("RFP.CYCLE_SPEED_DOWN(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  cycleSpeedDown()
end

function RFP.SET_DIRECTION(idBinding, strCommand, tParams)
  log:trace("RFP.SET_DIRECTION(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local esphome_direction
  if Select(tParams, "FORWARD") or tostring(Select(tParams, "DIRECTION")):lower() == "forward" then
    esphome_direction = 0 -- FAN_DIRECTION_FORWARD
  elseif Select(tParams, "REVERSE") or tostring(Select(tParams, "DIRECTION")):lower() == "reverse" then
    esphome_direction = 1 -- FAN_DIRECTION_REVERSE
  else
    log:warn("SET_DIRECTION called with unknown params: %s", tParams)
    return
  end
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      has_direction = true,
      direction = esphome_direction,
    }),
  })
end

function RFP.TOGGLE_DIRECTION(idBinding, strCommand)
  log:trace("RFP.TOGGLE_DIRECTION(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  toggleDirection()
end

function RFP.DESIGNATE_PRESET(idBinding, strCommand, tParams)
  log:trace("RFP.DESIGNATE_PRESET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  PRESET_SPEED = tointeger(Select(tParams, "SPEED"))
  log:debug("Preset speed set to %s", PRESET_SPEED)
end

function RFP.GET_CURRENT_STATE(idBinding, strCommand)
  log:trace("RFP.GET_CURRENT_STATE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  if STATE == nil then
    return
  end

  local is_on = toboolean(Select(STATE, "state"))
  local speed = getCurrentSpeed()
  local direction = tointeger(Select(STATE, "direction")) or 0

  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")
  SendToProxy(PROXY_BINDING, is_on and "ON" or "OFF", {}, "NOTIFY")
  if is_on and speed > 0 then
    SendToProxy(PROXY_BINDING, "CURRENT_SPEED", { SPEED = tostring(speed) }, "NOTIFY")
  end
  SendToProxy(PROXY_BINDING, "DIRECTION", { DIRECTION = direction == 0 and "forward" or "reverse" }, "NOTIFY")
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

  local oldIsOn = nil
  if STATE ~= nil then
    oldIsOn = toboolean(Select(STATE, "state"))
  end
  local newIsOn = toboolean(Select(state, "state"))

  ENTITY = entity
  STATE = state

  -- Always update connection status
  UpdateProperty("Driver Status", "Connected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = "true" }, "NOTIFY")

  -- Send ON/OFF notification
  if oldIsOn ~= newIsOn then
    log:debug("State changed from %s -> %s", oldIsOn, newIsOn)
    SendToProxy(PROXY_BINDING, newIsOn and "ON" or "OFF", {}, "NOTIFY")
  end

  -- Send speed notification
  local speed = getCurrentSpeed()
  if newIsOn and speed > 0 then
    SendToProxy(PROXY_BINDING, "CURRENT_SPEED", { SPEED = tostring(speed) }, "NOTIFY")
  end

  -- Send direction notification
  local direction = tointeger(Select(state, "direction")) or 0
  SendToProxy(PROXY_BINDING, "DIRECTION", { DIRECTION = direction == 0 and "forward" or "reverse" }, "NOTIFY")
end

function EC.Oscillate(tParams)
  log:trace("EC.Oscillate(%s)", tParams)
  local oscillating = Select(tParams, "Oscillation") == "True"
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      has_oscillating = true,
      oscillating = oscillating,
    }),
  })
end

function RFP.DO_CLICK(idBinding, strCommand, tParams, args)
  log:trace("RFP.DO_CLICK(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding == ON_BINDING then
    on()
  elseif idBinding == OFF_BINDING then
    off()
  elseif idBinding == TOGGLE_BINDING then
    toggle()
  elseif idBinding == SPEED_UP_BINDING then
    cycleSpeedUp()
  elseif idBinding == SPEED_DOWN_BINDING then
    cycleSpeedDown()
  elseif idBinding == TOGGLE_DIRECTION_BINDING then
    toggleDirection()
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
