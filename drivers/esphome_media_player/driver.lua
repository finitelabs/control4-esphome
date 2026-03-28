--#ifdef DRIVERCENTRAL
DC_PID = nil
DC_X = nil
DC_FILENAME = "esphome_media_player.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local log = require("lib.logging")

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

local ESPHOME_STATE = ESPHomeProtoSchema.Enum.MediaPlayerState
local ESPHOME_CMD = ESPHomeProtoSchema.Enum.MediaPlayerCommand

--- C4 play status strings for PLAY_STATUS_CHANGED notification
local C4_STATUS = {
  STOPPED = "0", -- Stopped
  PLAYING = "1", -- Playing
  PAUSED = "2", -- Paused
}

local ENTITY
local STATE

--- Map ESPHome media player state to C4 play status string.
--- @param espState number? The ESPHome media player state enum value.
--- @return string status The C4 play status string.
local function mapState(espState)
  local s = tointeger(espState)
  if
    s == ESPHOME_STATE.MEDIA_PLAYER_STATE_PLAYING
    or s == ESPHOME_STATE.MEDIA_PLAYER_STATE_ANNOUNCING
    or s == ESPHOME_STATE.MEDIA_PLAYER_STATE_ON
  then
    return C4_STATUS.PLAYING
  elseif s == ESPHOME_STATE.MEDIA_PLAYER_STATE_PAUSED then
    return C4_STATUS.PAUSED
  else
    return C4_STATUS.STOPPED
  end
end

--- Send a media player command to the ESPHome device via the main driver.
--- @param command number The ESPHome MediaPlayerCommand enum value.
local function sendMediaCommand(command)
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      has_command = true,
      command = command,
    }),
  })
end

--- Send a volume command to the ESPHome device via the main driver.
--- @param volume number The volume level (0.0 to 1.0).
local function sendVolumeCommand(volume)
  SendToProxy(ESPHOME_BINDING, "ENTITY_COMMAND", {
    body = SerializeSafe({
      has_volume = true,
      volume = volume,
    }),
  })
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
  SendToProxy(PROXY_BINDING, "ONLINE_STATUS_CHANGED", { STATUS = "false" }, "NOTIFY")
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

--- Handle Generic Media Player proxy commands
function RFP.PLAY(idBinding, strCommand)
  log:trace("RFP.PLAY(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendMediaCommand(ESPHOME_CMD.MEDIA_PLAYER_COMMAND_PLAY)
end

function RFP.PAUSE(idBinding, strCommand)
  log:trace("RFP.PAUSE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendMediaCommand(ESPHOME_CMD.MEDIA_PLAYER_COMMAND_PAUSE)
end

function RFP.STOP(idBinding, strCommand)
  log:trace("RFP.STOP(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  sendMediaCommand(ESPHOME_CMD.MEDIA_PLAYER_COMMAND_STOP)
end

function RFP.PLAYPAUSE(idBinding, strCommand)
  log:trace("RFP.PLAYPAUSE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  -- Toggle between play and pause based on current state
  local currentStatus = mapState(Select(STATE, "state"))
  if currentStatus == C4_STATUS.PLAYING then
    sendMediaCommand(ESPHOME_CMD.MEDIA_PLAYER_COMMAND_PAUSE)
  else
    sendMediaCommand(ESPHOME_CMD.MEDIA_PLAYER_COMMAND_PLAY)
  end
end

--- Handle a disconnect notification from the main ESPHome driver
function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s)", idBinding, strCommand)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  ENTITY = nil
  STATE = nil
  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_STATUS_CHANGED", { STATUS = "false" }, "NOTIFY")
end

--- Handle state updates from the main ESPHome driver
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

  local oldStatus = nil
  if STATE ~= nil then
    oldStatus = mapState(Select(STATE, "state"))
  end
  local newStatus = mapState(Select(state, "state"))

  ENTITY = entity
  STATE = state

  -- Always update connection status
  UpdateProperty("Driver Status", "Connected")
  SendToProxy(PROXY_BINDING, "ONLINE_STATUS_CHANGED", { STATUS = "true" }, "NOTIFY")

  -- Send play status notification when state changes
  if oldStatus ~= newStatus then
    log:debug("Play status changed from %s -> %s", oldStatus, newStatus)
    SendToProxy(PROXY_BINDING, "PLAY_STATUS_CHANGED", { STATUS = newStatus }, "NOTIFY")
  end

  -- Log volume/mute changes for debugging
  local volume = tonumber(state.volume)
  local muted = toboolean(state.muted)
  if volume ~= nil then
    log:debug("Volume: %.0f%%, Muted: %s", volume * 100, muted and "yes" or "no")
  end
end

OBC[ESPHOME_BINDING] = function()
  -- When the binding is changed, reset globals to allow for a refresh of the driver state.
  ENTITY = nil
  STATE = nil
end
