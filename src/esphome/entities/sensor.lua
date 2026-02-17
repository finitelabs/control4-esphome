local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")

--- @class SensorEntity:Entity
local SensorEntity = {
  TYPE = ESPHomeClient.EntityType.SENSOR,
}
SensorEntity.__index = SensorEntity

--- Create a new instance of the sensor entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return SensorEntity entity A new instance of the SensorEntity entity.
function SensorEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle updates to the sensor entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
--- @diagnostic disable-next-line: unused
function SensorEntity:updated(entity, state)
  log:trace("SensorEntity:updated(%s, %s)", entity, state)
  values:update(entity.name, round(tonumber(state.state) or 0, 1), "NUMBER")
end

return SensorEntity
