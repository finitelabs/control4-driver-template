-- lib.light.picks: the next-on color, the on cycle's pick and the follow-up window, as intents and another
-- hand's changes move them, and what OnColor makes of them.

local T = require("testlib")
local F = require("c4_fixtures")
local Color = require("lib.light.color")
local OnColor = require("lib.light.oncolor")
local Picks = require("lib.light.picks")

local RED = { x = 0.6, y = 0.32, mode = "xy" }
local BLUE = { x = 0.15, y = 0.06, mode = "xy" }
local GREEN = { x = 0.3, y = 0.6, mode = "xy" }
local DEVICE = { dims = true, color = true, cct = { minK = 2000, maxK = 6500 } }

local OFF = { on = false, level = 0.5, levelRamping = false, colorRamping = false }
local FADING_OFF = { on = false, level = 0, levelRamping = true, colorRamping = false }

--- The light on, heading for a color.
local function lit(color)
  return { on = true, level = 0.5, color = color, levelRamping = false, colorRamping = false }
end

local function intent(kind, fields)
  local i = { kind = kind, source = "proxy" }
  for k, v in pairs(fields or {}) do
    i[k] = v
  end
  return i
end

local function color(c, fields)
  local i = intent("color", fields)
  i.color = c
  return i
end

--- Dim-To-Warm between two whites, so a level while on carries a color unless one was picked.
local function dimToWarm()
  local wx, wy = Color.kelvinToXY(2700)
  local cx, cy = Color.kelvinToXY(5000)
  return {
    defaultOn = true,
    onLo = 1,
    onHi = 100,
    presetLevel = 100,
    colorOnMode = "fade",
    dimColor = { x = wx, y = wy, mode = "cct" },
    onColor = { x = cx, y = cy, mode = "cct" },
  }
end

--- The choice for an intent with these picks, under Dim-To-Warm.
local function choose(picks, i, now)
  return OnColor.choose(i, { now = now, device = DEVICE, settings = dimToWarm(), picks = picks:forOn() })
end

local function same(pick, c)
  return pick ~= nil and Color.alike(pick.color, c)
end

local clock = F.virtualClock()

T.section("DRV-163: a color set while off is the next on's, and the cycle's pick until off")
do
  local p = Picks.new()
  p:noted(color(RED, { presetId = 5, presetOrigin = 2 }), OFF)
  T.check("a color while off waits for the next on", same(p.nextOn, RED) and p.picked == nil, p)
  local on = intent("on")
  p:noted(on, OFF)
  T.check("the on takes it: the next-on color becomes the pick", p.nextOn == nil and same(p.picked, RED), p)
  local choice = choose(p, on, OFF)
  T.check("and the on comes on in it, ahead of Dim-To-Warm", choice and Color.alike(choice.color, RED), choice)
  T.eq("as the preset that set it", { choice.presetId, choice.presetOrigin, choice.unchosen }, { 5, 2, false })
  T.eq("a level while lit keeps it: no Dim-To-Warm color", choose(p, intent("level", { level = 80 }), lit(RED)), nil)
  p:noted(intent("off"), lit(RED))
  T.check("the off leaves it until the light reaches off", same(p.picked, RED), p)
  local level = intent("level", { level = 80 })
  p:noted(level, OFF)
  T.eq("the light reached off: the pick ended", p.picked, nil)
  local after = choose(p, level, OFF)
  T.check("so the next cycle's level carries Dim-To-Warm again", after ~= nil and after.color ~= nil, after)
end

T.section("a color set while on is the cycle's pick")
do
  local p = Picks.new()
  clock.run(1000)
  p:noted(color(BLUE), lit(RED))
  T.check("picked", same(p.picked, BLUE) and p.nextOn == nil, p)
  p:noted(intent("toggle"), lit(BLUE))
  T.check("a toggle while on leaves it until the light reaches off", same(p.picked, BLUE), p)
  p:noted(intent("level", { level = 40 }), OFF)
  T.eq("and once off it has ended", p.picked, nil)
  p:noted(color(BLUE), lit(RED))
  p:noted(intent("level", { level = 0 }), lit(BLUE))
  T.check("a level of 0 leaves it too", same(p.picked, BLUE), p)
  p:noted(intent("on"), OFF)
  T.eq("until the light reaches off", p.picked, nil)
end

T.section("a color set while off stays a pick when another client turns the light on")
do
  local p = Picks.new()
  p:noted(color(RED), OFF)
  p:foreign({ "on", "level" })
  T.check("the held color is now the pick of a light another hand lit", same(p.picked, RED) and p.nextOn == nil, p)
  T.eq("so no Dim-To-Warm color at the next level", choose(p, intent("level", { level = 60 }), lit(BLUE)), nil)
  p:foreign({ "on" })
  T.eq("another hand's off then ends that pick", p.picked, nil)
end

T.section("another hand's color voids both picks")
do
  local p = Picks.new()
  p:noted(color(RED), OFF)
  p:foreign({ "color" })
  T.eq("the next-on color goes", p.nextOn, nil)
  p:noted(color(BLUE), lit(RED))
  p:foreign({ "on", "color" })
  T.eq("and with an on in the same report, the pick goes too", { p.picked, p.nextOn }, {})
  p:noted(color(BLUE), lit(RED))
  p:foreign({ "level" })
  T.check("another hand's level leaves the pick", same(p.picked, BLUE), p)
end

T.section("a color set during a fade to off is a pick until that off, and no next-on color")
do
  local p = Picks.new()
  p:noted(intent("off", { rateMs = 3000 }), lit(RED))
  p:noted(color(BLUE), FADING_OFF)
  T.check("it is this cycle's pick, not the next on's", same(p.picked, BLUE) and p.nextOn == nil, p)
  local level = choose(p, intent("level", { level = 60 }), FADING_OFF)
  T.check("a level before the off takes it, not a Dim-To-Warm mix", level and Color.alike(level.color, BLUE), level)
  local on = intent("on")
  p:noted(on, FADING_OFF)
  local choice = choose(p, on, FADING_OFF)
  T.check("an on that reverses the fade comes on in it", choice and Color.alike(choice.color, BLUE), choice)
  local q = Picks.new()
  q:noted(intent("off", { rateMs = 3000 }), lit(RED))
  q:noted(color(BLUE), FADING_OFF)
  q:noted(intent("on"), OFF)
  T.eq("once the light has reached off the pick is gone, so the next On is in the On color", q.picked, nil)
end

T.section("a stop in a fade to off leaves the light lit in its pick")
do
  local p = Picks.new()
  p:noted(intent("off", { rateMs = 3000 }), lit(RED))
  p:noted(color(BLUE), FADING_OFF)
  p:noted(intent("stopLevel"), FADING_OFF)
  T.check("the stop keeps it the pick", same(p.picked, BLUE) and p.nextOn == nil, p)
  local q = Picks.new()
  q:noted(color(BLUE), OFF)
  q:noted(intent("stopLevel"), OFF)
  T.check("a stop of a light already off holds it still", same(q.nextOn, BLUE) and q.picked == nil, q)
end

T.section("a pick lasts until the light reaches off: a hold down or a fade that stays lit keeps it")
do
  local p = Picks.new()
  p:noted(color(BLUE), lit(RED))
  p:noted(intent("level", { level = 0, rateMs = 2000, source = "button" }), lit(BLUE))
  T.check("a hold down keeps it", same(p.picked, BLUE), p)
  p:noted(intent("stopLevel", { source = "button" }), FADING_OFF)
  T.check("and its release, with the light still lit, keeps it", same(p.picked, BLUE), p)
  p:noted(intent("off", { rateMs = 3000 }), lit(BLUE))
  T.check("a fade to off keeps it while the light is lit", same(p.picked, BLUE), p)
  p:noted(intent("level", { level = 50 }), OFF)
  T.eq("the light reached off, as an off adopted at a deadline leaves it: the pick ended", p.picked, nil)
end

T.section("a scene's color-only step is a pick; a step that sets level and color together is not")
do
  local p = Picks.new()
  p:noted(intent("color", { color = BLUE, source = "scene" }), lit(RED))
  T.check("a color-only step is the pick", same(p.picked, BLUE), p)
  local q = Picks.new()
  q:noted(intent("level", { level = 60, color = BLUE, source = "scene" }), lit(RED))
  T.eq("a level-and-color step goes to the device and is no pick", q.picked, nil)
  local mixed = choose(q, intent("level", { level = 30 }), lit(BLUE))
  T.check("so a level after it carries the Dim-To-Warm color", mixed ~= nil and mixed.color ~= nil, mixed)
end

T.section("a Navigator On opens a 250 ms window for the proxy's follow-up, which is no pick")
do
  local tap = intent("level", { level = 100, presetId = 1 })
  local followUp = color(RED, { presetId = 1, presetOrigin = 1 })
  local p = Picks.new()
  p:noted(tap, OFF)
  clock.run(100)
  T.eq("the window is open", p:forOn().followUp, true)
  p:noted(followUp, lit(RED))
  T.eq("the Color On Mode's preset, sent after it, is no pick", p.picked, nil)
  clock.run(200)
  T.eq("past 250 ms the window is shut", p:forOn().followUp, false)
  p:noted(followUp, lit(RED))
  T.check("and the same color then is a pick", same(p.picked, RED), p)

  -- A bare color is a pick, in the window too, and so is every color after an on that names no preset.
  local q = Picks.new()
  q:noted(tap, OFF)
  q:noted(color(RED), lit(RED))
  T.check("in the window, the color the light heads for, bare, is a pick", same(q.picked, RED), q)
  local r = Picks.new()
  r:noted(intent("on"), OFF)
  T.eq("programming's On names no preset, and opens no window", r:forOn().followUp, false)
  r:noted(color(RED), lit(RED))
  T.check("so the color the on chose, sent back, is a pick", same(r.picked, RED), r)
  local mixed = choose(r, intent("level", { level = 30 }), lit(RED))
  T.check("and a level after it carries no Dim-To-Warm color", mixed == nil or mixed.color == nil, mixed)
  clock.run(300)
end

T.section("a Navigator On that takes the held color: its follow-up names a preset, and is no pick")
do
  local p = Picks.new()
  p:noted(color(RED), OFF)
  local tap = intent("level", { level = 100, presetId = 1 })
  p:noted(tap, OFF)
  T.eq("the window is open", p:forOn().followUp, true)
  local followUp = color(BLUE, { presetId = 1, presetOrigin = 1 })
  T.eq("the follow-up is the proxy's", choose(p, followUp, lit(RED)).followUp, true)
  p:noted(followUp, lit(RED))
  T.check("and the pick stays the held color", same(p.picked, RED), p)
  clock.run(300)

  -- The window takes one follow-up: a pick in it closes it, and so does the follow-up it took.
  local r = Picks.new()
  r:noted(color(RED), OFF)
  r:noted(tap, OFF)
  r:noted(color(GREEN), lit(RED))
  T.check("a color picked inside the window is a pick", same(r.picked, GREEN), r)
  T.eq("and it closes the window", r:forOn().followUp, false)
  local onPreset = color(BLUE, { presetId = 1, presetOrigin = 1 })
  T.check("so the on mode's preset after it is a choice", not (choose(r, onPreset, lit(GREEN)) or {}).followUp)
  r:noted(onPreset, lit(GREEN))
  T.check("and a pick", same(r.picked, BLUE), r)
  clock.run(300)

  local s = Picks.new()
  s:noted(color(RED), OFF)
  s:noted(tap, OFF)
  s:noted(color(BLUE, { presetId = 1, presetOrigin = 1 }), lit(RED))
  T.eq("the follow-up is taken while the window reads open", s:forOn().followUp, true)
  s:noted(color(BLUE, { presetId = 1, presetOrigin = 1 }), lit(RED))
  T.check("a second one within 250 ms is a pick", same(s.picked, BLUE), s)
  clock.run(300)
end

T.section("an On, a Toggle or a level with no preset that takes the held color: the On color's preset after it applies")
do
  local presetOn = { colorOnMode = "preset", onColor = BLUE, onModes = true, onPresetId = 1, onPresetOrigin = 1 }
  local onPreset = color(BLUE, { presetId = 1, presetOrigin = 1 })
  for _, c in ipairs({
    { "an On", intent("on") },
    { "a Toggle", intent("toggle") },
    { "a level", intent("level", { level = 100 }) },
  }) do
    local p = Picks.new()
    p:noted(color(RED), OFF)
    p:noted(c[2], OFF)
    T.eq(c[1] .. ": no window opens", p:forOn().followUp, false)
    T.check(c[1] .. ": the On color's preset is no follow-up", not OnColor.followUp(onPreset, p:forOn(), presetOn))
    p:noted(onPreset, lit(RED), presetOn)
    T.check(c[1] .. ": it is the pick", same(p.picked, BLUE), p)
    clock.run(300)
  end
end

T.section("a loss or Reset Driver ends every pick")
do
  local p = Picks.new()
  p:noted(color(RED), OFF)
  p:noted(intent("level", { level = 100, presetId = 1 }), OFF)
  p:noted(color(BLUE), OFF)
  p:reset()
  T.eq("nothing held", { p.nextOn, p.picked, p:forOn().followUp }, { nil, nil, false })
end

clock.restore()
T.finish()
