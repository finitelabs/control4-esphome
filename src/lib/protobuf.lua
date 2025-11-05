--- @module "lib.protobuf"
--- A lightweight Protocol Buffers implementation for Lua.
--- This module provides encoding and decoding functions for Protocol Buffers data format.
local bit = require("bit")

--- @class Protobuf
--- A class providing Protocol Buffers encoding and decoding functionality.
local Protobuf = {}

--- Encodes an integer into a varint byte sequence.
--- @param value number|boolean The value to encode.
--- @return string bytes The encoded varint byte sequence.
function Protobuf.encode_varint(value)
  local bytes = {}
  if type(value) == "boolean" then
    value = value and 1 or 0
  end

  -- For values that fit in 32 bits, use bit operations for efficiency
  -- Otherwise use math operations to handle 64-bit values
  local use_bit_ops = value >= 0 and value < 0x100000000  -- 2^32

  repeat
    local byte
    if use_bit_ops then
      byte = bit.band(value, 0x7F)
      value = bit.rshift(value, 7)
    else
      -- Use math operations for large 64-bit values
      byte = value % 128  -- Equivalent to bit.band(value, 0x7F)
      value = math.floor(value / 128)  -- Equivalent to bit.rshift(value, 7)
    end

    if value > 0 then
      byte = byte + 0x80  -- Mark this byte as "continued"
    end
    table.insert(bytes, string.char(byte))
  until value == 0
  return table.concat(bytes)
end

--- Decodes a varint byte sequence into an integer.
--- @param buffer string The buffer containing the encoded varint.
--- @param pos integer The position in the buffer to start decoding from.
--- @return integer value The decoded integer value.
--- @return integer new_pos The new position in the buffer after decoding.
function Protobuf.decode_varint(buffer, pos)
  local result = 0
  local shift = 0
  local byte
  local byte_count = 0

  repeat
    byte = string.byte(buffer, pos)
    byte_count = byte_count + 1

    -- Use bit operations for the first 4 bytes (28 bits), then switch to math
    -- operations to handle 64-bit values
    if shift < 28 then
      result = result + bit.lshift(bit.band(byte, 0x7F), shift)
    else
      -- Use math operations for high-order bits to avoid overflow
      local value_bits = byte % 128  -- bit.band(byte, 0x7F)
      result = result + (value_bits * (2 ^ shift))
    end

    shift = shift + 7
    pos = pos + 1
  until byte < 128  -- Continue while bit 7 is set (byte >= 0x80)

  return result, pos
end

--- Encodes a 32-bit integer into a fixed-length 4-byte sequence.
--- @param value integer The 32-bit integer to encode.
--- @return string bytes The encoded 4-byte sequence.
function Protobuf.encode_fixed32(value)
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
function Protobuf.decode_fixed32(buffer, pos)
  local b1, b2, b3, b4 = string.byte(buffer, pos, pos + 3)
  local value = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  --- @cast value integer
  return value, pos + 4
end

--- Encodes a floating-point number into a 4-byte IEEE 754 single-precision format.
--- @param value number The floating-point number to encode.
--- @return string bytes The encoded 4-byte sequence.
function Protobuf.encode_float(value)
  if value == 0 then
    return string.char(0, 0, 0, 0)
  end

  local sign = 0
  if value < 0 then
    sign = 1
    value = -value
  end

  --- @diagnostic disable-next-line: undefined-field
  local mantissa, exponent = math.frexp(value)
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
  local b3 = bit.bor(math.floor(m / 65536), bit.lshift(e % 2, 7))
  local b4 = bit.bor(bit.rshift(e, 1), bit.lshift(sign, 7))

  return string.char(b1, b2, b3, b4)
end

--- Decodes a 4-byte IEEE 754 single-precision format into a floating-point number.
--- @param buffer string The buffer containing the encoded float.
--- @param pos integer The position in the buffer to start decoding from.
--- @return number value The decoded floating-point value.
--- @return integer new_pos The new position in the buffer after decoding.
function Protobuf.decode_float(buffer, pos)
  local b1, b2, b3, b4 = string.byte(buffer, pos, pos + 3)

  local sign = bit.rshift(b4, 7)
  local e = bit.lshift(bit.band(b4, 0x7F), 1) + bit.rshift(b3, 7)
  local m = bit.band(b3, 0x7F) * 65536 + b2 * 256 + b1

  if e == 0 and m == 0 then
    return 0, pos + 4
  end

  --- @diagnostic disable-next-line: undefined-field
  local value = math.ldexp(1 + m / 0x800000, e - 127)
  if sign == 1 then
    value = -value
  end

  return value, pos + 4
end

--- Encodes a length-delimited field (string or nested message).
--- @param data string The data to encode.
--- @return string bytes The encoded length-delimited data.
function Protobuf.encode_length_delimited(data)
  return Protobuf.encode_varint(#data) .. data
end

--- Decodes a length-delimited field.
--- @param buffer string The buffer containing the encoded length-delimited data.
--- @param pos integer The position in the buffer to start decoding from.
--- @return string data The decoded data.
--- @return integer new_pos The new position in the buffer after decoding.
function Protobuf.decode_length_delimited(buffer, pos)
  local length, new_pos = Protobuf.decode_varint(buffer, pos)
  local data = string.sub(buffer, new_pos, new_pos + length - 1)
  return data, new_pos + length
end

--- Encodes a message according to a schema.
--- @param protoSchema ProtoSchema The complete proto schema.
--- @param messageSchema ProtoMessageSchema The message schema to use for encoding.
--- @param message table<string, any> The message body to encode.
--- @return string buffer The encoded message.
function Protobuf.encode(protoSchema, messageSchema, message)
  local buffer = ""

  for field_number, field in pairs(messageSchema.fields) do
    local values = message[field.name]
    if values ~= nil then
      if field.repeated then
        if not IsList(values) then
          error("Field '" .. field.name .. "' is repeated but received a non-list value.")
        end
      else
        if IsList(values) then
          error("Field '" .. field.name .. "' is not repeated but received a list.")
        end
        values = { values } -- Wrap single value in a list for uniform processing
      end
      for _, value in ipairs(values) do
        -- Compute the key (field number and wire type)
        local key = bit.lshift(field_number, 3) + field.wireType
        buffer = buffer .. Protobuf.encode_varint(key)

        if field.wireType == protoSchema.WireType.VARINT then
          buffer = buffer .. Protobuf.encode_varint(value)
        elseif field.wireType == protoSchema.WireType.FIXED32 then
          if field.type == protoSchema.DataType.FLOAT then
            buffer = buffer .. Protobuf.encode_float(value)
          else
            buffer = buffer .. Protobuf.encode_fixed32(value)
          end
        elseif field.wireType == protoSchema.WireType.LENGTH_DELIMITED then
          if type(value) == "string" then
            buffer = buffer .. Protobuf.encode_length_delimited(value)
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
            local nested_message = Protobuf.encode(protoSchema, field.subschema, value)
            buffer = buffer .. Protobuf.encode_length_delimited(nested_message)
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
function Protobuf.decode(protoSchema, messageSchema, buffer)
  --- @type integer
  local pos = 1
  local message = {}

  local key
  while pos <= #buffer do
    -- Decode the key (field number and wire type)
    key, pos = Protobuf.decode_varint(buffer, pos)
    local field_number = bit.rshift(key, 3)
    local wire_type = bit.band(key, 0x7)

    -- Find the corresponding field in the schema
    local field = messageSchema.fields[field_number]
    if not field then
      -- Skip unknown field based on wire type
      if wire_type == protoSchema.WireType.VARINT then
        -- Decode and discard the varint
        local _
        _, pos = Protobuf.decode_varint(buffer, pos)
      elseif wire_type == protoSchema.WireType.FIXED32 then
        -- Skip 4 bytes
        pos = pos + 4
      elseif wire_type == protoSchema.WireType.LENGTH_DELIMITED then
        -- Decode length and skip that many bytes
        local length
        length, pos = Protobuf.decode_varint(buffer, pos)
        pos = pos + length
      else
        error("Unknown wire type: " .. wire_type)
      end
    else
      -- Known field - decode and store the value
      local value
      -- Decode the value based on the wire type
      if wire_type == protoSchema.WireType.VARINT then
        value, pos = Protobuf.decode_varint(buffer, pos)
        if field.type == protoSchema.DataType.BOOL then
          value = value ~= 0 -- Convert to boolean
        end
      elseif wire_type == protoSchema.WireType.FIXED32 then
        if field.type == protoSchema.DataType.FLOAT then
          value, pos = Protobuf.decode_float(buffer, pos)
        else
          value, pos = Protobuf.decode_fixed32(buffer, pos)
        end
      elseif wire_type == protoSchema.WireType.LENGTH_DELIMITED then
        local data
        data, pos = Protobuf.decode_length_delimited(buffer, pos)
        if field.subschema then
          value, _ = Protobuf.decode(protoSchema, field.subschema, data)
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

--- === Test Suite ===
--- Runs tests to verify the functionality of the Protobuf module.
--- This function tests encoding and decoding of various data types.
--function run_tests()
--  --- Asserts that two values are equal.
--  --- @param a any The first value.
--  --- @param b any The second value.
--  --- @param msg? string The error message (optional).
--  local function assert_equal(a, b, msg)
--    if a ~= b then
--      error("Assertion failed: " .. tostring(a) .. " ~= " .. tostring(b) .. " | " .. (msg or ""), 2)
--    end
--  end
--
--  --- Asserts that two floating-point values are approximately equal.
--  --- @param a number The first value.
--  --- @param b number The second value.
--  --- @param epsilon? number The maximum allowed difference (optional, default: 1e-6).
--  --- @param msg? string The error message (optional).
--  local function assert_close(a, b, epsilon, msg)
--    if math.abs(a - b) > (epsilon or 1e-6) then
--      error("Assertion failed: " .. tostring(a) .. " not close to " .. tostring(b) .. " | " .. (msg or ""), 2)
--    end
--  end
--
--  --- Asserts that two tables are equal (shallow comparison).
--  --- @param a table The first table.
--  --- @param b table The second table.
--  --- @param msg? string The error message (optional).
--  local function assert_table_equal(a, b, msg)
--    if #a ~= #b then
--      error("Assertion failed: tables have different lengths | " .. (msg or ""), 2)
--    end
--    for i = 1, #a do
--      if type(a[i]) == "number" and type(b[i]) == "number" and math.abs(a[i] - b[i]) <= 1e-6 then
--        -- Float comparison
--        -- Skip, it's close enough
--      elseif a[i] ~= b[i] then
--        error(
--          "Assertion failed: tables differ at index "
--            .. i
--            .. " ("
--            .. tostring(a[i])
--            .. " vs "
--            .. tostring(b[i])
--            .. ") | "
--            .. (msg or ""),
--          2
--        )
--      end
--    end
--  end
--
--  -- Varint
--  for _, v in ipairs({ 0, 1, 127, 128, 300, 65535 }) do --, 2 ^ 32 - 1 }) do
--    local enc = Protobuf.encode_varint(v)
--    local dec, _ = Protobuf.decode_varint(enc, 1)
--    assert_equal(dec, v, "Varint mismatch for " .. v)
--  end
--
--  ---- 64-bit
--  --local val64 = 2^40 + 12345678
--  --local enc64 = encode_64bit(val64)
--  --local dec64, _ = decode_64bit(enc64)
--  --assert_equal(dec64, val64, "64-bit mismatch")
--
--  -- 32-bit
--  local val32 = 1234567890
--  local enc32 = Protobuf.encode_fixed32(val32)
--  local dec32, _ = Protobuf.decode_fixed32(enc32, 1)
--  assert_equal(dec32, val32, "32-bit mismatch")
--
--  -- Float
--  for _, v in ipairs({ 0.0, 1.0, -1.0, 3.14159, 51.0, 1234.5678 }) do
--    local enc = Protobuf.encode_float(v)
--    local dec, _ = Protobuf.decode_float(enc, 1)
--    assert_close(dec, v, 1e-4, "Float mismatch for " .. v)
--    print("Float test: " .. v .. " encoded and decoded as " .. dec)
--  end
--
--  -- Length-delimited
--  local str = "hello world"
--  local enc2 = Protobuf.encode_length_delimited(str)
--  local dec2, _ = Protobuf.decode_length_delimited(enc2, 1)
--  assert_equal(dec2, str, "Length-delimited mismatch")
--
--  local message = {
--    id = 1,
--    name = "Test",
--    value = 42,
--    nested = {
--      id = 2,
--      name = "Nested",
--      value = 100,
--    },
--  }
--  local schema = {
--    fields = {
--      [1] = { name = "id", wireType = Protobuf.WireType.VARINT },
--      [2] = { name = "name", wireType = Protobuf.WireType.LENGTH_DELIMITED },
--      [3] = { name = "value", wireType = Protobuf.WireType.FIXED32 },
--      [4] = {
--        name = "nested",
--        wireType = Protobuf.WireType.LENGTH_DELIMITED,
--        subschema = {
--          fields = {
--            [1] = { name = "id", wireType = Protobuf.WireType.VARINT },
--            [2] = { name = "name", wireType = Protobuf.WireType.LENGTH_DELIMITED },
--            [3] = { name = "value", wireType = Protobuf.WireType.FIXED32 },
--          },
--        },
--      },
--    },
--  }
--  local encoded_message = Protobuf.encode(schema, message)
--  local decoded_message = Protobuf.decode(schema, encoded_message)
--  assert_equal(decoded_message.id, message.id, "ID mismatch")
--  assert_equal(decoded_message.name, message.name, "Name mismatch")
--  assert_equal(decoded_message.value, message.value, "Value mismatch")
--  assert_equal(decoded_message.nested.id, message.nested.id, "Nested ID mismatch")
--  assert_equal(decoded_message.nested.name, message.nested.name, "Nested Name mismatch")
--  assert_equal(decoded_message.nested.value, message.nested.value, "Nested Value mismatch")
--
--  -- Test repeated fields
--  print("Testing repeated fields...")
--
--  -- Test repeated primitive types
--  local repeated_message = {
--    int_array = { 1, 2, 3, 4, 5 },
--    float_array = { 1.1, 2.2, 3.3, 4.4, 5.5 },
--    bool_array = { true, false, true },
--    string_array = { "one", "two", "three" },
--  }
--
--  local repeated_schema = {
--    fields = {
--      [1] = { name = "int_array", wireType = Protobuf.WireType.VARINT, type = Protobuf.DataType.INT32, repeated = true },
--      [2] = { name = "float_array", wireType = Protobuf.WireType.FIXED32, type = Protobuf.DataType.FLOAT, repeated = true },
--      [3] = { name = "bool_array", wireType = Protobuf.WireType.VARINT, type = Protobuf.DataType.BOOL, repeated = true },
--      [4] = {
--        name = "string_array",
--        wireType = Protobuf.WireType.LENGTH_DELIMITED,
--        type = Protobuf.DataType.STRING,
--        repeated = true,
--      },
--    },
--  }
--
--  local encoded_repeated = Protobuf.encode(repeated_schema, repeated_message)
--  local decoded_repeated = Protobuf.decode(repeated_schema, encoded_repeated)
--
--  assert_table_equal(decoded_repeated.int_array, repeated_message.int_array, "Int array mismatch")
--  assert_table_equal(decoded_repeated.float_array, repeated_message.float_array, "Float array mismatch")
--  assert_table_equal(decoded_repeated.bool_array, repeated_message.bool_array, "Bool array mismatch")
--  assert_table_equal(decoded_repeated.string_array, repeated_message.string_array, "String array mismatch")
--
--  -- Test repeated message types
--  local repeated_nested_message = {
--    items = {
--      { id = 1, name = "Item 1", value = 10 },
--      { id = 2, name = "Item 2", value = 20 },
--      { id = 3, name = "Item 3", value = 30 },
--    },
--  }
--
--  local repeated_nested_schema = {
--    fields = {
--      [1] = {
--        name = "items",
--        wireType = Protobuf.WireType.LENGTH_DELIMITED,
--        repeated = true,
--        subschema = {
--          fields = {
--            [1] = { name = "id", wireType = Protobuf.WireType.VARINT },
--            [2] = { name = "name", wireType = Protobuf.WireType.LENGTH_DELIMITED },
--            [3] = { name = "value", wireType = Protobuf.WireType.FIXED32 },
--          },
--        },
--      },
--    },
--  }
--
--  local encoded_nested_repeated = Protobuf.encode(repeated_nested_schema, repeated_nested_message)
--  local decoded_nested_repeated = Protobuf.decode(repeated_nested_schema, encoded_nested_repeated)
--
--  assert_equal(#decoded_nested_repeated.items, #repeated_nested_message.items, "Repeated message count mismatch")
--  for i = 1, #repeated_nested_message.items do
--    assert_equal(
--      decoded_nested_repeated.items[i].id,
--      repeated_nested_message.items[i].id,
--      "Repeated message ID mismatch at index " .. i
--    )
--    assert_equal(
--      decoded_nested_repeated.items[i].name,
--      repeated_nested_message.items[i].name,
--      "Repeated message name mismatch at index " .. i
--    )
--    assert_equal(
--      decoded_nested_repeated.items[i].value,
--      repeated_nested_message.items[i].value,
--      "Repeated message value mismatch at index " .. i
--    )
--  end
--
--  print("All tests passed.")
--end

-- Uncomment to run the tests directly:
-- run_tests()

--- @return Protobuf
return Protobuf
