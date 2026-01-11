do
local _ENV = _ENV
package.preload[ "bitn.bit16" ] = function( ... ) local arg = _G.arg;
--- @module "bitn.bit16"
--- Pure Lua 16-bit bitwise operations library.
--- This module provides a complete, version-agnostic implementation of 16-bit
--- bitwise operations that works across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT
--- without depending on any built-in bit libraries.
--- @class bit16
local bit16 = {}

-- 16-bit mask constant
local MASK16 = 0xFFFF

--- Ensure value fits in 16-bit unsigned integer.
--- @param n number Input value
--- @return integer result 16-bit unsigned integer (0 to 0xFFFF)
function bit16.mask(n)
  return math.floor(n % 0x10000)
end

--- Bitwise AND operation.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of a AND b
function bit16.band(a, b)
  a = bit16.mask(a)
  b = bit16.mask(b)

  local result = 0
  local bit_val = 1

  for _ = 0, 15 do
    if (a % 2 == 1) and (b % 2 == 1) then
      result = result + bit_val
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_val = bit_val * 2

    if a == 0 and b == 0 then
      break
    end
  end

  return result
end

--- Bitwise OR operation.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of a OR b
function bit16.bor(a, b)
  a = bit16.mask(a)
  b = bit16.mask(b)

  local result = 0
  local bit_val = 1

  for _ = 0, 15 do
    if (a % 2 == 1) or (b % 2 == 1) then
      result = result + bit_val
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_val = bit_val * 2

    if a == 0 and b == 0 then
      break
    end
  end

  return result
end

--- Bitwise XOR operation.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of a XOR b
function bit16.bxor(a, b)
  a = bit16.mask(a)
  b = bit16.mask(b)

  local result = 0
  local bit_val = 1

  for _ = 0, 15 do
    if (a % 2) ~= (b % 2) then
      result = result + bit_val
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_val = bit_val * 2

    if a == 0 and b == 0 then
      break
    end
  end

  return result
end

--- Bitwise NOT operation.
--- @param a integer Operand (16-bit)
--- @return integer result Result of NOT a
function bit16.bnot(a)
  return bit16.mask(MASK16 - bit16.mask(a))
end

--- Left shift operation.
--- @param a integer Value to shift (16-bit)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a << n
function bit16.lshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  if n >= 16 then
    return 0
  end
  return bit16.mask(bit16.mask(a) * math.pow(2, n))
end

--- Logical right shift operation (fills with 0s).
--- @param a integer Value to shift (16-bit)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n (logical)
function bit16.rshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  a = bit16.mask(a)
  if n >= 16 then
    return 0
  end
  return math.floor(a / math.pow(2, n))
end

--- Arithmetic right shift operation (sign-extending, fills with sign bit).
--- @param a integer Value to shift (16-bit, treated as signed)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n with sign extension
function bit16.arshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  a = bit16.mask(a)

  -- Check if sign bit is set (bit 15)
  local is_negative = a >= 0x8000

  if n >= 16 then
    -- All bits shift out, result is all 1s if negative, all 0s if positive
    return is_negative and 0xFFFF or 0
  end

  -- Perform logical right shift first
  local result = math.floor(a / math.pow(2, n))

  -- If original was negative, fill high bits with 1s
  if is_negative then
    -- Create mask for high bits that need to be 1
    local fill_mask = MASK16 - (math.pow(2, 16 - n) - 1)
    result = bit16.bor(result, fill_mask)
  end

  return result
end

--- Left rotate operation.
--- @param x integer Value to rotate (16-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x left by n positions
function bit16.rol(x, n)
  n = n % 16
  x = bit16.mask(x)
  return bit16.mask(bit16.lshift(x, n) + bit16.rshift(x, 16 - n))
end

--- Right rotate operation.
--- @param x integer Value to rotate (16-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x right by n positions
function bit16.ror(x, n)
  n = n % 16
  x = bit16.mask(x)
  return bit16.mask(bit16.rshift(x, n) + bit16.lshift(x, 16 - n))
end

--- 16-bit addition with overflow handling.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of (a + b) mod 2^16
function bit16.add(a, b)
  return bit16.mask(bit16.mask(a) + bit16.mask(b))
end

--------------------------------------------------------------------------------
-- Byte conversion functions
--------------------------------------------------------------------------------

--- Convert 16-bit unsigned integer to 2 bytes (big-endian).
--- @param n integer 16-bit unsigned integer
--- @return string bytes 2-byte string in big-endian order
function bit16.u16_to_be_bytes(n)
  n = bit16.mask(n)
  return string.char(math.floor(n / 256), n % 256)
end

--- Convert 16-bit unsigned integer to 2 bytes (little-endian).
--- @param n integer 16-bit unsigned integer
--- @return string bytes 2-byte string in little-endian order
function bit16.u16_to_le_bytes(n)
  n = bit16.mask(n)
  return string.char(n % 256, math.floor(n / 256))
end

--- Convert 2 bytes to 16-bit unsigned integer (big-endian).
--- @param str string Binary string (at least 2 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 16-bit unsigned integer
function bit16.be_bytes_to_u16(str, offset)
  offset = offset or 1
  assert(#str >= offset + 1, "Insufficient bytes for u16")
  local b1, b2 = string.byte(str, offset, offset + 1)
  return b1 * 256 + b2
end

--- Convert 2 bytes to 16-bit unsigned integer (little-endian).
--- @param str string Binary string (at least 2 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 16-bit unsigned integer
function bit16.le_bytes_to_u16(str, offset)
  offset = offset or 1
  assert(#str >= offset + 1, "Insufficient bytes for u16")
  local b1, b2 = string.byte(str, offset, offset + 1)
  return b1 + b2 * 256
end

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

-- Compatibility for unpack
local unpack_fn = unpack or table.unpack

--- Run comprehensive self-test with test vectors.
--- @return boolean result True if all tests pass, false otherwise
function bit16.selftest()
  print("Running 16-bit operations test vectors...")
  local passed = 0
  local total = 0

  local test_vectors = {
    -- mask tests
    { name = "mask(0)", fn = bit16.mask, inputs = { 0 }, expected = 0 },
    { name = "mask(1)", fn = bit16.mask, inputs = { 1 }, expected = 1 },
    { name = "mask(0xFFFF)", fn = bit16.mask, inputs = { 0xFFFF }, expected = 0xFFFF },
    { name = "mask(0x10000)", fn = bit16.mask, inputs = { 0x10000 }, expected = 0 },
    { name = "mask(0x10001)", fn = bit16.mask, inputs = { 0x10001 }, expected = 1 },
    { name = "mask(-1)", fn = bit16.mask, inputs = { -1 }, expected = 0xFFFF },
    { name = "mask(-256)", fn = bit16.mask, inputs = { -256 }, expected = 0xFF00 },

    -- band tests
    { name = "band(0xFF00, 0x00FF)", fn = bit16.band, inputs = { 0xFF00, 0x00FF }, expected = 0 },
    { name = "band(0xFFFF, 0xFFFF)", fn = bit16.band, inputs = { 0xFFFF, 0xFFFF }, expected = 0xFFFF },
    { name = "band(0xAAAA, 0x5555)", fn = bit16.band, inputs = { 0xAAAA, 0x5555 }, expected = 0 },
    { name = "band(0xF0F0, 0xFF00)", fn = bit16.band, inputs = { 0xF0F0, 0xFF00 }, expected = 0xF000 },

    -- bor tests
    { name = "bor(0xFF00, 0x00FF)", fn = bit16.bor, inputs = { 0xFF00, 0x00FF }, expected = 0xFFFF },
    { name = "bor(0, 0)", fn = bit16.bor, inputs = { 0, 0 }, expected = 0 },
    { name = "bor(0xAAAA, 0x5555)", fn = bit16.bor, inputs = { 0xAAAA, 0x5555 }, expected = 0xFFFF },

    -- bxor tests
    { name = "bxor(0xFF00, 0x00FF)", fn = bit16.bxor, inputs = { 0xFF00, 0x00FF }, expected = 0xFFFF },
    { name = "bxor(0xFFFF, 0xFFFF)", fn = bit16.bxor, inputs = { 0xFFFF, 0xFFFF }, expected = 0 },
    { name = "bxor(0xAAAA, 0x5555)", fn = bit16.bxor, inputs = { 0xAAAA, 0x5555 }, expected = 0xFFFF },
    { name = "bxor(0x1234, 0x1234)", fn = bit16.bxor, inputs = { 0x1234, 0x1234 }, expected = 0 },

    -- bnot tests
    { name = "bnot(0)", fn = bit16.bnot, inputs = { 0 }, expected = 0xFFFF },
    { name = "bnot(0xFFFF)", fn = bit16.bnot, inputs = { 0xFFFF }, expected = 0 },
    { name = "bnot(0xAAAA)", fn = bit16.bnot, inputs = { 0xAAAA }, expected = 0x5555 },
    { name = "bnot(0x1234)", fn = bit16.bnot, inputs = { 0x1234 }, expected = 0xEDCB },

    -- lshift tests
    { name = "lshift(1, 0)", fn = bit16.lshift, inputs = { 1, 0 }, expected = 1 },
    { name = "lshift(1, 1)", fn = bit16.lshift, inputs = { 1, 1 }, expected = 2 },
    { name = "lshift(1, 15)", fn = bit16.lshift, inputs = { 1, 15 }, expected = 0x8000 },
    { name = "lshift(1, 16)", fn = bit16.lshift, inputs = { 1, 16 }, expected = 0 },
    { name = "lshift(0xFF, 8)", fn = bit16.lshift, inputs = { 0xFF, 8 }, expected = 0xFF00 },
    { name = "lshift(0x8000, 1)", fn = bit16.lshift, inputs = { 0x8000, 1 }, expected = 0 },

    -- rshift tests
    { name = "rshift(1, 0)", fn = bit16.rshift, inputs = { 1, 0 }, expected = 1 },
    { name = "rshift(2, 1)", fn = bit16.rshift, inputs = { 2, 1 }, expected = 1 },
    { name = "rshift(0x8000, 15)", fn = bit16.rshift, inputs = { 0x8000, 15 }, expected = 1 },
    { name = "rshift(0x8000, 16)", fn = bit16.rshift, inputs = { 0x8000, 16 }, expected = 0 },
    { name = "rshift(0xFF00, 8)", fn = bit16.rshift, inputs = { 0xFF00, 8 }, expected = 0xFF },
    { name = "rshift(0xFFFF, 8)", fn = bit16.rshift, inputs = { 0xFFFF, 8 }, expected = 0xFF },

    -- arshift tests (arithmetic shift - sign extending)
    { name = "arshift(0x8000, 1)", fn = bit16.arshift, inputs = { 0x8000, 1 }, expected = 0xC000 },
    { name = "arshift(0x8000, 15)", fn = bit16.arshift, inputs = { 0x8000, 15 }, expected = 0xFFFF },
    { name = "arshift(0x8000, 16)", fn = bit16.arshift, inputs = { 0x8000, 16 }, expected = 0xFFFF },
    { name = "arshift(0x7FFF, 1)", fn = bit16.arshift, inputs = { 0x7FFF, 1 }, expected = 0x3FFF },
    { name = "arshift(0x7FFF, 15)", fn = bit16.arshift, inputs = { 0x7FFF, 15 }, expected = 0 },
    { name = "arshift(0xFF00, 8)", fn = bit16.arshift, inputs = { 0xFF00, 8 }, expected = 0xFFFF },
    { name = "arshift(0x0F00, 8)", fn = bit16.arshift, inputs = { 0x0F00, 8 }, expected = 0x000F },

    -- rol tests
    { name = "rol(1, 0)", fn = bit16.rol, inputs = { 1, 0 }, expected = 1 },
    { name = "rol(1, 1)", fn = bit16.rol, inputs = { 1, 1 }, expected = 2 },
    { name = "rol(0x8000, 1)", fn = bit16.rol, inputs = { 0x8000, 1 }, expected = 1 },
    { name = "rol(1, 16)", fn = bit16.rol, inputs = { 1, 16 }, expected = 1 },
    { name = "rol(0x1234, 8)", fn = bit16.rol, inputs = { 0x1234, 8 }, expected = 0x3412 },
    { name = "rol(0x1234, 4)", fn = bit16.rol, inputs = { 0x1234, 4 }, expected = 0x2341 },

    -- ror tests
    { name = "ror(1, 0)", fn = bit16.ror, inputs = { 1, 0 }, expected = 1 },
    { name = "ror(1, 1)", fn = bit16.ror, inputs = { 1, 1 }, expected = 0x8000 },
    { name = "ror(2, 1)", fn = bit16.ror, inputs = { 2, 1 }, expected = 1 },
    { name = "ror(1, 16)", fn = bit16.ror, inputs = { 1, 16 }, expected = 1 },
    { name = "ror(0x1234, 8)", fn = bit16.ror, inputs = { 0x1234, 8 }, expected = 0x3412 },
    { name = "ror(0x1234, 4)", fn = bit16.ror, inputs = { 0x1234, 4 }, expected = 0x4123 },

    -- add tests
    { name = "add(0, 0)", fn = bit16.add, inputs = { 0, 0 }, expected = 0 },
    { name = "add(1, 1)", fn = bit16.add, inputs = { 1, 1 }, expected = 2 },
    { name = "add(0xFFFF, 1)", fn = bit16.add, inputs = { 0xFFFF, 1 }, expected = 0 },
    { name = "add(0xFFFF, 2)", fn = bit16.add, inputs = { 0xFFFF, 2 }, expected = 1 },
    { name = "add(0x8000, 0x8000)", fn = bit16.add, inputs = { 0x8000, 0x8000 }, expected = 0 },

    -- u16_to_be_bytes tests
    { name = "u16_to_be_bytes(0)", fn = bit16.u16_to_be_bytes, inputs = { 0 }, expected = string.char(0x00, 0x00) },
    { name = "u16_to_be_bytes(1)", fn = bit16.u16_to_be_bytes, inputs = { 1 }, expected = string.char(0x00, 0x01) },
    {
      name = "u16_to_be_bytes(0x1234)",
      fn = bit16.u16_to_be_bytes,
      inputs = { 0x1234 },
      expected = string.char(0x12, 0x34),
    },
    {
      name = "u16_to_be_bytes(0xFFFF)",
      fn = bit16.u16_to_be_bytes,
      inputs = { 0xFFFF },
      expected = string.char(0xFF, 0xFF),
    },

    -- u16_to_le_bytes tests
    { name = "u16_to_le_bytes(0)", fn = bit16.u16_to_le_bytes, inputs = { 0 }, expected = string.char(0x00, 0x00) },
    { name = "u16_to_le_bytes(1)", fn = bit16.u16_to_le_bytes, inputs = { 1 }, expected = string.char(0x01, 0x00) },
    {
      name = "u16_to_le_bytes(0x1234)",
      fn = bit16.u16_to_le_bytes,
      inputs = { 0x1234 },
      expected = string.char(0x34, 0x12),
    },
    {
      name = "u16_to_le_bytes(0xFFFF)",
      fn = bit16.u16_to_le_bytes,
      inputs = { 0xFFFF },
      expected = string.char(0xFF, 0xFF),
    },

    -- be_bytes_to_u16 tests
    {
      name = "be_bytes_to_u16(0x0000)",
      fn = bit16.be_bytes_to_u16,
      inputs = { string.char(0x00, 0x00) },
      expected = 0,
    },
    {
      name = "be_bytes_to_u16(0x0001)",
      fn = bit16.be_bytes_to_u16,
      inputs = { string.char(0x00, 0x01) },
      expected = 1,
    },
    {
      name = "be_bytes_to_u16(0x1234)",
      fn = bit16.be_bytes_to_u16,
      inputs = { string.char(0x12, 0x34) },
      expected = 0x1234,
    },
    {
      name = "be_bytes_to_u16(0xFFFF)",
      fn = bit16.be_bytes_to_u16,
      inputs = { string.char(0xFF, 0xFF) },
      expected = 0xFFFF,
    },

    -- le_bytes_to_u16 tests
    {
      name = "le_bytes_to_u16(0x0000)",
      fn = bit16.le_bytes_to_u16,
      inputs = { string.char(0x00, 0x00) },
      expected = 0,
    },
    {
      name = "le_bytes_to_u16(0x0001)",
      fn = bit16.le_bytes_to_u16,
      inputs = { string.char(0x01, 0x00) },
      expected = 1,
    },
    {
      name = "le_bytes_to_u16(0x1234)",
      fn = bit16.le_bytes_to_u16,
      inputs = { string.char(0x34, 0x12) },
      expected = 0x1234,
    },
    {
      name = "le_bytes_to_u16(0xFFFF)",
      fn = bit16.le_bytes_to_u16,
      inputs = { string.char(0xFF, 0xFF) },
      expected = 0xFFFF,
    },
  }

  for _, test in ipairs(test_vectors) do
    total = total + 1
    local result = test.fn(unpack_fn(test.inputs))
    if result == test.expected then
      print("  PASS: " .. test.name)
      passed = passed + 1
    else
      print("  FAIL: " .. test.name)
      if type(test.expected) == "string" then
        local exp_hex, got_hex = "", ""
        for i = 1, #test.expected do
          exp_hex = exp_hex .. string.format("%02X", string.byte(test.expected, i))
        end
        for i = 1, #result do
          got_hex = got_hex .. string.format("%02X", string.byte(result, i))
        end
        print("    Expected: " .. exp_hex)
        print("    Got:      " .. got_hex)
      else
        print(string.format("    Expected: 0x%04X", test.expected))
        print(string.format("    Got:      0x%04X", result))
      end
    end
  end

  print(string.format("\n16-bit operations: %d/%d tests passed\n", passed, total))
  return passed == total
end

return bit16
end
end

do
local _ENV = _ENV
package.preload[ "bitn.bit32" ] = function( ... ) local arg = _G.arg;
--- @module "bitn.bit32"
--- Pure Lua 32-bit bitwise operations library.
--- This module provides a complete, version-agnostic implementation of 32-bit
--- bitwise operations that works across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT
--- without depending on any built-in bit libraries.
--- @class bit32
local bit32 = {}

-- 32-bit mask constant
local MASK32 = 0xFFFFFFFF

--- Ensure value fits in 32-bit unsigned integer.
--- @param n number Input value
--- @return integer result 32-bit unsigned integer (0 to 0xFFFFFFFF)
function bit32.mask(n)
  return math.floor(n % 0x100000000)
end

--- Bitwise AND operation.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of a AND b
function bit32.band(a, b)
  a = bit32.mask(a)
  b = bit32.mask(b)

  local result = 0
  local bit_val = 1

  for _ = 0, 31 do
    if (a % 2 == 1) and (b % 2 == 1) then
      result = result + bit_val
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_val = bit_val * 2

    if a == 0 and b == 0 then
      break
    end
  end

  return result
end

--- Bitwise OR operation.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of a OR b
function bit32.bor(a, b)
  a = bit32.mask(a)
  b = bit32.mask(b)

  local result = 0
  local bit_val = 1

  for _ = 0, 31 do
    if (a % 2 == 1) or (b % 2 == 1) then
      result = result + bit_val
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_val = bit_val * 2

    if a == 0 and b == 0 then
      break
    end
  end

  return result
end

--- Bitwise XOR operation.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of a XOR b
function bit32.bxor(a, b)
  a = bit32.mask(a)
  b = bit32.mask(b)

  local result = 0
  local bit_val = 1

  for _ = 0, 31 do
    if (a % 2) ~= (b % 2) then
      result = result + bit_val
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_val = bit_val * 2

    if a == 0 and b == 0 then
      break
    end
  end

  return result
end

--- Bitwise NOT operation.
--- @param a integer Operand (32-bit)
--- @return integer result Result of NOT a
function bit32.bnot(a)
  return bit32.mask(MASK32 - bit32.mask(a))
end

--- Left shift operation.
--- @param a integer Value to shift (32-bit)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a << n
function bit32.lshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  if n >= 32 then
    return 0
  end
  return bit32.mask(bit32.mask(a) * math.pow(2, n))
end

--- Logical right shift operation (fills with 0s).
--- @param a integer Value to shift (32-bit)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n (logical)
function bit32.rshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  a = bit32.mask(a)
  if n >= 32 then
    return 0
  end
  return math.floor(a / math.pow(2, n))
end

--- Arithmetic right shift operation (sign-extending, fills with sign bit).
--- @param a integer Value to shift (32-bit, treated as signed)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n with sign extension
function bit32.arshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  a = bit32.mask(a)

  -- Check if sign bit is set (bit 31)
  local is_negative = a >= 0x80000000

  if n >= 32 then
    -- All bits shift out, result is all 1s if negative, all 0s if positive
    return is_negative and 0xFFFFFFFF or 0
  end

  -- Perform logical right shift first
  local result = math.floor(a / math.pow(2, n))

  -- If original was negative, fill high bits with 1s
  if is_negative then
    -- Create mask for high bits that need to be 1
    local fill_mask = MASK32 - (math.pow(2, 32 - n) - 1)
    result = bit32.bor(result, fill_mask)
  end

  return result
end

--- Left rotate operation.
--- @param x integer Value to rotate (32-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x left by n positions
function bit32.rol(x, n)
  n = n % 32
  x = bit32.mask(x)
  return bit32.mask(bit32.lshift(x, n) + bit32.rshift(x, 32 - n))
end

--- Right rotate operation.
--- @param x integer Value to rotate (32-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x right by n positions
function bit32.ror(x, n)
  n = n % 32
  x = bit32.mask(x)
  return bit32.mask(bit32.rshift(x, n) + bit32.lshift(x, 32 - n))
end

--- 32-bit addition with overflow handling.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of (a + b) mod 2^32
function bit32.add(a, b)
  return bit32.mask(bit32.mask(a) + bit32.mask(b))
end

--------------------------------------------------------------------------------
-- Byte conversion functions
--------------------------------------------------------------------------------

--- Convert 32-bit unsigned integer to 4 bytes (big-endian).
--- @param n integer 32-bit unsigned integer
--- @return string bytes 4-byte string in big-endian order
function bit32.u32_to_be_bytes(n)
  n = bit32.mask(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- Convert 32-bit unsigned integer to 4 bytes (little-endian).
--- @param n integer 32-bit unsigned integer
--- @return string bytes 4-byte string in little-endian order
function bit32.u32_to_le_bytes(n)
  n = bit32.mask(n)
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

--- Convert 4 bytes to 32-bit unsigned integer (big-endian).
--- @param str string Binary string (at least 4 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 32-bit unsigned integer
function bit32.be_bytes_to_u32(str, offset)
  offset = offset or 1
  assert(#str >= offset + 3, "Insufficient bytes for u32")
  local b1, b2, b3, b4 = string.byte(str, offset, offset + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

--- Convert 4 bytes to 32-bit unsigned integer (little-endian).
--- @param str string Binary string (at least 4 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 32-bit unsigned integer
function bit32.le_bytes_to_u32(str, offset)
  offset = offset or 1
  assert(#str >= offset + 3, "Insufficient bytes for u32")
  local b1, b2, b3, b4 = string.byte(str, offset, offset + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

-- Compatibility for unpack
local unpack_fn = unpack or table.unpack

--- Run comprehensive self-test with test vectors.
--- @return boolean result True if all tests pass, false otherwise
function bit32.selftest()
  print("Running 32-bit operations test vectors...")
  local passed = 0
  local total = 0

  local test_vectors = {
    -- mask tests
    { name = "mask(0)", fn = bit32.mask, inputs = { 0 }, expected = 0 },
    { name = "mask(1)", fn = bit32.mask, inputs = { 1 }, expected = 1 },
    { name = "mask(0xFFFFFFFF)", fn = bit32.mask, inputs = { 0xFFFFFFFF }, expected = 0xFFFFFFFF },
    { name = "mask(0x100000000)", fn = bit32.mask, inputs = { 0x100000000 }, expected = 0 },
    { name = "mask(0x100000001)", fn = bit32.mask, inputs = { 0x100000001 }, expected = 1 },
    { name = "mask(-1)", fn = bit32.mask, inputs = { -1 }, expected = 0xFFFFFFFF },
    { name = "mask(-256)", fn = bit32.mask, inputs = { -256 }, expected = 0xFFFFFF00 },

    -- band tests
    { name = "band(0xFF00FF00, 0x00FF00FF)", fn = bit32.band, inputs = { 0xFF00FF00, 0x00FF00FF }, expected = 0 },
    {
      name = "band(0xFFFFFFFF, 0xFFFFFFFF)",
      fn = bit32.band,
      inputs = { 0xFFFFFFFF, 0xFFFFFFFF },
      expected = 0xFFFFFFFF,
    },
    { name = "band(0xAAAAAAAA, 0x55555555)", fn = bit32.band, inputs = { 0xAAAAAAAA, 0x55555555 }, expected = 0 },
    {
      name = "band(0xF0F0F0F0, 0xFF00FF00)",
      fn = bit32.band,
      inputs = { 0xF0F0F0F0, 0xFF00FF00 },
      expected = 0xF000F000,
    },
    { name = "band(0, 0xFFFFFFFF)", fn = bit32.band, inputs = { 0, 0xFFFFFFFF }, expected = 0 },

    -- bor tests
    {
      name = "bor(0xFF00FF00, 0x00FF00FF)",
      fn = bit32.bor,
      inputs = { 0xFF00FF00, 0x00FF00FF },
      expected = 0xFFFFFFFF,
    },
    { name = "bor(0, 0)", fn = bit32.bor, inputs = { 0, 0 }, expected = 0 },
    {
      name = "bor(0xAAAAAAAA, 0x55555555)",
      fn = bit32.bor,
      inputs = { 0xAAAAAAAA, 0x55555555 },
      expected = 0xFFFFFFFF,
    },
    {
      name = "bor(0xF0F0F0F0, 0x0F0F0F0F)",
      fn = bit32.bor,
      inputs = { 0xF0F0F0F0, 0x0F0F0F0F },
      expected = 0xFFFFFFFF,
    },

    -- bxor tests
    {
      name = "bxor(0xFF00FF00, 0x00FF00FF)",
      fn = bit32.bxor,
      inputs = { 0xFF00FF00, 0x00FF00FF },
      expected = 0xFFFFFFFF,
    },
    { name = "bxor(0xFFFFFFFF, 0xFFFFFFFF)", fn = bit32.bxor, inputs = { 0xFFFFFFFF, 0xFFFFFFFF }, expected = 0 },
    {
      name = "bxor(0xAAAAAAAA, 0x55555555)",
      fn = bit32.bxor,
      inputs = { 0xAAAAAAAA, 0x55555555 },
      expected = 0xFFFFFFFF,
    },
    { name = "bxor(0x12345678, 0x12345678)", fn = bit32.bxor, inputs = { 0x12345678, 0x12345678 }, expected = 0 },

    -- bnot tests
    { name = "bnot(0)", fn = bit32.bnot, inputs = { 0 }, expected = 0xFFFFFFFF },
    { name = "bnot(0xFFFFFFFF)", fn = bit32.bnot, inputs = { 0xFFFFFFFF }, expected = 0 },
    { name = "bnot(0xAAAAAAAA)", fn = bit32.bnot, inputs = { 0xAAAAAAAA }, expected = 0x55555555 },
    { name = "bnot(0x12345678)", fn = bit32.bnot, inputs = { 0x12345678 }, expected = 0xEDCBA987 },

    -- lshift tests
    { name = "lshift(1, 0)", fn = bit32.lshift, inputs = { 1, 0 }, expected = 1 },
    { name = "lshift(1, 1)", fn = bit32.lshift, inputs = { 1, 1 }, expected = 2 },
    { name = "lshift(1, 31)", fn = bit32.lshift, inputs = { 1, 31 }, expected = 0x80000000 },
    { name = "lshift(1, 32)", fn = bit32.lshift, inputs = { 1, 32 }, expected = 0 },
    { name = "lshift(0xFF, 8)", fn = bit32.lshift, inputs = { 0xFF, 8 }, expected = 0xFF00 },
    { name = "lshift(0x80000000, 1)", fn = bit32.lshift, inputs = { 0x80000000, 1 }, expected = 0 },

    -- rshift tests
    { name = "rshift(1, 0)", fn = bit32.rshift, inputs = { 1, 0 }, expected = 1 },
    { name = "rshift(2, 1)", fn = bit32.rshift, inputs = { 2, 1 }, expected = 1 },
    { name = "rshift(0x80000000, 31)", fn = bit32.rshift, inputs = { 0x80000000, 31 }, expected = 1 },
    { name = "rshift(0x80000000, 32)", fn = bit32.rshift, inputs = { 0x80000000, 32 }, expected = 0 },
    { name = "rshift(0xFF00, 8)", fn = bit32.rshift, inputs = { 0xFF00, 8 }, expected = 0xFF },
    { name = "rshift(0xFFFFFFFF, 16)", fn = bit32.rshift, inputs = { 0xFFFFFFFF, 16 }, expected = 0xFFFF },

    -- arshift tests (arithmetic shift - sign extending)
    { name = "arshift(0x80000000, 1)", fn = bit32.arshift, inputs = { 0x80000000, 1 }, expected = 0xC0000000 },
    { name = "arshift(0x80000000, 31)", fn = bit32.arshift, inputs = { 0x80000000, 31 }, expected = 0xFFFFFFFF },
    { name = "arshift(0x80000000, 32)", fn = bit32.arshift, inputs = { 0x80000000, 32 }, expected = 0xFFFFFFFF },
    { name = "arshift(0x7FFFFFFF, 1)", fn = bit32.arshift, inputs = { 0x7FFFFFFF, 1 }, expected = 0x3FFFFFFF },
    { name = "arshift(0x7FFFFFFF, 31)", fn = bit32.arshift, inputs = { 0x7FFFFFFF, 31 }, expected = 0 },
    { name = "arshift(0xFF000000, 8)", fn = bit32.arshift, inputs = { 0xFF000000, 8 }, expected = 0xFFFF0000 },
    { name = "arshift(0x0F000000, 8)", fn = bit32.arshift, inputs = { 0x0F000000, 8 }, expected = 0x000F0000 },

    -- rol tests
    { name = "rol(1, 0)", fn = bit32.rol, inputs = { 1, 0 }, expected = 1 },
    { name = "rol(1, 1)", fn = bit32.rol, inputs = { 1, 1 }, expected = 2 },
    { name = "rol(0x80000000, 1)", fn = bit32.rol, inputs = { 0x80000000, 1 }, expected = 1 },
    { name = "rol(1, 32)", fn = bit32.rol, inputs = { 1, 32 }, expected = 1 },
    { name = "rol(0x12345678, 8)", fn = bit32.rol, inputs = { 0x12345678, 8 }, expected = 0x34567812 },
    { name = "rol(0x12345678, 16)", fn = bit32.rol, inputs = { 0x12345678, 16 }, expected = 0x56781234 },

    -- ror tests
    { name = "ror(1, 0)", fn = bit32.ror, inputs = { 1, 0 }, expected = 1 },
    { name = "ror(1, 1)", fn = bit32.ror, inputs = { 1, 1 }, expected = 0x80000000 },
    { name = "ror(2, 1)", fn = bit32.ror, inputs = { 2, 1 }, expected = 1 },
    { name = "ror(1, 32)", fn = bit32.ror, inputs = { 1, 32 }, expected = 1 },
    { name = "ror(0x12345678, 8)", fn = bit32.ror, inputs = { 0x12345678, 8 }, expected = 0x78123456 },
    { name = "ror(0x12345678, 16)", fn = bit32.ror, inputs = { 0x12345678, 16 }, expected = 0x56781234 },

    -- add tests
    { name = "add(0, 0)", fn = bit32.add, inputs = { 0, 0 }, expected = 0 },
    { name = "add(1, 1)", fn = bit32.add, inputs = { 1, 1 }, expected = 2 },
    { name = "add(0xFFFFFFFF, 1)", fn = bit32.add, inputs = { 0xFFFFFFFF, 1 }, expected = 0 },
    { name = "add(0xFFFFFFFF, 2)", fn = bit32.add, inputs = { 0xFFFFFFFF, 2 }, expected = 1 },
    { name = "add(0x80000000, 0x80000000)", fn = bit32.add, inputs = { 0x80000000, 0x80000000 }, expected = 0 },

    -- u32_to_be_bytes tests
    {
      name = "u32_to_be_bytes(0)",
      fn = bit32.u32_to_be_bytes,
      inputs = { 0 },
      expected = string.char(0x00, 0x00, 0x00, 0x00),
    },
    {
      name = "u32_to_be_bytes(1)",
      fn = bit32.u32_to_be_bytes,
      inputs = { 1 },
      expected = string.char(0x00, 0x00, 0x00, 0x01),
    },
    {
      name = "u32_to_be_bytes(0x12345678)",
      fn = bit32.u32_to_be_bytes,
      inputs = { 0x12345678 },
      expected = string.char(0x12, 0x34, 0x56, 0x78),
    },
    {
      name = "u32_to_be_bytes(0xFFFFFFFF)",
      fn = bit32.u32_to_be_bytes,
      inputs = { 0xFFFFFFFF },
      expected = string.char(0xFF, 0xFF, 0xFF, 0xFF),
    },

    -- u32_to_le_bytes tests
    {
      name = "u32_to_le_bytes(0)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 0 },
      expected = string.char(0x00, 0x00, 0x00, 0x00),
    },
    {
      name = "u32_to_le_bytes(1)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 1 },
      expected = string.char(0x01, 0x00, 0x00, 0x00),
    },
    {
      name = "u32_to_le_bytes(0x12345678)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 0x12345678 },
      expected = string.char(0x78, 0x56, 0x34, 0x12),
    },
    {
      name = "u32_to_le_bytes(0xFFFFFFFF)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 0xFFFFFFFF },
      expected = string.char(0xFF, 0xFF, 0xFF, 0xFF),
    },

    -- be_bytes_to_u32 tests
    {
      name = "be_bytes_to_u32(0x00000000)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string.char(0x00, 0x00, 0x00, 0x00) },
      expected = 0,
    },
    {
      name = "be_bytes_to_u32(0x00000001)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string.char(0x00, 0x00, 0x00, 0x01) },
      expected = 1,
    },
    {
      name = "be_bytes_to_u32(0x12345678)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string.char(0x12, 0x34, 0x56, 0x78) },
      expected = 0x12345678,
    },
    {
      name = "be_bytes_to_u32(0xFFFFFFFF)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string.char(0xFF, 0xFF, 0xFF, 0xFF) },
      expected = 0xFFFFFFFF,
    },

    -- le_bytes_to_u32 tests
    {
      name = "le_bytes_to_u32(0x00000000)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string.char(0x00, 0x00, 0x00, 0x00) },
      expected = 0,
    },
    {
      name = "le_bytes_to_u32(0x00000001)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string.char(0x01, 0x00, 0x00, 0x00) },
      expected = 1,
    },
    {
      name = "le_bytes_to_u32(0x12345678)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string.char(0x78, 0x56, 0x34, 0x12) },
      expected = 0x12345678,
    },
    {
      name = "le_bytes_to_u32(0xFFFFFFFF)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string.char(0xFF, 0xFF, 0xFF, 0xFF) },
      expected = 0xFFFFFFFF,
    },
  }

  for _, test in ipairs(test_vectors) do
    total = total + 1
    local result = test.fn(unpack_fn(test.inputs))
    if result == test.expected then
      print("  PASS: " .. test.name)
      passed = passed + 1
    else
      print("  FAIL: " .. test.name)
      if type(test.expected) == "string" then
        local exp_hex, got_hex = "", ""
        for i = 1, #test.expected do
          exp_hex = exp_hex .. string.format("%02X", string.byte(test.expected, i))
        end
        for i = 1, #result do
          got_hex = got_hex .. string.format("%02X", string.byte(result, i))
        end
        print("    Expected: " .. exp_hex)
        print("    Got:      " .. got_hex)
      else
        print(string.format("    Expected: 0x%08X", test.expected))
        print(string.format("    Got:      0x%08X", result))
      end
    end
  end

  print(string.format("\n32-bit operations: %d/%d tests passed\n", passed, total))
  return passed == total
end

return bit32
end
end

do
local _ENV = _ENV
package.preload[ "bitn.bit64" ] = function( ... ) local arg = _G.arg;
--- @module "bitn.bit64"
--- Pure Lua 64-bit bitwise operations library.
--- This module provides 64-bit bitwise operations using {high, low} pairs,
--- where high is the upper 32 bits and low is the lower 32 bits.
--- Works across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT without depending on
--- any built-in bit libraries.
--- @class bit64
local bit64 = {}

local bit32 = require("bitn.bit32")

-- Type definitions
--- @alias Int64HighLow [integer, integer] Array with [1]=high 32 bits, [2]=low 32 bits

--------------------------------------------------------------------------------
-- Bitwise operations
--------------------------------------------------------------------------------

--- Bitwise AND operation.
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} AND result
function bit64.band(a, b)
  return {
    bit32.band(a[1], b[1]),
    bit32.band(a[2], b[2]),
  }
end

--- Bitwise OR operation.
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} OR result
function bit64.bor(a, b)
  return {
    bit32.bor(a[1], b[1]),
    bit32.bor(a[2], b[2]),
  }
end

--- Bitwise XOR operation.
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} XOR result
function bit64.bxor(a, b)
  return {
    bit32.bxor(a[1], b[1]),
    bit32.bxor(a[2], b[2]),
  }
end

--- Bitwise NOT operation.
--- @param a Int64HighLow Operand {high, low}
--- @return Int64HighLow result {high, low} NOT result
function bit64.bnot(a)
  return {
    bit32.bnot(a[1]),
    bit32.bnot(a[2]),
  }
end

--------------------------------------------------------------------------------
-- Shift operations
--------------------------------------------------------------------------------

--- Left shift operation.
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.lshift(x, n)
  if n == 0 then
    return { x[1], x[2] }
  elseif n >= 64 then
    return { 0, 0 }
  elseif n >= 32 then
    -- Shift by 32 or more: low becomes 0, high gets bits from low
    return { bit32.lshift(x[2], n - 32), 0 }
  else
    -- Shift by less than 32
    local new_high = bit32.bor(bit32.lshift(x[1], n), bit32.rshift(x[2], 32 - n))
    local new_low = bit32.lshift(x[2], n)
    return { new_high, new_low }
  end
end

--- Logical right shift operation (fills with 0s).
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.rshift(x, n)
  if n == 0 then
    return { x[1], x[2] }
  elseif n >= 64 then
    return { 0, 0 }
  elseif n >= 32 then
    -- Shift by 32 or more: high becomes 0, low gets bits from high
    return { 0, bit32.rshift(x[1], n - 32) }
  else
    -- Shift by less than 32
    local new_low = bit32.bor(bit32.rshift(x[2], n), bit32.lshift(x[1], 32 - n))
    local new_high = bit32.rshift(x[1], n)
    return { new_high, new_low }
  end
end

--- Arithmetic right shift operation (sign-extending, fills with sign bit).
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.arshift(x, n)
  if n == 0 then
    return { x[1], x[2] }
  end

  -- Check sign bit (bit 31 of high word)
  local is_negative = bit32.band(x[1], 0x80000000) ~= 0

  if n >= 64 then
    -- All bits shift out, result is all 1s if negative, all 0s if positive
    if is_negative then
      return { 0xFFFFFFFF, 0xFFFFFFFF }
    else
      return { 0, 0 }
    end
  elseif n >= 32 then
    -- High word shifts into low, high fills with sign
    local new_low = bit32.arshift(x[1], n - 32)
    local new_high = is_negative and 0xFFFFFFFF or 0
    return { new_high, new_low }
  else
    -- Shift by less than 32
    local new_low = bit32.bor(bit32.rshift(x[2], n), bit32.lshift(x[1], 32 - n))
    local new_high = bit32.arshift(x[1], n)
    return { new_high, new_low }
  end
end

--------------------------------------------------------------------------------
-- Rotate operations
--------------------------------------------------------------------------------

--- Left rotate operation.
--- @param x Int64HighLow Value to rotate {high, low}
--- @param n integer Number of positions to rotate
--- @return Int64HighLow result {high, low} rotated value
function bit64.rol(x, n)
  n = n % 64
  if n == 0 then
    return { x[1], x[2] }
  end

  local high, low = x[1], x[2]

  if n == 32 then
    -- Special case: swap high and low
    return { low, high }
  elseif n < 32 then
    -- Rotate within 32-bit boundaries
    local new_high = bit32.bor(bit32.lshift(high, n), bit32.rshift(low, 32 - n))
    local new_low = bit32.bor(bit32.lshift(low, n), bit32.rshift(high, 32 - n))
    return { new_high, new_low }
  else
    -- n > 32: rotate by (n - 32) after swapping
    n = n - 32
    local new_high = bit32.bor(bit32.lshift(low, n), bit32.rshift(high, 32 - n))
    local new_low = bit32.bor(bit32.lshift(high, n), bit32.rshift(low, 32 - n))
    return { new_high, new_low }
  end
end

--- Right rotate operation.
--- @param x Int64HighLow Value to rotate {high, low}
--- @param n integer Number of positions to rotate
--- @return Int64HighLow result {high, low} rotated value
function bit64.ror(x, n)
  n = n % 64
  if n == 0 then
    return { x[1], x[2] }
  end

  local high, low = x[1], x[2]

  if n == 32 then
    -- Special case: swap high and low
    return { low, high }
  elseif n < 32 then
    -- Rotate within 32-bit boundaries
    local new_low = bit32.bor(bit32.rshift(low, n), bit32.lshift(high, 32 - n))
    local new_high = bit32.bor(bit32.rshift(high, n), bit32.lshift(low, 32 - n))
    return { new_high, new_low }
  else
    -- n > 32: rotate by (n - 32) after swapping
    n = n - 32
    local new_low = bit32.bor(bit32.rshift(high, n), bit32.lshift(low, 32 - n))
    local new_high = bit32.bor(bit32.rshift(low, n), bit32.lshift(high, 32 - n))
    return { new_high, new_low }
  end
end

--------------------------------------------------------------------------------
-- Arithmetic operations
--------------------------------------------------------------------------------

--- 64-bit addition with overflow handling.
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} sum
function bit64.add(a, b)
  local low = a[2] + b[2]
  local high = a[1] + b[1]

  -- Handle carry from low to high
  if low >= 0x100000000 then
    high = high + 1
    low = low % 0x100000000
  end

  -- Keep high within 32 bits
  high = high % 0x100000000

  return { high, low }
end

--------------------------------------------------------------------------------
-- Byte conversion functions
--------------------------------------------------------------------------------

--- Convert 64-bit value to 8 bytes (big-endian).
--- @param x Int64HighLow 64-bit value {high, low}
--- @return string bytes 8-byte string in big-endian order
function bit64.u64_to_be_bytes(x)
  return bit32.u32_to_be_bytes(x[1]) .. bit32.u32_to_be_bytes(x[2])
end

--- Convert 64-bit value to 8 bytes (little-endian).
--- @param x Int64HighLow 64-bit value {high, low}
--- @return string bytes 8-byte string in little-endian order
function bit64.u64_to_le_bytes(x)
  return bit32.u32_to_le_bytes(x[2]) .. bit32.u32_to_le_bytes(x[1])
end

--- Convert 8 bytes to 64-bit value (big-endian).
--- @param str string Binary string (at least 8 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return Int64HighLow value {high, low} 64-bit value
function bit64.be_bytes_to_u64(str, offset)
  offset = offset or 1
  assert(#str >= offset + 7, "Insufficient bytes for u64")
  local high = bit32.be_bytes_to_u32(str, offset)
  local low = bit32.be_bytes_to_u32(str, offset + 4)
  return { high, low }
end

--- Convert 8 bytes to 64-bit value (little-endian).
--- @param str string Binary string (at least 8 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return Int64HighLow value {high, low} 64-bit value
function bit64.le_bytes_to_u64(str, offset)
  offset = offset or 1
  assert(#str >= offset + 7, "Insufficient bytes for u64")
  local low = bit32.le_bytes_to_u32(str, offset)
  local high = bit32.le_bytes_to_u32(str, offset + 4)
  return { high, low }
end

--------------------------------------------------------------------------------
-- Aliases for compatibility
--------------------------------------------------------------------------------

--- Alias for bxor (compatibility with older API).
bit64.xor = bit64.bxor

--- Alias for rshift (compatibility with older API).
bit64.shr = bit64.rshift

--- Alias for lshift (compatibility with older API).
bit64.lsl = bit64.lshift

--- Alias for arshift (compatibility with older API).
bit64.asr = bit64.arshift

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

-- Compatibility for unpack
local unpack_fn = unpack or table.unpack

--- Compare two 64-bit values (high/low pairs).
--- @param a Int64HighLow First value {high, low}
--- @param b Int64HighLow Second value {high, low}
--- @return boolean equal True if equal
local function eq64(a, b)
  return a[1] == b[1] and a[2] == b[2]
end

--- Format 64-bit value as hex string.
--- @param x Int64HighLow Value {high, low}
--- @return string formatted Hex string
local function fmt64(x)
  return string.format("{0x%08X, 0x%08X}", x[1], x[2])
end

--- Run comprehensive self-test with test vectors.
--- @return boolean result True if all tests pass, false otherwise
function bit64.selftest()
  print("Running 64-bit operations test vectors...")
  local passed = 0
  local total = 0

  local test_vectors = {
    -- band tests
    {
      name = "band({0xFFFFFFFF, 0}, {0, 0xFFFFFFFF})",
      fn = bit64.band,
      inputs = { { 0xFFFFFFFF, 0 }, { 0, 0xFFFFFFFF } },
      expected = { 0, 0 },
    },
    {
      name = "band({0xFFFFFFFF, 0xFFFFFFFF}, {0xFFFFFFFF, 0xFFFFFFFF})",
      fn = bit64.band,
      inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0xFFFFFFFF, 0xFFFFFFFF } },
      expected = { 0xFFFFFFFF, 0xFFFFFFFF },
    },
    {
      name = "band({0xAAAAAAAA, 0x55555555}, {0x55555555, 0xAAAAAAAA})",
      fn = bit64.band,
      inputs = { { 0xAAAAAAAA, 0x55555555 }, { 0x55555555, 0xAAAAAAAA } },
      expected = { 0, 0 },
    },

    -- bor tests
    {
      name = "bor({0xFFFF0000, 0}, {0, 0x0000FFFF})",
      fn = bit64.bor,
      inputs = { { 0xFFFF0000, 0 }, { 0, 0x0000FFFF } },
      expected = { 0xFFFF0000, 0x0000FFFF },
    },
    { name = "bor({0, 0}, {0, 0})", fn = bit64.bor, inputs = { { 0, 0 }, { 0, 0 } }, expected = { 0, 0 } },
    {
      name = "bor({0xAAAAAAAA, 0x55555555}, {0x55555555, 0xAAAAAAAA})",
      fn = bit64.bor,
      inputs = { { 0xAAAAAAAA, 0x55555555 }, { 0x55555555, 0xAAAAAAAA } },
      expected = { 0xFFFFFFFF, 0xFFFFFFFF },
    },

    -- bxor tests
    {
      name = "bxor({0xFFFFFFFF, 0}, {0, 0xFFFFFFFF})",
      fn = bit64.bxor,
      inputs = { { 0xFFFFFFFF, 0 }, { 0, 0xFFFFFFFF } },
      expected = { 0xFFFFFFFF, 0xFFFFFFFF },
    },
    {
      name = "bxor({0x12345678, 0x9ABCDEF0}, {0x12345678, 0x9ABCDEF0})",
      fn = bit64.bxor,
      inputs = { { 0x12345678, 0x9ABCDEF0 }, { 0x12345678, 0x9ABCDEF0 } },
      expected = { 0, 0 },
    },

    -- bnot tests
    { name = "bnot({0, 0})", fn = bit64.bnot, inputs = { { 0, 0 } }, expected = { 0xFFFFFFFF, 0xFFFFFFFF } },
    {
      name = "bnot({0xFFFFFFFF, 0xFFFFFFFF})",
      fn = bit64.bnot,
      inputs = { { 0xFFFFFFFF, 0xFFFFFFFF } },
      expected = { 0, 0 },
    },
    {
      name = "bnot({0xAAAAAAAA, 0x55555555})",
      fn = bit64.bnot,
      inputs = { { 0xAAAAAAAA, 0x55555555 } },
      expected = { 0x55555555, 0xAAAAAAAA },
    },

    -- lshift tests
    { name = "lshift({0, 1}, 0)", fn = bit64.lshift, inputs = { { 0, 1 }, 0 }, expected = { 0, 1 } },
    { name = "lshift({0, 1}, 1)", fn = bit64.lshift, inputs = { { 0, 1 }, 1 }, expected = { 0, 2 } },
    { name = "lshift({0, 1}, 32)", fn = bit64.lshift, inputs = { { 0, 1 }, 32 }, expected = { 1, 0 } },
    { name = "lshift({0, 1}, 63)", fn = bit64.lshift, inputs = { { 0, 1 }, 63 }, expected = { 0x80000000, 0 } },
    { name = "lshift({0, 1}, 64)", fn = bit64.lshift, inputs = { { 0, 1 }, 64 }, expected = { 0, 0 } },
    {
      name = "lshift({0, 0xFFFFFFFF}, 8)",
      fn = bit64.lshift,
      inputs = { { 0, 0xFFFFFFFF }, 8 },
      expected = { 0xFF, 0xFFFFFF00 },
    },

    -- rshift tests
    { name = "rshift({0, 1}, 0)", fn = bit64.rshift, inputs = { { 0, 1 }, 0 }, expected = { 0, 1 } },
    { name = "rshift({0, 2}, 1)", fn = bit64.rshift, inputs = { { 0, 2 }, 1 }, expected = { 0, 1 } },
    { name = "rshift({1, 0}, 32)", fn = bit64.rshift, inputs = { { 1, 0 }, 32 }, expected = { 0, 1 } },
    {
      name = "rshift({0x80000000, 0}, 63)",
      fn = bit64.rshift,
      inputs = { { 0x80000000, 0 }, 63 },
      expected = { 0, 1 },
    },
    { name = "rshift({1, 0}, 64)", fn = bit64.rshift, inputs = { { 1, 0 }, 64 }, expected = { 0, 0 } },
    {
      name = "rshift({0xFF000000, 0}, 8)",
      fn = bit64.rshift,
      inputs = { { 0xFF000000, 0 }, 8 },
      expected = { 0x00FF0000, 0 },
    },

    -- arshift tests (sign-extending)
    {
      name = "arshift({0x80000000, 0}, 1)",
      fn = bit64.arshift,
      inputs = { { 0x80000000, 0 }, 1 },
      expected = { 0xC0000000, 0 },
    },
    {
      name = "arshift({0x80000000, 0}, 32)",
      fn = bit64.arshift,
      inputs = { { 0x80000000, 0 }, 32 },
      expected = { 0xFFFFFFFF, 0x80000000 },
    },
    {
      name = "arshift({0x80000000, 0}, 63)",
      fn = bit64.arshift,
      inputs = { { 0x80000000, 0 }, 63 },
      expected = { 0xFFFFFFFF, 0xFFFFFFFF },
    },
    {
      name = "arshift({0x80000000, 0}, 64)",
      fn = bit64.arshift,
      inputs = { { 0x80000000, 0 }, 64 },
      expected = { 0xFFFFFFFF, 0xFFFFFFFF },
    },
    {
      name = "arshift({0x7FFFFFFF, 0xFFFFFFFF}, 1)",
      fn = bit64.arshift,
      inputs = { { 0x7FFFFFFF, 0xFFFFFFFF }, 1 },
      expected = { 0x3FFFFFFF, 0xFFFFFFFF },
    },
    {
      name = "arshift({0x7FFFFFFF, 0}, 63)",
      fn = bit64.arshift,
      inputs = { { 0x7FFFFFFF, 0 }, 63 },
      expected = { 0, 0 },
    },

    -- rol tests
    { name = "rol({0, 1}, 0)", fn = bit64.rol, inputs = { { 0, 1 }, 0 }, expected = { 0, 1 } },
    { name = "rol({0, 1}, 1)", fn = bit64.rol, inputs = { { 0, 1 }, 1 }, expected = { 0, 2 } },
    { name = "rol({0x80000000, 0}, 1)", fn = bit64.rol, inputs = { { 0x80000000, 0 }, 1 }, expected = { 0, 1 } },
    { name = "rol({0, 1}, 32)", fn = bit64.rol, inputs = { { 0, 1 }, 32 }, expected = { 1, 0 } },
    { name = "rol({0, 1}, 64)", fn = bit64.rol, inputs = { { 0, 1 }, 64 }, expected = { 0, 1 } },
    {
      name = "rol({0x12345678, 0x9ABCDEF0}, 16)",
      fn = bit64.rol,
      inputs = { { 0x12345678, 0x9ABCDEF0 }, 16 },
      expected = { 0x56789ABC, 0xDEF01234 },
    },

    -- ror tests
    { name = "ror({0, 1}, 0)", fn = bit64.ror, inputs = { { 0, 1 }, 0 }, expected = { 0, 1 } },
    { name = "ror({0, 1}, 1)", fn = bit64.ror, inputs = { { 0, 1 }, 1 }, expected = { 0x80000000, 0 } },
    { name = "ror({0, 2}, 1)", fn = bit64.ror, inputs = { { 0, 2 }, 1 }, expected = { 0, 1 } },
    { name = "ror({1, 0}, 32)", fn = bit64.ror, inputs = { { 1, 0 }, 32 }, expected = { 0, 1 } },
    { name = "ror({0, 1}, 64)", fn = bit64.ror, inputs = { { 0, 1 }, 64 }, expected = { 0, 1 } },
    {
      name = "ror({0x12345678, 0x9ABCDEF0}, 16)",
      fn = bit64.ror,
      inputs = { { 0x12345678, 0x9ABCDEF0 }, 16 },
      expected = { 0xDEF01234, 0x56789ABC },
    },

    -- add tests
    { name = "add({0, 0}, {0, 0})", fn = bit64.add, inputs = { { 0, 0 }, { 0, 0 } }, expected = { 0, 0 } },
    { name = "add({0, 1}, {0, 1})", fn = bit64.add, inputs = { { 0, 1 }, { 0, 1 } }, expected = { 0, 2 } },
    {
      name = "add({0, 0xFFFFFFFF}, {0, 1})",
      fn = bit64.add,
      inputs = { { 0, 0xFFFFFFFF }, { 0, 1 } },
      expected = { 1, 0 },
    },
    {
      name = "add({0xFFFFFFFF, 0xFFFFFFFF}, {0, 1})",
      fn = bit64.add,
      inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0, 1 } },
      expected = { 0, 0 },
    },
    {
      name = "add({0xFFFFFFFF, 0xFFFFFFFF}, {0, 2})",
      fn = bit64.add,
      inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0, 2 } },
      expected = { 0, 1 },
    },

    -- u64_to_be_bytes tests
    {
      name = "u64_to_be_bytes({0, 0})",
      fn = bit64.u64_to_be_bytes,
      inputs = { { 0, 0 } },
      expected = string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
    },
    {
      name = "u64_to_be_bytes({0, 1})",
      fn = bit64.u64_to_be_bytes,
      inputs = { { 0, 1 } },
      expected = string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01),
    },
    {
      name = "u64_to_be_bytes({0x12345678, 0x9ABCDEF0})",
      fn = bit64.u64_to_be_bytes,
      inputs = { { 0x12345678, 0x9ABCDEF0 } },
      expected = string.char(0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0),
    },

    -- u64_to_le_bytes tests
    {
      name = "u64_to_le_bytes({0, 0})",
      fn = bit64.u64_to_le_bytes,
      inputs = { { 0, 0 } },
      expected = string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
    },
    {
      name = "u64_to_le_bytes({0, 1})",
      fn = bit64.u64_to_le_bytes,
      inputs = { { 0, 1 } },
      expected = string.char(0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
    },
    {
      name = "u64_to_le_bytes({0x12345678, 0x9ABCDEF0})",
      fn = bit64.u64_to_le_bytes,
      inputs = { { 0x12345678, 0x9ABCDEF0 } },
      expected = string.char(0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12),
    },

    -- be_bytes_to_u64 tests
    {
      name = "be_bytes_to_u64(zeros)",
      fn = bit64.be_bytes_to_u64,
      inputs = { string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00) },
      expected = { 0, 0 },
    },
    {
      name = "be_bytes_to_u64(one)",
      fn = bit64.be_bytes_to_u64,
      inputs = { string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01) },
      expected = { 0, 1 },
    },
    {
      name = "be_bytes_to_u64(0x123456789ABCDEF0)",
      fn = bit64.be_bytes_to_u64,
      inputs = { string.char(0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0) },
      expected = { 0x12345678, 0x9ABCDEF0 },
    },

    -- le_bytes_to_u64 tests
    {
      name = "le_bytes_to_u64(zeros)",
      fn = bit64.le_bytes_to_u64,
      inputs = { string.char(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00) },
      expected = { 0, 0 },
    },
    {
      name = "le_bytes_to_u64(one)",
      fn = bit64.le_bytes_to_u64,
      inputs = { string.char(0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00) },
      expected = { 0, 1 },
    },
    {
      name = "le_bytes_to_u64(0x123456789ABCDEF0)",
      fn = bit64.le_bytes_to_u64,
      inputs = { string.char(0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12) },
      expected = { 0x12345678, 0x9ABCDEF0 },
    },
  }

  for _, test in ipairs(test_vectors) do
    total = total + 1
    local result = test.fn(unpack_fn(test.inputs))

    if type(test.expected) == "table" then
      -- 64-bit comparison
      if eq64(result, test.expected) then
        print("  PASS: " .. test.name)
        passed = passed + 1
      else
        print("  FAIL: " .. test.name)
        print("    Expected: " .. fmt64(test.expected))
        print("    Got:      " .. fmt64(result))
      end
    elseif type(test.expected) == "string" then
      -- Byte string comparison
      if result == test.expected then
        print("  PASS: " .. test.name)
        passed = passed + 1
      else
        local exp_hex, got_hex = "", ""
        for i = 1, #test.expected do
          exp_hex = exp_hex .. string.format("%02X", string.byte(test.expected, i))
        end
        for i = 1, #result do
          got_hex = got_hex .. string.format("%02X", string.byte(result, i))
        end
        print("  FAIL: " .. test.name)
        print("    Expected: " .. exp_hex)
        print("    Got:      " .. got_hex)
      end
    else
      if result == test.expected then
        print("  PASS: " .. test.name)
        passed = passed + 1
      else
        print("  FAIL: " .. test.name)
        print("    Expected: " .. tostring(test.expected))
        print("    Got:      " .. tostring(result))
      end
    end
  end

  print(string.format("\n64-bit operations: %d/%d tests passed\n", passed, total))
  return passed == total
end

return bit64
end
end

--- @module "bitn"
--- Pure Lua bitwise operations library.
--- This library provides standalone, version-agnostic implementations of
--- bitwise operations for 16-bit, 32-bit, and 64-bit integers. It works
--- across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT without depending on any
--- built-in bit libraries.
---
--- @usage
--- local bitn = require("bitn")
--- print(bitn.version())
---
--- -- 32-bit operations
--- local result = bitn.bit32.band(0xFF00, 0x0FF0)  -- 0x0F00
---
--- -- 64-bit operations (using {high, low} pairs)
--- local sum = bitn.bit64.add({0, 1}, {0, 2})  -- {0, 3}
---
--- -- 16-bit operations
--- local shifted = bitn.bit16.lshift(1, 8)  -- 256
---
--- @class bitn
local bitn = {
  bit16 = require("bitn.bit16"),
  bit32 = require("bitn.bit32"),
  bit64 = require("bitn.bit64"),
}

--- Library version (injected at build time for releases).
local VERSION = "v0.1.0"

--- Get the library version string.
--- @return string version Version string (e.g., "v1.0.0" or "dev")
function bitn.version()
  return VERSION
end

return bitn
