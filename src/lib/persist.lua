--- A persistence utility module for storing and retrieving values with optional encryption.
--- This module provides a simple key-value store interface with caching capabilities.
---
--- ## Migrations
---
--- Persist supports one-time data migrations between driver versions. This is useful when the
--- structure of persisted data needs to change (e.g., converting integer keys to string keys).
---
--- To define migrations, create a `src/migrations.lua` file that returns a table mapping persist
--- keys to migration functions:
---
--- ```lua
--- -- src/migrations.lua
--- return {
---   ["MyData"] = function(value)
---     -- transform value from old format to new format
---     return transformedValue
---   end,
--- }
--- ```
---
--- Migrations are loaded automatically on the first `get()` call via `pcall(require, "migrations")`.
--- Each migration runs once per key, transforms the value, persists the result, and removes itself.
--- If no `migrations.lua` file exists, persist operates normally with no migrations.

local log = require("lib.logging")

--- A utility class for storing and retrieving values from the controller's persistence store.
--- @class Persist
--- @field _persist table<string, any> A table to store the cached values.
local Persist = {}
Persist.__index = Persist

--- Sentinel representing an empty value in the persistence store.
--- @type table
local EMPTY = {}

--- Migration functions loaded from the driver's `migrations.lua` module.
--- Populated lazily on first get() call. Each entry maps a persist key to a function that
--- transforms the old value format into the new format.
--- @type table<string, fun(value: any): any>
local MIGRATIONS = {}

--- Whether migrations have been loaded from the driver's migrations module.
--- @type boolean
local migrationsLoaded = false

--- Creates a new instance of the Persist class.
--- @return Persist persist A new instance of the Persist class.
function Persist:new()
  log:trace("Persist:new()")
  local instance = setmetatable({}, self)
  instance._persist = {}
  return instance
end

--- Loads driver-specific migrations from `migrations.lua` if present.
--- Called automatically on first get(). Safe to call multiple times (no-op after first call).
--- @private
local function loadMigrations()
  if migrationsLoaded then
    return
  end
  migrationsLoaded = true
  local ok, m = pcall(require, "migrations")
  if ok and type(m) == "table" then
    for key, fn in pairs(m) do
      MIGRATIONS[key] = fn
    end
  end
end

--- Retrieves a value from the persistence store.
--- On first call, loads any driver-specific migrations from `migrations.lua`.
--- If a migration exists for the requested key, it runs once, persists the transformed value,
--- and removes itself.
--- @param key string The key to retrieve the value for.
--- @param default? any The default value to return if the key doesn't exist (optional).
--- @param encrypted? boolean Whether the value is encrypted (optional).
--- @return any value The retrieved value, or the default if the key doesn't exist.
function Persist:get(key, default, encrypted)
  log:trace("Persist:get(%s, %s, %s)", key, default, encrypted)
  loadMigrations()
  local value = self:_get(key, default, encrypted)

  if type(MIGRATIONS[key]) == "function" then
    value = MIGRATIONS[key](value)
    MIGRATIONS[key] = nil
    self:set(key, value, encrypted)
  end

  return value
end

--- Internal get implementation with caching.
--- @private
--- @param key string The key to retrieve.
--- @param default any The default value if key is not found.
--- @param encrypted boolean? Whether the value is encrypted.
--- @return any value The retrieved value or default.
function Persist:_get(key, default, encrypted)
  log:trace("Persist:_get(%s, %s, %s)", key, default, encrypted)
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

--- Resets/clears specified keys from the persistence store.
--- @param keys string[] Array of keys to delete.
--- @return void
function Persist:reset(keys)
  log:trace("Persist:reset(%s)", keys)
  for _, key in ipairs(keys) do
    self:delete(key)
  end
end

return Persist:new()
