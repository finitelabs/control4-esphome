do
  local _ENV = _ENV
  package.preload["bitn._compat"] = function(...)
    local arg = _G.arg
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

    -- string.pack/unpack are bound only if they answer in the 5.3 dialect. Control4's
    -- LuaJIT ships lpack under the same names: no size suffixes, and unpack takes
    -- (data, fmt, pos) and returns the position first, so existence proves nothing.
    local function probe_string_pack()
      local pack, unpack = rawget(string, "pack"), rawget(string, "unpack")
      if not (pack and unpack) then
        return nil, nil
      end
      local packed_ok, packed = pcall(pack, "<I4", 0x04030201)
      if not packed_ok or packed ~= "\1\2\3\4" then
        return nil, nil
      end
      packed_ok, packed = pcall(pack, ">I4", 0x04030201)
      if not packed_ok or packed ~= "\4\3\2\1" then
        return nil, nil
      end
      local unpacked_ok, value, next_pos = pcall(unpack, "<I4", "\0\1\2\3\4", 2)
      if not unpacked_ok or value ~= 0x04030201 or next_pos ~= 6 then
        return nil, nil
      end
      return pack, unpack
    end

    _compat.string_pack, _compat.string_unpack = probe_string_pack()

    --------------------------------------------------------------------------------
    -- Implementation 1: Native operators (Lua 5.3+)
    --------------------------------------------------------------------------------

    -- Parsing `a & b` does not mean the result has 64-bit integer semantics. LuaJIT
    -- rolling releases from 2026 accept the syntax and return a signed 32-bit number,
    -- as from its `bit` library, while this branch assumes 5.3+ integers and skips the
    -- to_unsigned() normalisation such a host needs.
    --
    -- So test the value, not the runtime: 5.3+ answers 0xFFFFFFFF and anything with
    -- 32-bit semantics answers -1. Asking the question this way needs no list of which
    -- runtimes exist, so it stays correct for whatever grows the syntax next.
    local ok, result = pcall(load, "return function(a,b) return a & b end")
    if ok and result then
      local fn = result()
      if fn and fn(0xFFFFFFFF, 0xFFFFFFFF) == 0xFFFFFFFF then
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

    -- Try LuaJIT's bit library first. Fresh locals rather than the pcall results
    -- from the native-operator probe above: that `result` is a compiled chunk, this
    -- one is a library table.
    local bit_ok, bit_module = pcall(require, "bit")
    if bit_ok and bit_module then
      bit_lib = bit_module
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

    -- 4-bit truth tables, indexed [a * 16 + b + 1], so each op is at most 8 steps.
    local AND4, OR4, XOR4 = {}, {}, {}
    for a = 0, 15 do
      for b = 0, 15 do
        local x, y, r_and, r_or, r_xor, bit_val = a, b, 0, 0, 0, 1
        for _ = 1, 4 do
          local xb, yb = x % 2, y % 2
          if xb == 1 and yb == 1 then
            r_and = r_and + bit_val
          end
          if xb == 1 or yb == 1 then
            r_or = r_or + bit_val
          end
          if xb ~= yb then
            r_xor = r_xor + bit_val
          end
          x, y, bit_val = (x - xb) / 2, (y - yb) / 2, bit_val * 2
        end
        local i = a * 16 + b + 1
        AND4[i], OR4[i], XOR4[i] = r_and, r_or, r_xor
      end
    end

    -- band(a, 2^k - 1) is a % 2^k. Built by doubling so the values are integers on 5.3+.
    local LOW_MASK = {}
    do
      local m = 1
      for _ = 1, 32 do
        m = m * 2
        LOW_MASK[m - 1] = m
      end
    end

    function _compat.band(a, b)
      a, b = math_floor(a) % 0x100000000, math_floor(b) % 0x100000000
      local m = LOW_MASK[b] or LOW_MASK[a]
      if m then
        return (LOW_MASK[b] and a or b) % m
      end
      local r, scale = 0, 1
      while a > 0 and b > 0 do
        local na, nb = a % 16, b % 16
        r = r + AND4[na * 16 + nb + 1] * scale
        a, b, scale = (a - na) / 16, (b - nb) / 16, scale * 16
      end
      return r
    end

    function _compat.bor(a, b)
      a, b = math_floor(a) % 0x100000000, math_floor(b) % 0x100000000
      if a == 0 then
        return b
      elseif b == 0 then
        return a
      end
      local r, scale = 0, 1
      while a > 0 or b > 0 do
        local na, nb = a % 16, b % 16
        r = r + OR4[na * 16 + nb + 1] * scale
        a, b, scale = (a - na) / 16, (b - nb) / 16, scale * 16
      end
      return r
    end

    function _compat.bxor(a, b)
      a, b = math_floor(a) % 0x100000000, math_floor(b) % 0x100000000
      if a == 0 then
        return b
      elseif b == 0 then
        return a
      end
      local r, scale = 0, 1
      while a > 0 or b > 0 do
        local na, nb = a % 16, b % 16
        r = r + XOR4[na * 16 + nb + 1] * scale
        a, b, scale = (a - na) / 16, (b - nb) / 16, scale * 16
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
  package.preload["bitn.bit16"] = function(...)
    local arg = _G.arg
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
      if offset ~= offset or offset < 1 then
        error("Offset must be at least 1")
      end
      if #str < offset + 1 then
        error("Insufficient bytes for u16")
      end
      local b1, b2 = string_byte(str, offset, offset + 1)
      return b1 * 256 + b2
    end

    --- Convert 2 bytes to 16-bit unsigned integer (little-endian).
    --- @param str string Binary string (at least 2 bytes from offset)
    --- @param offset? integer Starting position (default: 1)
    --- @return integer n 16-bit unsigned integer
    function bit16.le_bytes_to_u16(str, offset)
      offset = offset or 1
      if offset ~= offset or offset < 1 then
        error("Offset must be at least 1")
      end
      if #str < offset + 1 then
        error("Insufficient bytes for u16")
      end
      local b1, b2 = string_byte(str, offset, offset + 1)
      return b1 + b2 * 256
    end

    return bit16
  end
end

do
  local _ENV = _ENV
  package.preload["bitn.bit32"] = function(...)
    local arg = _G.arg
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

    --- Convert unsigned 32-bit value to signed.
    --- The inverse of `to_unsigned`: values of 2^31 and above wrap to negative.
    --- @param n number Unsigned 32-bit value (already-signed values pass through)
    --- @return integer result Signed 32-bit value (-2^31 to 2^31 - 1)
    function bit32.to_signed(n)
      if n >= 0x80000000 then
        return n - 0x100000000
      end
      return n
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
    local string_pack = _compat.string_pack
    local string_unpack = _compat.string_unpack
    -- % is the whole operation on the pure Lua backend; skip the call.
    local fast_band = _compat.has_native_ops or _compat.has_bit_lib

    --- Convert 32-bit unsigned integer to 4 bytes (big-endian).
    --- @param n integer 32-bit unsigned integer
    --- @return string bytes 4-byte string in big-endian order
    function bit32.u32_to_be_bytes(n)
      if string_pack then
        return string_pack(">I4", n % 0x100000000)
      end
      n = fast_band and compat_band(n, MASK32) or n % 0x100000000
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
      if string_pack then
        return string_pack("<I4", n % 0x100000000)
      end
      n = fast_band and compat_band(n, MASK32) or n % 0x100000000
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
      if offset ~= offset or offset < 1 then
        error("Offset must be at least 1")
      end
      if #str < offset + 3 then
        error("Insufficient bytes for u32")
      end
      if string_unpack then
        return (string_unpack(">I4", str, offset))
      end
      local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
      return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end

    --- Convert 4 bytes to 32-bit unsigned integer (little-endian).
    --- @param str string Binary string (at least 4 bytes from offset)
    --- @param offset? integer Starting position (default: 1)
    --- @return integer n 32-bit unsigned integer
    function bit32.le_bytes_to_u32(str, offset)
      offset = offset or 1
      if offset ~= offset or offset < 1 then
        error("Offset must be at least 1")
      end
      if #str < offset + 3 then
        error("Insufficient bytes for u32")
      end
      if string_unpack then
        return (string_unpack("<I4", str, offset))
      end
      local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
      return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end

    return bit32
  end
end

do
  local _ENV = _ENV
  package.preload["bitn.bit64"] = function(...)
    local arg = _G.arg
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
    local math_floor = math.floor
    local string_char = string.char
    local string_pack = _compat.string_pack
    local string_unpack = _compat.string_unpack

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
      local high, low = x[1] % 0x100000000, x[2] % 0x100000000
      if string_pack then
        return string_pack(">I4I4", high, low)
      end
      return string_char(
        math_floor(high / 16777216) % 256,
        math_floor(high / 65536) % 256,
        math_floor(high / 256) % 256,
        math_floor(high % 256),
        math_floor(low / 16777216) % 256,
        math_floor(low / 65536) % 256,
        math_floor(low / 256) % 256,
        math_floor(low % 256)
      )
    end

    --- Convert 64-bit value to 8 bytes (little-endian).
    --- @param x Int64HighLow 64-bit value {high, low}
    --- @return string bytes 8-byte string in little-endian order
    function bit64.u64_to_le_bytes(x)
      local high, low = x[1] % 0x100000000, x[2] % 0x100000000
      if string_pack then
        return string_pack("<I4I4", low, high)
      end
      return string_char(
        math_floor(low % 256),
        math_floor(low / 256) % 256,
        math_floor(low / 65536) % 256,
        math_floor(low / 16777216) % 256,
        math_floor(high % 256),
        math_floor(high / 256) % 256,
        math_floor(high / 65536) % 256,
        math_floor(high / 16777216) % 256
      )
    end

    --- Convert 8 bytes to 64-bit value (big-endian).
    --- @param str string Binary string (at least 8 bytes from offset)
    --- @param offset? integer Starting position (default: 1)
    --- @return Int64HighLow value {high, low} 64-bit value
    function bit64.be_bytes_to_u64(str, offset)
      offset = offset or 1
      if offset ~= offset or offset < 1 then
        error("Offset must be at least 1")
      end
      if #str < offset + 7 then
        error("Insufficient bytes for u64")
      end
      if string_unpack then
        local high, low = string_unpack(">I4I4", str, offset)
        return setmetatable({ high, low }, Int64Meta)
      end
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
      if offset ~= offset or offset < 1 then
        error("Offset must be at least 1")
      end
      if #str < offset + 7 then
        error("Insufficient bytes for u64")
      end
      if string_unpack then
        local low, high = string_unpack("<I4I4", str, offset)
        return setmetatable({ high, low }, Int64Meta)
      end
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
      if type(value) == "table" and getmetatable(value) == Int64Meta then
        --- @cast value Int64HighLow
        return value
      end
      --- @cast value -Int64HighLow
      return setmetatable({ math_floor(value / 0x100000000) % 0x100000000, math_floor(value % 0x100000000) }, Int64Meta)
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

    return bit64
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
local VERSION = "v0.7.0"

--- Get the library version string.
--- @return string version Version string (e.g., "v1.0.0" or "dev")
function bitn.version()
  return VERSION
end

return bitn
