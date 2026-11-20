--- Tests an item added before this build: at the update its contacts keep reading as they did,
--- with nothing told and nothing fired. Setting its Contact When Active to Opened, or back, tells
--- each kept contact the new reading silently, so a bound item shows it and runs no programming.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_contact_reading_property.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local deferred = require("deferred")
local persist = require("lib.persist")
local ESPHomeClient = require("esphome.client")

local MARKER = "ContactsReadOpened"

--- Set Contact When Active as Composer does.
local function setReading(value)
  Properties["Contact When Active"] = value
  OnPropertyChanged("Contact When Active")
end

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

--- An item added before this build, at its first load of it, holding an open back door it told
--- Closed and a sensor not discovered since.
local function bootUpdated()
  return bootTelling(nil, function()
    persist:set("BinarySensorStates", { ["801"] = "CLOSED", ["802"] = "OPENED" })
    persist:delete(MARKER)
    persist:delete("ContactReading")
  end)
end

local BinarySensorEntity = require("esphome.entities.binary_sensor")
local DOOR = { key = 801, ref = "801", name = "Back Door", device_class = "door" }

--- The back door is discovered again, and the contact binding it has.
local function discoverDoor()
  local sensor = BinarySensorEntity:new({})
  sensor:discovered(DOOR)
  return sensor, bindings:getDynamicBinding(BinarySensorEntity.TYPE, "binary_sensor_801").bindingId
end

H.test("an ESPHome item added before keeps its reading at the update", function()
  local told = bootUpdated()
  T.eq("nothing is told at its start", told, {})
  T.eq("its kept states stay", persist:get("BinarySensorStates"), { ["801"] = "CLOSED", ["802"] = "OPENED" })
  T.eq("and it is not marked added", persist:get(MARKER), nil)
  local sensor, contact = discoverDoor()
  H.clearSent()
  sensor:updated(DOOR, { state = true })
  T.eq("the open door still reads Closed, silently", H.count("STATE_CLOSED", contact), 1)
  T.eq("not as a change", H.count("OPENED", contact) + H.count("CLOSED", contact), 0)
end)

H.test("setting an ESPHome item to Opened tells its contacts silently", function()
  bootUpdated()
  local sensor, contact = discoverDoor()
  H.clearSent()
  setReading("Opened")
  T.eq("the open door is told Opened, silently", H.count("STATE_OPENED", contact), 1)
  T.eq("not as a change", H.count("OPENED", contact), 0)
  T.eq("a sensor not discovered has its kept state forgotten", persist:get("BinarySensorStates")["802"], nil)
  H.clearSent()
  sensor:updated(DOOR, { state = true })
  T.eq("the door still open tells nothing", H.count("STATE_OPENED", contact) + H.count("OPENED", contact), 0)
  sensor:updated(DOOR, { state = false })
  T.eq("and its closing is told as a change", H.count("CLOSED", contact), 1)

  local told = bootTelling({ ["Contact When Active"] = "Opened" }, function() end)
  T.eq("the next load tells nothing", told, {})
  contact = select(2, discoverDoor())
  H.clearSent()
  setReading("Closed")
  T.eq("set back to Closed, the shut door is told Opened, silently", H.count("STATE_OPENED", contact), 1)
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

--- An item added before this build, at its first load of it: the tag home in the Kitchen, told
--- Closed with the Kitchen, as before.
local function bootCoordinatorUpdated()
  return bootTelling(
    nil,
    restart(function()
      persist:set("PresenceDevices", { [MAC] = { mac = MAC, name = "Test Tag" } })
      persist:set("PresenceStates", { device_020000000001 = "CLOSED", room_11 = "CLOSED" })
      persist:set("PresenceRooms", { [MAC] = { id = 11, name = "Kitchen" } })
      persist:delete(MARKER)
      persist:delete("ContactReading")
    end),
    function()
      connectProxies()
      inKitchen(7)
    end
  )
end

H.test("a Coordinator added before keeps its reading at the update, with nothing fired", function()
  local told, fired = bootCoordinatorUpdated()
  local changes = {}
  for _, s in ipairs(told) do
    if s.command == "OPENED" or s.command == "CLOSED" then
      changes[#changes + 1] = s.command
    end
  end
  T.eq("no contact is told a change", changes, {})
  T.eq("nothing fires", fired, {})
  T.eq("the tag is still home, read Closed", persist:get("PresenceStates").device_020000000001, "CLOSED")
  T.eq("and the Kitchen occupied", persist:get("PresenceStates").room_11, "CLOSED")
end)

H.test("setting a Coordinator to Opened tells Present and Occupied silently, with nothing fired", function()
  bootCoordinatorUpdated()
  local told, fired = bootTelling(nil, restart(), function()
    connectProxies()
    inKitchen(3)
    H.clearSent()
    setReading("Opened")
  end)
  T.eq("its Present is told Opened, silently", toldIn(told, "presence", "device_020000000001"), { "STATE_OPENED" })
  T.eq("the Kitchen's Occupied too", toldIn(told, "presence", "room_11"), { "STATE_OPENED" })
  T.eq("nothing fires", fired, {})
  T.eq("the tag is still home, read Opened", persist:get("PresenceStates").device_020000000001, "OPENED")
end)

for _, driver in ipairs({ "esphome", "esphome_switchbot", "esphome_bluetooth_coordinator" }) do
  H.use(driver)
  H.test(driver .. " marks an item Director adds, and only that", function()
    H.boot(nil, function()
      persist:delete(MARKER)
    end)
    OnDriverInit("DIT_UPDATING")
    T.eq("an update leaves it unmarked", persist:get(MARKER), nil)
    OnDriverInit("DIT_STARTUP")
    T.eq("and so does a start", persist:get(MARKER), nil)
    OnDriverInit("DIT_ADDING")
    T.eq("adding marks it", persist:get(MARKER), true)
  end)
end

T.finish()
