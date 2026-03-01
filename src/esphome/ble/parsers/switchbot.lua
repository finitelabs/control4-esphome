--- SwitchBot advertisement parser.
--- Parses SwitchBot service data (UUID FD3D) and manufacturer data.
--- Sources:
---  - https://github.com/OpenWonderLabs/SwitchBotAPI-BLE
---  - https://github.com/Danielhiversen/pySwitchbot

local bit32 = require("bitn").bit32
local log = require("lib.logging")
local UUID = require("esphome.ble.uuid")

--- @class SwitchBot
local SwitchBot = {}

--- SwitchBot service UUID (16-bit)
SwitchBot.SERVICE_UUID = "FD3D"

--- SwitchBot manufacturer company ID (Woan Technology)
SwitchBot.MANUFACTURER_ID = 0x0969

--- SwitchBot device type codes (from FD3D service data byte 0, bits 6:0)
--- @enum SwitchBotDeviceTypeCode
SwitchBot.DeviceTypeCode = {
  BOT = 0x48, -- 'H'
  METER = 0x54, -- 'T'
  METER_PLUS = 0x69, -- 'i'
  METER_PRO = 0x34, -- '4'
  METER_PRO_CO2 = 0x35, -- '5'
  INDOOR_OUTDOOR_METER = 0x77, -- 'w'
  CONTACT = 0x64, -- 'd'
  MOTION = 0x73, -- 's'
  PRESENCE = 0x10, -- Presence Sensor (detected via 4-byte prefix in mfr data)
  PLUG_MINI = 0x67, -- 'g'
  RELAY_1 = 0x3B, -- ';'
  RELAY_1PM = 0x3C, -- '<'
  RELAY_2PM = 0x3D, -- '='
  REMOTE = 0x62, -- 'b'
  WATER_LEAK = 0x26, -- '&'
  HUMIDIFIER = 0x65, -- 'e'
  CURTAIN = 0x63, -- 'c'
  CURTAIN_3 = 0x7B, -- '{'
  BULB = 0x75, -- 'u'
  LED_STRIP = 0x72, -- 'r'
  LOCK = 0x6F, -- 'o'
}

--- Device type code to name mapping
--- @type table<SwitchBotDeviceTypeCode, string?>
SwitchBot.DEVICE_NAMES = {
  [SwitchBot.DeviceTypeCode.BOT] = "SwitchBot Bot",
  [SwitchBot.DeviceTypeCode.METER] = "SwitchBot Meter",
  [SwitchBot.DeviceTypeCode.METER_PLUS] = "SwitchBot Meter Plus",
  [SwitchBot.DeviceTypeCode.METER_PRO] = "SwitchBot Meter Pro",
  [SwitchBot.DeviceTypeCode.METER_PRO_CO2] = "SwitchBot Meter Pro CO2",
  [SwitchBot.DeviceTypeCode.INDOOR_OUTDOOR_METER] = "SwitchBot Indoor/Outdoor Meter",
  [SwitchBot.DeviceTypeCode.CONTACT] = "SwitchBot Contact",
  [SwitchBot.DeviceTypeCode.MOTION] = "SwitchBot Motion",
  [SwitchBot.DeviceTypeCode.PRESENCE] = "SwitchBot Presence",
  [SwitchBot.DeviceTypeCode.PLUG_MINI] = "SwitchBot Plug Mini",
  [SwitchBot.DeviceTypeCode.RELAY_1] = "SwitchBot Relay Switch 1",
  [SwitchBot.DeviceTypeCode.RELAY_1PM] = "SwitchBot Relay Switch 1PM",
  [SwitchBot.DeviceTypeCode.RELAY_2PM] = "SwitchBot Relay Switch 2PM",
  [SwitchBot.DeviceTypeCode.REMOTE] = "SwitchBot Remote",
  [SwitchBot.DeviceTypeCode.WATER_LEAK] = "SwitchBot Water Leak Detector",
  [SwitchBot.DeviceTypeCode.HUMIDIFIER] = "SwitchBot Humidifier",
  [SwitchBot.DeviceTypeCode.CURTAIN] = "SwitchBot Curtain",
  [SwitchBot.DeviceTypeCode.CURTAIN_3] = "SwitchBot Curtain 3",
  [SwitchBot.DeviceTypeCode.BULB] = "SwitchBot Bulb",
  [SwitchBot.DeviceTypeCode.LED_STRIP] = "SwitchBot LED Strip",
  [SwitchBot.DeviceTypeCode.LOCK] = "SwitchBot Lock",
}

--- GATT command bytes for controllable devices
--- Commands are prefixed with 0x57 header
SwitchBot.Commands = {
  -- Plug Mini commands (prefix 0x50)
  PLUG_ON = "\x57\x0F\x50\x01\x01\x80",
  PLUG_OFF = "\x57\x0F\x50\x01\x01\x00",
  -- Relay Switch commands (prefix 0x70)
  RELAY_ON = "\x57\x0F\x70\x01\x01\x00",
  RELAY_OFF = "\x57\x0F\x70\x01\x00\x00",
  -- Relay 2PM dual channel commands
  RELAY_2PM_CH1_ON = "\x57\x0F\x70\x01\x0D\x00",
  RELAY_2PM_CH1_OFF = "\x57\x0F\x70\x01\x0C\x00",
  RELAY_2PM_CH2_ON = "\x57\x0F\x70\x01\x07\x00",
  RELAY_2PM_CH2_OFF = "\x57\x0F\x70\x01\x03\x00",
  -- Toggle command
  RELAY_TOGGLE = "\x57\x0F\x70\x01\x02\x00",
}

--- @class SwitchBotParsedData
--- @field deviceCode integer Raw device type byte
--- @field deviceType string Device type name
--- @field battery integer|nil Battery percentage (0-100)
--- @field temperature number|nil Temperature in Celsius
--- @field humidity integer|nil Humidity percentage
--- @field co2 integer|nil CO2 ppm (Meter Pro CO2 only)
--- @field isOn boolean|nil Power state for switches/plugs
--- @field isSwitchMode boolean|nil Bot switch mode (true = switch, false = press)
--- @field motionDetected boolean|nil Motion sensor state
--- @field isLight boolean|nil Light detected
--- @field lightLevel integer|nil Light level (0-3 or 0-31 for presence)
--- @field contactOpen boolean|nil Contact sensor open state
--- @field contactTimeout boolean|nil Contact timeout state
--- @field contactButtonCount integer|nil Contact sensor button press count (0-15, wraps)
--- @field leakDetected boolean|nil Water leak detected
--- @field tampered boolean|nil Tamper state
--- @field lowBattery boolean|nil Low battery warning flag
--- @field power number|nil Power in watts
--- @field channel1On boolean|nil Relay channel 1 state
--- @field channel2On boolean|nil Relay channel 2 state (2PM only)
--- @field channel1Power number|nil Channel 1 power in watts
--- @field channel2Power number|nil Channel 2 power in watts
--- @field duration integer|nil Presence sensor motion duration in seconds

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

--- Create a base result object with required fields
--- @param deviceCode SwitchBotDeviceTypeCode Device type code
--- @return SwitchBotParsedData|nil result Base result object or nil if model unknown
local function createResult(deviceCode)
  local deviceType = SwitchBot.DEVICE_NAMES[deviceCode]
  if not deviceType then
    return nil
  end
  return {
    deviceCode = deviceCode,
    deviceType = deviceType,
  }
end

--- Parse battery from a byte (bits 6:0 = percentage, bit 7 = low battery flag)
--- @param data string|nil The data string
--- @param index integer 1-based index of battery byte
--- @return integer|nil battery Battery percentage (0-127) or nil
--- @return boolean|nil lowBattery Low battery warning flag or nil (only used by Water Leak Detector)
local function parseBattery(data, index)
  local batteryByte = getByte(data, index)
  if not batteryByte then
    return nil, nil
  end
  local battery = bit32.band(batteryByte, 0x7F)
  -- Not all devices actually report this bit for low battery
  local lowBattery = bit32.band(batteryByte, 0x80) ~= 0
  return battery, lowBattery
end

--- Parse temperature and humidity from SwitchBot format
--- Bytes are always consecutive: [decimal, integer/sign, humidity]
--- Temperature: decimal byte (bits 3:0) + integer byte (bit 7=sign, bits 6:0=integer)
--- Humidity: bits 6:0
--- @param data string|nil The data string
--- @param offset integer 1-based index of temperature decimal byte (int is offset+1, humidity is offset+2)
--- @return number|nil temperature Temperature in Celsius
--- @return integer|nil humidity Humidity percentage
local function parseTempHumidity(data, offset)
  local tempDecByte = getByte(data, offset)
  local tempIntByte = getByte(data, offset + 1)
  local humidityByte = getByte(data, offset + 2)

  local temperature = nil
  if tempDecByte and tempIntByte then
    local tempSign = bit32.band(tempIntByte, 0x80) ~= 0 and 1 or -1
    local tempInt = bit32.band(tempIntByte, 0x7F)
    local tempDec = bit32.band(tempDecByte, 0x0F) / 10
    temperature = tempSign * (tempInt + tempDec)
  end

  local humidity = nil
  if humidityByte then
    humidity = bit32.band(humidityByte, 0x7F)
  end

  return temperature, humidity
end

--- Parse a 16-bit big-endian value from two bytes
--- @param data string|nil The data string
--- @param offset integer 1-based offset for high byte (low byte is offset+1)
--- @return integer|nil value The 16-bit value or nil
local function parseBigEndian16(data, offset)
  local high = getByte(data, offset)
  local low = getByte(data, offset + 1)
  if not high or not low then
    return nil
  end
  return high * 256 + low
end

--- Parse power data from two bytes (little-endian, scaled by 0.1)
--- @param data string|nil The data string
--- @param offset integer 1-based offset for first byte
--- @return number|nil power Power in watts
local function parsePower(data, offset)
  local low = getByte(data, offset)
  local high = getByte(data, offset + 1)
  if not low or not high then
    return nil
  end
  local raw = low + high * 256
  -- Check for invalid readings (0x7FFF typically means no data)
  if raw >= 0x7FFF then
    return nil
  end
  return raw / 10.0
end

--- Parse meter data for regular Meter and Meter Plus (service data bytes 3-5, 0-based)
--- @param serviceData string|nil Raw FD3D service data
--- @param deviceCode SwitchBotDeviceTypeCode Device type code
--- @return SwitchBotParsedData|nil
local function parseMeterBasic(serviceData, deviceCode)
  if not serviceData or #serviceData < 6 then
    return nil
  end

  local result = createResult(deviceCode)
  if not result then
    return nil
  end
  result.battery = parseBattery(serviceData, 3)
  result.temperature, result.humidity = parseTempHumidity(serviceData, 4)

  return result
end

--- Parse Bot data from service data
--- Per pySwitchbot: data[1] bit 7 = switch mode, bit 6 = isOn (inverted)
--- data[2] bits 6:0 = battery
--- @param serviceData string|nil Raw FD3D service data
--- @return SwitchBotParsedData|nil
local function parseBot(serviceData)
  if not serviceData or #serviceData < 3 then
    return nil
  end

  local result = createResult(SwitchBot.DeviceTypeCode.BOT)
  if not result then
    return nil
  end

  -- Byte 1 (index 2): Mode and state flags
  -- bit 7 = switch mode (1 = switch, 0 = press)
  -- bit 6 = isOn state (inverted: 0 = on, 1 = off) - only valid in switch mode
  local modeByte = getByte(serviceData, 2)
  if modeByte then
    local isSwitchMode = bit32.band(modeByte, 0x80) ~= 0
    result.isSwitchMode = isSwitchMode
    if isSwitchMode then
      -- isOn is inverted: bit clear = on
      result.isOn = bit32.band(modeByte, 0x40) == 0
    end
  end

  result.battery = parseBattery(serviceData, 3)

  return result
end

--- Parse meter data for Meter Pro and Meter Pro CO2
--- Meter Pro uses manufacturer data for temp/humidity (service data is short)
--- Per pySwitchbot: mfr_data[8:11] for temp/humidity (bytes 8, 9, 10 in Python = indices 9, 10, 11 in Lua)
--- @param manufacturerData string|nil Raw manufacturer data with temp/humidity
--- @param serviceData string|nil Raw FD3D service data (may be short, only has device type)
--- @return SwitchBotParsedData|nil
local function parseMeterPro(manufacturerData, serviceData)
  local deviceCode = SwitchBot.DeviceTypeCode.METER_PRO
  if not manufacturerData or #manufacturerData < 11 then
    -- Fallback: use service data format (same as regular meters)
    return parseMeterBasic(serviceData, deviceCode)
  end

  local result = createResult(deviceCode)
  if not result then
    return nil
  end

  -- Meter Pro uses manufacturer data for temp/humidity (offset 9 = byte 8 in 0-indexed)
  result.temperature, result.humidity = parseTempHumidity(manufacturerData, 9)

  -- Try to get battery from service data byte 2 (if available)
  result.battery = parseBattery(serviceData, 3)

  return result
end

--- Parse Meter Pro CO2 data including CO2 reading
--- @param manufacturerData string|nil Raw manufacturer data
--- @param serviceData string|nil Raw FD3D service data
--- @return SwitchBotParsedData|nil
local function parseMeterProCO2Full(manufacturerData, serviceData)
  local result = parseMeterPro(manufacturerData, serviceData)
  if not result then
    return nil
  end

  local deviceCode = SwitchBot.DeviceTypeCode.METER_PRO_CO2
  result.deviceType = SwitchBot.DEVICE_NAMES[deviceCode]
  result.deviceCode = deviceCode

  -- CO2: Try manufacturer data first (bytes 13-14, 0-indexed = index 14-15)
  if manufacturerData and #manufacturerData >= 15 then
    result.co2 = parseBigEndian16(manufacturerData, 14)
  elseif serviceData and #serviceData >= 15 then
    result.co2 = parseBigEndian16(serviceData, 14)
  end

  return result
end

--- Parse motion sensor data
--- @param serviceData string|nil Raw FD3D service data
--- @return SwitchBotParsedData|nil
local function parseMotion(serviceData)
  if not serviceData or #serviceData < 6 then
    return nil
  end

  local result = createResult(SwitchBot.DeviceTypeCode.MOTION)
  if not result then
    return nil
  end

  -- Byte 1 (index 2): Status flags - bit 6 = motion detected
  local statusByte = getByte(serviceData, 2)
  if statusByte then
    result.motionDetected = bit32.band(statusByte, 0x40) ~= 0
  end

  result.battery = parseBattery(serviceData, 3)

  -- Byte 5 (index 6): Light info - bits 0-1 = light level (0-3), bit 1 = is light detected
  local lightByte = getByte(serviceData, 6)
  if lightByte then
    result.lightLevel = bit32.band(lightByte, 0x03)
    result.isLight = bit32.band(lightByte, 0x02) ~= 0
  end

  return result
end

--- Parse contact sensor data
--- @param manufacturerData string|nil Raw manufacturer data
--- @param serviceData string|nil Raw FD3D service data
--- @return SwitchBotParsedData|nil
local function parseContact(manufacturerData, serviceData)
  if not serviceData or #serviceData < 4 then
    return nil
  end

  local result = createResult(SwitchBot.DeviceTypeCode.CONTACT)
  if not result then
    return nil
  end

  -- Byte 1 (index 2): Status flags - bit 6 = motion detected
  local statusByte = getByte(serviceData, 2)
  if statusByte then
    result.motionDetected = bit32.band(statusByte, 0x40) ~= 0
  end

  result.battery = parseBattery(serviceData, 3)

  -- Byte 3 (index 4): Contact state - bit 0 = light, bit 1 = contact open, bit 2 = contact timeout
  local contactByte = getByte(serviceData, 4)
  if contactByte then
    result.isLight = bit32.band(contactByte, 0x01) ~= 0
    result.contactOpen = bit32.band(contactByte, 0x02) ~= 0
    result.contactTimeout = bit32.band(contactByte, 0x04) ~= 0
  end

  -- Button count: mfr_data[12] & 0x0F (Lua index 13) or service data[8] & 0x0F (Lua index 9)
  local buttonByte = getByte(manufacturerData, 13) or getByte(serviceData, 9)
  if buttonByte then
    result.contactButtonCount = bit32.band(buttonByte, 0x0F)
  end

  return result
end

--- Parse water leak detector data from manufacturer data
--- @param manufacturerData string|nil Raw manufacturer data
--- @return SwitchBotParsedData|nil
local function parseWaterLeak(manufacturerData)
  if not manufacturerData or #manufacturerData < 9 then
    return nil
  end

  local result = createResult(SwitchBot.DeviceTypeCode.WATER_LEAK)
  if not result then
    return nil
  end
  result.battery, result.lowBattery = parseBattery(manufacturerData, 8)

  -- Byte 8 (index 9): Status - bit 0 = leak detected, bit 1 = tampered
  local statusByte = getByte(manufacturerData, 9)
  if statusByte then
    result.leakDetected = bit32.band(statusByte, 0x01) ~= 0
    result.tampered = bit32.band(statusByte, 0x02) ~= 0
  end

  return result
end

--- Parse Plug Mini data from manufacturer data
--- @param manufacturerData string|nil Raw manufacturer data
--- @return SwitchBotParsedData|nil
local function parsePlugMini(manufacturerData)
  if not manufacturerData or #manufacturerData < 11 then
    return nil
  end

  local result = createResult(SwitchBot.DeviceTypeCode.PLUG_MINI)
  if not result then
    return nil
  end
  -- Byte 7 (index 8): Power state (0x80 = on, otherwise off)
  local stateByte = getByte(manufacturerData, 8)
  if stateByte then
    result.isOn = stateByte == 0x80
  end

  result.power = parsePower(manufacturerData, 11)

  return result
end

--- Parse Relay Switch data from manufacturer data
--- @param manufacturerData string|nil Raw manufacturer data
--- @param deviceCode SwitchBotDeviceTypeCode Device type code (RELAY_1, RELAY_1PM, or RELAY_2PM)
--- @return SwitchBotParsedData|nil
local function parseRelaySwitch(manufacturerData, deviceCode)
  if not manufacturerData or #manufacturerData < 8 then
    return nil
  end

  local is2PM = deviceCode == SwitchBot.DeviceTypeCode.RELAY_2PM
  local is1PM = deviceCode == SwitchBot.DeviceTypeCode.RELAY_1PM

  local result = createResult(deviceCode)
  if not result then
    return nil
  end

  -- Byte 7 (index 8): Channel states - bit 7 = ch1 on, bit 6 = ch2 on (2PM only)
  local stateByte = getByte(manufacturerData, 8)
  if stateByte then
    result.channel1On = bit32.band(stateByte, 0x80) ~= 0
    result.isOn = result.channel1On -- Alias for single-channel compatibility
    if is2PM then
      result.channel2On = bit32.band(stateByte, 0x40) ~= 0
    end
  end

  -- Power monitoring (1PM and 2PM only)
  if is1PM or is2PM then
    result.channel1Power = parsePower(manufacturerData, 11)
    result.power = result.channel1Power -- Alias for single-channel compatibility
    if is2PM then
      result.channel2Power = parsePower(manufacturerData, 13)
    end
  end

  return result
end

--- Parse remote data
--- @param serviceData string|nil Raw FD3D service data
--- @return SwitchBotParsedData|nil
local function parseRemote(serviceData)
  if not serviceData or #serviceData < 3 then
    return nil
  end

  local result = createResult(SwitchBot.DeviceTypeCode.REMOTE)
  if not result then
    return nil
  end
  result.battery = parseBattery(serviceData, 3)

  -- Note: Button events are NOT currently detectable via passive advertisement

  return result
end

--- Parse Outdoor Meter (Indoor/Outdoor Thermo-Hygrometer) data
--- @param manufacturerData string|nil Raw manufacturer data
--- @param serviceData string|nil Raw FD3D service data
--- @return SwitchBotParsedData|nil
local function parseOutdoorMeter(manufacturerData, serviceData)
  local deviceCode = SwitchBot.DeviceTypeCode.INDOOR_OUTDOOR_METER

  -- Need either manufacturer data (>=12 bytes) or service data (>=6 bytes)
  if not manufacturerData or #manufacturerData < 12 then
    -- Fallback to service data format (same as regular meters)
    return parseMeterBasic(serviceData, deviceCode)
  end

  local result = createResult(deviceCode)
  if not result then
    return nil
  end
  result.battery = parseBattery(serviceData, 3)
  result.temperature, result.humidity = parseTempHumidity(manufacturerData, 9)

  return result
end

--- Battery level lookup for Presence Sensor (2-bit value to percentage)
--- @type table<integer, integer?>
local PRESENCE_BATTERY_LEVELS = {
  [0] = 100,
  [1] = 80,
  [2] = 60,
  [3] = 40,
}

--- Parse Presence Sensor data from manufacturer data
--- @param manufacturerData string|nil Raw manufacturer data
--- @param serviceData string|nil Raw FD3D service data (optional, for battery)
--- @return SwitchBotParsedData|nil
local function parsePresenceSensor(manufacturerData, serviceData)
  if not manufacturerData or #manufacturerData < 12 then
    return nil
  end

  local result = createResult(SwitchBot.DeviceTypeCode.PRESENCE)
  if not result then
    return nil
  end

  -- Byte 7 (index 8): Packed flags - bit 6 = motion, bits 4-3 = battery level
  local flagsByte = getByte(manufacturerData, 8)
  if flagsByte then
    result.motionDetected = bit32.band(flagsByte, 0x40) ~= 0
    local batteryBits = bit32.band(bit32.rshift(flagsByte, 3), 0x03)
    result.battery = PRESENCE_BATTERY_LEVELS[batteryBits] or 50
  end

  -- Bytes 8-9 (index 9-10): Duration (16-bit big-endian)
  result.duration = parseBigEndian16(manufacturerData, 9)

  -- Byte 11 (index 12): Light level (bits 0-4)
  local lightByte = getByte(manufacturerData, 12)
  if lightByte then
    result.lightLevel = bit32.band(lightByte, 0x1F)
    result.isLight = result.lightLevel > 0
  end

  -- Try to get more accurate battery from service data if available
  local serviceBattery = parseBattery(serviceData, 3)
  if serviceBattery then
    result.battery = serviceBattery
  end

  return result
end

--- Find SwitchBot manufacturer data
--- @param manufacturerData BLEManufacturerData[]|nil Manufacturer data entries
--- @return string|nil data The raw manufacturer data or nil
local function findManufacturerData(manufacturerData)
  if not manufacturerData then
    return nil
  end
  for _, mfg in ipairs(manufacturerData) do
    if mfg.company == SwitchBot.MANUFACTURER_ID then
      return mfg.data
    end
  end
  return nil
end

--- Check if service data matches Presence Sensor signature
--- Per pySwitchbot: check last 4 bytes of service data for signature
--- Presence Sensor signature: (0x00 or 0x01) 0x10 0xCC 0xC8
--- @param fd3dData string|nil FD3D service data
--- @return boolean isPresence True if this is a Presence Sensor
local function isPresenceSensor(fd3dData)
  if not fd3dData or #fd3dData < 4 then
    return false
  end
  -- Check last 4 bytes for signature
  local len = #fd3dData
  local s1 = string.byte(fd3dData, len - 3)
  local s2 = string.byte(fd3dData, len - 2)
  local s3 = string.byte(fd3dData, len - 1)
  local s4 = string.byte(fd3dData, len)
  return (s1 == 0x00 or s1 == 0x01) and s2 == 0x10 and s3 == 0xCC and s4 == 0xC8
end

--- Parse SwitchBot advertisement data.
--- @param serviceData BLEServiceData[]|nil Service data array
--- @param manufacturerData BLEManufacturerData[]|nil Manufacturer data array
--- @return SwitchBotParsedData|nil parsed Parsed data or nil if not SwitchBot
function SwitchBot.parse(serviceData, manufacturerData)
  local fd3dData = UUID.findData(serviceData, SwitchBot.SERVICE_UUID) or ""
  local mfgData = findManufacturerData(manufacturerData) or ""

  if IsEmpty(fd3dData) and IsEmpty(mfgData) then
    return nil
  end
  --- @cast fd3dData -nil
  --- @cast mfgData -nil

  -- Determine device type from service data byte 0
  --- @type SwitchBotDeviceTypeCode|nil
  local deviceCode = nil
  -- Check for Presence Sensor (uses signature in last 4 bytes, overrides deviceCode)
  if isPresenceSensor(fd3dData) then
    deviceCode = SwitchBot.DeviceTypeCode.PRESENCE
  elseif fd3dData and #fd3dData >= 1 then
    local firstByte = string.byte(fd3dData, 1)
    deviceCode = bit32.band(firstByte, 0x7F)
  end

  if not deviceCode or not SwitchBot.DEVICE_NAMES[deviceCode] then
    return nil
  end

  --- @type SwitchBotParsedData|nil
  local result = nil

  -- Route to appropriate parser based on device type
  if deviceCode == SwitchBot.DeviceTypeCode.METER then
    result = parseMeterBasic(fd3dData, deviceCode)
  elseif deviceCode == SwitchBot.DeviceTypeCode.METER_PLUS then
    result = parseMeterBasic(fd3dData, deviceCode)
  elseif deviceCode == SwitchBot.DeviceTypeCode.METER_PRO then
    result = parseMeterPro(mfgData, fd3dData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.METER_PRO_CO2 then
    result = parseMeterProCO2Full(mfgData, fd3dData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.INDOOR_OUTDOOR_METER then
    result = parseOutdoorMeter(mfgData, fd3dData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.MOTION then
    result = parseMotion(fd3dData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.CONTACT then
    result = parseContact(mfgData, fd3dData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.WATER_LEAK then
    result = parseWaterLeak(mfgData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.PLUG_MINI then
    result = parsePlugMini(mfgData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.RELAY_1 then
    result = parseRelaySwitch(mfgData, deviceCode)
  elseif deviceCode == SwitchBot.DeviceTypeCode.RELAY_1PM then
    result = parseRelaySwitch(mfgData, deviceCode)
  elseif deviceCode == SwitchBot.DeviceTypeCode.RELAY_2PM then
    result = parseRelaySwitch(mfgData, deviceCode)
  elseif deviceCode == SwitchBot.DeviceTypeCode.REMOTE then
    result = parseRemote(fd3dData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.BOT then
    result = parseBot(fd3dData)
  elseif deviceCode == SwitchBot.DeviceTypeCode.PRESENCE then
    result = parsePresenceSensor(mfgData, fd3dData)
  else
    -- Unknown device type - log warning and return nil
    log:warn("Unknown SwitchBot device code: 0x%02X", deviceCode)
  end

  log:trace("Parsed SwitchBot data: %s", result)
  return result
end

return SwitchBot
