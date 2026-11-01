--- With Cloud Monitoring on, an error the BLE proxy and scanner catch themselves is reported: a bound device's
--- advertisement monitoring or connection failing, the scan's start and end callbacks, a scanner property's selection
--- callback, and a proxy change callback.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_cloud_monitoring.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local diagnostics = require("lib.diagnostics")
local persist = require("lib.persist")
local BluetoothProxyCapability = require("esphome.capabilities.bluetooth_proxy")
local scanner = require("esphome.ble.scanner")
local scannerProperties = require("esphome.ble.scanner_properties")
local proxyRegistry = require("esphome.ble.coordinator.proxy_registry")

local MAC = "AA:BB:CC:DD:EE:FF"
local BINDING = 5013

-- This build carries no server, so Cloud Monitoring is turned on here and each error report is taken where it would
-- be written.
local reported = {}
diagnostics._enabled = true
function diagnostics:_writeErrorLog(message, _, source)
  reported[#reported + 1] = source .. ": " .. tostring(message):gsub("^.-:%d+: ", "")
end

--- What `fn` got reported, as "source: message", each call in a rate window of its own.
local function reports(fn)
  reported = {}
  diagnostics._errorWriteCount = 0
  fn()
  return reported
end

local function raises(message)
  return function()
    error(message)
  end
end

T.section("a bound device the proxy fails to monitor or connect is reported")
do
  local proxy = BluetoothProxyCapability:new({
    isBluetoothDeviceAllocated = function()
      return false
    end,
  })
  proxy._addedDevices[MAC] = { bindingId = BINDING, passive = false, name = "Test Sensor" }
  proxy._startAdvertisementMonitoring = raises("monitor boom")
  proxy._connectAndNotify = raises("connect boom")
  T.eq(
    "its bind",
    reports(function()
      proxy:onBindingChanged(BINDING, true)
    end),
    {
      "ESPHome.BluetoothProxyMonitor: monitor boom",
      "ESPHome.BluetoothProxyConnect: connect boom",
    }
  )

  local bound = C4.GetBoundConsumerDevices
  C4.GetBoundConsumerDevices = raises("bound boom")
  T.eq(
    "its reconnect after a reload",
    reports(function()
      proxy:_connectBoundDevices()
    end),
    { "ESPHome.BluetoothProxyBoundDevice: bound boom" }
  )
  C4.GetBoundConsumerDevices = bound
end

T.section("a scan's start and end callbacks that fail are reported")
do
  local node = {
    getId = function()
      return "node-1"
    end,
    isConnected = function()
      return true
    end,
    setAdvertisementCallback = function() end,
    clearAdvertisementCallback = function() end,
  }
  scanner:addNode(node)
  scanner:setOnScanStart(raises("start boom"))
  scanner:setOnScanEnd(raises("end boom"))
  T.eq(
    "a scan, stopped",
    reports(function()
      scanner:scan()
      scanner:stopScan()
    end),
    { "ESPHome.BLEScanStart: start boom", "ESPHome.BLEScanEnd: end boom" }
  )
  scanner:setOnScanStart(nil)
  scanner:setOnScanEnd(nil)
  scanner:removeNode("node-1")
end

T.section("a scanner property's selection callback that fails is reported")
do
  persist:set("TestSelection", { [MAC] = { mac = MAC, name = "Test Sensor" } })
  T.eq(
    "its stored selection applied",
    reports(function()
      scannerProperties:registerProperty(
        "Test Devices",
        { persistKey = "TestSelection", onChanged = raises("pick boom") }
      )
    end),
    { "ESPHome.BLEScannerSelection: pick boom" }
  )
  T.eq(
    "a device picked off it",
    reports(function()
      scannerProperties:handleSelection("Test Devices", "[X] " .. MAC .. " - Test Sensor")
    end),
    { "ESPHome.BLEScannerSelection: pick boom" }
  )
  T.eq(
    "its selection cleared",
    reports(function()
      scannerProperties:reset()
    end),
    { "ESPHome.BLEScannerSelection: pick boom" }
  )
end

T.section("a proxy change callback that fails is reported")
do
  proxyRegistry:onProxyChange("test", raises("change boom"))
  T.eq(
    "a proxy connecting",
    reports(function()
      proxyRegistry:_fireProxyChange("connected", { deviceId = 101 })
    end),
    { "ESPHome.BLEProxyChange: change boom" }
  )
  proxyRegistry:onProxyChange("test", nil)
end

T.finish()
