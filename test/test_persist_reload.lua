-- What lib/persist.lua reads back after a reload. A string is stored raw, and
-- every shipped build read one with a space or punctuation, or under four
-- characters, back as the default at a driver update.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_reload.lua

local T = require("testlib")

require("c4_shim")

-- A fresh instance has an empty cache, so get() reads storage as it does after a reload.
local function reload()
  return getmetatable(require("lib.persist")):new()
end

T.section("a string reads back as itself")
local p = reload()
p:set("Room", "Living Room")
p:set("Short", "Den")
p:set("Numeric", "12.5")
p:set("Secret", "Living Room", true)
local q = reload()
T.eq("one with a space", q:get("Room", "default"), "Living Room")
T.eq("one under four characters", q:get("Short", "default"), "Den")
T.eq("one that looks like a number, as a string", q:get("Numeric", "default"), "12.5")
-- The shim keeps one store for both flags, so this only documents that an encrypted string reads the same.
T.eq("one set encrypted", q:get("Secret", "default", true), "Living Room")
T.eq("stored raw, as every shipped build stored it", C4:PersistGetValue("Room"), "Living Room")

T.section("a number, a boolean and a table read back as themselves")
p:set("Number", 187723572702975)
p:set("Boolean", false)
p:set("Table", { name = "Living Room", ids = { 1, 2 } })
q = reload()
T.eq("a number, exactly", q:get("Number"), 187723572702975)
T.eq("a boolean", q:get("Boolean", true), false)
T.eq("a table", q:get("Table"), { name = "Living Room", ids = { 1, 2 } })

T.section("an older build's NaN reads as the default")
C4:PersistSetValue("NaN", 0 / 0)
T.eq("not as Director's text for it", reload():get("NaN", "default"), "default")

T.section('"" or NaN deletes the key')
p:set("Code", "1234", true)
p:set("Code", "", true)
T.eq('an encrypted string set to "" reads as the default', reload():get("Code", "default", true), "default")
p:set("Reading", 0 / 0)
T.eq("a NaN is not stored", C4:PersistGetValue("Reading"), nil)

-- Known limits: telling these from a string would need a new stored form.
T.section("a string that is base64 of JSON reads as that JSON, as it always did")
p:set("Lookalike", "MTIz")
T.eq('"MTIz" reads as 123', reload():get("Lookalike"), 123)

T.section("a string that is a JSON object or array reads as that JSON, as it always did")
-- Director reads '{"a":1}' back from storage as a table, and '{":number:":5}' as 5. The shim
-- keeps the text, so this puts back what Director returns.
p:set("JsonText", '{"a":1}')
C4:PersistSetValue("JsonText", JSON:decode(C4:PersistGetValue("JsonText")))
T.eq('{"a":1} reads as a table', reload():get("JsonText"), { a = 1 })

T.finish()
