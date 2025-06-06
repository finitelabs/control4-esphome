local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto-schema")

--- @class NumberEntity:Entity
local NumberEntity = {
  TYPE = ESPHomeClient.EntityType.NUMBER,
}

--- Create a new instance of the number entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return NumberEntity entity A new instance of the NumberEntity entity.
function NumberEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties NumberEntity
  return properties
end

--- Handle updates to the number entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function NumberEntity:updated(entity, state)
  log:trace("NumberEntity:updated(%s, %s)", entity, state)
  values:update(entity.name, round(tonumber(state.state) or 0, 1), "NUMBER", function(newValue)
    -- Convert the Control4 value (string or number) to a number for ESPHome
    local numValue = tonumber(newValue) or 0
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.number_command, {
        key = entity.key,
        state = numValue,
      })
      :next(function()
        log:info("Number value updated to %s for %s.%s", numValue, entity.entity_type, entity.object_id)
      end, function(error)
        log:error("Failed to update number value for %s.%s: %s", entity.entity_type, entity.object_id, error)
      end)
  end)
end

return NumberEntity
