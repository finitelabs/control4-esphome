local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto-schema")

--- @class LockEntity:Entity
local LockEntity = {
  TYPE = ESPHomeClient.EntityType.LOCK,
}

--- Create a new instance of the lock entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return LockEntity entity A new instance of the LockEntity entity.
function LockEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties LockEntity
  return properties
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
      local body = Deserialize(Select(tParams, "body")) or {}
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

--- Handle updates to the lock entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function LockEntity:updated(entity, state)
  log:trace("LockEntity:updated(%s, %s)", entity, state)
  local binding = bindings:getDynamicBinding(self.TYPE, "lock_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = Serialize(entity),
      state = Serialize(state),
    }, "NOTIFY")
  end
end

return LockEntity
