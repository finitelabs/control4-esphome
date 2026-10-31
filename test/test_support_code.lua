-- lib.support-code: which codes open the Lua window, for how long, and what is left in the property and the output.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_support_code.lua

local T = require("testlib")

require("c4_shim")
local supportCode = require("lib.support-code")

-- The same secret and days as tools/test_support_code.py, so the two computations cannot drift apart.
local SECRET = "0123456789abcdef0123456789abcdef"
local NOON_OCT_31 = 1793448000
local NOV_1_0030 = 1793493000
local NOV_1_0130 = 1793496600

local now = NOON_OCT_31
local realTime = os.time
os.time = function(t) -- luacheck: ignore
  return t and realTime(t) or now
end

local allowed = {}
function C4:AllowExecute(allow)
  allowed[#allowed + 1] = allow
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

--- Types a value into the property as Director would, and returns what the driver printed.
local function enter(sc, value)
  Properties["Support Code"] = value
  local ok, err, output = T.capture(function()
    sc:enter(value)
  end)
  T.check("entering " .. value .. " raised nothing", ok, err)
  return output
end

--- Lets an hour pass, and returns what the driver printed.
local function anHourOn()
  local _, _, output = T.capture(ShimFireTimers)
  return output
end

local sc = getmetatable(supportCode):new(SECRET)

if not C4.SHIM_HAS_CRYPTO then
  print("  skip no crypto backend on this host, C4:HMAC did not run")
  T.finish()
end

T.section("The day's code")
T.eq("is the one tools/support_code.py prints for the day", sc:codeFor("2026-10-31"), "VEAFARSBWM")
T.eq("and changes with the day", sc:codeFor("2026-11-01"), "0GE0QZ00XP")

T.section("Today's code opens the Lua window for an hour")
local output = enter(sc, "VEAFA-RSBWM")
T.eq("the window is opened", allowed, { true })
T.contains("and the output says for how long", output, "open for an hour")
T.eq("the property is cleared", Properties["Support Code"], "")
T.excludes("and the code is not printed", output, "VEAFA")
output = anHourOn()
T.eq("an hour on, it closes", allowed, { true, false })
T.contains("and says so", output, "closed")

T.section("Entering it again closes the window early")
allowed = {}
enter(sc, "veafarsbwm")
T.eq("lower case without the dash opens it", allowed, { true })
output = enter(sc, " VEAFA RSBWM ")
T.eq("the code again closes it", allowed, { true, false })
T.contains("and says so", output, "closed")
anHourOn()
T.eq("and its timer is gone", allowed, { true, false })

T.section("Anything else leaves the window as it was")
allowed = {}
output = enter(sc, "WYYNC-BTR1V")
T.eq("yesterday's code at noon does nothing", allowed, {})
T.contains("and is not accepted", output, "not accepted")
T.eq("the property is cleared anyway", Properties["Support Code"], "")
enter(sc, "VEAFA-RSBWN")
T.eq("nor does a code one character off", allowed, {})
enter(sc, "VEAFA-RSBWM")
output = enter(sc, "nonsense")
T.eq("a wrong code while open leaves it open", allowed, { true })
T.contains("and is not accepted", output, "not accepted")
anHourOn()

T.section("Around midnight UTC")
allowed = {}
now = NOV_1_0030
enter(sc, "VEAFA-RSBWM")
T.eq("yesterday's code still opens it half an hour after midnight", allowed, { true })
anHourOn()
enter(sc, "0GEOQ-ZOOXP")
T.eq("today's opens it too, typed with the letter O for zero", allowed, { true, false, true })
anHourOn()
allowed = {}
now = NOV_1_0130
enter(sc, "VEAFA-RSBWM")
T.eq("yesterday's no longer opens it at 01:30", allowed, {})
now = NOON_OCT_31

T.section("An empty value is the driver loading, not an attempt")
allowed = {}
Properties["Support Code"] = ""
output = enter(sc, "")
T.eq("nothing happens", allowed, {})
T.eq("and nothing is printed", output, "")

T.section("A build without the secret takes no code")
allowed = {}
for name, secret in pairs({ unset = "", short = string.rep("a", 31) }) do
  local off = getmetatable(supportCode):new(secret)
  output = enter(off, "VEAFA-RSBWM")
  T.eq("a " .. name .. " secret opens nothing", allowed, {})
  T.contains("and says the code is off", output, "off in this build")
end
output = enter(supportCode, "VEAFA-RSBWM")
T.eq("nor does the library's own outside a DriverCentral build", allowed, {})

T.section("A driver can follow the window")
allowed = {}
local told = {}
sc:onChange(function(open)
  told[#told + 1] = open
end)
enter(sc, "VEAFA-RSBWM")
T.eq("it is told when the code opens it", told, { true })
enter(sc, "VEAFA-RSBWM")
T.eq("and when the code closes it", told, { true, false })
enter(sc, "VEAFA-RSBWM")
anHourOn()
T.eq("and when the hour does", told, { true, false, true, false })
enter(sc, "nonsense")
T.eq("but not for a wrong code", told, { true, false, true, false })

T.section("The code never reaches the Lua output")
-- The driver's handler, as CONTRIBUTING.md shows it.
function OPC.Support_Code(propertyValue)
  sc:enter(propertyValue)
end
DEBUGPRINT = true
Properties["Support Code"] = "VEAFA-RSBWM"
local _, _, traced = T.capture(function()
  OnPropertyChanged("Support Code")
end)
DEBUGPRINT = false
T.excludes("the dispatcher's Trace output leaves the value out", traced, "VEAFA")
T.contains("while the handler still ran", traced, "Support Code accepted")
enter(sc, "VEAFA-RSBWM")
local realHMAC = C4.HMAC
C4.HMAC = function()
  return nil, "failed"
end
Properties["Support Code"] = "VEAFA-RSBWM"
_, _, traced = T.capture(function()
  OnPropertyChanged("Support Code")
end)
C4.HMAC = realHMAC
T.excludes("a C4:HMAC failure raises nothing that would print the value", traced, "VEAFA")
T.contains("and the code is just not accepted", traced, "not accepted")
sc:onChange(function()
  error("the driver's hook broke")
end)
allowed = {}
Properties["Support Code"] = "VEAFA-RSBWM"
_, _, traced = T.capture(function()
  OnPropertyChanged("Support Code")
end)
T.excludes("a driver's onChange that raises does not print the value either", traced, "VEAFA")
T.contains("its error is reported", traced, "the driver's hook broke")
T.eq("and the window still opened", allowed, { true })
traced = anHourOn()
T.eq("and closes on the hour", allowed, { true, false })
T.contains("reporting the hook again", traced, "the driver's hook broke")
sc:onChange(nil)

os.time = realTime -- luacheck: ignore
T.finish()
