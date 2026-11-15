-- The sort_order GetConditionals gives each conditional. Composer sorts a device's conditionals
-- only when every one has a sort_order, driver.xml's included; one without drops the device to
-- an order of Director's own, so a remote's Button 1-4 came out 1, 4, 3, 2.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_conditionals_sort_order.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers") -- TC

local conditionals = require("lib.conditionals")

local function add(namespace, key, statement, sortOrder)
  return conditionals:upsertConditional(namespace, key, {
    type = "BOOL",
    condition_statement = statement,
    description = "NAME " .. statement .. " is STRING",
    sort_order = sortOrder,
  }, function()
    return true
  end)
end

--- The statements GetConditionals lists, in sort_order.
local function listed()
  local rows = {}
  for _, c in pairs(GetConditionals()) do
    rows[#rows + 1] = c
  end
  table.sort(rows, function(a, b)
    return a.sort_order < b.sort_order
  end)
  local statements = {}
  for i, c in ipairs(rows) do
    statements[i] = c.condition_statement
  end
  return statements
end

T.section("every conditional gets a sort_order, after driver.xml's")
add("Buttons", "b10", "Button 10 status")
add("Buttons", "b2", "Button 2 status")
add("Buttons", "b1", "button 1 status")
add("Zones", "z", "Zone status")
local all = GetConditionals()
local missing, lowest = 0, math.huge
for _, c in pairs(all) do
  if type(c.sort_order) ~= "number" then
    missing = missing + 1
  else
    lowest = math.min(lowest, c.sort_order)
  end
end
T.eq("none without one", missing, 0)
T.truthy("each above driver.xml's", lowest > 999, lowest)

T.section("in order of statement, case aside and numbers as numbers")
T.eq("Button 2 before Button 10", listed(), { "button 1 status", "Button 2 status", "Button 10 status", "Zone status" })

T.section("one the driver orders keeps its sort_order")
local zone = add("Zones", "z", "Zone status", 5)
T.eq("first, where its driver put it", listed()[1], "Zone status")
T.eq("with the value it was given", GetConditionals()[tostring(zone.conditionalId)].sort_order, 5)

T.section("the saved conditionals are not changed")
local saved = conditionals:getConditionals()
T.eq("a button saved without a sort_order", saved.Buttons.b2.sort_order, nil)

T.section("the same order every call")
T.eq("again", listed(), { "Zone status", "button 1 status", "Button 2 status", "Button 10 status" })

conditionals:reset()
T.finish()
