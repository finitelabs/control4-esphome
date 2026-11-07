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

return BLEAdvertisementParser
