--- Tests that turning on a characteristic's notifications writes its CCCD
--- before the subscriber hears it is subscribed, through a direct proxy and
--- through the coordinator. ESPHome leaves that write to the API client on V3
--- connections; without it a Yale lock never answers its key exchange and
--- drops the link.
---
--- Runs the real ESPHome client and the bluetooth_proxy capability with only
--- the wire stubbed: requests are recorded, responses injected.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_notify_cccd.lua

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
local RPC = ESPHomeProtoSchema.RPC.APIConnection

local NOTIFY_HANDLE = 121
local CCCD_HANDLE = 122
local PLAIN_HANDLE = 119

--- A service with one notifying characteristic that has a CCCD, and one that
--- does not notify.
local SERVICES = {
  {
    uuid = { 1, 2 },
    handle = 118,
    characteristics = {
      { uuid = { 3, 4 }, handle = PLAIN_HANDLE, properties = 0x08 },
      {
        uuid = { 5, 6 },
        handle = NOTIFY_HANDLE,
        properties = 0x10,
        descriptors = { { short_uuid = 0x2902, handle = CCCD_HANDLE } },
      },
    },
  },
}

function C4:SetTimer()
  local timer = {}
  function timer:Cancel() end
  return timer
end

local requests
local sent

local function reset()
  requests = {}
  sent = {}
  SendToProxy = function(binding, command, params)
    table.insert(sent, { binding = binding, command = command, params = params or {} })
  end
end

--- A client whose requests go nowhere, with the device's link up.
local function newClient()
  local client = ESPHomeClient:new()
  client.callServiceMethod = function(_, method, body)
    table.insert(requests, { method = method, body = body })
    return deferred.new()
  end
  client._btConnections = { free = 2, limit = 3, allocated = { MAC }, initialized = true }
  return client
end

local function answer(client, schema, message)
  message.address = ADDRESS
  client:_invokeCallback(schema.id, message, schema)
end

local function descriptorWrites()
  local out = {}
  for _, r in ipairs(requests) do
    if r.method == RPC.bluetooth_gatt_write_descriptor then
      table.insert(out, r.body)
    end
  end
  return out
end

local function subscribedAnswers()
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == "GATT_NOTIFY_SUBSCRIBED" then
      table.insert(out, s)
    end
  end
  return out
end

local function notifyConfirmed(client, handle)
  answer(client, Message.BluetoothGATTNotifyResponse, { handle = handle })
end

local function descriptorWritten(client)
  answer(client, Message.BluetoothGATTWriteResponse, { handle = CCCD_HANDLE })
end

--------------------------------------------------------------------------------
-- Through the coordinator
--------------------------------------------------------------------------------

local function coordinatorProxy(client)
  local proxy = BluetoothProxyCapability:new(client)
  proxy._coordinatorBindingId = COORDINATOR_BINDING
  return proxy
end

--- The coordinator's connect, answered with SERVICES.
local function coordinatorConnected(client, proxy)
  client._btConnections.allocated = {}
  proxy:handleCoordinatorCommand("GATT_CONNECT", { mac = MAC, requestId = "r1" })
  answer(client, Message.BluetoothDeviceConnectionResponse, { connected = true, mtu = 247 })
  client._btConnections.allocated = { MAC }
  answer(client, Message.BluetoothGATTGetServicesResponse, { services = SERVICES })
  answer(client, Message.BluetoothGATTGetServicesDoneResponse, {})
end

local function coordinatorNotify(proxy, handle)
  proxy:handleCoordinatorCommand(
    "GATT_NOTIFY",
    { mac = MAC, handle = tostring(handle), enable = "true", requestId = "r2" }
  )
end

T.section("coordinator: a subscription writes the CCCD before it is answered")
do
  reset()
  local client = newClient()
  local proxy = coordinatorProxy(client)
  coordinatorConnected(client, proxy)
  coordinatorNotify(proxy, NOTIFY_HANDLE)
  notifyConfirmed(client, NOTIFY_HANDLE)

  local writes = descriptorWrites()
  T.eq("one descriptor write", #writes, 1)
  T.eq("to the CCCD", writes[1] and writes[1].handle, CCCD_HANDLE)
  T.eq("turning notifications on", writes[1] and writes[1].data, "\1\0")
  T.eq("not answered before the write is", #subscribedAnswers(), 0)

  descriptorWritten(client)
  local answers = subscribedAnswers()
  T.eq("answered once written", #answers, 1)
  T.eq("as a success", answers[1] and answers[1].params.success, "true")
  T.eq("to the coordinator", answers[1] and answers[1].binding, COORDINATOR_BINDING)
end

T.section("coordinator: a failed CCCD write still answers")
do
  reset()
  local client = newClient()
  local proxy = coordinatorProxy(client)
  coordinatorConnected(client, proxy)
  coordinatorNotify(proxy, NOTIFY_HANDLE)
  notifyConfirmed(client, NOTIFY_HANDLE)
  answer(client, Message.BluetoothGATTErrorResponse, { handle = CCCD_HANDLE, error = 3 })
  T.eq("answered", #subscribedAnswers(), 1)
end

T.section("coordinator: a characteristic without a CCCD is answered at once")
do
  reset()
  local client = newClient()
  local proxy = coordinatorProxy(client)
  coordinatorConnected(client, proxy)
  coordinatorNotify(proxy, PLAIN_HANDLE)
  notifyConfirmed(client, PLAIN_HANDLE)
  T.eq("no descriptor write", #descriptorWrites(), 0)
  T.eq("answered", #subscribedAnswers(), 1)
end

T.section("coordinator: services from a released link are not reused")
do
  reset()
  local client = newClient()
  local proxy = coordinatorProxy(client)
  coordinatorConnected(client, proxy)
  proxy:handleCoordinatorCommand("GATT_DISCONNECT", { mac = MAC })
  coordinatorNotify(proxy, NOTIFY_HANDLE)
  notifyConfirmed(client, NOTIFY_HANDLE)
  T.eq("no descriptor write from the old link's services", #descriptorWrites(), 0)
end

--------------------------------------------------------------------------------
-- Through a direct proxy
--------------------------------------------------------------------------------

T.section("direct: a subscription writes the CCCD before the child hears it")
do
  reset()
  local client = newClient()
  local proxy = BluetoothProxyCapability:new(client)
  proxy._addedDevices[MAC] =
    { mac = MAC, name = "Lock", bindingId = DEVICE_BINDING, addressType = 0, passive = false, services = SERVICES }
  proxy:handleCommand(MAC, DEVICE_BINDING, "GATT_NOTIFY", { handle = tostring(NOTIFY_HANDLE), enable = "true" }, {})
  notifyConfirmed(client, NOTIFY_HANDLE)

  local writes = descriptorWrites()
  T.eq("one descriptor write", #writes, 1)
  T.eq("to the CCCD", writes[1] and writes[1].handle, CCCD_HANDLE)
  T.eq("not answered before the write is", #subscribedAnswers(), 0)

  descriptorWritten(client)
  local answers = subscribedAnswers()
  T.eq("answered once written", #answers, 1)
  T.eq("to the child", answers[1] and answers[1].binding, DEVICE_BINDING)
end

T.section("direct: without cached services the child is answered at once")
do
  reset()
  local client = newClient()
  local proxy = BluetoothProxyCapability:new(client)
  proxy._addedDevices[MAC] = { mac = MAC, name = "Lock", bindingId = DEVICE_BINDING, addressType = 0, passive = false }
  proxy:handleCommand(MAC, DEVICE_BINDING, "GATT_NOTIFY", { handle = tostring(NOTIFY_HANDLE), enable = "true" }, {})
  notifyConfirmed(client, NOTIFY_HANDLE)
  T.eq("no descriptor write", #descriptorWrites(), 0)
  T.eq("answered", #subscribedAnswers(), 1)
end

T.finish()
