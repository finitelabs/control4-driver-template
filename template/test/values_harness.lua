-- Driver loads for the lib/values tests: a driver update or a Director restart on the
-- c4_shim Director, then a fresh lib/values (this build or a shipped one) restoring.

require("c4_shim")
require("drivers-common-public.global.lib") -- Serialize, Deserialize
require("drivers-common-public.global.handlers") -- OVC, OnVariableChanged

local T = require("testlib")

local H = {}

local LEGACY_DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
LEGACY_DIR = LEGACY_DIR .. "legacy/"

-- Shipped builds, byte-identical to their release blobs (git hash-object prefix given),
-- each with the lib/persist it shipped with.
H.LEGACY = {
  -- esphome v20250606..v20251031: new records reuse the lowest free index, no tombstones.
  F1 = { values = "values-esphome-v20250606", persist = "persist-esphome-v20250714", blob = "db964bfc49" },
  -- mqtt v20260117..v20260127: tombstones and trimming; every update rewrites the record.
  F2 = { values = "values-mqtt-v20260117", persist = "persist-mqtt-v20260117", blob = "a7b765c386" },
  -- template v0.1.0..v0.5.0 (esphome v20260217..v20260512, mqtt v20260217, essentials v20260711).
  F3 = { values = "values-v0.1.0", persist = "persist-v0.3.0", blob = "25c2c7a2ea" },
  -- template v0.9.23..v0.9.28: what esphome v20260922 and zigbee3 run.
  ["v0.9.28"] = { values = "values-v0.9.23", persist = "persist-v0.9.15", blob = "4debefa50c" },
  -- template v0.9.29, never released: renames deleted plain records to __deleted__N.
  ["v0.9.29"] = { values = "values-v0.9.29", persist = "persist-v0.9.29", blob = "2d753d3bca" },
}

--- Every Director call lib/values made in the current load, as "Add name->id", "Add #id(h)->id", ...
H.calls = {}

local real = {
  AddVariable = C4.AddVariable,
  DeleteVariable = C4.DeleteVariable,
  SetVariable = C4.SetVariable,
  GetDeviceVariables = C4.GetDeviceVariables,
}

local function describe(identifier)
  return type(identifier) == "number" and ("#" .. identifier) or tostring(identifier)
end

function C4:AddVariable(identifier, value, varType, readOnly, hidden)
  local ok, id = real.AddVariable(self, identifier, value, varType, readOnly, hidden)
  local entry = "Add " .. describe(identifier) .. (hidden and "(h)" or "") .. "->" .. tostring(ok and id or false)
  table.insert(H.calls, entry)
  return ok, id
end

function C4:DeleteVariable(identifier)
  table.insert(H.calls, "Delete " .. describe(identifier))
  return real.DeleteVariable(self, identifier)
end

function C4:SetVariable(identifier, value)
  table.insert(H.calls, "Set " .. describe(identifier))
  return real.SetVariable(self, identifier, value)
end

--- Makes C4:GetDeviceVariables raise, or return `result`, until H.readableDirector().
function H.unreadableDirector(result)
  C4.GetDeviceVariables = function()
    if result == nil then
      error("GetDeviceVariables unavailable")
    end
    return result
  end
end

function H.readableDirector()
  C4.GetDeviceVariables = real.GetDeviceVariables
end

--- With a rename (OS 4.0+) or without.
function H.mode(rename)
  ShimVariableRename(rename)
end

--- A fresh lib/values of this build, as a new driver load has.
local function thisBuild()
  T.unload("^lib%.persist$", "^lib%.values$")
  return require("lib.values")
end

--- A fresh lib/values of a shipped build.
local function shippedBuild(tag)
  local build = assert(H.LEGACY[tag], "unknown build " .. tostring(tag))
  require("lib.utils") -- builds before v0.9.15 relied on the driver having loaded it
  T.unload("^lib%.persist$", "^lib%.values$")
  local persist = assert(loadfile(LEGACY_DIR .. build.persist .. ".lua"))()
  package.loaded["lib.persist"] = persist
  local values = assert(loadfile(LEGACY_DIR .. build.values .. ".lua"))()
  package.loaded["lib.values"] = values
  return values
end

--- A driver load after `how` ("update" or "restart") of `build` (nil for this build), which
--- restores in OnDriverInit. Returns the build's values module.
function H.load(how, build)
  if how == "restart" then
    ShimRestartDirector()
  else
    ShimUpdateDriver()
  end
  H.calls = {}
  local values = build and shippedBuild(build) or thisBuild()
  values:restoreValues()
  return values
end

--- A clean install: no variables and no stored values.
function H.wipe()
  ShimRestartDirector()
  C4:PersistDeleteValue("Values")
  H.readableDirector()
end

--- This device's variables as id -> { name, hidden }.
function H.variables()
  local out = {}
  for id, v in pairs(real.GetDeviceVariables(C4, C4:GetDeviceID())) do
    out[tonumber(id)] = { name = v.name, hidden = v.hidden == "True" }
  end
  return out
end

--- "1001=A, 1002=B(h)" in id order.
function H.snapshot()
  local vars, ids = H.variables(), {}
  for id in pairs(vars) do
    table.insert(ids, id)
  end
  table.sort(ids)
  local out = {}
  for _, id in ipairs(ids) do
    table.insert(out, id .. "=" .. vars[id].name .. (vars[id].hidden and "(h)" or ""))
  end
  return table.concat(out, ", ")
end

--- name -> id of every visible variable.
function H.visible()
  local out = {}
  for id, v in pairs(H.variables()) do
    if not v.hidden then
      out[v.name] = id
    end
  end
  return out
end

--- The ids of hidden variables, sorted.
function H.hiddenIds()
  local out = {}
  for id, v in pairs(H.variables()) do
    if v.hidden then
      table.insert(out, id)
    end
  end
  table.sort(out)
  return out
end

function H.count()
  local n = 0
  for _ in pairs(H.variables()) do
    n = n + 1
  end
  return n
end

--- The stored blob, decoded.
function H.blob()
  local raw = C4:PersistGetValue("Values")
  return raw and Deserialize(raw) or {}
end

function H.blobSize()
  return #(C4:PersistGetValue("Values") or "")
end

--- name -> id of every record that has one.
function H.recordIds()
  local out = {}
  for name, record in pairs(H.blob()) do
    if record.id ~= nil then
      out[name] = record.id
    end
  end
  return out
end

--- Whether any call in this load matches the Lua pattern.
function H.called(pattern)
  for _, call in ipairs(H.calls) do
    if call:match(pattern) then
      return true
    end
  end
  return false
end

return H
