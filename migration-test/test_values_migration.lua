-- The first load of this lib/values after v0.9.28, whose values code every released
-- driver runs, keeps each variable id Director has, whether it follows a driver
-- update or a Director restart, and later loads keep them.
--
-- The template's CI copies this directory into a render's test/, with v0.9.28's
-- lib/values.lua as test/values_v0928.lua; driver repos never receive it.

local T = require("testlib")
local H = require("values_harness")

local OLDER = "values_v0928"

-- What v0.9.28 can leave behind, each run from a clean install. `back` names a
-- deleted name and the id it comes back at.
local HISTORIES = {
  {
    name = "a deleted variable, then a driver update",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      H.load("update", OLDER)
    end,
    back = { B = 1002 },
  },
  {
    name = "a deleted plain value, then a driver update",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:delete("J")
      H.load("update", OLDER)
    end,
  },
  {
    name = "a variable deleted and added back in one load",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      v:update("B", "2b", "STRING")
    end,
  },
  {
    name = "the last variable deleted and a new one added in one load",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:delete("B")
      v:update("C", "3", "STRING")
    end,
  },
  {
    name = "a restored placeholder whose record was trimmed",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      v = H.load("update", OLDER)
      v:delete("C")
      v:update("D", "4", "STRING")
    end,
    back = { B = 1002 },
  },
  {
    name = "a restored placeholder's name saved again",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:delete("B")
      v = H.load("update", OLDER)
      v:update("B", "2b", "STRING")
    end,
  },
  {
    name = "a variable turned into a plain value, then a new one after an update",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v:update("B", "2")
      v = H.load("update", OLDER)
      v:update("D", "4", "STRING")
    end,
  },
  {
    name = "a plain value turned into a variable",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:update("J", "x", "STRING")
    end,
  },
  {
    name = "reset with a restored plain-value placeholder",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:delete("J")
      v = H.load("update", OLDER)
      v:reset()
      v:update("C", "3", "STRING")
    end,
  },
  {
    name = "many values",
    run = function(v)
      for _, name in ipairs({ "Zeta", "Alpha", "Mid", "Beta", "Omega", "Gamma" }) do
        v:update(name, name, "STRING")
      end
    end,
  },
  {
    name = "a restored plain placeholder's name saved again as a plain value",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("J", "{}")
      v:update("B", "2", "STRING")
      v:delete("J")
      v = H.load("restart", OLDER)
      v:update("J", "{}")
    end,
  },
  {
    name = "after a driver update, a variable deleted and a new one added",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "STRING")
      v:update("C", "3", "STRING")
      v = H.load("update", OLDER)
      v:delete("B")
      v:update("E", "5", "STRING")
    end,
  },
  {
    name = "a deleted variable saved again with nil",
    run = function(v)
      v:update("A", "1", "STRING")
      v:update("B", "2", "NUMBER")
      v:update("C", "3", "STRING")
      v:delete("B")
      v:update("B", nil, "NUMBER")
    end,
  },
  {
    name = "zigbee3: a phantom Relay State deleted right after every restore",
    run = function(v)
      v:update("Last Seen", "now", "STRING")
      v:update("ResolvedModel", "model")
      v:update("Battery", "90", "NUMBER")
      v:update("Relay State", "0", "BOOL")
      v:update("Occupancy State", "0", "BOOL")
      for _, how in ipairs({ "restart", "update", "restart" }) do
        v = H.load(how, OLDER)
        if v:getValue("Relay State") then
          v:delete("Relay State")
        end
      end
    end,
    back = { ["Relay State"] = 1003 },
  },
  {
    name = "zigbee3: Last Action deleted on a re-pair, then restored hidden",
    run = function(v)
      v:update("Last Seen", "now", "STRING")
      v:update("Last Action", "", "STRING")
      v:update("Battery", "90", "NUMBER")
      v:delete("Last Action")
      H.load("restart", OLDER)
    end,
    back = { ["Last Action"] = 1002 },
  },
}

--- Asserts each variable of a layout is still its name's: the name's record keeps
--- the id, which no other record has, and a variable that was shown is shown there.
local function keeps(label, layout)
  local records, variables, lost, owners = H.blob(), H.variables(), {}, {}
  for name, record in pairs(records) do
    if record.id ~= nil and owners[record.id] ~= nil then
      table.insert(lost, record.id .. " is " .. owners[record.id] .. "'s and " .. name .. "'s")
    end
    owners[record.id or name] = name
  end
  for id, shown in pairs(layout) do
    local name, hidden = shown:gsub("%(h%)$", "")
    if (records[name] or {}).id ~= id then
      table.insert(lost, id .. " is not " .. name .. "'s")
    elseif hidden == 0 and (variables[id] == nil or variables[id].name ~= name or variables[id].hidden) then
      table.insert(lost, id .. " does not show " .. name)
    end
  end
  table.sort(lost)
  T.eq(label, lost, {})
end

--- Asserts each value with a variable is shown at the id its record keeps, as a
--- Director restart adds every variable again.
local function shows(label)
  local visible, wrong = H.visible(), {}
  for name, record in pairs(H.blob()) do
    if record.varType ~= nil and not record.deleted and visible[name] ~= record.id then
      table.insert(wrong, name)
    end
  end
  table.sort(wrong)
  T.eq(label, wrong, {})
end

local function setBlob(raw)
  C4:PersistDeleteValue("Values")
  C4:PersistSetValue("Values", raw)
end

for _, history in ipairs(HISTORIES) do
  T.section(history.name)

  -- The switch at a driver update.
  H.wipe()
  history.run(H.load("restart", OLDER))
  local raw, before = C4:PersistGetValue("Values"), H.layout()
  H.load("update")
  T.eq("a driver update to this build changes no variable", H.layout(), before)
  T.eq("and adds or deletes none", H.calls, {})
  keeps("every id Director had is recorded", before)
  local settled = C4:PersistGetValue("Values")
  local values = H.load("update")
  T.eq("the next load changes no record", C4:PersistGetValue("Values"), settled)
  T.eq("and no variable", H.calls, {})
  for name, id in pairs(history.back or {}) do
    values:update(name, "back", "STRING")
    T.eq(name .. " comes back at its id", H.visible()[name], id)
  end
  H.load("restart")
  keeps("a Director restart keeps every id", before)
  shows("and shows every variable at its id")

  -- The switch at a Director restart, before any id is recorded.
  ShimRestartDirector()
  setBlob(raw)
  H.load("restart", OLDER)
  local older = H.layout()
  ShimRestartDirector()
  setBlob(raw)
  values = H.load("restart")
  T.eq("a restart to this build restores as v0.9.28 did", H.layout(), older)
  -- A deleted name comes back where v0.9.28's restart held it.
  for id, shown in pairs(older) do
    local name = shown:match("^(.*)%(h%)$")
    if name ~= nil then
      values:update(name, "back", "STRING")
      T.eq(name .. " comes back there in that load", H.visible()[name], id)
    end
  end
  H.load("update")
  keeps("and records those ids", older)
  H.load("restart")
  keeps("which the next restart keeps", older)
  shows("and shows every variable at its id")

  -- Without a rename, the first load restores as v0.9.28 does.
  ShimVariableRename(false)
  for _, how in ipairs({ "update", "restart" }) do
    H.wipe()
    history.run(H.load("restart", OLDER))
    H.load(how, OLDER)
    local want = H.layout()
    H.wipe()
    history.run(H.load("restart", OLDER))
    H.load(how)
    T.eq("without a rename, a " .. how .. " restores as v0.9.28 does", H.layout(), want)
  end
  ShimVariableRename(true)
end

local function unreadable()
  error("unavailable")
end
local function empty()
  return {}
end

for _, case in ipairs({ { "raises", unreadable }, { "leaves out a variable", empty } }) do
  T.section("Director's variable list " .. case[1] .. " at the switch")
  H.wipe()
  local old = H.load("restart", OLDER)
  old:update("A", "1", "STRING")
  old:update("B", "2", "STRING")
  old:update("C", "3", "STRING")
  old = H.load("update", OLDER)
  old:delete("B")
  old:update("E", "5", "STRING") -- takes 1002, where restore order would put B
  local list = C4.GetDeviceVariables
  C4.GetDeviceVariables = case[2]
  local ok, err = pcall(H.load, "update")
  C4.GetDeviceVariables = list
  T.check("restore does not fail", ok, err)
  T.eq("the load runs as v0.9.28's would", H.visible(), { A = 1001, E = 1002, C = 1003 })
  T.eq("and records no id", H.blob().E.id, nil)
  H.load("update")
  T.eq("the next load records each id", H.blob().E.id, 1002)
  H.load("restart")
  T.eq("which a restart keeps", H.visible(), { A = 1001, E = 1002, C = 1003 })
end

T.section("a variable no record names keeps its id")
H.wipe()
local old = H.load("restart", OLDER)
old:update("A", "1", "STRING")
C4:AddVariable("STRING", "", "STRING", true, false) -- essentials' retired variable, 1002
local values = H.load("update")
values:update("C", "3", "STRING")
T.eq("a new name does not take it", H.visible(), { A = 1001, STRING = 1002, C = 1003 })
C4:DeleteVariable("STRING") -- as essentials does in OnDriverLateInit
values = H.load("restart")
values:update("D", "4", "STRING")
T.eq("nor once it is gone", H.visible(), { A = 1001, C = 1003, D = 1004 })

T.section("a variable v0.9.28 rewrote keeps its id through a downgrade and back")
H.wipe()
values = H.load("restart")
values:update("A", "1", "STRING")
values:update("B", "2", "STRING")
values:update("C", "3", "STRING")
old = H.load("update", OLDER)
old:update("A", "1b", "STRING") -- v0.9.28 rewrites A's record without its id
H.load("update")
T.eq("the load back records A's id", H.blob().A.id, 1001)
H.load("restart")
T.eq("which a restart keeps", H.visible(), { A = 1001, B = 1002, C = 1003 })
local list, asked = C4.GetDeviceVariables, false
C4.GetDeviceVariables = function(...)
  asked = true
  return list(...)
end
H.load("update")
C4.GetDeviceVariables = list
T.eq("and a later load does not ask Director for its variables", asked, false)

T.section("a name v0.9.28 deleted does not take an id a deleted value keeps")
H.wipe()
values = H.load("restart")
values:update("A", "1", "STRING")
C4:AddVariable("F", "", "STRING", true, false) -- a variable no record names, 1002
values:update("X", "x", "STRING")
values:update("Y", "y", "STRING")
old = H.load("update", OLDER)
old:update("Z", "z")
old:update("A", "1b", "STRING")
old:delete("X") -- X's record keeps 1003, where restore order puts Y
old:update("Y", "y2", "STRING")
old:delete("Y")
values = H.load("update")
T.neq("Y does not take X's id", H.blob().Y.id, 1003)
values:update("Y", "back", "STRING")
values:update("X", "back", "STRING")
T.eq("and X comes back at it", H.visible().X, 1003)

T.finish()
