-- The light library in Control4 load groups, over MemoryLight behind the fake proxy: what a stock load group
-- sends a member (measured on a controller), and a group in sync taking the light's own commands. The template's
-- own test: no driver repo gets it.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local K = require("behavior_kit")
local M = require("memory_light")

local GROUP = 1205

local function case(fn)
  K.case(T, fn)
end

local near = K.near

--- A world over a light that offers load groups, lit to `level` when given.
--- @param level integer|nil
--- @return MemoryWorld
local function world(level)
  local o = M.copy(K.ES)
  local profile = M.profile(o)
  profile.loadGroups = true
  o.profile = profile
  return K.world(o, {}, level)
end

--- The commands sent since the mark that change the level.
--- @param w MemoryWorld
--- @return LightCommand[]
local function changes(w)
  local out = {}
  for _, c in ipairs(w.m.sent) do
    if c.kind == "change" and c.setsLevel then
      out[#out + 1] = c
    end
  end
  return out
end

--- Record what the light hands to other devices until `restore` is called.
--- @return {[1]: integer, [2]: string, [3]: table}[] handed
--- @return fun() restore
local function recordHanded()
  local handed = {}
  local sendToDevice = C4.SendToDevice
  C4.SendToDevice = function(c4, id, cmd, params, ...)
    handed[#handed + 1] = { id, cmd, params }
    return sendToDevice(c4, id, cmd, params, ...)
  end
  return handed, function()
    C4.SendToDevice = sendToDevice
  end
end

T.section("a group's On, Off and Set Level arrive as GROUP_SET_LEVEL and act as Set Level")
case(function()
  local w = world(30)
  w.proxy:send("GROUP_SET_LEVEL", { GROUP_ID = GROUP, LEVEL = 100 })
  w.run(5000)
  T.eq("full", w.proxy.level, 100)
  w.proxy:send("GROUP_SET_LEVEL", { GROUP_ID = GROUP, LEVEL = 0 })
  w.run(5000)
  T.eq("off", { w.proxy.level, K.device(w).on }, { 0, false })
  w.restore()
end)

T.section("a group's ramp goes over its time")
case(function()
  local w = world(20)
  w.proxy:send("GROUP_RAMP_TO_LEVEL", { GROUP_ID = GROUP, LEVEL = 80, TIME = 2000 })
  local moved = changes(w)
  T.eq(
    "one change to 80 over 2000 ms",
    { #moved, near((moved[1] or {}).level, 0.8, 0.01), (moved[1] or {}).transitionMs },
    {
      1,
      true,
      2000,
    }
  )
  w.run(5000)
  T.eq("lands", w.proxy.level, 80)
  w.restore()
end)

T.section("a group's hold goes over its rate scaled by the distance left, and its stop holds the light there")
case(function()
  local w = world(30)
  w.proxy:send("GROUP_START_RAMP", { GROUP_ID = GROUP, RAMP_UP = 1, RATE = 5000 })
  local moved = changes(w)
  T.eq("to full over 70 % of 5000 ms", { near((moved[1] or {}).level, 1, 0.01), (moved[1] or {}).transitionMs }, {
    true,
    3500,
  })
  w.run(1000)
  w.proxy:send("GROUP_STOP_RAMP", { GROUP_ID = GROUP })
  T.eq("the stop is sent", #w.m:sentOf("stop"), 1)
  w.run(5000)
  local held = w.proxy.level
  T.check("part way", held > 30 and held < 100, held)
  w.restore()
end)

T.section("a group's click: a hold start and, 3 ms later, a ramp to the end at the click rate, with no stop")
case(function()
  local w = world(60)
  w.proxy:send("GROUP_START_RAMP", { GROUP_ID = GROUP, RAMP_UP = 0, RATE = 5000 })
  w.run(3)
  w.proxy:send("GROUP_RAMP_TO_LEVEL", { GROUP_ID = GROUP, LEVEL = 0, TIME = 750 })
  w.run(5000)
  T.eq("the ramp replaces the hold and ends off", { w.proxy.level, K.device(w).on }, { 0, false })
  T.eq("nothing was stopped", #w.m:sentOf("stop"), 0)
  w.restore()
end)

T.section("a group in sync takes the light's On, Off, levels and buttons; the group's own commands still act")
case(function()
  local w = world(30)
  local handed, restore = recordHanded()
  w.proxy:send("JOIN_GROUP", { GROUP_ID = GROUP, KEEP_SYNC = 0 })
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(5000)
  T.eq("out of sync, the light acts and hands nothing on", { w.proxy.level, #handed }, { 50, 0 })

  w.proxy:send("SET_GROUP_SYNC", { GROUP_ID = GROUP, KEEP_SYNC = 1 })
  w.m.sent = {}
  w.proxy:send("OFF")
  w.proxy:send("SET_LEVEL", { LEVEL = 10 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20 })
  K.button(w, 0, 1)
  w.run(5000)
  T.eq("each goes to the group", handed, {
    { GROUP, "OFF", {} },
    { GROUP, "SET_LEVEL", { LEVEL = 10 } },
    { GROUP, "RAMP_TO_LEVEL", { LEVEL = 20, TIME = tostring(w.m.light.settings:forMotion().rate) } },
    { GROUP, "BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 1 } },
  })
  T.eq("and the light does nothing itself", { #w.m.sent, w.proxy.level }, { 0, 50 })

  w.proxy:send("GROUP_SET_LEVEL", { GROUP_ID = GROUP, LEVEL = 0 })
  w.run(5000)
  T.eq("the group's own level acts, and is not handed back", { w.proxy.level, #handed }, { 0, 4 })

  w.proxy:send("LEAVE_GROUP", { GROUP_ID = GROUP })
  w.proxy:send("ON")
  w.run(5000)
  T.eq("out of the group, the light acts", { K.device(w).on, #handed }, { true, 4 })
  restore()
  w.restore()
end)

T.section("membership survives a driver restart")
case(function()
  local w = world(30)
  local handed, restore = recordHanded()
  w.proxy:send("JOIN_GROUP", { GROUP_ID = GROUP, KEEP_SYNC = 1 })
  w.restart()
  w.proxy:send("TOGGLE")
  T.eq("the group in sync still takes the light's Toggle", handed, { { GROUP, "TOGGLE", {} } })
  w.proxy:send("LEAVE_GROUP", { GROUP_ID = GROUP })
  restore()
  w.restore()
end)

T.finish()
