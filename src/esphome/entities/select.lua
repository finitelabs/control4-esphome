local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- Registry of discovered select entities for programming commands.
--- Maps display name to { key = number, options = string[], client = ESPHomeClient }
--- @type table<string, { key: integer, options: string[], client: ESPHomeClient }>
local selectRegistry = {}

--- @class SelectEntity:Entity
local SelectEntity = {
  TYPE = ESPHomeClient.EntityType.SELECT,
}
SelectEntity.__index = SelectEntity

--- Create a new instance of the select entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return SelectEntity entity A new instance of the SelectEntity entity.
function SelectEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a select entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function SelectEntity:discovered(entity)
  log:trace("SelectEntity:discovered(%s)", entity)

  -- Register select for programming commands
  selectRegistry[entity.name] = {
    key = entity.key,
    options = entity.options or {},
    client = self.client,
  }
end

--- Handle updates to the select entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function SelectEntity:updated(entity, state)
  log:trace("SelectEntity:updated(%s, %s)", entity, state)
  values:update(entity.name, state.state or "", "STRING", function(newValue)
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.select_command, {
        key = entity.key,
        state = newValue or "",
      })
      :next(function()
        log:info("Select option updated to '%s' for select.%s", newValue or "", entity.object_id)
      end, function(error)
        log:error("Failed to update select option for select.%s: %s", entity.name, error)
      end)
  end)
end

--- Get sorted list of select names for programming commands.
--- @return string[] names List of select display names.
local function getSelectNames()
  local names = TableKeys(selectRegistry)
  table.sort(names)
  return names
end

--- Populate the Select parameter dropdown for the Set Select command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of select names or option values.
function GCPL.Set_Select(paramName)
  log:trace("GCPL.Set_Select(%s)", paramName)
  if paramName == "Select" then
    return getSelectNames()
  elseif paramName == "Option" then
    -- Return options for the currently selected select entity
    -- Note: C4 does not pass previously selected param values to GCPL,
    -- so we return all options from all selects (deduplicated, sorted)
    local allOptions = {}
    local seen = {}
    for _, entry in pairs(selectRegistry) do
      for _, option in ipairs(entry.options) do
        if not seen[option] then
          seen[option] = true
          table.insert(allOptions, option)
        end
      end
    end
    table.sort(allOptions)
    return allOptions
  end
  return {}
end

--- Execute the Set Select command.
--- @param params table<string, any> Command parameters containing Select name and Option value.
function EC.Set_Select(params)
  log:trace("EC.Set_Select(%s)", params)
  local selectName = Select(params, "Select")
  if IsEmpty(selectName) then
    log:warn("Set Select command called without select name")
    return
  end

  local optionValue = Select(params, "Option")
  if optionValue == nil then
    log:warn("Set Select command called without option value")
    return
  end

  local entry = selectRegistry[selectName]
  if not entry then
    log:warn("Set Select command called for unknown select: %s", selectName)
    return
  end

  entry.client
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.select_command, {
      key = entry.key,
      state = optionValue,
    })
    :next(function()
      log:info("Select option set to '%s' for %s", optionValue, selectName)
    end, function(error)
      log:error("Failed to set select option for %s: %s", selectName, error)
    end)
end

return SelectEntity
