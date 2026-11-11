-- example_light's rigs for the adapter contract (test/test_light_contract.lua). A light repo writes
-- its own: one or more rigs per light_v2 driver, each loading the driver as it ships and faking only
-- its transport. example_light's transport is the bulb in its own chunk, which the rig reaches
-- through the adapter's functions.

local D = require("light_drivers")
local F = require("c4_fixtures")
local H = require("light_harness")
local Light = require("lib.light")

local DRIVER = D.root() .. "/drivers/example_light/driver.lua"

-- The shim answers no driver.xml section but connections, and OnDriverLateInit reads the driver's
-- minimum OS and version: answer them from example_light's driver.xml.
local xml = D.xml(D.root(), "example_light")
local config = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" or section == "version" then
    return xml:match("<" .. section .. ">([^<]*)</" .. section .. ">") or ""
  end
  return config(self, section)
end

--- A local the function closes over, by name.
local function upvalue(fn, name)
  for i = 1, math.huge do
    local key, value = debug.getupvalue(fn, i)
    if key == nil then
      return nil
    elseif key == name then
      return value
    end
  end
end

local rig = { name = "example_light", links = true }

--- Load the driver afresh, run its init, and hand the contract the bulb.
function rig.load(h)
  F.dofileBuild(DRIVER, "oss")
  local light = Light.made[#Light.made]
  h.light = light
  OnDriverInit()
  OnDriverLateInit()
  local bulb = upvalue(light.adapter.send, "bulb")
  local stateAt = upvalue(light.adapter.send, "stateAt")
  local reportState = upvalue(light.adapter.send, "reportState")
  local declaration = upvalue(OnDriverLateInit, "DECLARATION")
  return {
    state = function()
      return stateAt(h.clock.now())
    end,
    set = function(state, _, quiet)
      local now = h.clock.now()
      local from = stateAt(now)
      bulb.fade = { at = now, ms = 0, level = from.on and from.level or 0, color = from.color }
      for k, v in pairs(state) do
        bulb[k] = v
      end
      if not quiet then
        reportState()
      end
    end,
    drop = function()
      light:lost()
    end,
    back = function()
      light:declare(declaration)
      reportState()
    end,
    dims = true,
    color = true,
    cct = declaration.cct,
    stops = true,
    declaration = function()
      return declaration
    end,
  }
end

-- The declarations the contract checks before it loads the driver for each case.
F.dofileBuild(DRIVER, "oss")
rig.declarations = { upvalue(OnDriverLateInit, "DECLARATION") }

return { version = H.RIG_VERSION, rigs = { example_light = { rig } } }
