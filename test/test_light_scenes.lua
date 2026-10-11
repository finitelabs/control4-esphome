--- A light's scenes and ramps beside direct commands: what the proxy is told
--- and the device sent when a scene, a level and a color command overlap.
---
--- Driven through the driver's RFP entry points on a virtual clock, with
--- SendToProxy captured. No device answers: every notify is the driver's own.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_light_scenes.lua

local T = require("testlib")

require("c4_shim")

local ColorMode = require("esphome.proto_schema").Enum.ColorMode
local persist = require("lib.persist")

-- From this file: make test runs at the repo root, run_test.sh in test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/esphome_light/driver.lua"

local PROXY, ESPHOME = 5001, 5002

---------------------------------------------------------------------------
-- Virtual clock: the shim's timers have no clock to order by, and a scene's
-- step and a command's ramp end at different times.
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

--- A fresh light, on at full unless `on` is false. Its state lives in the
--- driver chunk's locals, and its Color On Mode in the process-wide store.
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

local function proxy(command, params)
  RFP[command](PROXY, command, params or {})
end

local function activate(elements)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = elements })
  mark()
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
end

--- Each `field` the proxy got with `command` since the mark; "at" is the ms.
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

--- A scene element setting a level over `rate` ms after `delay`, 0 if nil.
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

-- xy as hue and saturation over their ranges: the shim converts no colors.
function C4:ColorXYtoHSV(x, y)
  return x * 360, y * 100
end

-- An On Color preset, a Dim-To-Warm dim color and another color, as xy.
local ON, DIM, BLUE = { 0.6, 0.3, id = 1 }, { 0.14, 0.1 }, { 0.15, 0.06 }

--- Set the Color On Mode: an on preset and, for Dim-To-Warm, the dim color.
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

local function colorTarget(xy, rate)
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = xy[1], LIGHT_COLOR_TARGET_Y = xy[2], LIGHT_COLOR_TARGET_COLOR_RATE = rate }
  )
end

--- The red, green and blue of each command since the mark that had a color.
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

--- Set a color at once, and return the red, green and blue it was sent as.
local function setColor(xy)
  mark()
  colorTarget(xy, 0)
  return colors()[1]
end

--- A color light that is off, left in blue, with the On color as its mode.
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
  -- The proxy's Dynamic On: the level, then the On color the level has sent.
  offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(ON, 750)
  run(15000)
  T.eq("the On color goes out once", #colors(), 1)
  T.eq("and the proxy is told it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
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

--- A scene element setting a color (xy) over `rate` ms, and a level if given.
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
  -- The level's mix replaces the scene's color, so its ramp has no end.
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
  -- The On color goes out after the ramp's, whose end would re-send its own.
  local onColor = offInBlue()
  mark()
  colorTarget({ 0.3, 0.6 }, 3000)
  run(500)
  proxy("ON")
  run(15000)
  local out = colors()
  T.eq("the On color is the last the light is sent", out[#out], onColor)
  T.eq("and the last the proxy is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
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
  -- With Dim-To-Warm a color lasts until the level next changes.
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
  T.eq(
    "and the proxy is told the step's on, then off alone",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 100, 0 }
  )
  proxy("CLEAR_ALL_SCENES")
  -- Nor does a ramp it was itself asked for come back at its end.
  light({ ColorMode.COLOR_MODE_ON_OFF }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
  run(1000)
  mark()
  proxy("OFF")
  before = commands()
  run(15000)
  T.eq("an Off during a ramp it was asked for: the device is sent nothing after it", commands(), before)
  T.eq(
    "and the proxy is told off, with no ramp's end to follow",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 0 }
  )
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
  -- The ramp's end re-sends the level alone, lest its mix replace the color.
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
  previous = setColor({ 0.3, 0.6 })
  fadeOff()
  run(997)
  proxy("SET_BRIGHTNESS_STOP")
  run(15000)
  mark()
  proxy("ON")
  T.eq("and in the color a fade stopped at off left", colors(), { previous })
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
  -- A stop of a rated on whose color was set since: the light is still taken
  -- to be off, so the level held would carry the On color.
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
  -- With Dim-To-Warm the level held in a scene's fade would carry its mix.
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
  -- Still taken to be off, the level the stop holds would carry the on color.
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
  -- A fade to off carries no color of its own: a stop keeps the one set.
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
  -- Ramp Scene Up from 20, stopped a second into its 5 s: at 36.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 20 })
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 5000 })
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  run(15000)
  T.eq("Ramp Scene Up, stopped: the light is sent the level it had got to", commands(), 1)
  T.eq("and the proxy is told it", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 36 })
  -- STOP_RAMP_SCENE is the published spec's name for the same stop.
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

--- Half way up a 5 s ramp from off: at 50 %, held as off by the driver.
local function rising()
  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  run(2500)
  mark()
end

T.section("a press, click or toggle made in a ramp acts on the level the light has got to")
do
  rising()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  T.eq("Top click: the click sends its ramp and nothing else", commands(), 1)
  T.eq("from the level the press found", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  rising()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS })
  T.eq("Toggle press: it ramps toward off", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"), { 0 })
  run(110)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = RELEASE_CLICK })
  run(15000)
  T.eq("Toggle click: the light ends off", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
  rising()
  RFP.DO_CLICK(TOP_LINK, "DO_CLICK", {})
  T.eq("a click with no push: it sends its ramp and nothing else", commands(), 1)
  T.eq("from where the ramp had got to", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  rising()
  proxy("TOGGLE")
  run(15000)
  T.eq("the proxy's Toggle: the light ends off", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
end

T.section("a scene step taken at once is where the step or command after it starts from")
do
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

--- The brightness and transition of the last command sent since the mark.
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
  -- At its Default On level a press on Top heads for full before the click.
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
  -- With Dim-To-Warm the press's hold carried the mix for full.
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
  -- A color set lasts until a brightness command, which the click is.
  local green = { 0.3, 0.6 }
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(50)
  colorTarget(green, 0)
  run(60)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  run(15000)
  T.eq("after a color set during the hold: the bulb is last sent that level", lastLevel(), { 50 / 100, 0 })
  T.eq("in the mix for it, which the proxy is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(50) })
  -- 2 s into a fade to off begun after a color ramp, the light is at 25 %.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("SET_LEVEL", { LEVEL = 50 })
  colorTarget(green, 4000)
  run(100)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  run(2000)
  mark()
  proxy("SET_LEVEL", { LEVEL = 25 })
  T.eq("in a color ramp: the bulb is held at the level a fade has got to", lastLevel(), { 25 / 100, 0 })
  run(15000)
  T.eq(
    "in the mix for it, which the proxy is told once, and not the ramp's color after",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(25) }
  )
  -- With no Color On Mode the level has no color of its own: it goes alone.
  light({ ColorMode.COLOR_MODE_RGB })
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(50)
  colorTarget(green, 0)
  run(60)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  run(15000)
  T.eq("with no color mode, after a color set during the hold: the level goes alone", #colors(), 0)
  T.eq(
    "and the color set is kept: the proxy is told no other",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    {}
  )
  light({ ColorMode.COLOR_MODE_RGB })
  proxy("SET_LEVEL", { LEVEL = 50 })
  colorTarget(green, 4000)
  run(100)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  run(2000)
  mark()
  proxy("SET_LEVEL", { LEVEL = 25 })
  T.eq("with no color mode, in a color ramp: the level goes alone", #colors(), 0)
  run(15000)
  T.eq("and the color ramp runs to its own end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })
  -- With no ramp in flight there is nothing to hold.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 50 })
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("the level a settled light is at, asked for again: nothing is sent", commands(), 0)
  T.eq("and the proxy is told the level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  proxy("SET_PRESET_LEVEL", { LEVEL = 100 })
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  T.eq("a click that moves the light sends its ramp alone", commands(), 1)
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
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(BLUE)
  activate(colorStep(50, { 0.3, 0.6 }, 0))
  T.eq("a color at once: the proxy is told it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.3 })
  mark()
  colorTarget(ON, 2000)
  T.eq("and a color ramp after it starts there", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { 0.3 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("with Dim-To-Warm a brightness command for the level the light is at returns it to the formula's color")
do
  local green = { 0.3, 0.6 }
  --- A Dim-To-Warm light settled at 50 %, in the mix for it.
  local function settled()
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(ON, DIM)
    proxy("SET_LEVEL", { LEVEL = 50 })
  end
  settled()
  setColor(green)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("after a color was set: the level is sent again, at once", lastLevel(), { 50 / 100, 0 })
  T.eq("in the mix for it", #colors(), 1)
  T.eq("which the proxy is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(50) })
  T.eq("with the level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("with the mix already showing: nothing is sent", commands(), 0)
  T.eq("and the proxy is told the level alone", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})
  settled()
  colorTarget(green, 4000)
  run(1000)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  run(15000)
  T.eq(
    "during a color fade: the proxy is told the mix, and no fade's end after it",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(50) }
  )
  settled()
  setColor(green)
  local back = { mix(50), DIM[2] + (ON[2] - DIM[2]) * (50 * 0.01) }
  colorTarget(back, 4000)
  run(1000)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("during a color fade to the mix itself: nothing is sent", commands(), 0)
  run(15000)
  T.eq(
    "and the fade ends in the mix, at its own time",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(50) }
  )
  -- A color-temperature light cannot be sent a mix that is a color.
  light({ ColorMode.COLOR_MODE_COLOR_TEMPERATURE }, false)
  onMode(ON, DIM)
  proxy("SET_LEVEL", { LEVEL = 50 })
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("a light that cannot take the mix: nothing is sent", commands(), 0)
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  setColor(green)
  mark()
  proxy("SET_LEVEL", { LEVEL = 0 })
  T.eq("a light that is off, told off: nothing is sent", commands(), 0)
  -- The last is Dim-To-Warm switched off with its dim color still stored.
  local modes = {
    { "no Color On Mode", function() end },
    {
      "a preset as the Color On Mode",
      function()
        onMode(ON)
      end,
    },
    {
      "Dim-To-Warm switched off",
      function()
        proxy("UPDATE_COLOR_ON_MODE", {
          COLOR_PRESET_ID = ON.id,
          COLOR_PRESET_ORIGIN = 1,
          COLOR_PRESET_COLOR_X = ON[1],
          COLOR_PRESET_COLOR_Y = ON[2],
          COLOR_PRESET_COLOR_MODE = 0,
          COLOR_FADE_PRESET_ID = 2,
          COLOR_FADE_PRESET_ORIGIN = 0,
          COLOR_FADE_PRESET_COLOR_X = DIM[1],
          COLOR_FADE_PRESET_COLOR_Y = DIM[2],
          COLOR_FADE_PRESET_COLOR_MODE = 0,
        })
      end,
    },
  }
  for _, case in ipairs(modes) do
    local name, setup = case[1], case[2]
    light({ ColorMode.COLOR_MODE_RGB })
    setup()
    proxy("SET_LEVEL", { LEVEL = 50 })
    setColor(green)
    mark()
    proxy("SET_LEVEL", { LEVEL = 50 })
    T.eq("with " .. name .. ": nothing is sent", commands(), 0)
    T.eq(
      "with " .. name .. ": and the proxy is told the level",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      { 50 }
    )
  end
  for _, rate in ipairs({ 0, 2000 }) do
    settled()
    setColor(green)
    activate(levelStep(50, rate))
    T.eq("a scene step to that level over " .. rate .. " ms: its command carries the mix", #colors(), 1)
    run(15000)
    T.eq(
      "a scene step over " .. rate .. " ms: and the proxy is told the mix",
      told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
      { mix(50) }
    )
    proxy("CLEAR_ALL_SCENES")
  end
end

T.section("a Color On Mode's color, and a scene step's, is told in the form the light takes it")
do
  -- Kelvin as x over a y that curves as the locus does, so the mix of two
  -- temperatures lies off it, where no temperature a bulb reports reads.
  local toXY, toCCT = C4.ColorCCTtoXY, C4.ColorXYtoCCT
  function C4:ColorCCTtoXY(kelvin)
    local x = kelvin / 10000
    return x, 0.4 - (x - 0.45) ^ 2
  end
  function C4:ColorXYtoCCT(x)
    return x * 10000
  end
  local CCT, FULL = 1, 0
  --- Set the Color On Mode to an xy in mode CCT, with a dim one if given.
  local function onModeXY(onX, onY, dimX, dimY)
    proxy("UPDATE_COLOR_ON_MODE", {
      COLOR_PRESET_ID = 1,
      COLOR_PRESET_ORIGIN = 1,
      COLOR_PRESET_COLOR_X = onX,
      COLOR_PRESET_COLOR_Y = onY,
      COLOR_PRESET_COLOR_MODE = CCT,
      COLOR_FADE_PRESET_ID = dimX and 2 or 0,
      COLOR_FADE_PRESET_ORIGIN = dimX and 1 or 0,
      COLOR_FADE_PRESET_COLOR_X = dimX,
      COLOR_FADE_PRESET_COLOR_Y = dimY,
      COLOR_FADE_PRESET_COLOR_MODE = CCT,
    })
  end
  --- The same in kelvin.
  local function onModeCCT(on, dim)
    local onX, onY = C4:ColorCCTtoXY(on)
    if dim then
      onModeXY(onX, onY, C4:ColorCCTtoXY(dim))
    else
      onModeXY(onX, onY)
    end
  end
  --- The device reports back the last command sent, in its color mode `kind`.
  local function echo(kind)
    local cmd
    for i = #sent, 1, -1 do
      if sent[i].binding == ESPHOME and sent[i].command == "ENTITY_COMMAND" then
        cmd = DeserializeSafe(sent[i].params.body)
        break
      end
    end
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = { kind } }),
      state = SerializeSafe({
        state = true,
        brightness = cmd.brightness,
        color_mode = kind,
        color_temperature = cmd.color_temperature,
        red = cmd.red,
        green = cmd.green,
        blue = cmd.blue,
      }),
    })
  end
  --- Whether the proxy was told one color since the mark: `x`, `y`, `mode`.
  local function toldOnce(x, y, mode)
    local xs, ys =
      told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y")
    local modes = told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_COLOR_MODE")
    return #xs == 1 and math.abs(xs[1] - x) < 1e-9 and math.abs(ys[1] - y) < 1e-9 and modes[1] == mode
  end
  -- Dim-To-Warm from 2700 K to 6500 K at 50 %: 4600 K to a light with a color
  -- temperature, and the xy half way between them to one with color alone.
  local warmX, warmY = C4:ColorCCTtoXY(2700)
  local coolX, coolY = C4:ColorCCTtoXY(6500)
  local pointX, pointY = C4:ColorCCTtoXY(4600)
  for _, case in ipairs({
    { "a color and color temperature light", ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE, pointX, pointY, CCT },
    { "a color temperature light", ColorMode.COLOR_MODE_COLOR_TEMPERATURE, pointX, pointY, CCT },
    { "a color light", ColorMode.COLOR_MODE_RGB, (warmX + coolX) / 2, (warmY + coolY) / 2, FULL },
  }) do
    local name, kind = case[1], case[2]
    light({ kind }, false)
    onModeCCT(6500, 2700)
    mark()
    proxy("SET_LEVEL", { LEVEL = 50 })
    echo(kind)
    T.check(
      name .. ": the proxy is told the mix once, as the light takes and reports it",
      toldOnce(case[3], case[4], case[5]),
      T.show(sent)
    )
    mark()
    proxy("SET_LEVEL", { LEVEL = 50 })
    T.eq(name .. ", the level again: nothing is sent", commands(), 0)
    T.eq(
      name .. ", the level again: and the proxy is told no color",
      told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
      {}
    )
  end
  -- After a rated on the proxy sends the color the on carried, as an xy in
  -- mode CCT: the mix on the line, or an On color that is off the curve.
  local lineX, lineY = (warmX + coolX) / 2, (warmY + coolY) / 2
  --- The proxy's SET_COLOR_TARGET of an xy in mode CCT, over `rate` ms.
  local function target(x, y, rate)
    proxy("SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_X = x,
      LIGHT_COLOR_TARGET_Y = y,
      LIGHT_COLOR_TARGET_MODE = CCT,
      LIGHT_COLOR_TARGET_COLOR_RATE = rate,
    })
  end
  for _, case in ipairs({
    { "a color and color temperature light", ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE },
    { "a color temperature light", ColorMode.COLOR_MODE_COLOR_TEMPERATURE },
  }) do
    local kind = case[2]
    for _, on in ipairs({ { "Dim-To-Warm", 50 }, { "an On color off the curve", 100 } }) do
      local name = case[1] .. ", " .. on[1]
      light({ kind }, false)
      if on[2] == 50 then
        onModeCCT(6500, 2700)
      else
        onModeXY(lineX, lineY)
      end
      mark()
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = on[2], RATE = 4000 })
      run(20)
      target(lineX, lineY, 4000)
      run(20000)
      T.eq(name .. ": the proxy's send of the color puts nothing more out", commands(), 3)
      T.check(
        name .. ": the proxy is told the color once, as the light takes it",
        toldOnce(pointX, pointY, CCT),
        T.show(sent)
      )
      T.eq(name .. ": at the on's end", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
    end
    -- 0.8 of the way from 2700 K to 6500 K on the line: the point of 5740 K.
    light({ kind })
    mark()
    target(warmX + (coolX - warmX) * 0.8, warmY + (coolY - warmY) * 0.8, 0)
    echo(kind)
    local setX, setY = C4:ColorCCTtoXY(5740)
    T.check(
      case[1] .. ", a color temperature set off the curve: the proxy is told its point once",
      toldOnce(setX, setY, CCT),
      T.show(sent)
    )
    proxy(
      "UPDATE_COLOR_PRESET",
      { COMMAND = "ADDED", ID = 5, NAME = "mix", COLOR_X = lineX, COLOR_Y = lineY, COLOR_MODE = CCT }
    )
    mark()
    proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = 5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 })
    echo(kind)
    T.check(
      case[1] .. ", a preset off the curve by its id: the proxy is told its point once",
      toldOnce(pointX, pointY, CCT),
      T.show(sent)
    )
  end
  -- A light with color alone takes a color temperature as a color: the On
  -- color, which the proxy's own send of it 20 ms on matches, and a step's.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onModeCCT(3000)
  local onX, onY = C4:ColorCCTtoXY(3000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(20)
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = onX,
    LIGHT_COLOR_TARGET_Y = onY,
    LIGHT_COLOR_TARGET_MODE = CCT,
    LIGHT_COLOR_TARGET_COLOR_RATE = 4000,
  })
  run(20000)
  T.eq("an On color: the proxy's send of it puts no second color out", #colors(), 1)
  T.check("an On color: the proxy is told it once, as a color", toldOnce(onX, onY, FULL), T.show(sent))
  local stepX, stepY = C4:ColorCCTtoXY(4000)
  local step = "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>%s</colorX><colorY>%s</colorY>"
    .. "<colorMode>1</colorMode><colorRate>2000</colorRate></element>"
  activate(step:format(stepX, stepY))
  run(20000)
  T.check("a scene step's color: the proxy is told it once, as a color", toldOnce(stepX, stepY, FULL), T.show(sent))
  proxy("CLEAR_ALL_SCENES")
  C4.ColorCCTtoXY, C4.ColorXYtoCCT = toXY, toCCT
end

T.section("a scene stopped during a step's fade leaves the fade to run to its end")
do
  local green = { 0.3, 0.6 }
  -- A step fading to 20 % in green over 4 s, stopped a second in. The step after it must not run.
  for _, stop in ipairs({ "DEACTIVATE_SCENE", "CLEAR_ALL_SCENES" }) do
    light({ ColorMode.COLOR_MODE_RGB })
    setColor(ON)
    activate(colorStep(20, green, 4000) .. levelStep(80, 0, 5000))
    run(1000)
    proxy(stop, { SCENE_ID = 7 })
    run(15000)
    T.eq(
      stop .. ": the proxy is told the step's level, and no later step's",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      { 20 }
    )
    T.eq(stop .. ": at the fade's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 4000 })
    T.eq(stop .. ": and its color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })
    mark()
    proxy("SET_LEVEL", { LEVEL = 100 })
    T.eq(stop .. ": a level set after it goes to the bulb, which is at 20", commands(), 1)
  end
  -- The fade is still there for a stop to hold, and for a color set after it to start from.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  activate(colorStep(20, green, 4000))
  run(1000)
  proxy("DEACTIVATE_SCENE", { SCENE_ID = 7 })
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop a second after Deactivate Scene holds the level the fade has got to",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 60 }
  )
  colorTarget(BLUE, 1000)
  T.eq(
    "and a color set then ramps from half way through the fade",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (green[1] - ON[1]) * 0.5 }
  )
  run(15000)
  -- Nor is a ramp a command began forgotten: a color stop a second later holds that one half way.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(green, 4000)
  run(1000)
  proxy("DEACTIVATE_SCENE", { SCENE_ID = 7 })
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a color stop after Deactivate Scene holds a command's ramp half way",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (green[1] - ON[1]) * 0.5 }
  )
  -- With Dim-To-Warm, Ramp Scene Up a second into a step's fade to 20 % in green carries the mix from there.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(colorStep(20, green, 4000))
  run(1000)
  mark()
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 2000 })
  T.eq(
    "Ramp Scene Up in a step's fade: the color ramps from a quarter of the way through it",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (green[1] - ON[1]) * 0.25 }
  )
  T.eq("to the mix for the on level", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { mix(100) })
  run(15000)
  proxy("CLEAR_ALL_SCENES")
  -- Remove Scene cancels the step's timer too: the fade still ends.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(levelStep(20, 4000))
  run(1000)
  proxy("REMOVE_SCENE", { SCENE_ID = 7 })
  run(15000)
  T.eq(
    "Remove Scene during a step's fade: the proxy is told the fade's end",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 20 }
  )
end

T.section("a scene step that sets a color alone leaves a brightness ramp running, for a stop to hold")
do
  local other = { 0.2, 0.5 }
  -- 5 s into a 20 s fade from 100 to 30 a step fades the color over 500 ms; the stop comes 300 ms after that.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(BLUE)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 20000 })
  run(5000)
  activate(colorStep(nil, other, 500))
  run(800)
  T.eq(
    "the step's end is not the fade's: the proxy is told no level",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    {}
  )
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop after the step holds the fade where it has got to",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 80 }
  )
  T.eq("in the step's color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { other[1] })
  proxy("CLEAR_ALL_SCENES")
  -- Left alone the fade ends once, at its own time.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(BLUE)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, other, 500) })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 20000 })
  run(5000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  run(30000)
  T.eq(
    "the fade left to run ends at its own level",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )
  T.eq("at its own time", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 20000 })
  proxy("CLEAR_ALL_SCENES")
  -- A rated on from off carries the On color, which the step's color replaces: the stop does not send it again.
  offInBlue()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, other, 500) })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 20000 })
  run(5000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  run(800)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop of a rated on after the step: it sends the level alone", #colors(), 0)
  T.eq("where the on has got to", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 29 })
  T.eq("and tells the proxy no color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})
  proxy("CLEAR_ALL_SCENES")
  -- Left to run, the on does not tell the proxy the On color at its end, over the step's.
  offInBlue()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, other, 500) })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 20000 })
  run(5000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  run(30000)
  T.eq(
    "a rated on left to run after the step: the proxy is told the step's color alone",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { other[1] }
  )
  proxy("CLEAR_ALL_SCENES")
end

T.section("a scene step that sets a level starts from the level a ramp in flight has got to")
do
  -- Half way through each the bulb is at 50 %, which the driver holds as the level the ramp began at.
  local halfWay = {
    {
      "a ramp up from off",
      0,
      function()
        light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
        proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 30000 })
        run(15000)
      end,
    },
    {
      "another scene's fade to off",
      80,
      function()
        light({ ColorMode.COLOR_MODE_BRIGHTNESS })
        proxy("PUSH_SCENE", { SCENE_ID = 8, ELEMENTS = levelStep(0, 10000) })
        proxy("ACTIVATE_SCENE", { SCENE_ID = 8 })
        run(5000)
      end,
    },
  }
  for _, c in ipairs(halfWay) do
    local name = "a step to " .. c[2] .. " over 2 s in " .. c[1]
    c[3]()
    activate(levelStep(c[2], 2000))
    T.eq(
      name .. ": the proxy is told a ramp from 50",
      told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
      { 50 }
    )
    T.eq(name .. ": to " .. c[2], told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"), { c[2] })
    run(1000)
    proxy("SET_BRIGHTNESS_STOP")
    T.eq(
      name .. ": a stop a second in holds it half way there",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      { (50 + c[2]) / 2 }
    )
    proxy("CLEAR_ALL_SCENES")
  end
  -- A step back to the level a ramp began from: 2 s into a 10 s ramp from 30 to 100 the light is at 44.
  for _, rate in ipairs({ 3000, 0 }) do
    local name = "a step back to where a ramp began, over " .. rate .. " ms"
    light({ ColorMode.COLOR_MODE_BRIGHTNESS })
    proxy("SET_LEVEL", { LEVEL = 30 })
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
    run(2000)
    activate(levelStep(30, rate))
    T.eq(
      name .. ": the proxy is told a ramp from 44, or none",
      told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
      rate > 0 and { 44 } or {}
    )
    run(15000)
    T.eq(name .. ": and the step's level, once", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 30 })
    T.eq(name .. ": when the step ends", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { rate })
    proxy("CLEAR_ALL_SCENES")
  end
  -- A step to the level the ramp has got to has nothing to ramp, and is still the ramp's end for the proxy:
  -- 100 ms into a 30 s ramp up from off the light is still at 0.
  for _, rate in ipairs({ 0, 2000 }) do
    local name = "a step to off over " .. rate .. " ms as a ramp up begins"
    light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 30000 })
    run(100)
    activate(levelStep(0, rate))
    T.eq(name .. ": the proxy is told off at once", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
    run(40000)
    T.eq(name .. ": and nothing after", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
    proxy("CLEAR_ALL_SCENES")
  end
end

T.section("a color ramp that a scene step replaces is left where it has got to")
do
  local other = { 0.2, 0.5 }
  -- A scene's color step a second into a 4 s color ramp a command began.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(other, 4000)
  run(1000)
  activate(colorStep(nil, DIM, 2000))
  T.eq(
    "a step in a command's color ramp ramps from a quarter of the way through it",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (other[1] - ON[1]) * 0.25 }
  )
  run(15000)
  T.eq(
    "and at its end the proxy is told the step's color alone",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { DIM[1] }
  )
  proxy("CLEAR_ALL_SCENES")
  -- A step that sets a level alone, over 500 ms a second into the command's ramp, leaves it to run to its own end.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(50, 500) })
  mark()
  colorTarget(other, 4000)
  run(1000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  run(15000)
  T.eq(
    "a step that sets a level alone: the proxy is told the color asked for and nothing else",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { other[1] }
  )
  T.eq("at its ramp's end", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  T.eq("and the step's level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  proxy("CLEAR_ALL_SCENES")
  -- A step in the color a ramp has got to has nothing to ramp, and is still the ramp's end for the proxy.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(other, 4000)
  activate(colorStep(nil, ON, 2000))
  T.eq(
    "a step back to the color a ramp began from, as it begins: the proxy is told it at once",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )
  run(15000)
  T.eq("and nothing after", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a scene step on an On/Off-only light switches it at once, whatever its level and rate")
do
  -- { the light on, the step's level, what the proxy is told }: a level between is on, and no ramp is told.
  for _, c in ipairs({ { false, 50, { 100 } }, { true, 50, {} }, { true, 0, { 0 } }, { false, 100, { 100 } } }) do
    local name = (c[1] and "on" or "off") .. ", a step to " .. c[2] .. " over 3 s"
    light({ ColorMode.COLOR_MODE_ON_OFF }, c[1])
    activate(levelStep(c[2], 3000))
    T.eq(name .. ": the proxy is told no ramp", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"), {})
    T.eq(
      name .. ": and where the light is, at once",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      c[3]
    )
    run(20000)
    T.eq(name .. ": and nothing after", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), c[3])
    proxy("CLEAR_ALL_SCENES")
  end
  -- The step still takes its rate before the next one runs.
  light({ ColorMode.COLOR_MODE_ON_OFF }, false)
  activate(levelStep(50, 3000) .. levelStep(0))
  run(20000)
  T.eq("the step after it runs when its rate has passed", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 0, 3000 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a scene step that turns the light on fades it up from nothing, in the Color On Mode's color")
do
  -- Off in blue, its Color On Mode the On color: a step to 60 % over 10 s.
  local onColor = offInBlue()
  activate(levelStep(60, 10000))
  T.eq("it is sent a pre-on ahead of its fade", commands(), 2)
  T.eq("which carries the On color", colors(), { onColor })
  T.eq(
    "the proxy is told a color ramp from the blue",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] }
  )
  T.eq("to the On color", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { ON[1] })
  run(20000)
  T.eq(
    "at the step's end the proxy is told the On color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )
  T.eq("and the step's level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 60 })
  proxy("CLEAR_ALL_SCENES")
  -- The same step taken at once, from off in blue again.
  onColor = offInBlue()
  activate(levelStep(60))
  T.eq("a step from off at once: it is sent the On color", colors(), { onColor })
  T.eq("with no pre-on", commands(), 1)
  T.eq("and the proxy is told the color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  proxy("CLEAR_ALL_SCENES")
  -- A step with a color of its own keeps it.
  offInBlue()
  local own = setColor({ 0.3, 0.6 })
  setColor(BLUE)
  activate(colorStep(60, { 0.3, 0.6 }, 3000))
  T.eq("a step from off with a color of its own: it is sent that color", colors(), { own })
  run(15000)
  T.eq("which the proxy is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.3 })
  proxy("CLEAR_ALL_SCENES")
  -- Half way up a ramp from off the light is on, though the driver holds it as off until the ramp ends.
  offInBlue()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  run(5000)
  activate(levelStep(80, 2000))
  T.eq("a step half way up a ramp from off: it is sent its fade alone, with no pre-on", commands(), 1)
  T.eq("and no On color", #colors(), 0)
  proxy("CLEAR_ALL_SCENES")
end

T.section("a stop in a scene step's fade keeps the color the step set")
do
  -- With Dim-To-Warm, at 100 % in a color set for it: a step to 20 % in that color over 4 s.
  local own = { 0.3, 0.6 }
  for _, stop in ipairs({ "SET_BRIGHTNESS_STOP", "STOP_SCENE_RAMP" }) do
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(ON, DIM)
    proxy("ON")
    setColor(own)
    activate(colorStep(20, own, 4000))
    run(1000)
    mark()
    proxy(stop, { SCENE_ID = 7 })
    T.eq(stop .. " a second in: it sends the level alone", #colors(), 0)
    run(15000)
    T.eq(
      stop .. ": the proxy is told where it stopped",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      { 80 }
    )
    T.eq(stop .. ": and no color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})
    proxy("CLEAR_ALL_SCENES")
  end
  -- The Dim-To-Warm color a step takes for its level is the ramp's own: with the color fade stopped,
  -- a stop of the level takes the mix for where it stops.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(levelStep(20, 4000))
  run(1000)
  proxy("SET_COLOR_STOP")
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop of a step's Dim-To-Warm fade, its color stopped first: the mix for 80 %",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(80) }
  )
  proxy("CLEAR_ALL_SCENES")
end

T.section("a scene step with no ramp time is sent as one, not left to the device's default transition")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(levelStep(30))
  T.eq("the step's command carries a transition of 0", lastLevel(), { 30 / 100, 0 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a ramp that replaces one still changing the color starts from the color the light has got to")
do
  local other = { 0.2, 0.5 }
  --- The device reports itself on at `brightness`, in the color it was sent as `rgb`.
  local function report(rgb, brightness)
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = { ColorMode.COLOR_MODE_RGB } }),
      state = SerializeSafe({
        state = true,
        brightness = brightness,
        color_mode = ColorMode.COLOR_MODE_RGB,
        red = rgb[1],
        green = rgb[2],
        blue = rgb[3],
      }),
    })
  end
  -- A click follows its press by about 110 ms, and the press's hold ramp heads for the On color too.
  offInBlue()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  T.eq(
    "a click from off: its color ramp is from the blue the press found",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] }
  )
  T.eq("to the On color", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { ON[1] })
  run(15000)
  T.eq("which the proxy is then told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  -- Dim-To-Warm at 50 %: the press heads for the mix at 100 %, as the click to the on level does.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(110)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_CLICK })
  T.eq(
    "a click with Dim-To-Warm at 50 %: from the mix for 50 %",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { mix(50) }
  )
  run(15000)
  -- Dim-To-Warm at 100 %: a ramp to 10 % over 4 s, sent back to 100 % a second in.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  proxy("RAMP_TO_LEVEL", { LEVEL = 10, TIME = 4000 })
  run(1000)
  mark()
  proxy("RAMP_TO_LEVEL", { LEVEL = 100, TIME = 4000 })
  T.eq(
    "a dim sent back up: from a quarter of the way to the mix for 10 %",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { mix(100) + (mix(10) - mix(100)) * 0.25 }
  )
  T.eq("to the mix for 100 %", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { mix(100) })
  run(20000)
  T.eq("which the proxy is then told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(100) })
  -- A rated on from the blue to the On color, a quarter done when a color ramp, and then a scene's,
  -- replaces its color. The proxy sends the On color after the on, which the on has carried already.
  for _, replace in ipairs({ "SET_COLOR_TARGET", "a scene" }) do
    offInBlue()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
    colorTarget(ON, 4000)
    run(1000)
    if replace == "a scene" then
      activate(colorStep(nil, other, 1000))
    else
      mark()
      colorTarget(other, 1000)
    end
    T.eq(
      replace .. " a quarter into a rated on: from a quarter of the way to the On color",
      told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
      { BLUE[1] + (ON[1] - BLUE[1]) * 0.25 }
    )
    run(15000)
    T.eq(
      replace .. ": the proxy is then told its color, not the On color",
      told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
      { other[1] }
    )
    proxy("CLEAR_ALL_SCENES")
  end
  -- A step in the color the light is still in, as a rated on begins to change it, ends that change for the proxy.
  offInBlue()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  activate(colorStep(nil, BLUE, 2000))
  T.eq(
    "a step back to the color a rated on began from, as it begins: the proxy is told it at once",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] }
  )
  run(15000)
  T.eq("and nothing after", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
  proxy("CLEAR_ALL_SCENES")
  -- Until its end a rated on tells its own color: the device's report of the color it is going to is no news.
  local onColor = offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  report(onColor, 1.0)
  T.eq(
    "a report during a rated on: the proxy is told no color yet",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    {}
  )
  run(15000)
  T.eq("and the On color once, at the on's end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  -- A level command with no color of its own leaves the on's color where it had got to, so the
  -- device's report of the color it goes on to is news, and ends the color fade for the proxy.
  onColor = offInBlue()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  run(5000)
  proxy("SET_LEVEL", { LEVEL = 50 })
  mark()
  report(onColor, 0.5)
  local x = told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")[1]
  T.check(
    "a rated on cut short by a level command: the device's report of the On color is told",
    x ~= nil and math.abs(x - ON[1]) < 5e-3,
    T.show(told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"))
  )
  -- A color ramp tells the proxy the mode the light is leaving: a light starts in color temperature.
  light({ ColorMode.COLOR_MODE_RGB })
  mark()
  colorTarget(ON, 2000)
  T.eq(
    "a color ramp out of color temperature: it is leaving a color temperature",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE"),
    { 1 }
  )
  run(15000)
  T.eq("and ends on a color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_COLOR_MODE"), { 0 })
  -- A rated on to the On color has taken the light out of color temperature by a second in.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  mark()
  colorTarget(other, 1000)
  T.eq(
    "a color ramp a second into a rated on to a color: it is leaving a color",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE"),
    { 0 }
  )
  run(15000)
end

T.finish()
