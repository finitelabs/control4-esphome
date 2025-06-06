local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto-schema")

--- @class TextEntity:Entity
local TextEntity = {
  TYPE = ESPHomeClient.EntityType.TEXT,
}

--- Create a new instance of the text entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return TextEntity entity A new instance of the TextEntity entity.
function TextEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties TextEntity
  return properties
end

--- Handle updates to the text entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function TextEntity:updated(entity, state)
  log:trace("TextEntity:updated(%s, %s)", entity, state)
  values:update(entity.name, state.state or "", "STRING", function(newValue)
    -- Convert the Control4 value (string or number) to a number for ESPHome
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.text_command, {
        key = entity.key,
        state = newValue or "",
      })
      :next(function()
        log:info("Text value updated to %s for text.%s", newValue or "", entity.object_id)
      end, function(error)
        log:error("Failed to update text value for number.%s: %s", entity.name, error)
      end)
  end)
end

return TextEntity
