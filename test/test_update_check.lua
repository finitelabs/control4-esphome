--- Tests the ESPHome driver's automatic update check in each build. In the open-source build the
--- lowest-numbered ESPHome item checks GitHub every 30 minutes while Automatic Updates is On. The
--- DriverCentral build, whose updates come from the DriverCentral Cloud driver, has no such check.
--- In both builds every heartbeat tick tries to reconnect a device that is not connected.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_update_check.lua

local T = require("testlib")
local F = require("c4_fixtures")

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local deferred = require("deferred")
local ESPHomeClient = require("esphome.client")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DIR = HERE .. "/../drivers/esphome"
local ID = 12345

-- A clock the test steps; the driver reads it through os.time.
local now = 1000000
local realTime = os.time
os.time = function(date) -- luacheck: ignore
  return date and realTime(date) or now
end

local config
function C4:GetDriverConfigInfo(key)
  if key == "config" then
    return config
  elseif key == "version" then
    return "20261106"
  elseif key == "minimum_os_version" then
    return "3.3.0"
  end
  return "test"
end
function C4:GetVersionInfo()
  return { version = "4.3.0.763530-res" }
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:UpdatePropertyList() end
function C4:AddDynamicBinding() end

--- The ESPHome items in the project, by device id.
local items
function C4:GetDevicesByC4iName()
  return items
end

-- The device never answers: each connect attempt fails, so each tick that tries one counts.
local connects = 0
ESPHomeClient.connect = function()
  connects = connects + 1
  return deferred.new():reject("Connection refused")
end
ESPHomeClient.disconnect = function() end
ESPHomeClient.isConnected = function()
  return false
end
ESPHomeClient.isConfigured = function(self)
  return not IsEmpty(self._ipAddress)
end
ESPHomeClient.setConfig = function(self, ip)
  self._ipAddress = ip
  return self
end
ESPHomeClient.getFatalError = function()
  return nil
end

-- The DriverCentral build's license gate, holding a license.
local gate = {
  UNLICENSED_STATUS = "No active license",
  startClient = function() end,
  startGate = function() end,
  licensed = function()
    return true
  end,
}

--- When each named timer was last armed or fired, and its period.
local armedAt, delays = {}, {}
local realSetTimer = SetTimer
SetTimer = function(id, delay, fn, repeating) -- luacheck: ignore
  armedAt[id], delays[id] = now, delay
  return realSetTimer(id, delay, fn, repeating)
end

local function read(path)
  local f = assert(io.open(path))
  local body = f:read("*a")
  f:close()
  return body
end

-- The handlers the client and diagnostics wrap, put back before each load.
local pristine = {
  ExecuteCommand = ExecuteCommand,
  OnPropertyChanged = OnPropertyChanged,
  OnDriverDestroyed = OnDriverDestroyed,
}

local checks, errors
--- Load and start `build` of the driver as Director does, the device set but not answering.
--- @param build string "oss" or "drivercentral".
--- @param properties? table<string, string> Properties over the driver.xml defaults.
local function boot(build, properties)
  config = read(DIR .. "/driver.xml"):match("<config>(.*)</config>")
  for k in pairs(Properties) do
    Properties[k] = nil
  end
  for block in config:gmatch("<property>(.-)</property>") do
    Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
  Properties["IP Address"] = "192.0.2.10"
  Properties["Authentication Mode"] = "None"
  for k, v in pairs(properties or {}) do
    Properties[k] = v
  end
  for k, v in pairs(pristine) do
    _G[k] = v
  end
  UpdateDrivers = nil -- luacheck: ignore
  package.loaded["lib.drivercentral"] = build == "drivercentral" and gate or nil
  items = items or { [ID] = {} }
  F.dofileBuild(DIR .. "/driver.lua", build)
  OnDriverInit("DIT_ADDED")
  OnDriverLateInit("DIT_ADDED")
  checks, errors, connects = 0, {}, 0
  if UpdateDrivers then
    UpdateDrivers = function() -- luacheck: ignore
      checks = checks + 1
    end
  end
end

--- Step the clock `seconds` in 10 s ticks, firing the heartbeat and the update check when due.
local function run(seconds)
  for _ = 1, seconds / 10 do
    now = now + 10
    for _, name in ipairs({ "heartbeat", "UpdateCheck" }) do
      local handle = Timer[name]
      if handle and now - armedAt[name] >= delays[name] / 1000 then
        armedAt[name] = now
        local ok, err = pcall(TimerFunctions[handle], handle, 0)
        if not ok then
          errors[#errors + 1] = tostring(err)
        end
      end
    end
  end
end

T.section("The DriverCentral build runs no update check of its own")
do
  items = nil
  boot("drivercentral", { ["Automatic Updates"] = "On" })
  run(31 * 60)
  T.eq("31 minutes with Automatic Updates On raise nothing", errors, {})
  T.eq("and every tick tries to reconnect the device", connects, 31 * 6)
end

T.section("The open-source build's lowest-numbered item checks every 30 minutes")
do
  items = nil
  boot("oss", { ["Automatic Updates"] = "On" })
  run(29 * 60)
  T.eq("none in the first 29 minutes", checks, 0)
  run(2 * 60)
  T.eq("one by 31 minutes", checks, 1)
  run(30 * 60)
  T.eq("another by 61", checks, 2)
  T.eq("no errors", errors, {})
  T.eq("and every tick tries to reconnect the device, the check's included", connects, 61 * 6)
end

T.section("Another item, or Automatic Updates Off, checks nothing")
do
  items = { [ID] = {}, [ID - 1] = {} }
  boot("oss", { ["Automatic Updates"] = "On" })
  run(31 * 60)
  T.eq("an item that is not the lowest-numbered", checks, 0)

  items = nil
  boot("oss", { ["Automatic Updates"] = "Off" })
  run(31 * 60)
  T.eq("Automatic Updates Off", checks, 0)
end

T.finish()
