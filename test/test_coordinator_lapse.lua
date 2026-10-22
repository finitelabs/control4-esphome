--- Tests that the Bluetooth Coordinator does not mark a device Away while the
--- license is lapsed. A lapse disconnects every ESPHome device, so their
--- proxies stop forwarding advertisements while the device may still be in the
--- room; an Away then would run the Away, Left Room and Room Empty Programming.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_coordinator_lapse.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local persist = require("lib.persist")

H.use("esphome_bluetooth_coordinator")

local PROXY_BINDING = 5001
local SCANNER = 101 -- an ESPHome device's driver, bound to the coordinator as a proxy
local MAC = "AA:BB:CC:DD:EE:01"
local AWAY_TIMEOUT = 120

-- The away clock reads os.time, so the test moves it by hand.
local clock = 1000000
os.time = function() -- luacheck: ignore
  return clock
end

local fired = {}
function C4:FireEventByID(id)
  fired[#fired + 1] = id
end

--- The keys of the presence events fired since the last call.
local function events()
  local names = {}
  for key, event in pairs(Select(require("lib.events"):getEvents(), "presence") or {}) do
    names[event.eventId] = key
  end
  local out = {}
  for _, id in ipairs(fired) do
    out[#out + 1] = names[id] or tostring(id)
  end
  fired = {}
  return out
end

local function advertise()
  H.rfp(PROXY_BINDING, "BLE_ADVERTISEMENT", {
    proxyId = tostring(SCANNER),
    advertisement = SerializeSafe({ mac = MAC, rssi = -60 }),
  })
end

local function awayCheck()
  TimerFunctions[Timer.AwayCheck](Timer.AwayCheck, 0)
end

--- A coordinator with one scanner in the Kitchen and a BTHome tag it has placed there. Only a device selected
--- under Select Bluetooth Devices too is placed in a room.
local function tagInKitchen()
  H.boot({ ["Away Timeout (seconds)"] = tostring(AWAY_TIMEOUT) }, function()
    for _, name in ipairs({ "presence_tracker", "proxy_registry", "device_registry", "router" }) do
      package.loaded["esphome.ble.coordinator." .. name] = nil
    end
    persist:set("SelectedDevices", {
      [MAC] = {
        mac = MAC,
        name = "Test Tag",
        deviceType = "BTHome V2",
        bindingClass = "ESPHOME_BTHOME",
        passive = true,
      },
    })
    persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag", type = "device", txPower = -59 } })
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
  advertise()
  clock = clock + 6 -- past the room's dwell time
  advertise()
  events()
  H.clearSent()
end

local function opened()
  return H.count("OPENED")
end

H.test("a tag no proxy hears for the Away Timeout is Away", function()
  tagInKitchen()
  clock = clock + AWAY_TIMEOUT + 30
  awayCheck()
  T.eq("it fires Away, Left Room and the Kitchen's Empty", events(), {
    "room_20_empty",
    "device_AABBCCDDEE01_away",
    "device_AABBCCDDEE01_left_room",
    "any_device_left_room",
  })
  T.eq("and its contact and the Kitchen's open", opened(), 2)
end)

H.test("a lapsed license holds the tag home, and Away runs again once the license is active", function()
  tagInKitchen()
  DC_X = 0
  for _ = 1, 20 do
    clock = clock + 30
    awayCheck()
  end
  T.eq("ten minutes lapsed: no presence event fires", events(), {})
  T.eq("and its contact and the Kitchen's stay closed", opened(), 0)
  T.eq("it is still in the Kitchen", H.variable("Presence Test Tag [AABBCCDDEE01] Room"), "Kitchen")

  DC_X = 1
  clock = clock + 30
  awayCheck()
  clock = clock + AWAY_TIMEOUT
  awayCheck()
  T.eq("relicensed, the proxies get a whole Away Timeout from the first check to be heard", events(), {})
  clock = clock + 30
  awayCheck()
  T.eq("past it, the tag is Away", events(), {
    "room_20_empty",
    "device_AABBCCDDEE01_away",
    "device_AABBCCDDEE01_left_room",
    "any_device_left_room",
  })
  DC_X = nil
end)

H.test("a tag heard again after the lapse stays home", function()
  tagInKitchen()
  DC_X = 0
  clock = clock + 600
  awayCheck()
  DC_X = 1
  clock = clock + 30
  awayCheck()
  clock = clock + 20
  advertise()
  clock = clock + AWAY_TIMEOUT
  awayCheck()
  T.eq("no presence event fires", events(), {})
  DC_X = nil
end)

T.finish()
