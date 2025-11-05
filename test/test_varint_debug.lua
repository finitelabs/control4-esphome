#!/usr/bin/env luajit
-- Debug test for varint encoding

package.path = package.path .. ";../src/?.lua"

-- Load noiseprotocol first (it contains bit64 in package.preload)
require("vendor.noiseprotocol")
local bit64 = require("noiseprotocol.utils.bit64")

-- Helper to convert string to hex
local function to_hex(str)
  local hex = {}
  for i = 1, #str do
    table.insert(hex, string.format("%02X", string.byte(str, i)))
  end
  return table.concat(hex, " ")
end

-- Test MAC address: D8:35:34:38:49:70
local value = 237723020970352

print("Value (decimal): " .. string.format("%.0f", value))
print("Value (hex):     0x" .. string.format("%X", value))
print("")

-- Convert to {high, low}
local low_32 = value % 0x100000000
local high_32 = math.floor(value / 0x100000000)

print("Initial high_32: 0x" .. string.format("%X", high_32) .. " (" .. high_32 .. ")")
print("Initial low_32:  0x" .. string.format("%X", low_32) .. " (" .. low_32 .. ")")
print("")

local v = { high_32, low_32 }
local bytes = {}
local count = 0

repeat
  count = count + 1
  print("Iteration " .. count .. ":")
  print("  v = {0x" .. string.format("%X", v[1]) .. ", 0x" .. string.format("%X", v[2]) .. "}")

  -- Extract low 7 bits
  local byte = v[2] % 128
  print("  byte (before continue bit) = 0x" .. string.format("%02X", byte))

  -- Right shift by 7 bits
  v = bit64.shr(v, 7)
  print("  After shift: v = {0x" .. string.format("%X", v[1]) .. ", 0x" .. string.format("%X", v[2]) .. "}")

  -- Check if more bytes remain
  if v[1] ~= 0 or v[2] ~= 0 then
    byte = byte + 0x80
    print("  byte (with continue bit) = 0x" .. string.format("%02X", byte))
  else
    print("  byte (final, no continue bit) = 0x" .. string.format("%02X", byte))
  end
  
  table.insert(bytes, string.char(byte))
  print("")
until v[1] == 0 and v[2] == 0

local encoded = table.concat(bytes)
local hex = to_hex(encoded)

print("Encoded bytes:  " .. hex)
print("Expected bytes: F0 92 E1 A1 DA 8D 36")
