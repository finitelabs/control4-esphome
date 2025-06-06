local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto-schema")

--- @class ButtonEntity:Entity
local ButtonEntity = {
  TYPE = ESPHomeClient.EntityType.BUTTON,
}

--- Create a new instance of the button entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return ButtonEntity entity A new instance of the ButtonEntity entity.
function ButtonEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties ButtonEntity
  return properties
end

--- Handle the discovery of a button entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function ButtonEntity:discovered(entity)
  log:trace("ButtonEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "button_" .. entity.key, "CONTROL", true, entity.name, "BUTTON_LINK")
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "DO_CLICK" then
      self.client
        :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.button_command, { key = entity.key })
        :next(function()
          log:debug("Command press sent to %s.%s", entity.entity_type, entity.object_id)
        end, function(error)
          log:error("An error occurred sending command press to %s.%s; %s", entity.entity_type, entity.object_id, error)
        end)
    end
  end
  OBC[bindingId] = RefreshStatus
end

return ButtonEntity
