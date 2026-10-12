--- Tests that the esphome_switchbot driver releases the link when CONNECTED
--- arrives without the device's GATT characteristics. Discovery can come back
--- with no services, and with no handles cached from an earlier connect the
--- driver has nothing to write to. It used to only set an error status, leaving
--- the parent holding the connection slot and the press queued.
---
--- The coordinator answers the DISCONNECT with DISCONNECTED. That answer must not
--- turn the failure back into "Listening".
---
--- With cached handles the link is usable, but an encrypted switch with no key
--- still has nothing it can send, and has to release the link there too.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_switchbot_missing_characteristics.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local SwitchBot = require("esphome.ble.parsers.switchbot")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
local values = require("lib.values")

H.use("esphome_switchbot")

local ESPHOME = 5001
local BOT = SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.BOT]
local RELAY = SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1]
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
local NO_CHARACTERISTICS = SerializeSafe({})

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

--- @param services string|nil Serialized services; nil leaves them out.
--- @param deviceType string|nil Defaults to the Bot.
local function connected(services, deviceType)
  H.rfp(ESPHOME, "CONNECTED", {
    name = "SwitchBot",
    mac = "AA:BB:CC:DD:EE:FF",
    deviceType = deviceType or BOT,
    services = services,
  })
end

--- The coordinator's answer to a DISCONNECT.
local function disconnectAnswered()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "Requested" })
end

local CASES = {
  { name = "characteristics", services = NO_CHARACTERISTICS, status = "Error: Missing characteristics" },
  { name = "services", services = nil, status = "Error: Missing services" },
}

for _, case in ipairs(CASES) do
  H.test("CONNECTED without " .. case.name .. " frees the slot and drops the press", function()
    boot()
    press()
    connected(case.services)
    T.eq("it sends DISCONNECT once", H.count("DISCONNECT", ESPHOME), 1)
    T.eq("status says why", Properties["Driver Status"], case.status)
    T.eq("Connected is false", H.variable("Connected"), false)
    T.falsy("no connect timeout is left behind", H.armed("ConnectionTimeout"))

    disconnectAnswered()
    T.eq("the parent's answer keeps the failure status", Properties["Driver Status"], case.status)
    T.eq("and Connected false", H.variable("Connected"), false)

    -- A later CONNECTED with the characteristics must not replay the dropped press.
    H.clearSent()
    connected(SERVICES)
    T.eq("the press is not written", H.count("GATT_WRITE", ESPHOME), 0)
  end)

  H.test("the next press after a CONNECTED without " .. case.name .. " connects afresh", function()
    boot()
    press()
    connected(case.services)
    disconnectAnswered()

    H.clearSent()
    press()
    T.eq("it asks the parent to connect again", H.count("CONNECT", ESPHOME), 1)
    T.eq("and shows Busy", Properties["Driver Status"], "Busy")
    connected(SERVICES)
    T.eq("and is written once connected", H.count("GATT_WRITE", ESPHOME), 1)
  end)
end

H.test("handles cached from an earlier connect still carry a CONNECTED without characteristics", function()
  H.boot(nil, function()
    persist:set("TX_HANDLE", 12)
    persist:set("RX_HANDLE", 14)
    values:update("Device Type", BOT, "STRING")
  end)
  connected(NO_CHARACTERISTICS)
  T.eq("nothing is disconnected", H.count("DISCONNECT", ESPHOME), 0)
  T.eq("and no error is shown", Properties["Driver Status"]:find("Error", 1, true), nil)
end)

local NO_KEY_CASES = {
  { name = "with its characteristics", services = SERVICES },
  { name = "on cached handles", services = NO_CHARACTERISTICS },
}

for _, case in ipairs(NO_KEY_CASES) do
  H.test("an encrypted switch with no key releases a link that comes up " .. case.name, function()
    H.boot(nil, function()
      persist:set("TX_HANDLE", 12)
      persist:set("RX_HANDLE", 14)
      values:update("Device Type", RELAY, "STRING")
    end)
    H.rfp(bindings:getDynamicBinding("SwitchBot", "channel1").bindingId, "ON")
    T.eq("the press asks the parent to connect", H.count("CONNECT", ESPHOME), 1)

    connected(case.services, RELAY)
    T.eq("Encryption Status says why", Properties["Encryption Status"], "Required - Not Configured")
    T.truthy("the disconnect is scheduled", H.armed("DisconnectDelay"))
    T.truthy("and fires", H.fire("DisconnectDelay"))
    T.eq("sending DISCONNECT once", H.count("DISCONNECT", ESPHOME), 1)

    disconnectAnswered()
    T.eq("the driver is listening again", Properties["Driver Status"], "Listening")
    T.eq("nothing was written", H.count("GATT_WRITE", ESPHOME), 0)
  end)
end

T.finish()
