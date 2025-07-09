--- @module "lib.bit16"
--- 16-bit unsigned integer operations

--- @class bit16
local bit16 = {}

--- Mask a number to a 16-bit unsigned integer
--- @param n integer The number to mask
--- @return integer n 16-bit unsigned integer
function bit16.mask(n)
  return math.floor(n % 0x10000)
end

--- Convert 16-bit unsigned integer to 2 bytes (big-endian)
--- @param n integer 16-bit unsigned integer
--- @return string b 2-byte string in big-endian order
function bit16.u16_to_be_bytes(n)
  n = bit16.mask(n)
  return string.char(math.floor(n / 256), math.floor(n % 256))
end

--- Convert 2 bytes (big-endian) to a 16-bit unsigned integer
--- @param bytes string 2-byte string in big-endian order
--- @return integer n 16-bit unsigned integer
function bit16.be_bytes_to_u16(bytes)
  assert(#bytes == 2, "Input must be exactly 2 bytes")
  local b1, b2 = string.byte(bytes, 1, 2)
  return b1 * 256 + b2
end

--- Run comprehensive self-test with test vectors
--- @return boolean result True if all tests pass, false otherwise
function bit16.selftest()
  print("Running 16-bit operations test vectors...")
  local passed = 0
  local total = 0

  --- @class B16TestVector
  --- @field name string Test name
  --- @field fn fun(...): integer Function to test
  --- @field inputs any[] Input values
  --- @field expected integer|string Expected result

  --- @type B16TestVector[]
  local test_vectors = {
    -- mask tests
    { name = "mask(0)", fn = bit16.mask, inputs = { 0 }, expected = 0 },
    { name = "mask(255)", fn = bit16.mask, inputs = { 255 }, expected = 255 },
    { name = "mask(256)", fn = bit16.mask, inputs = { 256 }, expected = 256 },
    { name = "mask(65535)", fn = bit16.mask, inputs = { 65535 }, expected = 65535 },
    { name = "mask(65536)", fn = bit16.mask, inputs = { 65536 }, expected = 0 },
    { name = "mask(65537)", fn = bit16.mask, inputs = { 65537 }, expected = 1 },
    { name = "mask(131071)", fn = bit16.mask, inputs = { 131071 }, expected = 65535 },
    { name = "mask(-1)", fn = bit16.mask, inputs = { -1 }, expected = 65535 },
    { name = "mask(-256)", fn = bit16.mask, inputs = { -256 }, expected = 65280 },
    { name = "u16_to_be_bytes(0)", fn = bit16.u16_to_be_bytes, inputs = { 0 }, expected = "\x00\x00" },
    { name = "u16_to_be_bytes(1)", fn = bit16.u16_to_be_bytes, inputs = { 1 }, expected = "\x00\x01" },
    { name = "u16_to_be_bytes(255)", fn = bit16.u16_to_be_bytes, inputs = { 255 }, expected = "\x00\xFF" },
    { name = "u16_to_be_bytes(256)", fn = bit16.u16_to_be_bytes, inputs = { 256 }, expected = "\x01\x00" },
    { name = "u16_to_be_bytes(258)", fn = bit16.u16_to_be_bytes, inputs = { 258 }, expected = "\x01\x02" },
    { name = "u16_to_be_bytes(32768)", fn = bit16.u16_to_be_bytes, inputs = { 32768 }, expected = "\x80\x00" },
    { name = "u16_to_be_bytes(65535)", fn = bit16.u16_to_be_bytes, inputs = { 65535 }, expected = "\xFF\xFF" },
    { name = "u16_to_be_bytes(65536)", fn = bit16.u16_to_be_bytes, inputs = { 65536 }, expected = "\x00\x00" }, -- wraps around
    { name = "u16_to_be_bytes(65537)", fn = bit16.u16_to_be_bytes, inputs = { 65537 }, expected = "\x00\x01" }, -- wraps around
    { name = "be_bytes_to_u16('\\x00\\x00')", fn = bit16.be_bytes_to_u16, inputs = { "\x00\x00" }, expected = 0 },
    { name = "be_bytes_to_u16('\\x00\\x01')", fn = bit16.be_bytes_to_u16, inputs = { "\x00\x01" }, expected = 1 },
    { name = "be_bytes_to_u16('\\x00\\xFF')", fn = bit16.be_bytes_to_u16, inputs = { "\x00\xFF" }, expected = 255 },
    { name = "be_bytes_to_u16('\\x01\\x00')", fn = bit16.be_bytes_to_u16, inputs = { "\x01\x00" }, expected = 256 },
    { name = "be_bytes_to_u16('\\x01\\x02')", fn = bit16.be_bytes_to_u16, inputs = { "\x01\x02" }, expected = 258 },
    { name = "be_bytes_to_u16('\\x80\\x00')", fn = bit16.be_bytes_to_u16, inputs = { "\x80\x00" }, expected = 32768 },
    { name = "be_bytes_to_u16('\\xFF\\xFF')", fn = bit16.be_bytes_to_u16, inputs = { "\xFF\xFF" }, expected = 65535 },
  }

  ---@diagnostic disable-next-line: access-invisible
  local unpack_fn = unpack or table.unpack

  for _, test in ipairs(test_vectors) do
    total = total + 1
    local result = test.fn(unpack_fn(test.inputs))
    if result == test.expected then
      print("  ✅ PASS: " .. test.name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. test.name)
      print(string.format("    Expected: 0x%04X", test.expected))
      print(string.format("    Got:      0x%04X", result))
    end
  end

  print(string.format("\n16-bit operations result: %d/%d tests passed\n", passed, total))
  return passed == total
end

return bit16
