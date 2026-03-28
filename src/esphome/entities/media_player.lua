local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class MediaPlayerEntity:Entity
local MediaPlayerEntity = {
  TYPE = ESPHomeClient.EntityType.MEDIA_PLAYER,
}
MediaPlayerEntity.__index = MediaPlayerEntity

--- Create a new instance of the media player entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return MediaPlayerEntity entity A new instance of the MediaPlayerEntity entity.
function MediaPlayerEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Map a media player state enum value to a human-readable string.
--- @param state number? The ESPHome media player state enum value.
--- @return string stateString The human-readable state string.
local function stateToString(state)
  if state == ESPHomeProtoSchema.Enum.MediaPlayerState.MEDIA_PLAYER_STATE_IDLE then
    return "idle"
  elseif state == ESPHomeProtoSchema.Enum.MediaPlayerState.MEDIA_PLAYER_STATE_PLAYING then
    return "playing"
  elseif state == ESPHomeProtoSchema.Enum.MediaPlayerState.MEDIA_PLAYER_STATE_PAUSED then
    return "paused"
  elseif state == ESPHomeProtoSchema.Enum.MediaPlayerState.MEDIA_PLAYER_STATE_ANNOUNCING then
    return "announcing"
  elseif state == ESPHomeProtoSchema.Enum.MediaPlayerState.MEDIA_PLAYER_STATE_OFF then
    return "off"
  elseif state == ESPHomeProtoSchema.Enum.MediaPlayerState.MEDIA_PLAYER_STATE_ON then
    return "on"
  else
    return "none"
  end
end

--- Send a media player command to the ESPHome device.
--- @param self MediaPlayerEntity
--- @param entity table<string, any> The entity data.
--- @param command number The media player command enum value.
--- @param commandName string Human-readable command name for logging.
local function sendCommand(self, entity, command, commandName)
  self.client
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.media_player_command, {
      key = entity.key,
      has_command = true,
      command = command,
    })
    :next(function()
      log:debug("Command %s sent to %s.%s", commandName, entity.entity_type, entity.object_id)
    end, function(error)
      log:error(
        "An error occurred sending command %s to %s.%s; %s",
        commandName,
        entity.entity_type,
        entity.object_id,
        error
      )
    end)
end

--- Send a volume command to the ESPHome device.
--- @param self MediaPlayerEntity
--- @param entity table<string, any> The entity data.
--- @param volume number The volume level (0.0 to 1.0).
local function sendVolumeCommand(self, entity, volume)
  self.client
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.media_player_command, {
      key = entity.key,
      has_volume = true,
      volume = volume,
    })
    :next(function()
      log:debug("Volume set to %.0f%% for %s.%s", volume * 100, entity.entity_type, entity.object_id)
    end, function(error)
      log:error(
        "An error occurred setting volume for %s.%s; %s",
        entity.entity_type,
        entity.object_id,
        error
      )
    end)
end

--- Handle the discovery of a media player entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function MediaPlayerEntity:discovered(entity)
  log:trace("MediaPlayerEntity:discovered(%s)", entity)

  -- Device actions for media player commands
  local actions = {
    { name = "Play", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_PLAY },
    { name = "Pause", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_PAUSE },
    { name = "Stop", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_STOP },
    { name = "Mute", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_MUTE },
    { name = "Unmute", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_UNMUTE },
    { name = "Toggle", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_TOGGLE },
    { name = "Volume Up", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_VOLUME_UP },
    { name = "Volume Down", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_VOLUME_DOWN },
    { name = "Turn On", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_TURN_ON },
    { name = "Turn Off", command = ESPHomeProtoSchema.Enum.MediaPlayerCommand.MEDIA_PLAYER_COMMAND_TURN_OFF },
  }

  -- Register Execute Command handlers for each action
  for _, action in ipairs(actions) do
    local ecName = "Media_Player_" .. action.name:gsub(" ", "_") .. "_" .. entity.key
    EC[ecName] = function()
      sendCommand(self, entity, action.command, action.name)
    end
  end
end

--- Handle updates to the media player entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function MediaPlayerEntity:updated(entity, state)
  log:trace("MediaPlayerEntity:updated(%s, %s)", entity, state)

  -- Update state variable
  local stateString = stateToString(tointeger(state.state))
  values:update(entity.name .. " State", stateString, "STRING")

  -- Update volume variable (0-100 integer from 0.0-1.0 float)
  local volume = tointeger((tonumber(state.volume) or 0) * 100)
  values:update(entity.name .. " Volume", tostring(volume), "NUMBER", function(newValue)
    local newVolume = (tonumber_locale(newValue) or 0) / 100
    if newVolume < 0 then
      newVolume = 0
    elseif newVolume > 1 then
      newVolume = 1
    end
    sendVolumeCommand(self, entity, newVolume)
  end)

  -- Update muted variable
  local muted = toboolean(state.muted)
  values:update(entity.name .. " Muted", muted and "1" or "0", "BOOL")
end

return MediaPlayerEntity
