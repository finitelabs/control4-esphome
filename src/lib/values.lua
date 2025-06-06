--- @module "lib.values"
--- Values module for managing dynamic values with variable and property support.

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")

--- @class Values
--- A class representing a collection of named values with optional variable/property support.
local Values = {}

--- Persistent storage key for values.
--- @type string
local VALUES_PERSIST_KEY = "Values"

local function ovcKey(name)
  -- Convert the name to a valid OVC variable name by replacing spaces with underscores
  return string.gsub(name, "%s+", "_")
end

--- @class Value
--- @field index integer Index used for ordering values during restore.
--- @field varType VariableType? Optional variable type if registered as a variable
--- @field value string|integer|number|nil The stored value

--- Creates a new Values instance.
--- @return Values values A new Values instance.
function Values:new()
  log:trace("Values:new()")
  local properties = {}
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties Values
  return properties
end

--- Updates a value. If the value does not exist, it will be created. If the
--- `name` is also a property, it will also be updated.
--- @param name string The name of the value to update or create. Must be globally unique.
--- @param value string|integer|number|nil The value to set, can be `nil`.
--- @param varType VariableType? The type of the variable, if `nil` it will not be registered as a variable.
--- @param varChangedCallback (fun(newValue: string|integer|number): void)? The callback function to be called when the variable changes.
--- @return void
function Values:update(name, value, varType, varChangedCallback)
  log:trace("Values:update(%s, %s, %s, %s)", name, value, varType, varChangedCallback)
  local values = self:getValues()
  values[name] = {
    index = Select(values, name, "index") or self:_getNextValueId(),
    varType = varType,
    value = value,
  }
  self:_saveValues(values)

  local strValue = tostring(value or "")

  if varType ~= nil then
    -- Register an OVC handler for this variable if a callback is provided
    OVC[ovcKey(name)] = varChangedCallback
        and function(newValue)
          log:debug("Variable %s changed to %s", name, newValue)
          varChangedCallback(newValue)
        end
      or nil
    if Variables[name] == nil then
      C4:AddVariable(name, strValue, varType, varChangedCallback == nil, false)
    elseif Variables[name] ~= strValue then
      C4:SetVariable(name, strValue)
    end
  elseif Variables[name] ~= nil then
    OVC[ovcKey(name)] = nil
    C4:DeleteVariable(name)
    Variables[name] = nil
  end
  if Properties[name] ~= nil and Properties[name] ~= strValue then
    UpdateProperty(name, strValue, true)
    -- Ensure the property is visible
    C4:SetPropertyAttribs(name, constants.SHOW_PROPERTY)
  end
end

--- Deletes a value and removes associated variable/property.
--- @param name string The name of the value to delete.
--- @return void
function Values:delete(name)
  log:trace("Values:delete(%s)", name)
  local values = self:getValues()
  if values[name] == nil then
    log:warn("Value %s does not exist; ignoring delete", name)
    return
  end

  log:debug("Deleting value %s", name)
  values[name] = nil
  self:_saveValues(values)

  if Variables[name] ~= nil then
    OVC[ovcKey(name)] = nil
    C4:DeleteVariable(name)
    Variables[name] = nil
  end

  if Properties[name] ~= nil then
    UpdateProperty(name, "", true)
    -- The best we can do to delete a property is to hide it
    C4:SetPropertyAttribs(name, constants.HIDE_PROPERTY)
  end
end

--- Retrieves all values from persistent storage.
--- @return table<string, Value> values A table of all values mapped by their name.
function Values:getValues()
  log:trace("Values:getValues()")
  return persist:get(VALUES_PERSIST_KEY, {}) or {}
end

--- Retrieves a value by name.
--- @param name string The name of the value to retrieve.
--- @return Value|nil value The value associated with the name, or nil if it does not exist.
function Values:getValue(name)
  log:trace("Values:getValue(%s)", name)
  return Select(self:getValues(), name)
end

--- Restores all values from persistent storage. Ensures that all
--- values are re-added in a consistent order based on their index.
--- @return void
function Values:restoreValues()
  log:trace("Values:restoreValues()")
  local values = self:getValues()
  -- Sort by index so that the order is consistent, this is important to retain
  -- programming associated with any variables.
  table.sort(values, function(a, b)
    return a.index < b.index
  end)
  for name, value in pairs(values) do
    log:debug("Restoring %s value %s", value.varType, name)
    self:update(name, value.value, value.varType, nil)
  end
end

--- Saves the values to persistent storage.
--- @param values table<string, Value>? The values table to save, nil clears storage.
--- @return void
function Values:_saveValues(values)
  log:trace("Values:_saveValues(%s)", values)
  persist:set(VALUES_PERSIST_KEY, not IsEmpty(values) and values or nil)
end

--- Retrieves the next available value ID. Ensures that the ID is unique across all values.
--- @return number valueId The next available value ID starting from 1.
function Values:_getNextValueId()
  log:trace("Values:_getNextValueId()")
  local values = self:getValues()
  --- @type table<number, boolean>
  local currentValues = {}
  for _, value in pairs(values) do
    currentValues[value.index] = true
  end
  local index = 1
  while currentValues[index] ~= nil do
    index = index + 1
  end
  return index
end

return Values:new()
