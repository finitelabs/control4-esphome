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

-- Late init goes no further without a minimum OS version, and the shim has none.
local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return config(self, section)
end

-- The light's proxy and its answer to GET_SETUP: an empty one unless a case
-- gives one, or false for none. A case may give another for a new light,
-- which the proxy answers until it is told the light's capabilities.
local proxySetup, newLightSetup = "", nil
local capabilitiesTold = false
function C4:GetProxyDevices()
  return 643
end
local uiRequest = C4.SendUIRequest
function C4:SendUIRequest(id, request, params)
  if request == "GET_SETUP" then
    return not capabilitiesTold and newLightSetup or proxySetup or nil
  end
  return uiRequest(self, id, request, params)
end

--- The driver started over what it has stored, and its first state: on at
--- full unless `on` is false. Its state lives in the driver chunk's locals.
--- @param modes table|nil The entity's supported_color_modes, or nil for a light yet to connect.
local function restart(modes, on)
  queue, capabilitiesTold = {}, false
  dofile(DRIVER)
  function SendToProxy(idBinding, strCommand, tParams)
    capabilitiesTold = capabilitiesTold or strCommand == "DYNAMIC_CAPABILITIES_CHANGED"
    sent[#sent + 1] = { at = now - start, binding = idBinding, command = strCommand, params = tParams or {} }
  end
  OnDriverLateInit()
  if modes then
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = modes }),
      state = SerializeSafe({ state = on ~= false, brightness = 1.0 }),
    })
  end
  mark()
end

--- A fresh light, whose Color On Mode is in the process-wide store.
--- @param modes table The entity's supported_color_modes.
local function light(modes, on)
  for _, key in ipairs({ "color_on_mode", "color_presets", "previous_color" }) do
    persist:delete(key)
  end
  restart(modes, on)
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

--- ESPHome's easing of a transition: how far along it is at fraction `p` of
--- its time (LightTransformer::smoothed_progress).
local function eased(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

--- The level a fade from `from` to `to` has got to at fraction `p` of its time.
local function fadeLevel(from, to, p)
  return math.floor(from + (to - from) * eased(p) + 0.5)
end

--- The transition length of each command the device was sent since the mark.
local function lengths()
  local out = {}
  for _, s in ipairs(sent) do
    local cmd = s.binding == ESPHOME and s.command == "ENTITY_COMMAND" and DeserializeSafe(s.params.body)
    if cmd then
      out[#out + 1] = cmd.transition_length
    end
  end
  return out
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

-- No xy is a color temperature's point until a section gives the two a form.
function C4:ColorXYtoCCT()
  return nil
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

T.section("an on after a color set over a rate while the light was off: the light ends in the On color")
do
  -- An off light's color is its own at once; the On color then replaces it.
  local onColor = offInBlue()
  mark()
  colorTarget({ 0.3, 0.6 }, 3000)
  run(500)
  proxy("ON")
  run(15000)
  local out = colors()
  T.eq("the On color is the last the light is sent", out[#out], onColor)
  T.eq(
    "the proxy is told the color as it is set, and the On color last",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 0.3, ON[1] }
  )
  offInBlue()
  colorTarget({ 0.3, 0.6 }, 1000)
  run(100)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  T.eq("a rated on: from the color set while off", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), { 0.3 })
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
  T.eq("with the level, which takes the fade with it", told("LIGHT_COLOR_CHANGED", "at"), { 1500 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a color set during a rated on is the color the light ends in, with Dim-To-Warm too")
do
  -- The ramp's end sends nothing, so its mix cannot replace the color.
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
  -- A stop of a rated on whose color was set a second in, over 2 s: the color
  -- re-timed the on from where it had got to.
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
    "the proxy is told where the level stopped, 500 ms into the color's 2 s",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(fadeLevel(0, 100, 1000 / 4000), 100, 500 / 2000) }
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
  -- A color ramp begun before the fade it is stopped in.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  colorTarget(green, 10000)
  run(2000)
  proxy("RAMP_TO_LEVEL", { LEVEL = 0, TIME = 10000 })
  run(2000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("in a fade to off begun after the color ramp: it sends the level alone", #colors(), 0)
end

T.section("a stop of a rated on leaves the color set since the on began")
do
  -- The color's 3 s re-time the on from where a second of its 4 s had got to.
  for _, dim in ipairs({ false, DIM }) do
    local name = dim and "Dim-To-Warm" or "On color"
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(ON, dim or nil)
    setColor(BLUE)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
    run(1000)
    colorTarget({ 0.3, 0.6 }, 3000)
    run(1000)
    mark()
    proxy("SET_BRIGHTNESS_STOP")
    run(15000)
    T.eq(name .. ": the stop sends no color", #colors(), 0)
    T.eq(
      name .. ": the proxy is told the color set, and no other",
      told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
      { 0.3 }
    )
    T.eq(
      name .. ": it is told where the level stopped",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      { fadeLevel(fadeLevel(0, 100, 1000 / 4000), 100, 1000 / 3000) }
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
    { ON[1] + (DIM[1] - ON[1]) * eased(1000 / 4000) }
  )
  T.eq("which the light is sent", #colors(), 1)
  proxy("CLEAR_ALL_SCENES")
  -- Ramp Scene Up from 20, stopped a second into its 5 s.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 20 })
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 5000 })
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  run(15000)
  T.eq("Ramp Scene Up, stopped: the light is sent the level it had got to", commands(), 1)
  T.eq(
    "and the proxy is told it",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(20, 100, 1000 / 5000) }
  )
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
    { fadeLevel(50, 0, 2000 / 10000) }
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
    "a fade of level and color: the proxy is told the color a quarter of its time has got to",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (green[1] - ON[1]) * eased(1000 / 4000) }
  )
  T.eq(
    "and the level it stopped at",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(100, 20, 1000 / 4000) }
  )
  proxy("CLEAR_ALL_SCENES")
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(levelStep(20, 4000))
  run(1000)
  colorTarget(green, 3000)
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  -- The color re-timed the fade from where a quarter of its time had got to.
  local level = fadeLevel(100, 20, 1000 / 4000)
  local x = mix(100) + (mix(20) - mix(100)) * eased(1000 / 4000)
  T.eq("a stop after a color was set in the fade sends that color where it has got to", #colors(), 1)
  T.eq(
    "which the proxy is told, not the mix for the level",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { x + (green[1] - x) * eased(1000 / 3000) }
  )
  T.eq(
    "with the level it stopped at",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(level, 20, 1000 / 3000) }
  )
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

T.section("a color the light takes while off is its color, which a color ramp starts from once it is on")
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
  proxy("ON")
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
  T.eq(
    "after a color set at once in the hold, which took the bulb to full: it is ramped to that level",
    lastLevel(),
    { 50 / 100, 500 }
  )
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
  T.eq("and takes the color ramp with it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })
  T.eq("which the proxy is told then", told("LIGHT_COLOR_CHANGED", "at"), { 0 })
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
      T.eq(name .. ": the proxy's send of the color puts nothing more out", commands(), 2)
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
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(colorStep(20, green, 4000))
  run(1000)
  mark()
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 2000 })
  T.eq(
    "Ramp Scene Up in a step's fade: the color ramps from where a quarter of its time has got to",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (green[1] - ON[1]) * eased(0.25) }
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

T.section("a scene step that sets a color alone takes a brightness ramp with it, over the step's time")
do
  local other = { 0.2, 0.5 }
  -- 5 s into a 20 s fade from 100 to 30.
  local quarter = fadeLevel(100, 30, 5000 / 20000)
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(BLUE)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 20000 })
  run(5000)
  activate(colorStep(nil, other, 500))
  T.eq(
    "the proxy is told the fade again, from where it had got to",
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    { quarter }
  )
  T.eq("over the step's time", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 500 })
  run(250)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop half way through the step holds the fade half way from there",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(quarter, 30, 250 / 500) }
  )
  proxy("CLEAR_ALL_SCENES")
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(BLUE)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, other, 500) })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 20000 })
  run(5000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  run(30000)
  T.eq(
    "left to run, the fade ends at its own level",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )
  T.eq("when the step ends", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 5500 })
  T.eq("as the step's color does", told("LIGHT_COLOR_CHANGED", "at"), { 5500 })
  proxy("CLEAR_ALL_SCENES")
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(BLUE)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, other, 0) })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 20000 })
  run(5000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("a step at once: the proxy is told the fade's level with it", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 5000 })
  run(30000)
  T.eq("and nothing at the fade's own end", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 30 })
  proxy("CLEAR_ALL_SCENES")
  -- A rated on from off carries the On color, which the step's replaces.
  offInBlue()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, other, 500) })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 20000 })
  run(5000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  run(250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop of a rated on in the step: it sends the level alone", #colors(), 0)
  T.eq(
    "where the on has got to",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(fadeLevel(0, 100, 5000 / 20000), 100, 250 / 500) }
  )
  T.eq("and tells the proxy no color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})
  proxy("CLEAR_ALL_SCENES")
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
  -- Half way through each the bulb is at 50 %, held as the level it began at.
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
  -- 2 s into a 10 s ramp from 30 to 100.
  local fifth = fadeLevel(30, 100, 2000 / 10000)
  for _, rate in ipairs({ 3000, 0 }) do
    local name = "a step back to where a ramp began, over " .. rate .. " ms"
    light({ ColorMode.COLOR_MODE_BRIGHTNESS })
    proxy("SET_LEVEL", { LEVEL = 30 })
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
    run(2000)
    activate(levelStep(30, rate))
    T.eq(
      name .. ": the proxy is told a ramp from where it had got to, or none",
      told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
      rate > 0 and { fifth } or {}
    )
    run(15000)
    T.eq(name .. ": and the step's level, once", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 30 })
    T.eq(name .. ": when the step ends", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { rate })
    proxy("CLEAR_ALL_SCENES")
  end
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
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(other, 4000)
  run(1000)
  activate(colorStep(nil, DIM, 2000))
  T.eq(
    "a step in a command's color ramp ramps from where a quarter of its time has got to",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (other[1] - ON[1]) * eased(0.25) }
  )
  run(15000)
  T.eq(
    "and at its end the proxy is told the step's color alone",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { DIM[1] }
  )
  proxy("CLEAR_ALL_SCENES")
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
  T.eq("at the step's end, which its ramp now shares", told("LIGHT_COLOR_CHANGED", "at"), { 1500 })
  T.eq("and the step's level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 50 })
  proxy("CLEAR_ALL_SCENES")
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
  -- { the light on, the step's level, what the proxy is told }
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
  light({ ColorMode.COLOR_MODE_ON_OFF }, false)
  activate(levelStep(50, 3000) .. levelStep(0))
  run(20000)
  T.eq("the step after it runs when its rate has passed", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 0, 3000 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("a scene step that turns the light on fades it up from nothing, in the Color On Mode's color")
do
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
  onColor = offInBlue()
  activate(levelStep(60))
  T.eq("a step from off at once: it is sent the On color", colors(), { onColor })
  T.eq("with no pre-on", commands(), 1)
  T.eq("and the proxy is told the color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  proxy("CLEAR_ALL_SCENES")
  offInBlue()
  local own = setColor({ 0.3, 0.6 })
  setColor(BLUE)
  activate(colorStep(60, { 0.3, 0.6 }, 3000))
  T.eq("a step from off with a color of its own: it is sent that color", colors(), { own })
  run(15000)
  T.eq("which the proxy is told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 0.3 })
  proxy("CLEAR_ALL_SCENES")
  -- Half way up a ramp from off the light is on, though held as off.
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
  -- The step's color is the one the light is in, so it primes no color ramp.
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
      { fadeLevel(100, 20, 1000 / 4000) }
    )
    T.eq(stop .. ": and no color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})
    proxy("CLEAR_ALL_SCENES")
  end
  -- The Dim-To-Warm color a step takes for its level is the ramp's own.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  activate(levelStep(20, 4000))
  run(1000)
  proxy("SET_COLOR_STOP")
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a stop of a step's Dim-To-Warm fade, its color stopped first: the mix for the level it stopped at",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(fadeLevel(100, 20, 1000 / 4000)) }
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

--- A device report: on at `brightness`, in the color sent as `rgb`.
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

T.section("a ramp that replaces one still changing the color starts from the color the light has got to")
do
  local other = { 0.2, 0.5 }
  -- The press's hold ramp, 110 ms before the click, heads for the On color.
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
  -- With Dim-To-Warm at 50 % the press heads for the mix at 100 %.
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
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  proxy("RAMP_TO_LEVEL", { LEVEL = 10, TIME = 4000 })
  run(1000)
  mark()
  proxy("RAMP_TO_LEVEL", { LEVEL = 100, TIME = 4000 })
  T.eq(
    "a dim sent back up: from where a quarter of its time has got to, toward the mix for 10 %",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { mix(100) + (mix(10) - mix(100)) * eased(0.25) }
  )
  T.eq("to the mix for 100 %", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"), { mix(100) })
  run(20000)
  T.eq("which the proxy is then told", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(100) })
  -- The proxy sends the On color after the on, which has already carried it.
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
      replace .. " a quarter into a rated on: from where a quarter of its time has got to, toward the On color",
      told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
      { BLUE[1] + (ON[1] - BLUE[1]) * eased(0.25) }
    )
    run(15000)
    T.eq(
      replace .. ": the proxy is then told its color, not the On color",
      told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
      { other[1] }
    )
    proxy("CLEAR_ALL_SCENES")
  end
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
  -- With a level too, the step leaves the on's ramp before reading its color.
  offInBlue()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  activate(colorStep(80, BLUE, 2000))
  T.eq(
    "the same step with a level: the proxy is told the color at once",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] }
  )
  run(15000)
  T.eq("with a level: and no color after", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
  proxy("CLEAR_ALL_SCENES")
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  proxy("RAMP_TO_LEVEL", { LEVEL = 10, TIME = 4000 })
  activate(levelStep(100, 2000))
  T.eq(
    "a Dim-To-Warm step back to the level a dim began from: the proxy is told its mix at once",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { mix(100) }
  )
  run(15000)
  T.eq("Dim-To-Warm: and no color after", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { mix(100) })
  proxy("CLEAR_ALL_SCENES")
  -- Until its end a rated on tells its own color: a device report is no news.
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
  -- A light starts in color temperature.
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

T.section("a color still on its way at an off is the light's previous color, told ahead of the level")
do
  local green = { 0.3, 0.6 }
  --- The proxy's notifies since the mark, in order.
  local function said()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == PROXY then
        out[#out + 1] = s.command
      end
    end
    return out
  end
  --- A Previous mode light, on in blue, `ms` into a 20 s ramp to green.
  local function ramping(ms)
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(PREVIOUS_ON)
    proxy("ON")
    setColor(BLUE)
    colorTarget(green, 20000)
    run(ms)
    mark()
  end

  ramping(6000)
  proxy("OFF")
  T.eq(
    "an off 6 s into a 20 s color ramp: the proxy is told the color, then the level",
    said(),
    { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }
  )
  run(30000)
  T.eq(
    "the color the ramp was heading for, and nothing at its own end",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { green[1] }
  )
  -- The proxy's On in the Previous mode: the level, then the color it took.
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(green, 750)
  T.eq("a rated on carries that color, and the proxy's own send of it adds none", #colors(), 1)
  run(15000)
  T.eq("which the proxy is told once", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })

  ramping(2000)
  proxy("RAMP_TO_LEVEL", { LEVEL = 0, TIME = 4000 })
  run(3900)
  mark()
  run(200)
  T.eq(
    "a 4 s fade to off inside that color ramp: the color is told, then the level",
    said(),
    { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }
  )
  run(30000)
  T.eq("once, with nothing at the ramp's own end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })
end

T.section("the color a replaced fade carried arrives with the command that replaced it")
do
  local function toldColors()
    return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")
  end
  --- The one `field` the proxy got with `command` since the mark is `want`.
  local function near(name, command, field, want)
    local got = told(command, field)
    T.check(name, #got == 1 and math.abs(got[1] - want) < 1e-9, T.show(got))
  end
  --- A light off in blue, half way through a 10 s on that carries the On
  --- color. Returns the red, green and blue the On color is sent as.
  local function fading()
    local onColor = offInBlue()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
    run(5000)
    mark()
    return onColor
  end
  --- A Dim-To-Warm light half way through a 10 s fade from 50 % to 100 %,
  --- as a 4 s fade to off is sent.
  local function fadingOff()
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(ON, DIM)
    proxy("SET_LEVEL", { LEVEL = 50 })
    proxy("RAMP_TO_LEVEL", { LEVEL = 100, TIME = 10000 })
    run(5000)
    proxy("RAMP_TO_LEVEL", { LEVEL = 0, TIME = 4000 })
    run(2000)
    mark()
  end

  -- With no transition ESPHome puts every channel at its target at once.
  for _, c in ipairs({ { "a level at once", "SET_LEVEL", { LEVEL = 50 }, 0.5 }, { "an off", "OFF", nil, 0 } }) do
    local onColor = fading()
    proxy(c[2], c[3])
    T.eq(c[1] .. " in a rated on: it is sent with no color", #colors(), 0)
    T.eq(c[1] .. ": the proxy is told the On color with it", toldColors(), { ON[1] })
    report(onColor, c[4])
    run(15000)
    T.eq(c[1] .. ": and nothing after, the device's report included", toldColors(), { ON[1] })
  end

  -- Over a transition the color goes on to its target with the level.
  local onColor = fading()
  proxy("RAMP_TO_LEVEL", { LEVEL = 20, TIME = 4000 })
  report(onColor, 0.2)
  run(3900)
  T.eq("a rated level in a rated on: no color is told on the way", toldColors(), {})
  run(200)
  T.eq("the On color is told", toldColors(), { ON[1] })
  T.eq("at the level ramp's end", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })

  -- Half way through the on the color is half way; 2 s into the 4 s ramp
  -- that replaced it, half of the rest.
  fading()
  proxy("RAMP_TO_LEVEL", { LEVEL = 20, TIME = 4000 })
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  near(
    "Set Color Stop in a carried color: the proxy is told where it has got to",
    "LIGHT_COLOR_CHANGED",
    "LIGHT_COLOR_CURRENT_X",
    BLUE[1] + (ON[1] - BLUE[1]) * 0.75
  )
  T.eq("which the bulb is sent", #colors(), 1)
  run(15000)
  T.eq("and no color after", #toldColors(), 1)

  fading()
  proxy("RAMP_TO_LEVEL", { LEVEL = 20, TIME = 4000 })
  run(2000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop of the ramp that replaced a rated on: the level is sent alone", #colors(), 0)
  T.eq("and the proxy is told the On color with it", toldColors(), { ON[1] })
  run(15000)
  T.eq("and nothing after", toldColors(), { ON[1] })

  fadingOff()
  proxy("RAMP_TO_LEVEL", { LEVEL = 100, TIME = 4000 })
  near(
    "a fade up 2 s into a fade to off: from where the first fade's color has got to",
    "LIGHT_COLOR_CHANGING",
    "LIGHT_COLOR_CURRENT_X",
    mix(87.5)
  )
  run(15000)
  T.eq("and the proxy is told the mix for 100 % once", toldColors(), { mix(100) })
  -- The fade to off is at 38 %: the color it took on is the level's own.
  fadingOff()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop of that fade to off: the level is sent with a color", #colors(), 1)
  T.eq("the mix for the level it stopped at", toldColors(), { mix(38) })
  run(15000)
  T.eq("and nothing after", toldColors(), { mix(38) })

  for _, rate in ipairs({ 4000, 0 }) do
    local name = rate > 0 and "a scene step to a level over 4 s" or "a scene step to a level at once"
    onColor = fading()
    activate(levelStep(20, rate))
    report(onColor, 0.2)
    run(rate - 100)
    T.eq(name .. " in a rated on: the On color is told at its end", toldColors(), rate > 0 and {} or { ON[1] })
    run(15000)
    T.eq(name .. ": once", told("LIGHT_COLOR_CHANGED", "at"), { rate })
    proxy("CLEAR_ALL_SCENES")
  end

  -- A level that comes as the on's time is up, ahead of the on's own end.
  offInBlue()
  mark()
  C4:SetTimer(4000, function()
    proxy("SET_LEVEL", { LEVEL = 50 })
  end)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(15000)
  T.eq("a level as a rated on's time is up: the proxy is told the On color", toldColors(), { ON[1] })
  T.eq("with the level, at the on's last millisecond", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
end

T.section("a ramp part way through its time is where the light's easing has taken it, not a straight line")
do
  -- As measured on an ESPHome light: 91.8 % a quarter through a 10 s fade from
  -- 100 to 20, where a straight line gives 80, and 96 % 2 s into one to 30.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 10000 })
  run(2500)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop a quarter through: the light is held at 92", lastLevel(), { 92 / 100, 0 })
  T.eq("which the proxy is told", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 92 })
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 10000 })
  run(2000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 3000 })
  T.eq(
    "a fade to off 2 s in: its ramp is told from 96",
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    { 96 }
  )
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 10000 })
  run(5000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "half way through its time a fade is half way",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 60 }
  )
  -- A color is 10.4 % of its way a quarter through, the easing's value there.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(BLUE, 10000)
  run(2500)
  mark()
  proxy("SET_COLOR_STOP")
  local x = told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")[1]
  T.check(
    "a color stop a quarter through: the color is told 10.4 % of its way",
    x ~= nil and math.abs(x - (ON[1] + (BLUE[1] - ON[1]) * 0.1035)) < 1e-4,
    T.show(x)
  )
end

T.section("a ramp's end sends the light nothing: it reaches its level and color by itself")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  run(15000)
  T.eq("a level ramp: the light is sent its one command", lengths(), { 2000 })
  T.eq("and the proxy is told the level at its end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  mark()
  colorTarget(BLUE, 10000)
  run(15000)
  T.eq("a color ramp: the light is sent its one command", lengths(), { 10000 })
  T.eq("and the proxy is told the color at its end", told("LIGHT_COLOR_CHANGED", "at"), { 10000 })
  -- Sent again with no transition, a level put every channel at its target:
  -- a color fade begun in the ramp ended with it, and the reverse.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  run(300)
  colorTarget(BLUE, 10000)
  run(15000)
  T.eq("a color fade begun in a level ramp: nothing is sent as either ends", lengths(), { 2000, 10000 })
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  mark()
  colorTarget(BLUE, 2000)
  run(300)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 10000 })
  run(15000)
  T.eq("a level ramp begun in a color fade: nothing is sent as either ends", lengths(), { 2000, 10000 })
  -- The pre-on, and the on itself.
  offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(15000)
  T.eq("a rated on that carries the On color: nothing is sent at its end", lengths(), { 0, 4000 })
  T.eq("where the proxy is told the color", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
end

T.section("a command re-times the fade it sets nothing of, and the proxy is told")
do
  --- A color light on at full in the On color.
  local function onInColor()
    light({ ColorMode.COLOR_MODE_RGB })
    setColor(ON)
    mark()
  end
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end

  -- A level over 2 s and, 300 ms in, a color over 10 s: one 10 s fade of both.
  onInColor()
  level(30, 2000)
  run(300)
  colorTarget(BLUE, 10000)
  T.eq(
    "a color in a level ramp: the proxy is told the ramp again, over the color's time",
    told("LIGHT_BRIGHTNESS_CHANGING", "RATE"),
    { 2000, 10000 }
  )
  T.eq("from the 98 % the light has got to", told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"), { 100, 98 })
  run(15000)
  T.eq("the level is told when the color's time is up", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 10300 })
  T.eq("as the color is", told("LIGHT_COLOR_CHANGED", "at"), { 10300 })
  onInColor()
  level(30, 10000)
  run(2000)
  colorTarget(BLUE, 2000)
  run(15000)
  T.eq(
    "a short color in a long ramp: the level is told at the color's end",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 4000 }
  )

  onInColor()
  colorTarget(BLUE, 10000)
  run(2000)
  level(30, 2000)
  T.eq(
    "a level in a color fade: the proxy is told the fade again, over the level's time",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"),
    { 10000, 2000 }
  )
  T.eq(
    "from the color it has got to",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1], ON[1] + (BLUE[1] - ON[1]) * eased(2000 / 10000) }
  )
  run(15000)
  T.eq("the color is told when the level's time is up", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  T.eq("with the level", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 4000 })
  onInColor()
  colorTarget(BLUE, 2000)
  run(300)
  level(30, 10000)
  run(15000)
  T.eq(
    "a long ramp in a short color fade: the color is told at the ramp's end",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 10300 }
  )
  onInColor()
  colorTarget(BLUE, 10000)
  run(2000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30 })
  run(15000)
  T.eq("a level with no rate: the color arrives over the default rate", told("LIGHT_COLOR_CHANGED", "at"), { 2500 })

  -- With no transition every channel is at its target at once.
  onInColor()
  colorTarget(BLUE, 10000)
  run(2000)
  level(30, 0)
  T.eq("a level at once takes a color fade with it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
  run(15000)
  T.eq("the proxy is told the color then, and not at the fade's own end", told("LIGHT_COLOR_CHANGED", "at"), { 2000 })
  onInColor()
  level(30, 10000)
  run(2000)
  colorTarget(BLUE, 0)
  T.eq(
    "a color at once takes a level ramp with it",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )
  run(15000)
  T.eq(
    "the proxy is told the level then, and not at the ramp's own end",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 2000 }
  )

  -- 9.5 s into its 10 s a ramp to 30 % is within a rounding of it.
  onInColor()
  level(30, 10000)
  run(9500)
  colorTarget(BLUE, 2000)
  T.eq("a color as a level ramp arrives: the proxy is told the level", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 9500 })
  T.eq("and no ramp again", told("LIGHT_BRIGHTNESS_CHANGING", "RATE"), { 10000 })

  -- A scene step that sets a level alone, 2 s into a color fade.
  onInColor()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(30, 2000) })
  mark()
  colorTarget(BLUE, 10000)
  run(2000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a scene step to a level in a color fade: the proxy is told the fade again, over the step's time",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"),
    { 10000, 2000 }
  )
  run(15000)
  T.eq("and the color at the step's end", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  proxy("CLEAR_ALL_SCENES")
end

T.section("an off ends a color fade with it, and a fade to off takes the fade's end to its own")
do
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(BLUE, 10000)
  run(2000)
  mark()
  proxy("OFF")
  T.eq(
    "an off 2 s into a 10 s color fade: the proxy is told the color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] }
  )
  run(2000)
  mark()
  level(100, 10000)
  run(15000)
  T.eq(
    "an on over 10 s after it: the light is sent its pre-on and the on, and nothing as the fade's time is up",
    lengths(),
    { 0, 10000 }
  )
  T.eq("the proxy is told the level at the on's end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 10000 })
  T.eq("and nothing more of the color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), {})

  -- From 1 % a fade to off reads 0 half way: the color is told there, and a
  -- level sent then takes the light to it.
  light({ ColorMode.COLOR_MODE_RGB })
  level(1, 0)
  setColor(ON)
  colorTarget(BLUE, 10000)
  run(1000)
  level(0, 3000)
  run(1650)
  level(50, 2000)
  run(5000)
  mark()
  colorTarget({ 0.3, 0.6 }, 4000)
  T.eq(
    "a color told as a fade reaches off, and a level sent then: the next fade starts from that color",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { BLUE[1] }
  )

  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  mark()
  colorTarget(BLUE, 10000)
  run(2000)
  level(0, 3000)
  T.eq(
    "an off over 3 s in a color fade: the proxy is told the fade again, over the off's time",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"),
    { 10000, 3000 }
  )
  run(15000)
  T.eq("the color is told as the light goes off", told("LIGHT_COLOR_CHANGED", "at"), { 5000 })
  T.eq("and nothing at the fade's own end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })

  -- Sent on again as it reaches off, the fade to off has told its color.
  for _, rate in ipairs({ 2000, 0 }) do
    local name = "a level over " .. rate .. " ms as a fade to off in a color fade reaches off"
    light({ ColorMode.COLOR_MODE_RGB })
    setColor(ON)
    colorTarget(BLUE, 20000)
    run(1000)
    level(0, 4000)
    run(3990)
    mark()
    level(50, rate)
    run(15000)
    T.eq(name .. ": the color is told once, with it", told("LIGHT_COLOR_CHANGED", "at"), { 0 })
    T.eq(name .. ": and no fade of it again", told("LIGHT_COLOR_CHANGING", "at"), {})
  end
end

T.section("a stop holds its own fade where the light is and leaves the other the time it has left")
do
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end
  --- The notifies of an aspect, "COLOR" or "BRIGHTNESS", since the mark.
  local function notifies(aspect)
    return #told("LIGHT_" .. aspect .. "_CHANGING", "at") + #told("LIGHT_" .. aspect .. "_CHANGED", "at")
  end
  --- A color light 3 s into a 10 s fade to blue, with a 10 s ramp to 30 %
  --- begun 300 ms in: the ramp is at 91 %, and the color has 7.3 s left.
  local function both()
    light({ ColorMode.COLOR_MODE_RGB })
    setColor(ON)
    colorTarget(BLUE, 10000)
    run(300)
    level(30, 10000)
    run(2700)
    mark()
  end
  -- The color where the ramp re-timed it, and where the stop then finds it.
  local retimed = ON[1] + (BLUE[1] - ON[1]) * eased(300 / 10000)
  local stopped = retimed + (BLUE[1] - retimed) * eased(2700 / 10000)

  both()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a level stop with a color fading: the level is held over the color's 7.3 s", lastLevel(), { 91 / 100, 7300 })
  T.eq("the proxy is told the level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 91 })
  T.eq("and nothing of the color", notifies("COLOR"), 0)
  run(15000)
  T.eq("which it is told at the fade's own end", told("LIGHT_COLOR_CHANGED", "at"), { 7300 })
  T.eq("with nothing more sent", lengths(), { 7300 })

  -- The hold starts every channel again from where it is.
  both()
  proxy("SET_BRIGHTNESS_STOP")
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a color stop a second after it: the color is where the hold's fade has got to",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { stopped + (BLUE[1] - stopped) * eased(1000 / 7300) }
  )
  T.eq("and with nothing else fading, is sent with no transition", lengths(), { 0 })

  -- The mirror: the ramp first, the color 300 ms in.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  level(30, 10000)
  run(300)
  colorTarget(BLUE, 10000)
  run(2700)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a color stop with a level ramping: the color is held over the level's 7.3 s", lengths(), { 7300 })
  T.eq(
    "the proxy is told the color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] + (BLUE[1] - ON[1]) * eased(2700 / 10000) }
  )
  T.eq("and nothing of the level", notifies("BRIGHTNESS"), 0)
  run(15000)
  T.eq("which it is told", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 30 })
  T.eq("at the ramp's own end", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 7300 })

  both()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq("Stop Scene Ramp with both: the level is held, then the color lands both", lengths(), { 7300, 0 })
  T.eq("the proxy is told the level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 91 })
  T.eq("and the color", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { stopped })
  run(15000)
  T.eq("and nothing after", notifies("COLOR") + notifies("BRIGHTNESS"), 2)

  -- A rated on 100 ms old, still at 0 %, when a color re-times it over 5 s.
  offInBlue()
  level(100, 4000)
  run(100)
  colorTarget({ 0.3, 0.6 }, 5000)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop of a rated on with a color fading: the level is held, with no pre-on", lengths(), { 4000 })
  T.eq("where a fifth of its time has got to", lastLevel(), { fadeLevel(0, 100, 1000 / 5000) / 100, 4000 })

  -- With Dim-To-Warm a level sent alone would carry its mix.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  onMode(ON, DIM)
  proxy("ON")
  level(30, 10000)
  run(300)
  colorTarget(BLUE, 10000)
  run(2700)
  proxy("SET_COLOR_STOP")
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a level stop after the color's stop: nothing fading, it is sent with no transition", lengths(), { 0 })
  T.eq("and no color, the one stopped being kept", #colors(), 0)
  T.eq(
    "where the color stop's hold has got to",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(91, 30, 1000 / 7300) }
  )

  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(BLUE, 10000)
  run(2500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a color stop with nothing else fading is sent with no transition", lengths(), { 0 })
end

T.section("a full color goes out with its color mode named, so a light off in a white mode takes it")
do
  local RGBCT, CT = ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE, ColorMode.COLOR_MODE_COLOR_TEMPERATURE
  --- The color mode each command since the mark named, false where it named none.
  local function modes()
    local out = {}
    for _, s in ipairs(sent) do
      local cmd = s.binding == ESPHOME and s.command == "ENTITY_COMMAND" and DeserializeSafe(s.params.body)
      if cmd then
        out[#out + 1] = cmd.has_color_mode and cmd.color_mode or false
      end
    end
    return out
  end
  -- Off, ESPHome keeps the light's color mode unless the command names one,
  -- and a color temperature mode drops a color.
  light({ RGBCT, CT }, false)
  mark()
  colorTarget(ON, 0)
  T.eq("a color for a light that is off: it names the mode that holds a color", modes(), { RGBCT })
  light({ RGBCT, CT })
  mark()
  colorTarget(ON, 2000)
  run(1000)
  proxy("SET_COLOR_STOP")
  T.eq("a color ramp, and its stop", modes(), { RGBCT, RGBCT })
  activate(colorStep(nil, BLUE, 0))
  T.eq("a scene step's color", modes(), { RGBCT })
  activate(colorStep(50, ON, 2000))
  T.eq("with a level too", modes(), { RGBCT })
  proxy("CLEAR_ALL_SCENES")
  light({ ColorMode.COLOR_MODE_RGB })
  mark()
  colorTarget(ON, 0)
  T.eq("a light with color alone: its one mode", modes(), { ColorMode.COLOR_MODE_RGB })
  -- A color temperature is left as it was: its mode is the light's to choose.
  local toXY, toCCT = C4.ColorCCTtoXY, C4.ColorXYtoCCT
  function C4:ColorCCTtoXY(kelvin)
    return kelvin / 10000, 0.4
  end
  function C4:ColorXYtoCCT(x)
    return x * 10000
  end
  light({ RGBCT, CT })
  mark()
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq("a color temperature: no mode is named", modes(), { false })
  light({ RGBCT, CT }, false)
  local x, y = C4:ColorCCTtoXY(3000)
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = x,
    COLOR_PRESET_COLOR_Y = y,
    COLOR_PRESET_COLOR_MODE = 1,
  })
  mark()
  proxy("ON")
  T.eq("the color temperature an on carries: its mode, as before", modes(), { CT })
  C4.ColorCCTtoXY, C4.ColorXYtoCCT = toXY, toCCT
end

T.section("a color for a light that is off, or on its way off, is told at once and never turns it on")
do
  local green = { 0.3, 0.6 }
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end
  --- The state and transition of the last command sent since the mark.
  local function lastState()
    for i = #sent, 1, -1 do
      local s = sent[i]
      if s.binding == ESPHOME and s.command == "ENTITY_COMMAND" then
        local cmd = DeserializeSafe(s.params.body)
        return { cmd.state, cmd.transition_length }
      end
    end
  end

  -- 2 s into a 5 s fade to off the light is at 68 %, with 3 s left.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  mark()
  level(0, 5000)
  run(2000)
  colorTarget(BLUE, 1000)
  T.eq("a color 2 s into a 5 s fade to off: it is sent as an off, over the 3 s left", lastState(), { false, 3000 })
  T.eq("the proxy is told the color at once", told("LIGHT_COLOR_CHANGED", "at"), { 2000 })
  T.eq("with no color ramp", told("LIGHT_COLOR_CHANGING", "at"), {})
  T.eq("and the fade once, as it began", told("LIGHT_BRIGHTNESS_CHANGING", "at"), { 0 })
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop a second on: the level alone, the color being kept", #colors(), 0)
  T.eq(
    "where the fade, begun again with the color, has got to",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { fadeLevel(fadeLevel(100, 0, 2000 / 5000), 0, 1000 / 3000) }
  )
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  mark()
  level(0, 5000)
  run(2000)
  colorTarget(BLUE, 1000)
  run(15000)
  T.eq("left to run, the light is told off", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
  T.eq("when the fade's own time is up", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 5000 })
  T.eq("having been sent nothing more", lengths(), { 5000, 3000 })

  -- A color fade the off took over: its stop is an off too.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  colorTarget(BLUE, 10000)
  run(1000)
  level(0, 4000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a color stop in a fade to off: an off, over the 3 s left", lastState(), { false, 3000 })

  -- A scene step that sets a color alone is a color command here.
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, BLUE, 1000) })
  mark()
  level(0, 5000)
  run(2000)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq("a scene step's color 2 s into a 5 s fade to off: an off too, over the 3 s left", lastState(), { false, 3000 })
  T.eq("the proxy is told the color at once", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
  T.eq("and the fade once, as it began", told("LIGHT_BRIGHTNESS_CHANGING", "at"), { 0 })
  run(15000)
  T.eq("left to run, the light is told off", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
  T.eq("when the fade's own time is up", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 5000 })
  proxy("CLEAR_ALL_SCENES")
  light({ ColorMode.COLOR_MODE_RGB }, false)
  setColor(BLUE)
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = ON[1],
    LIGHT_COLOR_TARGET_Y = ON[2],
    LIGHT_COLOR_TARGET_PRESET_ID = 5,
  })
  activate(colorStep(nil, green, 1000) .. levelStep(50))
  T.eq("a scene step's color for a light that is off: it is sent at once, as an off", lastState(), { false, 0 })
  T.eq("and the proxy is told it at once", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })
  T.eq("as no preset's", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_PRESET_ID"), {})
  T.eq("with no color ramp", told("LIGHT_COLOR_CHANGING", "at"), {})
  run(15000)
  T.eq(
    "the scene's next step, a level, runs when the step's time is up",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 1000 }
  )
  proxy("CLEAR_ALL_SCENES")
  light({ ColorMode.COLOR_MODE_RGB }, false)
  setColor(BLUE)
  activate(colorStep(50, green, 0))
  T.eq("a scene step that sets a level too turns the light on", lastState(), { true, 0 })
  proxy("CLEAR_ALL_SCENES")

  light({ ColorMode.COLOR_MODE_RGB }, false)
  setColor(BLUE)
  mark()
  colorTarget(green, 5000)
  T.eq("a color over 5 s for a light that is off: it is sent at once, as an off", lastState(), { false, 0 })
  T.eq("and the proxy is told it at once", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { green[1] })
  T.eq("with no color ramp", told("LIGHT_COLOR_CHANGING", "at"), {})
  run(2000)
  mark()
  level(100, 4000)
  run(15000)
  T.eq("an on over 4 s, 2 s later: nothing is sent when the color's 5 s are up", lengths(), { 0, 4000 })
  T.eq("and the proxy is told no color again", told("LIGHT_COLOR_CHANGED", "at"), {})

  -- A fade up is on: its color fades with it.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  setColor(BLUE)
  level(100, 4000)
  run(1000)
  mark()
  colorTarget(green, 2000)
  T.eq("a color in a fade up from off: it is sent as an on, over its own time", lastState(), { true, 2000 })
  T.eq("and the proxy is told a color ramp", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"), { 2000 })
end

T.section("a scene step's color that the light cannot take is none: nothing of it is sent or told")
do
  -- The step's fields are built from the light's modes, and a dimmer has none for a color.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  activate(colorStep(nil, { 0.3, 0.6 }, 3000))
  T.eq("a color alone, on a light with no color: no command", commands(), 0)
  T.eq("and no color fade told", told("LIGHT_COLOR_CHANGING", "at"), {})
  run(4000)
  activate(colorStep(40, BLUE, 3000))
  T.eq("with a level: the level goes out", commands(), 1)
  T.eq("as a fade of the level", told("LIGHT_BRIGHTNESS_CHANGING", "at"), { 0 })
  T.eq("with no color fade beside it", told("LIGHT_COLOR_CHANGING", "at"), {})
  run(4000)
  T.eq("so none is left with no end", told("LIGHT_COLOR_CHANGED", "at"), {})
  T.eq("and the level's is told", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 3000 })
  -- A light that is off holds a color for its next on, but not one it cannot take.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  activate(colorStep(nil, { 0.3, 0.6 }, 3000))
  T.eq("a color alone, on such a light that is off: no command", commands(), 0)
  T.eq("and no color told as held", told("LIGHT_COLOR_CHANGED", "at"), {})
  light({ ColorMode.COLOR_MODE_COLOR_TEMPERATURE }, false)
  activate(colorStep(nil, { 0.3, 0.6 }, 3000))
  T.eq("a full color alone, on a color temperature light that is off: no command", commands(), 0)
  T.eq("and none told", told("LIGHT_COLOR_CHANGED", "at"), {})
end

T.section("a color with no rate takes the default rate, the brightness one when none was ever set")
do
  local function colorNoRate(xy)
    proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = xy[1], LIGHT_COLOR_TARGET_Y = xy[2] })
  end
  for _, key in ipairs({ "color_rate_default", "brightness_rate_default" }) do
    persist:delete(key)
  end
  light({ ColorMode.COLOR_MODE_RGB })
  setColor(ON)
  mark()
  colorNoRate(BLUE)
  T.eq("with no default ever set: it goes out over 500 ms, as a level does", lengths(), { 500 })
  T.eq("which the proxy is told", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_RATE"), { 500 })
  proxy("UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = 750 })
  mark()
  colorNoRate(ON)
  T.eq("with a default rate set: over that", lengths(), { 750 })
  proxy("UPDATE_COLOR_RATE_DEFAULT", { RATE = 0 })
  mark()
  colorNoRate(BLUE)
  T.eq("with a default of 0: at once", lengths(), { 0 })
  for _, key in ipairs({ "color_rate_default", "brightness_rate_default" }) do
    persist:delete(key)
  end
end

T.section("a report during a ramp of a level or color the driver did not send is another client's, taken as news")
do
  local RGB = ColorMode.COLOR_MODE_RGB
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end
  --- A report from a light of kind `modes`: a state, and a color if given,
  --- in the RGB color mode or `mode`.
  local function push(modes, state, rgb, mode)
    state.color_mode = rgb and (mode or RGB) or state.color_mode
    state.red, state.green, state.blue = (rgb or {})[1], (rgb or {})[2], (rgb or {})[3]
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = modes }),
      state = SerializeSafe(state),
    })
  end
  local dimmer = { ColorMode.COLOR_MODE_BRIGHTNESS }

  -- ESPHome reports a light's targets: 100 ms after a command, that command's.
  light(dimmer)
  level(30, 10000)
  run(100)
  push(dimmer, { state = true, brightness = 0.3 })
  T.eq("the report of the level a ramp is heading for: nothing is told", told("LIGHT_BRIGHTNESS_CHANGED", "at"), {})
  run(1900)
  push(dimmer, { state = true, brightness = 0.8 })
  T.eq(
    "a level set elsewhere 2 s into a 10 s ramp: the proxy is told it",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 80 }
  )
  T.eq("at once", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  run(15000)
  T.eq("the ramp is over: a stop sends nothing", commands(), 0)
  T.eq("and the proxy is told nothing when its time is up", told("LIGHT_BRIGHTNESS_CHANGED", "at"), {})
  light(dimmer)
  level(30, 10000)
  run(2000)
  push(dimmer, { state = false })
  T.eq(
    "the light turned off elsewhere: the proxy is told",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 0 }
  )
  -- The light's last report again, ahead of the ramp's own, is of a command
  -- before the ramp's. After the ramp's own it is another client's.
  light(dimmer)
  level(30, 10000)
  run(10)
  push(dimmer, { state = true, brightness = 1.0 })
  T.eq(
    "the report of the level a ramp began from, ahead of the ramp's own: nothing is told",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    {}
  )
  run(90)
  push(dimmer, { state = true, brightness = 0.3 })
  run(1900)
  push(dimmer, { state = true, brightness = 1.0 })
  T.eq(
    "the light set elsewhere to the level the ramp began at: the proxy is told that too",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 100 }
  )

  -- A float a light has nothing to report for comes as NaN.
  light(dimmer)
  level(30, 10000)
  run(100)
  push(dimmer, { state = true, brightness = 0.3 }, { 0 / 0, 0 / 0, 0 / 0 })
  T.eq("a report whose color is no number, in a ramp: nothing is told", told("LIGHT_BRIGHTNESS_CHANGED", "at"), {})

  -- A report can come after the next command has gone out.
  light(dimmer)
  level(30, 10000)
  run(50)
  level(60, 2000)
  run(50)
  push(dimmer, { state = true, brightness = 0.3 })
  run(100)
  push(dimmer, { state = true, brightness = 0.6 })
  T.eq(
    "the report of a level sent before the one a ramp is heading for: nothing is told",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    {}
  )
  push(dimmer, { state = true, brightness = 0.3 })
  T.eq(
    "that level again, after the ramp's own has been reported: it is another client's",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )
  -- A light may report two commands sent close together once, as the second.
  light(dimmer)
  level(30, 10000)
  run(50)
  level(60, 2000)
  run(100)
  push(dimmer, { state = true, brightness = 0.6 })
  push(dimmer, { state = true, brightness = 0.3 })
  T.eq(
    "a level whose own report never came, set elsewhere after the next one's: it is another client's",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )
  light(dimmer, false)
  level(100, 4000)
  push(dimmer, { state = true, brightness = 0.0039 })
  push(dimmer, { state = true, brightness = 1.0 })
  run(15000)
  T.eq(
    "the reports of a rated on's pre-on and of the on: the proxy is told the on's end alone",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 4000 }
  )
  -- A scene step's off goes out with no brightness.
  light(dimmer)
  activate(levelStep(0, 10000))
  run(100)
  push(dimmer, { state = false })
  run(15000)
  T.eq(
    "the report of a scene step's fade to off: the proxy is told off at the step's end alone",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 10000 }
  )
  proxy("CLEAR_ALL_SCENES")

  -- A command sent while the light is disconnected draws no report.
  light(dimmer)
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
  proxy("OFF")
  proxy("OFF")
  push(dimmer, { state = true, brightness = 1.0 })
  mark()
  level(30, 10000)
  run(50)
  push(dimmer, { state = false })
  T.eq(
    "offs sent while disconnected, and the light then turned off elsewhere in a ramp: the proxy is told",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 0 }
  )
  -- What was sent before a disconnect is forgotten with it.
  light(dimmer)
  level(30, 0)
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
  push(dimmer, { state = true, brightness = 1.0 })
  mark()
  level(60, 10000)
  run(2000)
  push(dimmer, { state = true, brightness = 0.3 })
  T.eq(
    "a level sent before a disconnect, set elsewhere in a ramp after it: the proxy is told",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )

  -- Green, a color the driver never sent, reads as x 1/3 through the stubs.
  local foreign = { 0, 1, 0 }
  light({ RGB })
  local blue = setColor(BLUE)
  setColor(ON)
  mark()
  colorTarget(BLUE, 10000)
  run(100)
  push({ RGB }, { state = true, brightness = 1.0 }, blue)
  T.eq("the report of the color a fade is heading for: nothing is told", told("LIGHT_COLOR_CHANGED", "at"), {})
  push({ RGB }, { state = true, brightness = 1.0 }, { blue[1] + 0.003, blue[2] - 0.003, blue[3] })
  T.eq("nor for that color as a light may round it", told("LIGHT_COLOR_CHANGED", "at"), {})
  run(1900)
  push({ RGB }, { state = true, brightness = 1.0 }, foreign)
  T.eq(
    "a color set elsewhere 2 s into a 10 s fade: the proxy is told it",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 1 / 3 }
  )
  T.eq("at once", told("LIGHT_COLOR_CHANGED", "at"), { 2000 })
  mark()
  proxy("SET_COLOR_STOP")
  run(15000)
  T.eq("the fade is over: a stop sends nothing", commands(), 0)
  T.eq("and the proxy is told nothing when its time is up", told("LIGHT_COLOR_CHANGED", "at"), {})
  light({ RGB })
  blue = setColor(BLUE)
  setColor(ON)
  mark()
  colorTarget(BLUE, 10000)
  run(2000)
  push({ RGB }, { state = true, brightness = 0.5 }, blue)
  T.eq(
    "a level set elsewhere in a color fade: the proxy is told the level",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 50 }
  )
  T.eq("and the color, the fade being over at the light too", told("LIGHT_COLOR_CHANGED", "at"), { 2000 })
  mark()
  proxy("SET_COLOR_STOP")
  run(15000)
  T.eq("a stop sends nothing", commands(), 0)
  T.eq("and the proxy is told nothing at the fade's own end", told("LIGHT_COLOR_CHANGED", "at"), {})
  light({ RGB })
  setColor(ON)
  mark()
  level(30, 10000)
  colorTarget(BLUE, 10000)
  run(2000)
  push({ RGB }, { state = true, brightness = 0.3 }, foreign)
  T.eq(
    "a color set elsewhere with a level ramping too: the proxy is told the level the ramp was heading for",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 30 }
  )
  T.eq("with the color", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  run(15000)
  T.eq("the ramp is over as well: a stop sends nothing", commands(), 0)
  T.eq("and the proxy is told nothing when its time is up", told("LIGHT_BRIGHTNESS_CHANGED", "at"), {})
  -- With no color on its way, a level set elsewhere is told alone.
  light({ RGB })
  blue = setColor(BLUE)
  push({ RGB }, { state = true, brightness = 1.0 }, blue)
  mark()
  level(30, 10000)
  run(2000)
  push({ RGB }, { state = true, brightness = 0.8 }, blue)
  T.eq(
    "a level set elsewhere in a ramp with no color fading: the proxy is told the level",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 80 }
  )
  T.eq("and no color", told("LIGHT_COLOR_CHANGED", "at"), {})
  light({ RGB })
  blue = setColor(BLUE)
  push({ RGB }, { state = true, brightness = 1.0 }, blue)
  mark()
  level(30, 10000)
  run(100)
  push({ RGB }, { state = true, brightness = 0.3 }, blue)
  run(1900)
  push({ RGB }, { state = true, brightness = 0.3 }, foreign)
  T.eq(
    "a color set elsewhere in a ramp with no color fading: the proxy is told the color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 1 / 3 }
  )
  T.eq("and the level the ramp was heading for, then", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 2000 })
  -- A light reports no red at all while it has none.
  light({ RGB })
  push({ RGB }, { state = true, brightness = 1.0 }, { nil, 1, 0 })
  mark()
  level(30, 10000)
  run(100)
  push({ RGB }, { state = true, brightness = 0.3 }, { nil, 1, 0 })
  run(1900)
  push({ RGB }, { state = true, brightness = 0.3 }, { 0.5, 1, 0 })
  T.eq(
    "a color set elsewhere that differs in the one field the light had not reported: the ramp is over then",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 2000 }
  )
  -- The report of a level sent before the last is the driver's own.
  light({ RGB })
  local on = setColor(ON)
  level(30, 0)
  level(60, 0)
  mark()
  colorTarget(BLUE, 10000)
  push({ RGB }, { state = true, brightness = 0.3 }, on)
  run(15000)
  T.eq(
    "the report of a level sent before the last, in a color fade: the fade runs on to its end",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 10000 }
  )

  -- The driver's own color, in a color mode it did not name.
  light({ RGB, ColorMode.COLOR_MODE_RGB_WHITE })
  blue = setColor(BLUE)
  setColor(ON)
  mark()
  colorTarget(BLUE, 10000)
  run(100)
  push({ RGB, ColorMode.COLOR_MODE_RGB_WHITE }, { state = true, brightness = 1.0 }, blue)
  run(1900)
  push(
    { RGB, ColorMode.COLOR_MODE_RGB_WHITE },
    { state = true, brightness = 1.0 },
    blue,
    ColorMode.COLOR_MODE_RGB_WHITE
  )
  run(15000)
  T.eq(
    "the light put in another color mode elsewhere: the fade is over then",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 2000 }
  )

  -- A light in a color it was given elsewhere, which the driver never sent.
  light({ RGB })
  push({ RGB }, { state = true, brightness = 1.0 }, foreign)
  mark()
  colorTarget(BLUE, 10000)
  run(10)
  push({ RGB }, { state = true, brightness = 1.0 }, foreign)
  T.eq(
    "the report of the color a fade began from, ahead of the fade's own: nothing is told",
    told("LIGHT_COLOR_CHANGED", "at"),
    {}
  )
  run(90)
  push({ RGB }, { state = true, brightness = 1.0 }, blue)
  push({ RGB }, { state = true, brightness = 1.0 }, foreign)
  T.eq(
    "that color set again after the fade's own report: the proxy is told the fade is over",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 1 / 3 }
  )

  -- A rated on that carries the On color.
  local onColor = offInBlue()
  push({ RGB }, { state = false }, foreign)
  mark()
  level(100, 4000)
  push({ RGB }, { state = true, brightness = 0.0039 }, foreign)
  push({ RGB }, { state = true, brightness = 1.0 }, onColor)
  run(15000)
  T.eq(
    "a rated on's pre-on reported in a color the light was given elsewhere: the proxy is told the on's end alone",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 4000 }
  )
  T.eq("with its On color", told("LIGHT_COLOR_CHANGED", "at"), { 4000 })
  offInBlue()
  mark()
  level(100, 4000)
  run(1000)
  push({ RGB }, { state = true, brightness = 1.0 }, foreign)
  T.eq(
    "a color set elsewhere in a rated on: the proxy is told it",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 1 / 3 }
  )
  T.eq("and the level the on was heading for", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 100 })
  run(15000)
  T.eq("and not the On color at the on's end", told("LIGHT_COLOR_CHANGED", "at"), { 1000 })
  T.eq("nor the level again", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 1000 })
  offInBlue()
  mark()
  level(100, 4000)
  run(1000)
  push({ RGB }, { state = true, brightness = 0.4 }, onColor)
  T.eq(
    "a level set elsewhere in a rated on: the proxy is told it",
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 40 }
  )
  T.eq("and the On color with it", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  run(15000)
  T.eq("and not again when the on's time is up", told("LIGHT_COLOR_CHANGED", "at"), { 1000 })

  -- A color temperature goes out in mireds, 2700 K as 370.37.
  local CT = ColorMode.COLOR_MODE_COLOR_TEMPERATURE
  local toXY, toCCT = C4.ColorCCTtoXY, C4.ColorXYtoCCT
  function C4:ColorCCTtoXY(kelvin)
    return kelvin / 10000, 0.4
  end
  function C4:ColorXYtoCCT(x)
    return x * 10000
  end
  local function kelvin(target, rate)
    proxy("SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = target,
      LIGHT_COLOR_TARGET_COLOR_RATE = rate,
    })
  end
  light({ CT })
  mark()
  kelvin(2700, 10000)
  run(100)
  push({ CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 370.3703613 })
  push({ CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 370.4 })
  T.eq(
    "the report of the color temperature a fade is heading for, as a light may round it: nothing is told",
    told("LIGHT_COLOR_CHANGED", "at"),
    {}
  )
  run(1900)
  push({ CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 200 })
  T.eq(
    "a color temperature set elsewhere in the fade: the proxy is told at once",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 2000 }
  )
  light({ CT })
  mark()
  kelvin(2700, 10000)
  run(50)
  push({ CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 200 })
  T.eq("and one set elsewhere ahead of the fade's own report", told("LIGHT_COLOR_CHANGED", "at"), { 50 })
  local RGBCT = ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE
  light({ RGBCT })
  mark()
  kelvin(2700, 10000)
  run(100)
  push({ RGBCT }, { state = true, brightness = 1.0, color_temperature = 370.3703613 }, { 1, 1, 1 }, RGBCT)
  run(1900)
  push({ RGBCT }, { state = true, brightness = 1.0, color_temperature = 370.3703613 }, foreign, RGBCT)
  T.eq(
    "a full color set elsewhere in the fade, the color temperature left as it was: the fade is over then",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 2000 }
  )
  -- The light's range here is 153 to 500 mireds, 6536 to 2000 K, and it
  -- holds a color temperature beyond an end to that end.
  light({ CT })
  mark()
  kelvin(1800, 10000)
  T.eq(
    "a color temperature beyond the light's range: the proxy is told a fade to the range's end",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"),
    { 2000 / 10000 }
  )
  run(100)
  push({ CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 500 })
  run(15000)
  T.eq(
    "the light's report of that end is the driver's own: the color is told at the fade's end",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 10000 }
  )
  light({ CT })
  mark()
  kelvin(8000, 10000)
  run(100)
  push({ CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 153 })
  run(15000)
  T.eq("one beyond the other end: that end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { 6536 / 10000 })
  T.eq("told at the fade's end too", told("LIGHT_COLOR_CHANGED", "at"), { 10000 })
  light({ CT })
  mark()
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 1800 / 10000,
    LIGHT_COLOR_TARGET_Y = 0.4,
    LIGHT_COLOR_TARGET_MODE = 1,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq(
    "and one given as its point, as a preset is: the range's end",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 2000 / 10000 }
  )
  C4.ColorCCTtoXY, C4.ColorXYtoCCT = toXY, toCCT
end

T.section("a fade a command re-times is read as the command goes out, not once the proxy has been told")
do
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end
  --- A color light on at full in the On color, with Dim-To-Warm if `warm`, on
  --- a controller that takes 10 ms over each message to the device or the proxy.
  local function slowLight(warm)
    light({ ColorMode.COLOR_MODE_RGB })
    if warm then
      onMode(ON, DIM)
    end
    setColor(ON)
    local send = SendToProxy
    function SendToProxy(...)
      send(...)
      now = now + 10
    end
    mark()
  end
  --- The level a stop holds the light at.
  local function stoppedAt()
    mark()
    proxy("SET_BRIGHTNESS_STOP")
    return told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
  end

  -- Half way through 1.5 s a fade is at its steepest: 20 ms is 2 % of 100 to 20.
  slowLight()
  level(20, 1500)
  run(730)
  colorTarget(BLUE, 1500)
  T.eq(
    "a color 750 ms into a level ramp: the ramp is told again from the level it was at as the color went out",
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    { 100, fadeLevel(100, 20, 750 / 1500) }
  )
  run(720)
  T.eq("and begins again then: a stop 750 ms on is half way from there", stoppedAt(), { fadeLevel(60, 20, 750 / 1500) })

  local half = ON[1] + (BLUE[1] - ON[1]) * eased(750 / 1500)
  slowLight()
  colorTarget(BLUE, 1500)
  run(730)
  level(20, 1500)
  T.eq(
    "a level 750 ms into a color fade: the fade is told again from the color it was at as the level went out",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1], half }
  )
  run(720)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "and begins again then: a stop 750 ms on is half way from there",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { half + (BLUE[1] - half) * eased(750 / 1500) }
  )

  -- With Dim-To-Warm the level carries a color of its own, which replaces the fade.
  slowLight(true)
  colorTarget(BLUE, 1500)
  run(730)
  level(20, 1500)
  T.eq(
    "a level that carries its color, 750 ms into a color fade: its color is told from where the fade was then",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1], half }
  )

  -- A color for a light fading to off restarts the fade's record, untold.
  slowLight()
  level(0, 1500)
  run(730)
  colorTarget(BLUE, 1000)
  run(80)
  T.eq(
    "a color 750 ms into a fade to off: a stop 100 ms on reads the fade from where the color found it",
    stoppedAt(),
    { fadeLevel(50, 0, 100 / 750) }
  )

  -- A color stop holds over the 770 ms the level has left, 730 ms into it.
  slowLight()
  colorTarget(BLUE, 3000)
  level(20, 1500)
  run(700)
  proxy("SET_COLOR_STOP")
  run(365)
  T.eq(
    "a color stop in a level ramp: a level stop half the hold on reads the ramp from where the stop found it",
    stoppedAt(),
    { fadeLevel(fadeLevel(100, 20, 730 / 1500), 20, 385 / 770) }
  )

  -- A scene step tells its own fade, 10 ms, and then sends.
  slowLight()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(20, 1500) })
  colorTarget(BLUE, 1500)
  run(730)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a scene step's level in a color fade: the fade is told again from the color it was at as the step went out",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1], ON[1] + (BLUE[1] - ON[1]) * eased(760 / 1500) }
  )
  proxy("CLEAR_ALL_SCENES")
  slowLight()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, BLUE, 1500) })
  level(20, 1500)
  run(730)
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a scene step's color in a level ramp: the ramp is told again from the level it was at as the step went out",
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    { 100, fadeLevel(100, 20, 760 / 1500) }
  )
  proxy("CLEAR_ALL_SCENES")
end

---------------------------------------------------------------------------
-- The proxy's setup
---------------------------------------------------------------------------

--- An answer the proxy gave GET_SETUP on OS 4.3.0, as it came.
local function setupFile(name)
  local f = assert(io.open(HERE .. "/light_setup/" .. name, "rb"))
  local xml = f:read("*a")
  f:close()
  return xml
end

--- `xml` with the text of each tag in `tags` replaced, or the tag taken out
--- where it is given false.
local function withTags(xml, tags)
  for tag, value in pairs(tags) do
    xml =
      xml:gsub("<" .. tag .. ">.-</" .. tag .. ">", value and ("<" .. tag .. ">" .. value .. "</" .. tag .. ">") or "")
  end
  return xml
end

local SETUP_KEYS = {
  "color_on_mode",
  "brightness_on_mode",
  "brightness_on_mode_preset",
  "brightness_rate_default",
  "color_rate_default",
}

--- Forget what the driver stores of the proxy's on modes, presets and rates.
local function forgetSetup()
  for _, key in ipairs({ "color_presets", "brightness_presets", "previous_color" }) do
    persist:delete(key)
  end
  for _, key in ipairs(SETUP_KEYS) do
    persist:delete(key)
  end
end

--- The color temperature, in kelvin, of each command since the mark that had one.
local function kelvins()
  local out = {}
  for _, s in ipairs(sent) do
    local cmd = s.binding == ESPHOME and s.command == "ENTITY_COMMAND" and DeserializeSafe(s.params.body)
    if cmd and cmd.has_color_temperature then
      out[#out + 1] = math.floor(1e6 / cmd.color_temperature + 0.5)
    end
  end
  return out
end

--- The x of each color the proxy was told as arrived since the mark.
local function colorsTold()
  return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")
end

-- A light with a color and a color temperature, as the one setup-643.xml is of.
local RGBCT, CT = ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE, ColorMode.COLOR_MODE_COLOR_TEMPERATURE
local CCT_MODE = 1

-- Kelvin as x over a fixed y, so a preset's color temperature is its x.
function C4:ColorCCTtoXY(kelvin)
  return kelvin / 10000, 0.4
end
function C4:ColorXYtoCCT(x)
  return x * 10000
end

T.section("a light the proxy never sent its Color On Mode reads it from the proxy's setup at start")
do
  -- The proxy sends a mode when it changes and a preset when it is made: a
  -- light left in the mode it was made with has its presets and no mode.
  forgetSetup()
  proxySetup = ""
  light({ RGBCT, CT }, false)
  for _, p in ipairs({
    { 1, "On Color", 0.380438, 0.376746 },
    { 2, "Dim Color", 0.526676, 0.413297 },
    { 10, "Previous On", 0.497642, 0.415248 },
  }) do
    proxy(
      "UPDATE_COLOR_PRESET",
      { COMMAND = "ADDED", ID = p[1], NAME = p[2], COLOR_X = p[3], COLOR_Y = p[4], COLOR_MODE = CCT_MODE }
    )
  end
  proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "ADDED", ID = 10, NAME = "Previous On", LEVEL = 20 })
  proxySetup = setupFile("setup-607.xml")
  restart({ RGBCT, CT }, false)
  proxy("SET_LEVEL", { LEVEL = 50 })
  -- Dim-To-Warm between the device's On Color and Dim Color: 3804 K and
  -- 5267 K here, 4536 K half way.
  T.eq("a level carries the Dim-To-Warm mix as a color temperature", kelvins(), { 4536 })
  T.eq("and the proxy is told it", colorsTold(), { 0.453557 })
  proxy(
    "UPDATE_COLOR_PRESET",
    { COMMAND = "MODIFIED", ID = 1, NAME = "On Color", COLOR_X = 0.3, COLOR_Y = 0.4, COLOR_MODE = CCT_MODE }
  )
  mark()
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("an edit of the On Color alone then moves the on color", kelvins(), { 3000 })
  T.eq("which the proxy is told", colorsTold(), { 0.3 })
end

T.section("a preset the setup names is found by its id and its origin together")
do
  -- This light's Dim-To-Warm is between the Color Agent's Sunset (8) and Blue
  -- Bonnet (10), and the device's own preset 10 is Previous On, which the
  -- driver has stored.
  forgetSetup()
  proxySetup = ""
  light({ RGBCT, CT }, false)
  proxy(
    "UPDATE_COLOR_PRESET",
    { COMMAND = "ADDED", ID = 10, NAME = "Previous On", COLOR_X = 0.305692, COLOR_Y = 0.189781, COLOR_MODE = 0 }
  )
  local mixX, mixY = 0.142639 + (0.608506 - 0.142639) * 0.5, 0.0993936 + (0.357644 - 0.0993936) * 0.5
  local between = setColor({ mixX, mixY })
  proxySetup = setupFile("setup-626.xml")
  restart({ RGBCT, CT }, false)
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("the mix is between the Color Agent's two", colors(), { between })
  T.eq("which the proxy is told", colorsTold(), { mixX })
end

T.section("a setup with no fade preset is Previous for the device's preset 10 and a preset for any other")
do
  local noFade = { light_color_on_mode_fade_preset_id = 0, light_color_on_mode_fade_preset_origin = 0 }
  --- A light started with `setup`, on in green and then off: the green it
  --- was sent.
  local function offInGreen(setup)
    forgetSetup()
    proxySetup = setup
    restart({ RGBCT, CT })
    local green = setColor({ 0.3, 0.6 })
    proxy("OFF")
    mark()
    return green
  end
  local setup = withTags(setupFile("setup-607.xml"), noFade)
  local green = offInGreen(withTags(setup, { light_color_on_mode_preset_id = 10 }))
  proxy("ON")
  T.eq("Previous: an on is in the color the light went off in", colors(), { green })
  offInGreen(setup)
  proxy("ON")
  T.eq("a preset: an on is in the On Color", { kelvins(), colors() }, { { 3804 }, {} })
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("and a level after it carries no color", { kelvins(), colors() }, { {}, {} })
end

T.section("a setup that cannot be read, or that names no on mode, leaves what the driver has stored")
do
  --- What the driver has stored under each key the setup can write.
  local function stored()
    local out = {}
    for _, key in ipairs(SETUP_KEYS) do
      out[key] = persist:get(key, false)
    end
    return out
  end
  forgetSetup()
  proxySetup = ""
  light({ RGBCT, CT }, false)
  onMode(ON, DIM)
  proxy("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 3, BRIGHTNESS_PRESET_LEVEL = 40 })
  proxy("UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = 1234 })
  local before = stored()
  local setup, none = setupFile("setup-607.xml"), {}
  for _, tag in ipairs({
    "light_color_on_mode_preset_id",
    "light_color_on_mode_preset_origin",
    "light_color_on_mode_fade_preset_id",
    "light_color_on_mode_fade_preset_origin",
    "light_brightness_on_mode_preset_id",
    "light_brightness_rate_default",
    "light_color_rate_default",
  }) do
    none[tag] = false
  end
  for _, c in ipairs({
    { "no answer", false },
    { "an empty answer", "" },
    { "an answer that is not whole", setup:sub(1, 2000) },
    { "a setup with none of the tags", withTags(setup, none) },
  }) do
    proxySetup = c[2]
    restart({ RGBCT, CT }, false)
    T.eq(c[1] .. ": nothing stored changes", stored(), before)
  end
  -- A preset the setup names and does not list has no color or level to
  -- store: the mode stored stands.
  for _, c in ipairs({
    { "an on preset that is not listed", "color_on_mode", { light_color_on_mode_preset_id = 99 } },
    { "a fade preset that is not listed", "color_on_mode", { light_color_on_mode_fade_preset_id = 99 } },
    { "no on origin", "color_on_mode", { light_color_on_mode_preset_origin = false } },
    { "no fade origin", "color_on_mode", { light_color_on_mode_fade_preset_origin = false } },
    { "a brightness preset that is not listed", "brightness_on_mode", { light_brightness_on_mode_preset_id = 99 } },
  }) do
    local had = persist:get(c[2], false)
    proxySetup = withTags(setup, c[3])
    restart({ RGBCT, CT }, false)
    T.eq(c[1] .. ": the mode stored stands", persist:get(c[2], false), had)
  end
end

T.section("the brightness on mode and the default rates are read from the proxy's setup too")
do
  -- The mode as Previous On, whose level the proxy has at 20 %, and both
  -- rates at 750 ms.
  forgetSetup()
  proxySetup = withTags(setupFile("setup-607.xml"), { light_brightness_on_mode_preset_id = 10 })
  restart({ RGBCT, CT }, false)
  proxy("ON")
  T.eq("an on goes to the level of the mode's preset", lastLevel(), { 20 / 100, 0 })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80 })
  T.eq("a target with no rate ramps at the proxy's default", lengths(), { 750 })
  run(1000)
  mark()
  proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.5 })
  T.eq("and a color with no rate fades at it", lengths(), { 750 })
  run(1000)
  -- The proxy sends the mode when it changes, and a preset when it is edited:
  -- the on level follows both.
  --- An edit of preset 10 and then its removal, on a light whose mode is that
  --- preset `how`.
  local function follows(how)
    proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = 35 })
    proxy("OFF")
    mark()
    proxy("ON")
    T.eq("a mode " .. how .. ": an edit of its preset moves the on level", lastLevel(), { 35 / 100, 0 })
    proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "REMOVED", ID = 10 })
    proxy("OFF")
    mark()
    proxy("ON")
    T.eq("a mode " .. how .. ": with its preset removed an on goes to the Default On level", lastLevel(), { 1, 0 })
  end
  follows("read from the setup")
  forgetSetup()
  proxySetup = ""
  light({ RGBCT, CT }, false)
  proxy("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 10, BRIGHTNESS_PRESET_LEVEL = 20 })
  follows("sent by the proxy")
  -- The two default rates are one setting to this light, so either of the
  -- setup's is both.
  for _, tag in ipairs({ "light_brightness_rate_default", "light_color_rate_default" }) do
    forgetSetup()
    proxySetup = withTags(setupFile("setup-607.xml"), { [tag] = false })
    restart({ RGBCT, CT }, false)
    T.eq(
      "a setup without " .. tag .. ": both rates are the other's",
      { persist:get("brightness_rate_default", false), persist:get("color_rate_default", false) },
      { 750, 750 }
    )
  end
end

T.section("a setup that lists one color or one level, and a preset listed with no level")
do
  --- A setup whose Color On Mode is its one color, and whose brightness on mode is its one level.
  local function setupOfOne(level)
    return "<setup><light_color_on_mode_preset_id>1</light_color_on_mode_preset_id>"
      .. "<light_color_on_mode_preset_origin>1</light_color_on_mode_preset_origin>"
      .. "<light_color_on_mode_fade_preset_id>0</light_color_on_mode_fade_preset_id>"
      .. "<light_color_on_mode_fade_preset_origin>0</light_color_on_mode_fade_preset_origin>"
      .. "<light_brightness_on_mode_preset_id>1</light_brightness_on_mode_preset_id>"
      .. '<brightnesses><level name="On" id="1"'
      .. (level and (' level="' .. level .. '"') or "")
      .. "/></brightnesses>"
      .. '<colors><color name="On Color" id="1" origin="1" color_x="0.3" color_y="0.4" color_mode="1"/></colors></setup>'
  end
  forgetSetup()
  proxySetup = setupOfOne(70)
  restart({ RGBCT, CT }, false)
  proxy("ON")
  T.eq("one color and one level: both are found", { kelvins(), lastLevel() }, { { 3000 }, { 0.7, 0 } })
  forgetSetup()
  proxySetup = setupOfOne(nil)
  restart({ RGBCT, CT }, false)
  T.eq(
    "a preset listed with no level leaves the brightness on mode as it is",
    persist:get("brightness_on_mode", false),
    false
  )
  forgetSetup()
  proxySetup = ""
end

T.section("an ESPHome light's own proxy: Dim-To-Warm between two presets of one color, and rates of 750 ms")
do
  -- setup-643.xml is what the proxy of a color and color temperature light
  -- answered with nothing in it ever edited, where the driver held no Color
  -- On Mode and no default rate. Both presets are 3200 K, 4234 K as read here.
  forgetSetup()
  proxySetup = setupFile("setup-643.xml")
  restart({ RGBCT, CT }, false)
  proxy("ON")
  T.eq("an on is at full", lastLevel(), { 1, 0 })
  T.eq("in the On Color, a color temperature", kelvins(), { 4234 })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30 })
  T.eq("a level with no rate goes out over the proxy's 750 ms", lastLevel(), { 30 / 100, 750 })
  T.eq("in the Dim-To-Warm color", kelvins(), { 4234 })
  -- The setup is read as the driver starts, whether or not its light is there.
  forgetSetup()
  restart()
  local mode = persist:get("color_on_mode", {})
  T.eq(
    "a driver whose light has yet to connect has the rate and the mode's two presets",
    { persist:get("brightness_rate_default", false), (mode.onPreset or {}).id, (mode.fadePreset or {}).id },
    { 750, 1, 2 }
  )
  forgetSetup()
  proxySetup = ""
end

T.section("a new light's Color On Mode is read once the proxy is told the light's capabilities")
do
  -- A proxy lists a light's colors, its On Color and Dim Color among them,
  -- once it is told the light has a color or a color temperature. The two
  -- files are what a new light's proxy answered as its driver started, and
  -- as the driver's first capabilities reached it.
  forgetSetup()
  newLightSetup, proxySetup = setupFile("setup-732-new.xml"), setupFile("setup-732.xml")
  restart()
  T.eq(
    "as the driver starts the setup names the mode's presets and lists none: it has the rate and no mode",
    { persist:get("brightness_rate_default", false), persist:get("color_on_mode", false) },
    { 750, false }
  )
  forgetSetup()
  restart({ CT }, false)
  proxy("ON")
  T.eq("once the light has connected an on is in the On Color", kelvins(), { 4234 })
  mark()
  proxy("SET_LEVEL", { LEVEL = 40 })
  T.eq("and a level carries the Dim-To-Warm color", kelvins(), { 4234 })
  forgetSetup()
  newLightSetup, proxySetup = nil, ""
end

---------------------------------------------------------------------------
-- A light with a white beside its color
---------------------------------------------------------------------------

-- The white is its own color mode, or one mode holds it with the color, as a
-- light built with no color_interlock has: RGB with a color temperature
-- (RGBCT above), or with cold and warm white.
local RGB, CWWW = ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_COLD_WARM_WHITE
local RGBWW = ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE
local FULL_MODE = 0

--- A report from a light of kind `modes`.
--- @param range table|nil The range its entity gives for its color temperature, in mireds.
local function pushed(modes, state, range)
  range = range or {}
  RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
    entity = SerializeSafe({
      key = 1,
      name = "Light",
      supported_color_modes = modes,
      min_mireds = range[1],
      max_mireds = range[2],
    }),
    state = SerializeSafe(state),
  })
end

-- 6500 to 2700 K.
local RANGE = { 153.8, 370.4 }

--- Set the Color On Mode to Dim-To-Warm between an On Color and a Dim Color, each an xy in `mode`.
local function fadeMode(on, dim, mode)
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = on[1],
    COLOR_PRESET_COLOR_Y = on[2],
    COLOR_PRESET_COLOR_MODE = mode,
    COLOR_FADE_PRESET_ID = 2,
    COLOR_FADE_PRESET_ORIGIN = 1,
    COLOR_FADE_PRESET_COLOR_X = dim[1],
    COLOR_FADE_PRESET_COLOR_Y = dim[2],
    COLOR_FADE_PRESET_COLOR_MODE = mode,
  })
end

--- The color mode the proxy was told with each color since the mark.
local function modesTold()
  return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_COLOR_MODE")
end

--- The last command the device was sent since the mark, empty if it was sent none.
local function lastCommand()
  for i = #sent, 1, -1 do
    if sent[i].binding == ESPHOME and sent[i].command == "ENTITY_COMMAND" then
      return DeserializeSafe(sent[i].params.body)
    end
  end
  return {}
end

T.section("a full color that is a color temperature's own point lights the white of a light that has one")
do
  -- A new color light's proxy makes its On Color and Dim Color one white
  -- point, 3200 K, and stores it as a full color (setup-626.xml's two).
  local POINT = { 0.32, 0.4 }
  for name, modes in pairs({
    ["cold and warm white beside its color"] = { RGBWW },
    ["a color temperature beside its color"] = { RGBCT, CT },
    ["a color mode and a white mode"] = { RGB, CWWW },
  }) do
    light()
    pushed(modes, { state = false, brightness = 1.0 }, RANGE)
    fadeMode(POINT, POINT, FULL_MODE)
    mark()
    proxy("ON")
    T.eq(
      "a light with " .. name .. ": an on is in that white, with no red, green or blue",
      { kelvins(), colors() },
      { { 3200 }, {} }
    )
    T.eq("which the proxy is told as a color temperature", { colorsTold(), modesTold() }, { { 0.32 }, { CCT_MODE } })
    mark()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
    T.eq("and so is a level after it", { kelvins(), colors() }, { { 3200 }, {} })
  end
  light({ RGB }, false)
  fadeMode(POINT, POINT, FULL_MODE)
  mark()
  proxy("ON")
  T.eq("a light with a color alone has only its color for it", { kelvins(), #colors() }, { {}, 1 })

  -- The same color from each place a full color comes from.
  light()
  pushed({ RGBCT, CT }, { state = false, brightness = 1.0 }, RANGE)
  onMode({ POINT[1], POINT[2], id = 1 })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(POINT, 750)
  T.eq(
    "an On Color preset, and the proxy's own copy of it after the on: the white, once",
    { kelvins(), colors() },
    { { 3200 }, {} }
  )
  run(1000)
  light()
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0 }, RANGE)
  mark()
  colorTarget(POINT, 0)
  T.eq("a color the proxy sets: the white", { kelvins(), colors(), modesTold() }, { { 3200 }, {}, { CCT_MODE } })
  activate(colorStep(nil, POINT, 0))
  T.eq("a scene step's: the white", { kelvins(), colors() }, { { 3200 }, {} })
  proxy("CLEAR_ALL_SCENES")
  mark()
  colorTarget({ 0.2, 0.4 }, 0)
  T.eq("the point of a white beyond the light's range stays a color", { kelvins(), #colors() }, { {}, 1 })
  mark()
  colorTarget({ 0.32, 0.41 }, 0)
  T.eq("and so does a color beside a white's point", { kelvins(), #colors() }, { {}, 1 })

  -- Dim-To-Warm is between its two ends: both a white's point, or a color.
  light()
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0 }, RANGE)
  fadeMode({ 0.5, 0.6 }, { 0.3, 0.2 }, FULL_MODE)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "between two colors, at the level whose mix crosses a white's point: a color still",
    { kelvins(), #colors() },
    { {}, 1 }
  )
  -- Kelvin as x over a y that curves as the locus does, so the mix of two whites lies off it.
  local toXY = C4.ColorCCTtoXY
  function C4:ColorCCTtoXY(k)
    return k / 10000, 0.4 - (k / 10000 - 0.45) ^ 2
  end
  light()
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0 }, RANGE)
  fadeMode({ C4:ColorCCTtoXY(6000) }, { C4:ColorCCTtoXY(3000) }, FULL_MODE)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "between two whites given as full colors: a white at every level, its mix off their line or not",
    { kelvins(), colors() },
    { { 4500 }, {} }
  )
  C4.ColorCCTtoXY = toXY
end

T.section("the color temperature a level carries is left to a light that can work its cold and warm white out")
do
  -- ESPHome splits a color temperature into cold and warm white with the
  -- light's gamma, for a light that gives a range for it.
  for name, modes in pairs({
    ["cold and warm white alone"] = { CWWW },
    ["a color mode beside its cold and warm white"] = { RGB, CWWW },
    ["cold and warm white beside its color"] = { RGBWW },
  }) do
    light()
    pushed(modes, { state = false, brightness = 1.0 }, RANGE)
    fadeMode({ 0.32, 0.4 }, { 0.32, 0.4 }, CCT_MODE)
    mark()
    proxy("ON")
    local cmd = lastCommand()
    T.eq(
      "a light with " .. name .. ": the color temperature, and neither cold nor warm white",
      { kelvins(), cmd.color_mode, cmd.has_cold_white or false, cmd.has_warm_white or false },
      { { 3200 }, modes[#modes], false, false }
    )
  end
  -- 3200 K between the driver's own 153 and 500 mireds, or the end the light gives.
  for name, case in pairs({
    ["no range"] = { {}, (312.5 - 153) / (500 - 153) },
    ["one end of a range"] = { { 153.8, 0 }, (312.5 - 153.8) / (500 - 153.8) },
    ["the other end"] = { { 0, 370.4 }, (312.5 - 153) / (370.4 - 153) },
  }) do
    local warm = case[2]
    light()
    pushed({ CWWW }, { state = false, brightness = 1.0 }, case[1])
    fadeMode({ 0.32, 0.4 }, { 0.32, 0.4 }, CCT_MODE)
    mark()
    proxy("ON")
    local cmd = lastCommand()
    T.check(
      "one that gives " .. name .. " cannot, and is sent the two as the driver splits them",
      cmd.color_mode == CWWW and math.abs(cmd.cold_white - (1 - warm)) < 1e-9 and math.abs(cmd.warm_white - warm) < 1e-9,
      T.show(cmd)
    )
  end
end

---------------------------------------------------------------------------
-- Combined color modes
---------------------------------------------------------------------------

local function kelvin(target, rate)
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = target,
    LIGHT_COLOR_TARGET_COLOR_RATE = rate,
  })
end

T.section("a combined color mode's report is the color or the white, whichever is turned up further")
do
  -- ESPHome reports the white's color temperature beside the color, lit or not.
  light({ RGBCT, CT })
  onMode(PREVIOUS_ON)
  local blue = setColor(BLUE)
  mark()
  pushed({ RGBCT, CT }, {
    state = true,
    brightness = 1.0,
    color_mode = RGBCT,
    color_brightness = 1,
    red = blue[1],
    green = blue[2],
    blue = blue[3],
    color_temperature = 333.3333,
  })
  T.eq("the color the light was sent, reported with a color temperature beside it: no white is told", colorsTold(), {})
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("and with Color On Mode set to Previous the light comes back on in the color", colors(), { blue })
  light({ RGBCT, CT })
  setColor(BLUE)
  mark()
  pushed({ RGBCT, CT }, {
    state = true,
    brightness = 1.0,
    color_mode = RGBCT,
    red = blue[1],
    green = blue[2],
    blue = blue[3],
    white = 1,
    color_temperature = 333.3333,
  })
  T.eq("the color turned down and the white up: the white", { colorsTold(), modesTold() }, { { 0.3 }, { CCT_MODE } })
  -- Both lit, as another client or a stop part way leaves them. A light in
  -- this mode reports a cold and a warm white too, which are not its white.
  for _, case in ipairs({
    { "the color turned up further: the color", 0.6, 0.5, FULL_MODE },
    { "the two level: the color, which the white cannot tell", 0.5, 0.5, FULL_MODE },
    { "the white turned up further: the white", 0.4, 0.5, CCT_MODE },
    { "the color at a hundredth beside the white at full: the white", 0.01, 1, CCT_MODE },
  }) do
    light({ RGBCT, CT })
    kelvin(5000, 0)
    mark()
    pushed({ RGBCT, CT }, {
      state = true,
      brightness = 1.0,
      color_mode = RGBCT,
      color_brightness = case[2],
      red = 1,
      green = 0,
      blue = 0,
      white = case[3],
      color_temperature = 333.3333,
      cold_white = 1,
      warm_white = 1,
    })
    T.eq("both lit, " .. case[1], modesTold(), { case[4] })
  end
  light({ RGBWW })
  blue = setColor(BLUE)
  mark()
  pushed({ RGBWW }, {
    state = true,
    brightness = 1.0,
    color_mode = RGBWW,
    color_brightness = 1,
    red = blue[1],
    green = blue[2],
    blue = blue[3],
    color_temperature = 250,
  })
  T.eq("a light with cold and warm white, its color lit: no white is told", colorsTold(), {})
  pushed({ RGBWW }, {
    state = true,
    brightness = 1.0,
    color_mode = RGBWW,
    red = blue[1],
    green = blue[2],
    blue = blue[3],
    color_temperature = 250,
    cold_white = 1,
    warm_white = 0.92,
  })
  T.eq("its color off: the white", { colorsTold(), modesTold() }, { { 0.4 }, { CCT_MODE } })
  for _, case in ipairs({
    { "the warm white turned up further than the color: the white", 0.3, 0.6, CCT_MODE },
    { "the cold white turned up further: the white", 0.6, 0.3, CCT_MODE },
    { "neither turned up as far as the color: the color", 0.3, 0.4, FULL_MODE },
  }) do
    light({ RGBWW })
    setColor(BLUE)
    kelvin(5000, 0)
    mark()
    pushed({ RGBWW }, {
      state = true,
      brightness = 1.0,
      color_mode = RGBWW,
      color_brightness = 0.5,
      red = 1,
      green = 0,
      blue = 0,
      color_temperature = 250,
      cold_white = case[2],
      warm_white = case[3],
    })
    T.eq("both lit, " .. case[1], modesTold(), { case[4] })
  end
  -- A white-only mode keeps a color brightness and has no color to light.
  light({ RGBCT, CT })
  setColor(BLUE)
  mark()
  pushed({ RGBCT, CT }, {
    state = true,
    brightness = 1.0,
    color_mode = CT,
    color_brightness = 1,
    red = 1,
    green = 1,
    blue = 1,
    color_temperature = 250,
  })
  T.eq(
    "a light put in its white-only mode elsewhere: the white",
    { colorsTold(), modesTold() },
    { { 0.4 }, { CCT_MODE } }
  )
end

T.finish()
