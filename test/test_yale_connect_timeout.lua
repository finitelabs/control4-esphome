--- Tests that the esphome_yale driver gives up on a CONNECT its parent never
--- answers. Neither CONNECTED nor CONNECTION_FAILED comes back when the message is
--- lost or the proxy restarts mid-connect, and before the timeout the queued
--- command and the connecting state then sat there until something else reset
--- them. The timeout has to free the proxy slot and hand over to the driver's
--- recovery path.
---
--- It and the handshake failures both send DISCONNECT and schedule recovery
--- themselves. The coordinator answers every DISCONNECT with DISCONNECTED, which
--- used to schedule recovery a second time: two reconnect attempts spent on one
--- failure, and a queued lock or unlock retried as a status read.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_connect_timeout.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local yale_protocol = require("esphome.ble.yale_protocol")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local OFFLINE_KEY = string.rep("0123456789ABCDEF", 2)
local PERSISTENT = { ["Connection Mode"] = "Persistent", ["Offline Key"] = OFFLINE_KEY }

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

-- The shim models only AES-128-CBC. The lock never answers the key exchange in
-- these cases, so what the handshake write carries does not matter: pass the
-- block through for ECB so startHandshake can send it.
local realEncrypt = C4.Encrypt
function C4:Encrypt(cipher, key, iv, data, options)
  if cipher == "AES-128-ECB" then
    return data
  end
  return realEncrypt(self, cipher, key, iv, data, options)
end

local function lock()
  H.rfp(PROXY, "LOCK")
end

local function connected()
  H.rfp(ESPHOME, "CONNECTED", { name = "Front Door", mac = "AA:BB:CC:DD:EE:FF", services = SERVICES })
end

--- Up to the key exchange being on the wire, awaiting the lock's answer.
local function startHandshake()
  connected()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
end

--- The coordinator's answer to a DISCONNECT.
local function disconnectAnswered()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "Requested" })
end

--- The command the armed Reconnect will retry. It only reaches the wire after a
--- full handshake, which the shim cannot run, so read it from the timer.
local function retryCommand()
  local fn = TimerFunctions[Timer.Reconnect]
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if name == nil or name == "retryCommand" then
      return value
    end
  end
end

H.test("a CONNECT nobody answers times out, frees the slot and polls again", function()
  H.boot()
  lock()
  T.eq("LOCK asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
  T.truthy("and arms the connect timeout", H.armed("ConnectionTimeout"))

  T.truthy("the timeout fires", H.fire("ConnectionTimeout"))
  T.eq("it sends DISCONNECT so the parent frees any half-open slot", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("Connected is false", H.variable("Connected"), false)
  T.eq("the driver waits for the next poll", Properties["Driver Status"], "Listening (next poll in 60s)")
  T.truthy("the poll is armed", H.armed("PollCycle"))

  H.clearSent()
  T.truthy("the poll fires", H.fire("PollCycle"))
  T.eq("and connects again", H.count("CONNECT", ESPHOME), 1)
  T.truthy("under a fresh timeout", H.armed("ConnectionTimeout"))
end)

H.test("the parent's DISCONNECTED answer to that DISCONNECT leaves recovery armed", function()
  -- The coordinator answers every DISCONNECT, connected or not.
  H.boot()
  lock()
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  T.eq("Connected stays false", H.variable("Connected"), false)
  T.truthy("the poll is still armed", H.armed("PollCycle"))
  T.falsy("and no connect timeout is left behind", H.armed("ConnectionTimeout"))
end)

H.test("in Persistent mode the timeout retries the command with backoff", function()
  H.boot(PERSISTENT)
  lock()
  T.truthy("the timeout fires", H.fire("ConnectionTimeout"))
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("Connected is false", H.variable("Connected"), false)
  T.truthy("the reconnect is armed", H.armed("Reconnect"))

  H.clearSent()
  T.truthy("the reconnect fires", H.fire("Reconnect"))
  T.eq("and connects again", H.count("CONNECT", ESPHOME), 1)
  T.truthy("under a fresh timeout", H.armed("ConnectionTimeout"))
end)

H.test("in Persistent mode the answer to that DISCONNECT is not a second failure", function()
  H.boot(PERSISTENT)
  lock()
  H.fire("ConnectionTimeout")
  T.eq("the timeout is the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("which retries the lock", retryCommand(), "lock")

  disconnectAnswered()
  T.eq("the answer leaves it the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.truthy("with the reconnect still armed", H.armed("Reconnect"))
  T.eq("and still retrying the lock", retryCommand(), "lock")

  H.clearSent()
  T.truthy("the reconnect fires", H.fire("Reconnect"))
  T.eq("and connects again", H.count("CONNECT", ESPHOME), 1)
end)

H.test("a handshake the lock never answers times out once, whatever the parent answers", function()
  H.boot(PERSISTENT)
  lock()
  startHandshake()
  T.eq("the key exchange goes to the secure write handle", H.count("GATT_WRITE", ESPHOME), 1)
  T.eq("on handle 24", H.sent[#H.sent].params.handle, "24")

  T.truthy("the handshake timeout fires", H.fire("HandshakeTimeout"))
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")

  disconnectAnswered()
  T.eq("the answer leaves it the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("still retrying the lock", retryCommand(), "lock")

  H.clearSent()
  T.truthy("the reconnect fires", H.fire("Reconnect"))
  T.eq("and connects again", H.count("CONNECT", ESPHOME), 1)
end)

H.test("a failed handshake write fails once, whatever the parent answers", function()
  H.boot(PERSISTENT)
  lock()
  startHandshake()
  H.rfp(ESPHOME, "GATT_WRITE_RESPONSE", { success = "false", error = "133" })
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.falsy("the handshake timeout is cancelled", H.armed("HandshakeTimeout"))

  disconnectAnswered()
  T.eq("the answer leaves it the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("and retries the lock", retryCommand(), "lock")
end)

H.test("a write answer that arrives after the attempt is over is not a second failure", function()
  H.boot(PERSISTENT)
  lock()
  startHandshake()
  H.fire("HandshakeTimeout")
  H.rfp(ESPHOME, "GATT_WRITE_RESPONSE", { success = "false", error = "133" })
  T.eq("only the timeout disconnected", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("it stays the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("still retrying the lock", retryCommand(), "lock")
end)

H.test("a link dropped mid-handshake still recovers, after an earlier failure too", function()
  H.boot(PERSISTENT)
  lock()
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  H.fire("Reconnect")

  -- The retry connects, so a DISCONNECTED now is the lock going away.
  startHandshake()
  H.clearSent()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("it counts as the second failure", Properties["Driver Status"], "Reconnecting (2/5)")
  T.truthy("the reconnect is armed", H.armed("Reconnect"))
  T.eq("to retry the lock", retryCommand(), "lock")
  T.falsy("the handshake timeout is cancelled", H.armed("HandshakeTimeout"))
  T.eq("nothing more is sent to a link that is gone", H.count("DISCONNECT", ESPHOME), 0)
end)

H.test("CONNECTED cancels the timeout", function()
  H.boot()
  lock()
  connected()
  T.falsy("the timeout is cancelled", H.armed("ConnectionTimeout"))
  T.eq("and the handshake starts with the secure-read subscription", H.count("GATT_NOTIFY", ESPHOME), 1)
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
end)

H.test("CONNECTION_FAILED cancels the timeout", function()
  H.boot()
  lock()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
  T.falsy("the timeout is cancelled", H.armed("ConnectionTimeout"))
  T.truthy("the failure path arms the poll", H.armed("PollCycle"))
end)

T.finish()
