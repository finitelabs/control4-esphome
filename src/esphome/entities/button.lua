local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- Registry of discovered buttons for programming commands.
--- Maps display name to { key = number, client = ESPHomeClient }
--- @type table<string, fun(): Deferred<void, string>>
local buttonRegistry = {}

--- @class ButtonEntity:Entity
local ButtonEntity = {
  TYPE = ESPHomeClient.EntityType.BUTTON,
}
ButtonEntity.__index = ButtonEntity

--- Create a new instance of the button entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return ButtonEntity entity A new instance of the ButtonEntity entity.
function ButtonEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a button entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function ButtonEntity:discovered(entity)
  log:trace("ButtonEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "button_" .. entity.key, "CONTROL", true, entity.name, "BUTTON_LINK")
  ).bindingId

  -- Register button for programming commands
  buttonRegistry[entity.name] = function()
    return self.client:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.button_command, { key = entity.key })
  end

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

--- Get sorted list of button names for programming commands.
--- @return string[] names List of button display names.
local function getButtonNames()
  local names = TableKeys(buttonRegistry)
  table.sort(names)
  return names
end

--- Populate the Button parameter dropdown for the Press Button command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of button names.
function GCPL.Press_Button(paramName)
  log:trace("GCPL.Press_Button(%s)", paramName)
  if paramName ~= "Button" then
    return {}
  end
  return getButtonNames()
end

--- Execute the Press Button command.
--- @param params table<string, any> Command parameters containing Button name.
function EC.Press_Button(params)
  log:trace("EC.Press_Button(%s)", params)
  local buttonName = Select(params, "Button")
  if IsEmpty(buttonName) then
    log:warn("Press Button command called without button name")
    return
  end

  local pressButton = buttonRegistry[buttonName]
  if not pressButton then
    log:warn("Press Button command called for unknown button: %s", buttonName)
    return
  end

  pressButton():next(function()
    log:debug("Command press sent to button %s", buttonName)
  end, function(error)
    log:error("An error occurred sending command press to button %s; %s", buttonName, error)
  end)
end

return ButtonEntity
