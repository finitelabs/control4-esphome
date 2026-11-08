local log = require("lib.logging")
local values = require("lib.values")
local entityValues = require("esphome.entity_values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class TextEntity:Entity
local TextEntity = {
  TYPE = ESPHomeClient.EntityType.TEXT,
}
TextEntity.__index = TextEntity

--- Create a new instance of the text entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return TextEntity entity A new instance of the TextEntity entity.
function TextEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- The variable's write callback: the value goes to the device, and one it rejects goes back to its last report.
--- @param self TextEntity
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return fun(newValue: string|integer|number): void
local function writer(self, entity)
  return function(newValue)
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.text_command, {
        key = entity.key,
        device_id = entity.device_id,
        state = newValue or "",
      })
      :next(function()
        log:info("Text value updated to %s for %s", newValue or "", ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error("Failed to update text value for %s: %s", ESPHomeClient.describeEntity(entity), error)
        entityValues.update(entity.name, Select(values:getValue(entity.name), "value") or "", "STRING")
      end)
  end
end

--- Handle the discovery of a text entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function TextEntity:discovered(entity)
  log:trace("TextEntity:discovered(%s)", entity)
  local kept = values:getValue(entity.name)
  entityValues.update(entity.name, kept and not kept.deleted and kept.value or "", "STRING", writer(self, entity))
end

--- Handle updates to the text entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function TextEntity:updated(entity, state)
  log:trace("TextEntity:updated(%s, %s)", entity, state)
  entityValues.update(entity.name, state.state or "", "STRING", writer(self, entity))
end

return TextEntity
