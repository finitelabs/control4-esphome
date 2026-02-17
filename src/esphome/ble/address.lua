--- BLE MAC address conversion utilities.
--- Provides consistent handling of 48-bit Bluetooth MAC addresses.

local log = require("lib.logging")
local bit64 = require("bitn").bit64

--- @class BLEAddress
local BLEAddress = {}

--- BLE Address Type per Bluetooth Core Specification.
--- See: https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host-controller-interface/host-controller-interface-functional-specification.html
--- @enum BLEAddressType
BLEAddress.Type = {
  PUBLIC = 0, -- Public Device Address
  RANDOM = 1, -- Random Device Address
  RPA_PUBLIC = 2, -- RPA resolved to Public Identity Address
  RPA_RANDOM = 3, -- RPA resolved to Random Static Identity Address
}

--- Convert a Bluetooth MAC address string to a 48-bit integer.
--- @param mac string|nil MAC address in format "AA:BB:CC:DD:EE:FF" or "AABBCCDDEEFF"
--- @return integer|nil address 48-bit address as an integer, or nil if invalid
function BLEAddress.fromString(mac)
  if type(mac) ~= "string" or mac == "" then
    return nil
  end

  -- Remove colons, dashes, spaces and convert to uppercase
  mac = mac:gsub("[:%s%-]", ""):upper()

  -- Validate length
  if #mac ~= 12 then
    log:warn("Invalid MAC address length: %s", mac)
    return nil
  end

  -- Convert hex string to number
  local address = tonumber(mac, 16)
  if not address then
    log:warn("Invalid MAC address format: %s", mac)
    return nil
  end

  return address
end

--- Convert a 48-bit address number to MAC string.
--- @param address number|Int64HighLow|nil The 48-bit Bluetooth MAC address as a number
--- @return string|nil mac MAC address in format "AA:BB:CC:DD:EE:FF"
function BLEAddress.toString(address)
  if address == nil then
    return nil
  end
  -- Handle both number and Int64HighLow format from protobuf
  local addressNum = bit64.to_number(address, true) -- Strict since MAC addresses fit in <53 bits
  if type(addressNum) ~= "number" then
    log:warn("Invalid BLE address: %s", address)
    return nil
  end

  return string
    .format(
      "%02X:%02X:%02X:%02X:%02X:%02X",
      math.floor(addressNum / 0x10000000000) % 256,
      math.floor(addressNum / 0x100000000) % 256,
      math.floor(addressNum / 0x1000000) % 256,
      math.floor(addressNum / 0x10000) % 256,
      math.floor(addressNum / 0x100) % 256,
      addressNum % 256
    )
    :upper()
end

return BLEAddress
