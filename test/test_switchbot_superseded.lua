--- Tests the esphome_switchbot driver against the parent's superseded answers.
---
--- The parent keys write callbacks by handle, so a write sent while an earlier
--- one to the same handle is unacknowledged makes the earlier one report
--- "Superseded by a newer request"; the newer write still answers. An encrypted
--- Relay writes the IV request, the device answers it by notification, and the
--- command goes out to the same handle at once. The IV write's superseded answer
--- was taken for the command failing: the driver stopped waiting for the
--- command's reply, so a device that refused the command, as with a wrong
--- encryption key, went unreported.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_switchbot_superseded.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local SwitchBot = require("esphome.ble.parsers.switchbot")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
local values = require("lib.values")

H.use("esphome_switchbot")

local ESPHOME = 5001
local RELAY = SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1]
local SERVICE = "CBA20D00-224D-11E6-9FB8-0002A5D5C51B"
local TX = "CBA20002-224D-11E6-9FB8-0002A5D5C51B"
local RX = "CBA20003-224D-11E6-9FB8-0002A5D5C51B"
local SUPERSEDED = "Superseded by a newer request"

local SERVICES = SerializeSafe({
  {
    uuid = H.uuidPairs(SERVICE),
    characteristics = {
      { uuid = H.uuidPairs(TX), handle = 12 },
      { uuid = H.uuidPairs(RX), handle = 14 },
    },
  },
})

-- The shim has no AES-128-CTR, and the device never sees what is written here
function C4:Encrypt(_cipher, _key, _iv, data)
  return data
end

--- A Relay seen before, with its keys set and no GATT handles stored.
local function boot()
  H.boot({ ["Key ID"] = "01", ["Encryption Key"] = string.rep("0123456789abcdef", 2) }, function()
    persist:delete("TX_HANDLE")
    persist:delete("RX_HANDLE")
    values:update("Device Type", RELAY, "STRING")
  end)
end

local function turnOn()
  H.rfp(bindings:getDynamicBinding("SwitchBot", "channel1").bindingId, "ON")
end

--- A device notification on the RX handle.
local function deviceSays(data)
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", { handle = "14", data = C4:Base64Encode(data) })
end

--- The last GATT write sent.
local function lastWrite()
  for i = #H.sent, 1, -1 do
    if H.sent[i].command == "GATT_WRITE" then
      return H.sent[i]
    end
  end
end

local function writeAnswered(success, err)
  H.rfp(ESPHOME, "GATT_WRITE_RESPONSE", { success = success and "true" or "false", error = err or "0" })
end

--- From CONNECTED to the IV request on the wire.
local function connectAndRequestIV()
  H.rfp(ESPHOME, "CONNECTED", { name = "Relay", mac = "AA:BB:CC:DD:EE:FF", deviceType = RELAY, services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "14", success = "true" })
end

--- The device's IV, after which the queued command goes out.
local function ivAnswered()
  deviceSays("\x01\x00\x00\x00" .. string.rep("\x11", 16))
end

H.test("the command superseding the IV request's write still gets its reply read", function()
  boot()
  turnOn()
  connectAndRequestIV()
  T.eq("the IV request goes out", H.count("GATT_WRITE", ESPHOME), 1)
  ivAnswered()
  T.eq("and the command after it, on the same handle", H.count("GATT_WRITE", ESPHOME), 2)
  T.eq("both on the TX handle", lastWrite().params.handle, "12")

  -- The IV write's answer, then the command's own
  writeAnswered(false, SUPERSEDED)
  T.falsy("the command is still awaited", H.armed("DisconnectDelay"))
  writeAnswered(true)

  -- The device refuses the command: a wrong key
  deviceSays("\x09")
  T.eq("its reply is read", Properties["Encryption Status"], "Error: Incorrect encryption key")
  T.truthy("and the link is released after it", H.armed("DisconnectDelay"))
end)

H.test("any other failed command write still ends the wait", function()
  boot()
  turnOn()
  connectAndRequestIV()
  ivAnswered()
  writeAnswered(false, "133")
  T.truthy("the link is released", H.armed("DisconnectDelay"))
end)

H.test("a superseded subscription is left to the newer one", function()
  boot()
  turnOn()
  H.rfp(ESPHOME, "CONNECTED", { name = "Relay", mac = "AA:BB:CC:DD:EE:FF", deviceType = RELAY, services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "14", success = "false", error = SUPERSEDED })
  T.truthy("no error is shown", Properties["Encryption Status"] ~= "Error: Notification subscription failed")

  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "14", success = "true" })
  T.eq("the newer answer requests the IV", H.count("GATT_WRITE", ESPHOME), 1)
end)

H.test("a subscription that really failed still says so", function()
  boot()
  turnOn()
  H.rfp(ESPHOME, "CONNECTED", { name = "Relay", mac = "AA:BB:CC:DD:EE:FF", deviceType = RELAY, services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "14", success = "false", error = "133" })
  T.eq("the error is shown", Properties["Encryption Status"], "Error: Notification subscription failed")
end)

T.finish()
