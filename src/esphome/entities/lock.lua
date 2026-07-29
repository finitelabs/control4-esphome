local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class LockEntity:Entity
local LockEntity = {
  TYPE = ESPHomeClient.EntityType.LOCK,
}
LockEntity.__index = LockEntity

--- Create a new instance of the lock entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return LockEntity entity A new instance of the LockEntity entity.
function LockEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a lock entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function LockEntity:discovered(entity)
  log:trace("LockEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "lock_" .. entity.key, "PROXY", true, entity.name, "ESPHOME_LOCK")
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "REFRESH_STATE" then
      -- TODO: Find a more elegant way to refresh the state of the light entity.
      RefreshStatus()
    elseif strCommand == "ENTITY_COMMAND" then
      local command = ESPHomeProtoSchema.RPC.APIConnection[Select(tParams, "command")]
        or ESPHomeProtoSchema.RPC.APIConnection.lock_command
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
function LockEntity:disconnected()
  log:trace("LockEntity:disconnected()")
  for _, binding in pairs(bindings:getDynamicBindings(self.TYPE)) do
    SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
  end
end

--- Handle updates to the lock entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function LockEntity:updated(entity, state)
  log:trace("LockEntity:updated(%s, %s)", entity, state)
  local binding = bindings:getDynamicBinding(self.TYPE, "lock_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = SerializeSafe(entity),
      state = SerializeSafe(state),
    }, "NOTIFY")
  end
end

return LockEntity
