--- BLE advertisement parsing utilities.
--- Parses raw Bluetooth LE advertisement data according to GAP specification.

local log = require("lib.logging")
local bit64 = require("bitn").bit64
local BLEAddress = require("esphome.ble.address")
local BLECompanyIds = require("esphome.ble.company_identifiers")

--- A parsed service UUID entry from advertisement data.
--- @class BLEServiceUUID
--- @field uuid string The service UUID (4-char hex for 16-bit, full UUID for 128-bit)

--- A parsed service data entry from advertisement data.
--- @class BLEServiceData
--- @field uuid string The service UUID (4-char hex for 16-bit, 8-char for 32-bit, full UUID for 128-bit)
--- @field data string Raw service data bytes

--- A parsed manufacturer data entry from advertisement data.
--- @class BLEManufacturerData
--- @field company integer The 16-bit company identifier
--- @field companyName string|nil Human-readable company name if known
--- @field data string Raw manufacturer-specific data bytes

--- Parsed BLE advertisement flags.
--- @class BLEFlags
--- @field leLimitedDiscoverable boolean LE Limited Discoverable Mode
--- @field leGeneralDiscoverable boolean LE General Discoverable Mode
--- @field brEdrNotSupported boolean BR/EDR Not Supported (device is LE only)
--- @field simultaneousLeBredrController boolean Simultaneous LE and BR/EDR (Controller)
--- @field simultaneousLeBredrHost boolean Simultaneous LE and BR/EDR (Host)

--- Parsed BLE advertisement data structure.
--- @class BLEAdvertisementData
--- @field name string|nil Device name (shortened or complete local name)
--- @field flags BLEFlags|nil Advertisement flags (discoverable mode, BR/EDR support)
--- @field txPower number|nil TX power level in dBm (signed)
--- @field serviceUuids BLEServiceUUID[] List of advertised service UUIDs
--- @field serviceData BLEServiceData[] List of service data entries
--- @field manufacturerData BLEManufacturerData[] List of manufacturer data entries

--- Enriched BLE advertisement with parsed fields merged in.
--- @class BLEAdvertisement : BLEAdvertisementData
--- @field mac string MAC address in format "AA:BB:CC:DD:EE:FF"
--- @field addressType BLEAddressType? Bluetooth address type
--- @field rssi number? RSSI in dBm
--- @field manufacturer string? Manufacturer name from first manufacturer data entry

--- @class BLEAdvertisementParser
local BLEAdvertisementParser = {}

--- Create a manufacturer data entry with company lookup.
--- @param company integer The 16-bit company identifier
--- @param data string Raw manufacturer-specific data bytes
--- @return BLEManufacturerData entry The manufacturer data entry
local function createManufacturerEntry(company, data)
  return {
    company = company,
    companyName = BLECompanyIds.getName(company),
    data = data,
  }
end

--- Get manufacturer name from the first manufacturer data entry with a non-empty company name.
--- @param manufacturerData BLEManufacturerData[] List of manufacturer data entries
--- @return string|nil manufacturerName The manufacturer name, or nil if not found
local function getManufacturerName(manufacturerData)
  for _, entry in ipairs(manufacturerData) do
    if not IsEmpty(entry.companyName) then
      --- @cast entry.companyName -nil
      return entry.companyName
    end
  end
  return nil
end

--- Parse a pre-decoded advertisement response (older ESPHome format).
--- Converts the ProtoBluetoothLEAdvertisementResponse format to the common BLEAdvertisement structure.
--- @param advertisement ProtoBluetoothLEAdvertisementResponse Pre-decoded advertisement from ESPHome
--- @return BLEAdvertisement|nil advertisement The parsed advertisement, or nil if the packet is invalid
function BLEAdvertisementParser.parse(advertisement)
  local address = advertisement.address
  if address == nil then
    return nil
  end
  -- Handle both number and Int64HighLow format from protobuf
  address = bit64.to_number(address, true) -- Strict since MAC addresses fit in <53 bits
  if type(address) ~= "number" then
    return nil
  end

  local mac = BLEAddress.toString(address)
  if IsEmpty(mac) then
    return nil
  end
  --- @cast mac -nil

  -- Convert service_uuids (string[]) to BLEServiceUUID[]
  --- @type BLEServiceUUID[]
  local serviceUuids = {}
  if advertisement.service_uuids then
    for _, uuid in ipairs(advertisement.service_uuids) do
      table.insert(serviceUuids, { uuid = uuid })
    end
  end

  -- Convert service_data (ProtoBluetoothServiceData[]) to BLEServiceData[]
  --- @type BLEServiceData[]
  local serviceData = {}
  if advertisement.service_data then
    for _, svc in ipairs(advertisement.service_data) do
      if svc.uuid then
        table.insert(serviceData, {
          uuid = svc.uuid,
          data = svc.data or "",
        })
      end
    end
  end

  -- Convert manufacturer_data (ProtoBluetoothServiceData[]) to BLEManufacturerData[]
  --- @type BLEManufacturerData[]
  local manufacturerData = {}
  if advertisement.manufacturer_data then
    for _, mfg in ipairs(advertisement.manufacturer_data) do
      -- The uuid field contains the company ID as a hex string (e.g., "004C" for Apple)
      local company = tonumber(mfg.uuid, 16)
      if company then
        table.insert(manufacturerData, createManufacturerEntry(company, mfg.data or ""))
      end
    end
  end

  --- @type BLEAdvertisement
  local result = {
    name = advertisement.name,
    addressType = advertisement.address_type --[[@as BLEAddressType?]],
    mac = mac,
    manufacturer = getManufacturerName(manufacturerData),
    manufacturerData = manufacturerData,
    serviceUuids = serviceUuids,
    serviceData = serviceData,
    txPower = nil, -- Not available in this format
    rssi = advertisement.rssi,
  }
  return result
end

--- Parse raw BLE advertisement data according to Bluetooth Core Specification GAP format.
--- Extracts device name, TX power, service UUIDs, service data, and manufacturer data
--- from the raw advertisement bytes using the GAP AD type format.
--- @param data string The raw advertisement data bytes
--- @return BLEAdvertisementData parsed The parsed advertisement data structure
local function parseAdvertisementData(data)
  --- @type BLEAdvertisementData
  local parsed = {
    serviceUuids = {},
    serviceData = {},
    manufacturerData = {},
  }

  if not data or #data == 0 then
    return parsed
  end

  local pos = 1
  while pos <= #data do
    -- Read length byte
    local length = string.byte(data, pos)
    if not length or length == 0 then
      break -- End of data
    end

    pos = pos + 1
    if pos + length - 1 > #data then
      log:warn("BLE advertisement data truncated at position %d", pos)
      break
    end

    -- Read AD type
    local adType = string.byte(data, pos)
    pos = pos + 1
    local adDataLen = length - 1

    -- Extract AD data
    local adData = string.sub(data, pos, pos + adDataLen - 1)
    pos = pos + adDataLen

    -- Parse based on AD type
    if adType == 0x01 then
      -- Flags
      if #adData >= 1 then
        local flagByte = string.byte(adData, 1)
        parsed.flags = {
          leLimitedDiscoverable = (flagByte % 2) >= 1,
          leGeneralDiscoverable = (math.floor(flagByte / 2) % 2) >= 1,
          brEdrNotSupported = (math.floor(flagByte / 4) % 2) >= 1,
          simultaneousLeBredrController = (math.floor(flagByte / 8) % 2) >= 1,
          simultaneousLeBredrHost = (math.floor(flagByte / 16) % 2) >= 1,
        }
      end
    elseif adType == 0x08 or adType == 0x09 then
      -- Shortened or Complete Local Name
      parsed.name = adData
    elseif adType == 0x02 or adType == 0x03 then
      -- Incomplete or Complete List of 16-bit Service UUIDs
      for i = 1, #adData, 2 do
        if i + 1 <= #adData then
          local uuid16 = string.byte(adData, i) + string.byte(adData, i + 1) * 256
          local uuidStr = string.format("%04X", uuid16)
          table.insert(parsed.serviceUuids, { uuid = uuidStr })
        end
      end
    elseif adType == 0x04 or adType == 0x05 then
      -- Incomplete or Complete List of 32-bit Service UUIDs
      for i = 1, #adData, 4 do
        if i + 3 <= #adData then
          local uuid32 = string.byte(adData, i)
            + string.byte(adData, i + 1) * 0x100
            + string.byte(adData, i + 2) * 0x10000
            + string.byte(adData, i + 3) * 0x1000000
          local uuidStr = string.format("%08X", uuid32)
          table.insert(parsed.serviceUuids, { uuid = uuidStr })
        end
      end
    elseif adType == 0x06 or adType == 0x07 then
      -- Incomplete or Complete List of 128-bit Service UUIDs
      for i = 1, #adData, 16 do
        local uuidBytes = string.sub(adData, i, i + 15)
        if #uuidBytes == 16 then
          -- Format as UUID string (little-endian to standard format)
          local uuid = string.format(
            "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            string.byte(uuidBytes, 4),
            string.byte(uuidBytes, 3),
            string.byte(uuidBytes, 2),
            string.byte(uuidBytes, 1),
            string.byte(uuidBytes, 6),
            string.byte(uuidBytes, 5),
            string.byte(uuidBytes, 8),
            string.byte(uuidBytes, 7),
            string.byte(uuidBytes, 9),
            string.byte(uuidBytes, 10),
            string.byte(uuidBytes, 11),
            string.byte(uuidBytes, 12),
            string.byte(uuidBytes, 13),
            string.byte(uuidBytes, 14),
            string.byte(uuidBytes, 15),
            string.byte(uuidBytes, 16)
          )
          table.insert(parsed.serviceUuids, { uuid = uuid })
        end
      end
    elseif adType == 0x16 then
      -- Service Data - 16-bit UUID
      if #adData >= 2 then
        local uuid16 = string.byte(adData, 1) + string.byte(adData, 2) * 256
        local uuidStr = string.format("%04X", uuid16)
        local serviceData = string.sub(adData, 3)
        table.insert(parsed.serviceData, { uuid = uuidStr, data = serviceData })
      end
    elseif adType == 0x20 then
      -- Service Data - 32-bit UUID
      if #adData >= 4 then
        local uuid32 = string.byte(adData, 1)
          + string.byte(adData, 2) * 0x100
          + string.byte(adData, 3) * 0x10000
          + string.byte(adData, 4) * 0x1000000
        local uuidStr = string.format("%08X", uuid32)
        local serviceData = string.sub(adData, 5)
        table.insert(parsed.serviceData, { uuid = uuidStr, data = serviceData })
      end
    elseif adType == 0x21 then
      -- Service Data - 128-bit UUID
      if #adData >= 16 then
        local uuidBytes = string.sub(adData, 1, 16)
        -- Format as UUID string (little-endian to standard format)
        local uuidStr = string.format(
          "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
          string.byte(uuidBytes, 4),
          string.byte(uuidBytes, 3),
          string.byte(uuidBytes, 2),
          string.byte(uuidBytes, 1),
          string.byte(uuidBytes, 6),
          string.byte(uuidBytes, 5),
          string.byte(uuidBytes, 8),
          string.byte(uuidBytes, 7),
          string.byte(uuidBytes, 9),
          string.byte(uuidBytes, 10),
          string.byte(uuidBytes, 11),
          string.byte(uuidBytes, 12),
          string.byte(uuidBytes, 13),
          string.byte(uuidBytes, 14),
          string.byte(uuidBytes, 15),
          string.byte(uuidBytes, 16)
        )
        local serviceData = string.sub(adData, 17)
        table.insert(parsed.serviceData, { uuid = uuidStr, data = serviceData })
      end
    elseif adType == 0x0A then
      -- TX Power Level (signed 8-bit)
      if #adData >= 1 then
        local power = string.byte(adData, 1)
        if power > 127 then
          power = power - 256
        end -- Convert to signed
        parsed.txPower = power
      end
    elseif adType == 0xFF then
      -- Manufacturer Specific Data
      if #adData >= 2 then
        local company = string.byte(adData, 1) + string.byte(adData, 2) * 256
        local mfgData = string.sub(adData, 3)
        table.insert(parsed.manufacturerData, createManufacturerEntry(company, mfgData))
      end
    end
  end

  return parsed
end

--- Enrich a raw advertisement with parsed data.
--- Parses the raw advertisement data and merges the extracted fields (name, TX power, service
--- UUIDs, service data, manufacturer data) into the advertisement table.
--- @param rawAdvertisement ProtoBluetoothLERawAdvertisement Raw advertisement from ESPHome with address, rssi, data fields
--- @return BLEAdvertisement|nil advertisement The parsed advertisement, or nil if the packet is invalid
function BLEAdvertisementParser.parseRaw(rawAdvertisement)
  -- Parse the raw advertisement data
  local address = rawAdvertisement.address
  if address == nil then
    return nil
  end
  -- Handle both number and Int64HighLow format from protobuf
  address = bit64.to_number(address, true) -- Strict since MAC addresses fit in <53 bits
  if type(address) ~= "number" then
    return nil
  end

  local mac = BLEAddress.toString(address)
  if IsEmpty(mac) then
    return nil
  end
  --- @cast mac -nil

  local parsedData = parseAdvertisementData(rawAdvertisement.data or "")

  --- @type BLEAdvertisement
  local advertisement = {
    name = parsedData.name,
    addressType = rawAdvertisement.address_type --[[@as BLEAddressType?]],
    mac = mac,
    flags = parsedData.flags,
    manufacturer = getManufacturerName(parsedData.manufacturerData),
    manufacturerData = parsedData.manufacturerData,
    serviceUuids = parsedData.serviceUuids,
    serviceData = parsedData.serviceData,
    txPower = parsedData.txPower,
    rssi = rawAdvertisement.rssi,
  }
  return advertisement
end

--- Convert a parsed advertisement to a human-readable string.
--- @param advertisement BLEAdvertisement The parsed advertisement
--- @return string str Human-readable representation
function BLEAdvertisementParser.toString(advertisement)
  local parts = { advertisement.mac }

  -- Name
  if advertisement.name then
    table.insert(parts, string.format("name=%q", advertisement.name))
  end

  -- RSSI
  if advertisement.rssi then
    table.insert(parts, string.format("rssi=%d", advertisement.rssi))
  end

  -- Manufacturer
  if advertisement.manufacturer then
    table.insert(parts, string.format("mfr=%q", advertisement.manufacturer))
  end

  -- Flags
  if advertisement.flags then
    local flagParts = {}
    if advertisement.flags.leGeneralDiscoverable then
      table.insert(flagParts, "discoverable")
    elseif advertisement.flags.leLimitedDiscoverable then
      table.insert(flagParts, "limited")
    end
    if advertisement.flags.brEdrNotSupported then
      table.insert(flagParts, "LE-only")
    end
    if #flagParts > 0 then
      table.insert(parts, "flags=[" .. table.concat(flagParts, ",") .. "]")
    end
  end

  -- TX Power
  if advertisement.txPower then
    table.insert(parts, string.format("txPower=%ddBm", advertisement.txPower))
  end

  -- Service UUIDs
  if advertisement.serviceUuids and #advertisement.serviceUuids > 0 then
    local uuids = {}
    for _, svc in ipairs(advertisement.serviceUuids) do
      table.insert(uuids, svc.uuid)
    end
    table.insert(parts, "services=[" .. table.concat(uuids, ",") .. "]")
  end

  -- Service Data (show UUIDs and data lengths)
  if advertisement.serviceData and #advertisement.serviceData > 0 then
    local svcData = {}
    for _, sd in ipairs(advertisement.serviceData) do
      table.insert(svcData, string.format("%s:%dB", sd.uuid, #(sd.data or "")))
    end
    table.insert(parts, "svcData=[" .. table.concat(svcData, ",") .. "]")
  end

  -- Manufacturer Data (show company and data lengths)
  if advertisement.manufacturerData and #advertisement.manufacturerData > 0 then
    local mfgData = {}
    for _, md in ipairs(advertisement.manufacturerData) do
      local name = md.companyName or string.format("0x%04X", md.company)
      table.insert(mfgData, string.format("%s:%dB", name, #(md.data or "")))
    end
    table.insert(parts, "mfgData=[" .. table.concat(mfgData, ",") .. "]")
  end

  return table.concat(parts, " ")
end

--- Run self-tests for the BLE parser.
--- @return boolean passed True if all tests passed
function BLEAdvertisementParser.selftest()
  print("Running BLE parser tests...")
  local passed = 0
  local total = 0

  local unpack_fn = unpack or table.unpack

  --- Deep compare two tables for equality.
  --- @param a any
  --- @param b any
  --- @return boolean
  local function deepEqual(a, b)
    if type(a) ~= type(b) then
      return false
    end
    if type(a) ~= "table" then
      return a == b
    end
    -- Check all keys in a exist in b with same value
    for k, v in pairs(a) do
      if not deepEqual(v, b[k]) then
        return false
      end
    end
    -- Check all keys in b exist in a
    for k, _ in pairs(b) do
      if a[k] == nil then
        return false
      end
    end
    return true
  end

  --- Format a value for display in test output.
  --- @param v any
  --- @return string
  local function formatValue(v)
    if type(v) == "table" then
      local parts = {}
      for k, val in pairs(v) do
        table.insert(parts, string.format("%s=%s", tostring(k), formatValue(val)))
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    elseif type(v) == "string" then
      -- Show hex for binary strings
      if #v > 0 and string.byte(v, 1) < 32 then
        local hex = {}
        for i = 1, #v do
          table.insert(hex, string.format("%02X", string.byte(v, i)))
        end
        return "0x" .. table.concat(hex)
      end
      return string.format("%q", v)
    else
      return tostring(v)
    end
  end

  -- Test vectors: { name, fn, inputs, expected, compare (optional) }
  local test_vectors = {
    -- Empty data
    {
      name = "parseAdvertisementData: empty string",
      fn = parseAdvertisementData,
      inputs = { "" },
      expected = {
        name = nil,
        flags = nil,
        serviceUuids = {},
        serviceData = {},
        manufacturerData = {},
      },
    },

    -- Flags (0x01)
    {
      name = "parseAdvertisementData: flags LE General Discoverable",
      fn = parseAdvertisementData,
      inputs = { "\x02\x01\x06" }, -- length=2, type=0x01, flags=0x06
      expected = {
        name = nil,
        flags = {
          leLimitedDiscoverable = false,
          leGeneralDiscoverable = true,
          brEdrNotSupported = true,
          simultaneousLeBredrController = false,
          simultaneousLeBredrHost = false,
        },
        serviceUuids = {},
        serviceData = {},
        manufacturerData = {},
      },
    },
    {
      name = "parseAdvertisementData: flags all set",
      fn = parseAdvertisementData,
      inputs = { "\x02\x01\x1F" }, -- length=2, type=0x01, flags=0x1F (all 5 bits)
      expected = {
        name = nil,
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

    -- Complete Local Name (0x09)
    {
      name = "parseAdvertisementData: complete local name",
      fn = parseAdvertisementData,
      inputs = { "\x05\x09Test" }, -- length=5, type=0x09, "Test"
      expected = {
        name = "Test",
        flags = nil,
        serviceUuids = {},
        serviceData = {},
        manufacturerData = {},
      },
    },

    -- 16-bit Service UUIDs (0x03)
    {
      name = "parseAdvertisementData: 16-bit service UUID",
      fn = parseAdvertisementData,
      inputs = { "\x03\x03\x0D\xFD" }, -- length=3, type=0x03, UUID=0xFD0D (little-endian)
      expected = {
        name = nil,
        flags = nil,
        serviceUuids = { { uuid = "FD0D" } },
        serviceData = {},
        manufacturerData = {},
      },
    },

    -- 32-bit Service UUIDs (0x05)
    {
      name = "parseAdvertisementData: 32-bit service UUID",
      fn = parseAdvertisementData,
      inputs = { "\x05\x05\x78\x56\x34\x12" }, -- length=5, type=0x05, UUID=0x12345678
      expected = {
        name = nil,
        flags = nil,
        serviceUuids = { { uuid = "12345678" } },
        serviceData = {},
        manufacturerData = {},
      },
    },

    -- Service Data 16-bit (0x16)
    {
      name = "parseAdvertisementData: service data 16-bit",
      fn = parseAdvertisementData,
      inputs = { "\x06\x16\x3D\xFD\x01\x02\x03" }, -- length=6, type=0x16, UUID=0xFD3D, data=010203
      expected = {
        name = nil,
        flags = nil,
        serviceUuids = {},
        serviceData = { { uuid = "FD3D", data = "\x01\x02\x03" } },
        manufacturerData = {},
      },
    },

    -- Service Data 32-bit (0x20)
    {
      name = "parseAdvertisementData: service data 32-bit",
      fn = parseAdvertisementData,
      inputs = { "\x06\x20\x78\x56\x34\x12\xAB" }, -- length=6, type=0x20, UUID=0x12345678, data=AB
      expected = {
        name = nil,
        flags = nil,
        serviceUuids = {},
        serviceData = { { uuid = "12345678", data = "\xAB" } },
        manufacturerData = {},
      },
    },

    -- Manufacturer Data (0xFF)
    {
      name = "parseAdvertisementData: manufacturer data Apple",
      fn = parseAdvertisementData,
      inputs = { "\x05\xFF\x4C\x00\x12\x34" }, -- length=5, type=0xFF, company=0x004C (Apple), data=1234
      expected = {
        name = nil,
        flags = nil,
        serviceUuids = {},
        serviceData = {},
        manufacturerData = { { company = 0x004C, companyName = "Apple, Inc.", data = "\x12\x34" } },
      },
    },

    -- TX Power (0x0A)
    {
      name = "parseAdvertisementData: TX power positive",
      fn = parseAdvertisementData,
      inputs = { "\x02\x0A\x04" }, -- length=2, type=0x0A, power=4 dBm
      expected = {
        name = nil,
        flags = nil,
        txPower = 4,
        serviceUuids = {},
        serviceData = {},
        manufacturerData = {},
      },
    },
    {
      name = "parseAdvertisementData: TX power negative",
      fn = parseAdvertisementData,
      inputs = { "\x02\x0A\xF0" }, -- length=2, type=0x0A, power=-16 dBm (0xF0 = 240 -> -16)
      expected = {
        name = nil,
        flags = nil,
        txPower = -16,
        serviceUuids = {},
        serviceData = {},
        manufacturerData = {},
      },
    },

    -- Combined: typical BLE advertisement
    {
      name = "parseAdvertisementData: combined flags + name + service UUID",
      fn = parseAdvertisementData,
      inputs = { "\x02\x01\x06\x05\x09Test\x03\x03\x0D\xFD" },
      expected = {
        name = "Test",
        flags = {
          leLimitedDiscoverable = false,
          leGeneralDiscoverable = true,
          brEdrNotSupported = true,
          simultaneousLeBredrController = false,
          simultaneousLeBredrHost = false,
        },
        serviceUuids = { { uuid = "FD0D" } },
        serviceData = {},
        manufacturerData = {},
      },
    },
  }

  for _, test in ipairs(test_vectors) do
    total = total + 1
    local result = test.fn(unpack_fn(test.inputs))
    local isEqual = deepEqual(result, test.expected)

    if isEqual then
      print("  PASS: " .. test.name)
      passed = passed + 1
    else
      print("  FAIL: " .. test.name)
      print("    expected: " .. formatValue(test.expected))
      print("    got:      " .. formatValue(result))
    end
  end

  print(string.format("\nTests: %d/%d passed\n", passed, total))
  return passed == total
end

return BLEAdvertisementParser
