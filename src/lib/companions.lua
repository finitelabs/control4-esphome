--- Companion drivers: the drivers a hub driver adds to the project and binds to its own provider bindings, one per
--- light, lock or thermostat. Gives each binding a companion: the one it had, a spare, or a new one, one at a time.
--- What a driver needs, what each companion is called, and when to run, are the driver's own.

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("lib.bindings")
require("lib.utils")
local deferred = require("deferred")
local log = require("lib.logging")
local persist = require("lib.persist")

--- @class CompanionNeed
--- @field binding integer This driver's provider binding the companion belongs on.
--- @field file string The companion's driver file, as `example_light.c4z`.
--- @field consumer integer The companion's consumer binding.
--- @field class string The binding's class.
--- @field name string The name a new companion gets.
--- @field room? integer The room a new companion goes in, and a "room" spare is taken from: this driver's when nil.

--- @alias SpareRule
--- | "room" # A companion bound to nothing in the need's room.
--- | "any" # A companion bound to nothing anywhere in the project.

--- @class CompanionOptions
--- @field spares? SpareRule Which companions bound to nothing a need can take; none when nil.
--- @field renameSpares? boolean Whether a spare taken is renamed to the need's name; it keeps its own when not.
--- @field progress? fun(done: integer, total: integer) Called before each need is worked on.

--- @class CompanionResult
--- @field kept integer Needs whose binding was already bound, left alone.
--- @field rebound integer Needs bound again to the companion they had.
--- @field spares integer Needs given a spare.
--- @field added integer Needs given a new companion.
--- @field failed integer Needs given no companion: an add that never answered, or a bind that did not hold.
--- @field missing string[] The driver files the controller could not add, so not on it; their needs got none.

--- @class Companions
--- @field running boolean Whether a setup is under way.
local Companions = {}
Companions.__index = Companions

-- The companion each binding was last bound to, as { [binding] = deviceId }.
local PERSIST_KEY = "Companions"
-- Between one add and the next, so Director keeps up.
local ADD_SPACING_MS = 5000
local ADD_TIMEOUT_MS = 30000
local ROOM_C4I_NAME = "roomdevice.c4i"

--- @return Companions
function Companions:new()
  return setmetatable({ running = false }, self)
end

--- @return table<string, integer>
local function remembered()
  return persist:get(PERSIST_KEY, {}) or {}
end

--- @param binding integer
--- @param deviceId integer
local function remember(binding, deviceId)
  local saved = remembered()
  if saved[tostring(binding)] ~= deviceId then
    saved[tostring(binding)] = deviceId
    persist:set(PERSIST_KEY, saved)
  end
end

--- The companion bound to one of our bindings, the lowest id when several are.
--- @param binding integer
--- @return integer|nil
local function boundTo(binding)
  local lowest
  for id in pairs(C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding) or {}) do
    id = tointeger(id)
    if id and (lowest == nil or id < lowest) then
      lowest = id
    end
  end
  return lowest
end

--- @param deviceId integer
--- @param consumer integer
--- @return boolean
local function unbound(deviceId, consumer)
  return tointeger(C4:GetBoundProviderDevice(deviceId, consumer)) == 0
end

--- @param deviceId integer
--- @return integer|nil
local function proxyOf(deviceId)
  return tointeger((C4:GetProxyDevicesById(deviceId)))
end

--- @param need CompanionNeed
--- @return integer
local function roomOf(need)
  return need.room or tointeger(C4:RoomGetId())
end

--- Shows a proxy in the Navigators of one room and hides it in every other.
--- @param proxyId integer
--- @param room integer
local function showOnlyInRoom(proxyId, room)
  for id in pairs(C4:GetDevicesByC4iName(ROOM_C4I_NAME) or {}) do
    id = tointeger(id)
    if id then
      SendToDevice(id, "SET_DEVICE_HIDDEN_STATE", { PROXY_GROUP = "ALL", DEVICE_ID = proxyId, IS_HIDDEN = id ~= room })
    end
  end
end

--- Binds a companion to a need's binding, and reads it back from the companion, since C4:Bind answers nothing. The
--- companion is the binding's from here, bound or not, so a later setup binds it again rather than adding another.
--- @param need CompanionNeed
--- @param deviceId integer
--- @return boolean bound
local function connect(need, deviceId)
  local me = tointeger(C4:GetDeviceID())
  remember(need.binding, deviceId)
  Bind(me, need.binding, deviceId, need.consumer, need.class)
  if tointeger(C4:GetBoundProviderDevice(deviceId, need.consumer)) ~= me then
    log:error("Companions: %s did not bind to binding %s", deviceId, need.binding)
    return false
  end
  return true
end

--- The companion a need had, when it is still in the project and bound to nothing.
--- @param need CompanionNeed
--- @return integer|nil
local function previous(need)
  local id = tointeger(remembered()[tostring(need.binding)])
  local device = id and C4:GetDevices({ DeviceIds = tostring(id) })[id]
  if device and device.driverFileName == need.file and unbound(id, need.consumer) then
    return id
  end
end

--- The lowest-id companion of a need's driver, bound to nothing, that the rule allows and no binding has.
--- @param need CompanionNeed
--- @param rule SpareRule|nil
--- @param taken table<integer, boolean>
--- @return integer|nil
local function spare(need, rule, taken)
  if rule == nil then
    return nil
  end
  local lowest
  for id, device in pairs(C4:GetDevices({ C4iNames = need.file }) or {}) do
    id = tointeger(id)
    if
      id
      and not taken[id]
      and device.driverFileName == need.file
      and (rule == "any" or tointeger(device.roomId) == roomOf(need))
      and unbound(id, need.consumer)
      and (lowest == nil or id < lowest)
    then
      lowest = id
    end
  end
  return lowest
end

--- Adds a companion in the need's room with its name.
--- @param need CompanionNeed
--- @return Deferred<{ id: integer, proxy: integer|nil }|nil, string> added Nil when the controller could not add the
--- file; rejected when it never answered.
local function add(need)
  local d, settled = deferred.new(), false
  local timer = "Companions.Add." .. tostring(need.binding)
  SetTimer(timer, ADD_TIMEOUT_MS, function()
    settled = true
    d:reject(string.format("no answer to adding %s in %d s", need.file, ADD_TIMEOUT_MS / 1000))
  end)
  log:info("Companions: adding %s as %s in room %s", need.file, need.name, roomOf(need))
  C4:AddDevice(need.file, roomOf(need), need.name, function(deviceId, info)
    deviceId = tointeger(deviceId)
    local added
    if deviceId and deviceId ~= 0 then
      local proxy
      for _, node in pairs(type(info) == "table" and info.ChildNodes or {}) do
        if node.Name == "proxy" then
          proxy = tointeger(node.Value)
        end
      end
      added = { id = deviceId, proxy = proxy or proxyOf(deviceId) }
    end
    if settled then
      -- Counted as failed, it is still this binding's: it is given the binding now when that is still free.
      if added then
        log:warn("Companions: %s was added as %s after its timeout", need.file, deviceId)
        showOnlyInRoom(added.proxy or added.id, roomOf(need))
        if boundTo(need.binding) == nil and unbound(added.id, need.consumer) and connect(need, added.id) then
          RefreshNavs()
        end
      end
      return
    end
    settled = true
    CancelTimer(timer)
    if not added then
      log:warn("Companions: the controller could not add %s: %s", need.file, type(info) == "table" and info.Value or "")
    end
    d:resolve(added)
  end)
  return d
end

--- Gives each need's binding a companion, one need at a time. Each companion's driver file is installed first with
--- InstallDrivers. A binding that is already bound is left alone. Otherwise it gets the companion it had before, if
--- that companion is still in the project and not bound to anything. If not, it gets a spare that the rule allows. If
--- there is no spare, a new companion is added in the need's room with the need's name and shown only in that room, and
--- the next add waits ADD_SPACING_MS. An add with no answer within ADD_TIMEOUT_MS counts as failed, and setup moves on
--- to the next need. If that add answers later, its companion takes the binding if the binding is still free. Only
--- spares are renamed, and only with `renameSpares`. Nothing is unbound or removed. Navigators are refreshed at the end
--- if anything was bound.
--- @param needs CompanionNeed[]
--- @param options? CompanionOptions
--- @return Deferred<CompanionResult, string> result Rejected only when a setup is already running.
function Companions:setup(needs, options)
  options = options or {}
  if self.running then
    return reject("a companion setup is already running")
  end
  self.running = true
  --- @type CompanionResult
  local result = { kept = 0, rebound = 0, spares = 0, added = 0, failed = 0, missing = {} }
  local done = deferred.new()
  local pending, total, missing = {}, #needs, {}
  for i, need in ipairs(needs) do
    pending[i] = need
  end
  local carried, seen = {}, {}
  for _, need in ipairs(needs) do
    if not seen[need.file] then
      seen[need.file] = true
      table.insert(carried, { name = need.file })
    end
  end
  InstallDrivers(carried)
  -- A companion some binding had is never another's spare.
  local taken = {}
  for _, id in pairs(remembered()) do
    taken[id] = true
  end

  local function finish()
    self.running = false
    if result.rebound + result.spares + result.added > 0 then
      RefreshNavs()
    end
    log:info(
      "Companions: %d kept, %d bound again, %d spares, %d added, %d failed, missing %s",
      result.kept,
      result.rebound,
      result.spares,
      result.added,
      result.failed,
      IsEmpty(result.missing) and "none" or table.concat(result.missing, ", ")
    )
    done:resolve(result)
  end

  --- @param key "rebound"|"spares"|"added"|"failed"
  local function count(key)
    result[key] = result[key] + 1
  end

  local nextNeed
  nextNeed = function()
    local need = table.remove(pending, 1)
    if not need then
      return finish()
    end
    if options.progress then
      options.progress(total - #pending, total)
    end
    local current = boundTo(need.binding)
    if current then
      remember(need.binding, current)
      result.kept = result.kept + 1
      return nextNeed()
    end
    local id = previous(need)
    if id then
      taken[id] = true
      count(connect(need, id) and "rebound" or "failed")
      return nextNeed()
    end
    id = spare(need, options.spares, taken)
    if id then
      taken[id] = true
      if connect(need, id) then
        count("spares")
        if options.renameSpares then
          RenameDevice(proxyOf(id) or id, need.name)
        end
      else
        count("failed")
      end
      return nextNeed()
    end
    if missing[need.file] then
      return nextNeed()
    end
    return add(need):next(function(added)
      if not added then
        missing[need.file] = true
        result.missing[#result.missing + 1] = need.file
        return nextNeed()
      end
      taken[added.id] = true
      showOnlyInRoom(added.proxy or added.id, roomOf(need))
      if boundTo(need.binding) ~= nil then
        -- An earlier add for this binding answered late and took it while this one was asked for.
        log:warn("Companions: binding %s was taken already; %s is left bound to nothing", need.binding, added.id)
        count("failed")
      elseif connect(need, added.id) then
        count("added")
      else
        count("failed")
      end
      return delay(ADD_SPACING_MS):next(nextNeed)
    end, function(err)
      log:error("Companions: %s", err)
      count("failed")
      return nextNeed()
    end)
  end

  nextNeed()
  return done
end

--- Forgets the companion each binding had, as when the device behind the bindings changes.
function Companions:reset()
  persist:set(PERSIST_KEY, nil)
end

return Companions:new()
