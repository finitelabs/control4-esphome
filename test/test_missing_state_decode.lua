-- ESPHome 2026.9 and later set missing_state on a switch, climate or water heater state while the entity has no
-- state yet, and the ESPHome driver drops an update that carries it. The flag must decode from the bytes the
-- device writes.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_missing_state_decode.lua

require("c4_shim")
local T = require("testlib")

local pb = require("protobuf")
local ESPHomeProtoSchema = require("esphome.proto_schema")

-- The key, field 1 as a fixed32: 0x12345678, little-endian.
local KEY = string.char(0x0D, 0x78, 0x56, 0x34, 0x12)

-- Each state as the device writes it with no state yet: the key, then missing_state as a varint true at the
-- message's own field number. A false state or zero reading is left out, as protobuf leaves out defaults.
for _, case in ipairs({
  { "SwitchStateResponse", KEY .. string.char(4 * 8, 1) },
  { "ClimateStateResponse", KEY .. string.char(0x88, 0x01, 1) }, -- field 17
  { "WaterHeaterStateResponse", KEY .. string.char(9 * 8, 1) },
}) do
  local decoded = pb.decode(ESPHomeProtoSchema, ESPHomeProtoSchema.Message[case[1]], case[2])
  T.eq(case[1] .. " keeps its key", decoded.key, 0x12345678)
  T.eq(case[1] .. " decodes missing_state", decoded.missing_state, true)
end

T.finish()
