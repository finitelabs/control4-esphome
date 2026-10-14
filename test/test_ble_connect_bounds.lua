--- Tests that one BLE connect through a proxy is answered within 60s: 30s to
--- connect and 30s for GATT discovery. The child drivers' 200s connect timeouts
--- assume that bound, three times over for the coordinator's failover.
---
--- Runs the real ESPHome client and the bluetooth_proxy capability on a virtual
--- clock, with only the wire stubbed: requests are recorded, responses injected.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_connect_bounds.lua

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
local Message = ESPHomeProtoSchema.Message
local RPC = ESPHomeProtoSchema.RPC.APIConnection

-- Virtual clock: timers fire only when advance() moves time past them.
local now = 0
local timers = {}

function C4:SetTimer(delay, callback, repeating)
  local timer = { due = now + delay, callback = callback, repeating = repeating, delay = delay }
  function timer:Cancel()
    self.cancelled = true
  end
  table.insert(timers, timer)
  return timer
end

local function advance(ms)
  local target = now + ms
  while true do
    local nextTimer
    for _, timer in ipairs(timers) do
      if not timer.cancelled and timer.due <= target and (not nextTimer or timer.due < nextTimer.due) then
        nextTimer = timer
      end
    end
    if not nextTimer then
      break
    end
    now = nextTimer.due
    if nextTimer.repeating then
      nextTimer.due = now + nextTimer.delay
    else
      nextTimer.cancelled = true
    end
    nextTimer.callback(nextTimer, 0)
  end
  now = target
end

local function armed()
  local n = 0
  for _, timer in ipairs(timers) do
    if not timer.cancelled then
      n = n + 1
    end
  end
  return n
end

local requests
local sent

local function reset()
  now = 0
  timers = {}
  requests = {}
  sent = {}
  SendToProxy = function(binding, command, params)
    table.insert(sent, { binding = binding, command = command, params = params or {}, at = now })
  end
end

--- A client whose requests go nowhere, with `free` connection slots of 3.
local function newClient(free)
  local client = ESPHomeClient:new()
  client.callServiceMethod = function(_, method, body)
    table.insert(requests, { method = method, body = body, at = now })
    return deferred.new()
  end
  client._btConnections = { free = free or 3, limit = 3, allocated = {}, initialized = true }
  return client
end

local function count(method)
  local n = 0
  for _, r in ipairs(requests) do
    if r.method == method then
      n = n + 1
    end
  end
  return n
end

local DISCONNECT = ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT

local function deviceRequests(disconnect)
  local n = 0
  for _, r in ipairs(requests) do
    if r.method == RPC.bluetooth_device_request and (r.body.request_type == DISCONNECT) == disconnect then
      n = n + 1
    end
  end
  return n
end

local function connects()
  return deviceRequests(false)
end

local function disconnects()
  return deviceRequests(true)
end

local function answer(client, schema, message)
  message.address = ADDRESS
  client:_invokeCallback(schema.id, message, schema)
end

--- ESPHome's connection answer. proto3 drops false and 0 on the wire, so a
--- `connected = false` with error 0 decodes the same as an in-progress answer.
local function connectionResponse(client, connected)
  answer(client, Message.BluetoothDeviceConnectionResponse, { connected = connected, mtu = connected and 247 or nil })
end

local function servicesDone(client)
  answer(client, Message.BluetoothGATTGetServicesResponse, { services = { { uuid = { 1, 2 }, handle = 10 } } })
  answer(client, Message.BluetoothGATTGetServicesDoneResponse, {})
end

--- Record how a deferred settles, and when.
local function watch(d)
  local outcome = {}
  d:next(function(value)
    outcome.resolved, outcome.value, outcome.at = true, value, now
  end, function(err)
    outcome.rejected, outcome.err, outcome.at = true, err, now
  end)
  return outcome
end

local function coordinatorProxy(client)
  local proxy = BluetoothProxyCapability:new(client)
  proxy._coordinatorBindingId = COORDINATOR_BINDING
  return proxy
end

local function coordinatorConnect(proxy)
  proxy:handleCoordinatorCommand("GATT_CONNECT", { mac = MAC, requestId = "r1" })
end

local function connectResponses()
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == "GATT_CONNECT_RESPONSE" then
      table.insert(out, s)
    end
  end
  return out
end

T.section("a connect answered only as in progress fails after 30s")
do
  reset()
  local client = newClient()
  local outcome = watch(client:bluetoothDeviceConnect(MAC, 0, false))
  advance(1000)
  connectionResponse(client, nil)
  advance(28999)
  T.falsy("still waiting just before 30s", outcome.rejected)
  advance(1)
  T.truthy("rejected at 30s", outcome.rejected)
  T.eq("measured from the request", outcome.at, 30000)
  T.eq("and tells the proxy to stop", disconnects(), 1)
end

T.section("a connect that succeeds leaves no timer to fire later")
do
  reset()
  local client = newClient()
  local outcome = watch(client:bluetoothDeviceConnect(MAC, 0, false))
  connectionResponse(client, nil)
  advance(5000)
  connectionResponse(client, true)
  T.truthy("resolved on the final answer", outcome.resolved)
  T.eq("no timer left armed", armed(), 0)
  advance(60000)
  T.falsy("and never rejected after", outcome.rejected)
end

T.section("a connect that fails leaves no timer to fire later")
do
  reset()
  local client = newClient()
  local outcome = watch(client:bluetoothDeviceConnect(MAC, 0, false))
  answer(client, Message.BluetoothDeviceConnectionResponse, { error = 133 })
  T.truthy("rejected on the failure", outcome.rejected)
  T.eq("no timer left armed", armed(), 0)
end

T.section("a connect fails at once when the proxy's connection drops")
do
  reset()
  local client = newClient()
  local outcome = watch(client:bluetoothDeviceConnect(MAC, 0, false))
  advance(1000)
  client:disconnect()
  T.truthy("rejected", outcome.rejected)
  T.eq("when the connection dropped", outcome.at, 1000)
end

T.section("discovery does not connect again when the slot list lags")
do
  reset()
  local client = newClient()
  watch(client:bluetoothGattGetServices(MAC))
  T.eq("no connect request", connects(), 0)
  T.eq("only the services request", count(RPC.bluetooth_gatt_get_services), 1)
end

T.section("coordinator: no free slot is answered at once")
do
  reset()
  local client = newClient(0)
  coordinatorConnect(coordinatorProxy(client))
  T.eq("no connect request", connects(), 0)
  local responses = connectResponses()
  T.eq("one GATT_CONNECT_RESPONSE", #responses, 1)
  T.eq("a failure", responses[1] and responses[1].params.success, "false")
  T.eq("saying why", responses[1] and responses[1].params.error, "No connection slots available")
  T.eq("for the request", responses[1] and responses[1].params.requestId, "r1")
end

T.section("coordinator: before the slot count is known, it connects")
do
  reset()
  local client = newClient(0)
  client._btConnections.initialized = false
  coordinatorConnect(coordinatorProxy(client))
  T.eq("it connects", connects(), 1)
  T.eq("and answers nothing yet", #connectResponses(), 0)
end

T.section("coordinator: a device already connected here does not need a free slot")
do
  reset()
  local client = newClient(0)
  client._btConnections.allocated = { MAC }
  coordinatorConnect(coordinatorProxy(client))
  T.eq("it connects", connects(), 1)
  T.eq("and answers nothing yet", #connectResponses(), 0)
end

T.section("coordinator: a connect answered only as in progress fails at 30s")
do
  reset()
  local client = newClient()
  coordinatorConnect(coordinatorProxy(client))
  connectionResponse(client, nil)
  advance(30000)
  local responses = connectResponses()
  T.eq("one GATT_CONNECT_RESPONSE", #responses, 1)
  T.eq("a failure", responses[1] and responses[1].params.success, "false")
  T.eq("at 30s", responses[1] and responses[1].at, 30000)
  T.eq("and tells the proxy to stop", disconnects(), 1)
end

T.section("coordinator: a slow connect then a silent discovery fails within 60s")
do
  reset()
  local client = newClient()
  coordinatorConnect(coordinatorProxy(client))
  advance(29900)
  connectionResponse(client, true)
  T.eq("discovery is asked for at once", count(RPC.bluetooth_gatt_get_services), 1)
  -- What would answer a second connect, had one been sent.
  advance(29900)
  connectionResponse(client, true)
  advance(60000)
  T.eq("one connect request in all", connects(), 1)
  local responses = connectResponses()
  T.eq("one GATT_CONNECT_RESPONSE", #responses, 1)
  T.eq("a failure", responses[1] and responses[1].params.success, "false")
  T.eq("at 59.9s", responses[1] and responses[1].at, 59900)
  T.eq("and releases the link", disconnects(), 1)
end

T.section("coordinator: a connect and discovery that complete answer with the services")
do
  reset()
  local client = newClient()
  coordinatorConnect(coordinatorProxy(client))
  advance(2000)
  connectionResponse(client, true)
  advance(1000)
  servicesDone(client)
  local responses = connectResponses()
  T.eq("one GATT_CONNECT_RESPONSE", #responses, 1)
  T.eq("a success", responses[1] and responses[1].params.success, "true")
  T.eq("with the services", responses[1] and #DeserializeSafe(responses[1].params.services), 1)
  advance(120000)
  T.eq("and nothing more later", #connectResponses(), 1)
end

T.section("direct: a slow connect then a silent discovery fails within 61s")
do
  reset()
  local client = newClient()
  local proxy = BluetoothProxyCapability:new(client)
  proxy._addedDevices[MAC] = { name = "Lock", addressType = 0, deviceType = "Yale", passive = false }
  proxy:handleCommand(MAC, 5001, "CONNECT", {}, {})
  advance(29900)
  connectionResponse(client, true)
  advance(29900)
  connectionResponse(client, true)
  advance(60000)
  T.eq("one connect request in all", connects(), 1)
  local failed
  for _, s in ipairs(sent) do
    if s.command == "CONNECTION_FAILED" and not failed then
      failed = s
    end
  end
  T.truthy("the child is told it failed", failed)
  T.eq("30s after discovery began", failed and failed.at, 60400)
end

T.finish()
