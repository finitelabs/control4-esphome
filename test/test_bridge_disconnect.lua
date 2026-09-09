--- The ESPHome bridge tells sub-drivers the device went away only on a
--- true->false edge in its heartbeat. `wasConnected` used to be a Connect()
--- local, and every connection property calls Connect() on change, so a
--- reconfiguration rebuilt the closure with the flag reset and the edge was
--- destroyed: the bridge reported a failed connection while its children went on
--- reporting the device as present. Observed on a controller - the bridge showed
--- "Connection Failed", the climate child showed "Connected", and the
--- touchscreen rendered a live thermostat for an unreachable device.

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local passed, failed = 0, 0
local function check(cond, name)
  if cond then
    passed = passed + 1
    print("  ok   - " .. name)
  else
    failed = failed + 1
    print("  FAIL - " .. name)
  end
end

-- Resolved against this file rather than the working directory: run_test.sh cds
-- into test/, make test runs from the repo root, and dofile takes a path rather
-- than going through LUA_PATH.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/esphome/driver.lua"
local BRIDGE_BINDING = 4001

-- Director would have created this from driver.xml; seed it so the status
-- writes Connect() makes are not reported as errors.
Properties["Driver Status"] = ""

-- Stubs the bridge needs that the shim does not provide.
function C4:GetDriverConfigInfo()
  return ""
end
function C4:GetDevicesByC4iName()
  return {}
end
function C4:UpdatePropertyList() end
function C4:AddDynamicBinding() end

local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")

--- Load the bridge fresh and take control of its transport and bindings.
--- @return table sent Records of every SendToProxy the bridge makes.
local function loadBridge(connected)
  -- Do NOT clear package.loaded for the client: the bridge would then require a
  -- pristine copy and never see the stubs installed on the shared table.
  local sent = {}

  -- Instant, deterministic transport. `connected` decides what isConnected()
  -- reports, so a test can put the device up or down without a network.
  local state = { connected = connected }
  ESPHomeClient.connect = function(self)
    state.connected = true
    return {
      next = function(_, ok)
        if ok then
          ok()
        end
        return { next = function() end }
      end,
    }
  end
  ESPHomeClient.disconnect = function(self)
    state.connected = false
  end
  ESPHomeClient.isConnected = function(self)
    return state.connected
  end
  ESPHomeClient.isConfigured = function(self)
    return not IsEmpty(self._ipAddress)
  end
  ESPHomeClient.setConfig = function(self, ip)
    self:disconnect()
    self._ipAddress = ip
    return self
  end
  ESPHomeClient.getFatalError = function()
    return nil
  end

  dofile(DRIVER)
  -- lib/utils redefines SendToProxy at load, so capture AFTER dofile.
  SendToProxy = function(binding, command)
    sent[#sent + 1] = { binding = binding, command = command }
  end
  bindings.getDynamicBindings = function()
    return { { bindingId = BRIDGE_BINDING } }
  end
  RefreshStatus = function() end
  gInitialized = true
  state.connected = connected
  return sent, state
end

local function disconnects(sent)
  local n = 0
  for _, e in ipairs(sent) do
    if e.command == "UPDATE_DISCONNECT" then
      n = n + 1
    end
  end
  return n
end

print("[1] A connection property change while connected notifies the children")
do
  local sent = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  local before = disconnects(sent)
  -- Repoint at another address, exactly as an installer would. The stub
  -- resolves either address instantly; what is under test is the property
  -- change re-running Connect().
  Properties["IP Address"] = "192.168.1.120"
  Connect()
  local fired = disconnects(sent) - before
  check(fired > 0, "repointing the bridge tells the children the device is gone")
  -- climate, fan, light, lock, water_heater. A new entity type that serves a
  -- child driver should trip this deliberately, so it gets considered rather
  -- than silently never being told its device went away.
  check(fired == 5, "every entity type that implements disconnected() is notified")
end

print("[2] Clearing the address tells the children before the heartbeat stops")
do
  local sent = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  local before = disconnects(sent)
  -- An installer clearing the address. This branch cancels the heartbeat and
  -- returns, so there is no later pass that could notice the edge.
  Properties["IP Address"] = ""
  Connect()
  local afterClear = disconnects(sent)
  check(afterClear > before, "an unconfigured bridge still notifies its children")

  -- The flag is cleared in that branch, so staying unconfigured must not keep
  -- re-notifying on every further Connect().
  Connect()
  check(disconnects(sent) == afterClear, "and it does not re-notify while it stays unconfigured")
end

print("[3] A first connection notifies nobody: there is no edge to report")
do
  local sent = loadBridge(false)
  Properties["IP Address"] = "192.168.1.120"
  Connect()
  check(disconnects(sent) == 0, "a cold start fires no disconnect")
end

print("")
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
