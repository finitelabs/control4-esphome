#!/usr/bin/env luajit
-- Quick test to verify varint encoding

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
local address = 0

-- Convert MAC to 48-bit integer
for byte_str in mac:gmatch("[^:]+") do
  local byte = tonumber(byte_str, 16)
  address = address * 256 + byte
end

print("Testing varint encoding for MAC address: " .. mac)
print("Address (decimal): " .. string.format("%.0f", address))
print("Address (hex):     0x" .. string.format("%X", address))
print("")

local encoded = protobuf.encode_varint(address)
local hex = to_hex(encoded)

print("Encoded bytes:     " .. hex)
print("Expected bytes:    F0 92 E1 A1 DA 8D 36")
print("")

if hex == "F0 92 E1 A1 DA 8D 36" then
  print("✓ CORRECT ENCODING!")
  os.exit(0)
else
  print("✗ INCORRECT ENCODING")
  os.exit(1)
end
