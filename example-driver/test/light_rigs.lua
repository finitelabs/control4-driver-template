-- example_light's rig for the conformance run (test/test_light_conformance.lua). A light repo writes its
-- own: one or more rigs per light_v2 driver, each loading the driver as it ships and faking only its
-- transport. example_light's transport is the bulb its adapter holds, which the rig reaches through the
-- light the chunk made.

local C = require("light_conformance")
local D = require("light_drivers")
local F = require("c4_fixtures")
local Light = require("lib.light")

local DRIVER = D.path(D.root(), "example_light")

--- @param color LightColor
--- @return LightColor
local function copyColor(color)
  return { x = color.x, y = color.y, mode = color.mode or "xy", kelvin = color.kelvin }
end

--- @type LightRig
local rig = { name = "example_light", folder = "example_light", settleMs = 1000 }

--- Load the driver afresh, with the bulb in `state`, and run its init.
--- @param h LightRigHarness
--- @param state LightValues|nil
--- @return LightRigDevice
function rig.load(h, state)
  F.dofileBuild(DRIVER, "oss")
  local light = Light.made[#Light.made]
  h.light = light
  --- @type ExampleLightAdapter
  local adapter = light.adapter
  local bulb = adapter.bulb
  if state then
    bulb.on = state.on == true
    bulb.level = state.level or bulb.level
    if state.color and state.color.x then
      bulb.color = copyColor(state.color)
    end
    bulb.fade = { at = h.clock.now(), ms = 0, level = bulb.on and bulb.level or 0, color = bulb.color }
  end
  OnDriverInit()
  OnDriverLateInit()
  return {
    state = function()
      return adapter:stateAt(h.clock.now())
    end,
    set = function(change, quiet)
      local now = h.clock.now()
      local from = adapter:stateAt(now)
      bulb.fade = { at = now, ms = 0, level = from.on and from.level or 0, color = from.color }
      if change.on ~= nil then
        bulb.on = change.on
      end
      if change.level then
        bulb.level = change.level
      end
      if change.color and change.color.x then
        bulb.color = copyColor(change.color)
      end
      if quiet then
        light:report({ kind = "push", on = bulb.on })
      else
        adapter:report()
      end
    end,
    drop = function()
      light:lost(false)
    end,
    back = function()
      light:declare(light.device)
      adapter:report()
    end,
    suspend = function()
      light:lost(true)
    end,
    resume = function()
      light:declare(light.device)
      adapter:report()
    end,
  }
end

return { version = C.RIG_VERSION, rigs = { example_light = { rig } } }
