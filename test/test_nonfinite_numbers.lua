-- Tests for how a non-finite number travels through the shared libraries:
-- `tofinite` coercion in lib/utils.lua, the SerializeSafe sentinels that carry
-- NaN and infinity across a JSON hop, and NaN-aware change detection in
-- `Values:update`.
--
-- Regression test for FL-15.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_nonfinite_numbers.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local NAN = 0 / 0

-- ── tofinite ─────────────────────────────────────────────────────────────────

T.section("tofinite keeps finite numbers")
T.eq("an integer", tofinite(3), 3)
T.eq("a fraction", tofinite(-2.5), -2.5)
T.eq("zero", tofinite(0), 0)
T.eq("a numeric string", tofinite("12.5"), 12.5)

T.section("tofinite rejects everything else")
T.eq("NaN", tofinite(NAN), nil)
T.eq("positive infinity", tofinite(math.huge), nil)
T.eq("negative infinity", tofinite(-math.huge), nil)
T.eq("a non-numeric string", tofinite("warm"), nil)
T.eq("nil", tofinite(nil), nil)

-- The reason the helper exists: this is what the idiom it replaces does.
T.check("tonumber alone lets a NaN through", tonumber(NAN) ~= tonumber(NAN))
T.eq("so the usual `or` fallback fires only with tofinite", tofinite(NAN) or 0, 0)

-- ── tointeger ────────────────────────────────────────────────────────────────

T.section("tointeger still rounds")
T.eq("rounds up at the half", tointeger(2.5), 3)
T.eq("rounds a negative away from zero", tointeger(-2.5), -3)
T.eq("parses a string", tointeger("7"), 7)
T.eq("rejects a non-numeric string", tointeger("warm"), nil)

T.section("tointeger rejects non-finite input")
T.eq("NaN is not an integer", tointeger(NAN), nil)
T.eq("infinity is not an integer", tointeger(math.huge), nil)
T.eq("negative infinity is not an integer", tointeger(-math.huge), nil)

-- assertInt only checks for nil, so before the above it would have handed a
-- caller a NaN while claiming to have narrowed the type.
T.raises("assertInt rejects a NaN rather than narrowing it", function()
  assertInt(NAN)
end, "expected integer")

-- ── SerializeSafe / DeserializeSafe ──────────────────────────────────────────

T.section("a non-finite number survives a serialize round trip")
local roundTrippedNan = DeserializeSafe(SerializeSafe(NAN))
T.check("NaN comes back as NaN, not nil", roundTrippedNan ~= roundTrippedNan, roundTrippedNan)
T.eq("positive infinity comes back", DeserializeSafe(SerializeSafe(math.huge)), math.huge)
T.eq("negative infinity comes back", DeserializeSafe(SerializeSafe(-math.huge)), -math.huge)

local nested = DeserializeSafe(SerializeSafe({ temperature = NAN, setpoint = 21.5, ceiling = math.huge }))
T.check("a NaN nested in a table survives", nested.temperature ~= nested.temperature, nested.temperature)
T.eq("its finite neighbour is untouched", nested.setpoint, 21.5)
T.eq("an infinity nested in a table survives", nested.ceiling, math.huge)

-- A NaN and an absent key are the two cases the sentinel exists to separate.
local absent = DeserializeSafe(SerializeSafe({ setpoint = 21.5 }))
T.eq("a key that was never set is still absent", absent.temperature, nil)

T.section("the sentinel strings do not collide with real strings")
for _, literal in ipairs({ "__nan__", "__inf__", "__-inf__", "__null__" }) do
  local got = DeserializeSafe(SerializeSafe(literal))
  T.eq(string.format("%q round trips as a string", literal), got, literal)
end

-- ── Values:update ────────────────────────────────────────────────────────────

T.section("Values:update does not rewrite storage for an unchanged NaN")

-- The module is a singleton instance, not the class.
local values = require("lib.values")

local writes = 0
local realPersistSetValue = C4.PersistSetValue
function C4:PersistSetValue(key, value, encrypted)
  writes = writes + 1
  return realPersistSetValue(self, key, value, encrypted)
end

T.check("the first NaN reading is a change", values:update("Temperature", NAN, "FLOAT") == true)

local writesAfterFirst = writes
local changedAgain = values:update("Temperature", NAN, "FLOAT")
T.check("republishing the same NaN is not a change", changedAgain == false)
T.eq("and it writes nothing to persistent storage", writes - writesAfterFirst, 0)

-- The guard must not swallow a genuine transition in either direction.
T.check("NaN to a real reading is a change", values:update("Temperature", 21.5, "FLOAT") == true)
T.check("the same real reading is not", values:update("Temperature", 21.5, "FLOAT") == false)
T.check("a real reading back to NaN is a change", values:update("Temperature", NAN, "FLOAT") == true)

C4.PersistSetValue = realPersistSetValue

T.finish()
