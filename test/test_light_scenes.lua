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

---------------------------------------------------------------------------
-- Color
---------------------------------------------------------------------------

-- xy as hue and saturation over their ranges: the shim has no color conversions.
function C4:ColorXYtoHSV(x, y)
  return x * 360, y * 100
end

-- The proxy's On Color preset, a Dim-To-Warm dim color, and a color to leave the light in (xy).
local ON, DIM, BLUE = { 0.6, 0.3, id = 1 }, { 0.14, 0.1 }, { 0.15, 0.06 }

--- Tell the driver its Color On Mode: an on preset and, for Dim-To-Warm, the dim color.
local function onMode(on, dim)
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = on.id,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = on[1],
    COLOR_PRESET_COLOR_Y = on[2],
    COLOR_PRESET_COLOR_MODE = 0,
    COLOR_FADE_PRESET_ID = dim and 2 or 0,
    COLOR_FADE_PRESET_ORIGIN = dim and 1 or 0,
    COLOR_FADE_PRESET_COLOR_X = dim and dim[1],
    COLOR_FADE_PRESET_COLOR_Y = dim and dim[2],
    COLOR_FADE_PRESET_COLOR_MODE = 0,
  })
end

--- Ask for a color (xy) over `rate` ms.
local function colorTarget(xy, rate)
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = xy[1], LIGHT_COLOR_TARGET_Y = xy[2], LIGHT_COLOR_TARGET_COLOR_RATE = rate }
  )
end

--- The red, green and blue of each command since the mark that carried a color.
local function colors()
  local out = {}
  for _, s in ipairs(sent) do
    local cmd = s.binding == ESPHOME and s.command == "ENTITY_COMMAND" and DeserializeSafe(s.params.body)
    if cmd and cmd.has_rgb then
      out[#out + 1] = { cmd.red, cmd.green, cmd.blue }
    end
  end
  return out
end

--- Set the light to a color at once, and return the red, green and blue it was sent as.
local function setColor(xy)
  mark()
  colorTarget(xy, 0)
  return colors()[1]
end

--- A color light that is off and left in blue, its Color On Mode the On color.
--- Returns the red, green and blue the On color is sent as.
local function offInBlue()
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON)
  local onColor = setColor(ON)
  setColor(BLUE)
  return onColor
end

T.section("a color the proxy sends with a rated on goes out, unless it is the On color the on carried")
do
  -- The proxy's Dynamic On: the level, then the On color the level command has already sent.
  offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(ON, 750)
  run(15000)
  T.eq("the On color goes out once", #colors(), 1)
  T.eq("and the proxy is told it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  -- Programming that ramps the light on and sets another color on the way.
  offInBlue()
  local asked = setColor({ 0.2, 0.5 })
  setColor(BLUE)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  colorTarget({ 0.2, 0.5 }, 1000)
  run(15000)
  local out = colors()
  T.eq("another color is the last the light is sent", out[#out], asked)
  T.eq("and the proxy is told it alone", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.2 })
end

--- The x of the Dim-To-Warm mix for a level, as the driver computes it.
local function mix(level)
  return DIM[1] + (ON[1] - DIM[1]) * (level * 0.01)
end

T.section("a rated on or dim that changes the color tells the proxy the color the light is leaving")
do
  offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  T.eq("a rated on: from the color it had", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
  T.eq("to the On color", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { ON[1] })
  run(15000)
  T.eq("which it is told at the ramp's end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  -- Dim-To-Warm at 100 %, where the mix is the On color.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  mark()
  proxy("RAMP_TO_LEVEL", { LEVEL = 10, TIME = 4000 })
  T.eq("a rated dim: from the On color", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  T.eq("to the mix for 10 %", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { mix(10) })
  run(15000)
end

--- A scene element that sets a color (xy) over `rate` ms, and a level unless it is nil.
local function colorStep(level, xy, rate)
  local brightness = "<brightnessEnabled>true</brightnessEnabled><brightness>%d</brightness>"
  local step = "<element><delay>0</delay><rate>%d</rate>%s<colorEnabled>true</colorEnabled><colorX>%s</colorX>"
    .. "<colorY>%s</colorY><colorMode>0</colorMode></element>"
  return step:format(rate, level and brightness:format(level) or "", xy[1], xy[2])
end

T.section(
  "a level set during a scene's fade, with Dim-To-Warm: the proxy is told the level's mix, never the scene's color"
)
do
  -- The level's mix replaces the scene's color at the bulb, so the scene's ramp has no end to tell.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(colorStep(60, { 0.3, 0.6 }, 3000))
  run(340)
  proxy("SET_LEVEL", { LEVEL = 2 })
  run(15000)
  T.eq(
    "the proxy is told the mix for 2 % and nothing else",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(2) }
  )
  proxy("CLEAR_ALL_SCENES")
end

T.section("an on during a color ramp begun while the light was off: the light ends in the On color")
do
  -- The on's On color goes out after the ramp's, which the ramp's end would then send again.
  local onColor = offInBlue()
  mark()
  colorTarget({ 0.3, 0.6 }, 3000)
  run(500)
  proxy("ON")
  run(15000)
  local out = colors()
  T.eq("the On color is the last the light is sent", out[#out], onColor)
  T.eq("and the last the proxy is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  -- A rated on a tenth into the ramp carries the On color from there to its own end.
  offInBlue()
  colorTarget({ 0.3, 0.6 }, 1000)
  run(100)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  local tenth = BLUE[1] + (0.3 - BLUE[1]) * (100 / 1000)
  T.eq(
    "a rated on: from a tenth of the way to the ramp's color",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { tenth }
  )
  run(15000)
  T.eq(
    "the proxy is then told the On color and nothing else",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )
  T.eq("at the on's end", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  -- With Dim-To-Warm a color lasts until the level next changes: a level set during its ramp carries the mix.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  mark()
  colorTarget({ 0.3, 0.6 }, 3000)
  run(500)
  proxy("SET_LEVEL", { LEVEL = 50 })
  run(15000)
  T.eq(
    "a level set in the ramp: the proxy is told the mix for 50 % and nothing else",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(50) }
  )
  T.eq("when the level is set, not at the ramp's end", told("LIGHT_COLOR_CHANGED", "at"), { 500 })
end

T.section("a level ramp begun during a scene's fade runs to its own end, not to the scene step's")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(levelStep(60, 3000))
  run(1500)
  proxy("RAMP_TO_LEVEL", { LEVEL = 10, TIME = 4000 })
  run(3900)
  T.eq("no LIGHT_BRIGHTNESS_CHANGED at the scene step's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), {})
  run(15000)
  T.eq("one for its level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 10 })
  T.eq("at its own ramp's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 5500 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a level command takes the light out of the scene: no later step runs")
do
  -- A second step, due 5 s after the first, would take the light to 20.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(levelStep(60, 3000) .. levelStep(20, 0, 5000))
  run(1500)
  proxy("SET_LEVEL", { LEVEL = 90 })
  local before = commands()
  run(15000)
  T.eq("the device is sent nothing after the level", commands(), before)
  T.eq("and the proxy is told the level alone", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 90 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("an On/Off-only light turned off during a scene stays off, and is not shown at the scene's level")
do
  light({ ColorMode.COLOR_MODE_ON_OFF }, false)
  activate(levelStep(100, 3000) .. levelStep(100, 0, 5000))
  run(1500)
  proxy("OFF")
  local before = commands()
  run(15000)
  T.eq("the device is sent nothing after the Off", commands(), before)
  T.eq("and the proxy is told off alone", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a color ramp asked for during a scene's fade runs to its own end, not to the scene step's")
do
  light({ ColorMode.COLOR_MODE_RGB })
  activate(colorStep(nil, { 0.3, 0.6 }, 3000))
  run(1500)
  colorTarget({ 0.2, 0.5 }, 4000)
  run(15000)
  T.eq("the proxy is told the color asked for", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.2 })
  T.eq("at its own ramp's end", told("LIGHT_COLOR_CHANGED", "at"), { 5500 })
  proxy("CLEAR_ALL_SCENES")
  -- A level set during the fade takes the light from the scene, whose step still ends the color ramp it began.
  light({ ColorMode.COLOR_MODE_RGB })
  activate(colorStep(60, { 0.3, 0.6 }, 3000))
  run(1500)
  proxy("SET_LEVEL", { LEVEL = 50 })
  run(15000)
  T.eq(
    "a level set during it: the proxy is told the scene's color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 0.3 }
  )
  T.eq("at the step's end", told("LIGHT_COLOR_CHANGED", "at"), { 3000 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a color set during a rated on is the color the light ends in, with Dim-To-Warm too")
do
  -- The ramp's end sends the level again: alone, or the Dim-To-Warm mix for it would replace the color.
  for _, case in ipairs({ { 4000, 500 }, { 500, 500 }, { 0, 500 }, { 1000, 100 } }) do
    local rate, at = case[1], case[2]
    local name = ("over %d ms, %d ms into the on"):format(rate, at)
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(ON, DIM)
    local asked = setColor({ 0.2, 0.5 })
    setColor(BLUE)
    mark()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
    run(at)
    colorTarget({ 0.2, 0.5 }, rate)
    run(15000)
    local out = colors()
    T.eq(name .. ": it is the last color the light is sent", out[#out], asked)
    T.eq(name .. ": and the proxy is told it once", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.2 })
  end
end

-- The proxy's Previous On preset, as UPDATE_COLOR_ON_MODE names it.
local PREVIOUS_ON = { 0.45, 0.41, id = 10 }

T.section("Color On Mode set to a preset turns the light on in it, whatever color it went off in")
do
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON)
  local onColor = setColor(ON)
  proxy("ON")
  setColor({ 0.2, 0.5 })
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("it is sent the preset's color", colors(), { onColor })
  T.eq("and the proxy is told it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
end

T.section("Color On Mode set to Previous turns the light on in the color it went off in")
do
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(PREVIOUS_ON)
  proxy("ON")
  local previous = setColor({ 0.2, 0.5 })
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("it is sent the color it went off in", colors(), { previous })
  T.eq("and the proxy is told it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.2 })
end

T.section("an edit of the preset the Color On Mode names is the color the light next turns on in")
do
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON)
  local edited = setColor({ 0.2, 0.5 })
  proxy(
    "UPDATE_COLOR_PRESET",
    { COMMAND = "MODIFIED", ID = 1, NAME = "On Color", COLOR_X = 0.2, COLOR_Y = 0.5, COLOR_MODE = 0 }
  )
  mark()
  proxy("ON")
  T.eq("it is sent the edited color", colors(), { edited })
  T.eq("and the proxy is told it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.2 })
end

T.section("a ramped off ends the on cycle, as an instant one does")
do
  local function fadeOff()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 1000 })
  end
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(PREVIOUS_ON)
  proxy("ON")
  setColor(ON)
  proxy("OFF")
  proxy("ON")
  local previous = setColor({ 0.2, 0.5 })
  fadeOff()
  run(15000)
  mark()
  proxy("ON")
  T.eq("Previous: it comes on in the color it faded off in", colors(), { previous })
  -- A fade stopped as it reaches off.
  previous = setColor({ 0.3, 0.6 })
  fadeOff()
  run(997)
  proxy("SET_BRIGHTNESS_STOP")
  run(15000)
  mark()
  proxy("ON")
  T.eq("and in the color a fade stopped at off left", colors(), { previous })
  -- A fade sent off again as it reaches off.
  previous = setColor({ 0.35, 0.45 })
  fadeOff()
  run(997)
  fadeOff()
  run(15000)
  mark()
  proxy("ON")
  T.eq("and in the color a fade sent off again as it reached off left", colors(), { previous })
end

T.section("a brightness stop takes the light out of the scene too")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(levelStep(60, 3000) .. levelStep(20, 0, 5000))
  run(1500)
  proxy("SET_BRIGHTNESS_STOP")
  local before = commands()
  run(15000)
  T.eq("the device is sent nothing after the stop", commands(), before)
  T.eq(
    "and the proxy is told where it stopped alone",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 80 }
  )
  proxy("CLEAR_ALL_SCENES")
end

T.section("a stop of the level leaves a color ramp in flight its color, not the one the level would carry")
do
  local green = { 0.3, 0.6 }
  -- The proxy's stop of a rated on whose color it has since set: the light is still taken to be
  -- off, so the level held would carry the On color.
  offInBlue()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  colorTarget(green, 2000)
  run(500)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("Set Brightness Stop: it sends the level alone", #colors(), 0)
  run(15000)
  T.eq("and the color ramp runs to its end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })
  T.eq(
    "the proxy is told where the level stopped",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 38 }
  )
  -- Dim-To-Warm at 100 %, a scene fading to 20 % in green: the level held would carry the mix for 80 %.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(colorStep(20, green, 4000))
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("in a scene's fade with Dim-To-Warm: it sends the level alone", #colors(), 0)
  run(15000)
  T.eq(
    "and the scene's color is told at its step's end",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { green[1] }
  )
  proxy("CLEAR_ALL_SCENES")
end

T.section("a stop of a rated on leaves the color set since the on began")
do
  -- The light is still taken to be off, so the level the stop holds would carry the on color again.
  for _, dim in ipairs({ false, DIM }) do
    local name = dim and "Dim-To-Warm" or "On color"
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(ON, dim or nil)
    setColor(BLUE)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
    run(1000)
    colorTarget({ 0.3, 0.6 }, 0)
    run(1000)
    mark()
    proxy("SET_BRIGHTNESS_STOP")
    run(15000)
    T.eq(name .. ": the stop sends no color", #colors(), 0)
    T.eq(name .. ": and tells the proxy none", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})
    T.eq(
      name .. ": it is told where the level stopped",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      { 50 }
    )
  end
end

T.section("with Dim-To-Warm a color set lasts until the level next changes, when the formula colors the light again")
do
  local green = { 0.3, 0.6 }
  -- A color set on a light at 100 %, then a dim.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  setColor(green)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "a dim after a color: the proxy is told the mix for 50 %",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(50) }
  )
  -- A color set a second into a 4 s dim stands to the dim's end, and the level set after it takes the mix.
  proxy("ON")
  proxy("RAMP_TO_LEVEL", { LEVEL = 10, TIME = 4000 })
  run(1000)
  mark()
  colorTarget(green, 0)
  run(15000)
  T.eq(
    "a color set in a dim: it stands to the dim's end",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { green[1] }
  )
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("and the level set after it takes the mix", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(50) })
  -- A fade to off carries no color of its own for the color set to replace: a stop still keeps it.
  proxy("ON")
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  run(1000)
  colorTarget(green, 0)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  run(15000)
  T.eq("a stop of a fade to off after a color was set sends no color", #colors(), 0)
  T.eq("and tells the proxy none", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})
end

T.section("with Dim-To-Warm a scene step that sets a level alone takes the formula's color for it")
do
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(levelStep(20, 3000))
  T.eq("a fade to 20 %: from the On color", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  T.eq("to the mix for 20 %", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { mix(20) })
  T.eq("which the step's command carries", #colors(), 1)
  run(15000)
  T.eq("and at its end the proxy is told the mix", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(20) })
  proxy("CLEAR_ALL_SCENES")
  -- A step that sets a color too takes its own.
  activate(colorStep(60, { 0.3, 0.6 }, 3000))
  run(15000)
  T.eq(
    "a step with a color of its own: the proxy is told that color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 0.3 }
  )
  proxy("CLEAR_ALL_SCENES")
end

T.section("Stop Scene Ramp holds the light where a scene's ramp has got to")
do
  local green = { 0.3, 0.6 }
  -- A scene's color fade, a quarter done.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  activate(colorStep(nil, DIM, 4000))
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "a color fade: the proxy is told the color it had got to",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (DIM[1] - ON[1]) * (1000 / 4000) }
  )
  T.eq("which the light is sent", #colors(), 1)
  proxy("CLEAR_ALL_SCENES")
  -- A held scene button: Ramp Scene Up from 20 toward full, stopped a second into its 5 s.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 20 })
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 5000 })
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  run(15000)
  T.eq("Ramp Scene Up, stopped: the light is sent the level it had got to", commands(), 1)
  T.eq("and the proxy is told it", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 36 })
  -- A step's own fade from 50 to off, stopped under the published spec's name: the step after it does not run.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 50 })
  activate(levelStep(0, 10000) .. levelStep(80))
  run(2000)
  proxy("STOP_RAMP_SCENE", { SCENE_ID = 7 })
  run(30000)
  T.eq(
    "a step's fade, stopped: the proxy is told where, and nothing after",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 40 }
  )
  -- A scene that ignores ramps leaves alone a ramp the proxy asked for.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 20 })
  proxy("PUSH_SCENE", { SCENE_ID = 7, IGNORE_RAMP = "true", ELEMENTS = levelStep(60) })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  run(1000)
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  run(30000)
  T.eq(
    "a stop for a scene that ignores ramps: the ramp runs to its end",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 100 }
  )
  proxy("CLEAR_ALL_SCENES")
  -- Dim-To-Warm at 100 %, a scene fading to 20 % in green: each stop holds its own, the level and the color.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(colorStep(20, green, 4000))
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "a fade of level and color: the proxy is told a quarter of the way to the green",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (green[1] - ON[1]) * (1000 / 4000) }
  )
  T.eq("and the level it stopped at", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 80 })
  proxy("CLEAR_ALL_SCENES")
  -- A color set during a step's fade that carried none of its own is not replaced by the stop.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(levelStep(20, 4000))
  run(1000)
  colorTarget(green, 0)
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq("a stop after a color was set in the fade sends no color", #colors(), 0)
  T.eq("and tells the proxy the level alone", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 60 })
  proxy("CLEAR_ALL_SCENES")
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------

local TOP, TOGGLE = 0, 2
local RELEASE_HOLD, PRESS, RELEASE_CLICK = 0, 1, 2

T.section("a held Top or Toggle ramps toward full, past the Default On level, until released")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_PRESET_LEVEL", { LEVEL = 50 })
  proxy("SET_LEVEL", { LEVEL = 80 })
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  T.eq("Top from 80: it ramps toward 100", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"), { 100 })
  run(1000)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_HOLD })
  local stopped = told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
  T.check("and stops above where it was", (stopped[#stopped] or 0) > 80, T.show(stopped))
  proxy("OFF")
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS })
  T.eq("Toggle from off: it ramps toward 100", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"), { 100 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = RELEASE_HOLD })
  proxy("SET_PRESET_LEVEL", { LEVEL = 100 })
end

local TOP_LINK = 300 -- the Top Button Link binding

T.section("a press, click or toggle made in a ramp acts on the level the light has got to")
do
  --- A light 2.5 s into a 5 s ramp up from off: at 50 %, which the driver holds as off until the ramp ends.
  local function rising()
    light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
    run(2500)
    mark()
  end
  -- Top pressed and clicked: the click's ramp starts from 50, with no Off and no pre-on ahead of it.
  rising()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  T.eq("Top click: the click sends its ramp and nothing else", commands(), 1)
  T.eq("from the level the press found", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  -- Toggle pressed and clicked: the light is on, so the hold ramp heads for off and the click turns it off.
  rising()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS })
  T.eq("Toggle press: it ramps toward off", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"), { 0 })
  run(110)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = RELEASE_CLICK })
  run(15000)
  T.eq("Toggle click: the light ends off", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
  -- A Button Link's click with no push replaces the ramp from where it has got to.
  rising()
  RFP.DO_CLICK(TOP_LINK, "DO_CLICK", {})
  T.eq("a click with no push: it sends its ramp and nothing else", commands(), 1)
  T.eq("from where the ramp had got to", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  -- The proxy's Toggle turns off a light on its way up.
  rising()
  proxy("TOGGLE")
  run(15000)
  T.eq("the proxy's Toggle: the light ends off", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
end

T.section("a scene step taken at once is where the step or command after it starts from")
do
  -- 30 % at once, then 60 % over 3 s: stopped half way through that fade, the light is at 45 %.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(levelStep(30) .. levelStep(60, 3000))
  T.eq(
    "the proxy is told the step's level as it goes out",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )
  T.eq("and the fade after it starts there", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 30 })
  run(1500)
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "a stop half way through that fade holds it at 45",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30, 45 }
  )
  -- A rated command after the step ramps from its level, over the rate it asks.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(levelStep(30))
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  T.eq("a rated command after it: from 30", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 30 })
  run(15000)
  T.eq("to 100 at its own ramp's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })
  proxy("CLEAR_ALL_SCENES")
end

-- Hue and saturation back to xy, the inverse of the stub above.
function C4:ColorHSVtoXY(h, s)
  return h / 360, s / 100
end

T.section("a color the light takes while off is its color, which a color ramp then starts from")
do
  light({ ColorMode.COLOR_MODE_RGB }, false)
  local rgb = setColor({ 0.25, 0.4 })
  setColor(BLUE)
  mark()
  -- The device reports the color it was given elsewhere, still off.
  RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
    entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = { ColorMode.COLOR_MODE_RGB } }),
    state = SerializeSafe({
      state = false,
      brightness = 1.0,
      color_mode = ColorMode.COLOR_MODE_RGB,
      red = rgb[1],
      green = rgb[2],
      blue = rgb[3],
    }),
  })
  local x = told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")[1]
  T.check(
    "the proxy is told it",
    x ~= nil and math.abs(x - 0.25) < 5e-3,
    T.show(told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"))
  )
  colorTarget(ON, 2000)
  T.eq("and the ramp starts from it", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { x })
end

T.section("Ramp Scene Up and Down in a ramp start from the level the light has got to")
do
  --- A light 2 s into a 4 s ramp up from off: at 50 %%, which the driver holds as off until the ramp ends.
  local function rising()
    light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
    run(2000)
    mark()
  end
  rising()
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 3000 })
  T.eq("Ramp Scene Up: from 50", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  T.eq("with no pre-on ahead of its ramp", commands(), 1)
  rising()
  proxy("RAMP_SCENE_DOWN", { SCENE_ID = 7, RATE = 3000 })
  T.eq("Ramp Scene Down: from 50", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  T.eq("toward off", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"), { 0 })
  run(15000)
  T.eq("which the proxy is told at its ramp's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 3000 })
end

--- The brightness and transition of the last command the device was sent since the mark.
local function lastLevel()
  for i = #sent, 1, -1 do
    local s = sent[i]
    if s.binding == ESPHOME and s.command == "ENTITY_COMMAND" then
      local cmd = DeserializeSafe(s.params.body)
      return { cmd.brightness, cmd.transition_length }
    end
  end
end

T.section("a command for the level a ramp has got to holds the bulb there")
do
  -- Top pressed and clicked on a light at its Default On level: the press's hold heads for full.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_PRESET_LEVEL", { LEVEL = 50 })
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  run(15000)
  T.eq("a Top click at the on level: the bulb is last sent that level, at once", lastLevel(), { 50 / 100, 0 })
  T.eq("and the proxy is told it", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  -- With Dim-To-Warm the hold carried the mix for full, so the level's own goes back with it.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  run(15000)
  T.eq("with Dim-To-Warm: the bulb is last sent that level", lastLevel(), { 50 / 100, 0 })
  T.eq("in the mix for it, which the proxy is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(50) })
  -- A click that moves the light sends its ramp and nothing ahead of it.
  proxy("SET_PRESET_LEVEL", { LEVEL = 100 })
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  T.eq("a click that moves the light sends its ramp alone", commands(), 1)
  -- A level command, and Ramp Scene Up, for the level a ramp has reached half way from 20 to 100.
  for _, case in ipairs({ "SET_LEVEL", "RAMP_SCENE_UP" }) do
    light({ ColorMode.COLOR_MODE_BRIGHTNESS })
    proxy("SET_PRESET_LEVEL", { LEVEL = 60 })
    proxy("SET_LEVEL", { LEVEL = 20 })
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
    run(2000)
    mark()
    proxy(case, { LEVEL = 60, SCENE_ID = 7, RATE = 3000 })
    run(15000)
    T.eq(case .. " to 60 with the ramp at 60: the bulb is held there", lastLevel(), { 60 / 100, 0 })
    T.eq(case .. ": and the proxy is told it", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 60 })
  end
  proxy("SET_PRESET_LEVEL", { LEVEL = 100 })
end

T.section("a scene step taken at once is the color the next fade starts from")
do
  -- With Dim-To-Warm a step that sets a level alone takes the mix for it.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(levelStep(20))
  T.eq(
    "a level at once with Dim-To-Warm: the proxy is told the mix for 20 %",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(20) }
  )
  mark()
  colorTarget({ 0.3, 0.6 }, 2000)
  T.eq("and a color ramp after it starts there", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { mix(20) })
  proxy("CLEAR_ALL_SCENES")
  -- A step with a color of its own.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(BLUE)
  activate(colorStep(50, { 0.3, 0.6 }, 0))
  T.eq("a color at once: the proxy is told it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.3 })
  mark()
  colorTarget(ON, 2000)
  T.eq("and a color ramp after it starts there", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { 0.3 })
  proxy("CLEAR_ALL_SCENES")
end

T.finish()
