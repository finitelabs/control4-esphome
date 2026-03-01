local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class FanEntity:Entity
local FanEntity = {
  TYPE = ESPHomeClient.EntityType.FAN,
}
FanEntity.__index = FanEntity

--- Create a new instance of the fan entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return FanEntity entity A new instance of the FanEntity entity.
function FanEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a fan entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function FanEntity:discovered(entity)
  log:trace("FanEntity:discovered(%s)", entity)
  local speed_count = entity.supported_speed_count or 0
  if speed_count <= 0 then
    speed_count = 1
  end
  local class = "ESPHOME_FAN_" .. speed_count .. "_SPEED"
  if entity.supports_direction then
    class = class .. "_REVERSE"
  end
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "fan_" .. entity.key, "PROXY", true, entity.name, class)
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "REFRESH_STATE" then
      RefreshStatus()
    elseif strCommand == "ENTITY_COMMAND" then
      local command = ESPHomeProtoSchema.RPC.APIConnection[Select(tParams, "command")]
        or ESPHomeProtoSchema.RPC.APIConnection.fan_command
      local body = DeserializeSafe(Select(tParams, "body")) or {}
      body.key = body.key or entity.key
      self.client:callServiceMethod(command, body):next(function()
        log:debug(
          "Method %s.%s(%s) called by entity %s.%s",
          command.service,
          command.method,
          body,
          entity.entity_type,
          entity.object_id
        )
      end, function(error)
        log:error(
          "An error occurred calling method %s.%s(%s) by entity %s.%s; %s",
          command.service,
          command.method,
          body,
          entity.entity_type,
          entity.object_id,
          error
        )
      end)
    end
  end
  OBC[bindingId] = RefreshStatus
end

--- Handle updates to the fan entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function FanEntity:updated(entity, state)
  log:trace("FanEntity:updated(%s, %s)", entity, state)
  local binding = bindings:getDynamicBinding(self.TYPE, "fan_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = SerializeSafe(entity),
      state = SerializeSafe(state),
    }, "NOTIFY")
  end
end

return FanEntity
