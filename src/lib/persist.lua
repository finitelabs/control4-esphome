--- @module "lib.persist"
--- A persistence utility module for storing and retrieving values with optional encryption.
--- This module provides a simple key-value store interface with caching capabilities.
local log = require("lib.logging")

--- A utility class for storing and retrieving values from the controller's persistence store.
--- @class Persist
--- @field _persist table<string, any> A table to store the cached values.
local Persist = {}

--- Sentinel representing an empty value in the persistence store.
--- @type table
local EMPTY = {}

--- Creates a new instance of the Persist class.
--- @return Persist persist A new instance of the Persist class.
function Persist:new()
  log:trace("Persist:new()")
  local properties = {
    _persist = {},
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties Persist
  return properties
end

--- Retrieves a value from the persistence store.
--- @param key string The key to retrieve the value for.
--- @param default? any The default value to return if the key doesn't exist (optional).
--- @param encrypted? boolean Whether the value is encrypted (optional).
--- @return any value The retrieved value, or the default if the key doesn't exist.
function Persist:get(key, default, encrypted)
  log:trace("Persist:get(%s, %s, %s)", key, default, encrypted)
  if default == nil then
    default = EMPTY
  end
  local value = self._persist[key]

  if value == nil then
    value = Deserialize(PersistGetValue(key, encrypted))
    if value == nil then
      value = default
    end
    self._persist[key] = value
  end

  if value == EMPTY or value == nil then
    return default
  elseif type(value) == "table" then
    return TableDeepCopy(value)
  else
    return value
  end
end

--- Sets a value in the persistence store.
--- @param key string The key to set the value for.
--- @param value any The value to store. If nil, the key will be deleted.
--- @param encrypted? boolean Whether to encrypt the value (optional).
--- @return void
function Persist:set(key, value, encrypted)
  log:trace("Persist:set(%s, %s, %s)", key, value, encrypted)
  if value == nil then
    self._persist[key] = EMPTY
    PersistDeleteValue(key)
  else
    if type(value) == "table" then
      self._persist[key] = TableDeepCopy(value)
    else
      self._persist[key] = value
    end
    PersistSetValue(key, Serialize(self._persist[key]), encrypted)
  end
end

--- Deletes a value from the persistence store.
--- @param key string The key to delete.
--- @return void
function Persist:delete(key)
  log:trace("Persist:delete(%s)", key)
  self:set(key, nil)
end

return Persist:new()
