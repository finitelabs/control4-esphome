--- Tests that the esphome_bluetooth_coordinator driver places a device selected
--- only under Select Presence Devices in a room, and fires the room events as it
--- moves between two proxies' rooms. Such a device is never in the device
--- registry, which records RSSI only for devices selected under Select Bluetooth
--- Devices, so its rooms come from the RSSI the presence tracker sees.
---
--- The sections follow one device through one boot, in order.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_presence_rooms.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local persist = require("lib.persist")

H.use("esphome_bluetooth_coordinator")

local PROXIES = 5001
local KITCHEN, LIVING_ROOM = 801, 802
local MAC = "02:00:00:00:00:01"
local TAG = "Test Tag [020000000001]"

-- The tracker's dwell time and reading age run on os.time; pinned so a test can step it.
local now = 1000000
local realTime = os.time
os.time = function(date) -- luacheck: ignore
  return date and realTime(date) or now
end

--- The names of the events fired since the last reset, in order.
local fired = {}
function C4:FireEventByID(idEvent)
  table.insert(fired, ShimEvents()[idEvent].name)
end

--- How many times `command` went to a presence binding; none if there is no such binding.
local function sentTo(command, key)
  local binding = bindings:getDynamicBinding("presence", key)
  return binding and H.count(command, binding.bindingId) or 0
end

--- The proxies report the device once a second for `seconds`; a nil RSSI is a
--- proxy that does not see it.
local function stay(seconds, kitchenRssi, livingRoomRssi)
  for _ = 1, seconds do
    for _, seen in ipairs({ { KITCHEN, kitchenRssi }, { LIVING_ROOM, livingRoomRssi } }) do
      if seen[2] then
        H.rfp(PROXIES, "BLE_ADVERTISEMENT", {
          proxyId = tostring(seen[1]),
          advertisement = SerializeSafe({ mac = MAC, rssi = seen[2] }),
        })
      end
    end
    now = now + 1
  end
end

H.test("a presence-only device is placed in the room with the strongest signal", function()
  H.boot(nil, function()
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
  end)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  T.eq("no device is selected under Select Bluetooth Devices", Properties["Selected Devices"], "0")
  fired = {}
  H.clearSent()

  stay(7, -50, -80)
  T.eq("it is in the Kitchen", H.variable("Presence " .. TAG .. " Room"), "Kitchen")
  T.eq("its room events fire", fired, {
    TAG .. " Home",
    "Kitchen [11] Occupied",
    TAG .. " Entered Room",
    "Any Device Entered Room",
  })
  T.eq("the Kitchen counts it", H.variable("Kitchen [11] Occupants"), "Test Tag")
  T.eq("the Kitchen's binding closes", sentTo("CLOSED", "room_11"), 1)
  T.eq("its Present binding closes", sentTo("CLOSED", "device_020000000001"), 1)
end)

H.test("moving to the Living Room fires the room events for both rooms", function()
  fired = {}
  H.clearSent()

  stay(12, -80, -50)
  T.eq("it is in the Living Room", H.variable("Presence " .. TAG .. " Room"), "Living Room")
  T.eq("the room events fire once", fired, {
    "Living Room [12] Occupied",
    "Kitchen [11] Empty",
    TAG .. " Entered Room",
    "Any Device Entered Room",
  })
  T.eq("the previous room is the Kitchen", H.variable("Last Presence Previous Room"), "Kitchen")
  T.eq("the Kitchen is empty", H.variable("Kitchen [11] Occupied"), "false")
  T.eq("the Living Room counts it", H.variable("Living Room [12] Occupants"), "Test Tag")
  T.eq("its RSSI is the Living Room's, in whole dBm", H.variable("Presence " .. TAG .. " RSSI"), -52)
  T.eq("the Kitchen's binding opens", sentTo("OPENED", "room_11"), 1)
  T.eq("the Living Room's binding closes", sentTo("CLOSED", "room_12"), 1)
end)

H.test("when the Living Room proxy loses it, its last reading there does not hold it", function()
  fired = {}

  stay(40, -62, nil)
  T.eq("it is in the Kitchen", H.variable("Presence " .. TAG .. " Room"), "Kitchen")
  T.eq("the room events fire once", fired, {
    "Kitchen [11] Occupied",
    "Living Room [12] Empty",
    TAG .. " Entered Room",
    "Any Device Entered Room",
  })
end)

H.test("going quiet past the Away Timeout fires Left Room and empties its room", function()
  fired = {}
  H.clearSent()

  now = now + 121
  T.truthy("the away check runs", H.fire("AwayCheck"))
  T.eq("it is Away", H.variable("Presence " .. TAG .. " Room"), "Away")
  T.eq("its room events fire", fired, {
    "Kitchen [11] Empty",
    TAG .. " Away",
    TAG .. " Left Room",
    "Any Device Left Room",
  })
  T.eq("its Present binding opens", sentTo("OPENED", "device_020000000001"), 1)
end)

H.test("back home, it is placed by the proxy that sees it now, not by older readings", function()
  fired = {}

  stay(7, -85, nil)
  T.eq("it is in the Kitchen", H.variable("Presence " .. TAG .. " Room"), "Kitchen")
  T.eq("its room events fire", fired, {
    TAG .. " Home",
    "Kitchen [11] Occupied",
    TAG .. " Entered Room",
    "Any Device Entered Room",
  })
  T.eq("it came from Away", H.variable("Last Presence Previous Room"), "Away")
end)

H.test("one weak reading from a proxy that last heard it close by does not move it", function()
  stay(30, -40, nil)
  stay(40, nil, -60)
  T.eq("it is in the Living Room", H.variable("Presence " .. TAG .. " Room"), "Living Room")
  fired = {}

  stay(1, -90, -60)
  stay(10, nil, -60)
  T.eq("it is still in the Living Room", H.variable("Presence " .. TAG .. " Room"), "Living Room")
  T.eq("no room events fire", fired, {})
  T.eq("its RSSI is the Living Room's", H.variable("Presence " .. TAG .. " RSSI"), -60)
end)

H.test("below Minimum Room RSSI it leaves its room and stays home", function()
  Properties["Minimum Room RSSI (dBm)"] = "-75"
  OnPropertyChanged("Minimum Room RSSI (dBm)")
  fired = {}
  H.clearSent()

  stay(10, nil, -80)
  T.eq("it is Home", H.variable("Presence " .. TAG .. " Room"), "Home")
  T.eq("its room events fire", fired, {
    TAG .. " Left Room",
    "Any Device Left Room",
    "Living Room [12] Empty",
  })
  T.eq("the Living Room is empty", H.variable("Living Room [12] Occupied"), "false")
  T.eq("its Present binding stays closed", sentTo("OPENED", "device_020000000001"), 0)
end)

H.test("back home below Minimum Room RSSI, it is present in no room", function()
  now = now + 121
  H.fire("AwayCheck")
  T.eq("it is Away", H.variable("Presence " .. TAG .. " Room"), "Away")
  fired = {}
  H.clearSent()

  stay(3, nil, -90)
  T.eq("it is Home", H.variable("Presence " .. TAG .. " Room"), "Home")
  T.eq("only Home fires", fired, { TAG .. " Home" })
  T.eq("its Present binding closes", sentTo("CLOSED", "device_020000000001"), 1)

  Properties["Minimum Room RSSI (dBm)"] = "-100"
  OnPropertyChanged("Minimum Room RSSI (dBm)")
end)

T.finish()
