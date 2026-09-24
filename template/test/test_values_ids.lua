-- Each variable keeps its Director id through updates, restarts, deletes, returns and reset,
-- with C4.SetVariableName (OS 4.0+) and without it (a deleted id stays held by a hidden variable).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_values_ids.lua

local T = require("testlib")
local H = require("values_harness")
local log = require("lib.logging")

-- Every error and warning lib/values logs, formatted.
local errors, warnings = {}, {}
local function collect(into, real)
  return function(self, text, ...)
    local args = { ... }
    for i = 1, select("#", ...) do
      args[i] = tostring(args[i])
    end
    table.insert(into(), string.format(text, unpack(args)))
    return real(self, text, ...)
  end
end
log.error = collect(function()
  return errors
end, log.error)
log.warn = collect(function()
  return warnings
end, log.warn)

--- How many times fn writes the stored values.
local function writesOf(fn)
  local count, real = 0, C4.PersistSetValue
  C4.PersistSetValue = function(self, key, ...)
    if key == "Values" then
      count = count + 1
    end
    return real(self, key, ...)
  end
  fn()
  C4.PersistSetValue = real
  return count
end

local MODES = {
  { rename = true, label = "with a rename" },
  { rename = false, label = "without a rename" },
}

--- Asserts the visible ids (and, without a rename, the held hidden ids) now, after a driver
--- update and after a Director restart. Returns the module of the last load.
local function holds(label, visible, hidden)
  T.eq(label .. ": ids", H.visible(), visible)
  if hidden ~= nil then
    T.eq(label .. ": held ids", H.hiddenIds(), hidden)
  end
  H.load("update")
  T.eq(label .. ": ids after a driver update", H.visible(), visible)
  T.eq(label .. ": a driver update adds nothing", H.called("^Add .*%->%d+$"), false)
  H.load("restart")
  T.eq(label .. ": ids after a Director restart", H.visible(), visible)
  if hidden ~= nil then
    T.eq(label .. ": held ids after a Director restart", H.hiddenIds(), hidden)
  end
  return H.load("update")
end

local function fresh(mode)
  H.mode(mode.rename)
  H.wipe()
  errors, warnings = {}, {}
  return H.load("restart")
end

for _, mode in ipairs(MODES) do
  local L = mode.label
  local R = mode.rename
  local none = R and {} or nil

  T.section(L .. ": new variables")
  local values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", 2, "NUMBER")
  values:update("C", true, "BOOL")
  values:update("Json", "{}")
  holds("A, B, C", { A = 1001, B = 1002, C = 1003 }, none or {})
  T.eq("each record carries its id", H.recordIds(), { A = 1001, B = 1002, C = 1003 })
  T.eq("a plain value has none", H.blob().Json.id, nil)

  T.section(L .. ": delete")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:delete("B")
  T.eq("B is gone", Variables["B"], nil)
  T.eq("its record keeps its id", values:getValue("B").id, 1002)
  T.eq("and says it is deleted", values:getValue("B").deleted, true)
  holds("after deleting B", { A = 1001, C = 1003 }, R and {} or { 1002 })
  if not R then
    H.load("restart")
    T.eq("a restart holds 1002 by number, whatever the counter does", H.called("^Add #1002%(h%)%->1002$"), true)
  end

  T.section(L .. ": a new name after a delete")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:delete("B")
  values = H.load("update")
  values:update("D", "4", "STRING")
  T.eq("does not take the deleted name's id", H.visible().D, 1004)
  values:update("B", "2", "STRING")
  holds("B and D", { A = 1001, B = R and 1002 or 1005, C = 1003, D = 1004 }, none or { 1002 })

  T.section(L .. ": the highest variable deleted, then a new name")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:delete("C")
  values = H.load("update")
  values:update("D", "4", "STRING")
  T.eq("does not take the deleted name's id", H.visible().D, 1004)
  values:update("C", "3", "STRING")
  holds("C and D", { A = 1001, B = 1002, C = R and 1003 or 1005, D = 1004 }, none or { 1003 })

  T.section(L .. ": deleting a plain value that never was a variable")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("Json", "{}")
  values:update("B", "2", "STRING")
  values:delete("Json")
  T.eq("removes its record", values:getValue("Json"), nil)
  holds("and holds nothing", { A = 1001, B = 1002 }, none or {})
  values:update("Json", "{}")
  holds("saving it again moves no id", { A = 1001, B = 1002 }, none or {})

  T.section(L .. ": delete, then the same name back in the same load")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:delete("B")
  values:update("B", "2b", "STRING")
  if R then
    T.eq("B is back at its id at once", H.visible(), { A = 1001, B = 1002, C = 1003 })
    holds("B back", { A = 1001, B = 1002, C = 1003 }, {})
  else
    T.eq("B takes a new id and 1002 stays held", H.snapshot(), "1001=A, 1002=1002(h), 1003=C, 1004=B")
    T.contains("which is logged", table.concat(warnings, "\n"), "B returns at id 1004; its id 1002 stays held")
    holds("B back", { A = 1001, B = 1004, C = 1003 }, { 1002 })
  end
  T.eq("B has its value", Variables["B"], "2b")

  for _, how in ipairs({ "update", "restart" }) do
    T.section(L .. ": delete, then the same name back after a " .. how)
    values = fresh(mode)
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:update("C", "3", "STRING")
    values:delete("B")
    values = H.load(how)
    values:update("B", "2b", "STRING")
    holds("B back", { A = 1001, B = R and 1002 or 1004, C = 1003 }, none or { 1002 })
  end

  T.section(L .. ": a variable becomes a plain value and back")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:update("B", "plain")
  T.eq("B's variable is gone", Variables["B"], nil)
  T.eq("B holds its plain value", values:getValue("B").value, "plain")
  T.eq("a plain value is not reported deleted", values:getValue("B").deleted, nil)
  T.eq("getValues agrees", values:getValues().B.deleted, nil)
  T.eq("the record keeps the id", values:getValue("B").id, 1002)
  T.eq("stored as deleted, so an older build holds its id", H.blob().B.deleted, true)
  holds("B plain", { A = 1001, C = 1003 }, none or { 1002 })
  values:update("B", "var", "STRING")
  holds("B a variable again, a load later", { A = 1001, B = R and 1002 or 1004, C = 1003 }, none or { 1002 })
  values:update("B", "plain again")
  values:update("B", "var again", "STRING")
  if R then
    holds("and within one load", { A = 1001, B = 1002, C = 1003 }, {})
  else
    holds("and within one load", { A = 1001, B = 1005, C = 1003 }, { 1002, 1004 })
  end

  T.section(L .. ": a plain value becomes a variable and back")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("J", "{}")
  values:update("B", "2", "STRING")
  values:update("J", "x", "STRING")
  holds("J a variable", { A = 1001, B = 1002, J = 1003 }, none or {})
  values:update("J", "{}")
  values:update("J", "y", "STRING")
  holds("J plain and back", { A = 1001, B = 1002, J = R and 1003 or 1004 }, none or { 1003 })

  T.section(L .. ": reset, then the names back")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING", function() end)
  values:update("Json", "{}")
  values:reset()
  T.eq("reset removes every variable", H.visible(), {})
  T.eq("and every value", (values:getValue("A") or {}).value, nil)
  T.eq("and a plain value's record", values:getValue("Json"), nil)
  T.eq("and the callbacks", OVC["B"], nil)
  T.eq("but each name keeps its id", H.recordIds(), { A = 1001, B = 1002 })
  values:update("B", "2", "STRING")
  values:update("A", "1", "STRING")
  values:update("C", "3", "STRING")
  if R then
    holds("names back after reset", { A = 1001, B = 1002, C = 1003 }, {})
  else
    holds("names back after reset", { A = 1004, B = 1003, C = 1005 }, { 1001, 1002 })
  end
  T.eq("B comes back read-only, its callback gone", H.variables()[H.visible().B].name, "B")

  T.section(L .. ": zigbee3 deletes a variable right after restore in OnDriverInit")
  values = fresh(mode)
  values:update("Last Seen", "now", "STRING")
  values:update("Relay State", "0", "BOOL")
  values:update("Occupancy State", "0", "BOOL")
  values:update("DesiredConfig", "{}")
  local layout
  for i = 1, 6 do
    values = H.load(i % 3 == 0 and "restart" or "update")
    if values:getValue("Relay State") then
      values:delete("Relay State") -- device.lua:389-390, a phantom relay
    end
    values:update("DesiredConfig", i % 2 == 0 and "{}" or '{"a":1}')
    layout = layout or H.snapshot()
    T.eq("load " .. i .. ": same layout", H.snapshot(), layout)
  end
  T.eq("no id moved", H.visible(), { ["Last Seen"] = 1001, ["Occupancy State"] = 1003 })
  T.eq("the deleted relay keeps its id", H.recordIds()["Relay State"], 1002)

  T.section(L .. ": esphome presence tracker churn, " .. (R and 300 or 60) .. " cycles")
  values = fresh(mode)
  local rooms = { "Kitchen Occupied", "Occupant Count", "Occupants" }
  values:update("Connected", true, "BOOL")
  for _, name in ipairs(rooms) do
    values:update(name, "", "STRING")
  end
  values:update("MAC Address", "aa", "STRING")
  local startIds, startCount, startSize = H.visible(), H.count(), H.blobSize()
  local startRecords = 0
  for _ in pairs(H.blob()) do
    startRecords = startRecords + 1
  end
  local cycles = R and 300 or 60
  local steady = true
  for cycle = 1, cycles do
    for _, name in ipairs(rooms) do
      values:delete(name) -- presence_tracker _cleanupRoom on a proxy disconnect
    end
    for _, name in ipairs(rooms) do
      values:update(name, "", "STRING") -- _ensureRoomSetup when the proxy reports again
    end
    if cycle % 25 == 0 then
      values = H.load("restart")
    elseif cycle % 10 == 0 then
      values = H.load("update")
    end
    if R and (not T.deepEqual(H.visible(), startIds) or H.count() ~= startCount) then
      steady = false
    end
  end
  local records = 0
  for _ in pairs(H.blob()) do
    records = records + 1
  end
  if R then
    T.check("every id is the same after every cycle", steady)
    T.eq("the variable count is the same", H.count(), startCount)
    T.eq("the blob is the same size", H.blobSize(), startSize)
    T.eq("one record per name ever used", records, startRecords)
  else
    local visible = H.visible()
    T.eq("Connected keeps its id", visible["Connected"], startIds["Connected"])
    T.eq("MAC Address keeps its id", visible["MAC Address"], startIds["MAC Address"])
    -- Accepted without a rename: each return of a deleted name leaves one hidden variable.
    T.eq("each return leaves exactly one hidden variable", #H.hiddenIds(), 3 * cycles)
    T.eq("and one record", records, startRecords + 3 * cycles)
    T.eq("every earlier id stays held", H.hiddenIds()[1], startIds["Kitchen Occupied"])
  end

  T.section(L .. ": names Director reads as ids")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("X", "x", "STRING") -- 1003
  local numeric = { "2000", "0042", "3.5", " 1020", "1e3", "0x10", "-5", "1003" }
  for _, name in ipairs(numeric) do
    T.check(
      "adding " .. string.format("%q", name) .. " does not raise",
      pcall(values.update, values, name, "v", "STRING")
    )
  end
  values:update("Y", "y", "STRING")
  if R then
    local want = { A = 1001, B = 1002, X = 1003, Y = 1012 }
    for i, name in ipairs(numeric) do
      want[name] = 1003 + i
    end
    T.eq("each is created at its own id and renamed", H.visible(), want)
    values:update("3.5", "new")
    values:update("3.5", "newer", "STRING")
    T.eq("its value is written by id", Variables["3.5"], "newer")
    values:delete("0042")
    T.eq("and it is deleted by id", H.visible()["0042"], nil)
    T.eq("with nothing else touched", H.visible().A, 1001)
    values:update("0042", "back", "STRING")
    want["3.5"] = 1006
    holds("numeric names", want, {})
  else
    local want = { A = 1001, B = 1002, X = 1003, Y = 1004, ["2000"] = 2000, ["42"] = 42, ["3"] = 3 }
    want["1020"], want["1000"], want["16"] = 1020, 1000, 16
    T.eq("each lands on the id Director reads from it", H.visible(), want)
    T.contains("a name Director raises on is logged", table.concat(errors, "\n"), "-5")
    T.contains("a name whose id is taken is logged", table.concat(errors, "\n"), "1003")
    values:update("0042", "new", "STRING")
    T.eq("its value is written by id", Variables["42"], "new")
    values:delete("2000")
    values:update("2000", "back", "STRING")
    T.eq("a numeric name comes back at the id it spells", H.visible()["2000"], 2000)
    holds("numeric names", want, {})
  end

  T.section(L .. ": a numeric-looking name Director refuses touches no other variable")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  local writes = writesOf(function()
    for _ = 1, 3 do
      values:update("1003", "x", "STRING")
    end
  end)
  T.eq("an unchanged value is written once", writes, 1)
  T.eq("and a refusal logged once", #errors, R and 0 or 1)
  values:delete("1003")
  T.eq("deleting it leaves C alone", H.visible().C, 1003)
  T.eq("and keeps a record only if it had an id", values:getValue("1003") ~= nil, R)
  values:update("1003", "x", "STRING")
  values:update("1003", "plain")
  T.eq("so does making it plain", H.visible().C, 1003)
  values:delete("B")
  H.calls = {}
  values:update("1002", "y", "STRING")
  values:delete("1002")
  values:update("1002", "y", "STRING")
  T.eq("and one named like a held id leaves the hold", { H.called("^Delete #1002$"), H.recordIds().B }, { false, 1002 })
  values = H.load("update")
  T.eq("restore writes into no other variable", H.called("^Set"), false)
  values:update("New", "n", "STRING")
  if R then
    holds("the ids", { A = 1001, C = 1003, ["1002"] = 1005, New = 1006 }, {})
  else
    holds("the ids", { A = 1001, C = 1003, New = 1004 }, { 1002 })
  end
  values:reset()
  T.eq("reset leaves every id reserved", H.recordIds().B, 1002)
  if not R then
    T.eq("and held", H.hiddenIds(), { 1001, 1002, 1003, 1004 })
  end

  T.section(L .. ": a variable renamed to another's decimal id")
  if R then
    values = fresh(mode)
    values:update("A", "1", "STRING")
    values:update("1004", "n", "STRING") -- 1002
    values:update("B", "2", "STRING") -- 1003
    values:update("C", "3", "STRING") -- 1004, while 1002 is named "1004"
    T.eq("C gets 1004 all the same", H.visible(), { A = 1001, ["1004"] = 1002, B = 1003, C = 1004 })
    values:delete("C")
    values:update("C", "3", "STRING")
    holds("both keep their ids", { A = 1001, ["1004"] = 1002, B = 1003, C = 1004 }, {})
  else
    values = fresh(mode)
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:delete("B")
    values:update("1002", "plain") -- a plain value under the key the held id 1002 would take
    values:update("B", "2", "STRING")
    T.eq("the plain value keeps its key", values:getValue("1002").value, "plain")
    T.eq("the held id moves to another key", H.blob()["#1002"].id, 1002)
    holds("B back", { A = 1001, B = 1003 }, { 1002 })
  end

  T.section(L .. ": an id Director has given to something else")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  C4:AddVariable(1003, "", "STRING", true, false) -- not ours
  values:update("C", "3", "STRING")
  T.eq("a new variable skips it", H.visible(), { A = 1001, B = 1002, ["1003"] = 1003, C = 1004 })
  H.load("update")
  T.eq("a driver update keeps every id", H.visible(), { A = 1001, B = 1002, ["1003"] = 1003, C = 1004 })
  H.load("restart")
  T.eq("so does a Director restart, which drops the other variable", H.visible(), { A = 1001, B = 1002, C = 1004 })
  -- A driver that adds its own variable before restoreValues after a restart.
  ShimRestartDirector()
  C4:AddVariable("Own", "", "STRING", true, false)
  errors = {}
  values = H.load("update")
  T.contains("restore logs the id it could not have", table.concat(errors, "\n"), "1001")
  if R then
    T.eq("only that variable moves", H.visible(), { Own = 1001, A = 1005, B = 1002, C = 1004 })
  else
    T.eq("restore records the ids Director gave", H.recordIds().A, H.visible().A)
  end
  T.check("restore completed", Variables["C"] ~= nil)

  T.section(L .. ": a held id deleted behind the library's back")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:delete("B")
  values = H.load("update")
  C4:DeleteVariable(1002) -- the driver itself, by id, after restore
  values:update("X", "x", "STRING")
  local placed = H.visible().X
  holds("X keeps the id it was given", { A = 1001, C = 1003, X = placed })
  T.eq("and no other record claims it", H.recordIds().B ~= placed, true)

  if R then
    T.section(L .. ": a hidden variable under the name at another id")
    values = fresh(mode)
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:delete("B")
    C4:AddVariable(1010, "", "STRING", true, true)
    C4:SetVariableName(1010, "B") -- a leftover under B's name, not at 1002
    values:update("B", "back", "STRING")
    T.eq("B comes back visible at its id", H.snapshot(), "1001=A, 1002=B")
    holds("B back", { A = 1001, B = 1002 }, {})
  else
    T.section(L .. ": a hidden variable under the name at another id")
    values = fresh(mode)
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:delete("B")
    C4:AddVariable("B", "", "STRING", true, true) -- a leftover under B's name, at 1003
    values:update("B", "back", "STRING")
    T.eq("B is shown at once, at a new id", H.snapshot(), "1001=A, 1002=1002(h), 1003=1003(h), 1004=B")
    T.eq("with its value", Variables["B"], "back")
    holds("B back", { A = 1001, B = 1004 }, { 1002, 1003 })

    T.section(L .. ": a held id another variable took is logged")
    values = fresh(mode)
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:update("C", "3", "STRING")
    values:delete("B")
    values = H.load("update")
    C4:DeleteVariable(1002)
    C4:AddVariable("Other", "", "STRING") -- the driver's own, by name, lands on 1002
    warnings = {}
    H.load("update")
    T.contains(
      "restore says who has it",
      table.concat(warnings, "\n"),
      "Variable id 1002 of B is taken by variable Other"
    )
    T.contains("and that it cannot be held", table.concat(warnings, "\n"), "Variable id 1002 of B is taken by another")
    T.eq("and B keeps it reserved", H.recordIds().B, 1002)

    T.section(L .. ": the driver's own value named like a held id")
    values = fresh(mode)
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:delete("B")
    values:update("B", "2", "STRING") -- 1002 is held under the key "1002"
    values:reset()
    values:update("1002", "y", "STRING")
    T.eq("does not take the held id", H.variables()[1002].hidden, true)
    T.eq("which stays reserved under another key", H.blob()["#1002"].id, 1002)
  end

  if R then
    T.section(L .. ": a rename Director refuses, or raises on")
    for _, how in ipairs({ "refuses", "raises" }) do
      values = fresh(mode)
      values:update("A", "1", "STRING")
      local realRename = C4.SetVariableName
      C4.SetVariableName = function(self, id, name)
        if name == "Odd" then
          assert(how ~= "raises", "rename failed")
          return false
        end
        return realRename(self, id, name)
      end
      local ok = true
      H.calls = {}
      for i = 1, 5 do
        ok = pcall(values.update, values, "Odd", tostring(i), "STRING") and ok
      end
      T.check("when it " .. how .. ", update does not raise", ok)
      T.eq("and the name has one variable", H.count(), 2)
      local adds = 0
      for _, call in ipairs(H.calls) do
        adds = adds + (call:match("^Add") and 1 or 0)
      end
      T.eq("added once, not again on each update", adds, 1)
      values = H.load("update")
      values:update("Odd", "6", "STRING")
      T.eq("also in the next load", H.count(), 2)
      H.load("restart")
      T.eq("and after a restart, at the same id", H.variables()[1002].name, "1002")
      C4.SetVariableName = realRename
    end
  end

  T.section(L .. ": an empty name is never a variable")
  values = fresh(mode)
  local asked, realAdd, realRename = 0, C4.AddVariable, C4.SetVariableName
  C4.AddVariable = function(self, identifier, ...)
    asked = asked + (identifier == "" and 1 or 0)
    return realAdd(self, identifier, ...)
  end
  if R then
    C4.SetVariableName = function(self, id, name)
      asked = asked + (name == "" and 1 or 0)
      return realRename(self, id, name)
    end
  end
  values:update("A", "1", "STRING")
  warnings = {}
  for i = 1, 3 do
    values:update("", "e" .. i, "STRING")
  end
  values:update("B", "2", "STRING")
  T.eq("it takes no id", H.snapshot(), "1001=A, 1002=B")
  T.eq("its value is kept as a plain value", { values:getValue("").value, values:getValue("").varType }, { "e3" })
  T.eq("which is logged once in a load", #warnings, 1)
  values = H.load("update")
  values:update("", true, "BOOL", function() end)
  T.eq("and once in the next", #warnings, 2)
  T.eq("converted as its type says", values:getValue("").value, true)
  values:delete("")
  values:update("", "back", "STRING")
  values = H.load("restart")
  values:update("", "again", "STRING")
  values:reset()
  values:update("", "after reset", "STRING")
  T.eq("no record of it has an id", H.recordIds()[""], nil)
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  holds("the others keep their ids", R and { A = 1001, B = 1002 } or { A = 1003, B = 1004 }, none or { 1001, 1002 })
  C4.AddVariable, C4.SetVariableName = realAdd, realRename
  T.eq("and Director is never asked for a variable of that name", asked, 0)

  -- The same device with and without "", each with a name Director reads as an id: identical.
  local layouts = {}
  for _, withEmpty in ipairs({ false, true }) do
    values = fresh(mode)
    for _, name in ipairs({ "A", "B", "C" }) do
      values:update(name, name, "STRING")
    end
    values:delete("C")
    values:update("1003", "n", "STRING")
    if withEmpty then
      values:update("", "e", "STRING")
    end
    values = H.load("restart")
    if withEmpty then
      values:update("", "e2", "STRING")
    end
    values:update("C", "c", "STRING")
    values = H.load("update")
    values:update("D", "d", "STRING")
    H.load("restart")
    table.insert(layouts, H.snapshot())
  end
  T.eq('beside a numeric name, "" changes no id', layouts[2], layouts[1])
  if R then
    T.eq("C keeps its id and 1003 its own", H.visible(), { A = 1001, B = 1002, C = 1003, ["1003"] = 1004, D = 1005 })
  end

  T.section(L .. ": a plain value keeps its value when another variable takes its old id")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("P", "2", "STRING")
  values:update("C", "3", "STRING")
  values:update("P", "data")
  values = H.load("update")
  C4:DeleteVariable(1002)
  values:update("X", "x", "STRING")
  T.eq("P is stored deleted only while it keeps the id", H.blob().P.deleted, R or nil)
  values = H.load("update")
  T.eq("P keeps its value", values:getValue("P").value, "data")

  T.section(L .. ": a plain value whose id a variable of another name now has keeps its value")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("P", "2", "STRING")
  values:update("P", "data")
  H.load("update")
  C4:DeleteVariable(1002) -- without a rename, the hold
  C4:AddVariable("R", "r", "STRING") -- by name, behind the library's back: 1002
  local blob = H.blob()
  blob.R = { index = 3, varType = "STRING", value = "r" }
  C4:PersistSetValue("Values", Serialize(blob))
  values = H.load("update")
  T.eq("R keeps that id", H.recordIds().R, 1002)
  T.eq("and P its value, as a plain value", { values:getValue("P").value, H.blob().P.deleted }, { "data" })

  T.section(L .. ": a driver update writes the stored value back to a variable that differs")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  ShimWriteVariable(1001, "stale")
  H.load("update")
  T.eq("A holds its stored value", Variables["A"], "1")

  T.section(L .. ": a live record with no id gets a variable after a restart")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  blob = H.blob()
  blob.N = { index = 2, varType = "STRING", value = "n" }
  C4:PersistSetValue("Values", Serialize(blob))
  H.load("restart")
  T.eq("N is shown after A", H.visible(), { A = 1001, N = 1002 })

  T.section(L .. ": a visible variable of the name is taken over, its id written at once")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("J", "{}")
  C4:AddVariable("J", "", "STRING", true, false) -- 1002, not added by lib/values
  C4:AddVariable("Ext", "", "STRING", true, false) -- 1003
  values:update("J", "x", "STRING")
  T.eq("a plain value turned variable keeps it", { H.visible().J, Variables.J }, { 1002, "x" })
  local persist = require("lib.persist")
  values:setWriteBehind(60000)
  persist:defer(values.update, values, "Ext", "v", "STRING")
  T.eq("a new name keeps it too, its id in storage at once", H.recordIds().Ext, 1003)
  T.eq("and no variable is added", H.count(), 3)

  T.section(L .. ": a hidden variable carrying a new name is not taken over")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  C4:AddVariable("Ghost", "", "STRING", true, true) -- 1002
  values:update("Ghost", "g", "STRING")
  holds("Ghost is shown", { A = 1001, Ghost = R and 1002 or 1003 }, none or { 1002 })

  T.section(L .. ": a record Director raises on, in the middle, moves nothing after it")
  values = fresh(mode)
  values:update("A", "1", "STRING")
  values:update("X", "x", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:update("X", "x", "BOGUS") -- Director keeps the variable as it is; the record stores the type
  for _, how in ipairs({ "restart", "update", "restart" }) do
    local ok = pcall(H.load, how)
    T.check("after a " .. how .. " restore completes", ok)
    T.eq("after a " .. how .. " the others keep their ids", H.visible(), { A = 1001, B = 1003, C = 1004 })
  end
  values = H.load("update")
  values:delete("X") -- without a rename its id is held again, as STRING
  values:update("D", "4", "STRING")
  T.eq("and a new name takes none of them", H.visible().D, 1005)
  H.load("restart")
  T.eq("which a restart keeps", H.visible(), { A = 1001, B = 1003, C = 1004, D = 1005 })

  T.section(L .. ": programming writes reach the callback")
  values = fresh(mode)
  local seen = {}
  values:update("A", "1", "STRING")
  values:update("Mode", "a", "STRING", function(v)
    table.insert(seen, v)
  end)
  local id = H.visible().Mode
  ShimWriteVariable(id, "b")
  values = H.load("restart")
  values:setCallback("Mode", function(v)
    table.insert(seen, v)
  end)
  ShimWriteVariable(H.visible().Mode, "c")
  T.eq("OnVariableChanged names the variable, before and after a restart", seen, { "b", "c" })
  T.eq("and the id did not move", H.visible().Mode, id)
  T.eq("it comes back writable", H.variables()[id].name, "Mode")

  T.section(L .. ": restore shows the property of every value, including one that kept an id")
  values = fresh(mode)
  Properties["Firmware"] = ""
  local shown, written = {}, {}
  local realAttribs, realUpdate = C4.SetPropertyAttribs, C4.UpdateProperty
  C4.SetPropertyAttribs = function(_, name, attrib)
    shown[name] = attrib
  end
  C4.UpdateProperty = function(_, name, value)
    written[name] = value
  end
  values:update("Firmware", "1.0", "STRING")
  values:update("Firmware", "1.1") -- now a plain value with an old id
  shown, written = {}, {}
  values = H.load("update")
  T.eq("the property is shown again", shown["Firmware"], 0)
  T.eq("with its value", written["Firmware"], "1.1")
  C4.SetPropertyAttribs, C4.UpdateProperty = realAttribs, realUpdate
  Properties["Firmware"] = nil

  T.section(L .. ": index order follows id order")
  values = fresh(mode)
  for _, name in ipairs({ "Zeta", "Alpha", "Mid" }) do
    values:update(name, name, "STRING")
  end
  values:delete("Zeta")
  values:update("Zeta", "z", "STRING")
  local rows = {}
  for name, record in pairs(H.blob()) do
    table.insert(rows, { name = name, record = record })
  end
  table.sort(rows, function(a, b)
    return a.record.index < b.record.index
  end)
  local ordered = true
  for i = 2, #rows do
    if (rows[i].record.id or math.huge) < (rows[i - 1].record.id or math.huge) then
      ordered = false
    end
  end
  T.check("an older build's restore adds them in id order", ordered)
end

T.finish()
