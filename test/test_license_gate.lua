-- The ESPHome device driver's DriverCentral build under the shared license gate, with the real vendored cloud
-- client answering a fake Cloud driver. One step is 10 s: the client's ping, the gate's read, then the heartbeat.
-- Without a license for five minutes the driver drops the device, tells its companions the device is suspended
-- (a light keeps its level) and sends nothing; a license reconnects it at the next heartbeat.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_gate.lua

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local cloud = require("dc_cloud")
local deferred = require("deferred")
local ESPHomeClient = require("esphome.client")
local driver = require("esphome_driver")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DIR = HERE .. "/../drivers/esphome"
local LIGHT_BINDING = 7001

local sent = {}
local config
function C4:GetDriverConfigInfo(key)
  if key == "config" then
    return config
  elseif key == "version" then
    return "20261104"
  elseif key == "minimum_os_version" then
    return "3.3.0"
  end
  return "test"
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:GetVersionInfo()
  return { version = "4.3.0.763530-res" }
end
function C4:UpdatePropertyList() end
function C4:AddDynamicBinding() end

-- The transport at the client's edges: connect() and sendMessage() are what reach the network.
local net = {}
ESPHomeClient.connect = function()
  net.connects = net.connects + 1
  net.connected = true
  return deferred.new():resolve()
end
ESPHomeClient.disconnect = function()
  net.connected = false
end
ESPHomeClient.isConnected = function()
  return net.connected
end
ESPHomeClient.isLogsSubscribed = function()
  return false
end
ESPHomeClient.isConfigured = function(self)
  return not IsEmpty(self._ipAddress)
end
ESPHomeClient.setConfig = function(self, ip)
  self:disconnect()
  self._ipAddress = ip
  return self
end
ESPHomeClient.getFatalError = function()
  return nil
end
ESPHomeClient.sendMessage = function()
  if not net.connected then
    return deferred.new():reject("Not connected to ESPHome device")
  end
  net.sends = net.sends + 1
  return deferred.new():resolve({})
end

--- The driver's DRIVERCENTRAL build, lines its directives leave out blanked, as preprocess.py makes it.
local function dcBuild(src)
  local out, stack, including = {}, {}, true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    local ifdef, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if ifdef then
      stack[#stack + 1] = including
      including = including and ((name == "DRIVERCENTRAL") == (ifdef == "ifdef"))
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    out[#out + 1] = including and line or ""
  end
  return table.concat(out, "\n")
end

local gate
--- Load and start the driver as Director does, with a light entity a companion can command.
--- @param prepare? fun() Runs before OnDriverInit.
local function boot(prepare)
  config = driver.reset(DIR)
  package.loaded["cloud-client-byte"] = nil
  package.loaded["lib.drivercentral"] = nil
  cloud.ping = nil
  net.connected, net.connects, net.sends = false, 0, 0
  assert(load(dcBuild(driver.read(DIR .. "/driver.lua")), "@" .. DIR .. "/driver.lua"))()
  SendToProxy = function(binding, command, params)
    sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
  end
  if prepare then
    prepare()
  end
  OnDriverInit("DIT_ADDED")
  OnDriverLateInit("DIT_ADDED")
  -- step() reads the gate before each heartbeat, so the order two timers fire in decides nothing.
  gate = require("lib.drivercentral")
  gate._timer:Cancel()
  local bindings = require("lib.bindings")
  bindings.getOrAddDynamicBinding = function()
    return { bindingId = LIGHT_BINDING }
  end
  bindings.getDynamicBindings = function()
    return { { bindingId = LIGHT_BINDING } }
  end
  local Light = require("esphome.entities.light")
  local light = Light:new(ESPHomeClient:new())
  light.client = setmetatable({}, { __index = ESPHomeClient })
  light:discovered({ ref = "kitchen", name = "Kitchen", key = 1 })
  sent = {}
end

--- `n` steps of 10 s.
local function step(n)
  for _ = 1, n or 1 do
    if cloud.ping then
      cloud.poll(1)
    end
    gate:_check()
    TimerFunctions[Timer.heartbeat](Timer.heartbeat, 0)
  end
end

--- Steps until the device is dropped, at most `max`.
local function stepsToDrop(max)
  for i = 1, max do
    step()
    if not net.connected then
      return i
    end
  end
end

--- Whether a companion's light command reaches the device.
local function lightCommand()
  local before = net.sends
  ReceivedFromProxy(
    LIGHT_BINDING,
    "ENTITY_COMMAND",
    { command = "light_command", body = SerializeSafe({ state = true }) }
  )
  return net.sends > before
end

--- How many companions were told the device is suspended.
local function suspendedNotices()
  local n = 0
  for _, s in ipairs(sent) do
    if s.command == "UPDATE_DISCONNECT" and s.params.suspended then
      n = n + 1
    end
  end
  return n
end

T.section("A licensed install or a trial keeps its device")
do
  cloud.present, cloud.silent = true, false
  cloud.answer = { AC = 1, AS = "License Activated" }
  boot()
  step()
  T.eq("licensed: DC_X", DC_X, 1)
  T.check("licensed: connected", net.connected)
  T.check("licensed: a companion's light command is sent", lightCommand())
  step(40)
  T.check("licensed: still connected after 400 s", net.connected)
  T.eq("licensed: connected once", net.connects, 1)
  cloud.answer = { AC = -720, AS = "Trial Running, 30 Days Remaining" }
  boot()
  step(40)
  T.eq("trial: DC_X is the hours left", DC_X, -720)
  T.check("trial: still connected", net.connected)
end

T.section("A Cloud driver that answers four minutes into a boot drops nothing")
do
  cloud.answer = { AC = 1, AS = "License Activated" }
  cloud.silent = true
  boot()
  step(24)
  T.eq("DC_X while it is quiet", DC_X, 0)
  T.check("connected", net.connected)
  cloud.silent = false
  step(40)
  T.check("connected after it answers", net.connected)
  T.eq("connected once", net.connects, 1)
end

T.section("Without a license the device is dropped after five minutes and nothing reaches it")
do
  cloud.answer = { AC = 0, AS = "Invalid License" }
  boot()
  T.eq("steps from the load to the drop", stepsToDrop(40), 30)
  T.eq("Driver Status", Properties["Driver Status"], "No active license")
  T.eq("Cloud Status", Properties["Cloud Status"], "Invalid License")
  T.check("companions told the device is suspended, so a light keeps its level", suspendedNotices() > 0)
  T.falsy("a companion's light command does not reach the device", lightCommand())
  local connects = net.connects
  step(60)
  T.eq("no reconnect in ten more minutes", net.connects, connects)
  Properties["IP Address"] = "192.0.2.11"
  OnPropertyChanged("IP Address")
  T.eq("an IP Address change does not reconnect", net.connects, connects)
  sent = {}
  ReceivedFromProxy(LIGHT_BINDING, "REFRESH_STATE", {})
  T.eq("a companion's REFRESH_STATE is told suspended", suspendedNotices(), 1)
  cloud.say({ AC = 1, AS = "License Activated" })
  step()
  T.check("a purchase reconnects at the next heartbeat", net.connected)
  T.check("and a light command is sent again", lightCommand())
end

T.section("A trial that expires while running drops the device five minutes later")
do
  cloud.answer = { AC = -1, AS = "Trial Running, 1 Hours Remaining" }
  boot()
  step(2)
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  T.eq("steps from the expiry to the drop", stepsToDrop(40), 30)
end

T.section("A Cloud driver update rides through")
do
  cloud.answer = { AC = 1, AS = "License Activated" }
  boot()
  step(3)
  -- The old Cloud driver tells every client 0 as it goes, and the new one is quiet until it has loaded.
  cloud.say({ AC = 0, AS = "Cloud driver removed, please install cloud driver." })
  cloud.silent = true
  step(3)
  cloud.silent = false
  step(40)
  T.check("still connected", net.connected)
  T.eq("never dropped", net.connects, 1)
end

T.section("A Cloud driver gone quiet drops the device 30 reads after the client gives up, and an answer brings it back")
do
  cloud.answer = { AC = 1, AS = "License Activated" }
  boot()
  step(3)
  cloud.silent = true
  T.eq("steps of silence before the drop", stepsToDrop(60), 35)
  T.eq("Cloud Status", Properties["Cloud Status"], "DriverCentral.io Cloud driver not found")
  cloud.silent = false
  step()
  T.check("back at the first answer", net.connected)
end

T.section("A client that never starts leaves DC_X nil, and the device runs")
do
  cloud.answer = { AC = 0, AS = "Invalid License" }
  boot(function()
    Properties["Cloud Status"] = nil
  end)
  step(40)
  T.eq("DC_X", DC_X, nil)
  T.check("connected", net.connected)
end

T.finish()
