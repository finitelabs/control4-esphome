-- Tests that esphome_climate reports the modes whose ESPHome enum value is zero.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_climate_zero_enum_state.lua
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
-- CLIMATE_ACTION_OFF and CLIMATE_FAN_ON are zero for the same reason.
--
-- Driving the real wire bytes through the real decoder is the point: a test that
-- handed UPDATE_STATE a hand-built `{ mode = nil }` table would assert the fix
-- against the harness's own idea of what ESPHome omits.
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

local PIECES = {
  { what = "CLIMATE_MODE_TO_C4", text = cutTable("CLIMATE_MODE_TO_C4") },
  { what = "CLIMATE_ACTION_TO_C4", text = cutTable("CLIMATE_ACTION_TO_C4") },
  { what = "CLIMATE_FAN_MODE_TO_C4", text = cutTable("CLIMATE_FAN_MODE_TO_C4") },
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
  (PIECES[4].text or ""):find("HVAC_MODE_CHANGED", 1, true) ~= nil,
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

--- Encode a ClimateStateResponse, decode it back, and hand it to UPDATE_STATE
--- the way entities/climate.lua does.
---
--- Fields left out of `state` are exactly the ones ESPHome omits when they hold
--- the type's zero, so the round trip reproduces the wire faithfully.
local function drive(handler, entity, state)
  local wire = pb.encode(ESPHomeProtoSchema, ClimateState, state)
  local decoded = pb.decode(ESPHomeProtoSchema, ClimateState, wire)
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
  supported_fan_modes = { Fan.CLIMATE_FAN_ON, Fan.CLIMATE_FAN_LOW },
  supports_two_point_target_temperature = false,
}

--------------------------------------------------------------------------------
T.section("a zero-valued enum really is absent after the round trip")
--------------------------------------------------------------------------------

-- The premise the rest of the file rests on. Asserted rather than assumed,
-- because if the decoder ever defaults these the tests below pass vacuously.
local offWire = pb.encode(ESPHomeProtoSchema, ClimateState, {
  key = 1234,
  current_temperature = 27.5,
  target_temperature = 26.5,
  fan_mode = Fan.CLIMATE_FAN_LOW,
})
local offDecoded = pb.decode(ESPHomeProtoSchema, ClimateState, offWire)
T.eq("an omitted mode decodes to nil, not 0", offDecoded.mode, nil)
T.eq("an omitted action decodes to nil, not 0", offDecoded.action, nil)

local coolDecoded = pb.decode(
  ESPHomeProtoSchema,
  ClimateState,
  pb.encode(ESPHomeProtoSchema, ClimateState, { key = 1234, mode = Mode.CLIMATE_MODE_COOL })
)
T.eq("a non-zero mode does arrive", coolDecoded.mode, Mode.CLIMATE_MODE_COOL)

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

drive(handler, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL })
T.eq("an omitted fan mode is reported as On", (lastParams("FAN_MODE_CHANGED") or {}).MODE, "On")

-- A custom fan mode still wins: it is a non-empty string, so it is on the wire.
drive(handler, ENTITY, { key = 1234, mode = Mode.CLIMATE_MODE_COOL, custom_fan_mode = "Turbo" })
T.eq("a custom fan mode still takes precedence", (lastParams("FAN_MODE_CHANGED") or {}).MODE, "Turbo")

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

T.finish()
