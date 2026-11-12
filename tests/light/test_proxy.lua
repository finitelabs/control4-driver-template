-- LightProxy: what the proxy and the links are told, as a diff of Motion's view against what was told,
-- and the proxy reads at start. Settings and Caps are stubbed here, so only LightProxy and the pure
-- color and range modules run.

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local persist = require("lib.persist")

-- Caps.dynamic as the test sets it, and a deep Caps.same.
local dynamicCaps = { dimmer = true, supports_color = false, brightness_rate_max = 65535 }
-- What the build wrote into driver.xml from the profile: the proxy holds these before any tell.
local staticCaps = { dimmer = "True", supports_color = "False", brightness_rate_max = "65535" }
local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
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
package.loaded["lib.light.caps"] = {
  dynamic = function()
    local copy = {}
    for k, v in pairs(dynamicCaps) do
      copy[k] = v
    end
    return copy
  end,
  static = function()
    local rows = {}
    for key, value in pairs(staticCaps) do
      rows[#rows + 1] = { key = key, value = value }
    end
    return rows
  end,
  same = same,
}

local LightProxy = require("lib.light.proxy")
local Range = require("lib.light.range")

local PROXY = 5001
local LINKS = { top = 300, toggle = 301, bottom = 302 }

local clock = F.virtualClock()

-- What went to the proxy and the links, in order.
local sent = {}
C4.SendToProxy = function(_, id, cmd, params)
  sent[#sent + 1] = { id = id, cmd = cmd, params = params }
end

-- The proxy's variables.
local vars = {}
C4.GetDeviceVariable = function(_, _, variable)
  return vars[variable]
end

--- A Settings stand-in with the getters LightProxy reads.
local function fakeSettings()
  local s = {
    lo = 1,
    hi = 100,
    preset = 100,
    colors = {},
    previousOn = 60,
    previousColor = nil,
    rates = { clickUp = 500, clickDown = 500, holdUp = 3000, holdDown = 3000 },
  }
  function s:onRange()
    return self.lo, self.hi
  end
  function s:presetLevel()
    return self.preset
  end
  function s:buttonColors(button)
    local c = self.colors[button]
    if c then
      return c.on, c.off
    end
    return "0000ff", "000000"
  end
  function s:clickRate(up)
    return up and self.rates.clickUp or self.rates.clickDown
  end
  function s:holdRate(up)
    return up and self.rates.holdUp or self.rates.holdDown
  end
  function s:previousOnLevel()
    return self.previousOn
  end
  function s:setPreviousColor(color)
    self.previousColor = color
  end
  return s
end

local DEVICE = { dims = true, color = true, cct = { minK = 2000, maxK = 6500 } }

--- A LightProxy and its settings, with nothing told yet.
local function make(links)
  local settings = fakeSettings()
  local profile = { api = 1, proxy = PROXY, links = links }
  return LightProxy.new(profile, settings), settings
end

--- A view at rest.
local function rest(on, level, color)
  return { on = on, level = level, levelMs = 0, color = color, colorMs = 0 }
end

--- The commands sent since the last call, as a list of names.
local function names()
  local out = {}
  for _, s in ipairs(sent) do
    out[#out + 1] = s.cmd
  end
  sent = {}
  return out
end

--- The sends since the last call, and clear them.
local function take()
  local out = sent
  sent = {}
  return out
end

local RED = { x = 0.64, y = 0.33, mode = "xy" }
local BLUE = { x = 0.15, y = 0.06, mode = "xy" }

T.section("read: what the proxy shows is seeded, and kept only when its target agrees")
do
  vars = { [1001] = "40", [1110] = "40", [1200] = "0.64,0.33,0", [1210] = "0.64,0.33,0" }
  local p = make()
  local seed = p:read()
  T.eq("a level at its target is the seed", seed.level, Range.toDevice(40, 1, 100))
  T.eq("a color at its target is the seed", { seed.color.x, seed.color.y, seed.color.mode }, { 0.64, 0.33, "xy" })
  sent = {}
  p:sync(rest(true, seed.level, seed.color))
  T.eq("so the first sync of the same light tells nothing", names(), {})

  vars = { [1001] = "40", [1110] = "80", [1200] = "0.64,0.33,0", [1210] = "0.3,0.3,0" }
  p = make()
  seed = p:read()
  T.eq("a ramp of an earlier load leaves the level unknown", seed.level, nil)
  T.eq("and the color", seed.color, nil)
  p:sync(rest(true, Range.toDevice(40, 1, 100), RED))
  T.eq(
    "so the first sync tells the light's values, which ends the proxy's ramp (ESPHome L-READ)",
    names(),
    { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }
  )

  vars = { [1001] = "100" }
  seed = make():read()
  T.eq("an On/Off light's proxy has no target: its level stands", seed.level, 1)

  vars = { [1001] = "0", [1110] = "0", [1200] = "0.3,0.32,1", [1210] = "0.3,0.32,1" }
  seed = make():read()
  T.eq("off is level 0", seed.level, 0)
  T.eq("a white is a cct color", seed.color.mode, "cct")
  T.check("with its kelvin", seed.color.kelvin ~= nil, seed.color)
  vars = {}
end

T.section("the connection: offline and online, and what a loss tells")
do
  local p = make(LINKS)
  p:offline()
  T.eq("start tells offline", names(), { "ONLINE_CHANGED" })
  p:offline()
  T.eq("once per outage", names(), {})
  p:online(DEVICE)
  local got = take()
  local cmds = {}
  for _, s in ipairs(got) do
    cmds[#cmds + 1] = s.cmd
  end
  T.eq("online: ONLINE_CHANGED, the capabilities, the buttons and the link colors, and no echo", cmds, {
    "ONLINE_CHANGED",
    "DYNAMIC_CAPABILITIES_CHANGED",
    "NUMBER_BUTTONS",
    "BUTTON_INFO",
    "BUTTON_INFO",
    "BUTTON_INFO",
    "BUTTON_COLORS",
    "BUTTON_COLORS",
    "BUTTON_COLORS",
  })
  T.eq("ONLINE_CHANGED true", got[1].params.STATE, true)
  T.eq("the links each hear their colors", { got[7].id, got[8].id, got[9].id }, { 300, 302, 301 })

  p:sync(rest(true, 0.5))
  take()
  p:lost(true)
  T.eq("a suspend tells offline and keeps the level", names(), { "ONLINE_CHANGED" })
  p:lost(false)
  got = take()
  T.eq("a loss after it reads off once", got[1].cmd, "LIGHT_BRIGHTNESS_CHANGED")
  T.eq("at 0", got[1].params.LIGHT_BRIGHTNESS_CURRENT, 0)
  T.eq("its LEDs with it", { got[2].cmd, got[2].params.STATE }, { "MATCH_LED_STATE", false })
  p:lost(false)
  T.eq("once per outage", names(), {})

  p = make()
  p:offline()
  take()
  p:lost(false)
  T.eq("a loss with no report since start reads off too", names(), { "LIGHT_BRIGHTNESS_CHANGED" })
end

T.section("capabilities: told only when the proxy does not hold them")
do
  persist:delete("light_rate_caps")
  local p = make()
  vars = {
    [6661] = "<DynamicCapabilities><dimmer>True</dimmer><supports_color>False</supports_color></DynamicCapabilities>",
  }
  T.eq(
    "none stored, and the table matches 6661 and driver.xml's static values: nothing told",
    p:capabilities(DEVICE),
    false
  )
  T.eq("and nothing stored", persist:get("light_rate_caps"), nil)
  dynamicCaps.brightness_rate_max = 60000
  p = make()
  T.eq("a rate the static value does not give is told, once after the upgrade", p:capabilities(DEVICE), true)
  T.eq("the rate keys 6661 does not show are kept", persist:get("light_rate_caps"), { brightness_rate_max = 60000 })
  T.eq("the same again in this load tells nothing", p:capabilities(DEVICE), false)
  take()

  p = make()
  T.eq("a new load whose proxy holds them all tells nothing", p:capabilities(DEVICE), false)
  T.eq("not even once", names(), {})
  dynamicCaps.brightness_rate_max = 65535

  vars[6661] = "<DynamicCapabilities><dimmer>False</dimmer></DynamicCapabilities>"
  p = make()
  T.eq("a reflected key the proxy shows otherwise is told", p:capabilities(DEVICE), true)
  take()

  vars[6661] = "<DynamicCapabilities><dimmer>True</dimmer><supports_color>False</supports_color></DynamicCapabilities>"
  persist:set("light_rate_caps", { brightness_rate_max = 60000 })
  p = make()
  T.eq("a rate key told otherwise is told", p:capabilities(DEVICE), true)
  dynamicCaps.supports_color = true
  T.eq("a change in this load is told", p:capabilities(DEVICE), true)
  dynamicCaps.supports_color = false
  take()
  vars = {}
end

T.section("the level: CHANGED at rest, CHANGING for a ramp, on the Min/Max On line")
do
  local p, settings = make(LINKS)
  p:sync(rest(true, Range.toDevice(50, 1, 100)))
  local got = take()
  T.eq(
    "a new level is CHANGED",
    { got[1].cmd, got[1].params.LIGHT_BRIGHTNESS_CURRENT },
    { "LIGHT_BRIGHTNESS_CHANGED", 50 }
  )
  T.eq(
    "and every link's LED shows the light's own state, the Off link's too",
    { got[2].id, got[2].params.STATE, got[3].id, got[3].params.STATE, got[4].id, got[4].params.STATE },
    { 300, true, 302, true, 301, true }
  )
  p:sync(rest(true, Range.toDevice(50, 1, 100)))
  T.eq("the same level tells nothing", names(), {})

  local view = {
    on = true,
    level = Range.toDevice(50, 1, 100),
    levelTarget = Range.toDevice(80, 1, 100),
    levelMs = 2000,
    colorMs = 0,
  }
  p:sync(view)
  got = take()
  T.eq("a ramp is CHANGING from where it is, to its target, at its time", {
    got[1].cmd,
    got[1].params.LIGHT_BRIGHTNESS_CURRENT,
    got[1].params.LIGHT_BRIGHTNESS_TARGET,
    got[1].params.RATE,
  }, { "LIGHT_BRIGHTNESS_CHANGING", 50, 80, 2000 })
  clock.run(500)
  view.level, view.levelMs = Range.toDevice(65, 1, 100), 1500
  p:sync(view)
  T.eq("the same ramp later tells nothing", names(), {})
  view.levelMs = 3000
  p:sync(view)
  T.eq("a re-timed one is told again", names(), { "LIGHT_BRIGHTNESS_CHANGING" })
  p:sync(rest(true, Range.toDevice(80, 1, 100)))
  T.eq("its end is CHANGED", names(), { "LIGHT_BRIGHTNESS_CHANGED" })

  view = {
    on = true,
    level = Range.toDevice(80, 1, 100),
    levelTarget = Range.toDevice(30, 1, 100),
    levelMs = 1000,
    colorMs = 0,
  }
  p:sync(view)
  take()
  p:sync(rest(true, Range.toDevice(80, 1, 100)))
  T.eq("a ramp stopped where it began still ends in CHANGED", names(), { "LIGHT_BRIGHTNESS_CHANGED" })

  settings.lo, settings.hi = 20, 60
  p:sync(rest(true, 0.6))
  got = take()
  T.eq("Max On is level 100", got[1].params.LIGHT_BRIGHTNESS_CURRENT, 100)
  p:sync(rest(true, 0.2))
  got = take()
  T.eq("Min On is level 1", got[1].params.LIGHT_BRIGHTNESS_CURRENT, 1)
  settings.lo, settings.hi = 1, 100
  take()

  p:sync({ on = true, level = 0.5, levelMs = 0, colorMs = 0, levelPreset = 3 })
  got = take()
  T.eq("a level's preset rides its CHANGED", got[1].params.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID, 3)
  p:sync({ on = true, level = 0.5, levelMs = 0, colorMs = 0, levelPreset = 4 })
  T.eq("another preset at the same level is told", names(), { "LIGHT_BRIGHTNESS_CHANGED" })
end

T.section("the level: a light lit from off, and the Previous On keep at its off")
do
  local p, settings = make()
  p:sync(rest(false, 0))
  take()
  p:sync({ on = true, level = 0, levelTarget = 0.7, levelMs = 1000, colorMs = 0 })
  local got = take()
  T.eq("a ramp up from off is told lit from the start", got[1].params.LIGHT_BRIGHTNESS_CURRENT, 1)
  p:sync(rest(false, 0.35))
  got = take()
  T.eq("off before its end: the proxy is first told the level to keep", {
    got[1].cmd,
    got[1].params.LIGHT_BRIGHTNESS_CURRENT,
    got[1].params.LIGHT_BRIGHTNESS_TARGET,
    got[1].params.RATE,
  }, { "LIGHT_BRIGHTNESS_CHANGING", settings.previousOn, 0, 0 })
  T.eq("then CHANGED 0", { got[2].cmd, got[2].params.LIGHT_BRIGHTNESS_CURRENT }, { "LIGHT_BRIGHTNESS_CHANGED", 0 })

  p:sync({ on = true, level = 0, levelTarget = 0.7, levelMs = 1000, colorMs = 0 })
  p:sync(rest(true, 0.7))
  take()
  p:sync(rest(false, 0.7))
  got = take()
  T.eq("a ramp that ended keeps nothing extra", got[1].cmd, "LIGHT_BRIGHTNESS_CHANGED")
end

T.section("the color: CHANGED and CHANGING, ahead of the level, with preset id and origin")
do
  local p, settings = make()
  p:sync(rest(true, 0.5, RED))
  local got = take()
  T.eq("a new color is told ahead of the level", { got[1].cmd, got[2].cmd }, {
    "LIGHT_COLOR_CHANGED",
    "LIGHT_BRIGHTNESS_CHANGED",
  })
  T.eq(
    "in xy, mode 0",
    { got[1].params.LIGHT_COLOR_CURRENT_X, got[1].params.LIGHT_COLOR_CURRENT_COLOR_MODE },
    { 0.64, 0 }
  )
  p:sync(rest(true, 0.5, { x = 0.641, y = 0.331, mode = "xy" }))
  T.eq("a color within the tolerance tells nothing", names(), {})

  local view = {
    on = true,
    level = 0.5,
    levelMs = 0,
    color = RED,
    colorTarget = BLUE,
    colorMs = 1500,
    colorPreset = 7,
    colorPresetOrigin = 2,
  }
  p:sync(view)
  got = take()
  local c = got[1].params
  T.eq(
    "a color ramp is CHANGING from the color told",
    { got[1].cmd, c.LIGHT_COLOR_CURRENT_X, c.LIGHT_COLOR_TARGET_X },
    {
      "LIGHT_COLOR_CHANGING",
      0.64,
      0.15,
    }
  )
  T.eq("with both rate keys", { c.LIGHT_COLOR_TARGET_COLOR_RATE, c.LIGHT_COLOR_TARGET_RATE }, { 1500, 1500 })
  T.eq(
    "and its preset with its origin",
    { c.LIGHT_COLOR_TARGET_PRESET_ID, c.LIGHT_COLOR_TARGET_PRESET_ORIGIN },
    { 7, 2 }
  )
  p:sync(rest(true, 0.5, BLUE))
  got = take()
  T.eq("its end is CHANGED", got[1].cmd, "LIGHT_COLOR_CHANGED")

  view = { on = true, level = 0.5, levelMs = 0, color = BLUE, colorTarget = RED, colorMs = 2000 }
  p:sync(view)
  take()
  p:sync({ on = false, level = 0.5, levelMs = 0, color = BLUE, colorTarget = RED, colorMs = 1800 })
  got = take()
  T.eq("off during a color ramp: its target is CHANGED first", { got[1].cmd, got[1].params.LIGHT_COLOR_CURRENT_X }, {
    "LIGHT_COLOR_CHANGED",
    0.64,
  })
  T.eq("then the level", got[2].cmd, "LIGHT_BRIGHTNESS_CHANGED")
  T.eq("and the color the light went off in is the next Previous", settings.previousColor.x, 0.64)
  clock.run(800)
  p:sync({ on = false, level = 0.5, levelMs = 0, color = BLUE, colorTarget = RED, colorMs = 1000 })
  p:sync(rest(false, 0.5, RED))
  T.eq("the ramp's end then tells nothing more", names(), {})

  p:sync({ on = false, level = 0.5, levelMs = 0, color = BLUE, colorMs = 0, colorPreset = 9, colorPresetOrigin = 1 })
  got = take()
  T.eq("a color while off is told", got[1].cmd, "LIGHT_COLOR_CHANGED")
  T.eq("an id goes with its origin", got[1].params.LIGHT_COLOR_CURRENT_PRESET_ORIGIN, 1)
  p:sync({ on = false, level = 0.5, levelMs = 0, color = BLUE, colorMs = 0, colorPreset = 9 })
  T.eq("an origin alone never goes", names(), {})

  p:sync(rest(true, 0.5, { x = 0.3, y = 0.32, mode = "cct", kelvin = 6000 }))
  got = take()
  T.eq("a white is mode 1", got[1].params.LIGHT_COLOR_CURRENT_COLOR_MODE, 1)
end

T.section("BUTTON_ACTION: echoed after the CHANGING it starts, never for a link's own press")
do
  local p = make(LINKS)
  p:pressed(0, 1, true)
  p:sync({ on = true, level = 0, levelTarget = 1, levelMs = 3000, colorMs = 0 })
  T.eq(
    "CHANGING, then the echo",
    names(),
    { "LIGHT_BRIGHTNESS_CHANGING", "MATCH_LED_STATE", "MATCH_LED_STATE", "MATCH_LED_STATE", "BUTTON_ACTION" }
  )
  p:pressed(0, 2, false)
  clock.run(600)
  p:sync({ on = true, level = 0.2, levelTarget = 1, levelMs = 2400, colorMs = 0 })
  T.eq("a link's DO_* is not echoed", names(), {})
end

T.section("settings the proxy hears back: preset level, Min and Max On, button colors")
do
  local p, settings = make(LINKS)
  p:online(DEVICE)
  p:sync(rest(true, 0.5))
  take()
  settings.preset = 70
  settings.hi = 90
  settings.lo = 5
  settings.colors[1] = { on = "ff0000", off = "000000" }
  p:sync(rest(true, 0.5))
  local got = take()
  local cmds = {}
  for _, s in ipairs(got) do
    cmds[#cmds + 1] = s.cmd .. "@" .. s.id
  end
  T.eq("each change is told once", cmds, {
    "LIGHT_BRIGHTNESS_CHANGED@5001",
    "PRESET_LEVEL@5001",
    "MAX_ON@5001",
    "MIN_ON@5001",
    "BUTTON_INFO@5001",
    "BUTTON_COLORS@302",
  })
  T.eq("the preset level as a plain string", got[2].params, "70")
  p:sync(rest(true, 0.5))
  T.eq("and not again", names(), {})
  settings.rates.holdDown = 4000
  p:sync(rest(true, 0.5))
  got = take()
  T.eq("a hold rate", { got[1].cmd, got[1].params }, { "HOLD_RATE_DOWN", "4000" })

  p, settings = make()
  settings.hi = 70
  p:sync(rest(false, 0))
  T.eq(
    "a setting changed before the first sync is still echoed, after the first level",
    names(),
    { "LIGHT_BRIGHTNESS_CHANGED", "MAX_ON" }
  )

  p = make()
  p:sync(rest(true, 0.5))
  T.eq("the first sync of a load echoes nothing", names(), { "LIGHT_BRIGHTNESS_CHANGED" })
end

T.section("a setup read tells no echo: an echo answers a setting command")
do
  local p, settings = make(LINKS)
  p:readSetup()
  settings.preset = 30
  settings.colors[1] = { on = "000000", off = "0000ff" }
  p:read()
  p:online(DEVICE)
  p:sync(rest(true, 0.5))
  local got = take()
  local cmds = {}
  for _, s in ipairs(got) do
    cmds[#cmds + 1] = s.cmd
  end
  T.check("a start tells no PRESET_LEVEL", not table.concat(cmds, " "):find("PRESET_LEVEL"), cmds)
  p:readSetup()
  settings.preset = 40
  p:sync(rest(true, 0.5))
  T.eq("the setup re-read at the first report tells nothing either", names(), {})
  settings.preset = 55
  p:sync(rest(true, 0.5))
  got = take()
  T.eq("a setting command after it is echoed", { #got, got[1].cmd, got[1].params }, { 1, "PRESET_LEVEL", "55" })
end

T.section("shown: at each connection's first sync, then whenever it changes")
do
  local p, settings = make()
  T.eq("nothing while offline", p:shown(), nil)
  p:online(DEVICE)
  take()
  p:sync(rest(true, 0.5, { x = 0.3, y = 0.32, mode = "cct", kelvin = 6000 }))
  T.eq("the first after online", p:shown(), { kelvin = 6000, minOn = 1, maxOn = 100 })
  T.eq("nothing while it holds", p:shown(), nil)
  settings.hi = 80
  T.eq("a new Max On", p:shown(), { kelvin = 6000, minOn = 1, maxOn = 80 })
  p:sync(rest(true, 0.5, RED))
  T.eq("full color has no kelvin", p:shown(), { minOn = 1, maxOn = 80 })
  p:offline()
  p:online(DEVICE)
  T.eq("a new connection is owed one again", p:shown(), { minOn = 1, maxOn = 80 })
  take()

  p = make()
  p:online({ dims = true, color = true })
  p:sync(rest(true, 0.5, { x = 0.3, y = 0.32, mode = "cct", kelvin = 6000 }))
  T.eq("a device without CCT shows no kelvin", p:shown(), { minOn = 1, maxOn = 100 })
  take()
end

T.section("answers: GET_CONNECTED_STATE, GET_LIGHT_LEVEL, REQUEST_BUTTON_COLORS")
do
  local p = make(LINKS)
  p:online(DEVICE)
  p:sync(rest(true, 0.5))
  take()
  p:answer("GET_CONNECTED_STATE", {}, rest(true, 0.5))
  local got = take()
  T.eq("connected", { got[1].cmd, got[1].params.STATE }, { "ONLINE_CHANGED", true })
  p:answer("GET_LIGHT_LEVEL", {}, rest(true, 0.5))
  got = take()
  T.eq("at rest: LIGHT_LEVEL, the level held", { got[1].cmd, got[1].params }, { "LIGHT_LEVEL", "50" })
  p:answer("GET_LIGHT_LEVEL", {}, { on = true, level = 0.6, levelTarget = 0.9, levelMs = 700, colorMs = 0 })
  got = take()
  T.eq("in a ramp: still the level held", { got[1].cmd, got[1].params }, { "LIGHT_LEVEL", "50" })
  p:answer("REQUEST_BUTTON_COLORS", {}, rest(true, 0.5))
  T.eq("each button's colors, then each LED again", names(), {
    "BUTTON_COLORS",
    "BUTTON_COLORS",
    "BUTTON_COLORS",
    "MATCH_LED_STATE",
    "MATCH_LED_STATE",
    "MATCH_LED_STATE",
  })
end

T.section("the told level starts unknown: the first level is told whatever it is")
do
  vars = {}
  local p = make()
  p:read()
  p:sync(rest(false, 0))
  local got = take()
  T.eq(
    "a fresh proxy with no 1001: an off first sync is told",
    { got[1].cmd, got[1].params.LIGHT_BRIGHTNESS_CURRENT },
    { "LIGHT_BRIGHTNESS_CHANGED", 0 }
  )
  vars = { [1001] = "0", [1110] = "0" }
  p = make()
  p:read()
  p:sync(rest(false, 0))
  T.eq("a proxy that shows 0: an off tells nothing", names(), {})
  vars = {}
end

T.section("GET_LIGHT_LEVEL answers nothing while no level is known")
do
  vars = { [1001] = "abc" }
  local p = make()
  p:read()
  p:online(DEVICE)
  take()
  p:answer("GET_LIGHT_LEVEL", {}, rest(false, 0))
  T.eq("an invalid 1001 and nothing told: no answer", names(), {})
  p:sync(rest(true, 0.5))
  take()
  p:answer("GET_LIGHT_LEVEL", {}, rest(true, 0.5))
  local got = take()
  T.eq("once told, the level held", { got[1].cmd, got[1].params }, { "LIGHT_LEVEL", "50" })
  vars = {}
end

T.section("REQUEST_BUTTON_COLORS on a Button Link is answered on that link")
do
  local p, settings = make(LINKS)
  settings.colors[1] = { on = "ff0000", off = "220000" }
  p:online(DEVICE)
  p:sync(rest(true, 0.5))
  take()
  p:answer("REQUEST_BUTTON_COLORS", {}, rest(true, 0.5), LINKS.bottom)
  local got = take()
  T.eq("two answers, both on the asking link", { #got, got[1].id, got[2].id }, { 2, LINKS.bottom, LINKS.bottom })
  T.eq(
    "its own button's colors",
    { got[1].cmd, got[1].params.ON_COLOR, got[1].params.OFF_COLOR, got[1].params.BUTTON_ID },
    { "BUTTON_COLORS", "ff0000", "220000", nil }
  )
  T.eq("then its LED: the light's own state", { got[2].cmd, got[2].params.STATE }, { "MATCH_LED_STATE", true })
  p:answer("REQUEST_BUTTON_COLORS", {}, rest(true, 0.5), PROXY)
  T.eq("on the proxy binding: each button's, then each LED", #take(), 6)
end

--- A proxy that has read the given variables and come online, with nothing sent since.
local function connected(variables, links)
  vars = variables
  local p, settings = make(links)
  p:read()
  p:offline()
  p:online(DEVICE)
  sent = {}
  return p, settings
end

--- The sends of one command, by name.
local function named(list, cmd)
  local out = {}
  for _, s in ipairs(list) do
    if s.cmd == cmd then
      out[#out + 1] = s
    end
  end
  return out
end

T.section("GET_LIGHT_LEVEL: LIGHT_LEVEL with the level the light holds, online or not")
do
  local function answered(p)
    sent = {}
    p:answer("GET_LIGHT_LEVEL", {}, rest(true, 1, nil))
    local s = named(take(), "LIGHT_LEVEL")
    return s[1] and s[1].params
  end
  local p = connected({ [1001] = "100" })
  T.eq("inside the first report's ONLINE_CHANGED: the level the proxy showed at start", answered(p), "100")
  p:sync(rest(true, Range.toDevice(40, 1, 100), nil))
  T.eq("online: the level last told", answered(p), "40")
  p:lost(true)
  T.eq("suspended: the level it keeps", answered(p), "40")
  p:lost(false)
  T.eq("lost: the off its loss told", answered(p), "0")
  vars = {}
  p = make()
  p:read()
  T.eq("nothing read and nothing told: no answer", answered(p), nil)
end

T.section("the link LEDs: told at the first report after a load and after a suspend")
do
  local level = Range.toDevice(60, 1, 100)
  local p = connected({ [1001] = "60", [1110] = "60" }, LINKS)
  p:sync(rest(true, level, nil))
  local all = take()
  T.eq("after a load the LEDs are told, though the level is as the proxy shows", #named(all, "MATCH_LED_STATE"), 3)
  T.eq("and no level", #named(all, "LIGHT_BRIGHTNESS_CHANGED"), 0)
  p:lost(true)
  p:online(DEVICE)
  sent = {}
  p:sync(rest(true, level, nil))
  T.eq("after a suspend, again", #named(take(), "MATCH_LED_STATE"), 3)
  p:lost(false)
  p:online(DEVICE)
  sent = {}
  p:sync(rest(false, level, nil))
  T.eq("after a loss, whose off told them, not again", #named(take(), "MATCH_LED_STATE"), 0)
end

T.section("a replacing color ramp's CHANGING starts where the color has got to")
do
  local p = connected({})
  p:sync({ on = true, level = 1, levelMs = 0, color = RED, colorMs = 0 })
  p:sync({ on = true, level = 1, levelMs = 0, color = RED, colorTarget = BLUE, colorMs = 3000 })
  sent = {}
  local mid = { x = 0.4, y = 0.2, mode = "xy" }
  p:sync({ on = true, level = 1, levelMs = 0, color = mid, colorTarget = RED, colorMs = 2000 })
  local s = named(take(), "LIGHT_COLOR_CHANGING")
  T.eq(
    "from the color it has got to",
    s[1] and { s[1].params.LIGHT_COLOR_CURRENT_X, s[1].params.LIGHT_COLOR_CURRENT_Y },
    {
      0.4,
      0.2,
    }
  )
end

T.section("with Min On at Max On or above, a level command is told the level it asked")
do
  local p, settings = connected({})
  settings.lo, settings.hi = 60, 60
  p:taken({ kind = "level", level = 37, source = "proxy" })
  p:sync(rest(true, Range.toDevice(37, 60, 60), nil))
  local s = named(take(), "LIGHT_BRIGHTNESS_CHANGED")
  T.eq("37 is told, though every level sits at one brightness", s[1] and s[1].params.LIGHT_BRIGHTNESS_CURRENT, 37)
end

T.section("a command for what the proxy shows tells nothing: the tell is a diff")
do
  local level = Range.toDevice(40, 1, 100)
  local p = connected({ [1001] = "40", [1110] = "40", [1200] = "0.64,0.33,0", [1210] = "0.64,0.33,0" })
  p:sync(rest(true, level, RED))
  sent = {}
  p:taken({ kind = "level", level = 40, source = "proxy" })
  p:sync(rest(true, level, RED))
  T.eq("a level command for the level shown", names(), {})
  p:taken({ kind = "color", color = RED, source = "proxy" })
  p:sync(rest(true, level, RED))
  T.eq("a color command for the color shown", names(), {})
end

T.section("a color preset picked while off is told its preset at once, though its color is the one held")
do
  local p = connected({ [1001] = "0", [1200] = "0.64,0.33,0", [1210] = "0.64,0.33,0" })
  p:sync(rest(false, 0.5, RED))
  sent = {}
  p:taken({ kind = "color", color = RED, presetId = 5, presetOrigin = 1, source = "proxy" })
  local view = rest(false, 0.5, RED)
  view.colorPreset, view.colorPresetOrigin = 5, 1
  p:sync(view)
  local s = named(take(), "LIGHT_COLOR_CHANGED")
  T.eq(
    "CHANGED with the preset",
    s[1] and { s[1].params.LIGHT_COLOR_CURRENT_PRESET_ID, s[1].params.LIGHT_COLOR_CURRENT_PRESET_ORIGIN },
    { 5, 1 }
  )
end

clock.restore()
T.finish()
