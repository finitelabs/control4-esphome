--- Tests the Yale protocol checksums against known-good vectors from yalexs-ble: the security checksum over a
--- command's first 12 bytes, written into a byte array or computed from a string, and the simple checksum.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_protocol.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local yale_protocol = require("esphome.ble.yale_protocol")

--- @param hex string
--- @return integer[]
local function hexToBytes(hex)
  local bytes = {}
  for i = 1, #hex, 2 do
    bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16)
  end
  return bytes
end

--- An 18-byte command: the 12 given bytes, a zero checksum, then 0x0F and key index 1.
--- @param hex string The first 12 bytes
--- @return integer[]
local function command(hex)
  local bytes = hexToBytes(hex)
  for i = #bytes + 1, 18 do
    bytes[i] = 0
  end
  bytes[17] = 0x0F
  bytes[18] = 0x01
  return bytes
end

-- { name, first 12 bytes, checksum as a little-endian u32 }
local SECURITY = {
  { "all zeros", "000000000000000000000000", 0x00000000 },
  { "all 0xFF", "ffffffffffffffffffffffff", 0x00000003 },
  { "all 0x01", "010101010101010101010101", 0xFCFCFCFD },
  { "ascending 0-11", "000102030405060708090a0b", 0xEAEDF0F4 },
  { "max first word only", "ffffffff0000000000000000", 0x00000001 },
  { "SEC_KEY_EXCHANGE bare", "010000000000000000000000", 0xFFFFFFFF },
  { "SEC_INIT bare", "030000000000000000000000", 0xFFFFFFFD },
  { "KEY_EXCHANGE with handshake keys", "01000000aabbccddeeff0011", 0x11324467 },
  { "SEC_INIT with handshake keys", "030000002233445566778899", 0x11335575 },
}

T.section("The security checksum written into a command")
for _, case in ipairs(SECURITY) do
  local bytes = command(case[2])
  yale_protocol.writeSecurityChecksum(bytes)
  T.eq(case[1], bytes[13] + bytes[14] * 256 + bytes[15] * 65536 + bytes[16] * 16777216, case[3])
end

T.section("The security checksum computed from a string")
for _, case in ipairs(SECURITY) do
  T.eq(case[1], yale_protocol.securityChecksum(string.char(unpack(command(case[2])))), case[3])
end

T.section("The simple checksum")
for _, case in ipairs({
  { "UNLOCK", "ee0a00060000000000000000000000000200", 0x06 },
  { "LOCK", "ee0b00050000000000000000000000000200", 0x05 },
  { "GETSTATUS", "ee0200000000000000000000000000000200", 0x0E },
  { "STATUS_LOCK", "ee0200000200000000000000000000000200", 0x0C },
  { "STATUS_BATTERY", "ee0200000f00000000000000000000000200", 0xFF },
}) do
  T.eq(case[1], yale_protocol.simpleChecksum(string.char(unpack(hexToBytes(case[2])))), case[3])
end

T.section("Known-good responses sum to zero")
for _, case in ipairs({
  { "LOCK_JAMMED", "bb0b001b00000000000000000000001f0000" },
  { "LOCK_UNLOCKED", "bb0b00030000000000000000000000370000" },
}) do
  local sum = 0
  for _, byte in ipairs(hexToBytes(case[2])) do
    sum = sum + byte
  end
  T.eq(case[1], sum % 256, 0)
end

T.finish()
