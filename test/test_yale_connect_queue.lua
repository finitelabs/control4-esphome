--- Tests that a Yale lock or unlock sent while a connect is in flight waits for
--- that connect.
---
--- It used to send a second CONNECT. The parent then failed the first with
--- "Superseded by a newer request", the failure cleared the queued command, and
--- the newer connect came up with nothing to send: the lock or unlock was lost.
--- A Poll-mode lock connects for every poll, so a tap during those few seconds
--- did nothing.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_connect_queue.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local yale_protocol = require("esphome.ble.yale_protocol")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local OFFLINE_KEY = string.rep("0123456789ABCDEF", 2)
local POLL = { ["Offline Key"] = OFFLINE_KEY }
local PERSISTENT = { ["Connection Mode"] = "Persistent", ["Offline Key"] = OFFLINE_KEY }
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

local function secureAnswer(opcode)
  return C4:Base64Encode(string.char(opcode) .. string.rep("\0", 3) .. "LOCKBYTE" .. string.rep("\0", 6))
end

--- From CONNECTED to the queued command on the wire.
local function session()
  H.rfp(ESPHOME, "CONNECTED", { name = "Front Door", mac = "AA:BB:CC:DD:EE:FF", services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", {
    handle = "26",
    data = secureAnswer(yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP),
  })
  H.rfp(
    ESPHOME,
    "GATT_NOTIFY_DATA",
    { handle = "26", data = secureAnswer(yale_protocol.Opcode.SEC_INITIALIZATION_RESP) }
  )
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "true" })
end

--- The opcode of the last command written to the regular write handle.
local function lastCommand()
  for i = #H.sent, 1, -1 do
    local s = H.sent[i]
    if s.command == "GATT_WRITE" and s.params.handle == "20" then
      return string.byte(C4:Base64Decode(s.params.data), 2)
    end
  end
end

for _, mode in ipairs({ { name = "Poll", props = POLL }, { name = "Persistent", props = PERSISTENT } }) do
  H.test(mode.name .. ": a lock during a status connect waits for it and goes out", function()
    H.boot(mode.props)
    EC.Request_Status()
    H.rfp(PROXY, "LOCK")
    T.eq("one CONNECT", H.count("CONNECT", ESPHOME), 1)

    session()
    T.eq("the lock is what goes out", lastCommand(), yale_protocol.Opcode.LOCK)
  end)
end

H.test("a connect the parent superseded leaves the newer one and its command alone", function()
  H.boot(POLL)
  H.rfp(PROXY, "UNLOCK")
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = SUPERSEDED })
  T.falsy("no poll is scheduled over it", H.armed("PollCycle"))
  T.truthy("the connect is still timed", H.armed("ConnectionTimeout"))

  session()
  T.eq("the unlock goes out", lastCommand(), yale_protocol.Opcode.UNLOCK)
end)

H.test("any other connect failure still ends the attempt", function()
  H.boot(POLL)
  H.rfp(PROXY, "UNLOCK")
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "GATT discovery failed" })
  T.truthy("the next poll is scheduled", H.armed("PollCycle"))
end)

T.finish()
