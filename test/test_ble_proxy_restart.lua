--- Tests for restarting a wedged ESP32 Bluetooth proxy: a scanner stuck where
--- the driver cannot act, and a device the proxy holds allocated but whose
--- service discovery never answers.
---
--- Runs the real ESPHome client and the bluetooth_proxy capability with only
--- the wire stubbed: requests are recorded, responses injected, and the
--- client's own discovery timeout is fired through the shim's timers.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_ble_proxy_restart.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local deferred = require("deferred")
local persist = require("lib.persist")
local constants = require("constants")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local ESPHomeClient = require("esphome.client")
local BluetoothProxyCapability = require("esphome.capabilities.bluetooth_proxy")
local BLEAddress = require("esphome.ble.address")

local ScannerState = ESPHomeProtoSchema.Enum.BluetoothScannerState
local ScannerMode = ESPHomeProtoSchema.Enum.BluetoothScannerMode
local Message = ESPHomeProtoSchema.Message
local BUTTON_COMMAND = ESPHomeProtoSchema.RPC.APIConnection.button_command

local MAC = "AA:BB:CC:DD:EE:FF"
local ADDRESS = BLEAddress.fromString(MAC)
local DEVICE_BINDING = 5013
local SCANNER_STATE_FLAG = 0x40

--- Mirrors the capability's thresholds; the sections assert both sides of each.
local NO_RECOVERY_INTERVALS = 3
local RESTART_INTERVALS = 10
local STALE_TIMEOUTS = 3
local RESTART_WINDOW_SECONDS = 6 * 60 * 60

local RESTART_BUTTON_KEY = "BluetoothProxyRestartButton"
local LAST_RESTART_KEY = "BluetoothProxyLastAutoRestart"
local MARKER = "Power Cycle Device"

local ENTITIES = {
  restart = { entity_type = "button", device_class = "restart", name = "Restart", key = 101, device_id = 0 },
  safe = { entity_type = "button", device_class = "restart", name = "Safe Mode", key = 102, device_id = 0 },
  factory = { entity_type = "button", device_class = "restart", name = "Factory Reset", key = 103, device_id = 0 },
  doorbell = { entity_type = "button", name = "Doorbell", key = 104, device_id = 0 },
  sensor = { entity_type = "sensor", device_class = "restart", name = "Uptime", key = 105, device_id = 0 },
}

local status, restartList, sent, calls

function C4:UpdateProperty(name, value)
  if name == BluetoothProxyCapability.STATUS_PROPERTY_NAME then
    status = value
  end
end

function C4:UpdatePropertyList(name, list, selected)
  if name == BluetoothProxyCapability.RESTART_BUTTON_PROPERTY_NAME then
    restartList = { list = list, selected = selected }
  end
end

SendToProxy = function(binding, command, params)
  table.insert(sent, { binding = binding, command = command, params = params or {} })
end

--- Button presses sent to the device, as their entity keys.
--- @return integer[]
local function presses()
  local keys = {}
  for _, call in ipairs(calls) do
    if call.method == BUTTON_COMMAND then
      table.insert(keys, call.body.key)
    end
  end
  return keys
end

--- The CONNECTION_FAILED errors the bound child was sent, in order.
--- @return string[]
local function childErrors()
  local errors = {}
  for _, s in ipairs(sent) do
    if s.binding == DEVICE_BINDING and s.command == "CONNECTION_FAILED" then
      table.insert(errors, s.params.error)
    end
  end
  return errors
end

--- A connected proxy whose scanner reports `scannerState` and that holds MAC allocated.
--- @param restartButton string|nil The saved restart button choice
--- @return table proxy, table client
local function newProxy(restartButton)
  status, restartList, sent, calls = "", nil, {}, {}
  ShimFireTimers()
  persist:delete(LAST_RESTART_KEY)
  if restartButton then
    persist:set(RESTART_BUTTON_KEY, restartButton)
  else
    persist:delete(RESTART_BUTTON_KEY)
  end

  local client = ESPHomeClient:new()
  client.callServiceMethod = function(_, method, body)
    table.insert(calls, { method = method, body = body })
    return deferred.new():resolve()
  end
  client.isConnected = function()
    return true
  end
  client._btConnections = { free = 2, limit = 3, allocated = { MAC }, initialized = true }
  client._btScannerState = {
    state = ScannerState.BLUETOOTH_SCANNER_STATE_STARTING,
    mode = ScannerMode.BLUETOOTH_SCANNER_MODE_ACTIVE,
    initialized = true,
  }

  local proxy = BluetoothProxyCapability:new(client)
  proxy._featureFlags = SCANNER_STATE_FLAG
  proxy._scannerWatchdogActive = true
  proxy._addedDevices[MAC] = { name = "Front Door", addressType = 0, bindingId = DEVICE_BINDING, passive = false }
  proxy:setRestartButtons(ENTITIES)
  return proxy, client
end

--- Fire the watchdog `n` times with no advertisements seen.
local function stuckFor(proxy, n)
  for _ = 1, n do
    proxy:_onScannerWatchdogFired()
  end
end

--- A CONNECT for the allocated device whose service discovery never answers.
local function unansweredDiscovery(proxy)
  proxy:handleCommand(MAC, DEVICE_BINDING, "CONNECT", {}, {})
  ShimFireTimers()
end

T.section("the restart choice offers only restart-class buttons and defaults to Off")
do
  newProxy()
  T.eq("Off first, then the restart-class buttons by name", restartList.list, "Off,Factory Reset,Restart,Safe Mode")
  T.eq("nothing is chosen for the installer", restartList.selected, "Off")
end

T.section("with the choice Off a stuck scanner is reported and nothing is pressed")
do
  local proxy = newProxy()
  stuckFor(proxy, NO_RECOVERY_INTERVALS)
  T.contains("the installer is told", status, MARKER)

  stuckFor(proxy, RESTART_INTERVALS * 3)
  T.eq("no button pressed", #presses(), 0)
end

T.section("a chosen restart button is pressed once the scanner is stuck long enough")
do
  local proxy = newProxy("Restart")
  stuckFor(proxy, RESTART_INTERVALS - 1)
  T.contains("reported before the restart", status, MARKER)
  T.eq("not pressed one interval early", #presses(), 0)

  stuckFor(proxy, 1)
  T.eq("pressed once", #presses(), 1)
  T.eq("the chosen button", presses()[1], ENTITIES.restart.key)
end

T.section("the restart is not repeated inside its window")
do
  local proxy = newProxy("Restart")
  stuckFor(proxy, RESTART_INTERVALS)
  T.eq("pressed once", #presses(), 1)

  stuckFor(proxy, RESTART_INTERVALS * 3)
  T.eq("still once while the window runs", #presses(), 1)

  -- The window is persisted, so a reloaded driver honours it too.
  local reloaded = BluetoothProxyCapability:new(proxy._client)
  reloaded._featureFlags = SCANNER_STATE_FLAG
  reloaded._scannerWatchdogActive = true
  reloaded:setRestartButtons(ENTITIES)
  stuckFor(reloaded, RESTART_INTERVALS)
  T.eq("still once after a driver reload", #presses(), 1)
end

T.section("a proxy still stuck after the window is restarted again")
do
  local proxy = newProxy("Restart")
  stuckFor(proxy, RESTART_INTERVALS)
  T.eq("pressed once", #presses(), 1)

  persist:set(LAST_RESTART_KEY, os.time() - RESTART_WINDOW_SECONDS - 1)
  stuckFor(proxy, 1)
  T.eq("pressed again once the window has passed", #presses(), 2)
end

T.section("only the chosen button is ever pressed")
do
  for _, choice in ipairs({ "Safe Mode", "Factory Reset" }) do
    local proxy = newProxy(choice)
    stuckFor(proxy, RESTART_INTERVALS)
    local key = choice == "Safe Mode" and ENTITIES.safe.key or ENTITIES.factory.key
    T.eq("the installer's choice of " .. choice .. " is what is pressed", presses()[1], key)
  end

  -- A saved name the device no longer lists is not matched to anything else.
  local proxy = newProxy("Reboot")
  T.eq("an unlisted saved choice shows as Off", restartList.selected, "Off")
  stuckFor(proxy, RESTART_INTERVALS)
  T.eq("and presses nothing", #presses(), 0)
end

T.section("time with the API down does not count towards a restart")
do
  local proxy, client = newProxy("Restart")
  stuckFor(proxy, RESTART_INTERVALS - 1)

  -- What the client caches between a disconnect and the next scanner report.
  client._btScannerState = {
    state = ScannerState.BLUETOOTH_SCANNER_STATE_IDLE,
    mode = ScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE,
    initialized = false,
  }
  stuckFor(proxy, RESTART_INTERVALS)
  T.eq("nothing pressed while disconnected", #presses(), 0)

  client._btScannerState = {
    state = ScannerState.BLUETOOTH_SCANNER_STATE_STARTING,
    mode = ScannerMode.BLUETOOTH_SCANNER_MODE_ACTIVE,
    initialized = true,
  }
  stuckFor(proxy, RESTART_INTERVALS - 1)
  T.eq("the count started over on reconnect", #presses(), 0)
  stuckFor(proxy, 1)
  T.eq("pressed after a full run of its own", #presses(), 1)
end

T.section("the startup property pass cannot clear a saved choice")
do
  local _, client = newProxy("Restart")
  local proxy = BluetoothProxyCapability:new(client)
  proxy:onRestartButtonChanged("Off")
  T.eq("the saved choice survives", persist:get(RESTART_BUTTON_KEY), "Restart")

  proxy:setRestartButtons(ENTITIES)
  T.eq("and is shown once buttons are listed", restartList.selected, "Restart")

  proxy:onRestartButtonChanged("Off")
  T.eq("an installer's Off after that is kept", persist:get(RESTART_BUTTON_KEY), "Off")
end

T.section("an allocated device whose discovery never answers is reported as a wedged proxy")
do
  local proxy, client = newProxy()
  client._btScannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING

  for _ = 1, STALE_TIMEOUTS - 1 do
    unansweredDiscovery(proxy)
  end
  T.eq("the child hears the plain failure first", childErrors()[STALE_TIMEOUTS - 1], "GATT discovery failed")
  T.excludes("nothing asked of the installer yet", status, MARKER)

  unansweredDiscovery(proxy)
  T.eq("then that the proxy needs a restart", childErrors()[STALE_TIMEOUTS], constants.BLUETOOTH_PROXY_NEEDS_RESTART)
  T.contains("and the parent status says so", status, MARKER)
  T.eq("with the choice Off nothing is pressed", #presses(), 0)
end

T.section("a wedged allocation presses the chosen restart button")
do
  local proxy = newProxy("Restart")
  for _ = 1, STALE_TIMEOUTS - 1 do
    unansweredDiscovery(proxy)
  end
  T.eq("not pressed before the count is reached", #presses(), 0)
  unansweredDiscovery(proxy)
  T.eq("pressed once it is", presses()[1], ENTITIES.restart.key)
end

T.section("a discovery that answers clears the stale allocation")
do
  local proxy, client = newProxy()
  client._btScannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING
  for _ = 1, STALE_TIMEOUTS do
    unansweredDiscovery(proxy)
  end
  T.contains("reported", status, MARKER)

  proxy:handleCommand(MAC, DEVICE_BINDING, "CONNECT", {}, {})
  client:_invokeCallback(
    Message.BluetoothGATTGetServicesDoneResponse.id,
    { address = ADDRESS },
    Message.BluetoothGATTGetServicesDoneResponse
  )
  T.excludes("the marker drops once the device answers", status, MARKER)

  proxy._addedDevices[MAC].services = nil
  unansweredDiscovery(proxy)
  T.eq("and a later timeout counts from one", childErrors()[#childErrors()], "GATT discovery failed")
end

T.section("only an unanswered discovery of a device still allocated counts")
do
  local proxy, client = newProxy()
  client._btScannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING

  -- The proxy answering with an error is a proxy that is still talking.
  for _ = 1, STALE_TIMEOUTS do
    proxy:handleCommand(MAC, DEVICE_BINDING, "CONNECT", {}, {})
    client:_invokeCallback(
      Message.BluetoothGATTErrorResponse.id,
      { address = ADDRESS, error = 133 },
      Message.BluetoothGATTErrorResponse
    )
  end
  T.excludes("not after GATT errors", status, MARKER)

  -- A release that took leaves nothing allocated to be stale.
  for _ = 1, STALE_TIMEOUTS do
    proxy:handleCommand(MAC, DEVICE_BINDING, "CONNECT", {}, {})
    client._btConnections.allocated = {}
    ShimFireTimers()
    client._btConnections.allocated = { MAC }
  end
  T.excludes("not after timeouts of a released device", status, MARKER)
  T.eq("the child heard only the plain failure", childErrors()[#childErrors()], "GATT discovery failed")
end

T.section("removing the device takes its stale allocation down")
do
  local proxy, client = newProxy()
  client._btScannerState.state = ScannerState.BLUETOOTH_SCANNER_STATE_RUNNING
  for _ = 1, STALE_TIMEOUTS do
    unansweredDiscovery(proxy)
  end
  T.contains("reported", status, MARKER)

  proxy:removeDevice(MAC)
  T.excludes("the marker drops with the device", status, MARKER)
end

T.finish()
