--- A fake Light V2 proxy for tests of a light driver. It records every notify to the proxy and the Button
--- Links, and models what the real proxy derives from them, as measured on dev (tests/light/test_proxy_fake.lua):
--- - LIGHT_STATE follows CHANGING's CURRENT, and Brightness Percent steps along the line once a second.
--- - Previous On is written from the last level told above 0 when the light goes off, and pushed back to
---   the driver as UPDATE_BRIGHTNESS_PRESET.
--- - Its variables hold what it was told: 1001 the level and 1110 its target (none for a light that does not
---   dim), 1200 the color and 1210 its target (as "x,y,mode", six figures each), and 6661 the capabilities.
--- - 6661 lists every capability it holds, but is rewritten only when a notify changes one of the keys that
---   rewrite it, so the others can lag; without dimming it lists the brightness, click and hold rates 0.
--- - A light that does not dim is asked GET_LIGHT_LEVEL inside the ONLINE_CHANGED that brings it online.
--- - A LIGHT_COLOR_CHANGED naming a preset id without its origin is dropped whole.
--- - GET_SETUP is answered from `setup`, or from `newLight` until the proxy is told the light has color.
---
--- It is the driver's library-independent view of the proxy: it knows no lib.light internals.

local P = {}

P.PROXY = 5001
P.LINKS = { top = 300, toggle = 301, bottom = 302 }
--- The proxy's own device id, which C4:GetProxyDevices answers and GET_SETUP is asked of.
P.PROXY_DEVICE = 7001

--- What 6661 lists, in its order.
--- @type string[]
P.CAPABILITY_KEYS = {
  "dimmer",
  "supports_target",
  "supports_brightness_stop",
  "supports_color",
  "supports_color_correlated_temperature",
  "supports_color_stop",
  "brightness_rate_min",
  "brightness_rate_max",
  "color_correlated_temperature_min",
  "color_correlated_temperature_max",
  "color_rate_behavior",
  "color_rate_min",
  "color_rate_max",
  "has_extras",
  "click_rate_min",
  "click_rate_max",
  "hold_rate_min",
  "hold_rate_max",
  "cold_start",
  "supports_color_cycling",
  "advanced_scene_support",
  "hide_proxy_properties",
  "hide_proxy_commands",
  "hide_proxy_events",
  "hide_proxy_conditionals_loops",
}

--- The order the proxy takes a notify's capabilities in, and whether a change to each rewrites 6661.
--- @type {[1]: string, [2]: boolean}[]
P.TAKEN = {
  { "dimmer", true },
  { "supports_target", true },
  { "supports_color", true },
  { "supports_color_correlated_temperature", true },
  { "brightness_rate_min", false },
  { "brightness_rate_max", false },
  { "has_extras", true },
  { "cold_start", true },
  { "supports_brightness_stop", false },
  { "supports_color_stop", false },
  { "color_rate_behavior", true },
  { "color_rate_min", true },
  { "color_rate_max", true },
  { "color_correlated_temperature_min", true },
  { "color_correlated_temperature_max", true },
}

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"

--- A GET_SETUP answer from test/light_setup, as the proxy gave it on 4.3.0.
--- @param name string The file's name, as "setup-607.xml".
--- @return string xml
function P.setupFile(name)
  local f = assert(io.open(HERE .. "light_setup/" .. name, "rb"))
  local xml = f:read("*a")
  f:close()
  return xml
end

--- @class FakeProxyNote
--- @field at integer
--- @field binding integer
--- @field cmd string
--- @field params table<string, any>

--- @class FakeProxyRamp
--- @field from number|nil
--- @field to number|nil
--- @field rate number|nil
--- @field at integer

--- @class FakeProxyColor
--- @field x number
--- @field y number
--- @field mode integer

--- @class FakeProxyOptions
--- @field setup string|nil GET_SETUP's answer.
--- @field newLight string|nil GET_SETUP's answer until the proxy is told the light has color.
--- @field links LightLinks|false|nil The Button Link bindings; false for none. Default P.LINKS.
--- @field variables table<integer, string>|nil What the proxy's variables hold at the start, as after a
---   controller restart. A 6661 among them is what the proxy holds.
--- @field capabilities table<string, string>|nil driver.xml's capabilities, which the proxy holds until it is
---   told others; every other key holds "False".

--- @class FakeClock
--- @field now fun(): integer
--- @field at fun(ms: integer, fn: fun())
--- @field run fun(ms: integer)

--- @class FakeProxy
--- @field clock FakeClock
--- @field links LightLinks|false
--- @field notes FakeProxyNote[] Every notify since the mark.
--- @field level number|nil The level last told by CHANGED, or CHANGING's CURRENT.
--- @field lit boolean LIGHT_STATE.
--- @field lastLit number|nil The last level told above 0.
--- @field previousOn number|nil The Previous On preset's level.
--- @field color FakeProxyColor|nil The color last told by CHANGED.
--- @field changing FakeProxyRamp|nil The level CHANGING in force.
--- @field online boolean|nil
--- @field leds table<integer, boolean>
--- @field caps table<string, any>|nil The last DYNAMIC_CAPABILITIES_CHANGED.
--- @field setupReads integer
--- @field vars table<string, {value: string}> The proxy device's variables, by id.
--- @field held table<string, string> The capabilities the proxy holds, which 6661 may lag.
local Proxy = {}
Proxy.__index = Proxy

--- A command to the light, as Director delivers it: a command-keyed RFP first, then the binding's.
--- @param binding integer
--- @param cmd string
--- @param params table<string, any>
local function dispatch(binding, cmd, params)
  local handler = RFP[cmd]
  if type(handler) ~= "function" then
    handler = RFP[binding]
  end
  assert(type(handler) == "function", "no handler for " .. cmd .. " on binding " .. tostring(binding))
  return handler(binding, cmd, params, {})
end

--- @param color FakeProxyColor|nil
--- @return string|nil
local function colorText(color)
  if not color then
    return nil
  end
  return string.format("%g,%g,%d", tonumber(color.x) or 0, tonumber(color.y) or 0, tonumber(color.mode) or 0)
end

--- Install a fake proxy over SendToProxy, the device registry and GET_SETUP.
--- @param clock FakeClock F.virtualClock's clock.
--- @param opts FakeProxyOptions|nil
--- @return FakeProxy
function P.install(clock, opts)
  opts = opts or {}
  local p = setmetatable({ clock = clock, links = opts.links == nil and P.LINKS or opts.links }, Proxy)
  p.setup, p.newLight = opts.setup or "", opts.newLight
  p.colorTold = false
  p.vars = {}
  p:reset()
  for id, value in pairs(opts.variables or {}) do
    p.vars[tostring(id)] = { value = value }
  end
  -- After a restart the proxy shows what its variables hold.
  local level = tonumber(p.vars["1001"] and p.vars["1001"].value)
  if level then
    p.level, p.lit = level, level > 0
    p.lastLit = p.lit and level or nil
  end
  local x, y, mode = tostring(p.vars["1200"] and p.vars["1200"].value or ""):match("^([^,]+),([^,]+),([^,]+)$")
  if x then
    p.color = { x = x, y = y, mode = mode }
  end
  p.held = {}
  for key, value in pairs(opts.capabilities or {}) do
    p.held[key] = value
  end
  local listed = p.vars["6661"] and p.vars["6661"].value or ""
  for _, key in ipairs(P.CAPABILITY_KEYS) do
    p.held[key] = listed:match("<" .. key .. ">([^<]*)</" .. key .. ">") or p.held[key]
  end
  local me = tonumber(C4:GetDeviceID())
  ShimSetDevices({
    [me] = { deviceName = "Light", proxies = { [P.PROXY_DEVICE] = {} } },
    [P.PROXY_DEVICE] = {
      deviceName = "Light",
      driverFileName = "light_v2.c4i",
      protocol = { [me] = {} },
      variables = p.vars,
    },
  })
  ShimSetUIRequest(function(id, request)
    if tonumber(id) == P.PROXY_DEVICE and request == "GET_SETUP" then
      p.setupReads = p.setupReads + 1
      return (not p.colorTold and p.newLight) or p.setup or ""
    end
    return ""
  end)
  p.priorGetDeviceVariable = C4.GetDeviceVariable
  C4.GetDeviceVariable = function(_, deviceId, variableId)
    return C4:GetVariable(deviceId, variableId)
  end
  p.prior = C4.SendToProxy
  C4.SendToProxy = function(self, id, cmd, params, ...)
    p:_heard(id, cmd, params)
    return p.prior(self, id, cmd, params, ...)
  end
  return p
end

--- Forget what was told, as at a fresh load of the proxy. Its variables are cleared too.
function Proxy:reset()
  self.notes = {}
  self.level = nil
  self.lit = false
  self.lastLit = nil
  self.previousOn = nil
  self.color = nil
  self.changing = nil
  self.online = nil
  self.leds = {}
  self.setupReads = 0
  self.caps = nil
  self.held = {}
  for id in pairs(self.vars) do
    self.vars[id] = nil
  end
end

--- Clear the record of notifies, keeping what the proxy derived.
function Proxy:mark()
  self.notes = {}
  self.setupReads = 0
end

--- @private
--- @param id string
--- @param value any
function Proxy:_var(id, value)
  if value == nil then
    self.vars[id] = nil
  else
    self.vars[id] = { value = tostring(value) }
  end
end

--- Whether the proxy treats the light as one that dims: unless 6661 says it does not.
--- @return boolean
function Proxy:dims()
  local listed = self.vars["6661"] and self.vars["6661"].value or ""
  return not listed:find("<dimmer>False</dimmer>", 1, true)
end

--- Write 6661 from what the proxy holds.
--- @private
function Proxy:_listCaps()
  local dims = self.held.dimmer == "True"
  local parts = {}
  for _, key in ipairs(P.CAPABILITY_KEYS) do
    local value = self.held[key] or "False"
    if not dims and key:match("^%l+_rate_m%l%l$") and not key:match("^color") then
      value = "0"
    end
    parts[#parts + 1] = string.format("<%s>%s</%s>", key, value, key)
  end
  self:_var("6661", "<DynamicCapabilities>" .. table.concat(parts) .. "</DynamicCapabilities>")
end

--- Take a DYNAMIC_CAPABILITIES_CHANGED as the proxy does: key by key in its order, rewriting 6661 at each change
--- to a key that rewrites it.
--- @private
--- @param told table<string, any>
function Proxy:_takeCaps(told)
  if not self.vars["6661"] then
    self:_listCaps()
  end
  for _, taken in ipairs(P.TAKEN) do
    local key, rewrites, value = taken[1], taken[2], told[taken[1]]
    if value ~= nil then
      value = type(value) == "boolean" and (value and "True" or "False") or tostring(value)
      if value ~= self.held[key] then
        self.held[key] = value
        if rewrites then
          self:_listCaps()
        end
      end
    end
  end
end

--- @private
function Proxy:_heard(id, cmd, params)
  local links = self.links or {}
  local now = self.clock.now()
  if id == links.top or id == links.toggle or id == links.bottom then
    if cmd == "MATCH_LED_STATE" then
      self.leds[id] = params.STATE
    end
    self.notes[#self.notes + 1] = { at = now, binding = id, cmd = cmd, params = params }
    return
  end
  if id ~= P.PROXY then
    return
  end
  self.notes[#self.notes + 1] = { at = now, binding = id, cmd = cmd, params = params }
  local wasLit = self.lit
  if cmd == "LIGHT_BRIGHTNESS_CHANGED" then
    -- A level that is no number is kept as it came, unlit, for a check to name rather than raise here.
    local level = tonumber(params.LIGHT_BRIGHTNESS_CURRENT)
    self.level, self.changing = level, nil
    self.lit = (level or 0) > 0
    if self.lit then
      self.lastLit = level
    end
    self:_var("1001", level)
    self:_var("1110", self:dims() and level or nil)
  elseif cmd == "LIGHT_BRIGHTNESS_CHANGING" then
    local current = tonumber(params.LIGHT_BRIGHTNESS_CURRENT)
    local target = tonumber(params.LIGHT_BRIGHTNESS_TARGET)
    self.changing = { from = current, to = target, rate = tonumber(params.RATE), at = now }
    self.level = current
    self.lit = (current or 0) > 0
    if self.lit then
      self.lastLit = current
    end
    self:_var("1001", current)
    self:_var("1110", self:dims() and target or nil)
  elseif cmd == "LIGHT_COLOR_CHANGED" then
    if params.LIGHT_COLOR_CURRENT_PRESET_ID ~= nil and params.LIGHT_COLOR_CURRENT_PRESET_ORIGIN == nil then
      return
    end
    self.color = {
      x = params.LIGHT_COLOR_CURRENT_X,
      y = params.LIGHT_COLOR_CURRENT_Y,
      mode = params.LIGHT_COLOR_CURRENT_COLOR_MODE,
    }
    self.colorChanging = nil
    self:_var("1200", colorText(self.color))
    self:_var("1210", colorText(self.color))
  elseif cmd == "LIGHT_COLOR_CHANGING" then
    local current = {
      x = params.LIGHT_COLOR_CURRENT_X,
      y = params.LIGHT_COLOR_CURRENT_Y,
      mode = params.LIGHT_COLOR_CURRENT_COLOR_MODE,
    }
    local target = {
      x = params.LIGHT_COLOR_TARGET_X,
      y = params.LIGHT_COLOR_TARGET_Y,
      mode = params.LIGHT_COLOR_TARGET_COLOR_MODE,
    }
    self.colorChanging = { from = current, to = target, at = now }
    self:_var("1200", colorText(current))
    self:_var("1210", colorText(target))
  elseif cmd == "ONLINE_CHANGED" then
    local was = self.online
    self.online = params.STATE
    if params.STATE and not was and not self:dims() then
      dispatch(P.PROXY, "GET_LIGHT_LEVEL", {})
    end
  elseif cmd == "DYNAMIC_CAPABILITIES_CHANGED" then
    self.caps = params
    self.colorTold = self.colorTold
      or params.supports_color == true
      or params.supports_color_correlated_temperature == true
    self:_takeCaps(params)
  end
  if wasLit and not self.lit and self.lastLit then
    -- The proxy rewrites its Previous On preset at every off, and tells the driver.
    local keep = self.lastLit
    self.previousOn = keep
    self.clock.at(1, function()
      dispatch(
        P.PROXY,
        "UPDATE_BRIGHTNESS_PRESET",
        { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = keep }
      )
    end)
  end
end

--- Every notify of one command to the proxy since the mark, in order.
--- @param cmd string
--- @return table<string, any>[] params
function Proxy:told(cmd)
  local out = {}
  for _, n in ipairs(self.notes) do
    if n.cmd == cmd and n.binding == P.PROXY then
      out[#out + 1] = n.params
    end
  end
  return out
end

--- The last notify of one command to the proxy since the mark.
--- @param cmd string
--- @return table<string, any>|nil params
function Proxy:last(cmd)
  local told = self:told(cmd)
  return told[#told]
end

--- Every notify of one command to a Button Link since the mark, in order.
--- @param binding integer
--- @param cmd string
--- @return table<string, any>[] params
function Proxy:toldLink(binding, cmd)
  local out = {}
  for _, n in ipairs(self.notes) do
    if n.cmd == cmd and n.binding == binding then
      out[#out + 1] = n.params
    end
  end
  return out
end

--- The levels told by CHANGED since the mark.
--- @return number[]
function Proxy:changed()
  local out = {}
  for _, p in ipairs(self:told("LIGHT_BRIGHTNESS_CHANGED")) do
    out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT
  end
  return out
end

--- The commands of each notify to the proxy since the mark, in order.
--- @return string[]
function Proxy:said()
  local out = {}
  for _, n in ipairs(self.notes) do
    if n.binding == P.PROXY then
      out[#out + 1] = n.cmd
    end
  end
  return out
end

--- How many notifies of one command since the mark.
--- @param cmd string
--- @return integer
function Proxy:count(cmd)
  return #self:told(cmd)
end

--- Brightness Percent as the proxy shows it now: stepped along the line once a second after a CHANGING.
--- @return number|nil
function Proxy:percent()
  local c = self.changing
  if not c then
    return self.level
  end
  if not c.rate or c.rate <= 0 or not c.from or not c.to then
    return c.to
  end
  local steps = math.floor((self.clock.now() - c.at) / 1000)
  local p = math.min(1, steps * 1000 / c.rate)
  return math.floor(c.from + (c.to - c.from) * p + 0.5)
end

--- Where the proxy shows the light heading: CHANGING's target, else the level told.
--- @return number|nil
function Proxy:target()
  return self.changing and self.changing.to or self.level
end

--- Send the light a proxy command on the proxy binding.
--- @param cmd string
--- @param params table<string, any>|nil
function Proxy:send(cmd, params)
  return dispatch(P.PROXY, cmd, params or {})
end

--- Send a Button Link command (DO_PUSH, DO_CLICK, DO_RELEASE) on one of the links.
--- @param binding integer
--- @param cmd string
function Proxy:link(binding, cmd)
  return dispatch(binding, cmd, {})
end

--- The Control4 app's On: SET_BRIGHTNESS_TARGET at the on level over 750 ms, then the on color about
--- 18 ms later as SET_COLOR_TARGET, with its preset id and origin.
--- @param level integer
--- @param color {x: number, y: number, mode: integer|nil, preset: integer|nil, origin: integer|nil}|nil
function Proxy:appOn(level, color)
  self:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level, RATE = 750 })
  if color then
    self.clock.at(18, function()
      self:send("SET_COLOR_TARGET", {
        LIGHT_COLOR_TARGET_X = color.x,
        LIGHT_COLOR_TARGET_Y = color.y,
        LIGHT_COLOR_TARGET_MODE = color.mode or 0,
        LIGHT_COLOR_TARGET_PRESET_ID = color.preset,
        LIGHT_COLOR_TARGET_PRESET_ORIGIN = color.origin,
        LIGHT_COLOR_TARGET_COLOR_RATE = 750,
      })
    end)
  end
end

--- Push an on mode or a rate default, as the proxy does: only when it changes.
--- @param cmd string
--- @param params table<string, any>
--- @return boolean pushed
function Proxy:push(cmd, params)
  self.pushed = self.pushed or {}
  local key = {}
  for k, v in pairs(params) do
    key[#key + 1] = tostring(k) .. "=" .. tostring(v)
  end
  table.sort(key)
  local text = table.concat(key, ",")
  if self.pushed[cmd] == text then
    return false
  end
  self.pushed[cmd] = text
  self:send(cmd, params)
  return true
end

--- Put SendToProxy, GetDeviceVariable, the device registry and the GET_SETUP answer back.
function Proxy:restore()
  C4.SendToProxy = self.prior
  C4.GetDeviceVariable = self.priorGetDeviceVariable
  ShimSetUIRequest(nil)
  ShimResetDevices()
end

return P
