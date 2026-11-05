-- lib.drivercentral's license gate, driven by the real vendored cloud client against a fake Cloud driver.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_drivercentral.lua

require("c4_shim")
local T = require("testlib")
local cloud = require("dc_cloud")

function C4:UpdateProperty(name, value)
  Properties[name] = value
end
local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  return section == "version" and "20261104" or configInfo(self, section)
end

local gate
local changes

--- A driver's load with a fresh client and gate: OnDriverInit starts the client, and the driver's own late init,
--- which the client runs before its own, starts the gate.
--- @param answer? table What the Cloud driver answers each ping with; nil answers nothing.
--- @param options? table `pid` for the product id (999), `properties` for the driver's properties.
local function load(answer, options)
  options = options or {}
  if gate and gate._timer then
    gate._timer:Cancel()
  end
  package.loaded["cloud-client-byte"] = nil
  package.loaded["lib.drivercentral"] = nil
  cloud.ping, cloud.answer, cloud.silent, cloud.present = nil, answer, answer == nil, true
  Properties = options.properties or { ["Cloud Status"] = "", ["Automatic Updates"] = "Off" }
  DC_OnDriverStatus = nil
  changes = {}
  gate = require("lib.drivercentral")
  gate.PRODUCT_ID = options.pid or 999
  function OnDriverLateInit()
    gate:startGate(function(licensed)
      changes[#changes + 1] = licensed
    end)
  end
  function ExecuteCommand() end
  gate:startClient()
  OnDriverLateInit("DIT_STARTUP")
end

--- `n` rounds of 10 s: one ping, then one read by the gate.
--- @param n? integer
local function tick(n)
  for _ = 1, n or 1 do
    if cloud.ping then
      cloud.poll(1)
    end
    ShimFireTimers()
  end
end

T.section("A licensed install or a trial runs, and the gate never stops it")
do
  load({ AC = 1, AS = "License Activated" })
  tick(40)
  T.eq("licensed: DC_X", DC_X, 1)
  T.eq("licensed: still running after 400 s", gate:licensed(), true)
  T.eq("licensed: no change heard", #changes, 0)
  load({ AC = -720, AS = "Trial Running, 30 Days Remaining" })
  tick(40)
  T.eq("trial: DC_X is the hours left", DC_X, -720)
  T.eq("trial: still running", gate:licensed(), true)
end

T.section("Without a license the driver runs five minutes after its load, then stops once")
do
  load({ AC = 0, AS = "Invalid License" })
  tick(29)
  T.eq("29 reads of 0: running", gate:licensed(), true)
  tick()
  T.eq("the 30th read of 0 stops it", gate:licensed(), false)
  tick(10)
  T.eq("and it is told once", changes, { false })
end

T.section("A Cloud driver that answers late at a boot stops nothing")
do
  load(nil)
  tick(24)
  T.eq("DC_X while the Cloud driver has not answered", DC_X, 0)
  cloud.silent, cloud.answer = false, { AC = 1, AS = "License Activated" }
  tick()
  tick(40)
  T.eq("running once it answers four minutes in", gate:licensed(), true)
  T.eq("no change heard", #changes, 0)
end

T.section("A trial that expires stops the driver, and a license starts it at once")
do
  load({ AC = -1, AS = "Trial Running, 1 Hours Remaining" })
  tick(2)
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  tick(29)
  T.eq("29 reads after the expiry: running", gate:licensed(), true)
  tick()
  T.eq("the 30th stops it", gate:licensed(), false)
  DC_OnDriverStatus()
  T.eq("a status call while DC_X is still 0 leaves it stopped", gate:licensed(), false)
  cloud.say({ AC = 1, AS = "License Activated" })
  T.eq("a license starts it without waiting for a read", gate:licensed(), true)
  T.eq("told stopped, then started", changes, { false, true })
end

T.section("A Cloud driver update rides through")
do
  load({ AC = 1, AS = "License Activated" })
  tick(3)
  -- The old Cloud driver tells every client 0 as it goes, and the new one is quiet until it has loaded.
  cloud.say({ AC = 0, AS = "Cloud driver removed, please install cloud driver." })
  cloud.silent = true
  tick(3)
  T.eq("DC_X while it reloads", DC_X, 0)
  cloud.silent = false
  tick()
  T.eq("DC_X once the new one answers", DC_X, 1)
  tick(40)
  T.eq("never stopped", #changes, 0)
end

T.section("A Cloud driver gone quiet stops the driver 30 reads after the client gives up, and an answer starts it")
do
  load({ AC = 1, AS = "License Activated" })
  cloud.silent = true
  local zeroAt, stopAt
  for i = 1, 60 do
    tick()
    zeroAt = zeroAt or (DC_X == 0 and i or nil)
    stopAt = stopAt or (not gate:licensed() and i or nil)
  end
  T.eq("the client sets 0 at the sixth unanswered ping", zeroAt, 6)
  T.eq("the gate stops the driver 30 reads later", stopAt, 35)
  T.eq("Cloud Status says why", Properties["Cloud Status"], "DriverCentral.io Cloud driver not found")
  cloud.silent = false
  tick()
  T.eq("the first answer starts it", gate:licensed(), true)
end

T.section("A project with no Cloud driver stops the driver")
do
  load({ AC = 1, AS = "License Activated" })
  cloud.present = false
  tick()
  T.eq("DC_X at the next ping", DC_X, 0)
  tick(30)
  T.eq("stopped 30 reads later", gate:licensed(), false)
end

T.section("A client that never starts leaves DC_X nil, and the driver runs")
do
  load({ AC = 0, AS = "Invalid License" }, { properties = { ["Automatic Updates"] = "Off" } })
  tick(40)
  T.eq("DC_X", DC_X, nil)
  T.eq("running", gate:licensed(), true)
end

T.section("With no product yet, the client stays out and the driver stops at its load")
do
  load({ AC = 1, AS = "License Activated" }, { pid = 0 })
  T.eq("the client is not loaded", package.loaded["cloud-client-byte"], nil)
  T.eq("DC_X", DC_X, 0)
  T.eq("Cloud Status", Properties["Cloud Status"], "No DriverCentral product")
  T.eq("stopped at once", changes, { false })
  DC_X = 1
  DC_OnDriverStatus()
  tick(40)
  T.eq("and stays stopped whatever DC_X reads", gate:licensed(), false)
end

if gate and gate._timer then
  gate._timer:Cancel()
end
T.finish()
