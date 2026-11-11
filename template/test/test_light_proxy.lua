-- The Light V2 library's own suite: lib.light driving MemoryLight, the kit's reference device and
-- adapter, behind the kit's fake proxy on a virtual clock, across the declarations a light can make.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_light_proxy.lua

local T = require("testlib")

require("c4_shim")

local H = require("light_harness")
local persist = require("lib.persist")
local Caps = require("lib.light.caps")
local Color = require("lib.light.color")

local FULL, CCT = Color.FULL, Color.CCT

--- One case: a raise in it is its failure, by name, and the next case still runs.
local function case(fn)
  H.case(T, fn)
end

-- The settings the library keeps, cleared before each case so none carries into the next.
local KEYS = {
  "preset_level",
  "click_rate_up",
  "click_rate_down",
  "hold_rate_up",
  "hold_rate_down",
  "brightness_rate_default",
  "color_rate_default",
  "brightness_on_mode",
  "brightness_on_mode_preset",
  "brightness_presets",
  "color_presets",
  "color_on_mode",
  "previous_color",
  "button_colors",
  "scenes",
  "max_on_level",
  "min_on_level",
}

local function forget()
  for _, key in ipairs(KEYS) do
    persist:delete(key)
  end
end

-- A color bulb that fades itself, keeps its last level while off, and reports progress with read
-- answers, as a Zigbee bulb through its device driver does.
local BULB = {
  dims = true,
  color = true,
  cct = { min = 2000, max = 6500 },
  levelSteps = 254,
  keepsLevel = true,
  policy = "settle",
  settleMs = 2500,
}

--- A world for `o` over BULB's defaults, on at `level` when given.
local function world(o, level)
  forget()
  local opts = {}
  for k, v in pairs(BULB) do
    opts[k] = v
  end
  for k, v in pairs(o or {}) do
    opts[k] = v
  end
  local w = H.world(opts)
  if level then
    w.proxy:send("SET_LEVEL", { LEVEL = level })
    w.run(10000)
    w.proxy:mark()
    w.m.sent = {}
  end
  return w
end

--- A world whose adapter gives its word on every command (ack = done).
local function held(o, level)
  o = o or {}
  o.ack = "done"
  return world(o, level)
end

local function near(a, b, tolerance)
  return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-3)
end

--- The color the proxy was last told, as { x, y, mode }.
local function toldColor(w)
  return w.proxy.color
end

--- The device's color now.
local function deviceColor(w)
  return w.device:state(w.clock.now()).color
end

--- The colors told since the mark, as { x, y }.
local function toldColors(w)
  local out = {}
  for _, q in ipairs(w.proxy:told("LIGHT_COLOR_CHANGED")) do
    out[#out + 1] = { x = q.LIGHT_COLOR_CURRENT_X, y = q.LIGHT_COLOR_CURRENT_Y }
  end
  return out
end

--- The levels of the commands the device was sent since the mark, pre-ons left out.
local function sentLevels(w)
  local out = {}
  for _, c in ipairs(w.m.sent) do
    if not c.preOn then
      out[#out + 1] = c.level and math.floor(c.level * 100 + 0.5) or (c.on == false and 0) or (c.on and "on") or "-"
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- The proxy's setup
--------------------------------------------------------------------------------

T.section("a light the proxy never sent its Color On Mode reads it from the proxy's setup at start")
case(function()
  local w = world({ setup = H.setupFile("setup-607.xml") })
  local mode = persist:get("color_on_mode")
  T.eq("the on preset is the device's On Color", mode and mode.onPreset.id, 1)
  T.eq("and the fade preset the Dim Color, so Dim-To-Warm", mode and mode.fadePreset.id, 2)
  T.check(
    "with the colors the setup lists",
    mode and near(mode.onPreset.x, 0.380438) and near(mode.fadePreset.x, 0.526676)
  )
  T.eq(
    "the default rates are the setup's",
    { persist:get("brightness_rate_default"), persist:get("color_rate_default") },
    { 750, 750 }
  )
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  local sent = w.m.sent[1] or {}
  T.check("a level carries the Dim-To-Warm mix", sent.color ~= nil and sent.color.kelvin ~= nil, T.show(sent))
  T.eq("and lands", w.proxy.level, 50)
  w.restore()
end)

T.section("a preset the setup names is found by its id and its origin together")
case(function()
  local w = world({ setup = H.setupFile("setup-626.xml") })
  local mode = persist:get("color_on_mode")
  T.eq("the on preset is the Color Agent's", mode and { mode.onPreset.id, mode.onPreset.origin }, { 8, 2 })
  T.eq(
    "and so is the fade preset, not the device's preset 10",
    mode and { mode.fadePreset.id, mode.fadePreset.origin },
    { 10, 2 }
  )
  w.restore()
end)

T.section("a setup with no fade preset is Previous for the device's preset 10 and a preset for any other")
case(function()
  local setup = H.setupFile("setup-607.xml")
  local noFade = setup
    :gsub(
      "<light_color_on_mode_fade_preset_id>.-</light_color_on_mode_fade_preset_id>",
      "<light_color_on_mode_fade_preset_id>0</light_color_on_mode_fade_preset_id>"
    )
    :gsub(
      "<light_color_on_mode_fade_preset_origin>.-</light_color_on_mode_fade_preset_origin>",
      "<light_color_on_mode_fade_preset_origin>0</light_color_on_mode_fade_preset_origin>"
    )
  local previous = noFade:gsub(
    "<light_color_on_mode_preset_id>.-</light_color_on_mode_preset_id>",
    "<light_color_on_mode_preset_id>10</light_color_on_mode_preset_id>"
  )
  local w = world({ setup = previous }, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(5000)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("ON")
  w.run(10000)
  local on = w.m.sent[1] or {}
  T.check(
    "Previous: an on is in the color the light went off in",
    on.color and near(on.color.x, 0.3) and near(on.color.y, 0.6),
    T.show(on)
  )
  w.restore()
  w = world({ setup = noFade }, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(5000)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("ON")
  w.run(10000)
  on = w.m.sent[1] or {}
  T.check("a preset: an on is in the On Color, a white", on.color and on.color.kelvin ~= nil, T.show(on))
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  T.eq("and a level after it carries no color", (w.m.sent[1] or {}).color, nil)
  w.restore()
end)

T.section("a setup that cannot be read, or that names no on mode, leaves what the light has stored")
case(function()
  local function stored()
    return {
      persist:get("color_on_mode", false),
      persist:get("brightness_on_mode", false),
      persist:get("brightness_rate_default", false),
    }
  end
  for _, c in ipairs({
    { "an empty answer", "" },
    { "an answer that is not whole", H.setupFile("setup-607.xml"):sub(1, 2000) },
  }) do
    forget()
    persist:set(
      "color_on_mode",
      { onPreset = { id = 3, origin = 1, x = 0.5, y = 0.4 }, fadePreset = { id = 0, origin = 0 } }
    )
    persist:set("brightness_rate_default", 1234)
    local before = stored()
    local w = H.world({ dims = true, policy = "settle", settleMs = 2000, setup = c[2] })
    T.eq(c[1] .. ": nothing stored changes", stored(), before)
    w.restore()
  end
end)

T.section("a new light's Color On Mode is read once the proxy is told the light has color")
case(function()
  local w = world({ newLight = H.setupFile("setup-732-new.xml"), setup = H.setupFile("setup-732.xml"), offline = true })
  T.eq("at start the setup lists no colors: no mode", persist:get("color_on_mode", false), false)
  w.m.connect()
  w.run(10000)
  local mode = persist:get("color_on_mode")
  T.check("once the capabilities are told, the setup read straight after has the mode", mode and mode.onPreset.id == 1)
  w.restore()
end)

T.section("the setup is read straight after the capabilities, before the buttons")
case(function()
  local w = world({ offline = true })
  w.proxy:mark()
  local order = {}
  local said = 0
  ShimSetUIRequest(function()
    order[#order + 1] = "GET_SETUP after " .. (w.proxy:said()[#w.proxy:said()] or "nothing")
    said = said + 1
    return ""
  end)
  w.m.connect()
  T.eq(
    "one read, straight after DYNAMIC_CAPABILITIES_CHANGED",
    order,
    { "GET_SETUP after DYNAMIC_CAPABILITIES_CHANGED" }
  )
  local s = w.proxy:said()
  T.eq("then the buttons and the preset level", { s[3], s[4] }, { "NUMBER_BUTTONS", "BUTTON_INFO" })
  w.restore()
end)

--------------------------------------------------------------------------------
-- Declarations
--------------------------------------------------------------------------------

--- Run fn with log:error collected; returns what it logged.
local function errorsOf(fn)
  local log = require("lib.logging")
  local logError = log.error
  local out = {}
  log.error = function(_, fmt, ...)
    out[#out + 1] = string.format(tostring(fmt), ...)
  end
  local ok, err = pcall(fn)
  log.error = logError
  assert(ok, err)
  return out
end

T.section("a declaration names its report policy: one without is refused whole, and the last accepted stays")
case(function()
  local w = world({}, 40)
  local accepted
  local errors = errorsOf(function()
    accepted = w.light:declare({ dims = true, fade = { by = "device" } })
  end)
  T.eq("it is refused", accepted, false)
  T.eq("with an error", #errors, 1)
  T.contains("that names the field", errors[1] or "", "reports.policy")
  w.m.other({ on = true, level = 0.7 })
  w.run(10000)
  T.eq("the light online keeps its reports, by the policy accepted before", w.proxy.level, 70)
  w.restore()

  forget()
  local clock = require("c4_fixtures").virtualClock()
  local proxy = H.proxy(clock)
  local m = H.memoryLight(clock, { dims = true, policy = "settle", settleMs = 2000 })
  m.light:start()
  errors = errorsOf(function()
    m.light:declare({ dims = true })
    m.light:report({ on = true, level = 0.5 }, {})
  end)
  T.eq("a light with none accepted never comes online", proxy.online, false)
  T.eq("its report is dropped, with an error", #errors, 2)
  proxy:restore()
  clock.restore()
end)

T.section("a bad or unknown field is logged and ignored; the rest stands")
case(function()
  local cases = {
    {
      "preOn without dims",
      { dims = false, fade = { by = "device", preOn = 0.0039 }, reports = { policy = "trust" } },
    },
    { "ackMs without ack = done", { dims = true, reports = { policy = "trust", ackMs = 1000 } } },
    { "a field this version does not know", { dims = true, glow = true, reports = { policy = "trust" } } },
    { "settleMs missing under settle", { dims = true, reports = { policy = "settle" } } },
    {
      "a fade this version does not run",
      { dims = true, fade = { by = "stepped" }, reports = { policy = "trust" } },
    },
  }
  for _, c in ipairs(cases) do
    local decl, errors = Caps.check(c[2])
    T.check(c[1] .. ": the declaration stands", decl ~= nil)
    T.eq(c[1] .. ": one error", #errors, 1)
  end
  local decl = Caps.check({ dims = false, fade = { by = "device", preOn = 0.0039 }, reports = { policy = "trust" } })
  T.eq("a preOn without dims is not taken", decl.fade.preOn, nil)
  decl = Caps.check({ dims = true, reports = { policy = "trust", ack = "done" } })
  T.eq("ack = done takes the default ackMs", decl.reports.ackMs, 40000)
  T.eq(
    "a declaration names no ack: commands are done at the send",
    Caps.check({ reports = { policy = "trust" } }).reports.ack,
    "send"
  )
end)

T.section("the proxy is told the capabilities each declaration derives, in one notify")
case(function()
  local function caps(decl)
    return Caps.dynamic((Caps.check(decl)))
  end
  local relay = caps({ dims = false, fade = { by = "none" }, reports = { policy = "settle", settleMs = 0 } })
  T.eq(
    "a relay: no dimming",
    { relay.dimmer, relay.set_level, relay.supports_target, relay.ramp_level },
    { false, false, false, false }
  )
  T.eq("no stops", { relay.supports_brightness_stop, relay.supports_color_stop }, { false, false })
  T.eq(
    "and every rate's bounds still go",
    { relay.color_rate_min, relay.color_rate_max, relay.brightness_rate_max },
    { 0, 65535, 65535 }
  )
  local dimmer = caps({
    dims = true,
    levelSteps = 254,
    fade = { by = "device", preOn = 0.0039 },
    reports = { policy = "settle", settleMs = 1 },
  })
  T.eq(
    "a dimmer the device fades: it dims and stops",
    { dimmer.dimmer, dimmer.supports_brightness_stop },
    { true, true }
  )
  T.eq("and has no color", { dimmer.supports_color, dimmer.supports_color_correlated_temperature }, { false, false })
  local cct = caps({ dims = true, cct = { min = 2203, max = 7042 }, reports = { policy = "trust" } })
  T.eq(
    "a color temperature light: its range",
    { cct.color_correlated_temperature_min, cct.color_correlated_temperature_max },
    { 2203, 7042 }
  )
  T.eq("and a color stop", cct.supports_color_stop, true)
  local still = caps({ dims = true, color = true, fade = { by = "none" }, reports = { policy = "trust" } })
  T.eq(
    "a dimmer that does not fade: no stop of either aspect",
    { still.supports_brightness_stop, still.supports_color_stop },
    { false, false }
  )
  T.eq("and its color rate cannot change (color_rate_behavior 0, where T3 told 1)", still.color_rate_behavior, 0)
  T.eq("the trace tolerance all three send", still.color_trace_tolerance, 2)
  local w = world({ offline = true })
  w.m.connect()
  T.eq("online, the full set goes once", #w.proxy:told("DYNAMIC_CAPABILITIES_CHANGED"), 1)
  T.eq("as the declaration derives it", w.proxy.caps, Caps.dynamic((Caps.check(w.m.declaration()))))
  w.m.connect()
  T.eq("and not again in the same connection", #w.proxy:told("DYNAMIC_CAPABILITIES_CHANGED"), 1)
  w.restore()
end)

T.section(
  "a capability change during a connection is told at once (N9; T3 waited for the next one); a policy change resets at once"
)
case(function()
  local w = world({}, 50)
  w.m.o.color = false
  w.light:declare(w.m.declaration())
  T.eq("the proxy is told the new set at once", #w.proxy:told("DYNAMIC_CAPABILITIES_CHANGED"), 1)
  T.eq("and it has no color", w.proxy.caps.supports_color, false)
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("a color no longer goes: the declaration in force has none", w.m.sent, {})
  w.light:declare(w.m.declaration())
  T.eq("the same declaration again tells nothing", #w.proxy:told("DYNAMIC_CAPABILITIES_CHANGED"), 1)
  w.run(10000)
  w.m.drop()
  w.m.back()
  w.run(10000)
  T.eq("at the next connection the proxy is told the light has no color", w.proxy.caps.supports_color, false)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 5000 })
  w.light:declare({ dims = true, levelSteps = 254, fade = { by = "device" }, reports = { policy = "trust" } })
  T.eq("a policy change ends the window: nothing is pending", w.light:_pending(), false)
  w.run(10000)
  w.restore()
end)

T.section("a report before start() is kept, the last one, and taken at start (T3 dropped it)")
case(function()
  forget()
  local clock = require("c4_fixtures").virtualClock()
  local proxy = H.proxy(clock)
  local m = H.memoryLight(clock, { dims = true, policy = "trust" })
  m.online = false
  m.light:declare(m.declaration())
  T.eq("its verdict is none", m.light:report({ on = true, level = 0.3 }, {}), nil)
  m.light:report({ on = true, level = 0.5 }, {})
  T.eq("and the proxy hears nothing before start", #proxy.notes, 0)
  m.light:start()
  T.eq("at start the kept report brings it online", proxy.online, true)
  T.eq("and the last one is told", proxy.level, 50)
  T.eq("once", #proxy:told("LIGHT_BRIGHTNESS_CHANGED"), 1)
  proxy:restore()
  clock.restore()
end)

T.section("a new settleMs during a connection opens the next window with it")
case(function()
  local w = world({
    drop = function(kind)
      return kind == "report"
    end,
  }, 20)
  w.m.o.settleMs = 8000
  w.light:declare(w.m.declaration())
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(5000)
  T.check("past the old settleMs the window is still open", w.light.device.settle ~= nil)
  w.run(10000)
  w.restore()
end)

T.section("a policy change starts from nothing: no window, held color or ledger entry of the old one acts after it")
case(function()
  local function quiet(o, level)
    o.drop = function(kind)
      return kind == "report"
    end
    return world(o, level)
  end
  local w = quiet({}, 50)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 5000 })
  w.m.o.policy = "trust"
  w.light:declare(w.m.declaration())
  w.run(6000)
  w.light:report({ on = true, level = 0.3 }, {})
  w.proxy:mark()
  w.run(10000)
  T.eq("the old window's end tells nothing", w.proxy:changed(), {})
  w.restore()
  w = quiet({}, 50)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.light:report({ color = { x = 0.2, y = 0.2 } }, { control = "color" })
  w.m.o.policy = "trust"
  w.light:declare(w.m.declaration())
  w.run(10000)
  T.check("nor does a color it held", near((toldColor(w) or {}).x, 0.3), T.show(toldColor(w)))
  w.restore()
  w = quiet({ ack = "done" }, 50)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.m.o.policy = "trust"
  w.light:declare(w.m.declaration())
  w.light:report({ on = true, level = 0.3 }, {})
  T.eq("and a command still owed its word holds nothing back", w.proxy.level, 30)
  w.restore()
end)

T.section("a policy change during a connection keeps what waits: the light lands on the level asked last")
case(function()
  for _, change in ipairs({ { "settle", "trust" }, { "trust", "settle" } }) do
    local name = change[1] .. " to " .. change[2]
    local w = held({ policy = change[1] }, 50)
    w.m.stall(w.clock.now() + 2000)
    w.proxy:send("SET_LEVEL", { LEVEL = 80 })
    w.proxy:send("SET_LEVEL", { LEVEL = 30 })
    w.m.o.policy = change[2]
    w.light:declare(w.m.declaration())
    w.run(30000)
    T.eq(name .. ": the waiting level goes at the word", { w.proxy.level, w.devicePercent() }, { 30, 30 })
    w.restore()
  end
end)

T.section("a new declaration's pre-on and fade take effect at once (N9; T3 waited for the next connection)")
case(function()
  local w = world({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.o.keepsLevel = false
  w.light:declare(w.m.declaration())
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  T.eq("a rated on from off goes with no pre-on: the declaration has none", (w.m.sent[1] or {}).preOn, nil)
  w.run(10000)
  w.m.o.fade = "none"
  w.light:declare(w.m.declaration())
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  T.eq("and a fade none at once: the level goes with no rate", (w.m.sent[1] or {}).ms or 0, 0)
  w.run(10000)
  w.restore()
end)

T.section("after a policy change the level verdict judges against the level told")
case(function()
  local w = world({}, 60)
  w.m.o.policy = "trust"
  w.light:declare(w.m.declaration())
  w.m.o.policy = "settle"
  w.light:declare(w.m.declaration())
  local v = w.light:report({ on = true, level = 0.6 }, { control = "level" })
  T.eq("a report of it is own", v.level.kind, "own")
  w.restore()
end)

--------------------------------------------------------------------------------
-- The invariants
--------------------------------------------------------------------------------

T.section("a ramp's end sends the device nothing; the proxy is told CHANGED at its end")
case(function()
  local w = world({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
  T.eq("one command, the ramp's", #w.m.sent, 1)
  w.run(2900)
  T.eq("no CHANGED before its end", w.proxy:changed(), {})
  w.run(200)
  T.eq("CHANGED 80 at its end", w.proxy:changed(), { 80 })
  w.run(10000)
  T.eq("and nothing more was sent", #w.m.sent, 1)
  w.restore()
end)

T.section("a rated on from off goes after a pre-on, and is told CHANGING from 1")
case(function()
  local w = world({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  local pre, ramp = w.m.sent[1] or {}, w.m.sent[2] or {}
  T.eq(
    "the pre-on: on, at the declared brightness, at once",
    { pre.preOn, pre.on, pre.level, pre.ms },
    { true, true, 0.0039, 0 }
  )
  T.eq("then the ramp", { ramp.on, ramp.ms }, { true, 4000 })
  T.check("to 60", near(ramp.level, 0.6))
  local changing = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.eq("CHANGING from 1", changing.LIGHT_BRIGHTNESS_CURRENT, 1)
  T.eq("so the proxy has the light on from the start", w.proxy.lit, true)
  w.run(10000)
  T.eq("it lands", w.proxy.level, 60)
  w.restore()
end)

T.section("Get Light Level in a ramp tells where the ramp has got to, and the time it has left")
case(function()
  local w = world({}, 0)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("GET_LIGHT_LEVEL")
  local c = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.eq("CHANGING, not CHANGED", w.proxy:changed(), {})
  T.eq("from a quarter of the way", c.LIGHT_BRIGHTNESS_CURRENT, 25)
  T.eq("with the time left", c.RATE, 3000)
  w.run(10000)
  w.proxy:mark()
  w.proxy:send("GET_LIGHT_LEVEL")
  T.eq("out of a ramp it is CHANGED", w.proxy:changed(), { 100 })
  w.restore()
end)

T.section("at a disconnect the proxy is told off and the button LEDs go off with it")
case(function()
  local w = world({}, 70)
  T.eq("lit, the Top LED is on", w.proxy.leds[H.LINKS.top], true)
  w.proxy:mark()
  w.m.drop()
  T.eq("offline", w.proxy.online, false)
  T.eq("and off", w.proxy:changed(), { 0 })
  T.eq("the Top LED is told off", w.proxy.leds[H.LINKS.top], false)
  T.eq("and the Bottom on", w.proxy.leds[H.LINKS.bottom], true)
  w.m.back()
  w.run(10000)
  T.eq("back, they follow the light again", w.proxy.leds[H.LINKS.top], true)
  w.restore()
  -- A disconnect drops the brightness preset id: neither its off nor the level back names it.
  w = world({}, 0)
  w.proxy:send(
    "SET_BRIGHTNESS_TARGET",
    { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 0, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 2 }
  )
  w.run(10000)
  local lit = w.proxy:told("LIGHT_BRIGHTNESS_CHANGED")
  T.eq("a preset's level is told as its preset", (lit[#lit] or {}).LIGHT_BRIGHTNESS_CURRENT_PRESET_ID, 2)
  w.proxy:mark()
  w.m.drop()
  local off = w.proxy:told("LIGHT_BRIGHTNESS_CHANGED")[1] or {}
  w.proxy:mark()
  w.m.back()
  w.run(10000)
  local back = w.proxy:told("LIGHT_BRIGHTNESS_CHANGED")[1] or {}
  T.eq("a disconnect's off names no preset, and nor does the level back", {
    back.LIGHT_BRIGHTNESS_CURRENT,
    off.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID,
    back.LIGHT_BRIGHTNESS_CURRENT_PRESET_ID,
  }, { 40 })
  w.restore()
  -- Lit in a color other than the one it last went off in: a disconnect is no off.
  w = world({}, 70)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("ON")
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.m.drop()
  local prev = persist:get("previous_color") or {}
  T.check("the previous color is still the one of the last off", near(prev.x, 0.3) and near(prev.y, 0.6), T.show(prev))
  w.restore()
end)

T.section("an off early in a rated on from off keeps Previous On where it was")
case(function()
  local w = world({}, 60)
  w.proxy:send("OFF")
  w.run(10000)
  T.eq("Previous On holds 60", w.proxy.previousOn, 60)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(10)
  w.proxy:send("OFF")
  w.run(10000)
  T.eq(
    "an off before the light is lit tells the level to keep first",
    (w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[2] or {}).LIGHT_BRIGHTNESS_CURRENT,
    60
  )
  T.eq("so Previous On is still 60", w.proxy.previousOn, 60)
  w.restore()
end)

T.section(
  "a light that says it is on with no level is at full, so outside a Max below 100 it is sent the level it shows"
)
case(function()
  local w = world({ offline = true })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.light:declare(w.m.declaration())
  w.light:report({ on = true }, {})
  T.eq("it shows 100", w.proxy.level, 100)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("and is sent it, which brings it to the Max", #w.m.sent, 1)
  w.run(10000)
  w.restore()
end)

T.section("the first color report on a connection is told even when it is the color the light starts in")
case(function()
  for _, policy in ipairs({ "settle", "trust" }) do
    local w = world({ policy = policy, offline = true })
    w.light:declare(w.m.declaration())
    w.light:report({ on = true, level = 0.5, color = { x = 0.3127, y = 0.329, mode = CCT } }, {})
    T.eq(policy .. ": LIGHT_COLOR_CHANGED once", #w.proxy:told("LIGHT_COLOR_CHANGED"), 1)
    w.restore()
  end
end)

T.section("a report's values: an infinity, a kelvin of 0 or a color with no y is no reading, and on left out is kept")
case(function()
  local w = world({ policy = "trust", keepsLevel = false }, 50)
  w.proxy:mark()
  w.light:report({ on = true, level = math.huge }, {})
  w.light:report({ color = { kelvin = 0 } }, {})
  w.light:report({ color = { x = 0.3 } }, {})
  T.eq("none is told", w.proxy.notes, {})
  w.light:report({ level = 0.4 }, {})
  T.eq("a level with no on is told, the light still on", w.proxy:changed(), { 40 })
  w.light:report({ on = true }, {})
  T.eq("and an on with no level keeps the level", w.proxy:changed(), { 40 })
  w.light:report({ color = { x = 0.2, y = 0.2 } }, {})
  T.eq("a color with no mode is a full color", (toldColor(w) or {}).mode, FULL)
  w.restore()
end)

T.section("the first report on a connection seeds on and level from whichever control it is")
case(function()
  for _, control in ipairs({ "onOff", "level" }) do
    local w = world({ offline = true })
    w.light:declare(w.m.declaration())
    w.light:report({ on = true, level = 0.5 }, { control = control })
    T.eq(control .. ": told at its level", w.proxy.level, 50)
    w.restore()
  end
end)

T.section("settle: the first report on a connection is told at once, whatever was sent before it")
case(function()
  local w = world({ offline = true })
  w.light:declare(w.m.declaration())
  w.proxy:send("ON")
  w.light:report({ on = true, level = 0.4 }, {})
  T.eq("the proxy shows the device's level", w.proxy.level, 40)
  w.run(10000)
  w.restore()
end)

T.section("the first report on a connection seeds the proxy's level even when it is off, under either policy")
case(function()
  for _, policy in ipairs({ "settle", "trust" }) do
    local w = world({ policy = policy, offline = true })
    w.light:declare(w.m.declaration())
    w.light:report({ on = false, level = 0.3 }, {})
    T.eq(policy .. ": CHANGED 0", w.proxy:changed(), { 0 })
    w.restore()
  end
end)

T.section("a level alone, with no on, has a level verdict")
case(function()
  local w = world({}, 50)
  local v = w.light:report({ level = 0.5 }, { control = "level" })
  T.check("one is given", v.level ~= nil, T.show(v))
  w.restore()
end)

--------------------------------------------------------------------------------
-- The library's decisions
--------------------------------------------------------------------------------

-- The proxy's On Color and Dim Color as UPDATE_COLOR_ON_MODE names them: a preset, or Dim-To-Warm.
local RED = { x = 0.6, y = 0.3 }
local function onMode(w, on, dim)
  dim = dim or { id = 0, origin = 0 }
  w.proxy:send("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = on.id,
    COLOR_PRESET_ORIGIN = on.origin,
    COLOR_PRESET_COLOR_X = on.x,
    COLOR_PRESET_COLOR_Y = on.y,
    COLOR_PRESET_COLOR_MODE = on.mode or FULL,
    COLOR_FADE_PRESET_ID = dim.id,
    COLOR_FADE_PRESET_ORIGIN = dim.origin,
    COLOR_FADE_PRESET_COLOR_X = dim.x,
    COLOR_FADE_PRESET_COLOR_Y = dim.y,
    COLOR_FADE_PRESET_COLOR_MODE = dim.mode or FULL,
  })
end
local ON_PRESET = { id = 1, origin = 1, x = 0.6, y = 0.3 }
local WARM = { id = 1, origin = 1, x = 0.45, y = 0.41, mode = CCT }
local DIM = { id = 2, origin = 1, x = 0.53, y = 0.41, mode = CCT }

T.section("a stop of a rated on from off keeps the color it came on in, unless Dim-To-Warm moves it")
case(function()
  local w = world({}, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  local stop = w.m.sent[1] or {}
  T.eq("the stop sends the level alone", stop.color, nil)
  T.eq("at once", stop.ms, 0)
  w.run(10000)
  w.restore()
  w = world({}, 0)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.check(
    "with Dim-To-Warm the stop carries the stopped level's mix",
    (w.m.sent[1] or {}).color ~= nil,
    T.show(w.m.sent)
  )
  w.run(10000)
  w.restore()
end)

T.section("SET_COLOR_ON_MODE changes nothing: UPDATE_COLOR_ON_MODE's presets pick the mode")
case(function()
  local w = world({})
  onMode(w, ON_PRESET)
  local before = { persist:get("color_on_mode"), persist:get("color_on_mode_preset", false) }
  w.proxy:send("SET_COLOR_ON_MODE", { MODE = 2, PRESET_ID = 10 })
  T.eq(
    "nothing stored moves, and no color_on_mode_preset is written",
    { persist:get("color_on_mode"), persist:get("color_on_mode_preset", false) },
    before
  )
  w.restore()
end)

T.section("the on color is told at once in the preset it is, and the proxy's follow-up of it is not sent again")
case(function()
  local w = world({}, 0)
  onMode(w, ON_PRESET)
  w.proxy:appOn(80, { x = RED.x, y = RED.y, preset = 1, origin = 1 })
  local colors = w.proxy:told("LIGHT_COLOR_CHANGED")
  T.eq("the on color is told CHANGED at once, not as a fade from the color it went off in", #colors, 1)
  T.eq("as the device preset it is", (colors[1] or {}).LIGHT_COLOR_CURRENT_PRESET_ID, 1)
  T.eq("and no color CHANGING", w.proxy:told("LIGHT_COLOR_CHANGING"), {})
  w.run(100)
  T.eq("the follow-up within 250 ms sends nothing more: the pre-on and the ramp", #w.m.sent, 2)
  w.run(10000)
  T.eq("it lands", w.proxy.level, 80)
  w.restore()
end)

T.section("a color still fading at an off is told at the off, ahead of the level, and saved as the previous color")
case(function()
  local w = world({}, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 5000 }
  )
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("OFF")
  local said = w.proxy:said()
  T.eq(
    "the color's target, then the level",
    { said[1], said[#said] },
    { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }
  )
  local prev = persist:get("previous_color") or {}
  T.check("the previous color is the target", near(prev.x, 0.3) and near(prev.y, 0.6), T.show(prev))
  w.run(10000)
  T.eq("and the color ramp's end tells it no more", #w.proxy:told("LIGHT_COLOR_CHANGED"), 1)
  w.restore()
  -- The off drops the preset the color was asked in, so a stop of its ramp after the off names none.
  w = world({}, 80)
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.3,
    LIGHT_COLOR_TARGET_Y = 0.6,
    LIGHT_COLOR_TARGET_PRESET_ID = 5,
    LIGHT_COLOR_TARGET_COLOR_RATE = 5000,
  })
  w.run(1000)
  w.proxy:send("OFF")
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("SET_COLOR_STOP")
  local stops = w.proxy:told("LIGHT_COLOR_CHANGED")
  T.eq(
    "a stop of the ramp after the off names no preset",
    { #stops, (stops[1] or {}).LIGHT_COLOR_CURRENT_PRESET_ID },
    { 1 }
  )
  w.run(10000)
  w.restore()
end)

T.section(
  "via: an unbind tells the proxy only that the light is offline, its LEDs off; the bind tells nothing; "
    .. "its first report tells the rest, the LEDs always (T3 told offline at the bind too)"
)
case(function()
  --- The LED notifies since the mark.
  local function ledNotes(w)
    local n = 0
    for _, note in ipairs(w.proxy.notes) do
      n = n + (note.cmd == "MATCH_LED_STATE" and 1 or 0)
    end
    return n
  end
  -- Director binds the device binding at every controller start, where an off would run Off programming.
  for _, policy in ipairs({ "settle", "trust", "echo" }) do
    for _, how in ipairs({ "on", "off", "in a ramp" }) do
      local name = policy .. ", " .. how .. ": "
      local w = world({ policy = policy, via = 5002 }, how == "off" and 0 or 70)
      w.proxy:send(
        "SET_COLOR_TARGET",
        { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
      )
      w.run(10000)
      if how == "in a ramp" then
        w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 4000 })
        w.run(1000)
      end
      local prev = persist:get("previous_color")
      w.proxy:mark()
      w.m.unbind()
      w.m.bind()
      T.eq(name .. "an unbind and a bind tell the proxy offline once", w.proxy:said(), { "ONLINE_CHANGED" })
      T.eq(name .. "and no level and no color", w.proxy.online, false)
      T.eq(name .. "with the LEDs off", w.proxy.leds[H.LINKS.top] == true, false)
      w.proxy:mark()
      -- The device's report as its own ramp lands, else its snapshot, is the first.
      w.run(10000)
      if not w.proxy.online then
        w.m.connect()
      end
      local level = how == "off" and 0 or how == "on" and 70 or 20
      local levels = w.proxy:changed()
      T.eq(name .. "its first report tells the level the light is at", levels[#levels], level)
      T.check(name .. "and its color", near(toldColor(w).x, 0.3) and near(toldColor(w).y, 0.6), T.show(toldColor(w)))
      T.eq(name .. "with its LEDs, which a bind left unknown", { w.proxy.leds[H.LINKS.top] == true, ledNotes(w) }, {
        level > 0,
        3,
      })
      T.eq(name .. "and no Previous Color is written", persist:get("previous_color"), prev)
      w.restore()
    end
    -- A light found off at its first report after the bind is told off then, with its LEDs.
    local w = world({ policy = policy, via = 5002 }, 70)
    w.m.unbind()
    w.m.other({ on = false })
    w.m.bind()
    w.proxy:mark()
    w.run(10000)
    T.eq(policy .. ": a light found off is told off at its first report", w.proxy:changed(), { 0 })
    T.eq(policy .. ": with its LEDs", { w.proxy.leds[H.LINKS.top], w.proxy.leds[H.LINKS.bottom] }, { false, true })
    w.restore()
  end
  -- A direct light whose device is replaced is forgotten: offline once, its color D65 in CCT again.
  local w = world({}, 70)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.proxy:mark()
  w.light:forget()
  T.eq("forget: the proxy is told offline once", w.proxy:said(), { "ONLINE_CHANGED" })
  local told = w.light.told
  T.check("forget: its color is D65 in CCT again", near(told.x, 0.3127) and told.mode == CCT, T.show(told))
  w.restore()
end)

T.section("under settle, a report from before a newer command is held, and never shown over it")
case(function()
  local w = world({ latency = 300 }, 10)
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.run(100)
  w.proxy:mark()
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.run(10000)
  T.eq("the proxy is told 70 and nothing else", w.proxy:changed(), { 70 })
  T.eq("which the device is at", w.devicePercent(), 70)
  w.restore()
end)

T.section("a stop near off under a raised Min holds at the Min, or goes off under half way")
case(function()
  local function stopAt(ms)
    local w = world({}, 0)
    w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 30 })
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 10000 })
    w.run(ms)
    w.proxy:mark()
    w.proxy:send("SET_BRIGHTNESS_STOP")
    w.run(10000)
    local out = { told = w.proxy:changed()[1], device = w.devicePercent() }
    w.restore()
    return out
  end
  T.eq("past half way to the Min's place it holds at the Min", stopAt(3000), { told = 1, device = 1 })
  T.eq("under it, it goes off", stopAt(1000), { told = 0, device = 0 })
end)

T.section("the setup's on modes are stored before its presets, and its rates last")
case(function()
  forget()
  local order = {}
  local set = persist.set
  persist.set = function(self, key, ...)
    order[#order + 1] = key
    return set(self, key, ...)
  end
  local w = H.world({
    dims = true,
    policy = "settle",
    settleMs = 2000,
    setup = H.setupFile("setup-607.xml"),
    offline = true,
  })
  persist.set = set
  local first = {}
  for _, key in ipairs(order) do
    if not first[key] then
      first[key] = #first + 1
      first[#first + 1] = key
    end
  end
  T.check(
    "color mode, brightness mode, presets, then the rates",
    first.color_on_mode < first.brightness_on_mode
      and first.brightness_on_mode < first.brightness_presets
      and first.brightness_presets < first.brightness_rate_default,
    T.show(order)
  )
  w.restore()
end)

T.section("a color ramp the controller's clock steps back across is at its start, as a level ramp is")
case(function()
  local w = world({}, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = RED.x, LIGHT_COLOR_TARGET_Y = RED.y, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(5000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  ShimSetClock(function()
    return w.clock.now() - 5000
  end)
  w.proxy:send("SET_COLOR_STOP")
  ShimSetClock(function()
    return w.clock.now()
  end)
  local told = toldColor(w) or {}
  T.check("the stop holds the color it started from", near(told.x, RED.x) and near(told.y, RED.y), T.show(told))
  w.run(10000)
  w.restore()
end)

T.section("a stop part way from a color to a white tells and sends the color it has got to")
case(function()
  local w = world({}, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = RED.x, LIGHT_COLOR_TARGET_Y = RED.y, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(5000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 2700, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(2000)
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("SET_COLOR_STOP")
  local stop = (w.m.sent[1] or {}).color or {}
  local told = toldColor(w) or {}
  T.eq("the stop goes as a full color", { stop.mode, stop.kelvin }, { FULL, nil })
  T.eq("and is told in mode 0", told.mode, FULL)
  local wx, wy = C4:ColorCCTtoXY(2700)
  T.check(
    "half way along the line",
    near(told.x, (RED.x + wx) / 2, 0.01) and near(told.y, (RED.y + wy) / 2, 0.01),
    T.show(told)
  )
  w.run(10000)
  T.eq("the light holds it", deviceColor(w).mode, FULL)
  w.restore()
  -- Under Dim-To-Warm a fade to off carries on the white a level ramp from the color was taking.
  w = world({}, 20)
  onMode(w, WARM, DIM)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = RED.x, LIGHT_COLOR_TARGET_Y = RED.y, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 8000 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_COLOR_STOP")
  stop = (w.m.sent[1] or {}).color or {}
  told = toldColor(w) or {}
  T.eq("a stop of that carried color goes and is told as a full color too", { stop.mode, told.mode }, { FULL, FULL })
  T.check("part way from the color", told.x ~= nil and told.x < RED.x - 0.01, T.show(told))
  w.run(10000)
  w.restore()
end)

T.section("a setting deleted under a live light reads as its default the next time")
case(function()
  local w = world({}, 0)
  w.proxy:send("SET_CLICK_RATE_UP", { RATE = 2000 })
  persist:delete("click_rate_up")
  w.m.sent = {}
  w.proxy:send("DO_CLICK")
  RFP.DO_CLICK(H.LINKS.top, "DO_CLICK", {}, {})
  local ramp = w.m.sent[#w.m.sent] or {}
  T.eq("a click goes at the default click rate", ramp.ms, 500)
  w.run(10000)
  w.restore()
end)

--- The steps of a scene, as the proxy pushes them.
local function scene(w, id, steps, flash)
  local xml = {}
  for _, s in ipairs(steps) do
    local parts = { "<element>", "<delay>" .. (s.delay or 0) .. "</delay>" }
    if s.level then
      parts[#parts + 1] = "<brightnessEnabled>True</brightnessEnabled><brightness>" .. s.level .. "</brightness>"
      parts[#parts + 1] = "<brightnessRate>" .. (s.rate or 0) .. "</brightnessRate>"
    end
    if s.color then
      parts[#parts + 1] = "<colorEnabled>True</colorEnabled><colorX>"
        .. s.color.x
        .. "</colorX><colorY>"
        .. s.color.y
        .. "</colorY>"
      parts[#parts + 1] = "<colorMode>"
        .. (s.color.mode or 0)
        .. "</colorMode><colorRate>"
        .. (s.rate or 0)
        .. "</colorRate>"
    end
    parts[#parts + 1] = "</element>"
    xml[#xml + 1] = table.concat(parts)
  end
  w.proxy:send(
    "PUSH_SCENE",
    { SCENE_ID = id, ELEMENTS = table.concat(xml), FLASH = flash and "True" or "False", FROM_GROUP = "True" }
  )
end

T.section("scene progress stays on the instance, with no SceneRamp timer; fromGroup is stored as given")
case(function()
  local w = world({}, 0)
  scene(w, 3, { { level = 40, rate = 1000 }, { level = 80, rate = 1000 }, { level = 20, rate = 1000 } })
  T.eq("fromGroup is stored as given", (persist:get("scenes")["3"] or {}).fromGroup, true)
  local writes = 0
  local set = persist.set
  persist.set = function(self, key, ...)
    if key == "scenes" then
      writes = writes + 1
    end
    return set(self, key, ...)
  end
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 3 })
  local timers = {}
  for name in pairs(Timer) do
    timers[#timers + 1] = tostring(name)
  end
  w.run(5000)
  persist.set = set
  T.eq("its three steps write nothing to the store", writes, 0)
  T.check(
    "and its timer is the scene's own",
    Timer["SceneRamp"] == nil and table.concat(timers, ","):find("Light.Scene.3", 1, true) ~= nil,
    table.concat(timers, ",")
  )
  T.eq("the scene ran to its last step", w.proxy.level, 20)
  w.restore()
end)

T.section("a color for a light that is off or fading to off goes with on = false, at its own rate")
case(function()
  local w = world({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
  )
  local c = w.m.sent[1] or {}
  T.eq("off: set the color and leave it off", { c.on, c.ms }, { false, 2000 })
  T.eq("told CHANGING", #w.proxy:told("LIGHT_COLOR_CHANGING"), 1)
  w.run(2100)
  T.eq("then CHANGED when the rate has passed", #w.proxy:told("LIGHT_COLOR_CHANGED"), 1)
  T.eq("and the light stays off", w.devicePercent(), 0)
  w.restore()
  w = world({}, 100)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 750 }
  )
  T.eq("fading to off: on = false too, so the fade goes on to off", (w.m.sent[1] or {}).on, false)
  w.run(10000)
  T.eq("and it does", w.devicePercent(), 0)
  w.restore()
end)

T.section("a white on a light with color and no cct goes as the full color of its point, in mode 0")
case(function()
  forget()
  local w =
    H.world({ dims = true, color = true, levelSteps = 254, keepsLevel = true, policy = "settle", settleMs = 2500 })
  onMode(w, { id = 10, origin = 1 })
  -- The device's first report is D65 in mode 1, so the light goes off in a white.
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(10000)
  w.proxy:send("OFF")
  w.run(10000)
  T.eq("the color it went off in is a white", (persist:get("previous_color") or {}).mode, CCT)
  w.m.sent = {}
  w.proxy:send("ON")
  local color = (w.m.sent[1] or {}).color or {}
  T.eq("Previous sends it with no kelvin", color.kelvin, nil)
  T.eq("so in mode 0, as its xy", color.mode, FULL)
  w.run(10000)
  w.restore()
end)

T.section("a kelvin outside the light's cct range goes as asked, for now")
case(function()
  local w = world({}, 60)
  for _, asked in ipairs({ 1800, 9000 }) do
    w.m.sent = {}
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = asked, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
    local kelvin = ((w.m.sent[1] or {}).color or {}).kelvin
    T.check(asked .. " K goes at " .. asked .. " K", kelvin ~= nil and math.abs(kelvin - asked) <= asked * 0.01, kelvin)
    w.run(10000)
  end
  w.restore()
end)

T.section("settle: a clamp whose reads are all lost shows the device's own report once the window ends")
case(function()
  local w = world({
    drop = function(kind)
      return kind == "read"
    end,
  }, 20)
  local take = w.device.take
  w.device.take = function(self, cmd, now)
    if cmd.level and cmd.level > 0.9 then
      cmd = H.copy(cmd)
      cmd.level = 0.9
    end
    return take(self, cmd, now)
  end
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(1000)
  T.eq("in the window the proxy keeps the target", w.proxy.level, 100)
  w.run(10000)
  T.eq("its end shows the device's report", w.proxy.level, 90)
  w.restore()
end)

T.section(
  "settle: a report overtaken by a later one, and a stall's reports that come again, show the light where it is"
)
case(function()
  local w = world({
    delay = function(_, control)
      return control == "level" and 700 or 0
    end,
  }, 20)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(200)
  w.proxy:send("SET_LEVEL", { LEVEL = 35 })
  w.run(10000)
  T.eq("the proxy ends where the device is", { w.proxy.level, w.devicePercent() }, { 35, 35 })
  w.restore()
  w = held({ hold = true }, 50)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 2000 })
  w.m.stall(w.clock.now() + 8000, 3)
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 25 })
  w.run(20000)
  T.eq("after the stall it lands on the newest", { w.proxy.level, w.devicePercent() }, { 25, 25 })
  w.restore()
end)

T.section("settle: the verdict per aspect, against the newest command of each")
case(function()
  local w = world({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  local v = w.light:report({ on = true, level = 0.4 }, { control = "level" })
  T.eq("a level on the ramp's path before its landing is own", v.level.kind, "own")
  T.eq("and names the command", v.level.seq, (w.m.sent[#w.m.sent] or {}).seq)
  v = w.light:report({ on = false, level = 0.4 }, { control = "onOff" })
  T.eq("an off against a command that lights it is another hand's", v.level.kind, "hand")
  w.run(10000)
  v = w.light:report({ on = true, level = 0.8, color = { x = 0.5, y = 0.2 } }, { control = "color" })
  T.eq("a color no command set is another hand's", v.color.kind, "hand")
  w.restore()
  w = world({ offline = true })
  w.light:declare(w.m.declaration())
  v = w.light:report({ on = true, level = 0.5 }, {})
  T.eq("the first report on a connection is first", v.level.kind, "first")
  w.restore()
end)

T.section("a stop near off under a raised Min holds at the Min itself")
case(function()
  local w = world({}, 0)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 30 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 10000 })
  w.run(3000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.check("the stop is sent at the Min's brightness", near((w.m.sent[1] or {}).level, 0.3), T.show(w.m.sent))
  w.run(10000)
  w.restore()
end)

T.section("the on color's dedupe holds 250 ms, for that color, and in its own preset")
case(function()
  local function on(w)
    onMode(w, ON_PRESET)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 750 })
  end
  local function color(w, x, y, preset)
    w.proxy:send("SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_X = x,
      LIGHT_COLOR_TARGET_Y = y,
      LIGHT_COLOR_TARGET_PRESET_ID = preset,
      LIGHT_COLOR_TARGET_COLOR_RATE = 750,
    })
  end
  local w = world({}, 0)
  on(w)
  w.run(300)
  w.m.sent = {}
  color(w, RED.x, RED.y, 1)
  T.eq("the on color after the window is a color command", #w.m.sent, 1)
  w.run(10000)
  w.restore()
  w = world({}, 0)
  on(w)
  w.run(20)
  w.m.sent = {}
  color(w, 0.3, 0.5)
  T.eq("another color in the window is one", #w.m.sent, 1)
  color(w, RED.x, RED.y, 1)
  T.eq("and the on color after it is news", #w.m.sent, 2)
  w.run(10000)
  w.restore()
  w = world({}, 0)
  on(w)
  w.proxy:mark()
  color(w, RED.x, RED.y, 1)
  T.eq("the follow-up in the on color's own preset tells nothing", #w.proxy:told("LIGHT_COLOR_CHANGED"), 0)
  color(w, RED.x, RED.y, 2)
  T.eq(
    "one naming another preset is told",
    (w.proxy:told("LIGHT_COLOR_CHANGED")[1] or {}).LIGHT_COLOR_CURRENT_PRESET_ID,
    2
  )
  w.run(10000)
  w.restore()
end)

T.section("Previous On: the level to keep is told once, at an off early in a rated on from off, and only then")
case(function()
  local w = world({}, 60)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(10000)
  w.proxy:mark()
  w.proxy:send("OFF")
  T.eq("an off after the on has landed tells no level to keep", w.proxy:told("LIGHT_BRIGHTNESS_CHANGING"), {})
  w.run(10000)
  w.proxy:send("SET_LEVEL", { LEVEL = 1 })
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 5000 })
  w.run(100)
  w.proxy:mark()
  w.proxy:send("OFF")
  T.eq("nor one early in a ramp up from 1, which was lit", w.proxy:told("LIGHT_BRIGHTNESS_CHANGING"), {})
  w.run(10000)
  w.restore()
end)

T.section("a white the controller gives no color temperature for is no color, sent or asked")
case(function()
  local w = world({}, 50)
  local toCCT = C4.ColorXYtoCCT
  local odd = { x = 0.2, y = 0.6 }
  C4.ColorXYtoCCT = function(self, x, y)
    if math.abs(x - odd.x) < 1e-6 and math.abs(y - odd.y) < 1e-6 then
      return 0
    end
    return toCCT(self, x, y)
  end
  w.m.sent = {}
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = odd.x,
    LIGHT_COLOR_TARGET_Y = odd.y,
    LIGHT_COLOR_TARGET_MODE = CCT,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq("asked as a white, it is ignored", #w.m.sent, 0)
  onMode(w, { id = 1, origin = 1, x = odd.x, y = odd.y, mode = CCT })
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("ON")
  T.eq("an on in it goes with no color", (w.m.sent[#w.m.sent] or {}).color, nil)
  C4.ColorXYtoCCT = toCCT
  w.run(10000)
  w.restore()
end)

T.section("a pre-on lights the light in its on color, and a light at 1 that rises takes neither")
case(function()
  local w = world({}, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  local pre = w.m.sent[1] or {}
  T.check("the pre-on carries the on color", pre.preOn and pre.color and near(pre.color.x, RED.x), T.show(pre))
  w.run(10000)
  w.restore()
  w = world({}, 1)
  onMode(w, ON_PRESET)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  local ramp = w.m.sent[1] or {}
  T.check(
    "a light at 1 is lit: its ramp goes alone, in no on color",
    #w.m.sent == 1 and not ramp.preOn and ramp.color == nil,
    T.show(w.m.sent)
  )
  w.run(10000)
  w.restore()
end)

T.section("Previous On: an off part way up keeps the level the ramp had got to; a Previous On of 0 is no level to keep")
case(function()
  local w = world({}, 60)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("OFF")
  local keep = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.eq("the level to keep is where the first ramp had got to", keep.LIGHT_BRIGHTNESS_CURRENT, 25)
  w.run(10000)
  w.restore()
  w = world({}, 60)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 6000 })
  w.run(100)
  w.proxy:mark()
  w.proxy:send("OFF")
  keep = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.eq(
    "with the ramp at 1, 1 is the level to keep",
    { keep.LIGHT_BRIGHTNESS_CURRENT, keep.LIGHT_BRIGHTNESS_TARGET },
    { 1, 0 }
  )
  w.run(10000)
  w.restore()
  w = world({}, 0)
  w.proxy:send("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = 0 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(10)
  w.proxy:mark()
  w.proxy:send("OFF")
  T.eq("an off before it is lit tells no CHANGING", w.proxy:told("LIGHT_BRIGHTNESS_CHANGING"), {})
  w.run(10000)
  w.restore()
end)

T.section("the proxy's follow-up within 50 ms is the on color already sent")
case(function()
  local w = world({}, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 750 })
  w.run(50)
  w.m.sent = {}
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = RED.x,
    LIGHT_COLOR_TARGET_Y = RED.y,
    LIGHT_COLOR_TARGET_PRESET_ID = 1,
    LIGHT_COLOR_TARGET_COLOR_RATE = 750,
  })
  T.eq("nothing is sent", #w.m.sent, 0)
  w.run(10000)
  w.restore()
end)

--------------------------------------------------------------------------------
-- A light that does not fade
--------------------------------------------------------------------------------

T.section("fade none, a light that dims: every change goes at once, told as CHANGED only")
case(function()
  local w = world({ fade = "none", keepsLevel = false }, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 5000 })
  T.eq("a rated level goes at once", (w.m.sent[1] or {}).ms, 0)
  T.eq("no CHANGING", w.proxy:told("LIGHT_BRIGHTNESS_CHANGING"), {})
  T.eq("CHANGED at once", w.proxy:changed(), { 80 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 3000 }
  )
  T.eq("a color at once too", (w.m.sent[2] or {}).ms, 0)
  T.eq("told CHANGED", #w.proxy:told("LIGHT_COLOR_CHANGED"), 1)
  T.eq("with no pre-on: the light does not keep a level to dip", w.m.declaration().fade.preOn, nil)
  w.run(10000)
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.proxy:send("SET_COLOR_STOP")
  T.eq("a stop sends nothing", #w.m.sent, 0)
  T.eq("and tells nothing", #w.proxy.notes, 0)
  T.eq(
    "which the capabilities hide",
    { w.proxy.caps.supports_brightness_stop, w.proxy.caps.supports_color_stop },
    { false, false }
  )
  RFP.DO_PUSH(H.LINKS.top, "DO_PUSH", {}, {})
  T.eq("a hold goes to its end at the press", w.proxy:changed(), { 100 })
  w.m.sent = {}
  RFP.DO_RELEASE(H.LINKS.top, "DO_RELEASE", {}, {})
  T.eq("and its release sends nothing", #w.m.sent, 0)
  w.run(10000)
  w.restore()
end)

T.section("fade none, a relay: an On goes with no ms, and a scene step keeps its rate for now")
case(function()
  local w = world({ dims = false, color = false, cct = false, fade = "none", keepsLevel = false })
  T.eq("a relay declares no dimming", w.proxy.caps.dimmer, false)
  w.proxy:send("ON")
  T.eq("an On switches it", { (w.m.sent[1] or {}).on, (w.m.sent[1] or {}).ms }, { true, nil })
  T.eq("told 100", w.proxy:changed()[#w.proxy:changed()], 100)
  w.run(10000)
  scene(w, 5, { { level = 0, rate = 2000 } })
  w.m.sent = {}
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 5 })
  T.eq("a scene step keeps its rate", (w.m.sent[1] or {}).ms, 2000)
  w.run(10000)
  T.eq("and switches it off", w.devicePercent(), 0)
  w.restore()
end)

T.section("fade none: a light that does not dim keeps its color's rate, which MemoryLight fades it over")
case(function()
  local w = world({ dims = false, fade = "none", keepsLevel = false }, 100)
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
  )
  T.eq("the color goes over its rate", (w.m.sent[1] or {}).ms, 2000)
  w.run(1000)
  local c = deviceColor(w)
  T.check("half way through it the light is part way", c.x > 0.35 and c.x < 0.55, T.show(c))
  w.run(10000)
  w.restore()
end)

T.section("a color relay: a scene step that turns it on goes as an on with the step's color and rate")
case(function()
  local w = world({ dims = false }, 0)
  scene(w, 7, { { level = 100, rate = 1000, color = { x = 0.3, y = 0.6 } } })
  w.m.sent = {}
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
  local step = w.m.sent[1] or {}
  T.eq(
    "an on, no level, the step's color and its rate",
    { #w.m.sent, step.on, step.level, step.color and step.color.x, step.ms },
    { 1, true, nil, 0.3, 1000 }
  )
  w.run(10000)
  T.eq(
    "so the relay is on in it",
    { w.proxy.level, w.devicePercent(), near(deviceColor(w).x, 0.3) },
    { 100, 100, true }
  )
  w.restore()
end)

--------------------------------------------------------------------------------
-- trust
--------------------------------------------------------------------------------

T.section("trust: MemoryLight answers a read with its whole state, with no control or answer, which are settle's")
case(function()
  local w = world({ policy = "trust" }, 40)
  local before = #w.m.reports
  w.m.adapter:refresh()
  w.run(1000)
  local metas = {}
  for i = before + 1, #w.m.reports do
    metas[#metas + 1] = w.m.reports[i].meta
  end
  T.eq("one whole report", metas, { {} })
  w.restore()
end)

T.section("trust: a report of a ramp's own aspect is ignored in the ramp, and told after it when it differs")
case(function()
  local w = world({ policy = "trust", keepsLevel = false }, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.m.other({ on = true, level = 0.5 })
  w.run(500)
  T.eq("in the ramp a report of its level tells nothing", w.proxy:changed(), {})
  w.run(5000)
  T.eq("the ramp tells its end", w.proxy:changed()[1], 80)
  w.m.other({ on = true, level = 0.55 })
  w.run(500)
  T.eq("outside a ramp a level that differs is told", w.proxy.level, 55)
  local before = #w.proxy:changed()
  w.m.push({ on = true, level = 0.55 }, {})
  w.run(500)
  T.eq("and the same level again tells nothing", #w.proxy:changed(), before)
  T.eq("its verdict is own: under trust with ack = send nothing is history", w.m.lastVerdict.level.kind, "own")
  w.restore()
end)

T.section("trust: a report of a color ramp's color is ignored in the ramp, and told after it when it differs")
case(function()
  local w = world({ policy = "trust", keepsLevel = false }, 60)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.m.other({ color = { x = 0.2, y = 0.2 } })
  w.run(500)
  T.eq("in the ramp a report of its color tells nothing", toldColors(w), {})
  w.run(5000)
  T.eq("the ramp tells its end", toldColors(w), { { x = 0.3, y = 0.5 } })
  w.m.other({ color = { x = 0.25, y = 0.25 } })
  w.run(500)
  T.check("outside a ramp a color that differs is told", near(toldColor(w).x, 0.25), T.show(toldColor(w)))
  w.restore()
end)

T.section("trust: an on from off in its on color is told once, from the push its device gives once the command is in")
case(function()
  for _, ack in ipairs({ "send", "done" }) do
    local w = world({ policy = "trust", ack = ack }, 30)
    onMode(w, ON_PRESET)
    w.proxy:send("OFF")
    w.run(10000)
    w.proxy:mark()
    w.proxy:send("ON")
    w.run(10000)
    T.eq(ack .. ": the level is told 100 and nothing else", w.proxy:changed(), { 100 })
    w.restore()
  end
end)

T.section("trust: a command sent since the device's word is where the light heads, not outside the range")
case(function()
  -- The pre-on's report is the device's word, at the floor, when a stop and a press follow at once.
  local w = world({ policy = "trust" }, 0)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 750 })
  w.run(700)
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.proxy:send("BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 1 })
  w.run(110)
  w.proxy:send("BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 2 })
  w.run(60)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 1, RATE = 2000 })
  local changing = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.check(
    "a ramp then starts where the click's ramp from the stop has the light",
    (changing.LIGHT_BRIGHTNESS_CURRENT or 0) >= 25,
    T.show(changing)
  )
  w.run(10000)
  w.restore()
end)

T.section("trust: news heard before the newest command's word is history, so it ends no ramp")
case(function()
  local w = held({ policy = "trust", news = true, keepsLevel = false }, 100)
  w.m.stall(w.clock.now() + 5000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 3000 })
  w.run(500)
  w.m.other({ color = { x = 0.3, y = 0.5 } })
  w.run(500)
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.run(10000)
  local at = w.devicePercent()
  T.check("a stop after it still holds the light part way", at > 35 and at < 95, at)
  T.eq("where the proxy shows it", w.proxy.level, at)
  w.restore()
end)

T.section("trust: news from the adapter ends the ramp and is told at once")
case(function()
  local w = world({ policy = "trust", news = true, keepsLevel = false }, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.m.other({ on = true, level = 0.3 })
  w.run(200)
  T.eq("told at once", w.proxy:changed(), { 30 })
  T.eq("as another hand's", w.m.lastVerdict.level.kind, "hand")
  T.eq("the ramp is over", w.light.aim.level, nil)
  w.run(5000)
  T.eq("so its end tells nothing", w.proxy:changed(), { 30 })
  w.restore()
end)

T.section("trust: a light that has reported no level keeps the level told when the range moves")
case(function()
  local w = world({
    policy = "trust",
    offline = true,
    drop = function(kind)
      return kind == "report"
    end,
  })
  w.light:declare(w.m.declaration())
  w.light:report({ color = { x = 0.3, y = 0.3 } }, {})
  T.eq("a first report of a color alone tells no level", w.proxy:changed(), {})
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  w.proxy:mark()
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 20 })
  T.eq("the proxy is told no level", w.proxy:changed(), {})
  w.restore()
end)

T.section("another hand's color is told with no preset id")
case(function()
  local w = world({}, 60)
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.3,
    LIGHT_COLOR_TARGET_Y = 0.5,
    LIGHT_COLOR_TARGET_PRESET_ID = 3,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  w.run(10000)
  w.proxy:mark()
  w.m.other({ color = { x = 0.2, y = 0.2 } })
  w.run(200)
  local told = w.proxy:told("LIGHT_COLOR_CHANGED")
  T.eq("its CHANGED names no preset", #told == 1 and (told[1].LIGHT_COLOR_CURRENT_PRESET_ID or "none"), "none")
  w.restore()
end)

T.section("a white light with no color takes another hand's color temperature, under either policy")
case(function()
  for _, policy in ipairs({ "settle", "trust" }) do
    local w = world({ color = false, policy = policy, keepsLevel = false }, 60)
    local x, y = C4:ColorCCTtoXY(2700)
    w.m.other({ color = { x = x, y = y, mode = CCT } })
    w.run(200)
    T.check(policy .. ": told", near((toldColor(w) or {}).x, x), T.show(toldColor(w)))
    w.restore()
  end
end)

T.section("trust: news ends the ramp of each aspect it carries, and only those, and is told even unchanged")
case(function()
  -- The device's own reports are lost: the news is reported by hand.
  local function trust(level)
    return world({
      policy = "trust",
      keepsLevel = false,
      drop = function(kind)
        return kind == "report"
      end,
    }, level)
  end
  local w = trust(20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.light:report({ color = { x = 0.2, y = 0.2 } }, { news = true })
  T.check("a color's news leaves the level ramp running", w.light.aim.level ~= nil)
  w.light:report({ on = true, level = 0.2 }, { news = true })
  T.eq("a level's news at the level the ramp started from is told", w.proxy:changed(), { 20 })
  w.run(5000)
  T.eq("and the ramp is over", w.proxy:changed(), { 20 })
  w.proxy:mark()
  w.light:report({ on = true, level = 0.2 }, { news = true })
  T.eq("with no ramp, news of the level told tells nothing", w.proxy:changed(), {})
  w.restore()
  w = trust(60)
  local function ramp()
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
    )
    w.run(1000)
  end
  ramp()
  w.light:report({ on = true, level = 0.6 }, { news = true })
  T.check("a level's news leaves the color ramp running", w.light.aim.color ~= nil)
  w.proxy:mark()
  local start = w.light.told
  w.light:report({ color = { x = start.x, y = start.y, mode = start.mode } }, { news = true })
  T.eq("a color's news is told, even at the color the ramp left", #toldColors(w), 1)
  w.run(5000)
  T.eq("and the ramp is over: its end tells nothing", #toldColors(w), 1)
  w.proxy:mark()
  w.light:report({ color = { x = start.x, y = start.y, mode = start.mode } }, { news = true })
  T.eq("with no ramp, news of the color told tells nothing", toldColors(w), {})
  w.restore()
  w = trust(20)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.light:report({ color = { x = 0.2, y = 0.2 } }, { news = true })
  T.eq("under Dim-To-Warm a color's news is told in the level's ramp", #toldColors(w), 1)
  w.run(5000)
  T.check("whose end no longer tells its mix", near((toldColor(w) or {}).x, 0.2), T.show(toldColor(w)))
  w.restore()
end)

T.section("a level within the device's step of the one told tells nothing, under either policy")
case(function()
  for _, policy in ipairs({ "settle", "trust" }) do
    local w = world({ policy = policy, keepsLevel = false, levelSteps = 100 }, 50)
    w.proxy:mark()
    w.m.other({ on = true, level = 0.51 })
    w.run(500)
    T.eq(policy .. ": 51 against 50 on 100 steps", w.proxy:changed(), {})
    w.restore()
  end
end)

--------------------------------------------------------------------------------
-- settle
--------------------------------------------------------------------------------

T.section("settle: a level the device clamps shows at the read-back's final answer")
case(function()
  local w = world({}, 20)
  local take = w.device.take
  w.device.take = function(self, cmd, now)
    if cmd.level and cmd.level > 0.9 then
      cmd = H.copy(cmd)
      cmd.level = 0.9
    end
    return take(self, cmd, now)
  end
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("the proxy is told the target at once", w.proxy.level, 100)
  w.run(10000)
  T.eq("and the clamp once the device is read", w.proxy.level, 90)
  T.eq("where the device is", w.devicePercent(), 90)
  w.restore()
end)

T.section("settle: an OnOff answer alone does not settle a dimmed target; the level's answer does")
case(function()
  -- The landing's report comes after the read-back, so the last level reported is part way.
  local w = world({ reportLag = 3000 }, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
  w.run(15000)
  T.eq("the proxy is told 80 and nothing else", w.proxy:changed(), { 80 })
  w.restore()
end)

T.section("settle: MemoryLight's late report tells the light as it is when it lands, not as it was when it left")
case(function()
  -- The Off's report lands after the rated on's answers: as it was when it left, it would say off.
  local w = world({ reportLag = 3000, keepsLevel = false }, 20)
  w.proxy:send("OFF")
  w.run(100)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 500 })
  w.run(15000)
  T.eq("the proxy ends where the device is", { w.proxy.level, w.devicePercent() }, { 50, 50 })
  w.restore()
end)

T.section("settle: a level heard while the light is off is the level it keeps, which confirms no dimmed target")
case(function()
  -- An off and a rated on from off at once: the device reports the off with the level it keeps, then the pre-on.
  local w = world({ latency = 40 }, 100)
  w.proxy:send("OFF")
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
  w.proxy:mark()
  w.run(500)
  T.eq("the ramp's start does not end it", w.proxy:changed(), {})
  w.run(10000)
  T.eq("its end comes with the light", { w.proxy.level, w.devicePercent() }, { 100, 100 })
  w.restore()
end)

T.section("settle: another hand's turn-on heard in an off's window is read for its level")
case(function()
  -- A scene's off to a light already off: the device says nothing, so its window stays open, and a color
  -- put its read-back off past it.
  local w = world({ settleMs = 880, readbackMs = 500 }, 50)
  w.proxy:send("OFF")
  w.run(10000)
  scene(w, 6, { { level = 0 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 6 })
  w.run(100)
  w.proxy:mark()
  w.m.other({ on = true, level = 0.71 }, true)
  w.run(300)
  w.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5 })
  w.run(10000)
  T.eq("the proxy is told the level another hand left", w.proxy:changed(), { 71 })
  w.restore()
end)

T.section("settle: another hand's turn-on is read, and a color that goes while that read is under way asks it again")
case(function()
  local w = held({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  -- Its level unreported; the stop's color waits for the ramp's word and goes after the read.
  w.proxy:mark()
  w.m.other({ on = true, level = 0.82 }, true)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 5000 }
  )
  w.proxy:send("SET_COLOR_STOP")
  w.run(20000)
  T.eq("the proxy is told only the level another hand left", w.proxy:changed(), { 82 })
  w.restore()
end)

T.section("settle: a light on at 0 is on its way up from off, which confirms no dimmed target")
case(function()
  local w = world({ keepsLevel = false }, 0)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 5 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("RAMP_TO_LEVEL", { LEVEL = 1, TIME = 750 })
  w.run(300)
  T.eq("the ramp's start does not end it", w.proxy:changed(), {})
  w.run(10000)
  T.eq("its end comes with the light", { w.proxy.level, w.devicePercent() }, { 1, 1 })
  w.restore()
end)

T.section("settle: MemoryLight drops the answer to a read that left before a command, and answers one asked after it")
case(function()
  -- Its read-back of the level leaves just before the rated off, so its answer is of the light before it.
  local w = world({ latency = 120 }, 0)
  w.proxy:send("SET_LEVEL", { LEVEL = 85 })
  w.run(1550)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 3000 })
  w.run(950)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.run(10000)
  local at = w.devicePercent()
  T.check(
    "the answer settles nothing of the off, so its stop holds the light part way",
    #w.m.sent == 1 and at > 20 and at < 80,
    T.show({ sent = #w.m.sent, at = at })
  )
  w.restore()
  -- A color sent while another hand's turn-on is unread asks the read again, straight after it.
  w = world({ keepsLevel = false }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.other({ on = true, level = 0.7 }, true)
  w.run(60)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  T.eq("a read asked straight after a command is answered after it", { w.proxy.level, w.devicePercent() }, { 70, 70 })
  w.restore()
  -- A read asked just before a command, at the same instant, is answered before it.
  w = world({}, 80)
  w.m.adapter:refresh()
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  w.run(10000)
  T.eq("so its answer is dropped, and the proxy is told only the off", w.proxy:changed(), { 0 })
  w.restore()
  -- A read-back while a command sent before it is still queued to the device is no answer after it.
  w = held({}, 50)
  w.m.stall(w.clock.now() + 20000, 0)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 250 }
  )
  w.run(10)
  w.proxy:send("OFF")
  w.proxy:mark()
  w.run(10000)
  T.eq("a color's read-back with the off still queued is dropped", w.proxy:changed(), {})
  w.run(30000)
  T.eq("and the off lands", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
end)

T.section("settle: MemoryLight off reports the level its level control holds, the last it was lit at")
case(function()
  local w = world({ keepsLevel = false }, 60)
  w.proxy:send("OFF")
  w.run(10000)
  local st = w.m.device:report(w.clock.now())
  T.check(
    "off, at the level it went off at, on its own steps",
    st.on == false and near(st.level, 0.6, 0.005),
    T.show(st)
  )
  w.restore()
end)

T.section("settle: MemoryLight reports the color a transition ends in")
case(function()
  local w = world({}, 60)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
  )
  w.m.reports = {}
  w.run(2100)
  local last
  for _, r in ipairs(w.m.reports) do
    if r.meta.control == "color" and not r.meta.answer then
      last = r.state.color
    end
  end
  T.check("its last color report is the target", near((last or {}).x, 0.3), T.show(last))
  w.restore()
end)

T.section("settle: an answer in a color's own transition is no final word on it, so another hand's color shows")
case(function()
  local w = world({}, 60)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 6000 }
  )
  w.run(1000)
  w.m.other({ color = { x = 0.6, y = 0.3 } })
  w.run(200)
  -- The level's read-back answers final in the color's transition.
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.run(20000)
  local c = deviceColor(w)
  T.check(
    "the proxy shows another hand's color, where the device is",
    near(toldColor(w).x, 0.6) and near(c.x, 0.6),
    T.show({ told = toldColor(w), device = c })
  )
  w.restore()
end)

T.section("settle: a report's on and level are taken only from their own control, not where they ride along")
case(function()
  local w = world({}, 80)
  local st = w.m.device:report(w.clock.now())
  w.m.push({ on = true, level = 0.3 }, { control = "onOff" })
  w.run(5000)
  T.eq("a level riding an OnOff report tells nothing", w.proxy:changed(), {})
  w.proxy:mark()
  w.m.push({ on = false, level = st.level }, { control = "level" })
  w.run(5000)
  T.eq("nor an off riding a level report", w.proxy:changed(), {})
  w.proxy:mark()
  w.m.push({ on = true, level = 0.3, color = st.color }, { control = "color" })
  w.run(5000)
  T.eq("nor a level riding a color report", w.proxy:changed(), {})
  w.restore()
end)

T.section(
  "settle: a scene asked while the device is lost is dropped and opens no window, so the first report back stands"
)
case(function()
  -- T3 sent its step judged as for an on/off light; the gate drops it.
  local w = world({}, 60)
  scene(w, 9, { { level = 0, rate = 1000 } })
  w.m.drop()
  w.m.sent = {}
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 9 })
  T.eq("nothing is sent", w.m.sent, {})
  w.run(100)
  w.m.back()
  w.run(10000)
  T.eq("the proxy shows the light as it came back", { w.proxy.level, w.devicePercent() }, { 60, 60 })
  w.restore()
end)

T.section("settle: another hand's turn-on is read, and told with the level the light comes on at")
case(function()
  local w = world({}, 60)
  w.proxy:send("OFF")
  w.run(10000)
  local reads = w.m.reads
  w.proxy:mark()
  w.m.other({ on = true })
  w.run(10000)
  T.eq("the turn-on asks a read", w.m.reads, reads + 1)
  T.eq("and is told at its own level", w.proxy:changed(), { 60 })
  w.restore()
end)

T.section("settle: an off while a command lights the light is read, and shown once the read confirms it")
case(function()
  local w = world({}, 0)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 6000 })
  w.run(2000)
  local reads = w.m.reads
  w.m.other({ on = false })
  w.run(200)
  T.eq("the off asks a read", w.m.reads, reads + 1)
  w.run(500)
  T.eq("and shows once it is answered", w.proxy.level, 0)
  w.run(10000)
  T.eq("it stays off", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
end)

T.section("settle: a color sent while the light's on or off is unread says neither")
case(function()
  local w = world({ latency = 500 }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.other({ on = true })
  w.run(600)
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  local c = w.m.sent[1] or {}
  T.eq("the color goes with on left out", c.on, nil)
  T.check("and the color", c.color ~= nil)
  w.run(10000)
  T.eq("and the light shows where it is", w.proxy.level, w.devicePercent())
  w.restore()
end)

T.section(
  "settle: a color report that differs from the color sent is held to the read-back's answer or the window's end"
)
case(function()
  -- With no pre-on, the bulb's first report of a rated on from off is the color it went off in.
  local w = world({ keepsLevel = false }, 60)
  onMode(w, ON_PRESET)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:mark()
  local heard = #w.m.reports
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
  w.run(10000)
  local first = (w.m.reports[heard + 1] or { state = {} }).state.color or {}
  T.check("the device reports the color it went off in first", near(first.x, 0.3) and near(first.y, 0.5), T.show(first))
  T.eq("the on color is told, and that report is not", toldColors(w), { { x = RED.x, y = RED.y } })
  w.restore()

  local function readLost(kind)
    return kind == "read"
  end
  for _, lost in ipairs({ false, true }) do
    w = world({ drop = lost and readLost or nil }, 60)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
    )
    w.run(2500)
    w.m.other({ color = { x = 0.2, y = 0.2 } })
    w.run(500)
    T.check(
      "another hand's color after the ramp, in its window, is held",
      near(toldColor(w).x, 0.3),
      T.show(toldColor(w))
    )
    w.run(1000) -- the read-back answers at 3.58 s; the window ends at 4.5 s
    T.check(
      lost and "with the read-back lost it is held to the window's end" or "and told at the read-back's final answer",
      near(toldColor(w).x, lost and 0.3 or 0.2),
      T.show(toldColor(w))
    )
    w.run(1000)
    T.check("then shown", near(toldColor(w).x, 0.2) and near(toldColor(w).y, 0.2), T.show(toldColor(w)))
    w.restore()
  end
end)

T.section("settle: a read during a color fade answers moving, and only the final answer ends the color's hold")
case(function()
  local w = world({}, 60)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  local heard = #w.m.reports
  w.proxy:send("SET_LEVEL", { LEVEL = 40 }) -- its read-back lands in the fade
  w.run(3500)
  local moving
  for i = heard + 1, #w.m.reports do
    local r = w.m.reports[i]
    if r.meta.control == "color" and r.meta.answer == "moving" then
      moving = r.state.color
    end
  end
  T.check(
    "the read answers the color moving, part way",
    moving ~= nil and not near(moving.y, 0.5, 0.01),
    T.show(moving)
  )
  -- A device driver that keeps the color it last read pushes it with the next level, after the fade.
  local st = w.m.device:report(w.clock.now())
  st.color = moving
  w.m.push(st, { control = "level" })
  w.run(10000)
  T.eq("the proxy is told the fade's target alone", toldColors(w), { { x = 0.3, y = 0.5 } })
  w.restore()
end)

T.section("settle: a level asked again while its command settles, or an off light asked off, sends nothing")
case(function()
  -- Outside a raised Min, the device's word is not where the command in its window has the light.
  local w = world({}, 10)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 30 })
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  T.eq("a level asked twice before the device reports goes once", #w.m.sent, 1)
  w.run(10000)
  w.restore()
  -- An off light keeps the brightness it went off at, here below the Min: off is still off.
  w = world({}, 10)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 30 })
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  T.eq("an off light asked off sends nothing", #w.m.sent, 0)
  w.run(10000)
  w.restore()
  -- In its last half level a ramp shows its target, and the device's reports have it on its way there.
  w = world({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(4990)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("a level asked as its ramp reaches it, the light on its way, sends nothing", #w.m.sent, 0)
  w.run(10000)
  w.restore()
end)

T.section("a new range tells the light's level at once, but not while a command waits on its report")
case(function()
  local w = world({}, 20)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:mark()
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 10 })
  T.eq("settle: not in a command's window", w.proxy:changed(), {})
  w.run(10000)
  T.eq("which ends on the light", w.proxy.level, w.devicePercent())
  w.restore()
  -- The device lands at once on a rated command: its report settles the window before the transition's end.
  w = world({ slow = 0 }, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  w.run(500)
  w.proxy:mark()
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 20 })
  T.eq("settle: once the window has settled, at once", #w.proxy:changed(), 1)
  w.restore()
  w = held({ policy = "trust", keepsLevel = false }, 20)
  w.m.stall(w.clock.now() + 3000)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(200)
  w.proxy:mark()
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 10 })
  T.eq("trust: not before the command's word", w.proxy:changed(), {})
  w.run(10000)
  w.restore()
  w = held({ policy = "trust", keepsLevel = false }, 20)
  w.m.stall(w.clock.now() + 3000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  w.run(3500)
  w.proxy:mark()
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 10 })
  T.eq("nor before its transition has run from the word", w.proxy:changed(), {})
  w.run(10000)
  w.restore()
  w = world({ policy = "trust", keepsLevel = false }, 50)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 20 })
  T.eq("nor while a color lands", w.proxy:changed(), {})
  w.run(5000)
  w.m.push(w.m.device:report(w.clock.now()), {})
  w.run(500)
  T.eq("the next report tells it", #w.proxy:changed(), 1)
  w.restore()
end)

T.section("settle: a color's verdict is against the newest color command, not the color last told")
case(function()
  local w = world({}, 60)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.m.other({ color = { x = 0.2, y = 0.2 } })
  w.run(10000)
  T.check("another hand's color is told", near((toldColor(w) or {}).x, 0.2), T.show(toldColor(w)))
  local v = w.light:report({ color = { x = 0.3, y = 0.5 } }, { control = "color" })
  T.eq("a report of the command's color is its own", v.color.kind, "own")
  w.restore()
end)

T.section("settle: what ends a command's window early, and what it holds through")
case(function()
  -- The device's own reports are lost: each case reports by hand.
  local function quiet(o, level)
    o = o or {}
    o.drop = function(kind)
      return kind == "report"
    end
    return world(o, level)
  end
  local function open(w)
    return w.light.device.settle ~= nil
  end
  local w = quiet({}, 20)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.light:report({ on = true, level = 0.5 }, { control = "level", answer = "final" })
  T.check("a level's final answer alone, off the target, holds it", open(w))
  w.light:report({ on = true, level = 0.5 }, { control = "onOff", answer = "moving" })
  T.check("as does an OnOff answer still moving", open(w))
  w.light:report({ on = true, level = 0.5 }, { control = "onOff", answer = "final" })
  T.check("the OnOff's final answer with it ends it", not open(w))
  w.restore()
  w = quiet({}, 0)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.light:report({ on = true, level = 0.3 }, { control = "level", answer = "moving" })
  T.check("a level answer while the light's word is off is no answer saying off", open(w))
  w.restore()
  w = quiet({}, 60)
  w.proxy:send("OFF")
  w.light:report({ on = false, level = 0 }, {})
  T.check("an off holds through a whole report: only a control's report confirms", open(w))
  w.light:report({ on = false }, { control = "onOff" })
  T.check("and ends on its OnOff report", not open(w))
  w.restore()
  w = quiet({}, 0)
  w.light:report({ on = true }, { control = "onOff" })
  T.check("another hand's turn-on opens a window for its level", open(w))
  w.light:report({ on = true, level = 0.4 }, { control = "level" })
  T.check("which a report of its level ends", not open(w))
  w.light:report({ on = false }, { control = "onOff" })
  w.light:report({ on = true }, { control = "onOff" })
  w.light:report({ on = false }, { control = "onOff" })
  T.check("as does an off", not open(w))
  w.restore()
  w = quiet({ dims = false, color = false, cct = false, fade = "none", keepsLevel = false })
  w.proxy:send("ON")
  w.light:report({ on = true }, { control = "onOff" })
  T.check("a relay's On ends on its OnOff report", not open(w))
  w.proxy:send("OFF")
  w.light:report({ on = true }, { control = "onOff", answer = "final" })
  T.check("and its Off on the OnOff's final answer, whatever it says", not open(w))
  w.restore()
  -- Above a lowered Max the light is outside the range, and shows 100.
  w = quiet({}, 100)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.light:report({ on = true, level = 1 }, { control = "level" })
  T.check("a report outside the range holds a command sent inside it", open(w))
  w.restore()
  w = quiet({}, 100)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  w.run(500)
  w.proxy:send("SET_BRIGHTNESS_STOP")
  local stop = (w.m.sent[#w.m.sent] or {}).level
  T.check("a stop there is sent outside the range", stop ~= nil and stop > 0.81, stop)
  w.light:report({ on = true, level = stop }, { control = "level" })
  T.check("and a report at its place ends its window", not open(w))
  w.restore()
end)

T.section("settle: an off while a command lights the light asks one read, and asks again after an answer")
case(function()
  local w = world({
    drop = function(kind)
      return kind == "report"
    end,
  }, 0)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  local reads = w.m.reads
  w.light:report({ on = true, level = 0.3 }, { control = "level" })
  w.light:report({ on = true }, { control = "onOff" })
  T.eq("a level, or an on, asks none", w.m.reads, reads)
  w.light:report({ on = false }, { control = "onOff" })
  w.light:report({ on = false }, { control = "onOff" })
  T.eq("an off asks one, once", w.m.reads, reads + 1)
  w.light:report({ on = false, level = 0.3 }, { control = "level", answer = "moving" })
  w.light:report({ on = false }, { control = "onOff" })
  T.eq("an answer ends that ask: the next off asks again", w.m.reads, reads + 2)
  w.restore()
end)

T.section("settle: at a window's end the command stands for what the device did not say, and for nothing it did")
case(function()
  local function quiet(level)
    return world({
      drop = function(kind)
        return kind == "report"
      end,
    }, level)
  end
  local w = quiet(60)
  w.proxy:send("OFF")
  w.light:report({ on = true }, { control = "onOff" })
  w.run(5000)
  T.eq("an off the light did not take shows the level it stayed at", w.proxy.level, 60)
  w.restore()
  w = quiet(20)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_LEVEL", { LEVEL = 80 })
  w.light:report({ on = false }, { control = "onOff" })
  w.run(5000)
  T.eq("an on the light did not take shows it off", w.proxy.level, 0)
  w.light:report({ on = true }, { control = "onOff" })
  w.run(5000)
  T.eq("another hand's on then shows the level it kept, not the one it did not take", w.proxy.level, 20)
  w.restore()
  w = quiet(100)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  w.run(500)
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.run(5000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("a stop outside the range stands at its place: the level it shows is sent, to bring it in", #w.m.sent, 1)
  w.restore()
end)

T.section("settle: a command whose reports are all lost stands at its window's end, on or off")
case(function()
  local w = world({
    drop = function(kind)
      return kind == "report"
    end,
  }, 60)
  T.eq("a level lands as sent", w.proxy.level, 60)
  w.proxy:send("OFF")
  w.run(10000)
  T.eq("and an off as off", w.proxy:changed(), { 0 })
  w.restore()
end)

T.section("settle: a device that lands before the ramp's time ends the ramp, told once at its report")
case(function()
  local w = world({ slow = 0 }, 20)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  w.run(1000)
  T.eq("CHANGED at the report", w.proxy:changed(), { 60 })
  w.run(5000)
  T.eq("and the ramp's time tells nothing more", w.proxy:changed(), { 60 })
  w.restore()
end)

T.section("settle: a level in a narrow range lands as sent, not at the device's step for it")
case(function()
  local w = world({}, 50)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 40 })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 45 })
  w.run(10000)
  w.proxy:mark()
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  T.eq("the proxy is told 50 and nothing else", w.proxy:changed(), { 50 })
  w.restore()
end)

T.section("settle: a color command's window holds another hand's color to its end, and no window holds anything")
case(function()
  -- The reads are lost, so each window ends at its time rather than at the read-back's answer.
  local w = world({
    drop = function(kind)
      return kind == "read"
    end,
  }, 60)
  w.m.other({ color = { x = 0.2, y = 0.2 } })
  w.run(200)
  T.check("with no window another hand's color is told", near((toldColor(w) or {}).x, 0.2), T.show(toldColor(w)))
  w.run(10000)
  local function color(x, y)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = x, LIGHT_COLOR_TARGET_Y = y, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end
  color(0.3, 0.5)
  w.run(2000)
  color(0.35, 0.45)
  w.run(1000)
  w.m.other({ color = { x = 0.25, y = 0.25 } })
  w.run(200)
  T.check(
    "in the newer window, past the older's end, it is held",
    near((toldColor(w) or {}).x, 0.35),
    T.show(toldColor(w))
  )
  w.run(10000)
  T.check("and told at its end", near((toldColor(w) or {}).x, 0.25), T.show(toldColor(w)))
  w.m.other({ color = { x = 0.4, y = 0.4 } })
  w.run(200)
  T.check("after it, at once", near((toldColor(w) or {}).x, 0.4), T.show(toldColor(w)))
  w.restore()
end)

T.section("settle: in a color window a push of another control repeats the old color, even as a final answer")
case(function()
  local w = world({}, 60)
  local old = w.m.device:report(w.clock.now()).color
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.light:report({ on = true, level = 0.6, color = old }, { control = "level", answer = "final" })
  T.check("the proxy keeps the color sent", near((toldColor(w) or {}).x, 0.3), T.show(toldColor(w)))
  w.run(10000)
  T.check("to the end", near((toldColor(w) or {}).x, 0.3), T.show(toldColor(w)))
  w.restore()
end)

T.section("settle: another hand's turn-on in a whole report is told at once; a relay's OnOff turn-on too")
case(function()
  local w = world({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  local reads = w.m.reads
  w.light:report({ on = true, level = 0.4 }, {})
  T.eq("a whole report has its level: told with no read", { w.proxy.level, w.m.reads }, { 40, reads })
  w.restore()
  w = world({ dims = false, color = false, cct = false, fade = "none", keepsLevel = false })
  reads = w.m.reads
  w.m.other({ on = true })
  w.run(200)
  T.eq("a relay has no level to read", { w.proxy.level, w.m.reads }, { 100, reads })
  w.restore()
end)

T.section("settle: a snapshot after the first report brings no news of on or level")
case(function()
  local w = world({}, 50)
  w.proxy:mark()
  w.light:report({ on = false, level = 0.3 }, { snapshot = true })
  T.eq("nothing is told", w.proxy:changed(), {})
  w.restore()
end)

T.section("settle: the level verdict, on a command's path and off it, and a hand names no command")
case(function()
  local w = world({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  local v = w.light:report({ on = false }, { control = "onOff" })
  T.eq("an off against an off is own", v.level.kind, "own")
  v = w.light:report({ on = false, level = 0.5 }, { control = "level" })
  T.eq("and so is the level an off light keeps", v.level.kind, "own")
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  v = w.light:report({ on = false, level = 0.2 }, { control = "level" })
  T.eq("a level off the target before the light's on is told is another hand's", v.level.kind, "hand")
  T.eq("and names no command", v.level.seq, nil)
  w.run(10000)
  w.restore()
  w = world({}, 0)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  v = w.light:report({ on = true, level = 0.95 }, { control = "level" })
  T.eq("in a ramp from off, a level past its end is another hand's", v.level.kind, "hand")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  w.run(1000)
  v = w.light:report({ on = true, level = 0.81 }, { control = "level" })
  T.eq("one level past where the path starts is own", v.level.kind, "own")
  v = w.light:report({ on = true, level = 0.82 }, { control = "level" })
  T.eq("two levels past it is another hand's", v.level.kind, "hand")
  w.run(10000)
  w.restore()
  w = world({}, 50)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 40 })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 45 })
  w.run(10000)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  v = w.light:report({ on = true, level = 0.4252 }, { control = "level" })
  T.eq("landed, a level within the device's step is own", v.level.kind, "own")
  w.restore()
end)

T.section("settle: the color verdict, within match, part way through its transition, and a hand names no command")
case(function()
  local w = world({}, 60)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  local v = w.light:report({ color = { x = 0.302, y = 0.498 } }, { control = "color" })
  T.eq("a color within match of the command's is own", v.color.kind, "own")
  v = w.light:report({ color = { x = 0.2, y = 0.2 } }, { control = "color" })
  T.eq("another is another hand's, naming no command", { v.color.kind, v.color.seq }, { "hand" })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  v = w.light:report({ color = { x = 0.35, y = 0.45 } }, { control = "color" })
  T.eq("part way through a transition, a color on the way is own", v.color.kind, "own")
  w.run(10000)
  w.restore()
end)

T.section("settle: the level the proxy shows is sent again while a command settles elsewhere, or the light is unread")
case(function()
  local w = world({}, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.m.sent = {}
  w.proxy:send("OFF")
  T.eq("an Off as a rated on from off starts is sent", sentLevels(w), { 0 })
  T.eq("with no color", (w.m.sent[1] or {}).color, nil)
  w.run(10000)
  T.eq("and the light is off", w.devicePercent(), 0)
  w.restore()
  w = world({ latency = 500 }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.other({ on = true })
  w.run(600)
  w.m.sent = {}
  w.proxy:send("OFF")
  T.eq("an Off before another hand's turn-on is read is sent", sentLevels(w), { 0 })
  w.run(10000)
  T.eq("and the light is off", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
end)

T.section("settle: a color sent while the light is unread opens the read's window again")
case(function()
  local w = world({
    latency = 500,
    drop = function(kind)
      return kind == "read"
    end,
  }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.other({ on = true })
  w.run(1500)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(2000)
  T.check("past the first window's end it is still unread", w.light:_unsure())
  w.run(10000)
  w.restore()
end)

--------------------------------------------------------------------------------
-- The outbox
--------------------------------------------------------------------------------

T.section("the outbox with ack = send: every command goes at once, as with no outbox at all")
case(function()
  local w = world({}, 20)
  for _, level in ipairs({ 30, 40, 50 }) do
    w.proxy:send("SET_LEVEL", { LEVEL = level })
  end
  T.eq("three commands, three sends, at once", sentLevels(w), { 30, 40, 50 })
  T.eq("no Light.Ack timer runs", Timer["Light.Ack." .. tostring((w.m.sent[3] or {}).seq)], nil)
  w.run(10000)
  T.eq("it lands on the last", w.devicePercent(), 50)
  w.restore()
end)

T.section("the outbox with ack = done: one command in flight per aspect, and the newest waiting wins")
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  T.eq("a rated on from off goes, after its pre-on", sentLevels(w), { 100 })
  for _, level in ipairs({ 80, 60, 40 }) do
    w.run(300)
    w.proxy:send("SET_LEVEL", { LEVEL = level })
  end
  T.eq("the burst waits while the ramp's word is held", sentLevels(w), { 100 })
  T.eq("each is told at once, from the model", w.proxy:changed(), { 80, 60, 40 })
  w.run(5000)
  T.eq("at the word the newest goes, and only it", sentLevels(w), { 100, 40 })
  w.run(10000)
  T.eq("the light lands where Control4 was told", { w.devicePercent(), w.proxy.level }, { 40, 40 })
  w.restore()
end)

T.section("the outbox: a command an adapter gives its word on inside send is done at once, alone or as a pre-on")
case(function()
  -- An adapter that puts nothing on the wire for a command says so from send.
  local function doneInSend(w, which)
    local send = w.m.adapter.send
    w.m.adapter.send = function(self, cmd)
      if which(cmd) then
        w.light:done(cmd.seq, true, cmd.epoch)
        return
      end
      return send(self, cmd)
    end
  end
  local w = held({}, 50)
  local first = true
  doneInSend(w, function(cmd)
    local now = first
    first = false
    return now
  end)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  T.eq("the next level goes at once", sentLevels(w), { 30 })
  w.run(10000)
  T.eq("and lands", { w.proxy.level, w.devicePercent() }, { 30, 30 })
  w.restore()
  w = held({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  doneInSend(w, function(cmd)
    return cmd.preOn == true
  end)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.run(500)
  T.eq("a pre-on done inside send: the ramp's own word lets the next level go", sentLevels(w), { 100, 40 })
  w.run(10000)
  T.eq("which lands", { w.proxy.level, w.devicePercent() }, { 40, 40 })
  w.restore()
  -- A lost off's timeout reads the light; a color sent unlit before the answer supersedes the read.
  w = held({ ackMs = 1000 }, 50)
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(1000)
  local reads = w.m.reads
  doneInSend(w, function(cmd)
    return cmd.color ~= nil
  end)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("a color done inside send that superseded a read asks it again at once", w.m.reads, reads + 1)
  w.run(10000)
  w.restore()
end)

T.section(
  "the outbox: a lost or a forget inside send leaves the command as one sent while lost; a report or a declaration is refused"
)
case(function()
  -- The adapter calls `call` inside its next send that `which` picks.
  local function inSend(w, which, call)
    local send = w.m.adapter.send
    w.m.adapter.send = function(self, cmd)
      if which(cmd) then
        w.m.adapter.send = send
        call()
      end
      return send(self, cmd)
    end
  end
  for _, ack in ipairs({ "send", "done" }) do
    for _, how in ipairs({ "lost", "forget" }) do
      local name = ack .. ", " .. how
      local w = world({ ack = ack }, 0)
      w.proxy:send("OFF")
      w.run(10000)
      inSend(w, function(cmd)
        return cmd.preOn == true
      end, function()
        w.light[how](w.light)
      end)
      w.m.sent = {}
      w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
      local box = w.light.device.outbox
      T.eq(name .. ": in the pre-on's send the light goes offline", w.proxy.online, false)
      T.eq(name .. ": and the ramp still reaches send", #w.m.sent, 2)
      T.check(name .. ": with nothing in flight", next(box.flight) == nil and next(box.units) == nil, T.show(box))
      w.run(10000)
      w.m.back()
      w.run(10000)
      T.eq(name .. ": back, the proxy shows the device", { w.proxy.online, w.proxy.level }, { true, w.devicePercent() })
      w.restore()
    end
  end
  -- At a go, an offline inside send: nothing else that waited goes.
  local w = held({}, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.stall(w.clock.now() + 1000)
  w.proxy:send("ON")
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  inSend(w, function()
    return true
  end, function()
    w.light:lost()
  end)
  w.m.sent = {}
  w.run(10000)
  T.eq("at a go: only the command whose send went offline is sent", #w.m.sent, 1)
  w.restore()
  -- At a go that sends nothing, an offline inside the read it asks: nothing else goes either.
  w = held({ hold = true }, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  local refresh = w.m.adapter.refresh
  w.m.adapter.refresh = function(self)
    w.m.adapter.refresh = refresh
    w.light:lost()
    return refresh(self)
  end
  w.m.sent = {}
  w.run(10000)
  T.eq("at a go that sends nothing: an offline inside its read leaves nothing to go", #w.m.sent, 0)
  w.restore()
  -- At a change of ack to send, the same.
  w = held({}, 50)
  w.m.stall(w.clock.now() + 5000)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  inSend(w, function()
    return true
  end, function()
    w.light:lost()
  end)
  w.m.sent = {}
  w.m.o.ack = "send"
  w.light:declare(w.m.declaration())
  T.eq("at a change of ack to send: the same", #w.m.sent, 1)
  w.run(10000)
  w.restore()
  for _, ack in ipairs({ "send", "done" }) do
    w = world({ policy = "trust", ack = ack }, 50)
    local verdict, accepted
    inSend(w, function()
      return true
    end, function()
      verdict = w.light:report(w.device:state(w.clock.now()))
      accepted = w.light:declare(w.m.declaration())
    end)
    w.proxy:mark()
    local errors = errorsOf(function()
      w.proxy:send(
        "SET_COLOR_TARGET",
        { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
      )
    end)
    T.eq(ack .. ": a report inside send is dropped, and a declaration refused", { verdict, accepted }, { nil, false })
    T.eq(ack .. ": each with an error", #errors, 2)
    w.run(5000)
    T.eq(ack .. ": so the color asked is told once", #toldColors(w), 1)
    w.restore()
  end
  -- A word inside send lets a waiting level go in a send of its own: the outer send is still a send.
  local w = held({}, 50)
  w.m.stall(w.clock.now() + 5000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  local first = w.m.sent[1]
  local verdict = "none"
  inSend(w, function(cmd)
    return cmd.color ~= nil
  end, function()
    w.light:done(first.seq, true, first.epoch)
    verdict = w.light:report(w.device:state(w.clock.now()))
  end)
  local errors = errorsOf(function()
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end)
  T.eq("the word inside the color's send lets the waiting level go", sentLevels(w), { 60, 70, "on" })
  T.eq("and a report after it, still inside the color's send, is dropped", { verdict, #errors }, { nil, 1 })
  w.run(10000)
  w.restore()
end)

T.section("a read's answer comes later: a report or a declaration inside refresh is refused, at a go or inside a send")
case(function()
  -- The adapter answers inside its next refresh, then asks the device as it always does.
  local function answerInRefresh(w)
    local refresh = w.m.adapter.refresh
    local got = {}
    w.m.adapter.refresh = function(self)
      w.m.adapter.refresh = refresh
      got.verdict = w.light:report(w.device:state(w.clock.now()), { control = "level", answer = "moving" })
      got.accepted = w.light:declare(w.m.declaration())
      return refresh(self)
    end
    return got
  end
  local function namesRefresh(errors)
    return #errors >= 2
      and errors[1]:find("inside refresh", 1, true) ~= nil
      and errors[2]:find("inside refresh", 1, true) ~= nil
  end
  -- A waiting level the ramp ahead lands on goes with nothing to send and asks the read.
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  local got = answerInRefresh(w)
  local errors = errorsOf(function()
    w.run(10000)
  end)
  T.eq("at a go: the report is dropped and the declaration refused", { got.verdict, got.accepted }, { nil, false })
  T.check("each with an error that names refresh", #errors == 2 and namesRefresh(errors), T.show(errors))
  T.eq("and the light lands where it was told", { w.proxy.level, w.devicePercent() }, { 70, 70 })
  w.restore()
  -- The same go, let out by a word given inside another command's send.
  w = held({}, 50)
  w.m.stall(w.clock.now() + 5000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 1000 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.run(1500)
  local ramp = w.m.sent[1]
  local send = w.m.adapter.send
  w.m.adapter.send = function(self, cmd)
    if cmd.color then
      w.m.adapter.send = send
      got = answerInRefresh(w)
      w.light:done(ramp.seq, true, ramp.epoch)
      got.after = w.light:report(w.device:state(w.clock.now()))
    end
    return send(self, cmd)
  end
  errors = errorsOf(function()
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end)
  T.eq("inside a send: the same", { got.verdict, got.accepted }, { nil, false })
  T.check("with the same errors, naming refresh and not send", namesRefresh(errors), T.show(errors))
  T.check(
    "and a report after the read, still inside the send, is dropped as one inside send",
    got.after == nil and #errors == 3 and errors[3]:find("inside send", 1, true) ~= nil,
    T.show(errors)
  )
  w.run(10000)
  w.restore()
end)

T.section("an error raised in send or refresh reaches the caller, and what the transport says after it is heard")
case(function()
  -- Refresh raises at start(), the transport not up yet.
  forget()
  local clock = require("c4_fixtures").virtualClock()
  local proxy = H.proxy(clock)
  local m = H.memoryLight(clock, { dims = true, policy = "settle", settleMs = 2000 })
  local refresh = m.adapter.refresh
  m.adapter.refresh = function()
    m.adapter.refresh = refresh
    error("transport not up", 0)
  end
  local ok, err = pcall(m.light.start, m.light)
  T.eq("start() raises refresh's error", { ok, err }, { false, "transport not up" })
  local errors = errorsOf(function()
    m.connect()
    clock.run(20000)
  end)
  T.eq("the light comes online once its transport is up", { proxy.online, #errors }, { true, 0 })
  proxy:restore()
  clock.restore()
  -- Send raises once.
  local w = world({}, 50)
  local send = w.m.adapter.send
  w.m.adapter.send = function()
    w.m.adapter.send = send
    error("frame too long", 0)
  end
  ok, err = pcall(w.proxy.send, w.proxy, "SET_LEVEL", { LEVEL = 60 })
  T.eq("a command raises send's error", { ok, err }, { false, "frame too long" })
  errors = errorsOf(function()
    w.proxy:send("SET_LEVEL", { LEVEL = 30 })
    w.run(20000)
  end)
  T.eq("the next command lands, its reports heard", { w.proxy.level, w.devicePercent(), #errors }, { 30, 30, 0 })
  w.restore()
end)

T.section("a command whose send raised went nowhere: the model is as before it, and what waits still goes")
case(function()
  local function raiseAt(w, nth)
    local send, calls = w.m.adapter.send, 0
    w.m.adapter.send = function(self, cmd)
      calls = calls + 1
      if calls == nth then
        w.m.adapter.send = send
        error("frame too long", 0)
      end
      return send(self, cmd)
    end
  end
  -- A rated level whose send raised leaves no ramp in the model, so under trust the light's reports show.
  local w = world({ policy = "trust" }, 40)
  raiseAt(w, 1)
  local ok = pcall(w.proxy.send, w.proxy, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  T.check("the level raises send's error", not ok)
  w.m.other({ on = true, level = 0.6 })
  w.run(10000)
  T.eq("another hand's level after it shows", { w.proxy.level, w.devicePercent() }, { 60, 60 })
  w.restore()
  -- A rated on from off whose ramp's send raised after its pre-on went.
  w = held({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  raiseAt(w, 2)
  pcall(w.proxy.send, w.proxy, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("the pre-on that went is in flight, so a level waits for its word", #w.m.sent, 0)
  w.run(10000)
  T.eq("and goes after it", { w.proxy.level, w.devicePercent() }, { 50, 50 })
  w.restore()
  -- That pre-on lit the light the model shows off: an Off asked before the device's word or report goes.
  for _, ack in ipairs({ "send", "done" }) do
    for _, policy in ipairs({ "trust", "settle" }) do
      w = world({ ack = ack, policy = policy, latency = 400 }, 0)
      if ack == "done" then
        w.m.stall(w.clock.now() + 10000)
      end
      raiseAt(w, 2)
      ok = pcall(w.proxy.send, w.proxy, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
      T.check(string.format("ack %s, %s: the ramp's raise after its pre-on reaches the caller", ack, policy), not ok)
      w.run(100)
      w.proxy:send("OFF")
      w.run(60000)
      T.eq(
        string.format("ack %s, %s: an Off after it turns the light off", ack, policy),
        { w.proxy.level, w.devicePercent() },
        { 0, 0 }
      )
      w.restore()
    end
  end
  -- With nothing asked after it, that pre-on's word has the light read, at the instant it went too.
  for _, policy in ipairs({ "trust", "settle" }) do
    w = held({ policy = policy }, 50)
    w.proxy:send("OFF")
    w.run(15000)
    w.m.stall(w.clock.now() + 10000)
    raiseAt(w, 2)
    pcall(w.proxy.send, w.proxy, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
    w.run(60000)
    T.eq(policy .. ": a pre-on left lit alone is read at its word", { w.proxy.level, w.devicePercent() }, { 1, 1 })
    w.restore()
  end
  -- With its word lost, that pre-on times out as a command with no transition.
  w = held({ ackMs = 1000 }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  raiseAt(w, 2)
  w.m.loseNext = true
  pcall(w.proxy.send, w.proxy, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(1100)
  T.eq("the level waiting goes at the pre-on's own timeout", sentLevels(w), { 50 })
  w.restore()
  -- A scene step whose send raised told the proxy nothing, so the light shows where it is.
  w = world({ policy = "trust" }, 40)
  scene(w, 5, { { level = 80, rate = 2000, color = { x = 0.3, y = 0.6 } } })
  raiseAt(w, 1)
  T.check("the step raises send's error", not pcall(w.proxy.send, w.proxy, "ACTIVATE_SCENE", { SCENE_ID = 5 }))
  T.eq("and told the proxy nothing", w.proxy.notes, {})
  w.run(10000)
  T.eq("which shows the light as it is", { w.proxy.level, w.devicePercent() }, { 40, 40 })
  w.restore()
  -- Under Dim-To-Warm a level carries a color, so a color asked since waits apart from it. The word is
  -- lost, so what waits goes at the timeout.
  w = held({ ackMs = 1000 }, 40)
  onMode(w, WARM, DIM)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  raiseAt(w, 1)
  w.run(10000)
  T.eq("the first to go at the timeout raises", #w.clock.errors, 1)
  w.clock.errors = {}
  T.check("the color waiting with it still goes", near(deviceColor(w).x, 0.3), T.show(deviceColor(w)))
  T.eq("and the light is read, shown where it is", w.proxy.level, w.devicePercent())
  w.restore()
  -- So does what waits when ack changes to send.
  w = held({}, 40)
  onMode(w, WARM, DIM)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.m.o.ack = "send"
  raiseAt(w, 1)
  T.check("the first to go at the change raises", not pcall(w.light.declare, w.light, w.m.declaration()))
  w.run(10000)
  T.check("the color waiting with it still goes then", near(deviceColor(w).x, 0.3), T.show(deviceColor(w)))
  T.eq("and the light is read then, shown where it is", w.proxy.level, w.devicePercent())
  w.restore()
  -- The level that raised at the change was told when it was asked, so the light is read, under either policy.
  for _, policy in ipairs({ "trust", "settle" }) do
    w = held({ policy = policy }, 50)
    w.m.stall(w.clock.now() + 5000)
    w.proxy:send("SET_LEVEL", { LEVEL = 60 })
    w.run(100)
    w.proxy:send("SET_LEVEL", { LEVEL = 70 })
    w.run(100)
    w.m.o.ack = "send"
    raiseAt(w, 1)
    T.check(
      policy .. ": a waiting level that raises at a change of ack raises",
      not pcall(w.light.declare, w.light, w.m.declaration())
    )
    w.run(60000)
    T.eq(policy .. ": and the light is read, shown where it is", { w.proxy.level, w.devicePercent() }, { 60, 60 })
    w.restore()
  end
  -- A command whose send raised is owed no word, and a read handed over before it still stands.
  w = held({ ackMs = 1000 }, 30)
  w.m.dropReads = true
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(1500)
  local dev = w.light.device
  local read = dev.read
  raiseAt(w, 1)
  ok = pcall(
    w.proxy.send,
    w.proxy,
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.check("a color sent unlit while the timeout's read is out raises", read ~= nil and not ok)
  T.eq("a word given for it anyway is ignored", { pcall(w.light.done, w.light, dev.seq, true, dev.epoch) }, { true })
  T.eq("and the read is still the one out", dev.read, read)
  T.eq("with no read asked again at a word for it", dev.reask, nil)
  w.restore()
  -- The read it took over stands only on the outbox it was asked on, and only if none was asked since.
  local function raising(w, inside)
    local send = w.m.adapter.send
    w.m.adapter.send = function()
      w.m.adapter.send = send
      inside()
      error("frame too long", 0)
    end
  end
  local color = { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  w = held({ ackMs = 1000 }, 30)
  w.m.dropReads = true
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(1500)
  dev = w.light.device
  raising(w, function()
    w.light:lost()
  end)
  ok = pcall(w.proxy.send, w.proxy, "SET_COLOR_TARGET", color)
  T.check("an offline inside a send that raises leaves no read out", not ok and dev.read == nil, T.show(dev.read))
  w.restore()
  w = held({ ackMs = 1000 }, 30)
  w.m.dropReads = true
  w.m.stall(w.clock.now() + 20000)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.m.other({ on = false })
  w.run(500)
  dev = w.light.device
  read = dev.read
  local level = dev.seq
  raising(w, function()
    w.light:done(level, false, dev.epoch) -- given up: the light is read
  end)
  ok = pcall(w.proxy.send, w.proxy, "SET_COLOR_TARGET", color)
  T.check(
    "a read asked inside a send that raises stands",
    not ok and read ~= nil and dev.read ~= read,
    T.show(dev.read)
  )
  w.restore()
  -- With ack = done, a level with no pre-on whose send raised holds nothing in flight.
  w = held({}, 40)
  raiseAt(w, 1)
  T.eq("ack done: a level raises send's error", { pcall(w.proxy.send, w.proxy, "SET_LEVEL", { LEVEL = 60 }) }, {
    false,
    "frame too long",
  })
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.run(20000)
  T.eq("and the next level lands", { w.proxy.level, w.devicePercent() }, { 30, 30 })
  w.restore()
  -- A level waiting behind one whose word was lost goes at the timeout, after the device's read-back came
  -- and went as history; its send raised, so the light is read, and shown where it is.
  w = held({}, 40)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  raiseAt(w, 1)
  pcall(w.run, 45000)
  w.clock.errors = {}
  w.run(20000)
  T.eq("a waiting level whose send raised at the timeout has the light read", { w.proxy.level, w.devicePercent() }, {
    60,
    60,
  })
  w.restore()
  -- Under trust a ramp in flight runs on to its end, its timer and all, so the light's reports show after it.
  w = world({ policy = "trust" }, 40)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.run(500)
  raiseAt(w, 1)
  pcall(w.proxy.send, w.proxy, "SET_LEVEL", { LEVEL = 20 })
  w.run(5000)
  w.m.other({ on = true, level = 0.6 })
  w.run(10000)
  T.eq("a level ramp runs on to its end", { w.proxy.level, w.devicePercent() }, { 60, 60 })
  w.restore()
  w = world({ policy = "trust" }, 40)
  local function color(x, y, rate)
    return { LIGHT_COLOR_TARGET_X = x, LIGHT_COLOR_TARGET_Y = y, LIGHT_COLOR_TARGET_COLOR_RATE = rate }
  end
  w.proxy:send("SET_COLOR_TARGET", color(0.6, 0.35, 2000))
  w.run(500)
  raiseAt(w, 1)
  pcall(w.proxy.send, w.proxy, "SET_COLOR_TARGET", color(0.2, 0.3, 0))
  w.run(5000)
  w.m.other({ color = { x = 0.3, y = 0.5 } })
  w.run(10000)
  T.check(
    "so does a color ramp",
    near(toldColor(w).x, 0.3, 0.01) and near(deviceColor(w).x, 0.3, 0.01),
    T.show({ toldColor(w), deviceColor(w) })
  )
  w.restore()
  -- Under Dim-To-Warm a level ramp carries its mix, so the device's pushes in it tell nothing, and its end
  -- tells it once, with no preset id the raised command named.
  for _, send in ipairs({
    { "SET_LEVEL", { LEVEL = 20 } },
    {
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_PRESET_ID = 3 },
    },
  }) do
    w = world({ policy = "trust", pushEveryMs = 250 }, 40)
    onMode(w, WARM, DIM)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 2000 })
    w.run(500)
    w.proxy:mark()
    raiseAt(w, 1)
    pcall(w.proxy.send, w.proxy, send[1], send[2])
    w.run(5000)
    local told = w.proxy:told("LIGHT_COLOR_CHANGED")
    T.eq(
      send[1] .. " raised: the ramp's end tells its mix once, with no preset id",
      { #told, told[1] and told[1].LIGHT_COLOR_CURRENT_PRESET_ID },
      { 1 }
    )
    w.restore()
  end
  -- A scene runs on past a command whose send raised, and a step whose send raised leaves no ramp.
  w = world({ policy = "trust" }, 40)
  scene(w, 6, { { level = 30 }, { delay = 2000, level = 70 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 6 })
  w.run(500)
  raiseAt(w, 1)
  pcall(w.proxy.send, w.proxy, "SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  T.eq("a scene's later step still runs", { w.proxy.level, w.devicePercent() }, { 70, 70 })
  w.restore()
  w = world({ policy = "trust" }, 40)
  scene(w, 7, { { delay = 1000, level = 80, rate = 2000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
  raiseAt(w, 1)
  pcall(w.run, 1500)
  w.clock.errors = {}
  w.run(5000)
  w.m.other({ on = true, level = 0.6 })
  w.run(10000)
  T.eq("a step after a delay whose send raised leaves no ramp", { w.proxy.level, w.devicePercent() }, { 60, 60 })
  w.restore()
end)

T.section("the outbox: a waiting level the light is already at sends nothing, and ends the ramp to it")
case(function()
  local w = held({ policy = "trust", hold = true, holdShare = 1 }, 100)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  w.run(500)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 5000 })
  w.proxy:mark()
  w.run(2500)
  T.eq("at the word the light is off, so nothing goes", #w.m.sent, 0)
  T.eq("and the proxy is told it is off then", w.proxy:changed(), { 0 })
  w.restore()
end)

T.section("the outbox: fields one command named go together, unless a newer command replaces one of them")
case(function()
  local w = held({ hold = true }, 0)
  onMode(w, WARM, DIM)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(500)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("both wait behind the held ramp", #w.m.sent, 0)
  w.run(4000)
  local level, color = w.m.sent[1] or {}, w.m.sent[2] or {}
  T.check(
    "at the word the level goes without the mix the color replaced",
    level.level ~= nil and level.color == nil,
    T.show(level)
  )
  T.check("and the color as its own command", color.color ~= nil and near(color.color.x, 0.3), T.show(color))
  w.run(10000)
  w.restore()
  w = held({ ackMs = 500 }, 30)
  onMode(w, ON_PRESET)
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(10)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
  w.run(10)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.m.sent = {}
  w.run(10000)
  local pre = {}
  for _, c in ipairs(w.m.sent) do
    pre = c.preOn and c or pre
  end
  T.eq("a rated on from off whose on color a newer color took: its pre-on goes", pre.preOn, true)
  T.eq("with no color", pre.color, nil)
  w.run(10000)
  w.restore()
end)

T.section("the outbox: a waiting command goes with the time its rate has left; a wait under 50 ms takes nothing off")
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
  w.run(1000)
  w.m.sent = {}
  local asked = w.clock.now()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 4000 })
  w.run(3000)
  local went = w.m.sent[1] or {}
  T.check("held about 2 s", went.at and went.at - asked > 1900 and went.at - asked < 2200, T.show(went))
  T.eq("it goes with the time its rate has left", went.ms, 4000 - ((went.at or 0) - asked))
  w.run(10000)
  w.restore()
  w = held({}, 50)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 750 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 750 })
  w.run(100)
  T.eq("one that waited a few ms goes with its whole rate", (w.m.sent[2] or {}).ms, 750)
  w.run(10000)
  w.restore()
  w = held({ latency = 47 }, 50)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 750 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 750 })
  w.run(150)
  local ahead, behind = w.m.sent[1] or {}, w.m.sent[2] or {}
  T.eq("one that waited 50 ms goes with 50 ms off", { (behind.at or 0) - (ahead.at or 0), behind.ms }, { 50, 700 })
  w.run(10000)
  w.restore()
end)

T.section("the outbox: a waiting on decides its pre-on as it goes, and tells the on color when the go adds one")
case(function()
  local w = held({ hold = true, holdShare = 1 }, 100)
  onMode(w, ON_PRESET)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
  w.run(600)
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  T.eq("asked late in the off, the light still lit: no on color is told", #w.proxy:told("LIGHT_COLOR_CHANGED"), 0)
  w.run(1000)
  local pre, on = w.m.sent[1] or {}, w.m.sent[2] or {}
  T.eq("at the off's word the light is off: the on goes after a pre-on", pre.preOn, true)
  T.eq("the pre-on goes at once", pre.ms, 0)
  T.check("in the on color", on.color ~= nil and near(on.color.x, RED.x), T.show(on))
  T.check("and so is the pre-on", pre.color ~= nil and near(pre.color.x, RED.x), T.show(pre))
  T.eq("which is told now", #w.proxy:told("LIGHT_COLOR_CHANGED"), 1)
  w.run(10000)
  T.eq("it lands", w.proxy.level, 80)
  w.restore()
end)

T.section("the outbox: a waiting on asked from off goes with no pre-on when the light is lit by its go")
case(function()
  local w = held({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.stall(w.clock.now() + 1000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 4000 })
  T.eq("asked as the ramp ahead leaves off, it waits", #w.m.sent, 0)
  w.run(1500)
  T.eq("at the word the light is lit: it goes alone", #w.m.sent, 1)
  T.eq("with no pre-on to dip it", (w.m.sent[1] or {}).preOn, nil)
  w.run(10000)
  T.eq("it lands", { w.proxy.level, w.devicePercent() }, { 60, 60 })
  w.restore()
end)

T.section(
  "the outbox: a waiting stop of a rated on from off sends no color, and a level the command ahead lands on is not sent again"
)
case(function()
  local w = held({ hold = true }, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.run(4000)
  local stop = w.m.sent[1] or {}
  T.check(
    "the stop of the rated on from off goes alone, with no color",
    stop.level ~= nil and stop.color == nil,
    T.show(stop)
  )
  w.run(10000)
  w.restore()
  w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.m.sent = {}
  w.run(4000)
  T.eq("a level the held ramp lands on is not sent again", #w.m.sent, 0)
  w.run(10000)
  T.eq("and the light is there", { w.devicePercent(), w.proxy.level }, { 70, 70 })
  w.restore()
end)

T.section("a command while the device is lost is dropped before the transport, under either ack (T3 sent it)")
case(function()
  for _, ack in ipairs({ "send", "done" }) do
    local w = world({ ack = ack }, 0)
    w.m.drop()
    w.m.sent = {}
    w.proxy:mark()
    w.proxy:send("ON")
    w.run(10000)
    T.eq(ack .. ": nothing reaches send", w.m.sent, {})
    T.eq(ack .. ": the proxy is told nothing", w.proxy:said(), {})
    T.eq(ack .. ": the light stays off", w.device:state(w.clock.now()).on, false)
    w.restore()
  end
end)

T.section("the outbox is emptied at lost and at forget: nothing waiting goes later")
case(function()
  for _, how in ipairs({ "lost", "forget" }) do
    -- A short ackMs: the run passes the timeout at which a unit left in flight would send what waits.
    local w = held({ hold = true, ackMs = 1000 }, 0)
    w.proxy:send("OFF")
    w.run(10000)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
    w.proxy:send("SET_LEVEL", { LEVEL = 30 })
    w.m.sent = {}
    w.light[how](w.light)
    w.run(10000)
    T.eq(how .. ": the waiting level is never sent", sentLevels(w), {})
    w.restore()
  end
  -- Another hand heard as history, and one heard after the word, put the light away from its commands.
  local w = held({}, 60)
  w.m.stall(w.clock.now() + 3000)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(5000)
  w.m.other({ on = true, level = 0.7 })
  w.run(5000)
  local dev = w.light.device
  T.check("a light heard away from its commands", dev.awayAt ~= nil and dev.movedAt ~= nil)
  local away, moved = dev.awayAt, dev.movedAt
  w.m.o.policy = "trust"
  w.light:declare(w.m.declaration())
  T.eq(
    "is still heard away after a change of policy, which keeps the outbox",
    { dev.awayAt, dev.movedAt },
    { away, moved }
  )
  w.light:lost()
  T.eq("is heard away no longer once lost", { dev.awayAt, dev.movedAt }, {})
  w.restore()
end)

T.section("a relay is never outside the range: a switch it has landed on is not sent again")
case(function()
  -- An on/off device reports no level; with its reports lost the light has only its first word.
  for _, policy in ipairs({ "settle", "trust" }) do
    local w = world({
      dims = false,
      color = false,
      cct = false,
      fade = "none",
      keepsLevel = false,
      ack = "done",
      policy = policy,
      offline = true,
      drop = function(kind)
        return kind == "report"
      end,
    })
    w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
    w.light:declare(w.m.declaration())
    w.light:report({ on = true }, {})
    w.m.sent = {}
    w.proxy:send("ON")
    w.proxy:send("ON")
    w.run(10000)
    T.eq(policy .. ": the second On is not sent", #w.m.sent, 1)
    w.restore()
  end
end)

T.section(
  "the outbox: a newer level takes the level from an on waiting with its on color; what is left goes as a color"
)
case(function()
  local w = held({}, 0)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  -- The color's word comes before its read-back answers.
  w.m.stall(w.clock.now() + 1000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.run(500) -- part way up, so the newer level carries no on color of its own
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.m.sent = {}
  w.run(10000)
  local preOns, colorOn = 0, "none"
  for _, c in ipairs(w.m.sent) do
    if c.preOn then
      preOns = preOns + 1
    elseif c.color and c.level == nil then
      colorOn = c.on
    end
  end
  T.eq("no pre-on goes with what is left", preOns, 0)
  T.eq("which goes as a color saying the light is lit", colorOn, true)
  T.eq("and the light lands on the newer level", { w.proxy.level, w.devicePercent() }, { 30, 30 })
  w.restore()
end)

T.section("settle, the outbox: a command in flight past its window does not end on its target while a newer one waits")
case(function()
  local w = held({}, 0)
  w.m.stall(w.clock.now() + 8000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.proxy:mark()
  w.run(6000)
  T.eq("nothing is told past its window", w.proxy:changed(), {})
  w.run(10000)
  T.eq("and the newer lands", { w.proxy.level, w.devicePercent() }, { 40, 40 })
  w.restore()
end)

T.section("settle, the outbox: no report settles the target or color a waiting command keeps from the ask")
case(function()
  -- An on in its on color waits behind a color whose word is lost, and the color's read-back says off.
  local w = held({}, 30)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:mark()
  w.m.loseNext = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10)
  w.proxy:send("ON")
  w.run(60000)
  local levels = {}
  for _, q in ipairs(w.proxy:told("LIGHT_BRIGHTNESS_CHANGED")) do
    levels[#levels + 1] = q.LIGHT_BRIGHTNESS_CURRENT
  end
  T.eq("an off read back for the color ahead: the on is told 100 and nothing else", levels, { 100 })
  T.eq("and lands", { w.proxy.level, w.devicePercent() }, { 100, 100 })
  w.restore()
  -- The same on waits behind an off whose word is lost, and the off's read-back has the old color.
  w = held({}, 30)
  onMode(w, ON_PRESET)
  w.proxy:mark()
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(10)
  w.proxy:send("ON")
  w.run(60000)
  local told = toldColors(w)
  T.check(
    "the old color read back for the off ahead: the on color is told once",
    #told == 1 and near(told[1].x, ON_PRESET.x) and near(told[1].y, ON_PRESET.y),
    T.show(told)
  )
  T.check("and the light comes on in it", near(deviceColor(w).x, ON_PRESET.x), T.show(deviceColor(w)))
  w.restore()
  -- A color waits behind that on, which it took the on color from.
  w = held({}, 30)
  onMode(w, ON_PRESET)
  local before = toldColor(w)
  w.proxy:mark()
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(10)
  w.proxy:send("ON")
  w.run(10)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(60000)
  told = toldColors(w)
  local old = 0
  for i, c in ipairs(told) do
    old = old + ((i > 1 and near(c.x, before.x) and near(c.y, before.y)) and 1 or 0)
  end
  T.eq("a color behind it: the old color read back for the off ahead is never told", old, 0)
  T.check(
    "and the last color told is the one asked",
    near(told[#told].x, 0.3) and near(told[#told].y, 0.6),
    T.show(told)
  )
  w.restore()
  -- A level waits behind an on in its on color, which it took the level from.
  w = held({}, 30)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:mark()
  w.m.loseNext = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10)
  w.proxy:send("ON")
  w.run(10)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.run(60000)
  levels = {}
  for _, q in ipairs(w.proxy:told("LIGHT_BRIGHTNESS_CHANGED")) do
    levels[#levels + 1] = q.LIGHT_BRIGHTNESS_CURRENT
  end
  T.eq("a level behind it: the off read back for the color ahead is never told", levels, { 100, 70 })
  T.eq("and the light lands on the level asked", { w.proxy.level, w.devicePercent() }, { 70, 70 })
  w.restore()
  -- Under Dim-To-Warm a level waits behind a color whose word is lost, and another hand turns the light off.
  w = held({}, 50)
  onMode(w, WARM, DIM)
  w.run(10000)
  w.m.loseNext = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  local reads = w.m.reads
  w.m.other({ on = false })
  w.run(500)
  T.eq("an off heard while a level waits asks no read: the level goes after it", w.m.reads, reads)
  w.run(60000)
  T.eq("and lands", { w.proxy.level, w.devicePercent() }, { 70, 70 })
  w.restore()
end)

T.section("trust, the outbox: a report of what a waiting command sets is history, and tells nothing")
case(function()
  -- An on in its on color waits behind a color whose word is lost, while the provider pushes the light off.
  local w = held({ policy = "trust", pushEveryMs = 1000 }, 30)
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:mark()
  w.m.loseNext = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10)
  w.proxy:send("ON")
  w.run(1500)
  T.eq("a push while it waits is history, naming no command", w.m.lastVerdict.level, { kind = "history" })
  w.run(30000)
  T.eq("so in the 30 s it waits the on is told 100 and nothing else", w.proxy:changed(), { 100 })
  w.run(30000)
  T.eq("and lands", { w.proxy.level, w.devicePercent() }, { 100, 100 })
  w.restore()
  -- The same on waits behind an off whose word is lost, while the provider pushes the old color.
  w = held({ policy = "trust", pushEveryMs = 1000 }, 30)
  onMode(w, ON_PRESET)
  w.proxy:mark()
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(10)
  w.proxy:send("ON")
  w.run(60000)
  local told = toldColors(w)
  T.check(
    "behind an off: the on color is told once",
    #told == 1 and near(told[1].x, ON_PRESET.x) and near(told[1].y, ON_PRESET.y),
    T.show(told)
  )
  T.check("and the light comes on in it", near(deviceColor(w).x, ON_PRESET.x), T.show(deviceColor(w)))
  w.restore()
end)

T.section("the outbox: while one aspect's command waits, a report of the other is heard, under either policy")
case(function()
  for _, policy in ipairs({ "settle", "trust" }) do
    -- A level waits behind a level whose word is held; another hand sets a color.
    local w = held({ policy = policy }, 50)
    w.m.stall(w.clock.now() + 3000)
    w.proxy:send("SET_LEVEL", { LEVEL = 60 })
    w.proxy:send("SET_LEVEL", { LEVEL = 70 })
    w.proxy:mark()
    w.m.other({ color = { x = 0.2, y = 0.6 } })
    w.run(500)
    T.check(
      policy .. ": a color from another hand while a level waits is told",
      near(toldColor(w).x, 0.2),
      T.show(toldColor(w))
    )
    w.run(10000)
    w.restore()
    -- A color waits behind a color whose word is held; another hand sets a level.
    w = held({ policy = policy }, 50)
    w.m.stall(w.clock.now() + 3000)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.35, LIGHT_COLOR_TARGET_Y = 0.55, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
    w.proxy:mark()
    w.m.other({ on = true, level = 0.3 })
    w.run(500)
    T.eq(policy .. ": a level from another hand while a color waits is told", w.proxy:changed(), { 30 })
    w.run(10000)
    w.restore()
  end
end)

T.section("settle, the outbox: what is left of a stripped on goes as a color, with no level window of its own")
case(function()
  -- An off whose word is lost holds the level; a color sent after it holds the color, briefly.
  local w = held({ ackMs = 5000 }, 50)
  onMode(w, ON_PRESET)
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("ON")
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.proxy:mark()
  w.run(20000)
  T.eq("the proxy is told nothing until the newer level lands", w.proxy:changed(), {})
  T.eq("where it is", { w.proxy.level, w.devicePercent() }, { 30, 30 })
  w.restore()
  w = held({ ackMs = 5000 }, 50)
  onMode(w, ON_PRESET)
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("ON")
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.run(500)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.run(20000)
  T.eq("a level asked after what was left went replaces the waiting one", sentLevels(w), { 40 })
  w.restore()
  w = held({ ackMs = 5000 }, 50)
  onMode(w, ON_PRESET)
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("ON")
  w.proxy:send("OFF")
  w.m.sent = {}
  w.run(20000)
  local left = {}
  for _, c in ipairs(w.m.sent) do
    if c.color and c.level == nil then
      left[#left + 1] = c.on
    end
  end
  T.eq("what is left of an on an off took says the light is off", left, { false })
  T.eq("and it stays off", w.devicePercent(), 0)
  w.restore()
end)

T.section("the outbox: a color alone says whether the light is lit as it goes, under either policy")
case(function()
  -- The on of the last color alone the device was sent.
  local function lastColorOn(w)
    local on = "none"
    for _, c in ipairs(w.m.sent) do
      if c.color and c.level == nil then
        on = c.on
      end
    end
    return on
  end
  for _, policy in ipairs({ "settle", "trust" }) do
    -- A stop's color waits behind the color ramp's word.
    local w = held({ policy = policy, hold = true, holdShare = 1 }, 100)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
    )
    w.run(1000)
    w.proxy:send("SET_COLOR_STOP")
    w.run(200)
    w.proxy:send("OFF")
    w.run(20000)
    T.eq(policy .. ": a color that waited goes unlit after an Off asked since", lastColorOn(w), false)
    T.eq(policy .. ": so the light stays off", { w.proxy.level, w.devicePercent() }, { 0, 0 })
    w.restore()
    w = held({ policy = policy, hold = true, holdShare = 1 }, 0)
    w.proxy:send("OFF")
    w.run(10000)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
    )
    w.run(100)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
    w.run(100)
    w.proxy:send("SET_LEVEL", { LEVEL = 60 })
    w.run(20000)
    T.eq(policy .. ": one asked while off goes lit after an On asked since", lastColorOn(w), true)
    w.restore()
    -- Lit when asked, it goes with an off in flight and an on waiting behind it: the device has the off.
    w = held({ policy = policy, hold = true, holdShare = 1 }, 100)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 3000 }
    )
    w.run(100)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
    w.run(2000)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 1500 })
    w.run(100)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
    w.run(20000)
    T.eq(policy .. ": one that goes while an off is in flight and an on waits goes unlit", lastColorOn(w), false)
    T.eq(policy .. ": and the light lands at the on's level", { w.proxy.level, w.devicePercent() }, { 80, 80 })
    w.restore()
    -- A relay's scene step that turns it on in a color holds its level too: an Off asked since takes it.
    w = held({ policy = policy, dims = false, hold = true, holdShare = 1 }, 0)
    w.proxy:send("OFF")
    w.run(10000)
    scene(w, 7, { { level = 100, color = { x = 0.3, y = 0.6 } } })
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
    )
    w.run(100)
    w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
    w.run(100)
    w.proxy:send("OFF")
    w.run(20000)
    T.eq(
      policy .. ": a relay's scene step that waited does not undo an Off asked since",
      { w.proxy.level, w.devicePercent() },
      { 0, 0 }
    )
    w.restore()
    -- With nothing asked since, a push that still says off as it waits is history.
    w = held({ policy = policy, dims = false, hold = true, holdShare = 1, pushEveryMs = 700 }, 0)
    w.proxy:send("OFF")
    w.run(10000)
    scene(w, 7, { { level = 100, color = { x = 0.3, y = 0.6 } } })
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
    )
    w.run(100)
    w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
    w.run(20000)
    T.eq(
      policy .. ": a relay's scene step that waited turns it on, though a push said off as it waited",
      { w.proxy.level, w.devicePercent() },
      { 100, 100 }
    )
    w.restore()
    -- An Off during a relay's color fade does not wait for the fade's word, as for a light that dims.
    w = held({ policy = policy, dims = false, hold = true, holdShare = 1 }, 100)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
    )
    w.run(1000)
    w.m.sent = {}
    w.proxy:send("OFF")
    T.eq(policy .. ": a relay's Off in a color fade goes at once", sentLevels(w), { 0 })
    w.run(20000)
    w.restore()
  end
  -- With ack = send, the step's report is its own, not another hand's.
  local w = world({ dims = false }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  scene(w, 7, { { level = 100, color = { x = 0.3, y = 0.6 } } })
  w.m.sent = {}
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
  w.run(10000)
  local step = w.m.sent[1] or {}
  T.eq("ack = send: a relay's scene step in a color is heard as its own", w.m.lastVerdict.level, {
    kind = "own",
    seq = step.seq,
  })
  w.restore()
end)

T.section("the outbox: a unit frees only its own aspects at its word")
case(function()
  local function color(w, x)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = x, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end
  local w = held({ ackMs = 3000 }, 50)
  w.m.loseNext = true
  color(w, 0.3)
  color(w, 0.35)
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.run(1000)
  local colors = 0
  for _, c in ipairs(w.m.sent) do
    colors = colors + (c.color and 1 or 0)
  end
  T.eq("a level's word does not let a color waiting on a color go", colors, 1)
  w.run(10000)
  w.restore()
end)

T.section("the outbox: a waiting command decides its pre-on from where the light is by the commands sent")
case(function()
  local function preOns(w)
    local n = 0
    for _, c in ipairs(w.m.sent) do
      n = n + (c.preOn and 1 or 0)
    end
    return n
  end
  -- A ramp down whose word comes long after its time: the light is at its end, not past it.
  local w = held({}, 80)
  w.m.stall(w.clock.now() + 3000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 1000 })
  w.run(1500)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  w.run(10000)
  T.eq("behind a ramp down landed long ago: no pre-on", preOns(w), 0)
  w.restore()
  w = held({}, 100)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  w.run(10)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  w.run(10000)
  T.eq("just after a fade to off starts the light is lit: no pre-on", preOns(w), 0)
  w.restore()
  w = held({}, 100)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 1000 })
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.run(10000)
  T.eq("and early in a 1 s one, on its path from when it went: no pre-on", preOns(w), 0)
  w.restore()
  w = held({}, 100)
  local t0 = w.clock.now()
  w.m.stall(t0 + 748)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
  w.run(10)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  w.run(10000)
  T.eq("under half a level from its end the light is off: a pre-on", preOns(w), 1)
  w.restore()
  w = held({}, 50)
  w.m.stall(w.clock.now() + 1000)
  w.proxy:send("OFF")
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  w.run(10000)
  T.eq("an unrated level and a rated off take none", preOns(w), 0)
  w.restore()
end)

T.section("the outbox under Dim-To-Warm: a pre-on added at the go keeps the command's mix, told at the ramp's end")
case(function()
  local w = held({}, 100)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
  w.m.stall(w.clock.now() + 800)
  w.run(10)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  w.proxy:mark()
  w.run(1000)
  T.eq("no color is told at the go", #toldColors(w), 0)
  w.run(10000)
  T.eq("one at the ramp's end", #toldColors(w), 1)
  w.restore()
end)

T.section("the outbox: a waiting level with a color is sent though the level it waited behind landed there")
case(function()
  local w = held({ hold = true }, 0)
  onMode(w, WARM, DIM)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.m.sent = {}
  w.run(4000)
  T.eq("it goes, with its mix", #w.m.sent, 1)
  w.run(10000)
  w.restore()
  -- With the device's reports lost, only the window's own time ends it.
  w = held({
    hold = true,
    drop = function(kind)
      return kind == "report"
    end,
  }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.run(10000)
  T.eq("one with none sends nothing, and its window still closes", w.light.device.settle, nil)
  w.restore()
end)

T.section("ack = done: an answer heard before the newest command's word is of the light after the command")
case(function()
  -- Words stall, so the Off's read-back is answered long before its word comes.
  local w = held({}, 60)
  w.m.stall(w.clock.now() + 20000)
  w.proxy:send("OFF")
  w.run(500)
  w.m.other({ on = true, level = 0.33 })
  w.run(4000)
  T.eq("the read-back's answer shows another hand's turn-on before the word", { w.proxy.level, w.devicePercent() }, {
    33,
    33,
  })
  w.restore()
end)

T.section(
  "settle, ack = done: an on or off heard before its command's word that is the command's says where the light is"
)
case(function()
  -- A rated on from off has its word at its transition's end, so its turn-on is heard as history.
  local w = held({ hold = true }, 0)
  w.m.dropReads = true
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 2000 })
  w.run(2500)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(1500)
  w.m.other({ on = true, level = 0.89 })
  w.run(20000)
  T.eq("a level heard after it settles the next command, so another hand's level then shows", w.proxy.level, 89)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(20000)
  T.eq("and the level asked again goes", { w.proxy.level, w.devicePercent() }, { 100, 100 })
  w.restore()
  -- So for a level asked right behind it, which waits: what is heard meanwhile is the rated on's history too.
  w = held({ hold = true }, 0)
  w.m.dropReads = true
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 2000 })
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(3000)
  w.m.other({ on = true, level = 0.89 })
  w.run(20000)
  T.eq("a level waiting behind it settles too, so another hand's level then shows", w.proxy.level, 89)
  w.restore()
  -- Only the newest level command's on or off, from its own control's report or a whole one, and no snapshot.
  local function stalled()
    local s = held({}, 0)
    s.m.o.drop = function(kind)
      return kind == "report" -- only the reports given here are heard
    end
    s.m.stall(s.clock.now() + 20000)
    return s
  end
  w = stalled()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 2000 })
  local word = w.light.device.word
  w.light:report({ on = true }, { snapshot = true })
  T.eq("a snapshot heard so sets no on", word.on, false)
  w.light:report({ on = true, level = 0.3 }, { control = "level" })
  T.eq("nor does an on riding a level report", word.on, false)
  w.light:report({ on = false }, { control = "onOff" })
  T.eq("nor an off while the command lights the light", word.on, false)
  w.light:report({ on = true }, { control = "onOff" })
  T.eq("an on the command sets is the device's word", word.on, true)
  w.restore()
  -- A pre-on left alone by its ramp's raise has no level to judge by: neither its on nor an off is taken.
  local function lonePreOn(s)
    local send, calls = s.m.adapter.send, 0
    s.m.adapter.send = function(self, cmd)
      calls = calls + 1
      if calls == 2 then
        error("frame too long", 0)
      end
      return send(self, cmd)
    end
    pcall(s.proxy.send, s.proxy, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 2000 })
    s.m.adapter.send = send
  end
  w = stalled()
  lonePreOn(w)
  word = w.light.device.word
  w.light:report({ on = true }, { control = "onOff" })
  T.eq("an on heard before a lone pre-on's word is not the device's word", word.on, false)
  w.restore()
  w = stalled()
  w.light:report({ on = true }, { control = "onOff" }) -- another hand's turn-on, read for its level
  lonePreOn(w)
  word = w.light.device.word
  w.light:report({ on = false }, { control = "onOff" })
  T.eq("nor is an off", word.on, true)
  w.restore()
  -- So the read its word asks tells the level the pre-on lit the light at, not the one the light last had.
  w = held({ hold = true }, 50)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:mark()
  lonePreOn(w)
  w.run(20000)
  T.eq("the read after a lone pre-on tells the level it lit the light at, and no other", w.proxy:changed(), { 1 })
  w.restore()
  -- Another hand's turn-on heard so in an off, whose word is lost, is not the off's: it is read for its level.
  w = held({ ackMs = 3000 }, 50)
  w.m.loseNext = true
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  w.run(4000)
  w.proxy:mark()
  w.m.other({ on = true, level = 0.9 })
  w.run(20000)
  T.eq("another hand's turn-on is told at the level read, and no other first", w.proxy:changed(), { 90 })
  w.restore()
end)

T.section("the outbox: a waiting level the command ahead lands on goes again when that command had no word")
case(function()
  local w = held({ ackMs = 3000 }, 60)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 20 })
  w.proxy:send("SET_LEVEL", { LEVEL = 80 })
  w.run(500)
  w.m.other({ on = true, level = 0.4 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 20 })
  w.run(10000)
  T.eq("the level asked last goes at the timeout", { w.proxy.level, w.devicePercent() }, { 20, 20 })
  w.restore()
end)

T.section("ack = done: a light heard away from where the newest command landed it is read at its word, and asked again")
case(function()
  -- Words stall: what the device says meanwhile is history.
  local function stalled(level, policy)
    local w = held({ policy = policy }, level)
    w.m.stall(w.clock.now() + 20000)
    return w
  end
  local w = stalled(60)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(1000)
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(30000)
  T.eq("a waiting level asked after the light was heard away goes", { w.proxy.level, w.devicePercent() }, { 50, 50 })
  w.restore()
  for _, policy in ipairs({ "settle", "trust" }) do
    w = stalled(60, policy)
    w.proxy:send("SET_LEVEL", { LEVEL = 50 })
    w.run(1000)
    w.m.other({ on = false })
    w.run(1000)
    w.proxy:send("SET_LEVEL", { LEVEL = 50 })
    w.run(30000)
    T.eq(policy .. ": so does the level shown, asked again", { w.proxy.level, w.devicePercent() }, { 50, 50 })
    w.restore()
  end
  -- Under trust, which reads nothing back, another hand's level on a ramp's path asks no read when heard.
  w = held({ policy = "trust" }, 0)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  w.run(3000)
  w.m.stall(w.clock.now() + 20000)
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.run(1000)
  w.m.other({ on = true, level = 0.5 })
  w.run(30000)
  T.eq("and the read at the word shows the light where it is", { w.proxy.level, w.devicePercent() }, { 50, 50 })
  w.restore()
end)

T.section("the outbox: a waiting level the command ahead lands on sends nothing and asks a read, under either policy")
case(function()
  for _, policy in ipairs({ "settle", "trust" }) do
    -- Another hand turns the light off while the level waits, and the device reads nothing back of its own.
    local w = held({ hold = true, policy = policy, readbackMs = 1e8 }, 0)
    w.proxy:send("OFF")
    w.run(10000)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
    w.run(500)
    w.proxy:send("SET_LEVEL", { LEVEL = 70 })
    w.run(300)
    local reads = w.m.reads
    w.m.sent = {}
    w.m.other({ on = false })
    w.run(30000)
    T.eq(policy .. ": the level is not sent again", sentLevels(w), {})
    T.eq(policy .. ": its go asks one read, as what it heard while it waited was history", w.m.reads - reads, 1)
    T.eq(policy .. ": which shows the light off, where it is", { w.proxy.level, w.devicePercent() }, { 0, 0 })
    w.restore()
  end
end)

T.section("the outbox: a waiting level goes when another hand has moved the light off the one before it")
case(function()
  -- Under Dim-To-Warm a level carries a color, so it waits behind a color whose word is lost.
  local w = held({ ackMs = 1000 }, 50)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  w.run(10000)
  w.m.other({ on = true, level = 0.8 })
  w.run(2000)
  w.m.loseNext = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  w.run(10000)
  T.eq("the off goes at the timeout, and the light ends off", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
  -- A device that pushes its state says the light is away again while the level waits: that hides nothing.
  w = held({ ackMs = 10000, policy = "trust", pushEveryMs = 5000 }, 50)
  onMode(w, WARM, DIM)
  w.run(2500) -- the off goes between pushes, so none crosses it
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  w.run(10000)
  w.m.other({ on = true, level = 0.8 })
  w.run(2000)
  w.m.loseNext = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  w.run(30000)
  T.eq("so it does when the light is heard away again as it waits", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
  -- So it does when the turn-on was heard as history, behind an off whose word is late.
  w = held({ policy = "trust", pushEveryMs = 500 }, 50)
  w.m.stall(w.clock.now() + 5000)
  w.proxy:send("OFF")
  w.run(1000)
  w.m.other({ on = true, level = 0.8 })
  w.run(1000)
  w.proxy:send("OFF")
  w.run(30000)
  T.eq("an off asked after a turn-on heard as history goes too", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
end)

T.section("trust, the outbox: a waiting command keeps no window, so a level later told is not sent again")
case(function()
  local w = held({ policy = "trust", keepsLevel = false }, 20)
  w.m.stall(w.clock.now() + 1000)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(10000)
  w.m.other({ on = true, level = 0.4 })
  w.run(500)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  T.eq("the level shown goes nowhere", #w.m.sent, 0)
  w.restore()
end)

T.section("a change of ack to send sends what waits as each would have gone: its pre-on, and nothing gone or landed")
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.m.sent = {}
  w.m.o.ack = "send"
  w.light:declare(w.m.declaration())
  T.eq("only the newest goes", sentLevels(w), { 40 })
  w.run(10000)
  w.restore()
  w = held({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.stall(w.clock.now() + 5000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 3000 })
  w.run(1500)
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.run(2000)
  w.m.sent = {}
  w.m.o.ack = "send"
  w.light:declare(w.m.declaration())
  T.eq("a level the held one has landed on goes nowhere", #w.m.sent, 0)
  w.run(10000)
  w.restore()
  w = held({ hold = true }, 100)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
  w.m.stall(w.clock.now() + 3000)
  w.run(1000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
  w.m.sent = {}
  w.m.o.ack = "send"
  w.light:declare(w.m.declaration())
  T.eq("a rated on from off goes after its pre-on", { (w.m.sent[1] or {}).preOn, #w.m.sent }, { true, 2 })
  w.run(10000)
  w.restore()
end)

T.section("the outbox: a stop held outside the range goes, though the ramp it waited behind landed on its level")
case(function()
  local w = held({}, 100)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.run(1000)
  w.m.stall(w.clock.now() + 3000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 2000 })
  w.run(1000)
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.m.sent = {}
  w.run(10000)
  local stop = (w.m.sent[1] or {}).level
  T.check("it is sent at its place", stop ~= nil and stop > 0.85, T.show(w.m.sent))
  w.restore()
end)

T.section(
  "the outbox and the ledger: a waiting level waits on a level, a superseded read is over at once, and ack = send dates what was in flight"
)
case(function()
  local w = held({ ackMs = 3000 }, 50)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(1000)
  local levels = 0
  for _, c in ipairs(w.m.sent) do
    levels = levels + (c.level and 1 or 0)
  end
  T.eq("a color's word does not let a level waiting on a level go", levels, 1)
  w.run(10000)
  w.restore()
  w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(200)
  w.run(10000)
  w.restore()
  w = held({
    ackMs = 1000,
    drop = function(kind)
      return kind == "read"
    end,
  }, 50)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(1100)
  T.check("a timeout asks a read", w.light.device.read ~= nil)
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  T.eq("a level sent then supersedes it at once", w.light.device.read, nil)
  w.run(10000)
  w.restore()
  w = held({}, 20)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.m.o.ack = "send"
  w.light:declare(w.m.declaration())
  w.run(10000)
  T.eq("after ack = send, nothing waits on a word", w.light:_pending(), false)
  w.restore()
end)

T.section("the outbox: an on color added at the go is told as its preset")
case(function()
  local w = held({ hold = true, holdShare = 1 }, 100)
  onMode(w, ON_PRESET)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
  w.run(600)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.run(1000)
  T.eq(
    "its CHANGED names the on preset",
    (w.proxy:told("LIGHT_COLOR_CHANGED")[1] or {}).LIGHT_COLOR_CURRENT_PRESET_ID,
    1
  )
  w.run(10000)
  w.restore()
end)

T.section("the outbox: an on color the go adds holds the color, and a color asked since wins over it")
case(function()
  -- An on asked late in a fade to off whose word is held to its end, or lost, finds the light off at its go.
  local function lateOn(lost)
    local w = held({ hold = true, holdShare = 1, ackMs = 1000 }, 100)
    onMode(w, ON_PRESET)
    w.m.loseNext = lost
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
    w.run(600)
    w.m.sent = {}
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
    return w
  end
  local green = { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  local w = lateOn()
  w.run(1000)
  local n = #w.m.sent
  w.proxy:send("SET_COLOR_TARGET", green)
  T.eq("a color asked while the ramp with its on color is in flight waits", #w.m.sent, n)
  w.run(10000)
  T.check("and goes at the ramp's word", near(deviceColor(w).x, 0.3, 0.01), T.show(deviceColor(w)))
  w.restore()
  w = lateOn()
  w.run(50)
  w.proxy:send("SET_COLOR_TARGET", green)
  T.eq("a color asked before the go says the light is off, as the device has it", (w.m.sent[1] or {}).on, false)
  w.run(10000)
  local c, t = deviceColor(w), toldColor(w)
  T.check(
    "the go adds no on color over it: the device ends in it",
    near(c.x, 0.3, 0.01) and near(c.y, 0.6, 0.01),
    T.show(c)
  )
  T.check("and the proxy shows it", near(t.x, 0.3, 0.01) and near(t.y, 0.6, 0.01), T.show(t))
  T.eq("the level lands", { w.proxy.level, w.devicePercent() }, { 80, 80 })
  w.restore()
  -- The off's word lost: the color has its own word before the on goes, at the off's timeout.
  w = lateOn(true)
  w.run(50)
  w.proxy:send("SET_COLOR_TARGET", green)
  w.run(10000)
  c = deviceColor(w)
  T.check(
    "a color asked since still wins once its word is in",
    near(c.x, 0.3, 0.01) and near(c.y, 0.6, 0.01),
    T.show(c)
  )
  w.restore()
  -- A color asked just before the on, still in flight at its go, keeps the color.
  w = held({ hold = true, holdShare = 1 }, 100)
  onMode(w, ON_PRESET)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
  w.run(550)
  w.proxy:send("SET_COLOR_TARGET", green)
  w.run(50)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.run(10000)
  c = deviceColor(w)
  T.check("a color in flight at the go keeps the color", near(c.x, 0.3, 0.01) and near(c.y, 0.6, 0.01), T.show(c))
  w.restore()
end)

--------------------------------------------------------------------------------
-- The ledger
--------------------------------------------------------------------------------

T.section("the ledger: with ack = done a report heard before the newest command's word is history, and tells nothing")
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 5000 })
  w.run(1000)
  w.proxy:mark()
  w.m.push({ on = true, level = 1 }, { control = "level" })
  w.run(200)
  T.eq("a report of full from before the word is not told", w.proxy:changed(), {})
  T.eq("its verdict is history", w.m.lastVerdict.level.kind, "history")
  w.run(10000)
  T.eq("the ramp lands as told", w.proxy:changed(), { 60 })
  T.eq("where the device is", w.devicePercent(), 60)
  w.restore()
end)

T.section(
  "the ledger: another hand's Off during a held rated on from off asks a read, told from its answer after the word"
)
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(2000)
  local reads = w.m.reads
  w.proxy:mark()
  w.m.other({ on = false })
  w.run(200)
  T.eq("the off is dropped as history", w.proxy:changed(), {})
  T.eq("and asks one read", w.m.reads, reads + 1)
  w.run(10000)
  T.eq("which, answered after the word, shows the light off", w.proxy.level, 0)
  T.eq("where it is", w.devicePercent(), 0)
  w.restore()
end)

T.section("the ledger: a color report heard before the newest color command's word is history too")
case(function()
  local w = held({ policy = "trust" }, 50)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(200)
  w.proxy:mark()
  w.m.push({ color = { x = RED.x, y = RED.y } }, {})
  w.run(200)
  T.eq("a color from before the word is not told", w.proxy:told("LIGHT_COLOR_CHANGED"), {})
  T.eq("its verdict is history", w.m.lastVerdict.color.kind, "history")
  w.run(5000)
  T.check("the proxy keeps the color sent", near(toldColor(w).x, 0.3, 0.01), T.show(toldColor(w)))
  w.restore()
  -- A color waiting behind it has no seq yet.
  w = held({ policy = "trust" }, 50)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.m.push({ color = { x = RED.x, y = RED.y } }, {})
  w.run(200)
  T.eq("with a color waiting behind it, it names no command", w.m.lastVerdict.color, { kind = "history" })
  w.run(5000)
  w.restore()
  -- A color alone from before the word tells no level either, though a new range moved the one shown.
  w = held({}, 50)
  w.m.stall(w.clock.now() + 5000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.proxy:mark()
  local v = w.light:report({ color = { x = 0.2, y = 0.5 } }, { control = "color" })
  T.eq(
    "a color alone from before the word tells no level a new range moved",
    { v.color.kind, w.proxy:changed() },
    { "history", {} }
  )
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a late report on an older command's path, within the late margin, asks no read")
case(function()
  local w = held({ ackMs = 2000 }, 90)
  w.proxy:send("SET_LEVEL", { LEVEL = 10 })
  w.run(200)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(200)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.run(100)
  local reads = w.m.reads
  w.m.push({ on = true, level = 0.8 }, { control = "level" })
  w.run(200)
  T.eq("a level on the first command's path alone is history", w.m.lastVerdict.level.kind, "history")
  T.eq("and asks no read: the first command is still in the ledger", w.m.reads, reads)
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a read the library asked ends at an answer, at a command after it, or settleMs after the word")
case(function()
  -- Answered: an answer ends the read even while the word is held, so the next off before the word asks a read at once.
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(200)
  T.check("an off before the word asks a read", w.light:_readUnanswered())
  w.m.push({ on = false }, { control = "onOff", answer = "final" })
  w.run(200)
  T.check("its answer ends it before the word", not w.light:_readUnanswered())
  local reads = w.m.reads
  w.m.push({ on = false }, { control = "onOff" })
  w.run(200)
  T.eq("so the next off before the word asks a read at once", w.m.reads, reads + 1)
  w.run(10000)
  w.restore()
  -- Superseded: a level command waiting behind the held ramp goes at the word, and its read-back shows the light.
  w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(200)
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  reads = w.m.reads
  w.run(10000)
  T.eq("superseded by a level command: no read is asked again", w.m.reads, reads)
  T.eq("and the light shows that command", { w.proxy.level, w.devicePercent() }, { 40, 40 })
  T.eq("the read is over", w.light.device.read, nil)
  w.restore()
  -- A color sent unlit arms no read-back, so the read is asked once more at its word.
  w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(200)
  reads = w.m.reads
  w.proxy:send("OFF")
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("a color for the light heading off goes unlit, at once", (w.m.sent[1] or {}).on, false)
  w.run(10000)
  T.eq("superseded by a color alone: asked once more at its word", w.m.reads, reads + 1)
  w.restore()
  -- An answer that never comes holds the next read back only until settleMs after the word.
  w = held({
    hold = true,
    drop = function(kind)
      return kind == "read"
    end,
  }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
  w.run(500)
  w.m.other({ on = false })
  w.run(200)
  reads = w.m.reads
  T.check("a read is unanswered", w.light:_readUnanswered())
  w.run(3000 + w.m.declaration().reports.settleMs + 500)
  T.check("settleMs after the word it is over", not w.light:_readUnanswered())
  w.restore()
end)

T.section(
  "the ledger: a word that never comes lets what waits go at the timeout, and reads the light only when nothing waited"
)
case(function()
  local w = held({ ackMs = 2000 }, 20)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  local reads = w.m.reads
  w.run(1900)
  T.eq("the next waits for the lost word", sentLevels(w), { 50 })
  w.run(200)
  T.eq("at the timeout it goes", sentLevels(w), { 50, 60 })
  T.eq("and the light is not read: a command went", w.m.reads, reads)
  w.run(10000)
  w.m.loseNext = true
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  reads = w.m.reads
  w.run(2100)
  T.eq("a lost word with nothing waiting: one read at the timeout", w.m.reads, reads + 1)
  w.run(10000)
  T.eq("and the light shows where it is", { w.proxy.level, w.devicePercent() }, { 30, 30 })
  w.restore()
end)

T.section("the ledger: the timeout is the send plus 1.5 times the transition plus ackMs")
case(function()
  local w = held({ ackMs = 2000 }, 20)
  w.m.loseNext = true
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(4900)
  T.eq("what waits behind a 2 s ramp whose word is lost holds to 5 s", sentLevels(w), { 80 })
  w.run(200)
  T.eq("and goes then", sentLevels(w), { 80, 60 })
  w.run(10000)
  w.restore()
end)

T.section("a change of settleMs, match or ackMs during a connection judges what comes next")
case(function()
  local w = held({ ackMs = 2000 }, 20)
  w.m.o.ackMs, w.m.o.match = 4000, 0.05
  w.light:declare(w.m.declaration())
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(3900)
  T.eq("what waits behind a lost word holds to the new ackMs", sentLevels(w), { 50 })
  w.run(200)
  T.eq("and goes at it", sentLevels(w), { 50, 60 })
  w.run(10000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.proxy:mark()
  w.m.other({ color = { x = 0.33, y = 0.5 } })
  w.run(10000)
  T.eq("a color within the new match reads as the one told", toldColors(w), {})
  w.restore()
end)

T.section(
  "the ledger: a word saying not delivered drops the command and reads the light; one from another load is ignored"
)
case(function()
  local w = held({}, 20)
  w.m.failNext = true
  local reads = w.m.reads
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(200)
  T.eq("not delivered: the light is read", w.m.reads, reads + 1)
  local inLedger = false
  for _, entry in ipairs(w.light.device.ledger.level) do
    inLedger = inLedger or entry.seq == (w.m.sent[1] or {}).seq
  end
  T.eq("and the command is out of the ledger", inLedger, false)
  w.run(10000)
  w.m.epochOverride = "another load"
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  w.proxy:send("SET_LEVEL", { LEVEL = 75 })
  w.run(1000)
  T.eq("a word with another load's epoch is ignored: the next still waits", sentLevels(w), { 70 })
  w.m.epochOverride = nil
  w.run(50000)
  T.eq("until the timeout", sentLevels(w), { 70, 75 })
  w.restore()
end)

T.section("a change of ack to send stops waiting at once: what waits goes")
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.m.sent = {}
  w.m.o.ack = "send"
  w.light:declare(w.m.declaration())
  T.eq("the waiting level goes now", sentLevels(w), { 30 })
  w.run(10000)
  T.eq("and lands", w.devicePercent(), 30)
  w.restore()
end)

T.section("the ledger: an entry older than one that has landed past the late margin is pruned, and no sooner")
case(function()
  -- Each case ends with a report from before a lost word, on the path of one older entry alone.
  local function readsFor(steps, report)
    local w = held({ ackMs = 2000 }, 90)
    for _, step in ipairs(steps) do
      if step.lose then
        w.m.loseNext = true
      end
      if step.rate then
        w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = step.level, RATE = step.rate })
      else
        w.proxy:send("SET_LEVEL", { LEVEL = step.level })
      end
      w.run(step.wait or 200)
    end
    local reads = w.m.reads
    w.m.push({ on = true, level = report }, { control = "level" })
    w.run(200)
    reads = w.m.reads - reads
    w.run(20000)
    w.restore()
    return reads
  end
  T.eq(
    "past the margin after a newer landing, an older path is gone: a report on it asks a read",
    readsFor({ { level = 10 }, { level = 60, wait = 3000 }, { level = 70, lose = true } }, 0.8),
    1
  )
  T.eq(
    "the landed entry stays: a report on its path asks none",
    readsFor({ { level = 10 }, { level = 60, wait = 3000 }, { level = 70, lose = true } }, 0.4),
    0
  )
  T.eq(
    "an entry still in its transition prunes nothing",
    readsFor({ { level = 10 }, { level = 20, rate = 10000, wait = 3000 }, { level = 25, lose = true } }, 0.7),
    0
  )
  T.eq(
    "nor one with no word",
    readsFor({ { level = 10 }, { level = 20, lose = true, wait = 3000 }, { level = 25, lose = true } }, 0.7),
    0
  )
end)

T.section("the ledger: a color heard before the color command's word is never told, though the level with it is taken")
case(function()
  for _, policy in ipairs({ "settle", "trust" }) do
    local w = held({
      policy = policy,
      keepsLevel = false,
      drop = function(kind)
        return kind == "read"
      end,
    }, 50)
    local old = w.m.device:report(w.clock.now()).color
    w.m.stall(w.clock.now() + 2000)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
    w.run(200)
    w.m.push({ on = true, level = 0.5, color = old }, { control = "color" })
    w.run(10000)
    T.check(policy .. ": the proxy ends on the color sent", near((toldColor(w) or {}).x, 0.3), T.show(toldColor(w)))
    w.restore()
  end
end)

T.section("the ledger under trust: a level heard before the newest command's word is history, and tells nothing")
case(function()
  local w = held({ policy = "trust", keepsLevel = false }, 20)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(200)
  w.proxy:mark()
  -- With a color that is no history, so the report is judged and its level dropped.
  w.m.push({ on = true, level = 0.2, color = w.m.device:report(w.clock.now()).color }, {})
  w.run(200)
  T.eq("not told", w.proxy:changed(), {})
  T.eq("its verdict is history, naming the command", { w.m.lastVerdict.level.kind, w.m.lastVerdict.level.seq }, {
    "history",
    (w.m.sent[#w.m.sent] or {}).seq,
  })
  w.run(10000)
  T.eq(
    "its own verdict names it too",
    (w.light:report({ on = true, level = 0.6 }, {}) or {}).level.seq,
    (w.m.sent[#w.m.sent] or {}).seq
  )
  w.restore()
end)

T.section("the ledger: a read superseded by an off, or by a color to a lit light, is not asked again")
case(function()
  local function rig()
    local w = held({ hold = true }, 0)
    w.proxy:send("OFF")
    w.run(10000)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
    w.run(1000)
    w.m.other({ on = false })
    w.run(200)
    return w
  end
  local w = rig()
  local reads = w.m.reads
  w.proxy:send("OFF")
  w.run(10000)
  T.eq("an off: its read-back shows the light", w.m.reads, reads)
  w.restore()
  w = rig()
  reads = w.m.reads
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("a color to a light on its way up says it is lit", (w.m.sent[#w.m.sent] or {}).on, true)
  T.eq("and arms a read-back of its own: no read is owed at its word", w.light.device.reask, nil)
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a transition is dated from the command's word, for the verdict of each aspect")
case(function()
  local w = held({}, 20)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
  )
  w.run(3000)
  local v = w.light:report({ on = true, level = 0.4, color = { x = 0.4, y = 0.4 } }, { control = "level" })
  T.eq("a part-way level 3 s after the send, 1 s after the word, is own", v.level.kind, "own")
  T.eq("and so is a part-way color", v.color.kind, "own")
  w.run(10000)
  w.restore()
end)

T.section("the ledger: news heard before the newest command's word is history too, and ends no ramp")
case(function()
  local w = held({ policy = "trust", keepsLevel = false }, 20)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(500)
  w.light:report({ on = true, level = 0.3 }, { news = true })
  T.check("the ramp runs on", w.light.aim.level ~= nil)
  w.run(10000)
  w.restore()
  w = held({ policy = "trust" }, 20)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.35, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(500)
  w.light:report({ on = true, level = 0.2, color = { x = 0.2, y = 0.3 } }, { news = true })
  T.check("so does a color ramp, though the news came with a level heard as it is", w.light.aim.color ~= nil)
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a level before its command's word is dropped, but a new color riding with it is told")
case(function()
  local w = held({}, 20)
  w.m.stall(w.clock.now() + 2000)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(200)
  w.light:report({ on = true, level = 0.2, color = { x = 0.2, y = 0.2 } }, { control = "level" })
  T.check("the color is told", near((toldColor(w) or {}).x, 0.2), T.show(toldColor(w)))
  w.run(10000)
  w.restore()
end)

T.section("the ledger: which reports from before the word ask a read")
case(function()
  local function reads(report, meta, offFirst)
    local w = held({ hold = true }, offFirst and 50 or 0)
    local n = w.m.reads
    if offFirst then
      w.m.stall(w.clock.now() + 3000)
      w.proxy:send("OFF")
    else
      w.proxy:send("OFF")
      w.run(10000)
      w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 5000 })
    end
    w.run(1000)
    w.light:report(report, meta)
    n = w.m.reads - n
    w.run(10000)
    w.restore()
    return n
  end
  T.eq("an off in a snapshot asks none", reads({ on = false }, { snapshot = true }), 0)
  T.eq("nor an off riding a level report", reads({ on = false, level = 0.95 }, { control = "level" }), 0)
  T.eq("nor an off while the newest command is an off", reads({ on = false }, { control = "onOff" }, true), 0)
  T.eq("nor an OnOff report riding a level off the path", reads({ on = true, level = 0.95 }, { control = "onOff" }), 0)
  T.eq(
    "nor an off riding a color report",
    reads({ on = false, color = { x = 0.3, y = 0.6 } }, { control = "color" }),
    0
  )
  T.eq(
    "nor a level off every path riding one",
    reads({ on = true, level = 0.95, color = { x = 0.3, y = 0.6 } }, { control = "color" }),
    0
  )
  T.eq("a level off every path asks one", reads({ on = true, level = 0.95 }, { control = "level" }), 1)
  -- A level owed its word, and only a color waiting: the off is still the level's to read.
  local w = held({}, 50)
  w.m.stall(w.clock.now() + 5000)
  w.proxy:send("SET_LEVEL", { LEVEL = 80 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  local n = w.m.reads
  w.light:report({ on = false }, { control = "onOff" })
  T.eq("an off while only a color waits asks one", w.m.reads - n, 1)
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a level within the device's step of a path's end is on the path")
case(function()
  local w = held({ ackMs = 2000 }, 50)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 40 })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 45 })
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(3000) -- past the late margin, so the path from 100 is pruned at the next send
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 55 })
  w.run(100)
  local reads = w.m.reads
  w.light:report({ on = true, level = (40 + 62 * 5 / 99) / 100 }, { control = "level" })
  T.eq("63 against paths ending at 60, four levels to a step: no read", w.m.reads, reads)
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a read asked again after a color alone is not asked a third time")
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(200)
  w.proxy:send("OFF")
  local function color(x)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = x, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end
  color(0.3)
  -- The color's word comes after the ramp's, which the transport holds; then the read is asked again.
  for _ = 1, 1000 do
    w.run(10)
    if (w.light.device.read or {}).reasked then
      break
    end
  end
  T.check("the read is asked again at the color's word", (w.light.device.read or {}).reasked)
  color(0.35)
  T.eq("a second color alone owes no read at its word", w.light.device.reask, nil)
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a word after its timeout is ignored, and a word with no ok given is delivered")
case(function()
  local w = held({
    ackMs = 1000,
    drop = function(kind)
      return kind == "read"
    end,
  }, 50)
  w.m.stall(w.clock.now() + 5000)
  w.m.failNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(2000)
  local reads = w.m.reads
  w.run(5000)
  T.eq("a late word saying not delivered asks nothing", w.m.reads, reads)
  w.restore()
  w = held({}, 50)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(200)
  reads = w.m.reads
  local cmd = w.m.sent[#w.m.sent] or {}
  w.light:done(cmd.seq, nil, cmd.epoch)
  T.eq("done with no ok asks no read", w.m.reads, reads)
  local inLedger = false
  for _, entry in ipairs(w.light.device.ledger.level) do
    inLedger = inLedger or entry.seq == cmd.seq
  end
  T.check("and keeps the command in the ledger", inLedger)
  w.restore()
end)

T.section("the ledger: an undelivered word that let a waiting command go asks no read")
case(function()
  local w = held({}, 50)
  w.m.dropNext, w.m.failNext = true, true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  local reads = w.m.reads
  w.run(100)
  T.eq("at the word the command that went reads the light back: none is asked", w.m.reads, reads)
  w.run(10000)
  T.eq("which lands", { w.proxy.level, w.devicePercent() }, { 40, 40 })
  w.restore()
end)

T.section("the ledger: a read asked in flight is unanswered until settleMs after the word, not after the ask")
case(function()
  local w = held({
    hold = true,
    drop = function(kind)
      return kind == "read"
    end,
  }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(500)
  w.m.other({ on = false })
  w.run(200)
  w.run(w.m.declaration().reports.settleMs + 500)
  T.check("past settleMs from the ask, before the word, it is unanswered", w.light:_readUnanswered())
  w.run(3000)
  T.check("just after the word it still is", w.light:_readUnanswered())
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a read asked with nothing in flight is over settleMs on, and forgotten then")
case(function()
  local w = held({
    ackMs = 2000,
    drop = function(kind)
      return kind == "read"
    end,
  }, 50)
  w.m.loseNext = true
  w.proxy:send("OFF")
  w.run(2000)
  T.check("at the timeout a read is asked", w.light:_readUnanswered())
  w.run(w.m.declaration().reports.settleMs)
  T.check("settleMs on it is over", not w.light:_readUnanswered())
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("so a color after it owes no read", w.light.device.reask, nil)
  w.restore()
end)

T.section("the ledger: one core read at a time")
case(function()
  local w = held({
    hold = true,
    drop = function(kind)
      return kind == "read"
    end,
  }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(500)
  local reads = w.m.reads
  w.light:report({ on = false }, { control = "onOff" })
  w.light:report({ on = false }, { control = "onOff" })
  T.eq("two offs from before the word ask one read", w.m.reads, reads + 1)
  w.run(10000)
  w.restore()
end)

T.section("the ledger: a color that supersedes a read asks it again at its own word, not at another's")
case(function()
  local w = held({ hold = true }, 0)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
  w.run(1000)
  w.m.other({ on = false })
  w.run(200)
  w.proxy:send("OFF")
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  local color = (w.m.sent[#w.m.sent] or {}).seq
  local words = #w.m.words
  for _ = 1, 2000 do
    w.run(5)
    if #w.m.words > words then
      break
    end
  end
  T.eq("at the ramp's word it is still owed", w.light.device.reask, color)
  w.run(10000)
  w.restore()
end)

T.section("with no level command in the ledger, where the device has the light is its own word")
case(function()
  local w = world({
    drop = function(kind)
      return kind == "report"
    end,
  }, 50)
  w.proxy:send("SET_LEVEL", { LEVEL = 20 })
  w.m.o.policy = "trust"
  w.light:declare(w.m.declaration())
  T.eq("the word, not the level told", w.light:_deviceLevel(), 50)
  w.restore()
end)

--------------------------------------------------------------------------------
-- The held transport, replaying two measured sequences
--------------------------------------------------------------------------------

--- The CHANGED levels told since `since`, with when, relative to `t0`.
local function changedSince(w, t0)
  local out = {}
  for _, n in ipairs(w.proxy.notes) do
    if n.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
      out[#out + 1] = { math.floor((n.at - t0) / 10 + 0.5) / 100, n.params.LIGHT_BRIGHTNESS_CURRENT }
    end
  end
  return out
end

T.section("buttons take 1, a bottom click then a toggle: no level is told from a report before the word")
case(function()
  local w = held({ hold = true, policy = "settle", settleMs = 2500 }, 100)
  w.proxy:send("SET_HOLD_RATE_DOWN", { RATE = 5000 })
  w.proxy:send("SET_HOLD_RATE_UP", { RATE = 5000 })
  w.proxy:send("SET_CLICK_RATE_DOWN", { RATE = 750 })
  w.proxy:send("SET_CLICK_RATE_UP", { RATE = 250 })
  w.proxy:mark()
  w.m.sent = {}
  local t0 = w.clock.now() - 11000
  local function at(t, fn)
    w.clock.at(t0 + t * 1000 - w.clock.now(), fn)
  end
  -- Director's queue held the press's frame behind older ones: its word came at 13.620 s.
  w.m.holdWordsUntil = t0 + 13620
  at(11.001, function()
    RFP.DO_PUSH(H.LINKS.bottom, "DO_PUSH", {}, {})
  end)
  at(11.123, function()
    RFP.DO_CLICK(H.LINKS.bottom, "DO_CLICK", {}, {})
  end)
  -- The bulb's reports in the stall, of frames it was sent before the press.
  w.m.inject(t0 + 12400, { on = false, level = 0.003937 }, { control = "level" })
  w.m.inject(t0 + 12593, { on = true, level = 0.003937 }, { control = "onOff" })
  w.m.inject(t0 + 12845, { on = false, level = 0.003937 }, { control = "onOff" })
  w.m.inject(t0 + 13229, { on = true, level = 0.003937 }, { control = "onOff" })
  w.m.inject(t0 + 13401, { on = true, level = 1 }, { control = "level" })
  w.run(15045 - 11000)
  T.eq(
    "the click's off is told at its end, and nothing after it: no CHANGED 100 at 13.40 s",
    changedSince(w, t0),
    { { 11.87, 0 } }
  )
  T.eq("the device got the press's ramp and, at its word, the click", sentLevels(w), { 0, 0 })
  T.eq("which it is at", w.devicePercent(), 0)
  w.m.sent = {}
  RFP.DO_PUSH(H.LINKS.toggle, "DO_PUSH", {}, {})
  local pre, ramp = w.m.sent[1] or {}, w.m.sent[2] or {}
  T.check(
    "so the toggle's press finds the light off, and ramps it up from a pre-on",
    pre.preOn and near(ramp.level, 1),
    T.show(w.m.sent)
  )
  w.run(10000)
  w.restore()
end)

T.section(
  "fades take 1, a stall: the bulb gets the command in flight and the newest, and no report from before the word is told"
)
case(function()
  local w = held({ hold = true, policy = "settle", settleMs = 2500 }, 100)
  w.proxy:mark()
  w.m.sent = {}
  local t0 = w.clock.now() - 9000
  local function at(t, fn)
    w.clock.at(t0 + t * 1000 - w.clock.now(), fn)
  end
  local function target(level, rate)
    return function()
      w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level, RATE = rate })
    end
  end
  -- The fade at 10.0 s ran on time, and Director's word on it came at 35.405 s.
  w.m.holdWordsUntil = t0 + 35405
  at(10.001, target(20, 6000))
  at(18.001, target(100, 4000))
  at(24.011, target(20, 8000))
  at(27.000, function()
    w.proxy:send("SET_BRIGHTNESS_STOP")
  end)
  at(30.001, target(100, 6000))
  at(32.001, target(40, 2000))
  -- The bulb's reports in the stall, of frames it had run: each before the word.
  w.m.inject(t0 + 18905, { on = true, level = 1 }, { control = "onOff" })
  w.m.inject(t0 + 19268, { on = true, level = 1 }, { control = "level" })
  w.m.inject(t0 + 28595, { on = true, level = 1 }, { control = "onOff" })
  w.m.inject(t0 + 35376, { on = true, level = 1 }, { control = "level" })
  w.run(49000 - 9000)
  T.eq(
    "each level told is the model's: the fade's end, the next ramp's, the stop and the last (not 100 at 19.27 s)",
    changedSince(w, t0),
    { { 16.0, 20 }, { 22.0, 100 }, { 27.0, 70 }, { 34.0, 40 } }
  )
  T.eq("the bulb was sent the fade in flight and the newest only", sentLevels(w), { 20, 40 })
  T.eq("and lands where Control4 was told", { w.devicePercent(), w.proxy.level }, { 40, 40 })
  w.restore()
end)

--------------------------------------------------------------------------------
-- Settings: presets, on modes, Dim-To-Warm, Min and Max On
--------------------------------------------------------------------------------

T.section("an On goes to the brightness on mode's level, else the preset level, and follows the preset's edits")
case(function()
  local w = world({}, 0)
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 70 })
  T.eq("the preset level is told back as a plain string", w.proxy:told("PRESET_LEVEL")[1], "70")
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

T.section("Dim-To-Warm: each level carries the mix between the Dim and On colors")
case(function()
  local w = world({}, 100)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  local c = (w.m.sent[1] or {}).color or {}
  local x, y = C4:ColorCCTtoXY(C4:ColorXYtoCCT(DIM.x + (WARM.x - DIM.x) * 0.5, DIM.y + (WARM.y - DIM.y) * 0.5))
  T.check(
    "half way, as a color temperature on the line of whites",
    c.kelvin ~= nil and near(c.x, x) and near(c.y, y),
    T.show(c)
  )
  T.check("told CHANGED with the level", near((toldColor(w) or {}).x, x))
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(5000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.check(
    "a color set lasts until the next level command, which brings the mix back (Light V2 _7.2)",
    ((w.m.sent[1] or {}).color or {}).kelvin ~= nil,
    T.show(w.m.sent)
  )
  w.run(10000)
  w.restore()
end)

T.section("Min and Max On Level remap every level sent and shown, and the adapter is told the range")
case(function()
  local w = world({}, 50)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 20 })
  T.eq("the proxy is told each back", { w.proxy:told("MAX_ON")[1], w.proxy:told("MIN_ON")[1] }, { "80", "20" })
  T.eq("the adapter is told the range", w.m.range, { 20, 80 })
  T.eq("and it reads", { w.light:range() }, { 20, 80 })
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.check("level 100 goes as the Max", near((w.m.sent[1] or {}).level, 0.8), T.show(w.m.sent))
  w.proxy:send("SET_LEVEL", { LEVEL = 1 })
  T.check("level 1 as the Min", near((w.m.sent[2] or {}).level, 0.2), T.show(w.m.sent))
  w.run(10000)
  T.eq("and the light shows what it was asked", w.proxy.level, 1)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 100 })
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 1 })
  w.run(10000)
  w.restore()
end)

T.section("Min and Max On: a light below the Min is sent the level it shows; one at the Min's step is not")
case(function()
  local w = world({}, 10)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 30 })
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = w.proxy.level })
  T.eq("below the Min: sent, to bring it to the Min", #w.m.sent, 1)
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 1 })
  T.eq("at the Min: nothing", #w.m.sent, 0)
  w.restore()
  w = world({}, 50)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 40 })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 40 })
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = w.proxy.level })
  T.eq("outside a range with no width: sent, to bring it to it", #w.m.sent, 1)
  w.run(10000)
  w.restore()
end)

T.section("a white-only light is sent no full color, and an off no level")
case(function()
  forget()
  local w = H.world({
    dims = true,
    cct = { min = 2000, max = 6500 },
    levelSteps = 254,
    keepsLevel = true,
    policy = "settle",
    settleMs = 2500,
  })
  onMode(w, ON_PRESET)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("ON")
  T.eq("an on in a full color's on mode goes with no color", (w.m.sent[#w.m.sent] or {}).color, nil)
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("OFF")
  T.eq("an off is on = false with no level", { (w.m.sent[1] or {}).on, (w.m.sent[1] or {}).level }, { false })
  w.run(10000)
  w.restore()
end)

T.section("Dim-To-Warm: an off light asked off sends nothing, though the dim color is not the one it went off in")
case(function()
  local w = world({}, 80)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 80 })
  w.run(10000)
  w.proxy:send("OFF")
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("OFF")
  T.eq("nothing is sent", #w.m.sent, 0)
  w.restore()
end)

T.section("Dim-To-Warm: a color asked in a level ramp stands, and a fade to off asked in it carries its mix on")
case(function()
  local w = world({}, 20)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:mark()
  w.run(10000)
  T.eq("a color asked in it: the ramp's end tells no mix", toldColors(w), {})
  w.restore()
  -- An off carries no mix, so the color the ramp carried goes on to its end at the ramp's pace.
  local function fadeOff()
    local f = world({}, 20)
    onMode(f, WARM, DIM)
    f.start = { x = f.light.told.x, y = f.light.told.y }
    f.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
    f.mix = (f.m.sent[#f.m.sent] or {}).color or {}
    f.run(1000)
    f.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 8000 })
    f.proxy:mark()
    return f
  end
  w = fadeOff()
  w.run(3500)
  local told = toldColors(w)
  T.check(
    "a fade to off asked in it: the mix is told at the first ramp's time",
    #told == 1 and near(told[1].x, w.mix.x, 0.002),
    T.show(told)
  )
  w.run(10000)
  w.restore()
  w = fadeOff()
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.check("a stop of the fade carries its stopped level's mix", (w.m.sent[1] or {}).color ~= nil, T.show(w.m.sent))
  w.run(10000)
  w.restore()
  w = fadeOff()
  w.run(1000)
  w.proxy:send("SET_COLOR_STOP")
  local at = toldColor(w) or {}
  T.check(
    "a color stop holds the carried color part way",
    at.x ~= nil and not near(at.x, w.mix.x, 0.002) and not near(at.x, w.start.x, 0.002),
    T.show({ at = at, from = w.start, to = w.mix })
  )
  w.run(10000)
  w.restore()
  w = world({}, 20)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.eq("a stop after a color set in the ramp keeps that color", (w.m.sent[1] or {}).color, nil)
  w.run(10000)
  w.restore()
end)

T.section("Dim-To-Warm: a stop of a fade to off keeps a color still ramping from before it")
case(function()
  -- An off carries no mix, so the color ramp runs on under the fade.
  local w = world({}, 100)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(10000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.2, LIGHT_COLOR_TARGET_COLOR_RATE = 10000 }
  )
  w.run(2000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 10000 })
  w.run(2000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.eq("the stop sends the level alone", (w.m.sent[1] or {}).color, nil)
  w.run(10000)
  w.restore()
end)

T.section("Dim-To-Warm: a level's mix ends a color ramp in flight, whose own end then tells nothing")
case(function()
  local w = world({}, 50)
  onMode(w, WARM, DIM)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:mark()
  w.run(10000)
  T.eq("only the level's mix is told", #toldColors(w), 0)
  w.restore()
end)

T.section("a retarget at a fade to off's end ends the on cycle: the color it went off in is kept")
case(function()
  local w = world({}, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  persist:delete("previous_color")
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 1000 })
  w.run(998)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  local prev = persist:get("previous_color") or {}
  T.check("the previous color is saved", near(prev.x, 0.3), T.show(prev))
  w.run(10000)
  w.restore()
end)

T.section("a range change in a ramp moves its target, and its end tells the level the target now shows")
case(function()
  local w = world({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 50 })
  w.proxy:mark()
  w.run(3500)
  T.eq("CHANGED 100: 80 % is above the new Max", w.proxy:changed()[1], 100)
  w.run(10000)
  w.restore()
end)

T.section("a color ramp between color temperatures stays one, and one from a white told as a color to a white too")
case(function()
  local w = world({}, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 6500, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 2000, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(2000)
  w.proxy:send("SET_COLOR_STOP")
  T.eq("a stop half way between 6500 K and 2000 K is told in mode 1", (toldColor(w) or {}).mode, CCT)
  w.run(10000)
  w.restore()
  w = world({}, 100)
  local wx, wy = C4:ColorCCTtoXY(4000)
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = wx,
    LIGHT_COLOR_TARGET_Y = wy,
    LIGHT_COLOR_TARGET_MODE = FULL,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  w.run(10000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3900, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(2000)
  w.proxy:send("SET_COLOR_STOP")
  T.eq("a stop on the line of whites, from a white told as a color, is told in mode 1", (toldColor(w) or {}).mode, CCT)
  w.run(10000)
  w.restore()
end)

T.section("a color retarget starts where the first ramp had got to, and only its own end is told")
case(function()
  local w = world({}, 100)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(2000)
  w.proxy:mark()
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.2, LIGHT_COLOR_TARGET_Y = 0.2, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  local c = w.proxy:told("LIGHT_COLOR_CHANGING")[1] or {}
  T.check("CHANGING starts half way", near(c.LIGHT_COLOR_CURRENT_X, 0.4, 0.01), T.show(c))
  w.run(10000)
  T.eq("one CHANGED, the new target's", toldColors(w), { { x = 0.2, y = 0.2 } })
  w.restore()
end)

T.section("the proxy's level commands: a target rounds, keeps its preset id, and RAMP_TO_LEVEL takes its TIME")
case(function()
  local w = world({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50.6, RATE = 0 })
  T.eq("50.6 goes to 51", w.proxy.level, 51)
  w.run(10000)
  w.proxy:mark()
  w.proxy:send(
    "SET_BRIGHTNESS_TARGET",
    { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 1000, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 4 }
  )
  T.eq(
    "CHANGING names its preset",
    (w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}).LIGHT_BRIGHTNESS_TARGET_PRESET_ID,
    4
  )
  w.run(10000)
  T.eq("and so does CHANGED", (w.proxy:told("LIGHT_BRIGHTNESS_CHANGED")[1] or {}).LIGHT_BRIGHTNESS_CURRENT_PRESET_ID, 4)
  w.m.sent = {}
  w.proxy:send("RAMP_TO_LEVEL", { LEVEL = 30, TIME = 2000 })
  T.eq("RAMP_TO_LEVEL goes over its TIME", (w.m.sent[1] or {}).ms, 2000)
  w.run(10000)
  w.restore()
end)

T.section(
  "the proxy's color commands: the default color rate, a preset's own mode, and no kelvin to a light without cct"
)
case(function()
  local w = world({}, 50)
  w.proxy:send("UPDATE_COLOR_RATE_DEFAULT", { RATE = 1500 })
  w.m.sent = {}
  w.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5 })
  T.eq("a color with no rate goes at the default color rate", (w.m.sent[1] or {}).ms, 1500)
  w.run(10000)
  local wx, wy = C4:ColorCCTtoXY(3000)
  w.proxy:send(
    "UPDATE_COLOR_PRESET",
    { COMMAND = "ADDED", ID = 7, NAME = "Warm", COLOR_X = wx, COLOR_Y = wy, COLOR_MODE = 1 }
  )
  w.m.sent = {}
  w.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = 7, LIGHT_COLOR_TARGET_COLOR_RATE = 0 })
  T.check("a preset of a white goes as its kelvin", ((w.m.sent[1] or {}).color or {}).kelvin ~= nil, T.show(w.m.sent))
  w.run(10000)
  w.restore()
  forget()
  w = H.world({ dims = true, color = true, levelSteps = 254, policy = "settle", settleMs = 2500 })
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("a kelvin alone to a light with color and no cct is ignored", #w.m.sent, 0)
  w.restore()
end)

T.section("the color a level carries: only Dim-To-Warm's moves a same level, and one the light cannot take does not")
case(function()
  local w = world({}, 50)
  onMode(w, ON_PRESET, { id = 2, origin = 0, x = 0.5, y = 0.4 })
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("an on preset with a dim color but no Dim-To-Warm: nothing", #w.m.sent, 0)
  w.restore()
  forget()
  w = H.world({
    dims = true,
    cct = { min = 2000, max = 6500 },
    levelSteps = 254,
    keepsLevel = true,
    policy = "settle",
    settleMs = 2500,
  })
  onMode(w, { id = 1, origin = 1, x = 0.6, y = 0.3 }, { id = 2, origin = 1, x = 0.2, y = 0.6 })
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("Dim-To-Warm in full colors on a white-only light: nothing", #w.m.sent, 0)
  w.restore()
  w = world({}, 50)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  local mix = { x = w.light.told.x, y = w.light.told.y, mode = w.light.told.mode }
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = mix.x,
    LIGHT_COLOR_TARGET_Y = mix.y,
    LIGHT_COLOR_TARGET_MODE = mix.mode,
    LIGHT_COLOR_TARGET_COLOR_RATE = 4000,
  })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("Dim-To-Warm, a color ramp on its way back to the level's mix: nothing", #w.m.sent, 0)
  w.run(10000)
  w.restore()
end)

T.section(
  "under a raised Min a fade to off runs to off's own place, and a ramp from off is lit at 1 from half a level above it"
)
case(function()
  local w = world({}, 50)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 30 })
  w.run(10000)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 10000 })
  w.run(3000)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.eq("a stop 30 % into the fade holds at 23", w.proxy:changed()[1], 23)
  w.run(10000)
  w.restore()
  w = world({}, 0)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 30 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 10000 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  T.eq(
    "10 % into a rated on from off it is lit: a fade to off from there starts at 1",
    (w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}).LIGHT_BRIGHTNESS_CURRENT,
    1
  )
  w.run(10000)
  w.restore()
end)

T.section("a level command with no preset clears the one told, and a target with no rate takes the default rate")
case(function()
  local w = world({}, 20)
  w.proxy:send(
    "SET_BRIGHTNESS_TARGET",
    { LIGHT_BRIGHTNESS_TARGET = 70, RATE = 0, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 4 }
  )
  w.run(10000)
  w.proxy:mark()
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  T.eq(
    "CHANGED names no preset",
    (w.proxy:told("LIGHT_BRIGHTNESS_CHANGED")[1] or {}).LIGHT_BRIGHTNESS_CURRENT_PRESET_ID,
    nil
  )
  w.run(10000)
  w.proxy:send("UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = 1200 })
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60 })
  T.eq("a target with no rate goes at the default", (w.m.sent[1] or {}).ms, 1200)
  w.run(10000)
  w.restore()
end)

T.section("a range change in a ramp from outside the range keeps the ramp on its line")
case(function()
  local w = world({}, 100)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.run(1000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
  w.run(500)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 90 })
  w.run(500)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.check(
    "a stop a quarter in holds near the top of the new range",
    (w.proxy:changed()[1] or 0) >= 90,
    T.show(w.proxy:changed())
  )
  w.run(10000)
  w.restore()
end)

T.section(
  "a rated level to a light that does not dim switches it at once; one to a lost light is dropped (T3 switched it)"
)
case(function()
  local w = world({ dims = false, color = false, cct = false, fade = "none", keepsLevel = false })
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 2000 })
  local cmd = w.m.sent[1] or {}
  T.eq("a relay: an on, with no level and no ms", { #w.m.sent, cmd.on, cmd.level, cmd.ms }, { 1, true })
  T.eq("told 100 at once, with no CHANGING", { w.proxy:changed(), w.proxy:told("LIGHT_BRIGHTNESS_CHANGING") }, {
    { 100 },
    {},
  })
  w.run(10000)
  w.restore()
  -- Lost, the command is dropped, and no ramp is left to end after the return.
  w = world({}, 40)
  w.m.drop()
  w.m.sent = {}
  w.proxy:mark()
  w.proxy:send("RAMP_TO_LEVEL", { LEVEL = 60, TIME = 750 })
  T.eq("lost: nothing is sent and nothing told", { w.m.sent, w.proxy:said() }, { {}, {} })
  T.eq("and no ramp is left", w.light.aim.level, nil)
  w.m.back()
  w.run(10000)
  T.eq("and back, the proxy shows the device", { w.proxy.level, w.devicePercent() }, { 40, 40 })
  w.restore()
end)

T.section("a relay: an Off goes with no ms, SET_LEVEL 0 is off, and a Toggle at level 1 turns a light off")
case(function()
  local w = world({ dims = false, color = false, cct = false, fade = "none", keepsLevel = false })
  w.proxy:send("ON")
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("OFF")
  T.eq("an Off: on = false, no ms", { (w.m.sent[1] or {}).on, (w.m.sent[1] or {}).ms }, { false })
  w.run(10000)
  w.proxy:send("ON")
  w.run(10000)
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  w.run(10000)
  T.eq("SET_LEVEL 0 is off", w.proxy.level, 0)
  w.restore()
  w = world({}, 1)
  w.proxy:send("TOGGLE")
  w.run(10000)
  T.eq("a Toggle at level 1 turns it off", w.proxy.level, 0)
  w.restore()
end)

T.section(
  "SET_COLOR_TARGET: its rate by either older name, coordinates or a kelvin over an unknown preset, and its preset told"
)
case(function()
  local w = world({}, 50)
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_RATE = 1300 }
  )
  w.run(10000)
  w.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.35, LIGHT_COLOR_TARGET_Y = 0.45, RATE = 1400 })
  T.eq("LIGHT_COLOR_TARGET_RATE and RATE are taken", { (w.m.sent[1] or {}).ms, (w.m.sent[2] or {}).ms }, { 1300, 1400 })
  w.run(10000)
  w.m.sent = {}
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.4,
    LIGHT_COLOR_TARGET_Y = 0.4,
    LIGHT_COLOR_TARGET_PRESET_ID = 99,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq("xy with an unknown preset goes at its xy", #w.m.sent, 1)
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000,
    LIGHT_COLOR_TARGET_PRESET_ID = 99,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq("and a kelvin with one at its kelvin", #w.m.sent, 2)
  w.run(10000)
  w.proxy:mark()
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.3,
    LIGHT_COLOR_TARGET_Y = 0.5,
    LIGHT_COLOR_TARGET_PRESET_ID = 5,
    LIGHT_COLOR_TARGET_COLOR_RATE = 1000,
  })
  T.eq("its CHANGING names its preset", (w.proxy:told("LIGHT_COLOR_CHANGING")[1] or {}).LIGHT_COLOR_TARGET_PRESET_ID, 5)
  w.run(10000)
  T.eq("and so does its CHANGED", (w.proxy:told("LIGHT_COLOR_CHANGED")[1] or {}).LIGHT_COLOR_CURRENT_PRESET_ID, 5)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.4, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = 98 })
  w.proxy:mark()
  w.run(10000)
  T.eq(
    "an unknown preset with no color sets no preset id on what is in flight",
    (w.proxy:told("LIGHT_COLOR_CHANGED")[1] or {}).LIGHT_COLOR_CURRENT_PRESET_ID,
    nil
  )
  w.restore()
end)

T.section("a white asked by xy is taken at its color temperature's own point, and its CHANGING starts in the told mode")
case(function()
  local w = world({}, 50)
  local kx, ky = C4:ColorCCTtoXY(3000)
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = kx + 0.004,
    LIGHT_COLOR_TARGET_Y = ky - 0.004,
    LIGHT_COLOR_TARGET_MODE = CCT,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  local told = toldColor(w) or {}
  local px, py = C4:ColorCCTtoXY(C4:ColorXYtoCCT(kx + 0.004, ky - 0.004))
  T.check("told at the point", near(told.x, px, 1e-4) and near(told.y, py, 1e-4), T.show(told))
  w.run(10000)
  w.proxy:mark()
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
  )
  local c = w.proxy:told("LIGHT_COLOR_CHANGING")[1] or {}
  T.check(
    "CHANGING starts at the white's point and names the color asked",
    near(c.LIGHT_COLOR_CURRENT_X, px, 1e-4)
      and near(c.LIGHT_COLOR_CURRENT_Y, py, 1e-4)
      and near(c.LIGHT_COLOR_TARGET_X, 0.3)
      and near(c.LIGHT_COLOR_TARGET_Y, 0.5),
    T.show(c)
  )
  T.eq(
    "CHANGING from the white is in mode 1, with the rate in both its names",
    { c.LIGHT_COLOR_CURRENT_COLOR_MODE, c.LIGHT_COLOR_TARGET_COLOR_RATE, c.LIGHT_COLOR_TARGET_RATE },
    { CCT, 2000, 2000 }
  )
  w.run(10000)
  w.restore()
end)

T.section("Dim-To-Warm: the proxy's follow-up of a level's mix is the color its end tells")
case(function()
  local w = world({}, 20)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  local mix = (w.m.sent[#w.m.sent] or {}).color or {}
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = mix.x + 0.003,
    LIGHT_COLOR_TARGET_Y = mix.y,
    LIGHT_COLOR_TARGET_MODE = CCT,
    LIGHT_COLOR_TARGET_COLOR_RATE = 2000,
  })
  local px = C4:ColorCCTtoXY(C4:ColorXYtoCCT(mix.x + 0.003, mix.y))
  w.proxy:mark()
  w.run(2100)
  T.check(
    "the end tells the follow-up's point",
    near((toldColor(w) or {}).x, px, 1e-4),
    T.show({ told = toldColor(w), mix = mix, px = px })
  )
  w.run(10000)
  w.restore()
end)

T.section("Dim-To-Warm: a color asked the instant a ramp ends tells the mix it arrived at first")
case(function()
  local w = world({}, 50)
  onMode(w, WARM, DIM)
  w.run(1000)
  w.proxy:mark()
  -- Due with the ramp's own end, and run ahead of it.
  w.clock.at(2000, function()
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
  w.run(10000)
  local told = toldColors(w)
  T.check("the mix, then the color asked", #told == 2 and near(told[2].x, 0.3), T.show(told))
  w.restore()
end)

T.section("a range change that leaves the level where it shows tells nothing")
case(function()
  local w = world({}, 100)
  w.proxy:mark()
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 10 })
  T.eq("100 is still 100", w.proxy:changed(), {})
  w.restore()
end)

T.section("the preset level is told with the capabilities, unless it is 0")
case(function()
  local w = world({ offline = true })
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 0 })
  w.light:declare(w.m.declaration())
  w.light:report({ on = true, level = 0.5 }, {})
  local told = {}
  for _, n in ipairs(w.proxy.notes) do
    if n.cmd == "PRESET_LEVEL" then
      told[#told + 1] = n.params
    end
  end
  T.eq("a preset level of 0 is not told", told, { "0" })
  w.restore()
  w = world({ offline = true })
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 70 })
  w.proxy:mark()
  w.light:declare(w.m.declaration())
  w.light:report({ on = true, level = 0.5 }, {})
  local preset = nil
  for _, n in ipairs(w.proxy.notes) do
    if n.cmd == "PRESET_LEVEL" then
      preset = n.params
    end
  end
  T.eq("one of 70 is, with the capabilities", preset, "70")
  w.restore()
end)

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------

T.section("a held Top ramps toward full until released; a click goes to the on level over the click rate")
case(function()
  local w = world({}, 30)
  w.proxy:send("SET_HOLD_RATE_UP", { RATE = 4000 })
  w.proxy:send("SET_CLICK_RATE_UP", { RATE = 600 })
  w.proxy:send("BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 1 })
  T.eq(
    "the press ramps toward full at the hold rate",
    (w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}).LIGHT_BRIGHTNESS_TARGET,
    100
  )
  T.eq("then the proxy is told the action, after the CHANGING", w.proxy:said()[#w.proxy:said()], "BUTTON_ACTION")
  w.run(2000)
  w.proxy:send("BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 0 })
  w.run(10000)
  local held = w.proxy.level
  T.check("its release holds the light part way", held > 30 and held < 100, held)
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 90 })
  w.m.sent = {}
  RFP.DO_PUSH(H.LINKS.top, "DO_PUSH", {}, {})
  w.run(100)
  RFP.DO_CLICK(H.LINKS.top, "DO_CLICK", {}, {})
  local click = w.m.sent[#w.m.sent] or {}
  T.eq("a click goes to the on level over the click rate", click.ms, 600)
  w.run(10000)
  T.eq("and lands", w.proxy.level, 90)
  RFP.DO_CLICK(H.LINKS.toggle, "DO_CLICK", {}, {})
  w.run(10000)
  T.eq("a Toggle click turns it off", w.proxy.level, 0)
  T.eq(
    "the LEDs follow: Top off, Bottom on",
    { w.proxy.leds[H.LINKS.top], w.proxy.leds[H.LINKS.bottom] },
    { false, true }
  )
  w.restore()
end)

T.section("button colors are stored and told back, and Request Button Colors answers them with each link's LED")
case(function()
  local w = world({}, 50)
  w.proxy:send("SET_BUTTON_COLOR", { BUTTON_ID = 1, ON_COLOR = "ff0000", OFF_COLOR = "00ff00" })
  T.eq("each color told back as BUTTON_INFO", #w.proxy:told("BUTTON_INFO"), 2)
  w.proxy:mark()
  w.proxy:send("REQUEST_BUTTON_COLORS")
  local colors = w.proxy:told("BUTTON_COLORS")
  T.eq("each button answered", #colors, 3)
  T.eq("with the colors stored", { colors[2].ON_COLOR, colors[2].OFF_COLOR }, { "ff0000", "00ff00" })
  T.eq("and the default for one with none", { colors[1].ON_COLOR, colors[1].OFF_COLOR }, { "0000ff", "000000" })
  T.eq(
    "each LED, Bottom's lit while the light is off",
    { w.proxy.leds[H.LINKS.top], w.proxy.leds[H.LINKS.bottom] },
    { true, false }
  )
  w.m.drop()
  w.m.back()
  w.run(10000)
  local bottom
  for _, info in ipairs(w.proxy:told("BUTTON_INFO")) do
    if info.BUTTON_ID == 1 and info.NAME then
      bottom = info
    end
  end
  T.eq(
    "the next connection tells each button with its saved colors",
    bottom and { bottom.ON_COLOR, bottom.OFF_COLOR },
    { "ff0000", "00ff00" }
  )
  w.restore()
end)

T.section("a light with no button links registers no DO_* and tells no LED")
case(function()
  local before = { RFP.DO_PUSH, RFP.DO_CLICK, RFP.DO_RELEASE }
  RFP.DO_PUSH, RFP.DO_CLICK, RFP.DO_RELEASE = nil, nil, nil
  local w = world({ links = false }, 50)
  T.eq("no link handlers", { RFP.DO_PUSH, RFP.DO_CLICK, RFP.DO_RELEASE }, {})
  T.eq("and no LED was told", w.proxy.leds, {})
  w.restore()
  RFP.DO_PUSH, RFP.DO_CLICK, RFP.DO_RELEASE = before[1], before[2], before[3]
end)

T.section("the button LEDs: told once per change, Toggle's lit while on, and on through a fade to off")
case(function()
  local w = world({}, 0)
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.run(10000)
  T.eq("Toggle's LED is lit while on", w.proxy.leds[H.LINKS.toggle], true)
  w.proxy:send("OFF")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 4000 })
  T.eq("a rated on from off lights the Top LED at its start", w.proxy.leds[H.LINKS.top], true)
  w.run(10000)
  w.proxy:mark()
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(10000)
  local leds = 0
  for _, n in ipairs(w.proxy.notes) do
    leds = leds + (n.cmd == "MATCH_LED_STATE" and 1 or 0)
  end
  T.eq("a level still on tells the LEDs nothing", leds, 0)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  w.run(1000)
  T.eq("in a fade to off the Top LED stays lit", w.proxy.leds[H.LINKS.top], true)
  w.run(10000)
  T.eq("and goes off at its end", w.proxy.leds[H.LINKS.top], false)
  w.restore()
end)

--------------------------------------------------------------------------------
-- Scenes
--------------------------------------------------------------------------------

T.section("a scene runs its steps, each over its rate; a level command takes the light out of it")
case(function()
  local w = world({}, 0)
  scene(w, 1, {
    { level = 40, rate = 1000 },
    { delay = 500, level = 80, rate = 1000 },
    { color = { x = 0.3, y = 0.6 }, rate = 0 },
  })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(1100)
  T.eq("its first step lands", w.proxy.level, 40)
  w.run(2000)
  T.eq("its second, after its delay", w.proxy.level, 80)
  T.check("its third sets a color alone", near((toldColor(w) or {}).x, 0.3), T.show(toldColor(w)))
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(500)
  w.proxy:send("SET_LEVEL", { LEVEL = 10 })
  w.run(5000)
  T.eq("a level command stops its later steps", w.proxy.level, 10)
  w.restore()
end)

T.section("trust: a scene stopped in its step's ramp ends that ramp at its own time, as the device does")
case(function()
  local w = world({ policy = "trust", keepsLevel = false }, 20)
  scene(w, 9, { { level = 80, rate = 3000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(1000)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(10000)
  T.eq("the proxy is told the step's end, where the device is", { w.proxy.level, w.devicePercent() }, { 80, 80 })
  w.restore()
  -- So does a step's color ramp.
  w = world({ policy = "trust", keepsLevel = false }, 20)
  scene(w, 9, { { color = { x = 0.5, y = 0.4 }, rate = 3000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(1000)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(10000)
  local told, at = toldColor(w) or {}, deviceColor(w)
  T.check("and of its color ramp", near(told.x, at.x) and near(told.y, at.y), T.show({ told, at }))
  w.restore()
  -- Under settle too a step's color ramp ends at its own time, before the device's report of its end.
  w = world({ latency = 200 }, 20)
  scene(w, 9, { { color = { x = 0.5, y = 0.4 }, rate = 3000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(1000)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(2100)
  told = toldColor(w) or {}
  T.check("settle: the proxy is told its color ramp's end at its time", near(told.x, 0.5), T.show(told))
  w.restore()
end)

T.section("a flash scene with nothing to wait on runs its steps once; Deactivate and Stop Scene Ramp stop a scene")
case(function()
  local w = world({}, 0)
  scene(w, 2, { { level = 100 }, { level = 0 } }, true)
  w.m.sent = {}
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 2 })
  T.eq("each step once", sentLevels(w), { 100, 0 })
  scene(w, 3, { { level = 90, rate = 4000 }, { level = 10, rate = 4000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 3 })
  w.run(1000)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 3 })
  w.run(10000)
  T.eq("deactivated, its step runs to its end and no later one runs", w.proxy.level, 90)
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 3 })
  w.run(6000)
  w.proxy:send("STOP_RAMP_SCENE", { SCENE_ID = 3 })
  w.run(10000)
  local at = w.proxy.level
  T.check("Stop Scene Ramp holds the light where the step's ramp has got to", at > 10 and at < 90, at)
  T.eq("which the device is at", w.devicePercent(), at)
  w.proxy:send("RAMP_SCENE_UP", { SCENE_ID = 3, RATE = 1000 })
  w.run(10000)
  T.eq("Ramp Scene Up goes to the on level", w.proxy.level, 100)
  w.proxy:send("RAMP_SCENE_DOWN", { SCENE_ID = 3, RATE = 1000 })
  w.run(10000)
  T.eq("and Down to off", w.proxy.level, 0)
  w.restore()
end)

T.section("settle: a scene's color at once shows with the device's report of it, within match")
case(function()
  local w = world({}, 60)
  scene(w, 4, { { color = { x = 0.3, y = 0.5 } } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 4 })
  w.light:report({ color = { x = 0.302, y = 0.498 } }, { control = "color" })
  T.check("told at the report", near((toldColor(w) or {}).x, 0.302, 1e-4), T.show(toldColor(w)))
  w.run(10000)
  w.restore()
end)

T.section("a scene step's color at once that ends a color ramp in flight is told, as no report need differ")
case(function()
  local w = world({}, 50)
  w.proxy:send("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = 0.25, LIGHT_COLOR_TARGET_Y = 0.4 })
  w.run(10000)
  scene(w, 8, { { color = { x = 0.3, y = 0.6 } }, { color = { x = 0.25, y = 0.4 } } })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.5, LIGHT_COLOR_TARGET_Y = 0.4, LIGHT_COLOR_TARGET_COLOR_RATE = 5000 }
  )
  w.proxy:mark()
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 8 })
  w.run(20000)
  local told, at = toldColors(w), deviceColor(w)
  local last = told[#told] or {}
  T.check(
    "the last color told is the one the light is in",
    near(last.x, at.x) and near(last.y, at.y),
    T.show({ told, at })
  )
  w.restore()
end)

T.section("a scene step's color alone says whether the light is lit, as a color command's does")
case(function()
  -- An off in flight and an on waiting behind it, then the color: the device's level as it goes.
  local function colorAfterOff(ask)
    local w = held({ hold = true, holdShare = 1 }, 100)
    onMode(w, ON_PRESET)
    scene(w, 7, { { color = { x = 0.3, y = 0.6 } } })
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
    w.run(600)
    w.m.sent = {}
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 2000 })
    w.run(50)
    ask(w)
    local color = w.m.sent[1] or {}
    local trace = {}
    for _ = 1, 20 do
      w.run(50)
      trace[#trace + 1] = math.floor(w.device:state(w.clock.now()).level * 1000 + 0.5) / 10
    end
    w.run(10000)
    w.restore()
    return color.on, trace
  end
  local stepOn, stepTrace = colorAfterOff(function(w)
    w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
  end)
  local colorOn, colorTrace = colorAfterOff(function(w)
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
  end)
  T.eq("the step's color goes unlit, as SET_COLOR_TARGET's does", { stepOn, colorOn }, { false, false })
  T.eq("so the light comes on from off as it does then, not first at the level it kept", stepTrace, colorTrace)
  -- A step with a level as well turns the light on.
  local w = world({}, 0)
  w.proxy:send("OFF")
  w.run(10000)
  scene(w, 7, { { level = 60, color = { x = 0.3, y = 0.6 } } })
  w.m.sent = {}
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
  w.run(10000)
  T.eq(
    "a step with a level and a color goes on, and the light is at its level",
    { (w.m.sent[1] or {}).on, w.proxy.level, w.devicePercent() },
    { true, 60, 60 }
  )
  w.restore()
end)

T.section("a stop, an On to a relay, and a Toggle in a ramp up: each takes the light out of a scene and acts at once")
case(function()
  local w = world({}, 0)
  scene(w, 6, { { level = 80, rate = 0 }, { level = 20, rate = 0, delay = 2000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 6 })
  w.run(500)
  w.proxy:send("SET_BRIGHTNESS_STOP")
  w.run(5000)
  T.eq("a stop: the next step does not run", w.proxy.level, 80)
  w.restore()
  w = world({ dims = false, color = false, cct = false, fade = "none", keepsLevel = false })
  scene(w, 6, { { level = 0, rate = 0 }, { level = 0, rate = 0, delay = 2000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 6 })
  w.run(500)
  w.proxy:send("ON")
  w.run(5000)
  T.eq("an On to a relay: the next step does not run", w.proxy.level, 100)
  w.restore()
  w = world({ dims = false, color = false, cct = false, fade = "none", keepsLevel = false })
  w.proxy:send("ON")
  w.run(10000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  w.proxy:send("ON")
  w.proxy:mark()
  w.proxy:send("GET_LIGHT_LEVEL")
  T.eq("an On to a relay replaces a ramp: Get Light Level tells CHANGED 100", w.proxy:changed(), { 100 })
  w.run(10000)
  w.restore()
  w = world({}, 0)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(1000)
  w.proxy:send("TOGGLE")
  w.run(10000)
  T.eq("a Toggle in a rated on from off turns it off", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
end)

--------------------------------------------------------------------------------
-- echo
--------------------------------------------------------------------------------

--- A light that answers each command with a report of its targets, in order, as an ESPHome node
--- does, on at `level` when given. `o.mute`, a table, drops the device's reports while mute[1].
local function echoWorld(o, level)
  forget()
  local opts = { dims = true, color = true, cct = { min = 2000, max = 6500 }, policy = "echo" }
  for k, v in pairs(o or {}) do
    opts[k] = v
  end
  local mute = opts.mute
  if mute then
    opts.drop = function(kind)
      return kind == "report" and mute[1]
    end
  end
  local w = H.world(opts)
  if level then
    w.proxy:send("SET_LEVEL", { LEVEL = level })
    w.run(10000)
    w.proxy:mark()
    w.m.sent = {}
  end
  return w
end

--- Deliver a report now, as the adapter gives it.
local function hear(w, state, meta)
  w.m.inject(w.clock.now(), state, meta or {})
  w.run(0)
  return w.m.lastVerdict
end

T.section("echo: a report is judged by its place in the list, not by its age")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.run(1500)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(100)
  w.proxy:mark()
  local v = hear(w, { on = true, level = 0.3 }).level
  T.eq("the first command's echo 1.6 s on, two sent since, is history", { v.kind, #v.since }, { "history", 2 })
  w.run(800)
  T.eq("it tells nothing while the newest's echo may still come", w.proxy:changed(), {})
  w.run(100)
  T.eq("with none by waitMs after the newest, the light is shown where it said", w.proxy:changed(), { 30 })
  w.restore()
end)

T.section("echo: a level told from history at waitMs's end, asked again, goes: the light heads for the newest command")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:mark()
  hear(w, { on = true, level = 0.2 })
  w.run(1000)
  T.eq("with no echo of the newest, the light is shown where it said", w.proxy:changed(), { 20 })
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 20 })
  T.eq("and that level asked again goes, as it may still be on its way to the newest", sentLevels(w), { 20 })
  w.restore()
end)

T.section("echo: a color from before the newest color command waits for that command's echo")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:mark()
  local v = hear(w, { on = true, level = 0.2, color = { x = 0.3127, y = 0.329, mode = CCT } }).color
  T.eq("a report of the color before it is history", { v.kind, #v.since }, { "history", 1 })
  w.run(900)
  T.eq("it tells nothing while the newest's echo may still come", toldColors(w), {})
  w.run(100)
  T.eq("with none by waitMs after the newest, the light is shown in it", toldColors(w), { { x = 0.3127, y = 0.329 } })
  w.restore()
  w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:mark()
  hear(w, { on = true, level = 0.2, color = { x = 0.3127, y = 0.329, mode = CCT } })
  hear(w, { on = true, level = 0.2, color = { x = 0.6, y = 0.3 } })
  w.run(2000)
  T.eq("and once the newest's echo comes, the color from before is never told", toldColors(w), {})
  w.restore()
end)

T.section("echo: the newest command's echo is the light's own, whatever came between")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:mark()
  T.eq("another hand's level first is news", hear(w, { on = true, level = 0.9 }).level.kind, "hand")
  T.eq("and is told", w.proxy:changed(), { 90 })
  local v = hear(w, { on = true, level = 0.6 }).level
  T.eq("the command's own echo after it is own, nothing left after it", { v.kind, #v.since }, { "own", 0 })
  T.eq("and shows the light at its level", w.proxy:changed(), { 90, 60 })
  T.eq("its repeat with nothing sent since is own", hear(w, { on = true, level = 0.6 }).level.kind, "own")
  T.eq("and tells nothing", w.proxy:changed(), { 90, 60 })
  w.restore()
end)

T.section("echo: the last report heads the list, and a repeat of one sent just after its match is dropped with it")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  local v = hear(w, { on = true, level = 0.2 }).level
  T.eq("a report of the level before the command is history", { v.kind, #v.since }, { "history", 1 })
  -- With no width to the range every on level goes out at the one brightness, and reads as each.
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("OFF")
  w.proxy:send("SET_LEVEL", { LEVEL = 90 })
  v = hear(w, { on = true, level = 0.5 }).level
  T.eq("an echo of the first drops the second sent straight after it, and keeps the off and the one after", #v.since, 2)
  w.restore()
end)

T.section("echo: after another hand's report the light heads for the report, not a command it never echoed")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  hear(w, { on = true, level = 0.4 })
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  T.eq("a Set Level to the level it reported sends nothing", #w.m.sent, 0)
  w.restore()
end)

T.section("echo: the level and the color of one report match commands of their own")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  local v = hear(w, { on = true, level = 0.4, color = { x = 0.6, y = 0.3 } })
  T.eq("its level is the first command's, with one sent since", { v.level.kind, #v.level.since }, { "history", 1 })
  T.eq("its color is the color command's own", { v.color.kind, #v.color.since }, { "own", 0 })
  T.check("each names its own command", v.level.seq ~= v.color.seq, T.show(v))
  w.restore()
end)

T.section("echo: a scene stopped in its step's ramp ends that ramp at its own time, as under trust")
case(function()
  local w = echoWorld({}, 20)
  scene(w, 9, { { level = 80, rate = 3000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(1000)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(10000)
  T.eq("the proxy is told the step's end, where the device is", { w.proxy.level, w.devicePercent() }, { 80, 80 })
  w.restore()
end)

T.section("echo: a command the transport gave up on leaves the lists, and the light's answer ends its ramp")
case(function()
  local w = echoWorld({ ack = "done" }, 20)
  w.m.dropNext, w.m.failNext = true, true
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 5000 })
  w.run(1000)
  T.eq("the read its word asks tells the light where it still is", w.proxy:changed(), { 20 })
  w.run(10000)
  T.eq("and the ramp's time ends nothing", { w.proxy.level, w.devicePercent() }, { 20, 20 })
  w.restore()
  w = echoWorld({ ack = "done" }, 20)
  w.m.dropNext, w.m.failNext = true, true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 5000 }
  )
  w.run(1000)
  T.eq("so does a color's", toldColors(w), { { x = 0.3127, y = 0.329 } })
  w.run(10000)
  T.eq("which its ramp's time does not undo", toldColors(w), { { x = 0.3127, y = 0.329 } })
  w.restore()
  -- The color a level ramp carries went with its command, so the light never took it either.
  w = echoWorld({ ack = "done" }, 20)
  onMode(w, WARM, DIM)
  w.proxy:mark()
  w.m.dropNext, w.m.failNext = true, true
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 5000 })
  w.run(1000)
  T.eq("the color a level ramp carried is told as the light still is", toldColors(w), { { x = 0.3127, y = 0.329 } })
  w.run(10000)
  T.eq("and the ramp's time tells it no other", toldColors(w), { { x = 0.3127, y = 0.329 } })
  w.restore()
end)

T.section("echo: a report says only what it carries, and a NaN or an infinity is no reading")
case(function()
  local w = echoWorld({}, 40)
  local v = hear(w, { color = { x = 0.5, y = 0.4 } })
  T.eq("a color alone has no level verdict", v.level, nil)
  T.eq("and tells no level", w.proxy:changed(), {})
  hear(w, { level = 0.6 })
  T.eq("a level with no on is the light still on, at it", w.proxy:changed(), { 60 })
  w.proxy:mark()
  hear(w, { on = true, level = 0 / 0 })
  hear(w, { on = true, level = math.huge })
  T.eq("an on with a NaN or an infinite level keeps the level, as an on with none does", w.proxy:changed(), {})
  hear(w, { on = true, level = 0.6, color = { x = 0 / 0, y = 0.3 } })
  T.eq("and a NaN color is none", w.proxy:told("LIGHT_COLOR_CHANGED"), {})
  w.restore()
end)

T.section("echo: a command joins the lists of the aspects it holds, so a color's on joins no level list")
case(function()
  local mute = { false }
  local w = echoWorld({ mute = mute }, 50)
  mute[1] = true
  w.proxy:send("OFF")
  w.proxy:mark()
  hear(w, { on = true, level = 0.5 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(1000)
  T.eq(
    "a color that leaves the light off waits on no level: one from before the Off is told",
    w.proxy:changed(),
    { 50 }
  )
  w.restore()
  w = echoWorld({ dims = false, cct = false, mute = mute })
  w.proxy:send("ON")
  w.run(10000)
  mute[1] = true
  w.proxy:send("OFF")
  w.proxy:send("ON")
  w.proxy:mark()
  hear(w, { on = false })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(1000)
  T.eq("nor does a color relay's color that says it is lit", w.proxy:changed(), { 0 })
  w.restore()
end)

T.section(
  "echo: another hand's color in a level ramp that carries one is told at once, and the ramp carries it no longer"
)
case(function()
  local w = echoWorld({}, 20)
  onMode(w, WARM, DIM)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.m.other({ color = { x = 0.2, y = 0.2 } })
  w.run(100)
  T.eq("the color is told", toldColors(w), { { x = 0.2, y = 0.2 } })
  w.run(5000)
  T.eq("and the ramp's end tells no other", toldColors(w), { { x = 0.2, y = 0.2 } })
  w.restore()
end)

T.section("echo: a level command waiting in the outbox sets the level when it goes, as under the other policies")
case(function()
  local w = echoWorld({ ack = "done", ackMs = 3000 }, 20)
  w.m.loseNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 80 })
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  w.run(500)
  w.proxy:mark()
  hear(w, { on = true, level = 0.5 })
  T.eq("another hand's level heard while it waits is not told", w.proxy:changed(), {})
  w.run(10000)
  T.eq("and the light ends where it was asked last", { w.proxy.level, w.devicePercent() }, { 30, 30 })
  w.restore()
  -- So does a color, waiting at once or over a rate.
  for _, rate in ipairs({ 0, 3000 }) do
    w = echoWorld({ ack = "done", ackMs = 3000 }, 20)
    w.m.loseNext = true
    for _, c in ipairs({ { 0.6, 0.3, 2000 }, { 0.3, 0.5, rate } }) do
      w.proxy:send(
        "SET_COLOR_TARGET",
        { LIGHT_COLOR_TARGET_X = c[1], LIGHT_COLOR_TARGET_Y = c[2], LIGHT_COLOR_TARGET_COLOR_RATE = c[3] }
      )
    end
    w.run(500)
    w.proxy:mark()
    hear(w, { on = true, level = 0.2, color = { x = 0.2, y = 0.2 } })
    local name = "a color waiting over " .. rate .. " ms: "
    T.eq(name .. "another hand's color heard then is not told", toldColors(w), {})
    T.eq(name .. "and ends no ramp of it", w.light.aim.color ~= nil, rate > 0)
    w.run(10000)
    local told, at = toldColor(w) or {}, deviceColor(w)
    T.check(
      name .. "the light ends in the color asked last",
      near(told.x, 0.3) and near(at.x, 0.3),
      T.show({ told, at })
    )
    w.restore()
  end
end)

T.section("a timeout ends a read that waited on its word, as a word does, so the light is read at it")
case(function()
  local w = echoWorld({ ack = "done", ackMs = 1000 }, 20)
  w.m.loseNext, w.m.dropNext = true, true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 500 }
  )
  w.m.failNext, w.m.dropNext = true, true
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(100)
  local reads = w.m.reads
  w.run(10000)
  T.eq("the color's timeout asks a read of its own", w.m.reads, reads + 1)
  T.check(
    "whose answer shows the light in the color it kept",
    near((toldColor(w) or {}).x, 0.3127),
    T.show(toldColor(w))
  )
  w.restore()
end)

T.section("echo: nothing is listed while the light is offline")
case(function()
  local w = echoWorld({}, 20)
  w.m.drop()
  w.proxy:send("SET_LEVEL", { LEVEL = 80 })
  w.m.online = true
  w.light:declare(w.m.declaration())
  local v = hear(w, { on = true, level = 0.2 }).level
  T.eq("the first report back has nothing listed behind it", { v.kind, #v.since }, { "first", 0 })
  w.restore()
end)

T.section("echo: send's token joins the lists it names, and echoes matches on it, the head on the last report")
case(function()
  local seen = {}
  local w = echoWorld({
    token = function(cmd)
      return { level = cmd.level or (cmd.on == false and 0) or nil, color = cmd.color and { wire = cmd.color.x } }
    end,
    echoes = function(_, aspect, token, raw)
      seen[#seen + 1] = { aspect = aspect, token = token, raw = raw }
      if aspect == "color" and raw then
        return (token.color or token).wire == raw.wire
      end
    end,
  }, 20)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  seen = {}
  local v = hear(w, { on = true, level = 0.3, color = { x = 0.1, y = 0.1 } }, { raw = { wire = 0.6 } })
  T.eq("the color matches by the adapter's own fields", v.color.kind, "own")
  local aspects = {}
  for _, s in ipairs(seen) do
    aspects[s.aspect] = true
  end
  T.eq("echoes is asked of both aspects", aspects, { level = true, color = true })
  seen = {}
  v = hear(w, { on = true, level = 0.3, color = { x = 0.1, y = 0.1 } }, { raw = { wire = 0.6 } })
  T.eq("a repeat matches the head", v.color.kind, "own")
  T.eq("whose token is the last report's raw", (seen[#seen] or {}).token, { wire = 0.6 })
  w.restore()
end)

T.section("echo: a color given as a function is read once its verdict says whose it is, echoes judging it")
case(function()
  local kinds = {}
  local function color(kind)
    kinds[#kinds + 1] = kind
    return { x = 0.6, y = 0.3 }
  end
  local mute = { false }
  local w = echoWorld({
    mute = mute,
    echoes = function(_, aspect, _, raw)
      if aspect == "color" and raw then
        return raw.same
      end
    end,
  }, 20)
  mute[1] = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(1000)
  w.proxy:mark()
  hear(w, { on = true, level = 0.2, color = color }, { raw = { same = true } })
  hear(w, {
    on = true,
    level = 0.2,
    color = function(kind)
      kinds[#kinds + 1] = kind
      return { x = 0.2, y = 0.5 }
    end,
  }, { raw = { same = false } })
  T.eq("the function hears each color's verdict", kinds, { "own", "hand" })
  T.eq("and its color is told by it", toldColors(w), { { x = 0.2, y = 0.5 } })
  w.restore()
end)

--------------------------------------------------------------------------------
-- A device that re-times, along an eased curve
--------------------------------------------------------------------------------

--- An echo light whose every command runs all its channels along one eased transition.
local function retimed(o, level)
  o = o or {}
  o.curve, o.retimes = "eased", true
  return echoWorld(o, level)
end

T.section("a scene step's command and its pre-on say they are one, on a device that re-times or not")
case(function()
  for _, how in ipairs({ "linear", "re-timed" }) do
    local w = how == "linear" and world({}, 0) or retimed({ keepsLevel = true }, 0)
    w.proxy:send("OFF")
    w.run(10000)
    w.m.sent = {}
    scene(w, 4, { { level = 50, rate = 1000 } })
    w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 4 })
    local preOn, step = w.m.sent[1] or {}, w.m.sent[2] or {}
    T.eq(how .. ": the pre-on and the step each say so", { preOn.preOn, preOn.scene, step.scene }, { true, true, true })
    w.run(10000)
    w.restore()
  end
end)

T.section("eased: a stop part way holds the light where the curve has it")
case(function()
  local w = retimed({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_STOP")
  local p = 0.25
  local eased = p * p * p * (p * (p * 6 - 15) + 10)
  T.eq("a quarter of the time is the eased place", w.proxy:changed(), { math.floor(20 + 80 * eased + 0.5) })
  w.restore()
end)

T.section("retimes: a command naming one aspect runs the other on to its target over its own time")
case(function()
  local w = retimed({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 1000 }
  )
  local changing = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.eq("a color in a level ramp tells the ramp again over the color's time", changing.RATE, 1000)
  w.run(1000)
  T.eq("which ends with it", w.proxy:changed(), { 80 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.eq("a level at once ends a color ramp with it", toldColors(w), { { x = 0.3, y = 0.5 } })
  w.restore()
  w = retimed({}, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  T.eq("and a color at once ends a level ramp at its target", { w.proxy:changed(), w.light.aim.level }, { { 80 } })
  w.restore()
end)

T.section("retimes: another hand's change of either aspect ends both ramps, each told from the report")
case(function()
  local mute = { false }
  local w = retimed({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  hear(w, { on = true, level = 0.3, color = { x = 0.6, y = 0.3 } })
  T.eq("a level from another hand is told", w.proxy:changed(), { 30 })
  T.eq("and its color with it, the color ramp over", { toldColors(w), w.light.aim.color }, { { { x = 0.6, y = 0.3 } } })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  hear(w, { on = true, level = 0.9, color = { x = 0.2, y = 0.2 } })
  T.eq("a color from another hand ends the level ramp too, told from the report", w.proxy:changed(), { 90 })
  T.eq("the ramp over", w.light.aim.level, nil)
  w.restore()
end)

T.section("retimes: a level command reads the color fade it carries on from as it goes out")
case(function()
  local w = retimed({ sendMs = 10 }, 20)
  onMode(w, WARM, DIM)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 1500 }
  )
  w.run(730)
  local at = w.clock.now()
  local ramp = w.light.aim.color
  w.proxy:mark()
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 1500 })
  local p = (at - ramp.startTime) / ramp.durationMs
  p = p * p * p * (p * (p * 6 - 15) + 10)
  local changing = w.proxy:told("LIGHT_COLOR_CHANGING")[1] or {}
  T.check(
    "its color is told from where the fade was when the level went",
    near(changing.LIGHT_COLOR_CURRENT_X, ramp.startX + (0.6 - ramp.startX) * p, 1e-6),
    T.show(changing)
  )
  w.restore()
end)

T.section("retimes: a stop holds the other aspect's ramp over the time it has left")
case(function()
  local w = retimed({}, 20)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.eq("a level stop keeps the color set in the ramp, over its time left", (w.m.sent[1] or {}).ms, 3000)
  T.eq("and sends no color", (w.m.sent[1] or {}).color, nil)
  w.m.sent = {}
  w.proxy:send("SET_COLOR_STOP")
  local stop = w.m.sent[1] or {}
  T.eq("a color stop is a stop of the color", stop.stop, "color")
  T.eq("held over no level ramp at once", stop.ms, 0)
  w.restore()
end)

T.section("retimes: a color for a light fading to off goes over the fade's time left, told at once")
case(function()
  local w = retimed({}, 60)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
  w.run(1000)
  w.proxy:mark()
  w.m.sent = {}
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 500 }
  )
  local cmd = w.m.sent[1] or {}
  T.eq("it goes unlit over the 3 s the fade has left", { cmd.on, cmd.ms }, { false, 3000 })
  T.eq("and is told at once", toldColors(w), { { x = 0.6, y = 0.3 } })
  T.eq("the fade is not told again", w.proxy:told("LIGHT_BRIGHTNESS_CHANGING"), {})
  w.run(3000)
  T.eq("which still ends off", w.proxy:changed(), { 0 })
  w.restore()
end)

T.section("retimes: a scene's stop leaves each ramp its step began to end by its own timer")
case(function()
  local mute = { false }
  local w = retimed({ mute = mute }, 20)
  scene(w, 3, { { level = 80, rate = 4000, color = { x = 0.6, y = 0.3 } }, { level = 20, rate = 0, delay = 5000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 3 })
  w.run(1000)
  -- Only the ramps' own ends are left to tell the proxy.
  mute[1] = true
  T.eq("a step's command says it is a scene's", (w.m.sent[#w.m.sent] or {}).scene, true)
  w.proxy:mark()
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 3 })
  w.run(4000)
  T.eq("the level ends at the step's target", w.proxy:changed(), { 80 })
  T.eq("and the color at the step's color", toldColors(w), { { x = 0.6, y = 0.3 } })
  w.restore()
end)

--- Have the adapter's send raise once, at its nth call from now.
local function raiseAt(w, nth)
  local send, calls = w.m.adapter.send, 0
  w.m.adapter.send = function(self, cmd)
    calls = calls + 1
    if calls == nth then
      w.m.adapter.send = send
      error("frame too long", 0)
    end
    return send(self, cmd)
  end
end

T.section("retimes: a scene step whose send raised told the proxy nothing, as any step")
case(function()
  local w = retimed({}, 40)
  scene(w, 5, { { level = 80, rate = 2000, color = { x = 0.3, y = 0.6 } } })
  raiseAt(w, 1)
  T.check("the step raises send's error", not pcall(w.proxy.send, w.proxy, "ACTIVATE_SCENE", { SCENE_ID = 5 }))
  T.eq("and told the proxy nothing", w.proxy.notes, {})
  w.run(10000)
  T.eq("which shows the light as it is", { w.proxy.level, w.devicePercent() }, { 40, 40 })
  w.restore()
end)

T.section("retimes: a stopped scene's step ramp, put back after a raise, still ends by its own timer")
case(function()
  local w = retimed({}, 20)
  scene(w, 9, { { level = 80, rate = 3000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(1000)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 9 })
  raiseAt(w, 1)
  pcall(w.proxy.send, w.proxy, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 })
  w.run(10000)
  T.eq("the proxy is told the level ramp's end, where the device is", { w.proxy.level, w.devicePercent() }, { 80, 80 })
  w.restore()
  w = retimed({}, 20)
  scene(w, 9, { { color = { x = 0.5, y = 0.4 }, rate = 3000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 9 })
  w.run(1000)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 9 })
  raiseAt(w, 1)
  pcall(w.proxy.send, w.proxy, "SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.3,
    LIGHT_COLOR_TARGET_Y = 0.3,
    LIGHT_COLOR_TARGET_COLOR_RATE = 2000,
  })
  w.run(10000)
  local told, at = toldColor(w) or {}, deviceColor(w)
  T.check("and of the color ramp's", near(told.x, at.x) and near(told.y, at.y), T.show({ told, at }))
  w.restore()
end)

T.section("retimes: a relay's switch takes a color on its way to its target at once, as the device does")
case(function()
  local w = retimed({ dims = false, cct = false })
  w.proxy:send("ON")
  w.run(10000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("OFF")
  T.eq("an Off ends the color ramp at its target", { toldColors(w), w.light.aim.color }, { { { x = 0.6, y = 0.3 } } })
  w.restore()
end)

T.section(
  "retimes: a color ramp another hand's level ends is told from the report, though it is from before the newest"
)
case(function()
  local mute = { false }
  local w = retimed({ mute = mute }, 20)
  mute[1] = true
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(500)
  w.proxy:mark()
  hear(w, { on = true, level = 0.5, color = { x = 0.3127, y = 0.329, mode = CCT } })
  T.eq("its color is told at once", toldColors(w), { { x = 0.3127, y = 0.329 } })
  w.restore()
end)

T.section(
  "darkBetweenModes: a stop while a color ramp crosses color modes eases back up over it, in one command "
    .. "(T3 took the stop time from colorAt)"
)
case(function()
  for _, dark in ipairs({ 500, false }) do
    local name = dark and "dark between modes: " or "control, no darkBetweenModes: "
    local w = retimed({ darkBetweenModes = dark or nil }, 20)
    -- A full color first, so the Dim-To-Warm color the level carries crosses into color temperature.
    w.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
    )
    w.run(1000)
    onMode(w, WARM, DIM)
    w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
    w.run(1000)
    w.m.sent = {}
    w.proxy:mark()
    w.proxy:send("SET_BRIGHTNESS_STOP")
    local stop = w.m.sent[1] or {}
    if dark then
      T.eq(name .. "a level stop with its own color in flight stops both, held over the stop time", {
        stop.stop,
        stop.level ~= nil,
        stop.color ~= nil,
        stop.ms,
      }, { "color", true, true, 500 })
      T.eq(
        name .. "the proxy is told the color, then the level",
        w.proxy:said(),
        { "LIGHT_COLOR_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }
      )
    else
      T.eq(name .. "the stop is not held", stop.ms or 0, 0)
    end
    w.restore()
  end
  local w = retimed({ darkBetweenModes = 500 }, 20)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_COLOR_STOP")
  T.eq(
    "a color stop on a ramp from a white to a full color is held at least the stop time",
    (w.m.sent[1] or {}).ms,
    500
  )
  w.restore()
end)

T.section(
  "darkBetweenModes: with no color ramp crossing modes a level stop goes at once (T3 held it over colorAt's "
    .. "time), and a ramp that keeps a color holds the level alone"
)
case(function()
  local w = retimed({ darkBetweenModes = 500 }, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  local stop = w.m.sent[1] or {}
  T.eq("with no color in flight the light is not between modes: the level stops at once", {
    stop.ms or 0,
    stop.color,
  }, { 0 })
  w.restore()
  w = retimed({ darkBetweenModes = 500 }, 20)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  w.run(1000)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 2000 }
  )
  w.run(500)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  stop = w.m.sent[1] or {}
  T.eq(
    "a ramp that keeps a color of its own holds the level alone over that color's time left",
    { stop.stop, stop.color, stop.ms },
    { nil, nil, 1500 }
  )
  w.restore()
end)

T.section("channelsAt: its color stands for the library's estimate at a stop (colorAt in T3)")
case(function()
  local w = retimed({
    channelsAt = function()
      return { x = 0.25, y = 0.25, mode = FULL }
    end,
  }, 20)
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 4000 }
  )
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("SET_COLOR_STOP")
  T.eq("the stop tells the adapter's color", toldColors(w), { { x = 0.25, y = 0.25 } })
  w.restore()
end)

T.section("shows: the adapter's form of a color, given the color alone (T3's takeColor also had a context)")
case(function()
  local calls = {}
  local mute = { false }
  local w = retimed({
    mute = mute,
    shows = function(_, color, ...)
      calls[#calls + 1] = { x = color.x, y = color.y, mode = color.mode, extra = select("#", ...) }
      return { x = color.x, y = color.y, mode = color.mode == FULL and 2 or color.mode }
    end,
  }, 20)
  local function since(n)
    local out = {}
    for i = n + 1, #calls do
      out[#out + 1] = calls[i]
    end
    return out
  end
  local function pure()
    for _, c in ipairs(calls) do
      if c.extra ~= 0 then
        return false
      end
    end
    return true
  end
  -- The device reports no mode of the adapter's own, so its echoes are kept out of the case.
  mute[1] = true
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.6,
    LIGHT_COLOR_TARGET_Y = 0.3,
    LIGHT_COLOR_TARGET_MODE = 0,
    LIGHT_COLOR_TARGET_COLOR_RATE = 4000,
  })
  local asked = false
  for _, c in ipairs(calls) do
    asked = asked or (near(c.x, 0.6) and near(c.y, 0.3))
  end
  T.check("a color the proxy sets goes through shows as asked", asked, T.show(calls))
  local changing = w.proxy:told("LIGHT_COLOR_CHANGING")[1] or {}
  T.eq("an adapter's own mode is told as a full color", changing.LIGHT_COLOR_TARGET_COLOR_MODE, FULL)
  w.run(1000)
  local n = #calls
  w.proxy:send("SET_COLOR_STOP")
  T.check("a stop's estimate goes through shows too", #since(n) > 0, T.show(calls))
  T.eq("its mode is told as 0", (toldColor(w) or {}).mode, FULL)
  w.proxy:send("OFF")
  T.eq("and kept as given for Previous On", persist:get("previous_color").mode, 2)
  onMode(w, WARM, DIM)
  n = #calls
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  T.check("a Dim-To-Warm color goes through shows", #since(n) > 0, T.show(calls))
  T.check("and every call has the color alone", pure(), T.show(calls))
  w.restore()
end)

T.section("a level the light shows goes again when the ramp a command replaces was heading elsewhere")
case(function()
  forget()
  local w = H.world({ dims = true, policy = "trust" })
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 50 })
  w.run(1000)
  w.proxy:send("BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 1 })
  w.run(110)
  w.m.sent = {}
  w.proxy:send("BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 2 })
  T.eq("a click at the level shown replaces its press's hold ramp, sending the level again", #w.m.sent, 1)
  w.run(5000)
  T.eq("so the light stays at it", { w.proxy.level, w.devicePercent() }, { 50, 50 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 1000 })
  w.run(997)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 1000 })
  T.eq("one replacing a ramp to the level it shows sends nothing more", #w.m.sent, 0)
  w.restore()
end)

T.section("settle: a level shown goes again when the device has said since its command that it is off its way")
case(function()
  local w = world({}, 75)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 2000 })
  w.run(500)
  w.m.other({ on = true, level = 0.91 })
  w.run(2400)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 250 })
  T.eq("another hand's turn-on in a fade to off: an off asked again goes", sentLevels(w), { 0 })
  w.run(10000)
  T.eq("and the light ends off", { w.proxy.level, w.devicePercent() }, { 0, 0 })
  w.restore()
  -- A command at once has no levels between its ends. Two at once: the device reports the first's level,
  -- and a color ramp puts its read-back off.
  w = world({}, 50)
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(300)
  w.m.other({ on = true, level = 0.75 })
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.5, LIGHT_COLOR_TARGET_COLOR_RATE = 5000 }
  )
  w.run(1300)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("another hand's level between the ends of a level at once: the level asked again goes", sentLevels(w), { 100 })
  w.run(10000)
  T.eq("and the light ends there", { w.proxy.level, w.devicePercent() }, { 100, 100 })
  w.restore()
  -- Past its transition a ramp has the light at its target, or elsewhere.
  w = world({}, 0)
  w.proxy:send("RAMP_TO_LEVEL", { LEVEL = 100, TIME = 5000 })
  w.run(100)
  w.m.other({ on = true, level = 0.42 })
  w.run(5300)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("another hand's level on a ramp's path, past its end: the level asked again goes", sentLevels(w), { 100 })
  w.run(10000)
  T.eq("and the light ends at it", { w.proxy.level, w.devicePercent() }, { 100, 100 })
  w.restore()
end)

T.section("a continuous light's report a hair past an end of its range is at that end")
case(function()
  forget()
  local w = H.world({ dims = true, policy = "trust" })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(1000)
  w.m.push({ on = true, level = 0.8000000119 }, {})
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("a Set Level to 100 then sends nothing", #w.m.sent, 0)
  w.restore()
end)

T.section("a light that does not dim has no level ramp: an Off after a rated level is told alone")
case(function()
  forget()
  local w = H.world({ dims = false, policy = "trust" })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
  w.run(1000)
  w.proxy:mark()
  w.proxy:send("OFF")
  w.run(5000)
  T.eq("the proxy is told off, and no ramp's end after it", w.proxy:changed(), { 0 })
  w.restore()
end)

--------------------------------------------------------------------------------
-- The kit's contract run, over MemoryLight
--------------------------------------------------------------------------------

forget()
H.contract(
  T,
  H.memoryRig("a Zigbee bulb (settle)", {
    dims = true,
    color = true,
    cct = { min = 2000, max = 6500 },
    levelSteps = 254,
    keepsLevel = true,
    policy = "settle",
    settleMs = 2500,
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a Zigbee bulb under Dim-To-Warm (settle)", {
    dims = true,
    color = true,
    cct = { min = 2000, max = 6500 },
    levelSteps = 254,
    keepsLevel = true,
    policy = "settle",
    settleMs = 2500,
    setup = H.setupFile("setup-607.xml"),
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a color bulb with no pre-on (settle)", {
    dims = true,
    color = true,
    cct = { min = 2000, max = 6500 },
    levelSteps = 254,
    policy = "settle",
    settleMs = 2500,
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a provider's dimmer (trust)", {
    dims = true,
    levelSteps = 100,
    policy = "trust",
    pushEveryMs = 5000,
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a dimmer that does not fade (none, trust)", {
    dims = true,
    fade = "none",
    policy = "trust",
    pushEveryMs = 5000,
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a relay (none, settle)", {
    dims = false,
    fade = "none",
    policy = "settle",
    settleMs = 2500,
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a bulb that gives its word (settle, ack = done)", {
    dims = true,
    color = true,
    cct = { min = 2000, max = 6500 },
    levelSteps = 254,
    keepsLevel = true,
    policy = "settle",
    settleMs = 2500,
    ack = "done",
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a provider's dimmer that gives its word (trust, ack = done)", {
    dims = true,
    levelSteps = 100,
    policy = "trust",
    pushEveryMs = 5000,
    ack = "done",
  })
)
forget()
H.contract(
  T,
  -- A push in every color ramp, dated by the words, so the window checks judge what a ramp tells.
  H.memoryRig("a provider's color bulb that gives its word (trust, ack = done)", {
    dims = true,
    color = true,
    cct = { min = 2000, max = 6500 },
    levelSteps = 254,
    policy = "trust",
    pushEveryMs = 1000,
    ack = "done",
  })
)
forget()
H.contract(
  T,
  H.memoryRig("a color bulb that echoes each command's targets, re-timing one eased transition (echo)", {
    dims = true,
    color = true,
    cct = { min = 2000, max = 6500 },
    policy = "echo",
    curve = "eased",
    retimes = true,
  })
)

--------------------------------------------------------------------------------
-- The v4 contract (TL-2): API, profile, static capabilities, lifecycle and hooks
--------------------------------------------------------------------------------

local Light = require("lib.light")

--- The static block a profile derives, by capability.
local function staticOf(profile, links)
  local out = {}
  for _, row in ipairs(Caps.static(assert(Caps.profile(profile)), links ~= false)) do
    out[row[1]] = row[2]
  end
  return out
end

--- Collect what log:error logs while `fn` runs.
local function logged(fn)
  local log = require("lib.logging")
  local logError, errors = log.error, {}
  log.error = function(self, fmt, ...)
    errors[#errors + 1] = string.format(tostring(fmt), ...)
    return logError(self, fmt, ...)
  end
  local ok, err = pcall(fn)
  log.error = logError
  if not ok then
    error(err, 0)
  end
  return errors
end

T.section("Light.new: opts.api must be Light.API, and the profile must be checked (T3 took any opts)")
case(function()
  local adapter = { send = function() end }
  local ok, err = pcall(Light.new, adapter, { profile = { dims = true } })
  T.check("no api raises", not ok, err)
  T.check("naming both numbers", tostring(err):find("API nil", 1, true) and tostring(err):find("API 1", 1, true), err)
  ok, err = pcall(Light.new, adapter, { api = 2, profile = { dims = true } })
  T.check("api 2 raises, naming both", not ok and tostring(err):find("API 2", 1, true) ~= nil, err)
  ok, err = pcall(Light.new, adapter, { api = Light.API })
  T.check("no profile raises", not ok and tostring(err):find("opts.profile is required", 1, true) ~= nil, err)
  ok, err = pcall(Light.new, adapter, { api = Light.API, profile = { dims = "yes" } })
  T.check("a bad profile field raises", not ok and tostring(err):find("profile.dims", 1, true) ~= nil, err)
  ok, err = pcall(Light.new, adapter, { api = Light.API, profile = { dimz = true } })
  T.check("an unknown profile field raises", not ok and tostring(err):find("profile.dimz", 1, true) ~= nil, err)
  ok, err = pcall(Light.new, { refresh = function() end }, { api = Light.API, profile = {} })
  T.check("an adapter with no send raises", not ok and tostring(err):find("send", 1, true) ~= nil, err)
  T.eq("Light.API is 1", Light.API, 1)
end)

T.section("Caps.static: the static block from the profile (T3 checked one fixed block); Rule 3.9's color stop")
case(function()
  local rgb = staticOf({ fixed = true, dims = true, color = true })
  T.eq(
    "a fixed RGB light declares its real set",
    { rgb.dimmer, rgb.supports_color, rgb.supports_color_correlated_temperature, rgb.supports_color_stop },
    { "True", "True", "False", "True" }
  )
  local fixedCct = staticOf({ fixed = true, dims = true, cct = { min = 2700, max = 5000 } })
  T.eq(
    "a fixed white light its range",
    { fixedCct.color_correlated_temperature_min, fixedCct.color_correlated_temperature_max },
    { "2700", "5000" }
  )
  local dim = staticOf({ dims = true, color = true, cct = true })
  T.eq("a light whose devices vary: dimming True, color False and raised at run time, 2000 to 6500", {
    dim.dimmer,
    dim.supports_color,
    dim.supports_color_correlated_temperature,
    dim.color_correlated_temperature_min,
    dim.color_correlated_temperature_max,
  }, { "True", "False", "False", "2000", "6500" })
  local dimOnly = staticOf({ dims = true })
  T.eq("a dim-only light has a color stop, so its stops reach it", dimOnly.supports_color_stop, "True")
  T.eq("and no color on modes", dimOnly.color_on_mode_fade, "False")
  local relay = staticOf({})
  T.eq(
    "an on/off relay: no dimming",
    { relay.dimmer, relay.set_level, relay.ramp_level },
    { "False", "False", "False" }
  )
  T.eq(
    "no stops, no click or hold rates",
    { relay.supports_brightness_stop, relay.supports_color_stop, relay.click_rates, relay.hold_rates },
    { "False", "False", "False", "False" }
  )
  T.eq("and no brightness on modes", relay.brightness_on_mode_preset, "False")
  local still = staticOf({ dims = true, color = true, fades = false })
  T.eq(
    "fades = false: the color rate cannot change and nothing stops",
    { still.color_rate_behavior, still.supports_brightness_stop, still.supports_color_stop, still.click_rates },
    { "0", "False", "False", "False" }
  )
  local legs = staticOf({ dims = true, fades = { maxMs = 60000 } })
  T.eq(
    "fades = { maxMs }: the rate maxima run to 24 h, as legs carry them",
    { legs.brightness_rate_max, legs.color_rate_max },
    { "86400000", "86400000" }
  )
  T.eq("and otherwise 65535", { dim.brightness_rate_max, dim.color_rate_max }, { "65535", "65535" })
  local unlinked = staticOf({ dims = true }, false)
  T.eq(
    "links false: no button events and no LEDs",
    { unlinked.has_button_events, unlinked.has_leds },
    { "False", "False" }
  )
  T.eq("links: both", { dim.has_button_events, dim.has_leds }, { "True", "True" })
  local extras = staticOf({ dims = true, extras = true, flash = false, scenes = false })
  T.eq(
    "extras, flash and scenes",
    { extras.has_extras, extras.disable_flash, extras.advanced_scene_support, dim.advanced_scene_support },
    { "True", "True", "False", "True" }
  )
  T.eq("reduced_als_support is False", dim.reduced_als_support, "False")
  local fixedCctTrue = { Caps.profile({ fixed = true, cct = true }) }
  T.eq("a fixed profile with cct true is refused: it names its range", fixedCctTrue[1], nil)
end)

T.section(
  "Caps.write: make light-caps replaces a marked block, an empty one or an unmarked one, and again changes nothing"
)
case(function()
  local profile = assert(Caps.profile({ dims = true }))
  local block = Caps.block(profile, true)
  local head, tail = "<devicedata>\n  <config/>\n", "  <proxies/>\n</devicedata>\n"
  for _, c in ipairs({
    { "an empty <capabilities/>", "  <capabilities/>\n" },
    { "an unmarked block", "  <capabilities>\n    <dimmer>False</dimmer>\n  </capabilities>\n" },
    { "a marked block", "  " .. Caps.BEGIN .. "\n  <capabilities>\n  </capabilities>\n  " .. Caps.END .. "\n" },
  }) do
    local out = assert(Caps.write(head .. c[2] .. tail, profile, true))
    T.eq(c[1] .. ": replaced by the block", out, head .. block .. "\n" .. tail)
    T.eq(c[1] .. ": a second write changes nothing", Caps.write(out, profile, true), out)
  end
  local none = { Caps.write("<devicedata/>", profile, true) }
  T.eq("a driver.xml with no capabilities is an error", { none[1], none[2] ~= nil }, { nil, true })
  local relay = assert(Caps.write(head .. "  <capabilities/>\n" .. tail, assert(Caps.profile({})), true))
  T.check("the written block is the profile's", relay:find("<dimmer>False</dimmer>", 1, true) ~= nil, relay)
end)

T.section("a declaration beyond the profile is refused whole, and a fixed profile's must equal it (T3 took any)")
case(function()
  local dimOnly = assert(Caps.profile({ dims = true }))
  local decl, errors = Caps.check({ dims = true, color = true, reports = { policy = "trust" } }, dimOnly)
  T.eq("color beyond a dim-only profile: refused", decl, nil)
  T.check("naming the claim", (errors[#errors] or ""):find("color", 1, true) ~= nil, T.show(errors))
  T.check(
    "a fade beyond fades = false: refused",
    Caps.check({ dims = true, reports = { policy = "trust" } }, assert(Caps.profile({ dims = true, fades = false })))
      == nil
  )
  T.check(
    "the same with fade none stands",
    Caps.check(
      { dims = true, fade = { by = "none" }, reports = { policy = "trust" } },
      assert(Caps.profile({ dims = true, fades = false }))
    ) ~= nil
  )
  local fixed = assert(Caps.profile({ fixed = true, dims = true, color = true }))
  T.eq(
    "a fixed profile: a declaration with less is refused",
    Caps.check({ dims = true, reports = { policy = "trust" } }, fixed),
    nil
  )
  T.check(
    "and its own set stands",
    Caps.check({ dims = true, color = true, reports = { policy = "trust" } }, fixed) ~= nil
  )
  local w = world({ profile = { dims = true, color = true, cct = true } }, 50)
  local errs = logged(function()
    T.eq(
      "declare takes one within the light's profile",
      w.light:declare({ dims = true, color = true, cct = { min = 2000, max = 6500 }, reports = { policy = "trust" } }),
      true
    )
  end)
  T.eq("a declaration within it stands, with no error", errs, {})
  w.restore()
  w = world({ profile = { dims = true, cct = true } }, 50)
  local before = w.light.device.decl
  errs = logged(function()
    T.eq(
      "declare returns false for color on a profile with none",
      w.light:declare({ dims = true, color = true, reports = { policy = "trust" } }),
      false
    )
  end)
  T.check("and logs it", #errs > 0, T.show(errs))
  T.eq("the last accepted stays in force", w.light.device.decl, before)
  w.restore()
end)

T.section("the gate: a command, button or link before the device's first state sends and tells nothing (T3 sent it)")
case(function()
  local w = world({ offline = true })
  w.proxy:mark()
  w.m.sent = {}
  for _, c in ipairs({
    { "ON" },
    { "SET_LEVEL", { LEVEL = 40 } },
    { "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 1000 } },
    {
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 },
    },
    { "GET_LIGHT_LEVEL" },
    { "BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 2 } },
  }) do
    w.proxy:send(c[1], c[2])
  end
  RFP.DO_CLICK(H.LINKS.toggle, "DO_CLICK", {})
  T.eq("nothing reaches send", w.m.sent, {})
  T.eq("and the proxy is told nothing", w.proxy:said(), {})
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  T.eq("a setting still applies", tonumber(persist:get("max_on_level")), 80)
  w.m.connect()
  w.run(10000)
  T.eq("after the first report", w.proxy.online, true)
  w.m.sent = {}
  w.proxy:send("ON")
  T.check("a command goes", #w.m.sent > 0)
  w.restore()
end)

T.section(
  "lost: suspended keeps the level, unbound turns the LEDs off, a real loss reads off; once per outage (T3 always read off)"
)
case(function()
  local w = world({}, 70)
  w.proxy:mark()
  w.m.drop({ suspended = true })
  T.eq("suspended: offline only", w.proxy:said(), { "ONLINE_CHANGED" })
  T.eq("the level kept", w.proxy.level, 70)
  T.eq("and the LEDs", w.proxy.leds[H.LINKS.top], true)
  T.eq("Connected is false", require("lib.values"):getValue("Connected").value, false)
  w.restore()
  w = world({}, 70)
  w.proxy:mark()
  w.m.drop({ unbound = true })
  T.eq("unbound: offline", w.proxy:said(), { "ONLINE_CHANGED" })
  T.eq("the level kept", w.proxy.level, 70)
  T.eq("the LEDs off", w.proxy.leds[H.LINKS.top], false)
  w.restore()
  w = world({}, 70)
  w.proxy:mark()
  w.m.drop()
  T.eq("a real loss: offline, then off", w.proxy:said(), { "ONLINE_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" })
  T.eq("at 0", w.proxy:changed(), { 0 })
  w.proxy:mark()
  w.light:lost()
  w.light:lost({ suspended = true })
  T.eq("again in the same outage: nothing", w.proxy:said(), {})
  w.m.back()
  w.run(10000)
  T.eq("back, online", w.proxy.online, true)
  T.eq("and Connected true", require("lib.values"):getValue("Connected").value, true)
  T.eq("a lost light keeps the declaration in force", w.light.device.decl ~= nil, true)
  w.restore()
end)

T.section(
  "via: the library owns the device binding; a bind before start tells nothing, after it keeps the state (T3 had no via)"
)
case(function()
  forget()
  local clock = require("c4_fixtures").virtualClock()
  local proxy = H.proxy(clock)
  local m = H.memoryLight(clock, { dims = true, policy = "trust", via = 5002 })
  OnBindingChanged(5002, "LIGHT", true, 0, 0)
  T.eq("a bind before start tells nothing", #proxy.notes, 0)
  m.light:start()
  m.connect()
  clock.run(10000)
  T.eq("start brings it online", proxy.online, true)
  proxy:restore()
  clock.restore()
  local bound = 0
  local w = world({
    via = 5002,
    bound = function()
      bound = bound + 1
    end,
  }, 70)
  local reads = w.m.reads
  w.proxy:mark()
  OnBindingChanged(5002, "LIGHT", true, 0, 0)
  T.eq("a bind after start tells nothing", w.proxy:said(), {})
  T.eq("asks the device again", w.m.reads, reads + 1)
  T.eq("and calls adapter:bound", bound, 1)
  w.m.sent = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 30 })
  T.check("the light still takes a command", #w.m.sent > 0)
  w.run(10000)
  w.proxy:mark()
  OnBindingChanged(5002, "LIGHT", false, 0, 0)
  T.eq("an unbind tells offline", w.proxy:said(), { "ONLINE_CHANGED" })
  T.eq("with no level", w.proxy:changed(), {})
  T.eq("and the LEDs off", w.proxy.leds[H.LINKS.top], false)
  w.m.sent = {}
  w.proxy:send("ON")
  T.eq("unbound, it takes no command", w.m.sent, {})
  w.restore()
  w = world({ via = 5002 }, 40)
  w.light:via(5003)
  T.eq("a change of device binding loses the light as unbound", w.proxy.online, false)
  T.eq("and the old binding is the library's no longer", OBC[5002], nil)
  T.check("the new one is", type(OBC[5003]) == "function")
  OBC[5003] = nil
  w.restore()
end)

T.section("reset: offline once as suspended, the proxy's settings kept, GET_SETUP read again (T3 had no reset)")
case(function()
  local w = world({ setup = H.setupFile("setup-607.xml") }, 70)
  scene(w, 9, { { level = 30, rate = 0 } })
  w.proxy:send("UPDATE_BRIGHTNESS_PRESET", { COMMAND = "ADDED", ID = 4, NAME = "Reading", LEVEL = 35 })
  w.run(1000)
  w.proxy:mark()
  w.light:reset()
  T.eq("offline once, no level", w.proxy:said(), { "ONLINE_CHANGED" })
  T.check("the setup is read again", w.proxy.setupReads >= 1, tostring(w.proxy.setupReads))
  T.check("its scenes kept", next(persist:get("scenes") or {}) ~= nil)
  T.check("and its presets", next(persist:get("brightness_presets") or {}) ~= nil)
  local told = w.light.told
  T.check("its color D65 again", near(told.x, 0.3127) and told.mode == CCT, T.show(told))
  w.run(10000)
  T.eq("the device's next state brings it back", w.proxy.online, true)
  w.restore()
end)

T.section("destroy: no Light timer is left, and nothing is taken after it (T3 had no destroy)")
case(function()
  local w = world({}, 20)
  scene(w, 3, { { level = 80, rate = 3000 }, { delay = 2000, level = 10, rate = 0 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 3 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 4000 })
  local function pending()
    local out = {}
    for k, v in pairs(Timer or {}) do
      if type(k) == "string" and k:match("^Light%.") and v then
        out[#out + 1] = k
      end
    end
    table.sort(out)
    return out
  end
  T.check("a ramp's timer is pending before", #pending() > 0, T.show(pending()))
  w.light:destroy()
  T.eq("none after", pending(), {})
  w.proxy:mark()
  w.m.sent = {}
  w.proxy:send("ON")
  T.eq("a command after it sends nothing", w.m.sent, {})
  T.eq("a report after it is dropped", w.light:report({ on = true, level = 0.5 }, {}), nil)
  w.run(10000)
  T.eq("and nothing is told", w.proxy:said(), {})
  w.restore()
end)

T.section("pass-through: a command on a binding the light does not own reaches the driver's RFP[id] (T3 dropped it)")
case(function()
  local w = world({}, 20)
  local got = {}
  RFP[400] = function(idBinding, strCommand)
    got[#got + 1] = idBinding .. " " .. strCommand
  end
  w.proxy:mark()
  w.m.sent = {}
  ReceivedFromProxy(400, "SET_LEVEL", { LEVEL = 50 })
  ReceivedFromProxy(400, "DO_CLICK", {})
  T.eq("both reach RFP[400]", got, { "400 SET_LEVEL", "400 DO_CLICK" })
  T.eq("and none of the light's", { w.m.sent, w.proxy:said() }, { {}, {} })
  RFP[400] = nil
  ReceivedFromProxy(400, "SET_LEVEL", { LEVEL = 50 })
  T.eq("with no RFP[400], nothing happens", w.m.sent, {})
  w.restore()
end)

T.section("a family the profile leaves out has no handlers; buttons are told only with links (T3 registered all)")
case(function()
  local SCENES = { "PUSH_SCENE", "ACTIVATE_SCENE", "RAMP_SCENE_UP", "STOP_SCENE_RAMP", "STOP_RAMP_SCENE" }
  local ON_MODES = { "UPDATE_BRIGHTNESS_ON_MODE", "UPDATE_COLOR_ON_MODE", "SET_COLOR_ON_MODE" }
  local clock = require("c4_fixtures").virtualClock()
  local proxy = H.proxy(clock, { links = false })
  H.memoryLight(
    clock,
    { dims = true, policy = "trust", profile = { dims = true, scenes = false, onModes = false }, links = false }
  )
  for _, c in ipairs(SCENES) do
    T.eq("scenes = false: no " .. c, RFP[c], nil)
  end
  for _, c in ipairs(ON_MODES) do
    T.eq("onModes = false: no " .. c, RFP[c], nil)
  end
  T.eq("links = false: no DO_CLICK", RFP.DO_CLICK, nil)
  T.check("and the rest are there", type(RFP.SET_LEVEL) == "function")
  proxy:restore()
  clock.restore()
  local w = world({ links = false, offline = true })
  w.m.connect()
  T.eq("with no links NUMBER_BUTTONS is not told", w.proxy:told("NUMBER_BUTTONS"), {})
  w.restore()
  w = world({ offline = true })
  w.m.connect()
  T.eq("with links it is, once", #w.proxy:told("NUMBER_BUTTONS"), 1)
  w.restore()
end)

T.section("has_extras from the profile, and a dim-only light's dynamic color stop (Rule 3.9; T3 told both False)")
case(function()
  local w = world({ profile = { dims = true, color = true, cct = true, extras = true } })
  T.eq("has_extras", w.proxy.caps.has_extras, true)
  w.restore()
  forget()
  w = H.world({ dims = true, policy = "trust" })
  T.eq("a dim-only light tells a color stop", w.proxy.caps.supports_color_stop, true)
  T.eq(
    "and has neither color nor cct",
    { w.proxy.caps.supports_color, w.proxy.caps.supports_color_correlated_temperature },
    {
      false,
      false,
    }
  )
  w.restore()
end)

T.section("the Connected variable follows online (lib.values, BOOL; T3 had none)")
case(function()
  local w = world({ offline = true })
  local values = require("lib.values")
  T.eq("offline at start", (values:getValue("Connected") or {}).value, false)
  T.eq("a BOOL", (values:getValue("Connected") or {}).varType, "BOOL")
  w.m.connect()
  T.eq("online at the first report", values:getValue("Connected").value, true)
  w.m.drop({ suspended = true })
  T.eq("offline when lost", values:getValue("Connected").value, false)
  w.restore()
end)

T.section(
  "shown: the adapter hears what the proxy shows after each level and color tell; a raise is logged (T3 had none)"
)
case(function()
  local heard = {}
  local w = world({
    shown = function(_, s)
      heard[#heard + 1] = s
    end,
  }, 20)
  heard = {}
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(10000)
  local last = heard[#heard] or {}
  T.eq("a level tell: the level", last.level, 50)
  T.check("with the color", last.color ~= nil and last.color.x ~= nil, T.show(last))
  w.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.3, LIGHT_COLOR_TARGET_Y = 0.6, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
  )
  w.run(10000)
  last = heard[#heard] or {}
  T.check("a color tell: the color", near((last.color or {}).x, 0.3) and near((last.color or {}).y, 0.6), T.show(last))
  w.restore()
  w = world({
    shown = function()
      error("the page is gone", 0)
    end,
  }, 20)
  local errs = logged(function()
    local ok = pcall(w.proxy.send, w.proxy, "SET_LEVEL", { LEVEL = 60 })
    T.check("a raising shown does not raise out of the command", ok)
    w.run(10000)
  end)
  T.check("it is logged", #errs > 0 and errs[1]:find("the page is gone", 1, true) ~= nil, T.show(errs))
  T.eq("and the level is still told", w.proxy.level, 60)
  w.restore()
end)

T.finish()
