--- Tests that the esphome_yale driver releases the link and recovers when
--- CONNECTED arrives without the lock's GATT characteristics. Discovery can come
--- back with no services, and with no handles cached from an earlier connect the
--- driver has nothing to talk to. It used to only set an error status: the parent
--- kept the connection slot, Poll mode never polled again and Persistent mode
--- never reconnected.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_missing_characteristics.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local persist = require("lib.persist")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local OFFLINE_KEY = string.rep("0123456789ABCDEF", 2)
local PERSISTENT = { ["Connection Mode"] = "Persistent", ["Offline Key"] = OFFLINE_KEY }
local HANDLES = { "WRITE_HANDLE", "READ_HANDLE", "SECURE_WRITE_HANDLE", "SECURE_READ_HANDLE" }
local NO_CHARACTERISTICS = SerializeSafe({})

--- A lock that has never connected: no handles cached to fall back on.
local function boot(properties)
  H.boot(properties, function()
    for _, key in ipairs(HANDLES) do
      persist:delete(key)
    end
  end)
end

local function lock()
  H.rfp(PROXY, "LOCK")
end

--- @param services string|nil Serialized services; nil leaves them out.
local function connected(services)
  H.rfp(ESPHOME, "CONNECTED", { name = "Front Door", mac = "AA:BB:CC:DD:EE:FF", services = services })
end

--- The coordinator's answer to a DISCONNECT.
local function disconnectAnswered()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "Requested" })
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

local CASES = {
  { name = "characteristics", services = NO_CHARACTERISTICS },
  { name = "services", services = nil },
}

for _, case in ipairs(CASES) do
  H.test("Poll mode: CONNECTED without " .. case.name .. " frees the slot and polls again", function()
    boot()
    lock()
    connected(case.services)
    T.eq("it sends DISCONNECT once", H.count("DISCONNECT", ESPHOME), 1)
    T.eq("Connected is false", H.variable("Connected"), false)
    T.truthy("the poll is armed", H.armed("PollCycle"))
    T.falsy("no connect timeout is left behind", H.armed("ConnectionTimeout"))

    disconnectAnswered()
    T.eq("the parent's answer leaves Connected false", H.variable("Connected"), false)
    T.truthy("and the poll armed", H.armed("PollCycle"))

    H.clearSent()
    T.truthy("the poll fires", H.fire("PollCycle"))
    T.eq("and connects again", H.count("CONNECT", ESPHOME), 1)
  end)

  H.test("Persistent mode: CONNECTED without " .. case.name .. " frees the slot and reconnects", function()
    boot(PERSISTENT)
    lock()
    connected(case.services)
    T.eq("it sends DISCONNECT once", H.count("DISCONNECT", ESPHOME), 1)
    T.eq("status shows the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
    T.eq("Connected is false", H.variable("Connected"), false)
    T.truthy("the reconnect is armed", H.armed("Reconnect"))
    T.eq("to retry the lock", retryCommand(), "lock")

    disconnectAnswered()
    T.eq("the parent's answer leaves it the first retry", Properties["Driver Status"], "Reconnecting (1/5)")
    T.truthy("with the reconnect still armed", H.armed("Reconnect"))
    T.eq("and still retrying the lock", retryCommand(), "lock")

    H.clearSent()
    T.truthy("the reconnect fires", H.fire("Reconnect"))
    T.eq("and connects again", H.count("CONNECT", ESPHOME), 1)
  end)
end

H.test("handles cached from an earlier connect still carry a CONNECTED without characteristics", function()
  H.boot(nil, function()
    for i, key in ipairs(HANDLES) do
      persist:set(key, 18 + 2 * i)
    end
  end)
  lock()
  connected(NO_CHARACTERISTICS)
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  T.eq("the handshake starts on the cached secure-read handle", H.count("GATT_NOTIFY", ESPHOME), 1)
  T.eq("which is handle 26", H.sent[#H.sent].params.handle, "26")
end)

T.finish()
