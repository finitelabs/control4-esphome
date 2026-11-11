--- Tests that the esphome_bluetooth_coordinator driver starts after a restart with a
--- presence device that advertises no name selected, and keeps tracking it under its
--- MAC address, as when it was selected.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_coordinator_nameless_presence.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local persist = require("lib.persist")

H.use("esphome_bluetooth_coordinator")

local PROXIES = 5001
local KITCHEN = 801
local MAC = "02:00:00:00:00:01"
local NAME = MAC .. " [020000000001]"

-- The tracker's dwell time runs on os.time; pinned so a test can step it.
local now = 1000000
local realTime = os.time
os.time = function(date) -- luacheck: ignore
  return date and realTime(date) or now
end

local fired = {}
function C4:FireEventByID(idEvent)
  table.insert(fired, ShimEvents()[idEvent].name)
end

H.test("a presence device with no name is tracked again after a restart", function()
  H.boot(nil, function()
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, addressType = 0 } })
  end)
  T.truthy("the coordinator finishes starting", gInitialized)
  T.eq("Driver Status reads Running", Properties["Driver Status"], "Running")
  T.truthy("the away check runs", H.armed("AwayCheck"))
  T.truthy("its presence binding is back", bindings:getDynamicBinding("presence", "device_020000000001"))
  T.eq("its room variable is back under its address", H.variable("Presence " .. NAME .. " Room"), "")
end)

H.test("it goes home and into the room it is heard in", function()
  OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, KITCHEN, 1)
  H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(KITCHEN), roomId = "11", roomName = "Kitchen" })
  fired = {}
  for _ = 1, 7 do
    H.rfp(PROXIES, "BLE_ADVERTISEMENT", {
      proxyId = tostring(KITCHEN),
      advertisement = SerializeSafe({ mac = MAC, rssi = -50 }),
    })
    now = now + 1
  end
  T.eq("it is in the Kitchen", H.variable("Presence " .. NAME .. " Room"), "Kitchen")
  T.truthy("its Home event fires", table.concat(fired, "\n"):find(NAME .. " Home", 1, true))
end)

H.test("Select Presence Devices takes a change", function()
  Properties["Select Presence Devices"] = "[X] " .. MAC .. " - " .. MAC
  OnPropertyChanged("Select Presence Devices")
  T.eq("it is no longer tracked", H.variable("Presence " .. NAME .. " Room"), nil)
  T.eq("it is no longer selected", persist:get("PresenceDevices"), nil)
end)

T.finish()
