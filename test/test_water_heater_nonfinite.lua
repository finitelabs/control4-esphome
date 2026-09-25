-- A non-finite water heater target must not reach the thermostatV2 sub-driver
-- as a setpoint.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_water_heater_nonfinite.lua
--
-- ESPHome sends a float for every target a unit declares, and an unset one
-- arrives as NaN on current firmware and as a ~1e38 sentinel on older builds.
-- The strip compared only `> 1e10`, which is false for NaN and for -inf, so
-- those two crossed to the sub-driver and were rendered as a setpoint.
--
-- Part of DRV-122, site 1.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local persist = require("lib.persist")
local store = {}
persist.get = function(_, k, d)
  local v = store[k]
  if v == nil then
    return d
  end
  return v
end
persist.set = function(_, k, v)
  store[k] = v
end
persist.delete = function(_, k)
  store[k] = nil
end

local log = require("lib.logging")
for _, m in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  if type(log[m]) == "function" then
    log[m] = function() end
  end
end

local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")

_G.RFP = _G.RFP or {}

local NAN = 0 / 0
local INF = math.huge
local SENTINEL = 1e38

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

local src = readFile(root .. "/src/esphome/entities/water_heater.lua")
T.check("the water_heater source was read", src ~= nil, "missing")

--------------------------------------------------------------------------------
T.section("premises the rest of the file rests on")
--------------------------------------------------------------------------------

-- If SerializeSafe dropped a NaN, "no setpoint crossed" would pass for the wrong
-- reason and the reverted arm below could not fail.
local round = DeserializeSafe(SerializeSafe({ a = NAN, b = -INF, c = INF, d = SENTINEL }))
T.check("a NaN survives the SerializeSafe hop", round.a ~= round.a, tostring(round.a))
T.eq("a -inf survives the SerializeSafe hop", round.b, -INF)
T.eq("an +inf survives the SerializeSafe hop", round.c, INF)
T.eq("the old-firmware sentinel survives the SerializeSafe hop", round.d, SENTINEL)

-- Why NaN and -inf are the cases that discriminate, and +inf and the sentinel
-- are not: the old guard caught the latter two on its own.
T.eq("the old guard did not catch a NaN", NAN > 1e10, false)
T.eq("the old guard did not catch a -inf", -INF > 1e10, false)
T.eq("the old guard did catch an +inf", INF > 1e10, true)
T.eq("the old guard did catch the sentinel", SENTINEL > 1e10, true)

--------------------------------------------------------------------------------
T.section("loading the entity, and the same entity with the fix reverted")
--------------------------------------------------------------------------------

--- Replace `from` with `to`, and fail rather than return the original when the
--- source no longer holds exactly one copy. A silent no-op here would leave the
--- reverted arm running the fixed code and passing.
--- @return string|nil
local function replaceOnce(text, from, to)
  local i, j = text:find(from, 1, true)
  if i == nil or text:find(from, j + 1, true) ~= nil then
    return nil
  end
  return text:sub(1, i - 1) .. to .. text:sub(j + 1)
end

local REVERTS = {
  {
    field = "target_temperature",
    fixed = "local target = tofinite(state.target_temperature)\n  if target == nil or target > 1e10 then",
    prefix = "if state.target_temperature and state.target_temperature > 1e10 then",
  },
  {
    field = "target_temperature_high",
    fixed = "local targetHigh = tofinite(state.target_temperature_high)\n  if targetHigh == nil or targetHigh > 1e10 then",
    prefix = "if state.target_temperature_high and state.target_temperature_high > 1e10 then",
  },
  {
    field = "target_temperature_low",
    fixed = "local targetLow = tofinite(state.target_temperature_low)\n  if targetLow == nil or targetLow > 1e10 then",
    prefix = "if state.target_temperature_low and state.target_temperature_low > 1e10 then",
  },
}

local reverted = src
for _, r in ipairs(REVERTS) do
  local next_ = reverted and replaceOnce(reverted, r.fixed, r.prefix)
  T.check("the " .. r.field .. " strip was reverted", next_ ~= nil, "no unique match")
  reverted = next_ or reverted
end
T.check("reverting changed the source", reverted ~= src, "identical")
T.check("no tofinite survives in the reverted source", not reverted:find("tofinite", 1, true), "still there")

local function loadEntity(text, chunkName)
  local chunk = loadstring(text, chunkName)
  T.check(chunkName .. " compiles", chunk ~= nil, "it did not compile")
  return chunk and chunk() or nil
end

local Fixed = loadEntity(src, "=water_heater.fixed")
local Reverted = loadEntity(reverted, "=water_heater.reverted")

--------------------------------------------------------------------------------
T.section("driving a state through the entity")
--------------------------------------------------------------------------------

local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams, strMessage)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams, message = strMessage })
end

local nextKey = 7700

--- Register the dynamic binding `discovered` would have created, then hand the
--- state to `updated` and return the state the sub-driver actually received.
--- @return table|nil state, boolean sent
local function drive(Entity, state)
  nextKey = nextKey + 1
  local entity = { key = nextKey, ref = tostring(nextKey), is_water_heater = true, name = "WH" }
  assert(
    bindings:getOrAddDynamicBinding(Entity.TYPE, "water_heater_" .. entity.ref, "PROXY", true, "WH", "ESPHOME_CLIMATE")
  )
  state.key = entity.key
  sends = {}
  Entity:new({
    getDeviceName = function()
      return "dev"
    end,
  }):updated(entity, state)
  for i = #sends, 1, -1 do
    if sends[i].command == "UPDATE_STATE" then
      return DeserializeSafe(Select(sends[i].params, "state")), true
    end
  end
  return nil, false
end

T.eq("the entity type is the one bindings were registered under", Fixed.TYPE, ESPHomeClient.EntityType.WATER_HEATER)

-- Positive control: the harness can see a target that is supposed to cross.
local ok = drive(Fixed, { target_temperature = 48.5, target_temperature_low = 40.0, target_temperature_high = 60.0 })
T.check("a state reaches the sub-driver at all", ok ~= nil, "nothing was sent")
T.eq("a finite target crosses unchanged", (ok or {}).target_temperature, 48.5)
T.eq("a finite low target crosses unchanged", (ok or {}).target_temperature_low, 40.0)
T.eq("a finite high target crosses unchanged", (ok or {}).target_temperature_high, 60.0)

--------------------------------------------------------------------------------
T.section("fixed: every non-finite target is stripped")
--------------------------------------------------------------------------------

local CASES = {
  { name = "NaN", value = NAN, discriminates = true },
  { name = "-inf", value = -INF, discriminates = true },
  { name = "+inf", value = INF, discriminates = false },
  { name = "the 1e38 sentinel", value = SENTINEL, discriminates = false },
}

local FIELDS = { "target_temperature", "target_temperature_low", "target_temperature_high" }

for _, case in ipairs(CASES) do
  for _, field in ipairs(FIELDS) do
    local state = drive(Fixed, { [field] = case.value })
    T.eq(string.format("%s is stripped from %s", case.name, field), (state or {})[field], nil)
  end
end

-- A target the unit never sent must stay absent rather than become a number.
local absent = drive(Fixed, { current_temperature = 21.0 })
T.eq("an absent target stays absent", (absent or {}).target_temperature, nil)
T.eq("an absent low target stays absent", (absent or {}).target_temperature_low, nil)
T.eq("an absent high target stays absent", (absent or {}).target_temperature_high, nil)
T.eq("the rest of the state is untouched", (absent or {}).current_temperature, 21.0)

--------------------------------------------------------------------------------
T.section("reverted: the two the old guard missed cross again")
--------------------------------------------------------------------------------

-- This is what makes the assertions above discriminate rather than pass for an
-- unrelated reason. +inf and the sentinel are kept as coverage of the class,
-- but only NaN and -inf can fail here, because `> 1e10` already caught the
-- other two.
for _, case in ipairs(CASES) do
  for _, field in ipairs(FIELDS) do
    local state = drive(Reverted, { [field] = case.value })
    local got = (state or {})[field]
    if case.discriminates then
      T.check(
        string.format("reverted, %s crosses in %s", case.name, field),
        got ~= nil,
        "it was stripped, so the fixed arm above proves nothing"
      )
    else
      T.eq(string.format("reverted, %s is still stripped from %s (class coverage only)", case.name, field), got, nil)
    end
  end
end

local revertedOk = drive(Reverted, { target_temperature = 48.5 })
T.eq("reverted, a finite target still crosses", (revertedOk or {}).target_temperature, 48.5)

T.finish()
