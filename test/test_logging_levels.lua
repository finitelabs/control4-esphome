-- lib.logging: the levels a build allows, the Log Level property's list, and drivers-common-public's dumps.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_logging_levels.lua

local T = require("testlib")

require("c4_shim")
local log = require("lib.logging")

local DUMPS = { "DEBUGPRINT", "DEBUG_TIMER", "DEBUG_RFN", "DEBUG_URL", "DEBUG_WEBSOCKET" }
local ALL_ON = { true, true, true, true, true }
local ALL_OFF = { false, false, false, false, false }

local function dumps()
  local on = {}
  for _, name in ipairs(DUMPS) do
    on[#on + 1] = _G[name] == true
  end
  return on
end

local lists, handled, unlisted = {}, {}, {}
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:UpdatePropertyList(name, list, value)
  lists[#lists + 1] = { name = name, list = list, value = value }
  if not ("," .. list .. ","):find("," .. value .. ",", 1, true) then
    unlisted[#unlisted + 1] = value .. " sent with " .. list
  end
end
function OPC.Log_Level(propertyValue)
  handled[#handled + 1] = propertyValue
  if #handled > 50 then
    error("OPC.Log_Level runs in a loop")
  end
  log:setLogLevel(propertyValue)
end

--- Picks a value in Composer, or sets it from programming.
local function pick(value)
  Properties["Log Level"] = value
  OnPropertyChanged("Log Level")
end

--- The list the property shows now: the last one sent.
local function offered()
  return lists[#lists]
end

local ALL = "0 - Fatal,1 - Error,2 - Warning,3 - Info,4 - Debug,5 - Trace,6 - Ultra"
local TO_DEBUG = "0 - Fatal,1 - Error,2 - Warning,3 - Info,4 - Debug"

T.section("The open-source build allows every level")
Properties["Log Level"] = "3 - Info"
log:setLogLevel(Properties["Log Level"])
T.eq(
  "the list, which driver.xml leaves empty, is filled at load",
  offered(),
  { name = "Log Level", list = ALL, value = "3 - Info" }
)
log:setLogMode("Print")
pick("6 - Ultra")
T.eq("Ultra is Ultra", log:getLogLevel(), log.LogLevel.ULTRA)
T.eq("the property is left as picked", Properties["Log Level"], "6 - Ultra")
T.eq("the dumps are on at Ultra with Print", dumps(), ALL_ON)
T.eq("the list still offers every level", offered().list, ALL)
T.eq("and so do the names", table.concat(log:getLogLevelNames(), ","), ALL)
pick("5 - Trace")
T.eq("the dumps are off at Trace", dumps(), ALL_OFF)
pick("6 - Ultra")
log:setLogMode("Log")
T.eq("and off at Ultra without Print, though Log Level did not run again", dumps(), ALL_OFF)
log:setLogMode("Print and Log")
T.eq("and on again with Print and Log", dumps(), ALL_ON)

T.section("Stopping at Debug, as a DriverCentral build starts")
handled = {}
log:allowTraceAndUltra(false)
T.eq("Ultra becomes Debug", log:getLogLevel(), log.LogLevel.DEBUG)
T.eq("the dumps go off", dumps(), ALL_OFF)
T.eq("the property is put back to Debug", Properties["Log Level"], "4 - Debug")
T.eq("and the driver's handler sees it", handled, { "4 - Debug" })
T.eq("the list stops at Debug", offered(), { name = "Log Level", list = TO_DEBUG, value = "4 - Debug" })
T.eq("and so do the names", table.concat(log:getLogLevelNames(), ","), TO_DEBUG)

pick("6 - Ultra")
T.eq("Ultra set from programming is Debug", log:getLogLevel(), log.LogLevel.DEBUG)
T.eq("and is put back to Debug", Properties["Log Level"], "4 - Debug")
T.eq("with the dumps off", dumps(), ALL_OFF)
T.eq("and a list that stops at Debug", offered(), { name = "Log Level", list = TO_DEBUG, value = "4 - Debug" })
pick("5 - Trace")
T.eq("as is Trace", Properties["Log Level"], "4 - Debug")

handled, lists = {}, {}
Properties["Log Level"] = "6 - Ultra"
log:setLogLevel(Properties["Log Level"])
T.eq("a stored Ultra restored in OnDriverInit is Debug", log:getLogLevel(), log.LogLevel.DEBUG)
T.eq("and is put back to Debug", Properties["Log Level"], "4 - Debug")
T.eq("without running the handler", handled, {})
T.eq("and the list it gets stops at Debug", offered(), { name = "Log Level", list = TO_DEBUG, value = "4 - Debug" })

pick("2 - Warning")
T.eq("a level up to Debug is taken", log:getLogLevel(), log.LogLevel.WARN)
T.eq("and left as picked", Properties["Log Level"], "2 - Warning")
log:setLogLevel(log.LogLevel.TRACE)
T.eq("a driver's own call is capped too", log:getLogLevel(), log.LogLevel.DEBUG)
T.eq("and leaves a property that shows no more than Debug", Properties["Log Level"], "2 - Warning")
pick("2 - Warning")

T.section("Allowing Trace and Ultra, as the Support Code does")
handled = {}
log:allowTraceAndUltra(true)
T.eq("the list reaches Ultra and keeps the value", offered(), { name = "Log Level", list = ALL, value = "2 - Warning" })
T.eq("the level is left as it was", log:getLogLevel(), log.LogLevel.WARN)
T.eq("and the handler does not run", handled, {})
pick("6 - Ultra")
T.eq("Ultra can be picked", log:getLogLevel(), log.LogLevel.ULTRA)
T.eq("and turns the dumps on", dumps(), ALL_ON)
T.eq("with the list still reaching Ultra", offered().list, ALL)

handled = {}
log:allowTraceAndUltra(false)
T.eq("closing it brings Ultra back to Debug", log:getLogLevel(), log.LogLevel.DEBUG)
T.eq("turns the dumps off", dumps(), ALL_OFF)
T.eq("puts the property back", Properties["Log Level"], "4 - Debug")
T.eq("and tells the handler", handled, { "4 - Debug" })
T.eq("and stops the list at Debug", offered(), { name = "Log Level", list = TO_DEBUG, value = "4 - Debug" })

log:allowTraceAndUltra(true)
pick("3 - Info")
log:setLogLevel(log.LogLevel.ULTRA)
T.eq("a driver's own call can reach Ultra while allowed", dumps(), ALL_ON)
handled = {}
log:allowTraceAndUltra(false)
T.eq("and is brought back to Debug when it closes", log:getLogLevel(), log.LogLevel.DEBUG)
T.eq("with the dumps off", dumps(), ALL_OFF)
T.eq("leaving a property that showed Info", Properties["Log Level"], "3 - Info")
T.eq("and the handler alone", handled, {})

T.eq("every list sent holds the value it selects", unlisted, {})

T.section("No loop when Director raises OnPropertyChanged for the driver's own writes")
function C4:UpdateProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end
function C4:UpdatePropertyList(name, list, value)
  lists[#lists + 1] = { name = name, list = list, value = value }
  Properties[name] = value
  OnPropertyChanged(name)
end
handled = {}
local ok, err = pcall(function()
  log:allowTraceAndUltra(true)
  pick("6 - Ultra")
  log:allowTraceAndUltra(false)
  pick("6 - Ultra")
end)
T.check("it settles", ok, err)
T.truthy("within a few runs of the handler", #handled < 20, #handled)
T.eq("at Debug", Properties["Log Level"], "4 - Debug")
T.eq("with the logger at Debug", log:getLogLevel(), log.LogLevel.DEBUG)

T.section("A driver with no Log Level property")
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:UpdatePropertyList(name, list, value)
  lists[#lists + 1] = { name = name, list = list, value = value }
end
lists = {}
Properties["Log Level"] = nil
local _, _, output = T.capture(function()
  log:allowTraceAndUltra(true)
  log:allowTraceAndUltra(false)
  log:setLogLevel("6 - Ultra")
end)
T.eq("is sent no list", lists, {})
T.eq("and prints nothing", output, "")
T.eq("and still stops at Debug", log:getLogLevel(), log.LogLevel.DEBUG)

T.finish()
