-- Tests for BLE scanner recovery escalation in
-- src/esphome/capabilities/bluetooth_proxy.lua.
--
-- Run from the repo root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_scanner_recovery.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

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

--------------------------------------------------------------------------------
print("\n[1] a healthy scanner is left alone")
--------------------------------------------------------------------------------
do
  local capability, client = capabilityWithWatchdog()
  capability._scannerWatchdogSeen = true
  capability:_onScannerWatchdogFired()

  check("no recovery attempted", #client.calls == 0, table.concat(client.calls, ","))
  check("seen flag reset for the next interval", capability._scannerWatchdogSeen == false)
end

--------------------------------------------------------------------------------
print("\n[2] a stalled scanner is restarted in place")
--------------------------------------------------------------------------------
do
  local capability, client = capabilityWithWatchdog()
  capability:_onScannerWatchdogFired()

  -- ESPHome ignores a set-mode request for the mode it is already in, so
  -- recovery has to leave the current mode to make the firmware act.
  check("scanner mode flipped away from active", client.calls[1] == "mode:passive", table.concat(client.calls, ","))
  check("nothing else is touched yet", client.calls[2] == nil, table.concat(client.calls, ","))

  -- The restore runs on a timer. A silently dead restore would strand the
  -- proxy in passive mode, which is what BTHome devices cannot work with.
  ShimFireTimers()
  check("mode restored after the restart", client.calls[2] == "mode:active", table.concat(client.calls, ","))
  check("nothing further", client.calls[3] == nil, table.concat(client.calls, ","))
  check("watchdog still running", capability._scannerWatchdogActive == true)
end

--------------------------------------------------------------------------------
print("\n[3] recovery is bounded and never reboots the device")
--------------------------------------------------------------------------------
do
  local capability, client = capabilityWithWatchdog()

  capability:_onScannerWatchdogFired()
  ShimFireTimers()
  capability:_onScannerWatchdogFired()
  ShimFireTimers()
  check("two restarts, each restored", #client.calls == 4, table.concat(client.calls, ","))

  -- Past the budget the driver stops acting. ESPHome reboots itself for the
  -- scanner failures it can detect, so there is nothing left to escalate to.
  capability:_onScannerWatchdogFired()
  capability:_onScannerWatchdogFired()
  ShimFireTimers()
  check("no further action past the budget", #client.calls == 4, table.concat(client.calls, ","))
  check("watchdog keeps watching", capability._scannerWatchdogActive == true)
  check("only scanner mode is ever touched", not table.concat(client.calls, ","):find("press"))
end

--------------------------------------------------------------------------------
print("\n[4] a scanner that is not running is not recovered")
--------------------------------------------------------------------------------
do
  local capability, client = capabilityWithWatchdog()
  client.scannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_STOPPED
  capability:_onScannerWatchdogFired()

  check("no recovery for a stopped scanner", #client.calls == 0, table.concat(client.calls, ","))
  check("attempt counter untouched", capability._scannerRecoveryAttempts == 0)
end

--------------------------------------------------------------------------------
print("\n[5] returning advertisements reset the escalation")
--------------------------------------------------------------------------------
do
  local capability, client = capabilityWithWatchdog()
  capability:_onScannerWatchdogFired()
  check("one attempt recorded", capability._scannerRecoveryAttempts == 1)

  capability._scannerWatchdogSeen = true
  capability:_onScannerWatchdogFired()
  check("counter cleared once ads resume", capability._scannerRecoveryAttempts == 0)

  -- A later stall starts the ladder over rather than jumping to a reboot.
  capability:_onScannerWatchdogFired()
  check("next stall restarts in place again", client.calls[2] == "mode:passive", table.concat(client.calls, ","))
end

--------------------------------------------------------------------------------
print("\n[6] a passive scanner is flipped the other way")
--------------------------------------------------------------------------------
do
  local capability, client = capabilityWithWatchdog()
  client.scannerState.mode = ScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE
  capability:_onScannerWatchdogFired()

  check("flipped to active from passive", client.calls[1] == "mode:active", table.concat(client.calls, ","))
end

--------------------------------------------------------------------------------
print("\n[7] the watchdog only starts where scanner state is reported")
--------------------------------------------------------------------------------
do
  -- Without the SCANNER_STATE flag the cached state never leaves its default,
  -- so the watchdog could only ever take its ignore branch.
  local capability = BluetoothProxyCapability:new(fakeClient())
  capability._featureFlags = 0x01 -- passive scan only
  capability:_startScannerWatchdog()
  check("not started without scanner state support", capability._scannerWatchdogActive == false)

  capability._featureFlags = 0x01 + SCANNER_STATE_FLAG
  capability:_startScannerWatchdog()
  check("started once scanner state is reported", capability._scannerWatchdogActive == true)
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
