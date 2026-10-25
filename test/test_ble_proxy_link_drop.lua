--- Tests that a proxy reports a closed link to whoever holds it: the bound
--- device for a direct link, the coordinator for a link the coordinator made.
--- A link the coordinator asked to close is not reported again.
---
--- Runs the real ESPHome client and the bluetooth_proxy capability with only
--- the wire stubbed: requests are recorded, responses injected.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_proxy_link_drop.lua

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local deferred = require("deferred")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local ESPHomeClient = require("esphome.client")
local BluetoothProxyCapability = require("esphome.capabilities.bluetooth_proxy")
local BLEAddress = require("esphome.ble.address")

local MAC = "AA:BB:CC:DD:EE:FF"
local ADDRESS = BLEAddress.fromString(MAC)
local COORDINATOR_BINDING = 6001
local DEVICE_BINDING = 5013
local Message = ESPHomeProtoSchema.Message

function C4:SetTimer()
  local timer = {}
  function timer:Cancel() end
  return timer
end

local sent

local function reset()
  sent = {}
  SendToProxy = function(binding, command, params)
    table.insert(sent, { binding = binding, command = command, params = params or {} })
  end
end

local function newClient()
  local client = ESPHomeClient:new()
  client.callServiceMethod = function()
    return deferred.new()
  end
  client._btConnections = { free = 3, limit = 3, allocated = {}, initialized = true }
  return client
end

local function answer(client, schema, message)
  message.address = ADDRESS
  client:_invokeCallback(schema.id, message, schema)
end

local function newProxy(client)
  local proxy = BluetoothProxyCapability:new(client)
  proxy._updateStatusProperty = function() end
  return proxy
end

local function slots(proxy, connected)
  proxy:_onConnectionSlots({ free = connected and 2 or 3, limit = 3, allocated = connected and { MAC } or {} })
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

--- A link the coordinator made, with its services discovered.
local function coordinatorLink()
  local client = newClient()
  local proxy = newProxy(client)
  proxy._coordinatorBindingId = COORDINATOR_BINDING
  proxy:handleCoordinatorCommand("GATT_CONNECT", { mac = MAC, requestId = "r1" })
  answer(client, Message.BluetoothDeviceConnectionResponse, { connected = true, mtu = 247 })
  client._btConnections.allocated = { MAC }
  answer(client, Message.BluetoothGATTGetServicesResponse, { services = { { uuid = { 1, 2 }, handle = 10 } } })
  answer(client, Message.BluetoothGATTGetServicesDoneResponse, {})
  slots(proxy, true)
  return proxy
end

T.section("a coordinator link that closes is reported to the coordinator")
do
  reset()
  local proxy = coordinatorLink()
  slots(proxy, false)
  local reports = sentTo(COORDINATOR_BINDING, "GATT_DISCONNECTED")
  T.eq("one report", #reports, 1)
  T.eq("for the device", reports[1] and reports[1].params.mac, MAC)
  T.eq("saying the link closed", reports[1] and reports[1].params.reason, "BLE connection closed")
  T.truthy("naming this proxy", reports[1] and reports[1].params.proxyId ~= nil)
end

T.section("a coordinator link it asked to close is not reported")
do
  reset()
  local proxy = coordinatorLink()
  proxy:handleCoordinatorCommand("GATT_DISCONNECT", { mac = MAC })
  slots(proxy, false)
  T.eq("no report", #sentTo(COORDINATOR_BINDING, "GATT_DISCONNECTED"), 0)
end

T.section("a coordinator link is reported once")
do
  reset()
  local proxy = coordinatorLink()
  slots(proxy, false)
  slots(proxy, false)
  T.eq("one report", #sentTo(COORDINATOR_BINDING, "GATT_DISCONNECTED"), 1)
end

T.section("a direct link that closes still reaches the bound device")
do
  reset()
  local client = newClient()
  local proxy = newProxy(client)
  proxy._coordinatorBindingId = COORDINATOR_BINDING
  proxy._addedDevices[MAC] = { mac = MAC, name = "Lock", bindingId = DEVICE_BINDING, addressType = 0, passive = false }
  slots(proxy, true)
  slots(proxy, false)
  T.eq("the device hears DISCONNECTED", #sentTo(DEVICE_BINDING, "DISCONNECTED"), 1)
  T.eq("the coordinator hears nothing", #sentTo(COORDINATOR_BINDING, "GATT_DISCONNECTED"), 0)
end

T.finish()
