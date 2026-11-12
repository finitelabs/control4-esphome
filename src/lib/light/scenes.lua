--- Advanced Lighting Scenes: the scenes the proxy pushes, kept under the `scenes` key, and the one run
--- of their steps. Each step becomes one intent for Motion. The step timer is timed from each step's own
--- delay and rate, never from the device's fade.

local log = require("lib.logging")
local persist = require("lib.persist")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

-- The key every release stored the scenes under, in the shape below.
local P_SCENES = "scenes"

-- The proxy's color mode for a color temperature.
local COLOR_MODE_CCT = 1

--- One step of a scene, as stored.
--- @class LightSceneStep
--- @field delay integer Ms to wait before the step.
--- @field brightnessRate integer
--- @field colorRate integer
--- @field level integer|nil C4 level 0-100.
--- @field levelEnabled boolean
--- @field colorEnabled boolean
--- @field colorX number|nil
--- @field colorY number|nil
--- @field colorMode integer|nil The proxy's color mode: 0 full color, 1 a color temperature.

--- One scene, as stored.
--- @class LightScene
--- @field elements LightSceneStep[]
--- @field flash boolean
--- @field ignoreRamp boolean
--- @field fromGroup boolean
--- @field state integer

--- What the timer does when it fires: take the step it waited for, or move to the next one.
--- @alias LightSceneDue "apply"|"advance"

--- The one scene running.
--- @class LightSceneRun
--- @field id integer
--- @field idx integer The step taken or waited for, 0 before the first.
--- @field due LightSceneDue
--- @field waited boolean This pass of a flash scene waited on a delay or a rate.

--- @class LightScenes
--- @field light Light
--- @field profile LightProfile
--- @field run LightSceneRun|nil
--- @field generation integer Bumped by every stop, so a timer from an earlier run takes nothing.
--- @field ramping boolean A Ramp Scene Up or Down sent from here still runs, which Stop Scene Ramp stops.
local Scenes = {}
Scenes.__index = Scenes

--- @param light Light
--- @param profile LightProfile
--- @return LightScenes
function Scenes.new(light, profile)
  return setmetatable({ light = light, profile = profile, run = nil, generation = 0, ramping = false }, Scenes)
end

--- @return table<string, LightScene>
local function stored()
  return persist:get(P_SCENES, {})
end

--- @param scenes table<string, LightScene>
local function store(scenes)
  persist:set(P_SCENES, scenes)
end

--- @param id integer
--- @return string
local function timerName(id)
  return "Light.Scene." .. tostring(id)
end

--- @param tParams table<string, string>|nil
--- @return integer|nil
local function sceneId(tParams)
  return tointeger(Select(tParams, "SCENE_ID"))
end

--- A scene's <element> XML as steps. A step that sets nothing and waits nothing is dropped.
--- @param elementsXml string|nil
--- @return LightSceneStep[]
local function parseElements(elementsXml)
  local steps = {}
  if IsEmpty(elementsXml) then
    return steps
  end
  local parsed = ParseXml("<root>" .. elementsXml .. "</root>")
  local list = Select(parsed, "root", "element") or {}
  if not IsList(list) then
    list = { list }
  end
  for _, el in ipairs(list) do
    if type(el) == "table" then
      local rawLevelEnabled = Select(el, "brightnessEnabled")
      local rawColorEnabled = Select(el, "colorEnabled")
      --- @type LightSceneStep
      local step = {
        delay = tointeger(Select(el, "delay")) or 0,
        brightnessRate = tointeger(Select(el, "brightnessRate") or Select(el, "rate")) or 0,
        colorRate = tointeger(Select(el, "colorRate")) or 0,
        level = tointeger(Select(el, "brightness") or Select(el, "level")),
        levelEnabled = toboolean(rawLevelEnabled),
        colorEnabled = toboolean(rawColorEnabled),
        colorX = tonumber(Select(el, "colorX")),
        colorY = tonumber(Select(el, "colorY")),
        colorMode = tointeger(Select(el, "colorMode")),
      }
      -- An older schema puts <level> at the element root with no wrapper. Only promote when the wrapper is
      -- truly absent: toboolean reads nil and "false" alike.
      if rawLevelEnabled == nil and rawColorEnabled == nil and step.level ~= nil then
        step.levelEnabled = true
      end
      if step.colorRate == 0 and step.brightnessRate > 0 then
        step.colorRate = step.brightnessRate
      end
      if step.levelEnabled or step.colorEnabled or step.delay > 0 then
        steps[#steps + 1] = step
      end
    end
  end
  return steps
end

--- How long a step takes: the longer of its two rates.
--- @param step LightSceneStep
--- @return integer
local function stepMs(step)
  return math.max(0, step.brightnessRate or 0, step.colorRate or 0)
end

--- The intent a step asks for: its level, its color, or both in one command. Nil for a step that only waits.
--- @param step LightSceneStep
--- @return LightIntent|nil
local function stepIntent(step)
  local level = step.levelEnabled and step.level or nil
  --- @type LightColor|nil
  local color = nil
  if step.colorEnabled and step.colorX and step.colorY then
    color = { x = step.colorX, y = step.colorY, mode = step.colorMode == COLOR_MODE_CCT and "cct" or "xy" }
  end
  if level == nil and color == nil then
    return nil
  end
  return {
    kind = level ~= nil and "level" or "color",
    level = level and math.max(0, math.min(100, level)) or nil,
    color = color,
    rateMs = stepMs(step),
    source = "scene",
  }
end

--- Arm the run's timer. Its function takes nothing once a stop has bumped the generation.
--- @private
--- @param ms integer
function Scenes:_arm(ms)
  local id, generation, light = self.run.id, self.generation, self.light
  -- Director refuses a 0 ms timer, so a step with no rate waits the shortest one it takes.
  SetTimer(timerName(id), math.max(1, ms), function()
    if generation == self.generation then
      light:_sceneStep(id)
    end
  end, false)
end

--- The scene the run plays, or nil once it has gone.
--- @private
--- @return LightScene|nil
function Scenes:_scene()
  return self.run and stored()[tostring(self.run.id)] or nil
end

--- Move to the next step: wait out its delay, or take it now. A flash scene starts over, unless a whole
--- pass took no time, which would loop at once forever.
--- @private
--- @return LightIntent|nil
function Scenes:_advance()
  local run, scene = self.run, self:_scene()
  if not scene then
    self:stopSteps()
    return nil
  end
  local idx = run.idx + 1
  if idx > #scene.elements then
    if scene.flash and self.profile.flash and run.waited then
      idx, run.waited = 1, false
    else
      self:stopSteps()
      return nil
    end
  end
  run.idx = idx
  local delay = math.max(0, scene.elements[idx].delay or 0)
  if delay > 0 then
    run.waited, run.due = true, "apply"
    self:_arm(delay)
    return nil
  end
  return self:_apply()
end

--- Take the run's step, and time the move to the next from the step's own rate.
--- @private
--- @return LightIntent|nil
function Scenes:_apply()
  local run, scene = self.run, self:_scene()
  if not scene or not scene.elements[run.idx] then
    self:stopSteps()
    return nil
  end
  local step = scene.elements[run.idx]
  local ms = stepMs(step)
  if ms > 0 then
    run.waited = true
  end
  run.due = "advance"
  self:_arm(ms)
  -- A step's own command replaces a scene ramp still running.
  self.ramping = false
  return stepIntent(step)
end

--- End the run: no later step moves the light. A step's ramp in flight is Motion's and runs on.
function Scenes:stopSteps()
  self.generation = self.generation + 1
  if self.run then
    CancelTimer(timerName(self.run.id))
    self.run = nil
  end
end

--- Another hand moved the light. A level or an on from elsewhere ends the run; a color does not.
--- @param aspects LightAspect[]
function Scenes:foreign(aspects)
  for _, aspect in ipairs(aspects) do
    if aspect == "level" or aspect == "on" then
      self:stopSteps()
      self.ramping = false
      return
    end
  end
end

--- The run is replaced: the light was lost or reset.
function Scenes:reset()
  self:stopSteps()
  self.ramping = false
end

--- The run's timer fired for scene `id`.
--- @param id integer
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:step(id, _now)
  local run = self.run
  if not run or run.id ~= id then
    return nil
  end
  if run.due == "apply" then
    return self:_apply()
  end
  return self:_advance()
end

--- PUSH_SCENE: store a scene's steps.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return nil
function Scenes:push(tParams, _now)
  local id = sceneId(tParams)
  if id == nil then
    return nil
  end
  if self.run and self.run.id == id then
    self:stopSteps()
  end
  local scenes = stored()
  scenes[tostring(id)] = {
    elements = parseElements(Select(tParams, "ELEMENTS")),
    flash = toboolean(Select(tParams, "FLASH")),
    ignoreRamp = toboolean(Select(tParams, "IGNORE_RAMP")),
    fromGroup = toboolean(Select(tParams, "FROM_GROUP")),
    state = 0,
  }
  store(scenes)
  log:debug("Stored scene %s with %d step(s)", id, #scenes[tostring(id)].elements)
  return nil
end

--- REMOVE_SCENE.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return nil
function Scenes:remove(tParams, _now)
  local id = sceneId(tParams)
  if id == nil then
    return nil
  end
  if self.run and self.run.id == id then
    self:stopSteps()
  end
  local scenes = stored()
  scenes[tostring(id)] = nil
  store(scenes)
  return nil
end

--- CLEAR_ALL_SCENES.
--- @param _tParams table<string, string>
--- @param _now LightNow
--- @return nil
function Scenes:clear(_tParams, _now)
  self:stopSteps()
  store({})
  return nil
end

--- ACTIVATE_SCENE: run a scene from its first step, ending any other.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:activate(tParams, _now)
  local id = sceneId(tParams)
  if id == nil then
    return nil
  end
  self:stopSteps()
  local scene = stored()[tostring(id)]
  if not scene then
    log:warn("ACTIVATE_SCENE: unknown scene id %s", id)
    return nil
  end
  self.run = { id = id, idx = 0, due = "advance", waited = false }
  return self:_advance()
end

--- DEACTIVATE_SCENE marks a scene off in the agent's own bookkeeping: the light only stops its steps.
--- @param _tParams table<string, string>
--- @param _now LightNow
--- @return nil
function Scenes:deactivate(_tParams, _now)
  self:stopSteps()
  return nil
end

--- RAMP_SCENE_UP or RAMP_SCENE_DOWN, unless the scene ignores ramps: the steps stop, and the light ramps to
--- full or off over the asked time, in the color of the scene's last element.
--- @private
--- @param tParams table<string, string>
--- @param up boolean
--- @return LightIntent|nil
function Scenes:_ramp(tParams, up)
  local id = sceneId(tParams)
  local scene = id and stored()[tostring(id)]
  if scene and scene.ignoreRamp then
    return nil
  end
  self:stopSteps()
  local last = scene and scene.elements[#scene.elements]
  local step = last and stepIntent(last)
  self.ramping = true
  return {
    kind = "level",
    level = up and 100 or 0,
    color = step and step.color or nil,
    rateMs = math.max(0, tointeger(Select(tParams, "RATE")) or 0),
    source = "scene",
    ramp = true,
  }
end

--- RAMP_SCENE_UP.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:rampUp(tParams, _now)
  return self:_ramp(tParams, true)
end

--- RAMP_SCENE_DOWN.
--- @param tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:rampDown(tParams, _now)
  return self:_ramp(tParams, false)
end

--- STOP_SCENE_RAMP, and its published name STOP_RAMP_SCENE: every scene's steps stop, and a Ramp Scene Up or Down
--- still running stops where it has got to, level and color. A step's own fade runs to its end.
--- @param _tParams table<string, string>
--- @param _now LightNow
--- @return LightIntent|nil
function Scenes:stopRamp(_tParams, _now)
  self:stopSteps()
  if not self.ramping then
    return nil
  end
  self.ramping = false
  return { kind = "stop", source = "scene" }
end

--- TOGGLE_SCENE: the light keeps no scene's active state, so it activates; the agent tracks the toggle.
--- @param tParams table<string, string>
--- @param now LightNow
--- @return LightIntent|nil
function Scenes:toggle(tParams, now)
  return self:activate(tParams, now)
end

return Scenes
