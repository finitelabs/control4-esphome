-- Tests the Programming events an ESPHome event entity declares: they are
-- declared again when the driver loads, and they follow the entity's name,
-- keeping their ids so programming stays attached.
--
-- ESPHome derives the key from the name, so a rename that keeps the key
-- (capitals, spaces for underscores) reaches the driver as the same entity
-- under a new name.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_event_names.lua

local T = require("testlib")
local E = require("esphome_fixtures")

local KEY = 2705582719 -- fnv1_hash_object_id("Front door bell"), and of "Front Door Bell"

local function doorbell(name)
  return {
    info = { name = "doorbell" },
    entities = {
      {
        message = "ListEntitiesEventResponse",
        body = { key = KEY, name = name, event_types = { "press", "double_press" } },
      },
    },
    states = {},
  }
end

--- Declared events as id -> name.
local function declared()
  local out = {}
  for id, event in pairs(ShimEvents()) do
    out[id] = event.name
  end
  return out
end

T.section("A new event entity declares one event per type")
E.wipe()
E.boot()
E.refresh(doorbell("Front door bell"))
T.eq("declared", declared(), { [10] = "Front door bell: press", [11] = "Front door bell: double_press" })

T.section("The driver declares its events again when it loads")
E.boot()
T.eq("declared before the device connects", declared(), {
  [10] = "Front door bell: press",
  [11] = "Front door bell: double_press",
})

T.section("A rename on the device renames the events in place")
E.refresh(doorbell("Front Door Bell"))
T.eq("same ids, new names", declared(), { [10] = "Front Door Bell: press", [11] = "Front Door Bell: double_press" })
T.eq("description", (ShimEvents()[10] or {}).description, "Front Door Bell press event")
E.boot()
T.eq("and they load under the new names", declared(), {
  [10] = "Front Door Bell: press",
  [11] = "Front Door Bell: double_press",
})

T.section("Where Director kept the events, the rename lands the same")
E.boot(true)
E.refresh(doorbell("Front door bell"))
T.eq("same ids, new names", declared(), { [10] = "Front door bell: press", [11] = "Front door bell: double_press" })

T.section("An unnamed event declared before the naming fix takes its device's name")
do
  -- What the driver declared for an unnamed event on ESPHome 2026.4.0 and later.
  E.wipe()
  E.boot()
  require("lib.persist"):set("Events", {
    event_24076872 = { press = { eventId = 10, name = ": press", description = " press event" } },
  })
  E.boot()
  E.refresh({
    info = { name = "office-plug", friendly_name = "Office Plug" },
    entities = { { message = "ListEntitiesEventResponse", body = { key = 24076872, event_types = { "press" } } } },
    states = {},
  })
  T.eq("same id, device name", declared(), { [10] = "Office Plug: press" })
end

T.finish()
