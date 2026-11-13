-- The fake proxy pinned to what the dev proxies were measured doing, so the library's suites and every
-- repo's conformance run test against the proxy as it is. Each case names where its fact was measured:
--   zb: control4-zigbee3 4cbbee10 test/test_light_feedback.lua
--   tp: control4-tplink f9b0d1b test/test_light_direct.lua
--   es: control4-esphome 0b6846d test/test_light_scenes.lua
-- The light proxy takes no STATE_ notify form: none of the three drivers sends one.

local T = require("testlib")
local F = require("c4_fixtures")

require("c4_shim")

local P = require("light_proxy_fake")

_G.RFP = _G.RFP or {}

--- @type {cmd: string, params: table<string, any>}[]
local heard = {}
RFP[P.PROXY] = function(_, cmd, params)
  heard[#heard + 1] = { cmd = cmd, params = params }
end

--- @param cmd string
--- @param params table<string, any>
local function tell(cmd, params)
  C4:SendToProxy(P.PROXY, cmd, params, "NOTIFY")
end

--- @param p FakeProxy
--- @param id integer
--- @return string|nil
local function var(p, id)
  local v = p.vars[tostring(id)]
  return v and v.value
end

--- @param p FakeProxy
--- @param key string
--- @return string|nil
local function listed(p, key)
  return (var(p, 6661) or ""):match("<" .. key .. ">([^<]*)</" .. key .. ">")
end

local clock = F.virtualClock()

T.section("GET_SETUP: a new light's answer until the proxy hears it has color (zb 463-465, the 732 captures)")
do
  local p = P.install(clock, { setup = P.setupFile("setup-732.xml"), newLight = P.setupFile("setup-732-new.xml") })
  T.eq("before: the new light's", C4:SendUIRequest(P.PROXY_DEVICE, "GET_SETUP", {}), P.setupFile("setup-732-new.xml"))
  tell("DYNAMIC_CAPABILITIES_CHANGED", { supports_color = true })
  T.eq(
    "after supports_color: the light's own",
    C4:SendUIRequest(P.PROXY_DEVICE, "GET_SETUP", {}),
    P.setupFile("setup-732.xml")
  )
  p:restore()
end

T.section("1001 and 1110: the level and its target (zb 470-473, tp 420-427)")
do
  local p = P.install(clock)
  tell("LIGHT_BRIGHTNESS_CHANGING", { LIGHT_BRIGHTNESS_CURRENT = 20, LIGHT_BRIGHTNESS_TARGET = 80, RATE = 1000 })
  T.eq("CHANGING: 1001 is its current", var(p, 1001), "20")
  T.eq("and 1110 its target", var(p, 1110), "80")
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 80 })
  T.eq("CHANGED: both its value", { var(p, 1001), var(p, 1110) }, { "80", "80" })
  p:restore()
end

T.section(
  "a light that does not dim: no 1110, rate ranges 0, asked its level as it comes online (zb 473-476, tp 324-325)"
)
do
  local p = P.install(clock)
  heard = {}
  tell("DYNAMIC_CAPABILITIES_CHANGED", { dimmer = false, brightness_rate_max = 65535, click_rate_max = 65535 })
  T.eq("6661 says it does not dim", listed(p, "dimmer"), "False")
  T.eq("and lists its brightness rate 0", listed(p, "brightness_rate_max"), "0")
  T.eq("and its click rate 0", listed(p, "click_rate_max"), "0")
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 100 })
  T.eq("1001 holds the level", var(p, 1001), "100")
  T.eq("and there is no 1110", var(p, 1110), nil)
  tell("ONLINE_CHANGED", { STATE = true })
  T.eq("ONLINE_CHANGED true asks GET_LIGHT_LEVEL inside it", heard[#heard] and heard[#heard].cmd, "GET_LIGHT_LEVEL")
  local asked = #heard
  tell("ONLINE_CHANGED", { STATE = true })
  T.eq("but not again while it stays online", #heard, asked)
  p:restore()
end

T.section("a light that dims is not asked its level at online")
do
  local p = P.install(clock)
  heard = {}
  tell("DYNAMIC_CAPABILITIES_CHANGED", { dimmer = true })
  tell("ONLINE_CHANGED", { STATE = true })
  T.eq("no GET_LIGHT_LEVEL", #heard, 0)
  p:restore()
end

T.section("1200 and 1210: the color as x,y,mode to six figures (zb 470-472, tp 431-433)")
do
  local p = P.install(clock)
  tell("LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = 0.31576713349498398,
    LIGHT_COLOR_CURRENT_Y = 0.32566383425793799,
    LIGHT_COLOR_CURRENT_COLOR_MODE = 1,
  })
  T.eq("1200", var(p, 1200), "0.315767,0.325664,1")
  T.eq("1210 the same", var(p, 1210), "0.315767,0.325664,1")
  tell("LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_CURRENT_X = 0.3,
    LIGHT_COLOR_CURRENT_Y = 0.3,
    LIGHT_COLOR_CURRENT_COLOR_MODE = 0,
    LIGHT_COLOR_TARGET_X = 0.64,
    LIGHT_COLOR_TARGET_Y = 0.33,
    LIGHT_COLOR_TARGET_COLOR_MODE = 0,
  })
  T.eq("CHANGING: 1200 its current and 1210 its target", { var(p, 1200), var(p, 1210) }, { "0.3,0.3,0", "0.64,0.33,0" })
  p:restore()
end

T.section("a color told with a preset id and no origin is dropped whole (zb 682, dev 2026-10-29)")
do
  local p = P.install(clock)
  tell(
    "LIGHT_COLOR_CHANGED",
    { LIGHT_COLOR_CURRENT_X = 0.3, LIGHT_COLOR_CURRENT_Y = 0.3, LIGHT_COLOR_CURRENT_COLOR_MODE = 0 }
  )
  tell("LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = 0.64,
    LIGHT_COLOR_CURRENT_Y = 0.33,
    LIGHT_COLOR_CURRENT_COLOR_MODE = 0,
    LIGHT_COLOR_CURRENT_PRESET_ID = 3,
  })
  T.eq("1200 keeps the color before it", var(p, 1200), "0.3,0.3,0")
  tell("LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = 0.64,
    LIGHT_COLOR_CURRENT_Y = 0.33,
    LIGHT_COLOR_CURRENT_COLOR_MODE = 0,
    LIGHT_COLOR_CURRENT_PRESET_ID = 3,
    LIGHT_COLOR_CURRENT_PRESET_ORIGIN = 2,
  })
  T.eq("with its origin it is taken", var(p, 1200), "0.64,0.33,0")
  p:restore()
end

T.section("6661: every key it holds, rewritten only by a change to one that rewrites it (zb 486-523, tp 321-373)")
do
  local p = P.install(clock, { capabilities = { dimmer = "True", brightness_rate_max = "65535" } })
  tell("DYNAMIC_CAPABILITIES_CHANGED", { supports_target = true })
  local order = {}
  for key in (var(p, 6661) or ""):gmatch("<(%l[%w_]*)>") do
    if key ~= "DynamicCapabilities" then
      order[#order + 1] = key
    end
  end
  T.eq("lists every key, in its order", order, P.CAPABILITY_KEYS)
  T.eq("driver.xml's held until told others", listed(p, "brightness_rate_max"), "65535")
  tell("DYNAMIC_CAPABILITIES_CHANGED", { brightness_rate_max = 86400000 })
  T.eq("a brightness rate alone does not rewrite it", listed(p, "brightness_rate_max"), "65535")
  T.eq("though the proxy holds it", p.held.brightness_rate_max, "86400000")
  tell("DYNAMIC_CAPABILITIES_CHANGED", { color_rate_max = 86400000 })
  T.eq("a color rate rewrites it", listed(p, "color_rate_max"), "86400000")
  T.eq("and the held brightness rate shows with it", listed(p, "brightness_rate_max"), "86400000")
  p:restore()
end

T.section("6661 at a start: what the proxy held, as its variable kept it (tp 321-323)")
do
  local p = P.install(clock, {
    variables = {
      [6661] = "<DynamicCapabilities><dimmer>True</dimmer><supports_color>True</supports_color></DynamicCapabilities>",
    },
  })
  T.eq("held from 6661", { p.held.dimmer, p.held.supports_color }, { "True", "True" })
  T.eq("dims", p:dims(), true)
  p:restore()
end

T.section("Previous On: written at each off from the last level told, and pushed to the driver (es 1780, tp 1546)")
do
  local p = P.install(clock)
  heard = {}
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 35 })
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 })
  T.eq("the preset is the last level above 0", p.previousOn, 35)
  clock.run(1)
  local push = heard[#heard]
  T.eq("UPDATE_BRIGHTNESS_PRESET MODIFIED 10 Previous On", push and {
    push.cmd,
    push.params.COMMAND,
    push.params.ID,
    push.params.NAME,
    push.params.LEVEL,
  }, { "UPDATE_BRIGHTNESS_PRESET", "MODIFIED", 10, "Previous On", 35 })
  p:restore()
end

--- The commands the light heard since `from`, by name.
--- @param from integer
--- @param cmd string
--- @return table<string, any>[]
local function since(from, cmd)
  local out = {}
  for i = from + 1, #heard do
    if heard[i].cmd == cmd then
      out[#out + 1] = heard[i].params
    end
  end
  return out
end

T.section("Previous On at an off: its level only when it changed, its color every time (dev 2026-11-12, 4 lights)")
do
  local p = P.install(clock)
  heard = {}
  tell("LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = 0.4357,
    LIGHT_COLOR_CURRENT_Y = 0.2814,
    LIGHT_COLOR_CURRENT_COLOR_MODE = 0,
  })
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 60 })
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 })
  clock.run(20)
  local color = since(0, "UPDATE_COLOR_PRESET")[1] or {}
  T.eq("the first off pushes the level", #since(0, "UPDATE_BRIGHTNESS_PRESET"), 1)
  T.eq(
    "and UPDATE_COLOR_PRESET MODIFIED 10 Previous On in the color 1200 holds",
    { color.COMMAND, color.ID, color.NAME, color.COLOR_X, color.COLOR_Y, color.COLOR_MODE },
    { "MODIFIED", 10, "Previous On", 0.4357, 0.2814, 0 }
  )
  local mark = #heard
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 60 })
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 })
  clock.run(20)
  T.eq("an off at the same level pushes no level", #since(mark, "UPDATE_BRIGHTNESS_PRESET"), 0)
  T.eq("but the color again", #since(mark, "UPDATE_COLOR_PRESET"), 1)
  mark = #heard
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 30 })
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 })
  clock.run(20)
  T.eq("an off at a new level pushes it", (since(mark, "UPDATE_BRIGHTNESS_PRESET")[1] or {}).LEVEL, 30)
  p:restore()
end

T.section("a light with no color told gets no Previous On color at its off")
do
  local p = P.install(clock)
  heard = {}
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 60 })
  tell("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 })
  clock.run(20)
  T.eq("no UPDATE_COLOR_PRESET", #since(0, "UPDATE_COLOR_PRESET"), 0)
  p:restore()
end

T.section("the app's On: the brightness on mode's preset, and a follow-up only under Dim-To-Warm (dev 2026-11-12)")
do
  local p = P.install(clock)
  heard = {}
  p:appOn(60)
  clock.run(50)
  local on = since(0, "SET_BRIGHTNESS_TARGET")[1] or {}
  T.eq(
    "SET_BRIGHTNESS_TARGET at the level over 750 ms, naming Default On",
    { on.LIGHT_BRIGHTNESS_TARGET, on.LIGHT_BRIGHTNESS_TARGET_PRESET_ID, on.RATE },
    { 60, 1, 750 }
  )
  T.eq("with no on mode, no follow-up", #since(0, "SET_COLOR_TARGET"), 0)

  local sunset = {
    COLOR_PRESET_ID = 8,
    COLOR_PRESET_ORIGIN = 2,
    COLOR_PRESET_COLOR_X = 0.608506,
    COLOR_PRESET_COLOR_Y = 0.357644,
    COLOR_PRESET_COLOR_MODE = 0,
    COLOR_FADE_PRESET_ID = 0,
    COLOR_FADE_PRESET_ORIGIN = 0,
  }
  p:send("UPDATE_COLOR_ON_MODE", sunset)
  local mark = #heard
  p:appOn(60)
  clock.run(50)
  T.eq("a preset as the On color sends no follow-up", #since(mark, "SET_COLOR_TARGET"), 0)

  p:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 10, BRIGHTNESS_PRESET_LEVEL = 35 })
  mark = #heard
  p:appOn(35)
  T.eq(
    "under Previous it names preset 10",
    (since(mark, "SET_BRIGHTNESS_TARGET")[1] or {}).LIGHT_BRIGHTNESS_TARGET_PRESET_ID,
    10
  )
  clock.run(50)

  p:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 1, BRIGHTNESS_PRESET_LEVEL = 60 })
  p:send("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 2,
    COLOR_PRESET_COLOR_X = 0.317097,
    COLOR_PRESET_COLOR_Y = 0.327069,
    COLOR_PRESET_COLOR_MODE = 1,
    COLOR_FADE_PRESET_ID = 6,
    COLOR_FADE_PRESET_ORIGIN = 2,
    COLOR_FADE_PRESET_COLOR_X = 0.526676,
    COLOR_FADE_PRESET_COLOR_Y = 0.413297,
    COLOR_FADE_PRESET_COLOR_MODE = 1,
  })
  mark = #heard
  p:appOn(60)
  clock.run(17)
  T.eq("under Dim-To-Warm, nothing more for 17 ms", #since(mark, "SET_COLOR_TARGET"), 0)
  clock.run(1)
  local follow = since(mark, "SET_COLOR_TARGET")[1] or {}
  T.eq("then the On preset at its full color", {
    follow.LIGHT_COLOR_TARGET_X,
    follow.LIGHT_COLOR_TARGET_Y,
    follow.LIGHT_COLOR_TARGET_MODE,
    follow.LIGHT_COLOR_TARGET_PRESET_ID,
    follow.LIGHT_COLOR_TARGET_PRESET_ORIGIN,
    follow.LIGHT_COLOR_TARGET_RATE,
  }, { 0.317097, 0.327069, 1, 1, 2, 750 })
  T.eq("its rate as LIGHT_COLOR_TARGET_RATE alone", follow.LIGHT_COLOR_TARGET_COLOR_RATE, nil)
  clock.run(50)
  p:restore()
end

T.section("a Default On level set on the proxy: SET_PRESET_LEVEL twice, then preset 1 (dev 2026-11-12)")
do
  local p = P.install(clock)
  heard = {}
  p:presetLevel(45)
  clock.run(10)
  local cmds = {}
  for _, h in ipairs(heard) do
    cmds[#cmds + 1] = h.cmd .. " " .. tostring(h.params.LEVEL)
  end
  T.eq("in that order", cmds, { "SET_PRESET_LEVEL 45", "SET_PRESET_LEVEL 45", "UPDATE_BRIGHTNESS_PRESET 45" })
  local push = heard[3] and heard[3].params or {}
  T.eq("MODIFIED 1 On", { push.COMMAND, push.ID, push.NAME }, { "MODIFIED", 1, "On" })
  p:restore()
end

T.section("a command reaches the light as Director delivers it: a command-keyed RFP first, then the binding's")
do
  local p = P.install(clock)
  heard = {}
  local keyed = 0
  RFP.EXTRA_SET = function()
    keyed = keyed + 1
  end
  p:send("EXTRA_SET", {})
  p:send("ON", {})
  T.eq("the command-keyed handler took EXTRA_SET", keyed, 1)
  T.eq("the binding's took ON", heard[#heard] and heard[#heard].cmd, "ON")
  RFP.EXTRA_SET = nil
  p:restore()
end

clock.restore()
T.finish()
