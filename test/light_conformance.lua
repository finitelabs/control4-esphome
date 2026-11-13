--- The shared conformance cases: what every light_v2 driver over lib.light does, proved on the repo's
--- own rigs. Each case is chosen from the profile and device facts of the light the driver made, and
--- judges only what the fake proxy is told and where the rig's device ends.
---
--- test/test_light_conformance.lua runs C.run over every rig test/light_rigs.lua gives: a LightRigFile, as
--- test/light_rig.lua declares it.

local F = require("c4_fixtures")
local P = require("light_proxy_fake")
local D = require("light_drivers")
local Caps = require("lib.light.caps")
local Range = require("lib.light.range")
local Light = require("lib.light")
local log = require("lib.logging")
local Rig = require("light_rig")

local C = {}

--- The rig interface's version (test/light_rig.lua declares the interface).
C.RIG_VERSION = Rig.VERSION

-- What the cases running installed and have not put back.
local open = {}

--- @param a {x: number, y: number}|nil
--- @param b {x: number, y: number}|nil
--- @return boolean
local function sameXY(a, b)
  return a ~= nil and b ~= nil and math.abs(a.x - b.x) <= 0.01 and math.abs(a.y - b.y) <= 0.01
end

--- A device color as xy: a white it holds by its kelvin, at that kelvin's point.
--- @param color LightColor|nil
--- @return {x: number, y: number}|nil
local function xyOf(color)
  if type(color) ~= "table" then
    return nil
  end
  if color.x then
    return { x = color.x, y = color.y }
  end
  if color.kelvin then
    local x, y = C4:ColorCCTtoXY(color.kelvin)
    return { x = x, y = y }
  end
  return nil
end

--- The proxy's color as xy, from LIGHT_COLOR_CHANGED's text values.
--- @param color FakeProxyColor|nil
--- @return {x: number, y: number}|nil
local function shownXY(color)
  if not color then
    return nil
  end
  return { x = tonumber(color.x), y = tonumber(color.y) }
end

--- @param value any
--- @return boolean
local function on(value)
  return value == true or value == "True" or value == "true" or value == 1 or value == "1"
end

--- A color for SET_COLOR_TARGET: (x, y) as a full color on a light with color, else the white of kelvin.
--- @class LightRigColor
--- @field x number
--- @field y number
--- @field mode integer 0 full color, 1 a white.

--- @param device LightDevice
--- @param x number
--- @param y number
--- @param kelvin integer
--- @return LightRigColor
local function colorFor(device, x, y, kelvin)
  if device.color then
    return { x = x, y = y, mode = 0 }
  end
  local cx, cy = C4:ColorCCTtoXY(kelvin)
  return { x = cx, y = cy, mode = 1 }
end

--- @param color LightRigColor
--- @param rate integer
--- @return table<string, any>
local function colorParams(color, rate)
  return {
    LIGHT_COLOR_TARGET_X = color.x,
    LIGHT_COLOR_TARGET_Y = color.y,
    LIGHT_COLOR_TARGET_MODE = color.mode,
    LIGHT_COLOR_TARGET_COLOR_RATE = rate,
  }
end

--- A white at `kelvin`: a white on a light with color temperature, else a full color at the white's point.
--- @param device LightDevice
--- @param kelvin integer
--- @return LightRigColor
local function whiteFor(device, kelvin)
  local x, y = C4:ColorCCTtoXY(kelvin)
  return { x = x, y = y, mode = device.cct and 1 or 0 }
end

--- The proxy's color on mode: `color` as the On color, from preset 1 of the device's presets, or none. With
--- `dim`, Dim-To-Warm, from `dim` (preset 2) at the bottom to `color` at the top.
--- @param p FakeProxy
--- @param color LightRigColor|nil
--- @param dim LightRigColor|nil
local function colorOnMode(p, color, dim)
  p:send("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = color and 1 or 0,
    COLOR_PRESET_ORIGIN = color and 1 or 0,
    COLOR_PRESET_COLOR_X = color and color.x,
    COLOR_PRESET_COLOR_Y = color and color.y,
    COLOR_PRESET_COLOR_MODE = color and color.mode,
    COLOR_FADE_PRESET_ID = dim and 2 or 0,
    COLOR_FADE_PRESET_ORIGIN = dim and 1 or 0,
    COLOR_FADE_PRESET_COLOR_X = dim and dim.x,
    COLOR_FADE_PRESET_COLOR_Y = dim and dim.y,
    COLOR_FADE_PRESET_COLOR_MODE = dim and dim.mode,
  })
end

--- Dim-To-Warm's mix at a C4 level: a white on the line between its ends' whites, else the point between them.
--- @param dim LightRigColor
--- @param color LightRigColor
--- @param level integer
--- @return {x: number, y: number}
local function mixAt(dim, color, level)
  local b = math.max(0, math.min(100, level)) / 100
  local x, y = dim.x + (color.x - dim.x) * b, dim.y + (color.y - dim.y) * b
  if color.mode == 1 then
    x, y = C4:ColorCCTtoXY(C4:ColorXYtoCCT(x, y))
  end
  return { x = x, y = y }
end

--- A scene's steps, as the proxy pushes them.
--- @class LightRigStep
--- @field delay integer|nil
--- @field level integer|nil C4 level.
--- @field rate integer|nil
--- @field color LightRigColor|nil

--- @param p FakeProxy
--- @param id integer
--- @param steps LightRigStep[]
--- @param flash boolean
local function pushScene(p, id, steps, flash)
  local xml = {}
  for _, s in ipairs(steps) do
    local parts = { "<element>", "<delay>" .. (s.delay or 0) .. "</delay>" }
    if s.level then
      parts[#parts + 1] = "<brightnessEnabled>True</brightnessEnabled><brightness>" .. s.level .. "</brightness>"
      parts[#parts + 1] = "<brightnessRate>" .. (s.rate or 0) .. "</brightnessRate>"
    end
    if s.color then
      parts[#parts + 1] = string.format(
        "<colorEnabled>True</colorEnabled><colorX>%s</colorX><colorY>%s</colorY><colorMode>%d</colorMode>"
          .. "<colorRate>%d</colorRate>",
        s.color.x,
        s.color.y,
        s.color.mode,
        s.rate or 0
      )
    end
    parts[#parts + 1] = "</element>"
    xml[#xml + 1] = table.concat(parts)
  end
  p:send("PUSH_SCENE", {
    SCENE_ID = id,
    ELEMENTS = table.concat(xml),
    FLASH = flash and "True" or "False",
    FROM_GROUP = "True",
  })
end

--- How long a step waits for the light to settle.
--- @param rig LightRig
--- @return integer
local function wait(rig)
  return (rig.settleMs or 12000) + 5000
end

--- Load the rig's driver afresh on a new clock behind a new fake proxy, and let it settle online.
--- @param rig LightRig
--- @param state LightValues|nil Where the device starts.
--- @param variables table<integer, string>|nil What the proxy's variables hold, as after a restart.
--- @return LightRigHarness
local function fresh(rig, state, variables)
  local clock = F.virtualClock()
  local proxy = P.install(clock, { setup = rig.setup, variables = variables })
  local errors = {}
  local logError = log.error
  log.error = function(self, fmt, ...)
    errors[#errors + 1] = string.format(tostring(fmt), ...)
    return logError(self, fmt, ...)
  end
  local xml = D.xml(D.root(), rig.folder) or ""
  D.seedProperties(xml)
  local restoreConfig = D.answerConfig(xml)
  local function restore()
    log.error = logError
    restoreConfig()
    proxy:restore()
    clock.restore()
  end
  open[#open + 1] = restore
  local h = { clock = clock, proxy = proxy, errors = errors, lo = 1, hi = 100 }
  function h.done()
    for i = #open, 1, -1 do
      if open[i] == restore then
        table.remove(open, i)
        restore()
      end
    end
  end
  local before = #Light.made
  h.device = rig.load(h, state)
  if not h.light and #Light.made > before then
    h.light = Light.made[#Light.made]
  end
  clock.run(wait(rig))
  return h
end

--- The device's level as the proxy shows it: 0 when off, 100 on a light that does not dim.
--- @param h LightRigHarness
--- @return integer
local function percent(h)
  local state = h.device.state()
  if not state.on then
    return 0
  end
  if not h.light.device.dims then
    return 100
  end
  return Range.toLevel(state.level, h.lo, h.hi)
end

--- A controller restart: Director restarts, the proxy keeps its variables, the device keeps its state,
--- and the driver loads afresh.
--- @param rig LightRig
--- @param h LightRigHarness
--- @return LightRigHarness
local function restart(rig, h)
  local state = h.device.state()
  local variables = {}
  for id, v in pairs(h.proxy.vars) do
    variables[tonumber(id)] = v.value
  end
  h.done()
  ShimRestartDirector()
  return fresh(rig, state, variables)
end

--- Run one case: a raise in it fails by name and the run goes on, with what it installed put back.
--- @param T table testlib
--- @param name string
--- @param fn fun()
function C.case(T, name, fn)
  local mark = #open
  local ok, err = xpcall(fn, debug.traceback)
  for i = #open, mark + 1, -1 do
    table.remove(open, i)()
  end
  if not ok then
    T.check(name .. ": the case runs to its end", false, err)
  end
end

--- Prove a driver's light over one rig.
--- @param T table testlib
--- @param rig LightRig
function C.run(T, rig)
  local name = rig.name or rig.folder
  local ms = wait(rig)

  --- @param h LightRigHarness
  local function finish(h)
    T.eq(name .. ": no callback raised", h.clock.errors, {})
    h.done()
  end

  -- The facts the sections are chosen by, from one load.
  --- @type { profile: LightProfile, device: LightDevice, suspends: boolean }|nil
  local probe
  C.case(T, name, function()
    local h = fresh(rig)
    if h.light and h.light.device then
      probe = {
        profile = h.light.profile,
        device = h.light.device,
        suspends = h.device.suspend ~= nil and h.device.resume ~= nil,
      }
    end
    h.done()
  end)
  T.section(name .. ": the driver makes its light, which comes online with its capabilities told once")
  C.case(T, name, function()
    local h = fresh(rig)
    T.check(name .. ": the driver made a light", h.light ~= nil)
    T.check(name .. ": and declared its device", h.light ~= nil and h.light.device ~= nil)
    T.check(name .. ": the proxy is told it is online", on(h.proxy.online), T.show(h.proxy.online))
    T.eq(name .. ": the capabilities are told once", h.proxy:count("DYNAMIC_CAPABILITIES_CHANGED"), 1)
    if h.light and h.light.device then
      T.eq(
        name .. ": as the device and profile derive them",
        h.proxy.caps,
        Caps.dynamic(h.light.device, h.light.profile)
      )
    end
    T.eq(name .. ": no error was logged", h.errors, {})
    finish(h)
  end)
  if not probe then
    return
  end
  local profile, device = probe.profile, probe.device
  local dims = device.dims
  local hasColor = device.color or device.cct ~= nil
  local ramps = dims and profile.fades and device.fade.kind ~= "own"
  local links = profile.links

  T.section(name .. ": On, Off and Toggle reach the device, and the proxy shows where it is")
  C.case(T, name, function()
    local h = fresh(rig)
    local p = h.proxy
    for _, step in ipairs({ { "ON", true }, { "OFF", false }, { "TOGGLE", true }, { "TOGGLE", false } }) do
      p:send(step[1])
      h.clock.run(ms)
      T.eq(
        name .. ": " .. step[1] .. " leaves the device " .. (step[2] and "on" or "off"),
        h.device.state().on,
        step[2]
      )
      T.eq(name .. ": and the proxy shows it", p.level, percent(h))
    end
    finish(h)
  end)

  if dims then
    T.section(name .. ": a level reaches the device, and the proxy shows it")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      p:send("SET_LEVEL", { LEVEL = 40 })
      h.clock.run(ms)
      T.eq(name .. ": the device is at 40", percent(h), 40)
      T.eq(name .. ": as the proxy shows", p.level, 40)
      finish(h)
    end)
  end

  if ramps then
    T.section(name .. ": a ramp moves the device over its rate, a stop holds it part way, a rated off ends off")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      p:send("SET_LEVEL", { LEVEL = 10 })
      h.clock.run(ms)
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 8000 })
      h.clock.run(4000)
      local mid = percent(h)
      T.check(name .. ": half way through its rate the device is part way", mid > 30 and mid < 70, mid)
      p:send("SET_BRIGHTNESS_STOP")
      h.clock.run(ms)
      local at = percent(h)
      T.check(name .. ": a stop holds it part way", at > 30 and at < 70, at)
      T.check(
        name .. ": where the proxy shows",
        math.abs((p.level or -9) - at) <= 1,
        T.show({ shown = p.level, device = at })
      )
      p:send("SET_LEVEL", { LEVEL = 80 })
      h.clock.run(ms)
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
      h.clock.run(2000)
      local fading = percent(h)
      T.check(name .. ": half way through a rated off the device is lit, part way", fading > 20 and fading < 60, fading)
      h.clock.run(ms)
      T.eq(name .. ": it ends off, as the proxy shows", { h.device.state().on, p.level }, { false, 0 })
      finish(h)
    end)

    T.section(name .. ": a rated on from off never jumps past its target, and the next off keeps Previous On")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      p:send("SET_LEVEL", { LEVEL = 60 })
      h.clock.run(ms)
      p:send("OFF")
      h.clock.run(ms)
      p:mark()
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
      local highest = 0
      for _ = 1, 40 do
        h.clock.run(100)
        highest = math.max(highest, percent(h))
      end
      h.clock.run(ms)
      T.check(name .. ": the device never goes above 50", highest <= 51, highest)
      T.eq(name .. ": it lands on 50", p.level, 50)
      p:send("OFF")
      h.clock.run(ms)
      T.eq(name .. ": the next off keeps Previous On at 50", p.previousOn, 50)
      finish(h)
    end)
  end

  if hasColor then
    T.section(name .. ": a color reaches a light that is on; one sent while off lights nothing, and the next On has it")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      local a, b = colorFor(device, 0.6, 0.3, 2700), colorFor(device, 0.3, 0.5, 6000)
      colorOnMode(p, nil)
      p:send("ON")
      h.clock.run(ms)
      p:send("SET_COLOR_TARGET", colorParams(a, 0))
      h.clock.run(ms)
      local color = xyOf(h.device.state().color)
      T.check(name .. ": a color reaches the device", sameXY(color, a), T.show(color))
      T.check(name .. ": and the proxy shows it", sameXY(shownXY(p.color), a), T.show(p.color))
      p:send("OFF")
      h.clock.run(ms)
      p:mark()
      p:send("SET_COLOR_TARGET", colorParams(b, 0))
      h.clock.run(ms)
      T.eq(name .. ": a color sent while off leaves the device off", h.device.state().on, false)
      T.eq(name .. ": and the proxy is told no level", p:changed(), {})
      p:send("ON")
      h.clock.run(ms)
      color = xyOf(h.device.state().color)
      T.check(name .. ": the next On comes on in it", sameXY(color, b), T.show(color))
      T.check(name .. ": as the proxy shows", sameXY(shownXY(p.color), b), T.show(p.color))
      finish(h)
    end)
  end

  if device.cct ~= nil then
    T.section(name .. ": two whites picked 100 ms apart end on the second, the first never read as another hand's")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      local function white(kelvin)
        local x, y = C4:ColorCCTtoXY(kelvin)
        return { x = x, y = y, mode = 1 }
      end
      local first, second = white(2700), white(4000)
      p:send("ON")
      h.clock.run(ms)
      p:mark()
      p:send("SET_COLOR_TARGET", colorParams(first, 0))
      h.clock.run(100)
      p:send("SET_COLOR_TARGET", colorParams(second, 0))
      h.clock.run(ms)
      local color = xyOf(h.device.state().color)
      T.check(name .. ": the device ends on the second", sameXY(color, second), T.show(color))
      T.check(name .. ": as the proxy shows", sameXY(shownXY(p.color), second), T.show(p.color))
      local afterSecond, back = false, false
      for _, n in ipairs(p.notes) do
        if n.binding == P.PROXY and n.cmd == "LIGHT_COLOR_CHANGED" then
          local told = { x = tonumber(n.params.LIGHT_COLOR_CURRENT_X), y = tonumber(n.params.LIGHT_COLOR_CURRENT_Y) }
          afterSecond = afterSecond or sameXY(told, second)
          back = back or (afterSecond and sameXY(told, first))
        end
      end
      T.check(name .. ": the first is never told after the second", not back)
      finish(h)
    end)
  end

  if hasColor and profile.onModes then
    T.section(name .. ": Navigator's On with a Color On Mode comes on in the On color, told once")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      local onColor, before = colorFor(device, 0.6, 0.3, 2700), colorFor(device, 0.3, 0.5, 6000)
      colorOnMode(p, onColor)
      p:send("ON")
      h.clock.run(ms)
      p:send("SET_COLOR_TARGET", colorParams(before, 0))
      h.clock.run(ms)
      p:send("OFF")
      h.clock.run(ms)
      p:mark()
      p:appOn(dims and 80 or 100)
      h.clock.run(ms)
      local told = p:told("LIGHT_COLOR_CHANGED")
      T.eq(name .. ": the proxy is told one color", #told, 1)
      local first = told[1]
      T.check(
        name .. ": the On color",
        first ~= nil
          and sameXY({ x = tonumber(first.LIGHT_COLOR_CURRENT_X), y = tonumber(first.LIGHT_COLOR_CURRENT_Y) }, onColor),
        T.show(first)
      )
      local color = xyOf(h.device.state().color)
      T.check(name .. ": and the device is in it", sameXY(color, onColor), T.show(color))
      colorOnMode(p, nil)
      finish(h)
    end)
  end

  if links then
    T.section(name .. ": a link's press and click turn the light on and off, and its LEDs follow the light")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      local steps = {
        { links.top, true },
        { links.bottom, false },
        { links.toggle, true },
        { links.toggle, false },
      }
      for _, step in ipairs(steps) do
        p:link(step[1], "DO_PUSH")
        p:link(step[1], "DO_CLICK")
        h.clock.run(ms)
        T.eq(
          name .. ": a click on link " .. step[1] .. " leaves the device on: " .. tostring(step[2]),
          h.device.state().on,
          step[2]
        )
        T.eq(name .. ": the proxy shows it", p.level, percent(h))
        T.eq(
          name .. ": every link's LED shows the light's own state",
          { on(p.leds[links.top]), on(p.leds[links.toggle]), on(p.leds[links.bottom]) },
          { step[2], step[2], step[2] }
        )
      end
      finish(h)
    end)

    T.section(name .. ": a keypad asking a link for its button's colors is answered on that link")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      for _, link in ipairs({ links.top, links.toggle, links.bottom }) do
        p:mark()
        p:link(link, "REQUEST_BUTTON_COLORS")
        h.clock.run(10)
        local colors = p:toldLink(link, "BUTTON_COLORS")
        T.eq(name .. ": link " .. link .. " answers BUTTON_COLORS on itself", #colors, 1)
        T.check(
          name .. ": with an on and an off color",
          colors[1] ~= nil and colors[1].ON_COLOR ~= nil and colors[1].OFF_COLOR ~= nil,
          T.show(colors[1])
        )
        T.eq(name .. ": and nothing on the proxy binding", p:count("BUTTON_COLORS"), 0)
      end
      finish(h)
    end)

    if ramps then
      T.section(name .. ": a link's hold ramps the light while held, and the release holds it there")
      C.case(T, name, function()
        local h = fresh(rig)
        local p = h.proxy
        p:send("SET_LEVEL", { LEVEL = 10 })
        h.clock.run(ms)
        p:link(links.top, "DO_PUSH")
        h.clock.run(1500)
        p:link(links.top, "DO_RELEASE")
        h.clock.run(ms)
        local at = percent(h)
        T.check(name .. ": the hold raised the level part way", at > 10 and at < 100, at)
        T.check(
          name .. ": where the proxy shows",
          math.abs((p.level or -9) - at) <= 1,
          T.show({ shown = p.level, device = at })
        )
        finish(h)
      end)

      if hasColor and profile.onModes then
        --- The light on in `before`, then off, and a hold of `link` from off let go part way up.
        --- @param h LightRigHarness
        --- @param before LightRigColor
        --- @param setMode fun()
        --- @param link integer
        local function holdFromOff(h, before, setMode, link)
          local p = h.proxy
          p:send("ON")
          h.clock.run(ms)
          p:send("SET_COLOR_TARGET", colorParams(before, 0))
          h.clock.run(ms)
          p:send("OFF")
          h.clock.run(ms)
          setMode()
          p:link(link, "DO_PUSH")
          h.clock.run(1500)
          p:link(link, "DO_RELEASE")
          h.clock.run(ms)
          local at = percent(h)
          T.check(name .. ": the hold from off stopped part way up", at > 0 and at < 100, at)
        end

        T.section(name .. ": a link's hold from off under a Color On Mode stops in the On color, not one on the way")
        C.case(T, name, function()
          local h = fresh(rig)
          local p = h.proxy
          local onColor, before = colorFor(device, 0.6, 0.3, 2700), colorFor(device, 0.3, 0.5, 6000)
          holdFromOff(h, before, function()
            colorOnMode(p, onColor)
          end, links.toggle)
          T.check(name .. ": the proxy shows the On color", sameXY(shownXY(p.color), onColor), T.show(p.color))
          local color = xyOf(h.device.state().color)
          T.check(name .. ": and the device is in it", sameXY(color, onColor), T.show(color))
          colorOnMode(p, nil)
          finish(h)
        end)

        T.section(
          name .. ": a link's hold from off under Dim-To-Warm, after a cool white, stops in the mix for its level"
        )
        C.case(T, name, function()
          local h = fresh(rig)
          local p = h.proxy
          local top, bottom = whiteFor(device, 4000), whiteFor(device, 2700)
          -- A device that shows both whites as asked shows the mix between them. One that shows every white on a
          -- white channel of its own can't, and the proxy alone says where the light stopped.
          local asked = true
          p:send("ON")
          h.clock.run(ms)
          for _, white in ipairs({ bottom, top }) do
            p:send("SET_COLOR_TARGET", colorParams(white, 0))
            h.clock.run(ms)
            asked = asked and sameXY(xyOf(h.device.state().color), white)
          end
          holdFromOff(h, whiteFor(device, 6000), function()
            colorOnMode(p, top, bottom)
          end, links.top)
          local want = mixAt(bottom, top, p.level or 0)
          T.check(
            name .. ": the proxy shows the mix",
            sameXY(shownXY(p.color), want),
            T.show({ shown = p.color, want = want, level = p.level })
          )
          local color = xyOf(h.device.state().color)
          T.check(
            name .. ": and the device is in it, on a device that shows both whites as asked",
            not asked or sameXY(color, want),
            T.show({ device = color, want = want })
          )
          colorOnMode(p, nil)
          finish(h)
        end)
      end
    end
  end

  if profile.scenes then
    T.section(name .. ": a stepped scene runs its steps to the last")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      local last = dims and 70 or 100
      local steps = { { level = dims and 30 or 0 }, { delay = 1000, level = last } }
      if hasColor then
        steps[2].color = colorFor(device, 0.6, 0.3, 2700)
      end
      pushScene(p, 7, steps, false)
      p:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
      h.clock.run(ms)
      T.eq(name .. ": the device ends at the last step", percent(h), last)
      T.eq(name .. ": as the proxy shows", p.level, last)
      if hasColor then
        local color = xyOf(h.device.state().color)
        T.check(name .. ": in its color", sameXY(color, steps[2].color), T.show(color))
      end
      finish(h)
    end)

    if profile.flash then
      T.section(name .. ": a flash scene flashes the light until it is deactivated")
      C.case(T, name, function()
        local h = fresh(rig)
        local p = h.proxy
        -- Each step outlasts the device's own fades, which the library can't shorten.
        local step = 500
        local own = device.fade.own
        if device.fade.kind == "own" and own then
          step = math.max(step, own.onMs + 200, own.offMs + 200, own.changeMs + 200)
        end
        pushScene(p, 8, { { level = 100 }, { delay = step, level = 0 }, { delay = step, level = 100 } }, true)
        p:send("ACTIVATE_SCENE", { SCENE_ID = 8 })
        local seen = { [true] = false, [false] = false }
        for _ = 1, math.ceil(step * 8 / 100) do
          h.clock.run(100)
          seen[h.device.state().on == true] = true
        end
        T.check(name .. ": the device was on and off while it ran", seen[true] and seen[false], T.show(seen))
        p:send("DEACTIVATE_SCENE", { SCENE_ID = 8 })
        h.clock.run(ms)
        local held = h.device.state().on
        h.clock.run(3000)
        T.eq(name .. ": deactivated, it stays as it was left", h.device.state().on, held)
        finish(h)
      end)
    end
  end

  if dims then
    T.section(name .. ": Min and Max On place the levels on the device's line")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      p:send("SET_MIN_ON_LEVEL", { LEVEL = 20 })
      p:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
      p:send("SET_LEVEL", { LEVEL = 100 })
      h.clock.run(ms)
      T.check(
        name .. ": 100 is the device at 80 %",
        math.abs(h.device.state().level - 0.8) <= 0.01,
        T.show(h.device.state())
      )
      T.eq(name .. ": and the proxy shows 100", p.level, 100)
      p:send("SET_LEVEL", { LEVEL = 1 })
      h.clock.run(ms)
      T.check(
        name .. ": 1 is the device at 20 %",
        math.abs(h.device.state().level - 0.2) <= 0.01,
        T.show(h.device.state())
      )
      p:send("SET_MIN_ON_LEVEL", { LEVEL = 1 })
      p:send("SET_MAX_ON_LEVEL", { LEVEL = 100 })
      h.clock.run(ms)
      finish(h)
    end)
  end

  T.section(name .. ": a lost connection reads offline and off; back, it shows the device")
  C.case(T, name, function()
    local h = fresh(rig)
    local p = h.proxy
    p:send("ON")
    h.clock.run(ms)
    p:mark()
    h.device.drop()
    h.clock.run(ms)
    T.eq(name .. ": ONLINE_CHANGED false", on(p.online), false)
    T.eq(name .. ": and off", p.level, 0)
    if links then
      T.eq(name .. ": the On link's LED is off", on(p.leds[links.top]), false)
    end
    p:mark()
    h.device.back()
    h.clock.run(ms)
    T.eq(name .. ": back online", on(p.online), true)
    T.eq(name .. ": the proxy shows the device", p.level, percent(h))
    T.eq(name .. ": no error was logged", h.errors, {})
    finish(h)
  end)

  T.section(name .. ": after a loss and after Reset Driver, the device's report is taken as it is")
  C.case(T, name, function()
    local h = fresh(rig)
    local p = h.proxy
    p:send(dims and "SET_LEVEL" or "ON", dims and { LEVEL = 37 } or nil)
    h.clock.run(ms)
    h.device.drop()
    h.clock.run(ms)
    h.device.back()
    h.clock.run(ms)
    T.eq(name .. ": back from a loss, the proxy shows the device", p.level, percent(h))
    h.light:reset()
    h.clock.run(ms)
    T.eq(name .. ": after Reset Driver, online again", on(p.online), true)
    T.eq(name .. ": and the proxy shows the device", p.level, percent(h))
    T.eq(name .. ": no error was logged", h.errors, {})
    finish(h)
  end)

  if probe.suspends then
    T.section(name .. ": a connection stopped on purpose reads offline and keeps its level")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      p:send("ON")
      h.clock.run(ms)
      local level = p.level
      h.device.suspend()
      h.clock.run(ms)
      T.eq(name .. ": ONLINE_CHANGED false", on(p.online), false)
      T.eq(name .. ": the level is kept", p.level, level)
      h.device.resume()
      h.clock.run(ms)
      T.eq(name .. ": back online", on(p.online), true)
      T.eq(name .. ": the proxy shows the device", p.level, percent(h))
      finish(h)
    end)
  end

  T.section(name .. ": another hand's change shows, during a ramp and outside one")
  C.case(T, name, function()
    local h = fresh(rig)
    local p = h.proxy
    if dims then
      p:send("SET_LEVEL", { LEVEL = 30 })
      h.clock.run(ms)
      h.device.set({ on = true, level = 0.7 })
      h.clock.run(ms)
      T.eq(name .. ": a level from another hand outside a ramp shows", p.level, percent(h))
    end
    if ramps then
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 6000 })
      h.clock.run(2000)
      h.device.set({ on = true, level = 0.5 })
      h.clock.run(ms + 6000)
      T.eq(name .. ": one during a ramp shows by the window's end", p.level, percent(h))
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 6000 })
      h.clock.run(2000)
      h.device.set({ on = false })
      h.clock.run(ms + 6000)
      T.eq(name .. ": an off during a ramp shows by the window's end", p.level, 0)
    end
    p:send("ON")
    h.clock.run(ms)
    local stale = p.level
    h.device.set({ on = false })
    h.clock.run(ms)
    T.eq(name .. ": an off from another hand shows", p.level, 0)
    p:mark()
    if dims then
      -- Back on at a level the device never reported, so only a read can show it.
      h.device.set({ on = true, level = (stale or 0) >= 50 and 0.2 or 0.8 }, true)
    else
      h.device.set({ on = true })
    end
    h.clock.run(ms)
    T.eq(name .. ": an on after another hand's off shows, with its level", p.level, percent(h))
    if dims then
      local told = {}
      for _, n in ipairs(p.notes) do
        if n.cmd == "LIGHT_BRIGHTNESS_CHANGED" or n.cmd == "LIGHT_BRIGHTNESS_CHANGING" then
          told[#told + 1] = n.params.LIGHT_BRIGHTNESS_CURRENT
        end
      end
      local shown = false
      for _, level in ipairs(told) do
        shown = shown or level == stale
      end
      T.check(name .. ": and never at the level it went off at", not shown, T.show({ stale = stale, told = told }))
    end
    finish(h)
  end)

  T.section(name .. ": a controller restart tells the brightness and color once, where the device is")
  C.case(T, name, function()
    local h = fresh(rig)
    local p = h.proxy
    p:send(dims and "SET_LEVEL" or "ON", dims and { LEVEL = 60 } or nil)
    h.clock.run(ms)
    if hasColor then
      p:send("SET_COLOR_TARGET", colorParams(colorFor(device, 0.6, 0.3, 2700), 0))
      h.clock.run(ms)
    end
    h = restart(rig, h)
    p = h.proxy
    T.eq(name .. ": online again", on(p.online), true)
    T.eq(name .. ": one Brightness Changed", p:count("LIGHT_BRIGHTNESS_CHANGED"), 1)
    T.eq(name .. ": at the device's level", p.level, percent(h))
    if hasColor then
      T.eq(name .. ": one Color Changed", p:count("LIGHT_COLOR_CHANGED"), 1)
      T.check(name .. ": in the device's color", sameXY(p.color, xyOf(h.device.state().color)), T.show(p.color))
    end
    finish(h)
  end)

  if hasColor and device.colorWhileOff == "hold" then
    T.section(name .. ": a color held while off survives a controller restart, and the next On has it")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      local held = colorFor(device, 0.6, 0.3, 2700)
      colorOnMode(p, nil)
      p:send("OFF")
      h.clock.run(ms)
      p:send("SET_COLOR_TARGET", colorParams(held, 0))
      h.clock.run(ms)
      T.eq(name .. ": the device stays off", h.device.state().on, false)
      h = restart(rig, h)
      p = h.proxy
      p:send("ON")
      h.clock.run(ms)
      local color = xyOf(h.device.state().color)
      T.check(name .. ": the next On comes on in the held color", sameXY(color, held), T.show(color))
      T.check(name .. ": as the proxy shows", sameXY(shownXY(p.color), held), T.show(p.color))
      finish(h)
    end)
  end

  if rig.rest then
    T.section(name .. ": a command the device rests apart from is told once, where the device rests")
    C.case(T, name, function()
      local h = fresh(rig)
      local p = h.proxy
      p:mark()
      rig.rest(h)
      h.clock.run(ms)
      local levels, colors = p:count("LIGHT_BRIGHTNESS_CHANGED"), p:count("LIGHT_COLOR_CHANGED")
      T.check(name .. ": the rest is told, each aspect once", levels <= 1 and colors <= 1 and levels + colors >= 1, {
        levels = levels,
        colors = colors,
      })
      T.eq(name .. ": at the level the device rests at", p.level, percent(h))
      local rested = xyOf(h.device.state().color)
      if rested then
        T.check(name .. ": in the color the device rests in", sameXY(shownXY(p.color), rested), T.show(p.color))
      end
      finish(h)
    end)
  end
end

return C
