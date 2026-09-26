-- Variable ids in lib/values.lua. Programming binds to a variable's id, so with
-- C4.SetVariableName (OS 4.0+) each name keeps its id through driver updates,
-- Director restarts, deletes, reset and the switch from an older build. Without
-- it, restore adds variables by name as older builds did.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_values_ids.lua

local T = require("testlib")
local H = require("values_harness")

--- Asserts the visible ids now, after a driver update, which adds no variable,
--- and after a Director restart. Returns the module of the last load.
local function holds(label, ids)
  T.eq(label, H.visible(), ids)
  H.load("update")
  T.eq(label .. " after a driver update", H.visible(), ids)
  T.eq("which adds no variable", H.called("^Add"), false)
  local values = H.load("restart")
  T.eq(label .. " after a Director restart", H.visible(), ids)
  return values
end

--- A clean install, loaded.
local function fresh()
  H.wipe()
  return H.load("restart")
end

T.section("new variables take ids from 1001 and keep them")
local values = fresh()
values:update("A", "1", "STRING")
values:update("B", 2, "NUMBER")
values:update("Json", "{}")
values:update("C", true, "BOOL")
holds("the ids", { A = 1001, B = 1002, C = 1003 })
local blob = H.blob()
T.eq("each record keeps its id", { blob.A.id, blob.B.id, blob.C.id }, { 1001, 1002, 1003 })
T.eq("a plain value has none", blob.Json.id, nil)

T.section("a load that changes no id does not write the values")
values = fresh()
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
local set, writes = C4.PersistSetValue, 0
C4.PersistSetValue = function(self, key, ...)
  writes = writes + (key == "Values" and 1 or 0)
  return set(self, key, ...)
end
H.load("update")
H.load("restart")
C4.PersistSetValue = set
T.eq("through a driver update and a Director restart", writes, 0)

T.section("a deleted name's id is not given to another")
values = fresh()
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
values:update("C", "3", "STRING")
values:delete("C")
T.eq("C's variable is gone", Variables["C"], nil)
T.eq("its record keeps its id", (values:getValue("C") or {}).id, 1003)
values = holds("the others keep theirs", { A = 1001, B = 1002 })
values:update("D", "4", "STRING")
T.eq("a new name takes the next id", H.visible().D, 1004)
values:update("Json", "{}")
values:delete("Json")
T.eq("deleting a value that never had a variable removes it", values:getValue("Json"), nil)

for _, case in ipairs({
  { "in the same load" },
  { "after a driver update", "update" },
  { "after a Director restart", "restart" },
}) do
  T.section("a deleted name comes back at its id " .. case[1])
  values = fresh()
  values:update("A", "1", "STRING")
  -- nil, which a delete leaves too, so only the delete tells the return apart
  values:update("B", nil, "NUMBER")
  values:update("C", "3", "STRING")
  values:delete("B")
  if case[2] then
    values = H.load(case[2])
  end
  values:update("B", nil, "NUMBER")
  holds("B is back", { A = 1001, B = 1002, C = 1003 })
end

T.section("a name that reads as a number is still its own variable")
values = fresh()
values:update("A", "1", "STRING")
values:update("1001", "x", "STRING") -- Director reads "1001" as A's id
values:update("1001", "y", "STRING")
T.eq("a set reaches it, not A", { Variables["1001"], Variables["A"] }, { "y", "1" })
values:delete("1001")
T.eq("and so does a delete", H.visible(), { A = 1001 })

T.section("a variable that becomes a plain value keeps its id")
values = fresh()
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
values:update("C", "3", "STRING")
values:update("B", "2")
T.eq("B's variable is gone", Variables["B"], nil)
values = holds("while B is plain", { A = 1001, C = 1003 })
values:update("B", "2", "STRING")
T.eq("B is a variable at its id again", H.visible().B, 1002)
values:update("B", "2")
values:delete("B")
values:update("B", "2", "STRING")
holds("and after a delete while plain", { A = 1001, B = 1002, C = 1003 })

T.section("reset keeps each name's id")
values = fresh()
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
values:reset()
T.eq("reset removes every variable", H.visible(), {})
values = H.load("restart")
values:update("B", "2", "STRING")
values:update("C", "3", "STRING")
values:update("A", "1", "STRING")
holds("the names come back at their ids", { A = 1001, B = 1002, C = 1003 })

T.section("an id another variable has is left to it")
values = fresh()
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
ShimRestartDirector()
C4:AddVariable(1002, "", "STRING", true, false)
C4:AddVariable(1003, "", "STRING", true, false)
H.load("update") -- restores into a Director that gave B's id and the next to others
T.eq("B takes the next free id", H.visible().B, 1004)
T.eq("which its record keeps", H.blob().B.id, 1004)

T.section("a name Director will not give a variable is not tried again in that load")
values = fresh()
local rename = C4.SetVariableName
C4.SetVariableName = function(self, id, name)
  return name ~= "Bad" and rename(self, id, name)
end
values:update("Bad", "1", "STRING")
values:update("Bad", "2", "STRING")
C4.SetVariableName = rename
T.eq("its variable is deleted, and the second update adds none", H.calls, { "Add #1001->1001", "Delete #1001" })

T.section("an empty name is never a variable")
values = fresh()
values:update("", "1", "STRING")
values:update("", "2", "STRING")
T.eq("Director cannot name one, so none is added", H.layout(), {})

T.section("a variable Director raises on does not stop restore")
values = fresh()
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
values:update("C", "3", "STRING")
local add = C4.AddVariable
C4.AddVariable = function(self, identifier, ...)
  if identifier == 1002 then
    error("refused")
  end
  return add(self, identifier, ...)
end
H.load("restart")
C4.AddVariable = add
T.eq("the others are restored at their ids", H.visible(), { A = 1001, C = 1003 })

T.section("stored values that are not a table")
H.wipe()
C4:PersistSetValue("Values", "not a table")
local ok, loaded = pcall(H.load, "update")
T.check("restore does not raise", ok, loaded)
T.eq("and starts with no values", ok and loaded:getValues(), {})

--- A clean install with `records` stored, as v0.9.28 writes them.
local function stored(records)
  H.wipe()
  C4:PersistSetValue("Values", Serialize(records))
end

--- Records as v0.9.28 stores them, with no ids: B deleted, and J, a plain value, deleted too.
local OLDER_VALUES = {
  A = { index = 1, varType = "STRING", value = "a", writable = false },
  B = { index = 2, varType = "STRING", writable = false, deleted = true },
  J = { index = 3, writable = false, deleted = true },
  C = { index = 4, varType = "NUMBER", value = 3, suffix = " %", writable = true },
  E = { index = 5, varType = "BOOL", value = true, writable = false },
}

--- Storage and Director as v0.9.28 leaves them: A 1001, E 1002, C 1004, and J and B hidden at 1003 and 1005.
local function older()
  stored(OLDER_VALUES)
  -- Its restore after a restart adds each variable by name in index order, J's as a hidden placeholder
  C4:AddVariable("A", "a", "STRING", true, false)
  C4:AddVariable("B", "b", "STRING", true, false)
  C4:AddVariable("J", "", "STRING", true, true)
  C4:AddVariable("C", "3", "NUMBER", false, false)
  -- After an update B is deleted and E takes its id; the next update's restore adds B's placeholder
  ShimUpdateDriver()
  C4:DeleteVariable("B")
  C4:AddVariable("E", "1", "BOOL", true, false)
  ShimUpdateDriver()
  C4:AddVariable("B", "", "STRING", true, true)
end

--- name -> id of every record that has one.
local function ids()
  local out = {}
  for name, record in pairs(H.blob()) do
    out[name] = record.id
  end
  return out
end

T.section("the switch from an older build at a driver update keeps every id Director has")
older()
H.load("update")
T.eq("each record takes its variable's id, hidden or not", ids(), { A = 1001, B = 1005, C = 1004, E = 1002, J = 1003 })
values = H.load("restart")
T.eq("which a Director restart keeps", H.visible(), { A = 1001, C = 1004, E = 1002 })
values:update("B", "b", "STRING")
T.eq("and B comes back at its id", H.visible().B, 1005)

T.section("the switch from an older build at a Director restart keeps the ids that build's restore gives")
older()
values = H.load("restart")
T.eq("each record takes its id in index order", ids(), { A = 1001, B = 1002, C = 1004, E = 1005, J = 1003 })
values:update("B", "b", "STRING")
T.eq("B comes back at its id in that load", H.visible().B, 1002)
H.load("update")
H.load("restart")
T.eq("and later loads keep every id", H.visible(), { A = 1001, B = 1002, C = 1004, E = 1005 })

T.section("Director's variable list failing at the switch loses no variable")
older()
local before, list = H.layout(), C4.GetDeviceVariables
C4.GetDeviceVariables = function()
  error("unavailable")
end
ok, loaded = pcall(H.load, "update")
T.check("a list that raises does not fail restore", ok, loaded)
C4.GetDeviceVariables = function()
  return {}
end
values = H.load("update")
C4.GetDeviceVariables = list
T.eq("an empty one is not trusted, so no record takes an id", ids(), {})
values:update("B", "b", "STRING")
T.eq("and a name back in that load moves no variable, as on v0.9.28", H.layout(), before)
values:update("N", "n", "STRING")
T.eq("nor does a new name take an id", ids(), {})
H.load("update")
H.load("restart")
local want = { A = 1001, B = 1005, C = 1004, E = 1002, N = 1006 }
T.eq("the next load learns each id, which a restart keeps", H.visible(), want)

T.section("a list that is not current at a later load keeps each recorded id")
values = fresh()
values:update("A", "a", "STRING")
values:update("B", "b", "STRING")
values:delete("A")
C4.GetDeviceVariables = function()
  return {}
end
values = H.load("update")
C4.GetDeviceVariables = list
values:update("A", "a", "STRING")
values:update("N", "n", "STRING")
T.eq("so a deleted name comes back at its id, a new name at the next", H.visible(), { A = 1001, B = 1002, N = 1003 })

T.section("a variable v0.9.28 rewrote keeps its id through a downgrade and back")
-- This build gave A, B and C their ids; v0.9.28 rewrote A's record without its id
stored({
  A = { index = 1, varType = "STRING", value = "a2", writable = false },
  B = { index = 2, id = 1002, varType = "STRING", value = "b", writable = false },
  C = { index = 3, id = 1003, varType = "STRING", value = "c", writable = false },
})
C4:AddVariable("A", "a2", "STRING", true, false)
C4:AddVariable("B", "b", "STRING", true, false)
C4:AddVariable("C", "c", "STRING", true, false)
H.load("update")
T.eq("the load back records A's id", ids(), { A = 1001, B = 1002, C = 1003 })
H.load("restart")
T.eq("which a restart keeps", H.visible(), { A = 1001, B = 1002, C = 1003 })

T.section("a variable v0.9.28 rewrote keeps its id when the way back is a Director restart")
-- v0.9.28 rewrote A and D without their ids, and deleted J, a plain value its restore
-- holds 1003 for with a placeholder
stored({
  A = { index = 1, varType = "STRING", value = "a2", writable = false },
  B = { index = 2, id = 1002, varType = "STRING", value = "b", writable = false },
  J = { index = 3, writable = false, deleted = true },
  C = { index = 4, id = 1004, varType = "STRING", value = "c", writable = false },
  D = { index = 5, varType = "STRING", value = "d2", writable = false },
})
H.load("restart")
holds("each takes the id v0.9.28's restore gives it", { A = 1001, B = 1002, C = 1004, D = 1005 })

T.section("a driver update after a restart on v0.9.28 learns the ids that restart gave")
-- P was a plain value when B was added, so this build gave B 1002 and P 1003. v0.9.28's
-- restart adds them in index order, P at 1002 and B at 1003, and rewrites no record.
stored({
  A = { index = 1, id = 1001, varType = "STRING", value = "a", writable = false },
  P = { index = 2, id = 1003, varType = "STRING", value = "p", writable = false },
  B = { index = 3, id = 1002, varType = "STRING", value = "b", writable = false },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("P", "p", "STRING", true, false)
C4:AddVariable("B", "b", "STRING", true, false)
values = H.load("update")
values:update("B", "b2", "STRING")
T.eq("a set of B reaches B's variable", { Variables.B, Variables.P }, { "b2", "p" })
holds("and each keeps the id Director has", { A = 1001, B = 1003, P = 1002 })

T.section("a set or delete reaches its own variable when a list that is not current leaves an id stale")
-- As above, but Director's list leaves out every variable, so the ids this build recorded stand
stored({
  A = { index = 1, id = 1001, varType = "STRING", value = "a", writable = false },
  P = { index = 2, id = 1003, varType = "STRING", value = "p", writable = false },
  B = { index = 3, id = 1002, varType = "STRING", value = "b", writable = false },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("P", "p", "STRING", true, false)
C4:AddVariable("B", "b", "STRING", true, false)
C4.GetDeviceVariables = function()
  return {}
end
values = H.load("update")
C4.GetDeviceVariables = list
values:update("B", "b2", "STRING")
T.eq("a set of B reaches B's variable", { Variables.B, Variables.P }, { "b2", "p" })
values:delete("B")
T.eq("and so does a delete", H.visible(), { A = 1001, P = 1002 })

T.section("a deleted name keeps its id when v0.9.28 put its placeholder at another's")
-- X was a plain value when B was added, so this build gave B 1002 and X 1003, then deleted both.
-- v0.9.28's restore at a driver update adds their placeholders by name, X's at 1002 and B's at 1003.
stored({
  A = { index = 1, id = 1001, varType = "STRING", value = "a", writable = false },
  X = { index = 2, id = 1003, varType = "STRING", writable = false, deleted = true },
  B = { index = 3, id = 1002, varType = "STRING", writable = false, deleted = true },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("X", "", "STRING", true, true)
C4:AddVariable("B", "", "STRING", true, true)
values = H.load("update")
values:update("X", "x", "STRING")
values:update("B", "b", "STRING")
holds("so each comes back at its own id", { A = 1001, B = 1002, X = 1003 })

T.section("a name v0.9.28 deleted with no id does not take an id a deleted value keeps")
-- This build gave X 1003, as F, a variable no record names, had 1002. v0.9.28 then rewrote A,
-- deleted X, and rewrote and deleted Y.
stored({
  A = { index = 1, varType = "STRING", value = "a2", writable = false },
  X = { index = 2, id = 1003, varType = "STRING", writable = false, deleted = true },
  Y = { index = 3, varType = "STRING", writable = false, deleted = true },
  Z = { index = 4, value = "z", writable = false },
})
C4:AddVariable("A", "a2", "STRING", true, false)
C4:AddVariable("F", "", "STRING", true, false)
values = H.load("update")
T.eq("Y takes none, and F keeps its id under a deleted record", ids(), { A = 1001, F = 1002, X = 1003 })
values:update("Y", "y", "STRING")
values:update("X", "x", "STRING")
T.eq("so Y comes back at a new id, X at its own", H.visible(), { A = 1001, F = 1002, X = 1003, Y = 1004 })

T.section("a name v0.9.28 deleted in its last load takes the id its restore gave it, if no variable has it")
stored({
  A = { index = 1, varType = "STRING", value = "a", writable = false },
  J = { index = 2, value = "{}", writable = false },
  B = { index = 3, varType = "STRING", value = "b", writable = false },
  C = { index = 4, varType = "STRING", writable = false, deleted = true },
  D = { index = 5, varType = "STRING", writable = false, deleted = true },
  E = { index = 6, varType = "STRING", value = "e", writable = false },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("B", "b", "STRING", true, false)
C4:AddVariable("C", "c", "STRING", true, false)
C4:AddVariable("D", "d", "STRING", true, false)
-- In its last load, after an update, C was deleted, E took C's id, and D was deleted
ShimUpdateDriver()
C4:DeleteVariable("C")
C4:AddVariable("E", "e", "STRING", true, false)
C4:DeleteVariable("D")
H.load("update")
T.eq("D takes 1004, and C none, as E has 1003", ids(), { A = 1001, B = 1002, D = 1004, E = 1003 })
values = H.load("restart")
values:update("C", "c", "STRING")
values:update("D", "d", "STRING")
T.eq("so D comes back there, and C at a new id", H.visible(), { A = 1001, B = 1002, C = 1005, D = 1004, E = 1003 })

T.section("a name v0.9.28 deleted takes the id its restart gave it, though a variable Director moved had it")
-- X was a plain value when B and Y were added, so this build gave them 1002 and 1003 and X 1004.
-- v0.9.28's restart put X at 1002, B at 1003 and Y at 1004, then it rewrote and deleted Y, whose
-- record P, after it, keeps from v0.9.28's trim.
stored({
  A = { index = 1, id = 1001, varType = "STRING", value = "a", writable = false },
  X = { index = 2, id = 1004, varType = "STRING", value = "x", writable = false },
  B = { index = 3, id = 1002, varType = "STRING", value = "b", writable = false },
  Y = { index = 4, varType = "STRING", writable = false, deleted = true },
  P = { index = 5, value = "{}", writable = false },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("X", "x", "STRING", true, false)
C4:AddVariable("B", "b", "STRING", true, false)
values = H.load("update")
values:update("N", "n", "STRING")
values:update("Y", "y", "STRING")
T.eq("so Y comes back there, N at the next id", H.visible(), { A = 1001, B = 1003, N = 1005, X = 1002, Y = 1004 })

T.section("a deleted name v0.9.28 added back is shown at its id")
-- v0.9.28 deleted B and saved it again with no value, which left its record deleted but added its variable
stored({
  A = { index = 1, varType = "STRING", value = "a", writable = false },
  B = { index = 2, varType = "NUMBER", writable = false, deleted = true },
  C = { index = 3, varType = "STRING", value = "c", writable = false },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("B", "2", "NUMBER", true, false)
C4:AddVariable("C", "c", "STRING", true, false)
C4:DeleteVariable("B")
C4:AddVariable("B", "", "NUMBER", true, false)
H.load("update")
H.load("restart")
T.eq("through the switch and a restart", H.visible(), { A = 1001, B = 1004, C = 1003 })
-- Had this build given B 1002, its record would keep it, and v0.9.28 could add B back there
stored({
  A = { index = 1, id = 1001, varType = "STRING", value = "a", writable = false },
  B = { index = 2, id = 1002, varType = "NUMBER", writable = false, deleted = true },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("B", "", "NUMBER", true, false)
H.load("update")
T.eq("and at the id its record keeps, the switch leaves its variable be", H.calls, {})

T.section("a plain value v0.9.28 deleted keeps its placeholder's id at a restart")
-- J was a variable, then a plain value, then deleted; v0.9.28's restore holds its id with a placeholder
stored({
  J = { index = 1, writable = false, deleted = true },
  K = { index = 2, value = "{}", writable = false },
})
values = H.load("restart")
values:update("N", "n", "STRING")
T.eq("so a new name takes the next id", ids(), { J = 1001, N = 1002 })

T.section("a plain value v0.9.28 deleted keeps its place when a list that is not current loads by name")
-- v0.9.28's restart held J's id with a placeholder; J is then saved and deleted again
stored({
  A = { index = 1, varType = "STRING", value = "a", writable = false },
  J = { index = 2, writable = false, deleted = true },
  B = { index = 3, varType = "STRING", value = "b", writable = false },
  C = { index = 4, varType = "STRING", value = "c", writable = false },
})
C4:AddVariable("A", "a", "STRING", true, false)
C4:AddVariable("J", "", "STRING", true, true)
C4:AddVariable("B", "b", "STRING", true, false)
C4:AddVariable("C", "c", "STRING", true, false)
C4.GetDeviceVariables = function()
  return {}
end
values = H.load("update")
C4.GetDeviceVariables = list
values:update("J", "{}")
values:delete("J")
H.load("restart")
T.eq("so a restart keeps B and C", H.visible(), { A = 1001, B = 1003, C = 1004 })

T.section("without a rename, restore adds variables by name as older builds did")
ShimVariableRename(false)
values = fresh()
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
values:update("C", "3", "STRING")
values:delete("B")
H.load("restart")
T.eq("in index order, B held by a hidden placeholder", H.layout(), { [1001] = "A", [1002] = "B(h)", [1003] = "C" })
T.eq("and no record has an id", H.blob().A.id, nil)

T.section("without a rename, a plain value v0.9.28 deleted keeps its placeholder's slot")
stored({
  A = { index = 1, varType = "STRING", value = "a", writable = false },
  J = { index = 2, writable = false, deleted = true },
  C = { index = 3, varType = "STRING", value = "c", writable = false },
})
values = H.load("restart")
values:update("J", "{}")
values = H.load("restart")
T.eq("so C keeps its id while J is saved again", H.visible(), { A = 1001, C = 1003 })
values:delete("J")
H.load("restart")
T.eq("and after J is deleted", H.visible(), { A = 1001, C = 1003 })
ShimVariableRename(true)

T.finish()
