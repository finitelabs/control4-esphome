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

--- The names of the events fired since the last reset, in order, and the Last
--- Presence Previous Room that programming on each would read.
local fired, previousRoomAt = {}, {}
function C4:FireEventByID(idEvent)
  local name = ShimEvents()[idEvent].name
  table.insert(fired, name)
  previousRoomAt[name] = H.variable("Last Presence Previous Room")
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

local values = require("lib.values")

--- Values kept from before a restart, for a device home in the Kitchen. The restart restores them.
local function keptInKitchen()
  persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
  persist:set("PresenceStates", { device_020000000001 = "CLOSED", room_11 = "CLOSED" })
  persist:set("PresenceRooms", { [MAC] = { id = 11, name = "Kitchen" } })
  values:update("Presence " .. TAG .. " Room", "Kitchen", "STRING")
  values:update("Kitchen [11] Occupied", "true", "STRING")
  values:update("Kitchen [11] Occupant Count", "1", "NUMBER")
  values:update("Kitchen [11] Occupants", "Test Tag", "STRING")
  values:update("Last Presence Device MAC", MAC, "STRING")
  values:update("Last Presence Device Name", TAG, "STRING")
  values:update("Last Presence Room", "Kitchen", "STRING")
  values:update("Last Presence Previous Room", "Away", "STRING")
  -- A restart starts a fresh Lua VM, so the tracker remembers nothing of this one.
  package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
end

--- Count the values that change from now on; counted() stops and returns their names, in order.
local counting
local function countChanges()
  local update = values.update
  counting = { names = {}, update = update }
  values.update = function(self, name, ...)
    local valueChanged, recordChanged = update(self, name, ...)
    if valueChanged then
      table.insert(counting.names, name)
    end
    return valueChanged, recordChanged
  end
end

local function counted()
  values.update = counting.update
  return counting.names
end

--- The names in `names` backed by a device's state: not a reading, nor the connection.
local function stateValues(names)
  local out = {}
  for _, name in ipairs(names) do
    if not name:match(" Distance$") and not name:match(" RSSI$") and name ~= "Connected" then
      table.insert(out, name)
    end
  end
  return out
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
  fired, previousRoomAt = {}, {}
  H.clearSent()

  stay(10, nil, -80)
  T.eq("it is Home", H.variable("Presence " .. TAG .. " Room"), "Home")
  T.eq("its room events fire", fired, {
    TAG .. " Left Room",
    "Any Device Left Room",
    "Living Room [12] Empty",
  })
  T.eq("Any Device Left Room names the room it left", previousRoomAt["Any Device Left Room"], "Living Room")
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

H.test("unbinding its room's proxy keeps the room, the programming on it and the tag in it", function()
  stay(7, nil, -50)
  T.eq("it is in the Living Room", H.variable("Presence " .. TAG .. " Room"), "Living Room")
  fired, previousRoomAt = {}, {}
  local deleted, realDelete = {}, C4.DeleteEvent
  C4.DeleteEvent = function(_, id)
    table.insert(deleted, id)
  end

  OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", false, LIVING_ROOM, 1)
  C4.DeleteEvent = realDelete
  T.eq("no event is deleted", deleted, {})
  T.eq("nothing fires, since the tag did not move", fired, {})
  T.eq("it is still in the Living Room", H.variable("Presence " .. TAG .. " Room"), "Living Room")
  T.truthy("the Living Room's connection stays", bindings:getDynamicBinding("presence", "room_12"))
  T.truthy(
    "its Occupied event stays",
    Select(require("lib.events"):getEvents(), "presence", "room_12_occupied", "eventId")
  )
  T.eq("its variables stay", H.variable("Living Room [12] Occupants"), "Test Tag")

  OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, LIVING_ROOM, 1)
  H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(LIVING_ROOM), roomId = "12", roomName = "Living Room" })
  stay(7, nil, -50)
  T.eq(
    "bound again and heard there, it is in the Living Room",
    H.variable("Presence " .. TAG .. " Room"),
    "Living Room"
  )
  T.eq("and nothing fires", fired, {})
  T.eq("the Living Room counts it", H.variable("Living Room [12] Occupants"), "Test Tag")
end)

H.test("deselecting it while it is in a room empties the room", function()
  fired = {}
  H.clearSent()

  Properties["Select Presence Devices"] = "[X] " .. MAC .. " - Test Tag"
  OnPropertyChanged("Select Presence Devices")
  T.eq("it is no longer tracked", H.variable("Presence " .. TAG .. " Room"), nil)
  T.eq("the Living Room empties", fired, { "Living Room [12] Empty" })
  T.eq("the Living Room is empty", H.variable("Living Room [12] Occupied"), "false")
  T.eq("the Living Room counts no one", H.variable("Living Room [12] Occupant Count"), 0)
  T.eq("the Living Room's binding opens", sentTo("OPENED", "room_12"), 1)
  T.eq("its room is no longer kept", persist:get("PresenceRooms", {})[MAC], nil)
end)

H.test("a device home in the Kitchen before a restart, seen there again, fires nothing", function()
  local ok, err = pcall(function()
    H.boot(nil, function()
      keptInKitchen()
      countChanges()
    end)
    for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
      OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
      H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
    end
    fired = {}
    H.clearSent()
    stay(7, -50, -80)
  end)
  local changed = counted()
  assert(ok, err)
  T.eq("it is in the Kitchen", H.variable("Presence " .. TAG .. " Room"), "Kitchen")
  T.eq("no event fires", fired, {})
  T.eq("no value backed by its state changes, from the start on", stateValues(changed), {})
  T.eq("the Kitchen still counts it", H.variable("Kitchen [11] Occupants"), "Test Tag")
  T.eq("its Present binding, which still shows it home, is told nothing", sentTo("CLOSED", "device_020000000001"), 0)
  T.eq("the Kitchen's binding, which still shows it occupied, is told nothing", sentTo("CLOSED", "room_11"), 0)
  T.eq("not even silently", sentTo("STATE_CLOSED", "room_11"), 0)
end)

H.test("a device home in the Kitchen before a restart, heard first in the Living Room, moves there", function()
  H.boot(nil, keptInKitchen)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  fired = {}
  H.clearSent()

  stay(7, -80, -50)
  T.eq("it is in the Living Room", H.variable("Presence " .. TAG .. " Room"), "Living Room")
  T.eq("the room events fire for both rooms", fired, {
    "Living Room [12] Occupied",
    "Kitchen [11] Empty",
    TAG .. " Entered Room",
    "Any Device Entered Room",
  })
  T.eq("the previous room is the Kitchen", previousRoomAt[TAG .. " Entered Room"], "Kitchen")
  T.eq("the Kitchen is empty", H.variable("Kitchen [11] Occupied"), "false")
  T.eq("the Kitchen's binding opens", sentTo("OPENED", "room_11"), 1)
  T.eq("the Living Room is kept as its room", persist:get("PresenceRooms", {})[MAC].name, "Living Room")
end)

H.test("a device home in the Kitchen before a restart, not heard again, leaves it and goes away", function()
  H.boot(nil, keptInKitchen)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  fired = {}
  H.clearSent()

  now = now + 121
  H.fire("AwayCheck")
  T.eq("the device is told away", sentTo("OPENED", "device_020000000001"), 1)
  T.eq("the Kitchen is told empty", sentTo("OPENED", "room_11"), 1)
  T.eq("the Kitchen empties, and it goes away from it", fired, {
    "Kitchen [11] Empty",
    TAG .. " Away",
    TAG .. " Left Room",
    "Any Device Left Room",
  })
  T.eq("the room it left is the Kitchen", previousRoomAt[TAG .. " Left Room"], "Kitchen")
  T.eq("the Kitchen is empty", H.variable("Kitchen [11] Occupied"), "false")
  T.eq("no room is kept for it", persist:get("PresenceRooms", {})[MAC], nil)
end)

H.test("a device that left its room for home before a restart is in no room after it", function()
  local belowKitchen = { ["Minimum Room RSSI (dBm)"] = "-75" }
  H.boot(belowKitchen, keptInKitchen)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  fired = {}
  stay(3, -80, nil)
  T.eq("below Minimum Room RSSI it leaves the Kitchen", fired, {
    TAG .. " Left Room",
    "Any Device Left Room",
    "Kitchen [11] Empty",
  })
  T.eq("no room is kept for it", persist:get("PresenceRooms", {})[MAC], nil)

  H.boot(belowKitchen, function()
    package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
  end)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  fired = {}
  stay(3, -80, nil)
  T.eq("after the restart, heard below it again, nothing fires", fired, {})
end)

H.test("a device home and a room occupied before a restart, with no room kept, read away and empty", function()
  H.boot(nil, function()
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
    persist:set("PresenceStates", { device_020000000001 = "CLOSED", room_11 = "CLOSED" })
    persist:delete("PresenceRooms")
    package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
  end)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  fired = {}
  H.clearSent()

  now = now + 60
  H.fire("AwayCheck")
  T.eq("within the Away Timeout nothing is told", #H.sent, 0)

  now = now + 61
  H.fire("AwayCheck")
  T.eq("past it, the device is told away", sentTo("OPENED", "device_020000000001"), 1)
  T.eq("the Kitchen is told empty", sentTo("OPENED", "room_11"), 1)
  T.eq("its Away and the Kitchen's Empty fire", fired, { TAG .. " Away", "Kitchen [11] Empty" })

  H.clearSent()
  now = now + 121
  H.fire("AwayCheck")
  T.eq("and only once", #H.sent, 0)
end)

H.test("a tag that goes away from a room with no proxy left empties the room", function()
  H.boot(nil, function()
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
    persist:delete("PresenceStates")
    package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
  end)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  stay(7, -50, -80)
  T.eq("it is in the Kitchen", H.variable("Presence " .. TAG .. " Room"), "Kitchen")

  OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", false, KITCHEN, 1)
  fired = {}
  H.clearSent()
  now = now + 200
  H.fire("AwayCheck")
  T.eq("it is Away", H.variable("Presence " .. TAG .. " Room"), "Away")
  T.eq("the Kitchen reads empty", H.variable("Kitchen [11] Occupied"), "false")
  T.eq("and counts no one", H.variable("Kitchen [11] Occupant Count"), 0)
  T.eq("the Kitchen's connection opens", sentTo("OPENED", "room_11"), 1)
end)

H.test("a tag removed and added again while home starts away", function()
  H.boot(nil, function()
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
    persist:set("PresenceStates", { device_020000000001 = "CLOSED" })
    package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
  end)
  local tracker = require("esphome.ble.coordinator.presence_tracker")
  tracker:untrackDevice(MAC)
  tracker:trackDevice(MAC, { mac = MAC, name = "Test Tag" })
  T.eq("its kept state is away", persist:get("PresenceStates").device_020000000001, "OPENED")
end)

-- Renames the Kitchen's events for the rest of the file, so it runs last before Reset Driver.
H.test("a room a proxy reports under a new name after a restart takes it, with the device still in it", function()
  H.boot(nil, keptInKitchen)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Pantry" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  fired = {}
  H.clearSent()

  stay(7, -50, -80)
  T.eq("no event fires", fired, {})
  T.eq("it is in the Pantry", H.variable("Presence " .. TAG .. " Room"), "Pantry")
  T.eq("the Pantry counts it", H.variable("Pantry [11] Occupants"), "Test Tag")
  T.eq("and reads occupied", H.variable("Pantry [11] Occupied"), "true")
  T.eq("its room is kept under the new name", persist:get("PresenceRooms", {})[MAC].name, "Pantry")
end)

H.test("Reset Driver removes every room and forgets every presence state told", function()
  H.boot(nil, function()
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
    persist:delete("PresenceStates")
    package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
  end)
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
  stay(7, -50, -80)
  OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", false, KITCHEN, 1)
  T.truthy("the Kitchen keeps its connection with no proxy left", bindings:getDynamicBinding("presence", "room_11"))

  ExecuteCommand("Reset Driver", { ["Are You Sure?"] = "Yes" })
  local events = require("lib.events"):getEvents()
  for _, room in ipairs({ "11", "12" }) do
    T.eq("room " .. room .. "'s connection is gone", bindings:getDynamicBinding("presence", "room_" .. room), nil)
    T.eq("and its Occupied event", Select(events, "presence", "room_" .. room .. "_occupied", "eventId"), nil)
  end
  T.eq("nothing is kept", persist:get("PresenceStates"), nil)
  T.eq("and no room", persist:get("PresenceRooms"), nil)
end)

T.finish()
