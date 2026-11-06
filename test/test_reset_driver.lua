--- Tests that Reset Driver returns each ESPHome driver to a fresh install: every
--- binding, variable and event it built goes, its settable properties go back to
--- their driver.xml defaults, and the address and credentials that reach the
--- same device stay.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_reset_driver.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local events = require("lib.events")
local persist = require("lib.persist")

local function reset()
  ExecuteCommand("Reset Driver", { ["Are You Sure?"] = "Yes" })
end

--- How many events lib.events still keeps, in every namespace.
local function eventCount()
  local n = 0
  for _, namespace in pairs(events:getEvents()) do
    for _ in pairs(namespace) do
      n = n + 1
    end
  end
  return n
end

-- The connect path looks up the other ESPHome items; this project has none.
function C4:GetDevicesByC4iName()
  return {}
end

H.use("esphome")
H.test("the ESPHome driver forgets its events, LED lights and restart button, and resets its settings", function()
  H.boot({
    ["IP Address"] = "192.168.9.9",
    ["Log Level"] = "5 - Trace",
    ["Bluetooth Proxy Room"] = "12",
    ["Minimum Room RSSI Override (dBm)"] = "-70",
  })
  events:getOrAddEvent("event_1", "press", "Doorbell press", "When the doorbell is pressed")
  persist:set("ButtonLedLights", { ["button_1"] = "light_2" })
  persist:set("BluetoothProxyRestartButton", "Restart")
  persist:set("BluetoothProxyLastAutoRestart", 1000)

  reset()
  T.eq("its events are gone", eventCount(), 0)
  T.eq("its LED lights are forgotten", persist:get("ButtonLedLights"), nil)
  T.eq("its restart button is forgotten", persist:get("BluetoothProxyRestartButton"), nil)
  T.eq("and when it last pressed it", persist:get("BluetoothProxyLastAutoRestart"), nil)
  T.eq("Bluetooth Proxy Room is back to its default", Properties["Bluetooth Proxy Room"], "")
  T.eq("so is Minimum Room RSSI Override", Properties["Minimum Room RSSI Override (dBm)"], "-100")
  T.eq("so is Log Level", Properties["Log Level"], "3 - Info")
  T.eq("its address stays", Properties["IP Address"], "192.168.9.9")
end)

H.use("esphome_bluetooth_coordinator")
local MAC = "02:00:00:00:00:01"
H.test("the coordinator forgets its presence devices, connections and events, and resets its settings", function()
  H.boot({ ["Away Timeout (seconds)"] = "300", ["Log Mode"] = "Print" }, function()
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
    persist:set("DiscoveredBLEDevices", { [MAC] = { mac = MAC } })
    package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
  end)
  T.truthy("its tag's Present connection exists", bindings:getDynamicBinding("presence", "device_020000000001"))
  T.truthy("and its presence events", eventCount() > 0)

  reset()
  local tracker = require("esphome.ble.coordinator.presence_tracker")
  T.eq("the tag's Present connection is gone", bindings:getDynamicBinding("presence", "device_020000000001"), nil)
  T.eq("its presence events are gone", eventCount(), 0)
  T.eq("it no longer tracks the tag", next(tracker:getPresenceDevices() or {}), nil)
  T.eq("the tag selection is cleared", persist:get("PresenceDevices"), nil)
  T.eq("the devices the scanner found are forgotten", persist:get("DiscoveredBLEDevices"), nil)
  T.eq("Away Timeout is back to its default", Properties["Away Timeout (seconds)"], "120")
  T.eq("so is Log Mode", Properties["Log Mode"], "Off")
end)

H.use("esphome_bthome")
H.test("BTHome resets its settings and keeps its Bind Key", function()
  H.boot({ ["Log Level"] = "5 - Trace", ["Log Mode"] = "Print", ["Bind Key"] = "00112233445566778899aabbccddeeff" })
  reset()
  T.eq("Log Level is back to its default", Properties["Log Level"], "3 - Info")
  T.eq("so is Log Mode", Properties["Log Mode"], "Off")
  T.eq("the Bind Key stays", Properties["Bind Key"], "00112233445566778899aabbccddeeff")
end)

H.use("esphome_govee")
H.test("Govee resets its settings", function()
  H.boot({ ["Log Level"] = "5 - Trace", ["Log Mode"] = "Print" })
  reset()
  T.eq("Log Level is back to its default", Properties["Log Level"], "3 - Info")
  T.eq("so is Log Mode", Properties["Log Mode"], "Off")
end)

H.use("esphome_serenescent")
H.test("SereneScent resets its settings", function()
  H.boot({ ["Polling Interval"] = "30", ["Log Level"] = "5 - Trace" })
  reset()
  T.eq("Polling Interval is back to its default", Properties["Polling Interval"], "5")
  T.eq("so is Log Level", Properties["Log Level"], "3 - Info")
end)

H.use("esphome_switchbot")
H.test("SwitchBot keeps its encryption keys and cloud login, and resets its settings", function()
  H.boot({
    ["Key ID"] = "a1",
    ["Encryption Key"] = "00112233445566778899aabbccddeeff",
    ["SwitchBot Username"] = "someone@example.invalid",
    ["Log Level"] = "5 - Trace",
  })
  reset()
  T.eq("the Key ID stays", Properties["Key ID"], "a1")
  T.eq("the Encryption Key stays", Properties["Encryption Key"], "00112233445566778899aabbccddeeff")
  T.eq("the cloud login stays", Properties["SwitchBot Username"], "someone@example.invalid")
  T.eq("Log Level is back to its default", Properties["Log Level"], "3 - Info")
end)

H.use("esphome_yale")
H.test("Yale keeps its key and login, and resets its settings", function()
  H.boot({
    ["Connection Mode"] = "Persistent",
    ["Polling Interval"] = "120",
    ["Offline Key"] = "00112233445566778899aabbccddeeff",
    ["Key Slot"] = "3",
    ["Yale Email"] = "someone@example.invalid",
    ["Log Mode"] = "Print",
  })
  reset()
  T.eq("Connection Mode is back to its default", Properties["Connection Mode"], "Poll")
  T.eq("so is Polling Interval", Properties["Polling Interval"], "60")
  T.eq("so is Log Mode", Properties["Log Mode"], "Off")
  T.eq("the Offline Key stays", Properties["Offline Key"], "00112233445566778899aabbccddeeff")
  T.eq("the Key Slot stays", Properties["Key Slot"], "3")
  T.eq("the Yale login stays", Properties["Yale Email"], "someone@example.invalid")
end)

T.finish()
