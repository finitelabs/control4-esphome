do
local _ENV = _ENV
package.preload[ "bitn._compat" ] = function( ... ) local arg = _G.arg;
--- @diagnostic disable: duplicate-set-field
--- @module "bitn._compat"
--- Internal compatibility layer for bitwise operations.
--- Provides feature detection and optimized primitives for use by bit16/bit32/bit64.
--- @class bitn._compat
local _compat = {}

--------------------------------------------------------------------------------
-- Helper functions (needed by all implementations)
--------------------------------------------------------------------------------

local math_floor = math.floor
local math_pow = math.pow or function(x, y)
  return x ^ y
end

--- Convert signed 32-bit to unsigned (for LuaJIT which returns signed values)
--- @param n number Potentially signed 32-bit value
--- @return number Unsigned 32-bit value
local function to_unsigned(n)
  if n < 0 then
    return n + 0x100000000
  end
  return n
end

_compat.to_unsigned = to_unsigned

-- Constants
local MASK32 = 0xFFFFFFFF

--------------------------------------------------------------------------------
-- Implementation 1: Native operators (Lua 5.3+)
--------------------------------------------------------------------------------

local ok, result = pcall(load, "return function(a,b) return a & b end")
if ok and result then
  local fn = result()
  if fn then
    -- Native operators available - define all functions using them
    local native_band = fn
    local native_bor = assert(load("return function(a,b) return a | b end"))()
    local native_bxor = assert(load("return function(a,b) return a ~ b end"))()
    local native_bnot = assert(load("return function(a) return ~a end"))()
    local native_lshift = assert(load("return function(a,n) return a << n end"))()
    local native_rshift = assert(load("return function(a,n) return a >> n end"))()

    _compat.has_native_ops = true
    _compat.has_bit_lib = false
    _compat.is_luajit = false

    function _compat.impl_name()
      return "native operators (Lua 5.3+)"
    end

    function _compat.band(a, b)
      return native_band(a, b)
    end

    function _compat.bor(a, b)
      return native_bor(a, b)
    end

    function _compat.bxor(a, b)
      return native_bxor(a, b)
    end

    function _compat.bnot(a)
      return native_band(native_bnot(a), MASK32)
    end

    function _compat.lshift(a, n)
      if n >= 32 then
        return 0
      end
      return native_band(native_lshift(a, n), MASK32)
    end

    function _compat.rshift(a, n)
      if n >= 32 then
        return 0
      end
      return native_rshift(native_band(a, MASK32), n)
    end

    function _compat.arshift(a, n)
      a = native_band(a, MASK32)
      local is_negative = a >= 0x80000000
      if n >= 32 then
        return is_negative and MASK32 or 0
      end
      local r = native_rshift(a, n)
      if is_negative then
        local fill_mask = native_lshift(MASK32, 32 - n)
        r = native_bor(r, native_band(fill_mask, MASK32))
      end
      return native_band(r, MASK32)
    end

    -- Raw operations provide direct access to native bit functions without the
    -- to_unsigned() wrapper. On Lua 5.3+, these are identical to wrapped versions
    -- since native operators already return unsigned values.
    -- Shifts must mask to 32 bits since native operators work on 64-bit values.
    _compat.raw_band = native_band
    _compat.raw_bor = native_bor
    _compat.raw_bxor = native_bxor
    _compat.raw_bnot = function(a)
      return native_band(native_bnot(a), MASK32)
    end
    _compat.raw_lshift = function(a, n)
      if n >= 32 then
        return 0
      end
      return native_band(native_lshift(a, n), MASK32)
    end
    _compat.raw_rshift = function(a, n)
      if n >= 32 then
        return 0
      end
      return native_rshift(native_band(a, MASK32), n)
    end
    _compat.raw_arshift = _compat.arshift
    -- No native rol/ror on Lua 5.3+
    _compat.raw_rol = nil
    _compat.raw_ror = nil

    return _compat
  end
end

--------------------------------------------------------------------------------
-- Implementation 2: Bit library (LuaJIT or Lua 5.2)
--------------------------------------------------------------------------------

local bit_lib
local is_luajit = false

-- Try LuaJIT's bit library first
ok, result = pcall(require, "bit")
if ok and result then
  bit_lib = result
  is_luajit = true
else
  -- Try Lua 5.2's bit32 library (use rawget to avoid recursion with our module name)
  bit_lib = rawget(_G, "bit32")
end

if bit_lib then
  -- Bit library available - define all functions using it
  local bit_band = assert(bit_lib.band)
  local bit_bor = assert(bit_lib.bor)
  local bit_bxor = assert(bit_lib.bxor)
  local bit_bnot = assert(bit_lib.bnot)
  local bit_lshift = assert(bit_lib.lshift)
  local bit_rshift = assert(bit_lib.rshift)
  local bit_arshift = assert(bit_lib.arshift)

  _compat.has_native_ops = false
  _compat.has_bit_lib = true
  _compat.is_luajit = is_luajit

  function _compat.impl_name()
    return "bit library"
  end

  if is_luajit then
    -- LuaJIT returns signed integers, need to convert to unsigned
    function _compat.band(a, b)
      return to_unsigned(bit_band(a, b))
    end

    function _compat.bor(a, b)
      return to_unsigned(bit_bor(a, b))
    end

    function _compat.bxor(a, b)
      return to_unsigned(bit_bxor(a, b))
    end

    function _compat.bnot(a)
      return to_unsigned(bit_bnot(a))
    end

    function _compat.lshift(a, n)
      if n >= 32 then
        return 0
      end
      return to_unsigned(bit_lshift(a, n))
    end

    function _compat.rshift(a, n)
      if n >= 32 then
        return 0
      end
      return to_unsigned(bit_rshift(a, n))
    end

    function _compat.arshift(a, n)
      a = to_unsigned(bit_band(a, MASK32))
      if n >= 32 then
        local is_negative = a >= 0x80000000
        return is_negative and MASK32 or 0
      end
      return to_unsigned(bit_arshift(a, n))
    end
  else
    -- Lua 5.2 bit32 library returns unsigned integers
    function _compat.band(a, b)
      return bit_band(a, b)
    end

    function _compat.bor(a, b)
      return bit_bor(a, b)
    end

    function _compat.bxor(a, b)
      return bit_bxor(a, b)
    end

    function _compat.bnot(a)
      return bit_band(bit_bnot(a), MASK32)
    end

    function _compat.lshift(a, n)
      if n >= 32 then
        return 0
      end
      return bit_band(bit_lshift(a, n), MASK32)
    end

    function _compat.rshift(a, n)
      if n >= 32 then
        return 0
      end
      return bit_rshift(bit_band(a, MASK32), n)
    end

    function _compat.arshift(a, n)
      a = bit_band(a, MASK32)
      if n >= 32 then
        local is_negative = a >= 0x80000000
        return is_negative and MASK32 or 0
      end
      return bit_band(bit_arshift(a, n), MASK32)
    end
  end

  -- Raw operations provide direct access to native bit functions without the
  -- to_unsigned() wrapper. On LuaJIT, these return signed 32-bit integers.
  -- On Lua 5.2 (bit32 library), these are identical to wrapped versions.
  _compat.raw_band = bit_band
  _compat.raw_bor = bit_bor
  _compat.raw_bxor = bit_bxor
  _compat.raw_bnot = bit_bnot
  _compat.raw_lshift = bit_lshift
  _compat.raw_rshift = bit_rshift
  _compat.raw_arshift = bit_arshift
  -- rol/ror only available on LuaJIT (bit library), not Lua 5.2 (bit32 library)
  if bit_lib.rol then
    _compat.raw_rol = bit_lib.rol
    _compat.raw_ror = bit_lib.ror
  else
    _compat.raw_rol = nil
    _compat.raw_ror = nil
  end

  return _compat
end

--------------------------------------------------------------------------------
-- Implementation 3: Pure Lua fallback
--------------------------------------------------------------------------------

_compat.has_native_ops = false
_compat.has_bit_lib = false
_compat.is_luajit = false

function _compat.impl_name()
  return "pure Lua"
end

function _compat.band(a, b)
  local r = 0
  local bit_val = 1
  for _ = 0, 31 do
    if (a % 2 == 1) and (b % 2 == 1) then
      r = r + bit_val
    end
    a = math_floor(a / 2)
    b = math_floor(b / 2)
    bit_val = bit_val * 2
    if a == 0 and b == 0 then
      break
    end
  end
  return r
end

function _compat.bor(a, b)
  local r = 0
  local bit_val = 1
  for _ = 0, 31 do
    if (a % 2 == 1) or (b % 2 == 1) then
      r = r + bit_val
    end
    a = math_floor(a / 2)
    b = math_floor(b / 2)
    bit_val = bit_val * 2
    if a == 0 and b == 0 then
      break
    end
  end
  return r
end

function _compat.bxor(a, b)
  local r = 0
  local bit_val = 1
  for _ = 0, 31 do
    if (a % 2) ~= (b % 2) then
      r = r + bit_val
    end
    a = math_floor(a / 2)
    b = math_floor(b / 2)
    bit_val = bit_val * 2
    if a == 0 and b == 0 then
      break
    end
  end
  return r
end

function _compat.bnot(a)
  return MASK32 - (math_floor(a) % 0x100000000)
end

function _compat.lshift(a, n)
  if n >= 32 then
    return 0
  end
  return math_floor((a * math_pow(2, n)) % 0x100000000)
end

function _compat.rshift(a, n)
  if n >= 32 then
    return 0
  end
  a = math_floor(a) % 0x100000000
  return math_floor(a / math_pow(2, n))
end

function _compat.arshift(a, n)
  a = math_floor(a) % 0x100000000
  local is_negative = a >= 0x80000000
  if n >= 32 then
    return is_negative and MASK32 or 0
  end
  local r = math_floor(a / math_pow(2, n))
  if is_negative then
    local fill_mask = MASK32 - (math_pow(2, 32 - n) - 1)
    r = _compat.bor(r, fill_mask)
  end
  return r
end

-- Raw operations for pure Lua fallback are identical to wrapped versions
-- since there's no native library to bypass.
_compat.raw_band = _compat.band
_compat.raw_bor = _compat.bor
_compat.raw_bxor = _compat.bxor
_compat.raw_bnot = _compat.bnot
_compat.raw_lshift = _compat.lshift
_compat.raw_rshift = _compat.rshift
_compat.raw_arshift = _compat.arshift
_compat.raw_rol = nil
_compat.raw_ror = nil

return _compat
end
end

do
local _ENV = _ENV
package.preload[ "bitn.bit16" ] = function( ... ) local arg = _G.arg;
--- @module "bitn.bit16"
--- 16-bit bitwise operations library.
--- This module provides a complete, version-agnostic implementation of 16-bit
--- bitwise operations that works across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- Uses native bit operations where available for optimal performance.
--- @class bitn.bit16
local bit16 = {}

local _compat = require("bitn._compat")

-- Cache methods as locals for faster access
local compat_band = _compat.band
local compat_bnot = _compat.bnot
local compat_bor = _compat.bor
local compat_bxor = _compat.bxor
local compat_lshift = _compat.lshift
local compat_rshift = _compat.rshift
local impl_name = _compat.impl_name
local math_floor = math.floor

-- 16-bit mask constant
local MASK16 = 0xFFFF

--------------------------------------------------------------------------------
-- Core operations
--------------------------------------------------------------------------------

--- Ensure value fits in 16-bit unsigned integer.
--- @param n number Input value
--- @return integer result 16-bit unsigned integer (0 to 0xFFFF)
function bit16.mask(n)
  return compat_band(math_floor(n), MASK16)
end

--- Bitwise AND operation.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of a AND b
function bit16.band(a, b)
  return compat_band(compat_band(a, MASK16), compat_band(b, MASK16))
end

--- Bitwise OR operation.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of a OR b
function bit16.bor(a, b)
  return compat_band(compat_bor(a, b), MASK16)
end

--- Bitwise XOR operation.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of a XOR b
function bit16.bxor(a, b)
  return compat_band(compat_bxor(a, b), MASK16)
end

--- Bitwise NOT operation.
--- @param a integer Operand (16-bit)
--- @return integer result Result of NOT a
function bit16.bnot(a)
  return compat_band(compat_bnot(a), MASK16)
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
  return compat_band(compat_lshift(compat_band(a, MASK16), n), MASK16)
end

--- Logical right shift operation (fills with 0s).
--- @param a integer Value to shift (16-bit)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n (logical)
function bit16.rshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  if n >= 16 then
    return 0
  end
  return compat_rshift(compat_band(a, MASK16), n)
end

--- Arithmetic right shift operation (sign-extending, fills with sign bit).
--- @param a integer Value to shift (16-bit, treated as signed)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n with sign extension
function bit16.arshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  a = compat_band(a, MASK16)

  -- Check if sign bit is set (bit 15)
  local is_negative = a >= 0x8000

  if n >= 16 then
    return is_negative and MASK16 or 0
  end

  -- Perform logical right shift
  local result = compat_rshift(a, n)

  -- If original was negative, fill high bits with 1s
  if is_negative then
    local fill_mask = compat_band(compat_lshift(MASK16, 16 - n), MASK16)
    result = compat_bor(result, fill_mask)
  end

  return compat_band(result, MASK16)
end

--- Left rotate operation.
--- @param x integer Value to rotate (16-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x left by n positions
function bit16.rol(x, n)
  n = n % 16
  x = compat_band(x, MASK16)
  return compat_band(compat_bor(compat_lshift(x, n), compat_rshift(x, 16 - n)), MASK16)
end

--- Right rotate operation.
--- @param x integer Value to rotate (16-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x right by n positions
function bit16.ror(x, n)
  n = n % 16
  x = compat_band(x, MASK16)
  return compat_band(compat_bor(compat_rshift(x, n), compat_lshift(x, 16 - n)), MASK16)
end

--- 16-bit addition with overflow handling.
--- @param a integer First operand (16-bit)
--- @param b integer Second operand (16-bit)
--- @return integer result Result of (a + b) mod 2^16
function bit16.add(a, b)
  return compat_band(compat_band(a, MASK16) + compat_band(b, MASK16), MASK16)
end

--------------------------------------------------------------------------------
-- Byte conversion functions
--------------------------------------------------------------------------------

local string_char = string.char
local string_byte = string.byte

--- Convert 16-bit unsigned integer to 2 bytes (big-endian).
--- @param n integer 16-bit unsigned integer
--- @return string bytes 2-byte string in big-endian order
function bit16.u16_to_be_bytes(n)
  n = compat_band(n, MASK16)
  return string_char(math_floor(n / 256), n % 256)
end

--- Convert 16-bit unsigned integer to 2 bytes (little-endian).
--- @param n integer 16-bit unsigned integer
--- @return string bytes 2-byte string in little-endian order
function bit16.u16_to_le_bytes(n)
  n = compat_band(n, MASK16)
  return string_char(n % 256, math_floor(n / 256))
end

--- Convert 2 bytes to 16-bit unsigned integer (big-endian).
--- @param str string Binary string (at least 2 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 16-bit unsigned integer
function bit16.be_bytes_to_u16(str, offset)
  offset = offset or 1
  assert(#str >= offset + 1, "Insufficient bytes for u16")
  local b1, b2 = string_byte(str, offset, offset + 1)
  return b1 * 256 + b2
end

--- Convert 2 bytes to 16-bit unsigned integer (little-endian).
--- @param str string Binary string (at least 2 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 16-bit unsigned integer
function bit16.le_bytes_to_u16(str, offset)
  offset = offset or 1
  assert(#str >= offset + 1, "Insufficient bytes for u16")
  local b1, b2 = string_byte(str, offset, offset + 1)
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
  print(string.format("  Using: %s", impl_name()))
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
        if type(result) ~= "string" then
          print("    Expected: string")
          print("    Got:      " .. type(result))
        else
          local exp_hex, got_hex = "", ""
          for i = 1, #test.expected do
            exp_hex = exp_hex .. string.format("%02X", string.byte(test.expected, i))
          end
          for i = 1, #result do
            got_hex = got_hex .. string.format("%02X", string.byte(result, i))
          end
          print("    Expected: " .. exp_hex)
          print("    Got:      " .. got_hex)
        end
      else
        print(string.format("    Expected: 0x%04X", test.expected))
        print(string.format("    Got:      0x%04X", result))
      end
    end
  end

  print(string.format("\n16-bit operations: %d/%d tests passed\n", passed, total))
  return passed == total
end

--------------------------------------------------------------------------------
-- Benchmarking
--------------------------------------------------------------------------------

local benchmark_op = require("bitn.utils.benchmark").benchmark_op

--- Run performance benchmarks for 16-bit operations.
function bit16.benchmark()
  local iterations = 100000

  print("16-bit Bitwise Operations:")
  print(string.format("  Implementation: %s", impl_name()))

  -- Test values
  local a, b = 0xAAAA, 0x5555

  benchmark_op("band", function()
    bit16.band(a, b)
  end, iterations)

  benchmark_op("bor", function()
    bit16.bor(a, b)
  end, iterations)

  benchmark_op("bxor", function()
    bit16.bxor(a, b)
  end, iterations)

  benchmark_op("bnot", function()
    bit16.bnot(a)
  end, iterations)

  print("\n16-bit Shift Operations:")

  benchmark_op("lshift", function()
    bit16.lshift(a, 4)
  end, iterations)

  benchmark_op("rshift", function()
    bit16.rshift(a, 4)
  end, iterations)

  benchmark_op("arshift", function()
    bit16.arshift(0x8000, 4)
  end, iterations)

  print("\n16-bit Rotate Operations:")

  benchmark_op("rol", function()
    bit16.rol(a, 4)
  end, iterations)

  benchmark_op("ror", function()
    bit16.ror(a, 4)
  end, iterations)

  print("\n16-bit Arithmetic:")

  benchmark_op("add", function()
    bit16.add(a, b)
  end, iterations)

  benchmark_op("mask", function()
    bit16.mask(0x12345)
  end, iterations)

  print("\n16-bit Byte Conversions:")

  local bytes_be = bit16.u16_to_be_bytes(0x1234)
  local bytes_le = bit16.u16_to_le_bytes(0x1234)

  benchmark_op("u16_to_be_bytes", function()
    bit16.u16_to_be_bytes(0x1234)
  end, iterations)

  benchmark_op("u16_to_le_bytes", function()
    bit16.u16_to_le_bytes(0x1234)
  end, iterations)

  benchmark_op("be_bytes_to_u16", function()
    bit16.be_bytes_to_u16(bytes_be)
  end, iterations)

  benchmark_op("le_bytes_to_u16", function()
    bit16.le_bytes_to_u16(bytes_le)
  end, iterations)
end

return bit16
end
end

do
local _ENV = _ENV
package.preload[ "bitn.bit32" ] = function( ... ) local arg = _G.arg;
--- @module "bitn.bit32"
--- 32-bit bitwise operations library.
--- This module provides a complete, version-agnostic implementation of 32-bit
--- bitwise operations that works across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- Uses native bit operations where available for optimal performance.
--- @class bitn.bit32
local bit32 = {}

local _compat = require("bitn._compat")

-- Cache methods as locals for faster access
local compat_arshift = _compat.arshift
local compat_band = _compat.band
local compat_bnot = _compat.bnot
local compat_bor = _compat.bor
local compat_bxor = _compat.bxor
local compat_lshift = _compat.lshift
local compat_raw_arshift = _compat.raw_arshift
local compat_raw_band = _compat.raw_band
local compat_raw_bnot = _compat.raw_bnot
local compat_raw_bor = _compat.raw_bor
local compat_raw_bxor = _compat.raw_bxor
local compat_raw_lshift = _compat.raw_lshift
local compat_raw_rol = _compat.raw_rol
local compat_raw_ror = _compat.raw_ror
local compat_raw_rshift = _compat.raw_rshift
local compat_rshift = _compat.rshift
local compat_to_unsigned = _compat.to_unsigned
local impl_name = _compat.impl_name
local math_floor = math.floor

-- 32-bit mask constant
local MASK32 = 0xFFFFFFFF

--------------------------------------------------------------------------------
-- Core operations
--------------------------------------------------------------------------------

--- Convert signed 32-bit value to unsigned.
--- On LuaJIT, bit operations return signed 32-bit integers. This function
--- converts them to unsigned by adding 2^32 to negative values.
--- @param n number Potentially signed 32-bit value
--- @return integer result Unsigned 32-bit value (0 to 0xFFFFFFFF)
function bit32.to_unsigned(n)
  return compat_to_unsigned(n)
end

--- Ensure value fits in 32-bit unsigned integer.
--- @param n number Input value
--- @return integer result 32-bit unsigned integer (0 to 0xFFFFFFFF)
function bit32.mask(n)
  return compat_band(math_floor(n), MASK32)
end

--- Bitwise AND operation.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of a AND b
function bit32.band(a, b)
  return compat_band(compat_band(a, MASK32), compat_band(b, MASK32))
end

--- Bitwise OR operation.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of a OR b
function bit32.bor(a, b)
  return compat_band(compat_bor(a, b), MASK32)
end

--- Bitwise XOR operation.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of a XOR b
function bit32.bxor(a, b)
  return compat_band(compat_bxor(a, b), MASK32)
end

--- Bitwise NOT operation.
--- @param a integer Operand (32-bit)
--- @return integer result Result of NOT a
function bit32.bnot(a)
  return compat_band(compat_bnot(a), MASK32)
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
  return compat_band(compat_lshift(compat_band(a, MASK32), n), MASK32)
end

--- Logical right shift operation (fills with 0s).
--- @param a integer Value to shift (32-bit)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n (logical)
function bit32.rshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  if n >= 32 then
    return 0
  end
  return compat_rshift(compat_band(a, MASK32), n)
end

--- Arithmetic right shift operation (sign-extending, fills with sign bit).
--- @param a integer Value to shift (32-bit, treated as signed)
--- @param n integer Number of positions to shift (must be >= 0)
--- @return integer result Result of a >> n with sign extension
function bit32.arshift(a, n)
  assert(n >= 0, "Shift amount must be non-negative")
  return compat_arshift(a, n)
end

--- Left rotate operation.
--- @param x integer Value to rotate (32-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x left by n positions
function bit32.rol(x, n)
  n = n % 32
  x = compat_band(x, MASK32)
  return compat_band(compat_bor(compat_lshift(x, n), compat_rshift(x, 32 - n)), MASK32)
end

--- Right rotate operation.
--- @param x integer Value to rotate (32-bit)
--- @param n integer Number of positions to rotate
--- @return integer result Result of rotating x right by n positions
function bit32.ror(x, n)
  n = n % 32
  x = compat_band(x, MASK32)
  return compat_band(compat_bor(compat_rshift(x, n), compat_lshift(x, 32 - n)), MASK32)
end

--- 32-bit addition with overflow handling.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of (a + b) mod 2^32
function bit32.add(a, b)
  return compat_band(compat_band(a, MASK32) + compat_band(b, MASK32), MASK32)
end

--------------------------------------------------------------------------------
-- Raw (zero-overhead) operations
--------------------------------------------------------------------------------
-- These functions provide direct access to the underlying bit library without
-- unsigned conversion. On LuaJIT, results may be negative when the high bit
-- is set. The bit pattern is identical to the regular function.
-- Use for performance-critical code where sign interpretation doesn't matter.

--- Raw bitwise AND (may return signed on LuaJIT).
--- @type fun(a: integer, b: integer): integer
--- @see bit32.band For guaranteed unsigned results
bit32.raw_band = compat_raw_band

--- Raw bitwise OR (may return signed on LuaJIT).
--- @type fun(a: integer, b: integer): integer
--- @see bit32.bor For guaranteed unsigned results
bit32.raw_bor = compat_raw_bor

--- Raw bitwise XOR (may return signed on LuaJIT).
--- @type fun(a: integer, b: integer): integer
--- @see bit32.bxor For guaranteed unsigned results
bit32.raw_bxor = compat_raw_bxor

--- Raw bitwise NOT (may return signed on LuaJIT).
--- @type fun(a: integer): integer
--- @see bit32.bnot For guaranteed unsigned results
bit32.raw_bnot = compat_raw_bnot

--- Raw left shift (may return signed on LuaJIT).
--- @type fun(a: integer, n: integer): integer
--- @see bit32.lshift For guaranteed unsigned results
bit32.raw_lshift = compat_raw_lshift

--- Raw logical right shift (may return signed on LuaJIT).
--- @type fun(a: integer, n: integer): integer
--- @see bit32.rshift For guaranteed unsigned results
bit32.raw_rshift = compat_raw_rshift

--- Raw arithmetic right shift (may return signed on LuaJIT).
--- @type fun(a: integer, n: integer): integer
--- @see bit32.arshift For guaranteed unsigned results
bit32.raw_arshift = compat_raw_arshift

--- Raw left rotate (uses native bit.rol on LuaJIT, falls back to computed otherwise).
--- @type fun(x: integer, n: integer): integer
--- @see bit32.rol For guaranteed unsigned results
bit32.raw_rol = compat_raw_rol or bit32.rol

--- Raw right rotate (uses native bit.ror on LuaJIT, falls back to computed otherwise).
--- @type fun(x: integer, n: integer): integer
--- @see bit32.ror For guaranteed unsigned results
bit32.raw_ror = compat_raw_ror or bit32.ror

--- Raw 32-bit addition with overflow handling.
--- @param a integer First operand (32-bit)
--- @param b integer Second operand (32-bit)
--- @return integer result Result of (a + b) mod 2^32 (signed on LuaJIT, unsigned elsewhere)
--- @see bit32.add For guaranteed unsigned results
function bit32.raw_add(a, b)
  return compat_raw_band(a + b, MASK32)
end

--------------------------------------------------------------------------------
-- Byte conversion functions
--------------------------------------------------------------------------------

local string_char = string.char
local string_byte = string.byte

--- Convert 32-bit unsigned integer to 4 bytes (big-endian).
--- @param n integer 32-bit unsigned integer
--- @return string bytes 4-byte string in big-endian order
function bit32.u32_to_be_bytes(n)
  n = compat_band(n, MASK32)
  return string_char(
    math_floor(n / 16777216) % 256,
    math_floor(n / 65536) % 256,
    math_floor(n / 256) % 256,
    math_floor(n % 256)
  )
end

--- Convert 32-bit unsigned integer to 4 bytes (little-endian).
--- @param n integer 32-bit unsigned integer
--- @return string bytes 4-byte string in little-endian order
function bit32.u32_to_le_bytes(n)
  n = compat_band(n, MASK32)
  return string_char(
    math_floor(n % 256),
    math_floor(n / 256) % 256,
    math_floor(n / 65536) % 256,
    math_floor(n / 16777216) % 256
  )
end

--- Convert 4 bytes to 32-bit unsigned integer (big-endian).
--- @param str string Binary string (at least 4 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 32-bit unsigned integer
function bit32.be_bytes_to_u32(str, offset)
  offset = offset or 1
  assert(#str >= offset + 3, "Insufficient bytes for u32")
  local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

--- Convert 4 bytes to 32-bit unsigned integer (little-endian).
--- @param str string Binary string (at least 4 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 32-bit unsigned integer
function bit32.le_bytes_to_u32(str, offset)
  offset = offset or 1
  assert(#str >= offset + 3, "Insufficient bytes for u32")
  local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
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
  print(string.format("  Using: %s", impl_name()))
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

    -- to_unsigned tests
    { name = "to_unsigned(0)", fn = bit32.to_unsigned, inputs = { 0 }, expected = 0 },
    { name = "to_unsigned(1)", fn = bit32.to_unsigned, inputs = { 1 }, expected = 1 },
    { name = "to_unsigned(0x7FFFFFFF)", fn = bit32.to_unsigned, inputs = { 0x7FFFFFFF }, expected = 0x7FFFFFFF },
    { name = "to_unsigned(-1)", fn = bit32.to_unsigned, inputs = { -1 }, expected = 0xFFFFFFFF },
    { name = "to_unsigned(-2147483648)", fn = bit32.to_unsigned, inputs = { -2147483648 }, expected = 0x80000000 },
    { name = "to_unsigned(-2147483647)", fn = bit32.to_unsigned, inputs = { -2147483647 }, expected = 0x80000001 },

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
      expected = string_char(0x00, 0x00, 0x00, 0x00),
    },
    {
      name = "u32_to_be_bytes(1)",
      fn = bit32.u32_to_be_bytes,
      inputs = { 1 },
      expected = string_char(0x00, 0x00, 0x00, 0x01),
    },
    {
      name = "u32_to_be_bytes(0x12345678)",
      fn = bit32.u32_to_be_bytes,
      inputs = { 0x12345678 },
      expected = string_char(0x12, 0x34, 0x56, 0x78),
    },
    {
      name = "u32_to_be_bytes(0xFFFFFFFF)",
      fn = bit32.u32_to_be_bytes,
      inputs = { 0xFFFFFFFF },
      expected = string_char(0xFF, 0xFF, 0xFF, 0xFF),
    },

    -- u32_to_le_bytes tests
    {
      name = "u32_to_le_bytes(0)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 0 },
      expected = string_char(0x00, 0x00, 0x00, 0x00),
    },
    {
      name = "u32_to_le_bytes(1)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 1 },
      expected = string_char(0x01, 0x00, 0x00, 0x00),
    },
    {
      name = "u32_to_le_bytes(0x12345678)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 0x12345678 },
      expected = string_char(0x78, 0x56, 0x34, 0x12),
    },
    {
      name = "u32_to_le_bytes(0xFFFFFFFF)",
      fn = bit32.u32_to_le_bytes,
      inputs = { 0xFFFFFFFF },
      expected = string_char(0xFF, 0xFF, 0xFF, 0xFF),
    },

    -- be_bytes_to_u32 tests
    {
      name = "be_bytes_to_u32(0x00000000)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string_char(0x00, 0x00, 0x00, 0x00) },
      expected = 0,
    },
    {
      name = "be_bytes_to_u32(0x00000001)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string_char(0x00, 0x00, 0x00, 0x01) },
      expected = 1,
    },
    {
      name = "be_bytes_to_u32(0x12345678)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string_char(0x12, 0x34, 0x56, 0x78) },
      expected = 0x12345678,
    },
    {
      name = "be_bytes_to_u32(0xFFFFFFFF)",
      fn = bit32.be_bytes_to_u32,
      inputs = { string_char(0xFF, 0xFF, 0xFF, 0xFF) },
      expected = 0xFFFFFFFF,
    },

    -- le_bytes_to_u32 tests
    {
      name = "le_bytes_to_u32(0x00000000)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string_char(0x00, 0x00, 0x00, 0x00) },
      expected = 0,
    },
    {
      name = "le_bytes_to_u32(0x00000001)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string_char(0x01, 0x00, 0x00, 0x00) },
      expected = 1,
    },
    {
      name = "le_bytes_to_u32(0x12345678)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string_char(0x78, 0x56, 0x34, 0x12) },
      expected = 0x12345678,
    },
    {
      name = "le_bytes_to_u32(0xFFFFFFFF)",
      fn = bit32.le_bytes_to_u32,
      inputs = { string_char(0xFF, 0xFF, 0xFF, 0xFF) },
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
          exp_hex = exp_hex .. string.format("%02X", string_byte(test.expected, i))
        end
        for i = 1, #result do
          got_hex = got_hex .. string.format("%02X", string_byte(result, i))
        end
        print("    Expected: " .. exp_hex)
        print("    Got:      " .. got_hex)
      else
        print(string.format("    Expected: 0x%08X", test.expected))
        print(string.format("    Got:      0x%08X", result))
      end
    end
  end

  -- Test raw_* operations
  print("\n  Testing raw_* operations...")

  local raw_tests = {
    -- Core bitwise (test high-bit cases where sign matters)
    {
      name = "raw_band(0xFFFFFFFF, 0x80000000)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_band(0xFFFFFFFF, 0x80000000))
      end,
      expected = bit32.band(0xFFFFFFFF, 0x80000000),
    },
    {
      name = "raw_bor(0x80000000, 0x00000001)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_bor(0x80000000, 0x00000001))
      end,
      expected = bit32.bor(0x80000000, 0x00000001),
    },
    {
      name = "raw_bxor(0xAAAAAAAA, 0x55555555)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_bxor(0xAAAAAAAA, 0x55555555))
      end,
      expected = bit32.bxor(0xAAAAAAAA, 0x55555555),
    },
    {
      name = "raw_bnot(0)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_bnot(0))
      end,
      expected = bit32.bnot(0),
    },
    {
      name = "raw_bnot(0x80000000)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_bnot(0x80000000))
      end,
      expected = bit32.bnot(0x80000000),
    },

    -- Shifts
    {
      name = "raw_lshift(1, 31)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_lshift(1, 31))
      end,
      expected = bit32.lshift(1, 31),
    },
    {
      name = "raw_rshift(0x80000000, 1)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_rshift(0x80000000, 1))
      end,
      expected = bit32.rshift(0x80000000, 1),
    },
    {
      name = "raw_arshift(0x80000000, 1)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_arshift(0x80000000, 1))
      end,
      expected = bit32.arshift(0x80000000, 1),
    },

    -- Shift masking (ensure 32-bit semantics on all platforms)
    -- Note: n >= 32 behavior is platform-specific for raw shifts; callers should use n in 0-31
    {
      name = "raw_lshift(0x12345678, 16) masks to 32 bits",
      fn = function()
        return bit32.to_unsigned(bit32.raw_lshift(0x12345678, 16))
      end,
      expected = 0x56780000,
    },
    {
      name = "raw_rshift(0xFFFFFFFF, 16) masks to 32 bits",
      fn = function()
        return bit32.to_unsigned(bit32.raw_rshift(0xFFFFFFFF, 16))
      end,
      expected = 0x0000FFFF,
    },

    -- Addition overflow
    {
      name = "raw_add(0xFFFFFFFF, 1)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_add(0xFFFFFFFF, 1))
      end,
      expected = bit32.add(0xFFFFFFFF, 1),
    },
    {
      name = "raw_add(0x80000000, 0x80000000)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_add(0x80000000, 0x80000000))
      end,
      expected = bit32.add(0x80000000, 0x80000000),
    },
  }

  for _, test in ipairs(raw_tests) do
    total = total + 1
    local result = test.fn()
    if result == test.expected then
      print("  PASS: " .. test.name)
      passed = passed + 1
    else
      print("  FAIL: " .. test.name)
      print(string.format("    Expected: 0x%08X", test.expected))
      print(string.format("    Got:      0x%08X", result))
    end
  end

  -- Test raw_rol/raw_ror (always available - falls back to computed if no native)
  print("\n  Testing raw_rol/raw_ror...")
  local rol_ror_tests = {
    {
      name = "raw_rol(0x80000000, 1)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_rol(0x80000000, 1))
      end,
      expected = bit32.rol(0x80000000, 1),
    },
    {
      name = "raw_rol(0x12345678, 8)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_rol(0x12345678, 8))
      end,
      expected = bit32.rol(0x12345678, 8),
    },
    {
      name = "raw_ror(1, 1)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_ror(1, 1))
      end,
      expected = bit32.ror(1, 1),
    },
    {
      name = "raw_ror(0x12345678, 8)",
      fn = function()
        return bit32.to_unsigned(bit32.raw_ror(0x12345678, 8))
      end,
      expected = bit32.ror(0x12345678, 8),
    },
  }

  for _, test in ipairs(rol_ror_tests) do
    total = total + 1
    local result = test.fn()
    if result == test.expected then
      print("  PASS: " .. test.name)
      passed = passed + 1
    else
      print("  FAIL: " .. test.name)
      print(string.format("    Expected: 0x%08X", test.expected))
      print(string.format("    Got:      0x%08X", result))
    end
  end

  -- Test zero-overhead on LuaJIT (identity check)
  if _compat.is_luajit then
    print("\n  Testing zero-overhead (LuaJIT function identity)...")
    local bit = require("bit")

    local identity_tests = {
      { name = "raw_band == bit.band", got = bit32.raw_band, expected = bit.band },
      { name = "raw_bor == bit.bor", got = bit32.raw_bor, expected = bit.bor },
      { name = "raw_bxor == bit.bxor", got = bit32.raw_bxor, expected = bit.bxor },
      { name = "raw_bnot == bit.bnot", got = bit32.raw_bnot, expected = bit.bnot },
      { name = "raw_lshift == bit.lshift", got = bit32.raw_lshift, expected = bit.lshift },
      { name = "raw_rshift == bit.rshift", got = bit32.raw_rshift, expected = bit.rshift },
      { name = "raw_arshift == bit.arshift", got = bit32.raw_arshift, expected = bit.arshift },
      { name = "raw_rol == bit.rol", got = bit32.raw_rol, expected = bit.rol },
      { name = "raw_ror == bit.ror", got = bit32.raw_ror, expected = bit.ror },
    }

    for _, test in ipairs(identity_tests) do
      total = total + 1
      if rawequal(test.got, test.expected) then
        print("  PASS: " .. test.name)
        passed = passed + 1
      else
        print("  FAIL: " .. test.name .. " (not identical function reference)")
      end
    end
  end

  print(string.format("\n32-bit operations: %d/%d tests passed\n", passed, total))
  return passed == total
end

--------------------------------------------------------------------------------
-- Benchmarking
--------------------------------------------------------------------------------

local benchmark_op = require("bitn.utils.benchmark").benchmark_op

--- Run performance benchmarks for 32-bit operations.
function bit32.benchmark()
  local iterations = 100000

  print("32-bit Bitwise Operations:")
  print(string.format("  Implementation: %s", impl_name()))

  -- Test values
  local a, b = 0xAAAAAAAA, 0x55555555

  benchmark_op("band", function()
    bit32.band(a, b)
  end, iterations)

  benchmark_op("bor", function()
    bit32.bor(a, b)
  end, iterations)

  benchmark_op("bxor", function()
    bit32.bxor(a, b)
  end, iterations)

  benchmark_op("bnot", function()
    bit32.bnot(a)
  end, iterations)

  print("\n32-bit Shift Operations:")

  benchmark_op("lshift", function()
    bit32.lshift(a, 8)
  end, iterations)

  benchmark_op("rshift", function()
    bit32.rshift(a, 8)
  end, iterations)

  benchmark_op("arshift", function()
    bit32.arshift(0x80000000, 8)
  end, iterations)

  print("\n32-bit Rotate Operations:")

  benchmark_op("rol", function()
    bit32.rol(a, 8)
  end, iterations)

  benchmark_op("ror", function()
    bit32.ror(a, 8)
  end, iterations)

  print("\n32-bit Arithmetic:")

  benchmark_op("add", function()
    bit32.add(a, b)
  end, iterations)

  benchmark_op("mask", function()
    bit32.mask(0x123456789)
  end, iterations)

  print("\n32-bit Byte Conversions:")

  local bytes_be = bit32.u32_to_be_bytes(0x12345678)
  local bytes_le = bit32.u32_to_le_bytes(0x12345678)

  benchmark_op("u32_to_be_bytes", function()
    bit32.u32_to_be_bytes(0x12345678)
  end, iterations)

  benchmark_op("u32_to_le_bytes", function()
    bit32.u32_to_le_bytes(0x12345678)
  end, iterations)

  benchmark_op("be_bytes_to_u32", function()
    bit32.be_bytes_to_u32(bytes_be)
  end, iterations)

  benchmark_op("le_bytes_to_u32", function()
    bit32.le_bytes_to_u32(bytes_le)
  end, iterations)
end

return bit32
end
end

do
local _ENV = _ENV
package.preload[ "bitn.bit64" ] = function( ... ) local arg = _G.arg;
--- @module "bitn.bit64"
--- 64-bit bitwise operations library.
--- This module provides 64-bit bitwise operations using {high, low} pairs,
--- where high is the upper 32 bits and low is the lower 32 bits.
--- Works across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- Uses native bit operations where available for optimal performance.
--- @class bitn.bit64
local bit64 = {}

local bit32 = require("bitn.bit32")
local _compat = require("bitn._compat")

-- Cache methods as locals for faster access
local bit32_arshift = bit32.arshift
local bit32_band = bit32.band
local bit32_be_bytes_to_u32 = bit32.be_bytes_to_u32
local bit32_bnot = bit32.bnot
local bit32_bor = bit32.bor
local bit32_bxor = bit32.bxor
local bit32_le_bytes_to_u32 = bit32.le_bytes_to_u32
local bit32_lshift = bit32.lshift
local bit32_raw_arshift = bit32.raw_arshift
local bit32_raw_band = bit32.raw_band
local bit32_raw_bnot = bit32.raw_bnot
local bit32_raw_bor = bit32.raw_bor
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_lshift = bit32.raw_lshift
local bit32_raw_rshift = bit32.raw_rshift
local bit32_rshift = bit32.rshift
local bit32_u32_to_be_bytes = bit32.u32_to_be_bytes
local bit32_u32_to_le_bytes = bit32.u32_to_le_bytes
local impl_name = _compat.impl_name

-- Private metatable for Int64 type identification
local Int64Meta = { __name = "Int64" }

-- Type definitions
--- @alias Int64HighLow [integer, integer] Array with [1]=high 32 bits, [2]=low 32 bits

--------------------------------------------------------------------------------
-- Constructor and type checking
--------------------------------------------------------------------------------

--- Create a new Int64 value with metatable marker.
--- Normalizes signed 32-bit values to unsigned (for LuaJIT raw_* compatibility).
--- @param high? integer Upper 32 bits (default: 0)
--- @param low? integer Lower 32 bits (default: 0)
--- @return Int64HighLow value Int64 value with metatable marker
function bit64.new(high, low)
  high = high or 0
  low = low or 0
  -- Normalize signed to unsigned (handles LuaJIT raw_* results)
  if high < 0 then
    high = high + 0x100000000
  end
  if low < 0 then
    low = low + 0x100000000
  end
  return setmetatable({ high, low }, Int64Meta)
end

--- Check if a value is an Int64 (created by bit64 functions).
--- @param value any Value to check
--- @return boolean is_int64 True if value is an Int64
function bit64.is_int64(value)
  return type(value) == "table" and getmetatable(value) == Int64Meta
end

--------------------------------------------------------------------------------
-- Bitwise operations
--------------------------------------------------------------------------------

--- Bitwise AND operation.
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} AND result
function bit64.band(a, b)
  return bit64.new(bit32_band(a[1], b[1]), bit32_band(a[2], b[2]))
end

--- Bitwise OR operation.
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} OR result
function bit64.bor(a, b)
  return bit64.new(bit32_bor(a[1], b[1]), bit32_bor(a[2], b[2]))
end

--- Bitwise XOR operation.
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} XOR result
function bit64.bxor(a, b)
  return bit64.new(bit32_bxor(a[1], b[1]), bit32_bxor(a[2], b[2]))
end

--- Bitwise NOT operation.
--- @param a Int64HighLow Operand {high, low}
--- @return Int64HighLow result {high, low} NOT result
function bit64.bnot(a)
  return bit64.new(bit32_bnot(a[1]), bit32_bnot(a[2]))
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
    return bit64.new(x[1], x[2])
  elseif n >= 64 then
    return bit64.new(0, 0)
  elseif n >= 32 then
    -- Shift by 32 or more: low becomes 0, high gets bits from low
    return bit64.new(bit32_lshift(x[2], n - 32), 0)
  else
    -- Shift by less than 32
    local new_high = bit32_bor(bit32_lshift(x[1], n), bit32_rshift(x[2], 32 - n))
    local new_low = bit32_lshift(x[2], n)
    return bit64.new(new_high, new_low)
  end
end

--- Logical right shift operation (fills with 0s).
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.rshift(x, n)
  if n == 0 then
    return bit64.new(x[1], x[2])
  elseif n >= 64 then
    return bit64.new(0, 0)
  elseif n >= 32 then
    -- Shift by 32 or more: high becomes 0, low gets bits from high
    return bit64.new(0, bit32_rshift(x[1], n - 32))
  else
    -- Shift by less than 32
    local new_low = bit32_bor(bit32_rshift(x[2], n), bit32_lshift(x[1], 32 - n))
    local new_high = bit32_rshift(x[1], n)
    return bit64.new(new_high, new_low)
  end
end

--- Arithmetic right shift operation (sign-extending, fills with sign bit).
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.arshift(x, n)
  if n == 0 then
    return bit64.new(x[1], x[2])
  end

  -- Check sign bit (bit 31 of high word)
  local is_negative = bit32_band(x[1], 0x80000000) ~= 0

  if n >= 64 then
    -- All bits shift out, result is all 1s if negative, all 0s if positive
    if is_negative then
      return bit64.new(0xFFFFFFFF, 0xFFFFFFFF)
    else
      return bit64.new(0, 0)
    end
  elseif n >= 32 then
    -- High word shifts into low, high fills with sign
    local new_low = bit32_arshift(x[1], n - 32)
    local new_high = is_negative and 0xFFFFFFFF or 0
    return bit64.new(new_high, new_low)
  else
    -- Shift by less than 32
    local new_low = bit32_bor(bit32_rshift(x[2], n), bit32_lshift(x[1], 32 - n))
    local new_high = bit32_arshift(x[1], n)
    return bit64.new(new_high, new_low)
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
    return bit64.new(x[1], x[2])
  end

  local high, low = x[1], x[2]

  if n == 32 then
    -- Special case: swap high and low
    return bit64.new(low, high)
  elseif n < 32 then
    -- Rotate within 32-bit boundaries
    local new_high = bit32_bor(bit32_lshift(high, n), bit32_rshift(low, 32 - n))
    local new_low = bit32_bor(bit32_lshift(low, n), bit32_rshift(high, 32 - n))
    return bit64.new(new_high, new_low)
  else
    -- n > 32: rotate by (n - 32) after swapping
    n = n - 32
    local new_high = bit32_bor(bit32_lshift(low, n), bit32_rshift(high, 32 - n))
    local new_low = bit32_bor(bit32_lshift(high, n), bit32_rshift(low, 32 - n))
    return bit64.new(new_high, new_low)
  end
end

--- Right rotate operation.
--- @param x Int64HighLow Value to rotate {high, low}
--- @param n integer Number of positions to rotate
--- @return Int64HighLow result {high, low} rotated value
function bit64.ror(x, n)
  n = n % 64
  if n == 0 then
    return bit64.new(x[1], x[2])
  end

  local high, low = x[1], x[2]

  if n == 32 then
    -- Special case: swap high and low
    return bit64.new(low, high)
  elseif n < 32 then
    -- Rotate within 32-bit boundaries
    local new_low = bit32_bor(bit32_rshift(low, n), bit32_lshift(high, 32 - n))
    local new_high = bit32_bor(bit32_rshift(high, n), bit32_lshift(low, 32 - n))
    return bit64.new(new_high, new_low)
  else
    -- n > 32: rotate by (n - 32) after swapping
    n = n - 32
    local new_low = bit32_bor(bit32_rshift(high, n), bit32_lshift(low, 32 - n))
    local new_high = bit32_bor(bit32_rshift(low, n), bit32_lshift(high, 32 - n))
    return bit64.new(new_high, new_low)
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

  return bit64.new(high, low)
end

--------------------------------------------------------------------------------
-- Byte conversion functions
--------------------------------------------------------------------------------

--- Convert 64-bit value to 8 bytes (big-endian).
--- @param x Int64HighLow 64-bit value {high, low}
--- @return string bytes 8-byte string in big-endian order
function bit64.u64_to_be_bytes(x)
  return bit32_u32_to_be_bytes(x[1]) .. bit32_u32_to_be_bytes(x[2])
end

--- Convert 64-bit value to 8 bytes (little-endian).
--- @param x Int64HighLow 64-bit value {high, low}
--- @return string bytes 8-byte string in little-endian order
function bit64.u64_to_le_bytes(x)
  return bit32_u32_to_le_bytes(x[2]) .. bit32_u32_to_le_bytes(x[1])
end

--- Convert 8 bytes to 64-bit value (big-endian).
--- @param str string Binary string (at least 8 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return Int64HighLow value {high, low} 64-bit value
function bit64.be_bytes_to_u64(str, offset)
  offset = offset or 1
  assert(#str >= offset + 7, "Insufficient bytes for u64")
  local high = bit32_be_bytes_to_u32(str, offset)
  local low = bit32_be_bytes_to_u32(str, offset + 4)
  return bit64.new(high, low)
end

--- Convert 8 bytes to 64-bit value (little-endian).
--- @param str string Binary string (at least 8 bytes from offset)
--- @param offset? integer Starting position (default: 1)
--- @return Int64HighLow value {high, low} 64-bit value
function bit64.le_bytes_to_u64(str, offset)
  offset = offset or 1
  assert(#str >= offset + 7, "Insufficient bytes for u64")
  local low = bit32_le_bytes_to_u32(str, offset)
  local high = bit32_le_bytes_to_u32(str, offset + 4)
  return bit64.new(high, low)
end

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

--- Converts a {high, low} pair to a 16-character hexadecimal string.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @return string hex The hexadecimal string (e.g., "0000180000001000").
function bit64.to_hex(value)
  return string.format("%08X%08X", value[1], value[2])
end

--- Converts a {high, low} pair to a Lua number.
--- Warning: Lua numbers use 64-bit IEEE 754 doubles with 53-bit mantissa precision.
--- Values exceeding 53 bits (greater than 9007199254740991) will lose precision.
--- To maintain full 64-bit precision, keep values in {high, low} format.
--- @param value number|integer|Int64HighLow The {high_32, low_32} pair (or number to pass through).
--- @param strict? boolean If true, errors when value exceeds 53-bit precision.
--- @return number|integer result The value as a Lua number (may lose precision for large values unless strict).
--- @overload fun(value: number, strict?: boolean): number
--- @overload fun(value: integer, strict?: boolean): integer
--- @overload fun(value: Int64HighLow, strict?: boolean): integer
--- @overload fun(value: number): number
--- @overload fun(value: integer): integer
--- @overload fun(value: Int64HighLow): integer
function bit64.to_number(value, strict)
  if type(value) == "number" then
    return value
  end
  if not bit64.is_int64(value) then
    error("Value is not a valid Int64HighLow pair", 2)
  end
  if strict and value[1] > 0x001FFFFF then
    error("Value exceeds 53-bit precision (max: 9007199254740991)", 2)
  end
  return value[1] * 0x100000000 + value[2]
end

--- Creates a {high, low} pair from a Lua number.
--- @param value number|Int64HighLow The number to convert (or Int64HighLow to pass through).
--- @return Int64HighLow pair The {high_32, low_32} pair.
function bit64.from_number(value)
  if bit64.is_int64(value) then
    --- @cast value Int64HighLow
    return value
  end
  --- @cast value -Int64HighLow
  local low = math.floor(value % 0x100000000)
  local high = math.floor(value / 0x100000000)
  return bit64.new(high, low)
end

--- Checks if two {high, low} pairs are equal.
--- @param a Int64HighLow The first {high_32, low_32} pair.
--- @param b Int64HighLow The second {high_32, low_32} pair.
--- @return boolean equal True if the values are equal.
function bit64.eq(a, b)
  return a[1] == b[1] and a[2] == b[2]
end

--- Checks if a {high, low} pair is zero.
--- @param value Int64HighLow The {high_32, low_32} pair.
--- @return boolean is_zero True if the value is zero.
function bit64.is_zero(value)
  return value[1] == 0 and value[2] == 0
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

--- Alias for is_int64 (compatibility with older API).
bit64.isInt64 = bit64.is_int64

--------------------------------------------------------------------------------
-- Raw (zero-overhead) operations
--------------------------------------------------------------------------------
-- These functions use bit32.raw_* internally for performance-critical code.
-- On LuaJIT, the internal 32-bit values may be signed, but bit patterns are correct.
-- Use for crypto code and tight loops where sign interpretation doesn't matter.

--- Raw bitwise AND (uses bit32.raw_band internally).
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} AND result
function bit64.raw_band(a, b)
  return bit64.new(bit32_raw_band(a[1], b[1]), bit32_raw_band(a[2], b[2]))
end

--- Raw bitwise OR (uses bit32.raw_bor internally).
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} OR result
function bit64.raw_bor(a, b)
  return bit64.new(bit32_raw_bor(a[1], b[1]), bit32_raw_bor(a[2], b[2]))
end

--- Raw bitwise XOR (uses bit32.raw_bxor internally).
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} XOR result
function bit64.raw_bxor(a, b)
  return bit64.new(bit32_raw_bxor(a[1], b[1]), bit32_raw_bxor(a[2], b[2]))
end

--- Raw bitwise NOT (uses bit32.raw_bnot internally).
--- @param a Int64HighLow Operand {high, low}
--- @return Int64HighLow result {high, low} NOT result
function bit64.raw_bnot(a)
  return bit64.new(bit32_raw_bnot(a[1]), bit32_raw_bnot(a[2]))
end

--- Raw left shift (uses bit32.raw_* internally).
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.raw_lshift(x, n)
  if n == 0 then
    return bit64.new(x[1], x[2])
  elseif n >= 64 then
    return bit64.new(0, 0)
  elseif n >= 32 then
    return bit64.new(bit32_raw_lshift(x[2], n - 32), 0)
  else
    local new_high = bit32_raw_bor(bit32_raw_lshift(x[1], n), bit32_raw_rshift(x[2], 32 - n))
    local new_low = bit32_raw_lshift(x[2], n)
    return bit64.new(new_high, new_low)
  end
end

--- Raw logical right shift (uses bit32.raw_* internally).
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.raw_rshift(x, n)
  if n == 0 then
    return bit64.new(x[1], x[2])
  elseif n >= 64 then
    return bit64.new(0, 0)
  elseif n >= 32 then
    return bit64.new(0, bit32_raw_rshift(x[1], n - 32))
  else
    local new_low = bit32_raw_bor(bit32_raw_rshift(x[2], n), bit32_raw_lshift(x[1], 32 - n))
    local new_high = bit32_raw_rshift(x[1], n)
    return bit64.new(new_high, new_low)
  end
end

--- Raw arithmetic right shift (uses bit32.raw_* internally).
--- @param x Int64HighLow Value to shift {high, low}
--- @param n integer Number of positions to shift (must be >= 0)
--- @return Int64HighLow result {high, low} shifted value
function bit64.raw_arshift(x, n)
  if n == 0 then
    return bit64.new(x[1], x[2])
  end

  local is_negative = bit32_raw_band(x[1], 0x80000000) ~= 0

  if n >= 64 then
    if is_negative then
      return bit64.new(0xFFFFFFFF, 0xFFFFFFFF)
    else
      return bit64.new(0, 0)
    end
  elseif n >= 32 then
    local new_low = bit32_raw_arshift(x[1], n - 32)
    local new_high = is_negative and 0xFFFFFFFF or 0
    return bit64.new(new_high, new_low)
  else
    local new_low = bit32_raw_bor(bit32_raw_rshift(x[2], n), bit32_raw_lshift(x[1], 32 - n))
    local new_high = bit32_raw_arshift(x[1], n)
    return bit64.new(new_high, new_low)
  end
end

--- Raw left rotate (uses bit32.raw_* internally).
--- @param x Int64HighLow Value to rotate {high, low}
--- @param n integer Number of positions to rotate
--- @return Int64HighLow result {high, low} rotated value
function bit64.raw_rol(x, n)
  n = n % 64
  if n == 0 then
    return bit64.new(x[1], x[2])
  end

  local high, low = x[1], x[2]

  if n == 32 then
    return bit64.new(low, high)
  elseif n < 32 then
    local new_high = bit32_raw_bor(bit32_raw_lshift(high, n), bit32_raw_rshift(low, 32 - n))
    local new_low = bit32_raw_bor(bit32_raw_lshift(low, n), bit32_raw_rshift(high, 32 - n))
    return bit64.new(new_high, new_low)
  else
    n = n - 32
    local new_high = bit32_raw_bor(bit32_raw_lshift(low, n), bit32_raw_rshift(high, 32 - n))
    local new_low = bit32_raw_bor(bit32_raw_lshift(high, n), bit32_raw_rshift(low, 32 - n))
    return bit64.new(new_high, new_low)
  end
end

--- Raw right rotate (uses bit32.raw_* internally).
--- @param x Int64HighLow Value to rotate {high, low}
--- @param n integer Number of positions to rotate
--- @return Int64HighLow result {high, low} rotated value
function bit64.raw_ror(x, n)
  n = n % 64
  if n == 0 then
    return bit64.new(x[1], x[2])
  end

  local high, low = x[1], x[2]

  if n == 32 then
    return bit64.new(low, high)
  elseif n < 32 then
    local new_low = bit32_raw_bor(bit32_raw_rshift(low, n), bit32_raw_lshift(high, 32 - n))
    local new_high = bit32_raw_bor(bit32_raw_rshift(high, n), bit32_raw_lshift(low, 32 - n))
    return bit64.new(new_high, new_low)
  else
    n = n - 32
    local new_low = bit32_raw_bor(bit32_raw_rshift(high, n), bit32_raw_lshift(low, 32 - n))
    local new_high = bit32_raw_bor(bit32_raw_rshift(low, n), bit32_raw_lshift(high, 32 - n))
    return bit64.new(new_high, new_low)
  end
end

--- Raw 64-bit addition (uses bit32.raw_band for masking).
--- @param a Int64HighLow First operand {high, low}
--- @param b Int64HighLow Second operand {high, low}
--- @return Int64HighLow result {high, low} sum
function bit64.raw_add(a, b)
  local low = a[2] + b[2]
  local high = a[1] + b[1]

  if low >= 0x100000000 then
    high = high + 1
    low = low % 0x100000000
  end

  high = high % 0x100000000

  return bit64.new(high, low)
end

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
  print(string.format("  Using: %s", impl_name()))
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

    -- to_hex tests
    {
      name = "to_hex({0x00001800, 0x00001000})",
      fn = bit64.to_hex,
      inputs = { { 0x00001800, 0x00001000 } },
      expected = "0000180000001000",
    },
    {
      name = "to_hex({0xFFFFFFFF, 0xFFFFFFFF})",
      fn = bit64.to_hex,
      inputs = { { 0xFFFFFFFF, 0xFFFFFFFF } },
      expected = "FFFFFFFFFFFFFFFF",
    },
    {
      name = "to_hex({0x00000000, 0x00000000})",
      fn = bit64.to_hex,
      inputs = { { 0x00000000, 0x00000000 } },
      expected = "0000000000000000",
    },

    -- to_number tests
    {
      name = "to_number({0x00000000, 0x00000001})",
      fn = bit64.to_number,
      inputs = { bit64.new(0x00000000, 0x00000001) },
      expected = 1,
    },
    {
      name = "to_number({0x00000000, 0xFFFFFFFF})",
      fn = bit64.to_number,
      inputs = { bit64.new(0x00000000, 0xFFFFFFFF) },
      expected = 4294967295,
    },
    {
      name = "to_number({0x00000001, 0x00000000})",
      fn = bit64.to_number,
      inputs = { bit64.new(0x00000001, 0x00000000) },
      expected = 4294967296,
    },

    -- from_number tests
    {
      name = "from_number(1)",
      fn = bit64.from_number,
      inputs = { 1 },
      expected = { 0x00000000, 0x00000001 },
    },
    {
      name = "from_number(4294967296)",
      fn = bit64.from_number,
      inputs = { 4294967296 },
      expected = { 0x00000001, 0x00000000 },
    },
    {
      name = "from_number(0)",
      fn = bit64.from_number,
      inputs = { 0 },
      expected = { 0x00000000, 0x00000000 },
    },

    -- eq tests
    { name = "eq({1,2}, {1,2})", fn = bit64.eq, inputs = { { 1, 2 }, { 1, 2 } }, expected = true },
    { name = "eq({1,2}, {1,3})", fn = bit64.eq, inputs = { { 1, 2 }, { 1, 3 } }, expected = false },
    { name = "eq({1,2}, {2,2})", fn = bit64.eq, inputs = { { 1, 2 }, { 2, 2 } }, expected = false },

    -- is_zero tests
    { name = "is_zero({0,0})", fn = bit64.is_zero, inputs = { { 0, 0 } }, expected = true },
    { name = "is_zero({0,1})", fn = bit64.is_zero, inputs = { { 0, 1 } }, expected = false },
    { name = "is_zero({1,0})", fn = bit64.is_zero, inputs = { { 1, 0 } }, expected = false },

    -- to_number strict mode tests (values within 53-bit range)
    {
      name = "to_number({0x001FFFFF, 0xFFFFFFFF}, true) -- max 53-bit",
      fn = bit64.to_number,
      inputs = { bit64.new(0x001FFFFF, 0xFFFFFFFF), true },
      expected = 9007199254740991,
    },
    {
      name = "to_number({0, 1}, true)",
      fn = bit64.to_number,
      inputs = { bit64.new(0, 1), true },
      expected = 1,
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
        print("  FAIL: " .. test.name)
        if type(result) ~= "string" then
          print("    Expected: string")
          print("    Got:      " .. type(result))
        else
          local exp_hex, got_hex = "", ""
          for i = 1, #test.expected do
            exp_hex = exp_hex .. string.format("%02X", string.byte(test.expected, i))
          end
          for i = 1, #result do
            got_hex = got_hex .. string.format("%02X", string.byte(result, i))
          end
          print("    Expected: " .. exp_hex)
          print("    Got:      " .. got_hex)
        end
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

  -- Int64 type identification tests
  print("\nRunning Int64 type identification tests...")

  -- Test bit64.new() creates Int64 values
  total = total + 1
  local new_val = bit64.new(0x12345678, 0x9ABCDEF0)
  if bit64.is_int64(new_val) and new_val[1] == 0x12345678 and new_val[2] == 0x9ABCDEF0 then
    print("  PASS: new() creates Int64 with correct values")
    passed = passed + 1
  else
    print("  FAIL: new() creates Int64 with correct values")
  end

  -- Test bit64.new() with defaults
  total = total + 1
  local zero_val = bit64.new()
  if bit64.is_int64(zero_val) and zero_val[1] == 0 and zero_val[2] == 0 then
    print("  PASS: new() with no args creates {0, 0}")
    passed = passed + 1
  else
    print("  FAIL: new() with no args creates {0, 0}")
  end

  -- Test bit64.new() normalizes negative values (LuaJIT raw_* compatibility)
  total = total + 1
  local neg_val = bit64.new(-1, -2147483648) -- -1 -> 0xFFFFFFFF, -2147483648 -> 0x80000000
  if bit64.is_int64(neg_val) and neg_val[1] == 0xFFFFFFFF and neg_val[2] == 0x80000000 then
    print("  PASS: new() normalizes negative values to unsigned")
    passed = passed + 1
  else
    print("  FAIL: new() normalizes negative values to unsigned")
    print(string.format("    Expected: {0x%08X, 0x%08X}", 0xFFFFFFFF, 0x80000000))
    print(string.format("    Got:      {0x%08X, 0x%08X}", neg_val[1], neg_val[2]))
  end

  -- Test is_int64() returns false for regular tables
  total = total + 1
  local plain_table = { 0x12345678, 0x9ABCDEF0 }
  if not bit64.is_int64(plain_table) then
    print("  PASS: is_int64() returns false for plain table")
    passed = passed + 1
  else
    print("  FAIL: is_int64() returns false for plain table")
  end

  -- Test is_int64() returns false for non-tables
  total = total + 1
  if not bit64.is_int64(123) and not bit64.is_int64("string") and not bit64.is_int64(nil) then
    print("  PASS: is_int64() returns false for non-tables")
    passed = passed + 1
  else
    print("  FAIL: is_int64() returns false for non-tables")
  end

  -- Test all operations return Int64 values
  local ops_returning_int64 = {
    {
      name = "band",
      fn = function()
        return bit64.band(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
    {
      name = "bor",
      fn = function()
        return bit64.bor(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
    {
      name = "bxor",
      fn = function()
        return bit64.bxor(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
    {
      name = "bnot",
      fn = function()
        return bit64.bnot(bit64.new(1, 2))
      end,
    },
    {
      name = "lshift",
      fn = function()
        return bit64.lshift(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "rshift",
      fn = function()
        return bit64.rshift(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "arshift",
      fn = function()
        return bit64.arshift(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "rol",
      fn = function()
        return bit64.rol(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "ror",
      fn = function()
        return bit64.ror(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "add",
      fn = function()
        return bit64.add(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
    {
      name = "be_bytes_to_u64",
      fn = function()
        return bit64.be_bytes_to_u64("\0\0\0\1\0\0\0\2")
      end,
    },
    {
      name = "le_bytes_to_u64",
      fn = function()
        return bit64.le_bytes_to_u64("\2\0\0\0\1\0\0\0")
      end,
    },
  }

  for _, op in ipairs(ops_returning_int64) do
    total = total + 1
    local result = op.fn()
    if bit64.is_int64(result) then
      print("  PASS: " .. op.name .. "() returns Int64")
      passed = passed + 1
    else
      print("  FAIL: " .. op.name .. "() returns Int64")
    end
  end

  -- Test to_number strict mode error case
  print("\nRunning to_number/from_number edge case tests...")
  total = total + 1
  local ok, err = pcall(function()
    bit64.to_number(bit64.new(0x00200000, 0x00000000), true) -- 2^53, exceeds 53-bit
  end)
  if not ok and type(err) == "string" and string.find(err, "53%-bit precision") then
    print("  PASS: to_number strict mode errors on values > 53 bits")
    passed = passed + 1
  else
    print("  FAIL: to_number strict mode errors on values > 53 bits")
    if ok then
      print("    Expected error but got success")
    else
      print("    Expected '53-bit precision' error but got: " .. tostring(err))
    end
  end

  -- Test to_number pass-through for number input
  total = total + 1
  local num_input = 12345
  local num_result = bit64.to_number(num_input)
  if num_result == num_input then
    print("  PASS: to_number passes through number input unchanged")
    passed = passed + 1
  else
    print("  FAIL: to_number passes through number input unchanged")
    print("    Expected: " .. tostring(num_input))
    print("    Got:      " .. tostring(num_result))
  end

  -- Test to_number errors on plain table (non-Int64)
  total = total + 1
  ok, err = pcall(function()
    bit64.to_number({ 1, 2 }) -- plain table, not Int64
  end)
  if not ok and type(err) == "string" and string.find(err, "not a valid Int64") then
    print("  PASS: to_number errors on plain table (non-Int64)")
    passed = passed + 1
  else
    print("  FAIL: to_number errors on plain table (non-Int64)")
    if ok then
      print("    Expected error but got success")
    else
      print("    Expected 'not a valid Int64' error but got: " .. tostring(err))
    end
  end

  -- Test from_number pass-through for Int64 input
  total = total + 1
  local int64_input = bit64.new(0x12345678, 0x9ABCDEF0)
  local int64_result = bit64.from_number(int64_input)
  if rawequal(int64_result, int64_input) then
    print("  PASS: from_number passes through Int64 input unchanged")
    passed = passed + 1
  else
    print("  FAIL: from_number passes through Int64 input unchanged")
    print("    Expected same reference, got different object")
  end

  -- Test raw_* operations
  print("\n  Testing raw_* operations...")

  local raw_tests = {
    -- Core bitwise (test high-bit cases where sign matters)
    {
      name = "raw_band(new(0xFFFFFFFF, 0x80000000), new(0x80000000, 0xFFFFFFFF))",
      fn = function()
        return bit64.raw_band(bit64.new(0xFFFFFFFF, 0x80000000), bit64.new(0x80000000, 0xFFFFFFFF))
      end,
      expected = bit64.new(0x80000000, 0x80000000),
    },
    {
      name = "raw_bor(new(0x80000000, 0), new(0, 0x80000000))",
      fn = function()
        return bit64.raw_bor(bit64.new(0x80000000, 0), bit64.new(0, 0x80000000))
      end,
      expected = bit64.new(0x80000000, 0x80000000),
    },
    {
      name = "raw_bxor(new(0xAAAAAAAA, 0x55555555), new(0x55555555, 0xAAAAAAAA))",
      fn = function()
        return bit64.raw_bxor(bit64.new(0xAAAAAAAA, 0x55555555), bit64.new(0x55555555, 0xAAAAAAAA))
      end,
      expected = bit64.new(0xFFFFFFFF, 0xFFFFFFFF),
    },
    {
      name = "raw_bnot(new(0, 0))",
      fn = function()
        return bit64.raw_bnot(bit64.new(0, 0))
      end,
      expected = bit64.new(0xFFFFFFFF, 0xFFFFFFFF),
    },

    -- Shifts
    {
      name = "raw_lshift(new(0, 1), 63)",
      fn = function()
        return bit64.raw_lshift(bit64.new(0, 1), 63)
      end,
      expected = bit64.new(0x80000000, 0),
    },
    {
      name = "raw_rshift(new(0x80000000, 0), 63)",
      fn = function()
        return bit64.raw_rshift(bit64.new(0x80000000, 0), 63)
      end,
      expected = bit64.new(0, 1),
    },
    {
      name = "raw_arshift(new(0x80000000, 0), 32)",
      fn = function()
        return bit64.raw_arshift(bit64.new(0x80000000, 0), 32)
      end,
      expected = bit64.new(0xFFFFFFFF, 0x80000000),
    },

    -- Rotates
    {
      name = "raw_rol(new(0x12345678, 0x9ABCDEF0), 16)",
      fn = function()
        return bit64.raw_rol(bit64.new(0x12345678, 0x9ABCDEF0), 16)
      end,
      expected = bit64.new(0x56789ABC, 0xDEF01234),
    },
    {
      name = "raw_ror(new(0x12345678, 0x9ABCDEF0), 16)",
      fn = function()
        return bit64.raw_ror(bit64.new(0x12345678, 0x9ABCDEF0), 16)
      end,
      expected = bit64.new(0xDEF01234, 0x56789ABC),
    },

    -- Addition
    {
      name = "raw_add(new(0xFFFFFFFF, 0xFFFFFFFF), new(0, 1))",
      fn = function()
        return bit64.raw_add(bit64.new(0xFFFFFFFF, 0xFFFFFFFF), bit64.new(0, 1))
      end,
      expected = bit64.new(0, 0),
    },
  }

  for _, test in ipairs(raw_tests) do
    total = total + 1
    local result = test.fn()
    if eq64(result, test.expected) then
      print("  PASS: " .. test.name)
      passed = passed + 1
    else
      print("  FAIL: " .. test.name)
      print("    Expected: " .. fmt64(test.expected))
      print("    Got:      " .. fmt64(result))
    end
  end

  -- Test that raw_* operations return Int64
  print("\n  Testing raw_* operations return Int64...")
  local raw_ops_returning_int64 = {
    {
      name = "raw_band",
      fn = function()
        return bit64.raw_band(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
    {
      name = "raw_bor",
      fn = function()
        return bit64.raw_bor(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
    {
      name = "raw_bxor",
      fn = function()
        return bit64.raw_bxor(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
    {
      name = "raw_bnot",
      fn = function()
        return bit64.raw_bnot(bit64.new(1, 2))
      end,
    },
    {
      name = "raw_lshift",
      fn = function()
        return bit64.raw_lshift(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "raw_rshift",
      fn = function()
        return bit64.raw_rshift(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "raw_arshift",
      fn = function()
        return bit64.raw_arshift(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "raw_rol",
      fn = function()
        return bit64.raw_rol(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "raw_ror",
      fn = function()
        return bit64.raw_ror(bit64.new(1, 2), 1)
      end,
    },
    {
      name = "raw_add",
      fn = function()
        return bit64.raw_add(bit64.new(1, 2), bit64.new(3, 4))
      end,
    },
  }

  for _, op in ipairs(raw_ops_returning_int64) do
    total = total + 1
    local result = op.fn()
    if bit64.is_int64(result) then
      print("  PASS: " .. op.name .. "() returns Int64")
      passed = passed + 1
    else
      print("  FAIL: " .. op.name .. "() returns Int64")
    end
  end

  print(string.format("\n64-bit operations: %d/%d tests passed\n", passed, total))
  return passed == total
end

--------------------------------------------------------------------------------
-- Benchmarking
--------------------------------------------------------------------------------

local benchmark_op = require("bitn.utils.benchmark").benchmark_op

--- Run performance benchmarks for 64-bit operations.
function bit64.benchmark()
  local iterations = 100000

  print("64-bit Bitwise Operations:")
  print(string.format("  Implementation: %s", impl_name()))

  -- Test values
  local a = bit64.new(0xAAAAAAAA, 0x55555555)
  local b = bit64.new(0x55555555, 0xAAAAAAAA)

  benchmark_op("band", function()
    bit64.band(a, b)
  end, iterations)

  benchmark_op("bor", function()
    bit64.bor(a, b)
  end, iterations)

  benchmark_op("bxor", function()
    bit64.bxor(a, b)
  end, iterations)

  benchmark_op("bnot", function()
    bit64.bnot(a)
  end, iterations)

  print("\n64-bit Shift Operations:")

  benchmark_op("lshift (small)", function()
    bit64.lshift(a, 8)
  end, iterations)

  benchmark_op("lshift (large)", function()
    bit64.lshift(a, 40)
  end, iterations)

  benchmark_op("rshift (small)", function()
    bit64.rshift(a, 8)
  end, iterations)

  benchmark_op("rshift (large)", function()
    bit64.rshift(a, 40)
  end, iterations)

  benchmark_op("arshift", function()
    bit64.arshift(bit64.new(0x80000000, 0), 8)
  end, iterations)

  print("\n64-bit Rotate Operations:")

  benchmark_op("rol (small)", function()
    bit64.rol(a, 8)
  end, iterations)

  benchmark_op("rol (large)", function()
    bit64.rol(a, 40)
  end, iterations)

  benchmark_op("ror (small)", function()
    bit64.ror(a, 8)
  end, iterations)

  benchmark_op("ror (large)", function()
    bit64.ror(a, 40)
  end, iterations)

  print("\n64-bit Arithmetic:")

  benchmark_op("add", function()
    bit64.add(a, b)
  end, iterations)

  benchmark_op("add (with carry)", function()
    bit64.add(bit64.new(0, 0xFFFFFFFF), bit64.new(0, 1))
  end, iterations)

  print("\n64-bit Byte Conversions:")

  local val = bit64.new(0x12345678, 0x9ABCDEF0)
  local bytes_be = bit64.u64_to_be_bytes(val)
  local bytes_le = bit64.u64_to_le_bytes(val)

  benchmark_op("u64_to_be_bytes", function()
    bit64.u64_to_be_bytes(val)
  end, iterations)

  benchmark_op("u64_to_le_bytes", function()
    bit64.u64_to_le_bytes(val)
  end, iterations)

  benchmark_op("be_bytes_to_u64", function()
    bit64.be_bytes_to_u64(bytes_be)
  end, iterations)

  benchmark_op("le_bytes_to_u64", function()
    bit64.le_bytes_to_u64(bytes_le)
  end, iterations)

  print("\n64-bit Utility Functions:")

  benchmark_op("new", function()
    bit64.new(0x12345678, 0x9ABCDEF0)
  end, iterations)

  benchmark_op("is_int64", function()
    bit64.is_int64(a)
  end, iterations)

  benchmark_op("to_hex", function()
    bit64.to_hex(a)
  end, iterations)

  benchmark_op("to_number", function()
    bit64.to_number(a)
  end, iterations)

  benchmark_op("from_number", function()
    bit64.from_number(12345678901234)
  end, iterations)

  benchmark_op("eq", function()
    bit64.eq(a, b)
  end, iterations)

  benchmark_op("is_zero", function()
    bit64.is_zero(a)
  end, iterations)
end

return bit64
end
end

do
local _ENV = _ENV
package.preload[ "bitn.utils.benchmark" ] = function( ... ) local arg = _G.arg;
--- @module "bitn.utils.benchmark"
--- Common benchmarking utilities for performance testing
--- @class bitn.utils.benchmark
local benchmark = {}

--- Run a benchmarked operation with warmup and timing
--- @param name string Operation name for display
--- @param func function Function to benchmark
--- @param iterations? integer Number of iterations (default: 100)
--- @return number ms_per_op Milliseconds per operation
function benchmark.benchmark_op(name, func, iterations)
  iterations = iterations or 100

  -- Warmup
  for _ = 1, 3 do
    func()
  end

  -- Actual benchmark
  local start = os.clock()
  for _ = 1, iterations do
    func()
  end
  local elapsed = os.clock() - start

  local per_op = (elapsed / iterations) * 1000 -- ms
  local ops_per_sec = iterations / elapsed

  print(string.format("%-30s: %8.3f ms/op, %8.1f ops/sec", name, per_op, ops_per_sec))

  return per_op
end

return benchmark
end
end

--- @module "bitn"
--- Portable bitwise operations library with automatic optimization.
--- This library provides standalone, version-agnostic implementations of
--- bitwise operations for 16-bit, 32-bit, and 64-bit integers. It works
--- across Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT with zero external dependencies.
--- Automatically uses native bit operations when available for optimal performance.
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
  --- @type bitn.bit16 16-bit bitwise operations
  bit16 = require("bitn.bit16"),
  --- @type bitn.bit32 32-bit bitwise operations
  bit32 = require("bitn.bit32"),
  --- @type bitn.bit64 64-bit bitwise operations
  bit64 = require("bitn.bit64"),
}

--- Library version (injected at build time for releases).
local VERSION = "v0.6.0"

--- Get the library version string.
--- @return string version Version string (e.g., "v1.0.0" or "dev")
function bitn.version()
  return VERSION
end

return bitn
