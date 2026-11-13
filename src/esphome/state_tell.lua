--- Tells contact and relay bindings their state. OPENED and CLOSED fire the bound
--- driver's programming, and ESPHome re-sends every state at each reconnect, so they
--- go out only for a real change, against the state told before (kept across loads);
--- anything else goes in the silent STATE_ form.

local persist = require("lib.persist")

--- @class StateTell
--- @field _key string The persist key holding the state last told per binding key.
--- @field _told table<string, boolean> The binding keys told this load.
local StateTell = {}
StateTell.__index = StateTell

--- Create a teller whose told states are kept under one persist key.
--- @param persistKey string The persist key, unique within the driver.
--- @return StateTell teller
function StateTell:new(persistKey)
  return setmetatable({ _key = persistKey, _told = {} }, self)
end

--- Tell a binding a state. A change from the state told before goes out as itself;
--- the first state this load that is not one goes out silently; a repeat goes out not at all.
--- @param key string A stable name for the binding.
--- @param bindingId number|nil The binding to tell; nil keeps the state without telling it.
--- @param state string "OPENED" or "CLOSED".
--- @return boolean changed Whether the state differs from the one told before.
function StateTell:tell(key, bindingId, state)
  local stored = persist:get(self._key, {})
  local before = stored[key]
  local changed = before ~= nil and before ~= state
  if bindingId ~= nil and (changed or not self._told[key]) then
    SendToProxy(bindingId, changed and state or "STATE_" .. state, {}, "NOTIFY")
  end
  self._told[key] = true
  if before ~= state then
    stored[key] = state
    persist:set(self._key, stored)
  end
  return changed
end

--- The state told before for one binding key.
--- @param key string A stable name for the binding.
--- @return string|nil state "OPENED", "CLOSED", or nil if none is kept.
function StateTell:state(key)
  return persist:get(self._key, {})[key]
end

--- Every state told before.
--- @return table<string, string> states By binding key.
function StateTell:states()
  return persist:get(self._key, {})
end

--- Take a state as the one told before, unless one is kept already.
--- @param key string A stable name for the binding.
--- @param state string "OPENED" or "CLOSED".
function StateTell:assume(key, state)
  local stored = persist:get(self._key, {})
  if stored[key] == nil then
    stored[key] = state
    persist:set(self._key, stored)
  end
end

--- Forget the state told for one binding key, this load and before.
--- @param key string A stable name for the binding.
function StateTell:forget(key)
  self._told[key] = nil
  local stored = persist:get(self._key, {})
  if stored[key] ~= nil then
    stored[key] = nil
    persist:set(self._key, stored)
  end
end

--- Turn the state told for one binding key the other way and tell it silently: the same reading
--- now reads the other way. Nothing happens for a key with no state kept.
--- @param key string A stable name for the binding.
--- @param bindingId number|nil The binding to tell; nil turns the state kept without telling it.
function StateTell:flip(key, bindingId)
  local stored = persist:get(self._key, {})
  local before = stored[key]
  if before == nil then
    return
  end
  local state = before == "OPENED" and "CLOSED" or "OPENED"
  stored[key] = state
  persist:set(self._key, stored)
  self._told[key] = true
  if bindingId ~= nil then
    SendToProxy(bindingId, "STATE_" .. state, {}, "NOTIFY")
  end
end

--- Forget what was told this load, so the next state is told again, silently unless it changed.
function StateTell:clear()
  self._told = {}
end

--- Forget every state told, this load and before (driver reset).
function StateTell:reset()
  self._told = {}
  persist:delete(self._key)
end

return StateTell
