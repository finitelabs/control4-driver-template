-- lib.light.oncolor, pure: the level an on goes to, the color it comes on in, the Dim-To-Warm color a level
-- carries, and the proxy's follow-up of an on.

local T = require("testlib")
local Color = require("lib.light.color")
local OnColor = require("lib.light.oncolor")

local COLOR_CCT = { dims = true, color = true, cct = { minK = 2000, maxK = 6500 } }
local CCT_ONLY = { dims = true, color = false, cct = { minK = 2700, maxK = 6500 } }
local DIMMER = { dims = true, color = false }

local RED = { x = 0.6, y = 0.32, mode = "xy" }
local BLUE = { x = 0.15, y = 0.06, mode = "xy" }
--- A white on the locus at a Kelvin.
local function white(kelvin)
  local x, y = Color.kelvinToXY(kelvin)
  return { x = x, y = y, mode = "cct", kelvin = kelvin }
end
local WARM = white(2700)
local COOL = white(5000)

--- Settings with every default, and the overrides given.
local function settings(over)
  local s = { defaultOn = true, onLo = 1, onHi = 100, presetLevel = 100, colorOnMode = "none" }
  for k, v in pairs(over or {}) do
    s[k] = v
  end
  return s
end

local function inputs(o)
  return {
    now = o.now or { on = false, level = 0.5, levelRamping = false, colorRamping = false },
    device = o.device or COLOR_CCT,
    settings = settings(o.settings),
    picks = o.picks or {},
  }
end

local OFF = { on = false, level = 0.5, levelRamping = false, colorRamping = false }
local ON = { on = true, level = 0.5, color = RED, levelRamping = false, colorRamping = false }

local function intent(kind, fields)
  local i = { kind = kind, source = "proxy" }
  for k, v in pairs(fields or {}) do
    i[k] = v
  end
  return i
end

local function near(a, b)
  return a ~= nil and b ~= nil and Color.alike(a, b)
end

T.section("which intents light the light, and which turn it off")
for _, c in ipairs({
  { "an on from off", intent("on"), OFF, true, false },
  { "a toggle from off", intent("toggle"), OFF, true, false },
  { "a level from off", intent("level", { level = 30 }), OFF, true, false },
  { "a level of 0 from off", intent("level", { level = 0 }), OFF, false, true },
  { "an on while on", intent("on"), ON, false, false },
  { "a toggle while on", intent("toggle"), ON, false, true },
  { "an off", intent("off"), ON, false, true },
  { "a color", intent("color", { color = RED }), OFF, false, false },
  { "a stop", intent("stopLevel"), ON, false, false },
}) do
  T.eq(c[1] .. ": lights, darkens", { OnColor.lights(c[2], c[3]), OnColor.darkens(c[2], c[3]) }, { c[4], c[5] })
end

T.section("the level an On goes to")
for _, c in ipairs({
  { "the on mode's level", { onModeLevel = 60, presetLevel = 80 }, OFF, 60 },
  { "with no on mode, the Default On level", { presetLevel = 80 }, OFF, 80 },
  { "without Default On, the level the device kept", { defaultOn = false, presetLevel = 80 }, OFF, 50 },
  {
    "without Default On and no level kept, the Default On level",
    { defaultOn = false, presetLevel = 80 },
    { on = false, level = 0 },
    80,
  },
  { "the on mode over a kept level", { defaultOn = false, onModeLevel = 25 }, OFF, 25 },
}) do
  local choice = OnColor.choose(intent("on"), inputs({ settings = c[2], now = c[3] }))
  T.eq(c[1], choice and choice.level, c[4])
end
T.eq("a toggle from off goes to the On level too", OnColor.choose(intent("toggle"), inputs({})).level, 100)
T.eq("a level from off goes to its own level", OnColor.choose(intent("level", { level = 30 }), inputs({})).level, 30)
T.eq(
  "an On while on goes to the On level, so a volume plays on rather than restarts",
  OnColor.choose(intent("on"), inputs({ now = ON, settings = { presetLevel = 70 } })).level,
  70
)

T.section("the color an on from off comes on in, by the color on mode")
do
  local dimToWarm = { colorOnMode = "fade", onColor = COOL, dimColor = WARM, onPresetId = 1, onPresetOrigin = 1 }
  local fadeAt30 = Color.forDevice(Color.dimToWarm(WARM, COOL, 30), COLOR_CCT)
  local cases = {
    {
      "a preset: the On preset's color, the mode's own choice, as its preset",
      { colorOnMode = "preset", onColor = RED, onPresetId = 4, onPresetOrigin = 2 },
      { RED, false, 4, 2 },
    },
    {
      "Previous: the color it went off in, no one's choice now",
      { colorOnMode = "previous", previousColor = BLUE, onPresetId = 10, onPresetOrigin = 1 },
      { BLUE, true, 10, 1 },
    },
    { "Dim-To-Warm: the mix at the level it comes on at, as no preset", dimToWarm, { fadeAt30, false } },
    { "no on mode: none", {}, { nil, false } },
  }
  for _, c in ipairs(cases) do
    local choice = OnColor.choose(intent("level", { level = 30 }), inputs({ settings = c[2] }))
    T.check(c[1] .. ": color", c[3][1] == nil and choice.color == nil or near(choice.color, c[3][1]), choice.color)
    T.eq(
      c[1] .. ": unchosen, preset",
      { choice.unchosen, choice.presetId, choice.presetOrigin },
      { c[3][2], c[3][3], c[3][4] }
    )
  end
end

T.section("the color is in the form the device takes it")
do
  local preset = { colorOnMode = "preset", onColor = RED }
  T.eq(
    "a light with no color and no CCT comes on in none",
    OnColor.choose(intent("on"), inputs({ device = DIMMER, settings = preset })).color,
    nil
  )
  T.eq(
    "a CCT light cannot take a full color, so none",
    OnColor.choose(intent("on"), inputs({ device = CCT_ONLY, settings = preset })).color,
    nil
  )
  local white = OnColor.choose(
    intent("on"),
    inputs({ device = CCT_ONLY, settings = { colorOnMode = "preset", onColor = { x = 0.5, y = 0.41, mode = "cct" } } })
  )
  T.check(
    "a white is clamped to the CCT range, with its Kelvin",
    white.color and white.color.mode == "cct" and white.color.kelvin >= 2700 and white.color.kelvin <= 6500,
    white.color
  )
end

T.section("a pick comes ahead of every on mode")
do
  local pick = { color = BLUE, presetId = 7, presetOrigin = 2 }
  local choice = OnColor.choose(
    intent("on"),
    inputs({
      settings = { colorOnMode = "preset", onColor = RED, onPresetId = 4, onPresetOrigin = 1 },
      picks = {
        picked = pick,
      },
    })
  )
  T.check("an on comes on in the pick", near(choice.color, BLUE), choice.color)
  T.eq("chosen, as the preset that set it", { choice.unchosen, choice.presetId, choice.presetOrigin }, { false, 7, 2 })
end

T.section("a level while on carries Dim-To-Warm's color, unless a color was picked")
do
  local dimToWarm = { colorOnMode = "fade", onColor = COOL, dimColor = WARM }
  local choice = OnColor.choose(intent("level", { level = 80 }), inputs({ now = ON, settings = dimToWarm }))
  T.check(
    "the mix at the new level",
    choice and near(choice.color, Color.forDevice(Color.dimToWarm(WARM, COOL, 80), COLOR_CCT)),
    choice
  )
  T.eq("which no one chose now", choice and choice.unchosen, true)
  T.eq(
    "with a pick it carries none, so there is nothing to choose",
    OnColor.choose(
      intent("level", { level = 80 }),
      inputs({ now = ON, settings = dimToWarm, picks = { picked = { color = RED } } })
    ),
    nil
  )
  T.eq(
    "without Dim-To-Warm a level while on needs no choice",
    OnColor.choose(
      intent("level", { level = 80 }),
      inputs({ now = ON, settings = { colorOnMode = "preset", onColor = RED } })
    ),
    nil
  )
  local on = OnColor.choose(intent("on"), inputs({ now = ON, settings = dimToWarm }))
  T.check(
    "an On while on carries the mix at the On level",
    on and near(on.color, Color.forDevice(Color.dimToWarm(WARM, COOL, 100), COLOR_CCT)),
    on
  )
end

T.section("an intent that lights nothing and follows nothing has no choice")
for _, c in ipairs({
  { "an off", intent("off"), ON },
  { "a toggle while on", intent("toggle"), ON },
  { "a level of 0", intent("level", { level = 0 }), ON },
  { "a stop", intent("stopLevel"), ON },
  { "a color stop", intent("stopColor"), ON },
  { "a color with no window open", intent("color", { color = RED }), ON },
}) do
  T.eq(
    c[1],
    OnColor.choose(c[2], inputs({ now = c[3], settings = { colorOnMode = "fade", onColor = COOL, dimColor = WARM } })),
    nil
  )
end

T.section("the proxy's follow-up of an on")
do
  local open = { followUp = { held = false } }
  local held = { followUp = { held = true } }
  local cases = {
    { "the color the light heads for, in the window", intent("color", { color = RED }), ON, open, true },
    { "another color, in the window", intent("color", { color = BLUE }), ON, open, false },
    { "the same color with no window", intent("color", { color = RED }), ON, {}, false },
    {
      "after a Navigator On that took the held color: a color naming a preset",
      intent("color", { color = BLUE, presetId = 1, presetOrigin = 1 }),
      ON,
      held,
      true,
    },
    {
      "after it, a color naming no preset is a pick",
      intent("color", { color = BLUE }),
      ON,
      held,
      false,
    },
    {
      "a preset id without its origin names no preset",
      intent("color", { color = BLUE, presetId = 1 }),
      ON,
      held,
      false,
    },
  }
  for _, c in ipairs(cases) do
    T.eq(c[1], OnColor.followUp(c[2], c[3], c[4]), c[5])
  end
  -- On a profile with on modes the held on's follow-up is the Color On Mode's own preset (zb:2020-2027).
  local onModes = { onModes = true, onPresetId = 7, onPresetOrigin = 1 }
  local withModes = {
    { "with on modes: the Color On Mode's own preset", { presetId = 7, presetOrigin = 1 }, true },
    { "with on modes: another preset is a pick", { presetId = 1, presetOrigin = 1 }, false },
    { "with on modes: the same id from another origin is a pick", { presetId = 7, presetOrigin = 2 }, false },
  }
  for _, c in ipairs(withModes) do
    local named = intent("color", { color = BLUE, presetId = c[2].presetId, presetOrigin = c[2].presetOrigin })
    T.eq(c[1], OnColor.followUp(named, ON, held, onModes), c[3])
  end
  T.eq(
    "without on modes: any named preset, Hatch's rule",
    OnColor.followUp(intent("color", { color = BLUE, presetId = 1, presetOrigin = 1 }), ON, held, { onModes = false }),
    true
  )
  local choice = OnColor.choose(intent("color", { color = RED }), inputs({ now = ON, picks = open }))
  T.eq("choose says follow-up, with the light's own color and level", {
    choice.followUp,
    near(choice.color, RED),
    choice.level,
  }, { true, true, 50 })
end

T.finish()
