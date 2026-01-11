do
local _ENV = _ENV
package.preload[ "vendor.bitn" ] = function( ... ) local arg = _G.arg;
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
end
end

--- A lightweight Protocol Buffers implementation for Lua.
--- This module provides encoding and decoding functions for Protocol Buffers data format.

local bitn = require("vendor.bitn")
local bit32 = bitn.bit32
local bit64 = bitn.bit64

--- Check if a value is a list (sequential table).
--- @param t any The value to check.
--- @return boolean is_list True if the value is a list.
local function IsList(t)
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

--- @class Protobuf
--- A class providing Protocol Buffers encoding and decoding functionality.
local Protobuf = {}

-- Version
local VERSION = "v0.1.0"

--- Returns the library version.
--- @return string version The version string.
function Protobuf.version()
  return VERSION
end

--- Encodes an integer into a varint byte sequence.
--- @param value number|boolean|Int64HighLow The value to encode. Can be a number, boolean, or {high, low} pair for 64-bit values.
--- @return string bytes The encoded varint byte sequence.
function Protobuf.encode_varint(value)
  if type(value) == "boolean" then
    value = value and 1 or 0
  end

  -- If value is a table, assume it's {high, low} format for 64-bit
  if type(value) == "table" then
    --- @cast value Int64HighLow
    local bytes = {}
    --- @type Int64HighLow
    local v = { value[1], value[2] } -- Copy the input

    repeat
      -- Extract low 7 bits
      local byte = v[2] % 128

      -- Right shift by 7 bits using bit64
      v = bit64.shr(v, 7)

      -- Set continue bit if more bytes remain
      if v[1] ~= 0 or v[2] ~= 0 then
        byte = byte + 0x80
      end
      table.insert(bytes, string.char(byte))
    until v[1] == 0 and v[2] == 0

    return table.concat(bytes)
  end

  -- For values that fit in 32 bits, use bit operations (fast path)
  if value >= 0 and value < 0x100000000 then
    local bytes = {}
    repeat
      local byte = bit32.band(value, 0x7F)
      value = bit32.rshift(value, 7)
      if value > 0 then
        byte = bit32.bor(byte, 0x80)
      end
      table.insert(bytes, string.char(byte))
    until value == 0
    return table.concat(bytes)
  end

  -- For large values (> 32 bits), convert to {high, low} and use bit64
  local low_32 = value % 0x100000000
  local high_32 = math.floor(value / 0x100000000)
  --- @type Int64HighLow
  local v = { high_32, low_32 }
  local bytes = {}

  repeat
    local byte = v[2] % 128
    v = bit64.shr(v, 7)
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
function Protobuf.decode_varint64(buffer, pos)
  --- @type Int64HighLow
  local result = { 0, 0 } -- {high, low} for precision
  local shift = 0
  local byte

  repeat
    byte = string.byte(buffer, pos)
    local value_bits = bit32.band(byte, 0x7F)

    -- Create a {high, low} pair for this 7-bit chunk and shift it
    local chunk = { 0, value_bits }
    local shifted = bit64.lsl(chunk, shift)

    -- OR with result
    result = bit64.bor(result, shifted)

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
function Protobuf.decode_varint(buffer, pos)
  local result, new_pos = Protobuf.decode_varint64(buffer, pos)
  return Protobuf.int64_to_number(result), new_pos
end

-- ============================================================================
-- 64-bit {high, low} Utility Functions
-- ============================================================================

--- Converts a {high, low} pair to a hexadecimal string.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @return string hex The 16-character hexadecimal string (e.g., "0000180000001000").
function Protobuf.int64_to_hex(value)
  return string.format("%08X%08X", value[1], value[2])
end

--- Converts a {high, low} pair to a Lua number.
--- Warning: Values exceeding 53-bit precision will lose precision.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @return number num The value as a Lua number.
function Protobuf.int64_to_number(value)
  return value[1] * 0x100000000 + value[2]
end

--- Creates a {high, low} pair from a Lua number.
--- @param value number The number to convert.
--- @return Int64HighLow pair The {high_32, low_32} pair.
function Protobuf.int64_from_number(value)
  local low = value % 0x100000000
  local high = math.floor(value / 0x100000000)
  return { high, low }
end

--- Checks if two {high, low} pairs are equal.
--- @param a Int64HighLow The first {high_32, low_32} pair.
--- @param b Int64HighLow The second {high_32, low_32} pair.
--- @return boolean equal True if the values are equal.
function Protobuf.int64_equals(a, b)
  return a[1] == b[1] and a[2] == b[2]
end

--- Checks if a {high, low} pair is zero.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @return boolean is_zero True if the value is zero.
function Protobuf.int64_is_zero(value)
  return value[1] == 0 and value[2] == 0
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

--- Encodes a 64-bit integer into a fixed-length 8-byte sequence.
--- @param value Int64HighLow|number The 64-bit integer as {high, low} or number.
--- @return string bytes The encoded 8-byte sequence.
function Protobuf.encode_fixed64(value)
  local high, low
  if type(value) == "table" then
    high, low = value[1], value[2]
  else
    low = value % 0x100000000
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
function Protobuf.decode_fixed64(buffer, pos)
  local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(buffer, pos, pos + 7)
  local low = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  local high = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
  return { high, low }, pos + 8
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
  local b3 = bit32.bor(math.floor(m / 65536), bit32.lshift(e % 2, 7))
  local b4 = bit32.bor(bit32.rshift(e, 1), bit32.lshift(sign, 7))

  return string.char(b1, b2, b3, b4)
end

--- Decodes a 4-byte IEEE 754 single-precision format into a floating-point number.
--- @param buffer string The buffer containing the encoded float.
--- @param pos integer The position in the buffer to start decoding from.
--- @return number value The decoded floating-point value.
--- @return integer new_pos The new position in the buffer after decoding.
function Protobuf.decode_float(buffer, pos)
  local b1, b2, b3, b4 = string.byte(buffer, pos, pos + 3)

  local sign = bit32.rshift(b4, 7)
  local e = bit32.lshift(bit32.band(b4, 0x7F), 1) + bit32.rshift(b3, 7)
  local m = bit32.band(b3, 0x7F) * 65536 + b2 * 256 + b1

  if e == 0 and m == 0 then
    return 0, pos + 4
  end

  local result = math.ldexp(1 + m / 0x800000, e - 127)
  if sign == 1 then
    result = -result
  end

  return result, pos + 4
end

--- Encodes a double-precision floating-point number into an 8-byte IEEE 754 format.
--- @param value number The double-precision floating-point number to encode.
--- @return string bytes The encoded 8-byte sequence.
function Protobuf.encode_double(value)
  if value == 0 then
    return string.char(0, 0, 0, 0, 0, 0, 0, 0)
  end

  local sign = 0
  if value < 0 then
    sign = 1
    value = -value
  end

  local mantissa, exponent = math.frexp(value)
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
  local m_low = m % 0x100000000
  local m_high = math.floor(m / 0x100000000) % 0x100000 -- 20 bits

  local b1 = m_low % 256
  local b2 = math.floor(m_low / 256) % 256
  local b3 = math.floor(m_low / 65536) % 256
  local b4 = math.floor(m_low / 16777216) % 256
  local b5 = m_high % 256
  local b6 = math.floor(m_high / 256) % 256
  local b7 = bit32.bor(math.floor(m_high / 65536), bit32.lshift(e % 16, 4))
  local b8 = bit32.bor(bit32.rshift(e, 4), bit32.lshift(sign, 7))

  return string.char(b1, b2, b3, b4, b5, b6, b7, b8)
end

--- Decodes an 8-byte IEEE 754 double-precision format into a floating-point number.
--- @param buffer string The buffer containing the encoded double.
--- @param pos integer The position in the buffer to start decoding from.
--- @return number value The decoded double-precision floating-point value.
--- @return integer new_pos The new position in the buffer after decoding.
function Protobuf.decode_double(buffer, pos)
  local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(buffer, pos, pos + 7)

  local sign = bit32.rshift(b8, 7)
  local e = bit32.lshift(bit32.band(b8, 0x7F), 4) + bit32.rshift(b7, 4)
  local m_high = bit32.band(b7, 0x0F) * 65536 + b6 * 256 + b5
  local m_low = b4 * 16777216 + b3 * 65536 + b2 * 256 + b1
  local m = m_high * 0x100000000 + m_low

  if e == 0 and m == 0 then
    return 0, pos + 8
  end

  local result = math.ldexp(1 + m / 0x10000000000000, e - 1023)
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
function Protobuf.zigzag_encode32(value)
  return bit32.bxor(bit32.lshift(value, 1), bit32.arshift(value, 31))
end

--- Decodes a zigzag-encoded 32-bit integer.
--- @param value integer The zigzag-encoded value.
--- @return integer decoded The signed integer.
function Protobuf.zigzag_decode32(value)
  local result = bit32.bxor(bit32.rshift(value, 1), -bit32.band(value, 1))
  -- Convert unsigned to signed if high bit is set
  if result >= 0x80000000 then
    result = result - 0x100000000
  end
  return result
end

--- Encodes a signed 64-bit integer using zigzag encoding.
--- @param value Int64HighLow The signed 64-bit integer as {high, low}.
--- @return Int64HighLow encoded The zigzag-encoded value as {high, low}.
function Protobuf.zigzag_encode64(value)
  -- (n << 1) ^ (n >> 63)
  local shifted = bit64.lsl(value, 1)
  local sign_extended = bit64.asr(value, 63)
  return bit64.bxor(shifted, sign_extended)
end

--- Decodes a zigzag-encoded 64-bit integer.
--- @param value Int64HighLow The zigzag-encoded value as {high, low}.
--- @return Int64HighLow decoded The signed 64-bit integer as {high, low}.
function Protobuf.zigzag_decode64(value)
  -- (n >>> 1) ^ -(n & 1)
  local shifted = bit64.shr(value, 1)
  local sign_bit = { 0, bit32.band(value[2], 1) }
  -- Negate: if sign_bit is 1, result is {0xFFFFFFFF, 0xFFFFFFFF}, else {0, 0}
  local neg_sign
  if sign_bit[2] == 1 then
    neg_sign = { 0xFFFFFFFF, 0xFFFFFFFF }
  else
    neg_sign = { 0, 0 }
  end
  return bit64.bxor(shifted, neg_sign)
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
        local key = bit32.lshift(field_number, 3) + field.wireType
        buffer = buffer .. Protobuf.encode_varint(key)

        local fieldType = field.type
        if field.wireType == protoSchema.WireType.VARINT then
          -- Handle zigzag encoding for signed types
          if fieldType == protoSchema.DataType.SINT32 then
            buffer = buffer .. Protobuf.encode_varint(Protobuf.zigzag_encode32(value))
          elseif fieldType == protoSchema.DataType.SINT64 then
            buffer = buffer .. Protobuf.encode_varint(Protobuf.zigzag_encode64(value))
          else
            buffer = buffer .. Protobuf.encode_varint(value)
          end
        elseif field.wireType == protoSchema.WireType.FIXED64 then
          if fieldType == protoSchema.DataType.DOUBLE then
            buffer = buffer .. Protobuf.encode_double(value)
          else
            -- FIXED64, SFIXED64
            buffer = buffer .. Protobuf.encode_fixed64(value)
          end
        elseif field.wireType == protoSchema.WireType.FIXED32 then
          if fieldType == protoSchema.DataType.FLOAT then
            buffer = buffer .. Protobuf.encode_float(value)
          else
            -- FIXED32, SFIXED32
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
    local field_number = bit32.rshift(key, 3)
    local wire_type = bit32.band(key, 0x7)

    -- Find the corresponding field in the schema
    local field = messageSchema.fields[field_number]
    if not field then
      -- Skip unknown field based on wire type
      if wire_type == protoSchema.WireType.VARINT then
        -- Decode and discard the varint
        local _
        _, pos = Protobuf.decode_varint(buffer, pos)
      elseif wire_type == protoSchema.WireType.FIXED64 then
        -- Skip 8 bytes
        pos = pos + 8
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
      local fieldType = field.type
      -- Decode the value based on the wire type
      if wire_type == protoSchema.WireType.VARINT then
        -- Use 64-bit decoder for types that need full precision
        if fieldType == protoSchema.DataType.UINT64 or fieldType == protoSchema.DataType.INT64 then
          value, pos = Protobuf.decode_varint64(buffer, pos)
        elseif fieldType == protoSchema.DataType.SINT64 then
          local raw
          raw, pos = Protobuf.decode_varint64(buffer, pos)
          value = Protobuf.zigzag_decode64(raw)
        elseif fieldType == protoSchema.DataType.SINT32 then
          local raw
          raw, pos = Protobuf.decode_varint(buffer, pos)
          value = Protobuf.zigzag_decode32(raw)
        elseif fieldType == protoSchema.DataType.BOOL then
          value, pos = Protobuf.decode_varint(buffer, pos)
          value = value ~= 0 -- Convert to boolean
        else
          -- INT32, UINT32, ENUM, etc.
          value, pos = Protobuf.decode_varint(buffer, pos)
        end
      elseif wire_type == protoSchema.WireType.FIXED64 then
        if fieldType == protoSchema.DataType.DOUBLE then
          value, pos = Protobuf.decode_double(buffer, pos)
        else
          -- FIXED64, SFIXED64
          value, pos = Protobuf.decode_fixed64(buffer, pos)
        end
      elseif wire_type == protoSchema.WireType.FIXED32 then
        if fieldType == protoSchema.DataType.FLOAT then
          value, pos = Protobuf.decode_float(buffer, pos)
        else
          -- FIXED32, SFIXED32
          value, pos = Protobuf.decode_fixed32(buffer, pos)
        end
      elseif wire_type == protoSchema.WireType.LENGTH_DELIMITED then
        local data
        data, pos = Protobuf.decode_length_delimited(buffer, pos)
        if field.subschema then
          value = Protobuf.decode(protoSchema, protoSchema.Message[field.subschema], data)
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

--- Runs self-tests to verify the functionality of the Protobuf module.
--- Test vectors based on official Protocol Buffers encoding specification.
--- @see https://protobuf.dev/programming-guides/encoding/
--- @return boolean success True if all tests passed.
function Protobuf.selftest()
  local passed = 0
  local failed = 0

  --- Helper to convert string to hex for display
  local function to_hex(s)
    local hex = {}
    for i = 1, #s do
      table.insert(hex, string.format("%02X", string.byte(s, i)))
    end
    return table.concat(hex, " ")
  end

  --- Assert helper
  local function assert_eq(actual, expected, msg)
    if actual == expected then
      passed = passed + 1
      return true
    else
      failed = failed + 1
      print("FAIL: " .. msg .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
      return false
    end
  end

  --- Assert helper for bytes
  local function assert_bytes(actual, expected_hex, msg)
    local expected = ""
    for byte in expected_hex:gmatch("%x%x") do
      expected = expected .. string.char(tonumber(byte, 16) or 0)
    end
    if actual == expected then
      passed = passed + 1
      return true
    else
      failed = failed + 1
      print("FAIL: " .. msg .. ": expected " .. expected_hex .. ", got " .. to_hex(actual))
      return false
    end
  end

  --- Assert helper for floats
  local function assert_close(actual, expected, epsilon, msg)
    if math.abs(actual - expected) <= epsilon then
      passed = passed + 1
      return true
    else
      failed = failed + 1
      print("FAIL: " .. msg .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
      return false
    end
  end

  --- Assert helper for {high, low} pairs
  local function assert_int64_eq(actual, expected_high, expected_low, msg)
    if type(actual) == "table" and actual[1] == expected_high and actual[2] == expected_low then
      passed = passed + 1
      return true
    else
      failed = failed + 1
      local actual_str = type(actual) == "table" and string.format("{%d, %d}", actual[1], actual[2]) or tostring(actual)
      print("FAIL: " .. msg .. ": expected {" .. expected_high .. ", " .. expected_low .. "}, got " .. actual_str)
      return false
    end
  end

  -- ==========================================
  -- VARINT ENCODING TESTS (from official spec)
  -- ==========================================

  -- Test: 0 -> 0x00
  assert_bytes(Protobuf.encode_varint(0), "00", "varint(0)")

  -- Test: 1 -> 0x01
  assert_bytes(Protobuf.encode_varint(1), "01", "varint(1)")

  -- Test: 127 -> 0x7F (max single byte)
  assert_bytes(Protobuf.encode_varint(127), "7F", "varint(127)")

  -- Test: 128 -> 0x80 0x01 (first two-byte value)
  assert_bytes(Protobuf.encode_varint(128), "8001", "varint(128)")

  -- Test: 150 -> 0x96 0x01 (from official docs)
  assert_bytes(Protobuf.encode_varint(150), "9601", "varint(150)")

  -- Test: 300 -> 0xAC 0x02
  assert_bytes(Protobuf.encode_varint(300), "AC02", "varint(300)")

  -- Test: 16383 -> 0xFF 0x7F (max two-byte)
  assert_bytes(Protobuf.encode_varint(16383), "FF7F", "varint(16383)")

  -- Test: 16384 -> 0x80 0x80 0x01 (first three-byte)
  assert_bytes(Protobuf.encode_varint(16384), "808001", "varint(16384)")

  -- Test roundtrip for various values
  for _, v in ipairs({ 0, 1, 127, 128, 150, 300, 16383, 16384, 65535, 2097151, 268435455 }) do
    local enc = Protobuf.encode_varint(v)
    local dec, _ = Protobuf.decode_varint(enc, 1)
    assert_eq(dec, v, "varint roundtrip " .. v)
  end

  -- ==========================================
  -- VARINT64 TESTS
  -- ==========================================

  -- Test: Large value that fits in 53 bits
  local large_val = 2 ^ 40 + 12345
  local enc64 = Protobuf.encode_varint(large_val)
  local dec64, _ = Protobuf.decode_varint(enc64, 1)
  assert_eq(dec64, large_val, "varint64 roundtrip 2^40+12345")

  -- Test: decode_varint64 always returns {high, low}
  local result64, _ = Protobuf.decode_varint64(Protobuf.encode_varint(150), 1)
  assert_int64_eq(result64, 0, 150, "decode_varint64(150)")

  -- Test: {high, low} encoding
  local hl_val = { 0x12345678, 0x9ABCDEF0 }
  local hl_enc = Protobuf.encode_varint(hl_val)
  local hl_dec, _ = Protobuf.decode_varint64(hl_enc, 1)
  assert_int64_eq(hl_dec, hl_val[1], hl_val[2], "varint {high,low} roundtrip")

  -- ==========================================
  -- FIXED32 TESTS
  -- ==========================================

  -- Test: 0 -> 00 00 00 00
  assert_bytes(Protobuf.encode_fixed32(0), "00000000", "fixed32(0)")

  -- Test: 1 -> 01 00 00 00 (little-endian)
  assert_bytes(Protobuf.encode_fixed32(1), "01000000", "fixed32(1)")

  -- Test: 12345 -> 39 30 00 00 (little-endian: 0x3039)
  assert_bytes(Protobuf.encode_fixed32(12345), "39300000", "fixed32(12345)")

  -- Test: max uint32 -> FF FF FF FF
  assert_bytes(Protobuf.encode_fixed32(0xFFFFFFFF), "FFFFFFFF", "fixed32(max)")

  -- Roundtrip
  for _, v in ipairs({ 0, 1, 12345, 0xFFFFFFFF, 1234567890 }) do
    local enc = Protobuf.encode_fixed32(v)
    local dec, _ = Protobuf.decode_fixed32(enc, 1)
    assert_eq(dec, v, "fixed32 roundtrip " .. v)
  end

  -- ==========================================
  -- FIXED64 TESTS
  -- ==========================================

  -- Test: 0 -> 00 00 00 00 00 00 00 00
  assert_bytes(Protobuf.encode_fixed64({ 0, 0 }), "0000000000000000", "fixed64(0)")

  -- Test: 1 -> 01 00 00 00 00 00 00 00
  assert_bytes(Protobuf.encode_fixed64({ 0, 1 }), "0100000000000000", "fixed64(1)")

  -- Roundtrip with {high, low}
  local test_vals = {
    { 0, 0 },
    { 0, 1 },
    { 0, 0xFFFFFFFF },
    { 1, 0 },
    { 0xFFFFFFFF, 0xFFFFFFFF },
    { 0x12345678, 0x9ABCDEF0 },
  }
  for _, v in ipairs(test_vals) do
    local enc = Protobuf.encode_fixed64(v)
    local dec, _ = Protobuf.decode_fixed64(enc, 1)
    assert_int64_eq(dec, v[1], v[2], string.format("fixed64 roundtrip {0x%X, 0x%X}", v[1], v[2]))
  end

  -- ==========================================
  -- FLOAT TESTS
  -- ==========================================

  -- Test: 0.0 -> 00 00 00 00
  assert_bytes(Protobuf.encode_float(0), "00000000", "float(0)")

  -- Test: 1.0 -> 00 00 80 3F (IEEE 754: 0x3F800000)
  assert_bytes(Protobuf.encode_float(1.0), "0000803F", "float(1.0)")

  -- Roundtrip
  for _, v in ipairs({ 0.0, 1.0, -1.0, 3.14159, 100.5, -1234.5678 }) do
    local enc = Protobuf.encode_float(v)
    local dec, _ = Protobuf.decode_float(enc, 1)
    assert_close(dec, v, 1e-4, "float roundtrip " .. v)
  end

  -- ==========================================
  -- DOUBLE TESTS
  -- ==========================================

  -- Test: 0.0 -> 00 00 00 00 00 00 00 00
  assert_bytes(Protobuf.encode_double(0), "0000000000000000", "double(0)")

  -- Test: 1.0 -> 00 00 00 00 00 00 F0 3F (IEEE 754: 0x3FF0000000000000)
  assert_bytes(Protobuf.encode_double(1.0), "000000000000F03F", "double(1.0)")

  -- Roundtrip
  for _, v in ipairs({ 0.0, 1.0, -1.0, 3.141592653589793, 1e100, -1e-100 }) do
    local enc = Protobuf.encode_double(v)
    local dec, _ = Protobuf.decode_double(enc, 1)
    assert_close(dec, v, 1e-10, "double roundtrip " .. v)
  end

  -- ==========================================
  -- ZIGZAG TESTS (from official spec)
  -- ==========================================

  -- Official test vectors from protobuf spec
  local zigzag32_tests = {
    { 0, 0 },
    { -1, 1 },
    { 1, 2 },
    { -2, 3 },
    { 2147483647, 4294967294 }, -- 0x7FFFFFFF -> 0xFFFFFFFE
    { -2147483648, 4294967295 }, -- 0x80000000 -> 0xFFFFFFFF
  }
  for _, test in ipairs(zigzag32_tests) do
    local input, expected = test[1], test[2]
    local actual = Protobuf.zigzag_encode32(input)
    -- Handle signed result from bit.bxor
    if actual < 0 then
      actual = actual + 0x100000000
    end
    assert_eq(actual, expected, string.format("zigzag_encode32(%d)", input))
  end

  -- Roundtrip zigzag32
  for _, v in ipairs({ 0, 1, -1, 100, -100, 2147483647, -2147483648 }) do
    local enc = Protobuf.zigzag_encode32(v)
    local dec = Protobuf.zigzag_decode32(enc)
    assert_eq(dec, v, "zigzag32 roundtrip " .. v)
  end

  -- Roundtrip zigzag64
  local zigzag64_tests = {
    { { 0, 0 }, { 0, 0 } }, -- 0 -> 0
    { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0, 1 } }, -- -1 -> 1
    { { 0, 1 }, { 0, 2 } }, -- 1 -> 2
  }
  for _, test in ipairs(zigzag64_tests) do
    local input, expected = test[1], test[2]
    local actual = Protobuf.zigzag_encode64(input)
    assert_int64_eq(actual, expected[1], expected[2], string.format("zigzag_encode64({%d,%d})", input[1], input[2]))
  end

  -- ==========================================
  -- LENGTH-DELIMITED TESTS
  -- ==========================================

  -- Test: "testing" from official docs (12 07 74 65 73 74 69 6e 67)
  local test_str = "testing"
  local enc_str = Protobuf.encode_length_delimited(test_str)
  assert_bytes(enc_str, "0774657374696E67", "length_delimited('testing')")

  -- Roundtrip
  local dec_str, _ = Protobuf.decode_length_delimited(enc_str, 1)
  assert_eq(dec_str, test_str, "length_delimited roundtrip")

  -- ==========================================
  -- INT64 UTILITY TESTS
  -- ==========================================

  -- to_hex
  local hex = Protobuf.int64_to_hex({ 0x12345678, 0x9ABCDEF0 })
  assert_eq(hex, "123456789ABCDEF0", "int64_to_hex")

  -- to_number / from_number roundtrip
  local num = 123456789012345
  local hl = Protobuf.int64_from_number(num)
  local back = Protobuf.int64_to_number(hl)
  assert_eq(back, num, "int64_from_number/to_number roundtrip")

  -- equals
  assert_eq(Protobuf.int64_equals({ 1, 2 }, { 1, 2 }), true, "int64_equals same")
  assert_eq(Protobuf.int64_equals({ 1, 2 }, { 1, 3 }), false, "int64_equals diff")

  -- is_zero
  assert_eq(Protobuf.int64_is_zero({ 0, 0 }), true, "int64_is_zero true")
  assert_eq(Protobuf.int64_is_zero({ 0, 1 }), false, "int64_is_zero false")

  -- ==========================================
  -- SUMMARY
  -- ==========================================
  if failed > 0 then
    print(string.format("FAIL: %d/%d tests failed", failed, passed + failed))
    return false
  else
    print(string.format("PASS: All %d tests passed", passed))
    return true
  end
end

return Protobuf
