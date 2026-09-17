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
  -- Each caller names the scale its own bare VALUE arrives in. A thermostat
  -- proxy setpoint carries CELSIUS, FAHRENHEIT and KELVIN together, so it
  -- returns before the default is read.
  T.eq("a sensor consumer reads Celsius", CelsiusFromParams({ VALUE = 21.5 }, "CELSIUS"), 21.5)
  T.eq("a setpoint handler reads Fahrenheit", CelsiusFromParams({ VALUE = 70.7 }, "F"), 21.5)
end

do
  -- Select returns the empty string for SCALE = "" rather than nil, and "" is
  -- truthy, so an absent-SCALE fallback has to treat it as absent explicitly.
  T.eq("an empty SCALE falls back like an absent one", CelsiusFromParams({ VALUE = 21.5, SCALE = "" }, "CELSIUS"), 21.5)
  T.eq("an empty SCALE on a Fahrenheit default", CelsiusFromParams({ VALUE = 70.7, SCALE = "" }, "F"), 21.5)
  T.eq("an empty SCALE still yields nil with no VALUE", CelsiusFromParams({ SCALE = "" }, "CELSIUS"), nil)
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

--------------------------------------------------------------------------------
T.section("A non-finite reading never reaches a consumer")
--------------------------------------------------------------------------------

-- Needs LuaJIT: stock Lua 5.4+ returns nil from tonumber("nan").
local NAN = 0 / 0
local INF = math.huge

local function isNonFinite(value)
  return type(value) == "number" and (value ~= value or value == INF or value == -INF)
end

-- Each case runs twice: as shipped, then reverted. `leaks` marks what the revert must break.
local CASES = {}

local function drops(label, thunk)
  CASES[#CASES + 1] = { label = label, thunk = thunk, leaks = true, dropped = true }
end

local function prefers(label, thunk, want)
  CASES[#CASES + 1] = { label = label, thunk = thunk, want = want, leaks = true }
end

local function keeps(label, thunk, want)
  CASES[#CASES + 1] = { label = label, thunk = thunk, want = want, leaks = false }
end

for _, text in ipairs({ "nan", "inf", "-inf", "1e999" }) do
  drops(string.format("a CELSIUS of %q", text), function()
    return CelsiusFromParams({ CELSIUS = text }, "CELSIUS")
  end)
  drops(string.format("a FAHRENHEIT of %q", text), function()
    return CelsiusFromParams({ FAHRENHEIT = text }, "CELSIUS")
  end)
  drops(string.format("a KELVIN VALUE of %q", text), function()
    return CelsiusFromParams({ VALUE = text, SCALE = "KELVIN" }, "CELSIUS")
  end)
  drops(string.format("a VALUE of %q in the default scale", text), function()
    return CelsiusFromParams({ VALUE = text }, "F")
  end)
end

for _, spelling in ipairs({ { "a NaN", NAN }, { "an infinity", INF }, { "a negative infinity", -INF } }) do
  local name, number = spelling[1], spelling[2]
  drops("a CELSIUS that is " .. name, function()
    return CelsiusFromParams({ CELSIUS = number }, "CELSIUS")
  end)
  drops("a FAHRENHEIT that is " .. name, function()
    return CelsiusFromParams({ FAHRENHEIT = number }, "CELSIUS")
  end)
  drops("a KELVIN VALUE that is " .. name, function()
    return CelsiusFromParams({ VALUE = number, SCALE = "KELVIN" }, "CELSIUS")
  end)
  drops("a Celsius VALUE that is " .. name, function()
    return CelsiusFromParams({ VALUE = number, SCALE = "C" }, "F")
  end)
  drops("ToCelsius of " .. name .. " in Celsius", function()
    return ToCelsius(number, "CELSIUS")
  end)
  drops("ToCelsius of " .. name .. " in Fahrenheit", function()
    return ToCelsius(number, "FAHRENHEIT")
  end)
  drops("ToCelsius of " .. name .. " in Kelvin", function()
    return ToCelsius(number, "KELVIN")
  end)
end

-- A finite input can still overflow in the conversion.
drops("a Fahrenheit reading at the top of the double range", function()
  return CelsiusFromParams({ FAHRENHEIT = 1e308 }, "CELSIUS")
end)
drops("a Kelvin reading at the top of the double range", function()
  return CelsiusFromParams({ VALUE = 1e308, SCALE = "KELVIN" }, "CELSIUS")
end)

for _, spelling in ipairs({ { "a NaN", NAN }, { "an infinity", INF }, { "a negative infinity", -INF } }) do
  local name, number = spelling[1], spelling[2]
  for _, key in ipairs({ "VALUE", "CELSIUS", "FAHRENHEIT" }) do
    drops(string.format("publishing %s in Celsius: %s", name, key), function()
      return SensorValueParams(number, "CELSIUS")[key]
    end)
  end
  drops(string.format("publishing %s as a percentage: VALUE", name), function()
    return SensorValueParams(number, "PERCENT").VALUE
  end)
end

drops("what the producer drops, the reader cannot resurrect", function()
  return CelsiusFromParams(SensorValueParams(NAN, "CELSIUS"), "CELSIUS")
end)

-- A non-finite key falls through to the next one, as a non-numeric key does.
prefers("a non-finite CELSIUS falls through to a finite FAHRENHEIT", function()
  return CelsiusFromParams({ CELSIUS = "nan", FAHRENHEIT = "70.7" }, "CELSIUS")
end, 21.5)

-- Controls. tofinite must wrap tonumber_expect_period, or "21,5" stops parsing.
keeps("a finite CELSIUS still reads", function()
  return CelsiusFromParams({ CELSIUS = "21.5" }, "CELSIUS")
end, 21.5)
keeps("a finite FAHRENHEIT still converts", function()
  return CelsiusFromParams({ FAHRENHEIT = 70.7 }, "CELSIUS")
end, 21.5)
keeps("a finite KELVIN VALUE still converts", function()
  return CelsiusFromParams({ VALUE = 294.65, SCALE = "KELVIN" }, "CELSIUS")
end, 21.5)
keeps("a comma decimal separator still parses", function()
  return CelsiusFromParams({ CELSIUS = "21,5" }, "CELSIUS")
end, 21.5)
keeps("a zero reading is not mistaken for an absent one", function()
  return CelsiusFromParams({ CELSIUS = 0 }, "CELSIUS")
end, 0)
keeps("a finite measurement still publishes VALUE", function()
  return SensorValueParams(21.5, "CELSIUS").VALUE
end, 21.5)
keeps("and CELSIUS", function()
  return SensorValueParams(21.5, "CELSIUS").CELSIUS
end, 21.5)
keeps("and FAHRENHEIT", function()
  return SensorValueParams(21.5, "CELSIUS").FAHRENHEIT
end, 70.7)
keeps("a finite humidity still publishes VALUE", function()
  return SensorValueParams(48, "PERCENT").VALUE
end, 48)
keeps("a zero reading still publishes VALUE", function()
  return SensorValueParams(0, "CELSIUS").VALUE
end, 0)
keeps("a non-numeric VALUE is passed through as before", function()
  return SensorValueParams("warm", "PERCENT").VALUE
end, "warm")
keeps("a reading at the top of the double range keeps its own VALUE", function()
  return SensorValueParams(1e308, "FAHRENHEIT").VALUE
end, 1e308)
drops("but publishes no CELSIUS it cannot represent", function()
  return SensorValueParams(1e308, "FAHRENHEIT").CELSIUS
end)

for _, c in ipairs(CASES) do
  T.eq(c.dropped and (c.label .. " yields nil") or c.label, c.thunk(), c.want)
end

do
  local function keysOf(t)
    local names = {}
    for k in pairs(t) do
      names[#names + 1] = k
    end
    table.sort(names)
    return table.concat(names, ",")
  end
  T.eq(
    "a non-finite reading emits exactly the keys a nil one does",
    keysOf(SensorValueParams(NAN, "CELSIUS")),
    keysOf(SensorValueParams(nil, "CELSIUS"))
  )
  T.eq("and still says which scale it measured in", SensorValueParams(NAN, "CELSIUS").SCALE, "CELSIUS")
  T.check(
    "and still carries TIMESTAMP, so the reading is fresh but empty",
    type(SensorValueParams(NAN, "CELSIUS").TIMESTAMP) == "number"
  )
end

--------------------------------------------------------------------------------
T.section("Reverting the fix brings every non-finite value back")
--------------------------------------------------------------------------------

-- Swapping tofinite back to tonumber is the exact revert.
do
  local real = tofinite
  _G.tofinite = tonumber

  local results = {}
  for i, c in ipairs(CASES) do
    local ok, got = pcall(c.thunk)
    results[i] = { ok = ok, got = got }
  end

  _G.tofinite = real

  for i, c in ipairs(CASES) do
    local r = results[i]
    if not r.ok then
      T.check("reverted: " .. c.label, false, "raised " .. tostring(r.got))
    elseif c.leaks then
      T.check("reverted, leaks again: " .. c.label, isNonFinite(r.got), T.show(r.got))
    else
      T.eq("reverted, unaffected: " .. c.label, r.got, c.want)
    end
  end

  T.eq("the revert is undone", tofinite(NAN), nil)
end

T.finish()
