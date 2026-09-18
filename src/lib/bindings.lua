--- Bindings module for managing dynamic bindings.
--- This module provides functionality to create, retrieve, delete, and restore dynamic bindings.
--- It also handles persistent storage of bindings and ensures unique binding IDs.

local log = require("lib.logging")
local persist = require("lib.persist")

require("drivers-common-public.global.lib")
require("lib.utils")

--- Create a binding between two devices if it doesn't already exist.
--- @param idDeviceProvider integer Provider device ID
--- @param idBindingProvider integer Provider binding ID
--- @param idDeviceConsumer integer Consumer device ID
--- @param idBindingConsumer integer Consumer binding ID
--- @param strClass string Binding class
--- @return boolean true if binding was created, false if it already existed
function Bind(idDeviceProvider, idBindingProvider, idDeviceConsumer, idBindingConsumer, strClass)
  -- Only bind if the binding does not currently exist
  if Select(C4:GetBoundConsumerDevices(idDeviceProvider, idBindingProvider), idDeviceConsumer) == nil then
    log:debug(
      "C4:Bind(%s, %s, %s, %s, %s)",
      idDeviceProvider,
      idBindingProvider,
      idDeviceConsumer,
      idBindingConsumer,
      strClass
    )
    C4:Bind(idDeviceProvider, idBindingProvider, idDeviceConsumer, idBindingConsumer, strClass)
    return true
  end
  return false
end

--- Capture the devices wired to one of our bindings (as provider or consumer), so a
--- rename that must remove and re-add the binding can reconnect them afterward.
--- @param bindingId integer
--- @return { device: integer, binding: integer }[] connections, boolean provider
local function snapshotConnections(bindingId)
  local info = Select(GetDeviceBindings(tointeger(C4:GetDeviceID())), bindingId)
  if type(info) ~= "table" or not info.isbound then
    return {}, false
  end
  local conns = {}
  local function add(c)
    if type(c) == "table" and c.deviceid and c.bindingid then
      conns[#conns + 1] = { device = tointeger(c.deviceid), binding = tointeger(c.bindingid) }
    end
  end
  if info.provider then
    for _, c in pairs(info.boundconsumers or {}) do
      add(c)
    end
  else
    add(Select(info, "boundprovider", "bound"))
  end
  return conns, info.provider == true
end

--- Reconnect the connections captured by snapshotConnections. Bind() is a no-op when
--- the link exists, so this recovers the consumer-side links Control4 drops on a
--- remove/add without duplicating the provider-side ones it re-attaches itself.
--- @param bindingId integer
--- @param provider boolean whether OUR side provides the binding
--- @param class string the binding's connection class
--- @param conns { device: integer, binding: integer }[]
local function restoreConnections(bindingId, provider, class, conns)
  local me = tointeger(C4:GetDeviceID())
  for _, c in ipairs(conns) do
    if provider then
      Bind(me, bindingId, c.device, c.binding, class)
    else
      Bind(c.device, c.binding, me, bindingId, class)
    end
  end
end

--- @class Bindings
--- A class representing dynamic bindings.
local Bindings = {}
Bindings.__index = Bindings

--- Persistent storage key for connection bindings.
--- @type string
local CONNECTION_BINDINGS_PERSIST_KEY = "ConnectionBindings"

--- The starting ID for control bindings.
--- @type integer
local CONTROL_BINDING_START = 10

--- The ending ID for control bindings.
--- @type integer
local CONTROL_BINDING_END = 999

--- The starting ID for proxy bindings.
--- @type integer
local PROXY_BINDING_START = 5012

--- The ending ID for proxy bindings.
--- @type integer
local PROXY_BINDING_END = 5999

--- @class Binding
--- @field key string
--- @field bindingId integer
--- @field type string
--- @field provider boolean
--- @field displayName string
--- @field class string

--- Creates a new Bindings instance.
--- @return Bindings bindings A new Bindings instance.
function Bindings:new()
  log:trace("Binding:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- Retrieves or adds a dynamic binding.
--- If the binding does not exist, it creates a new one with a unique ID.
--- @param namespace string The namespace of the binding.
--- @param key string The key of the binding.
--- @param type string The type of the binding (e.g., "CONTROL" or "PROXY").
--- @param provider boolean Whether the binding is a provider.
--- @param displayName string The display name of the binding.
--- @param class string The class of the binding.
--- @return Binding|nil binding The binding object or nil if the binding could not be created.
function Bindings:getOrAddDynamicBinding(namespace, key, type, provider, displayName, class)
  log:trace(
    "Binding:getOrAddDynamicBinding(%s, %s, %s, %s, %s, %s)",
    namespace,
    key,
    type,
    provider,
    displayName,
    class
  )
  local bindings = self:getBindings()
  --- @type Binding|nil
  local binding = Select(bindings, namespace, key)
  if binding == nil then
    local bindingId = self:_getNextBindingId(type)
    if bindingId == nil then
      return nil
    end
    binding = {
      key = key,
      bindingId = bindingId,
      type = type,
      provider = provider,
      displayName = displayName,
      class = class,
    }
    --- @cast binding Binding

    bindings[namespace] = bindings[namespace] or {}
    bindings[namespace][key] = binding
    self:_saveBindings(bindings)
    C4:AddDynamicBinding(bindingId, type, provider, displayName, class, false, false)
  elseif binding.displayName ~= displayName or binding.provider ~= provider or binding.class ~= class then
    -- Control4 has no in-place rename, so re-add under the same id, with the record's own
    -- type (its id came from that type's range and restoreBindings re-adds from it). Wiring
    -- is restored only across a name-only rename: a provider flip or class change reshapes
    -- the link, so the old peers can't be re-bound in the new shape and are dropped (warned).
    local conns, wasProvider = snapshotConnections(binding.bindingId)
    local restorable = wasProvider == provider and binding.class == class
    C4:RemoveDynamicBinding(binding.bindingId)
    binding.provider = provider
    binding.displayName = displayName
    binding.class = class
    self:_saveBindings(bindings)
    C4:AddDynamicBinding(binding.bindingId, binding.type, provider, displayName, class, false, false)
    if restorable then
      restoreConnections(binding.bindingId, provider, class, conns)
    elseif #conns > 0 then
      log:warn("Binding '%s' changed shape; %d connection(s) dropped, re-wire in Composer", displayName, #conns)
    end
  end
  return binding
end

--- Retrieves a dynamic binding by namespace and key.
--- @param namespace string The namespace of the binding.
--- @param key string The key of the binding.
--- @return Binding|nil binding The binding object or nil if not found.
function Bindings:getDynamicBinding(namespace, key)
  log:trace("Binding:getOrAddDynamicBinding(%s, %s)", namespace, key)
  local bindings = self:getBindings()
  --- @type Binding|nil
  return Select(bindings, namespace, key)
end

--- Retrieves all dynamic bindings for a given namespace.
--- @param namespace string The namespace of the bindings.
--- @return table<string, Binding> bindings A table of bindings for the namespace.
function Bindings:getDynamicBindings(namespace)
  log:trace("Binding:getDynamicBindings(%s)", namespace)
  local bindings = self:getBindings()
  --- @type table<string, Binding>
  return Select(bindings, namespace) or {}
end

--- Deletes a dynamic binding by namespace and key.
--- Removes the binding from persistent storage and deletes the associated dynamic binding.
--- @param namespace string The namespace of the binding.
--- @param key string The key of the binding.
function Bindings:deleteBinding(namespace, key)
  log:trace("Binding:deleteBinding(%s, %s)", namespace, key)
  local bindings = self:getBindings()
  --- @type integer|nil
  local bindingId = Select(bindings, namespace, key, "bindingId")
  if IsEmpty(bindingId) then
    return
  end
  --- @cast bindingId -nil

  C4:RemoveDynamicBinding(bindingId)
  RFP[bindingId] = nil
  OBC[bindingId] = nil

  bindings[namespace][key] = nil
  if IsEmpty(bindings[namespace]) then
    bindings[namespace] = nil
  end
  if IsEmpty(bindings) then
    --- @diagnostic disable-next-line: assign-type-mismatch
    bindings = nil
  end

  self:_saveBindings(bindings)
end

--- Delete all bindings in a namespace.
--- @param namespace string The namespace to delete all bindings from.
function Bindings:deleteAllBindings(namespace)
  log:trace("Binding:deleteAllBindings(%s)", namespace)
  local bindings = self:getBindings()
  local nsBindings = bindings[namespace]

  if IsEmpty(nsBindings) then
    return
  end

  -- Collect keys first to avoid modifying table while iterating
  local keys = {}
  for key in pairs(nsBindings) do
    table.insert(keys, key)
  end

  -- Delete each binding
  for _, key in ipairs(keys) do
    self:deleteBinding(namespace, key)
  end
end

--- Check if a binding ID is within the managed dynamic binding ranges.
--- @param bindingId integer The binding ID to check.
--- @return boolean True if the binding ID is within a managed range.
local function isInManagedRange(bindingId)
  return (bindingId >= CONTROL_BINDING_START and bindingId <= CONTROL_BINDING_END)
    or (bindingId >= PROXY_BINDING_START and bindingId <= PROXY_BINDING_END)
end

--- The static driver.xml connection ids, as a set. They share the dynamic-binding id
--- space but aren't in the store, so the managed-range sweep must skip them or it deletes
--- them on every init. GetDriverConfigInfo("connections") returns the block as XML, so
--- match <id> (a <facing>/<type> value or a digit in a name would else be scraped as one).
local function staticConnectionIds()
  local set = {}
  local ok, xml = pcall(function()
    return C4:GetDriverConfigInfo("connections")
  end)
  if ok and type(xml) == "string" then
    for id in xml:gmatch("<id>(%d+)</id>") do
      set[tonumber(id)] = true
    end
  end
  return set
end

--- Restores all dynamic bindings from persistent storage. Ensures that all
--- bindings are re-added and removes unknown bindings within managed ranges.
---
--- Call this from OnDriverInit, not OnDriverLateInit: Director resolves stored
--- connections before OnDriverLateInit, and connections where this driver's
--- binding is the consumer side are permanently dropped if the binding does
--- not exist yet (provider-side bindings get re-attached whenever they are
--- added, so only early restore covers both directions).
function Bindings:restoreBindings()
  log:trace("Binding:restoreBindings()")
  local deviceBindings = GetDeviceBindings(tointeger(C4:GetDeviceID()))
  for _, keys in pairs(self:getBindings()) do
    for _, binding in pairs(keys) do
      deviceBindings[binding.bindingId] = nil
      log:debug("Restoring %s binding %s", binding.class, binding.displayName)
      C4:AddDynamicBinding(
        binding.bindingId,
        binding.type,
        binding.provider,
        binding.displayName,
        binding.class,
        false,
        false
      )
    end
  end
  -- Delete unknown bindings inside our managed ranges, but never the driver's own
  -- static driver.xml connections, which share the id space (see staticConnectionIds).
  local static = staticConnectionIds()
  for bindingId, _ in pairs(deviceBindings) do
    if isInManagedRange(bindingId) and not static[bindingId] then
      log:debug("Deleting unknown binding %s", bindingId)
      C4:RemoveDynamicBinding(bindingId)
    end
  end
end

--- Retrieves the next available binding ID for a given type. Ensures that the
--- ID is unique and within the allowed range.
--- @private
--- @param type string The type of the binding (e.g., "CONTROL" or "PROXY").
--- @return integer|nil bindingId The next available binding ID or nil if the maximum is exceeded.
function Bindings:_getNextBindingId(type)
  log:trace("Binding:_getNextBindingId(%s)", type)
  --- @type table<integer, boolean>
  local currentBindings = {}
  for _, keys in pairs(self:getBindings()) do
    for _, binding in pairs(keys) do
      currentBindings[binding.bindingId] = true
    end
  end
  local nextId, maxId = CONTROL_BINDING_START, CONTROL_BINDING_END
  if type == "PROXY" then
    nextId, maxId = PROXY_BINDING_START, PROXY_BINDING_END
  end
  while currentBindings[nextId] ~= nil and nextId <= maxId do
    nextId = nextId + 1
  end
  if nextId > maxId then
    log:error("maximum %s bindings exceeded", type)
    return nil
  end
  return nextId
end

--- Retrieves all bindings from persistent storage.
--- @return table<string, table<string, Binding>> bindings A table of all bindings mapped by namespace then key.
--- @diagnostic disable-next-line: unused
function Bindings:getBindings()
  log:trace("Binding:getBindings()")
  return persist:get(CONNECTION_BINDINGS_PERSIST_KEY, {}) or {}
end

--- Saves the bindings to persistent storage.
--- @private
--- @param bindings table<string, table<string, Binding>>? The bindings table to save.
--- @diagnostic disable-next-line: unused
function Bindings:_saveBindings(bindings)
  log:trace("Binding:_saveBindings(%s)", bindings)
  persist:set(CONNECTION_BINDINGS_PERSIST_KEY, not IsEmpty(bindings) and bindings or nil)
end

--- Resets all dynamic bindings, removing them from the system and clearing persisted storage.
--- This does not affect static bindings defined in driver.xml.
function Bindings:reset()
  log:trace("Bindings:reset()")
  for _, nsBindings in pairs(self:getBindings()) do
    for _, binding in pairs(nsBindings) do
      log:debug("Removing binding '%s' (id=%s)", binding.displayName, binding.bindingId)
      C4:RemoveDynamicBinding(binding.bindingId)
      RFP[binding.bindingId] = nil
      OBC[binding.bindingId] = nil
    end
  end
  self:_saveBindings(nil)
end

return Bindings:new()
