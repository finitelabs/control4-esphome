--- Yale/August BLE lock protocol implementation.
--- Port of key logic from Home Assistant's yalexs-ble Python library.
--- Sources:
---  - https://github.com/bdraco/yalexs-ble

local bit32 = require("bitn").bit32

local yale_protocol = {}

--------------------------------------------------------------------------------
-- GATT UUIDs
--------------------------------------------------------------------------------

yale_protocol.UUID = {
  SERVICE = "0000FE24-0000-1000-8000-00805F9B34FB",
  WRITE = "BD4AC611-0B45-11E3-8FFD-0800200C9A66",
  READ = "BD4AC612-0B45-11E3-8FFD-0800200C9A66",
  SECURE_WRITE = "BD4AC613-0B45-11E3-8FFD-0800200C9A66",
  SECURE_READ = "BD4AC614-0B45-11E3-8FFD-0800200C9A66",
}

--------------------------------------------------------------------------------
-- Command Opcodes
--------------------------------------------------------------------------------

yale_protocol.Opcode = {
  -- Secure handshake opcodes
  SEC_LOCK_TO_MOBILE_KEY_EXCHANGE = 0x01,
  SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP = 0x02,
  SEC_INITIALIZATION_COMMAND = 0x03,
  SEC_INITIALIZATION_RESP = 0x04,
  SEC_DISCONNECT = 0x05,
  SEC_DISCONNECT_RESP = 0x8B,
  -- Lock operation opcodes
  LOCK = 0x0B,
  UNLOCK = 0x0A,
  GET_STATUS = 0x02,
}

--- Status query subtypes (sent at offset 0x04)
yale_protocol.StatusType = {
  LOCK_ONLY = 0x02,
  DOOR_ONLY = 0x2E,
  DOOR_AND_LOCK = 0x2F,
  BATTERY = 0x0F,
}

--------------------------------------------------------------------------------
-- Lock / Door Status Enums
--------------------------------------------------------------------------------

--- Lock status byte values
yale_protocol.LockStatus = {
  UNKNOWN = 0x00,
  CALIBRATING = 0x01,
  UNLOCKING = 0x02,
  UNLOCKED = 0x03,
  LOCKING = 0x04,
  LOCKED = 0x05,
  SECURE_MODE = 0x0C,
  JAMMED = 0x1B,
}

--- Door status byte values
yale_protocol.DoorStatus = {
  CLOSED = 0x01,
  AJAR = 0x02,
  OPENED = 0x03,
}

--- Map lock status byte to string
--- @param statusByte integer Lock status byte
--- @return string status Human-readable status
function yale_protocol.parseLockStatus(statusByte)
  statusByte = statusByte or 0
  if statusByte == yale_protocol.LockStatus.LOCKED then
    return "locked"
  elseif statusByte == yale_protocol.LockStatus.UNLOCKED then
    return "unlocked"
  elseif statusByte == yale_protocol.LockStatus.JAMMED then
    return "jammed"
  elseif statusByte == yale_protocol.LockStatus.LOCKING then
    return "locking"
  elseif statusByte == yale_protocol.LockStatus.UNLOCKING then
    return "unlocking"
  elseif statusByte == yale_protocol.LockStatus.CALIBRATING then
    return "calibrating"
  elseif statusByte == yale_protocol.LockStatus.SECURE_MODE then
    return "secure_mode"
  end
  return "unknown"
end

--- Map lock status to C4 lock status string
--- @param statusByte integer Lock status byte
--- @return string c4Status C4 lock status ("locked", "unlocked", "fault")
function yale_protocol.toC4LockStatus(statusByte)
  statusByte = statusByte or 0
  if statusByte == yale_protocol.LockStatus.LOCKED then
    return "locked"
  elseif statusByte == yale_protocol.LockStatus.UNLOCKED then
    return "unlocked"
  elseif statusByte == yale_protocol.LockStatus.JAMMED then
    return "fault"
  elseif statusByte == yale_protocol.LockStatus.LOCKING then
    return "unlocked" -- transitional
  elseif statusByte == yale_protocol.LockStatus.UNLOCKING then
    return "locked" -- transitional
  elseif statusByte == yale_protocol.LockStatus.CALIBRATING then
    return "fault" -- calibrating
  elseif statusByte == yale_protocol.LockStatus.SECURE_MODE then
    return "locked" -- secure mode = locked
  end
  return "unknown"
end

--- Map door status byte to string
--- @param statusByte integer Door status byte
--- @return string status "CLOSED", "OPENED", or "UNKNOWN"
function yale_protocol.parseDoorStatus(statusByte)
  statusByte = statusByte or 0
  if statusByte == yale_protocol.DoorStatus.CLOSED then
    return "CLOSED"
  elseif statusByte == yale_protocol.DoorStatus.AJAR then
    return "OPENED"
  elseif statusByte == yale_protocol.DoorStatus.OPENED then
    return "OPENED"
  end
  return "UNKNOWN"
end

--- Per-cell voltage to percentage lookup table (from yalexs-ble)
--- @type table<number, number>
local VOLTAGE_TO_PERCENT = {
  [1.6] = 100,
  [1.55] = 95,
  [1.51] = 90,
  [1.48] = 85,
  [1.44] = 80,
  [1.41] = 75,
  [1.38] = 70,
  [1.35] = 65,
  [1.32] = 60,
  [1.30] = 55,
  [1.28] = 50,
  [1.26] = 45,
  [1.24] = 40,
  [1.22] = 35,
  [1.21] = 30,
  [1.20] = 25,
  [1.18] = 20,
  [1.16] = 15,
  [1.14] = 10,
  [1.10] = 5,
  [1.0] = 0,
}

--- Convert battery millivolts to percentage.
--- Yale locks use 4x AA batteries; voltage is total pack millivolts (LE u16).
--- Divides by 4 for per-cell voltage, then uses lookup table from yalexs-ble.
--- @param millivolts integer Total pack millivolts (little-endian u16 from response)
--- @return integer percentage Battery percentage (0-100)
function yale_protocol.parseBattery(millivolts)
  local perCellVolts = (millivolts / 1000) / 4
  -- Find the closest voltage in the lookup table
  local bestPercent = 0
  local bestDiff = 999
  for voltage, percent in pairs(VOLTAGE_TO_PERCENT) do
    local diff = math.abs(perCellVolts - voltage)
    if diff < bestDiff then
      bestDiff = diff
      bestPercent = percent
    end
  end
  return bestPercent
end

--------------------------------------------------------------------------------
-- Packet Building
--------------------------------------------------------------------------------

--- Packet size for all Yale BLE commands
local PACKET_SIZE = 18

--- Build a basic command packet (18 bytes)
--- Format: [0xEE][opcode][0x00][checksum][12 payload bytes][0x02][0x00]
--- @param opcode integer Command opcode
--- @return string packet 18-byte command packet
function yale_protocol.buildCommand(opcode)
  local buf = {}
  for i = 1, PACKET_SIZE do
    buf[i] = 0
  end
  buf[1] = 0xEE -- Non-secure prefix
  buf[2] = opcode
  buf[3] = 0x00
  -- buf[4] = checksum (filled below)
  buf[17] = 0x02
  buf[18] = 0x00

  -- Simple checksum: negate sum of all 18 bytes (byte at offset 0x03)
  local sum = 0
  for i = 1, PACKET_SIZE do
    if i ~= 4 then -- skip checksum position
      sum = sum + buf[i]
    end
  end
  buf[4] = bit32.band(-sum, 0xFF)

  local chars = {}
  for i = 1, PACKET_SIZE do
    chars[i] = string.char(buf[i])
  end
  return table.concat(chars)
end

--- Build an operation command packet with sub-command at offset 0x04
--- @param opcode integer Command opcode
--- @param subCommand integer Sub-command/status type byte
--- @return string packet 18-byte command packet
function yale_protocol.buildOperationCommand(opcode, subCommand)
  local buf = {}
  for i = 1, PACKET_SIZE do
    buf[i] = 0
  end
  buf[1] = 0xEE
  buf[2] = opcode
  buf[3] = 0x00
  -- buf[4] = checksum (filled below)
  buf[5] = subCommand
  buf[17] = 0x02
  buf[18] = 0x00

  local sum = 0
  for i = 1, PACKET_SIZE do
    if i ~= 4 then
      sum = sum + buf[i]
    end
  end
  buf[4] = bit32.band(-sum, 0xFF)

  local chars = {}
  for i = 1, PACKET_SIZE do
    chars[i] = string.char(buf[i])
  end
  return table.concat(chars)
end

--- Read a little-endian uint32 from a byte array at 1-based offset
--- @param buf table Byte array (integer values)
--- @param offset integer 1-based offset
--- @return number value 32-bit unsigned integer
local function le_u32_from_array(buf, offset)
  return buf[offset] + buf[offset + 1] * 256 + buf[offset + 2] * 65536 + buf[offset + 3] * 16777216
end

--- Read a little-endian uint32 from a string at 1-based offset
--- @param s string Binary string
--- @param offset integer 1-based offset
--- @return number value 32-bit unsigned integer
local function le_u32_from_string(s, offset)
  return string.byte(s, offset)
    + string.byte(s, offset + 1) * 256
    + string.byte(s, offset + 2) * 65536
    + string.byte(s, offset + 3) * 16777216
end

--- Compute security checksum for a byte array.
--- Matches yalexs-ble: sum three LE u32 groups (bytes 0-3, 4-7, 8-11), negate mod 2^32.
--- The checksum at bytes 12-15 contributes to bits >=32 of val3, so it's masked away.
--- @param buf table Byte array (1-indexed, integer values)
local function writeSecurityChecksum(buf)
  local val1 = le_u32_from_array(buf, 1)
  local val2 = le_u32_from_array(buf, 5)
  local val3 = le_u32_from_array(buf, 9)
  local sum = (val1 + val2 + val3) % 4294967296
  local checksum = (4294967296 - sum) % 4294967296
  -- Store as little-endian at bytes 13-16 (1-indexed)
  buf[13] = checksum % 256
  buf[14] = math.floor(checksum / 256) % 256
  buf[15] = math.floor(checksum / 65536) % 256
  buf[16] = math.floor(checksum / 16777216) % 256
end

--- Build a secure command packet (18 bytes)
--- Format: [opcode][11 payload bytes][4-byte security checksum][0x0F][key_index]
--- @param opcode integer Command opcode
--- @param keyIndex integer Key index (default 1)
--- @return string packet 18-byte secure command packet
function yale_protocol.buildSecureCommand(opcode, keyIndex)
  keyIndex = keyIndex or 1
  local buf = {}
  for i = 1, PACKET_SIZE do
    buf[i] = 0
  end
  buf[1] = opcode
  buf[17] = 0x0F
  buf[18] = keyIndex

  writeSecurityChecksum(buf)

  local chars = {}
  for i = 1, PACKET_SIZE do
    chars[i] = string.char(buf[i])
  end
  return table.concat(chars)
end

--- Compute simple checksum for a packet: negate sum of all bytes except offset 0x03
--- @param packet string 18-byte packet
--- @return integer checksum Single byte checksum
function yale_protocol.simpleChecksum(packet)
  local sum = 0
  for i = 1, #packet do
    if i ~= 4 then
      sum = sum + string.byte(packet, i)
    end
  end
  return bit32.band(-sum, 0xFF)
end

--- Compute security checksum for a secure packet (string version).
--- @param packet string 18-byte packet
--- @return number checksum 32-bit checksum value
function yale_protocol.securityChecksum(packet)
  local val1 = le_u32_from_string(packet, 1)
  local val2 = le_u32_from_string(packet, 5)
  local val3 = le_u32_from_string(packet, 9)
  local sum = (val1 + val2 + val3) % 4294967296
  return (4294967296 - sum) % 4294967296
end

--------------------------------------------------------------------------------
-- Secure Session (AES-ECB, used during handshake)
--------------------------------------------------------------------------------

--- @class YaleSecureSession
--- @field _key string|nil 16-byte AES key
local SecureSession = {}
SecureSession.__index = SecureSession

--- Create a new secure session
--- @param offlineKey string 16-byte offline key
--- @return YaleSecureSession session
function SecureSession:new(offlineKey)
  assert(#offlineKey == 16, "Offline key must be 16 bytes")
  local instance = setmetatable({}, self)
  instance._key = offlineKey
  return instance
end

--- Set a new key for this session
--- @param newKey string 16-byte key
function SecureSession:setKey(newKey)
  assert(#newKey == 16, "Key must be 16 bytes")
  self._key = newKey
end

--- ECB encrypt bytes 0x00-0x0F of an 18-byte packet (in-place on first 16 bytes)
--- @param data string 18-byte packet
--- @return string encrypted 18-byte packet with first 16 bytes encrypted
function SecureSession:encrypt(data)
  assert(#data == 18, "Data must be 18 bytes")
  local plainBlock = data:sub(1, 16)
  local encrypted = C4:Encrypt("AES-128-ECB", self._key, "", plainBlock, { padding = false })
  return encrypted .. data:sub(17, 18)
end

--- ECB decrypt bytes 0x00-0x0F of an 18-byte packet
--- @param data string 18-byte packet
--- @return string decrypted 18-byte packet with first 16 bytes decrypted
function SecureSession:decrypt(data)
  assert(#data == 18, "Data must be 18 bytes")
  local cipherBlock = data:sub(1, 16)
  local decrypted = C4:Decrypt("AES-128-ECB", self._key, "", cipherBlock, { padding = false })
  return decrypted .. data:sub(17, 18)
end

--- Write security checksum into a byte array (exported for driver use).
yale_protocol.writeSecurityChecksum = writeSecurityChecksum

yale_protocol.SecureSession = SecureSession

--------------------------------------------------------------------------------
-- Session (AES-CBC, used for commands after handshake)
--------------------------------------------------------------------------------

--- @class YaleSession
--- @field _key string|nil 16-byte AES key
--- @field _encryptIV string 16-byte IV for encryption (tracks streaming state)
--- @field _decryptIV string 16-byte IV for decryption (tracks streaming state)
local Session = {}
Session.__index = Session

--- Create a new CBC session
--- @return YaleSession session
function Session:new()
  local instance = setmetatable({}, self)
  instance._key = nil
  instance._encryptIV = string.rep("\0", 16)
  instance._decryptIV = string.rep("\0", 16)
  return instance
end

--- Set the session key (also resets IVs)
--- @param newKey string 16-byte key
function Session:setKey(newKey)
  assert(#newKey == 16, "Key must be 16 bytes")
  self._key = newKey
  self._encryptIV = string.rep("\0", 16)
  self._decryptIV = string.rep("\0", 16)
end

--- Check if the session has a key set
--- @return boolean ready True if key is set
function Session:isReady()
  return self._key ~= nil
end

--- CBC encrypt bytes 0x00-0x0F of an 18-byte packet, tracking streaming IV
--- @param data string 18-byte packet
--- @return string encrypted 18-byte packet with first 16 bytes encrypted
function Session:encrypt(data)
  assert(#data == 18, "Data must be 18 bytes")
  assert(self._key, "Session key not set")
  local plainBlock = data:sub(1, 16)
  local encrypted = C4:Encrypt("AES-128-CBC", self._key, self._encryptIV, plainBlock, { padding = false })
  -- Update IV for next encryption (last ciphertext block)
  self._encryptIV = encrypted
  return encrypted .. data:sub(17, 18)
end

--- CBC decrypt bytes 0x00-0x0F of an 18-byte packet, tracking streaming IV
--- @param data string 18-byte packet
--- @return string decrypted 18-byte packet with first 16 bytes decrypted
function Session:decrypt(data)
  assert(#data == 18, "Data must be 18 bytes")
  assert(self._key, "Session key not set")
  local cipherBlock = data:sub(1, 16)
  local decrypted = C4:Decrypt("AES-128-CBC", self._key, self._decryptIV, cipherBlock, { padding = false })
  -- Update IV for next decryption (this ciphertext block)
  self._decryptIV = cipherBlock
  return decrypted .. data:sub(17, 18)
end

yale_protocol.Session = Session

--------------------------------------------------------------------------------
-- Response Parsing
--------------------------------------------------------------------------------

--- Parse an 18-byte decrypted response packet.
--- Response format depends on flag AND opcode (matches yalexs-ble parsing).
--- @param data string 18-byte decrypted response
--- @return table|nil response Parsed response
function yale_protocol.parseResponse(data)
  if not data or #data < 18 then
    return nil
  end

  local flag = string.byte(data, 1)
  local opcode = string.byte(data, 2)

  -- Status response (flag 0xBB)
  if flag == 0xBB then
    local result = { flag = flag, opcode = opcode }

    if opcode == yale_protocol.Opcode.GET_STATUS then
      -- GETSTATUS response: statusType at byte 0x04 (Lua 5), data at byte 0x08 (Lua 9)
      local statusType = string.byte(data, 5)
      result.statusType = statusType
      if statusType == yale_protocol.StatusType.LOCK_ONLY then
        result.lockStatus = string.byte(data, 9)
      elseif statusType == yale_protocol.StatusType.DOOR_ONLY then
        result.doorStatus = string.byte(data, 9)
      elseif statusType == yale_protocol.StatusType.DOOR_AND_LOCK then
        result.lockStatus = string.byte(data, 9)
        result.doorStatus = string.byte(data, 10)
      elseif statusType == yale_protocol.StatusType.BATTERY then
        -- Battery millivolts as little-endian u16 at bytes 0x08-0x09 (Lua 9-10)
        result.batteryMillivolts = string.byte(data, 9) + string.byte(data, 10) * 256
      end
    elseif opcode == yale_protocol.Opcode.LOCK or opcode == yale_protocol.Opcode.UNLOCK then
      -- Lock/unlock command response: lock status at byte 0x03 (Lua 4)
      result.lockStatus = string.byte(data, 4)
    end

    return result
  end

  -- Acknowledgment response (flag 0xAA) — command completed
  if flag == 0xAA then
    return {
      flag = flag,
      opcode = opcode,
    }
  end

  -- Handshake response (no flag prefix, opcode at byte 1)
  return {
    flag = 0,
    opcode = flag, -- first byte is actually the opcode for handshake responses
  }
end

--------------------------------------------------------------------------------
-- Self-Test
--------------------------------------------------------------------------------

--- Run self-tests with known-good test vectors from yalexs-ble.
--- Validates security checksum (LE u32 groups) and simple checksum.
--- @return boolean success True if all tests passed
function yale_protocol.selftest()
  local pass = true

  local function assertEq(name, got, expected)
    if got ~= expected then
      print(string.format("FAIL: %s: got 0x%08X, expected 0x%08X", name, got, expected))
      pass = false
    end
  end

  local function hexToBytes(hex)
    local bytes = {}
    for i = 1, #hex, 2 do
      bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16)
    end
    return bytes
  end

  local function bytesToString(bytes)
    local chars = {}
    for i = 1, #bytes do
      chars[i] = string.char(bytes[i])
    end
    return table.concat(chars)
  end

  -- Security checksum test vectors (from yalexs-ble)
  -- Each: { name, input_hex_bytes_0_11, expected_checksum_u32 }
  local securityTests = {
    { "all zeros", "000000000000000000000000", 0x00000000 },
    { "all 0xFF", "ffffffffffffffffffffffff", 0x00000003 },
    { "all 0x01", "010101010101010101010101", 0xFCFCFCFD },
    { "ascending 0-11", "000102030405060708090a0b", 0xEAEDF0F4 },
    { "max val1 only", "ffffffff0000000000000000", 0x00000001 },
    { "SEC_KEY_EXCHANGE bare", "010000000000000000000000", 0xFFFFFFFF },
    { "SEC_INIT bare", "030000000000000000000000", 0xFFFFFFFD },
    -- With handshake payload: KEY_EXCHANGE (0x01) + handshake_keys[0:8] at offset 4
    { "KEY_EXCHANGE with payload", "01000000aabbccddeeff0011", 0x11324467 },
    -- SEC_INIT (0x03) + handshake_keys[8:16] at offset 4
    { "SEC_INIT with payload", "030000002233445566778899", 0x11335575 },
  }

  for _, test in ipairs(securityTests) do
    local name, inputHex, expected = test[1], test[2], test[3]
    -- Build 18-byte buffer: first 12 bytes from input, zeros for checksum, then 0x0F, keyIndex
    local bytes = hexToBytes(inputHex)
    for i = #bytes + 1, 18 do
      bytes[i] = 0
    end
    bytes[17] = 0x0F
    bytes[18] = 0x01
    writeSecurityChecksum(bytes)
    -- Read computed checksum from bytes 13-16 as LE u32
    local got = bytes[13] + bytes[14] * 256 + bytes[15] * 65536 + bytes[16] * 16777216
    assertEq("security: " .. name, got, expected)
  end

  -- Also verify string version matches
  for _, test in ipairs(securityTests) do
    local name, inputHex, expected = test[1], test[2], test[3]
    local bytes = hexToBytes(inputHex)
    for i = #bytes + 1, 18 do
      bytes[i] = 0
    end
    bytes[17] = 0x0F
    bytes[18] = 0x01
    local s = bytesToString(bytes)
    local got = yale_protocol.securityChecksum(s)
    assertEq("security(str): " .. name, got, expected)
  end

  -- Simple checksum test vectors (from yalexs-ble test_lock.py)
  -- Each: { name, full_18_byte_hex, expected_byte3_value }
  local simpleTests = {
    { "UNLOCK", "ee0a00060000000000000000000000000200", 0x06 },
    { "LOCK", "ee0b00050000000000000000000000000200", 0x05 },
    { "GETSTATUS", "ee0200000000000000000000000000000200", 0x0E },
    { "STATUS_LOCK", "ee0200000200000000000000000000000200", 0x0C },
    { "STATUS_BATTERY", "ee0200000f00000000000000000000000200", 0xFF },
    -- Verify known-good response packets sum to 0
    { "LOCK_JAMMED resp", "bb0b001b00000000000000000000001f0000", nil },
    { "LOCK_UNLOCKED resp", "bb0b00030000000000000000000000370000", nil },
  }

  for _, test in ipairs(simpleTests) do
    local name, packetHex, expectedByte3 = test[1], test[2], test[3]
    local s = bytesToString(hexToBytes(packetHex))
    if expectedByte3 then
      local got = yale_protocol.simpleChecksum(s)
      assertEq("simple: " .. name, got, expectedByte3)
    else
      -- For response packets, verify that the full sum is 0 (checksum is valid)
      local sum = 0
      for i = 1, #s do
        sum = sum + string.byte(s, i)
      end
      local valid = (sum % 256 == 0)
      if not valid then
        print(string.format("FAIL: simple: %s: sum=%d (expected 0 mod 256)", name, sum % 256))
        pass = false
      end
    end
  end

  if pass then
    print("yale_protocol: all self-tests passed")
  end
  return pass
end

return yale_protocol
