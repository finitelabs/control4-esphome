--- The light library: one Light V2 light over a driver's adapter. lib.light.types is the contract.
---
--- Each state machine is a part that owns its state, its rules and its timers: Motion (the ramps and the
--- walk), Ledger (reports against commands), Buttons, Scenes, Settings, Picks and LightProxy (what the
--- proxy was told). Light routes each event to its part, then runs the one follow-up: send the commands
--- the part made, record them in the Ledger, tell the proxy what changed.
---
--- A new behavior goes into a part. Light gains a line only for a new event, and the follow-up never
--- changes.
---
--- A connection's states, and what moves it:
---   made      --start-->                        offline (the proxy is told so, and the device asked)
---   offline   --a report, after declare-->      online (ONLINE_CHANGED, then the capabilities)
---   online    --lost(suspended), reset-->       offline (the run ends: ramps, windows, picks, presses, steps)
---   offline   --declare-->                      offline, with the facts stored for the next report
--- Commands reach the adapter only while online. A report before start, or one made inside send or refresh,
--- waits and is taken in order once the library is free.

local log = require("lib.logging")
local Types = require("lib.light.types")
local Color = require("lib.light.color")
local Caps = require("lib.light.caps")
local OnColor = require("lib.light.oncolor")
local Settings = require("lib.light.settings")
local Picks = require("lib.light.picks")
local Buttons = require("lib.light.buttons")
local Scenes = require("lib.light.scenes")
local Motion = require("lib.light.motion")
local Ledger = require("lib.light.ledger")
local LightProxy = require("lib.light.proxy")
local Handlers = require("lib.light.handlers")
-- The pure modules adapters may use, required here so the build bundles them with every light.
require("lib.light.color")
require("lib.light.range")

local ADAPTER_METHODS = { "send", "refresh", "show" }

--- @type table<LightReportKind, boolean>
local REPORT_KINDS = { push = true, moving = true, final = true, seed = true }

-- The aspects each intent moves: a scene's steps end at a level or power another source moved, not a color.
--- @type table<LightIntentKind, LightAspect[]>
local MOVES = {
  on = { "on", "level" },
  off = { "on", "level" },
  toggle = { "on", "level" },
  level = { "level" },
  stopLevel = { "level" },
  color = { "color" },
  stopColor = { "color" },
  stop = { "level", "color" },
}

--- A Light V2 light over one adapter.
--- @class Light
--- @field adapter LightAdapter
--- @field profile LightProfile Checked, with its defaults filled.
--- @field device LightDevice|nil The facts in force, checked; nil before the first declare.
--- @field started boolean
--- @field online boolean The connection has reported since start or its last loss.
--- @field inside boolean The library is in a follow-up or a refresh: a report made now waits.
--- @field waiting LightReport[] Reports given before start or inside a follow-up, in order.
--- @field settings LightSettings
--- @field picks LightPicks
--- @field buttons LightButtons
--- @field scenes LightScenes
--- @field motion LightMotion
--- @field ledger LightLedger
--- @field proxy LightProxy
local Light = {}
Light.__index = Light

Light.API = Types.API

--- The lights made in this Lua process, in order. The build reads the one a driver's chunk made, and
--- writes driver.xml's light capabilities from its profile.
--- @type Light[]
Light.made = {}

--- Create the light and own its proxy and link bindings. Call it once, at the driver chunk's top level.
--- @param adapter LightAdapter
--- @param profile LightProfile
--- @return Light
function Light.new(adapter, profile)
  for _, method in ipairs(ADAPTER_METHODS) do
    if type(adapter) ~= "table" or type(adapter[method]) ~= "function" then
      error(string.format("lib.light: Light.new needs an adapter with %s()", method), 2)
    end
  end
  if type(profile) ~= "table" or profile.api ~= Types.API then
    error(
      string.format(
        "lib.light: the profile names API %s and this library is API %d; update the adapter",
        tostring(type(profile) == "table" and profile.api or nil),
        Types.API
      ),
      2
    )
  end
  local checked, errors = Caps.profile(profile)
  if not checked then
    error("lib.light: " .. table.concat(errors, "; "), 2)
  end
  local self = setmetatable({
    adapter = adapter,
    profile = checked,
    started = false,
    online = false,
    inside = false,
    waiting = {},
  }, Light)
  self.settings = Settings.new(checked)
  self.picks = Picks.new()
  self.buttons = Buttons.new(self, self.settings)
  self.scenes = Scenes.new(self, checked)
  self.motion = Motion.new(self)
  self.ledger = Ledger.new(self)
  self.proxy = LightProxy.new(checked, self.settings)
  Handlers.register(self)
  Light.made[#Light.made + 1] = self
  return self
end

-----------------------------------------------------------------------------------------------------
-- The driver's calls
-----------------------------------------------------------------------------------------------------

--- From OnDriverLateInit: read the proxy, tell offline until the device's first report, ask the device.
--- Reports given before it are taken then, in order.
function Light:start()
  self.started = true
  self.settings:readSetup(self.proxy:readSetup())
  self.motion:seed(self.proxy:read())
  self.proxy:offline()
  self:_refresh()
end

--- The facts of the connection: before its first report, and on any change.
--- @param device LightDevice
function Light:declare(device)
  local checked, errors = Caps.device(device, self.profile)
  for _, err in ipairs(errors) do
    log:error("Light:declare: %s", err)
  end
  if not checked or Caps.same(checked, self.device) then
    return
  end
  local before = self.device
  self.device = checked
  self.motion:declare(checked)
  self.ledger:declare(checked)
  self.buttons:declare(checked)
  local cmds = {}
  if before and not Caps.same(before.fade, checked.fade) then
    cmds = self.motion:finishAll()
    self.ledger:closeAll()
  end
  if self.online then
    self.proxy:capabilities(checked)
    self:_followUp(cmds)
  end
end

--- Why a report can't be taken, or nil when it can.
--- @param report LightReport
--- @return string|nil
local function unfit(report)
  if type(report) ~= "table" or not REPORT_KINDS[report.kind] then
    return "it has no known kind"
  end
  if report.on ~= nil and type(report.on) ~= "boolean" then
    return "its on is not a boolean"
  end
  local level = report.level
  if level ~= nil and not (type(level) == "number" and level >= 0 and level <= 1) then
    return "its level is not a number from 0 to 1"
  end
  local color = report.color
  if color ~= nil then
    if
      type(color) ~= "table"
      or type(color.x) ~= "number"
      or type(color.y) ~= "number"
      or not (color.x >= 0 and color.x <= 1 and color.y >= 0 and color.y <= 1)
      or (color.mode ~= "xy" and color.mode ~= "cct")
    then
      return "its color is not an xy from 0 to 1 with a mode"
    end
    if color.kelvin ~= nil and not (type(color.kelvin) == "number" and color.kelvin > 0 and color.kelvin < 100000) then
      return "its Kelvin is out of range"
    end
  end
  return nil
end

--- A report in the forms the light declares: a light with color and no color temperature shows a white as the full
--- color at its point, the form the library sends it in.
--- @param report LightReport
--- @param device LightDevice
--- @return LightReport
local function inForms(report, device)
  local color = report.color
  if not (color and color.mode == Color.CCT and device.color and not device.cct) then
    return report
  end
  local out = {}
  for k, v in pairs(report) do
    out[k] = v
  end
  local x, y, mode = Color.taken(color.x, color.y, Color.CCT, true, false)
  out.color = { x = x, y = y, mode = mode }
  return out
end

--- One device state.
--- @param report LightReport
function Light:report(report)
  local why = unfit(report)
  if why then
    log:error("Light:report: the report is dropped: %s", why)
    return
  end
  if not self.started or self.inside then
    self.waiting[#self.waiting + 1] = report
    return
  end
  if not self.device then
    log:error("Light:report: no device declared, so the report is dropped; declare comes first")
    return
  end
  if not self.online then
    self.online = true
    -- What the proxy shows now is what the connection's first report is weighed against: a ramp the proxy
    -- still runs from before the loss ends there.
    self.motion:seed(self.proxy:read())
    self.proxy:online(self.device)
    -- A new light's setup lists no colors until the proxy has heard its capabilities.
    self.settings:readSetup(self.proxy:readSetup())
  end
  self:_heard(self.ledger:heard(inForms(report, self.device), self.motion:now()))
end

--- The connection is gone. true: stopped on purpose, the proxy keeps the level. false: a loss.
--- @param suspended boolean
function Light:lost(suspended)
  self:_endRun()
  self.online = false
  self.proxy:lost(suspended == true)
end

--- Reset Driver: end the run, tell offline until the next report, ask the device.
function Light:reset()
  self:_endRun()
  self.online = false
  self.proxy:offline()
  self:_refresh()
end

-----------------------------------------------------------------------------------------------------
-- The handlers' entry points
-----------------------------------------------------------------------------------------------------

--- A motion command from the proxy. The proxy hears an answer for what it asked, even when nothing changes.
--- @param intent LightIntent
function Light:command(intent)
  self.proxy:taken(intent)
  self:_followUp(self:_move(intent))
end

--- BUTTON_ACTION, or a link's DO_PUSH, DO_CLICK or DO_RELEASE.
--- @param button integer 0 top, 1 bottom, 2 toggle.
--- @param action integer 0 release after a hold, 1 press, 2 release after a click.
--- @param echo boolean The proxy's own BUTTON_ACTION, which is echoed back; a link's press is not.
function Light:button(button, action, echo)
  self.proxy:pressed(button, action, echo)
  local intent = self.buttons:action(button, action, self.motion:now(), self.motion:view())
  self:_followUp(intent and self:_move(intent) or {})
end

--- A scene command: op is the LightScenes method that takes it.
--- @param op string
--- @param tParams table<string, string>
function Light:scene(op, tParams)
  local intent = self.scenes[op](self.scenes, tParams, self.motion:now())
  self:_followUp(intent and self:_move(intent) or {})
end

--- A setting command: presets, on modes, rates, Min and Max On, button colors.
--- @param strCommand string
--- @param tParams table<string, string>
function Light:setting(strCommand, tParams)
  self.settings:apply(strCommand, tParams)
  self:_followUp({})
end

--- A read the proxy asks: GET_CONNECTED_STATE, GET_LIGHT_LEVEL, REQUEST_BUTTON_COLORS.
--- @param strCommand string
--- @param tParams table<string, string>
--- @param idBinding integer The binding it came on: a link asks for its own button's colors.
function Light:ask(strCommand, tParams, idBinding)
  self.proxy:answer(strCommand, tParams, self.motion:view(), idBinding)
end

-----------------------------------------------------------------------------------------------------
-- The parts' timers
-----------------------------------------------------------------------------------------------------

--- Motion's ramp for an aspect reached its end.
--- @param aspect LightAspect
function Light:_rampEnded(aspect)
  self:_followUp(self.motion:ended(aspect))
end

--- Motion's walk is due its next step.
function Light:_walkStep()
  self:_followUp(self.motion:step(self.settings:forMotion()))
end

--- Ledger's deadline for an aspect.
--- @param aspect LightAspect
function Light:_due(aspect)
  self:_heard(self.ledger:due(aspect, self.motion:now()))
end

--- The wait for what the connection's first report left out ended.
function Light:_awaited()
  self:_heard(self.ledger:awaited())
end

--- A scene's next step is due.
--- @param id integer
function Light:_sceneStep(id)
  local intent = self.scenes:step(id, self.motion:now())
  self:_followUp(intent and self:_move(intent) or {})
end

--- Buttons' 250 ms press gate ended with the button still down.
function Light:_gateEnded()
  local intent = self.buttons:gateEnded(self.motion:now(), self.motion:view())
  self:_followUp(intent and self:_move(intent) or {})
end

-----------------------------------------------------------------------------------------------------
-- Routing
-----------------------------------------------------------------------------------------------------

--- An intent to Motion, after cancelling the parts it did not come from.
--- @private
--- @param intent LightIntent
--- @return LightCommand[]
function Light:_move(intent)
  if intent.source ~= "button" then
    self.buttons:cancel()
  end
  if intent.source ~= "scene" then
    self.scenes:foreign(MOVES[intent.kind])
  end
  self.picks:noted(intent, self.motion:now(), self.settings:forOn())
  self.buttons:noted(intent, self.motion:now())
  self.ledger:taken(intent)
  self.motion:assumeLit(self.ledger:lit())
  return self.motion:command(intent, OnColor.choose(intent, self:_onInputs()), self.settings:forMotion())
end

--- What OnColor.choose reads: plain values from the parts that hold them.
--- @private
--- @return LightOnInputs
function Light:_onInputs()
  return {
    now = self.motion:now(),
    device = self.device,
    settings = self.settings:forOn(),
    picks = self.picks:forOn(),
  }
end

--- The foreign aspects whose running ramp the report ended: only those end a scene's steps.
--- @param before LightNow
--- @param aspects LightAspect[]
--- @return LightAspect[]
local function rampsEnded(before, aspects)
  local ended = {}
  for _, aspect in ipairs(aspects) do
    if (aspect == "color" and before.colorRamping) or (aspect ~= "color" and before.levelRamping) then
      ended[#ended + 1] = aspect
    end
  end
  return ended
end

--- Ledger's verdict on a report or a deadline, carried out.
--- @private
--- @param heard LightHeard
function Light:_heard(heard)
  local before = self.motion:now()
  if #heard.foreign > 0 and (self.device.fade.retimes or self.device.fade.kind == "walk") then
    -- Another client's command restarts every channel of a device that re-times, and ends a fade the library
    -- walks, so no ramp of ours runs on.
    self.motion:haltAll()
  end
  self.motion:settle(heard.settle)
  if heard.form then
    self.motion:reform(heard.form)
  end
  if #heard.foreign > 0 then
    self.scenes:foreign(rampsEnded(before, heard.foreign))
    self.picks:foreign(heard.foreign)
  end
  -- A connection's first word on each aspect is told whatever it is, as at every start and reconnect.
  self.proxy:resay(heard.first or {})
  self:_followUp({})
  if heard.ask then
    self:_refresh()
  end
end

--- The one follow-up, always in this order: each command to the adapter, its rest into it, into the
--- Ledger; then, while online, what changed to the proxy, and to the adapter's show. Offline the proxy
--- hears nothing until the next connection's first report. Reports the adapter makes meanwhile wait until
--- it ends.
--- @private
--- @param cmds LightCommand[]
function Light:_followUp(cmds)
  self.inside = true
  -- The proxy is told the light as of the follow-up's start: on a controller C4:GetTime moves on while a command
  -- is sent, and a ramp it starts is told from where it starts.
  local t = C4:GetTime()
  for _, cmd in ipairs(cmds) do
    local ok, rest = pcall(self.adapter.send, self.adapter, cmd)
    if not ok then
      log:error("Light: adapter:send raised: %s", tostring(rest))
      rest = nil
    end
    local rested = self.motion:sent(cmd, rest)
    self.ledger:sent(rested, {
      on = self.motion:landing("on"),
      level = self.motion:landing("level"),
      color = self.motion:landing("color"),
    })
  end
  -- A command of ours that sets the power ends another hand's on waiting for its level: the walk's next step
  -- takes the light as the wire left it.
  self.motion:assumeLit(self.ledger:lit())
  if self.online then
    self.proxy:sync(self.motion:view(t), self.ledger.awaiting, t)
    local shown = self.proxy:shown()
    if shown then
      local ok, err = pcall(self.adapter.show, self.adapter, shown)
      if not ok then
        log:error("Light: adapter:show raised: %s", tostring(err))
      end
    end
  end
  self.inside = false
  self:_takeWaiting()
end

--- Ask the device for its whole state. Reports it makes meanwhile wait until it returns.
--- @private
function Light:_refresh()
  local was = self.inside
  self.inside = true
  local ok, err = pcall(self.adapter.refresh, self.adapter)
  if not ok then
    log:error("Light: adapter:refresh raised: %s", tostring(err))
  end
  self.inside = was
  if not was then
    self:_takeWaiting()
  end
end

--- Take the reports that waited, in order.
--- @private
function Light:_takeWaiting()
  while self.started and not self.inside and #self.waiting > 0 do
    self:report(table.remove(self.waiting, 1))
  end
end

--- The run replaced: ramps, windows, picks, presses and scene steps.
--- @private
function Light:_endRun()
  self.motion:reset()
  self.ledger:reset()
  self.picks:reset()
  self.buttons:reset()
  self.scenes:reset()
end

return Light
