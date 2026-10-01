--- Tests the Homedics SereneScent wire protocol and advertisement parser against
--- the Home Assistant integration they were ported from.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_serenescent_protocol.lua
---
--- Every expected frame below is copied byte for byte from upstream rather than
--- rebuilt from the module's own tables, so a typo in one cannot hide in both.
--- The single real status capture upstream publishes is the fixture the parser
--- is held to; the other status frames are that capture with one field changed,
--- because no other capture exists.
---   https://github.com/john-k-mcdowell/Homedics-SereneScent/blob/main/docs/PROTOCOL.md
---   https://github.com/john-k-mcdowell/Homedics-SereneScent/blob/main/custom_components/homedics_serenescent/const.py

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local protocol = require("esphome.ble.serenescent_protocol")
local SereneScent = require("esphome.ble.parsers.serenescent")
local UUID = require("esphome.ble.uuid")

local function bytes(...)
  return string.char(...)
end

local function hex(data)
  return ((data:gsub(".", function(c)
    return string.format("%02X ", c:byte())
  end)):gsub(" $", ""))
end

--- PROTOCOL.md "Status Query Response": powered on, LOW, WHITE, schedule off, HOME.
local CAPTURED_STATUS =
  bytes(0xFF, 0xFB, 0x40, 0x06, 0x00, 0x16, 0x00, 0x00, 0x0A, 0x00, 0xF0, 0x7F, 0x02, 0x00, 0x01, 0x00)

--- The captured frame with one 0-indexed byte replaced.
local function statusWith(offset, value)
  return CAPTURED_STATUS:sub(1, offset) .. string.char(value) .. CAPTURED_STATUS:sub(offset + 2)
end

--------------------------------------------------------------------------------
T.section("GATT UUIDs match const.py")
--------------------------------------------------------------------------------

T.check("service", UUID.matches(protocol.UUID.SERVICE, "53527aa4-29f7-ae11-4e74-997334782568"), protocol.UUID.SERVICE)
T.check("tx (write)", UUID.matches(protocol.UUID.TX, "ee684b1a-1e9b-ed3e-ee55-f894667e92ac"), protocol.UUID.TX)
T.check("rx (notify)", UUID.matches(protocol.UUID.RX, "654b749c-e37f-ae1f-ebab-40ca133e3690"), protocol.UUID.RX)

--------------------------------------------------------------------------------
T.section("command frames match const.py byte for byte")
--------------------------------------------------------------------------------

local EXPECTED = {
  { "power on", protocol.powerCommand(true), bytes(0xFF, 0xFA, 0x10, 0x04) },
  { "power off", protocol.powerCommand(false), bytes(0xFF, 0xFA, 0x11, 0x04) },
  { "intensity low", protocol.intensityCommand("low"), bytes(0xFF, 0xFA, 0x17, 0x08, 0x00, 0x0A, 0x00, 0xF0) },
  { "intensity medium", protocol.intensityCommand("medium"), bytes(0xFF, 0xFA, 0x17, 0x08, 0x00, 0x14, 0x00, 0x82) },
  { "intensity high", protocol.intensityCommand("high"), bytes(0xFF, 0xFA, 0x17, 0x08, 0x00, 0x1E, 0x00, 0x3C) },
  { "color off", protocol.colorCommand("off"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x00) },
  { "color rotating", protocol.colorCommand("rotating"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x01) },
  { "color white", protocol.colorCommand("white"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x02) },
  { "color red", protocol.colorCommand("red"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x03) },
  { "color blue", protocol.colorCommand("blue"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x04) },
  { "color violet", protocol.colorCommand("violet"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x05) },
  { "color green", protocol.colorCommand("green"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x06) },
  { "color orange", protocol.colorCommand("orange"), bytes(0xFF, 0xFA, 0x16, 0x05, 0x07) },
  { "status query, HOME", protocol.statusQuery(protocol.Mode.HOME), bytes(0xFF, 0xFA, 0x40, 0x05, 0x00) },
  { "status query, SCHEDULE", protocol.statusQuery(protocol.Mode.SCHEDULE), bytes(0xFF, 0xFA, 0x40, 0x05, 0x01) },
  { "status query, mode never read", protocol.statusQuery(nil), bytes(0xFF, 0xFA, 0x40, 0x05, 0x00) },
  { "switch to HOME mode", protocol.homeModeCommand(), bytes(0xFF, 0xFA, 0x43, 0x05, 0x00) },
}
for _, case in ipairs(EXPECTED) do
  local name, got, want = case[1], case[2], case[3]
  T.check(name, got == want, string.format("got %s, want %s", got and hex(got) or "nil", hex(want)))
end

T.eq("an unknown intensity has no frame", protocol.intensityCommand("max"), nil)
T.eq("intensity is case-sensitive; the driver lowercases first", protocol.intensityCommand("Low"), nil)
T.eq("an unknown color has no frame", protocol.colorCommand("pink"), nil)
T.eq("a nil color has no frame", protocol.colorCommand(nil), nil)

--------------------------------------------------------------------------------
T.section("the captured status frame parses as documented")
--------------------------------------------------------------------------------

local parsed, err = protocol.parseResponse(CAPTURED_STATUS)
T.check("it parses", parsed ~= nil, err)
T.eq("echoes the status opcode", parsed and parsed.opcode, 0x40)
T.check(
  "power on, LOW, WHITE, schedule off, HOME",
  T.deepEqual(parsed and parsed.status, {
    power = true,
    intensity = "low",
    color = "white",
    schedule = false,
    mode = protocol.Mode.HOME,
  }),
  T.show(parsed and parsed.status)
)

--------------------------------------------------------------------------------
T.section("each status field is read from its own byte")
--------------------------------------------------------------------------------

-- Bytes 13 and 15 are both 00 in the capture, so a parser that swapped schedule
-- and mode would pass it; each is flipped on its own here to tell them apart.
local function status(frame)
  local response = protocol.parseResponse(frame)
  return response and response.status or {}
end

T.eq("byte 14 = 0 is off", status(statusWith(14, 0x00)).power, false)
T.eq("byte 13 = 1 is schedule on", status(statusWith(13, 0x01)).schedule, true)
T.eq("byte 13 = 1 leaves the mode HOME", status(statusWith(13, 0x01)).mode, protocol.Mode.HOME)
T.eq("byte 15 = 1 is SCHEDULE mode", status(statusWith(15, 0x01)).mode, protocol.Mode.SCHEDULE)
T.eq("byte 15 = 1 leaves the schedule flag off", status(statusWith(15, 0x01)).schedule, false)
T.eq("byte 8 = 20 is medium", status(statusWith(8, 20)).intensity, "medium")
T.eq("byte 8 = 30 is high", status(statusWith(8, 30)).intensity, "high")
for index, color in ipairs(protocol.COLORS) do
  T.eq("byte 12 = " .. (index - 1) .. " is " .. color, status(statusWith(12, index - 1)).color, color)
end

-- Upstream substitutes "low" and "white" here. The parser reports unknown
-- instead so the driver can keep the last value rather than invent one.
T.eq("an unknown intensity byte is nil, not low", status(statusWith(8, 15)).intensity, nil)
T.eq("an unknown color byte is nil, not white", status(statusWith(12, 9)).color, nil)
T.eq("an unknown byte still reports power", status(statusWith(8, 15)).power, true)

--------------------------------------------------------------------------------
T.section("acks and non-responses")
--------------------------------------------------------------------------------

-- PROTOCOL.md "Acknowledgment Responses"
for _, case in ipairs({
  { "power on ack", bytes(0xFF, 0xFB, 0x10), 0x10 },
  { "power off ack", bytes(0xFF, 0xFB, 0x11), 0x11 },
  { "intensity ack", bytes(0xFF, 0xFB, 0x17), 0x17 },
  { "color ack", bytes(0xFF, 0xFB, 0x16), 0x16 },
  { "schedule sync ack (4 bytes)", bytes(0xFF, 0xFB, 0x15, 0x08), 0x15 },
}) do
  local response = protocol.parseResponse(case[2])
  T.eq(case[1] .. " echoes its opcode", response and response.opcode, case[3])
  T.eq(case[1] .. " carries no status", response and response.status, nil)
end

T.eq("a command frame is not a response", protocol.parseResponse(protocol.powerCommand(true)), nil)
T.eq("two bytes are not a response", protocol.parseResponse(bytes(0xFF, 0xFB)), nil)
T.eq("an empty notification is not a response", protocol.parseResponse(""), nil)
local short, shortErr = protocol.parseResponse(CAPTURED_STATUS:sub(1, 15))
T.eq("a truncated status frame is rejected", short, nil)
T.contains("and says why", shortErr or "", "too short")

--------------------------------------------------------------------------------
T.section("filler notifications")
--------------------------------------------------------------------------------

T.truthy("all 0xFF is filler", protocol.isFiller(string.rep("\255", 20)))
T.truthy("all 0x00 is filler", protocol.isFiller(string.rep("\0", 20)))
T.truthy("empty is filler", protocol.isFiller(""))
T.falsy("the captured status is not filler", protocol.isFiller(CAPTURED_STATUS))
T.falsy("an ack is not filler", protocol.isFiller(bytes(0xFF, 0xFB, 0x10)))
T.falsy("0xFF then zeros is not filler", protocol.isFiller(bytes(0xFF, 0x00, 0x00)))
T.falsy("zeros then 0xFF is not filler", protocol.isFiller(bytes(0x00, 0x00, 0xFF)))

--------------------------------------------------------------------------------
T.section("advertisements are matched on the local name alone")
--------------------------------------------------------------------------------

local DIFFUSER = SereneScent.DEVICE_NAMES.DIFFUSER

T.eq("ARMH- (the tested ARMH-972)", Select(SereneScent.parse("ARMH-972"), "deviceType"), DIFFUSER)
T.eq("ARPRP- (upstream's discovery manifest)", Select(SereneScent.parse("ARPRP-1234"), "deviceType"), DIFFUSER)
T.eq("a name without either prefix", SereneScent.parse("Govee_H5075"), nil)
T.eq("the prefix must lead the name", SereneScent.parse("MY-ARMH-972"), nil)
T.eq("the prefix is case-sensitive", SereneScent.parse("armh-972"), nil)
T.eq("no name", SereneScent.parse(nil), nil)
T.eq("an empty name", SereneScent.parse(""), nil)

--------------------------------------------------------------------------------
T.section("the scanner routes a diffuser to its sub-driver as an active device")
--------------------------------------------------------------------------------

local scanner = require("esphome.ble.scanner")

local diffuser = scanner:processAdvertisement({ mac = "AA:BB:CC:00:00:01", addressType = 0, name = "ARMH-972" }, "test")
T.eq("device type", Select(diffuser, "deviceType"), DIFFUSER)
T.eq("binding class", Select(diffuser, "bindingClass"), "ESPHOME_SERENESCENT")
T.eq("it needs a connection slot", Select(diffuser, "passive"), false)
-- The label the installer picks from, as the SereneScent docs quote it
T.eq(
  "display name",
  Select(diffuser, "displayName"),
  "AA:BB:CC:00:00:01 - ARMH-972 - [Homedics SereneScent / Active Connection]"
)

-- 0xFFF0 is a generic vendor UUID: claiming it would hand an unrelated beacon a
-- GATT slot, so the service UUID alone must not classify a device.
local stranger = scanner:processAdvertisement({
  mac = "AA:BB:CC:00:00:02",
  addressType = 0,
  serviceUuids = { { uuid = "FFF0" }, { uuid = "0000fff0-0000-1000-8000-00805f9b34fb" } },
}, "test")
T.check("an 0xFFF0 advertisement is still discovered", stranger ~= nil, "filtered out")
T.eq("but is not claimed as a diffuser", Select(stranger, "deviceType"), nil)
T.eq("and takes no connection slot", Select(stranger, "passive"), true)

-- A name seen once is kept across later advertisements that omit it.
scanner:processAdvertisement({ mac = "AA:BB:CC:00:00:03", addressType = 0, name = "ARPRP-7" }, "test")
local later = scanner:processAdvertisement({ mac = "AA:BB:CC:00:00:03", addressType = 0, rssi = -60 }, "test")
T.eq("a nameless follow-up keeps the classification", Select(later, "deviceType"), DIFFUSER)

T.finish()
