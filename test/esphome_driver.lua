--- Settings for the tests that load and start the real ESPHome device driver: its driver.xml
--- defaults with a device address set, and the handlers a load wraps put back first.
--- Require it after the drivers-common-public globals, so it keeps their handlers.

local M = {}

-- The handlers the client and diagnostics wrap, put back before each load so one load's client never wraps
-- another's.
local pristine = {
  ExecuteCommand = ExecuteCommand,
  OnPropertyChanged = OnPropertyChanged,
  OnDriverDestroyed = OnDriverDestroyed,
}

--- The whole of a file.
--- @param path string
--- @return string body
function M.read(path)
  local f = assert(io.open(path))
  local body = f:read("*a")
  f:close()
  return body
end

--- Set Properties to the driver.xml defaults in `dir`, with the device at a test address and no
--- authentication, then `overrides`; and put back the handlers an earlier load wrapped.
--- @param dir string The driver's directory.
--- @param overrides? table<string, string> Properties over the defaults.
--- @return string config The driver.xml <config> body, for C4:GetDriverConfigInfo("config").
function M.reset(dir, overrides)
  local config = M.read(dir .. "/driver.xml"):match("<config>(.*)</config>")
  for k in pairs(Properties) do
    Properties[k] = nil
  end
  for block in config:gmatch("<property>(.-)</property>") do
    Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
  Properties["IP Address"] = "192.0.2.10"
  Properties["Authentication Mode"] = "None"
  for k, v in pairs(overrides or {}) do
    Properties[k] = v
  end
  for k, v in pairs(pristine) do
    _G[k] = v
  end
  return config
end

return M
