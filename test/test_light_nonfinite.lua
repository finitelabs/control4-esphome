-- A light reporting a non-finite brightness must fall back, not hand the NaN to
-- the light library.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_light_nonfinite.lua
--
-- ESPHome sends NaN for the brightness of a light that has not reported one, and
-- protobuf v0.6.9 decodes it as a real NaN. `tonumber(x) or 1.0` does not fall
-- back for a NaN, and the library drops a report with a non-finite value whole,
-- so the light would never show its state.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local NAN = 0 / 0
local ColorMode = require("esphome.proto_schema").Enum.ColorMode

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local ESPHOME_BINDING = 1

local fh = io.open(root .. "/src/esphome/light_adapter.lua", "r")
local adapterSrc = fh and fh:read("*a")
if fh then
  fh:close()
end
T.check("the light adapter's source was read", adapterSrc ~= nil, "missing")

--- Load the light adapter from its source.
--- @param source string The adapter's source.
--- @return table LightAdapter
local function loadAdapter(source)
  local chunk, err = loadstring(source, "light_adapter")
  T.check("the adapter compiles", chunk ~= nil, err)
  return chunk()
end

local LightAdapter = loadAdapter(adapterSrc)

--- Report a state once through the real SerializeSafe hop the ESPHome bridge driver uses.
--- @param Adapter table The adapter module.
--- @param state table The entity state as ESPHome reported it.
--- @return LightReport report What the adapter hands the library.
local function drive(Adapter, state)
  local adapter = Adapter.new(ESPHOME_BINDING)
  local entity = { key = 91, name = "Hall Light", supported_color_modes = { ColorMode.COLOR_MODE_BRIGHTNESS } }
  adapter:learn(entity)
  return adapter:report(DeserializeSafe(SerializeSafe(entity)), DeserializeSafe(SerializeSafe(state)))
end

--------------------------------------------------------------------------------
T.section("the NaN survives the hop into the adapter")
--------------------------------------------------------------------------------

-- Without this the brightness assertions could pass because the NaN never
-- arrived, rather than because the adapter rejected it.
local roundTripped = DeserializeSafe(SerializeSafe({ brightness = NAN, state = true }))
T.check("SerializeSafe carries a NaN brightness", roundTripped.brightness ~= roundTripped.brightness)

--------------------------------------------------------------------------------
T.section("a non-finite brightness falls back instead of reaching the library")
--------------------------------------------------------------------------------

local nanLevel = drive(LightAdapter, { state = true, brightness = NAN }).level
T.check("a NaN brightness is not reported", nanLevel == nanLevel, "reported " .. tostring(nanLevel))
T.eq("it falls back to full brightness", nanLevel, 1.0)
T.eq("infinity falls back the same way", drive(LightAdapter, { state = true, brightness = math.huge }).level, 1.0)

--------------------------------------------------------------------------------
T.section("a finite brightness is still reported as measured")
--------------------------------------------------------------------------------

-- Without these the fix could report every light at full and still pass above.
T.eq("42 percent", drive(LightAdapter, { state = true, brightness = 0.42 }).level, 0.42)
T.eq("full", drive(LightAdapter, { state = true, brightness = 1.0 }).level, 1.0)
T.eq("an absent brightness assumes full", drive(LightAdapter, { state = true }).level, 1.0)
local off = drive(LightAdapter, { state = false, brightness = 0.42 })
T.eq("an off light reports off, with no level", { off.on, off.level }, { false, nil })

--------------------------------------------------------------------------------
T.section("reverting the fix puts the NaN case back")
--------------------------------------------------------------------------------

-- Reverts the adapter's `tofinite` to the `tonumber` the fix replaced, so the
-- assertions above are shown to fail against the pre-fix source rather than
-- passing for some unrelated reason.
local revertedSrc, swaps =
  adapterSrc:gsub('tofinite%(Select%(state, "brightness"%)%)', 'tonumber(Select(state, "brightness"))')
T.eq("the revert replaced exactly one call", swaps, 1)
local reverted = loadAdapter(revertedSrc)

local revertedLevel = drive(reverted, { state = true, brightness = NAN }).level
T.check("the reverted source reports a NaN", revertedLevel ~= revertedLevel, "reported " .. tostring(revertedLevel))
T.eq("and still agrees on a finite brightness", drive(reverted, { state = true, brightness = 0.42 }).level, 0.42)

T.finish()
