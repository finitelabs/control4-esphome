-- Tests that a climate state field left off the wire is read as zero.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_climate_zero_fields.lua
--
-- Protobuf does not encode a field at its zero value, so a unit switched to
-- OFF (ClimateMode 0) sends a state with no mode at all. ESPHome writes mode
-- and action on every update, and current temperature and humidity whenever
-- the entity reports them, so a missing one is zero rather than unchanged.
-- Reading it as unchanged left the thermostat showing Cool after the unit was
-- turned off at its own remote.
--
-- RFP.UPDATE_STATE and its helpers are cut out of the driver source and run
-- against a stub environment, as in test_button_link_protocol.lua, since a
-- driver.lua cannot be loaded far enough to reach them.
--
-- Regression test for issue 119.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local ESPHomeProtoSchema = require("esphome.proto_schema")
local ClimateMode = ESPHomeProtoSchema.Enum.ClimateMode

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams or {} })
end

--- The params of every send of `command`, in order.
local function sent(command)
  local out = {}
  for _, send in ipairs(sends) do
    if send.command == command then
      table.insert(out, send.params)
    end
  end
  return out
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
T.check("the climate source was read", src ~= nil, "missing")
src = src or ""

--- Cut a top-level function out of the source. Its closing `end` is the only
--- one at column zero, since everything inside is indented.
local function cut(pattern)
  return src:match("\n(" .. pattern .. ".-\nend)\n")
end

local stateNumberText = cut("local function stateNumber%s*%b()")
local modeMapText = src:match("\n(local CLIMATE_MODE_TO_C4 = %b{})")
local actionMapText = src:match("\n(local CLIMATE_ACTION_TO_C4 = %b{})")
local updateText = cut("function RFP%.UPDATE_STATE%s*%b()")

T.check("stateNumber was cut out", stateNumberText ~= nil, "no match")
T.check("the mode map was cut out", modeMapText ~= nil, "no match")
T.check("the action map was cut out", actionMapText ~= nil, "no match")
T.check("UPDATE_STATE was cut out", updateText ~= nil, "no match")

local noop = function() end
local env = setmetatable({
  ESPHomeProtoSchema = ESPHomeProtoSchema,
  ESPHOME_BINDING = 5002,
  PROXY_BINDING = 5001,
  TEMPERATURE_OUTPUT_BINDING = 5003,
  HUMIDITY_OUTPUT_BINDING = 5004,
  SCALE = "C",
  CAPABILITIES_SENT = true,
  IS_SINGLE_SETPOINT = false,
  CLIMATE_FAN_MODE_TO_C4 = {},
  C4_TO_WATER_HEATER_MODE = {},
  log = setmetatable({}, {
    __index = function()
      return noop
    end,
  }),
  persist = { set = noop },
  updateStatus = noop,
  sendConnectionState = noop,
  sendCapabilities = noop,
  sendDisplayScale = noop,
}, { __index = _G })

-- One chunk, so the maps and stateNumber are upvalues of UPDATE_STATE exactly
-- as they are in the driver.
local chunk = loadstring(
  table.concat({ modeMapText or "", actionMapText or "", stateNumberText or "", updateText or "" }, "\n"),
  "=climate"
)
T.check("the cut source compiles", chunk ~= nil, "did not compile")
if not chunk then
  T.finish()
end
env.RFP = {}
setfenv(chunk, env)
chunk()

local function update(entity, state)
  sends = {}
  env.RFP.UPDATE_STATE(5002, "UPDATE_STATE", {
    entity = SerializeSafe(entity),
    state = SerializeSafe(state),
  })
end

local MODES = { ClimateMode.CLIMATE_MODE_OFF, ClimateMode.CLIMATE_MODE_COOL }

-- A unit that reports nothing optional. Not an empty table: the handler rejects
-- an empty entity or state outright, which would pass every "sends nothing"
-- case below without reaching the code under test.
local BARE_UNIT = { supported_modes = MODES }

local COOLING_UNIT = {
  supports_current_temperature = true,
  supports_action = true,
  supported_modes = MODES,
}

--------------------------------------------------------------------------------
T.section("mode")
--------------------------------------------------------------------------------

update(COOLING_UNIT, { mode = ClimateMode.CLIMATE_MODE_COOL, action = 2, current_temperature = 27 })
T.eq("a present mode is reported", (sent("HVAC_MODE_CHANGED")[1] or {}).MODE, "Cool")

-- The regression: the unit turned off at its own remote.
update(COOLING_UNIT, { current_temperature = 27 })
T.eq("a missing mode is Off", (sent("HVAC_MODE_CHANGED")[1] or {}).MODE, "Off")

--------------------------------------------------------------------------------
T.section("action")
--------------------------------------------------------------------------------

update(COOLING_UNIT, { current_temperature = 27 })
T.eq("a missing action is Off when the unit reports action", (sent("HVAC_STATE_CHANGED")[1] or {}).STATE, "Off")

-- ESPHome writes action even for a unit that never tracks it, where it is
-- always zero, so without the support check every such unit would read Off.
update(BARE_UNIT, { current_temperature = 27 })
T.eq("the handler ran without action", (sent("HVAC_MODE_CHANGED")[1] or {}).MODE, "Off")
T.eq("a unit that does not report action sends no state", #sent("HVAC_STATE_CHANGED"), 0)

--------------------------------------------------------------------------------
T.section("readings")
--------------------------------------------------------------------------------

update(COOLING_UNIT, { mode = ClimateMode.CLIMATE_MODE_COOL })
T.eq("a missing current temperature is 0", (sent("TEMPERATURE_CHANGED")[1] or {}).TEMPERATURE, "0")

local cool = { mode = ClimateMode.CLIMATE_MODE_COOL }

update(BARE_UNIT, cool)
T.eq("the handler ran for the bare unit", (sent("HVAC_MODE_CHANGED")[1] or {}).MODE, "Cool")
T.eq("no temperature is sent for a unit without a sensor", #sent("TEMPERATURE_CHANGED"), 0)
T.eq("no humidity is sent for a unit without it", #sent("HUMIDITY_CHANGED"), 0)

update({ supported_modes = MODES, supports_current_humidity = true, supports_target_humidity = true }, cool)
T.eq("a missing current humidity is 0", (sent("HUMIDITY_CHANGED")[1] or {}).HUMIDITY, "0")
T.eq("a missing target humidity is 0", (sent("HUMIDIFY_SETPOINT_CHANGED")[1] or {}).SETPOINT, "0")

--------------------------------------------------------------------------------
T.section("setpoints are left alone")
--------------------------------------------------------------------------------

-- The water heater path clears a sentinel target to nil to mean unset, so a
-- missing setpoint must stay missing.
update(COOLING_UNIT, { mode = ClimateMode.CLIMATE_MODE_COOL })
T.eq("no cool setpoint without a target", #sent("COOL_SETPOINT_CHANGED"), 0)
T.eq("no heat setpoint without a target", #sent("HEAT_SETPOINT_CHANGED"), 0)

T.finish()
