-- The Light V2 adapter contract over every light_v2 driver in this repo. The template owns this file:
-- a new contract check reaches every light repo at its next copier update.
--
-- For each driver whose driver.xml names the light_v2 proxy, its chunk must make one light at load, at
-- the API this library is, and its driver.xml must hold the capabilities make light-caps writes from
-- its profile. Then every rig test/light_rigs.lua gives for it runs the kit's contract.
--
-- test/light_rigs.lua is the driver's own. It returns { version = <the rig interface>, rigs = { [folder]
-- = { rig, ... } } }, each rig as test/light_harness.lua's H.contract documents it.

local T = require("testlib")

require("c4_shim")

local D = require("light_drivers")
local H = require("light_harness")
local Light = require("lib.light")

local root = D.root()
local lights = D.lights(root)
local rigsFile = io.open(root .. "/test/light_rigs.lua")
local hasRigs = rigsFile ~= nil
if rigsFile then
  rigsFile:close()
end

-- A repo with no light driver yet has nothing to prove, unless it gives rigs.
if #lights == 0 and not hasRigs then
  print("No light_v2 driver under drivers/: nothing to prove.")
  T.finish()
  return
end

for _, folder in ipairs(lights) do
  T.section(folder .. ": its chunk makes one light at API " .. Light.API .. ", and driver.xml holds its capabilities")
  local light, err = D.load(root, folder)
  T.check(folder .. ": driver.lua loads and makes its light", light ~= nil, err)
  if light then
    local xml = D.xml(root, folder)
    local want, werr
    if xml then
      want, werr = D.written(xml, light)
    end
    T.check(
      folder .. ": driver.xml holds the capabilities its profile derives (make light-caps)",
      want ~= nil and want == xml,
      werr or "run make light-caps and commit driver.xml"
    )
  end
end

local ok, rigsOrErr = pcall(require, "light_rigs")
T.section("test/light_rigs.lua")
T.check("test/light_rigs.lua loads", ok, not ok and tostring(rigsOrErr) or nil)
if not ok then
  T.finish()
  return
end
local file = rigsOrErr
T.eq("it is written for the rig interface this kit runs", type(file) == "table" and file.version or nil, H.RIG_VERSION)
local rigs = type(file) == "table" and type(file.rigs) == "table" and file.rigs or {}

local isLight = {}
for _, folder in ipairs(lights) do
  isLight[folder] = true
  local list = rigs[folder]
  T.check(folder .. ": has at least one rig", type(list) == "table" and #list > 0, "test/light_rigs.lua gives none")
end
for folder in pairs(rigs) do
  T.check(folder .. ": a rig is for a light_v2 driver", isLight[folder] == true, "drivers/" .. folder .. " is not one")
end

if file.version == H.RIG_VERSION then
  for _, folder in ipairs(lights) do
    for index, rig in ipairs(rigs[folder] or {}) do
      rig.name = rig.name or string.format("%s rig %d", folder, index)
      rig.folder = folder
      H.contract(T, rig)
    end
  end
end

T.finish()
