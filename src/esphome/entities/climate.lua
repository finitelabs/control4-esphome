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
  local displayName = entity.name
  if IsEmpty(displayName) then
    -- An empty name marks the device's main entity; show it under the device
    -- name, the way Home Assistant does.
    displayName = self.client:getDeviceName()
  end
  if IsEmpty(displayName) then
    displayName = (entity.entity_type or "climate"):gsub("^%l", string.upper) .. " " .. entity.key
  end
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "climate_" .. entity.key, "PROXY", true, displayName, "ESPHOME_CLIMATE")
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "REFRESH_STATE" then
      RefreshStatus()
    elseif strCommand == "SET_REMOTE_TEMPERATURE" then
      local serviceName = Select(tParams, "service_name")
      local temperature = tonumber(Select(tParams, "temperature"))
      if not IsEmpty(serviceName) then
        self.client:executeServiceByName(serviceName, temperature):next(function()
          log:debug("Remote temperature service '%s' called (temp=%s)", serviceName, temperature)
        end, function(err)
          log:error("Failed to call remote temperature service '%s': %s", serviceName, err)
        end)
      end
    elseif strCommand == "ENTITY_COMMAND" then
      local command = ESPHomeProtoSchema.RPC.APIConnection[Select(tParams, "command")]
        or ESPHomeProtoSchema.RPC.APIConnection.climate_command
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

  -- Send discovered user-defined services to the child driver for DYNAMIC_LIST population
  self:_sendUserServices(bindingId)
end

--- Notify sub-drivers that the ESPHome device has disconnected.
--- @return void
function ClimateEntity:disconnected()
  log:trace("ClimateEntity:disconnected()")
  for _, binding in pairs(bindings:getDynamicBindings(self.TYPE)) do
    SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
  end
end

--- Send the list of discovered user-defined ESPHome services to the child driver.
--- @param bindingId number The binding ID of the child climate driver.
function ClimateEntity:_sendUserServices(bindingId)
  local serviceNames = {}
  for name, _ in pairs(self.client.userServices) do
    table.insert(serviceNames, name)
  end
  table.sort(serviceNames)
  if #serviceNames > 0 then
    log:debug("Sending %d user services to climate driver (binding %s): %s", #serviceNames, bindingId, serviceNames)
    SendToProxy(bindingId, "UPDATE_USER_SERVICES", {
      service_names = SerializeSafe(serviceNames),
    }, "NOTIFY")
  end
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
