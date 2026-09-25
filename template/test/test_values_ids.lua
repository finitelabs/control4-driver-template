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

--- Records as v0.9.28 stores them, with no ids: B deleted, J a plain value.
local OLDER_VALUES = {
  A = { index = 1, varType = "STRING", value = "a", writable = false },
  B = { index = 2, varType = "STRING", writable = false, deleted = true },
  J = { index = 3, value = "{}", writable = false },
  C = { index = 4, varType = "NUMBER", value = 3, suffix = " %", writable = true },
  E = { index = 5, varType = "BOOL", value = true, writable = false },
}

--- Storage and Director as v0.9.28 leaves them: A 1001, E 1002, C 1003, B hidden at 1004.
local function older()
  H.wipe()
  C4:PersistSetValue("Values", Serialize(OLDER_VALUES))
  -- Its restore after a restart adds each variable by name in index order
  C4:AddVariable("A", "a", "STRING", true, false)
  C4:AddVariable("B", "b", "STRING", true, false)
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
T.eq("each record takes its variable's id, B's hidden one too", ids(), { A = 1001, B = 1004, C = 1003, E = 1002 })
values = H.load("restart")
T.eq("which a Director restart keeps", H.visible(), { A = 1001, C = 1003, E = 1002 })
values:update("B", "b", "STRING")
T.eq("and B comes back at its id", H.visible().B, 1004)

T.section("the switch from an older build at a Director restart restores as that build did")
older()
values = H.load("restart")
T.eq("by name in index order, B hidden", H.layout(), { [1001] = "A", [1002] = "B(h)", [1003] = "C", [1004] = "E" })
T.eq("then each record takes its variable's id", ids(), { A = 1001, B = 1002, C = 1003, E = 1004 })
values:update("B", "b", "STRING")
T.eq("B comes back at its id in that load", H.visible().B, 1002)
H.load("update")
H.load("restart")
T.eq("and later loads keep every id", H.visible(), { A = 1001, B = 1002, C = 1003, E = 1004 })

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
H.load("update")
H.load("restart")
T.eq("the next load learns each id, which a restart keeps", H.visible(), { A = 1001, B = 1004, C = 1003, E = 1002 })

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
ShimVariableRename(true)

T.finish()
