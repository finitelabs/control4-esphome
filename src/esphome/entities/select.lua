local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- Registry of discovered select entities for programming commands.
--- Maps display name to { key = number, device_id = number, options = string[], client = ESPHomeClient }
--- @type table<string, { key: integer, device_id: integer?, options: string[], client: ESPHomeClient }>
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

--- The variable's write callback: a valid option goes to the device, and an invalid one or one it rejects goes
--- back to its last report.
--- @param self SelectEntity
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return fun(newValue: string|integer|number): void
local function writer(self, entity)
  return function(newValue)
    local currentState = Select(values:getValue(entity.name), "value") or ""
    newValue = newValue or ""
    local options = Select(selectRegistry, entity.name, "options") or {}
    local isValid = false
    for _, opt in ipairs(options) do
      if opt == newValue then
        isValid = true
        break
      end
    end
    if not isValid then
      log:error(
        "Invalid option '%s' for %s (valid: %s); reverting",
        newValue,
        ESPHomeClient.describeEntity(entity),
        table.concat(options, ", ")
      )
      values:update(entity.name, currentState, "STRING")
      return
    end
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.select_command, {
        key = entity.key,
        device_id = entity.device_id,
        state = newValue,
      })
      :next(function()
        log:info("Select option updated to '%s' for %s", newValue, ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error("Failed to update select option for %s: %s", ESPHomeClient.describeEntity(entity), error)
        values:update(entity.name, currentState, "STRING")
      end)
  end
end

--- Handle the discovery of a select entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function SelectEntity:discovered(entity)
  log:trace("SelectEntity:discovered(%s)", entity)

  -- Register select for programming commands
  selectRegistry[entity.name] = {
    key = entity.key,
    device_id = entity.device_id,
    options = entity.options or {},
    client = self.client,
  }

  -- Writable from discovery, blank until the device's first state
  local kept = values:getValue(entity.name)
  values:update(entity.name, kept and not kept.deleted and kept.value or "", "STRING", writer(self, entity))
end

--- Handle updates to the select entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function SelectEntity:updated(entity, state)
  log:trace("SelectEntity:updated(%s, %s)", entity, state)
  values:update(entity.name, state.state or "", "STRING", writer(self, entity))
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

  local isValid = false
  for _, opt in ipairs(entry.options) do
    if opt == optionValue then
      isValid = true
      break
    end
  end
  if not isValid then
    log:warn(
      "Set Select called with invalid option '%s' for '%s' (valid: %s)",
      optionValue,
      selectName,
      table.concat(entry.options, ", ")
    )
    return
  end

  entry.client
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.select_command, {
      key = entry.key,
      device_id = entry.device_id,
      state = optionValue,
    })
    :next(function()
      log:info("Select option set to '%s' for %s", optionValue, selectName)
    end, function(error)
      log:error("Failed to set select option for %s: %s", selectName, error)
    end)
end

return SelectEntity
