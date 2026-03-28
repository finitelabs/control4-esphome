local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class ClimateEntity:Entity
local ClimateEntity = {
  TYPE = ESPHomeClient.EntityType.CLIMATE,
}
ClimateEntity.__index = ClimateEntity

--- Create a new instance of the climate entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return ClimateEntity entity A new instance of the ClimateEntity entity.
function ClimateEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a climate entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function ClimateEntity:discovered(entity)
  log:trace("ClimateEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "climate_" .. entity.key, "PROXY", true, entity.name, "ESPHOME_CLIMATE")
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "REFRESH_STATE" then
      RefreshStatus()
    elseif strCommand == "ENTITY_COMMAND" then
      local command = ESPHomeProtoSchema.RPC.APIConnection[Select(tParams, "command")]
        or ESPHomeProtoSchema.RPC.APIConnection.climate_command
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

--- Handle updates to the climate entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function ClimateEntity:updated(entity, state)
  log:trace("ClimateEntity:updated(%s, %s)", entity, state)
  local binding = bindings:getDynamicBinding(self.TYPE, "climate_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = SerializeSafe(entity),
      state = SerializeSafe(state),
    }, "NOTIFY")
  end
end

return ClimateEntity
