--- BLE UUID handling utilities.

local bit64 = require("bitn").bit64

local UUID = {}

--- Convert a uint64 value (number or {high, low} table) to a hex string.
--- @param value number|Int64HighLow|nil The uint64 value
--- @param width number Number of hex digits (default 16)
--- @return string hex The hex representation
local function uint64ToHex(value, width)
  width = width or 16
  if type(value) == "number" then
    -- Simple number - use string.format for what we can
    if value < 0x100000000 then
      return string.format("%0" .. width .. "X", value)
    else
      -- Large number, need to split
      local low = value % 0x100000000
      local high = math.floor(value / 0x100000000)
      return string.format("%0" .. (width - 8) .. "X%08X", high, low)
    end
  elseif type(value) == "table" and value[1] ~= nil and value[2] ~= nil then
    -- {high, low} pair
    local high = value[1]
    local low = value[2]
    return string.format("%0" .. (width - 8) .. "X%08X", high, low)
  else
    return string.rep("0", width)
  end
end

--- Convert a short UUID (16-bit or 32-bit) to a full 128-bit UUID string.
--- @param shortUuid number|nil The 16-bit or 32-bit UUID
--- @return string|nil uuid The full UUID string (e.g., "00001800-0000-1000-8000-00805F9B34FB")
function UUID.shortToString(shortUuid)
  if not shortUuid or shortUuid == 0 then
    return nil
  end
  -- Short UUIDs go in the high 32 bits of the first 64-bit segment
  -- Full UUID format: XXXXXXXX-0000-1000-8000-00805F9B34FB
  local uuidHigh = string.format("%08X00001000", shortUuid)
  local uuidLow = "800000805F9B34FB"
  local full = uuidHigh .. uuidLow
  return string.format(
    "%s-%s-%s-%s-%s",
    string.sub(full, 1, 8),
    string.sub(full, 9, 12),
    string.sub(full, 13, 16),
    string.sub(full, 17, 20),
    string.sub(full, 21, 32)
  )
end

--- Convert a repeated uint64 UUID field to a UUID string.
--- The UUID is stored as two 64-bit values: uuid[1] is high 64 bits, uuid[2] is low 64 bits.
--- @param uuidField number[]|Int64HighLow[]|nil The repeated uint64 field (array of 1-2 values)
--- @return string|nil uuid The UUID string or nil if not valid
function UUID.repeatedUint64ToString(uuidField)
  if not uuidField or type(uuidField) ~= "table" then
    return nil
  end
  if #uuidField < 2 then
    -- Only one element or empty - check if it's a short UUID encoded oddly
    return nil
  end

  -- uuid[1] = high 64 bits, uuid[2] = low 64 bits
  local highHex = uint64ToHex(uuidField[1], 16)
  local lowHex = uint64ToHex(uuidField[2], 16)

  -- Combine and format as UUID
  local full = highHex .. lowHex
  return string.format(
    "%s-%s-%s-%s-%s",
    string.sub(full, 1, 8),
    string.sub(full, 9, 12),
    string.sub(full, 13, 16),
    string.sub(full, 17, 20),
    string.sub(full, 21, 32)
  )
end

--- Convert a GATT service/characteristic UUID to a string.
--- Handles both short_uuid and uuid fields from ESPHome proto.
--- @param obj ProtoBluetoothGATTService|ProtoBluetoothGATTCharacteristic The service or characteristic object with uuid and/or short_uuid fields
--- @return string|nil uuid The UUID string or nil if not present
function UUID.fromGattObject(obj)
  if not obj then
    return nil
  end

  -- Prefer short_uuid if available (more common for standard services)
  if obj.short_uuid and obj.short_uuid ~= 0 then
    return UUID.shortToString(obj.short_uuid)
  end

  -- Otherwise try the repeated uint64 uuid field
  if obj.uuid then
    return UUID.repeatedUint64ToString(obj.uuid)
  end

  return nil
end

--- Check if a UUID is the Bluetooth Base UUID with a given short UUID.
--- @param uuidStr string The full UUID string
--- @param shortUuid number The short UUID to check against
--- @return boolean matches True if the UUID matches the short UUID
function UUID.matchesShortUuid(uuidStr, shortUuid)
  if not uuidStr or not shortUuid then
    return false
  end
  local expected = UUID.shortToString(shortUuid)
  return expected ~= nil and uuidStr:upper() == expected:upper()
end

--- Normalize a UUID to canonical form (uppercase hex string, no dashes).
--- Handles numbers, strings (with/without dashes), Int64HighLow, and Int64HighLow[].
--- @param uuid string|number|Int64HighLow|Int64HighLow[]|nil UUID in any format
--- @return string|nil normalized Uppercase hex string without dashes, or nil if invalid
function UUID.normalize(uuid)
  if uuid == nil then
    return nil
  end

  -- Number: convert to hex (handles 16-bit, 32-bit values)
  if type(uuid) == "number" then
    return string.format("%X", uuid)
  end

  -- String: remove dashes, convert to uppercase
  if type(uuid) == "string" then
    return uuid:gsub("-", ""):upper()
  end

  -- Int64HighLow: single 64-bit value
  if bit64.is_int64(uuid) then
    --- @cast uuid Int64HighLow
    return uint64ToHex(uuid, 16)
  end
  --- @cast uuid -Int64HighLow

  -- Table: could be Int64HighLow[] array (two 64-bit values for 128-bit UUID)
  if type(uuid) == "table" and #uuid >= 2 then
    local first = uuid[1]
    local second = uuid[2]
    -- Check if elements are Int64HighLow
    if bit64.is_int64(first) and bit64.is_int64(second) then
      --- @cast first Int64HighLow
      --- @cast second Int64HighLow
      local highHex = uint64ToHex(first, 16)
      local lowHex = uint64ToHex(second, 16)
      return highHex .. lowHex
    end
  end

  return nil
end

--- Compare two UUIDs (handles any format: string, number, Int64HighLow).
--- @param uuid1 string|number|Int64HighLow|nil First UUID
--- @param uuid2 string|number|Int64HighLow|nil Second UUID
--- @return boolean matches True if UUIDs match
function UUID.matches(uuid1, uuid2)
  local norm1 = UUID.normalize(uuid1)
  local norm2 = UUID.normalize(uuid2)
  if not norm1 or not norm2 then
    return false
  end
  return norm1 == norm2
end

--- Find service data by UUID in a BLE advertisement.
--- Searches for the first matching UUID from the provided list.
--- @param data BLEServiceData[]|nil Array of service data entries {uuid, data}
--- @param ... string|integer One or more UUIDs to search for (e.g., "FCD2", 0xFCD2)
--- @return string|nil data Raw service data bytes or nil if not found
--- @return string|integer|nil uuid The UUID that matched, or nil if not found
--- @overload fun(data: BLEServiceData[], ...: string): (string|nil, string|nil)
--- @overload fun(data: BLEServiceData[], ...: integer): (string|nil, integer|nil)
function UUID.findData(data, ...)
  if not data then
    return nil, nil
  end
  local uuids = { ... }
  if #uuids == 0 then
    return nil, nil
  end
  for _, entry in ipairs(data) do
    for _, uuid in ipairs(uuids) do
      if UUID.matches(entry.uuid, uuid) then
        return entry.data, uuid
      end
    end
  end
  return nil, nil
end

--- Find a service by UUID in a list of GATT services.
--- @param services ProtoBluetoothGATTService[] List of GATT services from bluetoothGattGetServices
--- @param targetUuid string The UUID to find
--- @return ProtoBluetoothGATTService|nil service The matching service or nil
function UUID.findService(services, targetUuid)
  if not services or not targetUuid then
    return nil
  end
  for _, svc in ipairs(services) do
    local svcUuid = UUID.fromGattObject(svc)
    if svcUuid and UUID.matches(svcUuid, targetUuid) then
      return svc
    end
  end
  return nil
end

--- Find a characteristic by UUID in a service.
--- @param service ProtoBluetoothGATTService The GATT service
--- @param targetUuid string The UUID to find
--- @return ProtoBluetoothGATTCharacteristic|nil characteristic The matching characteristic or nil
function UUID.findCharacteristic(service, targetUuid)
  if not service or not service.characteristics or not targetUuid then
    return nil
  end
  for _, chr in ipairs(service.characteristics) do
    local chrUuid = UUID.fromGattObject(chr)
    if chrUuid and UUID.matches(chrUuid, targetUuid) then
      return chr
    end
  end
  return nil
end

--- Common Bluetooth GATT UUIDs (short form - 16-bit)
UUID.GATT = {
  -- Standard Services
  GENERIC_ACCESS = 0x1800,
  GENERIC_ATTRIBUTE = 0x1801,
  DEVICE_INFORMATION = 0x180A,
  BATTERY_SERVICE = 0x180F,

  -- Standard Characteristics
  DEVICE_NAME = 0x2A00,
  APPEARANCE = 0x2A01,
  BATTERY_LEVEL = 0x2A19,
  MANUFACTURER_NAME = 0x2A29,
  MODEL_NUMBER = 0x2A24,
  SERIAL_NUMBER = 0x2A25,
  FIRMWARE_REVISION = 0x2A26,

  -- Descriptors
  CLIENT_CHARACTERISTIC_CONFIGURATION = 0x2902,
}

--- Run self-tests for UUID module.
--- @return boolean success True if all tests passed
function UUID.selftest()
  print("Testing UUID module...")
  local passed = 0
  local failed = 0

  local function test(name, condition)
    if condition then
      passed = passed + 1
      print("  PASS: " .. name)
    else
      failed = failed + 1
      print("  FAIL: " .. name)
    end
  end

  -- Test normalize with numbers
  test("normalize(0xFCD2) = 'FCD2'", UUID.normalize(0xFCD2) == "FCD2")
  test("normalize(0x1800) = '1800'", UUID.normalize(0x1800) == "1800")
  test("normalize(0x12345678) = '12345678'", UUID.normalize(0x12345678) == "12345678")

  -- Test normalize with strings
  test("normalize('fcd2') = 'FCD2'", UUID.normalize("fcd2") == "FCD2")
  test("normalize('FCD2') = 'FCD2'", UUID.normalize("FCD2") == "FCD2")
  test(
    "normalize with dashes",
    UUID.normalize("12345678-1234-5678-1234-567890ABCDEF") == "12345678123456781234567890ABCDEF"
  )

  -- Test normalize with nil
  test("normalize(nil) = nil", UUID.normalize(nil) == nil)

  -- Test matches with mixed formats
  test("matches(0xFCD2, 'FCD2')", UUID.matches(0xFCD2, "FCD2"))
  test("matches('fcd2', 0xFCD2)", UUID.matches("fcd2", 0xFCD2))
  test("matches('FD3D', 'fd3d')", UUID.matches("FD3D", "fd3d"))
  test("not matches(0xFCD2, 'FD3D')", not UUID.matches(0xFCD2, "FD3D"))

  -- Test findData
  local serviceData = {
    { uuid = "FCD2", data = "bthome_data" },
    { uuid = "FD3D", data = "switchbot_data" },
  }
  local foundData, foundUuid = UUID.findData(serviceData, "FCD2")
  test("findData with string UUID", foundData == "bthome_data" and foundUuid == "FCD2")
  foundData, foundUuid = UUID.findData(serviceData, 0xFCD2)
  test("findData with number UUID", foundData == "bthome_data" and foundUuid == 0xFCD2)
  foundData, foundUuid = UUID.findData(serviceData, "fcd2")
  test("findData case insensitive", foundData == "bthome_data" and foundUuid == "fcd2")
  foundData, foundUuid = UUID.findData(serviceData, "1234")
  test("findData not found", foundData == nil and foundUuid == nil)
  foundData, foundUuid = UUID.findData(nil, "FCD2")
  test("findData nil array", foundData == nil and foundUuid == nil)
  -- Test findData with multiple UUIDs
  foundData, foundUuid = UUID.findData(serviceData, "XXXX", "FD3D", "FCD2")
  test("findData multiple UUIDs finds first match", foundData == "switchbot_data" and foundUuid == "FD3D")
  foundData, foundUuid = UUID.findData(serviceData, "AAAA", "BBBB")
  test("findData multiple UUIDs none match", foundData == nil and foundUuid == nil)

  -- Test Int64HighLow if bit64 is available
  local int64_1 = bit64.new(0x12345678, 0x9ABCDEF0)
  if bit64.is_int64(int64_1) then
    test("normalize Int64HighLow", UUID.normalize(int64_1) == "123456789ABCDEF0")
    test("matches Int64HighLow with string", UUID.matches(int64_1, "123456789ABCDEF0"))
  end

  print(string.format("\nUUID module: %d/%d tests passed\n", passed, passed + failed))
  return failed == 0
end

return UUID
