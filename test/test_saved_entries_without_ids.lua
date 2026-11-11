-- What lib/conditionals.lua, lib/events.lua and lib/bindings.lua do with a saved record that comes back without
-- its id, or as something other than a table. Their restores indexed by that id, so one such record threw
-- "table index is nil" at the start of OnDriverInit or OnDriverLateInit and stopped the driver from starting.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_saved_entries_without_ids.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers") -- TC, RFP, OBC

local log = require("lib.logging")
local persist = require("lib.persist")

--- Saves records under key the way a driver might find them: the given ones, one that is not a table, and a
--- namespace that is not a table either. Then fresh modules read them back, as after a restart.
local function savedAfterRestart(key, records)
  records.notATable = "x"
  persist:set(key, { Buttons = records, Broken = "x" })
  ShimPersistLand()
  T.unload("^lib%.")
  ShimResetEvents()
  persist = require("lib.persist")
  log = require("lib.logging")
end

--- The keys of t, sorted.
local function keys(t)
  local out = {}
  for k in pairs(t or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

--- Everything lib.logging prints at warning level while fn runs, and whether fn ran without raising.
local function warned(fn)
  log:setLogLevel("2 - Warning")
  log:setLogMode("Print")
  local ok, err, output = T.capture(fn)
  log:setLogMode("")
  return ok, err, output
end

T.section("a saved conditional without its id is skipped")
savedAfterRestart("Conditionals", {
  whole = {
    conditionalId = 10,
    name = "CONDITIONAL_10",
    type = "BOOL",
    condition_statement = "IS",
    description = "Whole",
  },
  noId = { name = "CONDITIONAL_LOST", type = "BOOL", condition_statement = "IS", description = "Lost its id" },
})
local conditionals = require("lib.conditionals")
local ok, added = pcall(conditionals.upsertConditional, conditionals, "Buttons", "new", {
  type = "BOOL",
  condition_statement = "IS",
  description = "New",
}, function()
  return true
end)
T.truthy("a new one is added", ok, added)
T.eq("under the next free id", ok and added.conditionalId, 11)
ok, added = pcall(conditionals.upsertConditional, conditionals, "Broken", "first", {
  type = "BOOL",
  condition_statement = "IS",
  description = "First",
}, function()
  return true
end)
T.eq("one in a namespace that was not a table replaces it", ok and added.conditionalId, 12)
local listed
ok, listed = pcall(GetConditionals)
T.truthy("GetConditionals runs", ok, listed)
T.eq("and lists only the ones with their ids", keys(ok and listed or nil), { "10", "11", "12" })
T.truthy("reset runs", pcall(conditionals.reset, conditionals))
T.eq("and removes the new one's test", TC.CONDITIONAL_11, nil)

T.section("a saved event without its id is skipped, and the driver adding it again gives it one")
savedAfterRestart("Events", {
  whole = { eventId = 10, name = "Whole", description = "When whole" },
  noId = { name = "Lost", description = "Lost its id" },
})
local events = require("lib.events")
local _, err, output = warned(function()
  events:restoreEvents()
end)
T.eq("restoreEvents runs", err, nil)
T.contains("and says what it skipped", output, "Skipping saved event Buttons/noId: it has no event ID")
T.eq("declaring only the whole one", keys(ShimEvents()), { 10 })
ok, added = pcall(events.getOrAddEvent, events, "Buttons", "new", "New", "When new")
T.truthy("a new one is added", ok, added)
T.eq("under the next free id", ok and added.eventId, 11)
ok, added = pcall(events.getOrAddEvent, events, "Buttons", "noId", "Lost", "Lost its id")
T.eq("the one without an id gets the next", ok and added.eventId, 12)
T.eq("and is declared", ShimEvents()[12] and ShimEvents()[12].name, "Lost")
ok, added = pcall(events.getOrAddEvent, events, "Broken", "first", "First", "When first")
T.eq("one in a namespace that was not a table replaces it", ok and added.eventId, 13)

T.section("an event C4 refuses to declare is not saved")
T.falsy("a nil name is refused", pcall(events.getOrAddEvent, events, "Buttons", "nameless", nil, "No name"))
ShimPersistLand()
T.eq("and nothing is saved for it", Select(events:getEvents(), "Buttons", "nameless"), nil)
T.truthy("so the next restore runs", pcall(events.restoreEvents, events))
T.truthy("reset runs", pcall(events.reset, events))
T.eq("and deletes every declared event", keys(ShimEvents()), {})

T.section("a saved binding without its id, type or class is skipped, and the driver adding it again adds it whole")
ShimResetDynamicBindings()
ShimSetStaticBindings({})
-- What Director still holds from before the restart: the binding with no class saved, and a connection on it.
C4:AddDynamicBinding(5013, "PROXY", true, "No class", "RELAY", false, false)
C4:Bind(C4:GetDeviceID(), 5013, 700, 1, "RELAY")
savedAfterRestart("ConnectionBindings", {
  whole = { key = "whole", bindingId = 5012, type = "PROXY", provider = true, displayName = "Whole", class = "RELAY" },
  noId = { key = "noId", type = "PROXY", provider = true, displayName = "No id", class = "RELAY" },
  noClass = { key = "noClass", bindingId = 5013, type = "PROXY", provider = true, displayName = "No class" },
  noType = { key = "noType", bindingId = 5014, provider = true, displayName = "No type", class = "RELAY" },
})
local bindings = require("lib.bindings")
_, err, output = warned(function()
  bindings:restoreBindings()
end)
T.eq("restoreBindings runs", err, nil)
T.contains(
  "and says it skipped the one with no id",
  output,
  "Skipping saved binding Buttons/noId: it has no binding ID"
)
T.contains("and the one with no class", output, "Skipping saved binding 5013: it has no type or class")
T.contains("and the one with no type", output, "Skipping saved binding 5014: it has no type or class")
T.eq("adding only the whole one, and keeping the one Director holds", keys(ShimDynamicBindings()), { 5012, 5013 })
--- getOrAddDynamicBinding's binding, or nil if it raised.
local function added(...)
  local ok, binding = pcall(bindings.getOrAddDynamicBinding, bindings, ...)
  return ok and binding or nil
end
local binding = added("Buttons", "new", "PROXY", true, "New", "RELAY")
T.eq("a new one takes the next id not saved", binding and binding.bindingId, 5015)
binding = added("Buttons", "noClass", "PROXY", true, "No class", "RELAY")
T.eq("the one with no class is added whole at its own id", {
  binding and binding.bindingId,
  binding and binding.class,
  ShimDynamicBindings()[5013] and ShimDynamicBindings()[5013].class,
}, { 5013, "RELAY", "RELAY" })
T.eq("keeping its connection", #ShimConnections(), 1)
binding = added("Buttons", "noType", "PROXY", true, "No type", "RELAY")
T.eq("the one with no type, added again as it was, is added whole at its own id", {
  binding and binding.bindingId,
  binding and binding.type,
  ShimDynamicBindings()[5014] and ShimDynamicBindings()[5014].type,
}, { 5014, "PROXY", "PROXY" })
binding = added("Buttons", "noId", "PROXY", true, "No id", "RELAY")
T.eq("the one with no id is given the next", binding and binding.bindingId, 5016)
binding = added("Broken", "first", "PROXY", true, "First", "RELAY")
T.eq("one in a namespace that was not a table replaces it", binding and binding.bindingId, 5017)
T.truthy("reset runs", pcall(bindings.reset, bindings))
T.eq("and removes every binding it added", keys(ShimDynamicBindings()), {})

T.finish()
