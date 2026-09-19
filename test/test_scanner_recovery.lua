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
    connectionState = {
      initialized = true,
      free = 3,
      limit = 3,
    },
  }

  function client:getBluetoothScannerState()
    return self.scannerState
  end

  function client:getBluetoothConnectionState()
    return self.connectionState
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

--- How many in-place restarts the driver spends before it runs out of options.
local RESTART_ATTEMPTS = 2

--- How many consecutive intervals in a state the driver cannot act from are
--- required before it reports the scanner as stuck there.
local NO_RECOVERY_INTERVALS = 3

local statusUpdates = {}
function C4:UpdateProperty(name, value)
  if name == BluetoothProxyCapability.STATUS_PROPERTY_NAME then
    table.insert(statusUpdates, value)
  end
end

--- Drop every status property write recorded so far.
local function resetStatus()
  for i = #statusUpdates, 1, -1 do
    statusUpdates[i] = nil
  end
end

--- The value most recently written to the status property.
--- @return string status
local function lastStatus()
  return statusUpdates[#statusUpdates] or ""
end

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

  -- Timer keys are global, so a watchdog left running here would cancel the
  -- recovery timers of every later section under the same key.
  capability:_stopScannerWatchdog()
end

T.section("a healthy scanner reports nothing extra")
do
  local capability = capabilityWithWatchdog()
  capability._scannerWatchdogSeen = true
  capability:_onScannerWatchdogFired()
  capability:_updateStatusProperty()

  T.contains("scanner state still reported", lastStatus(), "Scanning (Active)")
  T.excludes("no marker while advertisements arrive", lastStatus(), "Power Cycle")
end

T.section("a deaf scanner past its restart budget asks for a power cycle")
do
  local capability, client = capabilityWithWatchdog()

  for _ = 1, RESTART_ATTEMPTS do
    capability:_onScannerWatchdogFired()
    ShimFireTimers()
  end
  T.eq("budget spent on restarts", #client.calls, RESTART_ATTEMPTS * 2)
  T.falsy("nothing claimed while restarts remain", capability._scannerUnrecoverable)

  resetStatus()
  capability:_onScannerWatchdogFired()

  T.truthy("marker raised once restarts are exhausted", capability._scannerUnrecoverable)
  -- A deaf proxy gets no advertisement or state callbacks, so the watchdog has
  -- to push the property itself or the condition never reaches the installer.
  T.contains("watchdog refreshed the property unprompted", lastStatus(), "Power Cycle Device")
  T.contains("condition named", lastStatus(), "Not Recovering")
  T.contains("scanner state still reported", lastStatus(), "Scanning (Active)")
  T.eq("no further recovery attempted", #client.calls, RESTART_ATTEMPTS * 2)
end

T.section("a scanner wedged where the driver cannot act asks for a power cycle")
do
  -- STARTING never reaches the restart budget, so an exhaustion-keyed marker
  -- would stay silent in exactly the state that most needs surfacing.
  for _, state in ipairs({
    ScannerState.BLUETOOTH_SCANNER_STATE_STARTING,
    ScannerState.BLUETOOTH_SCANNER_STATE_IDLE,
    ScannerState.BLUETOOTH_SCANNER_STATE_STOPPING,
    ScannerState.BLUETOOTH_SCANNER_STATE_STOPPED,
  }) do
    local capability, client = capabilityWithWatchdog()
    client.scannerState.state = state

    for _ = 1, NO_RECOVERY_INTERVALS - 1 do
      capability:_onScannerWatchdogFired()
    end
    T.falsy("nothing claimed before the state persists from " .. tostring(state), capability._scannerUnrecoverable)

    resetStatus()
    capability:_onScannerWatchdogFired()

    T.truthy("marker raised from state " .. tostring(state), capability._scannerUnrecoverable)
    T.contains("power cycle asked for from state " .. tostring(state), lastStatus(), "Power Cycle Device")
    T.eq("budget untouched from state " .. tostring(state), capability._scannerRecoveryAttempts, 0)
    T.eq("nothing acted on from state " .. tostring(state), #client.calls, 0)
  end
end

T.section("a healthy proxy passing through a non-actionable state is not reported")
do
  -- The firmware holds the scan stopped while a client is connecting,
  -- disconnecting or discovered, so a proxy doing what a proxy exists to do sits
  -- in IDLE and STOPPING for a while. Reporting that would cry wolf.
  for _, state in ipairs({
    ScannerState.BLUETOOTH_SCANNER_STATE_IDLE,
    ScannerState.BLUETOOTH_SCANNER_STATE_STOPPING,
  }) do
    local capability, client = capabilityWithWatchdog()
    client.scannerState.state = state

    resetStatus()
    capability:_onScannerWatchdogFired()

    T.falsy("no marker after one interval in " .. tostring(state), capability._scannerUnrecoverable)
    capability:_updateStatusProperty()
    T.contains("a status is rendered to assert against", lastStatus(), "Standalone Mode")
    T.excludes("nothing asked of the installer from " .. tostring(state), lastStatus(), "Power Cycle")

    -- Connection work finished and the scan relaunched.
    client.scannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING
    resetStatus()
    capability:_onScannerWatchdogFired()

    T.falsy("still no marker once running again from " .. tostring(state), capability._scannerUnrecoverable)
    capability:_updateStatusProperty()
    T.contains("a status is rendered to assert against", lastStatus(), "Scanning (Active)")
    T.excludes("the marker was never carried from " .. tostring(state), lastStatus(), "Power Cycle")

    ShimFireTimers()
  end
end

T.section("an interval the scanner is not stuck in restarts the count")
do
  -- Without the reset, stuck intervals separated by minutes of ordinary operation
  -- would accumulate into a power cycle request.
  -- FAILED is ESPHome's own to recover and RUNNING is the arm the restart budget
  -- covers, so neither counts towards being stuck.
  local interruptions = {
    { label = "failed", state = ScannerState.BLUETOOTH_SCANNER_STATE_FAILED },
    { label = "running", state = ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING },
    { label = "advertisements", state = ScannerState.BLUETOOTH_SCANNER_STATE_IDLE, seen = true },
  }

  for _, interruption in ipairs(interruptions) do
    local capability, client = capabilityWithWatchdog()
    client.scannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_IDLE

    for _ = 1, NO_RECOVERY_INTERVALS - 1 do
      capability:_onScannerWatchdogFired()
    end

    client.scannerState.state = interruption.state
    capability._scannerWatchdogSeen = interruption.seen or false
    capability:_onScannerWatchdogFired()
    ShimFireTimers()

    client.scannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_IDLE
    resetStatus()
    capability:_onScannerWatchdogFired()

    T.falsy("the run started over after " .. interruption.label, capability._scannerUnrecoverable)
    capability:_updateStatusProperty()
    T.contains("a status is rendered to assert against", lastStatus(), "Standalone Mode")
    T.excludes("nothing asked of the installer after " .. interruption.label, lastStatus(), "Power Cycle")
  end
end

T.section("a failed scanner is left to ESPHome")
do
  -- ESPHome's own failure handler reboots on FAILED, so claiming the driver has
  -- run out of options there would send an installer after a device that recovers.
  local capability, client = capabilityWithWatchdog()
  client.scannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_FAILED

  -- Long enough that a FAILED counted as stuck would have been reported by now.
  for _ = 1, NO_RECOVERY_INTERVALS do
    capability:_onScannerWatchdogFired()
  end
  capability:_updateStatusProperty()

  T.falsy("no marker for a failed scanner", capability._scannerUnrecoverable)
  T.contains("a status is rendered to assert against", lastStatus(), "Standalone Mode")
  T.excludes("nothing asked of the installer", lastStatus(), "Power Cycle")
  T.eq("nothing acted on", #client.calls, 0)
end

T.section("the marker clears when advertisements resume")
do
  for _, state in ipairs({
    ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING,
    ScannerState.BLUETOOTH_SCANNER_STATE_STARTING,
  }) do
    local capability, client = capabilityWithWatchdog()
    client.scannerState.state = state

    for _ = 1, RESTART_ATTEMPTS + 1 do
      capability:_onScannerWatchdogFired()
      ShimFireTimers()
    end
    T.truthy("marker raised from state " .. tostring(state), capability._scannerUnrecoverable)

    resetStatus()
    capability._scannerWatchdogSeen = true
    capability:_onScannerWatchdogFired()

    T.falsy("marker cleared from state " .. tostring(state), capability._scannerUnrecoverable)
    capability:_updateStatusProperty()
    T.contains("a status is rendered to assert against", lastStatus(), "Standalone Mode")
    T.excludes("status no longer asks for a power cycle", lastStatus(), "Power Cycle")
    T.eq("escalation reset with it", capability._scannerRecoveryAttempts, 0)
  end
end

T.finish()
