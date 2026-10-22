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
local status -- the bridge's Driver Status, as Director would show it
function C4:UpdateProperty(name, value)
  if name == "Driver Status" then
    status = value
  end
end

local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local refreshStatus -- the bridge's own RefreshStatus, which loadBridge stubs

--- Load the bridge fresh and take control of its transport and bindings.
--- @return table sent Records of every SendToProxy the bridge makes.
local function loadBridge(connected)
  -- Do NOT clear package.loaded for the client: the bridge would then require a
  -- pristine copy and never see the stubs installed on the shared table.
  local sent = {}

  -- Instant, deterministic transport. `connected` decides what isConnected()
  -- reports, so a test can put the device up or down without a network.
  local state = { connected = connected, reachable = true, logs = false }
  ESPHomeClient.connect = function(self)
    return {
      next = function(_, ok, fail)
        if not state.reachable then
          fail("Connection refused")
        else
          state.connected = true
          ok()
        end
        return { next = function() end }
      end,
    }
  end
  ESPHomeClient.disconnect = function(self)
    state.connected = false
    state.logs = false
  end
  ESPHomeClient.isLogsSubscribed = function(self)
    return state.logs
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
  refreshStatus = RefreshStatus
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

--- Each UPDATE_DISCONNECT from the `from`th send on: "suspended" if it said so, else "lost".
local function told(sent, from)
  local out = {}
  for i = from or 1, #sent do
    if sent[i].command == "UPDATE_DISCONNECT" then
      out[#out + 1] = sent[i].params.suspended and "suspended" or "lost"
    end
  end
  return out
end

local SUSPENDED = { "suspended", "suspended", "suspended", "suspended", "suspended" }
local LOST = { "lost", "lost", "lost", "lost", "lost" }

--- Run `n` heartbeats with the cloud client's DC_X at `x`.
local function beats(n, x)
  DC_X = x
  for _ = 1, n do
    ShimFireTimers()
  end
end

--- A lapse as the bridge acts on it: DC_X at 0 for six heartbeats in a row, a minute.
local function lapse()
  beats(6, 0)
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

T.section("A lapsed license tells the children the device is suspended, and a device lost does not")
do
  local sent, state = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  -- The DriverCentral cloud client sets DC_X to 0 when the license lapses.
  lapse()
  T.eq("a lapse tells every child the device is suspended, so a light keeps its level", told(sent), SUSPENDED)
  ShimFireTimers()
  T.eq("and only once", told(sent), SUSPENDED)

  DC_X = 1
  ShimFireTimers()
  T.check("relicensed, the bridge connects again", state.connected)
  T.eq("and tells the children nothing more", told(sent), SUSPENDED)
  local from = #sent + 1
  state.connected = false -- the device drops off the network
  ShimFireTimers()
  T.eq("a device lost then tells every child it is lost, so a light reads off", told(sent, from), LOST)

  -- Lost in the heartbeat the lapse is acted on: the license did not end that connection.
  from = #sent + 1
  beats(5, 0)
  state.connected = false
  beats(1, 0)
  T.eq("a device lost just before a lapse is acted on tells them it is lost", told(sent, from), LOST)
  DC_X = nil
end

T.section("A device gone when the license is active again is told lost")
do
  local sent, state = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  lapse()
  local from = #sent + 1
  state.reachable = false -- it lost power while the license was lapsed
  DC_X = 1
  ShimFireTimers()
  T.eq("a reconnect that fails tells every child the device is lost", told(sent, from), LOST)
  ShimFireTimers()
  T.eq("and only once", told(sent, from), LOST)
  state.reachable = true
  ShimFireTimers()
  T.check("it connects again when the device is back", state.connected)
  T.eq("telling the children nothing more", told(sent, from), LOST)
  DC_X = nil
end

T.section("A license 0 that does not last a minute, as at a boot before the Cloud driver answers, keeps the device")
do
  local sent, state = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  status = nil
  beats(5, 0)
  T.check("five heartbeats at 0 keep the bridge connected", state.connected)
  T.eq("and tell the children nothing", told(sent), {})
  T.check("nor read No active license", status ~= "No active license", status)
  beats(1, 1)
  beats(5, 0)
  T.check("a license between them starts the minute again", state.connected)
  beats(1, 0)
  T.check("the sixth 0 in a row drops the connection", not state.connected)
  T.eq("telling every child the device is suspended", told(sent), SUSPENDED)
  T.eq("and reads No active license", status, "No active license")
  DC_X = nil
end

T.section("Only the heartbeat's tick is a license check, so the minute is a minute")
do
  local _, state = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  DC_X = 0 -- a boot, before the Cloud driver answers
  Connect()
  beats(5, 0)
  T.check("a start at 0 and five ticks keep the bridge connected", state.connected)
  Connect() -- a connection property changed
  T.check("and so does an edit to a connection property", state.connected)
  beats(1, 0)
  T.check("the sixth tick at 0 drops the connection", not state.connected)
  DC_X = nil
end

T.section("A sub-driver loaded while the bridge has dropped the connection itself is told the device is suspended")
do
  local sent, state = loadBridge(false)
  local refreshes = 0
  RefreshStatus = function()
    refreshes = refreshes + 1
  end
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  -- A light entity's binding, as the bridge sets it up when it lists the device's entities.
  local LightEntity = require("esphome.entities.light")
  LightEntity:new(ESPHomeClient:new()):discovered({ key = 1, name = "Light", ref = "light" })
  local light = bindings:getDynamicBinding(LightEntity.TYPE, "light_light").bindingId
  lapse()
  local from = #sent + 1
  refreshes = 0
  -- Through the dispatcher, as Director delivers the REFRESH_STATE a light sends at its late init.
  ReceivedFromProxy(light, "REFRESH_STATE", {})
  T.eq("its refresh during a lapse is answered suspended", told(sent, from), { "suspended" })
  T.eq("on its own binding", sent[#sent].binding, light)
  T.eq("and the device it is not connected to is not refreshed", refreshes, 0)

  beats(1, 1)
  T.check("relicensed, the bridge connects again", state.connected)
  from = #sent + 1
  refreshes = 0
  ReceivedFromProxy(light, "REFRESH_STATE", {})
  T.eq("then a refresh tells it nothing", told(sent, from), {})
  T.eq("and refreshes the device, whose report answers it", refreshes, 1)
  DC_X = nil
end

T.section("A refresh while the device is disconnected leaves Driver Status as the heartbeat set it")
do
  -- A connection made to an entity's binding refreshes, as does a companion's refresh with the device lost.
  local function refreshed()
    refreshStatus()
    TimerFunctions[Timer.RefreshStatus](Timer.RefreshStatus, 0)
  end
  local _, state = loadBridge(false)
  Properties["IP Address"] = "192.168.1.119"
  Connect()
  lapse()
  refreshed()
  T.eq("lapsed: it still reads No active license", status, "No active license")
  DC_X = nil

  _, state = loadBridge(false)
  state.reachable = false
  Connect()
  local failed = status
  refreshed()
  T.eq("lost: it still reads why the connection failed", status, failed)
end

T.section("Resubscribing the device logs tells the children the device is suspended")
do
  -- Each drops the connection, as the log subscription has no unsubscribe, and the heartbeat reconnects.
  local function beat()
    TimerFunctions[Timer.heartbeat](Timer.heartbeat, 0)
  end
  local function subscribed()
    local sent, state = loadBridge(false)
    Properties["IP Address"] = "192.168.1.119"
    Connect()
    state.logs = true
    return sent, state
  end
  for _, change in ipairs({
    { "Log Level", "5 - Debug" },
    { "Log Mode", "Off" },
    { "Device Log Forwarding", "Off" },
  }) do
    local name = change[1]
    local sent, state = subscribed()
    Properties[name] = change[2]
    OnPropertyChanged(name)
    T.check(name .. " drops the connection", not state.connected)
    beat()
    T.eq(name .. ": every child is told the device is suspended", told(sent), SUSPENDED)
    T.check(name .. ": and the bridge connects again", state.connected)
    local from = #sent + 1
    state.connected = false
    beat()
    T.eq(name .. ": a device lost after that is told lost", told(sent, from), LOST)
  end

  local sent, state = subscribed()
  state.reachable = false
  Properties["Log Level"] = "4 - Info"
  OnPropertyChanged("Log Level")
  beat()
  local both = { unpack(SUSPENDED) }
  for _, v in ipairs(LOST) do
    both[#both + 1] = v
  end
  T.eq("a resubscribe whose reconnect fails tells them suspended, then lost", told(sent), both)
end

T.finish()
