-- Variable id slots across a reload in lib/values.lua. Restore adds variables in
-- index order, so each deleted variable leaves a hidden placeholder. Deleting a value
-- that never had a variable used to leave one too, which moved every later id.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_values_placeholders.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.lib") -- Serialize

local realAddVariable = C4.AddVariable

--- A driver reload: its variables are gone and restore adds them again, in order.
--- Returns the fresh module and each added variable as "name" or "name (hidden)".
local function reload()
  for name in pairs(Variables) do
    C4:DeleteVariable(name)
  end
  T.unload("^lib%.persist$", "^lib%.values$")
  local values = require("lib.values")
  local added = {}
  C4.AddVariable = function(self, name, value, varType, readOnly, hidden)
    table.insert(added, hidden and (name .. " (hidden)") or name)
    return realAddVariable(self, name, value, varType, readOnly, hidden)
  end
  values:restoreValues()
  C4.AddVariable = realAddVariable
  return values, added
end

local values = reload()
values:update("A", "1", "STRING")
values:update("Json", '{"x":1}') -- no varType: no variable
values:update("B", "2", "STRING")

T.section("deleting a value with no variable leaves no placeholder")
values:delete("Json")
T.eq("the record is gone", values:getValue("Json"), nil)
local added
values, added = reload()
T.eq("restore adds only the variables", added, { "A", "B" })
values:update("Json", '{"x":2}')
values, added = reload()
T.eq("saving it again moves no id", added, { "A", "B" })

T.section("deleting a variable still keeps its slot")
values:update("C", "3", "STRING")
values:update("D", "4", "STRING")
values:delete("C")
values, added = reload()
T.eq("restore adds a hidden placeholder in its place", added, { "A", "B", "C (hidden)", "D" })

T.section("a blob with a pre-fix placeholder keeps its ids")
values:reset()
-- writable is set so restore rewrites nothing, and only the move can save.
C4:PersistSetValue(
  "Values",
  Serialize({
    A = { index = 1, varType = "STRING", value = "1", writable = false },
    Json = { index = 2, deleted = true },
    B = { index = 3, varType = "STRING", value = "2", writable = false },
  })
)
values, added = reload()
T.eq("restore adds its placeholder where it always did", added, { "A", "__deleted__2 (hidden)", "B" })
T.eq("the move is saved", Deserialize(C4:PersistGetValue("Values")).Json, nil)
values:update("Json", '{"x":3}')
values, added = reload()
T.eq("saving a value of the old name moves no id", added, { "A", "__deleted__2 (hidden)", "B" })
T.eq("that value is a new record", values:getValue("Json").index, 4)

T.section("a second pre-fix placeholder of the same name keeps its own slot")
-- An older build ran after the move, saved Json again, added C and deleted Json.
local blob = Deserialize(C4:PersistGetValue("Values"))
blob.Json = { index = 4, deleted = true }
blob.C = { index = 5, varType = "STRING", value = "3" }
C4:PersistSetValue("Values", Serialize(blob))
values, added = reload()
T.eq("both placeholders stay in place", added, { "A", "__deleted__2 (hidden)", "B", "__deleted__4 (hidden)", "C" })

T.finish()
