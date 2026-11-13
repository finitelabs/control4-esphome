--- Tests the first load of this build on an item an earlier build ran: the contact states it kept
--- are corrected once, silently, so a bound item shows the new reading and runs no programming.
--- The ESPHome driver forgets its binary sensors' kept states; the Bluetooth Coordinator turns its
--- Present and Occupied states, and a device that was home stays home with no Home event.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_contacts_after_update.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local deferred = require("deferred")
local persist = require("lib.persist")
local ESPHomeClient = require("esphome.client")

local MARKER = "ContactsReadOpened"

--- Boot, and return what the late init told each binding and the events fired by the end of
--- `after`, which H.boot would otherwise clear.
local function bootTelling(properties, prepare, after)
  local told, fired, send, fire = {}, {}, C4.SendToProxy, C4.FireEventByID
  C4.SendToProxy = function(self, idBinding, strCommand, ...)
    table.insert(told, { binding = idBinding, command = strCommand })
    return send(self, idBinding, strCommand, ...)
  end
  C4.FireEventByID = function(self, idEvent, ...)
    table.insert(fired, idEvent)
    return fire(self, idEvent, ...)
  end
  local ok, err = pcall(function()
    H.boot(properties, prepare)
    if after then
      after()
    end
  end)
  C4.SendToProxy, C4.FireEventByID = send, fire
  assert(ok, err)
  return told, fired
end

--- What one binding was told in `told`, in order.
local function toldIn(told, namespace, key)
  local binding = bindings:getDynamicBinding(namespace, key)
  local got = {}
  for _, s in ipairs(told) do
    if binding and s.binding == binding.bindingId then
      got[#got + 1] = s.command
    end
  end
  return got
end

H.use("esphome")
-- The device never answers, so late init's connect stays off the network.
local realConnect = ESPHomeClient.connect
ESPHomeClient.connect = function()
  return deferred.new():reject("Connection refused")
end

H.test("the ESPHome driver forgets its binary sensors' kept states once at the update", function()
  H.boot(nil, function()
    -- An earlier build told an open door Closed.
    persist:set("BinarySensorStates", { ["801"] = "CLOSED" })
    persist:delete(MARKER)
  end)
  T.eq("the kept states are gone", persist:get("BinarySensorStates"), nil)
  T.eq("and the correction is marked done", persist:get(MARKER), true)

  local BinarySensorEntity = require("esphome.entities.binary_sensor")
  local sensor = BinarySensorEntity:new({})
  local door = { key = 801, ref = "801", name = "Back Door", device_class = "door" }
  sensor:discovered(door)
  H.clearSent()
  sensor:updated(door, { state = true })
  local contact = bindings:getDynamicBinding(BinarySensorEntity.TYPE, "binary_sensor_801").bindingId
  T.eq("the open door's first reading goes out silently, as Opened", H.count("STATE_OPENED", contact), 1)
  T.eq("not as a change", H.count("OPENED", contact), 0)

  H.boot(nil, function()
    persist:set("BinarySensorStates", { ["801"] = "OPENED" })
  end)
  T.eq("a later load keeps the kept states", persist:get("BinarySensorStates"), { ["801"] = "OPENED" })
end)

H.test("a new ESPHome item has nothing to correct", function()
  H.boot(nil, function()
    persist:delete("BinarySensorStates")
    persist:delete(MARKER)
  end)
  T.eq("nothing is kept", persist:get("BinarySensorStates"), nil)
  T.eq("and the correction is marked done", persist:get(MARKER), true)
end)
ESPHomeClient.connect = realConnect

H.use("esphome_bluetooth_coordinator")
local PROXIES = 5001
local KITCHEN, LIVING_ROOM = 801, 802
local MAC = "02:00:00:00:00:01"

-- The tracker's dwell time and reading age run on os.time; pinned so a test can step it.
local now = 1000000
local realTime = os.time
os.time = function(date) -- luacheck: ignore
  return date and realTime(date) or now
end

--- Both proxies connect, the Kitchen's as room 11 and the Living Room's as room 12.
local function connectProxies()
  for proxy, room in pairs({ [KITCHEN] = { "11", "Kitchen" }, [LIVING_ROOM] = { "12", "Living Room" } }) do
    OnBindingChanged(PROXIES, "ESPHOME_BLUETOOTH", true, proxy, 1)
    H.rfp(PROXIES, "PROXY_CONNECTED", { proxyId = tostring(proxy), roomId = room[1], roomName = room[2] })
  end
end

--- The Kitchen proxy hears the tag once a second for `seconds`.
local function inKitchen(seconds)
  for _ = 1, seconds do
    H.rfp(PROXIES, "BLE_ADVERTISEMENT", {
      proxyId = tostring(KITCHEN),
      advertisement = SerializeSafe({ mac = MAC, rssi = -50 }),
    })
    now = now + 1
  end
end

--- A restart: a fresh Lua VM, so the tracker remembers nothing of the last load.
local function restart(prepare)
  return function()
    package.loaded["esphome.ble.coordinator.presence_tracker"] = nil
    if prepare then
      prepare()
    end
  end
end

H.test("a tag home in the Kitchen before the update stays home, corrected silently, with nothing fired", function()
  -- This build's Present and Occupied connections, as an update keeps them.
  H.boot(
    nil,
    restart(function()
      persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
      persist:delete("PresenceStates")
      persist:delete("PresenceRooms")
      persist:set(MARKER, true)
    end)
  )
  connectProxies()
  inKitchen(7)

  -- An earlier build told the tag home and the Kitchen occupied as Closed.
  local told, fired = bootTelling(
    nil,
    restart(function()
      persist:set("PresenceStates", { device_020000000001 = "CLOSED", room_11 = "CLOSED" })
      persist:set("PresenceRooms", { [MAC] = { id = 11, name = "Kitchen" } })
      persist:delete(MARKER)
    end),
    function()
      connectProxies()
      inKitchen(7)
    end
  )
  T.eq("its Present is told it reads Opened, silently", toldIn(told, "presence", "device_020000000001"), {
    "STATE_OPENED",
  })
  T.eq("the Kitchen's Occupied too", toldIn(told, "presence", "room_11"), { "STATE_OPENED" })
  T.eq("nothing fires, heard there again or not", fired, {})
  T.eq("it is still home", persist:get("PresenceStates").device_020000000001, "OPENED")

  told = bootTelling(nil, restart(), function()
    connectProxies()
    inKitchen(3)
  end)
  T.eq("a later load corrects nothing", toldIn(told, "presence", "device_020000000001"), {})
end)

H.test("a new Coordinator has nothing to correct", function()
  local told = bootTelling(
    nil,
    restart(function()
      persist:delete("PresenceDevices")
      persist:delete("PresenceStates")
      persist:delete(MARKER)
    end)
  )
  T.eq("nothing is told at its start", toldIn(told, "presence", "device_020000000001"), {})
  T.eq("and the correction is marked done", persist:get(MARKER), true)
end)

T.finish()
