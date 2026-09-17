-- Tests that esphome_climate reads a zero-valued state field that ESPHome left
-- off the wire.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_climate_zero_fields.lua
--
-- ESPHome's API is proto3 with implicit presence: a field holding the type's
-- zero is left off the wire entirely. In api_pb2.cpp, ClimateStateResponse
-- accounts for `mode` as `size += this->mode ? 2 : 0`, and proto.h's
-- encode_uint32 returns early on `value == 0 && !force`. So for a unit that is
-- off, CLIMATE_MODE_OFF (0) never arrives, and vendor/protobuf.lua decodes the
-- message into a table with no `mode` key rather than one holding 0.
--
-- Turning the unit off therefore used to strand the Control4 proxy on whatever
-- mode it last saw, while off -> cool worked, because COOL is 2 and 2 is sent.
-- CLIMATE_ACTION_OFF and CLIMATE_FAN_ON are zero for the same reason, and a
-- float is dropped when its bits are all zero, so a 0 C or 0% reading is too.
-- An unknown reading is NaN, which is sent, so a missing reading on a unit that
-- reports it means exactly 0.
--
-- States go through the real decoder. vendor/protobuf.lua's encoder writes a
-- zero where ESPHome's does not, so zero fields are stripped first by the same
-- rule ESPHome applies, and a test can write `mode = OFF` or a 0 C reading and
-- get the bytes a unit actually sends.
--
-- Regression test for #119.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local pb = require("protobuf")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local Mode = ESPHomeProtoSchema.Enum.ClimateMode
local Action = ESPHomeProtoSchema.Enum.ClimateAction
local Fan = ESPHomeProtoSchema.Enum.ClimateFanMode
local ClimateState = ESPHomeProtoSchema.Message.ClimateStateResponse

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local ESPHOME_BINDING = 1
local PROXY_BINDING = 5001

--- Everything sent since the last reset.
---
--- Captured at C4.SendToProxy rather than the global of the same name, which is
--- a wrapper in lib/utils.lua: stubbing the global would measure the argument
--- the driver passed instead of what came out the far end.
local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams, strMessage)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams, message = strMessage })
end

--- The parameters of the last `command` sent to the proxy, or nil.
local function lastParams(command)
  for i = #sends, 1, -1 do
    if sends[i].command == command and sends[i].idBinding == PROXY_BINDING then
      return sends[i].params
    end
  end
  return nil
end

--- A no-op logger. The driver calls log:trace/debug/warn on the way through.
local function newLog()
  return setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
end

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

--------------------------------------------------------------------------------
T.section("cutting UPDATE_STATE and its lookup tables out of the driver")
--------------------------------------------------------------------------------

-- A driver.lua cannot be loaded far enough to reach its handlers (see
-- test_sensor_binding_params.lua), so the handler is cut out and compiled on its
-- own. The lookup tables come along in the same chunk so that what is asserted
-- is the driver's own mapping, not a copy of it written here: a copy would agree
-- with the fix by construction.
local function cutTable(name)
  return src and src:match("\n(local " .. name .. " = %b{})\n")
end

local function cutHandler(name)
  return src and src:match("\n(function RFP%." .. name .. "%s*%b()\n.-\nend)\n")
end

local function cutLocalFunction(name)
  return src and src:match("\n(local function " .. name .. "%s*%b()\n.-\nend)\n")
end

local PIECES = {
  { what = "CLIMATE_MODE_TO_C4", text = cutTable("CLIMATE_MODE_TO_C4") },
  { what = "CLIMATE_ACTION_TO_C4", text = cutTable("CLIMATE_ACTION_TO_C4") },
  { what = "CLIMATE_FAN_MODE_TO_C4", text = cutTable("CLIMATE_FAN_MODE_TO_C4") },
  { what = "stateNumber", text = cutLocalFunction("stateNumber") },
  { what = "listHas", text = cutLocalFunction("listHas") },
  { what = "RFP.UPDATE_STATE", text = cutHandler("UPDATE_STATE") },
}
for _, piece in ipairs(PIECES) do
  T.check(piece.what .. " was cut out of the source", piece.text ~= nil, "no match")
end

local body = {}
for _, piece in ipairs(PIECES) do
  table.insert(body, piece.text or "")
end
-- A cut that matched the wrong region would send nothing, which reads the same
-- as the bug being fixed by deletion.
T.check(
  "the cut handler sends HVAC_MODE_CHANGED",
  (PIECES[6].text or ""):find("HVAC_MODE_CHANGED", 1, true) ~= nil,
  "not in the cut text"
)
T.check(
  "the cut mode table maps CLIMATE_MODE_OFF",
  (PIECES[1].text or ""):find("CLIMATE_MODE_OFF", 1, true) ~= nil,
  "not in the cut text"
)

local chunk = loadstring(table.concat(body, "\n") .. "\nreturn RFP.UPDATE_STATE", "=UPDATE_STATE")
T.check("the chunk compiles", chunk ~= nil, "it did not compile")

--- Compile UPDATE_STATE against a stub environment and return it.
---
--- What were upvalues in driver.lua resolve as globals here, so `env` supplies
--- them; anything env does not name falls through to _G, which is how Select,
--- tointeger and the SendToProxy wrapper reach the real lib/utils.lua.
local function newHandler()
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
  local fn = setfenv(
    loadstring(table.concat(body, "\n") .. "\nreturn RFP.UPDATE_STATE", "=UPDATE_STATE"),
    setmetatable(env, { __index = _G })
  )()
  return fn
end

--- Encode a ClimateStateResponse as an ESPHome unit would and decode it back.
---
--- ESPHome skips a 0 enum and an all-zero float (proto.h: `if (value == 0 &&
--- !force) return;`, and `raw == 0` for floats), and likewise "" and false.
local function fromWire(state)
  local sent = {}
  for name, value in pairs(state) do
    if value ~= 0 and value ~= "" and value ~= false then
      sent[name] = value
    end
  end
  return pb.decode(ESPHomeProtoSchema, ClimateState, pb.encode(ESPHomeProtoSchema, ClimateState, sent))
end

--- Hand a state to UPDATE_STATE the way entities/climate.lua does.
local function drive(handler, entity, state)
  local decoded = fromWire(state)
  sends = {}
  handler(ESPHOME_BINDING, "UPDATE_STATE", {
    entity = SerializeSafe(entity),
    state = SerializeSafe(decoded),
  })
  return decoded
end

local ENTITY = {
  key = 1234,
  supported_modes = { Mode.CLIMATE_MODE_OFF, Mode.CLIMATE_MODE_COOL },
  supports_action = true,
  supports_current_temperature = true,
  supports_current_humidity = true,
  supports_target_humidity = true,
  supported_fan_modes = { Fan.CLIMATE_FAN_ON, Fan.CLIMATE_FAN_LOW },
  supports_two_point_target_temperature = false,
}

--------------------------------------------------------------------------------
T.section("a zero-valued enum really is absent after the round trip")
--------------------------------------------------------------------------------

-- The premise the rest of the file rests on. Asserted rather than assumed,
-- because if the decoder ever defaults these the tests below pass vacuously.
local offDecoded = fromWire({
  key = 1234,
  mode = Mode.CLIMATE_MODE_OFF,
  action = Action.CLIMATE_ACTION_OFF,
  fan_mode = Fan.CLIMATE_FAN_ON,
  current_temperature = 0,
  current_humidity = 0,
})
T.eq("an OFF mode decodes to nil, not 0", offDecoded.mode, nil)
T.eq("an OFF action decodes to nil, not 0", offDecoded.action, nil)
T.eq("an On fan mode decodes to nil, not 0", offDecoded.fan_mode, nil)
T.eq("a 0 C reading decodes to nil, not 0", offDecoded.current_temperature, nil)
T.eq("a 0% reading decodes to nil, not 0", offDecoded.current_humidity, nil)

local sentDecoded = fromWire({ key = 1234, mode = Mode.CLIMATE_MODE_COOL, current_temperature = 27.5 })
T.eq("a non-zero mode does arrive", sentDecoded.mode, Mode.CLIMATE_MODE_COOL)
T.eq("a non-zero reading does arrive", sentDecoded.current_temperature, 27.5)

--------------------------------------------------------------------------------
T.section("cool -> off, the reported cycle")
--------------------------------------------------------------------------------

local handler = newHandler()

-- Cooling: every field is non-zero, so every field is on the wire. This is the
-- direction that already worked, and it is the control for the one that did not.
drive(handler, ENTITY, {
  key = 1234,
  mode = Mode.CLIMATE_MODE_COOL,
  current_temperature = 27.5,
  target_temperature = 26.5,
  action = Action.CLIMATE_ACTION_COOLING,
  fan_mode = Fan.CLIMATE_FAN_LOW,
})
T.eq("cool is reported as Cool", (lastParams("HVAC_MODE_CHANGED") or {}).MODE, "Cool")
T.eq("cooling is reported as Cooling", (lastParams("HVAC_STATE_CHANGED") or {}).STATE, "Cooling")

-- Off: mode and action hold zero, so ESPHome sends neither. Before #119 this
-- update carried no HVAC_MODE_CHANGED at all and the proxy stayed on Cool.
drive(handler, ENTITY, {
  key = 1234,
  mode = Mode.CLIMATE_MODE_OFF,
  action = Action.CLIMATE_ACTION_OFF,
  current_temperature = 27.5,
  target_temperature = 26.5,
  fan_mode = Fan.CLIMATE_FAN_LOW,
})
T.eq("off is reported as Off", (lastParams("HVAC_MODE_CHANGED") or {}).MODE, "Off")
T.eq("an off action is reported as Off", (lastParams("HVAC_STATE_CHANGED") or {}).STATE, "Off")

--------------------------------------------------------------------------------
T.section("fan mode, whose zero value is CLIMATE_FAN_ON")
--------------------------------------------------------------------------------

drive(handler, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, fan_mode = Fan.CLIMATE_FAN_LOW })
T.eq("a low fan is reported as Low", (lastParams("FAN_MODE_CHANGED") or {}).MODE, "Low")

drive(handler, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, fan_mode = Fan.CLIMATE_FAN_ON })
T.eq("an On fan mode is reported as On", (lastParams("FAN_MODE_CHANGED") or {}).MODE, "On")

-- ESPHome also omits fan_mode when the unit has none set, so on a unit that
-- does not offer On a missing one is not On. The reporter's unit is this shape.
local noOn = {
  key = 1234,
  supported_modes = { Mode.CLIMATE_MODE_OFF, Mode.CLIMATE_MODE_COOL },
  supported_fan_modes = { Fan.CLIMATE_FAN_AUTO, Fan.CLIMATE_FAN_LOW, Fan.CLIMATE_FAN_MEDIUM, Fan.CLIMATE_FAN_HIGH },
}
drive(handler, noOn, { key = 1234, mode = Mode.CLIMATE_MODE_COOL })
T.eq("the handler ran for a unit without On", (lastParams("HVAC_MODE_CHANGED") or {}).MODE, "Cool")
T.eq("a unit without On is not reported as On", lastParams("FAN_MODE_CHANGED"), nil)

-- A custom fan mode still wins: it is a non-empty string, so it is on the wire.
drive(handler, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, custom_fan_mode = "Turbo" })
T.eq("a custom fan mode still takes precedence", (lastParams("FAN_MODE_CHANGED") or {}).MODE, "Turbo")

--------------------------------------------------------------------------------
T.section("readings of exactly zero")
--------------------------------------------------------------------------------

drive(handler, ENTITY, {
  key = 1234,
  mode = Mode.CLIMATE_MODE_COOL,
  current_temperature = 0,
  current_humidity = 0,
  target_humidity = 0,
})
T.eq("a 0 C reading is reported", (lastParams("TEMPERATURE_CHANGED") or {}).TEMPERATURE, "0")
T.eq("a 0% humidity is reported", (lastParams("HUMIDITY_CHANGED") or {}).HUMIDITY, "0")
T.eq("a 0% humidity setpoint is reported", (lastParams("HUMIDIFY_SETPOINT_CHANGED") or {}).SETPOINT, "0")

-- Setpoints are left alone: the water heater path clears a sentinel target to
-- nil to mean unset, so a missing setpoint must stay missing.
T.eq("no cool setpoint is invented", lastParams("COOL_SETPOINT_CHANGED"), nil)
T.eq("no heat setpoint is invented", lastParams("HEAT_SETPOINT_CHANGED"), nil)

--------------------------------------------------------------------------------
T.section("a device that does not advertise the field reports nothing for it")
--------------------------------------------------------------------------------

-- The default is per-field on purpose. Reading an absent action as Off on a
-- device that never reports one would invent a state the device does not have,
-- and the same for a fan mode on a device with no fan control.
local bare = {
  key = 1234,
  supported_modes = { Mode.CLIMATE_MODE_OFF, Mode.CLIMATE_MODE_HEAT },
  supports_action = false,
  supported_fan_modes = {},
  supports_two_point_target_temperature = false,
}

drive(handler, bare, { key = 1234, current_temperature = 21.0, target_temperature = 22.0 })
T.eq("mode is still reported", (lastParams("HVAC_MODE_CHANGED") or {}).MODE, "Off")
T.eq("no HVAC state is invented", lastParams("HVAC_STATE_CHANGED"), nil)
T.eq("no fan mode is invented", lastParams("FAN_MODE_CHANGED"), nil)

drive(handler, bare, { key = 1234, mode = Mode.CLIMATE_MODE_HEAT })
T.eq("the handler ran with no readings", (lastParams("HVAC_MODE_CHANGED") or {}).MODE, "Heat")
T.eq("no temperature is invented", lastParams("TEMPERATURE_CHANGED"), nil)
T.eq("no humidity is invented", lastParams("HUMIDITY_CHANGED"), nil)
T.eq("no humidity setpoint is invented", lastParams("HUMIDIFY_SETPOINT_CHANGED"), nil)

T.finish()
