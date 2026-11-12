-- lib.light.motion: intents into commands across the fade kinds, the ramps and their estimates, stops, the
-- pre-on, the re-time, the walk, rests and settles, on a virtual clock. Light and Settings are fakes: the
-- light only carries the timers back, and the settings answer the getters Motion reads.

local T = require("testlib")
local F = require("c4_fixtures")

require("c4_shim")

local Color = require("lib.light.color")
local Motion = require("lib.light.motion")
local OnColor = require("lib.light.oncolor")
local Range = require("lib.light.range")

local clock = F.virtualClock()

local RED = { x = 0.64, y = 0.33, mode = "xy" }
local BLUE = { x = 0.15, y = 0.06, mode = "xy" }
local WARM_X, WARM_Y = C4:ColorCCTtoXY(2700)
local WARM = { x = WARM_X, y = WARM_Y, mode = "cct", kelvin = 2700 }

--- @param over table|nil Fields that replace the full-color device's; cct = false for none.
--- @return LightDevice
local function device(over)
  local d = {
    dims = true,
    color = true,
    cct = { minK = 2000, maxK = 6500 },
    colorWhileOff = "send",
    levelSteps = 255,
    fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 },
    feedback = { shows = "target", waitMs = 1000, refresh = false },
  }
  for k, v in pairs(over or {}) do
    d[k] = v
  end
  if d.cct == false then
    d.cct = nil
  end
  return d
end

local OWN = { kind = "own", maxMs = 65535, own = { onMs = 300, offMs = 400, changeMs = 200 } }
local WALK = { kind = "walk", maxMs = 60000, stepMs = 100 }
local PRE_ON = { kind = "device", curve = "linear", preOn = true, retimes = false, maxMs = 65535 }
local RETIMES = { kind = "device", curve = "linear", preOn = false, retimes = true, maxMs = 65535 }

--- Settings' values as Motion takes them: a Min/Max On range, the two default rates, and the on settings.
--- @return LightMotionSettings
local function settings(lo, hi, forOn)
  return {
    lo = lo or 1,
    hi = hi or 100,
    rate = 500,
    colorRate = 500,
    on = forOn or { defaultOn = true, onLo = lo or 1, onHi = hi or 100, presetLevel = 100, colorOnMode = "none" },
  }
end

-- What each Motion sent, kept until the test takes it, and the settings each one runs with.
--- @type table<LightMotion, LightCommand[]>
local sentBy = {}
--- @type table<LightMotion, LightMotionSettings>
local msOf = {}

--- @param m LightMotion
--- @param cmds LightCommand[]
local function keep(m, cmds)
  local list = sentBy[m]
  for _, cmd in ipairs(cmds) do
    list[#list + 1] = cmd
  end
end

--- An intent into Motion, its commands kept.
--- @param m LightMotion
--- @param intent LightIntent
--- @param choice LightOnChoice|nil
local function run(m, intent, choice)
  keep(m, m:command(intent, choice, msOf[m]))
end

--- The commands Motion sent since the last take.
--- @param m LightMotion
--- @return LightCommand[]
local function take(m)
  local list = sentBy[m]
  sentBy[m] = {}
  return list
end

--- A Motion over a fake Light, declared and seeded.
--- @return LightMotion
local function make(dev, seed, set)
  local light = {}
  local m = Motion.new(light)
  sentBy[m], msOf[m] = {}, set or settings()
  function light._rampEnded(_, aspect)
    keep(m, m:ended(aspect))
  end
  function light._walkStep()
    keep(m, m:step(msOf[m]))
  end
  m:declare(dev or device())
  m:seed(seed or { level = 0 })
  return m
end

local function level(c4, rate)
  return { kind = "level", level = c4, rateMs = rate, source = "proxy" }
end
local function color(c, rate)
  return { kind = "color", color = c, rateMs = rate, source = "proxy" }
end
local function on(rate)
  return { kind = "on", rateMs = rate, source = "proxy" }
end
local function off(rate)
  return { kind = "off", rateMs = rate, source = "proxy" }
end
local function choose(c4, c, unchosen)
  return { level = c4, color = c, unchosen = unchosen == true, followUp = false }
end

--- The flags of a command, for a compact comparison.
local function flags(cmd)
  return string.format(
    "%s on=%s L=%s C=%s off=%s",
    cmd.kind,
    tostring(cmd.on),
    cmd.setsLevel and 1 or 0,
    cmd.setsColor and 1 or 0,
    cmd.fromOff and 1 or 0
  )
end

local function near(a, b)
  return math.abs(a - b) < 1e-6
end

T.section("a level from off on a device fade")
do
  local m = make()
  run(m, level(50, 1000), choose(50))
  local cmds = take(m)
  T.eq("one change", #cmds, 1)
  T.eq("it lights the light and sets the level", flags(cmds[1]), "change on=true L=1 C=0 off=1")
  T.check("at the level's place on the line", near(cmds[1].level, Range.toDevice(50, 1, 100)), cmds[1].level)
  T.eq("over the time asked", cmds[1].transitionMs, 1000)
  T.eq("from dark", cmds[1].from.level, 0)
  T.eq("its color is carried, D65 before one is known", cmds[1].color.kelvin, Color.kelvin(0.3127, 0.3290))
  local view = m:view()
  T.check("the view heads for it", near(view.levelTarget, cmds[1].level) and view.levelMs == 1000, view)
  T.eq("now is the ramp's end", { m:now().on, m:now().levelRamping }, { true, true })
  clock.run(500)
  T.check("half way, the view is half way", near(m:view().level, cmds[1].level / 2), m:view().level)
  clock.run(500)
  T.eq("at its end the ramp is gone", m:now().levelRamping, false)
  T.check("and the view is at the level", near(m:view().level, cmds[1].level))
  T.eq("the landing of the level is now", m:landing("level"), clock.now())
  T.eq("nothing more went out", #take(m), 0)
end

T.section("a pre-on opens a rated on from off")
do
  local m = make(device({ fade = PRE_ON }))
  run(m, level(80, 2000), choose(80, RED))
  local cmds = take(m)
  T.eq("two commands", #cmds, 2)
  T.eq("the pre-on first: lit, at once, in a color", flags(cmds[1]), "preOn on=true L=1 C=1 off=1")
  T.eq("at the bottom step", cmds[1].level, 1 / 255)
  T.eq("0 ms", cmds[1].transitionMs, 0)
  T.eq("its change follows, not from off, and carries the on color", flags(cmds[2]), "change on=true L=1 C=1 off=0")
  T.check(
    "with no color known the pre-on puts the light in D65, and the change fades it to the on color",
    near(cmds[1].color.x, Color.forDevice(Color.D65, device()).x) and cmds[2].color.x == RED.x,
    { cmds[1].color, cmds[2].color }
  )
  T.eq("from the bottom step", cmds[2].from.level, 1 / 255)
  T.eq("over the rate", cmds[2].transitionMs, 2000)
  run(m, level(20, 0))
  T.eq("an at-once change while lit has no pre-on", flags(take(m)[1]), "change on=true L=1 C=0 off=0")
  run(m, off(0))
  take(m)
  run(m, level(40, 0), choose(40))
  local at = take(m)
  T.eq("an at-once on from off has no pre-on", { #at, at[1].kind }, { 1, "change" })
end

T.section("off keeps the level, and an off to a light already off still goes to the device")
do
  local m = make(nil, { level = 0.6 })
  run(m, off(0))
  local cmd = take(m)[1]
  T.eq("an off", flags(cmd), "change on=false L=1 C=0 off=0")
  T.eq("with the level kept", cmd.level, 0.6)
  T.eq("now: off, at the level kept", { m:now().on, m:now().level }, { false, 0.6 })
  T.eq("the view: dark", m:view().level, 0)
  run(m, off(0))
  local again = take(m)
  T.eq("off again goes out as an off", { #again, again[1] and flags(again[1]) }, { 1, "change on=false L=1 C=0 off=0" })
  run(m, on(), choose(100))
  local back = take(m)[1]
  T.eq("an on comes back lit", flags(back), "change on=true L=1 C=0 off=1")
  run(m, { kind = "toggle", source = "proxy" })
  T.eq("a toggle while lit is an off", take(m)[1].on, false)
  run(m, { kind = "toggle", source = "proxy" }, choose(30))
  local lit = take(m)[1]
  T.check("a toggle while dark is an on at the choice's level", lit.on and near(lit.level, Range.toDevice(30, 1, 100)))
end

T.section("a level the light is already at still goes to the device; one a ramp heads elsewhere from goes")
do
  local m = make(nil, { level = Range.toDevice(50, 1, 100) })
  run(m, level(50, 0))
  local same = take(m)
  T.eq("the same level goes out, setting the level", { #same, same[1] and same[1].setsLevel }, { 1, true })
  run(m, level(90, 2000))
  take(m)
  clock.run(500)
  run(m, level(50, 0))
  local cmd = take(m)[1]
  T.eq("back to the level it left, while the ramp runs: a change", { cmd and cmd.kind, cmd and cmd.setsLevel }, {
    "change",
    true,
  })
end

T.section("a light that does not dim, and Min/Max On")
do
  local m = make(device({ dims = false, color = false, cct = false }))
  run(m, level(30, 1000))
  local cmd = take(m)[1]
  T.eq("a level lights it at once, full", { cmd.on, cmd.level, cmd.transitionMs }, { true, 1, 0 })
  T.eq("no color on a device without one", cmd.color, nil)
  T.eq("no ramp", m:now().levelRamping, false)
  run(m, level(0, 1000))
  T.eq("level 0 turns it off", flags(take(m)[1]), "change on=false L=1 C=0 off=0")

  local narrow = make(nil, nil, settings(20, 80))
  run(narrow, level(1, 0), choose(1))
  T.check("level 1 is the Min On", near(take(narrow)[1].level, 0.2))
  run(narrow, level(100, 0))
  T.check("level 100 is the Max On", near(take(narrow)[1].level, 0.8))
end

T.section("a color while on, while off on a send device, and while off on a hold device")
do
  local m = make(nil, { level = 0.5, color = BLUE })
  run(m, color(RED, 1000))
  local cmd = take(m)[1]
  T.eq("while on: the color alone, power unchanged", flags(cmd), "change on=true L=0 C=1 off=0")
  T.eq("over the rate", cmd.transitionMs, 1000)
  T.eq("the level carried", cmd.level, 0.5)
  T.eq("the view heads for it", { m:view().colorMs, m:view().colorTarget.x }, { 1000, RED.x })
  run(m, color(RED, 300))
  local again = take(m)
  T.eq(
    "the color it already heads for still goes out, re-timed to the new rate",
    { #again, again[1] and again[1].transitionMs },
    { 1, 300 }
  )

  local dark = make(nil, { level = 0 })
  run(dark, color(RED, 1000))
  local sent = take(dark)[1]
  T.eq("off, on a send device: a color for a light that stays off", flags(sent), "change on=false L=0 C=1 off=0")
  T.eq("at once", sent.transitionMs, 0)
  T.eq("the proxy is told it", dark:view().color.x, RED.x)

  local hold = make(device({ colorWhileOff = "hold" }), { level = 0 })
  run(hold, color(RED, 1000))
  T.eq("off, on a hold device: nothing sent", #take(hold), 0)
  T.eq("but the proxy is told it", hold:view().color.x, RED.x)
  run(hold, on(), choose(100))
  local next = take(hold)[1]
  T.eq("the next on carries it", flags(next), "change on=true L=1 C=1 off=1")
  T.eq("in that color", next.color.x, RED.x)
end

T.section("colors in the device's form")
do
  local whites = make(device({ color = false }), { level = 0.5 })
  run(whites, color(RED, 0))
  local white = take(whites)
  T.eq(
    "a full color for a device with CCT alone goes as its nearest white",
    { #white, white[1] and white[1].color.mode },
    { 1, "cct" }
  )
  run(whites, color({ x = 0.3, y = 0.3, mode = "cct", kelvin = 9000 }, 0))
  local cmd = take(whites)[1]
  T.eq("a white past the range goes at its end", cmd.color.kelvin, 6500)
  T.eq("in CCT", cmd.color.mode, "cct")
  local full = make(device({ cct = false }), { level = 0.5 })
  run(full, color(WARM, 0))
  T.eq("a white for a device without CCT is a full color", take(full)[1].color.mode, "xy")
end

T.section("the re-time: on a device fade with retimes, a command for one aspect takes the other along")
do
  local m = make(device({ fade = RETIMES }), { level = 0.5, color = BLUE })
  run(m, color(RED, 2000))
  take(m)
  clock.run(500)
  run(m, level(90, 1000))
  local cmd = take(m)[1]
  T.eq(
    "the level command carries the color's target, not as a change",
    { cmd.color.x, cmd.setsColor },
    { RED.x, false }
  )
  T.eq("the color now lands with the level", m:landing("color"), clock.now() + 1000)
  clock.run(1000)
  T.eq("both done together", { m:now().levelRamping, m:now().colorRamping }, { false, false })

  local back = make(device({ fade = RETIMES }), { level = 0.5, color = BLUE })
  run(back, level(90, 3000))
  take(back)
  clock.run(1000)
  run(back, color(RED, 500))
  T.eq("a color re-times the level to land with it", back:landing("level"), clock.now() + 500)
  local later = take(back)[1]
  T.check("carrying the level's target", near(later.level, Range.toDevice(90, 1, 100)) and not later.setsLevel)

  local own = make(device({ fade = OWN }), { level = 0.5, color = BLUE })
  run(own, color(RED, 2000))
  take(own)
  local landing = own:landing("color")
  run(own, level(90, 1000))
  T.eq("an own fade takes no time from the command", take(own)[1].transitionMs, 0)
  T.eq("and re-times nothing", own:landing("color"), landing)
end

T.section("without retimes each aspect keeps its own ramp")
do
  local m = make(nil, { level = 0.5, color = BLUE })
  run(m, color(RED, 2000))
  take(m)
  local colorLands = m:landing("color")
  clock.run(500)
  run(m, level(90, 1000))
  local cmd = take(m)[1]
  T.eq(
    "the level command carries the color's target, not as a change",
    { cmd.color.x, cmd.setsColor },
    { RED.x, false }
  )
  T.eq("the color keeps its own landing", m:landing("color"), colorLands)
  clock.run(1000)
  T.eq("the level is done, the color still runs", { m:now().levelRamping, m:now().colorRamping }, { false, true })
  clock.run(500)
  T.eq("then it lands", m:now().colorRamping, false)

  local back = make(nil, { level = 0.5, color = BLUE })
  run(back, level(90, 3000))
  take(back)
  local levelLands = back:landing("level")
  clock.run(1000)
  run(back, color(RED, 500))
  T.eq("a color leaves the level ramp running", back:landing("level"), levelLands)
  take(back)
  clock.run(2000)

  local dark = make(nil, { level = 0.5, color = BLUE })
  run(dark, off(2000))
  take(dark)
  clock.run(500)
  run(dark, color(RED, 300))
  T.eq("a color while fading to off runs over what the fade has left, either way", take(dark)[1].transitionMs, 1500)
  clock.run(1500)
end

T.section("stops")
do
  local m = make(nil, { level = 0.2, color = BLUE })
  run(m, level(100, 1000))
  take(m)
  clock.run(250)
  run(m, { kind = "stopLevel", source = "proxy" })
  local cmd = take(m)[1]
  T.eq("a level stop holds where the ramp has the light", flags(cmd), "stop on=true L=1 C=0 off=0")
  T.check("at the estimate", near(cmd.level, 0.2 + 0.8 * 0.25), cmd.level)
  T.eq("at once", cmd.transitionMs, 0)
  T.eq("the ramp is gone", m:now().levelRamping, false)
  run(m, { kind = "stopLevel", source = "proxy" })
  T.eq("a stop with no ramp sends nothing", #take(m), 0)

  for _, case in ipairs({ { RETIMES, 500, "re-timed by the level to land with it" }, { device().fade, 0, "its own" } }) do
    local both = make(device({ fade = case[1] }), { level = 0.2, color = BLUE })
    run(both, color(RED, 2000))
    take(both)
    run(both, level(100, 1000))
    take(both)
    clock.run(500)
    run(both, { kind = "stopLevel", source = "proxy" })
    local held = take(both)[1]
    local label = case[1].retimes and "with retimes" or "without"
    T.eq(label .. ", a color of its own runs on: the stop carries its target", { held.color.x, held.setsColor }, {
      RED.x,
      false,
    })
    T.eq(label .. ": the stop asks " .. case[3], held.transitionMs, case[2])
    T.eq(label .. ": still running", both:now().colorRamping, true)
    both:finishAll()
  end

  local cl = make(device({ fade = RETIMES }), { level = 0.2, color = BLUE })
  run(cl, level(100, 2000))
  run(cl, color(RED, 2000))
  take(cl)
  clock.run(500)
  run(cl, { kind = "stopColor", source = "proxy" })
  T.eq("with retimes a color stop asks the level's time left", take(cl)[1].transitionMs, 1500)
  local nl = make(nil, { level = 0.2, color = BLUE })
  run(nl, level(100, 2000))
  run(nl, color(RED, 2000))
  take(nl)
  clock.run(500)
  run(nl, { kind = "stopColor", source = "proxy" })
  T.eq("without, it holds the color at once", take(nl)[1].transitionMs, 0)
  cl:finishAll()
  nl:finishAll()

  local c = make(nil, { level = 0.5, color = BLUE })
  run(c, color(RED, 1000))
  take(c)
  clock.run(500)
  run(c, { kind = "stopColor", source = "proxy" })
  local stop = take(c)[1]
  T.eq("a color stop: the color alone, power unchanged", flags(stop), "stop on=true L=0 C=1 off=0")
  T.check("at the estimate", near(stop.color.x, (BLUE.x + RED.x) / 2), stop.color)

  local up = make(nil, { level = 0 })
  run(up, level(50, 1000), choose(50))
  take(up)
  clock.run(1)
  run(up, { kind = "stopLevel", source = "proxy" })
  T.eq("a stop just after leaving dark stays lit, at the Min", flags(take(up)[1]), "stop on=true L=1 C=0 off=0")

  local own = make(device({ fade = OWN }), { level = 0.2 })
  run(own, level(100, 5000))
  take(own)
  clock.run(50)
  run(own, { kind = "stopLevel", source = "proxy" })
  T.eq("under an own fade a stop sends nothing", #take(own), 0)
  T.eq("the device's fade runs out", own:now().levelRamping, true)
  clock.run(200)
end

T.section("an own fade runs its own lengths")
do
  local m = make(device({ fade = OWN }), { level = 0 })
  run(m, level(60, 5000), choose(60))
  local cmd = take(m)[1]
  T.eq("no time asked of the device", cmd.transitionMs, 0)
  T.eq("off to on takes onMs", m:landing("level"), clock.now() + 300)
  clock.run(300)
  run(m, level(30, 5000))
  take(m)
  T.eq("on to another level takes changeMs", m:landing("level"), clock.now() + 200)
  clock.run(200)
  run(m, off(5000))
  take(m)
  T.eq("on to off takes offMs", m:landing("level"), clock.now() + 400)
  clock.run(400)
end

T.section("the walk: 0-time steps every stepMs")
do
  local m = make(device({ fade = WALK }), { level = 0 })
  run(m, level(100, 1000), choose(100))
  local steps = take(m)
  T.eq("from off the first step lights it at once, at the line's start", { #steps, steps[1].level }, { 1, 0.01 })
  for _ = 1, 12 do
    clock.run(100)
    for _, cmd in ipairs(take(m)) do
      steps[#steps + 1] = cmd
    end
  end
  T.check("at most duration / stepMs + 2 steps", #steps >= 9 and #steps <= 12, #steps)
  local zero, fromOff = true, 0
  for _, cmd in ipairs(steps) do
    zero = zero and cmd.transitionMs == 0
    fromOff = fromOff + (cmd.fromOff and 1 or 0)
  end
  T.check("each step takes no time", zero)
  T.eq("only the first lights it", { fromOff, steps[1].fromOff }, { 1, true })
  T.eq("the last is at the target", steps[#steps].level, 1)
  T.eq("the walk is done", { m:now().levelRamping, m.walking }, { false, false })

  run(m, off(500))
  local down = {}
  for _ = 1, 8 do
    clock.run(100)
    for _, cmd in ipairs(take(m)) do
      down[#down + 1] = cmd
    end
  end
  T.eq("a walk to off ends dark, setting the level", flags(down[#down]), "change on=false L=1 C=0 off=0")
  T.eq("keeping the level it left", down[#down].level, 1)

  run(m, on(), choose(100))
  take(m)
  run(m, level(1, 1000))
  clock.run(300)
  take(m)
  run(m, { kind = "stopLevel", source = "proxy" })
  local stop = take(m)
  T.eq("a stop sends one last 0-time step", { #stop, stop[1].kind, stop[1].transitionMs }, { 1, "stop", 0 })
  clock.run(500)
  T.eq("and nothing after", #take(m), 0)
end

T.section("Dim-To-Warm along a walk")
do
  local forOn = {
    defaultOn = true,
    onLo = 1,
    onHi = 100,
    presetLevel = 100,
    colorOnMode = "fade",
    onColor = { x = 0.33, y = 0.34, mode = "cct" },
    dimColor = { x = 0.52, y = 0.41, mode = "cct" },
  }
  local dev = device({ fade = WALK })
  local m = make(
    dev,
    { level = Range.toDevice(10, 1, 100), color = OnColor.dimToWarm(10, dev, forOn) },
    settings(1, 100, forOn)
  )
  run(m, level(90, 400), choose(90, OnColor.dimToWarm(90, dev, forOn), true))
  local ok = true
  for _ = 1, 5 do
    clock.run(100)
    for _, cmd in ipairs(take(m)) do
      local want = OnColor.dimToWarm(Range.toLevel(cmd.level, 1, 100), dev, forOn)
      ok = ok and math.abs(cmd.color.x - want.x) < 2e-3
    end
  end
  T.check("each step carries Dim-To-Warm's color for its level", ok)
end

T.section("a rest the adapter returns")
do
  local m = make(device({ color = false, cct = false }), { level = 0 })
  run(m, level(60, 0), choose(60))
  local cmd = take(m)[1]
  local rested = m:sent(cmd, { level = 0.35 })
  T.eq("the rested command carries it", rested.level, 0.35)
  T.eq("the sent one is not touched", cmd.level ~= 0.35, true)
  T.eq("now is there", m:now().level, 0.35)
  T.eq("no rest: the command as sent", m:sent(cmd, nil), cmd)
  local c = make(nil, { level = 0.5, color = BLUE })
  run(c, color(RED, 0))
  c:sent(take(c)[1], { color = WARM })
  T.eq("a color rest", c:now().color.x, WARM.x)
end

T.section("settle, finishAll, reset and seed")
do
  local m = make(nil, { level = 0.2, color = BLUE })
  run(m, level(100, 1000))
  take(m)
  m:settle({ level = 0.3 })
  T.eq("a settled level ends its ramp there", { m:now().levelRamping, m:now().level }, { false, 0.3 })
  m:settle({ on = false })
  T.eq("a settled off", m:now().on, false)
  run(m, on(), choose(100))
  take(m)
  m:settle({})
  T.eq("nothing to settle changes nothing", m:now().on, true)

  local f = make(nil, { level = 0.2, color = BLUE })
  run(f, level(100, 1000))
  run(f, color(RED, 1000))
  take(f)
  f:finishAll()
  T.eq("a changed fade ends both ramps at their targets", { f:now().levelRamping, f:now().colorRamping }, {
    false,
    false,
  })
  T.eq("at the targets", { f:view().level, f:view().color.x }, { 1, RED.x })
  clock.run(2000)
  T.eq("and sends nothing", #take(f), 0)

  local r = make(nil, { level = 0.2 })
  run(r, level(100, 1000))
  take(r)
  clock.run(500)
  r:reset()
  T.check("reset stops the ramp at the estimate", near(r:view().level, 0.6), r:view().level)
  clock.run(1000)
  T.eq("and its timers send nothing after", #take(r), 0)

  local s = make(nil, { level = 0.5, color = RED })
  T.eq("a seed is where the light is", { s:now().on, s:now().level, s:now().color.x }, { true, 0.5, RED.x })
  run(s, level(80, 0))
  T.eq("and the device is lit: no fromOff", take(s)[1].fromOff, false)
  local unknown = make(nil, {})
  T.eq("an unknown seed knows nothing", { unknown:now().on, unknown:now().level }, { false, nil })
end

T.section("a scene step's level with a color is one change that sets both")
do
  local m = make(nil, { level = 0.2, color = BLUE })
  run(m, { kind = "level", level = 80, color = RED, rateMs = 1000, source = "scene" })
  local cmd = take(m)
  T.eq("one command", #cmd, 1)
  T.eq("setting both", flags(cmd[1]), "change on=true L=1 C=1 off=0")
  T.eq("over the step's rate", cmd[1].transitionMs, 1000)
  T.eq("both ramps over it", { m:landing("level"), m:landing("color") }, { clock.now() + 1000, clock.now() + 1000 })
  clock.run(500)
  run(m, { kind = "stopLevel", source = "proxy" })
  local stop = take(m)[1]
  T.eq("its color is its own: a level stop lets it run on", { stop.setsColor, m:now().colorRamping }, { false, true })
  local dark = make(nil, { level = 0 })
  run(dark, { kind = "level", level = 0, color = RED, rateMs = 0, source = "scene" })
  T.eq("an off with a color sets both", flags(take(dark)[1]), "change on=false L=1 C=1 off=0")
end

T.section("the proxy's follow-up, and presets in the view")
do
  local m = make(nil, { level = 0.5, color = BLUE })
  run(m, color(RED, 0), { level = 50, color = BLUE, unchosen = false, followUp = true })
  T.eq("a follow-up moves nothing", #take(m), 0)
  run(m, { kind = "level", level = 70, rateMs = 0, presetId = 3, source = "proxy" })
  take(m)
  T.eq("a level preset shows in the view", m:view().levelPreset, 3)
  run(m, level(20, 0))
  T.eq("another level clears it", m:view().levelPreset, nil)
  run(m, { kind = "color", color = RED, rateMs = 0, presetId = 5, presetOrigin = 1, source = "proxy" })
  T.eq("a color preset with its origin", { m:view().colorPreset, m:view().colorPresetOrigin }, { 5, 1 })
  run(m, off(0))
  take(m)
  run(m, on(), { level = 100, color = BLUE, unchosen = false, followUp = false, presetId = 7, presetOrigin = 1 })
  take(m)
  T.eq("an on mode's preset rides the on", { m:view().colorPreset, m:view().colorPresetOrigin }, { 7, 1 })
end

T.section("every flag combination Motion emits")
do
  local cases = {
    { "on from off, no color news", device({ color = false, cct = false }), { level = 0 }, on(), choose(100) },
    { "on from off in a new on color", device(), { level = 0, color = BLUE }, on(), choose(100, RED) },
    {
      "on from off on a hold device",
      device({ colorWhileOff = "hold" }),
      { level = 0, color = BLUE },
      on(),
      choose(100),
    },
    { "a level while on", device(), { level = 0.2, color = BLUE }, level(80, 0) },
    {
      "a level while on with Dim-To-Warm's new mix",
      device(),
      { level = 0.2, color = BLUE },
      level(80, 0),
      choose(80, RED, true),
    },
    { "a color while on", device(), { level = 0.5, color = BLUE }, color(RED, 0) },
    { "an off", device(), { level = 0.5, color = BLUE }, off(0) },
    {
      "an off with a color",
      device(),
      { level = 0.5, color = BLUE },
      { kind = "level", level = 0, color = RED, source = "scene" },
    },
    { "a color for a light that stays off", device(), { level = 0, color = BLUE }, color(RED, 0) },
    {
      "a color for an off hold device",
      device({ colorWhileOff = "hold" }),
      { level = 0, color = BLUE },
      color(RED, 0),
    },
  }
  local want = {
    "change on=true L=1 C=0 off=1",
    "change on=true L=1 C=1 off=1",
    "change on=true L=1 C=1 off=1",
    "change on=true L=1 C=0 off=0",
    "change on=true L=1 C=1 off=0",
    "change on=true L=0 C=1 off=0",
    "change on=false L=1 C=0 off=0",
    "change on=false L=1 C=1 off=0",
    "change on=false L=0 C=1 off=0",
    "nothing",
  }
  for i, case in ipairs(cases) do
    local m = make(case[2], case[3])
    run(m, case[4], case[5])
    local cmds = take(m)
    T.eq(case[1], cmds[1] and flags(cmds[1]) or "nothing", want[i])
  end
end

T.section("a held color: a hold device's on carries it, and only it sets the color from off")
do
  local hold = make(device({ colorWhileOff = "hold" }), { level = 0, color = BLUE })
  T.eq("after a restart an off light's color counts as held", hold:now().colorHeld, true)
  run(hold, on(0), choose(100))
  local cmds = take(hold)
  T.eq("the on sets it", flags(cmds[1]), "change on=true L=1 C=1 off=1")
  T.eq("and the light is no longer holding", hold:now().colorHeld, false)
  run(hold, off(0))
  take(hold)
  T.eq("an off holds nothing", hold:now().colorHeld, false)
  run(hold, on(0), choose(100))
  T.eq(
    "an on with no held color and no on mode's comes on in the color it kept",
    flags(take(hold)[1]),
    "change on=true L=1 C=0 off=1"
  )
  run(hold, off(0))
  take(hold)
  run(hold, color(RED, 0))
  T.eq("a color for the off light is told, not sent", #take(hold), 0)
  T.eq("so it is held", hold:now().colorHeld, true)
  hold:settle({ on = true, level = 0.5 })
  T.eq("another hand lighting it ends the hold", hold:now().colorHeld, false)
  local send = make(device(), { level = 0, color = BLUE })
  T.eq("a send device never holds", send:now().colorHeld, false)
  run(send, on(0), choose(100))
  T.eq("so its on keeps the color it has", flags(take(send)[1]), "change on=true L=1 C=0 off=1")
end

T.section("an on from off sets an on mode's or a held color even when the light kept it")
do
  local plain = make(nil, { level = 0, color = RED })
  run(plain, on(0), choose(100, RED))
  T.eq("an on mode's color equal to the kept one is set", flags(take(plain)[1]), "change on=true L=1 C=1 off=1")
  local none = make(nil, { level = 0, color = RED })
  run(none, on(0), choose(100))
  T.eq("an on with no color of its own is not", flags(take(none)[1]), "change on=true L=1 C=0 off=1")
  local pre = make(device({ fade = PRE_ON }), { level = 0, color = RED })
  run(pre, level(60, 1500), choose(60, RED))
  local cmds = take(pre)
  T.eq("on a pre-on device, the pre-on and its change both set it", { flags(cmds[1]), flags(cmds[2]) }, {
    "preOn on=true L=1 C=1 off=1",
    "change on=true L=1 C=1 off=0",
  })
  local held = make(device({ colorWhileOff = "hold", fade = PRE_ON }), { level = 0, color = BLUE })
  run(held, level(60, 1500), choose(60))
  cmds = take(held)
  T.eq("a held color goes with both too", { flags(cmds[1]), flags(cmds[2]) }, {
    "preOn on=true L=1 C=1 off=1",
    "change on=true L=1 C=1 off=0",
  })
  T.eq("in the held color", cmds[2].color.x, BLUE.x)
  local lit = make(nil, { level = 0.5, color = RED })
  run(lit, level(80, 0), choose(80, RED))
  T.eq("a lit light's change to the same color sets no color", flags(take(lit)[1]), "change on=true L=1 C=0 off=0")
end

T.section("a stop lands on a whole C4 level")
do
  for _, case in ipairs({ { 1, 100 }, { 20, 80 } }) do
    local lo, hi = case[1], case[2]
    local m = make(nil, { level = 0.1 }, settings(lo, hi))
    run(m, level(100, 1000))
    take(m)
    clock.run(437)
    run(m, { kind = "stopLevel", source = "proxy" })
    local stop = take(m)[1]
    local c4 = Range.toLevel(stop.level, lo, hi)
    T.eq(
      string.format("on %d-%d the stop is the device value of a whole level", lo, hi),
      stop.level,
      Range.toDevice(c4, lo, hi)
    )
    T.eq("and the view rests there, the level LightProxy tells", m:view().level, stop.level)
  end
end

T.section("the view's power is Motion's, not the estimate's")
do
  local m = make()
  run(m, level(80, 1000), choose(80))
  take(m)
  T.eq("a rated on from off is on from its first moment", { m:view().on, m:view().level }, { true, 0 })
  local f = make(nil, { level = 0.8 })
  run(f, off(1000))
  take(f)
  clock.run(400)
  T.check("a fade to off is off while it still shows light", not f:view().on and f:view().level > 0, f:view())
  clock.run(600)
end

T.section("settle drops a preset only when the value it set is replaced")
do
  local m = make(nil, { level = 0.5, color = BLUE })
  run(m, { kind = "color", color = RED, rateMs = 0, presetId = 3, presetOrigin = 2, source = "proxy" })
  run(m, { kind = "level", level = 40, rateMs = 0, presetId = 7, source = "proxy" })
  take(m)
  m:settle({ color = RED, level = m:now().level })
  T.eq("an echo of the same values keeps both", { m:view().colorPreset, m:view().levelPreset }, { 3, 7 })
  m:settle({ color = BLUE })
  T.eq("another hand's color drops the color preset", { m:view().colorPreset, m:view().colorPresetOrigin }, {})
  T.eq("and keeps the level's", m:view().levelPreset, 7)
  m:settle({ level = 0.9 })
  T.eq("another hand's level drops the level preset", m:view().levelPreset, nil)
end

T.section("a seeded sweep: every command keeps the contract's rules")
do
  local seed = 20261112
  local function rand(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
  end
  local colors = { RED, BLUE, WARM, { x = 0.3, y = 0.3, mode = "cct", kelvin = 9000 } }
  local devices = {
    device(),
    device({ fade = PRE_ON }),
    device({ fade = OWN }),
    device({ fade = WALK }),
    device({ colorWhileOff = "hold" }),
    device({ dims = false, color = false, cct = false }),
    device({ color = false }),
    device({ fade = { kind = "device", curve = "smootherstep", preOn = true, retimes = true, maxMs = 3000 } }),
    device({ fade = RETIMES }),
    device({ fade = RETIMES, colorWhileOff = "hold" }),
  }
  local broken = {}
  local count = 0
  for d, dev in ipairs(devices) do
    local m = make(dev, { level = 0 })
    local wire = false
    local function check(cmd, what, heldBefore)
      count = count + 1
      local problems = {}
      if not (cmd.setsLevel or cmd.setsColor) then
        problems[#problems + 1] = "changes nothing"
      end
      if cmd.fromOff ~= (cmd.kind ~= "stop" and cmd.on and not wire) then
        problems[#problems + 1] = "fromOff wrong"
      end
      if cmd.fromOff and not cmd.setsLevel then
        problems[#problems + 1] = "fromOff without setsLevel"
      end
      if not cmd.setsLevel and cmd.on ~= wire then
        problems[#problems + 1] = "power changed without setsLevel"
      end
      if dev.colorWhileOff == "hold" and not cmd.on and not cmd.setsLevel then
        problems[#problems + 1] = "a color sent to an off hold device"
      end
      if heldBefore and cmd.fromOff and not cmd.setsColor then
        problems[#problems + 1] = "a hold device's on without its held color"
      end
      if dev.fade.kind ~= "device" and cmd.transitionMs ~= 0 then
        problems[#problems + 1] = "a timed command to an own or walk device"
      end
      if cmd.kind == "preOn" and (cmd.transitionMs ~= 0 or not dev.fade.preOn) then
        problems[#problems + 1] = "a timed or unasked pre-on"
      end
      if (cmd.color == nil) ~= not (dev.color or dev.cct) then
        problems[#problems + 1] = "color presence wrong"
      end
      if cmd.color and cmd.color.mode == "cct" and not (cmd.color.kelvin >= 2000 and cmd.color.kelvin <= 6500) then
        problems[#problems + 1] = "a Kelvin out of range"
      end
      if cmd.level < 0 or cmd.level > 1 then
        problems[#problems + 1] = "a level out of 0-1"
      end
      if #problems > 0 then
        broken[#broken + 1] =
          string.format("device %d after %s: %s (%s)", d, what, table.concat(problems, ", "), flags(cmd))
      end
      wire = cmd.on
    end
    for _ = 1, 300 do
      local r = rand(10)
      local intent, choice
      if r == 0 then
        intent, choice =
          on(rand(2) == 0 and 0 or 800), choose(1 + rand(100), rand(2) == 0 and colors[1 + rand(4)] or nil)
      elseif r == 1 then
        intent = off(rand(2) == 0 and 0 or 800)
      elseif r == 2 then
        intent, choice = { kind = "toggle", rateMs = rand(600), source = "proxy" }, choose(1 + rand(100))
      elseif r <= 4 then
        intent = level(rand(101), rand(1500))
      elseif r == 5 then
        intent = color(colors[1 + rand(4)], rand(1500))
      elseif r == 6 then
        intent = { kind = "stopLevel", source = "proxy" }
      elseif r == 7 then
        intent = { kind = "stopColor", source = "proxy" }
      elseif r == 8 then
        intent =
          { kind = "level", level = rand(101), color = colors[1 + rand(4)], rateMs = rand(900), source = "scene" }
      else
        local values = { on = rand(2) == 0, level = (1 + rand(255)) / 255 }
        m:settle(values)
        wire = values.on
      end
      if intent then
        local heldBefore = m:now().colorHeld
        run(m, intent, choice)
        for _, cmd in ipairs(take(m)) do
          check(cmd, intent.kind, heldBefore)
        end
      end
      clock.run(rand(400))
      for _, cmd in ipairs(take(m)) do
        check(cmd, "a step")
      end
    end
    m:finishAll()
  end
  T.check(string.format("%d commands, each within the rules", count), #broken == 0, broken[1])
end

T.section("a color goes out though the light has it; fading to off, the level re-times")
do
  local m = make(device(), { level = 0.5, color = RED })
  run(m, color(RED, 1000))
  local same = take(m)
  T.eq("a color the light shows still goes out", #same, 1)
  T.eq("but no ramp from it to itself: told as reached", m:view().colorMs, 0)
  local fading = make(device({ fade = RETIMES }), { level = 0.8, color = RED })
  run(fading, off(4000))
  take(fading)
  clock.run(1000)
  local at = fading:view().level
  run(fading, color(BLUE, 0))
  local cmd = take(fading)[1]
  T.eq("off, the color goes over what the fade has left", cmd.transitionMs, 3000)
  T.check(
    "and the level restarts from where it is, as a device that re-times restarts every channel",
    fading.levelRamp ~= nil and near(fading.levelRamp.from, at) and fading.levelRamp.startMs == C4:GetTime(),
    fading.levelRamp
  )
end

T.section("a ramp whose start is its target is told at once; a re-time at its target ends it")
do
  local m = make(device(), { level = 0.5, color = RED })
  run(m, color(BLUE, 2000))
  run(m, color(RED, 2000))
  T.eq("a color back to where the light still is: no ramp", m:view().colorMs, 0)
  local lv = make(device(), { level = 0.6 })
  run(lv, level(20, 2000))
  run(lv, level(60, 2000))
  T.eq("a level back to where the light still is: no ramp", lv:view().levelMs, 0)
  local rt = make(device({ fade = RETIMES }), { level = 0.5, color = RED })
  run(rt, level(30, 1000))
  clock.run(999)
  run(rt, color(BLUE, 2000))
  T.eq("a color re-times a level ramp already at its target by ending it", rt:view().levelMs, 0)
end

T.section("Dim-To-Warm follows the level it reaches")
do
  local forOn = {
    defaultOn = true,
    onLo = 1,
    onHi = 100,
    presetLevel = 100,
    colorOnMode = "fade",
    onColor = RED,
    dimColor = BLUE,
  }
  local dev = device()
  local function mix(c4)
    return OnColor.dimToWarm(c4, dev, forOn)
  end
  local m = make(dev, { level = 0.2, color = mix(20) }, settings(1, 100, forOn))
  run(m, level(80, 4000), choose(80, mix(80), true))
  take(m)
  clock.run(2000)
  local v = m:view()
  local want = mix(Range.toLevel(v.level, 1, 100))
  T.check("a carried color part way is the mix for the level reached", near(v.color.x, want.x), v.color)

  run(m, level(0, 4000), choose(0, mix(0), true))
  clock.run(2000)
  run(m, { kind = "stopLevel", source = "proxy" })
  local stop = take(m)
  local last = stop[#stop]
  T.check(
    "a level stop on a fade to off takes the mix for the stop level",
    last ~= nil and near(last.color.x, mix(Range.toLevel(last.level, 1, 100)).x),
    last
  )

  local carried = make(device({ fade = RETIMES }), { level = 0.2, color = mix(20) }, settings(1, 100, forOn))
  run(carried, level(100, 4000), choose(100, mix(100), true))
  clock.run(2000)
  run(carried, level(100, 4000), choose(100, mix(100), true))
  T.check(
    "a level whose mix is the carried ramp's target keeps it, re-timed to the new command",
    carried.colorRamp ~= nil and carried.colorRamp.startMs == C4:GetTime() and carried:view().colorMs == 4000,
    carried.colorRamp
  )

  local stopped = make(dev, { level = 0.2, color = mix(20) }, settings(1, 100, forOn))
  run(stopped, level(80, 4000), choose(80, mix(80), true))
  clock.run(1000)
  run(stopped, { kind = "stopColor", source = "proxy" })
  local colorStop = take(stopped)
  local held = (colorStop[#colorStop] or {}).color
  clock.run(1000)
  run(stopped, { kind = "stopLevel", source = "proxy" })
  local after = take(stopped)
  local ls = after[#after]
  T.check(
    "after a color stop, a level stop leaves the color where the color stop held it",
    ls ~= nil and not ls.setsColor and held ~= nil and near(ls.color.x, held.x),
    ls
  )
end

T.section("an off under Dim-To-Warm fades to the Dim color in its one command, and an on goes to the mix")
do
  local forOn = {
    defaultOn = true,
    onLo = 1,
    onHi = 100,
    presetLevel = 100,
    colorOnMode = "fade",
    onColor = RED,
    dimColor = BLUE,
  }
  local dev = device()
  local dim = OnColor.dimToWarm(0, dev, forOn)
  local m = make(dev, { level = 0.8, color = OnColor.dimToWarm(80, dev, forOn) }, settings(1, 100, forOn))
  run(m, off(2000), choose(0, dim, true))
  local cmds = take(m)
  T.eq("one command", #cmds, 1)
  T.eq("an off that sets the color", flags(cmds[1]), "change on=false L=1 C=1 off=0")
  T.check("the Dim color", near(cmds[1].color.x, BLUE.x) and near(cmds[1].color.y, BLUE.y), cmds[1].color)
  clock.run(1000)
  local v = m:view()
  local want = OnColor.dimToWarm(Range.toLevel(v.level, 1, 100), dev, forOn)
  T.check("part way, the light shows the mix for the level it has reached", near(v.color.x, want.x), v.color)
  clock.run(2000)
  run(m, on(1000), choose(100, OnColor.dimToWarm(100, dev, forOn), true))
  local lit = take(m)
  T.eq("an on is one command too", #lit, 1)
  T.check(
    "in the On color, with the brightness",
    lit[1].setsLevel and lit[1].setsColor and near(lit[1].color.x, RED.x),
    lit[1]
  )
end

T.section("a stop re-times the ramp that runs on, on a device that re-times")
do
  local m = make(device({ fade = RETIMES }), { level = 0.2, color = RED })
  run(m, level(80, 4000))
  run(m, color(BLUE, 4000))
  clock.run(1000)
  local estimate = m:view().color
  run(m, { kind = "stopLevel", source = "proxy" })
  T.check(
    "the color restarts from where it is, over its time left",
    m.colorRamp ~= nil and near(m.colorRamp.from.x, estimate.x) and m.colorRamp.startMs == C4:GetTime(),
    m.colorRamp
  )
end

T.section("a fade from off under half way to Min On reads as off; one to off is lit until it ends")
do
  local m = make(device({ fade = PRE_ON }), { level = 1 })
  run(m, off(4000))
  take(m)
  clock.run(3990)
  T.check("near the end of a fade to off the light is still lit", m:view().level > 0, m:view().level)
  run(m, on(1000), choose(100))
  T.eq("so the next on ramps from there, with no pre-on", take(m)[1].kind, "change")
  local up = make(device(), { level = 0 })
  run(up, level(60, 4000))
  clock.run(10)
  run(up, level(0, 2000))
  T.eq("a ramp up just begun, sent back to off: no ramp, told at once", up:view().levelMs, 0)
end

T.section("haltAll and the stop of both aspects")
do
  local m = make(device({ fade = RETIMES }), { level = 0.2, color = RED })
  run(m, level(80, 4000))
  run(m, color(BLUE, 4000))
  take(m)
  clock.run(1000)
  local v = m:view()
  m:haltAll()
  T.check(
    "haltAll ends every ramp where its estimate is, sending nothing",
    m.levelRamp == nil
      and m.colorRamp == nil
      and near(m.level, v.level)
      and near(m.color.x, v.color.x)
      and #take(m) == 0
  )
  local both = make(device(), { level = 0.2, color = RED })
  run(both, level(80, 4000))
  run(both, color(BLUE, 4000))
  take(both)
  clock.run(1000)
  run(both, { kind = "stop", source = "scene" })
  local stops = take(both)
  T.eq("a stop of both is one command", #stops, 1)
  T.eq("that names both aspects", flags(stops[1]), "stop on=true L=1 C=1 off=0")
  T.eq("on a whole C4 level", stops[1].level, Range.toDevice(Range.toLevel(stops[1].level, 1, 100), 1, 100))
  T.check("both ramps end", both.levelRamp == nil and both.colorRamp == nil)
  run(both, { kind = "stop", source = "scene" })
  T.eq("with neither ramping, nothing", #take(both), 0)
end

T.section("the fuzzer's seed 2263: a light that doesn't dim is sent level 1, whatever level it kept")
do
  local m = make(device({ dims = false }), { level = 0.9, color = RED })
  run(m, color(BLUE, 0))
  local cmd = take(m)[1]
  T.eq("a color while on carries level 1", cmd and cmd.level, 1)
end

T.section("the fuzzer's seed 267: a light that doesn't dim runs a color over its own lengths")
do
  local m = make(device({ dims = false, fade = OWN }), { level = 1, color = RED })
  run(m, { kind = "level", level = 100, color = BLUE, source = "scene" })
  T.check(
    "the color the level carries runs over the change length, with no level ramp",
    m.colorRamp ~= nil and m.colorRamp.ms == 200 and m.levelRamp == nil,
    m.colorRamp
  )
end

T.section("a power alone settles the power, and ends only a level ramp heading the other way")
do
  local m = make(nil, { level = 0.2 })
  run(m, level(80, 2000))
  take(m)
  m:settle({ on = true })
  T.check("an on during a ramp up keeps the ramp", m:now().levelRamping)
  m:settle({ on = false })
  T.check("an off ends it", not m:now().levelRamping)
end

T.section("an on from off fades the color from the one kept, its pre-on starting in it")
do
  local m = make(device({ fade = PRE_ON }), { level = 0, color = BLUE })
  run(m, on(1000), choose(100, RED))
  local cmds = take(m)
  T.eq(
    "a pre-on and its change",
    { #cmds, cmds[1] and cmds[1].kind, cmds[2] and cmds[2].kind },
    { 2, "preOn", "change" }
  )
  T.check(
    "the pre-on starts in the color kept, setting none",
    near(cmds[1].color.x, BLUE.x) and not cmds[1].setsColor,
    cmds[1]
  )
  T.check(
    "the change sets the on's color over the on's time",
    near(cmds[2].color.x, RED.x) and cmds[2].setsColor and cmds[2].transitionMs == 1000,
    cmds[2]
  )
  T.check("the view shows the color on its way", m:view().colorTarget ~= nil and m:view().colorMs > 0)
  local same = make(device({ fade = PRE_ON }), { level = 0, color = RED })
  run(same, on(1000), choose(100, RED))
  local both = take(same)
  T.eq(
    "an on color equal to the one kept: both set it, at once",
    { both[1].setsColor, both[2].setsColor },
    { true, true }
  )
end

T.section("a walk sends a color only once it has moved, lands it exactly, and re-sends no level")
do
  local m = make(device({ fade = WALK }), { level = 0.5, color = RED })
  local to = { x = RED.x - 0.02, y = RED.y, mode = "xy" }
  run(m, color(to, 1000))
  take(m)
  clock.run(1100)
  local steps = take(m)
  local last = steps[#steps]
  local levels = false
  for _, c in ipairs(steps) do
    levels = levels or c.setsLevel
  end
  T.check("fewer color steps than step times", #steps > 1 and #steps < 10, #steps)
  T.check("the last step lands the color exactly", last ~= nil and last.setsColor and near(last.color.x, to.x), last)
  T.check("and no step set the level", not levels)
end

T.section("on a hold device a color during a walk to off goes with no off step: it waits for the next on")
do
  -- With Min On at 20 the walk goes down to 20 % and sends its off at its end.
  local m = make(device({ fade = WALK, colorWhileOff = "hold" }), { level = 0.5, color = RED }, settings(20, 100))
  run(m, off(1000))
  take(m)
  clock.run(950)
  run(m, color(BLUE, 0))
  clock.run(200)
  local dark = false
  for _, c in ipairs(take(m)) do
    dark = dark or (c.setsColor and not c.on)
  end
  T.check("no off step carries the color", not dark)
  T.check("the color waits", m:now().colorHeld)
  run(m, on(0), choose(100))
  local back = take(m)[1]
  T.check("the next on carries it", back ~= nil and back.setsColor and near(back.color.x, BLUE.x), back)
end

T.section("a fade changed mid-walk ends the walk with one step to its ends")
do
  local m = make(device({ fade = WALK }), { level = 0.2 })
  run(m, level(80, 2000))
  clock.run(500)
  take(m)
  local last = m:finishAll()
  T.check(
    "one last 0 ms step to the target",
    #last == 1 and near(last[1].level, Range.toDevice(80, 1, 100)) and last[1].transitionMs == 0,
    last
  )
  T.check("and no ramp after it", not m:now().levelRamping)
end

T.section("during a walk now() is the step the device was sent")
do
  local m = make(device({ fade = WALK }), { level = 0.2 })
  run(m, level(80, 1000))
  clock.run(350)
  local steps = take(m)
  local last = steps[#steps]
  T.check(
    "now is the newest step's level",
    last ~= nil and near(m:now().level, last.level),
    { now = m:now().level, step = last and last.level }
  )
  T.check("and its ramp still runs", m:now().levelRamping)
end

T.section("a level set at once while the color walks goes at once, and a color stop then holds the color")
do
  local m = make(device({ fade = WALK }), { level = 0.2, color = RED })
  run(m, color(BLUE, 1000))
  take(m)
  clock.run(50)
  run(m, level(96, 0))
  local sent = take(m)
  local c = sent[1]
  T.check(
    "the level goes at once, alone, in the color the walk has sent",
    #sent == 1
      and c.setsLevel
      and not c.setsColor
      and near(c.level, Range.toDevice(96, 1, 100))
      and near(c.color.x, RED.x),
    sent
  )
  run(m, { kind = "stopColor", source = "proxy" })
  sent = take(m)
  c = sent[1]
  T.check(
    "the color stop holds the color where it stopped, at that level",
    #sent == 1 and c.kind == "stop" and c.setsColor and not c.setsLevel and near(c.level, Range.toDevice(96, 1, 100)),
    sent
  )
  clock.run(500)
  T.eq("and the walk is done", { #take(m), m.walking }, { 0, false })
end

T.section("a walk's off goes without a color of its own: a hold device keeps it for the next on")
do
  local m = make(device({ fade = WALK, colorWhileOff = "hold" }), { level = 0.5, color = RED })
  run(m, color(BLUE, 3000))
  run(m, off(500))
  local offStep
  for _ = 1, 8 do
    clock.run(100)
    for _, c in ipairs(take(m)) do
      if c.setsLevel and not c.on then
        offStep = c
      end
    end
  end
  T.check("the off sets the level alone", offStep ~= nil and not offStep.setsColor, offStep)
  T.check("and the color fade's point waits for the next on", m:now().colorHeld)
end

T.section("an instant color during a walk goes at once, as its own command, and no step repeats it")
do
  local m = make(device({ fade = WALK }), { level = 0.2, color = RED })
  run(m, level(80, 1000))
  clock.run(250)
  take(m)
  run(m, color(BLUE, 0))
  local c = take(m)[1]
  T.check(
    "at once, the color alone",
    c ~= nil and c.setsColor and not c.setsLevel and c.transitionMs == 0 and near(c.color.x, BLUE.x),
    c
  )
  clock.run(100)
  local step = take(m)[1]
  T.check("the next step moves the level alone", step ~= nil and step.setsLevel and not step.setsColor, step)
end

T.section("a walk's steps stay on the Min/Max On line until its off")
do
  local m = make(device({ fade = WALK }), { level = 0 }, settings(20, 80))
  run(m, level(100, 1000), choose(100))
  local first = take(m)[1]
  T.check(
    "up from off it starts at the line's start, 20 %",
    first ~= nil and first.on and near(first.level, 0.2),
    first
  )
  clock.run(1100)
  take(m)
  run(m, off(1000))
  local lit, offAt = {}, nil
  for i = 1, 12 do
    clock.run(100)
    for _, c in ipairs(take(m)) do
      if c.on then
        lit[#lit + 1] = c.level
      elseif c.setsLevel then
        offAt = i
      end
    end
  end
  local lowest = math.huge
  for _, l in ipairs(lit) do
    lowest = math.min(lowest, l)
  end
  T.check("down to off no step goes under the line's start", lowest >= 0.2 - 1e-9, lit)
  T.eq("and its off goes at its end", offAt, 10)

  local low = make(device({ fade = WALK }), { level = 0.05 }, settings(20, 80))
  run(low, off(4000))
  T.eq("a light under the Min walked to off: nothing at once", #take(low), 0)
  run(low, { kind = "stopLevel", source = "proxy" })
  T.eq("stopped before its first step: nothing goes out", #take(low), 0)
  T.check("and it holds where it is, lit", low:now().on and near(low:now().level, 0.05), low:now())

  local mid = make(device({ fade = WALK }), { level = 0.8 }, settings(20, 80))
  run(mid, off(4000))
  clock.run(3650)
  local steps = take(mid)
  local last = steps[#steps]
  run(mid, level(50, 2000))
  clock.run(100)
  local next = take(mid)[1]
  T.check(
    "a level mid-walk starts from the step last sent, not under it",
    last ~= nil and next ~= nil and next.from.level == last.level and next.level >= last.level,
    { last = last and last.level, next = next and next.level }
  )
end

T.section("a color stop near the end of a fade toward a white holds a white; one leaving a white is a color")
do
  local fourX, fourY = C4:ColorCCTtoXY(4000)
  local FOUR = { x = fourX, y = fourY, mode = "cct", kelvin = 4000 }
  --- The color a stop `ms` into a 4 s fade from `from` to `to` holds.
  local function stopped(from, to, ms)
    local m = make(nil, { level = 0.5, color = from })
    run(m, color(to, 4000))
    take(m)
    clock.run(ms)
    run(m, { kind = "stopColor", source = "proxy" })
    local c = take(m)[1]
    clock.run(4000 - ms)
    return c and c.color
  end
  local near4000 = stopped(RED, FOUR, 3900)
  T.check(
    "3.9 s into a fade from red to 4000 K, on the line of whites: a white, with its Kelvin",
    near4000 ~= nil and near4000.mode == "cct" and near4000.kelvin ~= nil,
    near4000
  )
  T.eq("half way: a color", (stopped(RED, FOUR, 2000) or {}).mode, "xy")
  T.eq("0.1 s into a fade from 4000 K to red: a color", (stopped(FOUR, RED, 100) or {}).mode, "xy")
end

T.section("a level that sends the color a ramp is on its way to takes that ramp over its own time")
do
  local m = make(nil, { level = 0.5, color = RED })
  run(m, { kind = "level", level = 20, color = BLUE, rateMs = 4000, source = "scene" })
  take(m)
  clock.run(1000)
  run(m, { kind = "level", level = 100, color = BLUE, rateMs = 2000, source = "scene", ramp = true })
  local c = take(m)[1]
  T.eq("the color goes with it, over its time", { c.setsColor, c.transitionMs }, { true, 2000 })
  T.eq("and the color ramp lands with it", m:landing("color"), clock.now() + 2000)
  clock.run(2000)
end

T.section("a color for a running color ramp's target sends nothing, unless it lands sooner")
do
  local m = make(nil, { level = 0.5, color = RED })
  run(m, color(BLUE, 4000))
  take(m)
  local lands = m:landing("color")
  clock.run(1000)
  run(m, color(BLUE, 4000))
  T.eq("no command: the ramp is on its way there already", #take(m), 0)
  T.eq("and it lands when it would have", m:landing("color"), lands)
  run(m, color(BLUE, 1000))
  local c = take(m)[1]
  T.eq("landing sooner, it goes over its own time", c and { c.setsColor, c.transitionMs }, { true, 1000 })
  T.eq("and the ramp lands then", m:landing("color"), clock.now() + 1000)
  clock.run(1000)
end

T.section("with no color known a color ramps from D65, alone and with a level")
do
  local d65 = Color.forDevice(Color.D65, device())
  local m = make(nil, { level = 0.5 })
  run(m, color(RED, 1000))
  local v = m:view()
  T.check(
    "a color alone ramps from D65 over its time",
    v.colorMs == 1000 and v.color ~= nil and near(v.color.x, d65.x),
    v
  )
  clock.run(1000)
  m = make(nil, { level = 0 })
  run(m, level(80, 2000), choose(80, RED))
  v = m:view()
  T.check(
    "an on in a color ramps it from D65 over the on's time",
    v.colorMs == 2000 and v.color ~= nil and near(v.color.x, d65.x),
    v
  )
  clock.run(2000)
end

T.section("a halted walk rests at the step it last sent")
do
  local m = make(device({ fade = WALK }), { level = 0.2, color = RED })
  run(m, level(80, 1000))
  run(m, color(BLUE, 1000))
  clock.run(350)
  local steps = take(m)
  local last = steps[#steps]
  clock.run(30)
  m:haltAll()
  local now = m:now()
  T.check(
    "the level and color of that step, not the estimate between steps",
    last ~= nil and near(now.level, last.level) and near(now.color.x, last.color.x),
    { now = now, last = last }
  )
  T.eq("and nothing runs", { now.levelRamping, now.colorRamping, m.walking }, { false, false, false })
end

T.section("late in a fade to off under a raised Min On the light is lit: no pre-on, and a Toggle turns it off")
do
  local m = make(device({ fade = PRE_ON }), { level = 1 }, settings(20, 100))
  run(m, off(10000))
  take(m)
  clock.run(9200)
  run(m, level(60, 2000), choose(60))
  local cmds = take(m)
  T.check(
    "9.2 s into 10 s, at 8 % under a Min of 20: one change, from where the light has got to",
    #cmds == 1 and cmds[1].kind == "change" and near(cmds[1].from.level, 0.08),
    cmds
  )
  clock.run(2000)
  run(m, off(10000))
  take(m)
  clock.run(9950)
  run(m, { kind = "toggle", source = "proxy" })
  local toggled = take(m)[1]
  T.check("under half a level, still fading: a Toggle turns it off", toggled ~= nil and not toggled.on, toggled)
  clock.run(100)
end

T.section("in one ms a walk sends a level once, and holds a step that falls in a command's ms")
do
  local m = make(device({ fade = WALK }), { level = 0.5, color = RED })
  run(m, level(60, 0))
  run(m, { kind = "level", level = 60, color = BLUE, rateMs = 500, source = "scene" })
  local sent = take(m)
  T.eq("a step to the level another command sent in the same ms walks its color alone", #sent, 1)
  clock.run(600)
  take(m)
  run(m, { kind = "level", level = 60, color = RED, rateMs = 500, source = "scene" })
  local again = take(m)
  T.check(
    "the same step later sends its level at once",
    #again == 1 and again[1].setsLevel and not again[1].setsColor,
    again
  )
  clock.run(600)
  take(m)

  run(m, color(BLUE, 1000))
  clock.run(250)
  take(m)
  run(m, level(80, 1000))
  T.eq("a step due in the ms a command set the ramps sends nothing", #m:step(msOf[m]), 0)
  T.check("and the walk steps on", m.walking)
  clock.run(100)
  local next = take(m)[1]
  T.check("the next step carries what moved", next ~= nil and next.setsLevel, next)
  clock.run(1000)
end

T.section("while another hand's on waits for its level, commands take the light as lit")
do
  local m = make(nil, { level = 0 })
  m:assumeLit(true)
  run(m, off(0))
  local o = take(m)[1]
  T.eq("an off goes out as an off", o and flags(o), "change on=false L=1 C=0 off=0")
  m:assumeLit(true)
  run(m, color(RED, 0))
  local c = take(m)[1]
  T.eq("a color goes as one for a lit light", c and flags(c), "change on=true L=0 C=1 off=0")
  T.eq("the view keeps the light as last settled", m:view().on, false)
end

T.section("a white part way between two whites is a white, with its Kelvin")
do
  local coolX, coolY = C4:ColorCCTtoXY(5000)
  local COOL = { x = coolX, y = coolY, mode = "cct", kelvin = 5000 }
  local m = make(nil, { level = 0.5, color = WARM })
  run(m, color(COOL, 2000))
  take(m)
  clock.run(1000)
  run(m, { kind = "stopColor", source = "proxy" })
  local s = take(m)[1]
  T.check(
    "the stop is a white with a Kelvin between the two",
    s ~= nil and s.color.mode == "cct" and s.color.kelvin ~= nil and s.color.kelvin > 2700 and s.color.kelvin < 5000,
    s and s.color
  )
end

T.section("a stop of a light on its way on lands lit; only a fade to off may stop at off")
do
  local m = make(nil, { level = 0 })
  run(m, on(4000), choose(40))
  take(m)
  clock.run(50)
  run(m, { kind = "stopLevel", source = "proxy" })
  local s = take(m)[1]
  T.check(
    "50 ms into a rated on from off the stop is an on at level 1 at least",
    s ~= nil and s.on and s.level >= Range.toDevice(1, 1, 100) - 1e-9,
    s
  )
  local f = make(nil, { level = 0.6 })
  run(f, off(4000))
  take(f)
  clock.run(3990)
  run(f, { kind = "stopLevel", source = "proxy" })
  local g = take(f)[1]
  T.check("near the end of a fade to off the stop is an off", g ~= nil and not g.on, g)
end

T.section("the contract's cases: Motion sends each case's commands, as adapters' wire tests take them")
do
  local Cases = require("light_contract_cases")
  --- Whether two values agree, numbers within 1e-9.
  local function alike(a, b)
    if type(a) == "number" and type(b) == "number" then
      return math.abs(a - b) <= 1e-9
    end
    if type(a) ~= "table" or type(b) ~= "table" then
      return a == b
    end
    for k, v in pairs(a) do
      if not alike(v, b[k]) then
        return false
      end
    end
    for k in pairs(b) do
      if a[k] == nil then
        return false
      end
    end
    return true
  end
  for _, case in ipairs(Cases.list) do
    --- @type LightContractSent[]
    local sent = {}
    local light = {}
    local m = Motion.new(light)
    local start = clock.now()
    local function keepAt(cmds)
      for _, cmd in ipairs(cmds) do
        sent[#sent + 1] = { at = clock.now() - start, command = m:sent(cmd, nil) }
      end
    end
    function light._rampEnded(_, aspect)
      keepAt(m:ended(aspect))
    end
    function light._walkStep()
      keepAt(m:step(case.settings))
    end
    m:declare(case.device)
    m:seed(case.seed)
    for _, step in ipairs(case.steps) do
      clock.run(step.at - (clock.now() - start))
      keepAt(m:command(step.intent, step.choice, case.settings))
    end
    clock.run(case.runMs)
    m:reset()
    T.check(case.name, alike(sent, case.commands), T.show(sent))
  end
end

clock.restore()
T.finish()
