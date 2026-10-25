--- Tests that the Bluetooth Coordinator tells a bound device when the proxy
--- holding its link reports that the link closed. A Yale lock that refuses its
--- key drops the link right after the key exchange; without this the driver
--- waited out its handshake timeout and never checked the Yale cloud for a key.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_coordinator_link_drop.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local persist = require("lib.persist")

H.use("esphome_bluetooth_coordinator")

local PROXY_BINDING = 5001
local SCANNER, OTHER_SCANNER = 101, 102
local MAC = "AA:BB:CC:DD:EE:01"

--- What the coordinator sent proxies with C4:SendToDevice.
local toDevices = {}
function C4:SendToDevice(deviceId, command, params)
  table.insert(toDevices, { deviceId = deviceId, command = command, params = params or {} })
end

local function lastRequestId(command)
  for i = #toDevices, 1, -1 do
    if toDevices[i].command == command then
      return toDevices[i].params.requestId
    end
  end
end

local function proxyConnected(proxy)
  OBC[PROXY_BINDING](PROXY_BINDING, "ESPHOME_BLUETOOTH", true, proxy, 1)
  H.rfp(PROXY_BINDING, "PROXY_CONNECTED", {
    proxyId = tostring(proxy),
    roomId = "20",
    roomName = "Kitchen",
    connectionSlots = "3",
    freeSlots = "3",
    featureFlags = "0",
  })
end

local function advertise(proxy, rssi)
  H.rfp(PROXY_BINDING, "BLE_ADVERTISEMENT", {
    proxyId = tostring(proxy),
    advertisement = SerializeSafe({ mac = MAC, rssi = rssi }),
  })
end

--- The lock's binding on the coordinator.
local function lockBinding()
  return bindings:getDynamicBinding("coordinator", "bt_" .. MAC:gsub(":", "")).bindingId
end

--- A coordinator with two proxies and a Yale lock, connected through SCANNER.
local function lockConnected()
  H.boot(nil, function()
    for _, name in ipairs({ "presence_tracker", "proxy_registry", "device_registry", "router" }) do
      package.loaded["esphome.ble.coordinator." .. name] = nil
    end
    persist:set("SelectedDevices", {
      [MAC] = {
        mac = MAC,
        name = "Front Door",
        deviceType = "Yale Lock",
        bindingClass = "ESPHOME_YALE",
        passive = false,
        addressType = 0,
      },
    })
  end)
  proxyConnected(SCANNER)
  proxyConnected(OTHER_SCANNER)
  advertise(SCANNER, -60)
  advertise(OTHER_SCANNER, -80)
  toDevices = {}

  local binding = lockBinding()
  H.rfp(binding, "CONNECT", {})
  H.rfp(PROXY_BINDING, "GATT_CONNECT_RESPONSE", {
    proxyId = tostring(SCANNER),
    mac = MAC,
    requestId = lastRequestId("GATT_CONNECT"),
    success = "true",
    services = SerializeSafe({}),
    mtu = "247",
  })
  T.eq("the lock is connected", H.count("CONNECTED", binding), 1)
  H.clearSent()
  return binding
end

local function linkClosed(proxy)
  H.rfp(PROXY_BINDING, "GATT_DISCONNECTED", {
    proxyId = tostring(proxy),
    mac = MAC,
    reason = "BLE connection closed",
  })
end

local function disconnectedReasons(binding)
  local out = {}
  for _, s in ipairs(H.sent) do
    if s.command == "DISCONNECTED" and s.binding == binding then
      table.insert(out, s.params.reason)
    end
  end
  return table.concat(out, ",")
end

H.test("a link the proxy reports closed reaches the lock", function()
  local binding = lockConnected()
  linkClosed(SCANNER)
  T.eq("the lock hears DISCONNECTED", disconnectedReasons(binding), "BLE connection closed")

  linkClosed(SCANNER)
  T.eq("a second report is not passed on", disconnectedReasons(binding), "BLE connection closed")
end)

H.test("a closed link is not used for the next write", function()
  local binding = lockConnected()
  linkClosed(SCANNER)
  -- Proxies are chosen by smoothed RSSI, so the other proxy needs a run of readings to lead
  for _ = 1, 20 do
    advertise(SCANNER, -90)
    advertise(OTHER_SCANNER, -40)
  end
  toDevices = {}
  H.rfp(binding, "GATT_WRITE", { handle = "119", data = C4:Base64Encode("x"), response = "true" })
  T.eq("the write goes to the proxy with the stronger signal", toDevices[1] and toDevices[1].deviceId, OTHER_SCANNER)
end)

H.test("a report from a proxy that no longer holds the link is ignored", function()
  local binding = lockConnected()
  linkClosed(OTHER_SCANNER)
  T.eq("nothing reaches the lock", disconnectedReasons(binding), "")
end)

H.test("after the lock asks to disconnect, the proxy's report adds nothing", function()
  local binding = lockConnected()
  H.rfp(binding, "DISCONNECT", {})
  T.eq("the lock hears its requested DISCONNECTED", disconnectedReasons(binding), "Requested")
  linkClosed(SCANNER)
  T.eq("and no second one", disconnectedReasons(binding), "Requested")
end)

T.finish()
