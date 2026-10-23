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

-- Late init stops without a minimum OS version, which the shim lacks.
local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return config(self, section)
end

-- GET_SETUP answers proxySetup (false for none), or newLightSetup until the
-- proxy is told the light's capabilities.
local proxySetup, newLightSetup = "", nil
local capabilitiesTold = false
function C4:GetProxyDevices()
  return 643
end
-- The proxy's Current Color Chromaticity (1200), which it keeps over a load or
-- bind: the current a CHANGED or CHANGING told it, to six figures as a dev
-- proxy shows it, or nil for a proxy never told one. Its target (1210) is a
-- CHANGING's target or a CHANGED's color.
local proxyColor, proxyTarget
function C4:GetDeviceVariable(id, variable)
  if id == 643 then
    return ({ [1200] = proxyColor, [1210] = proxyTarget })[variable]
  end
end
local uiRequest = C4.SendUIRequest
function C4:SendUIRequest(id, request, params)
  if request == "GET_SETUP" then
    return not capabilitiesTold and newLightSetup or proxySetup or nil
  end
  return uiRequest(self, id, request, params)
end

--- Reload the driver over its stored state (kept in the chunk's locals) and
--- report the light on at full, or off if `on` is false.
--- @param modes table|nil supported_color_modes; nil: not yet connected.
local function restart(modes, on)
  queue, capabilitiesTold = {}, false
  dofile(DRIVER)
  function SendToProxy(idBinding, strCommand, tParams)
    capabilitiesTold = capabilitiesTold or strCommand == "DYNAMIC_CAPABILITIES_CHANGED"
    if idBinding == PROXY and (strCommand == "LIGHT_COLOR_CHANGED" or strCommand == "LIGHT_COLOR_CHANGING") then
      local p, form = tParams, "%g,%g,%d"
      proxyColor = form:format(p.LIGHT_COLOR_CURRENT_X, p.LIGHT_COLOR_CURRENT_Y, p.LIGHT_COLOR_CURRENT_COLOR_MODE)
      proxyTarget = p.LIGHT_COLOR_TARGET_X
          and form:format(p.LIGHT_COLOR_TARGET_X, p.LIGHT_COLOR_TARGET_Y, p.LIGHT_COLOR_TARGET_COLOR_MODE)
        or proxyColor
    end
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

--- A fresh light: clears what the process-wide store holds of the last one.
--- @param modes table supported_color_modes.
local function light(modes, on)
  for _, key in ipairs({ "color_on_mode", "color_presets", "previous_color", "white_point" }) do
    persist:delete(key)
  end
  proxyColor, proxyTarget = nil, nil
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

--- ESPHome's transition easing (LightTransformer::smoothed_progress).
local function eased(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

--- Level a fade from `from` to `to` reaches at fraction `p` of its time.
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
    COLOR_PRESET_ORIGIN = on.origin or 1,
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
  T.eq("the On color goes out with the pre-on and the on alone", #colors(), 2)
  T.eq("and the proxy is told it once", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
  -- The Control4 app's own send names the On color's preset.
  offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = ON[1],
    LIGHT_COLOR_TARGET_Y = ON[2],
    LIGHT_COLOR_TARGET_COLOR_RATE = 750,
    LIGHT_COLOR_TARGET_PRESET_ID = ON.id,
  })
  run(15000)
  T.eq("with its preset: the light is sent nothing more, and the proxy is told the On color once, in that preset", {
    #colors(),
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_PRESET_ID"),
  }, { 2, { ON[1] }, { ON.id } })
  offInBlue()
  local asked = setColor({ 0.2, 0.5 })
  setColor(BLUE)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  colorTarget({ 0.2, 0.5 }, 1000)
  run(15000)
  local out = colors()
  T.eq("another color is the last the light is sent", out[#out], asked)
  T.eq(
    "and the proxy is told it after the On color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1], 0.2 }
  )
end

--- The x of the Dim-To-Warm mix for a level, as the driver computes it.
local function mix(level)
  return DIM[1] + (ON[1] - DIM[1]) * (level * 0.01)
end

T.section(
  "a rated dim that changes the color tells the proxy the color the light is leaving, a rated on the On color at once"
)
do
  offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  T.eq(
    "a rated on: the On color at once, which its pre-on brings the light up in",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X") },
    { { ON[1] }, {} }
  )
  run(15000)
  T.eq("and nothing at the ramp's end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
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
  run(15000)
  T.eq(
    "a rated on: the proxy is then told the On color and nothing else",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )
  T.eq("at once, as its pre-on brings the light up in it", told("LIGHT_COLOR_CHANGED", "at"), { 0 })
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
    T.eq(
      name .. ": and the proxy is told it once, after the on's own",
      told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
      { ON[1], 0.2 }
    )
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

T.section("a rated on tells its On color as the device preset it is, and again only in another one the proxy names")
do
  --- The preset each LIGHT_COLOR_CHANGED since the mark names, false for none.
  local function presetsTold()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == PROXY and s.command == "LIGHT_COLOR_CHANGED" then
        out[#out + 1] = s.params.LIGHT_COLOR_CURRENT_PRESET_ID or false
      end
    end
    return out
  end
  -- { the Color On Mode's preset, the one the proxy's send names, those the proxy is told the color in }
  for _, case in ipairs({
    { "the On color, its own named", ON, ON.id, { ON.id } },
    { "the On color, another named", ON, 5, { ON.id, 5 } },
    { "the On color, none named", ON, nil, { ON.id } },
    { "Previous On", PREVIOUS_ON, PREVIOUS_ON.id, { PREVIOUS_ON.id } },
    { "an agent's preset", { ON[1], ON[2], id = 1, origin = 2 }, nil, { false } },
  }) do
    local name, preset = case[1], case[2]
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(preset)
    proxy("ON")
    setColor(preset)
    proxy("OFF")
    mark()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
    proxy("SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_X = preset[1],
      LIGHT_COLOR_TARGET_Y = preset[2],
      LIGHT_COLOR_TARGET_COLOR_RATE = 750,
      LIGHT_COLOR_TARGET_PRESET_ID = case[3],
    })
    run(15000)
    local each = {}
    for i, id in ipairs(case[4]) do
      each[i] = id and "preset " .. id or "no preset"
    end
    T.eq(name .. ": told in " .. table.concat(each, ", then "), presetsTold(), case[4])
    T.eq(name .. ": the light is sent the pre-on and the on alone", #colors(), 2)
  end
end

T.section("the On color asked for after another color early in a rated on goes out: it is no echo of the on's")
do
  -- The other color 50 ms in re-times the on's ramp, which then carries no On color to match the ask at 100 ms.
  for _, scene in ipairs({ false, true }) do
    for _, rate in ipairs({ 0, 1000 }) do
      local name = (scene and "after a scene step's color" or "after a color command")
        .. (rate > 0 and " over 1 s" or " at once")
      local onColor = offInBlue()
      mark()
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
      colorTarget(ON, 2000)
      run(50)
      if scene then
        proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = colorStep(nil, { 0.3, 0.6 }, rate) })
        proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
      else
        colorTarget({ 0.3, 0.6 }, rate)
      end
      run(50)
      colorTarget(ON, 0)
      run(15000)
      local out, x = colors(), told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")
      T.eq(name .. ": the light is last sent the On color", out[#out], onColor)
      T.eq(
        name .. ": and the proxy is told it last, as it is asked for",
        { x[#x], told("LIGHT_COLOR_CHANGED", "at")[#x] },
        { ON[1], 100 }
      )
      proxy("CLEAR_ALL_SCENES")
    end
  end
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

local TOP, BOTTOM, TOGGLE = 0, 1, 2
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

local TOP_LINK, TOGGLE_LINK = 300, 301 -- the Top and Toggle Button Link bindings

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
  local blue = setColor(BLUE)
  mark()
  --- The device's report, still off, in the color sent as `color`.
  local function offIn(color)
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = { ColorMode.COLOR_MODE_RGB } }),
      state = SerializeSafe({
        state = false,
        brightness = 1.0,
        color_mode = ColorMode.COLOR_MODE_RGB,
        red = color[1],
        green = color[2],
        blue = color[3],
      }),
    })
  end
  -- The device reports blue, then the color it was given elsewhere.
  offIn(blue)
  offIn(rgb)
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

T.section("a rated on from off is told from 1, where its pre-on has the light, so Control4 shows it on from the start")
do
  -- The proxy takes LIGHT_STATE from CHANGING's current level: from 0 it showed the light off to the ramp's end.
  --- Each ramp the proxy was told since the mark, from its current level to its target.
  local function rampsTold()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGING" then
        out[#out + 1] = s.params.LIGHT_BRIGHTNESS_CURRENT .. " to " .. s.params.LIGHT_BRIGHTNESS_TARGET
      end
    end
    return out
  end
  --- The brightness of the first command since the mark: a ramped on's pre-on.
  local function firstBrightness()
    for _, s in ipairs(sent) do
      if s.binding == ESPHOME and s.command == "ENTITY_COMMAND" then
        return DeserializeSafe(s.params.body).brightness
      end
    end
  end
  local ons = {
    { "Set Brightness Target", PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 }, 60 },
    { "Ramp Scene Up", PROXY, "RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 2000 }, 100 },
    { "a scene step to 60 over 2 s", PROXY, "ACTIVATE_SCENE", { SCENE_ID = 7 }, 60 },
    { "a Top Button Link's click", TOP_LINK, "DO_CLICK", {}, 100 },
    { "a Toggle Button Link held", TOGGLE_LINK, "DO_PUSH", {}, 100 },
  }
  for _, c in ipairs(ons) do
    light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(60, 2000) })
    mark()
    RFP[c[3]](c[2], c[3], c[4])
    T.eq(c[1] .. " from off: its pre-on, and its ramp told from 1", { firstBrightness(), rampsTold() }, {
      0.0039,
      { "1 to " .. c[5] },
    })
    run(15000)
    T.eq(
      c[1] .. ": its level once, at the ramp's end",
      told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
      { c[5] }
    )
    proxy("CLEAR_ALL_SCENES")
  end
  light({ ColorMode.COLOR_MODE_RGB }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(100)
  mark()
  colorTarget(BLUE, 2000)
  T.eq("a color 100 ms into such an on: its ramp told again from 1", rampsTold(), { "1 to 60" })

  -- A rated level for a light that is on, and a fade to off, are told from where the light is.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 60 })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  run(15000)
  T.eq(
    "a rated level to 30 from 60: from 60",
    { rampsTold(), told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT") },
    { { "60 to 30" }, { 30 } }
  )
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  run(15000)
  T.eq(
    "a fade to off from 30: from 30",
    { rampsTold(), told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT") },
    { { "30 to 0" }, { 0 } }
  )
end

T.section("Get Light Level in a ramp tells where the ramp has got to, its target and the time left")
do
  -- Light V2 takes a CHANGED level as where the brightness stopped: in a ramp it was the ramp's start.
  --- What a Get Light Level tells the proxy: { command, current, target, rate }.
  local function getLevel()
    mark()
    proxy("GET_LIGHT_LEVEL")
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == PROXY then
        local p = s.params
        out[#out + 1] = { s.command, p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET, p.RATE }
      end
    end
    return out
  end
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 20 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
  run(5000)
  T.eq("half way from 20 to 100: a ramp from 60 to 100 with 5 s left", getLevel(), {
    { "LIGHT_BRIGHTNESS_CHANGING", 60, 100, 5000 },
  })
  mark()
  run(15000)
  T.eq("and the ramp's end is told as before", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 5000 })
  T.eq("at rest: the level it stopped at", getLevel(), { { "LIGHT_BRIGHTNESS_CHANGED", 100 } })

  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(100)
  T.eq("100 ms into a rated on from off: from 1, where its pre-on has the light", getLevel(), {
    { "LIGHT_BRIGHTNESS_CHANGING", 1, 60, 5900 },
  })
  run(15000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  run(2000)
  T.eq("half way through a fade to off from 60: from 30", getLevel(), {
    { "LIGHT_BRIGHTNESS_CHANGING", 30, 0, 2000 },
  })
  mark()
  run(15000)
  T.eq("which ends off as before", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
  T.eq("off at rest", getLevel(), { { "LIGHT_BRIGHTNESS_CHANGED", 0 } })
end

T.section("the Button Link LEDs show a light on from the start of a ramp up to the end of a fade to off")
do
  -- MATCH_LED_STATE went out with CHANGED alone: through a rated on from off the LEDs showed it off.
  local BOTTOM_LINK = 302
  --- When and what a Button Link's LED was told since the mark, the Top's if nil: { ms, STATE }.
  local function leds(binding)
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == (binding or TOP_LINK) and s.command == "MATCH_LED_STATE" then
        out[#out + 1] = { s.at, s.params.STATE }
      end
    end
    return out
  end
  local ons = {
    { "Set Brightness Target", PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 } },
    { "Ramp Scene Up", PROXY, "RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 2000 } },
    { "a scene step to 60 over 2 s", PROXY, "ACTIVATE_SCENE", { SCENE_ID = 7 } },
    { "a Top Button Link's click", TOP_LINK, "DO_CLICK", {} },
    { "a Toggle Button Link held", TOGGLE_LINK, "DO_PUSH", {} },
  }
  for _, c in ipairs(ons) do
    light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(60, 2000) })
    mark()
    RFP[c[3]](c[2], c[3], c[4])
    run(1000)
    T.eq(c[1] .. " from off: the LED is told on as its ramp begins", leds(), { { 0, true } })
    proxy("CLEAR_ALL_SCENES")
  end

  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  run(2500)
  mark()
  proxy("REQUEST_BUTTON_COLORS")
  T.eq(
    "Request Button Colors half way up: on, the Bottom's LED inverted",
    { leds(), leds(BOTTOM_LINK), leds(TOGGLE_LINK) },
    { { { 0, true } }, { { 0, false } }, { { 0, true } } }
  )
  run(15000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  run(15000)
  T.eq("a rated level between lit levels: the LED is told nothing", leds(), {})
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  run(2000)
  T.eq("a fade to off: nothing half way", leds(), {})
  proxy("REQUEST_BUTTON_COLORS")
  T.eq("where Request Button Colors says on", leds(), { { 2000, true } })
  run(15000)
  T.eq("and off at the fade's end", leds(), { { 2000, true }, { 4000, false } })

  -- One that stops at off is off, as the light is.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  mark()
  RFP.DO_PUSH(TOGGLE_LINK, "DO_PUSH", {})
  RFP.DO_RELEASE(TOGGLE_LINK, "DO_RELEASE", {})
  T.eq("a Toggle Button Link held from off and let go at once: on, then off", leds(), { { 0, true }, { 0, false } })
  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  run(2500)
  mark()
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
  T.eq("a disconnect half way up: off, as the proxy is told", leds(), { { 0, false } })
end

T.section("a ramp from off that ends before the light is lit leaves Previous On where it was")
do
  -- The proxy writes Previous On as the light goes off, from the last level it was told: the pre-on's 1 here.
  --- Each brightness notification since the mark: { ms, command, current, target, rate }.
  local function levelsTold()
    local out = {}
    for _, s in ipairs(sent) do
      local p = s.params
      if
        s.binding == PROXY and (s.command == "LIGHT_BRIGHTNESS_CHANGING" or s.command == "LIGHT_BRIGHTNESS_CHANGED")
      then
        out[#out + 1] = { s.at, s.command, p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET, p.RATE }
      end
    end
    return out
  end
  --- Previous On as the proxy keeps it through what it was told since the mark, from `held`.
  local function previousOn(held)
    local on, last = false, nil
    for _, t in ipairs(levelsTold()) do
      if t[3] > 0 then
        last = t[3]
      elseif on then
        held = last
      end
      on = t[3] > 0
    end
    return held
  end
  --- A light that is off, whose proxy holds Previous On at `level`, or none if nil.
  local function offWith(level)
    persist:delete("brightness_presets")
    light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
    if level then
      proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = level })
    end
    mark()
  end
  --- Send `step`: { binding, command, params }.
  local function send(step)
    RFP[step[2]](step[1], step[2], step[3])
  end
  local RATED = { PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 } }
  local STOP = { PROXY, "SET_BRIGHTNESS_STOP", {} }
  local ends = {
    {
      "a Toggle Button Link held from off and let go",
      { TOGGLE_LINK, "DO_PUSH", {} },
      { TOGGLE_LINK, "DO_RELEASE", {} },
    },
    { "Set Brightness Stop in a rated on", RATED, STOP },
    {
      "Stop Scene Ramp in Ramp Scene Up",
      { PROXY, "RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 2000 } },
      { PROXY, "STOP_SCENE_RAMP", { SCENE_ID = 7 } },
    },
    {
      "an off at once in a rated on",
      RATED,
      { PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 } },
    },
    {
      "a fade to off in a rated on",
      RATED,
      { PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 } },
    },
    { "Get Light Level and a stop in a rated on", RATED, { PROXY, "GET_LIGHT_LEVEL", {} }, STOP },
  }
  for _, c in ipairs(ends) do
    offWith(40)
    send(c[2])
    run(50)
    for i = 3, #c do
      send(c[i])
    end
    run(15000)
    T.eq(
      c[1] .. " 50 ms in: the light ends off and Previous On stays at 40",
      { told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), previousOn(40) },
      { { 0 }, 40 }
    )
  end

  offWith(40)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(50)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("the rated on is told from 1 as it begins, and its stop as an off at once from 40", levelsTold(), {
    { 0, "LIGHT_BRIGHTNESS_CHANGING", 1, 60, 6000 },
    { 50, "LIGHT_BRIGHTNESS_CHANGING", 40, 0, 0 },
    { 50, "LIGHT_BRIGHTNESS_CHANGED", 0 },
  })
  offWith(40)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(3000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 })
  T.eq(
    "an off at once half way through it, the light lit: Previous On is 30, where the light had got to",
    { levelsTold()[2], previousOn(40) },
    { { 3000, "LIGHT_BRIGHTNESS_CHANGING", 30, 0, 0 }, 30 }
  )

  -- An off from a level the light was told at is told as before.
  offWith(40)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(6000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  run(15000)
  T.eq("a rated on to its end, then a fade to off: Previous On is 60", { levelsTold(), previousOn(40) }, {
    {
      { 0, "LIGHT_BRIGHTNESS_CHANGING", 1, 60, 6000 },
      { 6000, "LIGHT_BRIGHTNESS_CHANGED", 60 },
      { 6000, "LIGHT_BRIGHTNESS_CHANGING", 60, 0, 2000 },
      { 8000, "LIGHT_BRIGHTNESS_CHANGED", 0 },
    },
    60,
  })
  offWith(40)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(3000)
  proxy("SET_BRIGHTNESS_STOP")
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 })
  T.eq("a stop once the light is lit, then an off at once: Previous On is the level it stopped at", {
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    previousOn(40),
  }, { { 1 }, { 30, 0 }, 30 })
  offWith(nil)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(50)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("with no Previous On known, a stop 50 ms in is told as before", levelsTold(), {
    { 0, "LIGHT_BRIGHTNESS_CHANGING", 1, 60, 6000 },
    { 50, "LIGHT_BRIGHTNESS_CHANGED", 0 },
  })
  persist:delete("brightness_presets")
end

T.section("a light's report from before the level last sent tells nothing: a ramp's echo after its stop leaves it off")
do
  -- The light takes commands in order, so a report of one with another sent since is history.
  local dimmer = { ColorMode.COLOR_MODE_BRIGHTNESS }
  --- The light's report of its brightness, off for 0; a dimmer's unless `modes` are given.
  local function push(brightness, modes)
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = modes or dimmer }),
      state = SerializeSafe(brightness > 0 and { state = true, brightness = brightness } or { state = false }),
    })
  end
  --- Each brightness notification since the mark: "current to target" or "current".
  local function brightnessTold()
    local out = {}
    for _, s in ipairs(sent) do
      local p = s.params
      if s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGING" then
        out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT .. " to " .. p.LIGHT_BRIGHTNESS_TARGET
      elseif s.binding == PROXY and s.command == "LIGHT_BRIGHTNESS_CHANGED" then
        out[#out + 1] = tostring(p.LIGHT_BRIGHTNESS_CURRENT)
      end
    end
    return out
  end
  --- When and what the Top Button Link's LED was told since the mark: { ms, STATE }.
  local function leds()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == TOP_LINK and s.command == "MATCH_LED_STATE" then
        out[#out + 1] = { s.at, s.params.STATE }
      end
    end
    return out
  end
  --- The levels the proxy was told the light is at since the mark.
  local function levels()
    return told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
  end
  --- A light that is off with Previous On at 40, sent `on` and 50 ms later `stop`, each { binding, command,
  --- params }; 40 ms on.
  local function stopped(on, stop)
    persist:delete("brightness_presets")
    light(dimmer, false)
    proxy("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = 40 })
    mark()
    RFP[on[2]](on[1], on[2], on[3])
    run(50)
    RFP[stop[2]](stop[1], stop[2], stop[3])
    run(40)
  end
  local RATED = { PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 } }
  local STOP = { PROXY, "SET_BRIGHTNESS_STOP", {} }

  -- As on dev with two lights on one node: the on's report 40 ms after the stop, then the stop's.
  for _, c in ipairs({
    { "Set Brightness Stop", RATED, STOP, 0.6, 60 },
    { "an off at once", RATED, { PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 } }, 0.6, 60 },
    { "a Toggle Button Link let go", { TOGGLE_LINK, "DO_PUSH", {} }, { TOGGLE_LINK, "DO_RELEASE", {} }, 1.0, 100 },
  }) do
    stopped(c[2], c[3])
    push(c[4])
    run(100)
    push(0)
    run(2000)
    T.eq(
      c[1] .. " 50 ms into a ramp from off, reported after it: told off once, from Previous On's 40",
      brightnessTold(),
      { "1 to " .. c[5], "40 to 0", "0" }
    )
    T.eq(c[1] .. ": the LED goes off with it and stays off", leds(), { { 0, true }, { 50, false } })
  end
  stopped(RATED, STOP)
  push(0)
  run(2000)
  T.eq(
    "the on and its stop answered with one report of the off, as one light alone was: the stop is told alone",
    brightnessTold(),
    { "1 to 60", "40 to 0", "0" }
  )

  -- Another client's level is news, whatever report is on its way.
  stopped(RATED, STOP)
  push(0.8)
  T.eq(
    "a level set elsewhere while the stop's report is on the way: told at once",
    { levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 0, 80 }, { 50, 90 } }
  )
  stopped(RATED, STOP)
  push(0.6)
  run(50)
  push(0.8)
  run(2000)
  T.eq(
    "and one set elsewhere after the on's report: told at once, and the on's 60 never",
    { levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 0, 80 }, { 50, 140 } }
  )
  stopped(RATED, STOP)
  push(0.6)
  run(100)
  push(0)
  run(100)
  push(0.6)
  local after, at = levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at")
  T.eq("the light set elsewhere to 60 once the stop's report has come: told at once", { after[#after], at[#at] }, {
    60,
    290,
  })

  -- A light that does not report the stop within a second is told as it is.
  stopped(RATED, STOP)
  push(0.6)
  T.eq(
    "a light that does not take the stop: nothing more is told while its report may be on the way",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 50 }
  )
  run(2000)
  T.eq(
    "then its 60, a second after the stop",
    { levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 0, 60 }, { 50, 1050 } }
  )
  stopped(RATED, STOP)
  push(0.6)
  run(860)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 0 })
  run(200)
  push(0.3)
  run(2000)
  T.eq(
    "a level sent 0.9 s after the stop: the on's 60 is not told while that level's report is on the way",
    { levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 0, 30 }, { 50, 950 } }
  )
  stopped(RATED, STOP)
  push(0.6)
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
  run(2000)
  T.eq("a disconnect while the stop's report may be on the way: the on's 60 is not told after it", levels(), { 0, 0 })
  persist:delete("brightness_presets")

  -- Not only a stop: any level the light reports with another sent since.
  light(dimmer)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 0 })
  run(12)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 0 })
  run(150)
  push(0.3)
  run(100)
  push(0.6)
  run(2000)
  T.eq("30 then 60 at once 12 ms apart, each reported by itself: 30 is not told again", levels(), { 30, 60 })
  light(dimmer, false)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 100 })
  run(150)
  push(0.0039)
  run(100)
  push(0.6)
  run(2000)
  T.eq(
    "a rated on over 100 ms from off, its pre-on and on reported after its end: 60 told once, at its end",
    { levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 60 }, { 100 } }
  )
  local onOff = { ColorMode.COLOR_MODE_ON_OFF }
  light(onOff, false)
  mark()
  proxy("ON")
  run(30)
  proxy("OFF")
  run(100)
  push(1, onOff)
  run(100)
  push(0, onOff)
  run(2000)
  T.eq(
    "an On/Off-only light switched on and off 30 ms apart, its on reported after the off: each told once",
    { levels(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 100, 0 }, { 0, 30 } }
  )
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
      T.eq(name .. ": at once, as the pre-on brings the light up in it", told("LIGHT_COLOR_CHANGED", "at"), { 0 })
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
  T.eq("an On color goes out with the pre-on and the on: the proxy's send of it puts no third out", #colors(), 2)
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
  -- A rated on lights the On color at once; the step's color replaces it.
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
    "a rated on left to run after the step: the proxy is told the step's color after the On color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1], other[1] }
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
  T.eq("both carry the On color, the pre-on so the light comes on in it", colors(), { onColor, onColor })
  T.eq(
    "the proxy is told the On color at once, and no color ramp",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X") },
    { { ON[1] }, {} }
  )
  run(20000)
  T.eq("and nothing at the step's end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
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
  T.eq("a step from off with a color of its own: it is sent that color, with its pre-on", colors(), { own, own })
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
    "a click from off: the On color at once, which its pre-on brings the light up in",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X") },
    { { ON[1] }, {} }
  )
  run(15000)
  T.eq("and nothing after", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { ON[1] })
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
      replace .. " a quarter into a rated on: from the On color, which its pre-on brought the light up in",
      told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
      { ON[1] }
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
    "a step back to the color a rated on began from, as it begins: a fade from the On color the light came up in",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    { ON[1] }
  )
  run(15000)
  T.eq("which the proxy is told at its end", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
  proxy("CLEAR_ALL_SCENES")
  -- With a level, the step finds the light off and sends its own pre-on.
  offInBlue()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  activate(colorStep(80, BLUE, 2000))
  T.eq(
    "the same step with a level: blue at once, which its own pre-on brings the light up in",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X") },
    { { BLUE[1] }, {} }
  )
  run(15000)
  T.eq("with a level: and nothing after", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), { BLUE[1] })
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
  -- A rated on tells its own color: a device report of it is no news.
  local onColor = offInBlue()
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  report(onColor, 1.0)
  run(15000)
  T.eq(
    "a report during a rated on: the proxy is told the On color once, at the on",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGED", "at") },
    { { ON[1] }, { 0 } }
  )
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
  T.eq("a rated on carries that color, with its pre-on, and the proxy's own send of it adds none", #colors(), 2)
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
  --- A light off in blue, half way through a 10 s on in the On color (lit by
  --- its pre-on). Returns the On color's red, green and blue.
  local function fading()
    local onColor = offInBlue()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 10000 })
    run(5000)
    mark()
    return onColor
  end
  --- A Dim-To-Warm light half way through a 10 s fade from 50 % to 100 %,
  --- which carries the mix for 100 %.
  local function fadingUp()
    light({ ColorMode.COLOR_MODE_RGB }, false)
    onMode(ON, DIM)
    proxy("SET_LEVEL", { LEVEL = 50 })
    proxy("RAMP_TO_LEVEL", { LEVEL = 100, TIME = 10000 })
    run(5000)
    mark()
  end
  --- The same, as a 4 s fade to off is sent.
  local function fadingOff()
    fadingUp()
    proxy("RAMP_TO_LEVEL", { LEVEL = 0, TIME = 4000 })
    run(2000)
    mark()
  end

  -- With no transition ESPHome puts every channel at its target at once.
  fadingUp()
  proxy("OFF")
  T.eq("an off in a fade that carries a color: it is sent with no color", #colors(), 0)
  T.eq("the proxy is told the color with it", toldColors(), { mix(100) })
  run(15000)
  T.eq("and nothing after", toldColors(), { mix(100) })
  -- A rated on's color was lit by its pre-on and told at the on.
  for _, c in ipairs({ { "a level at once", "SET_LEVEL", { LEVEL = 50 }, 0.5 }, { "an off", "OFF", nil, 0 } }) do
    local onColor = fading()
    proxy(c[2], c[3])
    T.eq(c[1] .. " in a rated on: it is sent with no color", #colors(), 0)
    report(onColor, c[4])
    run(15000)
    T.eq(c[1] .. ": and the proxy is told no color, the device's report included", toldColors(), {})
  end
  local onColor = fading()
  proxy("RAMP_TO_LEVEL", { LEVEL = 20, TIME = 4000 })
  report(onColor, 0.2)
  run(15000)
  T.eq("a rated level in a rated on: no color is told", toldColors(), {})
  fading()
  proxy("RAMP_TO_LEVEL", { LEVEL = 20, TIME = 4000 })
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("Set Color Stop in it: the light, in the On color, is sent nothing", commands(), 0)
  fading()
  proxy("RAMP_TO_LEVEL", { LEVEL = 20, TIME = 4000 })
  run(2000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop of the ramp that replaced a rated on: the level is sent alone", #colors(), 0)
  run(15000)
  T.eq("and the proxy is told no color", toldColors(), {})

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
    run(15000)
    T.eq(name .. " in a rated on: the proxy is told no color", toldColors(), {})
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
  T.eq(
    "a level as a rated on's time is up: the proxy is told the On color at the on alone",
    { toldColors(), told("LIGHT_COLOR_CHANGED", "at") },
    { { ON[1] }, { 0 } }
  )
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
  T.eq(
    "nor told: the color is told at once, as the pre-on brings the light up in it",
    told("LIGHT_COLOR_CHANGED", "at"),
    { 0 }
  )
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
  --- Color mode each command since the mark named; false where none.
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
  light({ ColorMode.COLOR_MODE_RGB, CT })
  mark()
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq("a color temperature: no mode is named", modes(), { false })
  light({ ColorMode.COLOR_MODE_RGB, CT }, false)
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
  -- A dimmer has no mode to build a color step's fields from.
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
  -- An off light holds a color for its next on, but not one it cannot take.
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

  -- A field with nothing to report comes as NaN, in the mode the light was in.
  light(dimmer)
  level(30, 10000)
  run(100)
  push(dimmer, { state = true, brightness = 0.3 }, { 0 / 0, 0 / 0, 0 / 0 }, ColorMode.COLOR_MODE_UNKNOWN)
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

  -- A rated on whose pre-on brings the light up in the On color.
  local onColor = offInBlue()
  push({ RGB }, { state = false }, foreign)
  mark()
  level(100, 4000)
  push({ RGB }, { state = true, brightness = 0.0039 }, onColor)
  push({ RGB }, { state = true, brightness = 1.0 }, onColor)
  run(15000)
  T.eq(
    "a rated on of a light given another color elsewhere while off: the proxy is told the on's end alone",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 4000 }
  )
  T.eq("with its On color at the on", told("LIGHT_COLOR_CHANGED", "at"), { 0 })
  offInBlue()
  mark()
  level(100, 4000)
  run(1000)
  push({ RGB }, { state = true, brightness = 1.0 }, foreign)
  T.eq(
    "a color set elsewhere in a rated on: the proxy is told it, after the On color",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { ON[1], 1 / 3 }
  )
  T.eq("and the level the on was heading for", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 100 })
  run(15000)
  T.eq("and not the On color at the on's end", told("LIGHT_COLOR_CHANGED", "at"), { 0, 1000 })
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
  run(15000)
  T.eq(
    "and the On color at the on alone",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"), told("LIGHT_COLOR_CHANGED", "at") },
    { { ON[1] }, { 0 } }
  )

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
  -- A light with both in one mode is sent the white turned up, and reports it.
  local RGBCT = ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE
  light({ RGBCT })
  mark()
  kelvin(2700, 10000)
  run(100)
  push({ RGBCT }, { state = true, brightness = 1.0, color_temperature = 370.3703613, white = 1 }, { 1, 1, 1 }, RGBCT)
  run(1900)
  push({ RGBCT }, { state = true, brightness = 1.0, color_temperature = 370.3703613, white = 1 }, foreign, RGBCT)
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
    "a color temperature beyond the light's range: the proxy is told a fade to the one asked for",
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_X"),
    { 1800 / 10000 }
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
  T.eq(
    "one beyond the other end: the one asked for too",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 8000 / 10000 }
  )
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
    "and one given as its point, as a preset is: the one asked for",
    told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X"),
    { 1800 / 10000 }
  )
  C4.ColorCCTtoXY, C4.ColorXYtoCCT = toXY, toCCT
end

T.section("a fade a command re-times is read as the command goes out, not once the proxy has been told")
do
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end
  --- A color light on at full in the On color (Dim-To-Warm if `warm`), on a
  --- controller that takes 10 ms per message to the device or the proxy.
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

  -- A 1.5 s fade is steepest half way: 20 ms there is 2 % of 100 to 20.
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

  -- With Dim-To-Warm the level carries its own color, replacing the fade.
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

--- Kelvin of each command since the mark that had a color temperature.
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
  -- Dim-To-Warm runs between the Color Agent's Sunset (8) and Blue Bonnet
  -- (10); the device's own preset 10 is the stored Previous On.
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
  -- The proxy sends the mode on change and a preset on edit: the on level
  -- follows both.
  --- Edit preset 10, then remove it; `how` names where the mode came from.
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

T.section("Previous On's level is read from the proxy's setup, for a ramp from off stopped before the light is lit")
do
  -- The proxy sends Previous On when it changes: one the driver has never been sent is the setup's 20.
  forgetSetup()
  proxySetup = setupFile("setup-607.xml")
  restart({ RGBCT, CT }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  run(50)
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop 50 ms into a rated on from off: told from 1, then an off at once from 20", {
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
  }, { { 1, 20 }, { 0 } })
  forgetSetup()
  proxySetup = ""
end

T.section("a setup that lists one color or one level, and a preset listed with no level")
do
  --- A setup with one color and one level, each its on mode.
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
  -- setup-643.xml: an unedited RGBCT light's proxy, nothing stored by the
  -- driver. Both presets are 3200 K, read as 4234 K through the stubs.
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
  -- The proxy lists colors (On and Dim Color too) only once told the light
  -- has color. The two files are its answers before and after that.
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

-- The white is its own mode, or shares one with the color (no
-- color_interlock): RGBCT above, RGB with cold/warm white, or RGBW.
local RGB, CWWW = ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_COLD_WARM_WHITE
local RGBWW, RGBW = ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE, ColorMode.COLOR_MODE_RGB_WHITE
local FULL_MODE = 0

--- A report from a light of kind `modes`.
--- @param range table|nil The entity's color temperature range, in mireds.
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

--- Dim-To-Warm between an On and a Dim Color, each an xy in `mode`.
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

--- The last command sent since the mark, or an empty table.
local function lastCommand()
  for i = #sent, 1, -1 do
    if sent[i].binding == ESPHOME and sent[i].command == "ENTITY_COMMAND" then
      return DeserializeSafe(sent[i].params.body)
    end
  end
  return {}
end

--- The state a light reports once it has that command: on, in white unless
--- the command set a color.
local function taken()
  local cmd = lastCommand()
  local state = { state = true, brightness = 1.0, red = 1, green = 1, blue = 1 }
  for _, field in ipairs({
    "color_mode",
    "color_brightness",
    "red",
    "green",
    "blue",
    "white",
    "color_temperature",
    "cold_white",
    "warm_white",
  }) do
    state[field] = cmd[field] or state[field]
  end
  return state
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
    T.eq("which the proxy is told as the color picked", { colorsTold(), modesTold() }, { { 0.32 }, { FULL_MODE } })
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
    "an On Color preset, and the proxy's own copy of it after the on: the white, with the pre-on and the on alone",
    { kelvins(), colors() },
    { { 3200, 3200 }, {} }
  )
  run(1000)
  light({ RGB })
  local point = setColor(POINT)
  light()
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0 }, RANGE)
  onMode(PREVIOUS_ON)
  local inColor = { state = true, brightness = 1.0, color_mode = RGBCT, color_brightness = 1, white = 0 }
  inColor.color_temperature, inColor.red, inColor.green, inColor.blue = 300, point[1], point[2], point[3]
  pushed({ RGBCT, CT }, inColor, RANGE)
  proxy("OFF")
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(POINT, 750)
  T.eq(
    "Previous, of a light read in its color at a white's point, and the proxy's own copy of it: the white, as the same",
    { kelvins(), colors() },
    { { 3200, 3200 }, {} }
  )
  run(1000)
  light()
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0 }, RANGE)
  mark()
  colorTarget(POINT, 0)
  T.eq("a color the proxy sets: the white", { kelvins(), colors(), modesTold() }, { { 3200 }, {}, { FULL_MODE } })
  activate(colorStep(nil, POINT, 0))
  T.eq("a scene step's: the white", { kelvins(), colors() }, { { 3200 }, {} })
  proxy("CLEAR_ALL_SCENES")
  mark()
  colorTarget({ 0.2, 0.4 }, 0)
  T.eq("the point of a white beyond the light's range stays a color", { kelvins(), #colors() }, { {}, 1 })
  mark()
  colorTarget({ 0.32, 0.42 }, 0)
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
  -- Kelvin as x over a y curving like the locus: a mix of two whites is off it.
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

T.section(
  "a full color that is a white's own point lights the white alone of a light whose white has no color temperature"
)
do
  -- RGBW without color_interlock: any white in the default 2000-6536 K range,
  -- sent with the point's red, green and blue beside it.
  local POINT = { 0.32, 0.4 }
  local WHITE, COLOR = { RGBW, 0, 1 }, { RGBW, 1, 0 }
  --- What the last command lit: its color mode, color brightness and white.
  local function lit()
    local cmd = lastCommand()
    return { cmd.color_mode, cmd.color_brightness, cmd.white }
  end
  --- The y of each color the proxy was told since the mark.
  local function ysTold()
    return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y")
  end
  local function places(values)
    local out = {}
    for i, value in ipairs(values) do
      out[i] = math.floor(value * 1e6 + 0.5) / 1e6
    end
    return out
  end
  light({ RGB })
  local point = setColor(POINT)

  light({ RGBW }, false)
  fadeMode(POINT, POINT, FULL_MODE)
  mark()
  proxy("ON")
  T.eq(
    "an on in a new light's On Color: the white alone, with the point's red, green and blue beside it",
    { lit(), colors() },
    { WHITE, { point } }
  )
  T.eq("which the proxy is told as that color", { colorsTold(), modesTold() }, { { 0.32 }, { FULL_MODE } })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq("and so is a level after it, told as going from that color to it", {
    lit(),
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE"),
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_TARGET_COLOR_MODE"),
  }, { WHITE, { FULL_MODE }, { FULL_MODE } })
  run(2000)

  light({ RGBW })
  setColor(BLUE)
  mark()
  colorTarget(POINT, 0)
  T.eq("a white set from Navigator: the white alone", lit(), WHITE)
  pushed({ RGBW }, taken())
  T.eq("and the light's report of it, from a color, tells nothing more", colorsTold(), { 0.32 })
  mark()
  colorTarget({ 0.15, 0.4 }, 0)
  local warmer = lit()
  colorTarget({ 0.7, 0.4 }, 0)
  T.eq(
    "the point of a white beyond the default range, warmer or cooler: its red, green and blue alone",
    { warmer, lit() },
    { COLOR, COLOR }
  )
  activate(colorStep(nil, POINT, 0))
  T.eq("a scene step's", lit(), WHITE)
  proxy("CLEAR_ALL_SCENES")
  mark()
  colorTarget({ 0.32, 0.42 }, 0)
  T.eq("a color beside a white's point: its red, green and blue alone", lit(), COLOR)
  colorTarget(BLUE, 0)
  T.eq("and any other color", lit(), COLOR)
  light({ RGBW })
  onMode(PREVIOUS_ON)
  colorTarget(POINT, 0)
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("with Color On Mode set to Previous a light that went off in the white comes back on in it", lit(), WHITE)
  light({ RGBW })
  onMode(PREVIOUS_ON)
  local inColor = { state = true, brightness = 1.0, color_mode = RGBW, color_brightness = 1, white = 0 }
  inColor.red, inColor.green, inColor.blue = point[1], point[2], point[3]
  pushed({ RGBW }, inColor)
  proxy("OFF")
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(POINT, 750)
  T.eq(
    "and one read in its color at a white's point, with the proxy's own copy of Previous: the white, as the same",
    { #colors(), lit() },
    { 2, WHITE }
  )
  run(1000)

  -- Dim-To-Warm runs between its two ends, as on a CCT light.
  light({ RGBW })
  fadeMode({ 0.5, 0.6 }, { 0.3, 0.2 }, FULL_MODE)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("between two colors, at the level whose mix crosses a white's point: red, green and blue still", lit(), COLOR)
  light({ RGBW })
  fadeMode(POINT, BLUE, FULL_MODE)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("between a white and a color: red, green and blue, the mix not asked", lit(), COLOR)
  local toXY = C4.ColorCCTtoXY
  function C4:ColorCCTtoXY(k)
    return k / 10000, 0.4 - (k / 10000 - 0.45) ^ 2
  end
  light({ RGBW })
  fadeMode({ C4:ColorCCTtoXY(6000) }, { C4:ColorCCTtoXY(3000) }, FULL_MODE)
  local each = {}
  for _, level in ipairs({ 20, 50, 80 }) do
    mark()
    proxy("SET_LEVEL", { LEVEL = level })
    each[#each + 1] = lit()
  end
  T.eq("between two whites, their mix off the curve they are on: the white alone at every level", each, {
    WHITE,
    WHITE,
    WHITE,
  })
  T.eq(
    "and told at the white's point, not their mix, which is no white's own point",
    places({ colorsTold()[1], ysTold()[1] }),
    places({ 0.54, 0.4 - 0.09 ^ 2 })
  )
  proxy("OFF")
  onMode(PREVIOUS_ON)
  mark()
  proxy("ON")
  T.eq("and with Color On Mode then set to Previous it comes back on in the white", lit(), WHITE)
  light({ RGBW })
  fadeMode({ C4:ColorCCTtoXY(6000) }, { C4:ColorCCTtoXY(3000) }, FULL_MODE)
  proxy("SET_LEVEL", { LEVEL = 80 })
  local mix = { colorsTold()[#colorsTold()], ysTold()[#ysTold()] }
  onMode(PREVIOUS_ON)
  proxy("OFF")
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(mix, 750)
  T.eq("and with the proxy's own copy of the color it was told: the white", lit(), WHITE)
  run(1000)
  C4.ColorCCTtoXY = toXY

  -- A fade from the white to a color is a cross-fade of the two.
  light({ RGBW })
  onMode(PREVIOUS_ON)
  colorTarget(POINT, 0)
  colorTarget(BLUE, 6000)
  run(1500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a fade from the white to a color stopped a quarter through its time: held with the white turned up further",
    { places({ lastCommand().white }), lastCommand().color_brightness > 0 },
    { places({ 1 - eased(0.25) }), true }
  )
  T.eq("which the proxy is told as a white's own point", { ysTold(), modesTold() }, { { 0.4 }, { FULL_MODE } })
  pushed({ RGBW }, taken())
  T.eq("and the light's report of the stop tells nothing more", #colorsTold(), 1)
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("with Color On Mode set to Previous it comes back on in the white alone", lit(), WHITE)

  -- Another client's command: color at a hundredth beside the white at full.
  light({ RGBW })
  onMode(PREVIOUS_ON)
  setColor(BLUE)
  mark()
  local elsewhere = {
    state = true,
    brightness = 1.0,
    color_mode = RGBW,
    color_brightness = 0.01,
    red = 0,
    green = 1,
    blue = 0,
    white = 1,
  }
  pushed({ RGBW }, elsewhere)
  T.eq("another client's color at a hundredth beside the white: a white's own point", ysTold(), { 0.4 })
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("so the light comes back on in the white alone, not in that color at full", lit(), WHITE)
  light({ RGBW })
  setColor(BLUE)
  mark()
  elsewhere.color_brightness = 1
  pushed({ RGBW }, elsewhere)
  T.eq("with its color turned up further: that color", ysTold(), { 1 })
end

T.section("a full color that is a white's own point lights the white mode of a light whose white is a mode of its own")
do
  -- RGBW with color_interlock: the white is a mode of its own with no color
  -- temperature, so the driver keeps its point.
  local POINT, WARMER = { 0.32, 0.4 }, { 0.4, 0.4 }
  local W = ColorMode.COLOR_MODE_WHITE
  local INTERLOCKED = { RGB, W }
  -- What the last command lit: color mode, white, and whether it set RGB.
  local WHITE, COLOR = { W, 1, false, false }, { RGB, false, true, false }
  local function lit()
    local cmd = lastCommand()
    return {
      cmd.color_mode,
      cmd.has_white and cmd.white or false,
      cmd.has_rgb or false,
      cmd.has_color_brightness or false,
    }
  end
  --- The color mode of each command the device was sent since the mark.
  local function modesSent()
    local out = {}
    for _, s in ipairs(sent) do
      local cmd = s.binding == ESPHOME and s.command == "ENTITY_COMMAND" and DeserializeSafe(s.params.body)
      if cmd then
        out[#out + 1] = cmd.color_mode or false
      end
    end
    return out
  end
  local function sixPlaces(values)
    local out = {}
    for i, value in ipairs(values) do
      out[i] = math.floor(value * 1e6 + 0.5) / 1e6
    end
    return out
  end
  --- The light in its white as another client leaves it, blue's RGB kept.
  local function inWhite()
    pushed(INTERLOCKED, { state = true, brightness = 1.0, color_mode = W, white = 1, red = 0, green = 0.4, blue = 1 })
  end

  light(INTERLOCKED, false)
  fadeMode(POINT, POINT, FULL_MODE)
  mark()
  proxy("ON")
  T.eq("an on in a new light's On Color: the white mode, the white at full and nothing of the color", lit(), WHITE)
  T.check("the light is sent no point", lastCommand().point == nil, T.show(lastCommand()))
  T.eq("the proxy is told that color", { colorsTold(), modesTold() }, { { 0.32 }, { FULL_MODE } })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq("and a level after it stays in the white mode", lit(), WHITE)
  run(2000)

  light(INTERLOCKED)
  setColor(BLUE)
  mark()
  colorTarget(POINT, 0)
  T.eq("a white set from Navigator: the white mode", lit(), WHITE)
  pushed(INTERLOCKED, taken())
  T.eq("and the light's report of it, in a mode that has no point, tells nothing more", colorsTold(), { 0.32 })
  mark()
  pushed(INTERLOCKED, { state = true, brightness = 1.0, color_mode = RGB, color_brightness = 1, red = 1 })
  inWhite()
  T.eq(
    "another client's red and then its white: the white read at the point the driver last sent",
    { colorsTold(), modesTold() },
    { { 0, 0.32 }, { FULL_MODE, FULL_MODE } }
  )
  mark()
  colorTarget({ 0.15, 0.4 }, 0)
  local warmer = lit()
  colorTarget({ 0.7, 0.4 }, 0)
  T.eq("the point of a white beyond the default range: its color", { warmer, lit() }, { COLOR, COLOR })
  colorTarget({ 0.32, 0.43 }, 0)
  T.eq("a color beside a white's point: its color", lit(), COLOR)
  activate(colorStep(nil, POINT, 0))
  T.eq("a scene step's white: the white mode", lit(), WHITE)
  proxy("CLEAR_ALL_SCENES")
  light(INTERLOCKED, false)
  mark()
  colorTarget(POINT, 0)
  T.eq("a white for a light that is off names the white mode, which it stays off in", {
    lastCommand().state,
    lit(),
  }, { false, WHITE })

  -- Dim-To-Warm is between its two ends, as on every light with a white.
  light(INTERLOCKED)
  fadeMode(POINT, WARMER, FULL_MODE)
  local each = {}
  for _, level in ipairs({ 20, 50, 80 }) do
    proxy("SET_LEVEL", { LEVEL = level })
    each[#each + 1] = lit()
  end
  T.eq("Dim-To-Warm between two whites: the white mode at every level", each, { WHITE, WHITE, WHITE })
  light(INTERLOCKED)
  fadeMode(POINT, BLUE, FULL_MODE)
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq("between a white and a color: the color, the mix not asked", lit(), COLOR)

  -- Another client's white has no point we sent: read at the default white.
  light(INTERLOCKED)
  onMode(PREVIOUS_ON)
  setColor(BLUE)
  mark()
  inWhite()
  T.eq("another client's white, from a color: the default white's point", {
    sixPlaces(colorsTold()),
    modesTold(),
  }, { { 0.3127 }, { FULL_MODE } })
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("with Color On Mode set to Previous the light comes back on in its white mode", lit(), WHITE)

  -- The stored point survives a bind (controller start) but not an unbind.
  light(INTERLOCKED)
  colorTarget(WARMER, 0)
  restart()
  OBC[ESPHOME](ESPHOME, "ESPHOME", true)
  inWhite()
  T.eq("a white, then a restart of the driver with the light still in it: the proxy shows that white", {
    colorsTold(),
    modesTold(),
  }, { {}, {} })
  proxyColor, proxyTarget = nil, nil
  restart()
  OBC[ESPHOME](ESPHOME, "ESPHOME", true)
  inWhite()
  T.eq("and one that shows no color is told it", { colorsTold(), modesTold() }, { { 0.4 }, { FULL_MODE } })
  OBC[ESPHOME](ESPHOME, "ESPHOME", false)
  OBC[ESPHOME](ESPHOME, "ESPHOME", true)
  mark()
  inWhite()
  T.eq("and bound to another light in its white: the default white's point", sixPlaces(colorsTold()), { 0.3127 })

  -- Every white is one channel: a fade between two stays in the white mode.
  light(INTERLOCKED)
  colorTarget(POINT, 0)
  pushed(INTERLOCKED, taken())
  mark()
  colorTarget(WARMER, 4000)
  run(1000)
  proxy("SET_COLOR_STOP")
  T.eq("a fade between two whites, stopped a quarter of the way: the white mode throughout", modesSent(), { W, W })
  T.eq(
    "told where the fade had got to",
    { sixPlaces(colorsTold()), modesTold() },
    { sixPlaces({ 0.32 + 0.08 * eased(0.25) }), { FULL_MODE } }
  )
  pushed(INTERLOCKED, taken())
  T.eq("and the light's report of the stop tells nothing more", #colorsTold(), 1)

  -- White to color changes mode, which ESPHome fades through off.
  for _, case in ipairs({
    { POINT, BLUE, "from the white to blue", 1000, "a quarter", WHITE, 0.32 },
    { POINT, BLUE, "from the white to blue", 3000, "three quarters", COLOR, BLUE[1] },
    -- A hold in the color names its color brightness too.
    { BLUE, POINT, "from blue to the white", 1000, "a quarter", { RGB, false, true, true }, BLUE[1] },
    { BLUE, POINT, "from blue to the white", 3000, "three quarters", WHITE, 0.32 },
  }) do
    light(INTERLOCKED)
    colorTarget(case[1], 0)
    pushed(INTERLOCKED, taken())
    colorTarget(case[2], 4000)
    run(case[4])
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      case[3] .. ", stopped " .. case[5] .. " of the way: held in the mode the light is in",
      { lit(), sixPlaces(colorsTold()) },
      { case[6], sixPlaces({ case[7] }) }
    )
  end

  -- Two whites far apart on a curved locus: the line between them leaves it.
  local toXY = C4.ColorCCTtoXY
  function C4:ColorCCTtoXY(k)
    return k / 10000, 0.4 - (k / 10000 - 0.45) ^ 2
  end
  light(INTERLOCKED)
  onMode(PREVIOUS_ON)
  colorTarget({ C4:ColorCCTtoXY(6000) }, 0)
  pushed(INTERLOCKED, taken())
  colorTarget({ C4:ColorCCTtoXY(3000) }, 4000)
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  pushed(INTERLOCKED, taken())
  T.eq(
    "a fade between two whites far apart, stopped half way off their line: the white mode, told its white's point",
    { sixPlaces(colorsTold()), sixPlaces(told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y")), lit() },
    { { 0.45 }, { 0.4 }, WHITE }
  )
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("and with Color On Mode set to Previous it comes back on in the white mode", lit(), WHITE)
  light(INTERLOCKED)
  fadeMode({ C4:ColorCCTtoXY(6000) }, { C4:ColorCCTtoXY(3000) }, FULL_MODE)
  mark()
  proxy("SET_LEVEL", { LEVEL = 80 })
  pushed(INTERLOCKED, taken())
  T.eq(
    "Dim-To-Warm between them at a level whose mix is off their line, and the light's report: the white mode,"
      .. " told once, at its white's point",
    { sixPlaces(colorsTold()), sixPlaces(told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y")), lit() },
    { { 0.54 }, sixPlaces({ 0.4 - 0.09 ^ 2 }), WHITE }
  )
  C4.ColorCCTtoXY = toXY
end

T.section("a full color is a white's own point within one distance of the whites, the same on every side")
do
  local KINDS = {
    { "a color temperature beside its color", { RGBCT, CT }, RANGE },
    { "cold and warm white beside its color", { RGBWW }, RANGE },
    { "a color mode and a white mode", { RGB, CWWW }, RANGE },
    { "a white with no color temperature beside its color", { RGBW } },
    { "a white mode with no color temperature", { RGB, ColorMode.COLOR_MODE_WHITE } },
  }
  --- Whether the last command lit the white (a CCT, or a plain white alone).
  local function whiteLit()
    local cmd = lastCommand()
    return cmd.has_color_temperature or (cmd.white == 1 and (cmd.color_brightness or 0) == 0) or false
  end
  --- Whether each of `colors`, set in turn on a `kind` light, lights a white.
  local function whites(kind, colors)
    light()
    pushed(kind[2], { state = true, brightness = 1.0 }, kind[3])
    local out = {}
    for _, xy in ipairs(colors) do
      colorTarget(xy, 0)
      out[#out + 1] = whiteLit()
    end
    return out
  end

  -- C4's answers on a controller (OS 4.3.0) for color wheel picks: the pick's
  -- xy, the temperature C4 gives it (the nearest point's), and that point.
  local WHEEL = {
    { 0.3127100, 0.3290200, 6360, 0.3157647, 0.3257940 }, -- its middle, 0.0044 from the point
    { 0.3117924, 0.3320290, 6300, 0.3167600, 0.3267477 }, -- 1 % toward green (hue 120), 0.0073
    { 0.3108568, 0.3350972, 6240, 0.3177775, 0.3277168 }, -- 2 %, 0.0101
    { 0.3099028, 0.3382255, 6180, 0.3188177, 0.3287015 }, -- 3 %, 0.0130
    { 0.3632250, 0.3545299, 4580, 0.3580381, 0.3615429 }, -- 20 % toward orange (hue 30), 0.0087
    { 0.5277968, 0.4362199, 2020, 0.5245015, 0.4136185 }, -- an orange at 80 % (hue 39), 0.0228
    { 0.708, 0.292, 1000, 0.6527501, 0.3444622 }, -- red, at the 1000 K end of the whites, 0.0762
  }
  local toXY, toCCT = C4.ColorCCTtoXY, C4.ColorXYtoCCT
  function C4:ColorXYtoCCT(x, y)
    for _, pick in ipairs(WHEEL) do
      if (x == pick[1] and y == pick[2]) or (x == pick[4] and y == pick[5]) then
        return pick[3]
      end
    end
  end
  function C4:ColorCCTtoXY(k)
    for _, pick in ipairs(WHEEL) do
      if pick[3] == k then
        return pick[4], pick[5]
      end
    end
  end
  local picks = {}
  for i = 1, 6 do
    picks[i] = WHEEL[i]
  end
  for _, kind in ipairs(KINDS) do
    T.eq(
      "a light with "
        .. kind[1]
        .. ": the wheel's middle, 1 and 2 % toward green and 20 % toward orange are whites; 3 % toward green and"
        .. " an orange at 80 % are not",
      whites(kind, picks),
      { true, true, true, false, true, false }
    )
  end
  T.eq(
    "red, for a light whose range reaches 1000 K: not a white",
    whites({ nil, { RGBCT, CT }, { 153.8, 1000 } }, { WHEEL[7] }),
    { false }
  )
  C4.ColorCCTtoXY, C4.ColorXYtoCCT = toXY, toCCT

  -- Through the stubs the whites run along y = 0.4.
  for _, kind in ipairs(KINDS) do
    T.eq(
      "a light with " .. kind[1] .. ": 0.011 from a white's point on either side is a white, and 0.013 is not",
      whites(kind, { { 0.32, 0.411 }, { 0.32, 0.389 }, { 0.32, 0.413 }, { 0.32, 0.387 } }),
      { true, true, false, false }
    )
  end
end

T.section("a color picked near a white lights that white, and the proxy is told the color picked")
do
  -- Through the stubs 0.01 from the 3200 K white's point: inside the bound, and
  -- outside the tolerance a color the light reports is compared at.
  local PICK, POINT = { 0.32, 0.41 }, { 0.32, 0.4 }
  local W = ColorMode.COLOR_MODE_WHITE
  -- Each kind: modes, range, the white's mode when unnamed, another client's
  -- white, the mode a white's point is told in, and its 4000 K report.
  local AT_4000, RGB_4000 = { color_temperature = 250 }, { red = 0.6, green = 1, blue = 0.76 }
  local KINDS = {
    {
      "a color temperature beside its color",
      { RGBCT, CT },
      RANGE,
      nil,
      { color_temperature = 309 },
      CCT_MODE,
      AT_4000,
    },
    { "cold and warm white beside its color", { RGBWW }, RANGE, nil, { color_temperature = 309 }, CCT_MODE, AT_4000 },
    { "a color mode and a white mode", { RGB, CWWW }, RANGE, CWWW, { color_temperature = 309 }, CCT_MODE, AT_4000 },
    { "a white with no color temperature beside its color", { RGBW }, nil, nil, { white = 0.5 }, FULL_MODE, RGB_4000 },
    { "a white mode with no color temperature", { RGB, W }, nil, nil, { white = 0.5 }, FULL_MODE },
  }
  --- Whether the last command lit the white (a CCT, or a plain white alone).
  local function whiteLit()
    local cmd = lastCommand()
    return cmd.has_color_temperature or (cmd.white == 1 and (cmd.color_brightness or 0) == 0) or false
  end
  --- Each color told since the mark: x and y to six places, and its mode.
  local function toldColors()
    local xs, ys, modes = colorsTold(), told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y"), modesTold()
    local out = {}
    for i = 1, #xs do
      out[i] = { math.floor(xs[i] * 1e6 + 0.5) / 1e6, math.floor(ys[i] * 1e6 + 0.5) / 1e6, modes[i] }
    end
    return out
  end
  local PICKED, AT_POINT = { { 0.32, 0.41, FULL_MODE } }, { { 0.32, 0.4, FULL_MODE } }
  local function lightOf(kind, on)
    light()
    pushed(kind[2], { state = on ~= false, brightness = 1.0 }, kind[3])
  end
  --- The light's report of its last command, which is returned.
  local function report(kind)
    local state = taken()
    state.color_mode = state.color_mode or kind[4]
    pushed(kind[2], state, kind[3])
    return state
  end

  for _, kind in ipairs(KINDS) do
    lightOf(kind)
    onMode(PREVIOUS_ON)
    colorTarget(BLUE, 0)
    mark()
    colorTarget(PICK, 0)
    T.eq(
      "a light with " .. kind[1] .. ": a color picked near a white, set from Navigator, lights it",
      { whiteLit(), toldColors() },
      { true, PICKED }
    )
    local own = taken()
    own.color_mode = own.color_mode or kind[4]
    mark()
    pushed(kind[2], own, kind[3])
    T.eq("and the light's report of that white is read back as the color picked", toldColors(), {})
    proxy("OFF")
    mark()
    proxy("ON")
    T.eq(
      "with Color On Mode set to Previous it comes back on in that white",
      { whiteLit(), toldColors() },
      { true, PICKED }
    )
    local state = report(kind)
    restart()
    OBC[ESPHOME](ESPHOME, "ESPHOME", true)
    pushed(kind[2], state, kind[3])
    T.eq(
      "a restart of the driver with the light still in that white: the proxy shows the color picked",
      toldColors(),
      {}
    )
    proxyColor, proxyTarget = nil, nil
    restart()
    OBC[ESPHOME](ESPHOME, "ESPHOME", true)
    pushed(kind[2], state, kind[3])
    T.eq("and one that shows no color is told it", toldColors(), PICKED)
    if kind[7] then
      restart()
      OBC[ESPHOME](ESPHOME, "ESPHOME", true)
      local other = {}
      for field, value in pairs(state) do
        other[field] = kind[7][field] or value
      end
      pushed(kind[2], other, kind[3])
      T.eq("and one with the light in another white: that white's point", toldColors(), { { 0.4, 0.4, kind[6] } })
    end
    mark()
    for field, value in pairs(kind[5]) do
      state[field] = value
    end
    pushed(kind[2], state, kind[3])
    T.eq(
      "another client's white beside it: the point of the white the light shows",
      { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y"), modesTold() },
      { { 0.4 }, { kind[6] } }
    )

    lightOf(kind)
    colorTarget(BLUE, 0)
    mark()
    colorTarget(POINT, 0)
    T.eq("a color at a white's own point: that point, in the mode it was picked in", toldColors(), AT_POINT)

    lightOf(kind, false)
    onMode({ PICK[1], PICK[2], id = 1 })
    mark()
    proxy("ON")
    T.eq("an On Color picked near a white: the on lights the white", { whiteLit(), toldColors() }, { true, PICKED })
    lightOf(kind)
    fadeMode({ 0.34, 0.41 }, { 0.3, 0.41 }, FULL_MODE)
    mark()
    proxy("SET_LEVEL", { LEVEL = 50 })
    T.eq(
      "Dim-To-Warm between two colors picked near whites: the white of their mix, told as the mix",
      { whiteLit(), toldColors() },
      { true, PICKED }
    )
    lightOf(kind)
    colorTarget(BLUE, 0)
    activate(colorStep(nil, PICK, 0))
    T.eq("a scene step's color picked near a white", { whiteLit(), toldColors() }, { true, PICKED })
    proxy("CLEAR_ALL_SCENES")
  end

  -- A stop where the light is in the white, as each kind fades into it.
  for _, kind in ipairs({ KINDS[1], KINDS[3], KINDS[5] }) do
    lightOf(kind)
    colorTarget(BLUE, 0)
    colorTarget(PICK, 4000)
    run(3000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "a light with "
        .. kind[1]
        .. ": a fade from blue to a color picked near a white, stopped three quarters of the way",
      toldColors(),
      PICKED
    )
  end
  lightOf(KINDS[5])
  colorTarget(PICK, 0)
  report(KINDS[5])
  colorTarget(BLUE, 4000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "on one whose white is a mode of its own, a fade from it to blue stopped a quarter of the way: still in it",
    { whiteLit(), toldColors() },
    { true, PICKED }
  )

  -- The proxy's own copy of the color an on carried reads as that color.
  lightOf(KINDS[1])
  onMode(PREVIOUS_ON)
  colorTarget(PICK, 0)
  proxy("OFF")
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  colorTarget(PICK, 750)
  T.eq(
    "Previous, and the proxy's own copy of it after the on: the white, with the pre-on and the on alone",
    { kelvins(), colors(), toldColors() },
    { { 3200, 3200 }, {}, PICKED }
  )
  run(1000)

  -- A color temperature is told as its point, and the light's report of it too.
  lightOf(KINDS[1])
  colorTarget(PICK, 0)
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3200, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  report(KINDS[1])
  T.eq("a color temperature set at that white, and its report: its point", toldColors(), { { 0.32, 0.4, CCT_MODE } })

  -- Separate modes: a stop part way to another white is told at the one held.
  lightOf(KINDS[3])
  colorTarget(PICK, 0)
  report(KINDS[3])
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 4000, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  report(KINDS[3])
  T.eq(
    "a light with "
      .. KINDS[3][1]
      .. ": a fade from a color picked near a white to a color temperature, stopped a quarter of the way,"
      .. " and its report: told once, at the white it is held in",
    { told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_Y"), modesTold() },
    { { 0.4 }, { CCT_MODE } }
  )

  -- Previous keeps the color picked: a color once its white leaves the range.
  lightOf(KINDS[1])
  onMode(PREVIOUS_ON)
  colorTarget(PICK, 0)
  proxy("OFF")
  restart()
  OBC[ESPHOME](ESPHOME, "ESPHOME", true)
  pushed(KINDS[1][2], { state = false, brightness = 1.0 }, { 153.8, 250 })
  mark()
  proxy("ON")
  T.eq(
    "Previous, a color picked near a white the light's range no longer reaches: its red, green and blue",
    { whiteLit(), #colors(), toldColors() },
    { false, 1, PICKED }
  )

  -- A light without color has only its white, and a proxy told no color.
  light()
  pushed({ CT }, { state = false, brightness = 1.0 }, RANGE)
  onMode({ PICK[1], PICK[2], id = 1 })
  mark()
  proxy("ON")
  T.eq(
    "a light with only a color temperature: an On Color picked near a white lights it, told as its point",
    { kelvins(), toldColors() },
    { { 3200 }, { { 0.32, 0.4, CCT_MODE } } }
  )
  light()
  pushed({ CT }, { state = true, brightness = 1.0 }, RANGE)
  fadeMode({ 0.34, 0.41 }, { 0.3, 0.41 }, FULL_MODE)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "and Dim-To-Warm between two colors picked near whites: the white of their mix, told as its point",
    { kelvins(), toldColors() },
    { { 3200 }, { { 0.32, 0.4, CCT_MODE } } }
  )
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
  -- 3200 K between the default 153 and 500 mireds, or the light's own end.
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

--- What that command turns up and down: its color mode, color brightness,
--- white, cold white and warm white, false for each it does not set.
local function channels()
  local cmd = lastCommand()
  return {
    cmd.has_color_mode and cmd.color_mode or false,
    cmd.has_color_brightness and cmd.color_brightness or false,
    cmd.has_white and cmd.white or false,
    cmd.has_cold_white and cmd.cold_white or false,
    cmd.has_warm_white and cmd.warm_white or false,
  }
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

T.section("a color temperature for a light in a combined color mode turns the color down, in that mode")
do
  --- Color On Mode: a color temperature preset, and a dim one for Dim-To-Warm.
  local function onModeKelvin(on, dim)
    proxy("UPDATE_COLOR_ON_MODE", {
      COLOR_PRESET_ID = 1,
      COLOR_PRESET_ORIGIN = 1,
      COLOR_PRESET_COLOR_X = on / 10000,
      COLOR_PRESET_COLOR_Y = 0.4,
      COLOR_PRESET_COLOR_MODE = CCT_MODE,
      COLOR_FADE_PRESET_ID = dim and 2 or 0,
      COLOR_FADE_PRESET_ORIGIN = dim and 1 or 0,
      COLOR_FADE_PRESET_COLOR_X = dim and dim / 10000,
      COLOR_FADE_PRESET_COLOR_Y = dim and 0.4,
      COLOR_FADE_PRESET_COLOR_MODE = CCT_MODE,
    })
  end
  local WHITE = { RGBCT, 0, 1, false, false }
  light({ RGBCT, CT })
  setColor(BLUE)
  mark()
  kelvin(3000, 0)
  T.eq("a light in a color: the combined mode, the color off and the white up", channels(), WHITE)
  T.eq("at the color temperature", kelvins(), { 3000 })
  T.eq("and at the level it was: none is sent", lastCommand().has_brightness or false, false)
  T.eq("nor told", told("LIGHT_BRIGHTNESS_CHANGED", "at"), {})
  mark()
  kelvin(5000, 3000)
  T.eq("over a rate", { channels(), lengths() }, { WHITE, { 3000 } })
  light({ RGBCT, CT }, false)
  mark()
  kelvin(3000, 0)
  T.eq("for a light that is off, which stays off", { lastCommand().state, channels() }, { false, WHITE })
  light({ RGBCT, CT }, false)
  onModeKelvin(3000)
  mark()
  proxy("ON")
  T.eq("the color temperature an on carries: not the white-only mode", { kelvins(), channels() }, { { 3000 }, WHITE })
  light({ RGBCT, CT })
  onModeKelvin(6000, 3000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq("Dim-To-Warm's color temperature for a level", { kelvins(), channels() }, { { 4500 }, WHITE })
  light({ RGBCT, CT })
  activate(
    "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>0.3</colorX><colorY>0.4</colorY>"
      .. "<colorMode>1</colorMode><colorRate>0</colorRate></element>"
  )
  T.eq("a scene step's", { kelvins(), channels() }, { { 3000 }, WHITE })
  proxy("CLEAR_ALL_SCENES")

  -- ESPHome works a color temperature out into cold and warm white with the
  -- light's gamma, for a light that gives a range for it.
  light()
  pushed({ RGBWW }, { state = true, brightness = 1.0 }, RANGE)
  mark()
  kelvin(4000, 0)
  T.eq(
    "a light with cold and warm white: the color off, and the two left to the light",
    { kelvins(), channels() },
    { { 4000 }, { RGBWW, 0, false, false, false } }
  )
  local warm = (250 - 153) / (500 - 153)
  local cmd
  for name, range in pairs({
    ["no range"] = {},
    ["one end of a range"] = { 153.8, 0 },
    ["the other end"] = { 0, 370.4 },
  }) do
    light()
    pushed({ RGBWW }, { state = true, brightness = 1.0 }, range)
    mark()
    kelvin(4000, 0)
    cmd = lastCommand()
    T.check(
      "one that gives " .. name .. " cannot, and is sent the two",
      cmd.color_brightness == 0
        and not cmd.has_white
        and math.abs(cmd.cold_white + cmd.warm_white - 1) < 1e-9
        and cmd.cold_white > cmd.warm_white,
      T.show(cmd)
    )
  end

  -- A light whose color and white are separate modes is sent what it was.
  light({ RGB, CT })
  setColor(BLUE)
  mark()
  kelvin(3000, 0)
  T.eq(
    "a light with a color mode and a white mode: the color temperature alone",
    channels(),
    { false, false, false, false, false }
  )
  light({ RGBW, CT })
  setColor(BLUE)
  mark()
  kelvin(3000, 0)
  T.eq(
    "a light whose combined mode has no color temperature: the same",
    channels(),
    { false, false, false, false, false }
  )
  light({ RGB, CWWW }, false)
  onModeKelvin(4000)
  mark()
  proxy("ON")
  cmd = lastCommand()
  T.check(
    "the one an on carries: its white mode and the driver's own two",
    cmd.color_mode == CWWW
      and not cmd.has_color_brightness
      and not cmd.has_white
      and math.abs(cmd.cold_white - (1 - warm)) < 1e-9
      and math.abs(cmd.warm_white - warm) < 1e-9,
    T.show(cmd)
  )

  -- The light reports each of these back: one that differs is another client's.
  for _, case in ipairs({
    { "the color brightness", { RGBCT, CT }, "color_brightness", 1 },
    { "the white", { RGBCT, CT }, "white", 0 },
    { "the cold white", { RGBWW }, "cold_white", 1 },
    { "the warm white", { RGBWW }, "warm_white", 1 },
  }) do
    for _, reported in ipairs({ true, false }) do
      local name, modes = case[1], case[2]
      light(modes)
      mark()
      kelvin(4000, 10000)
      run(100)
      local state = taken()
      if reported then
        pushed(modes, state)
        T.eq(
          name .. ": the light's report of the fade's own command tells nothing",
          told("LIGHT_COLOR_CHANGED", "at"),
          {}
        )
      end
      run(1900)
      state[case[3]] = case[4]
      pushed(modes, state)
      T.eq(
        name
          .. " set elsewhere in the fade"
          .. (reported and "" or ", ahead of the fade's own report")
          .. ": it is over then",
        told("LIGHT_COLOR_CHANGED", "at"),
        { 2000 }
      )
    end
  end
end

T.section("a color temperature for a light in its white-only mode leaves it in that mode")
do
  -- How a restart of the light or another client can leave an RGBCT light.
  local WHITE_ONLY = {
    state = true,
    brightness = 1.0,
    color_mode = CT,
    color_brightness = 1,
    red = 1,
    green = 1,
    blue = 1,
    white = 1,
    color_temperature = 300,
  }
  --- A light with both modes, in the white-only one.
  local function whiteOnly()
    light({ RGBCT, CT })
    pushed({ RGBCT, CT }, WHITE_ONLY, RANGE)
    mark()
  end
  whiteOnly()
  kelvin(3000, 3000)
  T.eq(
    "a color temperature over a rate: that alone, with no mode for the light to fade through off to",
    { kelvins(), channels() },
    { { 3000 }, { false, false, false, false, false } }
  )
  whiteOnly()
  fadeMode({ 0.5, 0.4 }, { 0.27, 0.4 }, CCT_MODE)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 3000 })
  T.eq(
    "the one a level carries: the mode the light is in",
    { kelvins(), channels() },
    { { 3620 }, { CT, false, false, false, false } }
  )
  -- A color has to leave it: the white-only mode has none.
  whiteOnly()
  colorTarget(BLUE, 3000)
  T.eq("a color names the combined mode", channels(), { RGBCT, 1, 0, false, false })
  -- The light reports a command a tenth of a second after it has it.
  whiteOnly()
  colorTarget(BLUE, 0)
  mark()
  kelvin(3000, 3000)
  T.eq(
    "a color temperature after a color, ahead of the light's report of the color: the combined mode",
    channels(),
    { RGBCT, 0, 1, false, false }
  )
  pushed({ RGBCT, CT }, WHITE_ONLY, RANGE)
  mark()
  kelvin(4000, 3000)
  T.eq(
    "and still, when the report that comes is of the state before the two",
    channels(),
    { RGBCT, 0, 1, false, false }
  )
  -- Another client puts the light back after our color was long reported.
  whiteOnly()
  colorTarget(BLUE, 0)
  pushed({ RGBCT, CT }, taken(), RANGE)
  pushed({ RGBCT, CT }, WHITE_ONLY, RANGE)
  mark()
  kelvin(3000, 3000)
  T.eq(
    "a light put back in its white-only mode elsewhere is left there again",
    channels(),
    { false, false, false, false, false }
  )
  whiteOnly()
  colorTarget(BLUE, 0)
  local elsewhere = {}
  for field, value in pairs(WHITE_ONLY) do
    elsewhere[field] = value
  end
  elsewhere.color_temperature = 250
  pushed({ RGBCT, CT }, elsewhere, RANGE)
  mark()
  kelvin(3000, 3000)
  T.eq(
    "and when it is put there after the driver's color and ahead of its report: the report is where it is",
    channels(),
    { false, false, false, false, false }
  )
  -- ESPHome gives a mode-less light its first mode at a turn-on naming none,
  -- such as a rated on's pre-on with no color.
  light({ RGBCT, CT }, false)
  fadeMode({ 0.5, 0.4 }, { 0.27, 0.4 }, CCT_MODE)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
  T.eq(
    "a light with no mode yet, ramped on with Dim-To-Warm: the combined mode, which its pre-on names too",
    { kelvins(), channels() },
    { { 5000, 5000 }, { RGBCT, 0, 1, false, false } }
  )
  light({ RGBCT, CT }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
  mark()
  kelvin(3000, 3000)
  T.eq(
    "and a color temperature sent as it ramps on, ahead of its report: that mode",
    channels(),
    { false, false, false, false, false }
  )
  light({ RGBCT, CT }, false)
  proxy("ON")
  mark()
  kelvin(3000, 3000)
  T.eq(
    "turned on at once, and sent a color temperature ahead of its report: the same",
    channels(),
    { false, false, false, false, false }
  )
  light({ RGBCT, CT }, false)
  activate(
    "<element><delay>0</delay><rate>3000</rate><brightnessEnabled>true</brightnessEnabled><brightness>100</brightness>"
      .. "<colorEnabled>true</colorEnabled><colorX>0.3</colorX><colorY>0.4</colorY><colorMode>1</colorMode></element>"
  )
  T.eq(
    "and a scene step that ramps it on in a color temperature: the combined mode, with its pre-on",
    { kelvins(), channels() },
    { { 3000, 3000 }, { RGBCT, 0, 1, false, false } }
  )
  proxy("CLEAR_ALL_SCENES")
end

T.section("a full color for a light in a combined color mode turns the white off")
do
  local COLOR = { RGBCT, 1, 0, false, false }
  light({ RGBCT, CT })
  kelvin(3000, 0)
  mark()
  colorTarget(ON, 0)
  T.eq("a light in a white: the color up and the white off", channels(), COLOR)
  mark()
  colorTarget(BLUE, 3000)
  T.eq("over a rate", { channels(), lengths() }, { COLOR, { 3000 } })
  light({ RGBW })
  mark()
  colorTarget(ON, 0)
  T.eq("a light with a white beside its color", channels(), { RGBW, 1, 0, false, false })
  light({ RGBWW })
  mark()
  colorTarget(ON, 0)
  T.eq("one with cold and warm white: both off", channels(), { RGBWW, 1, false, 0, 0 })
  light({ RGBCT, CT }, false)
  mark()
  colorTarget(ON, 0)
  T.eq("a color for a light that is off, which stays off", { lastCommand().state, channels() }, { false, COLOR })
  light({ RGBCT, CT }, false)
  onMode(ON)
  mark()
  proxy("ON")
  T.eq("the On color an on carries", channels(), COLOR)
  light({ RGBCT, CT })
  activate(colorStep(50, BLUE, 2000))
  T.eq("a scene step's", channels(), COLOR)
  proxy("CLEAR_ALL_SCENES")
  light({ RGB })
  mark()
  colorTarget(ON, 0)
  T.eq("a light with a color alone: the color, as before", channels(), { RGB, false, false, false, false })
  light({ RGB, CT })
  mark()
  colorTarget(ON, 0)
  T.eq("a light with a color mode and a white mode: the same", channels(), { RGB, false, false, false, false })

  -- A report of the color with the white lit again is another client's.
  light({ RGBCT, CT })
  mark()
  colorTarget(BLUE, 10000)
  run(100)
  local state = taken()
  pushed({ RGBCT, CT }, state)
  T.eq("the light's report of a fade's own color tells nothing", told("LIGHT_COLOR_CHANGED", "at"), {})
  run(1900)
  state.white = 0.5
  pushed({ RGBCT, CT }, state)
  T.eq("the white turned up elsewhere in the fade: it is over then", told("LIGHT_COLOR_CHANGED", "at"), { 2000 })
  T.eq("in the color, which is still lit", modesTold(), { FULL_MODE })
end

T.section("a color temperature for a light that is off names the white mode, where the mode it is off in may have none")
do
  -- ESPHome keeps the color mode of a light that is off unless a command names
  -- one, and drops a color temperature the mode cannot hold.
  light()
  pushed({ RGB, CWWW }, { state = false, brightness = 1.0 }, RANGE)
  setColor(BLUE)
  mark()
  kelvin(3000, 0)
  T.eq(
    "off in a color, a light with a color mode and a white mode: the white mode, and the light stays off",
    { lastCommand().state, kelvins(), channels() },
    { false, { 3000 }, { CWWW, false, false, false, false } }
  )
  light({ RGB, CWWW }, false)
  setColor(BLUE)
  mark()
  kelvin(3000, 0)
  local cmd = lastCommand()
  T.check(
    "one that gives no range for its color temperature: the driver's own cold and warm white with it",
    cmd.color_mode == CWWW and math.abs(cmd.cold_white + cmd.warm_white - 1) < 1e-9,
    T.show(cmd)
  )
  light({ RGB, CT })
  setColor(BLUE)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 3000 })
  run(1000)
  mark()
  kelvin(3000, 0)
  T.eq(
    "a light fading to off: the white mode, as an off over the time the fade has left",
    { lastCommand().state, channels()[1], lengths() },
    { false, CT, { 2000 } }
  )
  run(3000)
  light({ RGB, CT }, false)
  setColor(BLUE)
  activate(
    "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>0.3</colorX><colorY>0.4</colorY>"
      .. "<colorMode>1</colorMode><colorRate>2000</colorRate></element>"
  )
  T.eq("a scene step's, with no level", { lastCommand().state, channels()[1] }, { false, CT })
  proxy("CLEAR_ALL_SCENES")
  light({ RGBCT, CT }, false)
  pushed({ RGBCT, CT }, { state = false, brightness = 1.0, color_mode = CT, color_temperature = 300 }, RANGE)
  mark()
  kelvin(3000, 0)
  T.eq(
    "an RGBCT light off in its white-only mode: that mode",
    { lastCommand().state, channels() },
    { false, { CT, false, false, false, false } }
  )
  light({ CT }, false)
  mark()
  kelvin(3000, 0)
  T.eq(
    "a light with a color temperature alone: that alone, as before",
    channels(),
    { false, false, false, false, false }
  )
  -- On, a change of mode is a fade through off, and is left to the light.
  light({ RGB, CT })
  setColor(BLUE)
  mark()
  kelvin(3000, 2000)
  T.eq("a light that is on is sent the color temperature alone", channels(), { false, false, false, false, false })
end

T.section("a fade on a light in its combined color mode, stopped part way, is held where the light is")
do
  --- Six places: a fade's easing leaves values just off a round figure.
  local function places(values)
    local out = {}
    for i, value in ipairs(values) do
      out[i] = type(value) == "number" and math.floor(value * 1e6 + 0.5) / 1e6 or value
    end
    return out
  end
  --- What the stop sent: its color brightness and its white.
  local function held()
    return places({ lastCommand().color_brightness, lastCommand().white })
  end
  --- The last color told since the mark: its x and its color mode.
  local function lastTold()
    local xs, modes = colorsTold(), modesTold()
    return places({ xs[#xs], modes[#modes] })
  end
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end
  --- A color scaled as the light does: largest channel at full, and the scale.
  local function scaled(r, g, b)
    local full = math.max(r, g, b)
    return { r / full, g / full, b / full }, full
  end

  -- ESPHome fades each color/white field to its target (color down, white up);
  -- half way through its time a fade is half way along.
  light({ RGBCT, CT })
  local blue = setColor(BLUE)
  kelvin(3000, 6000)
  run(3000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a color fading to a white, half way: half of each, in the combined mode",
    { channels(), kelvins(), lengths() },
    { { RGBCT, 0.5, 0.5, false, false }, { 3000 }, { 0 } }
  )
  T.eq("the color its own", colors(), { blue })
  T.eq("which the proxy is told, the two being level", lastTold(), { BLUE[1], FULL_MODE })
  pushed({ RGBCT, CT }, taken())
  T.eq("and the light's report of both lit tells nothing more", #colorsTold(), 1)
  light({ RGBCT, CT })
  kelvin(3000, 0)
  colorTarget(BLUE, 6000)
  run(1500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a white fading to a color, a quarter through its time: the color as far as it has come",
    { held(), kelvins() },
    { places({ eased(0.25), 1 - eased(0.25) }), { 3000 } }
  )
  T.eq("where the light is still in the white, which the proxy is told", lastTold(), { 0.3, CCT_MODE })

  -- The proxy is told the one that is turned up further, as a report is read.
  light({ RGBCT, CT })
  onMode(PREVIOUS_ON)
  setColor(BLUE)
  kelvin(3000, 4000)
  run(3600)
  mark()
  proxy("SET_COLOR_STOP")
  -- eased(0.9) is 0.991: the color is at under a hundredth, the white at full.
  T.eq("nine tenths through a fade to a white: the white, not a color at a hundredth", modesTold(), { CCT_MODE })
  pushed({ RGBCT, CT }, taken())
  T.eq("and the light's report of what the stop sent tells no color", modesTold(), { CCT_MODE })
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("with Color On Mode set to Previous the light comes back on in that white", { kelvins(), colors() }, {
    { 3000 },
    {},
  })
  light({ RGBCT, CT })
  kelvin(3000, 0)
  colorTarget(BLUE, 4000)
  run(2400)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("six tenths through a fade to a color: the color", lastTold(), { BLUE[1], FULL_MODE })

  -- The white's CCT and the color fade too, each from where the light had it.
  light({ RGBCT, CT })
  setColor(BLUE)
  local state = taken()
  state.color_temperature = 200
  pushed({ RGBCT, CT }, state, RANGE)
  kelvin(3000, 6000)
  run(4500)
  mark()
  proxy("SET_COLOR_STOP")
  local mireds = 200 + (1e6 / 3000 - 200) * eased(0.75)
  T.eq(
    "a white coming up from another color temperature is held at the one it has got to",
    { lastCommand().color_temperature, lastTold() },
    { mireds, places({ math.floor(1e6 / mireds + 0.5) / 10000, CCT_MODE }) }
  )
  light({ RGBCT, CT })
  local on = setColor(ON)
  kelvin(3000, 0)
  mark()
  colorTarget(BLUE, 6000)
  run(3000)
  mark()
  proxy("SET_COLOR_STOP")
  local mixed, full = scaled((on[1] + blue[1]) / 2, (on[2] + blue[2]) / 2, (on[3] + blue[3]) / 2)
  T.eq(
    "a color coming up from another color: the mix the light has, its scale in the color brightness",
    { places(colors()[1]), held() },
    { places(mixed), places({ 0.5 * full, 0.5 }) }
  )

  -- Any command restarts the light's fade from where it is, over its own time.
  light({ RGBCT, CT })
  setColor(BLUE)
  kelvin(3000, 6000)
  run(3000)
  mark()
  level(50, 2000)
  T.eq("a level sent half way: the fade is told again from the color, the two being level", {
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X")[1] - BLUE[1] < 1e-9,
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE"),
  }, { true, { FULL_MODE } })
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a stop half way through that: three quarters of the way", held(), { 0.25, 0.75 })
  light({ RGBCT, CT })
  kelvin(3000, 0)
  colorTarget(BLUE, 6000)
  run(3000)
  level(50, 2000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("the same of a white fading to a color", held(), { 0.75, 0.25 })
  -- With 10 ms per message, timed from when the level went out.
  light({ RGBCT, CT })
  setColor(BLUE)
  local send = SendToProxy
  function SendToProxy(...)
    send(...)
    now = now + 10
  end
  kelvin(3000, 6000)
  run(2980)
  local asOf = now
  level(50, 2000)
  run(asOf + 1000 - now)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("the fade a level takes on is read as the level goes out", held(), { 0.25, 0.75 })
  light({ RGBCT, CT })
  setColor(BLUE)
  kelvin(3000, 4000)
  run(2000)
  kelvin(5000, 4000)
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("another white half way, stopped half way through that: a quarter of the color left", held(), { 0.25, 0.75 })
  light({ RGBCT, CT })
  setColor(BLUE)
  kelvin(3000, 4000)
  run(2000)
  mark()
  colorTarget(ON, 4000)
  T.eq(
    "a color that takes the fade over is told from the color the light is in",
    places(told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X")),
    { BLUE[1] }
  )
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  mixed, full = scaled((on[1] + blue[1]) / 2, (on[2] + blue[2]) / 2, (on[3] + blue[3]) / 2)
  T.eq(
    "and stopped half way through that, is held with a quarter of the white left",
    { places(colors()[1]), held() },
    { places(mixed), places({ 0.75 * full, 0.25 }) }
  )
  light({ RGBCT, CT })
  kelvin(3000, 0)
  colorTarget(BLUE, 4000)
  run(1000)
  proxy("SET_COLOR_STOP")
  colorTarget(BLUE, 4000)
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  local first = eased(0.25)
  T.eq(
    "a fade stopped, sent again and stopped again holds some of each, not the color at full",
    held(),
    places({ first + (1 - first) * 0.5, (1 - first) * 0.5 })
  )
  -- A level stop holds over the color's remaining time, restarting the fade.
  light({ RGBCT, CT })
  setColor(BLUE)
  level(40, 6000)
  kelvin(3000, 6000)
  run(3000)
  proxy("SET_BRIGHTNESS_STOP")
  run(1500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a stop of the level half way, then of the color half way through what was left", held(), { 0.25, 0.75 })
  light({ RGBCT, CT })
  setColor(BLUE)
  level(40, 6000)
  run(1000)
  kelvin(3000, 6000)
  run(3000)
  level(80, 4000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a fade stopped while the level ramps: some of each, over the time the ramp has left",
    { held(), lengths() },
    { places({ 0.5 * (1 - eased(0.25)), 1 - 0.5 * (1 - eased(0.25)) }), { 3000 } }
  )

  -- The color a level command carries fades under the level, and is handed on
  -- with the ramp to a level that carries none.
  light({ RGBCT, CT })
  blue = setColor(BLUE)
  fadeMode({ 0.3, 0.4 }, { 0.3, 0.4 }, CCT_MODE)
  level(50, 6000)
  run(2000)
  onMode(ON)
  mark()
  level(40, 4000)
  T.eq(
    "Dim-To-Warm's white coming up under a level from a color: a level with none tells it from the color, still lit",
    places({
      told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X")[1],
      told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE")[1],
    }),
    { BLUE[1], FULL_MODE }
  )
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  local left = (1 - eased(1 / 3)) * 0.5
  T.eq(
    "and a stop half way through that holds what the light has, told as the white it is mostly in",
    { held(), colors(), lastTold() },
    { places({ left, 1 - left }), { blue }, { 0.3, CCT_MODE } }
  )
  -- A rated on brings the light up in the color it carries, with its pre-on.
  light({ RGBCT, CT }, false)
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = 0.3,
    COLOR_PRESET_COLOR_Y = 0.4,
    COLOR_PRESET_COLOR_MODE = CCT_MODE,
    COLOR_FADE_PRESET_ID = 0,
    COLOR_FADE_PRESET_ORIGIN = 0,
  })
  setColor(BLUE)
  mark()
  level(100, 6000)
  T.eq(
    "a white preset a rated on from a color brings the light up in: told at once",
    { places(channels()), lastTold() },
    { { RGBCT, 0, 1, false, false }, { 0.3, CCT_MODE } }
  )
  run(2000)
  mark()
  level(50, 4000)
  run(2000)
  proxy("SET_COLOR_STOP")
  T.eq(
    "a second level tells no color, and a color stop in it has nothing to hold",
    { colorsTold(), #colors() },
    { {}, 0 }
  )
  -- A fade to off holds color and white; a level back up continues from there.
  light({ RGBCT, CT })
  setColor(BLUE)
  kelvin(3000, 10000)
  run(1000)
  level(0, 3000)
  run(1000)
  level(50, 2000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a fade to off and back on in a fade to a white: from the color it was held at",
    held(),
    places({ (1 - eased(0.1)) * 0.5, 1 - (1 - eased(0.1)) * 0.5 })
  )
  -- From 1 % a fade to off reads 0 half way, where its target white is told.
  light({ RGBCT, CT })
  level(1, 0)
  setColor(BLUE)
  kelvin(3000, 10000)
  run(1000)
  level(0, 3000)
  run(1650)
  level(50, 2000)
  run(500)
  mark()
  colorTarget(ON, 4000)
  T.eq("a white told as a fade reaches off: the light is in it from then, none of the color lit", {
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE"),
  }, { { 0.3 }, { CCT_MODE } })
  -- A fade at either end of its time.
  light({ RGBCT, CT })
  setColor(BLUE)
  kelvin(3000, 6000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a fade to a white stopped as it begins: the color, in full, and told as the color",
    { channels(), modesTold() },
    { { RGBCT, 1, 0, false, false }, { FULL_MODE } }
  )
  light({ RGBCT, CT })
  setColor(BLUE)
  kelvin(3000, 6000)
  now = now + 6001
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a stop as the fade's time runs out: the white alone",
    { channels(), kelvins(), modesTold() },
    { { RGBCT, 0, 1, false, false }, { 3000 }, { CCT_MODE } }
  )
  run(100)
  -- A scene step's fade is the light's too.
  light({ RGBCT, CT })
  setColor(BLUE)
  activate(
    "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>0.3</colorX><colorY>0.4</colorY>"
      .. "<colorMode>1</colorMode><colorRate>6000</colorRate></element>"
  )
  run(3000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq("a scene step from a color to a white, stopped half way: half of each", held(), { 0.5, 0.5 })
  proxy("CLEAR_ALL_SCENES")
  -- Another client's command restarts the fade over a time no report gives.
  light({ RGBCT, CT })
  setColor(BLUE)
  kelvin(3000, 4000)
  run(2000)
  state = taken()
  state.color_brightness, state.white = 1, 0.5
  pushed({ RGBCT, CT }, state)
  kelvin(3000, 4000)
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a fade after another client ended one: from what the light then reported", held(), { 0.5, 0.75 })

  -- A cold/warm white light works out both for a white, and reports them.
  light()
  pushed({ RGBWW }, { state = true, brightness = 1.0 }, RANGE)
  setColor(BLUE)
  kelvin(4000, 6000)
  run(50)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a light with cold and warm white, stopped ahead of its report of the two: as it last had them",
    places(channels()),
    places({ RGBWW, 1 - eased(50 / 6000), false, 0, 0 })
  )
  light()
  pushed({ RGBWW }, { state = true, brightness = 1.0 }, RANGE)
  setColor(BLUE)
  kelvin(4000, 6000)
  run(100)
  state = taken()
  state.cold_white, state.warm_white = 1, 0.8
  pushed({ RGBWW }, state, RANGE)
  run(2900)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "once it has reported them: half of each of the two, with half the color",
    { channels(), kelvins() },
    { { RGBWW, 0.5, false, 0.5, 0.4 }, { 4000 } }
  )
  T.eq("told as the color, which is level with the larger of the two", lastTold(), { BLUE[1], FULL_MODE })
  pushed({ RGBWW }, taken(), RANGE)
  T.eq("and its report of that tells nothing more", #colorsTold(), 1)

  -- A color-to-color or white-to-white fade is the light's own too.
  light({ RGBCT, CT })
  kelvin(3000, 0)
  kelvin(5000, 6000)
  run(3000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a fade between two whites: the white, at the color temperature half way between them in mireds",
    { channels(), kelvins(), lastTold() },
    { { RGBCT, 0, 1, false, false }, { 3750 }, { 0.375, CCT_MODE } }
  )
  T.eq("held at once, with no change of mode to come back from", lengths(), { 0 })
  for name, modes in pairs({
    ["a color temperature beside its color"] = { RGBCT, CT },
    ["a white beside its color"] = { RGBW },
  }) do
    light(modes)
    blue = setColor(BLUE)
    activate(colorStep(nil, ON, 4000))
    run(2000)
    mark()
    proxy("SET_COLOR_STOP")
    mixed, full = scaled((on[1] + blue[1]) / 2, (on[2] + blue[2]) / 2, (on[3] + blue[3]) / 2)
    T.eq(
      "a scene step's fade between two colors, a light with " .. name .. ": the mix, and the white off",
      { places(colors()[1]), places(channels()) },
      { places(mixed), places({ modes[1], full, 0, false, false }) }
    )
    proxy("CLEAR_ALL_SCENES")
  end

  -- A mode change fades through off with nothing of both to hold: before half
  -- way the light is in the mode it left, after it in the other.
  light({ RGBCT, CT })
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 300 }, RANGE)
  colorTarget(BLUE, 3000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a color fade begun in the white-only mode, a third of the way: that white, in that mode",
    { lastCommand().has_rgb or false, channels(), kelvins(), lastTold() },
    { false, { CT, false, false, false, false }, { 3333 }, { 0.3333, CCT_MODE } }
  )
  T.eq("eased back up to its level from the dip through off, over half a second", lengths(), { 500 })
  light({ RGBCT, CT })
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 300 }, RANGE)
  colorTarget(BLUE, 3000)
  blue = colors()[1]
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "two thirds of the way: the color, in the combined mode",
    { colors(), channels(), lastTold() },
    { { blue }, { RGBCT, 1, 0, false, false }, { BLUE[1], FULL_MODE } }
  )
  light({ RGBCT, CT })
  pushed({ RGBCT, CT }, { state = true, brightness = 1.0, color_mode = CT, color_temperature = 300 }, RANGE)
  kelvin(3000, 3000)
  run(1500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a fade between two whites in the white-only mode: a color temperature alone",
    { lastCommand().has_rgb or false, channels() },
    { false, { false, false, false, false, false } }
  )
  for name, modes in pairs({
    ["a color mode and a white mode"] = { RGB, CT },
    ["no color temperature in its combined mode"] = { RGBW, CT },
  }) do
    light(modes)
    setColor(BLUE)
    kelvin(3000, 6000)
    run(3000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "a light with " .. name .. ", from a color to a white, half way: the white",
      { lastCommand().has_rgb or false, channels(), kelvins(), modesTold() },
      { false, { false, false, false, false, false }, { 3000 }, { CCT_MODE } }
    )
  end
end

---------------------------------------------------------------------------
-- Max and Min On Level
---------------------------------------------------------------------------

local pb = require("protobuf")

--- Set the light's Max and Min On Level, as Composer sends them.
local function onLevels(max, min)
  proxy("SET_MAX_ON_LEVEL", { LEVEL = tostring(max) })
  proxy("SET_MIN_ON_LEVEL", { LEVEL = tostring(min) })
end

--- Reset the range, and the on level and hold rate these cases set.
local function forgetOnLevels()
  for _, key in ipairs({
    "max_on_level",
    "min_on_level",
    "brightness_on_mode",
    "brightness_on_mode_preset",
    "hold_rate_down",
  }) do
    persist:delete(key)
  end
end

--- `value` to nine places, as far as a serialized brightness keeps it.
local function nine(value)
  return math.floor(value * 1e9 + 0.5) / 1e9
end

--- Device brightness for a level with Max On Level 80 and Min On Level 20.
local function at80(level)
  return nine((20 + (level - 1) * 60 / 99) / 100)
end

--- The brightness of the last command sent since the mark: nil for none.
local function brightnessSent()
  local last = lastLevel()
  return last and nine(last[1])
end

--- A brightness as the float ESPHome sends it.
local function float(brightness)
  return (pb.decode_float(pb.encode_float(brightness), 1))
end

--- A dimmer's report of its brightness; off for 0.
local function reportAt(brightness)
  pushed({ ColorMode.COLOR_MODE_BRIGHTNESS }, { state = brightness > 0, brightness = float(brightness) })
end

local function levelsTold()
  return told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
end

T.section("Max and Min On Level remap every level the light is sent and reads back, as on a Control4 dimmer")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  for _, level in ipairs({ 100, 1, 37 }) do
    mark()
    proxy("SET_LEVEL", { LEVEL = level })
    T.eq(level .. " goes out at the light's " .. at80(level), brightnessSent(), at80(level))
    reportAt(at80(level))
    T.eq(level .. " is shown as sent, and the light's report of it tells nothing more", levelsTold(), { level })
  end
  mark()
  reportAt(0.5)
  T.eq("a brightness set elsewhere is read through the range", levelsTold(), { 51 })
  mark()
  proxy("SET_LEVEL", { LEVEL = 0 })
  T.eq("0 is off", { lastCommand().state, levelsTold() }, { false, { 0 } })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  T.eq("a ramp: to the Max On Level, over its rate", lastLevel(), { 0.8, 2000 })
  run(100)
  reportAt(0.8)
  run(15000)
  T.eq(
    "the light's report of it is its own: shown at 100 at the ramp's end alone",
    { levelsTold(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 100 }, { 2000 } }
  )
  proxy("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 1, BRIGHTNESS_PRESET_LEVEL = 50 })
  proxy("OFF")
  mark()
  proxy("ON")
  T.eq("an on goes to its on level on the range", brightnessSent(), at80(50))
  mark()
  activate(levelStep(37))
  T.eq("a scene step's level too", brightnessSent(), at80(37))
  proxy("CLEAR_ALL_SCENES")
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  T.eq("a held Top ramps to the Max On Level", brightnessSent(), 0.8)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_HOLD })

  light({ ColorMode.COLOR_MODE_RGB })
  onMode(ON, DIM)
  onLevels(80, 20)
  mark()
  proxy("SET_LEVEL", { LEVEL = 50 })
  T.eq(
    "Dim-To-Warm: the level goes out on the range, in the mix for the level",
    { brightnessSent(), told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X") },
    { at80(50), { mix(50) } }
  )
  forgetOnLevels()

  -- The Max reports as a float just over 0.8, which is not outside the range.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  proxy("SET_LEVEL", { LEVEL = 100 })
  reportAt(0.8)
  mark()
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("a Set Level to 100 once the light reports the Max On Level sends nothing", commands(), 0)
  forgetOnLevels()

  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(100, 0)
  mark()
  proxy("SET_LEVEL", { LEVEL = 1 })
  T.eq("a Min On Level of 0: level 1 goes out lit, at 0.01", { lastCommand().state, brightnessSent() }, { true, 0.01 })
  forgetOnLevels()
end

T.section("a stop part way through a fade to or from off holds the light where it has got to, or at the Min On Level")
do
  -- ESPHome fades brightness itself: 0.8 to off is 0.4 half way, level 34.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  proxy("SET_HOLD_RATE_DOWN", { RATE = 4000 })
  proxy("SET_LEVEL", { LEVEL = 100 })
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(2000)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE_HOLD })
  T.eq("a held Bottom let go half way down", { brightnessSent(), levelsTold() }, { 0.4, { 34 } })
  proxy("OFF")
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(2000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a fade up from off stopped half way", { brightnessSent(), levelsTold() }, { 0.4, { 34 } })
  -- Under the Min On Level it stops at the Min, or off under half way there.
  proxy("SET_LEVEL", { LEVEL = 100 })
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(2730)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE_HOLD })
  T.eq("a held Bottom let go at 0.15 goes to the Min On Level", { brightnessSent(), levelsTold() }, { 0.2, { 1 } })
  proxy("SET_LEVEL", { LEVEL = 100 })
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(3200)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE_HOLD })
  T.eq("let go at 0.05, it goes off", { lastCommand().state, levelsTold() }, { false, { 0 } })
  forgetOnLevels()
end

T.section("a toggle reads a light fading to or from off as on until it is half a level from off")
do
  -- Under 0.1 (half way to a Min of 20) a stop reads off, but a toggle still
  -- reads it as on and turns it off.
  local function fading()
    light({ ColorMode.COLOR_MODE_BRIGHTNESS })
    onLevels(80, 20)
    proxy("SET_LEVEL", { LEVEL = 100 })
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
    run(3000)
    mark()
  end
  fading()
  proxy("TOGGLE")
  T.eq(
    "the proxy's Toggle with the light at 0.083 on its way off",
    { lastCommand().state, levelsTold() },
    { false, { 0 } }
  )
  fading()
  RFP.DO_CLICK(TOGGLE_LINK, "DO_CLICK", {})
  T.eq("a Toggle Button Link's click with no push", { lastCommand().state, levelsTold() }, { false, { 0 } })

  local function click()
    proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS })
    run(110)
    proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = RELEASE_CLICK })
  end
  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  onLevels(80, 20)
  click()
  run(60)
  mark()
  click()
  run(15000)
  local levels = levelsTold()
  T.eq(
    "a Toggle clicked again with the light at 0.015 on its way on",
    { lastCommand().state, levels[#levels] },
    { false, 0 }
  )
  forgetOnLevels()
end

T.section("a new Max or Min On Level shows the light where it is on the new range, and does not move it")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 50 })
  reportAt(0.5)
  mark()
  onLevels(80, 20)
  local levels = levelsTold()
  T.eq("the light at 0.5 shows at 51", levels[#levels], 51)
  T.eq("and is sent nothing", commands(), 0)
  local echoes = {}
  for _, s in ipairs(sent) do
    if s.command == "MAX_ON" or s.command == "MIN_ON" then
      echoes[#echoes + 1] = s.command .. " " .. s.params
    end
  end
  T.eq("the proxy is told the two, as before", echoes, { "MAX_ON 80", "MIN_ON 20" })
  mark()
  proxy("SET_LEVEL", { LEVEL = 51 })
  T.eq("a Set Level to the level shown leaves it there", { commands(), levelsTold() }, { 0, { 51 } })
  forgetOnLevels()

  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 50 })
  reportAt(0.5)
  mark()
  proxy("SET_LEVEL", { LEVEL = 80 })
  onLevels(80, 20)
  T.eq("set before the light reports a level, it reads the brightness sent: 0.8, 100", levelsTold(), { 80, 100 })
  forgetOnLevels()

  -- Outside a new range a light reads as the end, and goes there when asked.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  mark()
  onLevels(80, 20)
  T.eq("a light at full: still shown at 100, and not moved", { levelsTold(), commands() }, { {}, 0 })
  mark()
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("a Set Level to 100 takes it down to the Max On Level", { brightnessSent(), levelsTold() }, { 0.8, { 100 } })
  reportAt(0.1)
  mark()
  proxy("SET_LEVEL", { LEVEL = 1 })
  T.eq("one set elsewhere below the Min On Level: a Set Level to 1 takes it up to it", brightnessSent(), 0.2)
  forgetOnLevels()

  -- A ramp in flight ends at its target on the new range: 0.6 is level 67.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  run(1000)
  mark()
  onLevels(80, 20)
  run(15000)
  T.eq("a ramp in flight: nothing more is sent", commands(), 0)
  T.eq("and at its end it is shown on the new range", { levelsTold(), told("LIGHT_BRIGHTNESS_CHANGED", "at") }, {
    { 67 },
    { 3000 },
  })
  forgetOnLevels()

  -- Composer sends Max and Min one at a time; each re-reads the ramp's target.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 8000 })
  run(1000)
  mark()
  onLevels(50, 10)
  run(15000)
  T.eq("a ramp to 0.2 as the range becomes 10 to 50 ends at 26 there", levelsTold(), { 26 })
  forgetOnLevels()

  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 8000 })
  run(1000)
  mark()
  onLevels(40, 60)
  onLevels(100, 50)
  run(15000)
  T.eq("and through a range with no width to 50 to 100, below its Min, at 1", levelsTold(), { 1 })
  forgetOnLevels()

  -- A stop after a range change is where the light is: half way, 0.5.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  onLevels(80, 20)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop half way after the range moved the ramp", { brightnessSent(), levelsTold() }, { at80(51), { 51 } })
  forgetOnLevels()

  light({ ColorMode.COLOR_MODE_BRIGHTNESS }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  onLevels(80, 20)
  now = now + 3001
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a stop past its time, before its end is told, holds it at full", { brightnessSent(), levelsTold() }, {
    1,
    { 100 },
  })
  forgetOnLevels()

  -- A color set after the range moved the target goes on to that target.
  light({ ColorMode.COLOR_MODE_RGB }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  onLevels(80, 20)
  run(1000)
  colorTarget(BLUE, 2000)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("and a stop half way through the color: at 0.75, 92", levelsTold(), { 92 })
  forgetOnLevels()
  light({ ColorMode.COLOR_MODE_RGB }, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  onLevels(80, 20)
  run(1000)
  colorTarget(BLUE, 2000)
  mark()
  onLevels(100, 1)
  run(15000)
  T.eq("or the range set back after the color: it ends at full, 100", levelsTold(), { 100 })
  forgetOnLevels()

  -- One from a light outside the range starts where the light was.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  run(1000)
  onLevels(100, 1)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a fade from full stopped half way after the range is set back", brightnessSent(), 0.5)
  forgetOnLevels()

  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  proxy("SET_LEVEL", { LEVEL = 50 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  run(1000)
  onLevels(80, 20)
  mark()
  proxy("GET_LIGHT_LEVEL")
  T.eq("the level the proxy asks for in a ramp: from where it has got to, 53, to 67 on the new range", {
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    told("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET"),
    told("LIGHT_BRIGHTNESS_CHANGING", "RATE"),
  }, { { 53 }, { 67 }, { 3000 } })
  forgetOnLevels()
end

T.section("a light the range leaves outside it ramps from where it is, and a stop holds it there")
do
  -- At full under a new Max of 80, ESPHome fades from 1.0, not 0.8.
  local function quarterDown()
    return nine(1 - eased(0.25))
  end
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  proxy("SET_HOLD_RATE_DOWN", { RATE = 4000 })
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(1000)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE_HOLD })
  T.eq("a held Bottom let go a quarter of the way", { brightnessSent(), levelsTold() }, { quarterDown(), { 100 } })
  mark()
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("shown at 100, a Set Level to 100 then takes it to the Max On Level", brightnessSent(), 0.8)
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE_HOLD })
  T.eq("one let go as it begins holds it at full", brightnessSent(), 1)

  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  T.eq("a ramp to the 100 it shows goes to the Max On Level over its rate", lastLevel(), { 0.8, 2000 })
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("and a stop half way holds it at 0.9", { brightnessSent(), levelsTold() }, { 0.9, { 100 } })

  -- One another client set below the Min On Level ramps up from there.
  reportAt(0.05)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  run(500)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a ramp up from 0.05 stopped an eighth of the way holds it there, at 1",
    { brightnessSent(), levelsTold() },
    { nine(float(0.05) + (at80(50) - float(0.05)) * eased(0.125)), { 1 } }
  )

  -- A click starts where its press found the light.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(110)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE_CLICK })
  run(250)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a Bottom click from full stopped half way, at 0.5, holds it at 51", levelsTold(), { 51 })

  -- A scene step to the 100 it shows ramps it there too.
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(80, 20)
  activate(levelStep(100, 2000))
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a scene step to 100 stopped half way holds it at 0.9", brightnessSent(), 0.9)
  proxy("CLEAR_ALL_SCENES")

  -- A color set mid-ramp restarts the level from where it is to its target.
  light({ ColorMode.COLOR_MODE_RGB })
  onLevels(80, 20)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  run(1000)
  colorTarget(BLUE, 2000)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("a ramp from full re-timed by a color, stopped at 0.722", { brightnessSent(), levelsTold() }, {
    at80(87),
    { 87 },
  })
  local b = 1 - 0.2 * eased(0.25)
  light({ ColorMode.COLOR_MODE_RGB })
  onLevels(80, 20)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  colorTarget(BLUE, 2000)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq("one to the 100 it shows, still on its way there", brightnessSent(), nine(b + (0.8 - b) * eased(0.5)))
  forgetOnLevels()
end

T.section("a Min On Level at or above the Max On Level puts every on level at the one brightness")
do
  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(40, 60)
  for _, level in ipairs({ 37, 80 }) do
    mark()
    proxy("SET_LEVEL", { LEVEL = level })
    reportAt(0.6)
    T.eq(level .. " goes out at 0.6, and is shown as sent", { brightnessSent(), levelsTold() }, { 0.6, { level } })
  end
  mark()
  proxy("SET_MAX_ON_LEVEL", { LEVEL = "30" })
  T.eq("a new range that still has no width tells nothing", levelsTold(), {})
  proxy("SET_LEVEL", { LEVEL = 0 })
  reportAt(0)
  mark()
  reportAt(0.3)
  T.eq("a light turned on elsewhere is told", levelsTold(), { 100 })
  forgetOnLevels()

  light({ ColorMode.COLOR_MODE_BRIGHTNESS })
  onLevels(40, 60)
  mark()
  proxy("SET_LEVEL", { LEVEL = 100 })
  T.eq("a light it leaves at full: a Set Level to the 100 it shows takes it there", brightnessSent(), 0.6)
  forgetOnLevels()
end

---------------------------------------------------------------------------
-- A light's color modes after a restart, and a change between them
---------------------------------------------------------------------------

T.section("a light's first on after a restart with no color mode saved is not another client's")
do
  local UNKNOWN = ColorMode.COLOR_MODE_UNKNOWN
  --- A light restored off with nothing saved: no color mode (`mode` as
  --- reported), default fields, and the coldest color temperature.
  local function restored(modes, mode)
    light()
    pushed(modes, {
      state = false,
      brightness = 1.0,
      color_mode = mode,
      color_brightness = 1,
      red = 1,
      green = 1,
      blue = 1,
      white = 1,
      color_temperature = RANGE[1],
      cold_white = 1,
      warm_white = 1,
    }, RANGE)
    mark()
  end
  --- Its report on at `brightness` in `mode`, every other field as it was.
  local function onIn(modes, mode, brightness)
    pushed(modes, {
      state = true,
      brightness = brightness,
      color_mode = mode,
      color_brightness = 1,
      red = 1,
      green = 1,
      blue = 1,
      white = 1,
      color_temperature = RANGE[1],
      cold_white = 1,
      warm_white = 1,
    }, RANGE)
  end
  -- ESPHome gives it the first of its modes at a turn-on that names none.
  for name, kind in pairs({
    ["a color temperature beside its color and a white-only mode"] = { { RGBCT, CT }, CT, RGBCT },
    ["a color mode and a white mode"] = { { RGB, CWWW }, CWWW, RGB },
  }) do
    for _, given in ipairs({ { "unknown", UNKNOWN }, { "left out, as on the wire", nil } }) do
      local modes, first, other = kind[1], kind[2], kind[3]
      local which = "a light with " .. name .. ", its mode " .. given[1]
      restored(modes, given[2])
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
      run(100)
      onIn(modes, first, 1.0)
      run(5000)
      T.eq(
        which .. ": its report of a rated on in its first mode is the on's own, told at the on's end",
        told("LIGHT_BRIGHTNESS_CHANGED", "at"),
        { 4000 }
      )
      restored(modes, given[2])
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
      onIn(modes, first, 0.0039)
      run(100)
      onIn(modes, first, 1.0)
      run(5000)
      T.eq(which .. ": and so is its report of the pre-on by itself", told("LIGHT_BRIGHTNESS_CHANGED", "at"), { 4000 })
      restored(modes, given[2])
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
      run(100)
      onIn(modes, other, 1.0)
      T.eq(
        which .. ": one in another mode is another client's, told at once",
        told("LIGHT_BRIGHTNESS_CHANGED", "at"),
        { 100 }
      )
      restored(modes, given[2])
      proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
      run(100)
      onIn(modes, first, 0.5)
      T.eq(
        which .. ": as is a level set elsewhere",
        told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
        { 50 }
      )
    end
  end
end

T.section(
  "a fade between a color and a white on a light with separate modes, stopped part way, holds the mode it is in"
)
do
  -- Red, x 0 through the stubs.
  local RED = { 0, 1 }
  local FIELDS = {
    "brightness",
    "color_mode",
    "color_brightness",
    "red",
    "green",
    "blue",
    "white",
    "color_temperature",
    "cold_white",
    "warm_white",
  }
  --- What the light has, as ESPHome keeps it: each field as it was last sent.
  local state
  --- A light with a color mode and a white mode, on at full in red.
  --- @param range table|nil Its color temperature range; RANGE if nil.
  local function inRed(modes, range)
    light()
    state = {
      state = true,
      brightness = 1.0,
      color_mode = RGB,
      color_brightness = 1,
      red = 1,
      green = 0,
      blue = 0,
      white = 1,
      color_temperature = RANGE[1],
      cold_white = 1,
      warm_white = 1,
    }
    pushed(modes, state, range or RANGE)
  end
  --- The light's report of its last command; `mode` if the command names none.
  local function reported(modes, mode)
    local cmd = lastCommand()
    for _, field in ipairs(FIELDS) do
      state[field] = cmd[field] or state[field]
    end
    state.color_mode = cmd.color_mode or mode
    pushed(modes, state, RANGE)
  end
  --- The last color told since the mark: its x and its color mode.
  local function lastTold()
    local xs, modes = colorsTold(), modesTold()
    return { math.floor(xs[#xs] * 1e6 + 0.5) / 1e6, modes[#modes] }
  end
  local function level(target, rate)
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
  end

  -- ESPHome fades the color it leaves to off over the first half of the time,
  -- and the white it was sent up from off over the second (transformers.h).
  for name, kind in pairs({
    ["a color mode and a white mode with a color temperature"] = { RGB, CT },
    ["a color mode and a cold and warm white mode, as the Athom bulb has"] = { RGB, CWWW },
  }) do
    local white = kind[2]
    inRed(kind)
    kelvin(4000, 4000)
    run(150)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "a light with " .. name .. ", from red to 4000 K, stopped at 150 ms: red, in its color mode",
      { lastCommand().color_mode, colors(), kelvins(), lastTold() },
      { RGB, { { 1, 0, 0 } }, {}, { 0, FULL_MODE } }
    )
    T.eq("at the level it was", lastCommand().has_brightness or false, false)
    T.eq("eased back up to it from the dip through off over half a second", lengths(), { 500 })
    reported(kind)
    T.eq("and the light's report of the stop tells nothing more", #colorsTold(), 1)
    run(1000)
    T.eq(
      "nor is anything told of the level",
      #told("LIGHT_BRIGHTNESS_CHANGING", "at") + #told("LIGHT_BRIGHTNESS_CHANGED", "at"),
      0
    )
    inRed(kind)
    kelvin(4000, 4000)
    run(3000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "three quarters of the way: the white, at 4000 K",
      { colors(), kelvins(), lastTold() },
      { {}, { 4000 }, { 0.4, CCT_MODE } }
    )
    T.eq("over half a second too", lengths(), { 500 })
    reported(kind, white)
    T.eq("and the light's report of that tells nothing more", #colorsTold(), 1)
    inRed(kind)
    kelvin(4000, 4000)
    run(2000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq("from half way: the white", { colors(), kelvins(), lastTold() }, { {}, { 4000 }, { 0.4, CCT_MODE } })

    -- From a white to a color the white is left first.
    inRed(kind)
    kelvin(3000, 0)
    reported(kind, white)
    colorTarget(RED, 4000)
    run(1000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "from 3000 K to red, a quarter of the way: 3000 K, in its white mode, the light working out its whites",
      { channels(), kelvins(), colors(), lastTold() },
      { { white, false, false, false, false }, { 3000 }, {}, { 0.3, CCT_MODE } }
    )
    T.eq("eased back up over half a second", lengths(), { 500 })
    -- A lone color temperature moves ESPHome to its first CCT-capable mode.
    inRed(kind)
    kelvin(3000, 0)
    colorTarget(RED, 4000)
    run(1000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "the same before the light reports 3000 K: 3000 K, in its white mode",
      { channels()[1], kelvins(), colors(), lastTold() },
      { white, { 3000 }, {}, { 0.3, CCT_MODE } }
    )
    inRed(kind)
    kelvin(3000, 0)
    reported(kind, white)
    colorTarget(RED, 4000)
    run(3000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "three quarters of the way: red, in its color mode",
      { lastCommand().color_mode, colors(), kelvins(), lastTold() },
      { RGB, { { 1, 0, 0 } }, {}, { 0, FULL_MODE } }
    )
  end

  -- A command mid-fade restarts the mode change from the mode the light is in.
  inRed({ RGB, CWWW })
  kelvin(4000, 4000)
  run(1000)
  mark()
  level(50, 2000)
  T.eq("a level sent a quarter of the way: the fade is told again from red, which the light is still in", {
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
    told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE"),
  }, { { 0 }, { FULL_MODE } })
  run(500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "and a stop a quarter through that: red, over the time the level has left",
    { lastCommand().color_mode, colors(), lengths(), lastTold() },
    { RGB, { { 1, 0, 0 } }, { 1500 }, { 0, FULL_MODE } }
  )
  inRed({ RGB, CWWW })
  kelvin(4000, 4000)
  run(1000)
  level(50, 2000)
  run(1500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a stop three quarters through that: the white, the light having changed mode over the level's time",
    { colors(), kelvins(), lastTold() },
    { {}, { 4000 }, { 0.4, CCT_MODE } }
  )
  inRed({ RGB, CWWW })
  kelvin(4000, 4000)
  run(1000)
  level(50, 1200)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  run(1000)
  T.eq(
    "a stop with less than half a second of the level left: over half a second, the level told at its end",
    { kelvins(), lengths(), told("LIGHT_BRIGHTNESS_CHANGED", "at") },
    { { 4000 }, { 500 }, { 500 } }
  )
  inRed({ RGB, CWWW })
  kelvin(4000, 4000)
  run(3000)
  level(50, 2000)
  run(500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "one sent three quarters of the way: the light is in the white from then",
    { colors(), kelvins(), lastTold() },
    { {}, { 4000 }, { 0.4, CCT_MODE } }
  )
  -- A fade within the one mode has no dip to come back from.
  inRed({ RGB, CT })
  colorTarget(BLUE, 4000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a fade from red to another color, stopped a quarter of the way: held at once, as before",
    { lastCommand().color_mode, lengths() },
    { RGB, { 0 } }
  )
  -- A level carrying a Dim-To-Warm white takes the light out of color mode too.
  for _, case in ipairs({ { 1000, "a quarter", 0, FULL_MODE }, { 3000, "three quarters", 0.45, CCT_MODE } }) do
    inRed({ RGB, CWWW })
    fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
    level(50, 4000)
    run(case[1])
    mark()
    colorTarget(BLUE, 2000)
    T.eq(
      "a color sent "
        .. case[2]
        .. " into a level carrying a Dim-To-Warm white from red: told from the one the light is in",
      {
        told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"),
        told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_COLOR_MODE"),
      },
      { { case[3] }, { case[4] } }
    )
    run(5000)
  end
  -- A level stop mid mode change is held as a color stop is.
  for name, kind in pairs({
    ["a color temperature white mode"] = { RGB, CT },
    ["a cold and warm white mode"] = { RGB, CWWW },
  }) do
    inRed(kind)
    fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
    level(50, 4000)
    run(1000)
    mark()
    proxy("SET_BRIGHTNESS_STOP")
    T.eq(
      "a light with a color mode and "
        .. name
        .. ", a level carrying a Dim-To-Warm white from red stopped a quarter of the way: red, at the level stopped at",
      {
        lastCommand().color_mode,
        colors(),
        kelvins(),
        lastCommand().has_brightness,
        brightnessSent(),
        lastTold(),
        levelsTold(),
      },
      { RGB, { { 1, 0, 0 } }, {}, true, 0.95, { 0, FULL_MODE }, { 95 } }
    )
    T.eq("eased back up to it from the dip over half a second, in the one command", lengths(), { 500 })
    reported(kind)
    T.eq("and the light's report of the stop tells nothing more", { #colorsTold(), #levelsTold() }, { 1, 1 })
    inRed(kind)
    fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
    level(50, 4000)
    run(3000)
    mark()
    proxy("SET_BRIGHTNESS_STOP")
    T.eq(
      "three quarters of the way: the level's white, which the light is in, at the level stopped at, over half a second",
      { colors(), kelvins(), brightnessSent(), lengths(), lastTold(), levelsTold() },
      { {}, { 4500 }, 0.55, { 500 }, { 0.45, CCT_MODE }, { 55 } }
    )
    reported(kind, kind[2])
    T.eq("and the light's report of that tells nothing more", { #colorsTold(), #levelsTold() }, { 1, 1 })
  end
  -- Above its Max On Level it is held where it has got to on the line.
  inRed({ RGB, CT })
  onLevels(80, 20)
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  level(50, 4000)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "with a Max On Level of 80, from red at full, a quarter of the way: red, where it has got to above the Max",
    { lastCommand().color_mode, brightnessSent(), lengths() },
    { RGB, nine(1 + (at80(50) - 1) * eased(0.25)), { 500 } }
  )
  forgetOnLevels()
  -- A keypad hold let go and a scene's ramp stopped are level stops too.
  inRed({ RGB, CWWW })
  state.brightness = 0.3
  pushed({ RGB, CWWW }, state, RANGE)
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(1000)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_HOLD })
  T.eq(
    "Top held from 30 % in red with Dim-To-Warm, let go a third of the way up: red, at 45 %, over half a second",
    { lastCommand().color_mode, colors(), brightnessSent(), lengths(), lastTold() },
    { RGB, { { 1, 0, 0 } }, 0.45, { 500 }, { 0, FULL_MODE } }
  )
  inRed({ RGB, CWWW })
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  level(50, 4000)
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "a scene's ramp stopped a quarter of the way: red, over half a second",
    { lastCommand().color_mode, colors(), lengths() },
    { RGB, { { 1, 0, 0 } }, { 500 } }
  )
  inRed({ RGB, CWWW })
  state.state = false
  pushed({ RGB, CWWW }, state, RANGE)
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  level(50, 4000)
  run(3000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a ramp up from off in red, stopped three quarters of the way: the light is held on, at 45 %",
    { lastCommand().state, brightnessSent(), levelsTold() },
    { true, 0.45, { 45 } }
  )
  inRed({ RGB, CWWW })
  state.state = false
  pushed({ RGB, CWWW }, state, RANGE)
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  level(50, 4000)
  run(100)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "and one stopped before it is lit: off, at once, as before",
    { lastCommand().state, lengths(), levelsTold() },
    { false, { 0 }, { 0 } }
  )
  -- A fade sent mid-change, in the light's current mode, starts from the dip;
  -- a stop brings it back up from there too.
  local FOUR_K = "<colorEnabled>true</colorEnabled><colorX>0.4</colorX><colorY>0.4</colorY><colorMode>1</colorMode>"
  inRed({ RGB, CWWW })
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  level(50, 4000)
  run(2500)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  run(1000)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_HOLD })
  T.eq(
    "Top held past half way through a level carrying a Dim-To-Warm white from red, let go a second later: the white, over half a second",
    { lastCommand().color_mode, colors(), brightnessSent(), lengths() },
    { CWWW, {}, fadeLevel(fadeLevel(100, 50, 2500 / 4000), 100, 1000 / 3000) / 100, { 500 } }
  )
  for name, color in pairs({ ["a level, with Dim-To-Warm,"] = "", ["a level and 4000 K"] = FOUR_K }) do
    inRed({ RGB, CWWW })
    if color == "" then
      fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
    end
    activate(
      "<element><delay>0</delay><rate>4000</rate><brightnessEnabled>true</brightnessEnabled>"
        .. "<brightness>50</brightness>"
        .. color
        .. "</element>"
    )
    run(3000)
    mark()
    proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
    T.eq(
      "a scene step of "
        .. name
        .. " from red, stopped three quarters of the way: the level over the step's time left, then the white over half a second",
      { lengths(), lastCommand().color_mode },
      { { 1000, 500 }, CWWW }
    )
    proxy("CLEAR_ALL_SCENES")
  end
  inRed({ RGB, CWWW })
  activate(
    "<element><delay>0</delay><rate>4000</rate><brightnessEnabled>true</brightnessEnabled>"
      .. "<brightness>50</brightness>"
      .. FOUR_K
      .. "</element>"
  )
  run(3000)
  proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 4000 })
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "Ramp Scene Up past half way through that step, stopped a second later: the white, over half a second",
    { lengths(), lastCommand().color_mode },
    { { 3000, 500 }, CWWW }
  )
  proxy("CLEAR_ALL_SCENES")
  -- Before half way it is in the mode it left; a fade back starts at the dip.
  inRed({ RGB, CWWW })
  kelvin(4000, 0)
  reported({ RGB, CWWW }, CWWW)
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  colorTarget(RED, 4000)
  run(1000)
  level(50, 4000)
  run(500)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "from 4000 K to red, a level carrying a Dim-To-Warm white sent a quarter of the way, stopped half a second later: in the white, over half a second",
    { lastCommand().color_mode, colors(), lengths() },
    { CWWW, {}, { 500 } }
  )
  inRed({ RGB, CWWW })
  kelvin(4000, 0)
  reported({ RGB, CWWW }, CWWW)
  colorTarget(RED, 4000)
  run(1000)
  kelvin(4000, 4000)
  run(500)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "and 4000 K sent back a quarter of the way, stopped half a second later: 4000 K, over half a second",
    { lastCommand().color_mode, kelvins(), lengths() },
    { CWWW, { 4000 }, { 500 } }
  )
  -- A fade to off keeps the mode the light is in, and it is held in that.
  inRed({ RGB, CWWW })
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  level(50, 4000)
  run(1000)
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = PRESS })
  run(1000)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = BOTTOM, ACTION = RELEASE_HOLD })
  T.eq(
    "Bottom held a quarter of the way through a level carrying a Dim-To-Warm white from red, let go a second later: red, over half a second",
    { lastCommand().color_mode, colors(), brightnessSent(), lengths(), lastTold() },
    {
      RGB,
      { { 1, 0, 0 } },
      fadeLevel(fadeLevel(100, 50, 1000 / 4000), 0, 1000 / 3000) / 100,
      { 500 },
      { 0, FULL_MODE },
    }
  )
  -- Once such a fade has run, the light is back up: the next has no dip.
  inRed({ RGB, CWWW })
  kelvin(4000, 4000)
  run(3000)
  level(50, 500)
  run(1500)
  kelvin(3000, 4000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a fade from 4000 K to 3000 K after it, stopped part way: at once", lengths(), { 0 })
  -- A level's stop within one mode has no dip to come back from.
  inRed({ RGB, CWWW })
  fadeMode({ 0.5, 0.4 }, { 0.4, 0.4 }, CCT_MODE)
  kelvin(4000, 0)
  level(50, 4000)
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a level carrying a Dim-To-Warm white from a white, stopped a quarter of the way: the stopped level's white, at once, as before",
    { kelvins(), brightnessSent(), lengths() },
    { { 4950 }, 0.95, { 0 } }
  )
  -- A color sent since is not the level's to hold; it goes on through it.
  inRed({ RGB, CWWW })
  kelvin(4000, 4000)
  run(1000)
  level(50, 2000)
  run(500)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "a level stopped part way through a color's fade from red to 4000 K: the level alone, over the time the color has left, as before",
    { lastCommand().has_color_mode or false, colors(), kelvins(), brightnessSent(), lengths(), levelsTold() },
    { false, {}, {}, 0.95, { 1500 }, { 95 } }
  )
  -- Nor one sent during a fade to off: the light goes on to it through off.
  inRed({ RGB, CWWW })
  level(0, 4000)
  run(1000)
  kelvin(4000, 2000)
  level(50, 2000)
  run(500)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  T.eq(
    "4000 K sent to a light fading to off from red, then a level stopped a quarter of the way: the level alone, over half a second",
    {
      lastCommand().has_color_mode or false,
      colors(),
      kelvins(),
      brightnessSent(),
      lengths(),
      #colorsTold(),
      levelsTold(),
    },
    { false, {}, {}, 0.86, { 500 }, 0, { 86 } }
  )
  -- A scene step's fade is the light's too.
  inRed({ RGB, CWWW })
  activate(
    "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>0.4</colorX><colorY>0.4</colorY>"
      .. "<colorMode>1</colorMode><colorRate>4000</colorRate></element>"
  )
  run(1000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "a scene step from red to 4000 K, stopped a quarter of the way: red",
    { lastCommand().color_mode, colors(), lastTold() },
    { RGB, { { 1, 0, 0 } }, { 0, FULL_MODE } }
  )
  T.eq("over half a second", lengths(), { 500 })
  proxy("CLEAR_ALL_SCENES")
  inRed({ RGB, CWWW })
  activate(
    "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>0.4</colorX><colorY>0.4</colorY>"
      .. "<colorMode>1</colorMode><colorRate>4000</colorRate></element>"
  )
  run(3000)
  level(50, 2000)
  run(500)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "one a level took on three quarters of the way, stopped: the white",
    { colors(), kelvins(), lastTold() },
    { {}, { 4000 }, { 0.4, CCT_MODE } }
  )
  proxy("CLEAR_ALL_SCENES")

  -- A plain white, as an RGBW light built with color_interlock has.
  local WHITE = ColorMode.COLOR_MODE_WHITE
  inRed({ RGB, WHITE })
  state.color_mode, state.green, state.blue = WHITE, 1, 1
  pushed({ RGB, WHITE }, state)
  level(50, 4000)
  colorTarget(RED, 4000)
  run(1000)
  proxy("SET_COLOR_STOP")
  T.eq(
    "a light with a color mode and a white mode with no color temperature, from that white to red, a quarter of the way: its white",
    channels(),
    { WHITE, false, 1, false, false }
  )
  mark()
  state.brightness, state.green, state.blue = 0.5, 0, 0
  pushed({ RGB, WHITE }, state)
  run(5000)
  T.eq(
    "and the light's report of that is the stop's own: the level is told at its ramp's end",
    told("LIGHT_BRIGHTNESS_CHANGED", "at"),
    { 3000 }
  )
  -- Without a mireds range, its cold and warm white must be kept too.
  inRed({ RGB, CWWW }, {})
  state.color_mode, state.color_temperature, state.cold_white, state.warm_white = CWWW, 0, 0.25, 0.75
  pushed({ RGB, CWWW }, state)
  colorTarget(RED, 4000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a light with a color mode and a cold and warm white mode that gives no range, a quarter of the way to red: its cold and warm white",
    { channels(), kelvins(), colors() },
    { { CWWW, false, false, 0.25, 0.75 }, {}, {} }
  )
end

T.section("a ramped on that changes the color brings the light up in it from its pre-on")
do
  local RED, WARM = { 0, 1 }, { 0.3, 0.4, id = 1 }
  --- The command the light was sent first since the mark: a ramped on's pre-on.
  local function preOn()
    for _, s in ipairs(sent) do
      if s.binding == ESPHOME and s.command == "ENTITY_COMMAND" then
        return DeserializeSafe(s.params.body)
      end
    end
    return {}
  end
  --- What that pre-on sets: its brightness, color mode, color temperature in
  --- kelvin and red, green and blue, false for each it does not set.
  local function carried()
    local cmd = preOn()
    return {
      cmd.brightness,
      cmd.has_color_mode and cmd.color_mode or false,
      cmd.has_color_temperature and math.floor(1e6 / cmd.color_temperature + 0.5) or false,
      cmd.has_rgb and { cmd.red, cmd.green, cmd.blue } or false,
    }
  end
  --- A light of kind `modes` that is off, in `mode` with `fields` lit.
  local function offIn(modes, mode, fields)
    light()
    local state = {
      state = false,
      brightness = 1.0,
      color_mode = mode,
      color_brightness = 1,
      red = 1,
      green = 1,
      blue = 1,
      white = 1,
      color_temperature = RANGE[1],
      cold_white = 1,
      warm_white = 1,
    }
    for field, value in pairs(fields) do
      state[field] = value
    end
    pushed(modes, state, RANGE)
    return state
  end
  local function rampedOn()
    mark()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  end
  local inRed = { red = 1, green = 0, blue = 0 }

  -- ESPHome brings a light up from off in the color it is turned on in
  -- (transformers.h); one already on at the pre-on changes mode through off.
  local SEPARATE = { RGB, CWWW }
  offIn(SEPARATE, RGB, inRed)
  onMode(WARM)
  rampedOn()
  T.eq(
    "a light with a color mode and a white mode, off in red, a white On Color: the pre-on is in that white, in its mode",
    carried(),
    { 0.0039, CWWW, 3000, false }
  )
  T.eq("as the on is, so the light changes no mode", lastCommand().color_mode, CWWW)
  offIn(SEPARATE, RGB, inRed)
  fadeMode({ 0.5, 0.4 }, { 0.27, 0.4 }, CCT_MODE)
  rampedOn()
  T.eq("with Dim-To-Warm: its white for the level", carried(), { 0.0039, CWWW, 5000, false })
  offIn(SEPARATE, CWWW, { color_temperature = 333.3 })
  onMode({ RED[1], RED[2], id = 1 })
  rampedOn()
  T.eq(
    "off in a white, a red On Color: the pre-on is red, in the color mode",
    carried(),
    { 0.0039, RGB, false, { 1, 0, 0 } }
  )
  offIn(SEPARATE, RGB, inRed)
  rampedOn()
  T.eq("with no Color On Mode: the pre-on carries no color, as before", carried(), { 0.0039, false, false, false })

  -- What the light then shows from the start, and is told.
  offIn(SEPARATE, RGB, inRed)
  onMode(WARM)
  rampedOn()
  T.eq(
    "the proxy is told the white at once, as the On Color, and no fade from the red the light went off in",
    { colorsTold(), modesTold(), told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X") },
    { { 0.3 }, { FULL_MODE }, {} }
  )
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  T.eq("a level a quarter into that on tells no color", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), {})
  offIn(SEPARATE, RGB, inRed)
  onMode(WARM)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(1000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  T.eq("nor does an off", told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X"), {})
  -- The light's report of the pre-on by itself is of the driver's own command.
  local state = offIn(SEPARATE, RGB, inRed)
  onMode(WARM)
  rampedOn()
  state.state, state.brightness = true, 0.0039
  state.color_mode, state.color_temperature = preOn().color_mode, preOn().color_temperature
  pushed(SEPARATE, state, RANGE)
  run(100)
  state.brightness = 1.0
  pushed(SEPARATE, state, RANGE)
  run(5000)
  T.eq(
    "its reports of the pre-on and of the on: the level told at the on's end alone, and the color at the on",
    { told("LIGHT_BRIGHTNESS_CHANGED", "at"), told("LIGHT_COLOR_CHANGED", "at") },
    { { 4000 }, { 0 } }
  )

  -- A light in its combined mode, and one with no mode yet.
  offIn({ RGBCT, CT }, RGBCT, { red = 0, green = 0, blue = 1, white = 0 })
  onMode(WARM)
  rampedOn()
  T.eq(
    "an RGBCT light off in blue, a white On Color: the pre-on lights the white alone, in the combined mode",
    { carried()[2], carried()[3], preOn().color_brightness, preOn().white },
    { RGBCT, 3000, 0, 1 }
  )
  offIn({ RGBCT, CT }, nil, {})
  onMode({ RED[1], RED[2], id = 1 })
  rampedOn()
  T.eq(
    "one with no mode yet and a red On Color: the pre-on names the combined mode, not the first a bare one would give",
    carried()[2],
    RGBCT
  )
  -- Every path that sends a pre-on: a scene step that ramps the light on.
  offIn(SEPARATE, RGB, inRed)
  mark()
  proxy("PUSH_SCENE", {
    SCENE_ID = 7,
    ELEMENTS = "<element><delay>0</delay><rate>4000</rate><brightnessEnabled>true</brightnessEnabled>"
      .. "<brightness>60</brightness><colorEnabled>true</colorEnabled><colorX>0.3</colorX><colorY>0.4</colorY>"
      .. "<colorMode>1</colorMode></element>",
  })
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  T.eq(
    "a scene step from off in a white: the pre-on carries it as the step does, which turns the light on in its white mode",
    { carried(), lastCommand().has_color_mode or false },
    { { 0.0039, false, 3000, false }, false }
  )
  T.eq(
    "told at once, with no fade from red",
    { colorsTold(), modesTold(), told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X") },
    { { 0.3 }, { CCT_MODE }, {} }
  )
  run(1000)
  colorTarget(RED, 4000)
  run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "a color sent before the light reports the step's white, stopped a quarter of the way: that white, in its mode",
    { lastCommand().color_mode, kelvins(), colors(), colorsTold(), modesTold() },
    { CWWW, { 3000 }, {}, { 0.3 }, { CCT_MODE } }
  )
  proxy("CLEAR_ALL_SCENES")
  offIn(SEPARATE, RGB, inRed)
  onMode(WARM)
  activate(levelStep(60, 4000))
  T.eq("and one that sets a level alone: the On Color", carried(), { 0.0039, false, 3000, false })
  proxy("CLEAR_ALL_SCENES")
end

T.section(
  "a color temperature beyond the light's range lights the range's end, and the proxy is told the one asked for"
)
do
  -- The range is 6500 to 2700 K: the light holds 2200 K at 2700 K.
  local KINDS = {
    { "only a color temperature", { CT }, CT },
    { "a color temperature beside its color", { RGBCT, CT } },
    { "a color mode and a white mode", { RGB, CWWW }, CWWW },
  }
  local ASKED = { { 0.22, CCT_MODE } }
  --- Each color told since the mark: x to six places, and its mode.
  local function toldOf()
    local xs, modes = colorsTold(), modesTold()
    local out = {}
    for i = 1, #xs do
      out[i] = { math.floor(xs[i] * 1e6 + 0.5) / 1e6, modes[i] }
    end
    return out
  end
  local function lightOf(kind, on)
    light()
    pushed(kind[2], { state = on ~= false, brightness = 1.0 }, RANGE)
  end
  --- The light's report of its last command, which is returned.
  local function report(kind)
    local state = taken()
    state.color_mode = state.color_mode or kind[3]
    pushed(kind[2], state, RANGE)
    return state
  end
  local function lastKelvin()
    local k = kelvins()
    return k[#k]
  end

  for _, kind in ipairs(KINDS) do
    lightOf(kind)
    onMode(PREVIOUS_ON)
    mark()
    kelvin(2200, 0)
    T.eq(
      "a light with " .. kind[1] .. ": 2200 K from Navigator lights 2700 K, told as 2200 K",
      { kelvins(), toldOf() },
      { { 2700 }, ASKED }
    )
    local state = taken()
    state.color_mode = state.color_mode or kind[3]
    mark()
    pushed(kind[2], state, RANGE)
    T.eq("and the light's report of the range's end reads back as 2200 K", toldOf(), {})
    proxy("OFF")
    mark()
    proxy("ON")
    T.eq("with Color On Mode set to Previous it comes back on at 2700 K, told as 2200 K", { lastKelvin(), toldOf() }, {
      2700,
      ASKED,
    })
    restart()
    OBC[ESPHOME](ESPHOME, "ESPHOME", true)
    pushed(kind[2], state, RANGE)
    T.eq("a restart of the driver with the light still at the range's end: the proxy shows 2200 K", toldOf(), {})
    proxyColor, proxyTarget = nil, nil
    restart()
    OBC[ESPHOME](ESPHOME, "ESPHOME", true)
    pushed(kind[2], state, RANGE)
    T.eq("and one that shows no color is told 2200 K", toldOf(), ASKED)
    mark()
    state.color_temperature = 250
    pushed(kind[2], state, RANGE)
    state.color_temperature = 370.4
    pushed(kind[2], state, RANGE)
    T.eq(
      "another client's 4000 K and then its white at the range's end: each as the light shows it",
      toldOf(),
      { { 0.4, CCT_MODE }, { 0.27, CCT_MODE } }
    )

    lightOf(kind)
    kelvin(2200, 0)
    report(kind)
    mark()
    kelvin(2700, 0)
    report(kind)
    T.eq("2700 K set after it, and its report: told 2700 K, once", toldOf(), { { 0.27, CCT_MODE } })
    kelvin(4000, 0)
    state = report(kind)
    mark()
    state.color_temperature = 370.4
    pushed(kind[2], state, RANGE)
    T.eq(
      "and another client's white at the range's end after a white of the driver's own: that end",
      toldOf(),
      { { 0.27, CCT_MODE } }
    )

    lightOf(kind)
    mark()
    proxy("SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_X = 0.22,
      LIGHT_COLOR_TARGET_Y = 0.4,
      LIGHT_COLOR_TARGET_MODE = CCT_MODE,
      LIGHT_COLOR_TARGET_COLOR_RATE = 0,
    })
    T.eq("one given as its point, as a preset is: the same", { kelvins(), toldOf() }, { { 2700 }, ASKED })
    lightOf(kind)
    mark()
    activate(
      "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>0.22</colorX><colorY>0.4</colorY>"
        .. "<colorMode>1</colorMode><colorRate>0</colorRate></element>"
    )
    T.eq("a scene step's", { kelvins(), toldOf() }, { { 2700 }, ASKED })
    proxy("CLEAR_ALL_SCENES")
    lightOf(kind)
    fadeMode({ 0.3, 0.4 }, { 0.2, 0.4 }, CCT_MODE)
    mark()
    proxy("SET_LEVEL", { LEVEL = 30 })
    T.eq(
      "Dim-To-Warm between 3000 K and 2000 K at 30 %: 2700 K, told as the mix, 2300 K",
      { kelvins(), toldOf() },
      { { 2700 }, { { 0.23, CCT_MODE } } }
    )
  end

  -- The proxy's own copy of the color Previous carried reads as that color.
  lightOf(KINDS[1])
  onMode(PREVIOUS_ON)
  kelvin(2200, 0)
  proxy("OFF")
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
  proxy("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.22,
    LIGHT_COLOR_TARGET_Y = 0.4,
    LIGHT_COLOR_TARGET_MODE = CCT_MODE,
    LIGHT_COLOR_TARGET_COLOR_RATE = 750,
  })
  run(1000)
  T.eq(
    "Previous, and the proxy's own copy of it after the on: 2700 K, with the pre-on and the on alone, told as 2200 K",
    { kelvins(), toldOf() },
    { { 2700, 2700 }, ASKED }
  )
  lightOf(KINDS[1])
  mark()
  kelvin(8000, 0)
  T.eq("beyond the other end: 6500 K, told as 8000 K", { kelvins(), toldOf() }, { { 6502 }, { { 0.8, CCT_MODE } } })
  lightOf(KINDS[1])
  mark()
  kelvin(2200, 2000)
  run(100)
  report(KINDS[1])
  run(2000)
  T.eq(
    "over a rate, with the light's report of the range's end on the way: told as 2200 K at the fade's end",
    { toldOf(), told("LIGHT_COLOR_CHANGED", "at") },
    { ASKED, { 2000 } }
  )

  -- A stop part way is told where the light is, to or from the range's end.
  for _, kind in ipairs({ KINDS[1], KINDS[3] }) do
    lightOf(kind)
    kelvin(2200, 0)
    report(kind)
    kelvin(5000, 4000)
    run(2000)
    mark()
    proxy("SET_COLOR_STOP")
    T.eq(
      "a light with " .. kind[1] .. ": from 2200 K to 5000 K, stopped half way: half way from 2700 K",
      { kelvins(), toldOf() },
      { { 3850 }, { { 0.385, CCT_MODE } } }
    )
    report(kind)
    T.eq("and its report of that tells nothing more", #colorsTold(), 1)
  end
  lightOf(KINDS[1])
  kelvin(5000, 0)
  report(KINDS[1])
  kelvin(2200, 4000)
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "from 5000 K to 2200 K, stopped half way: half way to 2700 K",
    { kelvins(), toldOf() },
    { { 3850 }, { { 0.385, CCT_MODE } } }
  )
  lightOf(KINDS[1])
  kelvin(2200, 0)
  report(KINDS[1])
  activate(
    "<element><delay>0</delay><colorEnabled>true</colorEnabled><colorX>0.5</colorX><colorY>0.4</colorY>"
      .. "<colorMode>1</colorMode><colorRate>4000</colorRate></element>"
  )
  run(2000)
  mark()
  proxy("STOP_SCENE_RAMP", { SCENE_ID = 7 })
  T.eq(
    "a scene step from 2200 K to 5000 K, stopped half way: half way from 2700 K",
    { kelvins(), toldOf() },
    { { 3850 }, { { 0.385, CCT_MODE } } }
  )
  proxy("CLEAR_ALL_SCENES")
  lightOf(KINDS[1])
  kelvin(2200, 0)
  report(KINDS[1])
  kelvin(5000, 4000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  run(2000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq(
    "from 2200 K to 5000 K with a level sent at the same moment, stopped half way: half way from 2700 K",
    { kelvins(), toldOf() },
    { { 3850 }, { { 0.385, CCT_MODE } } }
  )
  run(5000)
  -- A color sent mid-level carrying a Dim-To-Warm white beyond the range is
  -- told from where the light is.
  lightOf(KINDS[1])
  fadeMode({ 0.3, 0.4 }, { 0.2, 0.4 }, CCT_MODE)
  proxy("SET_LEVEL", { LEVEL = 100 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 4000 })
  run(2000)
  mark()
  kelvin(5000, 4000)
  local from = told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X")
  T.eq(
    "a color temperature sent half way through a level from 3000 K toward 2300 K: told from 2850 K",
    { #from, math.floor(from[1] * 1e6 + 0.5) / 1e6 },
    { 1, 0.285 }
  )
  run(5000)
  lightOf(KINDS[1])
  fadeMode({ 0.3, 0.4 }, { 0.2, 0.4 }, CCT_MODE)
  proxy("SET_LEVEL", { LEVEL = 20 })
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  run(2000)
  mark()
  kelvin(5000, 4000)
  from = told("LIGHT_COLOR_CHANGING", "LIGHT_COLOR_CURRENT_X")
  T.eq(
    "and half way through one from 2200 K toward 3000 K: told from 2850 K",
    { #from, from[1] and math.floor(from[1] * 1e6 + 0.5) / 1e6 },
    { 1, 0.285 }
  )
  run(5000)
  -- A light without CCT is told a white as a full color; out of range that
  -- would light its color.
  light()
  pushed({ RGBW }, { state = true, brightness = 1.0 })
  fadeMode({ 0.3, 0.4 }, { 0.18, 0.4 }, CCT_MODE)
  mark()
  proxy("SET_LEVEL", { LEVEL = 10 })
  T.eq(
    "an RGBW light, Dim-To-Warm between 3000 K and 1800 K at 10 %: its white, told as the range's end, 2000 K",
    { lastCommand().white, lastCommand().color_brightness, toldOf() },
    { 1, 0, { { 0.2, FULL_MODE } } }
  )
end

T.section("a level and a color sent 12 ms apart: the light's report of the level alone does not tell its old color")
do
  local SEPARATE = { RGB, CWWW }
  -- Red is x 0 through the stubs, green x 1/3 and 4000 K x 0.4.
  local RED, GREEN = { 0, 1 }, { 0, 1, 0 }
  local FIELDS = {
    "brightness",
    "color_mode",
    "color_brightness",
    "red",
    "green",
    "blue",
    "white",
    "color_temperature",
    "cold_white",
    "warm_white",
  }
  --- What the light has, as ESPHome keeps it, and how many commands since the
  --- mark it has answered.
  local state, answered
  --- A light with the Athom bulb's modes, on at full in 4000 K.
  local function inWhite()
    light()
    state = {
      state = true,
      brightness = 1.0,
      color_mode = CWWW,
      color_brightness = 1,
      red = 1,
      green = 0,
      blue = 0,
      white = 1,
      color_temperature = 250,
      cold_white = 0.95,
      warm_white = 1,
    }
    pushed(SEPARATE, state, RANGE)
    mark()
    answered = 0
  end
  --- The light's report of the next command since the mark, which it takes:
  --- each field as last sent, or the level alone if `levelOnly`.
  local function answer(levelOnly)
    answered = answered + 1
    local n = 0
    for _, s in ipairs(sent) do
      if s.binding == ESPHOME and s.command == "ENTITY_COMMAND" then
        n = n + 1
        local cmd = n == answered and DeserializeSafe(s.params.body)
        for _, field in ipairs(cmd and (levelOnly and { "brightness" } or FIELDS) or {}) do
          state[field] = cmd[field] or state[field]
        end
      end
    end
    pushed(SEPARATE, state, RANGE)
  end
  local function levelThenRed()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 0 })
    run(12)
    colorTarget(RED, 0)
  end

  -- ESPHome answers each command by itself, 100 to 250 ms after it is sent.
  inWhite()
  levelThenRed()
  run(150)
  answer()
  run(100)
  answer()
  run(2000)
  T.eq(
    "a level then red, each reported by itself: the proxy is told red once and never 4000 K",
    { colorsTold(), told("LIGHT_COLOR_CHANGED", "at") },
    { { 0 }, { 12 } }
  )
  T.eq("and the level once", levelsTold(), { 50 })
  inWhite()
  fadeMode({ 0.3, 0.4 }, { 0.2, 0.4 }, CCT_MODE)
  mark()
  answered = 0
  levelThenRed()
  local mix = colorsTold()[1]
  run(150)
  answer()
  run(100)
  answer()
  run(2000)
  T.eq(
    "a level that carries the Dim-To-Warm white, then red: each told once, the white not again after red",
    { colorsTold(), told("LIGHT_COLOR_CHANGED", "at") },
    { { mix, 0 }, { 0, 12 } }
  )

  -- A color neither the one before nor the one sent is another client's.
  inWhite()
  levelThenRed()
  run(150)
  answer()
  run(50)
  state.color_mode, state.red, state.green, state.blue = RGB, GREEN[1], GREEN[2], GREEN[3]
  pushed(SEPARATE, state, RANGE)
  T.eq("green set elsewhere before the light reports red: told at once", colorsTold(), { 0, 1 / 3 })
  run(50)
  answer()
  run(2000)
  T.eq("and red once the light reports it", colorsTold(), { 0, 1 / 3, 0 })

  -- A light that does not show red within a second of it is told as it is.
  inWhite()
  levelThenRed()
  run(150)
  answer()
  run(100)
  answer(true)
  T.eq("a light that does not take red: nothing more is told while its report may be on the way", colorsTold(), { 0 })
  run(2000)
  T.eq(
    "then its 4000 K, a second after red was sent",
    { colorsTold(), told("LIGHT_COLOR_CHANGED", "at") },
    { { 0, 0.4 }, { 12, 1012 } }
  )
  inWhite()
  levelThenRed()
  run(150)
  answer()
  run(1350)
  answer()
  T.eq(
    "a light whose report of red comes 1.5 s after it: 4000 K at 1 s, then red",
    { colorsTold(), told("LIGHT_COLOR_CHANGED", "at") },
    { { 0, 0.4, 0 }, { 12, 1012, 1512 } }
  )

  -- A color sent after red waits its own second, not what is left of red's.
  inWhite()
  levelThenRed()
  run(150)
  answer()
  run(100)
  answer(true)
  run(650)
  colorTarget({ 1 / 3, 1 }, 0)
  run(200)
  answer()
  run(2000)
  T.eq(
    "green sent 0.9 s after a red the light did not take: 4000 K is not told while green's report is on the way",
    { colorsTold(), told("LIGHT_COLOR_CHANGED", "at") },
    { { 0, 1 / 3 }, { 12, 912 } }
  )

  -- A wait begun before a disconnect tells nothing after it.
  inWhite()
  levelThenRed()
  run(150)
  answer()
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
  run(2000)
  T.eq(
    "a disconnect while red's report may be on the way: its 4000 K is not told after it",
    { colorsTold(), told("LIGHT_COLOR_CHANGED", "at") },
    { { 0 }, { 12 } }
  )
end

T.section("a suspended device tells the proxy only that the light is offline, and the device's next report the level")
do
  -- A suspend (a lapse, or a drop to resubscribe the logs) is not the device going away: a 0 would run Light Off
  -- Programming.
  local dimmer = { ColorMode.COLOR_MODE_BRIGHTNESS }
  local function suspend()
    RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", { suspended = "true" }) -- as Director delivers it
  end
  --- The device's report of the light, as when the main driver connects again.
  local function answer(on, brightness)
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = dimmer }),
      state = SerializeSafe({ state = on, brightness = brightness }),
    })
  end
  --- What the proxy and the Top Button Link's LED were told since the mark, in order.
  local function said()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == PROXY or s.binding == TOP_LINK then
        out[#out + 1] = s.command
      end
    end
    return out
  end
  local function levels()
    return told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
  end
  local function leds()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == TOP_LINK and s.command == "MATCH_LED_STATE" then
        out[#out + 1] = s.params.STATE
      end
    end
    return out
  end
  --- A light on at 60, its device suspended.
  local function suspendedAt60()
    light(dimmer)
    answer(true, 0.6)
    mark()
    suspend()
  end

  suspendedAt60()
  run(15000)
  T.eq("a light on at 60: the proxy is told it is offline and nothing else", said(), { "ONLINE_CHANGED" })
  T.eq("offline", told("ONLINE_CHANGED", "STATE"), { false })
  mark()
  proxy("GET_LIGHT_LEVEL")
  T.eq("Get Light Level while suspended tells the level it was at", levels(), { 60 })
  suspendedAt60()
  mark()
  answer(true, 0.3)
  T.eq(
    "back: the device's report tells the light online at its level, dimmed elsewhere meanwhile",
    { told("ONLINE_CHANGED", "STATE"), levels() },
    { { true }, { 30 } }
  )
  suspendedAt60()
  mark()
  answer(true, 0.6)
  T.eq("back at the level it was at: told it once, and the LEDs nothing", { levels(), leds() }, { { 60 }, {} })
  suspendedAt60()
  mark()
  answer(false)
  T.eq("back off, turned off elsewhere meanwhile: told off, with its LEDs", { levels(), leds() }, { { 0 }, { false } })

  -- The main driver drops a command to a suspended device, so the light does not move.
  suspendedAt60()
  proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(30) })
  mark()
  proxy("TOGGLE")
  proxy("SET_LEVEL", { LEVEL = 30 })
  proxy("ON")
  proxy("OFF")
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 1000 })
  proxy("RAMP_TO_LEVEL", { LEVEL = 30, TIME = 1000 })
  colorTarget(BLUE, 1000)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS })
  proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = RELEASE_CLICK })
  RFP.DO_CLICK(TOP_LINK, "DO_CLICK", {})
  RFP.DO_PUSH(TOGGLE_LINK, "DO_PUSH", {})
  RFP.DO_RELEASE(TOGGLE_LINK, "DO_RELEASE", {})
  proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
  proxy("RAMP_SCENE_DOWN", { SCENE_ID = 7, RATE = 1000 })
  run(15000)
  T.eq("its commands, buttons and scenes tell the proxy and the LEDs nothing", said(), {})
  T.eq("and send the device nothing", commands(), 0)
  proxy("GET_LIGHT_LEVEL")
  T.eq("Get Light Level then still tells the level it was at", levels(), { 60 })
  mark()
  answer(true, 0.6)
  proxy("OFF")
  T.eq("back, its report tells 60 and an Off turns it off", levels(), { 60, 0 })
  proxy("CLEAR_ALL_SCENES")

  -- The light runs the fade it was sent, so the proxy keeps the level it was told the light is heading to.
  light(dimmer, false)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  run(1000)
  mark()
  suspend()
  run(15000)
  T.eq(
    "suspended in a ramp up from off: the proxy is told only that the light is offline",
    said(),
    { "ONLINE_CHANGED" }
  )
  mark()
  proxy("GET_LIGHT_LEVEL")
  T.eq("and Get Light Level then tells the ramp's 60", levels(), { 60 })
  mark()
  answer(true, 0.6)
  T.eq("back: the device's report tells its level", levels(), { 60 })
  light(dimmer)
  answer(true, 0.6)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  run(1000)
  mark()
  suspend()
  run(15000)
  T.eq("suspended in a fade to off: the proxy is told only that the light is offline", said(), { "ONLINE_CHANGED" })
  mark()
  proxy("GET_LIGHT_LEVEL")
  T.eq("and Get Light Level then tells the fade's 0, where the light ends, with its LEDs", { levels(), leds() }, {
    { 0 },
    { false },
  })
  mark()
  answer(false)
  T.eq("back: the device's report tells it off", levels(), { 0 })

  -- A device that drops off has usually lost power: it still reads off.
  light(dimmer)
  answer(true, 0.6)
  mark()
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
  T.eq("the device lost, with the light on: told offline and off, with its LEDs", {
    told("ONLINE_CHANGED", "STATE"),
    levels(),
    leds(),
  }, { { false }, { 0 }, { false } })

  -- Before the device's first report the level is not known.
  restart(nil)
  proxy("GET_LIGHT_LEVEL")
  T.eq("Get Light Level before the device reports tells nothing", levels(), {})
end

T.section("a light with no state from its device ignores its commands, so Control4 shows only what the device reports")
do
  local dimmer = { ColorMode.COLOR_MODE_BRIGHTNESS }
  local function answer(on, brightness)
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = dimmer }),
      state = SerializeSafe({ state = on, brightness = brightness }),
    })
  end
  local function levels()
    return told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
  end
  --- What the proxy and the Top and Toggle Button Links were told since the mark.
  local function said()
    local out = {}
    for _, s in ipairs(sent) do
      if s.binding == PROXY or s.binding == TOP_LINK or s.binding == TOGGLE_LINK then
        out[#out + 1] = s.command
      end
    end
    return out
  end
  --- Every command a light takes, from the mark on.
  local function commandAll()
    proxy("PUSH_SCENE", { SCENE_ID = 7, ELEMENTS = levelStep(30) })
    mark()
    proxy("TOGGLE")
    proxy("SET_LEVEL", { LEVEL = 30 })
    proxy("ON")
    proxy("OFF")
    proxy("DYNAMIC_ON")
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 1000 })
    proxy("RAMP_TO_LEVEL", { LEVEL = 30, TIME = 1000 })
    colorTarget(BLUE, 1000)
    proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = PRESS })
    proxy("BUTTON_ACTION", { BUTTON_ID = TOGGLE, ACTION = RELEASE_CLICK })
    RFP.DO_CLICK(TOP_LINK, "DO_CLICK", {})
    RFP.DO_PUSH(TOGGLE_LINK, "DO_PUSH", {})
    RFP.DO_RELEASE(TOGGLE_LINK, "DO_RELEASE", {})
    proxy("ACTIVATE_SCENE", { SCENE_ID = 7 })
    proxy("RAMP_SCENE_UP", { SCENE_ID = 7, RATE = 1000 })
    run(15000)
  end

  -- A device that drops off reads off; a Toggle then told the light on, which ran Light On Programming.
  light(dimmer)
  answer(true, 0.6)
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
  commandAll()
  T.eq("its device lost: commands, buttons and scenes tell the proxy and the LEDs nothing", said(), {})
  T.eq("and send the device nothing", commands(), 0)
  mark()
  answer(true, 0.6)
  proxy("TOGGLE")
  T.eq("back, its report tells 60 and a Toggle turns it off", levels(), { 60, 0 })
  proxy("CLEAR_ALL_SCENES")

  -- Bound again, as at a controller start, the light has no report yet and tells nothing.
  light(dimmer)
  answer(true, 0.6)
  mark()
  OBC[ESPHOME](ESPHOME, "ESPHOME", true)
  T.eq("its connection bound: the proxy is told nothing", said(), {})
  answer(true, 0.6)
  mark()
  OBC[ESPHOME](ESPHOME, "ESPHOME", false)
  T.eq("its connection removed: the proxy is told only that the light is offline", said(), { "ONLINE_CHANGED" })
  T.eq("offline, and its Connected variable false", {
    told("ONLINE_CHANGED", "STATE"),
    Variables["Connected"],
  }, { { false }, "0" })
  commandAll()
  T.eq("its connection unbound: they tell the proxy and the LEDs nothing", said(), {})
  T.eq("and send the device nothing", commands(), 0)
  proxy("CLEAR_ALL_SCENES")

  restart(nil)
  commandAll()
  T.eq("before its device first reports: they tell the proxy and the LEDs nothing", said(), {})
  T.eq("and send the device nothing", commands(), 0)
  proxy("CLEAR_ALL_SCENES")

  -- A click starts from the level its press found, so a press the light ignored must leave none.
  light(dimmer)
  answer(true, 0.6)
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", { suspended = "true" })
  RFP.DO_PUSH(TOGGLE_LINK, "DO_PUSH", {})
  answer(false)
  mark()
  RFP.DO_CLICK(TOGGLE_LINK, "DO_CLICK", {})
  run(15000)
  T.eq("a Toggle press while suspended at 60, then back off: its click turns the light on", levels(), { 100 })
end

T.section("a light loaded while its device is suspended is told so, and tells no level it does not know")
do
  -- The main driver's answer to the refresh the light sends at late init.
  restart(nil)
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", { suspended = "true" })
  T.eq("told only that it is offline", told("ONLINE_CHANGED", "STATE"), { false })
  T.eq("and no level", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), {})
  mark()
  proxy("GET_LIGHT_LEVEL")
  proxy("TOGGLE")
  T.eq("Get Light Level and a Toggle tell nothing", told("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), {})
end

T.section("a light's first report after a load, bind or disconnect tells the proxy only a color it does not show")
do
  -- A Zigbee light's color read back a hair off the one told, and its start re-told it: Color Changed (4002) fired
  -- (dev, 2026-10-23). An ESPHome light reports its channels as 32-bit floats, a hair off the ones it was sent.
  local pb = require("protobuf")
  local modes = { ColorMode.COLOR_MODE_RGB }
  local SUNSET, AQUA = { 0.608506, 0.357644 }, { 0.147231, 0.358549 }
  --- The device's report of the light on in the color sent as `rgb`.
  local function report(rgb)
    local function float(v)
      return (pb.decode_float(pb.encode_float(v), 1))
    end
    RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", {
      entity = SerializeSafe({ key = 1, name = "Light", supported_color_modes = modes }),
      state = SerializeSafe({
        state = true,
        brightness = 1.0,
        color_mode = ColorMode.COLOR_MODE_RGB,
        red = float(rgb[1]),
        green = float(rgb[2]),
        blue = float(rgb[3]),
      }),
    })
  end
  local function xs()
    return told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_X")
  end
  for _, how in ipairs({ "an update", "a bind", "a suspend", "the device back online" }) do
    light(modes)
    local rgb = setColor(SUNSET)
    report(rgb)
    local aqua = setColor(AQUA)
    setColor(SUNSET)
    report(rgb)
    run(15000)
    local shown = proxyColor
    mark()
    if how == "an update" then
      restart(nil)
    elseif how == "a bind" then
      OBC[ESPHOME](ESPHOME, "ESPHOME", true)
    elseif how == "a suspend" then
      RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", { suspended = "true" })
    else
      RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
    end
    report(rgb)
    run(15000)
    T.eq(how .. ": the device's report of the color the proxy shows tells it no color", xs(), {})
    T.eq(how .. ": so it shows the one it did", proxyColor, shown)
    mark()
    report(aqua)
    T.check(
      how .. ": a color set elsewhere after it is told",
      #xs() == 1 and math.abs(xs()[1] - AQUA[1]) < 5e-3,
      T.show(xs())
    )
  end
  for _, how in ipairs({ "an update", "a bind", "a suspend" }) do
    light(modes)
    local rgb = setColor(SUNSET)
    report(rgb)
    run(15000)
    proxyTarget = "0.3,0.6,0" -- a ramp it was told of, still waiting on its end
    mark()
    if how == "an update" then
      restart(nil)
    elseif how == "a bind" then
      OBC[ESPHOME](ESPHOME, "ESPHOME", true)
    else
      RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", { suspended = "true" })
    end
    report(rgb)
    T.check(
      how .. " with the proxy in a ramp: it is told the color the light is in",
      #xs() == 1 and math.abs(xs()[1] - SUNSET[1]) < 5e-3,
      T.show(xs())
    )
    T.eq(how .. " with the proxy in a ramp: which ends it", proxyTarget, proxyColor)
  end
  for _, c in ipairs({
    { "a proxy that shows no color", nil },
    { "one whose value is no color", "" },
    { "one that shows another color", "0.2,0.5,0" },
    { "one that shows the color as a color temperature", ("%g,%g,1"):format(SUNSET[1], SUNSET[2]) },
  }) do
    light(modes)
    local rgb = setColor(SUNSET)
    run(15000)
    proxyColor, proxyTarget = c[2], c[2]
    restart(nil)
    report(rgb)
    T.check(
      c[1] .. ": an update, and it is told the device's color once",
      #xs() == 1 and math.abs(xs()[1] - SUNSET[1]) < 5e-3,
      T.show(xs())
    )
    T.eq(c[1] .. ": in its mode", told("LIGHT_COLOR_CHANGED", "LIGHT_COLOR_CURRENT_COLOR_MODE"), { 0 })
  end
end

T.finish()
