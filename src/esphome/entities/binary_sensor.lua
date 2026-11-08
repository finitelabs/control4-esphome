local log = require("lib.logging")
local bindings = require("lib.bindings")
local entityValues = require("esphome.entity_values")
local ESPHomeClient = require("esphome.client")
local StateTell = require("esphome.state_tell")

local told = StateTell:new("BinarySensorStates")

--- @class BinarySensorEntity:Entity
local BinarySensorEntity = {
  TYPE = ESPHomeClient.EntityType.BINARY_SENSOR,
}
BinarySensorEntity.__index = BinarySensorEntity

--- Forget the states told (driver reset).
function BinarySensorEntity.clearNotifiedState()
  told:reset()
end

--- Create a new instance of the binary sensor entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return BinarySensorEntity entity A new instance of the BinarySensorEntity entity.
function BinarySensorEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a binary sensor entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function BinarySensorEntity:discovered(entity)
  log:trace("BinarySensorEntity:discovered(%s)", entity)
  local binding = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "binary_sensor_" .. entity.ref,
      "PROXY",
      true,
      entity.name,
      "CONTACT_SENSOR"
    )
  )
  OBC[binding.bindingId] = function(_idBinding, _strClass, bIsBound)
    local state = told:state(entity.ref)
    if bIsBound and state ~= nil then
      SendToProxy(binding.bindingId, "STATE_" .. state, {}, "NOTIFY")
    end
  end
end

--- Handle updates to the binary sensor entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function BinarySensorEntity:updated(entity, state)
  log:trace("BinarySensorEntity:updated(%s, %s)", entity, state)
  local value = toboolean(state.state)
  entityValues.update(entity.name .. " State", value and "1" or "0", "BOOL")

  local binding = bindings:getDynamicBinding(self.TYPE, "binary_sensor_" .. entity.ref)
  if binding ~= nil then
    told:tell(entity.ref, binding.bindingId, value and "CLOSED" or "OPENED")
  end
end

return BinarySensorEntity
