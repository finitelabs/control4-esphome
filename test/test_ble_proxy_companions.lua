--- Tests what a Bluetooth proxy tells the drivers bound to its devices: that the ESPHome connection closed,
--- the full service list of a device whose link is up, and the state a driver asks for with REFRESH_STATE.
---
--- Runs the real ESPHome client and the bluetooth_proxy capability with only the wire stubbed: requests are
--- recorded, responses injected.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_proxy_companions.lua

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local deferred = require("deferred")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local ESPHomeClient = require("esphome.client")
local BluetoothProxyCapability = require("esphome.capabilities.bluetooth_proxy")
local BLEAddress = require("esphome.ble.address")

local LOCK, SENSOR = "AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02"
local LOCK_BINDING, SENSOR_BINDING, COORDINATOR_BINDING = 5013, 5014, 6001
local Message = ESPHomeProtoSchema.Message
local SERVICES = { { uuid = { 1, 2 }, handle = 10, characteristics = {} } }

function C4:SetTimer()
  local timer = {}
  function timer:Cancel() end
  return timer
end

-- Each binding of a device here has a driver bound to it.
function C4:GetBoundConsumerDevices()
  return { [900] = "Bound Driver" }
end

local sent

local function reset()
  sent = {}
  SendToProxy = function(binding, command, params)
    table.insert(sent, { binding = binding, command = command, params = params or {} })
  end
end

--- A client whose ESPHome connection is up, with the lock's link allocated.
local function newClient()
  local client = ESPHomeClient:new()
  client.callServiceMethod = function()
    return deferred.new()
  end
  client.isConnected = function(self)
    return self._up
  end
  client.initBluetoothProxy = function()
    return deferred.new():resolve()
  end
  client._up = true
  client._btConnections = { free = 2, limit = 3, allocated = { LOCK }, initialized = true }
  return client
end

--- A proxy with the lock (active, its link up) and a sensor (passive) added and bound.
local function newProxy(client, lockServices)
  local proxy = BluetoothProxyCapability:new(client)
  proxy._updateStatusProperty = function() end
  proxy._addedDevices[LOCK] = {
    name = "Lock",
    deviceType = "Yale Lock",
    bindingId = LOCK_BINDING,
    addressType = 0,
    passive = false,
    services = lockServices,
  }
  proxy._addedDevices[SENSOR] =
    { name = "Sensor", deviceType = "BTHome", bindingId = SENSOR_BINDING, addressType = 0, passive = true }
  proxy._previousAllocated = { [LOCK] = true }
  return proxy
end

local function sentTo(binding, command)
  local out = {}
  for _, s in ipairs(sent) do
    if s.binding == binding and s.command == command then
      table.insert(out, s)
    end
  end
  return out
end

--- How many services the last CONNECTED to the lock carried, or nil if none was sent.
local function lockServiceCount()
  local connected = sentTo(LOCK_BINDING, "CONNECTED")
  local last = connected[#connected]
  return last and #(DeserializeSafe(last.params.services) or {})
end

--- Run one case; a throw is one failed check, not the end of the run.
local function case(name, fn)
  T.section(name)
  local ok, err = pcall(fn)
  T.check("ran without throwing", ok, err)
end

case("the ESPHome connection closing tells each bound device once", function()
  reset()
  local client = newClient()
  local proxy = newProxy(client, SERVICES)
  client._up = false
  proxy:disconnected()
  T.eq("the lock hears DISCONNECTED", #sentTo(LOCK_BINDING, "DISCONNECTED"), 1)
  T.eq("so does the sensor", #sentTo(SENSOR_BINDING, "DISCONNECTED"), 1)
  T.eq(
    "saying the ESPHome device is gone",
    Select(sentTo(SENSOR_BINDING, "DISCONNECTED"), 1, "params", "reason"),
    "ESPHome device disconnected"
  )
  T.eq("the lock's services are dropped with its link", proxy._addedDevices[LOCK].services, nil)

  proxy:_onConnectionSlots({ free = 3, limit = 3, allocated = {} })
  T.eq("the first slot report after it does not tell the lock again", #sentTo(LOCK_BINDING, "DISCONNECTED"), 1)
end)

case("the ESPHome connection closing tells the coordinator the proxy is gone", function()
  reset()
  local proxy = BluetoothProxyCapability:new(newClient())
  proxy._updateStatusProperty = function() end
  proxy._coordinatorConnected = true
  proxy._coordinatorBindingId = COORDINATOR_BINDING
  proxy:disconnected()
  local told = sentTo(COORDINATOR_BINDING, "PROXY_DISCONNECTED")
  T.eq("the coordinator hears PROXY_DISCONNECTED", #told, 1)
  T.eq("naming this proxy", Select(told, 1, "params", "proxyId"), tostring(C4:GetDeviceID()))
end)

case("a refresh hands a device whose link is up its full service list", function()
  reset()
  local proxy = newProxy(newClient(), SERVICES)
  proxy:discovered({ bluetooth_proxy_feature_flags = 1 })
  T.eq("the lock hears CONNECTED with its services", lockServiceCount(), 1)
end)

case("a device whose link is up with no services cached has them discovered before CONNECTED", function()
  reset()
  local client = newClient()
  local proxy = newProxy(client, nil)
  proxy:onBindingChanged(LOCK_BINDING, true)
  T.eq("no CONNECTED before the services are known", lockServiceCount(), nil)
  local address = BLEAddress.fromString(LOCK)
  client:_invokeCallback(
    Message.BluetoothGATTGetServicesResponse.id,
    { address = address, services = SERVICES },
    Message.BluetoothGATTGetServicesResponse
  )
  client:_invokeCallback(
    Message.BluetoothGATTGetServicesDoneResponse.id,
    { address = address },
    Message.BluetoothGATTGetServicesDoneResponse
  )
  T.eq("then CONNECTED with them", lockServiceCount(), 1)
end)

case("a device's REFRESH_STATE gets what a bind gives it", function()
  reset()
  local client = newClient()
  local proxy = newProxy(client, SERVICES)
  RFP[SENSOR_BINDING] = nil
  proxy:handleCommand(SENSOR, SENSOR_BINDING, "REFRESH_STATE", {}, {})
  T.eq("the sensor hears CONNECTED_PASSIVE", #sentTo(SENSOR_BINDING, "CONNECTED_PASSIVE"), 1)
  proxy:handleCommand(LOCK, LOCK_BINDING, "REFRESH_STATE", {}, {})
  T.eq("the lock hears CONNECTED with its services", lockServiceCount(), 1)

  reset()
  client._up = false
  proxy:handleCommand(SENSOR, SENSOR_BINDING, "REFRESH_STATE", {}, {})
  T.eq("with the ESPHome device gone, the sensor hears DISCONNECTED", #sentTo(SENSOR_BINDING, "DISCONNECTED"), 1)
  T.eq("and no CONNECTED_PASSIVE", #sentTo(SENSOR_BINDING, "CONNECTED_PASSIVE"), 0)
end)

T.finish()
