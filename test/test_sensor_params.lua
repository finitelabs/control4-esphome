-- Tests for the temperature/humidity binding payload helpers in src/lib/utils.lua.
-- The key sets pinned here are an interop contract with drivers we do not own.
-- Regression test for DRV-121.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sensor_params.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

--------------------------------------------------------------------------------
T.section("SensorValueParams emits every key a strict consumer reads")
--------------------------------------------------------------------------------
do
  local before = os.time()
  local params = SensorValueParams(21.5, "CELSIUS")
  local after = os.time()

  T.eq("VALUE stays in the reported scale", params.VALUE, 21.5)
  T.eq("SCALE is passed through", params.SCALE, "CELSIUS")
  T.eq("CELSIUS is the Celsius reading", params.CELSIUS, 21.5)
  T.eq("FAHRENHEIT is converted", params.FAHRENHEIT, 70.7)
  T.check(
    "TIMESTAMP is epoch seconds from os.time()",
    type(params.TIMESTAMP) == "number" and params.TIMESTAMP >= before and params.TIMESTAMP <= after,
    params.TIMESTAMP
  )
end

--------------------------------------------------------------------------------
T.section("A Fahrenheit-native provider keeps its VALUE and gains Celsius")
--------------------------------------------------------------------------------
do
  -- An ESPHome sensor converted to Fahrenheit in its config, or a Device
  -- Programmer on a project set to Fahrenheit, measures in F. Rewriting VALUE
  -- to Celsius would change what every existing consumer reads.
  local params = SensorValueParams(70.7, "FAHRENHEIT")
  T.eq("VALUE is left in Fahrenheit", params.VALUE, 70.7)
  T.eq("SCALE still says Fahrenheit", params.SCALE, "FAHRENHEIT")
  T.eq("CELSIUS is converted", params.CELSIUS, 21.5)
  T.eq("FAHRENHEIT round-trips back to VALUE", params.FAHRENHEIT, 70.7)
end

do
  local params = SensorValueParams(294.65, "KELVIN")
  T.eq("Kelvin converts to Celsius", params.CELSIUS, 21.5)
  T.eq("and on to Fahrenheit", params.FAHRENHEIT, 70.7)
end

--------------------------------------------------------------------------------
T.section("A non-temperature scale gets TIMESTAMP but no temperature keys")
--------------------------------------------------------------------------------
do
  local params = SensorValueParams(48, "PERCENT")
  T.eq("VALUE is the percentage", params.VALUE, 48)
  T.eq("SCALE is PERCENT", params.SCALE, "PERCENT")
  T.eq("no CELSIUS on a humidity reading", params.CELSIUS, nil)
  T.eq("no FAHRENHEIT on a humidity reading", params.FAHRENHEIT, nil)
  T.check("humidity still carries TIMESTAMP", type(params.TIMESTAMP) == "number", params.TIMESTAMP)
end

do
  -- esphome_bthome types its config scale as optional, so a sensor class
  -- without one reaches here with nil.
  local params = SensorValueParams(48, nil)
  T.eq("a nil scale is passed through", params.SCALE, nil)
  T.eq("and yields no CELSIUS", params.CELSIUS, nil)
  T.check("but still carries TIMESTAMP", type(params.TIMESTAMP) == "number", params.TIMESTAMP)
end

--------------------------------------------------------------------------------
T.section("CelsiusFromParams reads each provider convention")
--------------------------------------------------------------------------------
do
  T.eq("CELSIUS is preferred", CelsiusFromParams({ CELSIUS = 21.5 }, "CELSIUS"), 21.5)
  T.eq(
    "CELSIUS wins over a disagreeing FAHRENHEIT",
    CelsiusFromParams({ CELSIUS = 21.5, FAHRENHEIT = 200 }, "CELSIUS"),
    21.5
  )
  T.eq("FAHRENHEIT is converted", CelsiusFromParams({ FAHRENHEIT = 70.7 }, "CELSIUS"), 21.5)
  T.eq("VALUE is read per SCALE", CelsiusFromParams({ VALUE = 70.7, SCALE = "FAHRENHEIT" }, "CELSIUS"), 21.5)
  T.eq("a Kelvin SCALE converts", CelsiusFromParams({ VALUE = 294.65, SCALE = "KELVIN" }, "CELSIUS"), 21.5)
end

do
  -- The thermostat proxy sends letters; sensor bindings send whole words; and
  -- esphome_climate has been reading a lowercase "c" since it was written.
  T.eq("letter C", CelsiusFromParams({ VALUE = 21.5, SCALE = "C" }, "F"), 21.5)
  T.eq("lowercase c", CelsiusFromParams({ VALUE = 21.5, SCALE = "c" }, "F"), 21.5)
  T.eq("letter F", CelsiusFromParams({ VALUE = 70.7, SCALE = "F" }, "C"), 21.5)
  T.eq("mixed case word", CelsiusFromParams({ VALUE = 70.7, SCALE = "Fahrenheit" }, "C"), 21.5)
end

--------------------------------------------------------------------------------
T.section("A bare VALUE is read in the caller's default scale")
--------------------------------------------------------------------------------
do
  -- The two call sites disagree on purpose: a TEMPERATURE_VALUE sensor binding
  -- reports Celsius, while the thermostat proxy's SET_SETPOINT_* sends
  -- Fahrenheit. A single shared default would silently mis-convert one of them.
  T.eq("a sensor consumer reads Celsius", CelsiusFromParams({ VALUE = 21.5 }, "CELSIUS"), 21.5)
  T.eq("a setpoint handler reads Fahrenheit", CelsiusFromParams({ VALUE = 70.7 }, "F"), 21.5)
end

--------------------------------------------------------------------------------
T.section("Params arriving as strings still parse")
--------------------------------------------------------------------------------
do
  -- SendToProxy params reach the far side as strings.
  T.eq("string CELSIUS", CelsiusFromParams({ CELSIUS = "21.5" }, "CELSIUS"), 21.5)
  T.eq("string FAHRENHEIT", CelsiusFromParams({ FAHRENHEIT = "70.7" }, "CELSIUS"), 21.5)
  T.eq("string VALUE with SCALE", CelsiusFromParams({ VALUE = "70.7", SCALE = "FAHRENHEIT" }, "CELSIUS"), 21.5)
  T.eq("a comma decimal separator", CelsiusFromParams({ CELSIUS = "21,5" }, "CELSIUS"), 21.5)
end

--------------------------------------------------------------------------------
T.section("Nothing readable yields nil rather than a wrong number")
--------------------------------------------------------------------------------
do
  T.eq("no params at all", CelsiusFromParams(nil, "CELSIUS"), nil)
  T.eq("an empty table", CelsiusFromParams({}, "CELSIUS"), nil)
  T.eq("only a SCALE", CelsiusFromParams({ SCALE = "CELSIUS" }, "CELSIUS"), nil)
  T.eq("a non-numeric VALUE", CelsiusFromParams({ VALUE = "warm" }, "CELSIUS"), nil)
  T.eq("a VALUE in a scale that is not a temperature", CelsiusFromParams({ VALUE = 48, SCALE = "PERCENT" }, "C"), nil)
end

--------------------------------------------------------------------------------
T.section("Output and input are inverses, which is the interop property")
--------------------------------------------------------------------------------
do
  -- What one of our drivers emits, another of our drivers must read back
  -- unchanged, whichever scale the provider measured in.
  local measured = { CELSIUS = 21.5, FAHRENHEIT = 70.7, KELVIN = 294.65 }
  for scale, value in pairs(measured) do
    local emitted = SensorValueParams(value, scale)
    T.eq(scale .. " round-trips to the original Celsius", CelsiusFromParams(emitted, "CELSIUS"), 21.5)
  end
end

do
  -- The YoLink shape: the two temperature keys, no VALUE and no TIMESTAMP.
  T.eq("a YoLink payload is ingestible", CelsiusFromParams({ CELSIUS = "21.5", FAHRENHEIT = "70.7" }, "CELSIUS"), 21.5)
end

T.finish()
