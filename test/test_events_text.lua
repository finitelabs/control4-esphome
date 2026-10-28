-- getOrAddEvent in lib/events.lua when the stored event's name or description differs
-- from the caller's. It returned the stored event unchanged, so a driver that changed
-- an event's text reached only new installs: restoreEvents() re-declared the old text.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_events_text.lua

local T = require("testlib")

require("c4_shim")

local adds = {}
local realAdd = C4.AddEvent
function C4:AddEvent(id, name, description)
  table.insert(adds, id)
  return realAdd(self, id, name, description)
end

-- A restart: fresh modules over the same storage, then restoreEvents() as at OnDriverLateInit.
local function restart()
  ShimPersistLand()
  T.unload("^lib%.")
  ShimResetEvents()
  local events = require("lib.events")
  events:restoreEvents()
  return events
end

local events = require("lib.events")

T.section("an event offered again with the same text is left alone")
local single = events:getOrAddEvent("Buttons", "single", "Single", "When Single is pressed")
local double = events:getOrAddEvent("Buttons", "double", "Double", "When Double is pressed")
adds = {}
local again = events:getOrAddEvent("Buttons", "single", "Single", "When Single is pressed")
T.eq("the same id", again.eventId, single.eventId)
T.eq("and no declaration", adds, {})

T.section("a changed description updates the event under its id")
adds = {}
local described = events:getOrAddEvent("Buttons", "single", "Single", "When NAME Single is pressed")
T.eq("the same id", described.eventId, single.eventId)
T.eq("declared once, under that id", adds, { single.eventId })
T.eq("with the new description", ShimEvents()[single.eventId].description, "When NAME Single is pressed")
T.eq("and returned with it", described.description, "When NAME Single is pressed")

T.section("a changed name updates the event under its id")
adds = {}
local renamed = events:getOrAddEvent("Buttons", "double", "Double press", "When Double is pressed")
T.eq("the same id", renamed.eventId, double.eventId)
T.eq("declared once, under that id", adds, { double.eventId })
T.eq("with the new name", ShimEvents()[double.eventId].name, "Double press")

T.section("the new text is what a restart declares")
adds = {}
events = restart()
T.eq("the description", ShimEvents()[single.eventId].description, "When NAME Single is pressed")
T.eq("the name", ShimEvents()[double.eventId].name, "Double press")
T.eq("each event once", #adds, 2)
adds = {}
events:getOrAddEvent("Buttons", "single", "Single", "When NAME Single is pressed")
T.eq("offered again after it, nothing is declared", adds, {})

T.finish()
