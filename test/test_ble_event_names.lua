--- Tests that the events the BTHome and Govee drivers add at runtime put NAME in
--- their descriptions. Director replaces NAME with the device's name, and Composer
--- Pro titles a script with the description, so without it the title does not say
--- which device the event is from.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_event_names.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local events = require("lib.events")
local Govee = require("esphome.ble.parsers.govee")

local ESPHOME = 5001

--- Declared descriptions, sorted.
local function descriptions()
  local out = {}
  for _, event in pairs(ShimEvents()) do
    table.insert(out, event.description)
  end
  table.sort(out)
  return out
end

local function fresh()
  events:reset()
  ShimResetEvents()
end

H.use("esphome_bthome")
H.test("BTHome button and dimmer events name the device", function()
  fresh()
  H.boot()
  -- BTHome v2, unencrypted: button 1 press, button 2 double press, dimmer left 3 steps.
  local advertisement = SerializeSafe({
    rssi = -60,
    serviceData = { { uuid = "FCD2", data = "\64\58\1\58\2\60\1\3" } },
  })
  H.rfp(ESPHOME, "BLE_ADVERTISEMENT", { mac = "AA:BB:CC:DD:EE:01", advertisement = advertisement })
  T.eq("declared", descriptions(), {
    "NAME Button (2) pressed twice",
    "NAME Button pressed once",
    "NAME Dimmer rotated counter-clockwise",
  })
end)

H.use("esphome_govee")
H.test("Govee probe and error events name the device", function()
  fresh()
  H.boot(nil, function()
    require("lib.values"):update("Device Type", Govee.DEVICE_NAMES[Govee.DeviceModel.H5182], "STRING")
  end)
  T.eq("declared", descriptions(), {
    "NAME error cleared",
    "NAME probe 1 below alarm temperature",
    "NAME probe 1 reached alarm temperature",
    "NAME probe 2 below alarm temperature",
    "NAME probe 2 reached alarm temperature",
    "NAME reported an error",
  })
end)

T.finish()
