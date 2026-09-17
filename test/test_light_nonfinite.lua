-- A light reporting a non-finite brightness must fall back, not push the NaN to
-- the LIGHT_V2 proxy.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_light_nonfinite.lua
--
-- ESPHome sends NaN for the brightness of a light that has not reported one, and
-- protobuf v0.6.9 decodes it as a real NaN. `tonumber(x) or 1.0` does not fall
-- back for a NaN, and math.max(0, math.min(100, nan)) returns the NaN rather
-- than clamping it, so the NaN reached the proxy and, since nan ~= anything,
-- re-notified on every state message.
--
-- A driver.lua cannot be loaded far enough to reach its handlers, so
-- RFP.UPDATE_STATE is cut out of the source and compiled under a synthetic
-- environment. The driver's own arithmetic is what runs; only its collaborators
-- are supplied here.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local NAN = 0 / 0

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."

local ESPHOME_BINDING = 1
local PROXY_BINDING = 5001

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local src = readFile(root .. "/drivers/esphome_light/driver.lua")
T.check("the esphome_light source was read", src ~= nil, "missing")

local handlerSrc = src and src:match("\n(function RFP%.UPDATE_STATE%s*%b()\n.-\nend)\n")
T.check("RFP.UPDATE_STATE was cut out", handlerSrc ~= nil, "no match")

local function newLog()
  return setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
end

--- Compile a cut handler under a synthetic environment.
--- @param source string The handler source.
--- @return table env The environment, carrying RFP and the recorded calls.
local function compileHandler(source)
  local env = {
    RFP = {},
    log = newLog(),
    ESPHOME_BINDING = ESPHOME_BINDING,
    PROXY_BINDING = PROXY_BINDING,
    ENTITY = nil,
    STATE = nil,
    updateStatus = function() end,
    updateDynamicCapabilities = function() end,
    supportsDimming = true,
    supportsColor = false,
    supportsCCT = false,
    rampingColor = false,
    rampingBrightness = false,
    currentBrightness = -1,
    COLOR_MODES_SUPPORTING_CCT = {},
    COLOR_MODES_SUPPORTING_RGB = {},
    brightnessPushes = {},
    proxySends = {},
  }
  env.notifyBrightnessChanged = function(level)
    env.brightnessPushes[#env.brightnessPushes + 1] = level
  end
  env.SendToProxy = function(idBinding, strCommand, tParams)
    env.proxySends[#env.proxySends + 1] = { idBinding = idBinding, command = strCommand, params = tParams }
  end
  setmetatable(env, { __index = _G })

  local chunk, err = loadstring(source, "light_update_state")
  T.check("the cut handler compiles", chunk ~= nil, err)
  setfenv(chunk, env)
  chunk()
  return env
end

--- Drive UPDATE_STATE once with a brightness, through the real SerializeSafe hop
--- the ESPHome bridge driver uses.
--- @param env table A freshly compiled handler environment.
--- @param state table The entity state as ESPHome reported it.
--- @return number|nil level The brightness pushed to the proxy, if any.
local function drive(env, state)
  local entity = { key = 91, name = "Hall Light", supports_brightness = true }
  env.RFP.UPDATE_STATE(ESPHOME_BINDING, "UPDATE_STATE", {
    entity = SerializeSafe(entity),
    state = SerializeSafe(state),
  })
  return env.brightnessPushes[#env.brightnessPushes]
end

--------------------------------------------------------------------------------
T.section("the NaN survives the hop into the handler")
--------------------------------------------------------------------------------

-- Without this the brightness assertions could pass because the NaN never
-- arrived, rather than because the handler rejected it.
local roundTripped = DeserializeSafe(SerializeSafe({ brightness = NAN, state = true }))
T.check("SerializeSafe carries a NaN brightness", roundTripped.brightness ~= roundTripped.brightness)

--------------------------------------------------------------------------------
T.section("a non-finite brightness falls back instead of reaching the proxy")
--------------------------------------------------------------------------------

local nanLevel = drive(compileHandler(handlerSrc), { state = true, brightness = NAN })
T.check("a NaN brightness is not pushed", nanLevel == nanLevel, "pushed " .. tostring(nanLevel))
T.eq("it falls back to full brightness", nanLevel, 100)

-- Infinity reached 100 before the fix too, since math.min clamps it where it
-- returns a NaN unchanged. Kept as coverage of the class, but only the NaN case
-- above discriminates.
local infLevel = drive(compileHandler(handlerSrc), { state = true, brightness = math.huge })
T.eq("infinity falls back the same way", infLevel, 100)

--------------------------------------------------------------------------------
T.section("a finite brightness is still reported as measured")
--------------------------------------------------------------------------------

-- Without these the fix could report every light at 100 and still pass above.
T.eq("42 percent", drive(compileHandler(handlerSrc), { state = true, brightness = 0.42 }), 42)
T.eq("full", drive(compileHandler(handlerSrc), { state = true, brightness = 1.0 }), 100)
T.eq("rounds to the nearest percent", drive(compileHandler(handlerSrc), { state = true, brightness = 0.005 }), 1)
T.eq("an on light never reports zero", drive(compileHandler(handlerSrc), { state = true, brightness = 0 }), 1)
T.eq("an absent brightness assumes full", drive(compileHandler(handlerSrc), { state = true }), 100)
T.eq("an off light reports zero", drive(compileHandler(handlerSrc), { state = false, brightness = 0.42 }), 0)

--------------------------------------------------------------------------------
T.section("reverting the fix puts the NaN case back")
--------------------------------------------------------------------------------

-- Reverts `tofinite` to the `tonumber` the fix replaced, so the assertions above
-- are shown to fail against the pre-fix source rather than passing for some
-- unrelated reason.
local revertedSrc, swaps =
  handlerSrc:gsub('tofinite%(Select%(state, "brightness"%)%)', 'tonumber(Select(state, "brightness"))')
T.eq("the revert replaced exactly one call", swaps, 1)

local revertedLevel = drive(compileHandler(revertedSrc), { state = true, brightness = NAN })
T.check("the reverted source pushes a NaN", revertedLevel ~= revertedLevel, "pushed " .. tostring(revertedLevel))
T.eq(
  "and still agrees on a finite brightness",
  drive(compileHandler(revertedSrc), { state = true, brightness = 0.42 }),
  42
)

T.finish()
