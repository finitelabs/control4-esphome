--- A fake Light V2 proxy for tests of a light driver. It records every notify to the proxy and the Button
--- Links, and models what the real proxy derives from them (measured on 4.3.0):
--- - LIGHT_STATE follows CHANGING's CURRENT, and Brightness Percent steps along the line once a second.
--- - Previous On is written from the last level told above 0 when the light goes off, and pushed back to
---   the driver as UPDATE_BRIGHTNESS_PRESET.
--- - Its variables hold what it was told: 1001 the level and 1110 its target, 1200 the color and 1210 its
---   target (as "x,y,mode"), and 6661 the capabilities, without the rate keys it never reflects.
--- - GET_SETUP is answered from `setup`, or from `newLight` until the proxy is told the light has color.
---
--- It is the driver's library-independent view of the proxy: it knows no lib.light internals.

local P = {}

P.PROXY = 5001
P.LINKS = { top = 300, toggle = 301, bottom = 302 }
--- The proxy's own device id, which C4:GetProxyDevices answers and GET_SETUP is asked of.
P.PROXY_DEVICE = 7001

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
---   controller restart.

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
  return string.format("%s,%s,%s", tostring(color.x), tostring(color.y), tostring(color.mode or 0))
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

--- @private
--- @param caps table<string, any>
function Proxy:_capsVar(caps)
  local keys = {}
  for key in pairs(caps) do
    if not (key:match("_rate_min$") or key:match("_rate_max$")) then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local v = caps[key]
    if type(v) == "boolean" then
      v = v and "True" or "False"
    end
    parts[#parts + 1] = string.format("<%s>%s</%s>", key, tostring(v), key)
  end
  self:_var("6661", "<DynamicCapabilities>" .. table.concat(parts) .. "</DynamicCapabilities>")
end

--- @private
function Proxy:_heard(id, cmd, params)
  local links = self.links or {}
  local now = self.clock.now()
  if id == links.top or id == links.toggle or id == links.bottom then
    if cmd == "MATCH_LED_STATE" then
      self.leds[id] = params.STATE
      self.notes[#self.notes + 1] = { at = now, binding = id, cmd = cmd, params = params }
    end
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
    self:_var("1110", level)
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
    self:_var("1110", target)
  elseif cmd == "LIGHT_COLOR_CHANGED" then
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
    self.online = params.STATE
  elseif cmd == "DYNAMIC_CAPABILITIES_CHANGED" then
    self.caps = params
    self.colorTold = self.colorTold
      or params.supports_color == true
      or params.supports_color_correlated_temperature == true
    self:_capsVar(params)
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
