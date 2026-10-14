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
local realDecrypt = C4.Decrypt
function C4:Decrypt(cipher, key, iv, data, options)
  if cipher == "AES-128-ECB" then
    return data
  end
  return realDecrypt(self, cipher, key, iv, data, options)
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

--- The lock's answer on the secure read: an 18-byte block led by its opcode.
--- @param opcode integer
local function secureAnswer(opcode)
  local block = string.char(opcode) .. string.rep("\0", 17)
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", { handle = "26", data = C4:Base64Encode(block) })
end

--- Through the handshake, up to the regular-read subscription being sent.
local function handshakeDone()
  startHandshake()
  secureAnswer(yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP)
  secureAnswer(yale_protocol.Opcode.SEC_INITIALIZATION_RESP)
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
  T.eq("which outlasts the parent's own", H.delay("ConnectionTimeout"), 200000)

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

H.test("a CONNECTION_FAILED after the timeout is not a second failure", function()
  H.boot(PERSISTENT)
  lock()
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  T.eq("the timeout is the first retry", Properties["Driver Status"], "Reconnecting (1/5)")

  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "timeout" })
  T.eq("the late answer leaves it the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("still retrying the lock", retryCommand(), "lock")
end)

H.test("a CONNECTION_FAILED that lands once connected leaves the link alone", function()
  H.boot(PERSISTENT)
  lock()
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  H.fire("Reconnect")
  startHandshake()
  H.clearSent()

  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "timeout" })
  T.eq("it stays the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.falsy("nothing is scheduled to reconnect", H.armed("Reconnect"))
  T.truthy("and the handshake is still waiting on the lock", H.armed("HandshakeTimeout"))
end)

--- A forwarded advertisement from the lock.
local function advertised()
  H.rfp(ESPHOME, "BLE_ADVERTISEMENT", { mac = "AA:BB:CC:DD:EE:FF", advertisement = SerializeSafe({ rssi = -60 }) })
end

H.test("in Persistent mode advertisements cannot hold a connect timeout off", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  T.eq("UNLOCK asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
  advertised()
  advertised()
  T.eq("the advertisements send no CONNECT", H.count("CONNECT", ESPHOME), 1)
  T.truthy("the timeout fires", H.fire("ConnectionTimeout"))
  T.eq("and retries the unlock", retryCommand(), "unlock")
end)

H.test("in Poll mode the first advertisement during a connect sends nothing", function()
  H.boot({ ["Connection Mode"] = "Poll", ["Offline Key"] = OFFLINE_KEY })
  H.rfp(PROXY, "UNLOCK")
  T.eq("UNLOCK asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
  advertised()
  T.eq("the advertisement sends no CONNECT", H.count("CONNECT", ESPHOME), 1)
end)

for _, mode in ipairs({ "Persistent", "Poll" }) do
  H.test("in " .. mode .. " mode a freshly bound lock whose parent's own connect fails still connects", function()
    H.boot({ ["Connection Mode"] = mode, ["Offline Key"] = OFFLINE_KEY })
    OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", true)
    H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
    H.fire("Reconnect")
    H.fire("PollCycle")
    advertised()
    T.eq("it asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
  end)
end

for _, mode in ipairs({ "Persistent", "Poll" }) do
  H.test("in " .. mode .. " mode a lock freshly bound to a parent that does not connect it connects", function()
    -- The coordinator connects nothing at bind.
    H.boot({ ["Connection Mode"] = mode, ["Offline Key"] = OFFLINE_KEY })
    OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", true)
    advertised()
    T.eq("its first advertisement asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
    T.eq("and brings it online", Properties["Driver Status"], "Listening")
  end)
end

H.test("a failed secure-read subscription releases the link and retries the unlock", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  connected()
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "false" })
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("and retries the unlock", retryCommand(), "unlock")
  T.falsy("the setup timeout is cancelled", H.armed("SubscribeTimeout"))
end)

H.test("a secure-read subscription nobody answers releases the link and retries the unlock", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  connected()
  T.truthy("CONNECTED arms the setup timeout", H.armed("SubscribeTimeout"))
  T.eq("which outlasts the parent's notify and descriptor waits", H.delay("SubscribeTimeout"), 25000)
  H.clearSent()
  T.truthy("the timeout fires", H.fire("SubscribeTimeout"))
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("and retries the unlock", retryCommand(), "unlock")
end)

H.test("the subscription answer hands over to the handshake timeout", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  startHandshake()
  T.falsy("the setup timeout is cancelled", H.armed("SubscribeTimeout"))
  T.truthy("and the handshake timeout armed", H.armed("HandshakeTimeout"))
end)

H.test("a failed subscription answer to an abandoned attempt is not a second failure", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  connected()
  H.fire("SubscribeTimeout")
  disconnectAnswered()
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "false" })
  T.eq("nothing more is sent", H.count("DISCONNECT", ESPHOME), 0)
  T.eq("it stays the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("still retrying the unlock", retryCommand(), "unlock")
end)

H.test("in Persistent mode an advertisement between CONNECTED and the handshake keeps the unlock", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  connected()
  advertised()
  T.eq("the advertisement sends no CONNECT", H.count("CONNECT", ESPHOME), 1)
  T.falsy("nor re-arms the connect timeout", H.armed("ConnectionTimeout"))
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("the unlock is the command retried", retryCommand(), "unlock")
end)

H.test("in Persistent mode the first advertisement connects and the next ones wait for it", function()
  H.boot(PERSISTENT)
  advertised()
  T.eq("the first advertisement asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
  T.truthy("under the connect timeout", H.armed("ConnectionTimeout"))
  advertised()
  T.eq("the next one sends no CONNECT", H.count("CONNECT", ESPHOME), 1)
end)

H.test("in Poll mode the first advertisement with nothing queued reads status", function()
  H.boot({ ["Connection Mode"] = "Poll", ["Offline Key"] = OFFLINE_KEY })
  advertised()
  T.eq("it asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
  advertised()
  T.eq("once", H.count("CONNECT", ESPHOME), 1)
end)

H.test("in Poll mode a lock rebound after its first status read connects when the parent's connect fails", function()
  H.boot({ ["Connection Mode"] = "Poll", ["Offline Key"] = OFFLINE_KEY })
  advertised()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
  OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", true)
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
  H.clearSent()
  advertised()
  T.eq("it asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
end)

H.test("in Poll mode a running lock moved to the coordinator connects on its next advertisement", function()
  H.boot({ ["Connection Mode"] = "Poll", ["Offline Key"] = OFFLINE_KEY })
  advertised()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
  OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", true)
  H.clearSent()
  advertised()
  T.eq("it asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
end)

for _, mode in ipairs({ "Persistent", "Poll" }) do
  H.test("in " .. mode .. " mode an advertisement after the parent's bind-time CONNECTED sends nothing", function()
    H.boot({ ["Connection Mode"] = mode, ["Offline Key"] = OFFLINE_KEY })
    OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", true)
    connected()
    advertised()
    T.eq("no CONNECT goes over the link being set up", H.count("CONNECT", ESPHOME), 0)
  end)
end

H.test("in Poll mode an advertisement between CONNECTED and the handshake sends nothing", function()
  H.boot({ ["Connection Mode"] = "Poll", ["Offline Key"] = OFFLINE_KEY })
  H.rfp(PROXY, "UNLOCK")
  connected()
  advertised()
  T.eq("the advertisement sends no CONNECT", H.count("CONNECT", ESPHOME), 1)
  T.falsy("nor re-arms the connect timeout", H.armed("ConnectionTimeout"))
end)

H.test("in Poll mode an advertisement during a Request Status connect sends nothing", function()
  H.boot({ ["Connection Mode"] = "Poll", ["Offline Key"] = OFFLINE_KEY })
  EC.Request_Status()
  advertised()
  T.eq("one CONNECT", H.count("CONNECT", ESPHOME), 1)
end)

H.test("the parent closing the link after its CONNECTION_FAILED is not a second failure", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "timeout" })
  T.eq("the failure is the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("the close leaves it the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.truthy("with the reconnect still armed", H.armed("Reconnect"))
end)

H.test("a failed subscription answer for a dropped link leaves the retry's connect alone", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  connected()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  H.fire("Reconnect")
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "false" })
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  T.eq("it stays the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.truthy("and the retry's connect timeout is still armed", H.armed("ConnectionTimeout"))
end)

H.test("a subscription answer after the setup timeout starts no handshake", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  connected()
  H.fire("SubscribeTimeout")
  disconnectAnswered()
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
  T.eq("no key exchange is written", H.count("GATT_WRITE", ESPHOME), 0)
  T.falsy("no handshake timeout is armed", H.armed("HandshakeTimeout"))
  T.eq("it stays the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
end)

H.test("the regular-read subscription sends the queued unlock once answered", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  handshakeDone()
  T.eq("the handshake connects", Properties["Driver Status"], "Connected")
  T.truthy("the regular-read subscription is under the setup timeout", H.armed("SubscribeTimeout"))
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "true" })
  T.falsy("the answer cancels it", H.armed("SubscribeTimeout"))
  T.eq("and the unlock goes to the write handle", H.count("GATT_WRITE", ESPHOME), 1)
  T.eq("on handle 20", H.sent[#H.sent].params.handle, "20")
end)

H.test("a failed regular-read subscription releases the link and retries the unlock", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  handshakeDone()
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "false" })
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("Connected is false", H.variable("Connected"), false)
  T.eq("and retries the unlock", retryCommand(), "unlock")
end)

H.test("a regular-read subscription nobody answers releases the link and retries the unlock", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  handshakeDone()
  H.clearSent()
  T.truthy("the timeout fires", H.fire("SubscribeTimeout"))
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("and retries the unlock", retryCommand(), "unlock")
end)

--- Persistent mode, every retry of a lock spent on a connect nobody answers.
local function retriesRunOut()
  H.boot(PERSISTENT)
  lock()
  for _ = 1, 5 do
    H.fire("ConnectionTimeout")
    H.fire("Reconnect")
  end
  H.fire("ConnectionTimeout")
end

H.test("a failed connect by the parent restarts the retries once they have run out", function()
  retriesRunOut()
  T.eq("the retries run out", Properties["Driver Status"], "Listening (reconnect failed)")
  T.falsy("with nothing armed", H.armed("Reconnect"))

  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
  T.eq("the parent's failure starts a fresh round", Properties["Driver Status"], "Reconnecting (1/5)")
  T.truthy("the reconnect is armed", H.armed("Reconnect"))
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
  T.eq("a second one does not spend an attempt", Properties["Driver Status"], "Reconnecting (1/5)")
end)

H.test("once the retries have run out a late failure leaves a tap's link being set up alone", function()
  retriesRunOut()
  H.rfp(PROXY, "UNLOCK")
  connected()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "timeout" })
  T.falsy("nothing is scheduled to reconnect", H.armed("Reconnect"))
  T.truthy("and the subscription is still waited on", H.armed("SubscribeTimeout"))
end)

H.test("once the retries have run out a late failure leaves the parent's handshake alone", function()
  retriesRunOut()
  startHandshake()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "timeout" })
  T.falsy("nothing is scheduled to reconnect", H.armed("Reconnect"))
  T.truthy("and the handshake is still waiting on the lock", H.armed("HandshakeTimeout"))
end)

H.test("a failed regular-read answer for a dropped link leaves the retry's connect alone", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  handshakeDone()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  H.fire("Reconnect")
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "false" })
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  T.eq("it stays the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
end)

H.test("a failed subscription on the parent's bind-time link releases it at once", function()
  H.boot(PERSISTENT)
  OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", true)
  connected()
  H.clearSent()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "false" })
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
end)

H.test("a second answer to the secure-read subscription starts no second handshake", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  startHandshake()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
  T.eq("one key exchange", H.count("GATT_WRITE", ESPHOME), 1)
end)

--- The proxy's answer to a subscription a newer one to the same handle replaced.
local function superseded()
  H.rfp(
    ESPHOME,
    "GATT_NOTIFY_SUBSCRIBED",
    { handle = "26", success = "false", error = "Superseded by a newer request" }
  )
end

H.test("in Poll mode an unlock tapped while the parent's link subscribes outlives the superseded answer", function()
  H.boot({ ["Connection Mode"] = "Poll", ["Offline Key"] = OFFLINE_KEY })
  OBC[ESPHOME](ESPHOME, "ESPHOME_YALE", true)
  connected()
  H.rfp(PROXY, "UNLOCK")
  -- The direct parent answers a CONNECT for a connected lock at once
  connected()
  H.clearSent()
  superseded()
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
  T.eq("the newer answer starts the handshake", H.count("GATT_WRITE", ESPHOME), 1)
end)

H.test("a dropped link's subscription superseded by the retry's leaves the retry alone", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "UNLOCK")
  connected()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  H.fire("Reconnect")
  connected()
  H.clearSent()
  superseded()
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  T.eq("it stays the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.truthy("and the retry's subscription is still waited on", H.armed("SubscribeTimeout"))
end)

H.test("once the retries have run out the parent closing the link after its failure is not a second one", function()
  H.boot(PERSISTENT)
  lock()
  for _ = 1, 6 do
    connected()
    H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
    H.fire("Reconnect")
  end
  T.eq("the retries run out on dropped links", Properties["Driver Status"], "Listening (reconnect failed)")
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "Connection failed with code 133" })
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("the close leaves it the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
end)

H.test("once the retries have run out a late failure leaves the parent's link being set up alone", function()
  retriesRunOut()
  connected()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "GATT discovery failed" })
  T.falsy("nothing is scheduled to reconnect", H.armed("Reconnect"))
  T.truthy("and the subscription is still waited on", H.armed("SubscribeTimeout"))
end)

T.finish()
