--- NaN and infinity must decode as such rather than as a large finite number:
--- ESPHome sends NaN for any float the device has not reported.
local T = require("testlib")
local pb = require("protobuf")

local function decodeFloat(...)
  return (pb.decode_float(string.char(...), 1))
end

local function decodeDouble(...)
  return (pb.decode_double(string.char(...), 1))
end

T.section("float32 (little-endian)")
T.check("1.5 still decodes", decodeFloat(0x00, 0x00, 0xC0, 0x3F) == 1.5)
T.check("zero still decodes", decodeFloat(0x00, 0x00, 0x00, 0x00) == 0)
T.check("the largest finite float is still finite", decodeFloat(0xFF, 0xFF, 0x7F, 0x7F) < math.huge)
T.check("positive infinity", decodeFloat(0x00, 0x00, 0x80, 0x7F) == math.huge)
T.check("negative infinity", decodeFloat(0x00, 0x00, 0x80, 0xFF) == -math.huge)
local quiet = decodeFloat(0x00, 0x00, 0xC0, 0x7F)
T.check("a quiet NaN decodes as NaN, not 5.1e38", quiet ~= quiet)
local signalling = decodeFloat(0x01, 0x00, 0x80, 0x7F)
T.check("a signalling NaN pattern decodes as NaN", signalling ~= signalling)
local _, nextPos = pb.decode_float(string.char(0x00, 0x00, 0xC0, 0x7F), 1)
T.check("the buffer position still advances past a NaN", nextPos == 5)

T.section("float64 (little-endian)")
T.check("1.5 still decodes", decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F) == 1.5)
T.check(
  "the largest finite double is still finite",
  decodeDouble(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF, 0x7F) < math.huge
)
T.check("positive infinity", decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x7F) == math.huge)
T.check("negative infinity", decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xFF) == -math.huge)
local dquiet = decodeDouble(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x7F)
T.check("a quiet NaN decodes as NaN", dquiet ~= dquiet)

T.section("round trip")
T.check("an ordinary float survives encode then decode", pb.decode_float(pb.encode_float(22.5), 1) == 22.5)

T.finish()
