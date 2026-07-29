local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")

--- @class BinarySensorEntity:Entity
local BinarySensorEntity = {
  TYPE = ESPHomeClient.EntityType.BINARY_SENSOR,
}
BinarySensorEntity.__index = BinarySensorEntity

--- Create a new instance of the binary sensor entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return BinarySensorEntity entity A new instance of the BinarySensorEntity entity.
function BinarySensorEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Send the last known state to a consumer that just bound, so it does not sit
--- unknown until the sensor next changes.
--- @param bindingId integer The binding to send on.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
local function sendCachedState(bindingId, entity)
  local cached = values:getValue(entity.name .. " State")
  if cached == nil or cached.value == nil then
    return
  end
  SendToProxy(bindingId, cached.value and "CLOSED" or "OPENED", {}, "NOTIFY")
end

--- Handle the discovery of a binary sensor entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function BinarySensorEntity:discovered(entity)
  log:trace("BinarySensorEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "binary_sensor_" .. entity.key,
      "PROXY",
      true,
      entity.name,
      "CONTACT_SENSOR"
    )
  ).bindingId

  -- Seed the consumer with the current state as soon as it binds.
  OBC[bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s)", bindingId, idBinding, bIsBound)
    if bIsBound then
      sendCachedState(idBinding, entity)
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
  values:update(entity.name .. " State", value and "1" or "0", "BOOL")

  local binding = bindings:getDynamicBinding(self.TYPE, "binary_sensor_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

return BinarySensorEntity
