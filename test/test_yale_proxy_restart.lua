--- Tests that a Yale lock shows a Bluetooth proxy needing a restart in its
--- Driver Status, where its retry and poll text would otherwise hide it.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_proxy_restart.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local constants = require("constants")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local OFFLINE_KEY = string.rep("0123456789ABCDEF", 2)
local POLL = { ["Offline Key"] = OFFLINE_KEY }
local PERSISTENT = { ["Connection Mode"] = "Persistent", ["Offline Key"] = OFFLINE_KEY }
local NEEDS_RESTART = constants.BLUETOOTH_PROXY_NEEDS_RESTART

H.test("in Poll mode a proxy needing a restart is shown over the poll schedule", function()
  H.boot(POLL)
  EC.Request_Status()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = NEEDS_RESTART })
  T.eq("the status names the proxy", Properties["Driver Status"], NEEDS_RESTART)
  T.truthy("and the next poll is still scheduled", H.armed("PollCycle"))
end)

H.test("in Poll mode any other failure still shows the poll schedule", function()
  H.boot(POLL)
  EC.Request_Status()
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = "GATT discovery failed" })
  T.eq("the status is the schedule", Properties["Driver Status"], "Listening (next poll in 60s)")
end)

H.test("in Persistent mode a proxy needing a restart is shown over the retry count", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "LOCK")
  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = NEEDS_RESTART })
  T.eq("the status names the proxy", Properties["Driver Status"], NEEDS_RESTART)
  T.truthy("and the lock is still retried", H.armed("Reconnect"))
end)

H.test("once the retries have run out the parent's failed connect still names the proxy", function()
  H.boot(PERSISTENT)
  H.rfp(PROXY, "LOCK")
  for _ = 1, 5 do
    H.fire("ConnectionTimeout")
    H.fire("Reconnect")
  end
  H.fire("ConnectionTimeout")
  T.eq("the retries ran out", Properties["Driver Status"], "Listening (reconnect failed)")

  H.rfp(ESPHOME, "CONNECTION_FAILED", { error = NEEDS_RESTART })
  T.eq("the status names the proxy", Properties["Driver Status"], NEEDS_RESTART)
  T.truthy("and a fresh round is armed", H.armed("Reconnect"))
end)

T.finish()
