--- Values named after an ESPHome entity. The device names them, so a name can match one of
--- the driver's own settings, such as wifi_info's "IP Address"; these never write that setting.

local values = require("lib.values")

local EntityValues = {}

--- A same-named property is left alone, here and when the value is restored or deleted.
local LEAVE_PROPERTY = { property = false }

--- Update or create an entity's value, as lib.values does, without touching a same-named property.
--- @param name string The value's name.
--- @param value string|integer|number|boolean|nil The value to set.
--- @param varType VariableType? The variable's type, or nil for no variable.
--- @param callbackOrWritable (fun(newValue: string|integer|number): void)|boolean|nil As lib.values.
--- @return boolean changed True if the value itself changed.
--- @return boolean recordChanged True if anything stored for it changed.
function EntityValues.update(name, value, varType, callbackOrWritable)
  return values:update(name, value, varType, callbackOrWritable, nil, LEAVE_PROPERTY)
end

return EntityValues
