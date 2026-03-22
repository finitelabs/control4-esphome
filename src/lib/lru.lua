--- This module provides an LRU (Least Recently Used) cache implementation in Lua.
--- Adapted from https://github.com/kenshinx/Lua-LRU-Cache

--- A simple LRU cache implementation.
--- @class LRUCache<K,V>
--- @field _max_size number|nil Maximum items to store, nil for no limit.
--- @field _ttl number|nil Time-to-live in seconds, nil for no expiration.
--- @field _values table<K,V> Table storing cache values.
--- @field _ttl_times table<K,number> Table storing expiration times.
--- @field _access_times table<K,number> Table storing last access times.
local LRUCache = {}
LRUCache.__index = LRUCache

--- Creates a new LRU cache instance
--- @param max_size? number Maximum items to store, nil for no limit.
--- @param ttl? number Time-to-live in seconds, nil for no expiration.
--- @return LRUCache<K,V>
function LRUCache:new(max_size, ttl)
  local instance = setmetatable({}, self)
  instance._max_size = max_size
  instance._ttl = ttl
  instance._values = {}
  instance._ttl_times = {}
  instance._access_times = {}
  return instance
end

--- Gets a value from the cache.
--- @param key K The key to look up.
--- @return V|nil value The cached value or nil if not found/expired.
function LRUCache:get(key)
  local time = os.time()
  self:cleanup()
  if self._values[key] ~= nil then
    self._access_times[key] = time
    return self._values[key]
  else
    return nil
  end
end

--- Gets a value from the cache or returns default if not found.
--- @param key K The key to look up.
--- @param default? V The default value if key not found.
--- @return V|nil value The cached value or default.
--- @overload fun(key: K, default: V): V
function LRUCache:getOrDefault(key, default)
  local value = self:get(key)
  if value == nil then
    return default
  end
  return value
end

--- Gets a value from cache or sets it using callback if not found
--- @param key K The key to look up
--- @param callback (fun(key: K): V) Function to generate value if not found
--- @return V value The cached or newly generated value
function LRUCache:getOrSet(key, callback)
  local value = self:get(key)
  if value == nil then
    value = callback(key)
    self:set(key, value)
  end
  return value
end

--- Sets a value in the cache
--- @param key K The key to set
--- @param value V The value to cache
function LRUCache:set(key, value)
  local time = os.time()
  self._values[key] = value
  self._ttl_times[key] = time + (self._ttl or 0)
  self._access_times[key] = time
  self:cleanup()
end

--- Removes a key from the cache
--- @param key K The key to remove
function LRUCache:remove(key)
  self._values[key] = nil
  self._ttl_times[key] = nil
  self._access_times[key] = nil
end

--- Cleans up expired and excess items from cache
function LRUCache:cleanup()
  -- remove expired items
  if self._ttl ~= nil then
    local time = os.time()
    for k, v in pairs(self._ttl_times) do
      if v < time then
        self:remove(k)
      end
    end
  end

  if self._max_size == nil then
    return
  end
  local current_size = LRUCache.__len(self)
  if current_size <= self._max_size then
    return
  end

  -- sort as the access time
  local sorted_array = {}
  for k, v in pairs(self._access_times) do
    table.insert(sorted_array, { key = k, access = v })
  end
  table.sort(sorted_array, function(a, b)
    return a.access < b.access
  end)

  -- remove oldest item
  for _, oldest in pairs(sorted_array) do
    self:remove(oldest.key)
    current_size = current_size - 1
    if current_size <= self._max_size then
      return
    end
  end
end

--- String representation of cached keys
--- @return string
function LRUCache:__tostring()
  local s = "{"
  local sep = ""
  for k, _ in pairs(self._values) do
    s = s .. sep .. k
    sep = ","
  end
  return s .. "}"
end

--- Gets number of items in cache
--- @return number count Number of cached items
function LRUCache:__len()
  local count = 0
  for _ in pairs(self._values) do
    count = count + 1
  end
  return count
end

return LRUCache
