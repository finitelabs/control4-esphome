--- A step an item runs once, at its first load that has the step, and never again.

local persist = require("lib.persist")

--- Run `step` unless this item ran it before under `key`.
--- @param key string The persist key that marks the step done.
--- @param step fun() The step.
--- @return boolean ran Whether the step ran now.
return function(key, step)
  if persist:get(key) then
    return false
  end
  step()
  persist:set(key, true)
  return true
end
