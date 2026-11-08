--- Tests the BLE UUID helpers: normalizing numbers, strings and 64-bit values to one form, matching across forms,
--- and finding service data by one or more UUIDs.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_uuid.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local bit64 = require("bitn").bit64
local UUID = require("esphome.ble.uuid")

T.section("normalize gives one upper-case form")
T.eq("a 16-bit number", UUID.normalize(0xFCD2), "FCD2")
T.eq("another 16-bit number", UUID.normalize(0x1800), "1800")
T.eq("a 32-bit number", UUID.normalize(0x12345678), "12345678")
T.eq("a lower-case string", UUID.normalize("fcd2"), "FCD2")
T.eq("an upper-case string", UUID.normalize("FCD2"), "FCD2")
T.eq("a string with dashes", UUID.normalize("12345678-1234-5678-1234-567890ABCDEF"), "12345678123456781234567890ABCDEF")
T.eq("nil", UUID.normalize(nil), nil)
T.eq("a 64-bit value", UUID.normalize(bit64.new(0x12345678, 0x9ABCDEF0)), "123456789ABCDEF0")

T.section("matches compares across forms")
T.truthy("a number and a string", UUID.matches(0xFCD2, "FCD2"))
T.truthy("a string and a number", UUID.matches("fcd2", 0xFCD2))
T.truthy("two cases of one string", UUID.matches("FD3D", "fd3d"))
T.falsy("different UUIDs", UUID.matches(0xFCD2, "FD3D"))
T.truthy("a 64-bit value and a string", UUID.matches(bit64.new(0x12345678, 0x9ABCDEF0), "123456789ABCDEF0"))

T.section("findData returns the data and the UUID it was asked for")
local serviceData = {
  { uuid = "FCD2", data = "bthome_data" },
  { uuid = "FD3D", data = "switchbot_data" },
}
T.eq("a string UUID", { UUID.findData(serviceData, "FCD2") }, { "bthome_data", "FCD2" })
T.eq("a number UUID", { UUID.findData(serviceData, 0xFCD2) }, { "bthome_data", 0xFCD2 })
T.eq("in any case", { UUID.findData(serviceData, "fcd2") }, { "bthome_data", "fcd2" })
T.eq("a UUID not present", { UUID.findData(serviceData, "1234") }, {})
T.eq("no service data", { UUID.findData(nil, "FCD2") }, {})
-- With several UUIDs, the first service data entry that matches any of them wins, whatever their order.
T.eq("several, the first entry that matches", { UUID.findData(serviceData, "XXXX", "FD3D", "FCD2") }, {
  "bthome_data",
  "FCD2",
})
T.eq("several, none present", { UUID.findData(serviceData, "AAAA", "BBBB") }, {})

T.finish()
