--- Tests that the esphome_switchbot driver gives up on a CONNECT its parent never
--- answers. Neither CONNECTED nor CONNECTION_FAILED comes back when the message is
--- lost or the proxy restarts mid-connect, and before the timeout the queued
--- command and the Busy status then sat there until something else reset them,
--- with the press replayed whenever a CONNECTED finally turned up. The timeout
--- has to free the proxy slot and fail the command the way CONNECTION_FAILED does.
---
--- The coordinator answers the timeout's DISCONNECT with DISCONNECTED. That answer
--- must not turn the failure back into "Listening", nor reset a press made since.
---
--- A press queued more than 60s before its CONNECTED is dropped and reported as
--- failed rather than sent late.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_switchbot_connect_timeout.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local SwitchBot = require("esphome.ble.parsers.switchbot")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
local values = require("lib.values")

H.use("esphome_switchbot")

local ESPHOME = 5001
local BOT = SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.BOT]
local SERVICE = "CBA20D00-224D-11E6-9FB8-0002A5D5C51B"
local TX = "CBA20002-224D-11E6-9FB8-0002A5D5C51B"
local RX = "CBA20003-224D-11E6-9FB8-0002A5D5C51B"

local SERVICES = SerializeSafe({
  {
    uuid = H.uuidPairs(SERVICE),
    characteristics = {
      { uuid = H.uuidPairs(TX), handle = 12 },
      { uuid = H.uuidPairs(RX), handle = 14 },
    },
  },
})

--- A Bot seen before, but with no GATT handles stored, so a press has to connect.
local function boot()
  H.boot(nil, function()
    persist:delete("TX_HANDLE")
    persist:delete("RX_HANDLE")
    values:update("Device Type", BOT, "STRING")
  end)
end

local function press()
  H.rfp(bindings:getDynamicBinding("SwitchBot", "botRelay").bindingId, "ON")
end

local function connected()
  H.rfp(ESPHOME, "CONNECTED", { name = "Bot", mac = "AA:BB:CC:DD:EE:FF", deviceType = BOT, services = SERVICES })
end

--- The coordinator's answer to a DISCONNECT.
local function disconnectAnswered()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "Requested" })
end

H.test("a CONNECT nobody answers times out, frees the slot and drops the press", function()
  boot()
  press()
  T.eq("the press asks the parent to connect", H.count("CONNECT", ESPHOME), 1)
  T.eq("and shows Busy", Properties["Driver Status"], "Busy")
  T.truthy("and arms the connect timeout", H.armed("ConnectionTimeout"))
  T.eq("which outlasts the parent's own", H.delay("ConnectionTimeout"), 200000)

  T.truthy("the timeout fires", H.fire("ConnectionTimeout"))
  T.eq("it sends DISCONNECT so the parent frees any half-open slot", H.count("DISCONNECT", ESPHOME), 1)
  T.eq("status says why, as CONNECTION_FAILED would", Properties["Driver Status"], "Connection Failed: timeout")
  T.eq("Connected is false", H.variable("Connected"), false)

  disconnectAnswered()
  T.eq("the parent's answer keeps the failure status", Properties["Driver Status"], "Connection Failed: timeout")
  T.eq("and Connected false", H.variable("Connected"), false)

  -- A CONNECTED that turns up after all must not replay the abandoned press.
  H.clearSent()
  connected()
  T.eq("the press is not written", H.count("GATT_WRITE", ESPHOME), 0)
  T.eq("nor anything subscribed", H.count("GATT_NOTIFY", ESPHOME), 0)
  T.truthy("the link is released", H.armed("DisconnectDelay"))
end)

H.test("the next press after a timeout connects afresh", function()
  boot()
  press()
  H.fire("ConnectionTimeout")
  H.clearSent()
  press()
  T.eq("it asks the parent to connect again", H.count("CONNECT", ESPHOME), 1)
  T.eq("and shows Busy", Properties["Driver Status"], "Busy")
  T.truthy("under a fresh timeout", H.armed("ConnectionTimeout"))

  -- The answer to the first attempt's DISCONNECT lands after the new press.
  disconnectAnswered()
  T.eq("the new press stays Busy", Properties["Driver Status"], "Busy")
  T.truthy("its timeout stays armed", H.armed("ConnectionTimeout"))
  connected()
  T.eq("and the new press is written once connected", H.count("GATT_WRITE", ESPHOME), 1)
end)

H.test("a DISCONNECTED on a live link still goes back to Listening, after a timeout too", function()
  boot()
  press()
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  press()
  connected()
  T.eq("the press is written", H.count("GATT_WRITE", ESPHOME), 1)

  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("the driver is listening again", Properties["Driver Status"], "Listening")
  T.eq("Connected is true", H.variable("Connected"), true)
end)

H.test("CONNECTED cancels the timeout", function()
  boot()
  press()
  connected()
  T.falsy("the timeout is cancelled", H.armed("ConnectionTimeout"))
  T.eq("and the queued press is written", H.count("GATT_WRITE", ESPHOME), 1)
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  T.falsy("and no disconnect is scheduled before the write is answered", H.armed("DisconnectDelay"))
end)

H.test("CONNECTION_FAILED cancels the timeout", function()
  boot()
  press()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "No connection slots available" })
  T.falsy("the timeout is cancelled", H.armed("ConnectionTimeout"))
  T.eq("status says why", Properties["Driver Status"], "Connection Failed: No connection slots available")
end)

H.test("a CONNECTED after the timeout releases the link it was not asked for", function()
  boot()
  press()
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  H.clearSent()

  connected()
  T.eq("the abandoned press is not written", H.count("GATT_WRITE", ESPHOME), 0)
  T.truthy("a disconnect is scheduled", H.armed("DisconnectDelay"))
  T.truthy("which fires", H.fire("DisconnectDelay"))
  T.eq("and sends DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)

  H.rfp(ESPHOME, "DISCONNECTED", { reason = "Requested" })
  T.eq("the driver is listening again", Properties["Driver Status"], "Listening")
end)

H.test("a CONNECTION_FAILED after the timeout is ignored", function()
  boot()
  press()
  H.fire("ConnectionTimeout")
  disconnectAnswered()

  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "late" })
  T.eq("the timeout's status stands", Properties["Driver Status"], "Connection Failed: timeout")
end)

H.test("a CONNECTION_FAILED that lands once connected leaves the press alone", function()
  boot()
  press()
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  press()
  connected()
  T.eq("the new press is written", H.count("GATT_WRITE", ESPHOME), 1)

  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "late" })
  T.eq("the driver stays Busy", Properties["Driver Status"], "Busy")
  H.rfp(ESPHOME, "GATT_WRITE_RESPONSE", { success = "true" })
  T.truthy("and the write answer still schedules the disconnect", H.armed("DisconnectDelay"))
end)

H.test("a Bot the parent connects at bind releases the link", function()
  boot()
  OBC[ESPHOME](ESPHOME, "ESPHOME_SWITCHBOT", true)
  connected()
  T.eq("nothing is subscribed", H.count("GATT_NOTIFY", ESPHOME), 0)
  T.eq("nor written", H.count("GATT_WRITE", ESPHOME), 0)
  T.eq("the disconnect waits the usual delay", H.delay("DisconnectDelay"), 4000)
  T.truthy("and fires", H.fire("DisconnectDelay"))
  T.eq("sending DISCONNECT", H.count("DISCONNECT", ESPHOME), 1)
end)

local RELAY = SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1]

H.test("a late CONNECTION_FAILED leaves an encrypted Relay Switch press waiting on its IV alone", function()
  H.boot({ ["Key ID"] = "01", ["Encryption Key"] = string.rep("00", 16) }, function()
    persist:delete("TX_HANDLE")
    persist:delete("RX_HANDLE")
    values:update("Device Type", RELAY, "STRING")
  end)
  local relay = bindings:getDynamicBinding("SwitchBot", "channel1").bindingId
  H.rfp(relay, "ON")
  H.fire("ConnectionTimeout")
  disconnectAnswered()
  H.rfp(relay, "ON")
  H.rfp(ESPHOME, "CONNECTED", { name = "Relay", mac = "AA:BB:CC:DD:EE:FF", deviceType = RELAY, services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "14", success = "true" })
  T.eq("the IV is requested", Properties["Encryption Status"], "Requesting IV...")

  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "late" })
  T.eq("the driver stays Busy", Properties["Driver Status"], "Busy")
end)

H.test("the parent closing the link after its CONNECTION_FAILED keeps the failure", function()
  boot()
  press()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "timeout" })
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("status stays the failure", Properties["Driver Status"], "Connection Failed: timeout")
  T.eq("and Connected false", H.variable("Connected"), false)
end)

H.test("the parent closing the link after its CONNECTION_FAILED keeps a press made since", function()
  boot()
  press()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "timeout" })
  press()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("the second press is still Busy", Properties["Driver Status"], "Busy")
  H.clearSent()
  connected()
  T.eq("and is written once connected", H.count("GATT_WRITE", ESPHOME), 1)
end)

--- What os.time reads inside withClock.
local now = 0

--- Run fn with os.time pinned to `now`, so a test sets how long a press waited.
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

H.test("a press whose CONNECTED arrives 59s after it is written", function()
  withClock(function()
    now = 1000
    boot()
    press()
    now = 1059
    connected()
    T.eq("the press is written", H.count("GATT_WRITE", ESPHOME), 1)
  end)
end)

H.test("a press whose CONNECTED arrives 61s after it is dropped and reported failed", function()
  withClock(function()
    now = 1000
    boot()
    press()
    now = 1061
    H.clearSent()
    connected()
    T.eq("the press is not written", H.count("GATT_WRITE", ESPHOME), 0)
    T.eq("the link is released", H.count("DISCONNECT", ESPHOME), 1)
    T.eq("status says why", Properties["Driver Status"], "Error: Command expired")
    T.eq("Connected is false", H.variable("Connected"), false)
    T.eq("the relay is never closed", H.count("CLOSED"), 0)

    disconnectAnswered()
    T.eq("the parent's answer keeps the failure status", Properties["Driver Status"], "Error: Command expired")
  end)
end)

H.test("a newer press is timed from when it was made", function()
  withClock(function()
    now = 1000
    boot()
    press()
    now = 1050
    press()
    now = 1100
    connected()
    T.eq("the newer press is written", H.count("GATT_WRITE", ESPHOME), 1)
  end)
end)

T.finish()
