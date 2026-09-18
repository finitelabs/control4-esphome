-- Tests for resolving the thermostat's display scale from Director.
--
-- The thermostatV2 proxy owns the display scale as variable 1100 on the proxy
-- item. Measured on a controller (DRV-125): an untouched proxy holds the bare
-- letter "F", and the proxy rewrites it to the whole word once a scale is
-- actually chosen -- pushing SCALE_CHANGED { SCALE = "C" } from this driver left
-- variable 1100 reading "CELSIUS". So a one-letter value is the proxy's own
-- default, not a choice, and treating it as a choice would pin every Celsius
-- project to Fahrenheit and never consult the project setting at all.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_display_scale.lua

require("drivers-common-public.global.handlers") -- OWVC, OnWatchedVariableChanged
require("c4_shim")

local T = require("testlib")
local DisplayScale = require("esphome.display_scale")

local PROXY_BINDING = 5001
local DRIVER_ID = tonumber(C4:GetDeviceID())
local PROXY_ID = 591

-- The shim has no GetDeviceVariable, and its GetBoundConsumerDevices reads a
-- connection registry this test has no need to populate. Both are stubbed so a
-- test can put any value on the proxy item, or take the proxy away entirely.
local proxyScale, boundProxy = nil, PROXY_ID

function C4:GetBoundConsumerDevices(deviceId, bindingId)
  if tonumber(deviceId) == DRIVER_ID and bindingId == PROXY_BINDING and boundProxy ~= nil then
    return { [boundProxy] = "Thermostat" }
  end
  return nil
end

function C4:GetDeviceVariable(deviceId, idVariable)
  if tonumber(deviceId) == boundProxy and idVariable == DisplayScale.SCALE_VARIABLE then
    return proxyScale
  end
  return nil
end

-- ── The proxy item is discovered, not assumed ────────────────────────────────

T.section("Proxy item discovery")

T.eq("the proxy item is found through the proxy binding", DisplayScale.proxyDeviceId(PROXY_BINDING), PROXY_ID)

boundProxy = nil
T.eq("an unbound proxy binding yields no item", DisplayScale.proxyDeviceId(PROXY_BINDING), nil)
boundProxy = PROXY_ID

-- ── Precedence: chosen scale, else project scale, else Fahrenheit ────────────

T.section("Resolution precedence")

ShimSetTemperatureScale("FAHRENHEIT")
proxyScale = "CELSIUS"
T.eq("a chosen Celsius beats a Fahrenheit project", DisplayScale.resolve(PROXY_BINDING), "C")

ShimSetTemperatureScale("CELSIUS")
proxyScale = "FAHRENHEIT"
T.eq("a chosen Fahrenheit beats a Celsius project", DisplayScale.resolve(PROXY_BINDING), "F")

-- The regression this file exists for.
proxyScale = "F"
T.eq("the proxy's untouched default defers to a Celsius project", DisplayScale.resolve(PROXY_BINDING), "C")

proxyScale = "C"
ShimSetTemperatureScale("FAHRENHEIT")
T.eq("a one-letter value is never read as a choice", DisplayScale.resolve(PROXY_BINDING), "F")

proxyScale = nil
ShimSetTemperatureScale("CELSIUS")
T.eq("no variable at all falls back to the project scale", DisplayScale.resolve(PROXY_BINDING), "C")

boundProxy = nil
T.eq("an unbound proxy falls back to the project scale", DisplayScale.resolve(PROXY_BINDING), "C")
boundProxy = PROXY_ID

ShimSetTemperatureScale("")
T.eq("an unreadable project scale falls back to Fahrenheit", DisplayScale.resolve(PROXY_BINDING), "F")
ShimResetTemperatureScale()

-- ── The watcher, which is what makes a Navigator change land ─────────────────

T.section("Watching the proxy's scale variable")

local fired = {}
DisplayScale.watch(PROXY_BINDING, function(idDevice, idVariable, strValue)
  table.insert(fired, { idDevice, idVariable, strValue })
end)

T.eq(
  "the listener is registered against the proxy item, not this driver",
  type(OWVC[PROXY_ID] and OWVC[PROXY_ID][DisplayScale.SCALE_VARIABLE]),
  "function"
)
T.eq("nothing is registered against the driver itself", OWVC[DRIVER_ID], nil)

OnWatchedVariableChanged(PROXY_ID, DisplayScale.SCALE_VARIABLE, "CELSIUS")
T.eq("a change to the scale variable reaches the driver", #fired, 1)
T.eq("the callback carries the new scale", fired[1] and fired[1][3], "CELSIUS")

boundProxy = nil
local ok = pcall(DisplayScale.watch, PROXY_BINDING, function() end)
T.truthy("watching an unbound proxy is a no-op rather than an error", ok)
boundProxy = PROXY_ID

T.finish()
