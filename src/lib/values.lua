--- Values module for managing dynamic values with variable and property support.

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")

--- @class Values
--- A class representing a collection of named values with optional variable/property support.
local Values = {}
Values.__index = Values

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
--- @field value string|integer|number|boolean|nil The stored value
--- @field suffix string? Optional suffix for property display (e.g., " °C", " %")
--- @field deleted boolean? If true, the value slot is reserved but the variable is hidden (preserves ID ordering)

--- Creates a new Values instance.
--- @return Values values A new Values instance.
function Values:new()
  log:trace("Values:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- Updates a value. If the value does not exist, it will be created. If the
--- `name` is also a property, it will also be updated.
--- @param name string The name of the value to update or create. Must be globally unique.
--- @param value string|integer|number|boolean|nil The value to set, can be `nil`.
--- @param varType VariableType? The type of the variable, if `nil` it will not be registered as a variable.
--- @param varChangedCallback (fun(newValue: string|integer|number): void)? The callback function to be called when the variable changes.
--- @param propertySuffix string? Optional suffix to append to the property value (e.g., "°C" for temperature units).
--- @return boolean changed True if the value changed, false otherwise.
function Values:update(name, value, varType, varChangedCallback, propertySuffix)
  log:trace("Values:update(%s, %s, %s, %s, %s)", name, value, varType, varChangedCallback, propertySuffix)

  -- Convert value to appropriate type based on varType
  if varType == "BOOL" then
    value = toboolean(value)
  elseif varType == "DEVICE" or varType == "INT" or varType == "ROOM" then
    value = tointeger(value)
  elseif varType == "FLOAT" or varType == "NUMBER" then
    value = tonumber(value)
  else
    value = tostring(value)
  end

  local values = self:getValues()
  local existing = values[name]

  -- Check if the entry has changed
  local changed = not existing
    or existing.value ~= value
    or existing.suffix ~= propertySuffix
    or existing.varType ~= varType
  if changed then
    values[name] = {
      index = Select(values, name, "index") or self:_getNextValueId(),
      varType = varType,
      value = value,
      suffix = propertySuffix,
    }
    self:_saveValues(values)
  end

  local strValue = value == nil and "" or tostring(value)

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

  if Properties[name] ~= nil then
    -- Ensure the property is visible
    C4:SetPropertyAttribs(name, constants.SHOW_PROPERTY)

    -- Format property value with optional suffix
    local propValue = strValue
    if propertySuffix and strValue ~= "" then
      propValue = strValue .. propertySuffix
    end
    if Properties[name] ~= propValue then
      UpdateProperty(name, propValue, true)
    end
  end

  return changed
end

--- Deletes a value. The value is marked as deleted to preserve its index slot
--- for variable ID ordering. On next restore, a hidden placeholder will be created.
--- Trailing deleted values are trimmed since they don't affect subsequent IDs.
--- @param name string The name of the value to delete.
--- @return void
function Values:delete(name)
  log:trace("Values:delete(%s)", name)
  local values = self:getValues()
  if values[name] == nil then
    log:warn("Value %s does not exist; ignoring delete", name)
    return
  end

  log:debug("Deleting value %s at index %d", name, values[name].index)

  -- Mark as deleted to preserve the index slot for variable ID ordering
  values[name].deleted = true
  values[name].value = nil

  -- Trim trailing deleted values (they don't need placeholders)
  values = self:_trimDeletedTail(values)
  self:_saveValues(values)

  -- Remove the OVC handler and delete the variable
  OVC[ovcKey(name)] = nil
  if Variables[name] ~= nil then
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
--- @diagnostic disable-next-line: unused
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
--- Deleted values are restored as hidden placeholders to preserve
--- variable ID ordering for subsequent variables.
--- @return void
function Values:restoreValues()
  log:trace("Values:restoreValues()")
  local values = self:getValues()

  -- Build sorted array with names (table.sort doesn't work on string-keyed tables)
  local sorted = {}
  for name, value in pairs(values) do
    table.insert(sorted, { name = name, data = value })
  end
  table.sort(sorted, function(a, b)
    return a.data.index < b.data.index
  end)

  -- Restore in index order to preserve variable IDs
  for _, entry in ipairs(sorted) do
    if entry.data.deleted then
      -- Create a hidden placeholder variable to preserve the ID slot
      log:debug("Restoring hidden placeholder for deleted value %s at index %d", entry.name, entry.data.index)
      C4:AddVariable(entry.name, "", entry.data.varType or "STRING", true, true)
    else
      log:debug("Restoring %s value %s at index %d", entry.data.varType, entry.name, entry.data.index)
      self:update(entry.name, entry.data.value, entry.data.varType, nil, entry.data.suffix)
    end
  end
end

--- Saves the values to persistent storage.
--- @private
--- @param values table<string, Value>? The values table to save, nil clears storage.
--- @diagnostic disable-next-line: unused
function Values:_saveValues(values)
  log:trace("Values:_saveValues(%s)", values)
  persist:set(VALUES_PERSIST_KEY, not IsEmpty(values) and values or nil)
end

--- Retrieves the next available value ID. Always returns max(existing indices) + 1
--- to avoid reusing indices from deleted values (which would break ID ordering).
--- @private
--- @return number valueId The next available value ID starting from 1.
function Values:_getNextValueId()
  log:trace("Values:_getNextValueId()")
  local values = self:getValues()
  local maxIndex = 0
  for _, value in pairs(values) do
    if value.index > maxIndex then
      maxIndex = value.index
    end
  end
  return maxIndex + 1
end

--- Removes trailing deleted entries from the values table.
--- Deleted entries at the end don't need placeholders since there are no
--- subsequent variables whose IDs would be affected.
--- @private
--- @param values table<string, Value> The values table to trim.
--- @return table<string, Value> The trimmed values table.
--- @diagnostic disable-next-line: unused
function Values:_trimDeletedTail(values)
  -- Find the maximum index among non-deleted entries
  local maxActiveIndex = 0
  for _, value in pairs(values) do
    if not value.deleted and value.index > maxActiveIndex then
      maxActiveIndex = value.index
    end
  end

  -- Remove all deleted entries with index > maxActiveIndex
  local toRemove = {}
  for name, value in pairs(values) do
    if value.deleted and value.index > maxActiveIndex then
      table.insert(toRemove, name)
    end
  end

  for _, name in ipairs(toRemove) do
    log:debug("Trimming deleted tail entry %s", name)
    values[name] = nil
  end

  return values
end

--- Resets all values, removing variables from the system and clearing persisted storage.
function Values:reset()
  log:trace("Values:reset()")
  for name, value in pairs(self:getValues()) do
    log:debug("Removing value '%s'", name)
    -- Delete the variable if it exists
    if value.varType ~= nil and Variables[name] ~= nil then
      OVC[ovcKey(name)] = nil
      C4:DeleteVariable(name)
      Variables[name] = nil
    end
  end
  self:_saveValues(nil)
end

return Values:new()
