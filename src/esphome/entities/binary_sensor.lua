local log = require("lib.logging")
local bindings = require("lib.bindings")
local entityValues = require("esphome.entity_values")
local ESPHomeClient = require("esphome.client")
local StateTell = require("esphome.state_tell")
local ContactReading = require("esphome.contact_reading")

local told = StateTell:new("BinarySensorStates")

--- Each sensor's device class by ref, as discovered this load.
--- @type table<string, string|nil>
local classes = {}

--- Device classes whose "on" is open or detected, which the contact reads as the item's reading.
local OPEN_WHEN_ON = {
  door = true,
  window = true,
  opening = true,
  garage_door = true,
  motion = true,
  occupancy = true,
  presence = true,
  moving = true,
}

--- The state a binary sensor's contact reads for `on`.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param on boolean Whether the sensor is on.
--- @return string state "OPENED" or "CLOSED".
local function contactState(entity, on)
  if OPEN_WHEN_ON[entity.device_class] then
    return ContactReading.state(on)
  end
  return on and "CLOSED" or "OPENED"
end

--- @class BinarySensorEntity:Entity
local BinarySensorEntity = {
  TYPE = ESPHomeClient.EntityType.BINARY_SENSOR,
}
BinarySensorEntity.__index = BinarySensorEntity

--- Forget the states told (driver reset).
function BinarySensorEntity.clearNotifiedState()
  told:reset()
end

--- Tell each kept state of a sensor the reading covers the other way, silently. A sensor not
--- discovered this load has its kept state forgotten, so its next reading goes out silently.
function BinarySensorEntity.retellContacts()
  for ref in pairs(told:states()) do
    if classes[ref] == nil then
      told:forget(ref)
    elseif OPEN_WHEN_ON[classes[ref]] then
      local binding = bindings:getDynamicBinding(BinarySensorEntity.TYPE, "binary_sensor_" .. ref)
      told:flip(ref, binding and binding.bindingId)
    end
  end
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
  classes[entity.ref] = entity.device_class or ""
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
    told:tell(entity.ref, binding.bindingId, contactState(entity, value))
  end
end

return BinarySensorEntity
