--- Tests the esphome_switchbot driver's commands sent while it connects.
---
--- Each command used to ask the parent to connect again, and a second CONNECT
--- mid-connect makes the parent start over: the first attempt then fails with
--- "GATT discovery failed", which dropped the queued command. The driver also
--- held one queued command, so turning on both channels of a Relay 2PM, as a
--- scene does, kept only the last one.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_switchbot_queue.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local SwitchBot = require("esphome.ble.parsers.switchbot")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
local values = require("lib.values")

H.use("esphome_switchbot")

local ESPHOME = 5001
local RELAY_2PM = SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_2PM]
local BOT = SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.BOT]
local SERVICE = "CBA20D00-224D-11E6-9FB8-0002A5D5C51B"
local TX = "CBA20002-224D-11E6-9FB8-0002A5D5C51B"
local RX = "CBA20003-224D-11E6-9FB8-0002A5D5C51B"
local CH1_ON = SwitchBot.Commands.RELAY_2PM_CH1_ON:sub(2)
local CH1_OFF = SwitchBot.Commands.RELAY_2PM_CH1_OFF:sub(2)
local CH2_ON = SwitchBot.Commands.RELAY_2PM_CH2_ON:sub(2)

local SERVICES = SerializeSafe({
  {
    uuid = H.uuidPairs(SERVICE),
    characteristics = {
      { uuid = H.uuidPairs(TX), handle = 12 },
      { uuid = H.uuidPairs(RX), handle = 14 },
    },
  },
})

-- The shim has no AES-128-CTR, so a command's payload goes out as it is
function C4:Encrypt(_cipher, _key, _iv, data)
  return data
end

--- A device seen before, with no GATT handles stored, so a command has to connect.
local function boot(deviceType)
  H.boot({ ["Key ID"] = "01", ["Encryption Key"] = string.rep("0123456789abcdef", 2) }, function()
    persist:delete("TX_HANDLE")
    persist:delete("RX_HANDLE")
    values:update("Device Type", deviceType, "STRING")
  end)
end

local function channel(n, command)
  H.rfp(bindings:getDynamicBinding("SwitchBot", "channel" .. n).bindingId, command)
end

local function connected(deviceType)
  H.rfp(
    ESPHOME,
    "CONNECTED",
    { name = "SwitchBot", mac = "AA:BB:CC:DD:EE:FF", deviceType = deviceType, services = SERVICES }
  )
end

local function deviceSays(data)
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", { handle = "14", data = C4:Base64Encode(data) })
end

--- From CONNECTED to the IV answered, after which the first queued command goes out.
local function relayReady()
  connected(RELAY_2PM)
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "14", success = "true" })
  deviceSays("\x01\x00\x00\x00" .. string.rep("\x11", 16))
end

--- The payloads of the commands written so far, the IV request left out.
local function commandsWritten()
  local out = {}
  for _, sent in ipairs(H.sent) do
    if sent.command == "GATT_WRITE" then
      local data = C4:Base64Decode(sent.params.data)
      for _, payload in ipairs({ CH1_ON, CH1_OFF, CH2_ON }) do
        if data:find(payload, 1, true) then
          table.insert(out, payload)
        end
      end
    end
  end
  return out
end

H.test("both channels turned on during a connect go out in order, with one CONNECT", function()
  boot(RELAY_2PM)
  channel(1, "ON")
  channel(2, "ON")
  T.eq("one CONNECT", H.count("CONNECT", ESPHOME), 1)

  relayReady()
  T.eq("channel 1 goes out first", commandsWritten(), { CH1_ON })

  deviceSays("\x01")
  T.eq("channel 2 after channel 1's reply", commandsWritten(), { CH1_ON, CH2_ON })
  T.falsy("the link stays up for its reply", H.armed("DisconnectDelay"))

  deviceSays("\x01")
  T.truthy("then the link is released", H.armed("DisconnectDelay"))
  T.eq("still one CONNECT", H.count("CONNECT", ESPHOME), 1)
end)

H.test("a newer command for a channel replaces the one queued for it", function()
  boot(RELAY_2PM)
  channel(1, "ON")
  channel(2, "ON")
  channel(1, "OFF")
  relayReady()
  deviceSays("\x01")
  T.eq("channel 1's last command keeps its place", commandsWritten(), { CH1_OFF, CH2_ON })
end)

H.test("a connect that fails drops the queue and says so", function()
  boot(RELAY_2PM)
  channel(1, "ON")
  channel(2, "ON")
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "GATT discovery failed" })
  T.eq("the failure is shown", Properties["Driver Status"], "Connection Failed: GATT discovery failed")

  H.clearSent()
  channel(1, "ON")
  T.eq("the next command connects again", H.count("CONNECT", ESPHOME), 1)
  relayReady()
  deviceSays("\x01")
  T.eq("and only it goes out", commandsWritten(), { CH1_ON })
end)

H.test("a second Bot press during a connect sends no second CONNECT", function()
  boot(BOT)
  H.rfp(bindings:getDynamicBinding("SwitchBot", "botRelay").bindingId, "ON")
  H.rfp(bindings:getDynamicBinding("SwitchBot", "botRelay").bindingId, "ON")
  T.eq("one CONNECT", H.count("CONNECT", ESPHOME), 1)
  connected(BOT)
  T.eq("the press is written once", H.count("GATT_WRITE", ESPHOME), 1)
end)

--- What os.time reads inside withClock.
local now = 0

--- Run fn with os.time pinned to `now`, so a test sets how long a command waited.
--- @param fn function
local function withClock(fn)
  local realTime = os.time
  os.time = function(...) -- luacheck: ignore
    if select("#", ...) > 0 then
      return realTime(...)
    end
    return now
  end
  local ok, err = pcall(fn)
  os.time = realTime -- luacheck: ignore
  assert(ok, err)
end

H.test("a command queued over 60s is dropped and the next one still goes out", function()
  withClock(function()
    now = 1000
    boot(RELAY_2PM)
    channel(1, "ON")
    now = 1030
    channel(2, "ON")
    now = 1061
    relayReady()
    T.eq("only channel 2 goes out", commandsWritten(), { CH2_ON })
    T.falsy("and the attempt is not given up", Properties["Driver Status"] == "Error: Command expired")
  end)
end)

T.finish()
