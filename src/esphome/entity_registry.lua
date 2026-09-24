--- The Control4 identity of each ESPHome entity: the name it is shown under and
--- the part of its connection and event keys that tells it apart from the others
--- of its type. An entity keeps both for as long as the device lists it, so they
--- do not move when other entities come and go.

local persist = require("lib.persist")
local ESPHomeClient = require("esphome.client")

--- @class EntityRecord
--- @field name string The name the entity is shown under.
--- @field ref string Its key, or key@device_id when another entity of its type had the key first.
--- @field wanted string The entity's own name when `name` was chosen; a rename re-chooses it.

--- @class EntityRegistry
local EntityRegistry = {}
EntityRegistry.__index = EntityRegistry

local PERSIST_KEY = "EntityRegistry"

--- Types whose variable is named after the entity alone.
--- @type table<string, boolean>
local BARE_NAME_TYPES = {
  sensor = true,
  text_sensor = true,
  number = true,
  select = true,
  text = true,
  datetime_date = true,
  datetime_time = true,
  datetime_datetime = true,
}

--- The Control4 names an entity called `name` takes, which no other entity may
--- share. lib.values keys variables and plain values alike by name.
--- @param entityType string
--- @param name string
--- @return string[] claims
local function claimsOf(entityType, name)
  if BARE_NAME_TYPES[entityType] then
    return { "value:" .. name }
  elseif entityType == "binary_sensor" or entityType == "switch" then
    return { "value:" .. name .. " State" }
  elseif entityType == "cover" then
    return { "value:" .. name .. " State", "value:" .. name .. " Open", "value:" .. name .. " Closed" }
  elseif entityType == "event" then
    return { "value:" .. name .. " Last Event" }
  elseif entityType == "water_heater" then
    -- Its connection has the climate class.
    return { "climate:" .. name }
  end
  return { entityType .. ":" .. name }
end

--- Names to try, in order, for an entity whose own name `holder` already has.
--- @param entity table<string, any>
--- @param holder table<string, any>
--- @param client ESPHomeClient
--- @return string[] names
local function alternativesFor(entity, holder, client)
  local name = entity.name
  local label = ESPHomeClient.entityTypeLabel(entity.entity_type)
  local device = client:getSubDeviceName(entity.device_id) or client:getDeviceName()
  -- An unnamed entity is already called after its device.
  local prefixable = device ~= nil and name ~= device and name:sub(1, #device + 1) ~= device .. " "
  local names = {}
  if prefixable and (holder.device_id or 0) ~= (entity.device_id or 0) then
    names[#names + 1] = device .. " " .. name
  end
  names[#names + 1] = string.format("%s (%s)", name, label)
  if prefixable then
    names[#names + 1] = string.format("%s %s (%s)", device, name, label)
  end
  return names
end

--- Creates a new EntityRegistry instance.
--- @return EntityRegistry registry
function EntityRegistry:new()
  return setmetatable({}, self)
end

--- Give each listed entity its Control4 name (`name`) and key part (`ref`). The key-only store kept
--- the entity listed last but commanded its type's main-device twin, so that twin, else it, goes first.
--- @param list table[] ListEntities responses in the order the device sent them.
--- @param client ESPHomeClient For device and sub-device names.
--- @return table[] entities The listed entities, each once, in listing order.
--- @return table<string, table> byId The same entities by ESPHomeClient.entityId.
function EntityRegistry:assign(list, client)
  local records = persist:get(PERSIST_KEY, {}) or {}

  --- @type string[]
  local order = {}
  --- @type table<string, table>
  local byId = {}
  --- @type table<string, string>
  local lastWithKey = {}
  for _, entity in ipairs(list) do
    local id = ESPHomeClient.entityId(entity.entity_type, entity.device_id, entity.key)
    if byId[id] == nil then
      order[#order + 1] = id
    end
    byId[id] = entity
    lastWithKey[tostring(entity.key)] = id
  end
  -- Per key, the entity that inherits what the key-only store set up.
  --- @type table<string, string>
  local heirOf = {}
  for key, id in pairs(lastWithKey) do
    local mainTwin = ESPHomeClient.entityId(byId[id].entity_type, 0, byId[id].key)
    heirOf[key] = byId[mainTwin] ~= nil and mainTwin or id
  end

  local changed = false
  for id in pairs(records) do
    if byId[id] == nil then
      changed = true
    end
  end

  --- @type table<string, EntityRecord>
  local assigned = {}
  --- @type table<string, { id: string, own: boolean }>
  local claimed = {}
  --- @type table<string, boolean> type:ref
  local refs = {}

  local function claim(id, name)
    for _, c in ipairs(claimsOf(byId[id].entity_type, name)) do
      claimed[c] = { id = id, own = name == byId[id].name }
    end
  end
  --- Who stands in the way of `entity` being called `name`. Its own name gives way
  --- only to one sharing its key, which the driver used to merge with it: entities
  --- with different keys were set up side by side before, so neither is renamed.
  local function holderOf(entity, name)
    for _, c in ipairs(claimsOf(entity.entity_type, name)) do
      local holder = claimed[c] and byId[claimed[c].id]
      if holder ~= nil and (name ~= entity.name or not claimed[c].own or holder.key == entity.key) then
        return holder
      end
    end
  end

  -- Entities seen before keep their key part, and their name unless renamed since.
  for _, id in ipairs(order) do
    local entity, record = byId[id], records[id]
    if record ~= nil then
      assigned[id] = { ref = record.ref }
      refs[entity.entity_type .. ":" .. record.ref] = true
      if record.wanted == entity.name then
        assigned[id].name = record.name
        assigned[id].wanted = record.wanted
        claim(id, record.name)
      end
    end
  end

  --- @type string[]
  local pending = {}
  for _, heirs in ipairs({ true, false }) do
    for _, id in ipairs(order) do
      local isHeir = heirOf[tostring(byId[id].key)] == id
      if isHeir == heirs and (assigned[id] == nil or assigned[id].name == nil) then
        pending[#pending + 1] = id
      end
    end
  end

  for _, id in ipairs(pending) do
    local entity = byId[id]
    if assigned[id] == nil then
      local ref = tostring(entity.key)
      if refs[entity.entity_type .. ":" .. ref] then
        ref = ref .. "@" .. tostring(entity.device_id or 0)
      end
      refs[entity.entity_type .. ":" .. ref] = true
      assigned[id] = { ref = ref }
    end
    assigned[id].wanted = entity.name
    changed = true
  end

  -- Own names first, so a name an entity really has beats a made-up one.
  local toldApart = {}
  for _, id in ipairs(pending) do
    if holderOf(byId[id], byId[id].name) == nil then
      assigned[id].name = byId[id].name
      claim(id, byId[id].name)
    else
      toldApart[#toldApart + 1] = id
    end
  end
  for _, id in ipairs(toldApart) do
    local entity = byId[id]
    local holder = holderOf(entity, entity.name)
    local name
    for _, alternative in ipairs(alternativesFor(entity, holder, client)) do
      if holderOf(entity, alternative) == nil then
        name = alternative
        break
      end
    end
    local n = 2
    while name == nil do
      local numbered = string.format("%s (%s) %d", entity.name, ESPHomeClient.entityTypeLabel(entity.entity_type), n)
      if holderOf(entity, numbered) == nil then
        name = numbered
      end
      n = n + 1
    end
    assigned[id].name = name
    claim(id, name)
  end

  local entities = {}
  for _, id in ipairs(order) do
    local entity = byId[id]
    entity.name = assigned[id].name
    entity.ref = assigned[id].ref
    entities[#entities + 1] = entity
  end
  if changed then
    persist:set(PERSIST_KEY, not IsEmpty(assigned) and assigned or nil)
  end
  return entities, byId
end

--- Forget every entity's name and key part, so the next listing chooses afresh.
function EntityRegistry:reset()
  persist:delete(PERSIST_KEY)
end

return EntityRegistry:new()
