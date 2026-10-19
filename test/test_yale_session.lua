--- Tests the esphome_yale session, from connect to a lock operation, against the
--- frames and timing a real lock produces.
---
--- The lock answers the key exchange before its write is acknowledged, so the
--- init command goes out on the same handle with that write still pending. The
--- parent keys write callbacks by handle, so the older write reports
--- "Superseded by a newer request". The driver took that for a failed handshake
--- and disconnected, so every connect failed: Poll mode never read the lock and
--- Persistent mode gave up after its retries.
---
--- A command or advertisement that arrived while a connect was still in flight
--- also sent a second CONNECT. The parent rediscovered services for it and the
--- first attempt failed with "GATT discovery failed", dropping a queued lock or
--- unlock. A connect that failed outright dropped it too, where a lost link
--- kept it for the retry.
---
--- A notification subscription that failed only logged an error: the lock's
--- answers never arrived and nothing retried.
---
--- After the ack for a lock or unlock, the lock sends the motor's result when it
--- stops. The driver read that frame's checksum byte as the lock's state, so
--- every lock and unlock showed unknown until the next status read, and a motor
--- that stalled went unreported.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_session.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local yale_protocol = require("esphome.ble.yale_protocol")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local OFFLINE_KEY = string.rep("0123456789ABCDEF", 2)
local POLL = { ["Offline Key"] = OFFLINE_KEY }
local PERSISTENT = { ["Connection Mode"] = "Persistent", ["Offline Key"] = OFFLINE_KEY }
local MAC = "AA:BB:CC:DD:EE:FF"
local SUPERSEDED = "Superseded by a newer request"

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

-- The shim models only padded AES-128-CBC, and the lock never sees what is
-- written here: pass blocks through both ways so the lock's answers can be
-- written as plaintext.
function C4:Encrypt(_cipher, _key, _iv, data)
  return data
end
function C4:Decrypt(_cipher, _key, _iv, data)
  return data
end

--- 18 bytes from hex.
local function fromHex(hex)
  return (hex:gsub("%x%x", function(byte)
    return string.char(tonumber(byte, 16))
  end))
end

--- An 18-byte secure-read notification carrying `opcode`.
local function secureAnswer(opcode)
  return C4:Base64Encode(string.char(opcode) .. string.rep("\0", 3) .. "LOCKBYTE" .. string.rep("\0", 6))
end

local function lock()
  H.rfp(PROXY, "LOCK")
end

local function connected()
  H.rfp(ESPHOME, "CONNECTED", { name = "Front Door", mac = MAC, services = SERVICES })
end

--- Up to the key exchange being on the wire.
local function startHandshake()
  connected()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
end

local function keyExchangeAnswered()
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", {
    handle = "26",
    data = secureAnswer(yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP),
  })
end

local function initAnswered()
  H.rfp(
    ESPHOME,
    "GATT_NOTIFY_DATA",
    { handle = "26", data = secureAnswer(yale_protocol.Opcode.SEC_INITIALIZATION_RESP) }
  )
end

--- From CONNECTED to the queued command on the wire.
local function session()
  startHandshake()
  keyExchangeAnswered()
  initAnswered()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "true" })
end

--- A regular-read notification, as the lock's frame in hex.
local function lockSays(hex)
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", { handle = "22", data = C4:Base64Encode(fromHex(hex)) })
end

local function writeAnswered(success, err)
  H.rfp(ESPHOME, "GATT_WRITE_RESPONSE", { success = success and "true" or "false", error = err or "0" })
end

--- The command the armed Reconnect will retry.
local function retryCommand()
  local fn = TimerFunctions[Timer.Reconnect]
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if name == nil or name == "retryCommand" then
      return value
    end
  end
end

for _, mode in ipairs({ { name = "Poll", props = POLL }, { name = "Persistent", props = PERSISTENT } }) do
  H.test(mode.name .. ": the init write superseding the key exchange's does not fail the handshake", function()
    H.boot(mode.props)
    lock()
    startHandshake()
    keyExchangeAnswered()
    T.eq("the init command follows the key exchange on the secure write handle", H.count("GATT_WRITE", ESPHOME), 2)
    T.eq("on handle 24", H.sent[#H.sent].params.handle, "24")

    -- The parent's answer for the key exchange write, then the init write's own
    writeAnswered(false, SUPERSEDED)
    writeAnswered(true)
    T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
    T.truthy("the handshake is still timed", H.armed("HandshakeTimeout"))

    initAnswered()
    T.eq("the handshake completes", H.variable("Connected"), true)
    T.falsy("and its timeout is cancelled", H.armed("HandshakeTimeout"))
    T.eq("the regular read is subscribed next", H.sent[#H.sent].command, "GATT_NOTIFY")
    T.eq("on handle 22", H.sent[#H.sent].params.handle, "22")
  end)
end

H.test("any other failed handshake write still fails the handshake", function()
  H.boot(POLL)
  lock()
  startHandshake()
  keyExchangeAnswered()
  writeAnswered(false, "133")
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.truthy("and waits for the next poll", H.armed("PollCycle"))
end)

H.test("a lock while the connect is in flight waits for it instead of connecting again", function()
  H.boot(PERSISTENT)
  EC.Request_Status()
  T.eq("the status read connects", H.count("CONNECT", ESPHOME), 1)
  lock()
  T.eq("the lock does not connect again", H.count("CONNECT", ESPHOME), 1)

  -- Failing the attempt hands its queued command to recovery
  T.truthy("the connect timeout fires", H.fire("ConnectionTimeout"))
  T.eq("the lock is what gets retried", retryCommand(), "lock")
end)

H.test("an advertisement while the connect is in flight does not connect again", function()
  H.boot(PERSISTENT)
  H.rfp(ESPHOME, "BLE_ADVERTISEMENT", { mac = MAC })
  T.eq("the first advertisement auto-connects", H.count("CONNECT", ESPHOME), 1)
  H.rfp(ESPHOME, "BLE_ADVERTISEMENT", { mac = MAC })
  T.eq("the next one waits for it", H.count("CONNECT", ESPHOME), 1)
end)

H.test("a notification subscription that never answers times out", function()
  H.boot(POLL)
  lock()
  connected()
  T.truthy("the handshake timeout covers the subscription", H.armed("HandshakeTimeout"))
  T.truthy("it fires", H.fire("HandshakeTimeout"))
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.truthy("and waits for the next poll", H.armed("PollCycle"))

  H.clearSent()
  T.truthy("the poll fires", H.fire("PollCycle"))
  T.eq("and connects again", H.count("CONNECT", ESPHOME), 1)
end)

H.test("a failed connect retries the lock it was making, like a lost link does", function()
  H.boot(PERSISTENT)
  lock()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "GATT discovery failed" })
  T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
  T.eq("the lock is what gets retried", retryCommand(), "lock")
end)

H.test("a failed subscription ends the attempt", function()
  H.boot(POLL)
  lock()
  connected()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "false", error = "133" })
  T.eq("it sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
  T.truthy("and waits for the next poll", H.armed("PollCycle"))
end)

H.test("a superseded subscription is left to the newer one", function()
  H.boot(POLL)
  lock()
  connected()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "false", error = SUPERSEDED })
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
  T.eq("the newer answer starts the handshake", H.sent[#H.sent].command, "GATT_WRITE")
end)

-- Frames a lock sent for a LOCK: the ack, then the motor's result when it stops.
local LOCK_ACK = "aa0b00490000000000000000000000000200"
local LOCK_DONE = "bb0b003a0000000000000000000000000000"
local LOCK_STALLED = "bb0b003a00000000000000000000001e0000"

H.test("the motor's result after a lock is not read as the lock's state", function()
  H.boot(POLL)
  lock()
  session()
  T.eq("the lock goes out on the write handle", H.sent[#H.sent].params.handle, "20")
  lockSays(LOCK_ACK)
  T.eq("the ack reports locked", Properties["Lock Status"], "locked")
  lockSays(LOCK_DONE)
  T.eq("a successful result leaves it locked", Properties["Lock Status"], "locked")
  T.truthy("and the status read still follows", H.armed("StatusPoll"))
end)

H.test("a lock the motor could not finish reports a fault", function()
  H.boot(POLL)
  lock()
  session()
  lockSays(LOCK_ACK)
  lockSays(LOCK_STALLED)
  T.eq("the lock shows a fault", Properties["Lock Status"], "fault")
end)

H.test("the parser reads status frames from their data bytes", function()
  local status = yale_protocol.parseResponse(fromHex("bb02003a0200000005000000000000000200"))
  T.eq("a lock status frame carries the lock's state", status.lockStatus, yale_protocol.LockStatus.LOCKED)
  local done = yale_protocol.parseResponse(fromHex(LOCK_DONE))
  T.eq("a lock result frame carries no lock state", done.lockStatus, nil)
  T.eq("only the operation result", done.operationResult, 0)
  T.eq("which names a stall", yale_protocol.parseResponse(fromHex(LOCK_STALLED)).operationResult, 0x1E)
end)

H.test("a stale write failure while connecting does not end the attempt", function()
  H.boot(POLL)
  lock()
  writeAnswered(false, "133")
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  T.truthy("the connect is still timed", H.armed("ConnectionTimeout"))
end)

T.finish()
