--- This module provides functionality for managing and persisting conditionals.

local log = require("lib.logging")
local persist = require("lib.persist")

--- @class Conditionals
--- A class representing conditionals.
local Conditionals = {}
Conditionals.__index = Conditionals

--- The key used to persist conditionals.
--- @type string
local CONDITIONALS_PERSIST_KEY = "Conditionals"

--- The starting ID for conditionals.
--- @type number
local CONDITIONAL_ID_START = 10

--- @class Conditional
--- @field conditionalId number
--- @field name string
--- @field type string
--- @field condition_statement string
--- @field description string

--- Creates a new instance of the `Conditionals` class.
--- @return Conditionals conditionals A new instance of the `Conditionals` class.
function Conditionals:new()
  log:trace("Conditionals:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- Upserts a conditional into the conditionals table.
--- @param namespace string The namespace for the conditional.
--- @param key string The key for the conditional.
--- @param conditional Conditional The conditional object to upsert.
--- @param testFunction function The test function associated with the conditional.
--- @return Conditional conditional The upserted conditional.
function Conditionals:upsertConditional(namespace, key, conditional, testFunction)
  log:trace("Conditionals:upsertConditional(%s, %s, %s, <testFunction>)", namespace, key, conditional)
  local conditionals = self:getConditionals()
  --- @type number
  local conditionalId = Select(conditionals, namespace, key, "conditionalId") or self:_getNextConditionalId()

  conditional = TableDeepCopy(conditional)

  conditional.conditionalId = conditionalId
  conditional.name = "CONDITIONAL_" .. conditionalId

  conditionals[namespace] = conditionals[namespace] or {}
  conditionals[namespace][key] = conditional

  TC[conditional.name] = testFunction

  self:_saveConditionals(conditionals)
  return conditional
end

--- Deletes a conditional from the conditionals table.
--- @param namespace string The namespace of the conditional.
--- @param key string The key of the conditional.
function Conditionals:deleteConditional(namespace, key)
  log:trace("Conditionals:deleteConditional(%s, %s)", namespace, key)
  local conditionals = self:getConditionals()
  --- @type Conditional|nil
  local conditional = Select(conditionals, namespace, key)
  if IsEmpty(conditional) then
    return
  end
  --- @cast conditional -nil

  conditionals[namespace][key] = nil
  if IsEmpty(conditionals[namespace]) then
    conditionals[namespace] = nil
  end
  if IsEmpty(conditionals) then
    --- @diagnostic disable-next-line: assign-type-mismatch
    conditionals = nil
  end

  TC[conditional.name] = nil

  self:_saveConditionals(conditionals)
end

--- Gets the next available conditional ID.
--- @private
--- @return number conditionalId The next available conditional ID.
function Conditionals:_getNextConditionalId()
  log:trace("Conditionals:_getNextConditionalId()")
  local currentConditionals = {}
  for _, keys in pairs(self:getConditionals()) do
    for _, conditional in pairs(keys) do
      currentConditionals[conditional.conditionalId] = true
    end
  end
  local nextId = CONDITIONAL_ID_START
  while currentConditionals[nextId] ~= nil do
    nextId = nextId + 1
  end
  return nextId
end

--- Retrieves all conditionals from persistent storage.
--- @return table<string, table<string, Conditional>> conditionals A table containing all conditionals.
--- @diagnostic disable-next-line: unused
function Conditionals:getConditionals()
  log:trace("Conditionals:getConditionals()")
  return persist:get(CONDITIONALS_PERSIST_KEY, {}) or {}
end

--- Saves the conditionals to persistent storage.
--- @private
--- @param conditionals table<string, table<string, Conditional>>? The conditionals table to save.
--- @diagnostic disable-next-line: unused
function Conditionals:_saveConditionals(conditionals)
  log:trace("Conditionals:_saveConditionals(%s)", conditionals)
  persist:set(CONDITIONALS_PERSIST_KEY, not IsEmpty(conditionals) and conditionals or nil)
end

--- Resets all conditionals, removing them from the system and clearing persisted storage.
function Conditionals:reset()
  log:trace("Conditionals:reset()")
  for _, nsConditionals in pairs(self:getConditionals()) do
    for _, conditional in pairs(nsConditionals) do
      log:debug("Removing conditional '%s' (id=%s)", conditional.name, conditional.conditionalId)
      TC[conditional.name] = nil
    end
  end
  self:_saveConditionals(nil)
end

local conditionals = Conditionals:new()

--- Retrieves all conditionals in a program-friendly format.
--- @return table<string, Conditional> conditionals A table of conditionals indexed by their ID as strings.
function GetConditionals()
  log:trace("GetConditionals()")
  local progConditionals = {}
  for _, keys in pairs(conditionals:getConditionals()) do
    for _, conditional in pairs(keys) do
      progConditionals[tostring(conditional.conditionalId)] = conditional
    end
  end
  return progConditionals
end

return conditionals
