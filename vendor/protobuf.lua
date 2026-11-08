--- @module "protobuf"
--- A lightweight Protocol Buffers implementation for Lua.
--- This module provides encoding and decoding functions for Protocol Buffers data format.
--- @class protobuf
local pb = {}

local bitn = require("bitn")
local bit32 = bitn.bit32
local bit64 = bitn.bit64

-- Cache methods as locals for faster access
local bit32_le_bytes_to_u32 = bit32.le_bytes_to_u32
local bit32_raw_arshift = bit32.raw_arshift
local bit32_raw_band = bit32.raw_band
local bit32_raw_bor = bit32.raw_bor
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_lshift = bit32.raw_lshift
local bit32_raw_rshift = bit32.raw_rshift
local bit32_to_signed = bit32.to_signed
local bit32_to_unsigned = bit32.to_unsigned
local bit32_u32_to_le_bytes = bit32.u32_to_le_bytes
local bit64_eq = bit64.eq
local bit64_from_number = bit64.from_number
local bit64_is_int64 = bit64.is_int64
local bit64_is_zero = bit64.is_zero
local bit64_le_bytes_to_u64 = bit64.le_bytes_to_u64
local bit64_new = bit64.new
local bit64_raw_arshift = bit64.raw_arshift
local bit64_raw_bor = bit64.raw_bor
local bit64_raw_bxor = bit64.raw_bxor
local bit64_raw_lshift = bit64.raw_lshift
local bit64_raw_rshift = bit64.raw_rshift
local bit64_to_hex = bit64.to_hex
local bit64_to_number = bit64.to_number
local bit64_u64_to_le_bytes = bit64.u64_to_le_bytes

-- Lua 5.3+ removed math.frexp and math.ldexp; provide polyfills
local math_frexp = math.frexp
  or function(x)
    if x == 0 or x ~= x or x == math.huge or x == -math.huge then
      return x, 0
    end
    local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1
    -- Scaling by a power of two is exact, but only while that power is itself a
    -- normal double. 2 ^ -e is infinity by e = -1024 and subnormal by e = 1023,
    -- and LuaJIT 2.0 returns zero for the subnormal end rather than the exact
    -- value. Split the scale so neither factor ever leaves the normal range.
    local m
    if e > 1000 then
      m = x * 2 ^ -1000 * 2 ^ (1000 - e)
    elseif e < -1000 then
      m = x * 2 ^ 1000 * 2 ^ (-e - 1000)
    else
      m = x * 2 ^ -e
    end
    -- The log quotient lands on the wrong side of an integer for some inputs,
    -- which puts m outside [0.5, 1). Left uncorrected it reaches exactly 1.0 and
    -- overflows the mantissa field downstream.
    while m ~= 0 and (m >= 1 or m <= -1) do
      m = m / 2
      e = e + 1
    end
    while m ~= 0 and m > -0.5 and m < 0.5 do
      m = m * 2
      e = e - 1
    end
    return m, e
  end
local math_ldexp = math.ldexp
  or function(m, e)
    -- Same constraint as the frexp fallback above: 2 ^ e is only exact while it
    -- is itself a normal double, and LuaJIT 2.0 returns zero at the subnormal
    -- end. Step the scale in normal-range chunks so a representable result is
    -- never reached through an intermediate infinity or zero.
    while e > 1000 do
      m = m * 2 ^ 1000
      e = e - 1000
    end
    while e < -1000 do
      m = m * 2 ^ -1000
      e = e + 1000
    end
    return m * 2 ^ e
  end

--- Rounds to the nearest integer with ties to even, which is the IEEE 754 default and
--- the rule the hardware applies when it narrows a double to a float.
--- @param x number A non-negative value below 2 ^ 53, so `x - floor(x)` is exact.
--- @return number rounded
local function round_half_even(x)
  local lower = math.floor(x)
  local fraction = x - lower
  if fraction > 0.5 then
    return lower + 1
  elseif fraction < 0.5 then
    return lower
  elseif lower % 2 == 0 then
    return lower
  end
  return lower + 1
end

-- The smallest normal at each width. Below these an IEEE value is subnormal: no
-- implicit leading one, and an exponent pinned at the minimum instead of scaling.
local FLOAT_MIN_NORMAL = 2 ^ -126
local DOUBLE_MIN_NORMAL = 2 ^ -1022

local NAN = 0 / 0
local INF = math.huge
-- Lua 5.1 constant-folds the literal -0.0 to +0.0, and LuaJIT does the same to
-- 0.0 * -1. Dividing into an infinity is the one form that survives everywhere.
local NEG_ZERO = -1 / INF

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
local VERSION = "v0.7.0"

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
      local byte = bit32_raw_band(v[2], 0x7F)

      -- Right shift by 7 bits using bit64
      v = bit64_raw_rshift(v, 7)

      -- Set continue bit if more bytes remain
      if v[1] ~= 0 or v[2] ~= 0 then
        byte = bit32_raw_bor(byte, 0x80)
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
  local v = bit64_from_number(value)
  local bytes = {}

  repeat
    local byte = bit32_raw_band(v[2], 0x7F)
    v = bit64_raw_rshift(v, 7)
    if v[1] ~= 0 or v[2] ~= 0 then
      byte = bit32_raw_bor(byte, 0x80)
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
  if value < -0x80000000 or value > 0xFFFFFFFF then
    error("fixed32 value out of range: " .. tostring(value), 2)
  end
  return bit32_u32_to_le_bytes(value)
end

--- Decodes a fixed-length 4-byte sequence into a 32-bit integer.
--- @param buffer string The buffer containing the encoded fixed32.
--- @param pos integer The position in the buffer to start decoding from.
--- @return integer value The decoded 32-bit integer value.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_fixed32(buffer, pos)
  return bit32_le_bytes_to_u32(buffer, pos), pos + 4
end

--- Encodes a 64-bit integer into a fixed-length 8-byte sequence.
--- @param value Int64HighLow|number The 64-bit integer as {high, low} or number.
--- @return string bytes The encoded 8-byte sequence.
function pb.encode_fixed64(value)
  return bit64_u64_to_le_bytes(bit64_from_number(value))
end

--- Decodes a fixed-length 8-byte sequence into a 64-bit integer.
--- @param buffer string The buffer containing the encoded fixed64.
--- @param pos integer The position in the buffer to start decoding from.
--- @return Int64HighLow value The decoded 64-bit value as {high_32, low_32}.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_fixed64(buffer, pos)
  return bit64_le_bytes_to_u64(buffer, pos), pos + 8
end

--- Encodes a floating-point number into a 4-byte IEEE 754 single-precision format.
--- @param value number The floating-point number to encode.
--- @return string bytes The encoded 4-byte sequence.
function pb.encode_float(value)
  -- The frexp path below cannot represent these: it reads a non-finite as a
  -- mantissa of 1 and an exponent of 0, so every one of them encoded as 0.5.
  -- Emitted as the canonical patterns any conformant parser produces.
  if value ~= value then
    return string.char(0x00, 0x00, 0xC0, 0x7F)
  elseif value == INF then
    return string.char(0x00, 0x00, 0x80, 0x7F)
  elseif value == -INF then
    return string.char(0x00, 0x00, 0x80, 0xFF)
  end

  if value == 0 then
    -- -0.0 == 0, so the sign is only observable through the reciprocal.
    if 1 / value < 0 then
      return string.char(0x00, 0x00, 0x00, 0x80)
    end
    return string.char(0, 0, 0, 0)
  end

  local sign = 0
  if value < 0 then
    sign = 1
    value = -value
  end

  local e, m
  if value < FLOAT_MIN_NORMAL then
    -- Subnormal: the mantissa is the whole value counted in units of the smallest
    -- one, since there is no implicit leading bit to subtract off.
    e = 0
    m = round_half_even(math_ldexp(value, 149))
  else
    local mantissa, exponent = math_frexp(value)
    e = exponent - 1 + 127
    if e >= 255 then
      -- 255 is the all-ones exponent, so it has to be reached by clamping too:
      -- leaving it to a finite input would emit a nonzero mantissa, i.e. a NaN.
      e = 255
      m = 0
    else
      m = round_half_even((mantissa * 2 - 1) * 0x800000)
    end
  end

  -- Rounding to nearest can carry out of the mantissa. Bit 23 of m lands on the
  -- exponent's low bit below, which is the wanted answer in both bands: a subnormal
  -- carries into the smallest normal, a normal into the next binade, and the largest
  -- finite into the all-ones exponent, i.e. infinity.
  if m >= 0x800000 then
    m = 0
    e = e + 1
  end

  local word = bit32_raw_bor(bit32_raw_lshift(sign, 31), bit32_raw_lshift(e, 23))
  return bit32_u32_to_le_bytes(bit32_raw_bor(word, m))
end

--- Decodes a 4-byte IEEE 754 single-precision format into a floating-point number.
--- @param buffer string The buffer containing the encoded float.
--- @param pos integer The position in the buffer to start decoding from.
--- @return number value The decoded floating-point value.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_float(buffer, pos)
  local word = bit32_le_bytes_to_u32(buffer, pos)

  local sign = bit32_raw_rshift(word, 31)
  local e = bit32_raw_band(bit32_raw_rshift(word, 23), 0xFF)
  local m = bit32_raw_band(word, 0x7FFFFF)

  if e == 0 and m == 0 then
    return sign == 1 and NEG_ZERO or 0, pos + 4
  end

  -- IEEE 754 reserves an all-ones exponent for the non-finite values: infinity
  -- when the mantissa is zero, NaN otherwise. Without this the mantissa term is
  -- scaled by 2^128 and a NaN comes back as a plausible finite reading.
  if e == 255 then
    if m == 0 then
      return sign == 1 and -INF or INF, pos + 4
    end
    return NAN, pos + 4
  end

  -- A subnormal carries no implicit leading one and sits at the minimum exponent
  -- rather than at the bias.
  local result
  if e == 0 then
    result = math_ldexp(m / 0x800000, -126)
  else
    result = math_ldexp(1 + m / 0x800000, e - 127)
  end
  if sign == 1 then
    result = -result
  end

  return result, pos + 4
end

--- Encodes a double-precision floating-point number into an 8-byte IEEE 754 format.
--- @param value number The double-precision floating-point number to encode.
--- @return string bytes The encoded 8-byte sequence.
function pb.encode_double(value)
  -- Non-finite, as in encode_float.
  if value ~= value then
    return string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x7F)
  elseif value == INF then
    return string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x7F)
  elseif value == -INF then
    return string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xFF)
  end

  if value == 0 then
    if 1 / value < 0 then
      return string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80)
    end
    return string.char(0, 0, 0, 0, 0, 0, 0, 0)
  end

  local sign = 0
  if value < 0 then
    sign = 1
    value = -value
  end

  -- 52 bits of mantissa either way: 20 in high, 32 in low.
  local e, m
  if value < DOUBLE_MIN_NORMAL then
    -- Subnormal, as in encode_float. No rounding: a double below this boundary is
    -- already a whole multiple of the smallest subnormal, so the scale is exact.
    e = 0
    m = bit64_from_number(math_ldexp(value, 1074))
  else
    local mantissa, exponent = math_frexp(value)
    e = exponent - 1 + 1023
    if e > 2047 then
      e = 2047
      m = bit64_from_number(0)
    else
      m = bit64_from_number((mantissa * 2 - 1) * 0x10000000000000)
    end
  end
  local high = bit32_raw_bor(bit32_raw_lshift(sign, 31), bit32_raw_lshift(e, 20))
  m[1] = bit32_raw_bor(high, bit32_raw_band(m[1], 0xFFFFF))
  return bit64_u64_to_le_bytes(m)
end

--- Decodes an 8-byte IEEE 754 double-precision format into a floating-point number.
--- @param buffer string The buffer containing the encoded double.
--- @param pos integer The position in the buffer to start decoding from.
--- @return number value The decoded double-precision floating-point value.
--- @return integer new_pos The new position in the buffer after decoding.
function pb.decode_double(buffer, pos)
  local word = bit64_le_bytes_to_u64(buffer, pos)
  local high = word[1]

  local sign = bit32_raw_rshift(high, 31)
  local e = bit32_raw_band(bit32_raw_rshift(high, 20), 0x7FF)
  word[1] = bit32_raw_band(high, 0xFFFFF)
  local m = bit64_to_number(word)

  if e == 0 and m == 0 then
    return sign == 1 and NEG_ZERO or 0, pos + 8
  end

  -- Non-finite, as in decode_float. Here the 2^1024 scale overflows to infinity
  -- instead, so an unhandled NaN was indistinguishable from a real infinity.
  if e == 2047 then
    if m == 0 then
      return sign == 1 and -INF or INF, pos + 8
    end
    return NAN, pos + 8
  end

  -- Subnormal, as in decode_float.
  local result
  if e == 0 then
    result = math_ldexp(m / 0x10000000000000, -1022)
  else
    result = math_ldexp(1 + m / 0x10000000000000, e - 1023)
  end
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
  return bit32_to_signed(bit32_raw_bxor(bit32_raw_rshift(value, 1), -bit32_raw_band(value, 1)))
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

--- Decodes one non-length-delimited value off the wire.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param fieldType integer The field's data type, which selects among the wire type's readings.
--- @param wireType integer The wire type to read as.
--- @param buffer string The encoded bytes.
--- @param pos integer The position to read from.
--- @return any value The decoded value.
--- @return integer pos The position after the value.
local function decode_scalar(protoSchema, fieldType, wireType, buffer, pos)
  local value
  if wireType == protoSchema.WireType.VARINT then
    -- Use 64-bit decoder for types that need full precision
    if fieldType == protoSchema.DataType.UINT64 or fieldType == protoSchema.DataType.INT64 then
      value, pos = pb.decode_varint64(buffer, pos)
    elseif fieldType == protoSchema.DataType.SINT64 then
      local raw
      raw, pos = pb.decode_varint64(buffer, pos)
      value = pb.zigzag_decode64(raw)
    elseif fieldType == protoSchema.DataType.SINT32 then
      local raw
      raw, pos = pb.decode_varint64(buffer, pos)
      value = pb.zigzag_decode32(raw[2])
    elseif fieldType == protoSchema.DataType.BOOL then
      value, pos = pb.decode_varint(buffer, pos)
      value = value ~= 0 -- Convert to boolean
    elseif fieldType == protoSchema.DataType.UINT32 then
      local raw
      raw, pos = pb.decode_varint64(buffer, pos)
      value = raw[2]
    else
      -- INT32, ENUM: truncated to the low word, so 0xFFFFFFFF reads as -1.
      local raw
      raw, pos = pb.decode_varint64(buffer, pos)
      value = bit32_to_signed(raw[2])
    end
  elseif wireType == protoSchema.WireType.FIXED64 then
    if fieldType == protoSchema.DataType.DOUBLE then
      value, pos = pb.decode_double(buffer, pos)
    else
      -- FIXED64, SFIXED64
      value, pos = pb.decode_fixed64(buffer, pos)
    end
  elseif wireType == protoSchema.WireType.FIXED32 then
    if fieldType == protoSchema.DataType.FLOAT then
      value, pos = pb.decode_float(buffer, pos)
    elseif fieldType == protoSchema.DataType.SFIXED32 then
      value, pos = pb.decode_fixed32(buffer, pos)
      value = bit32_to_signed(value)
    else
      -- FIXED32
      value, pos = pb.decode_fixed32(buffer, pos)
    end
  else
    error("Unsupported wire type: " .. wireType)
  end
  return value, pos
end

--- Decodes a packed repeated scalar block into its elements.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param field ProtoFieldSchema The repeated field, whose wireType is the element's.
--- @param data string The block's bytes, with the length prefix already consumed.
--- @return any[] values The decoded elements.
local function decode_packed(protoSchema, field, data)
  local values = {}
  local pos = 1
  local value
  while pos <= #data do
    value, pos = decode_scalar(protoSchema, field.type, field.wireType, data, pos)
    values[#values + 1] = value
  end
  return values
end

--- Returns a map entry's key and value field schemas.
--- @param entrySchema ProtoMessageSchema The entry message a map field's subschema names.
--- @return ProtoFieldSchema keyField The entry's key field.
--- @return ProtoFieldSchema valueField The entry's value field.
local function map_entry_fields(entrySchema)
  -- protobuf fixes a synthesized map entry's field numbers: the key is 1, the value 2.
  return entrySchema.fields[1], entrySchema.fields[2]
end

--- Returns the protobuf default for a field's type.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param field ProtoFieldSchema The field whose type supplies the default.
--- @return any value The type's default value.
local function default_value(protoSchema, field)
  local dataType = protoSchema.DataType
  local fieldType = field.type
  if fieldType == dataType.STRING or fieldType == dataType.BYTES then
    return ""
  elseif fieldType == dataType.BOOL then
    return false
  elseif fieldType == dataType.MESSAGE then
    return {}
  elseif
    fieldType == dataType.INT64
    or fieldType == dataType.UINT64
    or fieldType == dataType.SINT64
    or fieldType == dataType.FIXED64
    or fieldType == dataType.SFIXED64
  then
    -- Matches decode, which returns these five as Int64 tables rather than numbers.
    return bit64_new(0, 0)
  end
  return 0
end

local function ascending(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return ta < tb
  elseif ta == "table" then
    -- Unsigned high word, so negative 64-bit keys sort after positive ones: deterministic, not numeric.
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  elseif ta == "boolean" then
    return b and not a
  end
  return a < b
end

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  table.sort(keys, ascending)
  return keys
end

--- Encodes a map field as the repeated key/value entry messages it is on the wire.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param field ProtoFieldSchema The map field's schema.
--- @param field_number integer The field's number.
--- @param entries table<any, any> The map to encode.
--- @return string buffer The encoded entries.
local function encode_map(protoSchema, field, field_number, entries)
  if type(entries) ~= "table" or bit64_is_int64(entries) then
    error("Field '" .. field.name .. "' is a map but received a non-table value.")
  end

  local entrySchema = protoSchema.Message[field.subschema]
  local keyField, valueField = map_entry_fields(entrySchema)
  local wire_type = field.wireType
  --- @cast wire_type integer
  local key = bit32_to_unsigned(bit32_raw_lshift(field_number, 3)) + wire_type

  local buffer = ""
  for _, entry_key in ipairs(sorted_keys(entries)) do
    local entry_value = entries[entry_key]
    local entry = pb.encode(protoSchema, entrySchema, {
      [keyField.name] = entry_key,
      [valueField.name] = entry_value,
    })
    buffer = buffer .. pb.encode_varint(key) .. pb.encode_length_delimited(entry)
  end
  return buffer
end

--- Encodes a message according to a schema.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param messageSchema ProtoMessageSchema The message schema to use for encoding.
--- @param message table<string, any> The message body to encode.
--- @return string buffer The encoded message.
function pb.encode(protoSchema, messageSchema, message)
  local buffer = ""

  for _, field_number in ipairs(sorted_keys(messageSchema.fields)) do
    local field = messageSchema.fields[field_number]
    local values = message[field.name]
    if values ~= nil and field.map then
      buffer = buffer .. encode_map(protoSchema, field, field_number, values)
    elseif values ~= nil then
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
      -- Held in a local because `@cast` applies to locals, not table fields.
      local wire_type = field.wireType
      --- @cast wire_type integer
      for _, value in ipairs(values) do
        -- Compute the key (field number and wire type)
        -- Use to_unsigned since large field numbers produce high-bit-set results
        local key = bit32_to_unsigned(bit32_raw_lshift(field_number, 3)) + wire_type
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
          else
            -- The tag is already written; without this a non-string/table value
            -- would emit a bare tag with no length or payload, silently truncating
            -- the stream instead of failing like the varint/fixed paths do.
            error(
              "Field '"
                .. field.name
                .. "' is length-delimited (string, bytes, or message) but received a "
                .. type(value)
                .. "."
            )
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
      local packed
      -- Decode the value based on the wire type
      if wire_type == protoSchema.WireType.LENGTH_DELIMITED then
        local data
        data, pos = pb.decode_length_delimited(buffer, pos)
        -- proto3 packs a repeated scalar by default: the tag carries the block's wire
        -- type, so the element's is the schema's.
        if field.repeated and field.wireType ~= protoSchema.WireType.LENGTH_DELIMITED then
          packed = decode_packed(protoSchema, field, data)
        elseif field.subschema then
          value = pb.decode(protoSchema, protoSchema.Message[field.subschema], data)
        else
          value = data
        end
      else
        value, pos = decode_scalar(protoSchema, field.type, wire_type, buffer, pos)
      end

      if packed then
        -- One field may arrive as several blocks, or mix packed and unpacked, so append.
        local list = message[field.name]
        if list == nil then
          list = {}
          message[field.name] = list
        end
        for _, element in ipairs(packed) do
          list[#list + 1] = element
        end
      elseif field.map then
        if message[field.name] == nil then
          message[field.name] = {}
        end
        local keyField, valueField = map_entry_fields(protoSchema.Message[field.subschema])
        local entry_key = value[keyField.name]
        local entry_value = value[valueField.name]
        -- An entry may omit either side when it holds the type's zero value.
        if entry_key == nil then
          entry_key = default_value(protoSchema, keyField)
        end
        if entry_value == nil then
          entry_value = default_value(protoSchema, valueField)
        end
        message[field.name][entry_key] = entry_value
      elseif field.repeated then
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

-- Whichever frexp/ldexp the module bound at load. Exposed so the fallbacks can
-- be compared against a native implementation directly; the codecs only reach
-- them over the argument range the wire format produces, which is narrower than
-- the range the fallbacks have to be correct over.
pb._math = { frexp = math_frexp, ldexp = math_ldexp }

return pb
