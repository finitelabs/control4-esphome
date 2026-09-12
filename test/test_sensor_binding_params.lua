-- Tests that sensor binding payloads carry every key convention a consumer may
-- read, and that the drivers build them with the shared helper.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sensor_binding_params.lua
--
-- The helpers' own behaviour is covered by test_sensor_params.lua. What is
-- checked here is the call sites. C4-THERM reads a bound temperature from
-- tParams["CELSIUS"] and never looks at VALUE or SCALE, and it reads
-- tParams["TIMESTAMP"] into a Dbg:Trace concatenation before testing it, so a
-- payload without one crashes the thermostat at its driver.lua:2982 before the
-- reading is ever considered.
--
-- src/esphome/entities/sensor.lua is driven for real. The drivers/*/driver.lua
-- sends cannot be: a driver.lua cannot be loaded far enough to reach those
-- handlers, so they are read from the sources instead.
--
-- Regression test for DRV-121.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

--- Everything sent since the last reset.
---
--- Captured at C4.SendToProxy rather than the global SendToProxy of the same
--- name: the global is a wrapper in lib/utils.lua that forwards through C4Call,
--- so stubbing it would measure the argument the caller passed instead of what
--- came out the far end of the path the driver actually takes.
local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams })
end

RFP = RFP or {}
OBC = OBC or {}

local SensorEntity = require("esphome.entities.sensor")

--- Discover an entity and return the binding id it registered handlers under.
--- Read as the difference against the ids already present rather than by
--- scanning RFP afterwards: pairs order is arbitrary, so a scan would return
--- whichever entity happened to hash last.
local function discover(entity)
  local before = {}
  for id in pairs(RFP) do
    before[id] = true
  end
  SensorEntity:discovered(entity)
  for id in pairs(RFP) do
    if not before[id] and type(id) == "number" then
      return id
    end
  end
  return nil
end

--------------------------------------------------------------------------------
T.section("a temperature sensor reports every key convention")
--------------------------------------------------------------------------------

local celsiusEntity = {
  key = 1,
  name = "Hall Temp",
  device_class = "temperature",
  unit_of_measurement = "°C",
}

discover(celsiusEntity)
sends = {}
SensorEntity:updated(celsiusEntity, { state = 21.5 })
local reported = sends[1]

T.check("an update pushes a VALUE_CHANGED", reported ~= nil, "no send")
T.eq("as VALUE_CHANGED", reported.command, "VALUE_CHANGED")
T.eq("VALUE is the measured number", reported.params.VALUE, 21.5)
T.eq("SCALE names the measured scale", reported.params.SCALE, "CELSIUS")
T.eq("CELSIUS is what C4-THERM reads", reported.params.CELSIUS, 21.5)
T.eq("FAHRENHEIT is converted alongside", reported.params.FAHRENHEIT, 70.7)

--------------------------------------------------------------------------------
T.section("an entity reporting Fahrenheit keeps VALUE in its own scale")
--------------------------------------------------------------------------------

-- An ESPHome sensor converted to Fahrenheit in its config reports Fahrenheit
-- with unit_of_measurement riding along. Rewriting VALUE to Celsius would change
-- the number every already-bound consumer reads, so CELSIUS is added alongside.
local fahrenheitEntity = {
  key = 2,
  name = "Attic Temp",
  device_class = "temperature",
  unit_of_measurement = "°F",
}

discover(fahrenheitEntity)
sends = {}
SensorEntity:updated(fahrenheitEntity, { state = 70.7 })
local fahrenheit = sends[1]

T.eq("VALUE is left as measured", fahrenheit.params.VALUE, 70.7)
T.eq("SCALE says so", fahrenheit.params.SCALE, "FAHRENHEIT")
T.eq("CELSIUS is converted for C4-THERM", fahrenheit.params.CELSIUS, 21.5)

--------------------------------------------------------------------------------
T.section("a Kelvin entity is converted too")
--------------------------------------------------------------------------------

local kelvinEntity = {
  key = 3,
  name = "Probe Temp",
  device_class = "temperature",
  unit_of_measurement = "K",
}

discover(kelvinEntity)
sends = {}
SensorEntity:updated(kelvinEntity, { state = 294.7 })
local kelvin = sends[1]

T.eq("VALUE stays in Kelvin", kelvin.params.VALUE, 294.7)
T.eq("SCALE says so", kelvin.params.SCALE, "KELVIN")
T.eq("CELSIUS is converted", kelvin.params.CELSIUS, 21.6)

--------------------------------------------------------------------------------
T.section("humidity carries no temperature keys")
--------------------------------------------------------------------------------

-- PERCENT is not a temperature scale, so a CELSIUS here would be a converted
-- humidity reading: a number a bound thermostat would happily act on.
local humidityEntity = {
  key = 4,
  name = "Hall Humidity",
  device_class = "humidity",
  unit_of_measurement = "%",
}

local humidityBinding = discover(humidityEntity)
sends = {}
SensorEntity:updated(humidityEntity, { state = 55 })
local humidity = sends[1]

T.eq("VALUE is the percentage", humidity.params.VALUE, 55)
T.eq("SCALE is PERCENT", humidity.params.SCALE, "PERCENT")
T.eq("no CELSIUS", humidity.params.CELSIUS, nil)
T.eq("no FAHRENHEIT", humidity.params.FAHRENHEIT, nil)

--------------------------------------------------------------------------------
T.section("the cached-value replies carry the same payload")
--------------------------------------------------------------------------------

-- sendCachedValue is the second send site in entities/sensor.lua, reached when a
-- consumer asks (GET_VALUE) and when one first binds (OBC). A fix applied only
-- to the update path would leave a newly bound thermostat with the old payload.
T.check("the humidity entity registered a binding", humidityBinding ~= nil, "no RFP entry")

sends = {}
RFP[humidityBinding](humidityBinding, "GET_VALUE", {})
local onRequest = sends[1]

T.check("GET_VALUE answers", onRequest ~= nil, "no send")
T.eq("with a TIMESTAMP", type(onRequest and onRequest.params.TIMESTAMP), "number")
T.eq("and a SCALE", onRequest and onRequest.params.SCALE, "PERCENT")

sends = {}
OBC[humidityBinding](humidityBinding, "HUMIDITY_VALUE", true)
local onBind = sends[1]

T.check("binding seeds the consumer", onBind ~= nil, "no send")
T.eq("with a TIMESTAMP", type(onBind and onBind.params.TIMESTAMP), "number")

--------------------------------------------------------------------------------
T.section("TIMESTAMP is present and fresh on every payload")
--------------------------------------------------------------------------------

-- C4-THERM crashes on a payload with no stamp and discards one stamped older
-- than 900 seconds, so both properties are asserted rather than presence alone.
local now = os.time()
for _, case in ipairs({
  { what = "celsius", captured = reported },
  { what = "fahrenheit", captured = fahrenheit },
  { what = "kelvin", captured = kelvin },
  { what = "humidity", captured = humidity },
}) do
  local stamp = case.captured.params.TIMESTAMP
  T.check(case.what .. ": TIMESTAMP is a number", type(stamp) == "number", type(stamp))
  T.check(
    case.what .. ": TIMESTAMP is epoch seconds inside C4-THERM's 900s gate",
    type(stamp) == "number" and stamp > now - 900 and stamp <= now,
    stamp
  )
end

--------------------------------------------------------------------------------
T.section("every VALUE_CHANGED send in the sources is built by the helper")
--------------------------------------------------------------------------------

-- The four drivers cannot be loaded, so their sends are read from the source.
-- Matched over the whole file rather than line by line, so a send whose
-- arguments are wrapped across lines is parsed like any other.

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function ls(dir)
  local names = {}
  local pipe = io.popen(string.format("ls %q 2>/dev/null", dir))
  if not pipe then
    return names
  end
  for name in pipe:lines() do
    table.insert(names, name)
  end
  pipe:close()
  return names
end

local function stripComments(src)
  local out = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(out, (line:gsub("%-%-.*$", "")))
  end
  return table.concat(out, "\n")
end

local sources = {}
for _, name in ipairs(ls(root .. "/drivers")) do
  local body = readFile(root .. "/drivers/" .. name .. "/driver.lua")
  if body then
    sources["drivers/" .. name] = stripComments(body)
  end
end
local entitySource = readFile(root .. "/src/esphome/entities/sensor.lua")
if entitySource then
  sources["src/esphome/entities/sensor.lua"] = stripComments(entitySource)
end

T.check("the sources are readable", next(sources) ~= nil, "nothing could be read")

-- Bounded on the open paren so SensorValueParamsX would not satisfy it.
local function isHelperCall(params)
  return params ~= nil and params:match("^SensorValueParams%s*%(") ~= nil
end

local function oneLine(text)
  return (text:gsub("%s+", " "))
end

--- Every VALUE_CHANGED send in a source as { label, params }, the number of
--- sends seen, and the number of SendToProxy occurrences %b() could not read as
--- a call.
local function valueChangedSends(src)
  local seen, parsed, unreadable = 0, {}, 0
  for _ in src:gmatch("SendToProxy") do
    unreadable = unreadable + 1
  end
  for call in src:gmatch("SendToProxy%s*(%b())") do
    unreadable = unreadable - 1
    if call:find('"VALUE_CHANGED"', 1, true) then
      seen = seen + 1
      local params = call:sub(2, -2):match('"VALUE_CHANGED"%s*,%s*(.-)%s*$')
      if params then
        table.insert(parsed, { label = oneLine("SendToProxy" .. call), params = params })
      end
    end
  end
  return seen, parsed, unreadable
end

local totalSends, totalParsed, totalUnreadable = 0, 0, 0
for name, src in pairs(sources) do
  local seen, parsed, unreadable = valueChangedSends(src)
  totalSends = totalSends + seen
  totalUnreadable = totalUnreadable + unreadable
  totalParsed = totalParsed + #parsed
  for _, send in ipairs(parsed) do
    T.check(name .. ": " .. send.label, isHelperCall(send.params), oneLine(send.params))
  end
end

-- A rename or refactor that stopped matching would otherwise pass silently.
T.check("the scan found sends to check", totalParsed > 0, totalParsed)

-- Two ways a send goes unchecked, both of which move only the assertion count:
-- %b() cannot read the call, or it can but no payload argument parses out of it.
T.check(
  "every SendToProxy occurrence was read as a call",
  totalUnreadable == 0,
  string.format("%d occurrences did not parse as SendToProxy(...)", totalUnreadable)
)
T.check(
  "every VALUE_CHANGED send yielded a payload argument",
  totalParsed == totalSends,
  string.format("parsed %d of %d sends", totalParsed, totalSends)
)

--------------------------------------------------------------------------------
T.section("the climate driver reads its inputs with the right default scale")
--------------------------------------------------------------------------------

-- The local getCelsiusFromParams was folded onto the shared CelsiusFromParams.
-- Its default scale is per-caller and the two kinds of caller disagree, so each
-- call is read out of its own enclosing function: a file-global search cannot
-- see which caller it sits in, and would still pass with the defaults swapped.
--
-- The setpoint handlers pass no default. A proxy setpoint arrives carrying
-- CELSIUS, FAHRENHEIT and KELVIN at once, so the default gates only the bare
-- VALUE branch, which no setpoint sender uses; with no default that branch
-- yields nil and the handler drops the command rather than driving the HVAC
-- from a misconverted number. handleValueChanged is a sensor binding, where a
-- bare VALUE is reachable and reports Celsius by the binding convention, so its
-- default is load-bearing and stays (DRV-123).
local climate = sources["drivers/esphome_climate"]

T.check("the climate source was read", climate ~= nil, "missing")

-- `bare` is what CelsiusFromParams must return for a VALUE-only payload at that
-- site: dropped where there is no default, read as Celsius at the sensor.
local INPUT_CALLERS = {
  { fn = "RFP%.SET_SETPOINT_HEAT", scale = nil, bare = nil, what = "a heat setpoint takes no default" },
  { fn = "RFP%.SET_SETPOINT_COOL", scale = nil, bare = nil, what = "a cool setpoint takes no default" },
  { fn = "RFP%.SET_SETPOINT_SINGLE", scale = nil, bare = nil, what = "a single setpoint takes no default" },
  {
    fn = "local function handleValueChanged",
    scale = "CELSIUS",
    bare = 21.5,
    what = "a bound sensor reports Celsius",
  },
}

--- The default scale a call site passes, as `scale, readable`. Both shapes are
--- matched explicitly so an unrecognised one reports as unreadable instead of
--- reading as the absence of an argument, which is the thing under test.
local function defaultScaleOf(call)
  if call == nil then
    return nil, false
  end
  if call:match("^%(%s*tParams%s*%)$") then
    return nil, true
  end
  local scale = call:match('^%(%s*tParams%s*,%s*"([^"]+)"%s*%)$')
  return scale, scale ~= nil
end

for _, case in ipairs(INPUT_CALLERS) do
  local body = climate and climate:match(case.fn .. "%s*%b()(.-)\nend\n")
  -- Frontier-bounded: an unbounded match also hits inside the local
  -- getCelsiusFromParams this fold removes, which reads as a call with no scale
  -- argument rather than as the absence of one.
  local call = body and body:match("%f[%w_]CelsiusFromParams%s*(%b())")
  local scale, readable = defaultScaleOf(call)
  T.check(
    case.what,
    readable and scale == case.scale,
    call and oneLine(call) or ("no CelsiusFromParams call found in " .. case.fn)
  )
  -- Driven with the scale parsed out of the call rather than with case.scale, so
  -- the two halves cannot drift apart. Collapsing the sites onto one shared
  -- default converts the bare VALUE at a setpoint instead of dropping it, and
  -- fails here as behaviour, not only as changed call text above.
  local got
  if readable then
    got = CelsiusFromParams({ VALUE = 21.5 }, scale)
  end
  T.eq(case.what .. ": a bare VALUE", got, case.bare)
end

T.check(
  "no local parser is left behind",
  climate ~= nil and climate:find("getCelsiusFromParams", 1, true) == nil,
  "getCelsiusFromParams is still referenced"
)

T.finish()
