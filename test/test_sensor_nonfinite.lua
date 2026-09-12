-- A non-finite reading must not reach a C4 variable, the push memo, or a proxy.
--
-- ESPHome reports NaN for any float an entity has not measured yet, and sets
-- missing_state on the same message. Before protobuf v0.6.9 that NaN decoded as
-- ~5.1e38, so tonumber() produced a finite number and the old `or 0` fallback
-- never fired; with a correct decoder it is a real NaN, and NaN ~= NaN made both
-- the persisted-value change check and the lastPushed memo compare false on
-- every message.

require("c4_shim")
local T = require("testlib")

local SensorEntity = require("esphome.entities.sensor")
local NumberEntity = require("esphome.entities.number")
local values = require("lib.values")

local NAN = 0 / 0
local INF = math.huge

--- Record proxy pushes. Stubs the C4 method rather than the SendToProxy global
--- so the driver's own parameter handling still runs.
--- @return table pushes, function restore
local function captureProxy()
  local pushes = {}
  local real = C4.SendToProxy
  C4.SendToProxy = function(_, idBinding, strCommand, tParams)
    pushes[#pushes + 1] = { bindingId = idBinding, command = strCommand, params = tParams }
  end
  return pushes, function()
    C4.SendToProxy = real
  end
end

--- Record every variable create/assign the driver makes.
--- @return table writes, function restore
local function captureVariableWrites()
  local writes = {}
  local realAdd, realSet = C4.AddVariable, C4.SetVariable
  C4.AddVariable = function(self, name, value, varType, readOnly, hidden)
    writes[#writes + 1] = { name = name, value = value, how = "add", readOnly = readOnly }
    return realAdd(self, name, value, varType, readOnly, hidden)
  end
  C4.SetVariable = function(self, name, value)
    writes[#writes + 1] = { name = name, value = value, how = "set" }
    return realSet(self, name, value)
  end
  return writes, function()
    C4.AddVariable, C4.SetVariable = realAdd, realSet
  end
end

--- A distinct entity per case, so no case inherits another's memo or variable.
local nextKey = 4200
local function sensorEntity(name, overrides)
  nextKey = nextKey + 1
  local entity = {
    key = nextKey,
    name = name,
    device_class = "temperature",
    unit_of_measurement = "°C",
  }
  for k, v in pairs(overrides or {}) do
    entity[k] = v
  end
  return entity
end

--- Drive `updated` `count` times with one reading, counting pushes and writes.
--- @return table result { pushes = table, writes = table, variable = any }
local function drive(item, entity, state, count, discover)
  SensorEntity.clearNotifiedState()
  local pushes, restoreProxy = captureProxy()
  local writes, restoreWrites = captureVariableWrites()
  if discover then
    item:discovered(entity)
  end
  for _ = 1, count do
    item:updated(entity, state)
  end
  restoreProxy()
  restoreWrites()
  return {
    pushes = pushes,
    writes = writes,
    variable = Variables[entity.name],
    persisted = values:getValue(entity.name),
  }
end

local sensor = SensorEntity:new({})
local number = NumberEntity:new({
  callServiceMethod = function()
    error("a non-finite reading must not command the device")
  end,
})

T.section("SensorEntity:updated drops a NaN reading")

local nanEntity = sensorEntity("Attic Temperature NaN")
local nan = drive(sensor, nanEntity, { key = nanEntity.key, state = NAN, missing_state = true }, 5, true)
T.eq("no proxy push for 5 NaN readings", #nan.pushes, 0)
T.eq("no variable write for 5 NaN readings", #nan.writes, 0)
T.eq("variable stays unset", nan.variable, nil)
T.eq("nothing persisted", nan.persisted, nil)

T.section("SensorEntity:updated still reports a finite reading")

local okEntity = sensorEntity("Attic Temperature Finite")
local ok = drive(sensor, okEntity, { key = okEntity.key, state = 21.5 }, 5, true)
T.eq("one proxy push for 5 identical finite readings", #ok.pushes, 1)
T.eq("pushed VALUE_CHANGED", ok.pushes[1] and ok.pushes[1].command, "VALUE_CHANGED")
T.eq("pushed the value", ok.pushes[1] and ok.pushes[1].params and ok.pushes[1].params.VALUE, 21.5)
T.eq("pushed the scale", ok.pushes[1] and ok.pushes[1].params and ok.pushes[1].params.SCALE, "CELSIUS")
T.eq("one variable write for 5 identical finite readings", #ok.writes, 1)
T.eq("variable holds the reading", tonumber(ok.variable), 21.5)

T.section("SensorEntity:updated drops infinity and a missing state")

local infEntity = sensorEntity("Attic Temperature Inf")
local inf = drive(sensor, infEntity, { key = infEntity.key, state = INF }, 3, true)
T.eq("no push for infinity", #inf.pushes, 0)
T.eq("no variable write for infinity", #inf.writes, 0)

local missingEntity = sensorEntity("Attic Temperature Missing")
local missing = drive(sensor, missingEntity, { key = missingEntity.key, state = 21.5, missing_state = true }, 3, true)
T.eq("no push when missing_state is set", #missing.pushes, 0)
T.eq("no variable write when missing_state is set", #missing.writes, 0)

T.section("NumberEntity:updated drops a NaN reading")

local numberNan = sensorEntity("Fan Speed NaN", { device_class = nil, unit_of_measurement = nil })
local numNan = drive(number, numberNan, { key = numberNan.key, state = NAN, missing_state = true }, 5, false)
T.eq("no variable write for 5 NaN readings", #numNan.writes, 0)
T.eq("variable stays unset", numNan.variable, nil)
T.eq("nothing persisted", numNan.persisted, nil)

T.section("NumberEntity:updated still reports a finite reading")

local numberOk = sensorEntity("Fan Speed Finite", { device_class = nil, unit_of_measurement = nil })
local numOk = drive(number, numberOk, { key = numberOk.key, state = 42 }, 5, false)
T.eq("one variable write for 5 identical finite readings", #numOk.writes, 1)
T.eq("variable holds the reading", tonumber(numOk.variable), 42)

T.section("NumberEntity:updated comes up writable on the first finite reading after NaN")

-- The early return skips values:update, and with it the setCallback that makes
-- the variable writable. That must delay writability, not forfeit it. Drop the
-- callback argument from the update call in number.lua and every number entity
-- is created read-only: writable is derived from _callbacks[name], and
-- setCallback only runs from inside update.
local numberLate = sensorEntity("Fan Speed Late", { device_class = nil, unit_of_measurement = nil })
local lateNan = drive(number, numberLate, { key = numberLate.key, state = NAN, missing_state = true }, 3, false)
T.eq("no variable while only NaN has been reported", #lateNan.writes, 0)

local lateOk = drive(number, numberLate, { key = numberLate.key, state = 42 }, 1, false)
T.eq("the first finite reading creates the variable", #lateOk.writes, 1)
T.eq("created rather than assigned", lateOk.writes[1] and lateOk.writes[1].how, "add")
T.eq("variable holds the reading", tonumber(lateOk.variable), 42)
T.eq("created writable, so AddVariable's readOnly is false", lateOk.writes[1] and lateOk.writes[1].readOnly, false)

--- The readOnly flag as C4 reports it back, rather than as the driver passed it.
local function readOnlyFlag(name)
  for _, variable in pairs(C4:GetDeviceVariables(C4:GetDeviceID())) do
    if variable.name == name then
      return variable.readonly
    end
  end
end
T.eq("C4 reports the variable as writable", readOnlyFlag(numberLate.name), "False")

T.finish()
