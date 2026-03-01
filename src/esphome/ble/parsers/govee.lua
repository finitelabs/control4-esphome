--- Govee BLE advertisement parser.
---
--- Sources:
---   - https://github.com/Bluetooth-Devices/govee-ble
---   - https://github.com/custom-components/ble_monitor
---   - https://github.com/wcbonner/GoveeBTTempLogger

local bit32 = require("bitn").bit32
local log = require("lib.logging")
local UUID = require("esphome.ble.uuid")

--- @class Govee
local Govee = {}

--- Govee manufacturer company IDs
--- @enum GoveeManufacturerId
Govee.ManufacturerId = {
  -- Temperature/Humidity sensors
  EC88 = 0xEC88, -- H5072, H5075, H5074, H5051, H5052, H5071
  ID_0001 = 0x0001, -- H5100-H5110, H5174, H5177, H5178, H5106, H5112
  ID_8801 = 0x8801, -- H5179
  ID_8803 = 0x8803, -- H5127 (occupancy)
  -- Meat thermometer IDs
  H5181_F861 = 0xF861,
  H5181_388A = 0x388A,
  H5181_EA42 = 0xEA42,
  H5181_AAA2 = 0xAAA2,
  H5181_D14B = 0xD14B,
  H5182 = 0x2730,
  H5183_67DD = 0x67DD,
  H5183_E02F = 0xE02F,
  H5183_F79F = 0xF79F,
  H5184 = 0x1B36,
  H5185_4A32 = 0x4A32,
  H5185_0332 = 0x0332,
  H5185_4C32 = 0x4C32,
  H5191 = 0xAC63,
  H5198 = 0x3022,
}

--- Govee device model codes (derived from name or service UUID)
--- @enum GoveeDeviceModel
Govee.DeviceModel = {
  -- Temperature/Humidity sensors (EC88)
  H5051 = "H5051",
  H5052 = "H5052",
  H5071 = "H5071",
  H5072 = "H5072",
  H5074 = "H5074",
  H5075 = "H5075",
  -- Temperature/Humidity sensors (0x0001)
  H5100 = "H5100",
  H5101 = "H5101",
  H5102 = "H5102",
  H5103 = "H5103",
  H5104 = "H5104",
  H5105 = "H5105",
  H5106 = "H5106", -- Air quality (PM2.5)
  H5108 = "H5108",
  H5110 = "H5110",
  H5112 = "H5112", -- Dual probe
  H5174 = "H5174",
  H5177 = "H5177",
  H5178 = "H5178", -- Dual sensor
  -- Temperature/Humidity sensors (0x8801)
  H5179 = "H5179",
  -- Meat thermometers
  H5055 = "H5055",
  H5181 = "H5181",
  H5182 = "H5182",
  H5183 = "H5183",
  H5184 = "H5184",
  H5185 = "H5185",
  H5191 = "H5191",
  H5198 = "H5198",
}

--- Device model to friendly name mapping
--- @type table<GoveeDeviceModel, string?>
Govee.DEVICE_NAMES = {
  -- Temperature/Humidity sensors
  [Govee.DeviceModel.H5051] = "Govee H5051",
  [Govee.DeviceModel.H5052] = "Govee H5052",
  [Govee.DeviceModel.H5071] = "Govee H5071",
  [Govee.DeviceModel.H5072] = "Govee H5072",
  [Govee.DeviceModel.H5074] = "Govee H5074",
  [Govee.DeviceModel.H5075] = "Govee H5075",
  [Govee.DeviceModel.H5100] = "Govee H5100",
  [Govee.DeviceModel.H5101] = "Govee H5101",
  [Govee.DeviceModel.H5102] = "Govee H5102",
  [Govee.DeviceModel.H5103] = "Govee H5103",
  [Govee.DeviceModel.H5104] = "Govee H5104",
  [Govee.DeviceModel.H5105] = "Govee H5105",
  [Govee.DeviceModel.H5106] = "Govee H5106",
  [Govee.DeviceModel.H5108] = "Govee H5108",
  [Govee.DeviceModel.H5110] = "Govee H5110",
  [Govee.DeviceModel.H5112] = "Govee H5112",
  [Govee.DeviceModel.H5174] = "Govee H5174",
  [Govee.DeviceModel.H5177] = "Govee H5177",
  [Govee.DeviceModel.H5178] = "Govee H5178",
  [Govee.DeviceModel.H5179] = "Govee H5179",
  -- Meat thermometers
  [Govee.DeviceModel.H5055] = "Govee H5055",
  [Govee.DeviceModel.H5181] = "Govee H5181",
  [Govee.DeviceModel.H5182] = "Govee H5182",
  [Govee.DeviceModel.H5183] = "Govee H5183",
  [Govee.DeviceModel.H5184] = "Govee H5184",
  [Govee.DeviceModel.H5185] = "Govee H5185",
  [Govee.DeviceModel.H5191] = "Govee H5191",
  [Govee.DeviceModel.H5198] = "Govee H5198",
}

--- @class GoveeParsedData
--- @field deviceType string Device type name
--- @field model string Device model code
--- @field temperature number|nil Temperature in Celsius
--- @field humidity number|nil Humidity percentage
--- @field battery number|nil Battery percentage (0-100)
--- @field pm25 number|nil PM2.5 in µg/m³ (H5106 only)
--- @field hasError boolean|nil True if device reports an error
--- @field sensorId integer|nil Sensor ID for dual-sensor devices (H5178, H5112)
--- @field probe1Temp number|nil Probe 1 temperature (meat thermometers)
--- @field probe2Temp number|nil Probe 2 temperature (meat thermometers)
--- @field probe3Temp number|nil Probe 3 temperature (meat thermometers)
--- @field probe4Temp number|nil Probe 4 temperature (meat thermometers)
--- @field probe1Alarm number|nil Probe 1 alarm temperature
--- @field probe2Alarm number|nil Probe 2 alarm temperature
--- @field ambientTemp number|nil Ambient temperature (H5191)

--------------------------------------------------------------------------------
-- Common Helper Functions (offset-based, like SwitchBot pattern)
--------------------------------------------------------------------------------

--- Safe byte extraction with bounds checking
--- @param data string|nil The data string
--- @param index integer 1-based index
--- @return integer|nil byte The byte value or nil if out of bounds
local function getByte(data, index)
  if not data or index < 1 or index > #data then
    return nil
  end
  return string.byte(data, index)
end

--- Parse battery percentage and error flag from a byte at offset
--- @param data string|nil The data string
--- @param offset integer 1-based offset of battery byte
--- @return integer|nil battery Battery percentage (0-100)
--- @return boolean|nil hasError Error flag
local function parseBattery(data, offset)
  local batteryByte = getByte(data, offset)
  if not batteryByte then
    return nil, nil
  end
  local battery = bit32.band(batteryByte, 0x7F)
  local hasError = bit32.band(batteryByte, 0x80) ~= 0
  return battery, hasError
end

--- Parse 3-byte combined temperature/humidity from data at offset
--- Format: 3 bytes combined = base_num
--- Temperature = int(base_num / 1000) / 10 (or negative if bit 0x800000 set)
--- Humidity = (base_num % 1000) / 10
--- @param data string|nil The data string
--- @param offset integer 1-based offset of first temp/humid byte
--- @return number|nil temperature Temperature in Celsius
--- @return number|nil humidity Humidity percentage
local function parse3ByteTempHumid(data, offset)
  local b1 = getByte(data, offset)
  local b2 = getByte(data, offset + 1)
  local b3 = getByte(data, offset + 2)

  if not b1 or not b2 or not b3 then
    return nil, nil
  end

  local baseNum = bit32.lshift(b1, 16) + bit32.lshift(b2, 8) + b3
  local isNegative = bit32.band(baseNum, 0x800000) ~= 0
  local tempAsInt = bit32.band(baseNum, 0x7FFFFF)

  local temperature
  if isNegative then
    temperature = -math.floor(tempAsInt / 1000) / 10
  else
    temperature = math.floor(tempAsInt / 1000) / 10
  end

  local humidity = (tempAsInt % 1000) / 10

  return temperature, humidity
end

--- Convert signed 16-bit two's complement value
--- @param value integer Unsigned 16-bit value
--- @return integer signed Signed value
local function toSigned16(value)
  if value >= 0x8000 then
    return value - 0x10000
  end
  return value
end

--- Parse 4-byte little-endian temperature/humidity from data at offset
--- Format: 2 bytes signed temp (LE), 2 bytes unsigned humidity (LE), both /100
--- @param data string|nil The data string
--- @param offset integer 1-based offset of first byte
--- @return number|nil temperature Temperature in Celsius
--- @return number|nil humidity Humidity percentage
local function parse4ByteTempHumidLE(data, offset)
  local tempLow = getByte(data, offset)
  local tempHigh = getByte(data, offset + 1)
  local humLow = getByte(data, offset + 2)
  local humHigh = getByte(data, offset + 3)

  if not tempLow or not tempHigh or not humLow or not humHigh then
    return nil, nil
  end

  local tempRaw = tempLow + bit32.lshift(tempHigh, 8)
  local humRaw = humLow + bit32.lshift(humHigh, 8)

  local temperature = toSigned16(tempRaw) / 100
  local humidity = humRaw / 100

  return temperature, humidity
end

--- Parse 16-bit big-endian value from data at offset
--- @param data string|nil The data string
--- @param offset integer 1-based offset of high byte
--- @return integer|nil value The 16-bit value or nil
local function parseBigEndian16(data, offset)
  local high = getByte(data, offset)
  local low = getByte(data, offset + 1)
  if not high or not low then
    return nil
  end
  return high * 256 + low
end

--- Parse signed 16-bit big-endian value from data at offset
--- @param data string|nil The data string
--- @param offset integer 1-based offset of high byte
--- @return integer|nil value The signed 16-bit value or nil
local function parseSignedBigEndian16(data, offset)
  local value = parseBigEndian16(data, offset)
  if not value then
    return nil
  end
  return toSigned16(value)
end

--- Decode probe temperature (divide by 100, return nil if negative/invalid)
--- @param rawValue integer|nil Raw temperature value
--- @return number|nil temperature Temperature in Celsius or nil if invalid
local function decodeProbeTemp(rawValue)
  if not rawValue or rawValue < 0 then
    return nil
  end
  return rawValue / 100
end

--- Create a base result object with required fields
--- @param model GoveeDeviceModel Device model code
--- @return GoveeParsedData|nil result Base result object or nil if model unknown
local function createResult(model)
  local deviceType = Govee.DEVICE_NAMES[model]
  if not deviceType then
    return nil
  end
  return {
    deviceType = deviceType,
    model = model,
  }
end

--- Format bytes as hex string for debug logging
--- @param data string Binary data
--- @return string hex Hex string representation
local function bytesToHex(data)
  local hex = {}
  for i = 1, #data do
    table.insert(hex, string.format("%02X", string.byte(data, i)))
  end
  return table.concat(hex, " ")
end

--------------------------------------------------------------------------------
-- H5106 Air Quality Sensor Helpers
--------------------------------------------------------------------------------

--- Decode temperature from 4-byte combined packet (H5106 air quality sensor)
--- Per govee-ble: packet_value / 1000000 / 10, with sign bit at 0x80000000
--- @param packetValue integer 4-byte value
--- @return number temperature Temperature in Celsius
local function decodeTempFrom4Bytes(packetValue)
  if bit32.band(packetValue, 0x80000000) ~= 0 then
    packetValue = bit32.band(packetValue, 0x7FFFFFFF)
    return -math.floor(packetValue / 10000000) / 10
  end
  return math.floor(packetValue / 1000000) / 10
end

--- Decode humidity from 4-byte combined packet (H5106 air quality sensor)
--- Per govee-ble: (packet_value % 1000000) / 1000 / 10
--- @param packetValue integer 4-byte value
--- @return number humidity Humidity percentage
local function decodeHumidFrom4Bytes(packetValue)
  packetValue = bit32.band(packetValue, 0x7FFFFFFF)
  return math.floor((packetValue % 1000000) / 1000) / 10
end

--- Decode PM2.5 from 4-byte combined packet (H5106 air quality sensor)
--- Per govee-ble: packet_value % 1000
--- @param packetValue integer 4-byte value
--- @return integer pm25 PM2.5 in µg/m³
local function decodePM25From4Bytes(packetValue)
  packetValue = bit32.band(packetValue, 0x7FFFFFFF)
  return packetValue % 1000
end

--------------------------------------------------------------------------------
-- Device-Specific Parsers
--------------------------------------------------------------------------------

--- Parse 3-byte format devices (H5072, H5075, H5101-H5105, H5108, H5110, H5174, H5177, H5178)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @param offset integer 1-based offset for temp/humid data (battery is offset+3)
--- @return GoveeParsedData|nil
local function parse3ByteFormat(data, model, offset)
  if #data < offset + 3 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  result.temperature, result.humidity = parse3ByteTempHumid(data, offset)
  result.battery, result.hasError = parseBattery(data, offset + 3)

  return result
end

--- Parse 4-byte little-endian format devices (H5074, H5051, H5052, H5071, H5179)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @param offset integer 1-based offset for temp/humidity data (battery is offset+4)
--- @return GoveeParsedData|nil
local function parse4ByteLEFormat(data, model, offset)
  if #data < offset + 4 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  result.temperature, result.humidity = parse4ByteTempHumidLE(data, offset)
  result.battery, result.hasError = parseBattery(data, offset + 4)

  return result
end

--- Parse H5106 air quality sensor (4-byte combined temp/humidity/PM2.5)
--- Per govee-ble: 6 bytes, data[2:6] contains 4-byte combined value
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5106(data, model)
  if #data < 6 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- Per govee-ble: data[2:6] as hex string, then parsed as integer
  -- In Lua 1-indexed: bytes 3-6 (4 bytes)
  local b1 = getByte(data, 3)
  local b2 = getByte(data, 4)
  local b3 = getByte(data, 5)
  local b4 = getByte(data, 6)

  if not b1 or not b2 or not b3 or not b4 then
    return nil
  end

  -- Build 4-byte value (big-endian per govee-ble hex string parsing)
  local packetValue = bit32.lshift(b1, 24) + bit32.lshift(b2, 16) + bit32.lshift(b3, 8) + b4

  result.temperature = decodeTempFrom4Bytes(packetValue)
  result.humidity = decodeHumidFrom4Bytes(packetValue)
  result.pm25 = decodePM25From4Bytes(packetValue)

  return result
end

--- Parse H5178 dual-sensor device
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5178(data, model)
  if #data < 9 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- Byte 2 (index 3): Sensor ID (0=primary, 1=remote)
  result.sensorId = getByte(data, 3)

  -- data[3:7] = Lua offset 4 for temp/humid/battery
  result.temperature, result.humidity = parse3ByteTempHumid(data, 4)
  result.battery, result.hasError = parseBattery(data, 7)

  return result
end

--- Parse H5112 dual-probe sensor
--- Per govee-ble: 8 bytes, data[2:6] for temp/humid/battery, data[7] = probe ID
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5112(data, model)
  if #data < 8 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- data[2:6] = Lua offset 3 for temp/humid/battery
  result.temperature, result.humidity = parse3ByteTempHumid(data, 3)
  result.battery, result.hasError = parseBattery(data, 6)

  -- Byte 7 (index 8): Probe ID (0x41=probe 1, 0x82=probe 2)
  local probeIdByte = getByte(data, 8)
  if probeIdByte then
    if probeIdByte == 0x41 then
      result.sensorId = 1
    elseif probeIdByte == 0x82 then
      result.sensorId = 2
    else
      result.sensorId = probeIdByte
    end
  end

  return result
end

--------------------------------------------------------------------------------
-- Meat Thermometer Parsers
--------------------------------------------------------------------------------

--- Parse H5181/H5183 single-probe meat thermometer (14 bytes)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5181(data, model)
  if #data < 14 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- data[8:12] = Lua offset 9, big-endian probe temps
  local probe1Raw = parseSignedBigEndian16(data, 9)
  local alarm1Raw = parseSignedBigEndian16(data, 11)

  result.probe1Temp = decodeProbeTemp(probe1Raw)
  result.probe1Alarm = decodeProbeTemp(alarm1Raw)

  return result
end

--- Parse H5182 dual-probe meat thermometer (17 bytes)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5182(data, model)
  if #data < 17 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- data[8:17] = Lua offset 9
  local probe1Raw = parseSignedBigEndian16(data, 9)
  local alarm1Raw = parseSignedBigEndian16(data, 11)
  local probe2Raw = parseSignedBigEndian16(data, 13)
  local alarm2Raw = parseSignedBigEndian16(data, 15)

  result.probe1Temp = decodeProbeTemp(probe1Raw)
  result.probe1Alarm = decodeProbeTemp(alarm1Raw)
  result.probe2Temp = decodeProbeTemp(probe2Raw)
  result.probe2Alarm = decodeProbeTemp(alarm2Raw)

  return result
end

--- Probe mapping for H5184 (4-probe thermometer)
--- Maps sensor ID (byte 6) to probe number assignment
--- @type table<integer, { [1]: integer, [1]: integer }?>
local H5184_PROBE_MAPPING = {
  [0] = { 1, 2 },
  [1] = { 3, 4 },
}

--- Parse H5184 multi-probe meat thermometer (17 bytes, mapped probes)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5184(data, model)
  if #data < 17 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- Byte 6 (index 7): Sensor ID for probe mapping
  local sensorId = getByte(data, 7)
  local probeMap = sensorId and H5184_PROBE_MAPPING[sensorId]

  -- data[8:17] = Lua offset 9
  local probe1Raw = parseSignedBigEndian16(data, 9)
  local alarm1Raw = parseSignedBigEndian16(data, 11)
  local probe2Raw = parseSignedBigEndian16(data, 13)
  local alarm2Raw = parseSignedBigEndian16(data, 15)

  local temp1 = decodeProbeTemp(probe1Raw)
  local temp2 = decodeProbeTemp(probe2Raw)

  -- Map to correct probe fields based on sensor ID
  if not probeMap or probeMap[1] == 1 then
    result.probe1Temp = temp1
    result.probe1Alarm = decodeProbeTemp(alarm1Raw)
  elseif probeMap[1] == 3 then
    result.probe3Temp = temp1
  end
  if not probeMap or probeMap[2] == 2 then
    result.probe2Temp = temp2
    result.probe2Alarm = decodeProbeTemp(alarm2Raw)
  elseif probeMap[2] == 4 then
    result.probe4Temp = temp2
  end

  return result
end

--- Parse H5185 dual-probe meat thermometer (20 bytes)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5185(data, model)
  if #data < 20 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- data[8:18] = Lua offset 9
  local probe1Raw = parseSignedBigEndian16(data, 9)
  local alarm1Raw = parseSignedBigEndian16(data, 11)
  local probe2Raw = parseSignedBigEndian16(data, 13)
  local alarm2Raw = parseSignedBigEndian16(data, 15)

  result.probe1Temp = decodeProbeTemp(probe1Raw)
  result.probe1Alarm = decodeProbeTemp(alarm1Raw)
  result.probe2Temp = decodeProbeTemp(probe2Raw)
  result.probe2Alarm = decodeProbeTemp(alarm2Raw)

  return result
end

--- Parse H5191 meat thermometer with ambient temp (20 bytes)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5191(data, model)
  if #data < 20 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- data[8:16] = Lua offset 9
  local probe1Raw = parseSignedBigEndian16(data, 9)
  local alarm1Raw = parseSignedBigEndian16(data, 11)
  local ambientRaw = parseSignedBigEndian16(data, 13)

  result.probe1Temp = decodeProbeTemp(probe1Raw)
  result.probe1Alarm = decodeProbeTemp(alarm1Raw)
  result.ambientTemp = decodeProbeTemp(ambientRaw)

  return result
end

--- Probe mapping for H5198 (multi-probe with high/low alarms)
--- @type table<integer, { [1]: integer, [1]: integer }?>
local H5198_PROBE_MAPPING = {
  [0] = { 1, 2 },
  [1] = { 3, 4 },
}

--- Parse H5198 multi-probe meat thermometer (20 bytes)
--- @param data string Manufacturer data
--- @param model GoveeDeviceModel Device model
--- @return GoveeParsedData|nil
local function parseH5198(data, model)
  if #data < 20 then
    return nil
  end

  local result = createResult(model)
  if not result then
    return nil
  end

  -- Byte 6 (index 7): Sensor ID for probe mapping
  local sensorId = getByte(data, 7)
  local probeMap = sensorId and H5198_PROBE_MAPPING[sensorId]

  -- data[8:20] = Lua offset 9
  local probe1Raw = parseSignedBigEndian16(data, 9)
  local probe2Raw = parseSignedBigEndian16(data, 11)

  local temp1 = decodeProbeTemp(probe1Raw)
  local temp2 = decodeProbeTemp(probe2Raw)

  -- Map to correct probe fields based on sensor ID
  if not probeMap or probeMap[1] == 1 then
    result.probe1Temp = temp1
  elseif probeMap[1] == 3 then
    result.probe3Temp = temp1
  end
  if not probeMap or probeMap[2] == 2 then
    result.probe2Temp = temp2
  elseif probeMap[2] == 4 then
    result.probe4Temp = temp2
  end

  return result
end

--------------------------------------------------------------------------------
-- Model Name Matching
--------------------------------------------------------------------------------

--- Extract model from device name using substring matching.
--- Per govee-ble: uses "H5074" in local_name style checks.
--- @param name string|nil Device name
--- @return GoveeDeviceModel|nil model
local function getModelFromName(name)
  if not name then
    return nil
  end

  -- Check for each known model in the name (per govee-ble substring matching)
  -- Order matters: check more specific models first (longer numbers before shorter)
  -- Meat thermometers
  if name:find("H5181") then
    return Govee.DeviceModel.H5181
  elseif name:find("H5182") then
    return Govee.DeviceModel.H5182
  elseif name:find("H5183") then
    return Govee.DeviceModel.H5183
  elseif name:find("H5184") then
    return Govee.DeviceModel.H5184
  elseif name:find("H5185") then
    return Govee.DeviceModel.H5185
  elseif name:find("H5191") then
    return Govee.DeviceModel.H5191
  elseif name:find("H5198") then
    return Govee.DeviceModel.H5198
  elseif name:find("H5055") then
    return Govee.DeviceModel.H5055
  -- Temperature/Humidity sensors (check longer model numbers first)
  elseif name:find("H5174") then
    return Govee.DeviceModel.H5174
  elseif name:find("H5177") then
    return Govee.DeviceModel.H5177
  elseif name:find("H5178") or name:find("B5178") then
    return Govee.DeviceModel.H5178
  elseif name:find("H5179") or name:find("GV5179") then
    return Govee.DeviceModel.H5179
  elseif name:find("H5112") then
    return Govee.DeviceModel.H5112
  elseif name:find("H5110") then
    return Govee.DeviceModel.H5110
  elseif name:find("H5108") then
    return Govee.DeviceModel.H5108
  elseif name:find("H5106") then
    return Govee.DeviceModel.H5106
  elseif name:find("H5105") then
    return Govee.DeviceModel.H5105
  elseif name:find("H5104") then
    return Govee.DeviceModel.H5104
  elseif name:find("H5103") then
    return Govee.DeviceModel.H5103
  elseif name:find("H5102") then
    return Govee.DeviceModel.H5102
  elseif name:find("H5101") then
    return Govee.DeviceModel.H5101
  elseif name:find("H5100") then
    return Govee.DeviceModel.H5100
  elseif name:find("H5074") then
    return Govee.DeviceModel.H5074
  elseif name:find("H5075") then
    return Govee.DeviceModel.H5075
  elseif name:find("H5072") then
    return Govee.DeviceModel.H5072
  elseif name:find("H5071") then
    return Govee.DeviceModel.H5071
  elseif name:find("H5052") then
    return Govee.DeviceModel.H5052
  elseif name:find("H5051") then
    return Govee.DeviceModel.H5051
  end

  return nil
end

--------------------------------------------------------------------------------
-- Manufacturer ID Helpers
--------------------------------------------------------------------------------

--- H5181 manufacturer IDs
--- @type table<GoveeManufacturerId, boolean?>
local H5181_MFG_IDS = {
  [Govee.ManufacturerId.H5181_F861] = true,
  [Govee.ManufacturerId.H5181_388A] = true,
  [Govee.ManufacturerId.H5181_EA42] = true,
  [Govee.ManufacturerId.H5181_AAA2] = true,
  [Govee.ManufacturerId.H5181_D14B] = true,
}

--- H5183 manufacturer IDs
--- @type table<GoveeManufacturerId, boolean?>
local H5183_MFG_IDS = {
  [Govee.ManufacturerId.H5183_67DD] = true,
  [Govee.ManufacturerId.H5183_E02F] = true,
  [Govee.ManufacturerId.H5183_F79F] = true,
}

--- H5185 manufacturer IDs
--- @type table<GoveeManufacturerId, boolean?>
local H5185_MFG_IDS = {
  [Govee.ManufacturerId.H5185_4A32] = true,
  [Govee.ManufacturerId.H5185_0332] = true,
  [Govee.ManufacturerId.H5185_4C32] = true,
}

--- Check if manufacturer ID is a known Govee ID
--- @param manufacturerId integer Manufacturer company ID
--- @return boolean isGovee True if Govee manufacturer ID
local function isGoveeManufacturer(manufacturerId)
  return manufacturerId == Govee.ManufacturerId.EC88
    or manufacturerId == Govee.ManufacturerId.ID_0001
    or manufacturerId == Govee.ManufacturerId.ID_8801
    or manufacturerId == Govee.ManufacturerId.ID_8803
    or H5181_MFG_IDS[manufacturerId]
    or H5183_MFG_IDS[manufacturerId]
    or H5185_MFG_IDS[manufacturerId]
    or manufacturerId == Govee.ManufacturerId.H5182
    or manufacturerId == Govee.ManufacturerId.H5184
    or manufacturerId == Govee.ManufacturerId.H5191
    or manufacturerId == Govee.ManufacturerId.H5198
end

--- Find Govee manufacturer data
--- @param manufacturerData BLEManufacturerData[]|nil Manufacturer data entries
--- @return string|nil data The raw manufacturer data
--- @return number|nil companyId The manufacturer company ID
local function findGoveeManufacturerData(manufacturerData)
  if not manufacturerData then
    return nil, nil
  end
  for _, mfg in ipairs(manufacturerData) do
    if isGoveeManufacturer(mfg.company) then
      return mfg.data, mfg.company
    end
  end
  return nil, nil
end

--- Govee service UUIDs (16-bit)
--- Some Govee devices broadcast sensor data via service UUID instead of manufacturer data
--- @type string
local SERVICE_UUID_EC88 = "EC88" -- H5072, H5075, H5074, etc.

--------------------------------------------------------------------------------
-- Main Parser
--------------------------------------------------------------------------------

--- Parse Govee data from manufacturer data
--- Infer device model from manufacturer ID when name doesn't provide it
--- Some devices (like H5179 with 0x8801) can be identified by manufacturer ID alone
--- @param companyId number Manufacturer company ID
--- @param dataLen number Length of manufacturer data
--- @return GoveeDeviceModel|nil model Inferred model or nil
local function inferModelFromManufacturerId(companyId, dataLen)
  -- H5179: manufacturer ID 0x8801 with 9 bytes is uniquely H5179
  -- Per govee-ble: "H5179" in local_name OR mgr_id == 0x8801
  if companyId == Govee.ManufacturerId.ID_8801 and dataLen == 9 then
    return Govee.DeviceModel.H5179
  end
  return nil
end

--- @param manufacturerData BLEManufacturerData[]|nil Manufacturer data array
--- @param serviceData BLEServiceData[]|nil Service data array
--- @param deviceName string|nil Device name from advertisement
--- @return GoveeParsedData|nil parsed Parsed data or nil if not Govee
function Govee.parse(manufacturerData, serviceData, deviceName)
  local mfgData, companyId = findGoveeManufacturerData(manufacturerData)

  -- If no manufacturer data, try service data with UUID EC88
  -- Some Govee devices broadcast via service UUID instead of manufacturer ID
  if not mfgData then
    local svcData = UUID.findData(serviceData, SERVICE_UUID_EC88)
    if svcData then
      mfgData = svcData
      companyId = Govee.ManufacturerId.EC88
      log:trace("Govee: found service data with UUID %s for device %q", SERVICE_UUID_EC88, deviceName or "")
    end
  end

  if not mfgData then
    return nil
  end

  local dataLen = #mfgData

  -- Try to determine model from device name first
  local model = getModelFromName(deviceName)

  -- Fallback: infer model from manufacturer ID if name doesn't provide it
  -- Some devices (like H5179) can be identified by manufacturer ID alone
  if not model or Govee.DEVICE_NAMES[model] == nil then
    model = companyId and inferModelFromManufacturerId(companyId, dataLen)
    if model then
      log:debug("Govee: inferred model %s from manufacturer ID 0x%04X", model, companyId)
    end
  end

  if not model or Govee.DEVICE_NAMES[model] == nil then
    log:trace(
      "Govee: could not determine model for device %q with companyId=0x%04X, dataLen=%d",
      deviceName or "",
      companyId,
      dataLen
    )
    return nil
  end

  log:debug(
    "Govee parse: companyId=0x%04X, len=%d, model=%s, data=[%s]",
    companyId,
    dataLen,
    model,
    bytesToHex(mfgData)
  )

  -- Route to appropriate parser based on manufacturer ID and data length

  -- EC88 manufacturer ID (0xEC88)
  if companyId == Govee.ManufacturerId.EC88 then
    -- H5072/H5075: 6 bytes, data[1:5] = Lua offset 2 (3-byte format)
    if dataLen == 6 and (model == Govee.DeviceModel.H5072 or model == Govee.DeviceModel.H5075) then
      return parse3ByteFormat(mfgData, model, 2)
    -- H5074: 7 bytes, data[1:6] = Lua offset 2 (4-byte LE format)
    elseif dataLen == 7 and model == Govee.DeviceModel.H5074 then
      return parse4ByteLEFormat(mfgData, model, 2)
    -- H5051/H5052/H5071: 9 bytes, data[1:6] = Lua offset 2 (4-byte LE format)
    elseif
      dataLen == 9
      and (model == Govee.DeviceModel.H5051 or model == Govee.DeviceModel.H5052 or model == Govee.DeviceModel.H5071)
    then
      return parse4ByteLEFormat(mfgData, model, 2)
    end

    log:debug("Govee EC88: model %s with len=%d not supported", model, dataLen)
    return nil
  end

  -- 0x0001 manufacturer ID
  if companyId == Govee.ManufacturerId.ID_0001 then
    -- H5106: 6 bytes, data[2:6] = 4-byte combined temp/humidity/PM2.5
    if dataLen == 6 and model == Govee.DeviceModel.H5106 then
      return parseH5106(mfgData, model)
    -- H5100/H5101/H5102/H5103/H5104/H5105/H5108/H5110/H5174/H5177/H5179: 6 or 8 bytes, data[2:6] = Lua offset 3
    -- Note: H5179 can use either 0x0001 (6 bytes, 3-byte format) or 0x8801 (9 bytes, 4-byte LE format)
    elseif
      (dataLen == 6 or dataLen == 8)
      and (
        model == Govee.DeviceModel.H5100
        or model == Govee.DeviceModel.H5101
        or model == Govee.DeviceModel.H5102
        or model == Govee.DeviceModel.H5103
        or model == Govee.DeviceModel.H5104
        or model == Govee.DeviceModel.H5105
        or model == Govee.DeviceModel.H5108
        or model == Govee.DeviceModel.H5110
        or model == Govee.DeviceModel.H5174
        or model == Govee.DeviceModel.H5177
        or model == Govee.DeviceModel.H5179
      )
    then
      return parse3ByteFormat(mfgData, model, 3)
    -- H5112: 8 bytes, dual probe
    elseif dataLen == 8 and model == Govee.DeviceModel.H5112 then
      return parseH5112(mfgData, model)
    -- H5178: 9 bytes, data[3:7] = Lua offset 4
    elseif dataLen == 9 and model == Govee.DeviceModel.H5178 then
      return parseH5178(mfgData, model)
    end

    log:debug("Govee 0001: model %s with len=%d not supported", model, dataLen)
    return nil
  end

  -- 0x8801 manufacturer ID
  if companyId == Govee.ManufacturerId.ID_8801 then
    -- H5179: 9 bytes, data[4:9] = Lua offset 5 (4-byte LE format)
    if dataLen == 9 and model == Govee.DeviceModel.H5179 then
      return parse4ByteLEFormat(mfgData, model, 5)
    end

    log:debug("Govee 8801: model %s with len=%d not supported", model, dataLen)
    return nil
  end

  -- Meat thermometer manufacturer IDs
  if H5181_MFG_IDS[companyId] then
    if dataLen == 14 and model == Govee.DeviceModel.H5181 then
      return parseH5181(mfgData, model)
    end
    log:debug("Govee H5181: len=%d not supported", dataLen)
    return nil
  end

  if companyId == Govee.ManufacturerId.H5182 then
    if dataLen == 17 and model == Govee.DeviceModel.H5182 then
      return parseH5182(mfgData, model)
    end
    log:debug("Govee H5182: len=%d not supported", dataLen)
    return nil
  end

  if H5183_MFG_IDS[companyId] then
    if dataLen == 14 and model == Govee.DeviceModel.H5183 then
      return parseH5181(mfgData, model) -- Same format as H5181
    end
    log:debug("Govee H5183: len=%d not supported", dataLen)
    return nil
  end

  if companyId == Govee.ManufacturerId.H5184 then
    if dataLen == 17 and model == Govee.DeviceModel.H5184 then
      return parseH5184(mfgData, model)
    end
    log:debug("Govee H5184: len=%d not supported", dataLen)
    return nil
  end

  if H5185_MFG_IDS[companyId] then
    if dataLen == 20 and model == Govee.DeviceModel.H5185 then
      return parseH5185(mfgData, model)
    end
    log:debug("Govee H5185: len=%d not supported", dataLen)
    return nil
  end

  if companyId == Govee.ManufacturerId.H5191 then
    if dataLen == 20 and model == Govee.DeviceModel.H5191 then
      return parseH5191(mfgData, model)
    end
    log:debug("Govee H5191: len=%d not supported", dataLen)
    return nil
  end

  if companyId == Govee.ManufacturerId.H5198 then
    if dataLen == 20 and model == Govee.DeviceModel.H5198 then
      return parseH5198(mfgData, model)
    end
    log:debug("Govee H5198: len=%d not supported", dataLen)
    return nil
  end

  log:debug("Govee: unknown companyId=0x%04X", companyId)
  return nil
end

return Govee
