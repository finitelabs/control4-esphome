--- Tests how the esphome_yale driver recovers when it cannot reach the lock:
---
--- - Persistent mode gives up after its reconnect attempts. A later
---   advertisement starts a fresh round, no sooner than five minutes after, so
---   a lock that comes back in range reconnects and one that stays away costs
---   no connection attempts.
--- - The lock proxy is told the lock is offline when the reconnects run out and
---   when the ESPHome connection is removed, once each time.
--- - Poll mode with no Offline Key stops polling and says why, and a key
---   entered later starts it again.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_recovery.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local yale_protocol = require("esphome.ble.yale_protocol")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local OFFLINE_KEY = string.rep("0123456789ABCDEF", 2)
local PERSISTENT = { ["Connection Mode"] = "Persistent", ["Offline Key"] = OFFLINE_KEY }
local MAC = "AA:BB:CC:DD:EE:FF"

local SERVICES = SerializeSafe({
  {
    uuid = H.uuidPairs(yale_protocol.UUID.SERVICE),
    characteristics = {
      { uuid = H.uuidPairs(yale_protocol.UUID.WRITE), handle = 20 },
      { uuid = H.uuidPairs(yale_protocol.UUID.READ), handle = 22 },
      { uuid = H.uuidPairs(yale_protocol.UUID.SECURE_WRITE), handle = 24 },
      { uuid = H.uuidPairs(yale_protocol.UUID.SECURE_READ), handle = 26 },
    },
  },
})

-- A clock the test steps; the driver reads it through os.time.
local now = 1000000
local realTime = os.time
os.time = function(date) -- luacheck: ignore
  return date and realTime(date) or now
end

local function advertise()
  H.rfp(ESPHOME, "BLE_ADVERTISEMENT", { mac = MAC, advertisement = SerializeSafe({ rssi = -60 }) })
end

local function failConnect()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "Connection timed out" })
end

--- The ONLINE_CHANGED states told to the lock proxy since the last clearSent.
local function toldOnline()
  local states = {}
  for _, s in ipairs(H.sent) do
    if s.command == "ONLINE_CHANGED" and s.binding == PROXY then
      table.insert(states, tostring(s.params.STATE))
    end
  end
  return states
end

H.test("Persistent: after its reconnects run out, an advertisement five minutes later starts a fresh round", function()
  H.boot(PERSISTENT)
  advertise()
  T.eq("the first advertisement connects", H.count("CONNECT", ESPHOME), 1)
  for _ = 1, 5 do
    failConnect()
    H.fire("Reconnect")
  end
  H.clearSent()
  failConnect()
  T.eq("the sixth failure gives up", Properties["Driver Status"], "Listening (reconnect failed)")
  T.falsy("with no reconnect armed", H.armed("Reconnect"))
  T.eq("and tells the lock proxy the lock is offline", toldOnline(), { "false" })

  H.clearSent()
  now = now + 60
  advertise()
  T.eq("an advertisement a minute later connects nothing", H.count("CONNECT", ESPHOME), 0)
  now = now + 300
  advertise()
  T.eq("one five minutes after giving up starts a fresh round", H.count("CONNECT", ESPHOME), 1)
end)

H.test("removing the ESPHome connection tells the lock proxy the lock is offline, once", function()
  H.boot(PERSISTENT)
  advertise()
  H.clearSent()
  OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", false)
  T.eq("offline is told", toldOnline(), { "false" })
  H.clearSent()
  OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", false)
  T.eq("and not again", toldOnline(), {})
end)

H.test("Poll: with no Offline Key it stops polling and says why, and a key entered later starts it again", function()
  H.boot({})
  H.rfp(PROXY, "LOCK")
  H.rfp(ESPHOME, "CONNECTED", { name = "Front Door", mac = MAC, services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
  H.fire("DisconnectDelay")
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "requested" })
  T.falsy("no poll is armed", H.armed("PollCycle"))
  T.eq("Driver Status says why", Properties["Driver Status"], "Error: Offline key required")

  H.clearSent()
  Properties["Offline Key"] = OFFLINE_KEY
  OnPropertyChanged("Offline Key")
  T.eq("an Offline Key puts it back to listening", Properties["Driver Status"], "Listening")
  advertise()
  T.eq("and the next advertisement reads the lock", H.count("CONNECT", ESPHOME), 1)
end)

T.finish()
