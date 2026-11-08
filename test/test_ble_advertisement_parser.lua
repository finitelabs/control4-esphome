--- Tests the BLE advertisement parser on raw advertisement data: flags, local name, 16- and 32-bit service UUIDs,
--- 16- and 32-bit service data, manufacturer data and TX power, alone and combined.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_advertisement_parser.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local BLEAdvertisementParser = require("esphome.ble.parsers.advertisement")

--- The fields parsed from `data`, as parseRaw puts them on the advertisement.
--- @param data string Raw advertisement data
--- @return table
local function parse(data)
  local advertisement = BLEAdvertisementParser.parseRaw({ address = 1, data = data, rssi = -50 })
  return {
    name = advertisement.name,
    flags = advertisement.flags,
    txPower = advertisement.txPower,
    serviceUuids = advertisement.serviceUuids,
    serviceData = advertisement.serviceData,
    manufacturerData = advertisement.manufacturerData,
  }
end

local NO_FLAGS = nil
local GENERAL_DISCOVERABLE = {
  leLimitedDiscoverable = false,
  leGeneralDiscoverable = true,
  brEdrNotSupported = true,
  simultaneousLeBredrController = false,
  simultaneousLeBredrHost = false,
}

T.section("Each advertisement data type is parsed")
for _, case in ipairs({
  {
    "empty data",
    "",
    { flags = NO_FLAGS, serviceUuids = {}, serviceData = {}, manufacturerData = {} },
  },
  {
    "flags LE General Discoverable",
    "\x02\x01\x06",
    { flags = GENERAL_DISCOVERABLE, serviceUuids = {}, serviceData = {}, manufacturerData = {} },
  },
  {
    "flags all set",
    "\x02\x01\x1F",
    {
      flags = {
        leLimitedDiscoverable = true,
        leGeneralDiscoverable = true,
        brEdrNotSupported = true,
        simultaneousLeBredrController = true,
        simultaneousLeBredrHost = true,
      },
      serviceUuids = {},
      serviceData = {},
      manufacturerData = {},
    },
  },
  {
    "complete local name",
    "\x05\x09Test",
    { name = "Test", serviceUuids = {}, serviceData = {}, manufacturerData = {} },
  },
  {
    "16-bit service UUID, little-endian",
    "\x03\x03\x0D\xFD",
    { serviceUuids = { { uuid = "FD0D" } }, serviceData = {}, manufacturerData = {} },
  },
  {
    "32-bit service UUID",
    "\x05\x05\x78\x56\x34\x12",
    { serviceUuids = { { uuid = "12345678" } }, serviceData = {}, manufacturerData = {} },
  },
  {
    "service data with a 16-bit UUID",
    "\x06\x16\x3D\xFD\x01\x02\x03",
    { serviceUuids = {}, serviceData = { { uuid = "FD3D", data = "\x01\x02\x03" } }, manufacturerData = {} },
  },
  {
    "service data with a 32-bit UUID",
    "\x06\x20\x78\x56\x34\x12\xAB",
    { serviceUuids = {}, serviceData = { { uuid = "12345678", data = "\xAB" } }, manufacturerData = {} },
  },
  {
    "manufacturer data with its company name",
    "\x05\xFF\x4C\x00\x12\x34",
    {
      serviceUuids = {},
      serviceData = {},
      manufacturerData = { { company = 0x004C, companyName = "Apple, Inc.", data = "\x12\x34" } },
    },
  },
  {
    "TX power positive",
    "\x02\x0A\x04",
    { txPower = 4, serviceUuids = {}, serviceData = {}, manufacturerData = {} },
  },
  {
    "TX power negative",
    "\x02\x0A\xF0",
    { txPower = -16, serviceUuids = {}, serviceData = {}, manufacturerData = {} },
  },
  {
    "flags, name and service UUID together",
    "\x02\x01\x06\x05\x09Test\x03\x03\x0D\xFD",
    {
      name = "Test",
      flags = GENERAL_DISCOVERABLE,
      serviceUuids = { { uuid = "FD0D" } },
      serviceData = {},
      manufacturerData = {},
    },
  },
}) do
  T.eq(case[1], parse(case[2]), case[3])
end

T.finish()
