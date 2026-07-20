--- @module "protobuf"
--- A lightweight Protocol Buffers implementation for Lua.
--- This module provides encoding and decoding functions for Protocol Buffers data format.
--- @class protobuf
local pb = {}

local bitn = require("bitn")
local bit32 = bitn.bit32
local bit64 = bitn.bit64

-- Cache methods as locals for faster access
local bit32_raw_arshift = bit32.raw_arshift
local bit32_raw_band = bit32.raw_band
local bit32_raw_bor = bit32.raw_bor
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_lshift = bit32.raw_lshift
local bit32_raw_rshift = bit32.raw_rshift
local bit32_to_unsigned = bit32.to_unsigned
local bit64_eq = bit64.eq
local bit64_from_number = bit64.from_number
local bit64_is_int64 = bit64.is_int64
local bit64_is_zero = bit64.is_zero
local bit64_new = bit64.new
local bit64_raw_arshift = bit64.raw_arshift
local bit64_raw_bor = bit64.raw_bor
local bit64_raw_bxor = bit64.raw_bxor
local bit64_raw_lshift = bit64.raw_lshift
local bit64_raw_rshift = bit64.raw_rshift
local bit64_to_hex = bit64.to_hex
local bit64_to_number = bit64.to_number

-- Lua 5.3+ removed math.frexp and math.ldexp; provide polyfills
local math_frexp = math.frexp
  or function(x)
    if x == 0 then
      return 0, 0
    end
    local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1
    return x / 2 ^ e, e
  end
local math_ldexp = math.ldexp or function(m, e)
  return m * 2 ^ e
end

--- Check if a value is a list (sequential table).
--- @param t any The value to check.
--- @return boolean is_list True if the value is a list.
local function is_list(t)
  if type(t) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  for i = 1, count do
    if t[i] == nil then
      return false
    end
  end
  return count > 0
end

-- Version
local VERSION = "v0.6.4"

--- Returns the library version.
--- @return string version The version string.
function pb.version()
  return VERSION
end

--- Encodes an integer into a varint byte sequence.
--- @param value integer|boolean|Int64HighLow The value to encode. Can be a number, boolean, or {high, low} pair for 64-bit values.
--- @return string bytes The encoded varint byte sequence.
function pb.encode_varint(value)
  if type(value) == "boolean" then
    value = value and 1 or 0
  end

  -- If value is a table, assume it's {high, low} format for 64-bit
  if bit64_is_int64(value) then
    --- @cast value Int64HighLow
    local bytes = {}
    local v = bit64_new(value[1], value[2]) -- Copy the input

    repeat
      -- Extract low 7 bits
      local byte = v[2] % 128

      -- Right shift by 7 bits using bit64
      v = bit64_raw_rshift(v, 7)

      -- Set continue bit if more bytes remain
      if v[1] ~= 0 or v[2] ~= 0 then
        byte = byte + 0x80
      end
      table.insert(bytes, string.char(byte))
    until v[1] == 0 and v[2] == 0

    return table.concat(bytes)
  end
  --- @cast value -Int64HighLow

  -- For values that fit in 32 bits, use bit operations (fast path)
  if value >= 0 and value < 0x100000000 then
    local bytes = {}
    repeat
      local byte = bit32_raw_band(value, 0x7F)
      value = bit32_raw_rshift(value, 7)
      if value > 0 then
        byte = bit32_raw_bor(byte, 0x80)
      end
      table.insert(bytes, string.char(byte))
    until value == 0
    return table.concat(bytes)
  end

  -- For large values (> 32 bits), convert to {high, low} and use bit64
  local low_32 = value % 0x100000000
  local high_32 = math.floor(value / 0x100000000)
  local v = bit64_new(high_32, low_32)
  local bytes = {}

  repeat
    local byte = v[2] % 128
    v = bit64_raw_rshift(v, 7)
    if v[1] ~= 0 or v[2] ~= 0 then
      byte = byte + 0x80
    end
    table.insert(bytes, string.char(byte))
  until v[1] == 0 and v[2] == 0

  return table.concat(bytes)
end

--- Decodes a varint byte sequence into a {high, low} pair.
--- Always returns a Int64HighLow table for full 64-bit precision.
--- Use this for uint64/int64 fields that may exceed 53-bit precision.
--- @param buffer string The buffer containing the encoded varint.
--- @param pos integer The position in the buffer to start decoding from.
--- @return Int64HighLow value The decoded value as {high_32, low_32}.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_varint64(buffer, pos)
  local result = bit64_new(0, 0)
  local shift = 0
  local byte

  repeat
    byte = string.byte(buffer, pos)
    local value_bits = bit32_raw_band(byte, 0x7F)

    -- Create a Int64 for this 7-bit chunk and shift it
    local chunk = bit64_new(0, value_bits)
    local shifted = bit64_raw_lshift(chunk, shift)

    -- OR with result
    result = bit64_raw_bor(result, shifted)

    shift = shift + 7
    pos = pos + 1
  until byte < 128

  return result, pos
end

--- Decodes a varint byte sequence into an integer.
--- Always returns a Lua number. Values exceeding 53-bit precision are truncated.
--- Use decode_varint64 for fields that need full 64-bit precision.
--- @param buffer string The buffer containing the encoded varint.
--- @param pos integer The position in the buffer to start decoding from.
--- @return integer value The decoded value as a number.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_varint(buffer, pos)
  local result, new_pos = pb.decode_varint64(buffer, pos)
  return pb.int64_to_number(result), new_pos
end

--- Encodes a 32-bit integer into a fixed-length 4-byte sequence.
--- @param value integer The 32-bit integer to encode.
--- @return string bytes The encoded 4-byte sequence.
function pb.encode_fixed32(value)
  local b1 = value % 256
  local b2 = math.floor(value / 256) % 256
  local b3 = math.floor(value / 65536) % 256
  local b4 = math.floor(value / 16777216)
  return string.char(b1, b2, b3, b4)
end

--- Decodes a fixed-length 4-byte sequence into a 32-bit integer.
--- @param buffer string The buffer containing the encoded fixed32.
--- @param pos integer The position in the buffer to start decoding from.
--- @return integer value The decoded 32-bit integer value.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_fixed32(buffer, pos)
  local b1, b2, b3, b4 = string.byte(buffer, pos, pos + 3)
  local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  --- @cast value integer
  return value, pos + 4
end

--- Encodes a 64-bit integer into a fixed-length 8-byte sequence.
--- @param value Int64HighLow|number The 64-bit integer as {high, low} or number.
--- @return string bytes The encoded 8-byte sequence.
function pb.encode_fixed64(value)
  local high, low
  if bit64_is_int64(value) then
    --- @cast value Int64HighLow
    high, low = value[1], value[2]
  else
    --- @cast value -Int64HighLow
    low = math.floor(value % 0x100000000)
    high = math.floor(value / 0x100000000)
  end
  local b1 = low % 256
  local b2 = math.floor(low / 256) % 256
  local b3 = math.floor(low / 65536) % 256
  local b4 = math.floor(low / 16777216) % 256
  local b5 = high % 256
  local b6 = math.floor(high / 256) % 256
  local b7 = math.floor(high / 65536) % 256
  local b8 = math.floor(high / 16777216) % 256
  return string.char(b1, b2, b3, b4, b5, b6, b7, b8)
end

--- Decodes a fixed-length 8-byte sequence into a 64-bit integer.
--- @param buffer string The buffer containing the encoded fixed64.
--- @param pos integer The position in the buffer to start decoding from.
--- @return Int64HighLow value The decoded 64-bit value as {high_32, low_32}.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_fixed64(buffer, pos)
  --- @type integer, integer, integer, integer, integer, integer, integer, integer
  local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(buffer, pos, pos + 7)
  local low = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  local high = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
  return bit64_new(high, low), pos + 8
end

--- Encodes a floating-point number into a 4-byte IEEE 754 single-precision format.
--- @param value number The floating-point number to encode.
--- @return string bytes The encoded 4-byte sequence.
function pb.encode_float(value)
  if value == 0 then
    return string.char(0, 0, 0, 0)
  end

  local sign = 0
  if value < 0 then
    sign = 1
    value = -value
  end

  local mantissa, exponent = math_frexp(value)
  exponent = exponent - 1
  mantissa = mantissa * 2 - 1

  local e = exponent + 127
  if e < 0 then
    e = 0
    mantissa = 0
  elseif e > 255 then
    e = 255
    mantissa = 0
  end

  local m = math.floor(mantissa * 0x800000 + 0.5)

  local b1 = m % 256
  local b2 = math.floor(m / 256) % 256
  local b3 = bit32_raw_bor(math.floor(m / 65536), bit32_raw_lshift(e % 2, 7))
  local b4 = bit32_raw_bor(bit32_raw_rshift(e, 1), bit32_raw_lshift(sign, 7))

  return string.char(b1, b2, b3, b4)
end

--- Decodes a 4-byte IEEE 754 single-precision format into a floating-point number.
--- @param buffer string The buffer containing the encoded float.
--- @param pos integer The position in the buffer to start decoding from.
--- @return number value The decoded floating-point value.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_float(buffer, pos)
  local b1, b2, b3, b4 = string.byte(buffer, pos, pos + 3)

  local sign = bit32_raw_rshift(b4, 7)
  local e = bit32_raw_lshift(bit32_raw_band(b4, 0x7F), 1) + bit32_raw_rshift(b3, 7)
  local m = bit32_raw_band(b3, 0x7F) * 65536 + b2 * 256 + b1

  if e == 0 and m == 0 then
    return 0, pos + 4
  end

  local result = math_ldexp(1 + m / 0x800000, e - 127)
  if sign == 1 then
    result = -result
  end

  return result, pos + 4
end

--- Encodes a double-precision floating-point number into an 8-byte IEEE 754 format.
--- @param value number The double-precision floating-point number to encode.
--- @return string bytes The encoded 8-byte sequence.
function pb.encode_double(value)
  if value == 0 then
    return string.char(0, 0, 0, 0, 0, 0, 0, 0)
  end

  local sign = 0
  if value < 0 then
    sign = 1
    value = -value
  end

  local mantissa, exponent = math_frexp(value)
  exponent = exponent - 1
  mantissa = mantissa * 2 - 1

  local e = exponent + 1023
  if e < 0 then
    e = 0
    mantissa = 0
  elseif e > 2047 then
    e = 2047
    mantissa = 0
  end

  -- Mantissa is 52 bits, split across bytes
  local m = mantissa * 0x10000000000000 -- 2^52
  local m_low = math.floor(m % 0x100000000)
  local m_high = math.floor(m / 0x100000000) % 0x100000 -- 20 bits

  local b1 = m_low % 256
  local b2 = math.floor(m_low / 256) % 256
  local b3 = math.floor(m_low / 65536) % 256
  local b4 = math.floor(m_low / 16777216) % 256
  local b5 = m_high % 256
  local b6 = math.floor(m_high / 256) % 256
  local b7 = bit32_raw_bor(math.floor(m_high / 65536), bit32_raw_lshift(e % 16, 4))
  local b8 = bit32_raw_bor(bit32_raw_rshift(e, 4), bit32_raw_lshift(sign, 7))

  return string.char(b1, b2, b3, b4, b5, b6, b7, b8)
end

--- Decodes an 8-byte IEEE 754 double-precision format into a floating-point number.
--- @param buffer string The buffer containing the encoded double.
--- @param pos integer The position in the buffer to start decoding from.
--- @return number value The decoded double-precision floating-point value.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_double(buffer, pos)
  local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(buffer, pos, pos + 7)

  local sign = bit32_raw_rshift(b8, 7)
  local e = bit32_raw_lshift(bit32_raw_band(b8, 0x7F), 4) + bit32_raw_rshift(b7, 4)
  local m_high = bit32_raw_band(b7, 0x0F) * 65536 + b6 * 256 + b5
  local m_low = b4 * 16777216 + b3 * 65536 + b2 * 256 + b1
  local m = m_high * 0x100000000 + m_low

  if e == 0 and m == 0 then
    return 0, pos + 8
  end

  local result = math_ldexp(1 + m / 0x10000000000000, e - 1023)
  if sign == 1 then
    result = -result
  end

  return result, pos + 8
end

-- ============================================================================
-- Zigzag Encoding (for sint32/sint64)
-- ============================================================================

--- Encodes a signed 32-bit integer using zigzag encoding.
--- @param value integer The signed integer to encode.
--- @return integer encoded The zigzag-encoded value.
function pb.zigzag_encode32(value)
  -- Raw ops return signed; convert to unsigned for encode_varint
  local result = bit32_raw_bxor(bit32_raw_lshift(value, 1), bit32_raw_arshift(value, 31))
  return bit32_to_unsigned(result)
end

--- Decodes a zigzag-encoded 32-bit integer.
--- @param value integer The zigzag-encoded value.
--- @return integer decoded The signed integer.
function pb.zigzag_decode32(value)
  local result = bit32_raw_bxor(bit32_raw_rshift(value, 1), -bit32_raw_band(value, 1))
  -- Convert unsigned to signed if high bit is set
  if result >= 0x80000000 then
    result = result - 0x100000000
  end
  return result
end

--- Encodes a signed 64-bit integer using zigzag encoding.
--- @param value Int64HighLow The signed 64-bit integer as {high, low}.
--- @return Int64HighLow encoded The zigzag-encoded value as {high, low}.
function pb.zigzag_encode64(value)
  -- (n << 1) ^ (n >> 63)
  local shifted = bit64_raw_lshift(value, 1)
  local sign_extended = bit64_raw_arshift(value, 63)
  return bit64_raw_bxor(shifted, sign_extended)
end

--- Decodes a zigzag-encoded 64-bit integer.
--- @param value Int64HighLow The zigzag-encoded value as {high, low}.
--- @return Int64HighLow decoded The signed 64-bit integer as {high, low}.
function pb.zigzag_decode64(value)
  -- (n >>> 1) ^ -(n & 1)
  local shifted = bit64_raw_rshift(value, 1)
  local sign_bit = bit32_raw_band(value[2], 1)
  -- Negate: if sign_bit is 1, result is all 1s, else all 0s
  local neg_sign
  if sign_bit == 1 then
    neg_sign = bit64_new(0xFFFFFFFF, 0xFFFFFFFF)
  else
    neg_sign = bit64_new(0, 0)
  end
  return bit64_raw_bxor(shifted, neg_sign)
end

--- Encodes a length-delimited field (string or nested message).
--- @param data string The data to encode.
--- @return string bytes The encoded length-delimited data.
function pb.encode_length_delimited(data)
  return pb.encode_varint(#data) .. data
end

--- Decodes a length-delimited field.
--- @param buffer string The buffer containing the encoded length-delimited data.
--- @param pos integer The position in the buffer to start decoding from.
--- @return string data The decoded data.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_length_delimited(buffer, pos)
  local length, new_pos = pb.decode_varint(buffer, pos)
  local data = string.sub(buffer, new_pos, new_pos + length - 1)
  return data, new_pos + length
end

--- Encodes a message according to a schema.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param messageSchema ProtoMessageSchema The message schema to use for encoding.
--- @param message table<string, any> The message body to encode.
--- @return string buffer The encoded message.
function pb.encode(protoSchema, messageSchema, message)
  local buffer = ""

  for field_number, field in pairs(messageSchema.fields) do
    local values = message[field.name]
    if values ~= nil then
      if field.repeated then
        if not is_list(values) or bit64_is_int64(values) then
          error("Field '" .. field.name .. "' is repeated but received a non-list value.")
        end
      else
        if is_list(values) and not bit64_is_int64(values) then
          error("Field '" .. field.name .. "' is not repeated but received a list.")
        end
        values = { values } -- Wrap single value in a list for uniform processing
      end
      for _, value in ipairs(values) do
        -- Compute the key (field number and wire type)
        -- Use to_unsigned since large field numbers produce high-bit-set results
        --- @cast field.wireType integer
        local key = bit32_to_unsigned(bit32_raw_lshift(field_number, 3)) + field.wireType
        buffer = buffer .. pb.encode_varint(key)

        local fieldType = field.type
        if field.wireType == protoSchema.WireType.VARINT then
          -- Handle zigzag encoding for signed types
          if fieldType == protoSchema.DataType.SINT32 then
            buffer = buffer .. pb.encode_varint(pb.zigzag_encode32(value))
          elseif fieldType == protoSchema.DataType.SINT64 then
            buffer = buffer .. pb.encode_varint(pb.zigzag_encode64(value))
          else
            buffer = buffer .. pb.encode_varint(value)
          end
        elseif field.wireType == protoSchema.WireType.FIXED64 then
          if fieldType == protoSchema.DataType.DOUBLE then
            buffer = buffer .. pb.encode_double(value)
          else
            -- FIXED64, SFIXED64
            buffer = buffer .. pb.encode_fixed64(value)
          end
        elseif field.wireType == protoSchema.WireType.FIXED32 then
          if fieldType == protoSchema.DataType.FLOAT then
            buffer = buffer .. pb.encode_float(value)
          else
            -- FIXED32, SFIXED32
            buffer = buffer .. pb.encode_fixed32(value)
          end
        elseif field.wireType == protoSchema.WireType.LENGTH_DELIMITED then
          if type(value) == "string" then
            buffer = buffer .. pb.encode_length_delimited(value)
          elseif type(value) == "table" then
            if field.subschema == nil then
              error(
                "Field '"
                  .. messageSchema.name
                  .. "."
                  .. field.name
                  .. "' is a nested message but has no subschema defined."
              )
            end
            -- For nested messages
            local nested_message = pb.encode(protoSchema, protoSchema.Message[field.subschema], value)
            buffer = buffer .. pb.encode_length_delimited(nested_message)
          end
        else
          error("Unsupported wire type: " .. tostring(field.wireType))
        end
      end
    end
  end

  return buffer
end

--- Decodes a message according to a schema.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param messageSchema ProtoMessageSchema The schema defining the message structure.
--- @param buffer string The encoded message bytes.
--- @return table<string, any> message The decoded message.
--- @return number pos The position in the buffer after decoding.
function pb.decode(protoSchema, messageSchema, buffer)
  --- @type integer
  local pos = 1
  local message = {}

  local key
  while pos <= #buffer do
    -- Decode the key (field number and wire type)
    key, pos = pb.decode_varint(buffer, pos)
    local field_number = bit32_raw_rshift(key, 3)
    local wire_type = bit32_raw_band(key, 0x7)

    -- Find the corresponding field in the schema
    local field = messageSchema.fields[field_number]
    if not field then
      -- Skip unknown field based on wire type
      if wire_type == protoSchema.WireType.VARINT then
        -- Decode and discard the varint
        local _
        _, pos = pb.decode_varint(buffer, pos)
      elseif wire_type == protoSchema.WireType.FIXED64 then
        -- Skip 8 bytes
        pos = pos + 8
      elseif wire_type == protoSchema.WireType.FIXED32 then
        -- Skip 4 bytes
        pos = pos + 4
      elseif wire_type == protoSchema.WireType.LENGTH_DELIMITED then
        -- Decode length and skip that many bytes
        local length
        length, pos = pb.decode_varint(buffer, pos)
        pos = pos + length
      else
        error("Unknown wire type: " .. wire_type)
      end
    else
      -- Known field - decode and store the value
      local value
      local fieldType = field.type
      -- Decode the value based on the wire type
      if wire_type == protoSchema.WireType.VARINT then
        -- Use 64-bit decoder for types that need full precision
        if fieldType == protoSchema.DataType.UINT64 or fieldType == protoSchema.DataType.INT64 then
          value, pos = pb.decode_varint64(buffer, pos)
        elseif fieldType == protoSchema.DataType.SINT64 then
          local raw
          raw, pos = pb.decode_varint64(buffer, pos)
          value = pb.zigzag_decode64(raw)
        elseif fieldType == protoSchema.DataType.SINT32 then
          local raw
          raw, pos = pb.decode_varint(buffer, pos)
          value = pb.zigzag_decode32(raw)
        elseif fieldType == protoSchema.DataType.BOOL then
          value, pos = pb.decode_varint(buffer, pos)
          value = value ~= 0 -- Convert to boolean
        else
          -- INT32, UINT32, ENUM, etc.
          value, pos = pb.decode_varint(buffer, pos)
        end
      elseif wire_type == protoSchema.WireType.FIXED64 then
        if fieldType == protoSchema.DataType.DOUBLE then
          value, pos = pb.decode_double(buffer, pos)
        else
          -- FIXED64, SFIXED64
          value, pos = pb.decode_fixed64(buffer, pos)
        end
      elseif wire_type == protoSchema.WireType.FIXED32 then
        if fieldType == protoSchema.DataType.FLOAT then
          value, pos = pb.decode_float(buffer, pos)
        else
          -- FIXED32, SFIXED32
          value, pos = pb.decode_fixed32(buffer, pos)
        end
      elseif wire_type == protoSchema.WireType.LENGTH_DELIMITED then
        local data
        data, pos = pb.decode_length_delimited(buffer, pos)
        if field.subschema then
          value = pb.decode(protoSchema, protoSchema.Message[field.subschema], data)
        else
          value = data
        end
      else
        error("Unsupported wire type: " .. wire_type)
      end

      if field.repeated then
        if message[field.name] == nil then
          message[field.name] = {}
        end
        table.insert(message[field.name], value)
      else
        message[field.name] = value
      end
    end
  end

  return message, pos
end

-- ============================================================================
-- 64-bit {high, low} Utility Functions
-- ============================================================================

--- Converts a {high, low} pair to a hexadecimal string.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @return string hex The 16-character hexadecimal string (e.g., "0000180000001000").
function pb.int64_to_hex(value)
  return bit64_to_hex(value)
end

--- Converts a {high, low} pair to a Lua number.
--- Warning: Values exceeding 53-bit precision will lose precision.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @param strict? boolean If true, errors when value exceeds 53-bit precision.
--- @return integer result The value as a Lua number (may lose precision for large values unless strict).
function pb.int64_to_number(value, strict)
  return bit64_to_number(value, strict)
end

--- Creates a {high, low} pair from a Lua number.
--- @param value number The number to convert.
--- @return Int64HighLow pair The {high_32, low_32} pair.
function pb.int64_from_number(value)
  return bit64_from_number(value)
end

--- Checks if two {high, low} pairs are equal.
--- @param a Int64HighLow The first {high_32, low_32} pair.
--- @param b Int64HighLow The second {high_32, low_32} pair.
--- @return boolean equal True if the values are equal.
function pb.int64_equals(a, b)
  return bit64_eq(a, b)
end

--- Checks if a {high, low} pair is zero.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @return boolean is_zero True if the value is zero.
function pb.int64_is_zero(value)
  return bit64_is_zero(value)
end

--- Runs self-tests to verify the functionality of the protobuf module.
--- Test vectors based on official Protocol Buffers encoding specification.
--- @see https://protobuf.dev/programming-guides/encoding/
--- @return boolean success True if all tests passed.
function pb.selftest()
  print("Running protobuf test vectors...")
  local passed = 0
  local failed = 0

  -- ============================================================================
  -- TEST HELPERS
  -- ============================================================================

  local function to_hex(s)
    local hex = {}
    for i = 1, #s do
      table.insert(hex, string.format("%02X", string.byte(s, i)))
    end
    return table.concat(hex, " ")
  end

  local function assert_eq(actual, expected, msg)
    if actual == expected then
      passed = passed + 1
      print("  PASS: " .. msg)
    else
      failed = failed + 1
      print("  FAIL: " .. msg .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
  end

  local function assert_bytes(actual, expected_hex, msg)
    local expected = ""
    for byte in expected_hex:gmatch("%x%x") do
      expected = expected .. string.char(tonumber(byte, 16) or 0)
    end
    if actual == expected then
      passed = passed + 1
      print("  PASS: " .. msg)
    else
      failed = failed + 1
      print("  FAIL: " .. msg .. ": expected " .. expected_hex .. ", got " .. to_hex(actual))
    end
  end

  local function assert_close(actual, expected, epsilon, msg)
    if math.abs(actual - expected) <= epsilon then
      passed = passed + 1
      print("  PASS: " .. msg)
    else
      failed = failed + 1
      print("  FAIL: " .. msg .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
  end

  local function assert_int64(actual, high, low, msg)
    if type(actual) == "table" and actual[1] == high and actual[2] == low then
      passed = passed + 1
      print("  PASS: " .. msg)
    else
      failed = failed + 1
      local actual_str = type(actual) == "table" and string.format("{0x%X, 0x%X}", actual[1], actual[2])
        or tostring(actual)
      print("  FAIL: " .. msg .. string.format(": expected {0x%X, 0x%X}, got %s", high, low, actual_str))
    end
  end

  local function assert_error(fn, pattern, msg)
    local ok, err = pcall(fn)
    if not ok and type(err) == "string" and string.find(err, pattern) then
      passed = passed + 1
      print("  PASS: " .. msg)
    else
      failed = failed + 1
      print("  FAIL: " .. msg .. (ok and " (no error thrown)" or ": " .. tostring(err)))
    end
  end

  -- ============================================================================
  -- TEST SCHEMA (shared across encode/decode tests)
  -- ============================================================================

  --- @type ProtoSchema
  local Schema = {
    WireType = { VARINT = 0, FIXED64 = 1, LENGTH_DELIMITED = 2, FIXED32 = 5 },
    DataType = {
      DOUBLE = 1,
      FLOAT = 2,
      INT64 = 3,
      UINT64 = 4,
      INT32 = 5,
      FIXED64 = 6,
      FIXED32 = 7,
      BOOL = 8,
      STRING = 9,
      MESSAGE = 11,
      BYTES = 12,
      UINT32 = 13,
      ENUM = 14,
      SFIXED32 = 15,
      SFIXED64 = 16,
      SINT32 = 17,
      SINT64 = 18,
    },
    Enum = {},
    Message = {},
    RPC = {},
  }

  -- Helper to create simple single-field message schemas
  local function make_schema(name, field_name, data_type, wire_type, opts)
    opts = opts or {}
    return {
      name = name,
      options = {},
      fields = {
        [1] = {
          name = field_name,
          type = data_type,
          wireType = wire_type,
          repeated = opts.repeated,
          subschema = opts.subschema,
        },
      },
    }
  end

  -- ============================================================================
  -- VERSION
  -- ============================================================================

  assert_eq(type(pb.version()), "string", "version() returns string")

  -- ============================================================================
  -- VARINT ENCODING (official protobuf spec test vectors)
  -- ============================================================================

  local varint_vectors = {
    { 0, "00" },
    { 1, "01" },
    { 127, "7F" },
    { 128, "8001" },
    { 150, "9601" }, -- from official docs
    { 300, "AC02" },
    { 16383, "FF7F" }, -- max 2-byte
    { 16384, "808001" }, -- first 3-byte
  }
  for _, t in ipairs(varint_vectors) do
    assert_bytes(pb.encode_varint(t[1]), t[2], "varint encode " .. t[1])
  end

  -- Varint roundtrip
  for _, v in ipairs({ 0, 1, 127, 128, 150, 300, 16383, 16384, 65535, 2097151, 268435455, 2 ^ 40 + 12345 }) do
    local enc = pb.encode_varint(v)
    local dec = pb.decode_varint(enc, 1)
    assert_eq(dec, v, "varint roundtrip " .. v)
  end

  -- Varint64 with Int64 values
  local v64 = bit64_new(0x12345678, 0x9ABCDEF0)
  local enc64 = pb.encode_varint(v64)
  local dec64 = pb.decode_varint64(enc64, 1)
  assert_int64(dec64, v64[1], v64[2], "varint64 Int64 roundtrip")
  assert_eq(bit64_is_int64(dec64), true, "decode_varint64 returns marked Int64")

  -- Varint 32-bit boundary values (tests raw bit op signed/unsigned handling)
  for _, v in ipairs({ 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF }) do
    local enc = pb.encode_varint(v)
    local dec = pb.decode_varint(enc, 1)
    assert_eq(dec, v, string.format("varint 0x%X roundtrip", v))
  end

  -- Varint64 with high bits set (tests raw 64-bit op handling)
  local high_bit_values = {
    { 0x80000000, 0x00000000 }, -- bit 63 set
    { 0x80000000, 0x00000001 }, -- bit 63 + low bit
    { 0xFFFFFFFF, 0x00000000 }, -- high word all 1s
    { 0x00000000, 0x80000000 }, -- bit 31 set
  }
  for _, v in ipairs(high_bit_values) do
    local val = bit64_new(v[1], v[2])
    local enc = pb.encode_varint(val)
    local dec = pb.decode_varint64(enc, 1)
    assert_int64(dec, v[1], v[2], string.format("varint64 {0x%X, 0x%X} roundtrip", v[1], v[2]))
  end

  -- ============================================================================
  -- FIXED32 ENCODING
  -- ============================================================================

  local fixed32_vectors = {
    { 0, "00000000" },
    { 1, "01000000" },
    { 12345, "39300000" },
    { 0xFFFFFFFF, "FFFFFFFF" },
  }
  for _, t in ipairs(fixed32_vectors) do
    assert_bytes(pb.encode_fixed32(t[1]), t[2], "fixed32 encode " .. t[1])
    local dec = pb.decode_fixed32(pb.encode_fixed32(t[1]), 1)
    assert_eq(dec, t[1], "fixed32 roundtrip " .. t[1])
  end

  -- ============================================================================
  -- FIXED64 ENCODING
  -- ============================================================================

  local fixed64_vectors = {
    { bit64_new(0, 0), "0000000000000000" },
    { bit64_new(0, 1), "0100000000000000" },
    { bit64_new(0, 0xFFFFFFFF), "FFFFFFFF00000000" },
    { bit64_new(1, 0), "0000000001000000" },
    { bit64_new(0xFFFFFFFF, 0xFFFFFFFF), "FFFFFFFFFFFFFFFF" },
  }
  for _, t in ipairs(fixed64_vectors) do
    assert_bytes(pb.encode_fixed64(t[1]), t[2], string.format("fixed64 encode {0x%X, 0x%X}", t[1][1], t[1][2]))
    local dec = pb.decode_fixed64(pb.encode_fixed64(t[1]), 1)
    assert_int64(dec, t[1][1], t[1][2], string.format("fixed64 roundtrip {0x%X, 0x%X}", t[1][1], t[1][2]))
  end

  -- ============================================================================
  -- FLOAT ENCODING
  -- ============================================================================

  assert_bytes(pb.encode_float(0), "00000000", "float encode 0")
  assert_bytes(pb.encode_float(1.0), "0000803F", "float encode 1.0")

  for _, v in ipairs({ 0.0, 1.0, -1.0, 3.14159, 100.5, -1234.5678, 1e10, -1e-10 }) do
    local dec = pb.decode_float(pb.encode_float(v), 1)
    assert_close(dec, v, 1e-4, "float roundtrip " .. v)
  end

  -- ============================================================================
  -- DOUBLE ENCODING
  -- ============================================================================

  assert_bytes(pb.encode_double(0), "0000000000000000", "double encode 0")
  assert_bytes(pb.encode_double(1.0), "000000000000F03F", "double encode 1.0")

  for _, v in ipairs({ 0.0, 1.0, -1.0, 3.141592653589793, 1e100, -1e-100 }) do
    local dec = pb.decode_double(pb.encode_double(v), 1)
    assert_close(dec, v, 1e-10, "double roundtrip " .. v)
  end

  -- ============================================================================
  -- ZIGZAG ENCODING (official protobuf spec test vectors)
  -- ============================================================================

  local zigzag32_vectors = {
    { 0, 0 },
    { -1, 1 },
    { 1, 2 },
    { -2, 3 },
    { 2147483647, 4294967294 },
    { -2147483648, 4294967295 },
  }
  for _, t in ipairs(zigzag32_vectors) do
    local enc = pb.zigzag_encode32(t[1])
    if enc < 0 then
      enc = enc + 0x100000000
    end
    assert_eq(enc, t[2], "zigzag32 encode " .. t[1])
  end

  for _, v in ipairs({ 0, 1, -1, 100, -100, 2147483647, -2147483648 }) do
    local dec = pb.zigzag_decode32(pb.zigzag_encode32(v))
    assert_eq(dec, v, "zigzag32 roundtrip " .. v)
  end

  -- Additional zigzag32 edge cases (values that produce high-bit-set results)
  for _, v in ipairs({ 0x3FFFFFFF, 0x40000000, -0x40000000, -0x40000001 }) do
    local dec = pb.zigzag_decode32(pb.zigzag_encode32(v))
    assert_eq(dec, v, string.format("zigzag32 edge case %d roundtrip", v))
  end

  local zigzag64_vectors = {
    { bit64_new(0, 0), bit64_new(0, 0) },
    { bit64_new(0xFFFFFFFF, 0xFFFFFFFF), bit64_new(0, 1) },
    { bit64_new(0, 1), bit64_new(0, 2) },
  }
  for _, t in ipairs(zigzag64_vectors) do
    local enc = pb.zigzag_encode64(t[1])
    assert_int64(enc, t[2][1], t[2][2], string.format("zigzag64 encode {0x%X, 0x%X}", t[1][1], t[1][2]))
  end

  local zigzag64_roundtrip = {
    bit64_new(0, 0),
    bit64_new(0xFFFFFFFF, 0xFFFFFFFF),
    bit64_new(0, 1),
    bit64_new(0xFFFFFFFF, 0xFFFFFFFE),
    bit64_new(0x7FFFFFFF, 0xFFFFFFFF),
  }
  for _, v in ipairs(zigzag64_roundtrip) do
    local dec = pb.zigzag_decode64(pb.zigzag_encode64(v))
    assert_int64(dec, v[1], v[2], string.format("zigzag64 roundtrip {0x%X, 0x%X}", v[1], v[2]))
  end

  -- ============================================================================
  -- LENGTH-DELIMITED ENCODING
  -- ============================================================================

  assert_bytes(pb.encode_length_delimited("testing"), "0774657374696E67", "length_delimited 'testing'")

  for _, s in ipairs({ "", "hello", string.rep("x", 1000) }) do
    local dec = pb.decode_length_delimited(pb.encode_length_delimited(s), 1)
    assert_eq(dec, s, "length_delimited roundtrip len=" .. #s)
  end

  -- ============================================================================
  -- INT64 UTILITIES
  -- ============================================================================

  assert_eq(pb.int64_to_hex({ 0x12345678, 0x9ABCDEF0 }), "123456789ABCDEF0", "int64_to_hex")

  local num = 123456789012345
  assert_eq(pb.int64_to_number(pb.int64_from_number(num)), num, "int64 from/to number roundtrip")
  assert_eq(bit64_is_int64(pb.int64_from_number(num)), true, "int64_from_number returns marked Int64")

  assert_eq(pb.int64_equals({ 1, 2 }, { 1, 2 }), true, "int64_equals same")
  assert_eq(pb.int64_equals({ 1, 2 }, { 1, 3 }), false, "int64_equals diff")
  assert_eq(pb.int64_is_zero({ 0, 0 }), true, "int64_is_zero true")
  assert_eq(pb.int64_is_zero({ 0, 1 }), false, "int64_is_zero false")

  assert_error(function()
    pb.int64_to_number(bit64_new(0x00200000, 0), true)
  end, "53%-bit", "int64_to_number strict mode rejects >53-bit")

  -- Int64 vs array distinction
  local int64_val = bit64_new(0, 42)
  local array_val = { 1, 2 }
  assert_eq(bit64_is_int64(int64_val), true, "bit64.is_int64 identifies Int64")
  assert_eq(bit64_is_int64(array_val), false, "bit64.is_int64 rejects plain array")

  -- ============================================================================
  -- MESSAGE ENCODE/DECODE: SCALAR TYPES
  -- ============================================================================

  -- Bool
  local boolSchema = make_schema("Bool", "flag", Schema.DataType.BOOL, Schema.WireType.VARINT)
  for _, v in ipairs({ true, false }) do
    local dec = pb.decode(Schema, boolSchema, pb.encode(Schema, boolSchema, { flag = v }))
    assert_eq(dec.flag, v, "encode/decode bool " .. tostring(v))
  end

  -- Int32
  local int32Schema = make_schema("Int32", "value", Schema.DataType.INT32, Schema.WireType.VARINT)
  for _, v in ipairs({ 0, 1, 127, 128, 65535, 2147483647 }) do
    local dec = pb.decode(Schema, int32Schema, pb.encode(Schema, int32Schema, { value = v }))
    assert_eq(dec.value, v, "encode/decode int32 " .. v)
  end

  -- Uint64
  local uint64Schema = make_schema("Uint64", "value", Schema.DataType.UINT64, Schema.WireType.VARINT)
  local u64 = bit64_new(0x00001800, 0x00001000)
  local decU64 = pb.decode(Schema, uint64Schema, pb.encode(Schema, uint64Schema, { value = u64 }))
  assert_int64(decU64.value, u64[1], u64[2], "encode/decode uint64")

  -- Sint32 (zigzag)
  local sint32Schema = make_schema("Sint32", "value", Schema.DataType.SINT32, Schema.WireType.VARINT)
  for _, v in ipairs({ 0, 1, -1, 100, -100, 2147483647, -2147483648 }) do
    local dec = pb.decode(Schema, sint32Schema, pb.encode(Schema, sint32Schema, { value = v }))
    assert_eq(dec.value, v, "encode/decode sint32 " .. v)
  end

  -- Sint64 (zigzag)
  local sint64Schema = make_schema("Sint64", "value", Schema.DataType.SINT64, Schema.WireType.VARINT)
  for _, t in ipairs({ { bit64_new(0, 0), "0" }, { bit64_new(0, 1), "1" }, { bit64_new(0xFFFFFFFF, 0xFFFFFFFF), "-1" } }) do
    local dec = pb.decode(Schema, sint64Schema, pb.encode(Schema, sint64Schema, { value = t[1] }))
    assert_int64(dec.value, t[1][1], t[1][2], "encode/decode sint64 " .. t[2])
  end

  -- String
  local stringSchema = make_schema("String", "text", Schema.DataType.STRING, Schema.WireType.LENGTH_DELIMITED)
  for _, v in ipairs({ "", "hello", "unicode: \xC3\xA9", string.rep("x", 1000) }) do
    local dec = pb.decode(Schema, stringSchema, pb.encode(Schema, stringSchema, { text = v }))
    assert_eq(dec.text, v, "encode/decode string len=" .. #v)
  end

  -- Float
  local floatSchema = make_schema("Float", "value", Schema.DataType.FLOAT, Schema.WireType.FIXED32)
  for _, v in ipairs({ 0.0, 1.0, -1.0, 3.14159, 1e10 }) do
    local dec = pb.decode(Schema, floatSchema, pb.encode(Schema, floatSchema, { value = v }))
    assert_close(dec.value, v, 1e-4, "encode/decode float " .. v)
  end

  -- Double
  local doubleSchema = make_schema("Double", "value", Schema.DataType.DOUBLE, Schema.WireType.FIXED64)
  for _, v in ipairs({ 0.0, 1.0, -1.0, 3.141592653589793, 1e100 }) do
    local dec = pb.decode(Schema, doubleSchema, pb.encode(Schema, doubleSchema, { value = v }))
    assert_close(dec.value, v, 1e-10, "encode/decode double " .. v)
  end

  -- Fixed32
  local fixed32FieldSchema = make_schema("Fixed32", "value", Schema.DataType.FIXED32, Schema.WireType.FIXED32)
  for _, v in ipairs({ 0, 1, 255, 0xFFFFFFFF }) do
    local dec = pb.decode(Schema, fixed32FieldSchema, pb.encode(Schema, fixed32FieldSchema, { value = v }))
    assert_eq(dec.value, v, "encode/decode fixed32 " .. v)
  end

  -- Fixed64
  local fixed64FieldSchema = make_schema("Fixed64", "value", Schema.DataType.FIXED64, Schema.WireType.FIXED64)
  for _, v in ipairs({ bit64_new(0, 0), bit64_new(0, 1), bit64_new(0xFFFFFFFF, 0xFFFFFFFF) }) do
    local dec = pb.decode(Schema, fixed64FieldSchema, pb.encode(Schema, fixed64FieldSchema, { value = v }))
    assert_int64(dec.value, v[1], v[2], string.format("encode/decode fixed64 {0x%X, 0x%X}", v[1], v[2]))
  end

  -- Enum
  local enumSchema = make_schema("Enum", "status", Schema.DataType.ENUM, Schema.WireType.VARINT)
  for _, v in ipairs({ 0, 1, 2, 100 }) do
    local dec = pb.decode(Schema, enumSchema, pb.encode(Schema, enumSchema, { status = v }))
    assert_eq(dec.status, v, "encode/decode enum " .. v)
  end

  -- Large field numbers (tests raw lshift signed/unsigned handling in key encoding)
  for _, fn in ipairs({ 536870911, 268435455, 100000 }) do
    local largeFieldSchema = {
      name = "LargeField",
      options = {},
      fields = {
        [fn] = { name = "val", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
      },
    }
    local dec = pb.decode(Schema, largeFieldSchema, pb.encode(Schema, largeFieldSchema, { val = 42 }))
    assert_eq(dec.val, 42, "encode/decode field number " .. fn)
  end

  -- ============================================================================
  -- MESSAGE ENCODE/DECODE: REPEATED FIELDS
  -- ============================================================================

  local repeatedSchema =
    make_schema("Repeated", "values", Schema.DataType.INT32, Schema.WireType.VARINT, { repeated = true })
  local vals = { 1, 2, 3, 100, 200 }
  local decR = pb.decode(Schema, repeatedSchema, pb.encode(Schema, repeatedSchema, { values = vals }))
  assert_eq(#decR.values, #vals, "repeated field count")
  for i, v in ipairs(vals) do
    assert_eq(decR.values[i], v, "repeated field[" .. i .. "]")
  end

  -- ============================================================================
  -- MESSAGE ENCODE/DECODE: NESTED MESSAGES
  -- ============================================================================

  -- Single level nesting
  Schema.Message["Inner"] = {
    name = "Inner",
    options = {},
    fields = {
      [1] = { name = "id", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
    },
  }
  local outerSchema =
    make_schema("Outer", "inner", Schema.DataType.MESSAGE, Schema.WireType.LENGTH_DELIMITED, { subschema = "Inner" })
  local decO = pb.decode(Schema, outerSchema, pb.encode(Schema, outerSchema, { inner = { id = 42 } }))
  assert_eq(decO.inner.id, 42, "nested message single level")

  -- Deep nesting (3 levels)
  Schema.Message["L3"] = {
    name = "L3",
    options = {},
    fields = {
      [1] = { name = "val", type = Schema.DataType.STRING, wireType = Schema.WireType.LENGTH_DELIMITED },
    },
  }
  Schema.Message["L2"] = {
    name = "L2",
    options = {},
    fields = {
      [1] = { name = "name", type = Schema.DataType.STRING, wireType = Schema.WireType.LENGTH_DELIMITED },
      [2] = {
        name = "child",
        type = Schema.DataType.MESSAGE,
        wireType = Schema.WireType.LENGTH_DELIMITED,
        subschema = "L3",
      },
    },
  }
  local l1Schema = {
    name = "L1",
    options = {},
    fields = {
      [1] = { name = "id", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
      [2] = {
        name = "child",
        type = Schema.DataType.MESSAGE,
        wireType = Schema.WireType.LENGTH_DELIMITED,
        subschema = "L2",
      },
    },
  }
  local deepMsg = { id = 100, child = { name = "level2", child = { val = "deepest" } } }
  local decD = pb.decode(Schema, l1Schema, pb.encode(Schema, l1Schema, deepMsg))
  assert_eq(decD.id, 100, "deep nested level1.id")
  assert_eq(decD.child.name, "level2", "deep nested level2.name")
  assert_eq(decD.child.child.val, "deepest", "deep nested level3.val")

  -- Repeated nested messages
  Schema.Message["Item"] = {
    name = "Item",
    options = {},
    fields = {
      [1] = { name = "name", type = Schema.DataType.STRING, wireType = Schema.WireType.LENGTH_DELIMITED },
      [2] = { name = "qty", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
    },
  }
  local orderSchema = {
    name = "Order",
    options = {},
    fields = {
      [1] = { name = "id", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
      [2] = {
        name = "items",
        type = Schema.DataType.MESSAGE,
        wireType = Schema.WireType.LENGTH_DELIMITED,
        subschema = "Item",
        repeated = true,
      },
    },
  }
  local orderMsg = { id = 123, items = { { name = "A", qty = 5 }, { name = "B", qty = 3 } } }
  local decOrder = pb.decode(Schema, orderSchema, pb.encode(Schema, orderSchema, orderMsg))
  assert_eq(decOrder.id, 123, "repeated nested order.id")
  assert_eq(#decOrder.items, 2, "repeated nested item count")
  assert_eq(decOrder.items[1].name, "A", "repeated nested item[1].name")
  assert_eq(decOrder.items[2].qty, 3, "repeated nested item[2].qty")

  -- Multiple nested message fields
  Schema.Message["Addr"] = {
    name = "Addr",
    options = {},
    fields = {
      [1] = { name = "street", type = Schema.DataType.STRING, wireType = Schema.WireType.LENGTH_DELIMITED },
      [2] = { name = "city", type = Schema.DataType.STRING, wireType = Schema.WireType.LENGTH_DELIMITED },
    },
  }
  local personSchema = {
    name = "Person",
    options = {},
    fields = {
      [1] = { name = "name", type = Schema.DataType.STRING, wireType = Schema.WireType.LENGTH_DELIMITED },
      [2] = {
        name = "home",
        type = Schema.DataType.MESSAGE,
        wireType = Schema.WireType.LENGTH_DELIMITED,
        subschema = "Addr",
      },
      [3] = {
        name = "work",
        type = Schema.DataType.MESSAGE,
        wireType = Schema.WireType.LENGTH_DELIMITED,
        subschema = "Addr",
      },
    },
  }
  local personMsg =
    { name = "Alice", home = { street = "123 Home", city = "H" }, work = { street = "456 Work", city = "W" } }
  local decP = pb.decode(Schema, personSchema, pb.encode(Schema, personSchema, personMsg))
  assert_eq(decP.name, "Alice", "multi-nested person.name")
  assert_eq(decP.home.city, "H", "multi-nested home.city")
  assert_eq(decP.work.city, "W", "multi-nested work.city")

  -- ============================================================================
  -- EDGE CASES
  -- ============================================================================

  -- Empty message
  local emptyDec = pb.decode(Schema, int32Schema, pb.encode(Schema, int32Schema, {}))
  assert_eq(emptyDec.value, nil, "empty message has nil field")

  -- Unknown field skipping
  local twoField = {
    name = "Two",
    options = {},
    fields = {
      [1] = { name = "a", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
      [2] = { name = "b", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
    },
  }
  local oneField = {
    name = "One",
    options = {},
    fields = {
      [1] = { name = "a", type = Schema.DataType.INT32, wireType = Schema.WireType.VARINT },
    },
  }
  local enc2 = pb.encode(Schema, twoField, { a = 123, b = 456 })
  local dec1 = pb.decode(Schema, oneField, enc2)
  assert_eq(dec1.a, 123, "unknown field skipped, known preserved")

  -- ============================================================================
  -- ERROR HANDLING
  -- ============================================================================

  assert_error(function()
    pb.encode(Schema, repeatedSchema, { values = 123 })
  end, "non%-list", "error: non-list for repeated field")

  assert_error(function()
    pb.encode(Schema, int32Schema, { value = { 1, 2, 3 } })
  end, "not repeated", "error: list for non-repeated field")

  local noSubSchema = make_schema("NoSub", "nested", Schema.DataType.MESSAGE, Schema.WireType.LENGTH_DELIMITED)
  assert_error(function()
    pb.encode(Schema, noSubSchema, { nested = { foo = 1 } })
  end, "no subschema", "error: nested message without subschema")

  -- ============================================================================
  -- SUMMARY
  -- ============================================================================
  print(string.format("\nProtobuf operations: %d/%d tests passed\n", passed, passed + failed))
  return failed == 0
end

return pb
