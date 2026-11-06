--- Tests the esphome_yale session against the frames and timing a real lock
--- produces:
---
--- - The lock answers the key exchange before its write is acknowledged, so the
---   init write supersedes it on the parent. The driver took the "Superseded"
---   answer for a failed handshake, and every connect failed.
--- - The motor's result frame after a lock or unlock was read as lock state,
---   so the lock showed unknown and a stall went unreported.
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

-- The shim has only padded AES-128-CBC: pass blocks through so the lock's
-- answers can be written as plaintext
function C4:Encrypt(_cipher, _key, _iv, data)
  return data
end
function C4:Decrypt(_cipher, _key, _iv, data)
  return data
end

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

-- A LOCK's ack and the motor's result when it stops, as a lock sent them; the
-- stall differs only in its result byte
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

H.test("the status read after a lock waits for the motor to stop", function()
  H.boot(POLL)
  lock()
  session()
  lockSays(LOCK_ACK)
  T.falsy("no status read while the motor turns", H.armed("StatusPoll"))
  lockSays(LOCK_DONE)
  T.truthy("the result queues the status read", H.armed("StatusPoll"))
end)

H.test("a lock that sends no result gets its status read from the jam check", function()
  H.boot(POLL)
  lock()
  session()
  lockSays(LOCK_ACK)
  H.clearSent()
  T.truthy("the jam check fires", H.fire("JamCheck"))
  T.eq("and reads the status", H.count("GATT_WRITE", ESPHOME), 1)
  T.eq("on the write handle", H.sent[#H.sent].params.handle, "20")
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
end)

-- An unlock's ack and result, and the status chain's frames: lock, door, battery
local UNLOCK_ACK = "aa0a00490000000000000000000000000200"
local UNLOCK_DONE = "bb0a003a0000000000000000000000000000"
local STATUS_LOCKED = "bb02003a0200000005000000000000000200"
local DOOR = "bb02003a2e00000002000000000000000000"
local BATTERY = "bb02003a0f000000a00f0000000000000000"

--- A Persistent link that has locked and read its status, door and battery,
--- which arms the keepalive.
local function persistentLink()
  H.boot(PERSISTENT)
  lock()
  session()
  lockSays(LOCK_ACK)
  lockSays(LOCK_DONE)
  H.fire("StatusPoll")
  lockSays(STATUS_LOCKED)
  H.fire("DoorPoll")
  lockSays(DOOR)
  H.fire("BatteryPoll")
  lockSays(BATTERY)
end

H.test("Persistent: the keepalive reads no status while an unlock is in flight", function()
  persistentLink()
  T.truthy("the keepalive runs", H.armed("Keepalive"))
  H.rfp(PROXY, "UNLOCK")
  H.clearSent()
  H.fire("Keepalive")
  T.eq("no status read while the unlock awaits its ack", H.count("GATT_WRITE", ESPHOME), 0)
  lockSays(UNLOCK_ACK)
  H.fire("Keepalive")
  T.eq("nor while the motor turns", H.count("GATT_WRITE", ESPHOME), 0)
  T.truthy("the keepalive stays armed", H.armed("Keepalive"))
  lockSays(UNLOCK_DONE)
  H.fire("StatusPoll")
  T.eq("the unlock's own status read follows", H.count("GATT_WRITE", ESPHOME), 1)
end)

H.test("Persistent: an unlock whose answer is lost holds the keepalive off for a minute at most", function()
  persistentLink()
  H.rfp(PROXY, "UNLOCK")
  H.clearSent()
  local realTime = os.time
  local now = realTime()
  os.time = function() -- luacheck: ignore
    return now + 61
  end
  local ok, err = pcall(H.fire, "Keepalive")
  os.time = realTime -- luacheck: ignore
  T.check("the keepalive ran", ok, err)
  T.eq("it reads the status again", H.count("GATT_WRITE", ESPHOME), 1)
end)

H.test("Persistent: for a lock that sends no result, the keepalive reads again after the jam check", function()
  persistentLink()
  H.rfp(PROXY, "UNLOCK")
  lockSays(UNLOCK_ACK)
  H.fire("JamCheck")
  lockSays("bb02003a0200000003000000000000000200")
  H.fire("DoorPoll")
  lockSays(DOOR)
  H.fire("BatteryPoll")
  lockSays(BATTERY)
  H.clearSent()
  H.fire("Keepalive")
  T.eq("the next keepalive reads the status", H.count("GATT_WRITE", ESPHOME), 1)
end)

H.test("the parser reads status frames from their data bytes", function()
  local status = yale_protocol.parseResponse(fromHex("bb02003a0200000005000000000000000200"))
  T.eq("a lock status frame carries the lock's state", status.lockStatus, yale_protocol.LockStatus.LOCKED)
  local done = yale_protocol.parseResponse(fromHex(LOCK_DONE))
  T.eq("a lock result frame carries no lock state", done.lockStatus, nil)
  T.eq("only the operation result", done.operationResult, 0)
  T.eq("which names a stall", yale_protocol.parseResponse(fromHex(LOCK_STALLED)).operationResult, 0x1E)
end)

T.finish()
