--- Values module for managing dynamic values with variable and property support.

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.handlers")
require("lib.utils")

--- @class Values
--- @field _callbacks table<string, function?> In-memory registry of OVC callbacks keyed by variable name.
--- @field _byId boolean Whether variables are added at their ids in this load.
--- @field _rejected table<string, boolean> Names Director would not give a variable in this load.
--- @field _placeholders table<integer, string> The name of each hidden variable Director listed in this load, by id.
--- A class representing a collection of named values with optional variable/property support.
local Values = {}
Values.__index = Values

--- Persistent storage key for values.
--- @type string
local VALUES_PERSIST_KEY = "Values"

--- The id Director gives a device's first variable.
--- @type integer
local FIRST_VARIABLE_ID = 1001

--- How many ids a new variable tries before giving up.
--- @type integer
local MAX_ID_TRIES = 100

--- Reserved name prefix, followed by the record's index, under which an older
--- build's placeholder for a plain value keeps its id slot.
--- @type string
local LEGACY_PLACEHOLDER_PREFIX = "__deleted__"

--- Whether restore adds a visible variable for this record.
local function isVariable(record)
  return record ~= nil and record.varType ~= nil and not record.deleted
end

--- What C4:SetVariable and C4:DeleteVariable take for a value's variable: the name
--- Director knows it by, so a stale id cannot reach another variable, or else its id,
--- as Director reads a name like "1001" as an id.
local function variableKey(name, id)
  return (Variables[name] == nil or tonumber(name) ~= nil) and id or name
end

local function ovcKey(name)
  -- Convert the name to a valid OVC variable name by replacing spaces with underscores
  return string.gsub(name, "%s+", "_")
end

--- Equality for a stored value. Differs from `==` only for NaN, which is never
--- equal to itself: a driver republishing an unknown reading would otherwise
--- report a change on every push and rewrite persistent storage each time.
local function sameValue(a, b)
  return a == b or (a ~= a and b ~= b)
end

--- @class Value
--- @field index integer Index used for ordering values during restore.
--- @field id integer? The Director id of the value's variable, kept once it has had one.
--- @field varType VariableType? Optional variable type if registered as a variable
--- @field value string|integer|number|boolean|nil The stored value
--- @field suffix string? Optional suffix for property display (e.g., " °C", " %")
--- @field writable boolean? Whether the variable accepts writes from programming. Persisted so restore can recreate the C4 variable with the correct readOnly flag.
--- @field deleted boolean? If true, the value has no variable now; its record keeps its id, if it has one

--- Deleting a plain value in an older build left a deleted record, which restore
--- by name adds as a hidden placeholder. Each such slot moves to a name built from
--- its index, which no other record has, so a later value of the old name cannot take it.
--- @param values table<string, Value> The values table, changed in place.
--- @return boolean moved True if any record moved.
local function moveLegacyPlaceholders(values)
  local legacy = {}
  for name, value in pairs(values) do
    if value.deleted and value.varType == nil then
      table.insert(legacy, name)
    end
  end
  for _, name in ipairs(legacy) do
    values[name].varType = "STRING"
    values[string.format("%s%d", LEGACY_PLACEHOLDER_PREFIX, values[name].index)] = values[name]
    values[name] = nil
  end
  return #legacy > 0
end

--- Creates a new Values instance.
--- @return Values values A new Values instance.
function Values:new()
  log:trace("Values:new()")
  local instance = setmetatable({}, self)
  instance._callbacks = {}
  instance._byId = false
  instance._rejected = {}
  instance._placeholders = {}
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
---   * `nil`      - no change; any previously registered callback/writable
---                  state is left alone. This is what 3-arg callers get.
---   * `false`    - clears the callback (equivalent to
---                  `setCallback(name, nil)`), marking the variable read-only.
---   * `true`     - registers a no-op placeholder callback so the variable is
---                  writable from C4 programming. No change-notification path;
---                  the driver observes updates by reading `Variables[name]`.
---   * function   - registers the callback (equivalent to
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
    or existing.deleted
    or not sameValue(existing.value, value)
    or existing.suffix ~= propertySuffix
    or existing.varType ~= varType
    or existing.writable ~= writable
  if changed then
    values[name] = {
      index = Select(values, name, "index") or self:_getNextValueId(),
      id = Select(values, name, "id"),
      varType = varType,
      value = value,
      suffix = propertySuffix,
      writable = writable,
    }
  end
  local record = values[name]

  -- C4 BOOL variables expect "0"/"1", not "true"/"false".
  local strValue
  if value == nil then
    strValue = ""
  elseif type(value) == "boolean" then
    strValue = value and "1" or "0"
  else
    strValue = tostring(value)
  end

  local idChanged = false
  if varType ~= nil then
    if Variables[name] ~= nil and not isVariable(existing) and record.id ~= nil then
      -- An older build's hidden placeholder for the name gives way to it
      C4:DeleteVariable(variableKey(name, record.id))
      Variables[name] = nil
    end
    if Variables[name] == nil then
      idChanged = self:_addVariable(values, name, record, strValue)
    elseif Variables[name] ~= strValue then
      C4:SetVariable(variableKey(name, record.id), strValue)
    end
  elseif Variables[name] ~= nil then
    OVC[ovcKey(name)] = nil
    self._callbacks[name] = nil
    C4:DeleteVariable(variableKey(name, record.id))
    Variables[name] = nil
  end

  if changed or idChanged then
    -- A change to which variables exist, or to an id, is written now even under write-behind,
    -- so a restart restores this set; a lost new variable would give its id to another.
    self:_saveValues(values, idChanged or isVariable(existing) ~= (varType ~= nil))
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

--- Deletes a value. A value that has had a variable is marked as deleted, and its
--- record keeps the variable's id for when the name comes back; a value that never
--- had one is removed.
--- @param name string The name of the value to delete.
--- @return void
function Values:delete(name)
  log:trace("Values:delete(%s)", name)
  local values = self:getValues()
  local value = values[name]
  if value == nil then
    log:debug("Value %s does not exist; ignoring delete", name)
    return
  end

  log:debug("Deleting value %s at index %d", name, value.index)

  local wasVariable = isVariable(value)
  -- A plain value with no id goes, unless a load by name on OS 4.0+ keeps it for the next restart's order
  if value.varType == nil and value.id == nil and (self._byId or C4.SetVariableName == nil) then
    values[name] = nil
  else
    value.deleted = true
    value.value = nil
  end
  self:_saveValues(values, wasVariable)

  -- Remove the OVC handler and delete the variable
  OVC[ovcKey(name)] = nil
  self._callbacks[name] = nil
  if Variables[name] ~= nil then
    C4:DeleteVariable(variableKey(name, value.id))
    Variables[name] = nil
  end

  if Properties[name] ~= nil then
    UpdateProperty(name, "", true)
    -- The best we can do to delete a property is to hide it
    C4:SetPropertyAttribs(name, constants.HIDE_PROPERTY)
  end
end

--- Opts the values in to write-behind (see lib.persist): an update made inside
--- `persist:defer()` reaches storage at most once per `ms`, unless it adds or
--- removes a variable.
--- @param ms number The flush interval in milliseconds.
--- @return void
function Values:setWriteBehind(ms)
  log:trace("Values:setWriteBehind(%s)", ms)
  persist:setWriteBehind(VALUES_PERSIST_KEY, ms)
end

--- Writes any update still waiting under write-behind to storage now.
--- @return void
function Values:flush()
  log:trace("Values:flush()")
  persist:flush(VALUES_PERSIST_KEY)
end

--- Retrieves all values from persistent storage.
--- @return table<string, Value> values A table of all values mapped by their name.
--- @diagnostic disable-next-line: unused
function Values:getValues()
  log:trace("Values:getValues()")
  local values = persist:get(VALUES_PERSIST_KEY, {})
  -- Stored values that do not read back as a table start over rather than fail every load
  return type(values) == "table" and values or {}
end

--- Retrieves a value by name.
--- @param name string The name of the value to retrieve.
--- @return Value|nil value The value associated with the name, or nil if it does not exist.
function Values:getValue(name)
  log:trace("Values:getValue(%s)", name)
  return Select(self:getValues(), name)
end

--- Restores all values from persistent storage. Programming binds to a
--- variable's id, so with C4.SetVariableName (OS 4.0+) each variable is added at
--- the id its record keeps and then named. At a driver update each record first
--- takes its variable's id from Director, by name; after a Director restart, a
--- record an older build wrote without an id takes the id that build's restore
--- gives it. Without C4.SetVariableName, variables are added by name in index
--- order, with hidden placeholders for deleted values, as older builds did.
---
--- Call this from OnDriverInit: programming attached to variables added
--- after OnDriverInit may not work after a Director restart.
--- @return void
function Values:restoreValues()
  log:trace("Values:restoreValues()")
  local values = self:getValues()
  -- With a rename a record holds its slot itself, by its id or its place in the next restart's order
  if C4.SetVariableName == nil and moveLegacyPlaceholders(values) then
    self:_saveValues(values, true)
  end
  self._byId = self:_learnIds(values)

  -- Build sorted array with names (table.sort doesn't work on string-keyed tables)
  local sorted = {}
  for name, value in pairs(values) do
    if not (value.deleted and self._byId) then
      table.insert(sorted, { name = name, data = value })
    end
  end
  table.sort(sorted, function(a, b)
    return a.data.index < b.data.index
  end)

  -- Restore in index order to preserve variable IDs
  for _, entry in ipairs(sorted) do
    local ok, err = pcall(function()
      if entry.data.deleted then
        -- Create a hidden placeholder variable to preserve the ID slot
        log:debug("Restoring hidden placeholder for deleted value %s at index %d", entry.name, entry.data.index)
        C4:AddVariable(entry.name, "", entry.data.varType or "STRING", true, true)
      else
        log:debug("Restoring %s value %s at index %d", entry.data.varType, entry.name, entry.data.index)
        self:update(entry.name, entry.data.value, entry.data.varType, nil, entry.data.suffix)
      end
    end)
    if not ok then
      log:error("Failed to restore value %s: %s", entry.name, err)
    end
  end
end

--- Saves the values to persistent storage.
--- @private
--- @param values table<string, Value>? The values table to save, nil clears storage.
--- @param durable boolean? Write to storage now even under write-behind.
--- @diagnostic disable-next-line: unused
function Values:_saveValues(values, durable)
  log:trace("Values:_saveValues(%s, %s)", values, durable)
  persist:set(VALUES_PERSIST_KEY, not IsEmpty(values) and values or nil)
  if durable then
    persist:flush(VALUES_PERSIST_KEY)
  end
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

--- Retrieves the next variable id: one above every id a record keeps, deleted
--- ones included, so a name that comes back finds its id free.
--- @private
--- @param values table<string, Value> The values table.
--- @return integer variableId The next variable id, from FIRST_VARIABLE_ID.
function Values:_getNextVariableId(values)
  log:trace("Values:_getNextVariableId()")
  local maxId = FIRST_VARIABLE_ID - 1
  for _, value in pairs(values) do
    if value.id ~= nil and value.id > maxId then
      maxId = value.id
    end
  end
  return maxId + 1
end

--- Adds the variable for a value. With ids, it is added at the id its record
--- keeps, or at the next variable id, and then named, and the record takes the
--- id. Without, it is added by name.
--- @private
--- @param values table<string, Value> The values table the record is in.
--- @param name string The name of the value.
--- @param value Value The value's record.
--- @param strValue string The variable's value.
--- @return boolean changed True if the record's id changed.
function Values:_addVariable(values, name, value, strValue)
  log:trace("Values:_addVariable(%s, %s)", name, strValue)
  local readOnly = not value.writable
  if not self._byId then
    C4:AddVariable(name, strValue, value.varType, readOnly, false)
    return false
  elseif self._rejected[name] or name == "" then
    return false -- Director keeps a variable renamed to "" under its number
  end

  local id = value.id
  local placeholder = self._placeholders[id]
  if placeholder ~= nil and Variables[placeholder] ~= nil and not isVariable(values[placeholder]) then
    -- An older build put another deleted name's hidden placeholder at this id; it holds no programming
    C4:DeleteVariable(variableKey(placeholder, id))
    Variables[placeholder] = nil
  end
  if id ~= nil and not C4:AddVariable(id, strValue, value.varType, readOnly, false) then
    log:warn("Variable id %d of %s is taken; it gets a new one", id, name)
    id = nil
  end
  if id == nil then
    local first = self:_getNextVariableId(values)
    for candidate = first, first + MAX_ID_TRIES - 1 do
      if C4:AddVariable(candidate, strValue, value.varType, readOnly, false) then
        id = candidate
        break
      end
    end
  end
  if id == nil or not C4:SetVariableName(id, name) then
    log:error("Director would not add variable %s", name)
    if id ~= nil then
      C4:DeleteVariable(id)
    end
    -- Not tried again in this load, or every update would add and delete a variable
    self._rejected[name] = true
    return false
  end

  local changed = value.id ~= id
  value.id = id
  return changed
end

--- Whether variables are added at their ids in this load. A record takes the id of
--- its visible variable in Director's list; with no id, that of its hidden one, and
--- with no variable either, the id an older build's restore gives it.
--- @private
--- @param values table<string, Value> The values table, which takes the ids.
--- @return boolean byId True if variables are added at their ids.
function Values:_learnIds(values)
  log:trace("Values:_learnIds()")
  if C4.SetVariableName == nil then
    return false
  end

  local restarted, variables = next(Variables) == nil, {}
  if not restarted then
    -- The DriverWorks docs advise against this call in OnDriverInit, where restore runs, so its list is checked
    local ok, list = pcall(C4.GetDeviceVariables, C4, C4:GetDeviceID())
    variables = ok and type(list) == "table" and list or {}
    local listed = {}
    for _, variable in pairs(variables) do
      listed[variable.name] = true
    end
    -- A list that leaves out a variable the driver has is not current. The recorded ids
    -- stand, and with none this load adds variables by name, as the older build did.
    for name in pairs(Variables) do
      if not listed[name] then
        log:warn("Could not read this device's variables from Director; no id is learned in this load")
        return self:_getNextVariableId(values) > FIRST_VARIABLE_ID
      end
    end
  end

  -- The older build's restore order, from before any record takes an id
  local order = {}
  for name, value in pairs(values) do
    if value.varType ~= nil or value.deleted then
      table.insert(order, name)
    end
  end
  table.sort(order, function(a, b)
    return values[a].index < values[b].index
  end)

  -- Each variable keeps its id, under a deleted record of its name if no record has one
  local changed = false
  for id, variable in pairs(variables) do
    local value = values[variable.name] or { index = tonumber(id), deleted = true }
    local recorded = value.id
    if value.deleted and value.varType ~= nil and variable.hidden == "False" then
      value.deleted = nil -- the older build deleted it, then added it again
      changed = true
    end
    if variable.hidden == "True" then
      -- An older build's placeholder holds no programming, so a record's own id stands over it
      self._placeholders[tonumber(id)] = variable.name
      value.id = value.id or tonumber(id)
    else
      value.id = tonumber(id)
    end
    changed = changed or value.id ~= recorded
    values[variable.name] = value
  end

  -- A deleted record's id is taken though Director has no variable at it
  local taken = {}
  for _, value in pairs(values) do
    if value.id ~= nil then
      taken[value.id] = true
    end
  end

  -- A name deleted in the older build's last load has no variable to learn from, and after a restart no name has.
  -- One with no id takes the id that build's restore gives it, counting from the first id, if free.
  for rank, name in ipairs(order) do
    local value, id = values[name], FIRST_VARIABLE_ID + rank - 1
    if value.id == nil and not taken[id] then
      value.id = id
      taken[id] = true
      changed = true
    end
  end
  if changed then
    self:_saveValues(values, true)
  end
  return true
end

--- Resets all values, removing their variables. A value that has had a variable
--- keeps a deleted record with its id for when it comes back.
function Values:reset()
  log:trace("Values:reset()")
  local values = self:getValues()
  for name, value in pairs(values) do
    log:debug("Removing value '%s'", name)
    -- Delete the variable if it exists
    if value.varType ~= nil and Variables[name] ~= nil then
      OVC[ovcKey(name)] = nil
      C4:DeleteVariable(variableKey(name, value.id))
      Variables[name] = nil
    end
    values[name] = value.id ~= nil and { index = value.index, id = value.id, deleted = true } or nil
  end
  self._callbacks = {}
  self:_saveValues(values, true)
end

return Values:new()
