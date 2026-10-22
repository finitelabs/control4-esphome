--- The ESPHome bridge tells sub-drivers the device went away only on a
--- true->false edge in its heartbeat. A reconfiguration through Connect() must
--- not reset that edge, or the children keep reporting a device the bridge has
--- lost.

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

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
  SendToProxy = function(binding, command, params)
    sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
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

--- The reason each UPDATE_DISCONNECT from the `from`th send on carried, "none" for none.
local function reasons(sent, from)
  local out = {}
  for i = from or 1, #sent do
    if sent[i].command == "UPDATE_DISCONNECT" then
      out[#out + 1] = sent[i].params.reason or "none"
    end
  end
  return out
end

T.section("A connection property change while connected notifies the children")
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
  T.check("repointing the bridge tells the children the device is gone", fired > 0)
  -- climate, fan, light, lock, water_heater. A new entity type that serves a
  -- child driver should trip this deliberately, so it gets considered rather
  -- than silently never being told its device went away.
  T.check("every entity type that implements disconnected() is notified", fired == 5)
end

T.section("Clearing the address tells the children before the heartbeat stops")
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
  T.check("an unconfigured bridge still notifies its children", afterClear > before)

  -- The flag is cleared in that branch, so staying unconfigured must not keep
  -- re-notifying on every further Connect().
  Connect()
  T.check("and it does not re-notify while it stays unconfigured", disconnects(sent) == afterClear)
end

T.section("A first connection notifies nobody: there is no edge to report")
do
  local sent = loadBridge(false)
  Properties["IP Address"] = "192.168.1.120"
  Connect()
  T.check("a cold start fires no disconnect", disconnects(sent) == 0)
end

T.section("A lapsed license tells the children it is the license, and a device lost does not")
do
  local sent, state = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  -- The DriverCentral cloud client sets DC_X to 0 when the license lapses; the next heartbeat acts on it.
  DC_X = 0
  ShimFireTimers()
  local license = { "license", "license", "license", "license", "license" }
  T.eq("a lapse tells every child it is the license, so a light keeps its level", reasons(sent), license)
  ShimFireTimers()
  T.eq("and only once", reasons(sent), license)

  DC_X = 1
  ShimFireTimers()
  T.check("relicensed, the bridge connects again", state.connected)
  local from = #sent + 1
  state.connected = false -- the device drops off the network
  ShimFireTimers()
  local none = { "none", "none", "none", "none", "none" }
  T.eq("a device lost tells every child with no reason, so a light reads off", reasons(sent, from), none)

  -- Lost in the heartbeat the lapse is seen in: the license did not end that connection.
  from = #sent + 1
  ShimFireTimers()
  state.connected = false
  DC_X = 0
  ShimFireTimers()
  T.eq("a device lost just before a lapse is seen tells them with no reason", reasons(sent, from), none)
  DC_X = nil
end

T.finish()
