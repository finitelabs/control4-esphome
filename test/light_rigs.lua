--- The esphome_light conformance rigs: the driver as it ships, behind a fake of the ESPHome connection
--- alone. Each rig is one family of ESPHome light, named by the color modes its entity lists. The fake
--- answers every command with a report of the values it now heads to, as ESPHome does, and runs each
--- transition over its length with ESPHome's easing.

local Rig = require("light_rig")
local Color = require("lib.light.color")
local ColorMode = require("esphome.proto_schema").Enum.ColorMode

local ROOT = (debug.getinfo(1, "S").source:match("^@(.*)/") or ".") .. "/.."
local ESPHOME = 5002
-- ESPHome answers each command with a report of its own, seen within 250 ms.
local ANSWER_MS = 50

local FIELDS = { "color_brightness", "red", "green", "blue", "white", "color_temperature", "cold_white", "warm_white" }

--- @type table<ProtoColorMode, boolean>
local RGB_MODES = {
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @type table<ProtoColorMode, boolean>
local CCT_MODES = {
  [ColorMode.COLOR_MODE_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_COLD_WARM_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

local function eased(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

-- The lowest listed mode of a set, as ESPHome's compute_color_mode_ picks one.
local function lowest(modes, set)
  local pick
  for _, mode in ipairs(modes) do
    if (not set or set[mode]) and (not pick or mode < pick) then
      pick = mode
    end
  end
  return pick
end

--- The device's values at full scale, read as the library reads a color: the white of a mode showing it
--- (as Kelvin where it has a color temperature), else its RGB as xy.
local function shown(s)
  local mode = s.color_mode
  local white = mode == ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE and math.max(s.cold_white, s.warm_white) or s.white
  local inWhite = not (RGB_MODES[mode] and s.color_brightness > 0 and s.color_brightness >= white)
  if inWhite and CCT_MODES[mode] and s.color_temperature > 0 then
    return { kelvin = math.floor(1e6 / s.color_temperature + 0.5) }
  end
  if RGB_MODES[mode] and math.max(s.red, s.green, s.blue) > 0 and not inWhite then
    local x, y = Color.rgbToXY(s.red, s.green, s.blue)
    return { x = x, y = y }
  end
  if mode == ColorMode.COLOR_MODE_WHITE or mode == ColorMode.COLOR_MODE_RGB_WHITE then
    return { x = 0.3127, y = 0.3290 }
  end
  return nil
end

--- A fake ESPHome light with these modes and, optionally, a mireds range.
local function device(h, modes, mireds, values)
  local entity = { key = 1, name = "Light", supported_color_modes = modes }
  for k, v in pairs(mireds or {}) do
    entity[k] = v
  end
  local dims = lowest(modes) ~= ColorMode.COLOR_MODE_ON_OFF
  local s = {
    state = false,
    brightness = 1,
    color_mode = lowest(modes, { [ColorMode.COLOR_MODE_UNKNOWN] = false }) or lowest(modes),
  }
  for _, f in ipairs(FIELDS) do
    s[f] = 0
  end
  -- ESPHome reports a color light's color_brightness as 1 until a command sets it.
  s.color_brightness = 1
  local fade = nil -- { from, to, start, ms } of the light's output, 0 when dark
  local connected = true

  local function report()
    if not connected then
      return
    end
    local state = { state = s.state, brightness = dims and s.brightness or nil, color_mode = s.color_mode }
    for _, f in ipairs(FIELDS) do
      state[f] = s[f]
    end
    ReceivedFromProxy(ESPHOME, "UPDATE_STATE", { entity = SerializeSafe(entity), state = SerializeSafe(state) })
  end

  -- The light's output now: a fade to off keeps it lit until the fade ends.
  local function output()
    if fade then
      local p = (h.clock.now() - fade.start) / fade.ms
      if p < 1 then
        return fade.from + (fade.to - fade.from) * eased(math.max(0, p))
      end
      fade = nil
    end
    return s.state and s.brightness or 0
  end

  local function take(cmd)
    local was = output()
    if cmd.has_state then
      s.state = cmd.state
    end
    if cmd.has_brightness and cmd.state ~= false then
      s.brightness = cmd.brightness
    end
    if cmd.has_color_mode then
      s.color_mode = cmd.color_mode
    elseif cmd.has_color_temperature and not CCT_MODES[s.color_mode] then
      s.color_mode = lowest(modes, CCT_MODES) or s.color_mode
    elseif cmd.has_rgb and not RGB_MODES[s.color_mode] then
      s.color_mode = lowest(modes, RGB_MODES) or s.color_mode
    end
    if cmd.has_rgb then
      local full = math.max(cmd.red, cmd.green, cmd.blue)
      if full > 0 then
        s.red, s.green, s.blue = cmd.red / full, cmd.green / full, cmd.blue / full
      end
    end
    for _, f in ipairs({ "color_brightness", "white", "color_temperature", "cold_white", "warm_white" }) do
      if cmd["has_" .. f] then
        s[f] = cmd[f]
      end
    end
    local ms = tonumber(cmd.transition_length) or 0
    local to = s.state and s.brightness or 0
    fade = ms > 0 and was ~= to and { from = was, to = to, start = h.clock.now(), ms = ms } or nil
    h.clock.at(ANSWER_MS, report)
  end

  local prior = C4.SendToProxy
  C4.SendToProxy = function(self, id, cmd, params, ...)
    if tonumber(id) == ESPHOME then
      if not connected then
        return
      end
      if cmd == "ENTITY_COMMAND" then
        take(DeserializeSafe(params.body))
      elseif cmd == "REFRESH_STATE" then
        h.clock.at(ANSWER_MS, report)
      end
      return
    end
    return prior(self, id, cmd, params, ...)
  end

  local fake = {}

  function fake.state()
    if not dims then
      return { on = s.state, level = s.state and 1 or 0 }
    end
    local out = output()
    if fade then
      return { on = out > 0, level = out, color = shown(s) }
    end
    -- Off, it keeps the level it had.
    return { on = s.state, level = s.brightness, color = shown(s) }
  end

  function fake.set(state, _quiet)
    -- ESPHome reports a light's whole state, so a change is never quiet.
    if state.on ~= nil then
      s.state = state.on
    end
    if state.level ~= nil and dims then
      s.brightness = state.level
    end
    local c = state.color
    if c and c.kelvin and lowest(modes, CCT_MODES) then
      s.color_mode = CCT_MODES[s.color_mode] and s.color_mode or lowest(modes, CCT_MODES)
      s.color_temperature = 1e6 / c.kelvin
      s.color_brightness = 0
    elseif c and c.x and lowest(modes, RGB_MODES) then
      s.color_mode = RGB_MODES[s.color_mode] and s.color_mode or lowest(modes, RGB_MODES)
      local r, g, b = Color.xyToRGB(c.x, c.y)
      local full = math.max(r, g, b)
      s.red, s.green, s.blue = r / full, g / full, b / full
      s.color_brightness, s.white, s.cold_white, s.warm_white = 1, 0, 0, 0
    end
    fade = nil
    h.clock.at(ANSWER_MS, report)
  end

  function fake.drop()
    connected = false
    fade = nil
    ReceivedFromProxy(ESPHOME, "UPDATE_DISCONNECT", {})
  end

  function fake.back()
    connected = true
    h.clock.at(ANSWER_MS, report)
  end

  function fake.suspend()
    connected = false
    ReceivedFromProxy(ESPHOME, "UPDATE_DISCONNECT", { suspended = "true" })
  end

  fake.resume = fake.back

  if values then
    fake.set(values)
  end
  return fake
end

--- A rig for one family, by the modes its entity lists. OnDriverInit is not called: its --#ifdef
--- DRIVERCENTRAL arms are plain comments in unpreprocessed source, so both would run and need the cloud
--- client. The rig leaves gInitialized as OnDriverInit would, as the repo's other driver harnesses do.
--- @param start LightValues|nil Where the rig's light starts when a case gives no state.
local function rig(name, modes, mireds, rest, start)
  local r = { name = name, rest = rest }
  function r.load(h, state)
    local folder = r.folder:match("[^/]+$")
    local fake = device(h, modes, mireds, state or start)
    gInitialized = false
    dofile(ROOT .. "/drivers/" .. folder .. "/driver.lua")
    ShimLateInit()
    return fake
  end
  return r
end

local RANGE = { min_mireds = 153, max_mireds = 500 }

-- A color fade into a white of another mode, stopped part way, from the rig's start in red: the light rests
-- where its own fade has it.
local function stopMidModeChange(h)
  local x, y = Color.kelvinToXY(4000)
  h.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = x,
    LIGHT_COLOR_TARGET_Y = y,
    LIGHT_COLOR_TARGET_MODE = 1,
    LIGHT_COLOR_TARGET_RATE = 2000,
  })
  h.clock.run(500)
  h.proxy:send("SET_COLOR_STOP", {})
end

local RED = { on = true, level = 1, color = { x = 0.64, y = 0.33 } }

return {
  version = Rig.VERSION,
  rigs = {
    esphome_light = {
      rig("RGBWW in one combined mode", { ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE }, RANGE),
      rig("RGBWW in one combined mode, no mireds range", { ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE }),
      rig(
        "RGBCT with separate modes",
        { ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_COLOR_TEMPERATURE },
        RANGE,
        stopMidModeChange,
        RED
      ),
      rig("RGBW with separate modes", { ColorMode.COLOR_MODE_RGB, ColorMode.COLOR_MODE_WHITE }),
      rig("RGB", { ColorMode.COLOR_MODE_RGB }),
      rig("CCT", { ColorMode.COLOR_MODE_COLOR_TEMPERATURE }, RANGE),
      rig("cold and warm white, no mireds range", { ColorMode.COLOR_MODE_COLD_WARM_WHITE }),
      rig("dimmer", { ColorMode.COLOR_MODE_BRIGHTNESS }),
      rig("on and off", { ColorMode.COLOR_MODE_ON_OFF }),
    },
  },
}
