-- The first load of this lib/values after a shipped build (legacy/, byte-identical copies) keeps
-- every variable id Director has, after a driver update or a Director restart, and later loads keep it.
--
-- The template's CI copies migration-test/ into a render's test/ and runs it with `make test`.

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
        local after = layout()
        for id, name in pairs(after) do
          if before[id] == nil and not mode.rename and name == id .. "(h)" then
            after[id] = nil -- without a rename, the id of a name deleted in the last load is held
          end
        end
        T.eq("a driver update to this build changes no variable", after, before)
        local settled = blobCopy()
        values = H.load("update")
        T.eq("the next load changes no record", blobCopy(), settled)
        T.eq("and no variable", H.calls, {})
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
    T.eq("and B's guess at E's id is dropped", H.recordIds().B, nil)
    if not mode.rename then
      T.eq("its id, read from Director once it can, is held", H.hiddenIds(), { 1002 })
    end
    values:update("F", "8", "STRING")
    T.eq("a new name does not take it", H.visible().F, 1004)
    values:update("E", "7", "STRING")
    -- With a rename E comes back at the id Director had for it; without, a returning name takes a new one.
    local want = { A = 1001, C = 1003, F = 1004, E = mode.rename and 1002 or 1005 }
    H.load("restart")
    T.eq("after a restart", H.visible(), want)
    H.load("update")
    T.eq("and after a driver update", H.visible(), want)
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

for _, mode in ipairs(MODES) do
  for _, failure in ipairs({ { "raises" }, { "returns an empty table", {} } }) do
    T.section(mode.label .. ": GetDeviceVariables " .. failure[1] .. " on a later load: nothing changes")
    H.mode(mode.rename)
    H.wipe()
    local values = H.load("restart")
    values:update("A", "1", "STRING")
    values:update("B", "2", "STRING")
    values:update("C", "3", "STRING")
    values:delete("B")
    H.load("update")
    local raw, before = blobCopy(), H.snapshot()
    H.unreadableDirector(failure[2])
    H.load("update")
    H.readableDirector()
    T.eq("no record", blobCopy(), raw)
    T.eq("and no variable", H.snapshot(), before)
  end
end

for _, mode in ipairs(MODES) do
  local variants = {
    { "a driver update", "update", true },
    { "a driver update, the older build's variables still shown", "update", false },
    { "a restart", "restart", true },
  }
  for _, variant in ipairs(variants) do
    T.section(mode.label .. ": numeric names the older build deleted come back at their ids, after " .. variant[1])
    H.mode(mode.rename)
    H.wipe()
    local old = H.load("restart", "v0.9.28")
    old:update("A", "1", "STRING")
    old:update("0042", "x", "STRING") -- at 42, named "42"
    old:update("3.5", "y", "STRING") -- at 3, named "3"
    old:update("B", "2", "STRING")
    old:delete("0042") -- Variables["0042"] is nil, so v0.9.28 leaves "42" shown
    old:delete("3.5")
    if variant[3] then
      H.load("restart", "v0.9.28") -- each is held hidden at its id, named by it
    end
    local values = H.load(variant[2])
    values:update("0042", "back", "STRING")
    values:update("3.5", "back", "STRING")
    local want = mode.rename and { A = 1001, B = 1002, ["0042"] = 42, ["3.5"] = 3 }
      or { A = 1001, B = 1002, ["42"] = 42, ["3"] = 3 }
    T.eq("each is shown at its id", H.visible(), want)
    T.eq("and nothing else", H.count(), 4)
    H.load("restart")
    T.eq("after a restart too", H.visible(), want)
  end

  local old
  for _, case in ipairs({ { "0042", 42 }, { "02000", 2000 } }) do
    local name, id = case[1], case[2]
    T.section(mode.label .. ": a device whose only variable is " .. name)
    H.mode(mode.rename)
    H.wipe()
    old = H.load("restart", "v0.9.28")
    old:update(name, "x", "STRING") -- Director names it by the id
    old:update("J", "{}")
    H.load("update")
    T.eq("a driver update is not taken for a restart", H.count(), 1)
    H.load("restart")
    T.eq("and it keeps its id", H.visible()[mode.rename and name or tostring(id)], id)
  end

  T.section(mode.label .. ": a numeric name the older build made plain keeps the id of the variable it left")
  H.mode(mode.rename)
  H.wipe()
  old = H.load("restart", "v0.9.28")
  old:update("A", "1", "STRING")
  old:update("02000", "x", "STRING") -- at 2000, named "2000"
  old:update("02000", "p") -- v0.9.28 looks for Variables["02000"], so "2000" stays
  local values = H.load("update")
  T.eq("its id is recorded", H.recordIds()["02000"], 2000)
  T.eq("with its value", values:getValue("02000").value, "p")
  values:update("N", "n", "STRING")
  values:update("02000", "v", "STRING")
  local shownAs = mode.rename and "02000" or "2000"
  T.eq("it comes back there", H.visible()[shownAs], 2000)
  H.load("restart")
  T.eq("after a restart too", H.visible()[shownAs], 2000)

  for _, restartFirst in ipairs({ false, true }) do
    T.section(
      mode.label
        .. ": a numeric name the older build reset takes back the id it spells"
        .. (restartFirst and ", after a restart" or "")
    )
    H.mode(mode.rename)
    H.wipe()
    old = H.load("restart", "v0.9.28")
    old:update("0042", "x", "STRING")
    old:reset() -- v0.9.28 looks for Variables["0042"], so "42" stays
    values = H.load("update")
    if restartFirst then
      values = H.load("restart")
    end
    values:update("0042", "back", "STRING")
    T.eq("at 42", H.visible()[mode.rename and "0042" or "42"], 42)
  end

  for _, plain in ipairs({ true, false }) do
    T.section(
      mode.label
        .. ": a hidden variable whose record the older build trimmed"
        .. (plain and ", beside a plain value" or ", nothing stored")
    )
    H.mode(mode.rename)
    H.wipe()
    old = H.load("restart", "v0.9.28")
    if plain then
      old:update("P", "{}")
    end
    old:update("A", "1", "STRING")
    old:update("B", "2", "STRING")
    old:delete("A")
    old = H.load("restart", "v0.9.28") -- A is held hidden at 1001
    old:delete("B") -- which trims both records
    local values = H.load("update")
    T.eq("its id is recorded", H.recordIds().A, 1001)
    values:update("C", "3", "STRING")
    T.eq("a new name does not take it", H.visible().C, 1002)
    values:update("A", "back", "STRING")
    local want = { A = mode.rename and 1001 or 1003, C = 1002 }
    T.eq("A comes back shown, with its value", { H.visible(), Variables.A }, { want, "back" })
    H.load("restart")
    T.eq("after a restart too", H.visible(), want)
  end

  T.section(mode.label .. ": a name the older build deleted in its last load keeps its id")
  H.mode(mode.rename)
  H.wipe()
  old = H.load("restart", "v0.9.28")
  old:update("A", "1", "STRING")
  old:update("B", "2", "STRING")
  old:update("C", "3", "STRING")
  old:delete("B")
  local values = H.load("update")
  T.eq("its id is recorded", H.recordIds().B, 1002)
  if not mode.rename then
    T.eq("and held", H.hiddenIds(), { 1002 })
  end
  values:update("D", "4", "STRING")
  T.eq("a new name does not take it", H.visible().D, 1004)
  values:update("B", "back", "STRING")
  H.load("restart")
  T.eq("B comes back", H.visible(), { A = 1001, B = mode.rename and 1002 or 1005, C = 1003, D = 1004 })

  T.section(mode.label .. ": estimated ids are checked against Director before one is used")
  H.mode(mode.rename)
  H.wipe()
  old = H.load("restart", "v0.9.28")
  for _, name in ipairs({ "B", "F", "E", "Dv" }) do
    old:update(name, name, "STRING")
  end
  old:delete("F")
  old:delete("E")
  old = H.load("restart", "v0.9.28") -- 1001=B, 1002=F(h), 1003=E(h), 1004=Dv
  old:update("B", "plain now") -- 1001 is free
  H.unreadableDirector({})
  values = H.load("update")
  H.readableDirector() -- readable again after OnDriverInit
  values:update("E", "e", "STRING")
  T.eq("Dv keeps its id", H.visible().Dv, 1004)
  if mode.rename then
    T.eq("E comes back at the id Director had for it", H.visible().E, 1003)
  end
  local now = H.visible()
  H.load("restart")
  T.eq("after a restart too", H.visible(), now)

  T.section(mode.label .. ": the id of a visible variable that is not ours stays reserved after it goes")
  H.mode(mode.rename)
  H.wipe()
  old = H.load("restart", "v0.9.28")
  old:update("A", "1", "STRING")
  old:update("B", "2", "STRING")
  C4:AddVariable("STRING", "", "STRING", true, false) -- essentials' retired variable, 1003
  values = H.load("update")
  C4:DeleteVariable("STRING") -- variable_expressions, in OnDriverLateInit
  values:update("N", "n", "STRING")
  T.eq("a new name does not take it", H.visible().N, 1004)
  H.load("restart")
  T.eq("nor after a restart", H.visible(), { A = 1001, B = 1002, N = 1004 })

  for _, gap in ipairs({ "a gap the older build left", "a gap another variable left" }) do
    T.section(mode.label .. ": downgraded, restarted under the older build and switched back, with " .. gap)
    H.mode(mode.rename)
    H.wipe()
    old = H.load("restart", "v0.9.28")
    old:update("A", "a", "STRING")
    if gap == "a gap the older build left" then
      old:update("B", "b", "STRING")
      old:delete("B")
      old:update("C", "c", "STRING") -- 1003; 1002 is empty and no record has it
      values = H.load("update")
    else
      C4:AddVariable("STRING", "", "STRING", true, false) -- 1002
      values = H.load("update")
      values:update("C", "c", "STRING")
      C4:DeleteVariable("STRING")
    end
    values:update("D", "d", "STRING")
    H.load("update", "v0.9.28")
    H.load("restart", "v0.9.28")
    local director = H.visible()
    values = H.load("update")
    values:update("C", "C-new", "STRING")
    values:update("D", "D-new", "STRING")
    T.eq("each write reaches its own variable", { Variables.C, Variables.D }, { "C-new", "D-new" })
    T.eq("where Director has it", H.visible(), director)
    H.load("restart")
    T.eq("which a restart keeps", H.visible(), director)
    values = H.load("update")
    values:update("N", "n", "STRING")
    local fresh = (gap == "a gap the older build left" and not mode.rename) and 1004 or 1005
    T.eq("and a new name takes no id a name had", H.visible().N, fresh)
  end

  T.section(mode.label .. ": a hidden variable the older build added in a downgrade gives way to its name")
  H.mode(mode.rename)
  H.wipe()
  values = H.load("restart")
  values:update("A", "1", "STRING")
  values:update("B", "2", "STRING")
  values:update("C", "3", "STRING")
  values:delete("B")
  H.load("update", "v0.9.28") -- adds B hidden, by name
  values = H.load("update")
  values:update("B", "back", "STRING")
  T.eq("B is shown with its value", { H.visible().B ~= nil, Variables.B }, { true, "back" })
  T.eq("A and C keep their ids", { H.visible().A, H.visible().C }, { 1001, 1003 })
  if mode.rename then
    T.eq("and B is back at its id", H.visible().B, 1002)
  end
end

for _, mode in ipairs(MODES) do
  T.section(mode.label .. ': an older build\'s variable named "" goes at its next update, its id kept')
  H.mode(mode.rename)
  H.wipe()
  local old = H.load("restart", "v0.9.28")
  old:update("A", "1", "STRING")
  old:update("", "e", "STRING") -- 1002, named ""
  old:update("B", "2", "STRING")
  local raw = blobCopy()
  local values = H.load("update")
  T.eq("the switch changes no variable", H.snapshot(), "1001=A, 1002=, 1003=B")
  values:update("", "e2", "STRING")
  T.eq("its next update removes it", H.visible(), { A = 1001, B = 1003 })
  T.eq("and keeps its value", values:getValue("").value, "e2")
  values:update("N", "n", "STRING")
  T.eq("its id is not handed out", H.visible().N, 1004)
  H.load("restart")
  T.eq("nor after a restart", H.visible(), { A = 1001, B = 1003, N = 1004 })

  ShimRestartDirector()
  setBlob(raw)
  values = H.load("restart")
  T.eq("switched by a restart, its place is held by number", H.snapshot(), "1001=A, 1002=1002(h), 1003=B")
  values:update("", "e3", "STRING")
  values:update("N", "n", "STRING")
  H.load("restart")
  T.eq("and its id is not handed out", H.visible(), { A = 1001, B = 1003, N = 1004 })
end

for _, older in ipairs({ "v0.9.28", "F3" }) do
  T.section("with a rename: a returning name takes no id another record keeps, after a downgrade to " .. older)
  H.mode(true)
  H.wipe()
  local values = H.load("restart")
  for _, name in ipairs({ "C", "E", "B", "F" }) do
    values:update(name, name, "STRING") -- 1001 to 1004
  end
  values:delete("E")
  values:delete("B")
  local old = H.load("update", older)
  old:update("C", "{}") -- the older build makes C plain
  H.load("restart", older) -- E(h)=1001, B(h)=1002, F=1003: B's id is F's now
  values = H.load("update")
  values:update("B", "b", "STRING")
  local owners, shared = {}, {}
  for name, record in pairs(H.blob()) do
    if record.id ~= nil and owners[record.id] ~= nil then
      table.insert(shared, record.id)
    end
    owners[record.id or 0] = name
  end
  T.eq("no two records share an id", shared, {})
  values:update("E", "e", "STRING")
  T.eq("E comes back at its id", H.visible().E, 1002)
  H.load("restart")
  T.eq("which a restart keeps", H.visible(), { B = 1005, E = 1002, F = 1003 })
end

for _, mode in ipairs(MODES) do
  local cases = {
    { "after a deleted name", { "A", "B", "Z", "Y" }, "A", { "Z", "Y" } },
    { "around one that kept its id", { "C", "B", "D" }, nil, { "C", "D" } },
  }
  for _, case in ipairs(cases) do
    T.section(mode.label .. ": ids an older build's rewrite dropped, then a restart first, " .. case[1])
    H.mode(mode.rename)
    H.wipe()
    local values = H.load("restart")
    for _, name in ipairs(case[2]) do
      values:update(name, name, "STRING")
    end
    if case[3] then
      values:delete(case[3])
    end
    local old = H.load("update", "v0.9.28")
    for _, name in ipairs(case[4]) do
      old:update(name, name .. "2", "STRING") -- the older build rewrites the record without its id
    end
    local want, raw = H.visible(), blobCopy()
    ShimRestartDirector()
    setBlob(raw)
    H.load("restart")
    T.eq("each comes back where Director had it", H.visible(), want)
  end

  T.section(mode.label .. ": a recorded id beats the id of a hidden variable an older build wrote into")
  H.mode(mode.rename)
  H.wipe()
  values = H.load("restart")
  for _, name in ipairs({ "C", "A", "D", "F" }) do
    values:update(name, name, "STRING") -- 1001 to 1004
  end
  values:delete("A")
  values:delete("D")
  H.load("update", "v0.9.28"):update("C", "{}") -- the older build makes C plain
  H.load("restart", "v0.9.28"):update("D", "d2", "STRING") -- A(h)=1001, D(h)=1002 holding D's value, F=1003
  values = H.load("update")
  T.eq("A keeps its id", H.recordIds().A, 1002)
  values:update("D", "d3", "STRING")
  values:update("A", "a", "STRING")
  H.load("restart")
  -- Without a rename a returning name takes a new id; D took 1005 just before.
  T.eq("and comes back at it", H.visible().A, mode.rename and 1002 or 1006)

  T.section(mode.label .. ": after a restart, live records with no free id of their own get new ones in index order")
  H.mode(mode.rename)
  H.wipe()
  local blob = {}
  for i = 1, 6 do
    blob["Z" .. (7 - i)] = { index = i, varType = "STRING", value = "z" } -- restore order would give them 1001-1006
    blob["K" .. i] = { index = 6 + i, id = 1000 + i, varType = "STRING", value = "k" }
  end
  C4:PersistSetValue("Values", Serialize(blob))
  H.load("restart")
  local got = {}
  for i = 1, 6 do
    got[i] = H.visible()["Z" .. (7 - i)]
  end
  T.eq("so they follow the order an older build restores them in", got, { 1007, 1008, 1009, 1010, 1011, 1012 })
end

for _, build in ipairs({ "F2", "v0.9.28" }) do
  for _, name in ipairs({ "0042", "1e3", "B" }) do
    T.section(
      "with a rename: " .. build .. "'s live " .. name .. ", its variable left hidden, is shown at its next update"
    )
    H.mode(true)
    H.wipe()
    local old = H.load("restart", build)
    old:update(name, "1", "STRING")
    old:update("A", "a", "STRING")
    old:delete(name)
    old = H.load("restart", build) -- restores the placeholder, hidden
    old:update(name, "2", "STRING") -- the value has no visible variable
    local id = tonumber(name) and math.floor(tonumber(name)) or 1001
    local values = H.load("update") -- the harness fails a restore that deletes a variable
    T.eq("restore addresses nothing by name", H.called("^Set [^#]"), false)
    values:update(name, "3", "STRING")
    T.eq("it is shown at its id with its value", { H.visible()[name], Variables[name] }, { id, "3" })
    H.load("restart")
    T.eq("which a restart keeps", H.visible()[name], id)
  end
end

T.section("without a rename: a deleted name's id is held when an older build left its name at another id")
H.mode(false)
H.wipe()
local walked = H.load("restart")
walked:update("C", "c", "STRING") -- 1001
walked:update("A", "a", "STRING") -- 1002
walked:update("E", "e", "STRING") -- 1003
walked:delete("E") -- 1003 held
H.load("update", "v0.9.28"):update("C", "{}") -- the older build makes C plain
H.load("restart", "v0.9.28") -- A=1001, E(h)=1002
walked = H.load("update")
T.eq("1003 is held", H.called("^Add #1003%(h%)%->1003$"), true)
walked:update("N", "n", "STRING")
T.eq("so a new name does not take it", { H.visible().N, H.recordIds().E }, { 1004, 1003 })

--- The first load of this build after a driver update, with GetDeviceVariables failing during it.
local function unreadableSwitch()
  H.unreadableDirector()
  local values = H.load("update")
  H.readableDirector()
  return values
end

T.section("without a rename, Director unreadable at the switch: a name the older build deleted keeps its id")
H.mode(false)
H.wipe()
local deg = H.load("restart", "v0.9.28")
deg:update("A", "1", "STRING")
deg:update("B", "2", "STRING")
deg:update("C", "3", "STRING")
deg:delete("B")
deg = unreadableSwitch()
T.eq("its id is held", H.hiddenIds(), { 1002 })
deg:update("D", "4", "STRING")
T.eq("so a new name does not take it", H.visible(), { A = 1001, C = 1003, D = 1004 })

T.section("without a rename, Director unreadable at the switch: a new name does not take a live name's id")
H.wipe()
deg = H.load("restart", "v0.9.28")
deg:update("A", "1", "STRING")
deg:update("B", "2", "STRING")
deg:update("C", "3", "STRING")
deg:delete("C") -- trimmed: 1003 is free, and restore order puts D there
deg:update("D", "4", "STRING") -- 1004
deg = unreadableSwitch()
deg:update("E", "5", "STRING")
deg:delete("D")
deg:update("F", "6", "STRING")
T.eq(
  "D's id is held once it goes",
  { H.visible(), H.hiddenIds() },
  { { A = 1001, B = 1002, E = 1003, F = 1005 }, { 1004 } }
)

T.section("without a rename, Director unreadable at the switch: the coordinator's rooms keep their ids held")
H.wipe()
local kitchen = { "Kitchen (12) Occupied", "Kitchen (12) Occupant Count", "Kitchen (12) Occupants" }
local office = { "Office (15) Occupied", "Office (15) Occupant Count", "Office (15) Occupants" }
deg = H.load("restart", "v0.9.28")
deg:update("Connected", true, "BOOL")
for _, name in ipairs(kitchen) do
  deg:update(name, "", "STRING")
end
for _, name in ipairs(office) do
  deg:update(name, "", "STRING")
end
deg:update("Scanner Count", "2", "NUMBER")
for _, name in ipairs(kitchen) do
  deg:delete(name) -- both proxies are offline when the driver is updated
end
for _, name in ipairs(office) do
  deg:delete(name)
end
deg = unreadableSwitch()
for _, name in ipairs(office) do
  deg:update(name, "", "STRING") -- the Office proxy reports first
end
T.eq("every room's old id is held", H.hiddenIds(), { 1002, 1003, 1004, 1005, 1006, 1007 })
T.eq("and Office takes new ones", H.visible()[office[1]], 1009)

T.section("without a rename: an id that is only a guess is not held when its name is deleted")
H.mode(false)
H.wipe()
local h13 = H.load("restart", "v0.9.28")
h13:update("A", "1", "STRING")
h13:update("B", "2", "STRING")
h13:update("C", "3", "STRING")
h13 = H.load("update", "v0.9.28")
h13:delete("B")
h13:update("E", "5", "STRING") -- at 1002; restore order says 1004
H.unreadableDirector()
h13 = H.load("update")
warnings = {}
h13:delete("E")
H.readableDirector()
T.eq("E is gone", H.visible(), { A = 1001, C = 1003 })
T.eq("and nothing is held at the guessed id", H.hiddenIds(), {})
T.contains("which is logged", table.concat(warnings, "\n"), "not known")

T.section("with a rename: a variable an older build left hidden is shown at its next update")
H.mode(true)
H.wipe()
local v = H.load("restart", "v0.9.28")
v:update("A", "1", "STRING")
v:update("B", "2", "STRING")
v:update("C", "3", "STRING")
v:delete("B")
v = H.load("update", "v0.9.28") -- B comes back hidden at 1002
v:update("B", "2b", "STRING") -- a normal record again, its variable still hidden
local healed = H.load("update")
T.eq("still hidden after the switch", H.variables()[1002].hidden, true)
healed:update("B", "2b", "STRING")
T.eq("shown at its id, with its value", { H.visible().B, Variables.B }, { 1002, "2b" })

T.section("GetDeviceVariables leaving out a name Director shows: every id comes from restore order")
H.mode(true)
H.wipe()
v = H.load("restart", "v0.9.28")
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
