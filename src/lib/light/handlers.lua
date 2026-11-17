--- The light's bindings: one RFP function for the proxy binding and one for each Button Link, with the
--- native signature. Each parses a command into one of Light's entry points. No command-keyed RFP
--- is set, so a driver's own one for a command the library does not handle (EXTRA_SET) runs first. A light that
--- offers load groups also takes a group driver's commands as ExecuteCommand, the way one driver reaches another.

local log = require("lib.logging")
local Buttons = require("lib.light.buttons")
local Color = require("lib.light.color")

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("lib.utils")

--- @alias LightFamily "scenes"|"onModes"|"links"|"loadGroups"

-- The commands that move or ask the device. With no state from its device the light drops them: from a
-- load, a loss or a reset until the device's next report.
local DEVICE = {
  SET_BRIGHTNESS_TARGET = true,
  ON = true,
  OFF = true,
  TOGGLE = true,
  DYNAMIC_ON = true,
  DYNAMIC_OFF = true,
  SET_LEVEL = true,
  RAMP_TO_LEVEL = true,
  SET_COLOR_TARGET = true,
  SET_BRIGHTNESS_STOP = true,
  SET_COLOR_STOP = true,
  ACTIVATE_SCENE = true,
  DEACTIVATE_SCENE = true,
  RAMP_SCENE_UP = true,
  RAMP_SCENE_DOWN = true,
  STOP_SCENE_RAMP = true,
  STOP_RAMP_SCENE = true,
  TOGGLE_SCENE = true,
  BUTTON_ACTION = true,
  GROUP_SET_LEVEL = true,
  GROUP_RAMP_TO_LEVEL = true,
  GROUP_START_RAMP = true,
  GROUP_STOP_RAMP = true,
  LIGHT_GROUP_COMMAND = true,
}

-- The families a profile can leave out, and their commands: a family not offered takes none of them.
--- @type table<string, LightFamily>
local FAMILY = {
  PUSH_SCENE = "scenes",
  REMOVE_SCENE = "scenes",
  CLEAR_ALL_SCENES = "scenes",
  ALL_SCENES_PUSHED = "scenes",
  ACTIVATE_SCENE = "scenes",
  DEACTIVATE_SCENE = "scenes",
  RAMP_SCENE_UP = "scenes",
  RAMP_SCENE_DOWN = "scenes",
  STOP_SCENE_RAMP = "scenes",
  STOP_RAMP_SCENE = "scenes",
  TOGGLE_SCENE = "scenes",
  UPDATE_BRIGHTNESS_ON_MODE = "onModes",
  SET_BRIGHTNESS_ON_MODE = "onModes",
  UPDATE_COLOR_ON_MODE = "onModes",
  SET_COLOR_ON_MODE = "onModes",
  REQUEST_BUTTON_COLORS = "links",
  SET_BUTTON_COLOR = "links",
  BUTTON_ACTION = "links",
  JOIN_GROUP = "loadGroups",
  LEAVE_GROUP = "loadGroups",
  SET_GROUP_SYNC = "loadGroups",
  GROUP_SET_LEVEL = "loadGroups",
  GROUP_RAMP_TO_LEVEL = "loadGroups",
  GROUP_START_RAMP = "loadGroups",
  GROUP_STOP_RAMP = "loadGroups",
  LIGHT_GROUP_JOIN = "loadGroups",
  LIGHT_GROUP_LEAVE = "loadGroups",
  LIGHT_GROUP_COMMAND = "loadGroups",
}

-- The membership commands a load group sends.
local MEMBERSHIP = { JOIN_GROUP = true, LEAVE_GROUP = true, SET_GROUP_SYNC = true }

-- What a group driver built on lib.light.group sends a member.
local GROUP_DRIVER = { LIGHT_GROUP_JOIN = true, LIGHT_GROUP_LEAVE = true, LIGHT_GROUP_COMMAND = true }

-- The intents a group driver's command names.
--- @type table<string, LightIntentKind>
local DECIDED = {
  level = "level",
  off = "off",
  color = "color",
}

-- The light's own commands a load group in sync takes instead of the light, and the name each goes on as.
--- @type table<string, string>
local TO_GROUP = {
  ON = "ON",
  DYNAMIC_ON = "ON",
  OFF = "OFF",
  DYNAMIC_OFF = "OFF",
  TOGGLE = "TOGGLE",
  SET_LEVEL = "SET_LEVEL",
  RAMP_TO_LEVEL = "RAMP_TO_LEVEL",
  SET_BRIGHTNESS_TARGET = "RAMP_TO_LEVEL",
  BUTTON_ACTION = "BUTTON_ACTION",
}

-- The scene commands, and the LightScenes method each one is. The published name is STOP_RAMP_SCENE;
-- older code sends STOP_SCENE_RAMP.
--- @type table<string, string>
local SCENE_OPS = {
  PUSH_SCENE = "push",
  REMOVE_SCENE = "remove",
  CLEAR_ALL_SCENES = "clear",
  ACTIVATE_SCENE = "activate",
  DEACTIVATE_SCENE = "deactivate",
  RAMP_SCENE_UP = "rampUp",
  RAMP_SCENE_DOWN = "rampDown",
  STOP_SCENE_RAMP = "stopRamp",
  STOP_RAMP_SCENE = "stopRamp",
  TOGGLE_SCENE = "toggle",
}

-- The setting commands: presets, on modes, rates, Min and Max On, and button colors.
local SETTINGS = {
  SET_MAX_ON_LEVEL = true,
  SET_MIN_ON_LEVEL = true,
  SET_PRESET_LEVEL = true,
  UPDATE_BRIGHTNESS_ON_MODE = true,
  SET_BRIGHTNESS_ON_MODE = true,
  UPDATE_BRIGHTNESS_PRESET = true,
  UPDATE_BRIGHTNESS_RATE_DEFAULT = true,
  UPDATE_COLOR_RATE_DEFAULT = true,
  UPDATE_COLOR_PRESET = true,
  UPDATE_COLOR_ON_MODE = true,
  SET_CLICK_RATE_UP = true,
  SET_CLICK_RATE_DOWN = true,
  SET_HOLD_RATE_UP = true,
  SET_HOLD_RATE_DOWN = true,
  SET_BUTTON_COLOR = true,
}

-- The reads the proxy asks. GET_LIGHT_LEVEL passes the device gate: a lost light answers the level it keeps.
local ASKS = { GET_CONNECTED_STATE = true, GET_LIGHT_LEVEL = true, REQUEST_BUTTON_COLORS = true }

-- Commands the light takes and does nothing with: the proxy's mark that it has pushed its scenes, and
-- SET_COLOR_ON_MODE, whose mode UPDATE_COLOR_ON_MODE's presets already pick.
local IGNORED = { ALL_SCENES_PUSHED = true, SET_COLOR_ON_MODE = true }

-- A link's commands, as the BUTTON_ACTION actions they are: 0 release after a hold, 1 press, 2 release
-- after a click.
--- @type table<string, integer>
local LINK_ACTIONS = { DO_PUSH = Buttons.PRESS, DO_CLICK = Buttons.RELEASE_CLICK, DO_RELEASE = Buttons.RELEASE_HOLD }

--- @class LightHandlers
local Handlers = {}

--- Every command the library handles on the proxy and link bindings, sorted. A driver's command-keyed RFP for
--- one would run before the library's binding handler and take the command from it.
--- @type string[]
Handlers.COMMANDS = {}
do
  local seen = {}
  for _, set in ipairs({ DEVICE, FAMILY, MEMBERSHIP, GROUP_DRIVER, SCENE_OPS, SETTINGS, ASKS, IGNORED, LINK_ACTIONS }) do
    for command in pairs(set) do
      if not seen[command] then
        seen[command] = true
        Handlers.COMMANDS[#Handlers.COMMANDS + 1] = command
      end
    end
  end
  table.sort(Handlers.COMMANDS)
end

--- A C4 level param, rounded and held to 0-100.
--- @param value string|number|nil
--- @return integer
local function level(value)
  return math.max(0, math.min(100, math.floor((tonumber(value) or 0) + 0.5)))
end

--- SET_COLOR_TARGET's color: by Kelvin, by xy, or by a preset the light stores (Light V2 _3.1).
--- @param light Light
--- @param tParams table<string, string>
--- @param presetId integer|nil
--- @return LightColor|nil
local function targetColor(light, tParams, presetId)
  local kelvin = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE"))
  if kelvin and kelvin > 0 then
    local x, y = Color.kelvinToXY(kelvin)
    return { x = x, y = y, mode = Color.CCT, kelvin = math.floor(kelvin + 0.5) }
  end
  local x = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_X"))
  local y = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_Y"))
  if x and y then
    local mode = Color.fromProxyMode(Select(tParams, "LIGHT_COLOR_TARGET_MODE"))
    local color = { x = x, y = y, mode = mode }
    if mode == Color.CCT then
      local k = Color.kelvin(x, y)
      color.kelvin = k and math.floor(k + 0.5) or nil
    end
    return color
  end
  if presetId ~= nil then
    return light.settings:colorPreset(presetId)
  end
  return nil
end

--- A motion command as the intent it is, or nil for one that names nothing to do.
--- @param light Light
--- @param strCommand string
--- @param tParams table<string, string>
--- @return LightIntent|nil
local function intent(light, strCommand, tParams)
  if strCommand == "ON" or strCommand == "DYNAMIC_ON" then
    -- Navigators from OS 3.3.2 send DYNAMIC_ON and DYNAMIC_OFF for a generic on or off.
    return { kind = "on", source = "proxy" }
  elseif strCommand == "OFF" or strCommand == "DYNAMIC_OFF" then
    return { kind = "off", source = "proxy" }
  elseif strCommand == "TOGGLE" then
    return { kind = "toggle", source = "proxy" }
  elseif strCommand == "SET_LEVEL" or strCommand == "GROUP_SET_LEVEL" then
    -- A load group's level command acts as its single light twin.
    return { kind = "level", level = level(Select(tParams, "LEVEL")), rateMs = 0, source = "proxy" }
  elseif strCommand == "RAMP_TO_LEVEL" or strCommand == "GROUP_RAMP_TO_LEVEL" then
    -- The legacy form older programming and Alexa Voice Scenes send, and a load group's ramp.
    return {
      kind = "level",
      level = level(Select(tParams, "LEVEL")),
      rateMs = tointeger(Select(tParams, "TIME")),
      source = "proxy",
    }
  elseif strCommand == "SET_BRIGHTNESS_TARGET" then
    return {
      kind = "level",
      level = level(Select(tParams, "LIGHT_BRIGHTNESS_TARGET")),
      rateMs = tointeger(Select(tParams, "RATE")),
      presetId = tointeger(Select(tParams, "LIGHT_BRIGHTNESS_TARGET_PRESET_ID")),
      presetOrigin = tointeger(Select(tParams, "LIGHT_BRIGHTNESS_TARGET_PRESET_ORIGIN")),
      source = "proxy",
    }
  elseif strCommand == "SET_COLOR_TARGET" then
    local presetId = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ID"))
    local color = targetColor(light, tParams, presetId)
    if not color then
      log:warn("SET_COLOR_TARGET names no color: %s", tParams)
      return nil
    end
    return {
      kind = "color",
      color = color,
      rateMs = tointeger(
        Select(tParams, "LIGHT_COLOR_TARGET_COLOR_RATE")
          or Select(tParams, "LIGHT_COLOR_TARGET_RATE")
          or Select(tParams, "RATE")
      ),
      presetId = presetId,
      presetOrigin = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ORIGIN")),
      source = "proxy",
    }
  elseif strCommand == "SET_BRIGHTNESS_STOP" or strCommand == "GROUP_STOP_RAMP" then
    return { kind = "stopLevel", source = "proxy" }
  elseif strCommand == "SET_COLOR_STOP" then
    return { kind = "stopColor", source = "proxy" }
  end
  return nil
end

--- A group driver's LIGHT_GROUP_COMMAND as the intent it decided, or nil for one that names nothing.
--- @param tParams table<string, string>
--- @return LightIntent|nil
local function decided(tParams)
  local kind = DECIDED[Select(tParams, "KIND") or ""]
  if not kind then
    log:warn("LIGHT_GROUP_COMMAND names no command: %s", tParams)
    return nil
  end
  local color
  local x, y = tonumber(Select(tParams, "X")), tonumber(Select(tParams, "Y"))
  if x and y then
    color = { x = x, y = y, mode = Select(tParams, "MODE") == "cct" and "cct" or "xy" }
    color.kelvin = color.mode == "cct" and tointeger(Select(tParams, "KELVIN")) or nil
  end
  if kind == "color" and not color then
    log:warn("LIGHT_GROUP_COMMAND names no color: %s", tParams)
    return nil
  end
  return {
    kind = kind,
    level = kind == "level" and level(Select(tParams, "LEVEL")) or nil,
    color = color,
    rateMs = tointeger(Select(tParams, "RATE")) or 0,
    source = "proxy",
  }
end

--- Whether the light's profile offers a family.
--- @param light Light
--- @param family LightFamily|nil
--- @return boolean
local function offers(light, family)
  if family == nil then
    return true
  elseif family == "links" then
    return light.profile.links ~= nil
  end
  return light.profile[family] == true
end

--- One command on the proxy binding.
--- @param light Light
--- @param strCommand string
--- @param tParams table<string, string>
local function onProxy(light, strCommand, tParams)
  if not offers(light, FAMILY[strCommand]) then
    log:debug("%s dropped: the light does not offer %s", strCommand, FAMILY[strCommand])
    return
  end
  if MEMBERSHIP[strCommand] then
    light:membership(strCommand, tParams)
    return
  end
  if strCommand == "LIGHT_GROUP_JOIN" or strCommand == "LIGHT_GROUP_LEAVE" then
    light:groupDriver(strCommand, tParams)
    return
  end
  local toGroup = light.profile.loadGroups and TO_GROUP[strCommand]
  if toGroup then
    local params = tParams
    if strCommand == "SET_BRIGHTNESS_TARGET" then
      params = { LEVEL = Select(tParams, "LIGHT_BRIGHTNESS_TARGET"), TIME = Select(tParams, "RATE") }
    end
    if light:toGroups(toGroup, params) then
      return
    end
  end
  if DEVICE[strCommand] and not light.online then
    log:debug("%s dropped: no state from the device yet", strCommand)
    return
  end
  if IGNORED[strCommand] then
    return
  elseif SCENE_OPS[strCommand] then
    light:scene(SCENE_OPS[strCommand], tParams)
  elseif SETTINGS[strCommand] then
    light:setting(strCommand, tParams)
  elseif ASKS[strCommand] then
    light:ask(strCommand, tParams, light.profile.proxy)
  elseif strCommand == "BUTTON_ACTION" then
    local button = tointeger(Select(tParams, "BUTTON_ID"))
    local action = tointeger(Select(tParams, "ACTION"))
    if button and action then
      light:button(button, action, true)
    end
  elseif strCommand == "GROUP_START_RAMP" then
    light:groupHold(toboolean(Select(tParams, "RAMP_UP")), tointeger(Select(tParams, "RATE")))
  elseif strCommand == "LIGHT_GROUP_COMMAND" then
    local taken = decided(tParams)
    if taken then
      light:take(taken)
    end
  else
    local motion = intent(light, strCommand, tParams)
    if motion then
      light:command(motion)
    elseif not DEVICE[strCommand] then
      log:trace("%s is not a light command: dropped", strCommand)
    end
  end
end

--- Own the light's proxy binding and its Button Links.
--- @param light Light
function Handlers.register(light)
  local profile = light.profile
  RFP[profile.proxy] = function(idBinding, strCommand, tParams, _args)
    log:trace("RFP[%s] %s %s", idBinding, strCommand, tParams)
    onProxy(light, strCommand, tParams or {})
  end
  if profile.loadGroups then
    for command in pairs(GROUP_DRIVER) do
      EC[command] = function(tParams)
        onProxy(light, command, tParams or {})
      end
    end
  end
  local links = profile.links
  if not links then
    return
  end
  for _, button in ipairs(Buttons.ALL) do
    local id = Buttons.link(links, button)
    RFP[id] = function(idBinding, strCommand, tParams, _args)
      log:trace("RFP[%s] %s", idBinding, strCommand)
      if strCommand == "REQUEST_BUTTON_COLORS" then
        -- A keypad button bound to this link asks for its colors here, and is answered here.
        light:ask(strCommand, tParams or {}, idBinding)
        return
      end
      local action = LINK_ACTIONS[strCommand]
      if action == nil then
        log:trace("%s on a link is not a light command: dropped", strCommand)
        return
      end
      if
        profile.loadGroups
        and light:toGroups("BUTTON_ACTION", { BUTTON_ID = tostring(button), ACTION = tostring(action) })
      then
        return
      end
      if not light.online then
        log:debug("%s dropped: no state from the device yet", strCommand)
        return
      end
      light:button(button, action, false)
    end
  end
end

return Handlers
