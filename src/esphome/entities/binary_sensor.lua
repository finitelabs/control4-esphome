local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")

--- @class BinarySensorEntity:Entity
local BinarySensorEntity = {
  TYPE = ESPHomeClient.EntityType.BINARY_SENSOR,
}

--- Create a new instance of the binary sensor entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return BinarySensorEntity entity A new instance of the BinarySensorEntity entity.
function BinarySensorEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties BinarySensorEntity
  return properties
end

--- Handle the discovery of a binary sensor entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function BinarySensorEntity:discovered(entity)
  log:trace("BinarySensorEntity:discovered(%s)", entity)
  assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "binary_sensor_" .. entity.key,
      "PROXY",
      true,
      entity.name,
      "CONTACT_SENSOR"
    )
  )
end

--- Handle updates to the binary sensor entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function BinarySensorEntity:updated(entity, state)
  log:trace("BinarySensorEntity:updated(%s, %s)", entity, state)
  local value = toboolean(state.state)
  values:update(entity.name .. " State", value and "1" or "0", "BOOL")

  local binding = bindings:getDynamicBinding(self.TYPE, "binary_sensor_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

return BinarySensorEntity
