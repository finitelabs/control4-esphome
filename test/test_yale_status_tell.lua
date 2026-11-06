--- Tests what esphome_yale tells the lock proxy. LOCK_STATUS_CHANGED writes a
--- history line and fires the proxy's events, so it goes out only for a real
--- change. A status the proxy does not show yet initializes it with the silent
--- LOCK_STATUS_INITIALIZE, and one it shows already is told nothing.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_status_tell.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local yale_protocol = require("esphome.ble.yale_protocol")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local PROXY_DEVICE = 9001
local OFFLINE_KEY = string.rep("0123456789ABCDEF", 2)
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

-- The shim has only padded AES-128-CBC: pass blocks through so the lock's
-- answers can be written as plaintext
function C4:Encrypt(_cipher, _key, _iv, data)
  return data
end
function C4:Decrypt(_cipher, _key, _iv, data)
  return data
end

--- What the proxy's LockStatus shows: a driver update leaves the status shown, a
--- controller start leaves it unknown.
local proxyShows

function C4:GetProxyDevices()
  return PROXY_DEVICE
end

function C4:GetDeviceVariable(deviceId, variableId)
  if deviceId == PROXY_DEVICE and variableId == 1000 then
    return proxyShows
  end
end

local function fromHex(hex)
  return (hex:gsub("%x%x", function(byte)
    return string.char(tonumber(byte, 16))
  end))
end

local function secureAnswer(opcode)
  return C4:Base64Encode(string.char(opcode) .. string.rep("\0", 3) .. "LOCKBYTE" .. string.rep("\0", 6))
end

--- From CONNECTED to the queued command on the wire.
local function session()
  H.rfp(ESPHOME, "CONNECTED", { name = "Front Door", mac = MAC, services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", {
    handle = "26",
    data = secureAnswer(yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP),
  })
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", {
    handle = "26",
    data = secureAnswer(yale_protocol.Opcode.SEC_INITIALIZATION_RESP),
  })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "true" })
end

local function lockSays(hex)
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", { handle = "22", data = C4:Base64Encode(fromHex(hex)) })
end

-- The lock's status frames, and a LOCK's ack and motor result
local LOCKED = "bb02003a0200000005000000000000000200"
local UNLOCKED = "bb02003a0200000003000000000000000200"
local LOCK_ACK = "aa0b00490000000000000000000000000200"
local LOCK_DONE = "bb0b003a0000000000000000000000000000"

--- The statuses told the proxy since the last clear, as "COMMAND status".
local function statusTold(sent)
  local got = {}
  for _, s in ipairs(sent or H.sent) do
    if s.binding == PROXY and s.command:find("^LOCK_STATUS_") then
      got[#got + 1] = s.command .. " " .. tostring(s.params.LOCK_STATUS)
    end
  end
  return got
end

--- Load the driver with `kept` as its stored Lock Status and `shows` on the
--- proxy, and return the statuses late init told.
local function boot(kept, shows)
  proxyShows = shows
  local told
  local lateInit = ShimLateInit
  H.boot({ ["Offline Key"] = OFFLINE_KEY, ["Lock Status"] = kept }, function()
    ShimLateInit = function()
      lateInit()
      told = statusTold()
    end
  end)
  ShimLateInit = lateInit
  return told
end

H.test("after a driver update, the status the proxy shows is told nothing", function()
  T.eq("late init tells nothing", boot("locked", "locked"), {})
  H.rfp(PROXY, "LOCK")
  session()
  lockSays(LOCKED)
  T.eq("nor does the same status read from the lock", statusTold(), {})
end)

H.test("after a controller start, the status kept initializes the proxy, silently", function()
  T.eq("late init initializes it", boot("locked", "unknown"), { "LOCK_STATUS_INITIALIZE locked" })
end)

H.test("a status read tells only a change", function()
  boot("locked", "locked")
  H.rfp(PROXY, "LOCK")
  session()
  lockSays(LOCKED)
  lockSays(LOCKED)
  T.eq("the same status again tells nothing", statusTold(), {})
  lockSays(UNLOCKED)
  T.eq("a change is told once", statusTold(), { "LOCK_STATUS_CHANGED unlocked" })
end)

H.test("a lock and the status read after it tell one change", function()
  boot("unlocked", "unlocked")
  H.rfp(PROXY, "LOCK")
  session()
  lockSays(LOCK_ACK)
  lockSays(LOCK_DONE)
  T.truthy("the status read follows", H.fire("StatusPoll"))
  lockSays(LOCKED)
  T.eq("locked is told once", statusTold(), { "LOCK_STATUS_CHANGED locked" })
end)

H.test("the lock heard again after an outage tells no status", function()
  boot("locked", "locked")
  H.rfp(ESPHOME, "BLE_ADVERTISEMENT", { mac = MAC, advertisement = SerializeSafe({ rssi = -60 }) })
  T.eq("it comes back online", H.count("ONLINE_CHANGED", PROXY), 1)
  T.eq("and tells no status", statusTold(), {})
end)

T.finish()
