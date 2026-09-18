-- Tests for BLE scanner recovery escalation in
-- src/esphome/capabilities/bluetooth_proxy.lua.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_scanner_recovery.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local deferred = require("deferred")
local BluetoothProxyCapability = require("esphome.capabilities.bluetooth_proxy")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local ScannerState = ESPHomeProtoSchema.Enum.BluetoothScannerState
local ScannerMode = ESPHomeProtoSchema.Enum.BluetoothScannerMode

--- A client stub recording the recovery calls the capability makes.
--- @return table client
local function fakeClient()
  local client = {
    calls = {},
    scannerState = {
      state = ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING,
      mode = ScannerMode.BLUETOOTH_SCANNER_MODE_ACTIVE,
      initialized = true,
    },
  }

  function client:getBluetoothScannerState()
    return self.scannerState
  end

  function client:setBluetoothScannerMode(active)
    table.insert(self.calls, active and "mode:active" or "mode:passive")
    local d = deferred.new()
    d:resolve()
    return d
  end

  return client
end

--- Bluetooth proxy feature flag for scanner state reporting.
local SCANNER_STATE_FLAG = 0x40

--- Build a capability wired to a stub client, with the watchdog already armed.
--- @return table capability, table client
local function capabilityWithWatchdog()
  local client = fakeClient()
  local capability = BluetoothProxyCapability:new(client)
  capability._featureFlags = SCANNER_STATE_FLAG
  capability._scannerWatchdogActive = true
  return capability, client
end

T.section("a healthy scanner is left alone")
do
  local capability, client = capabilityWithWatchdog()
  capability._scannerWatchdogSeen = true
  capability:_onScannerWatchdogFired()

  T.eq("no recovery attempted", #client.calls, 0)
  T.falsy("seen flag reset for the next interval", capability._scannerWatchdogSeen)
end

T.section("a stalled scanner is restarted in place")
do
  local capability, client = capabilityWithWatchdog()
  capability:_onScannerWatchdogFired()

  -- ESPHome ignores a set-mode request for the mode it is already in, so
  -- recovery has to leave the current mode to make the firmware act.
  T.eq("scanner mode flipped away from active", client.calls[1], "mode:passive")
  T.eq("nothing else is touched yet", client.calls[2], nil)

  -- The restore runs on a timer. A silently dead restore would strand the
  -- proxy in passive mode, which is what BTHome devices cannot work with.
  ShimFireTimers()
  T.eq("mode restored after the restart", client.calls[2], "mode:active")
  T.eq("nothing further", client.calls[3], nil)
  T.truthy("watchdog still running", capability._scannerWatchdogActive)
end

T.section("recovery is bounded and never reboots the device")
do
  local capability, client = capabilityWithWatchdog()

  capability:_onScannerWatchdogFired()
  ShimFireTimers()
  capability:_onScannerWatchdogFired()
  ShimFireTimers()
  T.eq("two restarts, each restored", #client.calls, 4)

  -- Past the budget the driver stops acting. ESPHome reboots itself for the
  -- scanner failures it can detect, so there is nothing left to escalate to.
  capability:_onScannerWatchdogFired()
  capability:_onScannerWatchdogFired()
  ShimFireTimers()
  T.eq("no further action past the budget", #client.calls, 4)
  T.truthy("watchdog keeps watching", capability._scannerWatchdogActive)
  T.excludes("only scanner mode is ever touched", table.concat(client.calls, ","), "press")
end

T.section("a scanner that is not running is not recovered")
do
  local capability, client = capabilityWithWatchdog()
  client.scannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_STOPPED
  capability:_onScannerWatchdogFired()

  T.eq("no recovery for a stopped scanner", #client.calls, 0)
  T.eq("attempt counter untouched", capability._scannerRecoveryAttempts, 0)
end

T.section("a scanner still starting is left to finish")
do
  -- The firmware's stop, which the mode round trip acts through, runs only from
  -- RUNNING. Acting here would spend the whole budget changing nothing.
  local capability, client = capabilityWithWatchdog()
  client.scannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_STARTING
  capability:_onScannerWatchdogFired()

  T.eq("no recovery while starting", #client.calls, 0)
  T.eq("budget not spent", capability._scannerRecoveryAttempts, 0)
end

T.section("returning advertisements reset the escalation")
do
  local capability, client = capabilityWithWatchdog()
  capability:_onScannerWatchdogFired()
  T.eq("one attempt recorded", capability._scannerRecoveryAttempts, 1)

  capability._scannerWatchdogSeen = true
  capability:_onScannerWatchdogFired()
  T.eq("counter cleared once ads resume", capability._scannerRecoveryAttempts, 0)

  -- A later stall starts the ladder over rather than jumping to a reboot.
  capability:_onScannerWatchdogFired()
  T.eq("next stall restarts in place again", client.calls[2], "mode:passive")
end

T.section("a passive scanner is flipped the other way")
do
  local capability, client = capabilityWithWatchdog()
  client.scannerState.mode = ScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE
  capability:_onScannerWatchdogFired()

  T.eq("flipped to active from passive", client.calls[1], "mode:active")
end

T.section("the watchdog only starts where scanner state is reported")
do
  -- Without the SCANNER_STATE flag the cached state never leaves its default,
  -- so the watchdog could only ever take its ignore branch.
  local capability = BluetoothProxyCapability:new(fakeClient())
  capability._featureFlags = 0x01 -- passive scan only
  capability:_startScannerWatchdog()
  T.falsy("not started without scanner state support", capability._scannerWatchdogActive)

  capability._featureFlags = 0x01 + SCANNER_STATE_FLAG
  capability:_startScannerWatchdog()
  T.truthy("started once scanner state is reported", capability._scannerWatchdogActive)
end

T.finish()
