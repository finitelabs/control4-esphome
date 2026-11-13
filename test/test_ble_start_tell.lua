--- Tests what the BTHome and SwitchBot drivers tell their contact and relay
--- consumers. OPENED and CLOSED fire the consumer's programming, so after a
--- restart or a repeated advertisement only a change against the state told
--- before is told that way; anything else goes silently as STATE_OPENED or
--- STATE_CLOSED, once per load.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_start_tell.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local bindings = require("lib.bindings")
local persist = require("lib.persist")

local ESPHOME = 5001
local MAC = "AA:BB:CC:DD:EE:03"

--- The parent relays one advertisement with this service data.
local function advertise(uuid, data)
  H.rfp(ESPHOME, "BLE_ADVERTISEMENT", {
    mac = MAC,
    advertisement = SerializeSafe({ rssi = -60, serviceData = { { uuid = uuid, data = data } } }),
  })
end

--- What one binding was told since the last clear, in order.
local function toldTo(namespace, key)
  local binding = bindings:getDynamicBinding(namespace, key)
  local got = {}
  for _, s in ipairs(H.sent) do
    if binding and s.binding == binding.bindingId then
      got[#got + 1] = s.command
    end
  end
  return got
end

H.use("esphome_bthome")

-- BTHome v2, unencrypted: door (0x1A) open or closed.
local DOOR_OPEN, DOOR_CLOSED = "\64\26\1", "\64\26\0"
local DOOR = "contact_door_1"

H.test("a BTHome contact tells a change as one, and nothing else", function()
  H.boot(nil, function()
    persist:delete("ContactStates")
  end)
  advertise("FCD2", DOOR_CLOSED)
  T.eq("its first state is told silently", toldTo("BTHome", DOOR), { "STATE_CLOSED" })
  advertise("FCD2", DOOR_CLOSED)
  T.eq("the same state again tells nothing more", toldTo("BTHome", DOOR), { "STATE_CLOSED" })
  H.clearSent()
  advertise("FCD2", DOOR_OPEN)
  T.eq("a change is told as one", toldTo("BTHome", DOOR), { "OPENED" })
end)

H.test("after a restart, a BTHome contact's unchanged state fires nothing", function()
  H.boot()
  advertise("FCD2", DOOR_OPEN)
  T.eq("the state told before the restart is told silently", toldTo("BTHome", DOOR), { "STATE_OPENED" })
  H.boot()
  advertise("FCD2", DOOR_CLOSED)
  T.eq("one that changed while the driver was down is told as a change", toldTo("BTHome", DOOR), { "CLOSED" })
end)

H.use("esphome_switchbot")

-- FD3D service data: a Bot (model 'H') in switch mode, on or off.
local BOT_ON, BOT_OFF = "\72\128\100", "\72\192\100"
-- A Contact Sensor (model 'd'): no motion, battery 100, contact closed or open.
local CONTACT_CLOSED, CONTACT_OPEN = "\100\0\100\0", "\100\0\100\2"

H.test("a SwitchBot Bot's relay tells a change as one, and nothing else", function()
  H.boot({ ["MAC Address"] = MAC }, function()
    persist:delete("RelayContactStates")
  end)
  advertise("FD3D", BOT_ON)
  T.eq("its first state is told silently", toldTo("SwitchBot", "botRelay"), { "STATE_CLOSED" })
  advertise("FD3D", BOT_ON)
  T.eq("the same state again tells nothing more", toldTo("SwitchBot", "botRelay"), { "STATE_CLOSED" })
  H.clearSent()
  advertise("FD3D", BOT_OFF)
  T.eq("a change is told as one", toldTo("SwitchBot", "botRelay"), { "OPENED" })

  H.clearSent()
  OnBindingChanged(ESPHOME, "ESPHOME_BLUETOOTH", true, 100, 1)
  advertise("FD3D", BOT_OFF)
  T.eq(
    "after the ESPHome connection is bound again, its state is told again, silently",
    toldTo("SwitchBot", "botRelay"),
    {
      "STATE_OPENED",
    }
  )
end)

H.test("after a restart, a SwitchBot Bot's unchanged state fires nothing", function()
  H.boot({ ["MAC Address"] = MAC })
  advertise("FD3D", BOT_OFF)
  T.eq("the state told before the restart is told silently", toldTo("SwitchBot", "botRelay"), { "STATE_OPENED" })
  H.boot({ ["MAC Address"] = MAC })
  advertise("FD3D", BOT_ON)
  T.eq("one that changed while the driver was down is told as a change", toldTo("SwitchBot", "botRelay"), { "CLOSED" })
end)

H.test("a SwitchBot contact tells an open door OPENED, however long it is open, and a closed one CLOSED", function()
  H.boot({ ["MAC Address"] = MAC }, function()
    persist:delete("RelayContactStates")
    require("lib.values"):delete("Device Type")
  end)
  advertise("FD3D", CONTACT_CLOSED)
  T.eq("closed, first heard: CLOSED, silently", toldTo("SwitchBot", "contact_contact"), { "STATE_CLOSED" })
  T.eq("its Contact reads Closed", H.variable("Contact"), "Closed")
  H.clearSent()
  advertise("FD3D", CONTACT_OPEN)
  T.eq("opened: OPENED", toldTo("SwitchBot", "contact_contact"), { "OPENED" })
  T.eq("its Contact reads Open", H.variable("Contact"), "Open")
  H.clearSent()
  -- SwitchBot's spec gives open too long as 2 in bits 1-2; some decoders read it as 3. Both are open.
  for _, data in ipairs({ "\100\0\100\4", "\100\0\100\6" }) do
    advertise("FD3D", data)
    T.eq("open too long (" .. data:byte(4) .. ") tells nothing more", toldTo("SwitchBot", "contact_contact"), {})
    T.eq("and its Contact still reads Open", H.variable("Contact"), "Open")
  end
  advertise("FD3D", CONTACT_CLOSED)
  T.eq("closed again: CLOSED", toldTo("SwitchBot", "contact_contact"), { "CLOSED" })
end)

-- The Contact Sensor's motion bit: byte 1 bit 6.
local NO_MOTION, MOTION = "\100\0\100\0", "\100\64\100\0"

H.test("a SwitchBot motion sensor tells motion OPENED and no motion CLOSED", function()
  H.boot({ ["MAC Address"] = MAC }, function()
    persist:delete("RelayContactStates")
    require("lib.values"):delete("Device Type")
  end)
  advertise("FD3D", NO_MOTION)
  T.eq("no motion, first heard: CLOSED, silently", toldTo("SwitchBot", "contact_motion"), { "STATE_CLOSED" })
  H.clearSent()
  advertise("FD3D", MOTION)
  T.eq("motion seen: OPENED", toldTo("SwitchBot", "contact_motion"), { "OPENED" })
end)

--- Boot, and return what the late init told each binding and the events it fired, which H.boot
--- would otherwise clear.
local function bootTelling(properties, prepare)
  local told, fired, send, fire = {}, {}, C4.SendToProxy, C4.FireEventByID
  C4.SendToProxy = function(self, idBinding, strCommand, ...)
    table.insert(told, { binding = idBinding, command = strCommand })
    return send(self, idBinding, strCommand, ...)
  end
  C4.FireEventByID = function(self, idEvent, ...)
    table.insert(fired, idEvent)
    return fire(self, idEvent, ...)
  end
  local ok, err = pcall(H.boot, properties, prepare)
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

H.test("after the update, the motion state an earlier build told is corrected silently, once", function()
  -- This build's contact and motion connections, as an update keeps them.
  H.boot({ ["MAC Address"] = MAC }, function()
    persist:delete("RelayContactStates")
    require("lib.values"):delete("Device Type")
  end)
  advertise("FD3D", NO_MOTION)

  -- An earlier build told no motion OPENED; a leak and the Bot's relay already read as they do now.
  local told, fired = bootTelling({ ["MAC Address"] = MAC }, function()
    persist:set("RelayContactStates", { motion = "OPENED", leak = "OPENED", botRelay = "CLOSED" })
    persist:delete("ContactsReadOpened")
  end)
  T.eq("no motion is told it reads CLOSED, silently", toldIn(told, "SwitchBot", "contact_motion"), { "STATE_CLOSED" })
  T.eq("nothing fires", fired, {})
  local kept = persist:get("RelayContactStates", {})
  T.eq("the leak state is left as it was", kept.leak, "OPENED")
  T.eq("and so is the Bot relay's", kept.botRelay, "CLOSED")
  H.clearSent()
  advertise("FD3D", NO_MOTION)
  T.eq("the same reading after it tells nothing", toldTo("SwitchBot", "contact_motion"), {})

  told = bootTelling({ ["MAC Address"] = MAC }, function()
    persist:set("RelayContactStates", { motion = "OPENED" })
  end)
  T.eq("a later load corrects nothing", toldIn(told, "SwitchBot", "contact_motion"), {})
end)

H.test("after the update, a SwitchBot contact told the reverse before is corrected silently", function()
  H.boot({ ["MAC Address"] = MAC }, function()
    -- An earlier build told a shut door OPENED.
    persist:set("RelayContactStates", { contact = "OPENED" })
    persist:delete("ContactsReadOpened")
    require("lib.values"):delete("Device Type")
  end)
  advertise("FD3D", CONTACT_CLOSED)
  T.eq("the shut door is told CLOSED, silently", toldTo("SwitchBot", "contact_contact"), { "STATE_CLOSED" })
  H.clearSent()
  advertise("FD3D", CONTACT_OPEN)
  T.eq("and its next change as one", toldTo("SwitchBot", "contact_contact"), { "OPENED" })
end)

H.test("after the update, a contact already read the right way is left as it is", function()
  -- A build that reads the door the right way keeps it under its own key; an older build's reversed state is
  -- still kept beside it.
  local told, fired = bootTelling({ ["MAC Address"] = MAC }, function()
    persist:set("RelayContactStates", { contact = "CLOSED", door = "CLOSED" })
    persist:delete("ContactsReadOpened")
    require("lib.values"):delete("Device Type")
  end)
  T.eq("nothing is told to the contact at the start", toldIn(told, "SwitchBot", "contact_contact"), {})
  T.eq("nothing fires", fired, {})
  advertise("FD3D", CONTACT_CLOSED)
  T.eq("the shut door's reading is told silently", toldTo("SwitchBot", "contact_contact"), { "STATE_CLOSED" })
  H.clearSent()
  advertise("FD3D", CONTACT_OPEN)
  T.eq("and its next change as one", toldTo("SwitchBot", "contact_contact"), { "OPENED" })
end)

H.test("after the update, a door that opened while the driver was down is told as a change", function()
  H.boot({ ["MAC Address"] = MAC }, function()
    persist:set("RelayContactStates", { door = "CLOSED" })
    persist:delete("ContactsReadOpened")
    require("lib.values"):delete("Device Type")
  end)
  advertise("FD3D", CONTACT_OPEN)
  T.eq("the door that opened is told as a change", toldTo("SwitchBot", "contact_contact"), { "OPENED" })
end)

H.test("a new SwitchBot item has nothing to correct", function()
  local told = bootTelling({ ["MAC Address"] = MAC }, function()
    persist:delete("RelayContactStates")
    persist:delete("ContactsReadOpened")
  end)
  T.eq("nothing is told at its start", toldIn(told, "SwitchBot", "contact_contact"), {})
  T.eq("or to its motion", toldIn(told, "SwitchBot", "contact_motion"), {})
  T.eq("and the correction is marked done", persist:get("ContactsReadOpened"), true)
end)

H.test("after a restart, a SwitchBot contact's unchanged state fires nothing", function()
  H.boot({ ["MAC Address"] = MAC }, function()
    persist:delete("RelayContactStates")
    require("lib.values"):delete("Device Type")
  end)
  advertise("FD3D", CONTACT_OPEN)
  local first = toldTo("SwitchBot", "contact_contact")
  T.eq("its first state is told silently", #first == 1 and first[1]:sub(1, 6) == "STATE_", true)
  H.boot({ ["MAC Address"] = MAC })
  advertise("FD3D", CONTACT_OPEN)
  T.eq("the same state after a restart is told silently", toldTo("SwitchBot", "contact_contact"), first)
  H.boot({ ["MAC Address"] = MAC })
  advertise("FD3D", CONTACT_CLOSED)
  local changed = toldTo("SwitchBot", "contact_contact")
  T.eq("a change while the driver was down is told as one", #changed == 1 and changed[1]:sub(1, 6) ~= "STATE_", true)
end)

T.finish()
