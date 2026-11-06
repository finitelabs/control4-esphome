--- Tests that the Bluetooth Coordinator disables itself below its minimum OS,
--- as every other driver in this repo does: Driver Status says so and nothing
--- starts.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_coordinator_min_os.lua

local T = require("testlib")
local H = require("ble_driver_harness")

H.use("esphome_bluetooth_coordinator")

H.test("below its minimum OS the coordinator disables itself", function()
  local realVersion = C4.GetVersionInfo
  C4.GetVersionInfo = function()
    return { version = "3.2.0.600000-res" }
  end
  H.boot()
  C4.GetVersionInfo = realVersion
  T.eq(
    "Driver Status says it is disabled",
    tostring(Properties["Driver Status"]):sub(1, #"DRIVER DISABLED"),
    "DRIVER DISABLED"
  )
  T.falsy("the away check does not start", H.armed("AwayCheck"))
end)

H.test("on a supported OS it starts", function()
  H.boot()
  T.eq("Driver Status reads Running", Properties["Driver Status"], "Running")
  T.truthy("the away check runs", H.armed("AwayCheck"))
end)

T.finish()
