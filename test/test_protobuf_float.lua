--- NaN and infinity must decode as such rather than as a large finite number:
--- ESPHome sends NaN for any float the device has not reported.
local pb = require("protobuf")

local passed, failed = 0, 0
local function check(cond, name)
  if cond then
    passed = passed + 1
    print("  ok   - " .. name)
  else
    failed = failed + 1
    print("  FAIL - " .. name)
  end
end

local function decodeFloat(...)
  return (pb.decode_float(string.char(...), 1))
end

local function decodeDouble(...)
  return (pb.decode_double(string.char(...), 1))
end

print("[1] float32 (little-endian)")
check(decodeFloat(0x00, 0x00, 0xC0, 0x3F) == 1.5, "1.5 still decodes")
check(decodeFloat(0x00, 0x00, 0x00, 0x00) == 0, "zero still decodes")
check(decodeFloat(0xFF, 0xFF, 0x7F, 0x7F) < math.huge, "the largest finite float is still finite")
check(decodeFloat(0x00, 0x00, 0x80, 0x7F) == math.huge, "positive infinity")
check(decodeFloat(0x00, 0x00, 0x80, 0xFF) == -math.huge, "negative infinity")
local quiet = decodeFloat(0x00, 0x00, 0xC0, 0x7F)
check(quiet ~= quiet, "a quiet NaN decodes as NaN, not 5.1e38")
local signalling = decodeFloat(0x01, 0x00, 0x80, 0x7F)
check(signalling ~= signalling, "a signalling NaN pattern decodes as NaN")
local _, nextPos = pb.decode_float(string.char(0x00, 0x00, 0xC0, 0x7F), 1)
check(nextPos == 5, "the buffer position still advances past a NaN")

print("[2] float64 (little-endian)")
check(decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F) == 1.5, "1.5 still decodes")
check(
  decodeDouble(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF, 0x7F) < math.huge,
  "the largest finite double is still finite"
)
check(decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x7F) == math.huge, "positive infinity")
check(decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xFF) == -math.huge, "negative infinity")
local dquiet = decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x7F)
check(dquiet ~= dquiet, "a quiet NaN decodes as NaN")

print("[3] round trip")
check(pb.decode_float(pb.encode_float(22.5), 1) == 22.5, "an ordinary float survives encode then decode")

print("")
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
