-- A non-finite climate reading must not reach the thermostatV2 proxy, and a
-- non-finite stored setpoint must not be stepped and sent back to the unit.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_climate_nonfinite.lua
--
-- ESPHome reports NaN for a float an entity has not measured yet. `tonumber`
-- passes NaN and infinity straight through, so neither the `~= nil` guards on
-- the reported values nor the `or 0` fallbacks in the stepping path ever fired
-- for them, and `math.floor(nan + 0.5)` is still NaN, so "nan" was rendered
-- into the proxy parameters.
--
-- The absent case has to stay distinct from the non-finite one: #119 made a
-- missing field read as zero, because protobuf leaves a zero off the wire, and
-- collapsing the two would publish a plausible zero for a reading the unit
-- never took.
--
-- Part of DRV-122, sites 2 to 7.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local pb = require("protobuf")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local Mode = ESPHomeProtoSchema.Enum.ClimateMode
local Fan = ESPHomeProtoSchema.Enum.ClimateFanMode
local ClimateState = ESPHomeProtoSchema.Message.ClimateStateResponse

local NAN = 0 / 0
local INF = math.huge

local ESPHOME_BINDING = 1
local PROXY_BINDING = 5001

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local src = readFile(root .. "/drivers/esphome_climate/driver.lua")
T.check("the esphome_climate source was read", src ~= nil, "missing")

local function newLog()
  return setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
end

--------------------------------------------------------------------------------
T.section("premises: a NaN really arrives, and the old reads really passed it on")
--------------------------------------------------------------------------------

--- Encode a ClimateStateResponse as a unit would and decode it back. ESPHome
--- skips a zero enum or float, "" and false.
local function fromWire(state)
  local sent = {}
  for name, value in pairs(state) do
    if value ~= 0 and value ~= "" and value ~= false then
      sent[name] = value
    end
  end
  return pb.decode(ESPHomeProtoSchema, ClimateState, pb.encode(ESPHomeProtoSchema, ClimateState, sent))
end

-- If the decoder lost the NaN, every "nothing was sent" case below would pass
-- for the wrong reason and the reverted arms could not fail.
local nanDecoded = fromWire({ key = 1234, current_temperature = NAN, target_temperature = NAN, current_humidity = NAN })
T.check(
  "a NaN survives the protobuf round trip",
  nanDecoded.current_temperature ~= nanDecoded.current_temperature,
  "lost"
)
T.check("a NaN target survives too", nanDecoded.target_temperature ~= nanDecoded.target_temperature, "lost")
T.check("a NaN humidity survives too", nanDecoded.current_humidity ~= nanDecoded.current_humidity, "lost")

local infDecoded = fromWire({ key = 1234, current_temperature = INF, target_temperature = -INF })
T.eq("an +inf survives the protobuf round trip", infDecoded.current_temperature, INF)
T.eq("a -inf survives the protobuf round trip", infDecoded.target_temperature, -INF)

-- Why the fix had to be `tofinite` and not a tighter `or` fallback.
T.check("tonumber passes a NaN through", tonumber(NAN) ~= tonumber(NAN), "it did not")
T.eq("an or-fallback does not fire for a NaN", (tonumber(NAN) or 0) ~= (tonumber(NAN) or 0), true)
T.check("flooring a NaN is still a NaN", math.floor(NAN + 0.5) ~= math.floor(NAN + 0.5), "it is not")
T.eq("rendering a NaN produces a number-shaped string", tostring(NAN), "nan")

--------------------------------------------------------------------------------
T.section("reverting each fixed read back to its pre-fix text")
--------------------------------------------------------------------------------

--- Replace `from` with `to`, and fail rather than return the original when the
--- source no longer holds exactly one copy. A silent no-op here would leave a
--- reverted arm running the fixed code and passing.
--- @return string|nil
local function replaceOnce(text, from, to)
  local i, j = text:find(from, 1, true)
  if i == nil or text:find(from, j + 1, true) ~= nil then
    return nil
  end
  return text:sub(1, i - 1) .. to .. text:sub(j + 1)
end

--- One entry per audited site. `fixed` must appear exactly once in the source.
local REVERTS = {
  readers = {
    site = "2 and 6, the stateNumber reads",
    fixed = "local raw = Select(state, name)\n  if raw == nil and reported then\n    return 0\n  end\n  return tofinite(raw)",
    prefix = "local value = tonumber(Select(state, name))\n  if value == nil and reported then\n    return 0\n  end\n  return value",
  },
  singleSetpoint = {
    site = "3, the single setpoint",
    fixed = '-- Single setpoint mode (water heaters, floor heaters, etc.)\n    local targetTemp = tofinite(Select(state, "target_temperature"))',
    prefix = '-- Single setpoint mode (water heaters, floor heaters, etc.)\n    local targetTemp = tonumber(Select(state, "target_temperature"))',
  },
  twoPointSetpoints = {
    site = "4, the low/high setpoints",
    fixed = 'local targetLow = tofinite(Select(state, "target_temperature_low"))\n    local targetHigh = tofinite(Select(state, "target_temperature_high"))',
    prefix = 'local targetLow = tonumber(Select(state, "target_temperature_low"))\n    local targetHigh = tonumber(Select(state, "target_temperature_high"))',
  },
  modeSetpoint = {
    site = "5, the single point non-water-heater setpoint",
    fixed = 'local targetTemp = tofinite(Select(state, "target_temperature"))\n    if targetTemp ~= nil then\n      -- Send to the appropriate setpoint based on current mode',
    prefix = 'local targetTemp = tonumber(Select(state, "target_temperature"))\n    if targetTemp ~= nil then\n      -- Send to the appropriate setpoint based on current mode',
  },
  stepTwoPoint = {
    site = "7, stepping a two-point setpoint",
    fixed = "local current = tofinite(Select(STATE, twoPointField)) or 0",
    prefix = "local current = tonumber(Select(STATE, twoPointField)) or 0",
  },
  stepAdjustSingle = {
    site = "7, stepping a single setpoint via adjustSetpoint",
    fixed = 'local current = tofinite(Select(STATE, "target_temperature")) or 0\n    sendClimateCommand({ has_target_temperature = true,',
    prefix = 'local current = tonumber(Select(STATE, "target_temperature")) or 0\n    sendClimateCommand({ has_target_temperature = true,',
  },
  stepIncSingle = {
    site = "7, INC_SETPOINT_SINGLE",
    fixed = 'local current = tofinite(Select(STATE, "target_temperature")) or 0\n  sendTargetTemperature(clampTemperature(current + step))',
    prefix = 'local current = tonumber(Select(STATE, "target_temperature")) or 0\n  sendTargetTemperature(clampTemperature(current + step))',
  },
  stepDecSingle = {
    site = "7, DEC_SETPOINT_SINGLE",
    fixed = 'local current = tofinite(Select(STATE, "target_temperature")) or 0\n  sendTargetTemperature(clampTemperature(current - step))',
    prefix = 'local current = tonumber(Select(STATE, "target_temperature")) or 0\n  sendTargetTemperature(clampTemperature(current - step))',
  },
}

local sourceCache = {}

--- The source with the named sites reverted to their pre-fix text.
--- @param names string[] Keys of REVERTS, or {} for the source as it stands.
--- @return string text, string key
local function sourceWith(names)
  local key = table.concat(names, ",")
  if sourceCache[key] ~= nil then
    return sourceCache[key], key
  end
  local text = src
  for _, name in ipairs(names) do
    local entry = REVERTS[name]
    local next_ = text and replaceOnce(text, entry.fixed, entry.prefix)
    T.check("site " .. entry.site .. " was reverted", next_ ~= nil, "no unique match for " .. name)
    text = next_ or text
  end
  sourceCache[key] = text
  return text, key
end

-- Every site reverts on its own, which is also the check that each `fixed`
-- string still matches exactly one place in the driver.
local ALL = {}
for name in pairs(REVERTS) do
  table.insert(ALL, name)
end
table.sort(ALL)
for _, name in ipairs(ALL) do
  sourceWith({ name })
end

--------------------------------------------------------------------------------
T.section("cutting the handlers out of the driver")
--------------------------------------------------------------------------------

-- A driver.lua cannot be loaded far enough to reach its handlers, so each one is
-- cut out and compiled on its own. The lookup tables and the arithmetic helpers
-- come with it, so the driver's own clamping and stepping is what runs rather
-- than a copy made here.
local function cutter(text)
  return {
    table_ = function(name)
      return text:match("\n(local " .. name .. " = %b{})\n")
    end,
    localFn = function(name)
      return text:match("\n(local function " .. name .. "%s*%b()\n.-\nend)\n")
    end,
    handler = function(name)
      return text:match("\n(function RFP%." .. name .. "%s*%b()\n.-\nend)\n")
    end,
  }
end

-- Built once per (spec, set of reverts); the cases below each ask for a body
-- many times and the cut is the same every time.
local bodyCache = {}

--- @param text string The driver source, possibly with reverts applied.
--- @param spec table<number, table> {kind, name} pairs, in dependency order.
--- @param label string
--- @param key string Identifies the reverts applied to `text`.
--- @return string|nil body
local function cutBody(text, spec, label, key)
  local cacheKey = label .. "|" .. (key or "")
  local hit = bodyCache[cacheKey]
  if hit ~= nil then
    return hit.body
  end
  local cut = cutter(text)
  local parts = {}
  for _, item in ipairs(spec) do
    local piece = cut[item[1]](item[2])
    if not T.check(label .. ": " .. item[2] .. " was cut out", piece ~= nil, "no match") then
      bodyCache[cacheKey] = { body = nil }
      return nil
    end
    table.insert(parts, piece)
  end
  local body = table.concat(parts, "\n")
  bodyCache[cacheKey] = { body = body }
  return body
end

local UPDATE_STATE_SPEC = {
  { "table_", "CLIMATE_MODE_TO_C4" },
  { "table_", "CLIMATE_ACTION_TO_C4" },
  { "table_", "CLIMATE_FAN_MODE_TO_C4" },
  { "localFn", "stateNumber" },
  { "localFn", "listHas" },
  { "handler", "UPDATE_STATE" },
}

local STEP_SPEC = {
  { "localFn", "getEntityTempRange" },
  { "localFn", "getEntityTempStep" },
  { "localFn", "clampTemperature" },
  { "localFn", "adjustSetpoint" },
  { "handler", "INC_SETPOINT_HEAT" },
  { "handler", "INC_SETPOINT_COOL" },
  { "handler", "INC_SETPOINT_SINGLE" },
  { "handler", "DEC_SETPOINT_SINGLE" },
}

-- A cut of the wrong region would send nothing, which is what most cases below
-- assert, so the cut text is checked for the code that does the sending.
local updateBody = cutBody(src, UPDATE_STATE_SPEC, "UPDATE_STATE", "")
local stepBody = cutBody(src, STEP_SPEC, "stepping", "")
T.contains("the cut UPDATE_STATE sends TEMPERATURE_CHANGED", updateBody, "TEMPERATURE_CHANGED")
T.contains("the cut UPDATE_STATE sends SINGLE_SETPOINT_CHANGED", updateBody, "SINGLE_SETPOINT_CHANGED")
T.contains("the cut UPDATE_STATE sends HUMIDITY_CHANGED", updateBody, "HUMIDITY_CHANGED")
T.contains("the cut stepping path clamps", stepBody, "clampTemperature")
T.contains("the cut stepping path sends a climate command", stepBody, "sendClimateCommand")

--------------------------------------------------------------------------------
T.section("compiling each handler under a synthetic environment")
--------------------------------------------------------------------------------

local sends = {}

-- Captured below lib/utils.lua's SendToProxy wrapper, so the wrapper stays in
-- the path under test.
C4.SendToProxy = function(_, idBinding, strCommand, tParams, strMessage)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams, message = strMessage })
end

local function lastParams(command)
  for i = #sends, 1, -1 do
    if sends[i].command == command and sends[i].idBinding == PROXY_BINDING then
      return sends[i].params
    end
  end
  return nil
end

--- The driver's upvalues resolve as globals here, so `env` supplies them and
--- everything else falls through to the real lib/utils.lua.
local function compile(body, extraEnv, returns, chunkName)
  local env = {
    RFP = {},
    log = newLog(),
    ESPHomeProtoSchema = ESPHomeProtoSchema,
    ESPHOME_BINDING = ESPHOME_BINDING,
    PROXY_BINDING = PROXY_BINDING,
    TEMPERATURE_OUTPUT_BINDING = 5002,
    HUMIDITY_OUTPUT_BINDING = 5003,
    SCALE = "C",
    CAPABILITIES_SENT = true,
    IS_SINGLE_SETPOINT = false,
    C4_TO_WATER_HEATER_MODE = {},
    persist = { set = function() end },
    sendCapabilities = function() end,
    sendDisplayScale = function() end,
    updateStatus = function() end,
    sendConnectionState = function() end,
  }
  for k, v in pairs(extraEnv or {}) do
    env[k] = v
  end
  local chunk = loadstring(body .. "\n" .. returns, chunkName)
  if not T.check(chunkName .. " compiles", chunk ~= nil, "it did not compile") then
    return nil, env
  end
  return setfenv(chunk, setmetatable(env, { __index = _G }))(), env
end

--- @param names string[] Sites to revert; {} for the driver as it stands.
local function updateStateHandler(names, singleSetpoint)
  local body = cutBody(sourceWith(names), UPDATE_STATE_SPEC, "UPDATE_STATE", table.concat(names, ","))
  local fn = compile(body, { IS_SINGLE_SETPOINT = singleSetpoint or false }, "return RFP.UPDATE_STATE", "=UPDATE_STATE")
  return fn
end

--- Hand a state to UPDATE_STATE the way entities/climate.lua does.
local function drive(handler, entity, state)
  sends = {}
  handler(ESPHOME_BINDING, "UPDATE_STATE", {
    entity = SerializeSafe(entity),
    state = SerializeSafe(fromWire(state)),
  })
end

local ENTITY = {
  key = 1234,
  supported_modes = { Mode.CLIMATE_MODE_OFF, Mode.CLIMATE_MODE_COOL, Mode.CLIMATE_MODE_HEAT },
  supports_action = true,
  supports_current_temperature = true,
  supports_current_humidity = true,
  supports_target_humidity = true,
  supported_fan_modes = { Fan.CLIMATE_FAN_ON, Fan.CLIMATE_FAN_LOW },
  supports_two_point_target_temperature = false,
}

local TWO_POINT = {}
for k, v in pairs(ENTITY) do
  TWO_POINT[k] = v
end
TWO_POINT.supports_two_point_target_temperature = true

--------------------------------------------------------------------------------
T.section("sites 2 and 6: readings, with absent kept distinct from non-finite")
--------------------------------------------------------------------------------

local fixed = updateStateHandler({})

drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, current_temperature = 21.5, current_humidity = 44 })
T.eq("a finite temperature is still reported", (lastParams("TEMPERATURE_CHANGED") or {}).TEMPERATURE, "21.5")
T.eq("a finite humidity is still reported", (lastParams("HUMIDITY_CHANGED") or {}).HUMIDITY, "44")

-- The #119 behaviour this fix must not undo.
drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, current_temperature = 0, current_humidity = 0 })
T.eq("a reading of exactly zero is still reported", (lastParams("TEMPERATURE_CHANGED") or {}).TEMPERATURE, "0")
T.eq("a humidity of exactly zero is still reported", (lastParams("HUMIDITY_CHANGED") or {}).HUMIDITY, "0")

drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, current_temperature = NAN, current_humidity = NAN })
T.eq("a NaN temperature is not reported", lastParams("TEMPERATURE_CHANGED"), nil)
T.eq("a NaN humidity is not reported", lastParams("HUMIDITY_CHANGED"), nil)

drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, current_temperature = INF, current_humidity = -INF })
T.eq("an infinite temperature is not reported", lastParams("TEMPERATURE_CHANGED"), nil)
T.eq("an infinite humidity is not reported", lastParams("HUMIDITY_CHANGED"), nil)

-- The distinction that matters: a NaN must not be laundered into the zero that
-- an absent-but-reported field is entitled to.
drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, current_temperature = NAN })
T.neq("a NaN temperature is not reported as zero", (lastParams("TEMPERATURE_CHANGED") or {}).TEMPERATURE, "0")
T.eq("and is not reported at all", lastParams("TEMPERATURE_CHANGED"), nil)

-- Same read, same entity, field simply absent: still zero.
drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL })
T.eq("an absent-but-reported temperature is still zero", (lastParams("TEMPERATURE_CHANGED") or {}).TEMPERATURE, "0")
T.eq("an absent-but-reported humidity is still zero", (lastParams("HUMIDITY_CHANGED") or {}).HUMIDITY, "0")

-- Reading through the same helper, so it moves with sites 2 and 6.
drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_humidity = NAN })
T.eq("a NaN humidity setpoint is not reported", lastParams("HUMIDIFY_SETPOINT_CHANGED"), nil)

local revertedReaders = updateStateHandler({ "readers" })
drive(
  revertedReaders,
  ENTITY,
  { key = 1234, mode = Mode.CLIMATE_MODE_COOL, current_temperature = NAN, current_humidity = NAN }
)
T.eq("reverted, a NaN temperature is published as nan", (lastParams("TEMPERATURE_CHANGED") or {}).TEMPERATURE, "nan")
T.eq("reverted, a NaN humidity is published as nan", (lastParams("HUMIDITY_CHANGED") or {}).HUMIDITY, "nan")
drive(revertedReaders, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL })
T.eq("reverted, an absent temperature is still zero", (lastParams("TEMPERATURE_CHANGED") or {}).TEMPERATURE, "0")

--------------------------------------------------------------------------------
T.section("site 3: the single setpoint")
--------------------------------------------------------------------------------

local fixedSingle = updateStateHandler({}, true)
drive(fixedSingle, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_HEAT, target_temperature = 52.0 })
T.eq("a finite single setpoint is reported", (lastParams("SINGLE_SETPOINT_CHANGED") or {}).SETPOINT, "52")

drive(fixedSingle, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_HEAT, target_temperature = NAN })
T.eq("a NaN single setpoint is not reported", lastParams("SINGLE_SETPOINT_CHANGED"), nil)
drive(fixedSingle, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_HEAT, target_temperature = INF })
T.eq("an infinite single setpoint is not reported", lastParams("SINGLE_SETPOINT_CHANGED"), nil)

local revertedSingle = updateStateHandler({ "singleSetpoint" }, true)
drive(revertedSingle, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_HEAT, target_temperature = NAN })
T.eq(
  "reverted, a NaN single setpoint is published as nan",
  (lastParams("SINGLE_SETPOINT_CHANGED") or {}).SETPOINT,
  "nan"
)

--------------------------------------------------------------------------------
T.section("site 4: the low and high setpoints")
--------------------------------------------------------------------------------

drive(
  fixed,
  TWO_POINT,
  { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_temperature_low = 19, target_temperature_high = 24 }
)
T.eq("a finite heat setpoint is reported", (lastParams("HEAT_SETPOINT_CHANGED") or {}).SETPOINT, "19")
T.eq("a finite cool setpoint is reported", (lastParams("COOL_SETPOINT_CHANGED") or {}).SETPOINT, "24")

drive(
  fixed,
  TWO_POINT,
  { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_temperature_low = NAN, target_temperature_high = NAN }
)
T.eq("a NaN heat setpoint is not reported", lastParams("HEAT_SETPOINT_CHANGED"), nil)
T.eq("a NaN cool setpoint is not reported", lastParams("COOL_SETPOINT_CHANGED"), nil)

drive(
  fixed,
  TWO_POINT,
  { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_temperature_low = -INF, target_temperature_high = INF }
)
T.eq("an infinite heat setpoint is not reported", lastParams("HEAT_SETPOINT_CHANGED"), nil)
T.eq("an infinite cool setpoint is not reported", lastParams("COOL_SETPOINT_CHANGED"), nil)

-- One non-finite must not suppress the other.
drive(
  fixed,
  TWO_POINT,
  { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_temperature_low = NAN, target_temperature_high = 24 }
)
T.eq("a NaN low does not suppress a finite high", (lastParams("COOL_SETPOINT_CHANGED") or {}).SETPOINT, "24")
T.eq("and the NaN low is still dropped", lastParams("HEAT_SETPOINT_CHANGED"), nil)

local revertedTwoPoint = updateStateHandler({ "twoPointSetpoints" })
drive(
  revertedTwoPoint,
  TWO_POINT,
  { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_temperature_low = NAN, target_temperature_high = NAN }
)
T.eq("reverted, a NaN heat setpoint is published as nan", (lastParams("HEAT_SETPOINT_CHANGED") or {}).SETPOINT, "nan")
T.eq("reverted, a NaN cool setpoint is published as nan", (lastParams("COOL_SETPOINT_CHANGED") or {}).SETPOINT, "nan")

--------------------------------------------------------------------------------
T.section("site 5: the single point non-water-heater setpoint")
--------------------------------------------------------------------------------

drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_temperature = 23.5 })
T.eq(
  "a finite target is reported to the cool setpoint in Cool",
  (lastParams("COOL_SETPOINT_CHANGED") or {}).SETPOINT,
  "23.5"
)

drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, target_temperature = NAN })
T.eq("a NaN target reports no cool setpoint", lastParams("COOL_SETPOINT_CHANGED"), nil)
drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_HEAT, target_temperature = NAN })
T.eq("a NaN target reports no heat setpoint", lastParams("HEAT_SETPOINT_CHANGED"), nil)

-- The both-setpoints branch, which a mode outside Cool/Heat takes.
drive(fixed, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_OFF, target_temperature = NAN })
T.eq("a NaN target reports neither setpoint in Off", lastParams("HEAT_SETPOINT_CHANGED"), nil)
T.eq("and none on the cool side either", lastParams("COOL_SETPOINT_CHANGED"), nil)

local revertedMode = updateStateHandler({ "modeSetpoint" })
drive(revertedMode, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_OFF, target_temperature = NAN })
T.eq("reverted, a NaN target is published to heat as nan", (lastParams("HEAT_SETPOINT_CHANGED") or {}).SETPOINT, "nan")
T.eq("reverted, a NaN target is published to cool as nan", (lastParams("COOL_SETPOINT_CHANGED") or {}).SETPOINT, "nan")

--------------------------------------------------------------------------------
T.section("site 7: stepping a stored setpoint that is not finite")
--------------------------------------------------------------------------------

-- Stepping reads the last state the unit sent, so a NaN there became
-- `nan + step`, which clampTemperature returns unchanged, and the driver then
-- wrote that NaN back to the unit as a command.

--- @param names string[] Sites to revert.
--- @param entity table
--- @param state table
--- @return table commands Each body handed to sendClimateCommand/sendTargetTemperature.
local function step(names, entity, state, method)
  local commands = {}
  local body = cutBody(sourceWith(names), STEP_SPEC, "stepping", table.concat(names, ","))
  local RFP = compile(body, {
    ENTITY = entity,
    STATE = state,
    sendClimateCommand = function(b)
      table.insert(commands, b)
    end,
    sendTargetTemperature = function(celsius)
      table.insert(commands, { target_temperature = celsius })
    end,
  }, "return RFP", "=stepping")
  if RFP == nil then
    return commands
  end
  RFP[method](PROXY_BINDING, method)
  return commands
end

local RANGED = { min_temperature = 7, max_temperature = 35, target_temperature_step = 0.5 }
local UNRANGED = { target_temperature_step = 0.5 }

--- @return number|nil
local function sent(commands, field)
  return commands[1] and commands[1][field] or nil
end

--- @return boolean
local function isNan(value)
  return value ~= value
end

-- Positive control: a finite stored setpoint still steps.
local ok = step({}, RANGED, { target_temperature = 21.0 }, "INC_SETPOINT_SINGLE")
T.eq("a finite setpoint steps up by the step value", sent(ok, "target_temperature"), 21.5)
ok = step({}, RANGED, { target_temperature = 21.0 }, "DEC_SETPOINT_SINGLE")
T.eq("a finite setpoint steps down by the step value", sent(ok, "target_temperature"), 20.5)

for _, method in ipairs({ "INC_SETPOINT_SINGLE", "DEC_SETPOINT_SINGLE" }) do
  local out = step({}, RANGED, { target_temperature = NAN }, method)
  T.check(
    method .. " sends a finite setpoint for a NaN stored value",
    not isNan(sent(out, "target_temperature")),
    "nan"
  )
  T.truthy(method .. " still sends something", sent(out, "target_temperature") ~= nil)
end

-- adjustSetpoint, the two-point and single-point branches.
local twoPointRanged = { min_temperature = 7, max_temperature = 35, supports_two_point_target_temperature = true }
local heat = step({}, twoPointRanged, { target_temperature_low = NAN }, "INC_SETPOINT_HEAT")
T.check(
  "INC_SETPOINT_HEAT sends a finite low for a NaN stored low",
  not isNan(sent(heat, "target_temperature_low")),
  "nan"
)
local cool = step({}, twoPointRanged, { target_temperature_high = NAN }, "INC_SETPOINT_COOL")
T.check(
  "INC_SETPOINT_COOL sends a finite high for a NaN stored high",
  not isNan(sent(cool, "target_temperature_high")),
  "nan"
)
local single = step({}, RANGED, { target_temperature = NAN }, "INC_SETPOINT_HEAT")
T.check(
  "INC_SETPOINT_HEAT on a single point unit sends a finite target",
  not isNan(sent(single, "target_temperature")),
  "nan"
)

-- Without a declared range nothing clamps, so infinity reaches the unit too.
for _, value in ipairs({ INF, -INF }) do
  local out = step({}, UNRANGED, { target_temperature = value }, "INC_SETPOINT_SINGLE")
  local got = sent(out, "target_temperature")
  T.check("an unranged unit is not sent an infinite setpoint", got ~= INF and got ~= -INF, tostring(got))
end

-- Reverted arms, one per stepping site.
local revertedInc = step({ "stepIncSingle" }, RANGED, { target_temperature = NAN }, "INC_SETPOINT_SINGLE")
T.check(
  "reverted, INC_SETPOINT_SINGLE writes a NaN back to the unit",
  isNan(sent(revertedInc, "target_temperature")),
  "it did not"
)
local revertedDec = step({ "stepDecSingle" }, RANGED, { target_temperature = NAN }, "DEC_SETPOINT_SINGLE")
T.check(
  "reverted, DEC_SETPOINT_SINGLE writes a NaN back to the unit",
  isNan(sent(revertedDec, "target_temperature")),
  "it did not"
)
local revertedTwo = step({ "stepTwoPoint" }, twoPointRanged, { target_temperature_low = NAN }, "INC_SETPOINT_HEAT")
T.check(
  "reverted, INC_SETPOINT_HEAT writes a NaN low back to the unit",
  isNan(sent(revertedTwo, "target_temperature_low")),
  "it did not"
)
local revertedAdjust = step({ "stepAdjustSingle" }, RANGED, { target_temperature = NAN }, "INC_SETPOINT_HEAT")
T.check(
  "reverted, adjustSetpoint writes a NaN target back to the unit",
  isNan(sent(revertedAdjust, "target_temperature")),
  "it did not"
)

local revertedUnranged = step({ "stepIncSingle" }, UNRANGED, { target_temperature = INF }, "INC_SETPOINT_SINGLE")
T.eq("reverted, an unranged unit is sent an infinite setpoint", sent(revertedUnranged, "target_temperature"), INF)

T.finish()
