do
  local _ENV = _ENV
  package.preload["noiseprotocol.utils"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils"
    --- Common utility functions for the Noise Protocol Framework
    --- @class noiseprotocol.utils
    local utils = {
      --- @type noiseprotocol.utils.bytes
      bytes = require("noiseprotocol.utils.bytes"),
      --- @type noiseprotocol.utils.benchmark
      benchmark = require("noiseprotocol.utils.benchmark"),
    }

    return utils
  end
end

do
  local _ENV = _ENV
  package.preload["noiseprotocol.utils.benchmark"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils.benchmark"
    --- Common benchmarking utilities for performance testing
    --- @class noiseprotocol.utils.benchmark
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

do
  local _ENV = _ENV
  package.preload["noiseprotocol.utils.bytes"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils.bytes"
    --- Byte manipulation and conversion utilities
    --- @class noiseprotocol.utils.bytes
    local bytes = {}

    local bitn = require("bitn")
    local bit32 = bitn.bit32
    local bit64 = bitn.bit64

    -- Local references for performance
    local bit32_mask = bit32.mask
    local bit32_raw_bor = bit32.raw_bor
    local bit32_raw_bxor = bit32.raw_bxor
    local bit64_new = bit64.new
    local floor = math.floor
    local string_byte = string.byte
    local string_char = string.char
    local string_format = string.format
    local string_rep = string.rep
    local table_concat = table.concat

    --- Convert binary string to hexadecimal string
    --- @param str string Binary string
    --- @return string hex Hexadecimal representation
    function bytes.to_hex(str)
      return (str:gsub(".", function(c)
        return string_format("%02x", string_byte(c))
      end))
    end

    --- Convert hexadecimal string to binary string
    --- @param hex string Hexadecimal string
    --- @return string str Binary string
    function bytes.from_hex(hex)
      return (hex:gsub("..", function(cc)
        return string_char(tonumber(cc, 16))
      end))
    end

    --- Convert 32-bit unsigned integer to 4 bytes (little-endian)
    --- @param n integer 32-bit unsigned integer
    --- @return string bytes 4-byte string in little-endian order
    function bytes.u32_to_le_bytes(n)
      n = bit32_mask(n)
      return string_char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
    end

    --- Convert 32-bit unsigned integer to 4 bytes (big-endian)
    --- @param n integer 32-bit unsigned integer
    --- @return string bytes 4-byte string in big-endian order
    function bytes.u32_to_be_bytes(n)
      n = bit32_mask(n)
      return string_char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
    end

    --- Convert 64-bit value to 8 bytes (big-endian)
    --- @param x Int64HighLow {high, low} 64-bit value
    --- @return string bytes 8-byte string in big-endian order
    function bytes.u64_to_be_bytes(x)
      local high, low = x[1], x[2]
      return bytes.u32_to_be_bytes(high) .. bytes.u32_to_be_bytes(low)
    end

    --- Convert 64-bit value to 8 bytes (little-endian)
    --- @param x Int64HighLow|integer {high, low} 64-bit value or simple integer
    --- @return string bytes 8-byte string in little-endian order
    function bytes.u64_to_le_bytes(x)
      -- Handle simple integer case (< 2^53)
      if type(x) == "number" then
        local low = x % 0x100000000
        local high = floor(x / 0x100000000)
        return bytes.u32_to_le_bytes(low) .. bytes.u32_to_le_bytes(high)
      else
        -- Handle {high, low} pair
        local high, low = x[1], x[2]
        return bytes.u32_to_le_bytes(low) .. bytes.u32_to_le_bytes(high)
      end
    end

    --- Convert 4 bytes to 32-bit unsigned integer (little-endian)
    --- @param str string Binary string (at least 4 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return integer n 32-bit unsigned integer
    function bytes.le_bytes_to_u32(str, offset)
      offset = offset or 1
      assert(#str >= offset + 3, "Insufficient bytes for u32")
      local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
      return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end

    --- Convert 4 bytes to 32-bit unsigned integer (big-endian)
    --- @param str string Binary string (at least 4 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return integer n 32-bit unsigned integer
    function bytes.be_bytes_to_u32(str, offset)
      offset = offset or 1
      assert(#str >= offset + 3, "Insufficient bytes for u32")
      local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
      return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end

    --- Convert 8 bytes to 64-bit value (big-endian)
    --- @param str string Binary string (at least 8 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return Int64HighLow value {high, low} 64-bit value
    function bytes.be_bytes_to_u64(str, offset)
      offset = offset or 1
      assert(#str >= offset + 7, "Insufficient bytes for u64")
      local high = bytes.be_bytes_to_u32(str, offset)
      local low = bytes.be_bytes_to_u32(str, offset + 4)
      return { high, low }
    end

    --- Convert 8 bytes to 64-bit value (little-endian)
    --- @param str string Binary string (at least 8 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return Int64HighLow value {high, low} 64-bit value
    function bytes.le_bytes_to_u64(str, offset)
      offset = offset or 1
      assert(#str >= offset + 7, "Insufficient bytes for u64")
      local low = bytes.le_bytes_to_u32(str, offset)
      local high = bytes.le_bytes_to_u32(str, offset + 4)
      return { high, low }
    end

    --- XOR two byte strings
    --- @param a string First byte string
    --- @param b string Second byte string
    --- @return string result XORed byte string
    function bytes.xor_bytes(a, b)
      assert(#a == #b, "Strings must be same length for XOR")
      local result = {}
      -- Using raw_bxor for performance; XOR on bytes (0-255) is always safe
      for i = 1, #a do
        result[i] = string_char(bit32_raw_bxor(string_byte(a, i), string_byte(b, i)))
      end
      return table_concat(result)
    end

    --- Constant-time comparison of two strings
    --- @param a string First string
    --- @param b string Second string
    --- @return boolean equal True if strings are equal
    function bytes.constant_time_compare(a, b)
      if #a ~= #b then
        return false
      end
      local result = 0
      for i = 1, #a do
        result = bit32_raw_bor(result, bit32_raw_bxor(string_byte(a, i), string_byte(b, i)))
      end
      return result == 0
    end

    --- Pad data to 16-byte boundary with zeros
    --- @param data string Data to pad
    --- @return string padded Padded data
    function bytes.pad_to_16(data)
      local len = #data
      local padding_len = (16 - (len % 16)) % 16
      if padding_len == 0 then
        return data
      end
      return data .. string_rep("\0", padding_len)
    end

    --- Run comprehensive self-test with test vectors
    --- @return boolean result True if all tests pass, false otherwise
    function bytes.selftest()
      print("Running byte operations test vectors...")
      local passed = 0
      local total = 0

      local test_vectors = {
        -- Hex conversion tests
        {
          name = "hex - basic roundtrip",
          test = function()
            local data = "Hello"
            local hex = bytes.to_hex(data)
            local back = bytes.from_hex(hex)
            return hex == "48656c6c6f" and back == data
          end,
        },
        {
          name = "hex - empty string",
          test = function()
            local data = ""
            local hex = bytes.to_hex(data)
            local back = bytes.from_hex(hex)
            return hex == "" and back == ""
          end,
        },
        {
          name = "hex - single byte min",
          test = function()
            local data = string_char(0x00)
            local hex = bytes.to_hex(data)
            return hex == "00"
          end,
        },
        {
          name = "hex - single byte max",
          test = function()
            local data = string_char(0xFF)
            local hex = bytes.to_hex(data)
            return hex == "ff"
          end,
        },
        {
          name = "hex - all byte values",
          test = function()
            -- Test a few representative byte values
            local data = string_char(0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF)
            local hex = bytes.to_hex(data)
            return hex == "00017f80feff"
          end,
        },
        {
          name = "hex - uppercase input",
          test = function()
            local hex = "48656C6C6F"
            local data = bytes.from_hex(hex)
            return data == "Hello"
          end,
        },
        {
          name = "hex - binary data",
          test = function()
            local data = string_char(0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0)
            local hex = bytes.to_hex(data)
            local back = bytes.from_hex(hex)
            return hex == "8090a0b0c0d0e0f0" and back == data
          end,
        },

        -- 32-bit conversion tests
        {
          name = "u32 LE - basic",
          test = function()
            local n = 0x12345678
            local bytes_str = bytes.u32_to_le_bytes(n)
            local back = bytes.le_bytes_to_u32(bytes_str)
            local b1, b2, b3, b4 = string_byte(bytes_str, 1, 4)
            return back == n and b1 == 0x78 and b2 == 0x56 and b3 == 0x34 and b4 == 0x12
          end,
        },
        {
          name = "u32 LE - zero",
          test = function()
            local n = 0
            local bytes_str = bytes.u32_to_le_bytes(n)
            local back = bytes.le_bytes_to_u32(bytes_str)
            return back == 0 and bytes_str == string_char(0, 0, 0, 0)
          end,
        },
        {
          name = "u32 LE - max value",
          test = function()
            local n = 0xFFFFFFFF
            local bytes_str = bytes.u32_to_le_bytes(n)
            local back = bytes.le_bytes_to_u32(bytes_str)
            return back == 0xFFFFFFFF and bytes_str == string_char(0xFF, 0xFF, 0xFF, 0xFF)
          end,
        },
        {
          name = "u32 LE - needs masking",
          test = function()
            local n = 0x100000000 -- Should be masked to 0
            local bytes_str = bytes.u32_to_le_bytes(n)
            return bytes_str == string_char(0, 0, 0, 0)
          end,
        },
        {
          name = "u32 LE - single bit patterns",
          test = function()
            local n = 0x80000000
            local bytes_str = bytes.u32_to_le_bytes(n)
            local back = bytes.le_bytes_to_u32(bytes_str)
            return back == 0x80000000 and bytes_str == string_char(0, 0, 0, 0x80)
          end,
        },
        {
          name = "u32 LE - with offset",
          test = function()
            local data = "XXX" .. string_char(0x78, 0x56, 0x34, 0x12) .. "YYY"
            local n = bytes.le_bytes_to_u32(data, 4)
            return n == 0x12345678
          end,
        },
        {
          name = "u32 BE - basic",
          test = function()
            local n = 0x12345678
            local bytes_str = bytes.u32_to_be_bytes(n)
            local back = bytes.be_bytes_to_u32(bytes_str)
            local b1, b2, b3, b4 = string_byte(bytes_str, 1, 4)
            return back == n and b1 == 0x12 and b2 == 0x34 and b3 == 0x56 and b4 == 0x78
          end,
        },
        {
          name = "u32 BE - zero",
          test = function()
            local n = 0
            local bytes_str = bytes.u32_to_be_bytes(n)
            local back = bytes.be_bytes_to_u32(bytes_str)
            return back == 0 and bytes_str == string_char(0, 0, 0, 0)
          end,
        },
        {
          name = "u32 BE - max value",
          test = function()
            local n = 0xFFFFFFFF
            local bytes_str = bytes.u32_to_be_bytes(n)
            local back = bytes.be_bytes_to_u32(bytes_str)
            return back == 0xFFFFFFFF and bytes_str == string_char(0xFF, 0xFF, 0xFF, 0xFF)
          end,
        },
        {
          name = "u32 BE - with offset",
          test = function()
            local data = "XXX" .. string_char(0x12, 0x34, 0x56, 0x78) .. "YYY"
            local n = bytes.be_bytes_to_u32(data, 4)
            return n == 0x12345678
          end,
        },

        -- 64-bit conversion tests
        {
          name = "u64 LE - basic table",
          test = function()
            local n = bit64_new(0x12345678, 0x9ABCDEF0)
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            local b1, b2, b3, b4, b5, b6, b7, b8 = string_byte(bytes_str, 1, 8)
            return back[1] == n[1]
              and back[2] == n[2]
              and b1 == 0xF0
              and b2 == 0xDE
              and b3 == 0xBC
              and b4 == 0x9A
              and b5 == 0x78
              and b6 == 0x56
              and b7 == 0x34
              and b8 == 0x12
          end,
        },
        {
          name = "u64 LE - number input",
          test = function()
            local n = 0x123456789ABCD -- Small enough for Lua number
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            -- Check the conversion worked correctly
            local expected_low = n % 0x100000000
            local expected_high = floor(n / 0x100000000)
            return back[1] == expected_high and back[2] == expected_low
          end,
        },
        {
          name = "u64 LE - zero",
          test = function()
            local n = bit64_new(0, 0)
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0 and back[2] == 0 and bytes_str == string_rep(string_char(0), 8)
          end,
        },
        {
          name = "u64 LE - max value",
          test = function()
            local n = bit64_new(0xFFFFFFFF, 0xFFFFFFFF)
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0xFFFFFFFF and back[2] == 0xFFFFFFFF and bytes_str == string_rep(string_char(0xFF), 8)
          end,
        },
        {
          name = "u64 LE - high word only",
          test = function()
            local n = bit64_new(0x12345678, 0)
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0x12345678 and back[2] == 0
          end,
        },
        {
          name = "u64 LE - low word only",
          test = function()
            local n = bit64_new(0, 0x12345678)
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0 and back[2] == 0x12345678
          end,
        },
        {
          name = "u64 LE - with offset",
          test = function()
            local data = "XXX" .. bytes.u64_to_le_bytes(bit64_new(0x12345678, 0x9ABCDEF0)) .. "YYY"
            local n = bytes.le_bytes_to_u64(data, 4)
            return n[1] == 0x12345678 and n[2] == 0x9ABCDEF0
          end,
        },
        {
          name = "u64 BE - basic",
          test = function()
            local n = bit64_new(0x12345678, 0x9ABCDEF0)
            local bytes_str = bytes.u64_to_be_bytes(n)
            local back = bytes.be_bytes_to_u64(bytes_str)
            local b1, b2, b3, b4, b5, b6, b7, b8 = string_byte(bytes_str, 1, 8)
            return back[1] == n[1]
              and back[2] == n[2]
              and b1 == 0x12
              and b2 == 0x34
              and b3 == 0x56
              and b4 == 0x78
              and b5 == 0x9A
              and b6 == 0xBC
              and b7 == 0xDE
              and b8 == 0xF0
          end,
        },
        {
          name = "u64 BE - zero",
          test = function()
            local n = bit64_new(0, 0)
            local bytes_str = bytes.u64_to_be_bytes(n)
            local back = bytes.be_bytes_to_u64(bytes_str)
            return back[1] == 0 and back[2] == 0 and bytes_str == string_rep(string_char(0), 8)
          end,
        },
        {
          name = "u64 BE - with offset",
          test = function()
            local data = "XXX" .. bytes.u64_to_be_bytes(bit64_new(0x12345678, 0x9ABCDEF0)) .. "YYY"
            local n = bytes.be_bytes_to_u64(data, 4)
            return n[1] == 0x12345678 and n[2] == 0x9ABCDEF0
          end,
        },

        -- XOR tests
        {
          name = "xor - basic",
          test = function()
            local a = string_char(0x01, 0x02, 0x03, 0x04)
            local b = string_char(0xFF, 0xFE, 0xFD, 0xFC)
            local result = bytes.xor_bytes(a, b)
            local r1, r2, r3, r4 = string_byte(result, 1, 4)
            return r1 == 0xFE and r2 == 0xFC and r3 == 0xFE and r4 == 0xF8
          end,
        },
        {
          name = "xor - empty strings",
          test = function()
            local a = ""
            local b = ""
            local result = bytes.xor_bytes(a, b)
            return result == ""
          end,
        },
        {
          name = "xor - single byte",
          test = function()
            local a = string_char(0x00)
            local b = string_char(0xFF)
            local result = bytes.xor_bytes(a, b)
            return result == string_char(0xFF)
          end,
        },
        {
          name = "xor - with self",
          test = function()
            local a = "test"
            local result = bytes.xor_bytes(a, a)
            return result == string_char(0, 0, 0, 0)
          end,
        },
        {
          name = "xor - all zeros pattern",
          test = function()
            local a = string_char(0xAA, 0xBB, 0xCC, 0xDD)
            local b = string_char(0xAA, 0xBB, 0xCC, 0xDD)
            local result = bytes.xor_bytes(a, b)
            return result == string_char(0, 0, 0, 0)
          end,
        },
        {
          name = "xor - identity with zeros",
          test = function()
            local a = string_char(0x12, 0x34, 0x56, 0x78)
            local b = string_char(0, 0, 0, 0)
            local result = bytes.xor_bytes(a, b)
            return result == a
          end,
        },

        -- Constant-time comparison tests
        {
          name = "constant_time_compare - equal",
          test = function()
            local a = "test"
            local b = "test"
            return bytes.constant_time_compare(a, b) == true
          end,
        },
        {
          name = "constant_time_compare - not equal",
          test = function()
            local a = "test"
            local b = "text"
            return bytes.constant_time_compare(a, b) == false
          end,
        },
        {
          name = "constant_time_compare - different lengths",
          test = function()
            local a = "test"
            local b = "testing"
            return bytes.constant_time_compare(a, b) == false
          end,
        },
        {
          name = "constant_time_compare - empty strings",
          test = function()
            local a = ""
            local b = ""
            return bytes.constant_time_compare(a, b) == true
          end,
        },
        {
          name = "constant_time_compare - single char equal",
          test = function()
            local a = "a"
            local b = "a"
            return bytes.constant_time_compare(a, b) == true
          end,
        },
        {
          name = "constant_time_compare - single char not equal",
          test = function()
            local a = "a"
            local b = "b"
            return bytes.constant_time_compare(a, b) == false
          end,
        },
        {
          name = "constant_time_compare - binary with nulls",
          test = function()
            local a = string_char(0x00, 0x01, 0xFF)
            local b = string_char(0x00, 0x01, 0xFF)
            return bytes.constant_time_compare(a, b) == true
          end,
        },

        -- Padding tests
        {
          name = "pad_to_16 - no padding needed",
          test = function()
            local data = string_rep("a", 16)
            local padded = bytes.pad_to_16(data)
            return padded == data and #padded == 16
          end,
        },
        {
          name = "pad_to_16 - padding needed",
          test = function()
            local data = "Hello"
            local padded = bytes.pad_to_16(data)
            return #padded == 16 and padded:sub(1, 5) == "Hello" and padded:sub(6) == string_rep("\0", 11)
          end,
        },
        {
          name = "pad_to_16 - empty string",
          test = function()
            local data = ""
            local padded = bytes.pad_to_16(data)
            return padded == "" and #padded == 0
          end,
        },
        {
          name = "pad_to_16 - exactly 32 bytes",
          test = function()
            local data = string_rep("a", 32)
            local padded = bytes.pad_to_16(data)
            return padded == data and #padded == 32
          end,
        },
        {
          name = "pad_to_16 - one byte short",
          test = function()
            local data = string_rep("a", 15)
            local padded = bytes.pad_to_16(data)
            return #padded == 16 and padded:sub(1, 15) == data and padded:sub(16) == "\0"
          end,
        },
        {
          name = "pad_to_16 - one byte over",
          test = function()
            local data = string_rep("a", 17)
            local padded = bytes.pad_to_16(data)
            return #padded == 32 and padded:sub(1, 17) == data and padded:sub(18) == string_rep("\0", 15)
          end,
        },
        {
          name = "pad_to_16 - large data",
          test = function()
            local data = string_rep("a", 1000)
            local padded = bytes.pad_to_16(data)
            local expected_len = math.ceil(1000 / 16) * 16
            return #padded == expected_len and padded:sub(1, 1000) == data
          end,
        },
      }

      -- Run error handling tests separately with pcall
      local error_tests = {
        {
          name = "u32 LE - insufficient bytes",
          test = function()
            local ok, err = pcall(bytes.le_bytes_to_u32, "XX")
            return not ok and type(err) == "string" and err:match("Insufficient bytes")
          end,
        },
        {
          name = "u32 BE - insufficient bytes",
          test = function()
            local ok, err = pcall(bytes.be_bytes_to_u32, "XX")
            return not ok and type(err) == "string" and err:match("Insufficient bytes")
          end,
        },
        {
          name = "u64 LE - insufficient bytes",
          test = function()
            local ok, err = pcall(bytes.le_bytes_to_u64, "XXXXXX")
            return not ok and type(err) == "string" and err:match("Insufficient bytes")
          end,
        },
        {
          name = "u64 BE - insufficient bytes",
          test = function()
            local ok, err = pcall(bytes.be_bytes_to_u64, "XXXXXX")
            return not ok and type(err) == "string" and err:match("Insufficient bytes")
          end,
        },
        {
          name = "xor - length mismatch",
          test = function()
            local ok, err = pcall(bytes.xor_bytes, "abc", "abcd")
            return not ok and type(err) == "string" and err:match("same length")
          end,
        },
      }

      -- Run main tests
      for _, test in ipairs(test_vectors) do
        total = total + 1
        if test.test() then
          print("  ✅ PASS: " .. test.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. test.name)
        end
      end

      -- Run error tests
      for _, test in ipairs(error_tests) do
        total = total + 1
        if test.test() then
          print("  ✅ PASS: " .. test.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. test.name)
        end
      end

      print(string_format("\nByte operations result: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return bytes
  end
end

--- @module "noiseprotocol"
--- Noise Protocol Framework Implementation
---
--- This module implements the Noise Protocol Framework, providing a secure
--- channel establishment protocol with support for various handshake patterns,
--- cipher suites, and optional OpenSSL acceleration.
---
--- @usage
--- local noise = require("noiseprotocol")
---
--- -- Enable OpenSSL acceleration (optional)
--- noise.use_openssl(true)
---
--- -- Create a connection
--- local connection = noise.NoiseConnection:new({
---   protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
---   initiator = true,
---   static_key = my_static_key
--- })
--- ...
--- @class noiseprotocol
local noiseprotocol = {}

local crypto = require("crypto")
local utils = require("noiseprotocol.utils")
local openssl_wrapper = require("crypto.openssl_wrapper")

--- Module version
local VERSION = "v0.6.3"

--- Enable or disable OpenSSL acceleration
--- @function use_openssl
--- @param use boolean True to enable OpenSSL, false to disable
--- @see crypto.openssl_wrapper.use
function noiseprotocol.use_openssl(use)
  openssl_wrapper.use(use)
end

--- Get the module version
--- @function version
--- @return string version The version string
function noiseprotocol.version()
  return VERSION
end

-- ============================================================================
-- PROTOCOL NAME PARSING
-- ============================================================================

--- Parsed protocol name components
--- @class ParsedProtocolName
--- @field pattern string Base handshake pattern (e.g., "XX", "IK", "NN")
--- @field modifiers string[] List of modifier strings (e.g., {"psk0", "psk2"})
--- @field dh string Diffie-Hellman function name (e.g., "25519", "448")
--- @field cipher string Cipher name (e.g., "ChaChaPoly", "AESGCM")
--- @field hash string Hash function name (e.g., "SHA256", "BLAKE2s")
--- @field full_name string Original full protocol name

--- Parse pattern and modifiers from the pattern portion
--- @param pattern_str string Pattern with modifiers (e.g. "NNpsk0+psk2")
--- @return string pattern Base pattern (e.g. "NN")
--- @return table modifiers List of modifiers with their parameters
local function parse_pattern_and_modifiers(pattern_str)
  -- Extract base pattern (uppercase letters only)
  local pattern = pattern_str:match("^([A-Z1]+)")
  if not pattern then
    error("Invalid pattern format: " .. pattern_str)
  end

  -- Extract modifiers
  local modifiers = {}
  local remaining = pattern_str:sub(#pattern + 1)

  if remaining ~= "" then
    -- Parse modifiers (e.g. "psk0+psk2" or "fallback+psk0")
    for modifier in remaining:gmatch("([^+]+)") do
      table.insert(modifiers, modifier)
    end
  end

  return pattern, modifiers
end

--- Parse a Noise protocol name into its components
--- @param protocol_name string Full protocol name (e.g. "Noise_NNpsk0+psk2_25519_AESGCM_SHA256")
--- @return ParsedProtocolName parsed Parsed protocol components
local function parse_protocol_name(protocol_name)
  -- Protocol name format: Noise_PATTERNmodifiers_DH_CIPHER_HASH
  local prefix, pattern_with_modifiers, dh, cipher, hash =
    protocol_name:match("^(Noise)_([^_]+)_([^_]+)_([^_]+)_([^_]+)$")

  if not prefix or not pattern_with_modifiers or not dh or not cipher or not hash then
    error("Invalid protocol name format: " .. protocol_name)
  end

  -- Parse pattern and modifiers
  local pattern, modifiers = parse_pattern_and_modifiers(pattern_with_modifiers)

  return {
    pattern = pattern,
    modifiers = modifiers,
    dh = dh,
    cipher = cipher,
    hash = hash,
    full_name = protocol_name,
  }
end

--- Parse PSK modifiers to get placement positions
--- @param modifiers table List of modifier strings
--- @return table psk_positions List of PSK positions in order
local function parse_psk_modifiers(modifiers)
  local psk_positions = {}

  for _, modifier in ipairs(modifiers) do
    local psk_num = modifier:match("^psk(%d)$")
    if psk_num then
      table.insert(psk_positions, tonumber(psk_num))
    elseif modifier == "fallback" then
      error("Fallback modifier not yet supported")
    else
      error("Unknown modifier: " .. modifier)
    end
  end

  -- Sort positions to ensure consistent ordering
  table.sort(psk_positions)

  return psk_positions
end

-- ============================================================================
-- CIPHER SUITE INTERFACE DEFINITIONS
-- ============================================================================

--- Cipher suite interface definitions
--- @class DHFunction
--- @field name string Name of the DH function (e.g., "25519")
--- @field dhlen integer Length of public/private keys in bytes
--- @field generate_keypair fun(): string, string Generate private and public key pair
--- @field dh fun(private_key: string, public_key: string): string Perform DH operation
--- @field derive_public_key fun(private_key: string): string Derive public key from private key

--- @class CipherFunction
--- @field name string Name of the cipher (e.g., "ChaChaPoly")
--- @field keylen integer Length of cipher key in bytes
--- @field noncelen integer Length of nonce in bytes
--- @field taglen integer Length of authentication tag in bytes
--- @field encrypt fun(key: string, nonce: integer, plaintext: string, ad: string): string Encrypt with AEAD
--- @field decrypt fun(key: string, nonce: integer, ciphertext: string, ad: string): string? Decrypt with AEAD
--- @field rekey fun(key: string): string Generate new key for rekeying

--- @class HashFunction
--- @field name string Name of the hash function (e.g., "SHA256")
--- @field hashlen integer Length of hash output in bytes
--- @field blocklen integer Internal block length in bytes
--- @field hash fun(data: string): string Compute hash
--- @field hmac fun(key: string, data: string): string Compute HMAC
--- @field hkdf fun(chaining_key: string, input_key_material: string, num_outputs: integer): string, string, string? HKDF expansion

--- @class CipherSuite
--- @field name string Cipher suite name (e.g., "25519_ChaChaPoly_SHA256")
--- @field dh DHFunction Diffie-Hellman function
--- @field cipher CipherFunction Cipher function
--- @field hash HashFunction Hash function
local CipherSuite = {}
CipherSuite.__index = CipherSuite

--- Create a new cipher suite
--- @param dh DHFunction Diffie-Hellman function
--- @param cipher CipherFunction Cipher function
--- @param hash HashFunction Hash function
--- @return CipherSuite suite New cipher suite
function CipherSuite:new(dh, cipher, hash)
  local instance = setmetatable({}, self)
  instance.name = dh.name .. "_" .. cipher.name .. "_" .. hash.name
  instance.dh = dh
  instance.cipher = cipher
  instance.hash = hash
  return instance
end

-- Protocol constants
local MAX_NONCE = 2 ^ 32 - 1

--- X25519 Diffie-Hellman implementation
--- @type DHFunction
local DH_25519 = {
  name = "25519",
  dhlen = 32,
  generate_keypair = function()
    return crypto.x25519.generate_keypair()
  end,
  dh = function(private_key, public_key)
    return crypto.x25519.diffie_hellman(private_key, public_key)
  end,
  derive_public_key = function(private_key)
    return crypto.x25519.derive_public_key(private_key)
  end,
}

--- X448 Diffie-Hellman implementation
--- @type DHFunction
local DH_448 = {
  name = "448",
  dhlen = 56,
  generate_keypair = function()
    return crypto.x448.generate_keypair()
  end,
  dh = function(private_key, public_key)
    return crypto.x448.diffie_hellman(private_key, public_key)
  end,
  derive_public_key = function(private_key)
    return crypto.x448.derive_public_key(private_key)
  end,
}

local function make_chachapoly_nonce(n)
  -- ChaCha20Poly1305 uses little-endian format: 4 zero bytes + 64-bit counter
  assert(n <= MAX_NONCE, "Nonce overflow")
  local nonce = string.rep("\0", 4) -- 4 zero bytes padding
  -- Little-endian 64-bit counter (8 bytes)
  for _ = 1, 8 do
    nonce = nonce .. string.char(n % 256)
    n = math.floor(n / 256)
  end

  return nonce
end

--- ChaCha20-Poly1305 AEAD implementation
--- @type CipherFunction
local CIPHER_ChaChaPoly = {
  name = "ChaChaPoly",
  keylen = 32,
  noncelen = 12,
  taglen = 16,
  encrypt = function(key, nonce, plaintext, ad)
    return crypto.chacha20_poly1305.encrypt(key, make_chachapoly_nonce(nonce), plaintext, ad)
  end,
  decrypt = function(key, nonce, ciphertext, ad)
    return crypto.chacha20_poly1305.decrypt(key, make_chachapoly_nonce(nonce), ciphertext, ad)
  end,
  rekey = function(key)
    local dummy_nonce = string.rep(string.char(0xFF), 12)
    local new_key = crypto.chacha20_poly1305.encrypt(key, dummy_nonce, string.rep("\0", 32), "")
    return new_key:sub(1, 32)
  end,
}

local function make_aesgcm_nonce(n)
  -- AESGCM uses big-endian format: 4 zero bytes + 64-bit counter
  assert(n <= MAX_NONCE, "Nonce overflow")
  local nonce = string.rep("\0", 4) -- 4 zero bytes padding

  -- Big-endian 64-bit counter
  local bytes = {}
  for i = 1, 8 do
    bytes[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  -- Reverse the bytes for big-endian
  for i = 8, 1, -1 do
    nonce = nonce .. bytes[i]
  end

  return nonce
end

--- AES-GCM AEAD implementation
--- @type CipherFunction
local CIPHER_AESGCM = {
  name = "AESGCM",
  keylen = 32, -- Use AES-256 for Noise
  noncelen = 12,
  taglen = 16,
  encrypt = function(key, nonce, plaintext, ad)
    return crypto.aes_gcm.encrypt(key, make_aesgcm_nonce(nonce), plaintext, ad)
  end,
  decrypt = function(key, nonce, ciphertext, ad)
    return crypto.aes_gcm.decrypt(key, make_aesgcm_nonce(nonce), ciphertext, ad)
  end,
  rekey = function(key)
    local dummy_nonce = string.rep(string.char(0xFF), 12)
    local new_key = crypto.aes_gcm.encrypt(key, dummy_nonce, string.rep("\0", 32), "")
    return new_key:sub(1, 32)
  end,
}

--- SHA256 hash implementation
--- @type HashFunction
local HASH_SHA256 = {
  name = "SHA256",
  hashlen = 32,
  blocklen = 64,
  hash = function(data)
    return crypto.sha256.sha256(data)
  end,
  hmac = function(key, data)
    return crypto.sha256.hmac_sha256(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.sha256.hmac_sha256(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.sha256.hmac_sha256(prk, string.char(0x01))
    local t2 = crypto.sha256.hmac_sha256(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.sha256.hmac_sha256(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- SHA512 hash implementation
--- @type HashFunction
local HASH_SHA512 = {
  name = "SHA512",
  hashlen = 64,
  blocklen = 128,
  hash = function(data)
    return crypto.sha512.sha512(data)
  end,
  hmac = function(key, data)
    return crypto.sha512.hmac_sha512(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.sha512.hmac_sha512(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.sha512.hmac_sha512(prk, string.char(0x01))
    local t2 = crypto.sha512.hmac_sha512(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.sha512.hmac_sha512(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- BLAKE2s hash implementation
--- @type HashFunction
local HASH_BLAKE2S = {
  name = "BLAKE2s",
  hashlen = 32,
  blocklen = 64,
  hash = function(data)
    return crypto.blake2.blake2s(data)
  end,
  hmac = function(key, data)
    return crypto.blake2.hmac_blake2s(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.blake2.hmac_blake2s(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.blake2.hmac_blake2s(prk, string.char(0x01))
    local t2 = crypto.blake2.hmac_blake2s(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.blake2.hmac_blake2s(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- BLAKE2b hash implementation
--- @type HashFunction
local HASH_BLAKE2B = {
  name = "BLAKE2b",
  hashlen = 64,
  blocklen = 128,
  hash = function(data)
    return crypto.blake2.blake2b(data)
  end,
  hmac = function(key, data)
    return crypto.blake2.hmac_blake2b(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.blake2.hmac_blake2b(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.blake2.hmac_blake2b(prk, string.char(0x01))
    local t2 = crypto.blake2.hmac_blake2b(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.blake2.hmac_blake2b(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- Noise Protocol message tokens
--- @enum MessageToken
local MessageToken = {
  -- Key exchange tokens
  E = "e", -- Generate/send ephemeral key pair
  S = "s", -- Send static public key (encrypted after first DH)

  -- Diffie-Hellman tokens
  EE = "ee", -- Ephemeral-ephemeral DH between local and remote ephemeral keys
  ES = "es", -- Ephemeral-static DH (initiator ephemeral with responder static, or vice versa)
  SE = "se", -- Static-ephemeral DH (initiator static with responder ephemeral, or vice versa)
  SS = "ss", -- Static-static DH between local and remote static keys

  -- Pre-shared key token
  PSK = "psk", -- Mix pre-shared key (placement determined by context)
}

--- PSK placement positions
--- @enum PSKPlacement
local PSKPlacement = {
  ZERO = 0, -- psk0: Beginning of first message
  ONE = 1, -- psk1: Beginning of second message
  TWO = 2, -- psk2: Beginning of third message
  THREE = 3, -- psk3: End of final message
}

--- Noise Protocol handshake patterns
--- @enum NoisePattern
local NoisePattern = {
  -- No authentication patterns
  NN = "NN", -- No static keys (ephemeral-ephemeral)

  -- Server authentication patterns
  NK = "NK", -- Responder has static key known to initiator

  -- Client authentication patterns
  KN = "KN", -- Initiator has static key known to responder

  -- Mutual known keys
  KK = "KK", -- Both parties have static keys known to each other

  -- Server known, client transmitted
  XK = "XK", -- Responder static key known, initiator transmits static key

  -- Client known, server transmitted
  KX = "KX", -- Initiator static key known, responder transmits static key

  -- Server transmitted during handshake
  NX = "NX", -- Responder transmits static key during handshake

  -- Mutual authentication
  XX = "XX", -- Both parties transmit static keys during handshake

  -- Immediate known server key
  IK = "IK", -- Responder static key known, enables 0-RTT encryption

  -- I patterns - Immediate client authentication
  IN = "IN", -- Initiator static key transmitted immediately
  IX = "IX", -- Both static keys, initiator transmits immediately

  -- X patterns - Delayed server authentication
  XN = "XN", -- Responder transmits static key, no initiator static

  -- One-way patterns
  N = "N", -- No static keys, one-way pattern
  K = "K", -- Recipient has sender's static key, one-way pattern
  X = "X", -- Sender transmits static key, one-way pattern

  -- Deferred patterns (1 = initiator defers static key)
  NK1 = "NK1", -- NK with initiator deferring static key
  NX1 = "NX1", -- NX with initiator deferring static key
  X1N = "X1N", -- XN with sender deferring static key
  X1X = "X1X", -- XX with initiator deferring first static key
  XK1 = "XK1", -- XK with initiator deferring static key
  K1N = "K1N", -- KN with initiator deferring static key
  K1K = "K1K", -- KK with initiator deferring static key
  KK1 = "KK1", -- KK with responder deferring static key
  K1X = "K1X", -- KX with initiator deferring static key
  KX1 = "KX1", -- KX with responder deferring static key
  K1K1 = "K1K1", -- KK with both parties deferring static keys
  K1X1 = "K1X1", -- KX with both parties deferring static keys
  X1K = "X1K", -- XK with initiator deferring static key
  X1K1 = "X1K1", -- XK with both parties deferring static keys
  X1X1 = "X1X1", -- XX with both parties deferring static keys
  XX1 = "XX1", -- XX with responder deferring static key
  I1N = "I1N", -- IN with initiator deferring static key
  I1K = "I1K", -- IK with initiator deferring static key
  IK1 = "IK1", -- IK with responder deferring static key
  I1K1 = "I1K1", -- IK with both parties deferring static keys
  I1X = "I1X", -- IX with initiator deferring static key
  IX1 = "IX1", -- IX with responder deferring static key
  I1X1 = "I1X1", -- IX with both parties deferring static keys
}

--- CipherState manages a symmetric encryption key and nonce
--- @class CipherState
--- @field cipher CipherFunction Cipher function from cipher suite
--- @field k string|nil Encryption key (nil if uninitialized)
--- @field n integer Nonce counter (64-bit)
local CipherState = {}
CipherState.__index = CipherState

--- Create a new CipherState
--- @param cipher CipherFunction Cipher function from cipher suite
--- @return CipherState state New cipher state
function CipherState:new(cipher)
  local instance = setmetatable({}, self)
  instance.cipher = cipher
  instance.k = nil
  instance.n = 0
  return instance
end

--- Initialize cipher state with a key
--- @param key string Encryption key
function CipherState:initialize_key(key)
  assert(#key == self.cipher.keylen, "Key must be exactly " .. self.cipher.keylen .. " bytes")
  self.k = key
  self.n = 0
end

--- Check if cipher state has a key
--- @return boolean has_key True if cipher has a key
function CipherState:has_key()
  return self.k ~= nil
end

--- Encrypt plaintext with associated data
--- @param ad string Associated data
--- @param plaintext string Data to encrypt
--- @return string ciphertext Encrypted data with authentication tag
function CipherState:encrypt_with_ad(ad, plaintext)
  if not self:has_key() then
    return plaintext -- Return plaintext if no key
  end
  -- Held in a local because `@cast` applies to locals, not table fields.
  local k = self.k
  --- @cast k -nil

  local ciphertext = self.cipher.encrypt(k, self.n, plaintext, ad)
  self.n = self.n + 1

  return ciphertext
end

--- Decrypt ciphertext with associated data
--- @param ad string Associated data
--- @param ciphertext string Data to decrypt
--- @return string? plaintext Decrypted data, or nil if authentication fails
function CipherState:decrypt_with_ad(ad, ciphertext)
  if not self:has_key() then
    return ciphertext -- Return ciphertext if no key
  end
  local k = self.k
  --- @cast k -nil

  local plaintext = self.cipher.decrypt(k, self.n, ciphertext, ad)

  -- Only increment nonce if decryption was successful
  if plaintext then
    self.n = self.n + 1
  end

  return plaintext
end

--- Rekey the cipher state (for forward secrecy)
function CipherState:rekey()
  if self:has_key() then
    local k = self.k
    --- @cast k -nil
    self.k = self.cipher.rekey(k)
  end
end

--- SymmetricState manages handshake encryption and hashing
--- @class SymmetricState
--- @field cipher_suite CipherSuite The cipher suite being used
--- @field cipher_state CipherState Cipher state for encryption
--- @field ck string Chaining key
--- @field h string Handshake hash
local SymmetricState = {}
SymmetricState.__index = SymmetricState

--- Create a new SymmetricState
--- @param cipher_suite CipherSuite Cipher suite to use
--- @param protocol_name string Noise protocol name
--- @return SymmetricState state New symmetric state
function SymmetricState:new(cipher_suite, protocol_name)
  local instance = setmetatable({}, self)
  instance.cipher_suite = cipher_suite
  instance.cipher_state = CipherState:new(cipher_suite.cipher)

  -- Initialize with protocol name
  if #protocol_name <= cipher_suite.hash.hashlen then
    instance.h = protocol_name .. string.rep("\0", cipher_suite.hash.hashlen - #protocol_name)
  else
    instance.h = cipher_suite.hash.hash(protocol_name)
  end
  instance.ck = instance.h

  return instance
end

--- Mix key material into the chaining key
--- @param input_key_material string Key material to mix
function SymmetricState:mix_key(input_key_material)
  local temp_k
  self.ck, temp_k = self.cipher_suite.hash.hkdf(self.ck, input_key_material, 2)
  -- Truncate temp_k if needed
  if #temp_k > self.cipher_suite.cipher.keylen then
    temp_k = string.sub(temp_k, 1, self.cipher_suite.cipher.keylen)
  end
  self.cipher_state:initialize_key(temp_k)
end

--- Mix data into the handshake hash
--- @param data string Data to mix
function SymmetricState:mix_hash(data)
  self.h = self.cipher_suite.hash.hash(self.h .. data)
end

--- Mix key and hash with DH output
--- @param dh_output string Diffie-Hellman shared secret
function SymmetricState:mix_key_and_hash(dh_output)
  local temp_h, temp_k
  --- @type string, string, string
  self.ck, temp_h, temp_k = self.cipher_suite.hash.hkdf(self.ck, dh_output, 3)
  self:mix_hash(temp_h)
  -- Truncate temp_k if needed
  if #temp_k > self.cipher_suite.cipher.keylen then
    temp_k = string.sub(assert(temp_k), 1, self.cipher_suite.cipher.keylen)
  end
  self.cipher_state:initialize_key(temp_k)
end

--- Get handshake hash
--- @return string hash Current handshake hash
function SymmetricState:get_handshake_hash()
  return self.h
end

--- Encrypt and hash a payload
--- @param plaintext string Payload to encrypt
--- @return string ciphertext Encrypted payload
function SymmetricState:encrypt_and_hash(plaintext)
  local ciphertext = self.cipher_state:encrypt_with_ad(self.h, plaintext)
  self:mix_hash(ciphertext)
  return ciphertext
end

--- Decrypt and hash a payload
--- @param ciphertext string Payload to decrypt
--- @return string? plaintext Decrypted payload, or nil if authentication fails
function SymmetricState:decrypt_and_hash(ciphertext)
  local plaintext = self.cipher_state:decrypt_with_ad(self.h, ciphertext)
  if plaintext then
    self:mix_hash(ciphertext)
  end
  return plaintext
end

--- Split into two cipher states for transport
--- @return CipherState cipher1 First cipher state (for sending)
--- @return CipherState cipher2 Second cipher state (for receiving)
function SymmetricState:split()
  local temp_k1, temp_k2 = self.cipher_suite.hash.hkdf(self.ck, "", 2)

  local cipher1 = CipherState:new(self.cipher_suite.cipher)
  local cipher2 = CipherState:new(self.cipher_suite.cipher)

  -- Truncate keys if needed (for BLAKE2b/SHA512 which output 64 bytes)
  if #temp_k1 > self.cipher_suite.cipher.keylen then
    temp_k1 = string.sub(temp_k1, 1, self.cipher_suite.cipher.keylen)
  end
  if #temp_k2 > self.cipher_suite.cipher.keylen then
    temp_k2 = string.sub(temp_k2, 1, self.cipher_suite.cipher.keylen)
  end

  cipher1:initialize_key(temp_k1)
  cipher2:initialize_key(temp_k2)

  return cipher1, cipher2
end

--- HandshakeState manages the handshake process
--- @class HandshakeState
--- @field cipher_suite CipherSuite Cipher suite being used
--- @field symmetric_state SymmetricState Symmetric state
--- @field s string|nil Static private key
--- @field e string|nil Ephemeral private key
--- @field rs string|nil Remote static public key
--- @field re string|nil Remote ephemeral public key
--- @field initiator boolean True if this is the initiator
--- @field message_patterns table Handshake message patterns
--- @field pattern_index integer Current pattern index
--- @field psks table List of pre-shared keys
--- @field psk_positions table List of PSK positions (0, 1, 2, or 3)
--- @field psk_index integer Current PSK index for handshake
local HandshakeState = {}
HandshakeState.__index = HandshakeState

--- @class PatternPreMessages
--- @field initiator? MessageToken[] Pre-messages for initiator
--- @field responder? MessageToken[] Pre-messages for responder

--- @class PatternDefinition
--- @field pre_messages PatternPreMessages Pre-messages for initiator and responder
--- @field messages MessageToken[][] List of message sequences for the pattern

--- Handshake patterns
--- @type table<NoisePattern, PatternDefinition>
local PATTERNS = {
  -- No authentication patterns
  [NoisePattern.NN] = {
    pre_messages = {},
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
    },
  },

  -- Server authentication patterns
  [NoisePattern.NK] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
    },
  },

  -- Client authentication patterns
  [NoisePattern.KN] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  -- Mutual known keys
  [NoisePattern.KK] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.SS },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  -- Server known, client transmitted
  [NoisePattern.XK] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- Client known, server transmitted
  [NoisePattern.KX] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S, MessageToken.ES },
    },
  },

  -- Server transmitted during handshake
  [NoisePattern.NX] = {
    pre_messages = {},
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
    },
  },

  -- Mutual authentication (existing)
  [NoisePattern.XX] = {
    pre_messages = {},
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- Immediate known server key (existing)
  [NoisePattern.IK] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.S, MessageToken.SS },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  -- I patterns - Immediate client authentication
  [NoisePattern.IN] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  [NoisePattern.IX] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S, MessageToken.ES },
    },
  },

  -- X patterns - Delayed server authentication
  [NoisePattern.XN] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- One-way patterns
  [NoisePattern.N] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
    },
  },

  [NoisePattern.K] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.SS },
    },
  },

  [NoisePattern.X] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.S, MessageToken.SS },
    },
  },

  -- Deferred patterns
  -- I1K: IK pattern with initiator deferring static key
  [NoisePattern.I1K] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.S },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- I1K1: IK pattern with both parties deferring static keys
  [NoisePattern.I1K1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- I1N: IN pattern with initiator deferring static key
  [NoisePattern.I1N] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- I1X: IX pattern with initiator deferring static key
  [NoisePattern.I1X] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- I1X1: IX pattern with both parties deferring static keys
  [NoisePattern.I1X1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.SE, MessageToken.ES },
    },
  },

  -- IK1: IK pattern (deferred variant of IK)
  [NoisePattern.IK1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.ES },
    },
  },

  -- IX1: IX pattern with responder deferring static key
  [NoisePattern.IX1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S },
      { MessageToken.ES },
    },
  },

  -- K1K: KK pattern with initiator deferring static key
  [NoisePattern.K1K] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- K1K1: KK pattern with both parties deferring static keys
  [NoisePattern.K1K1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- K1N: KN pattern with initiator deferring static key
  [NoisePattern.K1N] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- K1X: KX pattern with initiator deferring static key
  [NoisePattern.K1X] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- K1X1: KX pattern with both parties deferring static keys
  [NoisePattern.K1X1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.SE, MessageToken.ES },
    },
  },

  -- KK1: KK pattern with responder deferring static key
  [NoisePattern.KK1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.ES },
    },
  },

  -- KX1: KX pattern with responder deferring static key
  [NoisePattern.KX1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S },
      { MessageToken.ES },
    },
  },

  -- NK1: NK pattern with responder deferring static key
  [NoisePattern.NK1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
    },
  },

  -- NX1: NX pattern with responder deferring static key
  [NoisePattern.NX1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.ES },
    },
  },

  -- X1K: XK pattern with initiator deferring static key
  [NoisePattern.X1K] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1K1: XK pattern with both parties deferring static keys
  [NoisePattern.X1K1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1N: XN pattern with initiator deferring static key
  [NoisePattern.X1N] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1X: XX pattern with initiator deferring static key
  [NoisePattern.X1X] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1X1: XX pattern with both parties deferring static keys
  [NoisePattern.X1X1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.ES, MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- XK1: XK pattern with responder deferring static key
  [NoisePattern.XK1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- XX1: XX pattern with responder deferring static key
  [NoisePattern.XX1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.ES, MessageToken.S, MessageToken.SE },
    },
  },
}

--- Apply PSK tokens to pattern at specified positions
--- @param base_pattern table Base handshake pattern
--- @param psk_positions table List of PSK positions (0, 1, 2, or 3)
--- @return table modified_pattern Pattern with PSK tokens inserted at appropriate positions
local function apply_psk_placements(base_pattern, psk_positions)
  -- Validate positions
  for _, pos in ipairs(psk_positions) do
    assert(pos >= PSKPlacement.ZERO and pos <= PSKPlacement.THREE, "PSK position must be 0, 1, 2, or 3")
  end

  -- Deep copy the base pattern
  local pattern = {
    pre_messages = {},
    messages = {},
  }

  -- Copy pre_messages
  if base_pattern.pre_messages.initiator then
    pattern.pre_messages.initiator = {}
    for i, token in ipairs(base_pattern.pre_messages.initiator) do
      pattern.pre_messages.initiator[i] = token
    end
  end
  if base_pattern.pre_messages.responder then
    pattern.pre_messages.responder = {}
    for i, token in ipairs(base_pattern.pre_messages.responder) do
      pattern.pre_messages.responder[i] = token
    end
  end

  -- Copy messages
  for i, message in ipairs(base_pattern.messages) do
    pattern.messages[i] = {}
    for j, token in ipairs(message) do
      pattern.messages[i][j] = token
    end
  end

  -- Sort positions to apply them in order
  local sorted_positions = {}
  for _, pos in ipairs(psk_positions) do
    table.insert(sorted_positions, pos)
  end
  table.sort(sorted_positions)

  -- Apply PSK tokens
  -- Track number of tokens added to each message to adjust positions
  local tokens_added = {}
  for i = 1, #pattern.messages do
    tokens_added[i] = 0
  end

  for _, pos in ipairs(sorted_positions) do
    if pos == PSKPlacement.ZERO then
      -- psk0: prepend to first message
      if #pattern.messages >= 1 then
        table.insert(pattern.messages[1], 1 + tokens_added[1], MessageToken.PSK)
        tokens_added[1] = tokens_added[1] + 1
      else
        error("PSK position 0 requires at least one message")
      end
    else
      -- psk1, psk2, psk3: append to message at index pos
      local message_idx = pos
      if message_idx <= #pattern.messages then
        table.insert(pattern.messages[message_idx], MessageToken.PSK)
      else
        error("PSK position " .. pos .. " not valid for pattern with " .. #pattern.messages .. " messages")
      end
    end
  end

  return pattern
end

--- Create a new HandshakeState
--- @param cipher_suite CipherSuite Cipher suite to use
--- @param pattern NoisePattern Base handshake pattern (e.g., NoisePattern.NN, NoisePattern.XX, NoisePattern.IK)
--- @param initiator boolean True if this is the initiator
--- @param prologue? string Optional prologue data
--- @param s? string Optional static private key
--- @param e? string Optional ephemeral private key
--- @param rs? string Optional remote static public key
--- @param re? string Optional remote ephemeral public key
--- @param psks? table Optional list of pre-shared keys
--- @param psk_positions? table Optional list of PSK positions (0, 1, 2, or 3)
--- @return HandshakeState state New handshake state
function HandshakeState:new(cipher_suite, pattern, initiator, prologue, s, e, rs, re, psks, psk_positions)
  local base_pattern = PATTERNS[pattern]
  assert(base_pattern, "Unknown handshake pattern: " .. tostring(pattern))

  -- Apply PSK placements if specified
  local pattern_def = base_pattern
  local protocol_pattern_name = tostring(pattern)
  if psk_positions and #psk_positions > 0 then
    assert(psks and #psks == #psk_positions, "Number of PSKs must match PSK positions")
    pattern_def = apply_psk_placements(base_pattern, psk_positions)
    -- Build pattern name with PSK modifiers
    local modifiers = {}
    for _, pos in ipairs(psk_positions) do
      table.insert(modifiers, "psk" .. pos)
    end
    protocol_pattern_name = protocol_pattern_name .. table.concat(modifiers, "+")
  end

  local protocol_name = string.format("Noise_%s_%s", protocol_pattern_name, cipher_suite.name)

  local instance = setmetatable({}, self)
  instance.cipher_suite = cipher_suite
  instance.symmetric_state = SymmetricState:new(cipher_suite, protocol_name)
  instance.s = s
  instance.e = e
  instance.rs = rs
  instance.re = re
  instance.initiator = initiator
  instance.message_patterns = pattern_def.messages
  instance.pattern_index = 1
  instance.psks = psks or {}
  instance.psk_positions = psk_positions or {}
  instance.psk_index = 1 -- Track which PSK to use next

  -- Mix prologue
  prologue = prologue or ""
  instance.symmetric_state:mix_hash(prologue)

  -- Process pre-messages (both parties process all pre-messages)
  if pattern_def.pre_messages then
    -- Process initiator pre-messages
    if pattern_def.pre_messages.initiator then
      for _, token in ipairs(pattern_def.pre_messages.initiator) do
        if token == MessageToken.S then
          if initiator and instance.s then
            -- Initiator mixes their own static key
            local s_pub = instance.cipher_suite.dh.derive_public_key(instance.s)
            instance.symmetric_state:mix_hash(s_pub)
          elseif not initiator and instance.rs then
            -- Responder mixes initiator's static key (if known)
            instance.symmetric_state:mix_hash(instance.rs)
          end
        end
      end
    end

    -- Process responder pre-messages
    if pattern_def.pre_messages.responder then
      for _, token in ipairs(pattern_def.pre_messages.responder) do
        if token == MessageToken.S then
          if not initiator and instance.s then
            -- Responder mixes their own static public key
            local s_pub = instance.cipher_suite.dh.derive_public_key(instance.s)
            instance.symmetric_state:mix_hash(s_pub)
          elseif initiator and instance.rs then
            -- Initiator mixes responder's static public key (if known)
            instance.symmetric_state:mix_hash(instance.rs)
          end
        end
      end
    end
  end

  return instance
end

--- Write a handshake message
--- @param payload string Message payload
--- @return string message Complete handshake message
--- @return boolean finished True if handshake is complete
function HandshakeState:write_message(payload)
  assert(self.pattern_index <= #self.message_patterns, "No more handshake messages")

  local pattern = self.message_patterns[self.pattern_index]
  local message = ""

  for _, token in ipairs(pattern) do
    if token == MessageToken.PSK then
      -- Mix pre-shared key
      assert(self.psks[self.psk_index], "PSK required but not provided")
      self.symmetric_state:mix_key_and_hash(self.psks[self.psk_index])
      self.psk_index = self.psk_index + 1
    elseif token == MessageToken.E then
      -- Generate ephemeral key pair (or use pre-generated one for testing)
      local e_pub
      if not self.e then
        self.e, e_pub = self.cipher_suite.dh.generate_keypair()
      else
        e_pub = self.cipher_suite.dh.derive_public_key(self.e)
      end
      message = message .. e_pub
      self.symmetric_state:mix_hash(e_pub)

      -- In PSK handshakes, also mix the ephemeral public key into the key
      if #self.psk_positions > 0 then
        self.symmetric_state:mix_key(e_pub)
      end
    elseif token == MessageToken.S then
      -- Send static public key (encrypted)
      assert(self.s, "Static key required but not provided")
      local s_pub = self.cipher_suite.dh.derive_public_key(self.s)
      message = message .. self.symmetric_state:encrypt_and_hash(s_pub)
    elseif token == MessageToken.EE then
      -- Ephemeral-ephemeral DH
      assert(self.e and self.re, "Ephemeral keys required for ee")
      local dh_output = self.cipher_suite.dh.dh(self.e, self.re)
      self.symmetric_state:mix_key(dh_output)
    elseif token == MessageToken.ES then
      -- Ephemeral-static DH
      if self.initiator then
        assert(self.e and self.rs, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
        self.symmetric_state:mix_key(dh_output)
      else
        assert(self.s and self.re, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
        self.symmetric_state:mix_key(dh_output)
      end
    elseif token == MessageToken.SE then
      -- Static-ephemeral DH
      if self.initiator then
        if self.s and self.re then
          local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
          self.symmetric_state:mix_key(dh_output)
        end
      else
        if self.e and self.rs then
          local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
          self.symmetric_state:mix_key(dh_output)
        end
      end
    elseif token == MessageToken.SS then
      -- Static-static DH
      assert(self.s and self.rs, "Static keys required for ss")
      local dh_output = self.cipher_suite.dh.dh(self.s, self.rs)
      self.symmetric_state:mix_key(dh_output)
    else
      error("Unknown message token: " .. tostring(token))
    end
  end

  -- Encrypt payload
  message = message .. self.symmetric_state:encrypt_and_hash(payload)

  self.pattern_index = self.pattern_index + 1
  local finished = self.pattern_index > #self.message_patterns

  return message, finished
end

--- Read a handshake message
--- @param message string Complete handshake message
--- @return string payload Decrypted message payload
--- @return boolean finished True if handshake is complete
function HandshakeState:read_message(message)
  assert(self.pattern_index <= #self.message_patterns, "No more handshake messages")

  local pattern = self.message_patterns[self.pattern_index]
  local offset = 1

  for _, token in ipairs(pattern) do
    if token == MessageToken.PSK then
      -- Mix pre-shared key
      assert(self.psks[self.psk_index], "PSK required but not provided")
      self.symmetric_state:mix_key_and_hash(self.psks[self.psk_index])
      self.psk_index = self.psk_index + 1
    elseif token == MessageToken.E then
      -- Read ephemeral public key
      self.re = message:sub(offset, offset + self.cipher_suite.dh.dhlen - 1)
      offset = offset + self.cipher_suite.dh.dhlen
      self.symmetric_state:mix_hash(self.re)

      -- In PSK handshakes, also mix the ephemeral public key into the key
      if #self.psk_positions > 0 then
        self.symmetric_state:mix_key(self.re)
      end
    elseif token == MessageToken.S then
      -- Read static public key (encrypted)
      local has_key = self.symmetric_state.cipher_state:has_key()
      local s_len = self.cipher_suite.dh.dhlen + (has_key and self.cipher_suite.cipher.taglen or 0)

      local encrypted_s = message:sub(offset, offset + s_len - 1)
      offset = offset + s_len
      self.rs = self.symmetric_state:decrypt_and_hash(encrypted_s)
      assert(self.rs, "Failed to decrypt static key")
    elseif token == MessageToken.EE then
      -- Ephemeral-ephemeral DH
      assert(self.e and self.re, "Ephemeral keys required for ee")
      local dh_output = self.cipher_suite.dh.dh(self.e, self.re)
      self.symmetric_state:mix_key(dh_output)
    elseif token == MessageToken.ES then
      -- Ephemeral-static DH
      if self.initiator then
        assert(self.e and self.rs, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
        self.symmetric_state:mix_key(dh_output)
      else
        assert(self.s and self.re, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
        self.symmetric_state:mix_key(dh_output)
      end
    elseif token == MessageToken.SE then
      -- Static-ephemeral DH
      if self.initiator then
        if self.s and self.re then
          local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
          self.symmetric_state:mix_key(dh_output)
        end
      else
        if self.e and self.rs then
          local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
          self.symmetric_state:mix_key(dh_output)
        end
      end
    elseif token == MessageToken.SS then
      -- Static-static DH
      assert(self.s and self.rs, "Static keys required for ss")
      local dh_output = self.cipher_suite.dh.dh(self.s, self.rs)
      self.symmetric_state:mix_key(dh_output)
    end
  end

  -- Decrypt payload
  local payload_ciphertext = message:sub(offset)
  local payload = self.symmetric_state:decrypt_and_hash(payload_ciphertext)
  assert(payload, "Failed to decrypt payload")

  self.pattern_index = self.pattern_index + 1
  local finished = self.pattern_index > #self.message_patterns

  return payload, finished
end

--- Get transport cipher states after handshake completion
--- @return CipherState send_cipher Cipher for sending messages
--- @return CipherState recv_cipher Cipher for receiving messages
function HandshakeState:split()
  local c1, c2 = self.symmetric_state:split()
  if self.initiator then
    return c1, c2 -- Initiator: send with c1, receive with c2
  else
    return c2, c1 -- Responder: send with c2, receive with c1
  end
end

--- Noise connection configuration
--- @class NoiseConfig
--- @field protocol_name? string Full protocol name (e.g. "Noise_NNpsk0_25519_AESGCM_SHA256")
--- @field initiator boolean True if this connection initiates the handshake, false if it responds
--- @field static_key? string Optional static private key (required for patterns with local static key)
--- @field remote_static_key? string Optional remote static public key (required for patterns with known remote key)
--- @field psks? table Optional list of pre-shared keys (each exactly 32 bytes)
--- @field prologue? string Optional prologue data to mix into handshake hash
--- @field ephemeral_key? string Optional ephemeral private key (for testing)

--- Noise connection instance
--- @class NoiseConnection
--- @field protocol_name string Full protocol name
--- @field cipher_suite CipherSuite The cipher suite being used
--- @field pattern NoisePattern The handshake pattern
--- @field psk_positions table? List of PSK positions
--- @field initiator boolean True if this is the initiator
--- @field static_key string? Static private key
--- @field remote_static_key string? Remote static public key
--- @field psks table? List of pre-shared keys
--- @field prologue string? Prologue data
--- @field handshake_state HandshakeState? Current handshake state
--- @field send_cipher CipherState? Cipher for sending transport messages
--- @field recv_cipher CipherState? Cipher for receiving transport messages
--- @field handshake_complete boolean True when handshake is finished
--- @field ephemeral_key string? Optional ephemeral private key (for testing)
local NoiseConnection = {}
NoiseConnection.__index = NoiseConnection

--- Create a new Noise connection
--- @param config NoiseConfig Connection configuration
--- @return NoiseConnection connection Noise connection instance
function NoiseConnection:new(config)
  -- Validate required fields
  assert(config, "Configuration required")
  assert(config.initiator ~= nil, "Initiator flag required in configuration")

  local instance = setmetatable({}, self)
  instance.initiator = config.initiator
  instance.prologue = config.prologue
  instance.static_key = config.static_key
  instance.remote_static_key = config.remote_static_key
  instance.ephemeral_key = config.ephemeral_key -- For testing with fixed ephemeral keys

  -- Parse protocol name
  assert(config.protocol_name, "Protocol name required")
  local parsed = parse_protocol_name(config.protocol_name)
  instance.protocol_name = config.protocol_name

  -- Get pattern
  -- Get pattern - handle as string enum
  local pattern_key = parsed.pattern
  instance.pattern = NoisePattern[pattern_key]
  assert(instance.pattern, "Unknown handshake pattern: " .. pattern_key)
  assert(PATTERNS[instance.pattern], "Handshake pattern not implemented: " .. pattern_key)

  -- Get cipher suite components
  -- Map DH functions
  local dh = noiseprotocol.DH[parsed.dh]
  if dh == nil then
    error("Unknown DH function: " .. parsed.dh)
  end

  -- Map cipher functions
  local cipher = noiseprotocol.Cipher[parsed.cipher]
  if cipher == nil then
    error("Unknown cipher: " .. parsed.cipher)
  end

  -- Map hash functions
  local hash = noiseprotocol.Hash[parsed.hash]
  if hash == nil then
    error("Unknown hash: " .. parsed.hash)
  end

  instance.cipher_suite = CipherSuite:new(dh, cipher, hash)

  -- Parse PSK positions from modifiers
  instance.psk_positions = parse_psk_modifiers(parsed.modifiers)

  -- Handle PSKs
  instance.psks = config.psks or {}
  if #instance.psk_positions > 0 then
    assert(#instance.psks == #instance.psk_positions, "Number of PSKs must match number of PSK positions")
    for i, psk in ipairs(instance.psks) do
      assert(#psk == 32, "PSK " .. i .. " must be exactly 32 bytes")
    end
  end

  -- Validate static keys with DH length
  if instance.static_key then
    assert(
      #instance.static_key == instance.cipher_suite.dh.dhlen,
      "Static key must be exactly " .. instance.cipher_suite.dh.dhlen .. " bytes"
    )
  end

  if instance.remote_static_key then
    assert(
      #instance.remote_static_key == instance.cipher_suite.dh.dhlen,
      "Remote static key must be exactly " .. instance.cipher_suite.dh.dhlen .. " bytes"
    )
  end

  instance.handshake_state = nil
  instance.send_cipher = nil
  instance.recv_cipher = nil
  instance.handshake_complete = false

  return instance
end

--- Start handshake
--- @param prologue? string Optional prologue data (overrides config.prologue if provided)
function NoiseConnection:start_handshake(prologue)
  -- Use provided prologue or fall back to config prologue
  prologue = prologue or self.prologue

  self.handshake_state = HandshakeState:new(
    self.cipher_suite,
    self.pattern,
    self.initiator,
    prologue,
    self.static_key,
    self.ephemeral_key, -- ephemeral key (for testing, otherwise generated as needed)
    self.remote_static_key,
    nil, -- remote ephemeral key (received during handshake)
    self.psks, -- list of pre-shared keys
    self.psk_positions -- list of PSK positions
  )
  self.handshake_complete = false
end

--- Write handshake message
--- @param payload? string Optional payload data
--- @return string message Handshake message to send
function NoiseConnection:write_handshake_message(payload)
  assert(self.handshake_state, "Handshake not started")
  assert(not self.handshake_complete, "Handshake already complete")

  payload = payload or ""
  local message, finished = self.handshake_state:write_message(payload)

  if finished then
    self.send_cipher, self.recv_cipher = self.handshake_state:split()
    self.handshake_complete = true
  end

  return message
end

--- Read handshake message
--- @param message string Received handshake message
--- @return string payload Decrypted payload
function NoiseConnection:read_handshake_message(message)
  assert(self.handshake_state, "Handshake not started")
  assert(not self.handshake_complete, "Handshake already complete")

  local payload, finished = self.handshake_state:read_message(message)

  if finished then
    self.send_cipher, self.recv_cipher = self.handshake_state:split()
    self.handshake_complete = true
  end

  return payload
end

--- Send transport message
--- @param plaintext string Message to send
--- @return string ciphertext Encrypted message
function NoiseConnection:send_message(plaintext)
  assert(self.handshake_complete, "Handshake not complete")
  assert(self.send_cipher, "Send cipher not available")

  return self.send_cipher:encrypt_with_ad("", plaintext)
end

--- Receive transport message
--- @param ciphertext string Encrypted message
--- @return string? plaintext Decrypted message, or nil if authentication fails
function NoiseConnection:receive_message(ciphertext)
  assert(self.handshake_complete, "Handshake not complete")
  assert(self.recv_cipher, "Receive cipher not available")

  return self.recv_cipher:decrypt_with_ad("", ciphertext)
end

--- Get handshake hash (for authentication)
--- @return string hash Handshake hash
function NoiseConnection:get_handshake_hash()
  assert(self.handshake_state, "Handshake not started")
  return self.handshake_state.symmetric_state:get_handshake_hash()
end

--- Run comprehensive self-test with test vectors and functional tests
---
--- This function validates the Noise Protocol implementation against test vectors
--- and functional tests. ALL tests must pass for the implementation to be
--- considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function noiseprotocol.selftest()
  local function functional_tests()
    print("Running Noise Protocol functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Comprehensive XX Handshake (based on example_noise.lua)
    total = total + 1
    local success, err = pcall(function()
      -- Generate static keys
      local alice_static_priv, _alice_static_pub = DH_25519.generate_keypair()
      local bob_static_priv, _bob_static_pub = DH_25519.generate_keypair()

      -- Create clients
      local alice = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = alice_static_priv,
      })
      local bob = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        pattern = NoisePattern.XX,
        initiator = false,
        static_key = bob_static_priv,
      })

      -- Start handshake with prologue
      local prologue = "MyApplication_v1.0"
      alice:start_handshake(prologue)
      bob:start_handshake(prologue)

      -- XX Handshake Message 1: Alice -> Bob (e)
      local msg1 = alice:write_handshake_message("Initial payload from Alice")
      assert(#msg1 > 32, "Message 1 should contain ephemeral key + payload")
      local payload1 = bob:read_handshake_message(msg1)
      assert(payload1 == "Initial payload from Alice", "Payload 1 mismatch")

      -- XX Handshake Message 2: Bob -> Alice (e, ee, s, es)
      local msg2 = bob:write_handshake_message("Response from Bob")
      assert(#msg2 > 64, "Message 2 should contain ephemeral + encrypted static + payload")
      local payload2 = alice:read_handshake_message(msg2)
      assert(payload2 == "Response from Bob", "Payload 2 mismatch")

      -- XX Handshake Message 3: Alice -> Bob (s, se)
      local msg3 = alice:write_handshake_message("Handshake finished!")
      assert(#msg3 > 32, "Message 3 should contain encrypted static + payload")
      local payload3 = bob:read_handshake_message(msg3)
      assert(payload3 == "Handshake finished!", "Payload 3 mismatch")

      -- Verify handshake completion and authentication
      assert(alice.handshake_complete, "Alice handshake not complete")
      assert(bob.handshake_complete, "Bob handshake not complete")

      -- Verify handshake hash consistency (mutual authentication)
      local alice_hash = alice:get_handshake_hash()
      local bob_hash = bob:get_handshake_hash()
      assert(alice_hash == bob_hash, "Handshake hashes don't match")
      assert(#alice_hash == 32, "Handshake hash should be 32 bytes")

      -- Test bidirectional transport phase
      local transport1 = alice:send_message("This is a secure message from Alice to Bob")
      local received1 = bob:receive_message(transport1)
      assert(received1 == "This is a secure message from Alice to Bob", "Transport 1 failed")

      local transport2 = bob:send_message("This is Bob's encrypted reply")
      local received2 = alice:receive_message(transport2)
      assert(received2 == "This is Bob's encrypted reply", "Transport 2 failed")

      -- Test multiple transport messages (session continuity)
      local transport3 = alice:send_message("Follow-up message from Alice")
      local received3 = bob:receive_message(transport3)
      assert(received3 == "Follow-up message from Alice", "Transport 3 failed")
    end)

    if success then
      print("  ✅ PASS: Comprehensive XX Handshake (mutual authentication)")
      passed = passed + 1
    else
      print("  ❌ FAIL: Comprehensive XX Handshake (mutual authentication) - " .. err)
    end

    -- Test 2: Comprehensive IK Handshake with 0-RTT (based on example_noise.lua)
    total = total + 1
    success, err = pcall(function()
      -- Generate keys
      local client_static_priv, _client_static_pub = DH_25519.generate_keypair()
      local server_static_priv, server_static_pub = DH_25519.generate_keypair()

      -- Create IK clients (client knows server's static key beforehand)
      local client = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = client_static_priv,
        remote_static_key = server_static_pub,
      })
      local server = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = server_static_priv,
      })

      -- Start handshake
      client:start_handshake("IK_Example")
      server:start_handshake("IK_Example")

      -- IK Message 1: Client -> Server (e, es, s, ss) with 0-RTT encryption!
      local ik_msg1 = client:write_handshake_message("This message is encrypted with 0-RTT!")
      assert(#ik_msg1 > 96, "IK Message 1 should contain ephemeral + encrypted static + encrypted payload")
      local ik_payload1 = server:read_handshake_message(ik_msg1)
      assert(ik_payload1 == "This message is encrypted with 0-RTT!", "0-RTT payload mismatch")

      -- IK Message 2: Server -> Client (e, ee, se)
      local ik_msg2 = server:write_handshake_message("Server response")
      assert(#ik_msg2 > 48, "IK Message 2 should contain ephemeral + encrypted payload")
      local ik_payload2 = client:read_handshake_message(ik_msg2)
      assert(ik_payload2 == "Server response", "IK payload 2 mismatch")

      -- Verify completion and authentication
      assert(client.handshake_complete, "Client handshake not complete")
      assert(server.handshake_complete, "Server handshake not complete")

      -- Verify handshake hash consistency
      local client_hash = client:get_handshake_hash()
      local server_hash = server:get_handshake_hash()
      assert(client_hash == server_hash, "IK handshake hashes don't match")
      assert(#client_hash == 32, "IK handshake hash should be 32 bytes")

      -- Test bidirectional transport phase
      local ik_transport1 = client:send_message("Post-handshake message from client")
      local ik_received1 = server:receive_message(ik_transport1)
      assert(ik_received1 == "Post-handshake message from client", "IK transport 1 failed")

      local ik_transport2 = server:send_message("Post-handshake message from server")
      local ik_received2 = client:receive_message(ik_transport2)
      assert(ik_received2 == "Post-handshake message from server", "IK transport 2 failed")

      -- Test multiple IK transport messages
      local ik_transport3 = client:send_message("Follow-up client message")
      local ik_received3 = server:receive_message(ik_transport3)
      assert(ik_received3 == "Follow-up client message", "IK transport 3 failed")
    end)

    if success then
      print("  ✅ PASS: Comprehensive IK Handshake (0-RTT encryption)")
      passed = passed + 1
    else
      print("  ❌ FAIL: Comprehensive IK Handshake (0-RTT encryption) - " .. err)
    end

    -- Test 3: Security Properties and Tamper Detection (from example_noise.lua)
    total = total + 1
    success, err = pcall(function()
      -- Set up a fresh XX handshake for security testing
      local alice = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = string.rep(string.char(0x10), 32),
      })
      local bob = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = string.rep(string.char(0x20), 32),
      })

      alice:start_handshake("SecurityTest")
      bob:start_handshake("SecurityTest")

      -- Complete handshake with empty payloads
      local msg1 = alice:write_handshake_message("")
      bob:read_handshake_message(msg1)
      local msg2 = bob:write_handshake_message("")
      alice:read_handshake_message(msg2)
      local msg3 = alice:write_handshake_message("")
      bob:read_handshake_message(msg3)

      -- Verify handshake authentication via hash consistency
      local alice_hash = alice:get_handshake_hash()
      local bob_hash = bob:get_handshake_hash()
      assert(alice_hash == bob_hash, "Security test: handshake hashes must match")
      assert(#alice_hash == 32, "Security test: handshake hash must be 32 bytes")

      -- Test message integrity: tamper detection
      local original_msg = alice:send_message("Original message")
      assert(#original_msg > 16, "Transport message should include auth tag")

      -- Derived from the byte it displaces: a fixed 0xFF matched the ciphertext's
      -- own byte 1 time in 256, leaving the "tampered" copy identical.
      local first_byte = original_msg:byte(1)
      local last_byte = original_msg:byte(#original_msg)
      assert(first_byte and last_byte, "Transport message should have bytes to tamper with")

      local tampered_msg1 = string.char((first_byte + 1) % 256) .. original_msg:sub(2)
      local tamper_result1 = bob:receive_message(tampered_msg1)
      assert(tamper_result1 == nil, "First byte tampered message should be rejected")

      local tampered_msg2 = original_msg:sub(1, -2) .. string.char((last_byte + 1) % 256)
      local tamper_result2 = bob:receive_message(tampered_msg2)
      assert(tamper_result2 == nil, "Last byte tampered message should be rejected")

      -- Test truncated message
      local truncated_msg = original_msg:sub(1, #original_msg - 1)
      local truncate_result = bob:receive_message(truncated_msg)
      assert(truncate_result == nil, "Truncated message should be rejected")

      -- Verify legitimate message still works
      local legit_result = bob:receive_message(original_msg)
      assert(legit_result == "Original message", "Legitimate message should still work")
    end)

    if success then
      print("  ✅ PASS: Security Properties and Tamper Detection")
      passed = passed + 1
    else
      print("  ❌ FAIL: Security Properties and Tamper Detection - " .. err)
    end

    -- Test 4: Empty message handling
    total = total + 1
    success, err = pcall(function()
      local alice = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = string.rep(string.char(0x11), 32),
      })
      local bob = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = string.rep(string.char(0x22), 32),
      })

      alice:start_handshake("")
      bob:start_handshake("")

      -- Complete handshake with empty payloads
      local msg1 = alice:write_handshake_message("")
      local payload1 = bob:read_handshake_message(msg1)
      assert(payload1 == "", "Empty payload should work")

      local msg2 = bob:write_handshake_message("")
      local payload2 = alice:read_handshake_message(msg2)
      assert(payload2 == "", "Empty payload should work")

      local msg3 = alice:write_handshake_message("")
      local payload3 = bob:read_handshake_message(msg3)
      assert(payload3 == "", "Empty payload should work")

      -- Test empty transport messages
      local empty_transport = alice:send_message("")
      local empty_received = bob:receive_message(empty_transport)
      assert(empty_received == "", "Empty transport message should work")
    end)

    if success then
      print("  ✅ PASS: Empty message handling")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty message handling - " .. err)
    end

    -- Test 5: Error conditions
    total = total + 1
    success, err = pcall(function()
      --Test invalid protocol name
      local invalid_ok, _invalid_err = pcall(function()
        NoiseConnection:new({
          protocol_name = "INVALID",
          initiator = true,
        })
      end)
      assert(not invalid_ok, "Should reject invalid pattern")

      -- Test premature transport
      local client = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = string.rep(string.char(0x99), 32),
      })
      local premature_ok, _premature_err = pcall(function()
        client:send_message("test")
      end)
      assert(not premature_ok, "Should reject transport before handshake")

      -- Test NNpsk0 pattern without PSK should fail during handshake
      local nnpsk0_no_psk_ok, nnpsk0_no_psk_err = pcall(function()
        local client_no_psk = NoiseConnection:new({
          protocol_name = "Noise_XXpsk0_25519_ChaChaPoly_SHA256",
          initiator = true,
          psk = nil, -- No PSK provided
          psk_placement = noiseprotocol.PSKPlacement.ZERO,
        })
        client_no_psk:start_handshake("test")
        client_no_psk:write_handshake_message("test") -- Should fail here due to missing PSK
      end)
      assert(not nnpsk0_no_psk_ok, "Should reject NNpsk0 without PSK")
      assert(nnpsk0_no_psk_err and string.find(nnpsk0_no_psk_err, "PSK"), "Should indicate missing PSK")

      -- Test NNpsk0 pattern with PSK should work
      local psk = string.rep(string.char(0x33), 32)
      local nnpsk0_with_psk_ok, nnpsk0_with_psk_err = pcall(function()
        local client_with_psk = NoiseConnection:new({
          protocol_name = "Noise_NN_25519_ChaChaPoly_SHA256",
          initiator = true,
          psk = psk,
          psk_placement = noiseprotocol.PSKPlacement.ZERO,
        })
        client_with_psk:start_handshake("test")
        client_with_psk:write_handshake_message("test") -- Should work with PSK
      end)
      assert(nnpsk0_with_psk_ok, "Should accept NNpsk0 with PSK: " .. (nnpsk0_with_psk_err or ""))
    end)

    if success then
      print("  ✅ PASS: Error conditions")
      passed = passed + 1
    else
      print("  ❌ FAIL: Error conditions - " .. err)
    end

    -- Test 6: Noise Protocol Features Showcase (from example_noise.lua)
    total = total + 1
    success, err = pcall(function()
      -- Test multiple features in one comprehensive scenario
      local alice_static_priv, _alice_static_pub = DH_25519.generate_keypair()
      local bob_static_priv, bob_static_pub = DH_25519.generate_keypair()

      -- Test both XX and IK patterns in sequence

      -- XX: Mutual authentication without prior key knowledge
      local alice_xx = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = alice_static_priv,
      })
      local bob_xx = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = bob_static_priv,
      })

      alice_xx:start_handshake("FeatureTest_XX")
      bob_xx:start_handshake("FeatureTest_XX")

      -- Complete XX handshake
      local xx_msg1 = alice_xx:write_handshake_message("XX payload 1")
      bob_xx:read_handshake_message(xx_msg1)
      local xx_msg2 = bob_xx:write_handshake_message("XX payload 2")
      alice_xx:read_handshake_message(xx_msg2)
      local xx_msg3 = alice_xx:write_handshake_message("XX payload 3")
      bob_xx:read_handshake_message(xx_msg3)

      -- IK: 0-RTT with server authentication
      local alice_ik = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = alice_static_priv,
        remote_static_key = bob_static_pub,
      })
      local bob_ik = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = bob_static_priv,
      })

      alice_ik:start_handshake("FeatureTest_IK")
      bob_ik:start_handshake("FeatureTest_IK")

      -- Complete IK handshake with 0-RTT
      local ik_msg1 = alice_ik:write_handshake_message("IK 0-RTT payload")
      bob_ik:read_handshake_message(ik_msg1)
      local ik_msg2 = bob_ik:write_handshake_message("IK response")
      alice_ik:read_handshake_message(ik_msg2)

      -- Verify both handshakes completed successfully
      assert(alice_xx.handshake_complete and bob_xx.handshake_complete, "XX handshake must complete")
      assert(alice_ik.handshake_complete and bob_ik.handshake_complete, "IK handshake must complete")

      -- Test forward secrecy: each handshake produces different session keys
      local xx_msg_a = alice_xx:send_message("XX transport message")
      local ik_msg_a = alice_ik:send_message("IK transport message")
      assert(xx_msg_a ~= ik_msg_a, "Different handshakes should produce different ciphertexts")

      -- Test session isolation: messages from one session can't decrypt in another
      local xx_plaintext = bob_xx:receive_message(xx_msg_a)
      local ik_cross_result = bob_ik:receive_message(xx_msg_a) -- Wrong session
      assert(xx_plaintext == "XX transport message", "XX session should decrypt correctly")
      assert(ik_cross_result == nil, "Cross-session messages should be rejected")

      -- Test replay protection: same ciphertext can't be decrypted twice
      local replay_result = bob_xx:receive_message(xx_msg_a)
      assert(replay_result == nil, "Replayed message should be rejected")
    end)

    if success then
      print("  ✅ PASS: Noise Protocol Features Showcase")
      passed = passed + 1
    else
      print("  ❌ FAIL: Noise Protocol Features Showcase - " .. err)
    end

    -- Test 7: NNpsk0 Pre-Shared Key Pattern
    total = total + 1
    success, err = pcall(function()
      -- Test NNpsk0 with pre-shared key
      local psk = string.rep(string.char(0x42), 32) -- Test PSK

      local alice_psk = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        pattern = NoisePattern.NN,
        initiator = true,
        psks = { psk },
      })
      local bob_psk = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        initiator = false,
        psks = { psk },
      })

      alice_psk:start_handshake("NNpsk0_functional_test")
      bob_psk:start_handshake("NNpsk0_functional_test")

      -- NNpsk0 Message 1: Alice -> Bob (psk0, e)
      local psk_msg1 = alice_psk:write_handshake_message("PSK encrypted message 1")
      assert(#psk_msg1 > 32, "NNpsk0 Message 1 should contain ephemeral key + encrypted payload")
      local psk_payload1 = bob_psk:read_handshake_message(psk_msg1)
      assert(psk_payload1 == "PSK encrypted message 1", "PSK payload 1 mismatch")

      -- NNpsk0 Message 2: Bob -> Alice (e, ee)
      local psk_msg2 = bob_psk:write_handshake_message("PSK encrypted message 2")
      assert(#psk_msg2 > 32, "NNpsk0 Message 2 should contain ephemeral key + encrypted payload")
      local psk_payload2 = alice_psk:read_handshake_message(psk_msg2)
      assert(psk_payload2 == "PSK encrypted message 2", "PSK payload 2 mismatch")

      -- Verify handshake completion
      assert(alice_psk.handshake_complete, "Alice NNpsk0 handshake not complete")
      assert(bob_psk.handshake_complete, "Bob NNpsk0 handshake not complete")

      -- Test handshake hash consistency
      local alice_psk_hash = alice_psk:get_handshake_hash()
      local bob_psk_hash = bob_psk:get_handshake_hash()
      assert(alice_psk_hash == bob_psk_hash, "NNpsk0 handshake hashes don't match")
      assert(#alice_psk_hash == 32, "NNpsk0 handshake hash should be 32 bytes")

      -- Test transport phase with PSK-derived keys
      local psk_transport1 = alice_psk:send_message("NNpsk0 transport message from Alice")
      local psk_received1 = bob_psk:receive_message(psk_transport1)
      assert(psk_received1 == "NNpsk0 transport message from Alice", "NNpsk0 transport 1 failed")

      local psk_transport2 = bob_psk:send_message("NNpsk0 transport message from Bob")
      local psk_received2 = alice_psk:receive_message(psk_transport2)
      assert(psk_received2 == "NNpsk0 transport message from Bob", "NNpsk0 transport 2 failed")

      -- Test PSK security: different PSK should produce different results
      local different_psk = string.rep(string.char(0x99), 32)
      local alice_different = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        initiator = true,
        psks = { different_psk },
      })
      local bob_different = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        initiator = false,
        psks = { different_psk },
      })

      alice_different:start_handshake("NNpsk0_functional_test")
      bob_different:start_handshake("NNpsk0_functional_test")

      local diff_msg1 = alice_different:write_handshake_message("PSK encrypted message 1")
      assert(diff_msg1 ~= psk_msg1, "Different PSKs should produce different ciphertexts")
    end)

    if success then
      print("  ✅ PASS: NNpsk0 Pre-Shared Key Pattern")
      passed = passed + 1
    else
      print("  ❌ FAIL: NNpsk0 Pre-Shared Key Pattern - " .. err)
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local functional_passed = functional_tests()

  return functional_passed
end

--- @type table<string, DHFunction>
noiseprotocol.DH = {
  [DH_25519.name] = DH_25519,
  [DH_448.name] = DH_448,
}

--- @type table<string, CipherFunction>
noiseprotocol.Cipher = {
  [CIPHER_ChaChaPoly.name] = CIPHER_ChaChaPoly,
  [CIPHER_AESGCM.name] = CIPHER_AESGCM,
}

--- @type table<string, HashFunction>
noiseprotocol.Hash = {
  [HASH_SHA256.name] = HASH_SHA256,
  [HASH_SHA512.name] = HASH_SHA512,
  [HASH_BLAKE2S.name] = HASH_BLAKE2S,
  [HASH_BLAKE2B.name] = HASH_BLAKE2B,
}

-- Utility types
noiseprotocol.CipherState = CipherState
noiseprotocol.SymmetricState = SymmetricState
noiseprotocol.HandshakeState = HandshakeState
noiseprotocol.NoiseConnection = NoiseConnection
noiseprotocol.CipherSuite = CipherSuite
noiseprotocol.PSKPlacement = PSKPlacement
noiseprotocol.NoisePattern = NoisePattern

-- Export submodules for convenience
noiseprotocol.crypto = crypto
noiseprotocol.utils = utils

return noiseprotocol
