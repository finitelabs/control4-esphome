local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")

--- @class TextSensorEntity:Entity
local TextSensorEntity = {
  TYPE = ESPHomeClient.EntityType.TEXT_SENSOR,
}
TextSensorEntity.__index = TextSensorEntity

--- Create a new instance of the text sensor entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return TextSensorEntity entity A new instance of the TextSensorEntity entity.
function TextSensorEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle updates to the text sensor entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
--- @diagnostic disable-next-line: unused
function TextSensorEntity:updated(entity, state)
  log:trace("TextSensorEntity:updated(%s, %s)", entity, state)
  values:update(entity.name, state.state or "", "STRING")
end

return TextSensorEntity
