local log = require("lib.logging")
local bindings = require("lib.bindings")
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

--- Handle the discovery of a media player entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function MediaPlayerEntity:discovered(entity)
  log:trace("MediaPlayerEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "media_player_" .. entity.key,
      "PROXY",
      true,
      entity.name,
      "ESPHOME_MEDIA_PLAYER"
    )
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "REFRESH_STATE" then
      RefreshStatus()
    elseif strCommand == "ENTITY_COMMAND" then
      local command = ESPHomeProtoSchema.RPC.APIConnection[Select(tParams, "command")]
        or ESPHomeProtoSchema.RPC.APIConnection.media_player_command
      local body = DeserializeSafe(Select(tParams, "body")) or {}
      body.key = body.key or entity.key
      self.client:callServiceMethod(command, body):next(function()
        log:debug(
          "Method %s.%s(%s) called by entity %s",
          command.service,
          command.method,
          body,
          ESPHomeClient.describeEntity(entity)
        )
      end, function(error)
        log:error(
          "An error occurred calling method %s.%s(%s) by entity %s; %s",
          command.service,
          command.method,
          body,
          ESPHomeClient.describeEntity(entity),
          error
        )
      end)
    end
  end
  OBC[bindingId] = RefreshStatus
end

--- Notify sub-drivers that the ESPHome device has disconnected.
--- @return void
function MediaPlayerEntity:disconnected()
  log:trace("MediaPlayerEntity:disconnected()")
  for _, binding in pairs(bindings:getDynamicBindings(self.TYPE)) do
    SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
  end
end

--- Handle updates to the media player entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function MediaPlayerEntity:updated(entity, state)
  log:trace("MediaPlayerEntity:updated(%s, %s)", entity, state)
  local binding = bindings:getDynamicBinding(self.TYPE, "media_player_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = SerializeSafe(entity),
      state = SerializeSafe(state),
    }, "NOTIFY")
  end
end

return MediaPlayerEntity
