--- Tests that the Bluetooth Coordinator's RSSI Freshness setting decides which readings count when it picks a proxy
--- to connect a device through: a reading older than the setting is not used.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_coordinator_rssi_freshness.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local persist = require("lib.persist")

H.use("esphome_bluetooth_coordinator")

local PROXY_BINDING = 5001
local SCANNER = 101
local MAC = "AA:BB:CC:DD:EE:01"
local FRESHNESS = "RSSI Freshness (seconds)"

-- A clock the test steps; the registries read it through os.time.
local now = 1000000
local realTime = os.time
os.time = function(date) -- luacheck: ignore
  return date and realTime(date) or now
end

--- What the coordinator sent proxies with C4:SendToDevice.
local toDevices = {}
function C4:SendToDevice(deviceId, command, params)
  table.insert(toDevices, { deviceId = deviceId, command = command, params = params or {} })
end

--- How many times the coordinator asked a proxy to connect the lock.
local function connectRequests()
  local n = 0
  for _, sent in ipairs(toDevices) do
    if sent.command == "GATT_CONNECT" then
      n = n + 1
    end
  end
  return n
end

--- A coordinator with one proxy that heard a Yale lock, booted with `freshness`.
local function heardByProxy(freshness)
  H.boot({ [FRESHNESS] = freshness }, function()
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
  OBC[PROXY_BINDING](PROXY_BINDING, "ESPHOME_BLUETOOTH", true, SCANNER, 1)
  H.rfp(PROXY_BINDING, "PROXY_CONNECTED", {
    proxyId = tostring(SCANNER),
    roomId = "20",
    roomName = "Kitchen",
    connectionSlots = "3",
    freeSlots = "3",
    featureFlags = "0",
  })
  H.rfp(PROXY_BINDING, "BLE_ADVERTISEMENT", {
    proxyId = tostring(SCANNER),
    advertisement = SerializeSafe({ mac = MAC, rssi = -60 }),
  })
end

--- Ask the coordinator to connect the lock `age` seconds after the proxy last heard it.
local function connectAfter(age)
  now = now + age
  toDevices = {}
  H.rfp(bindings:getDynamicBinding("coordinator", "bt_" .. MAC:gsub(":", "")).bindingId, "CONNECT", {})
  return connectRequests()
end

H.test("a reading older than RSSI Freshness is not used to pick a proxy", function()
  heardByProxy("20")
  T.eq("30 s old against 20 s: no proxy is asked", connectAfter(30), 0)
end)

H.test("a reading within RSSI Freshness is used", function()
  heardByProxy("20")
  T.eq("10 s old against 20 s: the proxy is asked", connectAfter(10), 1)
end)

H.test("the default of 60 s keeps a 30-s-old reading", function()
  heardByProxy("60")
  T.eq("30 s old against 60 s: the proxy is asked", connectAfter(30), 1)
end)

H.test("a change to RSSI Freshness takes effect at once", function()
  heardByProxy("60")
  Properties[FRESHNESS] = "20"
  OnPropertyChanged(FRESHNESS)
  T.eq("30 s old against the new 20 s: no proxy is asked", connectAfter(30), 0)
end)

T.finish()
