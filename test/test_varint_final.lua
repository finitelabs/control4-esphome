#!/usr/bin/env luajit
-- Test varint encoding with correct expected value

package.path = package.path .. ";../src/?.lua"

local protobuf = require("lib.protobuf")

-- Helper to convert string to hex
local function to_hex(str)
  local hex = {}
  for i = 1, #str do
    table.insert(hex, string.format("%02X", string.byte(str, i)))
  end
  return table.concat(hex, " ")
end

-- Test MAC address: D8:35:34:38:49:70
local mac = "D8:35:34:38:49:70"

-- Parse MAC to {high, low} format (avoiding precision loss)
local clean_mac = mac:gsub("[:%s]", ""):upper()
local bytes = {}
for i = 1, 12, 2 do
  local byte = tonumber(clean_mac:sub(i, i + 1), 16)
  table.insert(bytes, byte)
end

local high_32 = bytes[1] * 256 + bytes[2]
local low_32 = bytes[3] * 0x1000000 + bytes[4] * 0x10000 + bytes[5] * 0x100 + bytes[6]
local address = { high_32, low_32 }

print("Testing varint encoding for MAC address: " .. mac)
print("Address (high, low): {0x" .. string.format("%X", address[1]) .. ", 0x" .. string.format("%X", address[2]) .. "}")
print("")

local encoded = protobuf.encode_varint(address)
local hex = to_hex(encoded)

-- The CORRECT expected value (verified with Python)
local expected = "F0 92 E1 A1 D3 86 36"

print("Encoded bytes:     " .. hex)
print("Expected bytes:    " .. expected)
print("")

if hex == expected then
  print("✓ CORRECT ENCODING!")
  os.exit(0)
else
  print("✗ INCORRECT ENCODING")
  os.exit(1)
end
