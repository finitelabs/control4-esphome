--- This module provides functionality for managing and persisting conditionals.

local log = require("lib.logging")
local persist = require("lib.persist")

require("drivers-common-public.global.lib")
require("lib.utils")

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

--- Composer sorts a device's conditionals only when every one has a sort_order, driver.xml's
--- included, so one given none is listed from here, after driver.xml's, in order of statement.
--- @type number
local SORT_ORDER_START = 1000

--- @class ConditionalConfig
--- @field type string
--- @field condition_statement string
--- @field description string
--- @field sort_order number? Where Composer lists it; left out, it follows driver.xml's in order of statement.

--- @class Conditional:ConditionalConfig
--- @field conditionalId number
--- @field name string

--- Calls `fn` with each saved conditional that has its ID, skipping any other saved entry.
--- @param saved table<string, table<string, Conditional>> The saved conditionals.
--- @param fn fun(conditional: Conditional)
local function eachConditional(saved, fn)
  for _, keys in pairs(saved) do
    for _, conditional in pairs(type(keys) == "table" and keys or {}) do
      if Select(conditional, "conditionalId") ~= nil then
        fn(conditional)
      end
    end
  end
end

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
--- @param conditional ConditionalConfig The conditional object to upsert.
--- @param testFunction function The test function associated with the conditional.
--- @return Conditional conditional The upserted conditional.
function Conditionals:upsertConditional(namespace, key, conditional, testFunction)
  log:trace("Conditionals:upsertConditional(%s, %s, %s, <testFunction>)", namespace, key, conditional)
  local conditionals = self:getConditionals()
  --- @type number
  local conditionalId = Select(conditionals, namespace, key, "conditionalId") or self:_getNextConditionalId()

  --- @type Conditional
  conditional = TableDeepCopy(conditional)

  conditional.conditionalId = conditionalId
  conditional.name = "CONDITIONAL_" .. conditionalId

  conditionals[namespace] = type(conditionals[namespace]) == "table" and conditionals[namespace] or {}
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
  eachConditional(self:getConditionals(), function(conditional)
    currentConditionals[conditional.conditionalId] = true
  end)
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
  eachConditional(self:getConditionals(), function(conditional)
    log:debug("Removing conditional '%s' (id=%s)", conditional.name, conditional.conditionalId)
    TC[conditional.name] = nil
  end)
  self:_saveConditionals(nil)
end

local conditionals = Conditionals:new()

--- Whether statement a sorts before b, case aside and its runs of digits compared as numbers, so
--- Button 2 comes before Button 10.
--- @param a string
--- @param b string
--- @return boolean
local function statementBefore(a, b)
  local pa, pb = 1, 1
  while pa <= #a and pb <= #b do
    local da, db = a:match("^%d+", pa), b:match("^%d+", pb)
    if da and db then
      local na, nb = tonumber(da), tonumber(db)
      if na ~= nb then
        return na < nb
      end
      pa, pb = pa + #da, pb + #db
    else
      local ca, cb = a:sub(pa, pa):lower(), b:sub(pb, pb):lower()
      if ca ~= cb then
        return ca < cb
      end
      pa, pb = pa + 1, pb + 1
    end
  end
  return #a - pa < #b - pb
end

--- Retrieves all conditionals in a program-friendly format, each with a sort_order.
--- @return table<string, Conditional> conditionals A table of conditionals indexed by their ID as strings.
function GetConditionals()
  log:trace("GetConditionals()")
  local progConditionals = {}
  --- @type Conditional[]
  local unsorted = {}
  eachConditional(conditionals:getConditionals(), function(conditional)
    progConditionals[tostring(conditional.conditionalId)] = conditional
    if conditional.sort_order == nil then
      unsorted[#unsorted + 1] = conditional
    end
  end)
  table.sort(unsorted, function(a, b)
    local sa, sb = tostring(a.condition_statement or ""), tostring(b.condition_statement or "")
    if statementBefore(sa, sb) then
      return true
    elseif statementBefore(sb, sa) then
      return false
    elseif sa ~= sb then
      return sa < sb
    end
    return a.conditionalId < b.conditionalId
  end)
  for i, conditional in ipairs(unsorted) do
    conditional.sort_order = SORT_ORDER_START + i
  end
  return progConditionals
end

return conditionals
