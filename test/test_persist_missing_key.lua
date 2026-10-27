-- What lib/persist.lua gives for a key that is not stored. Every shipped build
-- gave one table shared by all such keys, which `persist:get(key) or {}` wrote
-- into, and kept the first default a key was read with as its value.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_missing_key.lua

local T = require("testlib")

require("c4_shim")

-- A fresh instance has an empty cache, so get() reads storage as it does after a reload.
local function reload()
  ShimPersistLand()
  return getmetatable(require("lib.persist")):new()
end

-- Migrations load at the first get() of the process, so these are in place before any.
local migrated = {}
local function migration(value)
  migrated[#migrated + 1] = type(value)
  return value
end
package.preload["migrations"] = function()
  return {
    Legacy = migration,
    Seeded = migration,
    Stored = migration,
    Emptied = function()
      return nil
    end,
  }
end

T.section("a key that is not stored, read with no default, is nil")
local p = reload()
T.eq("at the first read", p:get("Missing"), nil)
T.eq("and at the next", p:get("Missing"), nil)
local colors = p:get("Colors") or {}
colors.on = "ff0000"
T.eq("so a write into `get(key) or {}` reaches no other key", p:get("Presets"), nil)
T.eq("nor the key itself until it is set", p:get("Colors"), nil)

T.section("a default is the call's alone")
T.eq("the default it was read with", p:get("Level", 5), 5)
T.eq("another default at the next read", p:get("Level", 7), 7)
T.eq("and nil with none", p:get("Level"), nil)
ShimPersistLand()
T.eq("nothing was stored for it", C4:PersistGetValue("Level"), nil)

T.section("a table default comes back as a copy")
local defaults = { rate = 250, ramp = { up = 1 } }
local got = p:get("Rates", defaults)
T.eq("with the default's contents", got, { rate = 250, ramp = { up = 1 } })
got.rate = 0
got.ramp.up = 0
T.eq("the caller's table is not written through it, at any depth", defaults, { rate = 250, ramp = { up = 1 } })
T.eq("and the key is still not stored", p:get("Rates"), nil)

T.section("a deleted key reads as one that was never stored")
p:set("Room", "Den")
p:set("Room", nil) -- in the call that set it, so the set lands after the delete
T.eq("nil with no default", p:get("Room"), nil)
T.eq("the default with one", p:get("Room", "default"), "default")
T.eq("and the same after a reload", reload():get("Room"), nil)
p:set("Room", "Den")
p:set("Room", "")
T.eq('one set to "" reads the same', p:get("Room", "default"), "default")
p:set("Room", "Den")
p:set("Room", 0 / 0)
T.eq("and so does one set to a NaN", p:get("Room", "default"), "default")

T.section("a stored value is not a missing one")
p:set("Empty", {})
p:set("Off", false)
p:set("Zero", 0)
local q = reload()
T.eq("an empty table is a table", q:get("Empty", "default"), {})
T.eq("false is false", q:get("Off", true), false)
T.eq("0 is 0", q:get("Zero", 5), 0)

T.section("a stored table comes back as a copy")
p:set("Scene", { level = 50 })
p:get("Scene").level = 0
T.eq("a write into it does not reach the stored value", p:get("Scene"), { level = 50 })

T.section("a migration is not run for a key that is not stored")
C4:PersistSetValue("Stored", 1)
C4:PersistSetValue("Emptied", 1)
ShimPersistLand()
p:get("Legacy")
p:get("Seeded", 5)
T.eq("with a default or without", migrated, {})
ShimPersistLand()
T.eq("so the default is not stored", C4:PersistGetValue("Seeded"), nil)
T.eq("one for a stored key still runs", { p:get("Stored", 5), migrated[1] }, { 1, "number" })
T.eq("and one that deletes its key leaves the read its default", p:get("Emptied", "default"), "default")

T.section("storage is asked once for a key that is not stored")
local reads = 0
local read = C4.PersistGetValue
C4.PersistGetValue = function(...)
  reads = reads + 1
  return read(...)
end
q = reload()
q:get("Missing", 5)
q:get("Missing")
q:get("Missing", 7)
T.eq("three reads, one question", reads, 1)
reads = 0
q:set("Room", "Den")
q:set("Room", nil)
q:get("Room")
q:get("Room", "default")
C4.PersistGetValue = read
T.eq("and none for a key deleted here", reads, 0)

T.finish()
