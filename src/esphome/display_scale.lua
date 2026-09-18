--- Effective thermostat display scale, resolved from Director.
---
--- The thermostatV2 proxy owns the display scale as a variable on the proxy
--- item, so a Navigator change lands there whether or not SET_SCALE reaches the
--- driver, and the choice outlives a driver reload with nothing stored here.

require("lib.utils") -- TemperatureScaleLetter
require("drivers-common-public.global.handlers") -- RegisterVariableListener

local M = {}

--- The proxy's SCALE variable. C4:GetDeviceVariable rejects the name with
--- "idVariable should be a number", so it is addressed by numeric id.
M.SCALE_VARIABLE = 1100

--- An untouched proxy holds the bare letter "F"; the proxy rewrites it to the
--- whole word ("CELSIUS"/"FAHRENHEIT") once a scale is actually chosen, whether
--- by Navigator or by this driver's own SCALE_CHANGED. A one-letter value
--- therefore means nobody has chosen yet, not Fahrenheit.
--- @param value string|nil The raw variable value.
--- @return string|nil letter "C"/"F", or nil when no scale has been chosen.
local function chosenScaleLetter(value)
  if type(value) ~= "string" or #value <= 1 then
    return nil
  end
  return TemperatureScaleLetter(value)
end

--- The proxy item this driver drives, read off the binding rather than assumed
--- from the driver's own device id.
--- @param proxyBinding integer The driver's proxy binding id.
--- @return integer|nil idProxy
function M.proxyDeviceId(proxyBinding)
  return (next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), proxyBinding) or {}))
end

--- Resolve the scale to display in: the proxy's chosen scale, else the
--- project's, else Fahrenheit.
--- @param proxyBinding integer The driver's proxy binding id.
--- @return string letter "C" or "F".
function M.resolve(proxyBinding)
  local idProxy = M.proxyDeviceId(proxyBinding)
  local chosen
  if idProxy ~= nil then
    chosen = chosenScaleLetter(C4:GetDeviceVariable(idProxy, M.SCALE_VARIABLE))
  end
  return chosen or TemperatureScaleLetter(C4:GetTemperatureScale()) or "F"
end

--- Call back when the proxy's scale changes, so a Navigator change is seen
--- without relying on SET_SCALE.
--- @param proxyBinding integer The driver's proxy binding id.
--- @param callback function Receives (idDevice, idVariable, strValue).
--- @return void
function M.watch(proxyBinding, callback)
  local idProxy = M.proxyDeviceId(proxyBinding)
  if idProxy == nil then
    return
  end
  RegisterVariableListener(idProxy, M.SCALE_VARIABLE, callback)
end

return M
