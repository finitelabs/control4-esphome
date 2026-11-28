-- What lib/persist.lua writes when a migration in src/migrations.lua runs. A migration
-- runs at every driver start, so one that finds nothing to change must not rewrite its key.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_migration_noop.lua

local T = require("testlib")

require("c4_shim")

-- A fresh instance has an empty cache, so get() reads storage as it does after a reload.
local function reload()
  ShimPersistLand()
  return getmetatable(require("lib.persist")):new()
end

package.preload["migrations"] = function()
  return {
    Same = function(value)
      return value
    end,
    Rebuilt = function(value)
      return { level = value.level, ramp = { up = value.ramp.up } }
    end,
    Changed = function(value)
      return { version = 2, items = value }
    end,
    InPlace = function(value)
      value.level = 100
      return value
    end,
    Scalar = function(value)
      return value
    end,
    ToNil = function()
      return nil
    end,
    ToEmpty = function()
      return ""
    end,
    NumberToString = function(value)
      return tostring(value)
    end,
    TableToString = function(value)
      return value.name
    end,
  }
end

-- Stored through a persist of its own: the migrations load at the first get() of the process.
local seed = reload()
seed:set("Same", { level = 50 })
seed:set("Rebuilt", { level = 50, ramp = { up = 1 } })
seed:set("Changed", { "a", "b" })
seed:set("InPlace", { level = 50 })
seed:set("Scalar", "Den")
seed:set("ToNil", { level = 50 })
seed:set("ToEmpty", "Den")
seed:set("NumberToString", 5)
seed:set("TableToString", { name = "Den" })

local writes = {}
local set = C4.PersistSetValue
C4.PersistSetValue = function(self, key, ...)
  writes[key] = (writes[key] or 0) + 1
  return set(self, key, ...)
end

local p = reload()

T.section("a migration that returns its input untouched")
T.eq("reads the stored value", p:get("Same"), { level = 50 })
T.eq("and writes nothing", writes.Same, nil)
T.eq("nor for a string", p:get("Scalar"), "Den")
T.eq("which stays unwritten", writes.Scalar, nil)

T.section("a migration that builds an equal table")
T.eq("reads the same contents", p:get("Rebuilt"), { level = 50, ramp = { up = 1 } })
T.eq("and writes nothing", writes.Rebuilt, nil)

T.section("a migration that changes the value")
T.eq("reads the new value", p:get("Changed"), { version = 2, items = { "a", "b" } })
T.eq("written once", writes.Changed, 1)
T.eq("a table changed in place reads its change", p:get("InPlace"), { level = 100 })
T.eq("and is written once", writes.InPlace, 1)

T.section("a migration that changes the value's kind")
T.eq("to nil deletes the key", p:get("ToNil", "default"), "default")
T.eq('to "" deletes it too', p:get("ToEmpty", "default"), "default")
T.eq("a number to a string reads the string", p:get("NumberToString"), "5")
T.eq("and is written once", writes.NumberToString, 1)
T.eq("a table to a string reads the string", p:get("TableToString"), "Den")
T.eq("and is written once", writes.TableToString, 1)

C4.PersistSetValue = set
local after = reload()
T.eq("each reads back after a reload", {
  after:get("ToNil", "default"),
  after:get("ToEmpty", "default"),
  after:get("NumberToString"),
  after:get("TableToString"),
}, { "default", "default", "5", "Den" })
T.eq("both read back after a reload", { reload():get("Changed"), reload():get("InPlace") }, {
  { version = 2, items = { "a", "b" } },
  { level = 100 },
})

T.finish()
