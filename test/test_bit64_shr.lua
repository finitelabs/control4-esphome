#!/usr/bin/env luajit

package.path = package.path .. ";../src/?.lua"

require("vendor.noiseprotocol")
local bit64 = require("noiseprotocol.utils.bit64")

-- Test case from iteration 4 -> 5
local v = { 0x0, 0x6C1A9A1 }

print("Before shift: {0x" .. string.format("%X", v[1]) .. ", 0x" .. string.format("%X", v[2]) .. "}")
print("Decimal value: " .. (v[1] * 0x100000000 + v[2]))

local result = bit64.shr(v, 7)

print("After shift:  {0x" .. string.format("%X", result[1]) .. ", 0x" .. string.format("%X", result[2]) .. "}")
print("Decimal value: " .. (result[1] * 0x100000000 + result[2]))

print("")
print("Expected: 0x" .. string.format("%X", math.floor(v[2] / 128)))
print("Got:      0x" .. string.format("%X", result[2]))

-- Manual calculation
local expected = math.floor(0x6C1A9A1 / 128)
print("")
print("Manual: " .. expected .. " (0x" .. string.format("%X", expected) .. ")")
