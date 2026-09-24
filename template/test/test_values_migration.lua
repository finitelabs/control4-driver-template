-- The first load of this lib/values after a shipped build (test/legacy/, byte-identical copies) keeps
-- every variable id Director has, after a driver update or a Director restart, and later loads keep it.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_values_migration.lua

local T = require("testlib")
local H = require("values_harness")
local log = require("lib.logging")

-- Every warning lib/values logs, formatted.
local warnings = {}
local realWarn = log.warn
function log:warn(text, ...)
  local args = { ... }
  for i = 1, select("#", ...) do
    args[i] = tostring(args[i])
  end
  table.insert(warnings, string.format(text, unpack(args)))
  return realWarn(self, text, ...)
end

local MODES = {
  { rename = true, label = "with a rename" },
  { rename = false, label = "without a rename" },
}

-- Histories an older build can leave behind (research notes H1 to H15, and two dev devices).
-- Each runs from a clean install under `build`; `v` is that build's module.
local HISTORIES = {
  {
    name = "H1 a deleted variable, then a driver update",
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      H.load("update", build)
    end,
    back = { B = 1002 },
  },
  {
    name = "H2 a deleted plain value, then a driver update",
    skip = { F1 = true },
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:delete("J")
      H.load("update", build)
    end,
  },
  {
    name = "H3 a variable deleted and added back in one load",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      v:update("B", "2b", "STRING")
    end,
  },
  {
    name = "H4 the last variable deleted and a new one added in one load",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:delete("B")
      v:update("C", "3", "STRING")
    end,
  },
  {
    name = "H5 a restored placeholder whose record was trimmed",
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      v = H.load("update", build)
      v:delete("C")
      v:update("D", "4", "STRING")
    end,
    back = { B = 1002 },
  },
  {
    name = "H6 a restored placeholder's name saved again",
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      v = H.load("update", build)
      v:update("B", "2b", "STRING")
    end,
  },
  {
    name = "H7 a variable turned into a plain value, then a new one after an update",
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:update("B", "2")
      v = H.load("update", build)
      v:update("D", "4", "STRING")
    end,
  },
  {
    name = "H8 a plain value turned into a variable",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:update("J", "x", "STRING")
    end,
  },
  {
    name = "H9 reset with a restored plain-value placeholder",
    skip = { F1 = true },
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:delete("J")
      v = H.load("update", build)
      v:reset()
      v:update("C", "3", "STRING")
    end,
  },
  {
    name = "H10 many values",
    run = function(v)
      for _, name in ipairs({ "Zeta", "Alpha", "Mid", "Beta", "Omega", "Gamma" }) do
        v:update(name, name, "STRING")
      end
    end,
  },
  {
    name = "H11 v0.9.28 with a restored plain placeholder, updated to v0.9.29",
    only = { ["v0.9.29"] = true },
    run = function()
      local v = H.load("restart", "v0.9.28")
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:delete("J")
      H.load("restart", "v0.9.28")
      v = H.load("update", "v0.9.29")
      v:update("C", "3", "STRING")
    end,
  },
  {
    name = "H12 a restored plain placeholder's name saved again as a plain value",
    skip = { F1 = true },
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:delete("J")
      v = H.load("restart", build)
      v:update("J", "{}")
    end,
  },
  {
    name = "H13 after a driver update, a variable deleted and a new one added",
    run = function(v, build)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v = H.load("update", build)
      v:delete("B")
      v:update("E", "5", "STRING")
    end,
  },
  {
    name = "H14 an F1 blob with a reused index, updated to v0.9.28",
    only = { ["v0.9.28"] = true },
    run = function()
      local v = H.load("restart", "F1")
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      v:update("D", "4", "STRING")
      H.load("update", "v0.9.28")
    end,
  },
  {
    name = "H15 a deleted variable saved again with nil",
    skip = { F1 = true, F2 = true },
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "NUMBER")
      v:update("C", "3", "STRING")
      v:delete("B")
      v:update("B", nil, "NUMBER")
    end,
  },
  {
    name = "Z605 a phantom relay deleted right after every restore",
    skip = { F1 = true },
    run = function(v, build)
      v:update("Last Seen", "now", "STRING")
      v:update("Battery", "90", "NUMBER")
      v:update("Relay State", "0", "BOOL")
      v:update("Occupancy State", "0", "BOOL")
      for _, how in ipairs({ "restart", "update", "restart" }) do
        v = H.load(how, build)
        if v:getValue("Relay State") then
          v:delete("Relay State")
        end
      end
    end,
    back = { ["Relay State"] = 1003 },
  },
  {
    name = "Z583 Last Action deleted on a re-pair, then restored hidden",
    skip = { F1 = true },
    run = function(v, build)
      v:update("Last Seen", "now", "STRING")
      v:update("Last Action", "", "STRING")
      v:update("Battery", "90", "NUMBER")
      v:delete("Last Action")
      H.load("restart", build)
    end,
    back = { ["Last Action"] = 1002 },
  },
}

--- id -> "name" or "name(h)".
local function layout()
  local out = {}
  for id, v in pairs(H.variables()) do
    out[id] = v.name .. (v.hidden and "(h)" or "")
  end
  return out
end

--- Whether every id in `ids` (id -> name) is still held: live records at that id under their
--- name, the rest by some record, and without a rename by a hidden variable too.
local function keeps(label, ids, rename, hiddenAsBefore)
  local owners = {}
  for name, record in pairs(H.blob()) do
    if record.id ~= nil then
      owners[record.id] = { name = name, record = record }
    end
  end
  local vars, lost = H.variables(), {}
  for id, name in pairs(ids) do
    local owner = owners[id]
    if owner == nil then
      table.insert(lost, id .. " " .. name .. " has no record")
    elseif not owner.record.deleted and owner.record.varType ~= nil then
      if vars[id] == nil or vars[id].name ~= owner.name or (vars[id].hidden and not hiddenAsBefore) then
        table.insert(lost, id .. " " .. owner.name .. " is not shown there")
      end
    elseif not rename and (vars[id] == nil or not vars[id].hidden) then
      table.insert(lost, id .. " " .. name .. " is not held by a hidden variable")
    end
  end
  table.sort(lost)
  return T.eq(label, lost, {})
end

local function blobCopy()
  return C4:PersistGetValue("Values")
end

local function setBlob(raw)
  C4:PersistDeleteValue("Values")
  if raw ~= nil then
    C4:PersistSetValue("Values", raw)
  end
end

for _, mode in ipairs(MODES) do
  for _, build in ipairs({ "F1", "F2", "F3", "v0.9.28", "v0.9.29" }) do
    for _, history in ipairs(HISTORIES) do
      local applies = (history.only == nil or history.only[build]) and not (history.skip and history.skip[build])
      if applies then
        local label = build .. ", " .. history.name
        T.section(mode.label .. ": " .. label)

        -- The first load of this build follows a driver update.
        H.mode(mode.rename)
        H.wipe()
        history.run(H.load("restart", build), build)
        local before, held = layout(), {}
        for id, name in pairs(before) do
          held[id] = name:gsub("%(h%)$", "")
        end
        local raw = blobCopy()
        local values = H.load("update")
        T.eq("a driver update to this build changes no variable", layout(), before)
        local asked = 0
        local realGet = C4.GetDeviceVariables
        C4.GetDeviceVariables = function(...)
          asked = asked + 1
          return realGet(...)
        end
        values = H.load("update")
        C4.GetDeviceVariables = realGet
        T.eq("the next load does not read Director again", asked, 0)
        keeps("every id Director had is recorded", held, true, true)
        values = H.load("restart")
        keeps("and held after a Director restart", held, mode.rename)
        values = H.load("update")
        keeps("and after another driver update", held, mode.rename)
        if mode.rename and history.back and build ~= "F1" then -- F1 kept no record of a delete
          for name, id in pairs(history.back) do
            values:update(name, "back", "STRING")
            T.eq(name .. " comes back at its id", H.visible()[name], id)
          end
          H.load("restart")
          keeps("which a restart keeps", held, true)
        end

        -- The first load of this build follows a Director restart, before it recorded any id.
        ShimRestartDirector()
        setBlob(raw)
        H.load("restart", build == "F1" and "v0.9.28" or build) -- F1 restored in pairs() order
        local olderRestart = layout()
        ShimRestartDirector()
        setBlob(raw)
        H.load("restart")
        T.eq("after a restart it restores as the older build did", layout(), olderRestart)
        local restored = {}
        for id, name in pairs(olderRestart) do
          restored[id] = name:gsub("%(h%)$", "")
        end
        H.load("update")
        keeps("and records those ids", restored, true)
        H.load("restart")
        keeps("which the next restart keeps", restored, mode.rename)
      end
    end
  end
end

for _, mode in ipairs(MODES) do
  T.section(mode.label .. ": zigbee3 heals Last Action after the switch")
  H.mode(mode.rename)
  H.wipe()
  local v = H.load("restart", "v0.9.28")
  v:update("Last Seen", "now", "STRING")
  v:update("Last Action", "", "STRING")
  v:update("Battery", "90", "NUMBER")
  v:delete("Last Action")
  H.load("restart", "v0.9.28") -- Last Action comes back hidden at 1002
  local values = H.load("update")
  local existing = values:getValue("Last Action")
  T.eq("the tombstone is still a tombstone", existing.deleted, true)
  values:update("Last Action", nil) -- button.lua:104-106
  values:update("Last Action", "", "STRING")
  if mode.rename then
    T.eq("Last Action is shown at its id", H.visible()["Last Action"], 1002)
  else
    T.eq(
      "Last Action is shown at a new id, 1002 held",
      H.snapshot(),
      "1001=Last Seen, 1002=1002(h), 1003=Battery, 1004=Last Action"
    )
  end
  H.load("restart")
  T.eq(
    "and stays there",
    H.visible(),
    { ["Last Seen"] = 1001, ["Last Action"] = mode.rename and 1002 or 1004, Battery = 1003 }
  )
end

for _, mode in ipairs(MODES) do
  T.section(mode.label .. ": zigbee3 un-hides Last Action that an older build left hidden")
  H.mode(mode.rename)
  H.wipe()
  local old = H.load("restart", "v0.9.28")
  old:update("Last Seen", "now", "STRING")
  old:update("Last Action", "single", "STRING")
  old:update("Battery", "90", "NUMBER")
  old:delete("Last Action")
  old = H.load("update", "v0.9.28") -- Last Action comes back hidden at 1002
  old:update("Last Action", "single", "STRING") -- the older build's reseed: a normal record, still hidden
  local values = H.load("update")
  T.eq("still hidden after the switch", H.variables()[1002].hidden, true)
  local keep = values:getValue("Last Action").value
  values:update("Last Action", nil) -- button.lua:111-115
  values:update("Last Action", keep, "STRING")
  if mode.rename then
    T.eq("shown at its id with its value", { H.visible()["Last Action"], Variables["Last Action"] }, { 1002, "single" })
  else
    T.eq("shown at a new id, 1002 held", H.snapshot(), "1001=Last Seen, 1002=1002(h), 1003=Battery, 1004=Last Action")
  end
  H.load("restart")
  T.eq("and stays there", H.visible()["Last Action"], mode.rename and 1002 or 1004)
end

for _, mode in ipairs(MODES) do
  for _, failure in ipairs({ { "raises" }, { "returns a string", "x" }, { "returns an empty table", {} } }) do
    T.section(mode.label .. ": GetDeviceVariables " .. failure[1] .. " on the first load after a driver update")
    H.mode(mode.rename)
    H.wipe()
    -- H13: E took the id B freed, so restore order (E at 1004) is not where E is now (1002).
    local v = H.load("restart", "v0.9.28")
    v:update("A", "1", "STRING")
    v:update("B", "2", "STRING")
    v:update("C", "3", "STRING")
    v = H.load("update", "v0.9.28")
    v:delete("B")
    v:update("E", "5", "STRING")
    local before = H.snapshot()
    warnings = {}
    H.unreadableDirector(failure[2])
    local ok, values = pcall(H.load, "update")
    H.readableDirector()
    T.check("restore does not abort", ok, values)
    T.contains("it warns", table.concat(warnings, "\n"), "restore order")
    T.eq("and changes no variable", H.snapshot(), before)
    -- Without a rename an id must be held by a variable, and B's is not: B keeps none.
    T.eq(
      "ids are taken from restore order",
      H.recordIds(),
      { A = 1001, B = mode.rename and 1002 or nil, C = 1003, E = 1004 }
    )
    values:update("E", "6", "STRING")
    T.eq("E's value still reaches E", Variables["E"], "6")
    values:delete("E")
    T.eq("deleting E deletes E and nothing else", H.visible(), { A = 1001, C = 1003 })
    values:update("E", "7", "STRING")
    -- Without a rename a returning name takes a new id; here Director gives E the id it freed.
    local want = mode.rename and { A = 1001, C = 1003, E = 1004 } or { A = 1001, C = 1003, E = 1002 }
    H.load("restart")
    T.eq("after a restart the ids are restore order", H.visible(), want)
    H.load("update")
    T.eq("and stay", H.visible(), want)
  end
end

for _, rename in ipairs({ true, false }) do
  T.section("a visible variable no record names is left alone (" .. tostring(rename) .. ")")
  H.mode(rename)
  H.wipe()
  local old = H.load("restart", "v0.9.28")
  old:update("A", "1", "STRING")
  old:update("B", "2", "STRING")
  C4:AddVariable("STRING", "", "STRING", true, false) -- essentials' retired pre-release variable, 1003
  local values = H.load("update")
  T.eq("it gets no record", values:getValue("STRING"), nil)
  values:update("C", "3", "STRING")
  T.eq("its id is not handed out while it exists", H.visible(), { A = 1001, B = 1002, STRING = 1003, C = 1004 })
  C4:DeleteVariable("STRING") -- variable_expressions OnDriverLateInit
  H.load("restart")
  T.eq("and the ids hold after it is gone", H.visible(), { A = 1001, B = 1002, C = 1004 })
end

for _, rename in ipairs({ true, false }) do
  T.section("a restart where Director places a variable elsewhere records where (" .. tostring(rename) .. ")")
  H.mode(rename)
  H.wipe()
  local old = H.load("restart", "v0.9.28")
  old:update("A", "1", "STRING")
  old:update("B", "2", "STRING")
  local raw = blobCopy()
  ShimRestartDirector()
  setBlob(raw)
  C4:AddVariable("Own", "", "STRING", true, false) -- the driver's own, before restoreValues: 1001
  H.load("update") -- the same load: only the counter starts again, at 1001
  T.eq("the ids are Director's", H.recordIds(), { A = 1002, B = 1003 })
  T.eq("and the variables are there", H.visible(), { Own = 1001, A = 1002, B = 1003 })
end

T.section("GetDeviceVariables leaving out a name Director shows: every id comes from restore order")
H.mode(true)
H.wipe()
local v = H.load("restart", "v0.9.28")
v:update("A", "1", "STRING")
v:update("B", "2", "STRING")
local listed = {}
for id, variable in pairs(C4:GetDeviceVariables(C4:GetDeviceID())) do
  if variable.name == "A" then
    listed[id] = variable
  end
end
H.unreadableDirector(listed)
H.load("update")
H.readableDirector()
T.eq("not A from Director and B from restore order", H.blob().A.unverified, true)
T.eq("with the same ids", H.recordIds(), { A = 1001, B = 1002 })

T.section("without a rename, a restart after the switch holds each gap by number")
H.mode(false)
H.wipe()
v = H.load("restart", "v0.9.28")
v:update("A", "1", "STRING")
v:update("J", "{}")
v:update("B", "2", "STRING")
v:delete("J")
v = H.load("restart", "v0.9.28")
v:update("J", "{}") -- H12: the older build deletes J's placeholder, leaving 1002 empty
H.load("update")
H.load("restart")
T.eq("1002 is held by number", H.called("^Add #1002%(h%)%->1002$"), true)
T.eq("so B keeps 1003", H.visible(), { A = 1001, B = 1003 })

T.section("GetDeviceVariables is not asked after a Director restart")
H.mode(true)
H.wipe()
v = H.load("restart", "v0.9.28")
v:update("A", "1", "STRING")
v:update("B", "2", "STRING")
v:delete("A")
local asked = 0
H.unreadableDirector()
local realGet = C4.GetDeviceVariables
C4.GetDeviceVariables = function(...)
  asked = asked + 1
  return realGet(...)
end
local ok = pcall(H.load, "restart")
C4.GetDeviceVariables = realGet
H.readableDirector()
T.check("restore completes", ok)
T.eq("without asking", asked, 0)
T.eq("with the older build's ids", H.visible(), { B = 1002 })

T.section("an OS whose AddVariable returns no id")
for _, rename in ipairs({ true, false }) do
  H.mode(rename)
  H.wipe()
  v = H.load("restart", "v0.9.28")
  v:update("A", "1", "STRING")
  v:update("B", "2", "STRING")
  v:delete("A")
  local raw = blobCopy()
  ShimRestartDirector()
  setBlob(raw)
  local realAdd = C4.AddVariable
  C4.AddVariable = function(...)
    return (realAdd(...))
  end
  local values = H.load("restart")
  values:update("C", "3", "STRING")
  C4.AddVariable = realAdd
  T.eq(
    "ids come from restore order and Director (" .. tostring(rename) .. ")",
    H.recordIds(),
    { A = 1001, B = 1002, C = 1003 }
  )
end

T.section("a record Director raises on does not stop restore")
for _, rename in ipairs({ true, false }) do
  H.mode(rename)
  H.wipe()
  v = H.load("restart", "v0.9.28")
  v:update("A", "1", "STRING")
  pcall(v.update, v, "-5", "x", "STRING") -- the shipped build raises, after storing the record
  v:update("B", "2", "STRING")
  v:update("0042", "y", "STRING") -- Director stores it as 42, named "42"
  local raw = blobCopy()
  for _, how in ipairs({ "update", "restart" }) do
    if how == "restart" then
      ShimRestartDirector()
      setBlob(raw)
    end
    local okLoad = pcall(H.load, how)
    T.check(how .. ": restore completes (" .. tostring(rename) .. ")", okLoad)
    T.eq(how .. ": the others keep their ids", { H.visible().A, H.visible().B }, { 1001, 1002 })
    T.eq(how .. ": a numeric name keeps the id it has", H.recordIds()["0042"], 42)
    T.eq(how .. ": and is named as the driver names it", H.visible()[rename and "0042" or "42"], 42)
  end
end

T.section("the migration is written at once under write-behind")
H.mode(true)
H.wipe()
v = H.load("restart", "v0.9.28")
v:update("A", "1", "STRING")
v:update("B", "2", "STRING")
ShimUpdateDriver()
T.unload("^lib%.persist$", "^lib%.values$")
local persist = require("lib.persist")
local values = require("lib.values")
values:setWriteBehind(60000)
persist:defer(values.restoreValues, values)
T.eq("the ids are in storage", H.recordIds(), { A = 1001, B = 1002 })

-- An older build reading this build's blob, after a downgrade. Best effort: it must not
-- raise, and what it does to ids is reported, not asserted.
for _, mode in ipairs(MODES) do
  for _, older in ipairs({ "v0.9.28", "v0.9.29" }) do
    T.section(mode.label .. ": " .. older .. " reading this build's blob")
    H.mode(mode.rename)
    H.wipe()
    values = H.load("restart")
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:update("C", "3", "STRING")
    values:update("J", "{}")
    values:delete("B")
    values:update("C", "plain")
    values:update("D", "4", "STRING")
    values:update("B", "2b", "STRING")
    local before = H.snapshot()
    local okUpdate = pcall(H.load, "update", older)
    T.check("its driver update does not raise", okUpdate)
    print("  info " .. older .. " update:  " .. before .. "  ->  " .. H.snapshot())
    local okRestart = pcall(H.load, "restart", older)
    T.check("its restart does not raise", okRestart)
    print("  info " .. older .. " restart: " .. H.snapshot())
    local okBack = pcall(H.load, "update")
    T.check("this build after it does not raise", okBack)
  end
end

T.finish()
