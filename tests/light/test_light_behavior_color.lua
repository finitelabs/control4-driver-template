-- The light library's behavior over MemoryLight behind the fake proxy: color, the color held while
-- off, the on modes, Dim-To-Warm and the picks. The template's own test: no driver repo gets it.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local Color = require("lib.light.color")
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

T.section("on a hold device, a report that says off carries no color news")
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

T.section("a restart keeps the held color: the proxy's stands at the first report, and the next On carries it")
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

T.section("a color preset is told with its id and its origin")
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

T.section("Color On Mode preset: an On from off fades to it from the color kept, and the follow-up is not sent again")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.onMode(w, K.ON_PRESET)
  w.proxy:appOn(100, { x = K.ON_PRESET.x, y = K.ON_PRESET.y, preset = 1, origin = 1 })
  w.run(10)
  local first = colored(w)
  T.eq("the pre-on starts in the color kept, and the change sets the preset's color", #first, 1)
  T.check("that color, over the on's time", near(((first[1] or {}).color or {}).x, K.ON_PRESET.x), first[1])
  w.run(5000)
  T.eq("the follow-up sends no color again", #colored(w), 1)
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
  -- A color set in an on cycle is a pick until the next off, so the mix waits for it.
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

T.section("Dim-To-Warm with the On and Dim colors the same: a level fade tells no color event")
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

T.section("the walk under Dim-To-Warm: the color fades straight to the mix at the target, and lands there")
case(function()
  local w = K.world(K.WALK, {}, 100)
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(5000)
  w.m.sent = {}
  K.target(w, 20, 1000)
  w.run(3000)
  local steps = colored(w)
  local last = steps[#steps]
  local want = w.light.motion.color
  T.check(
    "the last step lands the color the walk was heading for, exactly",
    last ~= nil and want ~= nil and math.abs(last.color.x - want.x) <= 1e-9 and math.abs(last.color.y - want.y) <= 1e-9,
    { last = last and last.color, want = want }
  )
  w.restore()
end)

T.section("colorUnchosen: Previous On's color, and a level change's Dim-To-Warm color, but not an on's")
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

T.section("a color set while off stays a pick when another client turns the light on")
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

T.section("a color set during a fade to off is a pick until that off")
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

T.section("Dim-To-Warm: a color picked while on stays through every level command until the light goes off")
for _, base in ipairs({ K.ZB, K.ES }) do
  case(function()
    local w = K.world(base, {}, 0)
    K.onMode(w, K.WARM, K.DIM)
    w.proxy:send("ON")
    w.run(15000)
    K.color(w, GREEN.x, GREEN.y)
    w.run(15000)
    local steps = {
      {
        "Set Level",
        function()
          w.proxy:send("SET_LEVEL", { LEVEL = 50 })
        end,
      },
      {
        "a rated dim",
        function()
          K.target(w, 10, 4000)
        end,
      },
      {
        "Ramp To Level",
        function()
          w.proxy:send("RAMP_TO_LEVEL", { LEVEL = 30, TIME = 2000 })
        end,
      },
      {
        "a held Toggle",
        function()
          K.button(w, 2, 1)
          w.run(1000)
          K.button(w, 2, 0)
        end,
      },
      {
        "a scene step that sets a level alone",
        function()
          K.scene(w, 7, { { level = 40, rate = 1000 } })
          w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
        end,
      },
      {
        "On",
        function()
          w.proxy:send("ON")
        end,
      },
    }
    for _, s in ipairs(steps) do
      w.m.sent = {}
      w.proxy:mark()
      s[2]()
      w.run(15000)
      T.eq(s[1] .. ": no color sent", #colored(w), 0)
      T.eq(s[1] .. ": none told", w.proxy:count("LIGHT_COLOR_CHANGED") + w.proxy:count("LIGHT_COLOR_CHANGING"), 0)
    end
    w.restore()
  end)
end

T.section("Dim-To-Warm: with nothing picked, a scene step that sets a level alone takes the mix")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("ON")
  w.run(15000)
  w.m.sent = {}
  K.scene(w, 7, { { level = 40, rate = 1000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
  w.run(15000)
  T.eq("the step sends the mix", #colored(w), 1)
  w.restore()
end)

--- The color modes told by CHANGED since the mark.
--- @param w MemoryWorld
--- @return integer[]
local function toldModes(w)
  local out = {}
  for _, q in ipairs(w.proxy:told("LIGHT_COLOR_CHANGED")) do
    out[#out + 1] = q.LIGHT_COLOR_CURRENT_COLOR_MODE
  end
  return out
end

--- A light with color and CCT at 50 % under Dim-To-Warm, set by another hand to a full color at the mix's xy.
--- @return MemoryWorld
local function inColorAtMix()
  local w = K.world(K.ES, {}, 100)
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(5000)
  local mix = w.proxy.color
  w.m:other({ color = { x = mix.x, y = mix.y, mode = "xy" } })
  w.run(3000)
  w.proxy:mark()
  w.m.sent = {}
  return w
end

T.section("Dim-To-Warm: a full color at the mix's xy, heard while the mix is out, is the light's own")
case(function()
  -- The device pushes nothing of its own: the full color is the one report while the level's mix is out.
  local w = K.world(K.ES, {}, 100)
  w.m.o.silent = true
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  local mix = (colored(w)[1] or {}).color or {}
  w.run(20)
  w.m:deliver({ kind = "push", on = true, level = 0.5, color = { x = mix.x, y = mix.y, mode = "xy" } })
  w.run(5000)
  w.proxy:mark()
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("the level again sends the mix", #colored(w), 1)
  T.eq("and the proxy is told it once, as a white", toldModes(w), { K.CCT })
  w.restore()
end)

T.section("Dim-To-Warm: a report from before a level, of another hand's full color at the mix, landing after it")
case(function()
  local w = inColorAtMix()
  local before = w.device:values(w.clock.now(), true)
  before.kind = "push"
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.m:inject(w.clock.now() + 20, before)
  w.run(5000)
  T.eq("the level again sends the mix", #colored(w), 1)
  T.eq("the proxy is told it once, as a white: the report is from before", toldModes(w), { K.CCT })
  T.eq("and the light is in it", (K.device(w).color or {}).mode, "cct")
  w.restore()
end)
T.section("a full color's echo, landing after a white sent at the same xy, is that older command's, not the white's")
case(function()
  -- The device pushes nothing of its own: each report lands as the case delivers it.
  local w = K.world(K.ES, {}, 100)
  w.m.o.silent = true
  K.color(w, K.RED.x, K.RED.y)
  w.run(20)
  w.m:deliver({ kind = "push", on = true, level = 1, color = { x = K.RED.x, y = K.RED.y, mode = "xy" } })
  w.run(5000)
  K.color(w, K.WARM.x, K.WARM.y)
  w.run(10)
  w.proxy:mark()
  K.color(w, K.WARM.x, K.WARM.y, 0, K.CCT)
  local white = K.copy(w.m.sent[#w.m.sent].color)
  w.run(10)
  w.m:deliver({ kind = "push", on = true, level = 1, color = { x = K.WARM.x, y = K.WARM.y, mode = "xy" } })
  w.run(10)
  w.m:deliver({ kind = "push", on = true, level = 1, color = white })
  w.run(5000)
  T.eq("the proxy is told the white once, and not the full color the late echo repeats", toldModes(w), { K.CCT })
  w.restore()
end)
--- Replay commands at their ms offsets from the first, then run `tail` ms.
--- @param w MemoryWorld
--- @param steps {at: integer, cmd: string, params: table|nil}[]
--- @param tail integer
local function replay(w, steps, tail)
  local at = steps[1].at
  for _, step in ipairs(steps) do
    w.run(step.at - at)
    at = step.at
    w.proxy:send(step.cmd, step.params)
  end
  w.run(tail)
end

--- A SET_BRIGHTNESS_TARGET's params.
local function target(level, rate)
  return { LIGHT_BRIGHTNESS_TARGET = level, RATE = rate }
end

T.section("a light that shows a full color at a white as the Kelvin: an On preset at that white is told as the white")
case(function()
  -- An RGB and white bulb: it reports a white it was sent as a full color as the Kelvin, and re-times its fades.
  local o = K.copy(K.ES)
  o.fade.retimes = true
  local w = K.world(o, { kelvinWhites = true }, 50)
  local x, y = Color.kelvinToXY(3200)
  K.color(w, x, y, 0, K.CCT)
  w.run(3000)
  w.proxy:send("OFF")
  w.run(3000)
  K.onMode(w, { id = 5, origin = 1, x = x, y = y })
  w.proxy:mark()
  w.m.sent = {}
  -- The bulb's live pass: fades, then an ON, an OFF 1.5 s on, a SET_LEVEL 100 and an OFF a second on.
  replay(w, {
    { at = 3007, cmd = "SET_BRIGHTNESS_TARGET", params = target(100, 300) },
    { at = 4508, cmd = "SET_BRIGHTNESS_TARGET", params = target(0, 300) },
    { at = 8007, cmd = "SET_BRIGHTNESS_TARGET", params = target(60, 300) },
    { at = 10007, cmd = "SET_BRIGHTNESS_TARGET", params = target(20, 300) },
    { at = 12007, cmd = "SET_BRIGHTNESS_TARGET", params = target(60, 300) },
    { at = 14007, cmd = "SET_BRIGHTNESS_TARGET", params = target(0, 300) },
    { at = 17007, cmd = "SET_BRIGHTNESS_TARGET", params = target(100, 300) },
    { at = 18207, cmd = "SET_BRIGHTNESS_TARGET", params = target(0, 300) },
    { at = 21007, cmd = "ON" },
    { at = 22511, cmd = "OFF" },
    { at = 25007, cmd = "SET_LEVEL", params = { LEVEL = 100 } },
    { at = 26007, cmd = "OFF" },
  }, 3000)
  T.eq("each of its five ons tells the white once, as a white", toldModes(w), { K.CCT, K.CCT, K.CCT, K.CCT, K.CCT })
  local full = 0
  for _, c in ipairs(colored(w)) do
    full = full + (c.color.mode == "xy" and 1 or 0)
  end
  T.eq("and never sent as one", full, 0)
  T.eq("the light ends in the white", (K.device(w).color or {}).mode, "cct")
  w.restore()
end)

T.section("a light without color temperature that reports a white as a Kelvin is told the white as a full color")
case(function()
  -- A strip with RGB and white LEDs, no color temperature: it shows a white on its white LEDs and reports it as
  -- the Kelvin.
  local o = K.copy(K.ES)
  o.cct = nil
  o.fade = { kind = "device", curve = "linear", preOn = true, retimes = true }
  o.feedback = { shows = "target", waitMs = 1000, refresh = true }
  local w = K.world(o, { kelvinWhites = true }, 100)
  local x, y = Color.kelvinToXY(4000)
  local px, py = Color.kelvinToXY(3200)
  K.onMode(w, { id = 1, origin = 1, x = px, y = py })
  w.run(100)
  w.proxy:mark()
  -- The strip's live pass: a Kelvin and an off at once, then four fades on to the On preset's white and off.
  local steps = {
    {
      at = 2,
      cmd = "SET_COLOR_TARGET",
      params = {
        LIGHT_COLOR_TARGET_X = x,
        LIGHT_COLOR_TARGET_Y = y,
        LIGHT_COLOR_TARGET_MODE = K.CCT,
        LIGHT_COLOR_TARGET_COLOR_RATE = 0,
      },
    },
    { at = 13, cmd = "SET_BRIGHTNESS_TARGET", params = target(0, 0) },
  }
  for i, on in ipairs({ 3033, 7017, 11017, 15017 }) do
    steps[#steps + 1] = { at = on, cmd = "SET_BRIGHTNESS_TARGET", params = target(100, 300) }
    steps[#steps + 1] = { at = on + (i == 1 and 1484 or 1200), cmd = "SET_BRIGHTNESS_TARGET", params = target(0, 300) }
  end
  replay(w, steps, 3000)
  T.eq(
    "the Kelvin and each of the four ons tell the white once, as a full color",
    toldModes(w),
    { K.FULL, K.FULL, K.FULL, K.FULL, K.FULL }
  )
  w.restore()
end)

T.section("a Kelvin command, and a level on a lit white, are told once in the white's own form")
case(function()
  for _, o in ipairs({ K.ES, K.ZB, K.WALK }) do
    local w = K.world(o, { kelvinWhites = true }, 50)
    local x, y = Color.kelvinToXY(3200)
    K.color(w, x, y, 0, K.CCT)
    w.run(3000)
    T.eq("a Kelvin is told once, as a white", toldModes(w), { K.CCT })
    w.proxy:mark()
    for _, level in ipairs({ 30, 80 }) do
      w.proxy:send("SET_LEVEL", { LEVEL = level })
      w.run(3000)
    end
    T.eq("a level on it tells no color", toldModes(w), {})
    w.restore()
  end
end)
T.finish()
