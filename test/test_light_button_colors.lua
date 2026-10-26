-- A keypad button bound to one of the light's button links asks for the
-- button's colors and LED state over that link, and is answered on it.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_light_button_colors.lua
--
-- A driver.lua cannot be loaded far enough to reach its handlers, so the handler
-- and the binding-to-button map it uses are cut out of the source and compiled
-- under a synthetic environment.
local T = require("testlib")
require("c4_shim")
require("lib.utils")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local fh = assert(io.open(root .. "/drivers/esphome_light/driver.lua", "r"))
local src = fh:read("*a")
fh:close()

local mapSrc = src:match("\n(local function buttonIdFromBinding%b()\n.-\nend)\n")
local handlerSrc = src:match("\n(function RFP%.REQUEST_BUTTON_COLORS%b()\n.-\nend)\n")
local setSrc = src:match("\n(function RFP%.SET_BUTTON_COLOR%b()\n.-\nend)\n")
T.check("buttonIdFromBinding was cut out", mapSrc ~= nil, "no match")
T.check("RFP.REQUEST_BUTTON_COLORS was cut out", handlerSrc ~= nil, "no match")
T.check("RFP.SET_BUTTON_COLOR was cut out", setSrc ~= nil, "no match")

local ON_BINDING, TOGGLE_BINDING, OFF_BINDING, PROXY_BINDING = 300, 301, 302, 5001

local function compile(ledState)
  local env = {
    RFP = {},
    log = setmetatable({}, {
      __index = function()
        return function() end
      end,
    }),
    constants = require("constants"),
    ON_BINDING = ON_BINDING,
    TOGGLE_BINDING = TOGGLE_BINDING,
    OFF_BINDING = OFF_BINDING,
    PROXY_BINDING = PROXY_BINDING,
    ledState = ledState,
    sends = {},
  }
  env.saved = {}
  env.getButtonColors = function(buttonId)
    local saved = env.saved[buttonId] or {}
    return saved.on or ("color" .. buttonId .. "on"), saved.off or ("color" .. buttonId .. "off")
  end
  env.setButtonColors = function(buttonId, onColor, offColor)
    local saved = env.saved[buttonId] or {}
    env.saved[buttonId] = { on = onColor or saved.on, off = offColor or saved.off }
  end
  env.SendToProxy = function(idBinding, strCommand, tParams)
    env.sends[#env.sends + 1] = { idBinding = idBinding, command = strCommand, params = tParams }
  end
  setmetatable(env, { __index = _G })
  local chunk, err = loadstring(table.concat({ mapSrc, handlerSrc, setSrc }, "\n"), "light_request_button_colors")
  T.check("the cut handler compiles", chunk ~= nil, err)
  setfenv(chunk, env)
  chunk()
  return env
end

T.section("A request on the On link is answered on it")
local env = compile(true)
env.RFP.REQUEST_BUTTON_COLORS(ON_BINDING, "REQUEST_BUTTON_COLORS", {})
T.eq("two answers", #env.sends, 2)
T.eq("colors on the link", env.sends[1].idBinding, ON_BINDING)
T.eq("BUTTON_COLORS", env.sends[1].command, "BUTTON_COLORS")
T.eq("the top button's on color", env.sends[1].params.ON_COLOR, "color0on")
T.eq("the top button's off color", env.sends[1].params.OFF_COLOR, "color0off")
T.eq("no button id on a link", env.sends[1].params.BUTTON_ID, nil)
T.eq("state on the link", env.sends[2].idBinding, ON_BINDING)
T.eq("MATCH_LED_STATE", env.sends[2].command, "MATCH_LED_STATE")
T.eq("lit while the light is on", env.sends[2].params.STATE, true)

T.section("The Off link's LED is lit while the light is off")
env = compile(false)
env.RFP.REQUEST_BUTTON_COLORS(OFF_BINDING, "REQUEST_BUTTON_COLORS", {})
T.eq("the bottom button's colors", env.sends[1].params.ON_COLOR, "color1on")
T.eq("lit while the light is off", env.sends[2].params.STATE, true)
env = compile(true)
env.RFP.REQUEST_BUTTON_COLORS(TOGGLE_BINDING, "REQUEST_BUTTON_COLORS", {})
T.eq("the toggle button's colors", env.sends[1].params.ON_COLOR, "color2on")
T.eq("the toggle link follows the light", env.sends[2].params.STATE, true)

T.section("A request through the proxy still answers every button")
env = compile(true)
env.RFP.REQUEST_BUTTON_COLORS(PROXY_BINDING, "REQUEST_BUTTON_COLORS", {})
local colors, states = 0, 0
for _, sent in ipairs(env.sends) do
  if sent.command == "BUTTON_COLORS" and sent.idBinding == PROXY_BINDING then
    colors = colors + 1
  elseif sent.command == "MATCH_LED_STATE" then
    states = states + 1
  end
end
T.eq("three colors to the proxy", colors, 3)
T.eq("three LED states", states, 3)

T.section("New colors from Composer go out on the button's link")
env = compile(true)
env.RFP.SET_BUTTON_COLOR(PROXY_BINDING, "SET_BUTTON_COLOR", { BUTTON_ID = "0", ON_COLOR = "ff0000" })
local onLink
for _, sent in ipairs(env.sends) do
  if sent.command == "BUTTON_COLORS" then
    onLink = sent
  end
end
T.check("BUTTON_COLORS was sent", onLink ~= nil, "none")
T.eq("on the On link", onLink and onLink.idBinding, ON_BINDING)
T.eq("with the new on color", onLink and onLink.params.ON_COLOR, "ff0000")
T.eq("and the saved off color", onLink and onLink.params.OFF_COLOR, "color0off")

T.section("A request on another binding is ignored")
env = compile(true)
env.RFP.REQUEST_BUTTON_COLORS(1, "REQUEST_BUTTON_COLORS", {})
T.eq("nothing sent", #env.sends, 0)

T.finish()
