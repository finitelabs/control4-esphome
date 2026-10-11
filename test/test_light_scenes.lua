--- A light's scenes and ramps beside direct commands: what the driver tells the proxy and
--- sends the device when a scene, a level command and a color command overlap.
---
--- Driven through the esphome_light driver's RFP entry points on a virtual clock, with
--- SendToProxy captured. No device answers, so every notify here is the driver's own.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_light_scenes.lua

local T = require("testlib")

require("c4_shim")

local ColorMode = require("esphome.proto_schema").Enum.ColorMode
local persist = require("lib.persist")

-- Resolved against this file: make test runs from the repo root, run_test.sh from test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/esphome_light/driver.lua"

local PROXY, ESPHOME = 5001, 5002

---------------------------------------------------------------------------
-- Virtual clock: the shim's timers have no clock to order by, and a scene's step
-- and a command's ramp end at different times.
---------------------------------------------------------------------------

local now = 1000000
local queue, order = {}, 0

function C4:GetTime()
  return now
end

function C4:SetTimer(delayMs, callback)
  order = order + 1
  local t = { at = now + delayMs, order = order }
  local handle = newproxy(true)
  getmetatable(handle).__index = {
    Cancel = function()
      t.cancelled = true
    end,
  }
  t.fn = function()
    callback(handle, 0)
  end
  queue[#queue + 1] = t
  return handle
end

--- Run everything due within the next `ms`, in the order it falls due.
local function run(ms)
  local stop = now + ms
  while true do
    local best, bi
    for i, t in ipairs(queue) do
      if
        not t.cancelled
        and t.at <= stop
        and (not best or t.at < best.at or (t.at == best.at and t.order < best.order))
      then
        best, bi = t, i
      end
    end
    if not best then
      break
    end
    table.remove(queue, bi)
    now = best.at
    best.fn()
  end
  now = stop
end

---------------------------------------------------------------------------
-- The light, and what it tells the proxy and sends the device
---------------------------------------------------------------------------

Properties["Driver Status"] = ""
Properties["Driver Version"] = ""

local sent, start = {}, now

--- Count what the proxy is told and the device is sent from here.
local function mark()
  sent, start = {}, now
end

--- A fresh light, on at full unless `on` is false: its state lives in the driver chunk's
--- locals, and its Color On Mode in the process-wide store.
--- @param modes table The entity's supported_color_modes.
local function light(modes, on)
  queue = {}
  for _, key in ipairs({ "color_on_mode", "color_presets", "previous_color" }) do
    persist:delete(key)
  end
  dofile(DRIVER)
  function SendToProxy(idBinding, strCommand, tParams)
    sent[#sent + 1] = { at = now - start, binding = idBinding, command = strCommand, params = tParams or {} }
  end
  RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
    entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = modes }),
    state = SerializeSafe({ state = on ~= false, brightness = 1.0 }),
  })
  mark()
end

--- Send the driver a LIGHT_V2 proxy command, as the proxy does.
local function proxy(command, params)
  RFP[command](PROXY, command, params or {})
end

--- Activate a scene of `elements`, and count what follows from here.
local function activate(elements)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = elements })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
end

--- Every `field` the proxy was sent with `command` since the mark, or the ms after it for "at".
local function told(command, field)
  local out = {}
  for _, s in ipairs(sent) do
    if s.binding == PROXY and s.command == command then
      out[#out + 1] = field == "at" and s.at or s.params[field]
    end
  end
  return out
end

--- How many commands the device was sent since the mark.
local function commands()
  local count = 0
  for _, s in ipairs(sent) do
    if s.binding == ESPHOME and s.command == "ENTITY_COMMAND" then
      count = count + 1
    end
  end
  return count
end

--- A scene element that sets a level over `rate` ms after `delay`: at once unless they are given.
local function levelStep(level, rate, delay)
  local step = "<element><delay>%d</delay><rate>%d</rate><brightnessEnabled>true</brightnessEnabled>"
    .. "<brightness>%d</brightness></element>"
  return step:format(delay or 0, rate or 0, level)
end

T.section("a flash scene with nothing to wait on runs its steps once, not forever")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("PUSH_SCENE", { SCENE_ID = 7, FLASH = "true", ELEMENTS = levelStep(30) .. levelStep(60) })
  mark()
  -- A scene that never stops sending fails here rather than running on.
  local send = SendToProxy
  function SendToProxy(...)
    assert(commands() < 50, "the scene is still sending")
    return send(...)
  end
  local ok, err = pcall(proxy, "ACTIVATE_SCENE", { SCENE_ID = 7 })
  SendToProxy = send
  T.check("it returns", ok, err)
  T.eq("having sent each step once", commands(), 2)
  proxy("CLEAR_ALL_SCENES")
end

T.finish()
