-- Shipped lib/values builds for the template's own CI, which copies migration-test/ into a
-- render's test/; driver repos never receive it. values_harness loads a build through it.

local T = require("testlib")

local L = {}

local DIR = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "legacy/"

-- Shipped builds, byte-identical to their release blobs (git hash-object prefix given),
-- each with the lib/persist it shipped with.
L.BUILDS = {
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

--- A fresh lib/values of a shipped build, as a driver load of it has.
function L.load(tag)
  local build = assert(L.BUILDS[tag], "unknown build " .. tostring(tag))
  require("lib.utils") -- builds before v0.9.15 relied on the driver having loaded it
  T.unload("^lib%.persist$", "^lib%.values$")
  local persist = assert(loadfile(DIR .. build.persist .. ".lua"))()
  package.loaded["lib.persist"] = persist
  local values = assert(loadfile(DIR .. build.values .. ".lua"))()
  package.loaded["lib.values"] = values
  return values
end

return L
