--- Values module for managing dynamic values with variable and property support.

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")

--- @class Values
--- @field _callbacks table<string, function?> In-memory registry of OVC callbacks keyed by variable name.
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
--- @field writable boolean? Whether the variable accepts writes from programming. Persisted so restore can recreate the C4 variable with the correct readOnly flag.
--- @field deleted boolean? If true, the value slot is reserved but the variable is hidden (preserves ID ordering)

--- Creates a new Values instance.
--- @return Values values A new Values instance.
function Values:new()
  log:trace("Values:new()")
  local instance = setmetatable({}, self)
  instance._callbacks = {}
  return instance
end

--- Register (or clear) the OnVariableChanged callback for a variable. Callback
--- wiring is managed independently of value updates so that inbound state
--- changes never accidentally clear an entity's programming handler.
---
--- Persists the writable flag so future restores recreate the C4 variable with
--- the correct readOnly state. Does NOT delete/recreate an already-created C4
--- variable, since that would orphan any programming attached to it; flipping
--- writable on an existing variable takes effect on the next restart.
--- @param name string The variable name.
--- @param callback (fun(newValue: string|integer|number): void)? The callback, or nil to clear.
function Values:setCallback(name, callback)
  log:trace("Values:setCallback(%s, %s)", name, callback)

  self._callbacks[name] = callback

  OVC[ovcKey(name)] = callback
      and function(newValue)
        log:debug("Variable %s changed to %s", name, newValue)
        callback(newValue)
      end
    or nil

  local values = self:getValues()
  local existing = values[name]
  if existing == nil then
    return
  end

  local desiredWritable = (callback ~= nil)
  if existing.writable ~= desiredWritable then
    existing.writable = desiredWritable
    self:_saveValues(values)
  end
end

--- Updates a value. If the value does not exist, it will be created. If the
--- `name` is also a property, it will also be updated.
---
--- The `callbackOrWritable` argument (arg 4) controls callback wiring and
--- writability. It is dispatched by type:
---
---   * `nil`      — no change; any previously registered callback/writable
---                  state is left alone. This is what 3-arg callers get.
---   * `false`    — clears the callback (equivalent to
---                  `setCallback(name, nil)`), marking the variable read-only.
---   * `true`     — registers a no-op placeholder callback so the variable is
---                  writable from C4 programming. No change-notification path;
---                  the driver observes updates by reading `Variables[name]`.
---   * function   — registers the callback (equivalent to
---                  `setCallback(name, fn)`) and marks the variable writable.
---
--- When a function (or `true`) is passed, `setCallback` runs before the C4
--- variable is created on this call, so a newly-created variable comes up
--- writable on the very first call. For existing variables, flipping
--- writability takes effect on the next restart (see `setCallback`).
---
--- @param name string The name of the value to update or create. Must be globally unique.
--- @param value string|integer|number|boolean|nil The value to set, can be `nil`.
--- @param varType VariableType? The type of the variable, if `nil` it will not be registered as a variable.
--- @param callbackOrWritable (fun(newValue: string|integer|number): void)|boolean|nil Callback to register, `true` for writable-with-placeholder, `false` to clear, or `nil` for no change.
--- @param propertySuffix string? Optional suffix to append to the property value (e.g., "°C" for temperature units).
--- @return boolean changed True if the value changed, false otherwise.
function Values:update(name, value, varType, callbackOrWritable, propertySuffix)
  log:trace("Values:update(%s, %s, %s, %s, %s)", name, value, varType, callbackOrWritable, propertySuffix)

  if type(callbackOrWritable) == "function" then
    self:setCallback(name, callbackOrWritable)
  elseif callbackOrWritable == true then
    self:setCallback(name, function() end)
  elseif callbackOrWritable == false then
    self:setCallback(name, nil)
  end

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

  -- Writable iff a callback is currently registered, or the persisted record
  -- already says so (lets restore recreate the C4 variable correctly before
  -- items have a chance to re-register their callbacks).
  local writable = self._callbacks[name] ~= nil or (existing and existing.writable) or false

  -- Check if the entry has changed
  local changed = not existing
    or existing.value ~= value
    or existing.suffix ~= propertySuffix
    or existing.varType ~= varType
    or existing.writable ~= writable
  if changed then
    values[name] = {
      index = Select(values, name, "index") or self:_getNextValueId(),
      varType = varType,
      value = value,
      suffix = propertySuffix,
      writable = writable,
    }
    self:_saveValues(values)
  end

  -- C4 BOOL variables expect "0"/"1", not "true"/"false".
  local strValue
  if value == nil then
    strValue = ""
  elseif type(value) == "boolean" then
    strValue = value and "1" or "0"
  else
    strValue = tostring(value)
  end

  if varType ~= nil then
    if Variables[name] == nil then
      C4:AddVariable(name, strValue, varType, not writable, false)
    elseif Variables[name] ~= strValue then
      C4:SetVariable(name, strValue)
    end
  elseif Variables[name] ~= nil then
    OVC[ovcKey(name)] = nil
    self._callbacks[name] = nil
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
  self._callbacks[name] = nil
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
  self._callbacks = {}
  self:_saveValues(nil)
end

return Values:new()
