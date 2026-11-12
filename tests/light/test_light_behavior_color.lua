-- The light library's behavior over MemoryLight behind the fake proxy: color, the color held while
-- off, the on modes, Dim-To-Warm and the picks. The template's own test: no driver repo gets it.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local K = require("behavior_kit")

local function case(fn)
  K.case(T, fn)
end

local near = K.near
local RED, GREEN = K.RED, K.GREEN

--- The commands sent since the mark that set a color.
--- @param w MemoryWorld
--- @return LightCommand[]
local function colored(w)
  local out = {}
  for _, c in ipairs(w.m.sent) do
    if c.setsColor then
      out[#out + 1] = c
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Color commands
--------------------------------------------------------------------------------

T.section("a color over a rate: CHANGING to it, CHANGED at its end, and the device ends there")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.color(w, RED.x, RED.y, 2000)
  local changing = w.proxy:last("LIGHT_COLOR_CHANGING") or {}
  T.check("CHANGING to it", near(changing.LIGHT_COLOR_TARGET_X, RED.x), changing)
  T.eq("one command over the rate", { #w.m.sent, (w.m.sent[1] or {}).transitionMs }, { 1, 2000 })
  w.run(1000)
  T.eq("no CHANGED part way", w.proxy:count("LIGHT_COLOR_CHANGED"), 0)
  w.run(4000)
  T.check("CHANGED at its end", near((w.proxy.color or {}).x, RED.x), w.proxy.color)
  T.check("the device there", near(K.device(w).color.x, RED.x, 0.01), K.device(w).color)
  w.restore()
end)

T.section("a color for an off light that takes it goes with on = false, and lights nothing")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.color(w, RED.x, RED.y)
  local c = w.m.sent[1] or {}
  T.eq("sent with on = false", { #w.m.sent, c.on, c.setsColor }, { 1, false, true })
  w.run(3000)
  T.eq("the light stays off", K.device(w).on, false)
  T.check("and the proxy shows it off", (w.proxy.level or 0) == 0, w.proxy.level)
  T.check("the device holds the color", near(K.device(w).color.x, RED.x, 0.01), K.device(w).color)
  w.restore()
end)

T.section("hold: a color for an off light is told, not sent, and the next On carries it")
for _, base in ipairs({ K.HOLD, K.WALK }) do
  case(function()
    local w = K.world(base, {}, 0)
    K.color(w, RED.x, RED.y)
    T.eq("nothing sent", #w.m.sent, 0)
    T.check("the proxy shows it", near((w.proxy.color or {}).x, RED.x), w.proxy.color)
    w.proxy:send("ON")
    local on = colored(w)[1] or {}
    T.eq("the On carries it", { on.fromOff, on.setsColor }, { true, true })
    T.check("in that color", near((on.color or {}).x, RED.x), on.color)
    w.run(5000)
    T.check("the device lit in it", near(K.device(w).color.x, RED.x, 0.01), K.device(w).color)
    T.eq("and dropped no color", w.device.droppedColors, 0)
    w.restore()
  end)
end

T.section("J1: on a hold device, a report that says off carries no color news")
case(function()
  local w = K.world(K.HOLD, {}, 0)
  K.color(w, RED.x, RED.y)
  w.proxy:mark()
  w.light:report({ kind = "push", on = false, color = { x = 0.3127, y = 0.329, mode = "xy" } })
  w.light:report({ kind = "push", color = { x = 0.3127, y = 0.329, mode = "xy" } })
  w.run(1000)
  T.eq("no color told", w.proxy:count("LIGHT_COLOR_CHANGED") + w.proxy:count("LIGHT_COLOR_CHANGING"), 0)
  T.check("the held color stands", near((w.proxy.color or {}).x, RED.x), w.proxy.color)
  w.restore()
end)

T.section("J1: a restart keeps the held color: the proxy's stands at the first report, and the next On carries it")
case(function()
  local w = K.world(K.HOLD, {}, 0)
  K.color(w, RED.x, RED.y)
  w.run(1000)
  w.restart()
  w.run(5000)
  T.eq("no color told at the restart", w.proxy:count("LIGHT_COLOR_CHANGED") + w.proxy:count("LIGHT_COLOR_CHANGING"), 0)
  w.proxy:send("ON")
  local on = colored(w)[1] or {}
  T.check("the On carries the held color", near((on.color or {}).x, RED.x), on.color)
  w.restore()
end)

T.section("a white on a light with color and CCT goes as a color temperature, clamped to the device's range")
case(function()
  local w = K.world(K.ES, {}, 100)
  local x, y = C4:ColorCCTtoXY(2700)
  K.color(w, x, y, 0, K.CCT)
  local c = (w.m.sent[1] or {}).color or {}
  T.eq("a cct color", c.mode, "cct")
  T.check("at its Kelvin", c.kelvin and math.abs(c.kelvin - 2700) <= 30, c.kelvin)
  w.run(2000)
  w.m.sent = {}
  x, y = C4:ColorCCTtoXY(1500)
  K.color(w, x, y, 0, K.CCT)
  c = (w.m.sent[1] or {}).color or {}
  T.eq("one below the range at its floor", c.kelvin, 2000)
  w.restore()
end)

T.section("a color preset is told with its id and its origin (Rule 3.5)")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.color(w, RED.x, RED.y, 0, K.FULL, { id = 3, origin = 2 })
  w.run(3000)
  local told = w.proxy:last("LIGHT_COLOR_CHANGED") or w.proxy:last("LIGHT_COLOR_CHANGING") or {}
  local id, origin
  for k, v in pairs(told) do
    if k:match("PRESET_ID$") then
      id = v
    elseif k:match("PRESET_ORIGIN$") then
      origin = v
    end
  end
  T.eq("the preset's id and origin", { id, origin }, { 3, 2 })
  w.restore()
end)

T.section("another hand's color is told with no preset id")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.color(w, RED.x, RED.y, 0, K.FULL, { id = 3, origin = 2 })
  w.run(5000)
  w.proxy:mark()
  w.m:other({ color = { x = GREEN.x, y = GREEN.y, mode = "xy" } })
  w.run(2000)
  local told = w.proxy:last("LIGHT_COLOR_CHANGED") or {}
  T.check("told", near(told.LIGHT_COLOR_CURRENT_X, GREEN.x, 0.01), told)
  T.eq("with no preset", told.LIGHT_COLOR_CURRENT_PRESET_ID, nil)
  w.restore()
end)

--------------------------------------------------------------------------------
-- The on modes
--------------------------------------------------------------------------------

T.section("the proxy's setup at start: its Dim-To-Warm and its default rate act before any push")
case(function()
  local Fake = require("light_proxy_fake")
  local w = K.world(K.ES, { setup = Fake.setupFile("setup-607.xml") }, 100)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  local c = (colored(w)[1] or {}).color or {}
  T.check("a level carries the Dim-To-Warm mix", c.mode == "cct" and c.kelvin ~= nil, c)
  w.run(5000)
  T.eq("and lands", w.proxy.level, 50)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70 })
  T.eq("a target with no rate takes the setup's default", (w.m.sent[#w.m.sent] or {}).transitionMs, 750)
  w.run(5000)
  w.restore()
end)

T.section("an On goes to the brightness on mode's level, else the preset level, and follows the preset's edits")
case(function()
  local w = K.world(K.ES, {}, 0)
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 70 })
  w.proxy:send("ON")
  w.run(10000)
  T.eq("an On goes to the preset level", w.proxy.level, 70)
  w.proxy:send("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "ADDED", ID = 4, NAME = "Reading", LEVEL = 35 })
  w.proxy:send("SET_BRIGHTNESS_ON_MODE", { PRESET_ID = 4 })
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("ON")
  w.run(10000)
  T.eq("with an on mode, to its preset's level", w.proxy.level, 35)
  w.proxy:send("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "MODIFIED", ID = 4, NAME = "Reading", LEVEL = 45 })
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("ON")
  w.run(10000)
  T.eq("which follows an edit of the preset", w.proxy.level, 45)
  w.restore()
end)

T.section("without Default On, an On with no on mode resumes at the level the device kept")
case(function()
  local o = K.copy(K.HOLD)
  local profile = require("memory_light").profile(o)
  profile.defaultOn = false
  o.profile = profile
  local w = K.world(o, {}, 40)
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 90 })
  w.proxy:send("OFF")
  w.run(5000)
  w.proxy:send("ON")
  w.run(5000)
  T.eq("back at 40, not the preset", w.proxy.level, 40)
  w.restore()
end)

T.section("Color On Mode preset: an On from off comes on in it, and the proxy's follow-up is not sent again")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.onMode(w, K.ON_PRESET)
  w.proxy:appOn(100, { x = K.ON_PRESET.x, y = K.ON_PRESET.y, preset = 1, origin = 1 })
  w.run(10)
  local first = colored(w)
  T.eq("the pre-on and its change both carry the preset's color (contract edit 4)", #first, 2)
  T.check("that color", near(((first[1] or {}).color or {}).x, K.ON_PRESET.x), first[1])
  w.run(5000)
  T.eq("the follow-up sends no color again", #colored(w), 2)
  T.check("told in it", near((w.proxy.color or {}).x, K.ON_PRESET.x), w.proxy.color)
  w.restore()
end)

T.section("Previous: an On from off comes on in the color it was last on in")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.color(w, GREEN.x, GREEN.y)
  w.run(3000)
  w.proxy:send("OFF")
  w.run(3000)
  K.onMode(w, { id = 10, origin = 1, x = 0, y = 0 })
  w.m.sent = {}
  w.proxy:send("ON")
  w.run(10)
  local first = w.m.sent[#w.m.sent] or {}
  T.check("the On names the previous color", near((first.color or {}).x, GREEN.x, 0.01), first.color)
  w.run(3000)
  T.check("and the device comes on in it", near(K.device(w).color.x, GREEN.x, 0.01), K.device(w).color)
  w.restore()
end)

T.section("Dim-To-Warm: each level carries the mix between the Dim and On colors, as a color temperature")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  local c = (colored(w)[1] or {}).color or {}
  local x, y =
    C4:ColorCCTtoXY(C4:ColorXYtoCCT(K.DIM.x + (K.WARM.x - K.DIM.x) * 0.5, K.DIM.y + (K.WARM.y - K.DIM.y) * 0.5))
  T.check("half way, on the line of whites", c.mode == "cct" and near(c.x, x, 0.003) and near(c.y, y, 0.003), c)
  w.run(5000)
  K.color(w, GREEN.x, GREEN.y)
  w.run(3000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  -- Rule 3.7 (K05, K06): a color set in an on cycle is a pick until the next off, so the mix waits for it.
  T.eq("a color set is a pick: the next level brings no mix", #colored(w), 0)
  w.run(5000)
  w.proxy:send("OFF")
  w.run(5000)
  w.proxy:send("ON")
  w.run(5000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("after the off, a level brings the mix again", #colored(w), 1)
  w.run(5000)
  w.restore()
end)

T.section("Dim-To-Warm with the On and Dim colors the same: a level fade tells no color event (WLED dig2go, 11-10)")
for _, base in ipairs({ K.ES, K.ZB, K.WALK }) do
  for _, pair in ipairs({
    { name = "a white", on = K.WARM, dim = { id = 2, origin = 1, x = K.WARM.x, y = K.WARM.y, mode = K.CCT } },
    { name = "a full color", on = K.ON_PRESET, dim = { id = 2, origin = 1, x = K.ON_PRESET.x, y = K.ON_PRESET.y } },
  }) do
    case(function()
      local w = K.world(base, {}, 100)
      K.onMode(w, pair.on, pair.dim)
      w.proxy:send("SET_LEVEL", { LEVEL = 100 })
      w.run(20000)
      w.proxy:mark()
      K.target(w, 30, 3000)
      w.run(1500)
      K.target(w, 80, 3000)
      w.run(20000)
      T.eq(pair.name .. ": no color CHANGING", w.proxy:count("LIGHT_COLOR_CHANGING"), 0)
      T.eq(pair.name .. ": no color CHANGED", w.proxy:count("LIGHT_COLOR_CHANGED"), 0)
      T.check(pair.name .. ": while the level moved", w.proxy:count("LIGHT_BRIGHTNESS_CHANGING") > 0)
      w.restore()
    end)
  end
end
case(function()
  local w = K.world(K.ES, {}, 100)
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(20000)
  w.proxy:mark()
  K.target(w, 30, 3000)
  w.run(20000)
  T.check("the control: On and Dim apart, the fade tells its color", w.proxy:count("LIGHT_COLOR_CHANGING") > 0)
  w.restore()
end)

T.section("the walk under Dim-To-Warm: each step carries the mix for its level")
case(function()
  local w = K.world(K.WALK, {}, 100)
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(5000)
  w.m.sent = {}
  K.target(w, 20, 1000)
  w.run(3000)
  local kelvins = {}
  for _, c in ipairs(colored(w)) do
    kelvins[#kelvins + 1] = c.color and c.color.kelvin
  end
  local distinct = {}
  for _, k in ipairs(kelvins) do
    distinct[k or -1] = true
  end
  local n = 0
  for _ in pairs(distinct) do
    n = n + 1
  end
  T.check("the steps move through the mix", n > 2, kelvins)
  w.restore()
end)

T.section("colorUnchosen: Previous On's color, and a level change's Dim-To-Warm color, but not an on's (zb:1479-1482)")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.color(w, GREEN.x, GREEN.y)
  w.run(3000)
  w.proxy:send("OFF")
  w.run(3000)
  K.onMode(w, { id = 10, origin = 1, x = 0, y = 0 })
  w.m.sent = {}
  K.target(w, 80, 4000)
  local on = w.m.sent[#w.m.sent] or {}
  T.eq("Previous On's color is unchosen", on.colorUnchosen, true)
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.eq("and so is its stop", (w.m:sentOf("stop")[1] or {}).colorUnchosen, true)
  w.restore()
end)
case(function()
  local w = K.world(K.ES, {}, 0)
  K.onMode(w, K.WARM, K.DIM)
  K.target(w, 80, 4000)
  local chosen = 0
  for _, c in ipairs(w.m.sent) do
    if c.colorUnchosen then
      chosen = chosen + 1
    end
  end
  T.eq("an on's Dim-To-Warm color is no unchosen color", chosen, 0)
  w.run(6000)
  w.m.sent = {}
  K.target(w, 20, 4000)
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.eq("a level change's mix is: its stop says so", (w.m:sentOf("stop")[1] or {}).colorUnchosen, true)
  w.restore()
end)

--------------------------------------------------------------------------------
-- The picks
--------------------------------------------------------------------------------

T.section("DRV-163: a color picked while off is the next On's, over Dim-To-Warm, until the light is off again")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.onMode(w, K.WARM, K.DIM)
  K.color(w, GREEN.x, GREEN.y)
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("ON")
  local on = colored(w)
  T.check("the On comes on in the pick", #on == 0 or near(((on[#on] or {}).color or {}).x, GREEN.x, 0.01), on)
  w.run(5000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("a level in that on cycle brings no mix", #colored(w), 0)
  w.run(5000)
  w.proxy:send("OFF")
  w.run(5000)
  w.m.sent = {}
  w.proxy:send("ON")
  T.eq("the next on cycle takes Dim-To-Warm again", #colored(w), 1)
  w.run(5000)
  w.restore()
end)

T.section("K05: a color set while off stays a pick when another client turns the light on")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.onMode(w, K.WARM, K.DIM)
  K.color(w, GREEN.x, GREEN.y)
  w.run(2000)
  w.m:other({ on = true, level = 1 })
  w.run(2000)
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(5000)
  T.eq("the level sends no color", #colored(w), 0)
  T.eq("and tells none", w.proxy:count("LIGHT_COLOR_CHANGED") + w.proxy:count("LIGHT_COLOR_CHANGING"), 0)
  w.restore()
end)

T.section("K06: a color set during a fade to off is a pick until that off")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(5000)
  K.target(w, 0, 4000)
  w.run(1000)
  K.color(w, GREEN.x, GREEN.y)
  w.run(500)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  local mixed = 0
  for _, c in ipairs(colored(w)) do
    if not near(c.color and c.color.x, GREEN.x, 0.01) then
      mixed = mixed + 1
    end
  end
  T.eq("the level before the off sends no Dim-To-Warm color", mixed, 0)
  w.run(5000)
  w.restore()
end)

T.finish()
