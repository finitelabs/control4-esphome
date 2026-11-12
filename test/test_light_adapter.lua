--- The ESPHome light adapter against the light library's contract: each light family's commands as ENTITY_COMMAND
--- bodies, each report as the library takes it, and a stop mid mode change held where the light's fade has got to.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_light_adapter.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local ColorMode = require("esphome.proto_schema").Enum.ColorMode
local LightAdapter = require("esphome.light_adapter")
local persist = require("lib.persist")

local ESPHOME = 5002

local now = 1000000
function C4:GetTime()
  return now
end

-- xy as hue and saturation over their ranges, and Kelvin as x over a y that curves as the locus does: the shim
-- converts no colors, and these invert exactly.
function C4:ColorXYtoHSV(x, y)
  return x * 360, y * 100
end
function C4:ColorHSVtoXY(h, s)
  return h / 360, s / 100
end
function C4:ColorCCTtoXY(kelvin)
  local x = kelvin / 10000
  return x, 0.4 - (x - 0.45) ^ 2
end
function C4:ColorXYtoCCT(x)
  return x * 10000
end

local sent = {}
function SendToProxy(idBinding, strCommand, tParams)
  sent[#sent + 1] = { binding = idBinding, command = strCommand, params = tParams }
end

--- The body of the last ENTITY_COMMAND, and how many went out since the last call.
local function lastBody()
  local count, body = 0, nil
  for _, s in ipairs(sent) do
    if s.command == "ENTITY_COMMAND" then
      count = count + 1
      body = DeserializeSafe(s.params.body)
    end
  end
  sent = {}
  return body, count
end

local function near(a, b)
  return a ~= nil and b ~= nil and math.abs(a - b) < 1e-6
end

--- A connected light with these modes, and its first report.
local function light(modes, mireds, state)
  persist:delete("white_point")
  local adapter = LightAdapter.new(ESPHOME)
  local entity = { key = 1, name = "Light", supported_color_modes = modes }
  for k, v in pairs(mireds or {}) do
    entity[k] = v
  end
  adapter:learn(entity)
  adapter:report(entity, state or { state = false })
  sent = {}
  return adapter, entity
end

local WHITE_2700 = { C4:ColorCCTtoXY(2700) }
local RED = { x = 0.0, y = 1.0, mode = "xy" }

--- A command, filled with the defaults of a change to `level` in `color`.
local function command(fields)
  local cmd = {
    kind = "change",
    on = true,
    fromOff = false,
    level = 1,
    setsLevel = false,
    setsColor = false,
    transitionMs = 0,
    from = { level = 1 },
    colorUnchosen = false,
  }
  for k, v in pairs(fields) do
    cmd[k] = v
  end
  return cmd
end

---------------------------------------------------------------------------
T.section("the device facts")
---------------------------------------------------------------------------
do
  local adapter = light({ ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE }, { min_mireds = 153, max_mireds = 500 })
  local device = adapter:device()
  T.truthy("it dims", device.dims)
  T.truthy("it has color", device.color)
  T.eq("its color temperature range comes from its mireds", device.cct, { minK = 2000, maxK = 6536 })
  T.eq(
    "it fades as ESPHome eases, with a pre-on",
    device.fade,
    { kind = "device", curve = "smootherstep", preOn = true, retimes = true }
  )
  T.eq(
    "its reports show the target, are seen within a second, and a refresh re-enumerates it",
    device.feedback,
    { shows = "target", waitMs = 1000, refresh = false }
  )
  local plain = light({ ColorMode.COLOR_MODE_BRIGHTNESS }):device()
  T.falsy("a dimmer has no color", plain.color)
  T.eq("and no color temperature", plain.cct, nil)
end

---------------------------------------------------------------------------
T.section("an RGB light")
---------------------------------------------------------------------------
do
  local adapter = light({ ColorMode.COLOR_MODE_RGB })
  T.eq(
    "a color and level change goes out as one command",
    adapter:send(command({ level = 0.5, setsLevel = true, setsColor = true, color = RED, transitionMs = 1000 })),
    nil
  )
  local body = lastBody()
  T.eq("it is on", body.state, true)
  T.truthy("at the level", near(body.brightness, 0.5))
  T.eq("over the command's time", body.transition_length, 1000)
  T.eq("in the RGB mode, named", body.color_mode, ColorMode.COLOR_MODE_RGB)
  T.truthy("in red", near(body.red, 1) and near(body.green, 0) and near(body.blue, 0))

  adapter:send(command({ setsColor = true, color = RED }))
  T.eq("a color alone carries no brightness", lastBody().has_brightness, nil)

  local report = adapter:report({ supported_color_modes = { ColorMode.COLOR_MODE_RGB } }, {
    state = true,
    brightness = 0.5,
    color_mode = ColorMode.COLOR_MODE_RGB,
    color_brightness = 1,
    red = 1,
    green = 0,
    blue = 0,
  })
  T.eq("its report is a push", report.kind, "push")
  T.truthy("on at the level", report.on and near(report.level, 0.5))
  T.truthy("in red, as xy", near(report.color.x, 0) and near(report.color.y, 1) and report.color.mode == "xy")
end

---------------------------------------------------------------------------
T.section("an RGBW light built with color_interlock")
---------------------------------------------------------------------------
do
  local adapter = light({ ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_WHITE })
  local picked = { x = WHITE_2700[1], y = WHITE_2700[2], mode = "xy" }
  adapter:send(command({ setsColor = true, color = picked }))
  local body = lastBody()
  T.eq("a white picked on the color wheel goes out in the white mode", body.color_mode, ColorMode.COLOR_MODE_WHITE)
  T.eq("at full white", body.white, 1)
  T.eq("its point is not sent", body.point, nil)
  local report = adapter:report(
    { supported_color_modes = { ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_WHITE } },
    { state = true, brightness = 1, color_mode = ColorMode.COLOR_MODE_WHITE, white = 1 }
  )
  T.truthy(
    "the light's report of that white reads back as the color picked",
    near(report.color.x, picked.x) and near(report.color.y, picked.y) and report.color.mode == "xy"
  )
end

---------------------------------------------------------------------------
T.section("an RGBWW light built without color_interlock, with no mireds range")
---------------------------------------------------------------------------
do
  local adapter = light({ ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE })
  local white = { x = WHITE_2700[1], y = WHITE_2700[2], mode = "cct", kelvin = 2700 }
  adapter:send(command({ setsColor = true, color = white }))
  local body = lastBody()
  T.eq("a white stays in the combined mode", body.color_mode, ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE)
  T.eq("with the color side off", body.color_brightness, 0)
  local ratio = (1e6 / 2700 - 153) / (500 - 153)
  T.truthy(
    "and cold and warm white split over the default range",
    near(body.cold_white, 1 - ratio) and near(body.warm_white, ratio)
  )
  adapter:send(command({ setsColor = true, color = RED }))
  body = lastBody()
  T.eq("a color stays in the combined mode too", body.color_mode, ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE)
  T.truthy("with the white side off", body.cold_white == 0 and body.warm_white == 0 and body.color_brightness == 1)
end

---------------------------------------------------------------------------
T.section("an RGBCT light built with color_interlock")
---------------------------------------------------------------------------
do
  local modes = { ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_COLOR_TEMPERATURE }
  local adapter = light(modes, { min_mireds = 153, max_mireds = 500 })
  local white = { x = WHITE_2700[1], y = WHITE_2700[2], mode = "cct", kelvin = 2700 }
  adapter:send(command({ on = false, level = 0, setsColor = true, color = white }))
  local body = lastBody()
  T.eq("a white set while off names the white mode", body.color_mode, ColorMode.COLOR_MODE_COLOR_TEMPERATURE)
  T.truthy("at the color temperature", near(body.color_temperature, 1e6 / 2700))
  T.eq("and stays off", body.state, false)

  adapter:send(command({ setsColor = true, color = white }))
  T.eq("a white sent while on leaves the light in its mode", lastBody().color_mode, nil)
end

---------------------------------------------------------------------------
T.section("a CCT light, and a cold and warm white one with no mireds range")
---------------------------------------------------------------------------
do
  local adapter = light({ ColorMode.COLOR_MODE_COLOR_TEMPERATURE }, { min_mireds = 153, max_mireds = 500 })
  local white = { x = WHITE_2700[1], y = WHITE_2700[2], mode = "cct", kelvin = 2700 }
  adapter:send(command({ setsColor = true, color = white }))
  local body = lastBody()
  T.truthy("a CCT light takes the color temperature", near(body.color_temperature, 1e6 / 2700))
  local report = adapter:report(
    { supported_color_modes = { ColorMode.COLOR_MODE_COLOR_TEMPERATURE }, min_mireds = 153, max_mireds = 500 },
    {
      state = true,
      brightness = 1,
      color_mode = ColorMode.COLOR_MODE_COLOR_TEMPERATURE,
      color_temperature = 1e6 / 2700,
    }
  )
  T.eq("its report reads back as that white", report.color.mode, "cct")
  T.eq("at its Kelvin", report.color.kelvin, 2700)

  local cw = light({ ColorMode.COLOR_MODE_COLD_WARM_WHITE })
  cw:send(command({ setsLevel = true, setsColor = true, color = white }))
  body = lastBody()
  T.eq(
    "a cold and warm white light with no mireds range names its mode",
    body.color_mode,
    ColorMode.COLOR_MODE_COLD_WARM_WHITE
  )
  T.truthy("and gets its channels sent", body.has_cold_white and body.has_warm_white)
end

---------------------------------------------------------------------------
T.section("a pre-on, a light that does not dim, and a refresh")
---------------------------------------------------------------------------
do
  local adapter = light({ ColorMode.COLOR_MODE_RGB })
  adapter:send(command({
    kind = "preOn",
    fromOff = true,
    level = 1 / 255,
    setsLevel = true,
    setsColor = true,
    color = RED,
    from = { level = 0 },
  }))
  local body = lastBody()
  T.truthy(
    "a pre-on lights the bottom step at once",
    body.state and near(body.brightness, 0.0039) and body.transition_length == 0
  )
  T.eq("in the color of the ramp that follows", body.color_mode, ColorMode.COLOR_MODE_RGB)

  local switch = light({ ColorMode.COLOR_MODE_ON_OFF })
  switch:send(command({ setsLevel = true, level = 1 }))
  body = lastBody()
  T.eq("a light that does not dim is switched with its state alone", body, { has_state = true, state = true })

  switch:refresh()
  T.eq("a refresh asks for the state", sent[1] and sent[1].command, "REFRESH_STATE")
  T.eq("on the ESPHome connection", sent[1] and sent[1].binding, ESPHOME)
end

---------------------------------------------------------------------------
T.section("a stop mid mode change is held where the light's fade has got to")
---------------------------------------------------------------------------
do
  local modes = { ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_COLOR_TEMPERATURE }
  local entity = { supported_color_modes = modes, min_mireds = 153, max_mireds = 500 }
  local adapter = light(modes, { min_mireds = 153, max_mireds = 500 }, {
    state = true,
    brightness = 1,
    color_mode = ColorMode.COLOR_MODE_RGB,
    color_brightness = 1,
    red = 1,
    green = 0,
    blue = 0,
  })
  local white = { x = WHITE_2700[1], y = WHITE_2700[2], mode = "cct", kelvin = 2700 }
  adapter:send(command({ setsLevel = true, setsColor = true, color = white, transitionMs = 2000 }))
  T.eq("a white from red changes the light's mode", lastBody().color_mode, ColorMode.COLOR_MODE_COLOR_TEMPERATURE)
  now = now + 500
  local rest = adapter:send(command({ kind = "stop", setsColor = true, color = white, transitionMs = 0 }))
  local body = lastBody()
  T.eq("a stop before the midpoint holds the light in red's mode", body.color_mode, ColorMode.COLOR_MODE_RGB)
  T.eq("easing it back up", body.transition_length, LightAdapter.MODE_STOP_RATE)
  T.truthy("and says it rests in red", rest and rest.color and near(rest.color.x, 0) and rest.color.mode == "xy")

  local echo = adapter:report(entity, {
    state = true,
    brightness = 1,
    color_mode = ColorMode.COLOR_MODE_RGB,
    color_brightness = 1,
    red = 1,
    green = 0,
    blue = 0,
  })
  T.truthy("the light's report of the hold reads back as red", near(echo.color.x, 0) and echo.color.mode == "xy")

  now = now + 1000
  adapter:send(command({ setsLevel = true, setsColor = true, color = white, transitionMs = 2000 }))
  lastBody()
  now = now + 1500
  T.eq(
    "a stop past the midpoint, with the light in the white, says nothing of where it rests",
    adapter:send(command({ kind = "stop", setsColor = true, color = white })),
    nil
  )
end

---------------------------------------------------------------------------
T.section("a report from before the last command keeps the light heading to it")
---------------------------------------------------------------------------
do
  local modes = { ColorMode.COLOR_MODE_RGB }
  local entity = { supported_color_modes = modes }
  local adapter = light(
    modes,
    nil,
    { state = true, brightness = 1, color_mode = ColorMode.COLOR_MODE_RGB, color_brightness = 1, red = 1 }
  )
  local green = { x = 120 / 360, y = 1, mode = "xy" }
  local blue = { x = 240 / 360, y = 1, mode = "xy" }
  adapter:send(command({ setsColor = true, color = green, transitionMs = 1000 }))
  adapter:send(command({ setsColor = true, color = blue, transitionMs = 1000 }))
  lastBody()
  now = now + 100
  adapter:report(
    entity,
    { state = true, brightness = 1, color_mode = ColorMode.COLOR_MODE_RGB, color_brightness = 1, green = 1 }
  )
  T.truthy("its target is still the last color sent", near(adapter.target.blue, 1) and near(adapter.target.green, 0))
  T.truthy("and its fade still runs", adapter.fade ~= nil)
  adapter:report(
    entity,
    { state = true, brightness = 1, color_mode = ColorMode.COLOR_MODE_RGB, color_brightness = 1, red = 1, blue = 1 }
  )
  T.truthy("a color never sent is the light's new target", near(adapter.target.red, 1) and near(adapter.target.blue, 1))
  T.eq("and its fade is unknown", adapter.fade, nil)
end

T.finish()
