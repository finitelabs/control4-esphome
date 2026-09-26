-- Driver loads for the lib/values tests: a driver update or a Director restart on
-- the c4_shim Director, then a fresh lib/values restoring in OnDriverInit.

require("c4_shim")
require("drivers-common-public.global.lib") -- Deserialize
require("drivers-common-public.global.handlers") -- OVC

local T = require("testlib")

local H = {}

--- Every variable lib/values added or deleted in the current load, as "Add B->1002", "Delete #1002".
H.calls = {}

local realAddVariable = C4.AddVariable
local realDeleteVariable = C4.DeleteVariable

local function describe(identifier)
  return type(identifier) == "number" and ("#" .. identifier) or tostring(identifier)
end

function C4:AddVariable(identifier, ...)
  local ok, id = realAddVariable(self, identifier, ...)
  table.insert(H.calls, "Add " .. describe(identifier) .. "->" .. tostring(ok and id))
  return ok, id
end

function C4:DeleteVariable(identifier)
  table.insert(H.calls, "Delete " .. describe(identifier))
  return realDeleteVariable(self, identifier)
end

--- A driver load after `how`, "update" or "restart", that restores its values.
function H.load(how)
  if how == "restart" then
    ShimRestartDirector()
  else
    ShimUpdateDriver()
  end
  H.calls = {}
  T.unload("^lib%.persist$", "^lib%.values$")
  local values = require("lib.values")
  values:restoreValues()
  -- The DriverWorks docs say not to call DeleteVariable in OnDriverInit, where restore runs.
  if H.called("^Delete") then
    T.check("restore deletes no variable (" .. how .. ")", false, table.concat(H.calls, ", "))
  end
  return values
end

--- A clean install: no variables and no stored values.
function H.wipe()
  ShimRestartDirector()
  C4:PersistDeleteValue("Values")
end

--- This device's variables as id -> { name, hidden }.
function H.variables()
  local out = {}
  for id, variable in pairs(C4:GetDeviceVariables(C4:GetDeviceID())) do
    out[tonumber(id)] = { name = variable.name, hidden = variable.hidden == "True" }
  end
  return out
end

--- This device's variables as id -> "name", or "name(h)" for a hidden one.
function H.layout()
  local out = {}
  for id, variable in pairs(H.variables()) do
    out[id] = variable.name .. (variable.hidden and "(h)" or "")
  end
  return out
end

--- name -> id of every visible variable.
function H.visible()
  local out = {}
  for id, variable in pairs(H.variables()) do
    if not variable.hidden then
      out[variable.name] = id
    end
  end
  return out
end

--- The stored values, decoded.
function H.blob()
  local raw = C4:PersistGetValue("Values")
  return raw and Deserialize(raw) or {}
end

--- Whether any call in this load matches the Lua pattern.
function H.called(pattern)
  for _, call in ipairs(H.calls) do
    if call:match(pattern) then
      return true
    end
  end
  return false
end

return H
