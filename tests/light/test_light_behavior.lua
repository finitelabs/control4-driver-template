-- The light library's behavior over MemoryLight behind the fake proxy: start, the connection, and how
-- the light moves under each fade kind. The template's own test: no driver repo gets it.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local K = require("behavior_kit")
local M = require("memory_light")

local function case(fn)
  K.case(T, fn)
end

local near = K.near

--------------------------------------------------------------------------------
-- Start and the connection
--------------------------------------------------------------------------------

T.section("start tells offline and asks the device once; its first report brings it online, then the capabilities")
case(function()
  local w = K.world(K.ES, { offline = true })
  T.eq("offline at start", w.proxy.online, false)
  T.eq("the device asked once", w.m.reads, 1)
  w.m:connect()
  local said = w.proxy:said()
  local online, caps
  for i, cmd in ipairs(said) do
    if cmd == "ONLINE_CHANGED" and not online then
      online = i
    elseif cmd == "DYNAMIC_CAPABILITIES_CHANGED" and not caps then
      caps = i
    end
  end
  T.eq("online at the first report", w.proxy.online, true)
  T.check("ONLINE_CHANGED before the capabilities", online ~= nil and caps ~= nil and online < caps, said)
  w.restore()
end)

T.section("a report before start is kept, and taken at start, in order")
case(function()
  local w = K.world(K.ES, { noStart = true })
  w.device:set({ on = true, level = 0.6 })
  w.light:declare(w.m:declaration())
  w.m.online = true
  w.light:report({ kind = "push", on = true, level = 0.3 })
  w.light:report({ kind = "push", on = true, level = 0.6 })
  T.eq("nothing told before start", w.proxy:count("LIGHT_BRIGHTNESS_CHANGED"), 0)
  w.light:start()
  w.run(5000)
  T.eq("online once started", w.proxy.online, true)
  T.eq("the last of them is what the proxy shows", w.proxy.level, 60)
  w.restore()
end)

T.section("J2: a fresh proxy, which shows nothing yet, is told the device's first state, off included")
for _, on in ipairs({ true, false }) do
  case(function()
    local w = K.world(K.ES, { offline = true, on = on, level = 0.4 })
    w.m:connect()
    w.run(1000)
    T.eq(on and "lit" or "off", w.proxy.level, on and 40 or 0)
    w.restore()
  end)
end

T.section("a report with no device declared is dropped")
case(function()
  local w = K.world(K.ES, { noStart = true })
  w.light:start()
  w.light:report({ kind = "push", on = true, level = 0.5 })
  w.run(1000)
  T.falsy("not online", w.proxy.online)
  T.eq("and nothing told of it", w.proxy:count("LIGHT_BRIGHTNESS_CHANGED"), 0)
  w.restore()
end)

T.section("the gate: a command, button or link before the device's first report sends and tells nothing")
case(function()
  local w = K.world(K.ES, { offline = true })
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.proxy:send("ON")
  K.button(w, 0, 1)
  K.button(w, 0, 2)
  w.proxy:link(M.LINKS.toggle, "DO_PUSH")
  w.proxy:link(M.LINKS.toggle, "DO_CLICK")
  w.run(3000)
  T.eq("nothing sent", #w.m.sent, 0)
  T.eq("no level told", w.proxy:count("LIGHT_BRIGHTNESS_CHANGED") + w.proxy:count("LIGHT_BRIGHTNESS_CHANGING"), 0)
  w.m:connect()
  w.run(1000)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(3000)
  T.eq("after the first report a command goes", w.m:sentLevels(), { 50 })
  w.restore()
end)

T.section("the Connected variable follows online")
case(function()
  local w = K.world(K.ES, { offline = true })
  local values = require("lib.values")
  local function connected()
    local v = values:getValue("Connected")
    return v and v.value
  end
  T.eq("offline at start", connected(), false)
  w.m:connect()
  T.eq("online at the first report", connected(), true)
  w.m:drop(true)
  T.eq("offline when lost", connected(), false)
  w.restore()
end)

--------------------------------------------------------------------------------
-- A restart: the first report against what the proxy shows (J2)
--------------------------------------------------------------------------------

T.section("J2: a restart where the device is as the proxy shows it tells no level and no color")
for _, base in ipairs({ K.ES, K.ZB, K.HOLD }) do
  case(function()
    local w = K.world(base, {}, 60)
    K.color(w, K.RED.x, K.RED.y)
    w.run(10000)
    w.restart()
    w.run(10000)
    T.eq("no level told", w.proxy:count("LIGHT_BRIGHTNESS_CHANGED") + w.proxy:count("LIGHT_BRIGHTNESS_CHANGING"), 0)
    T.eq("no color told", w.proxy:count("LIGHT_COLOR_CHANGED") + w.proxy:count("LIGHT_COLOR_CHANGING"), 0)
    T.eq("still showing 60", w.proxy.level, 60)
    w.restore()
  end)
end

T.section("J2: a device that moved while the driver was down is told at its first report")
case(function()
  local w = K.world(K.ES, {}, 60)
  w.device:set({ on = true, level = 0.3 })
  w.restart()
  w.run(5000)
  T.eq("the device's level is told", w.proxy:changed(), { 30 })
  w.restore()
end)

T.section("J2: a proxy still ramping at the restart (1110 not 1001) takes the device's word")
case(function()
  local w = K.world(K.ES, {}, 40)
  w.proxy.vars["1110"] = { value = "80" }
  w.device:set({ on = true, level = 0.8 })
  w.restart()
  w.run(5000)
  T.eq("the device's level is told", w.proxy.level, 80)
  w.restore()
end)

--------------------------------------------------------------------------------
-- Losses, reset and declarations
--------------------------------------------------------------------------------

T.section("a loss tells offline and off once per outage; a suspend keeps the level")
case(function()
  local w = K.world(K.ES, {}, 60)
  w.m:drop(false)
  T.eq("offline", w.proxy.online, false)
  T.eq("off told once", w.proxy:changed(), { 0 })
  T.eq("the LEDs off: Top unlit", w.proxy.leds[M.LINKS.top], false)
  w.light:lost(false)
  T.eq("a second loss tells nothing more", w.proxy:changed(), { 0 })
  w.m:back()
  w.run(5000)
  T.eq("back, the device's level is told", w.proxy.level, 60)
  w.proxy:mark()
  w.m:drop(true)
  T.eq("a suspend tells offline", w.proxy.online, false)
  T.eq("and keeps the level", w.proxy:changed(), {})
  w.light:lost(false)
  T.eq("a loss after a suspend reads off", w.proxy:changed(), { 0 })
  w.restore()
end)

T.section("a command while the device is lost sends nothing")
case(function()
  local w = K.world(K.ES, {}, 60)
  w.m:drop(true)
  w.proxy:send("SET_LEVEL", { LEVEL = 20 })
  K.target(w, 90, 2000)
  w.run(5000)
  T.eq("nothing sent", #w.m.sent, 0)
  w.restore()
end)

T.section("reset: offline until the next report, the device asked once, the proxy's settings kept")
case(function()
  local w = K.world(K.ES, {}, 0)
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 70 })
  local reads = w.m.reads
  w.light:reset()
  T.eq("offline", w.proxy.online, false)
  T.eq("the device asked once", w.m.reads, reads + 1)
  w.run(5000)
  T.eq("its answer brings it online", w.proxy.online, true)
  w.proxy:send("ON")
  w.run(5000)
  T.eq("an On still goes to the preset level", w.proxy.level, 70)
  w.restore()
end)

T.section("declare: the same facts do nothing; capabilities alone are re-told and keep the run")
case(function()
  local w = K.world(K.ES, {}, 20)
  w.light:declare(w.m:declaration())
  T.eq("the same facts tell nothing", w.proxy:count("DYNAMIC_CAPABILITIES_CHANGED"), 0)
  K.target(w, 80, 4000)
  w.run(1000)
  w.m.o.color = false
  w.light:declare(w.m:declaration())
  T.eq("a capability change is told", w.proxy:count("DYNAMIC_CAPABILITIES_CHANGED"), 1)
  T.eq("without color", (w.proxy.caps or {}).supports_color, false)
  T.eq("the ramp runs on", w.proxy:changed(), {})
  w.run(5000)
  T.eq("and ends at its own time", w.proxy:changed(), { 80 })
  w.restore()
end)

T.section("declare: a changed fade ends the running ramps at their targets (tp:4647-4653)")
case(function()
  local w = K.world(K.ES, {}, 20)
  K.target(w, 80, 4000)
  w.run(1000)
  w.m.o.fade = { kind = "device", curve = "linear", preOn = true }
  w.light:declare(w.m:declaration())
  T.eq("told its target at once", w.proxy:changed(), { 80 })
  w.run(10000)
  T.eq("and nothing more", w.proxy:changed(), { 80 })
  w.restore()
end)

T.section("N9: a capability lost mid-connection takes effect at once")
case(function()
  local w = K.world(K.ES, {}, 50)
  w.m.o.color = false
  w.m.o.cct = nil
  w.light:declare(w.m:declaration())
  w.m.sent = {}
  K.color(w, K.RED.x, K.RED.y)
  w.run(2000)
  local colored = 0
  for _, c in ipairs(w.m.sent) do
    if c.setsColor then
      colored = colored + 1
    end
  end
  T.eq("no color goes to a device that has none", colored, 0)
  w.restore()
end)

--------------------------------------------------------------------------------
-- Levels and fades
--------------------------------------------------------------------------------

T.section("a level over a rate: CHANGING to it, CHANGED at its end, and the device ends there")
case(function()
  local w = K.world(K.ES, {}, 20)
  K.target(w, 80, 2000)
  local changing = w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}
  T.eq(
    "CHANGING from where it is to the target over the rate",
    { changing.LIGHT_BRIGHTNESS_CURRENT, changing.LIGHT_BRIGHTNESS_TARGET, changing.RATE },
    { 20, 80, 2000 }
  )
  T.eq("one command, over the rate", { #w.m.sent, (w.m.sent[1] or {}).transitionMs }, { 1, 2000 })
  w.run(1000)
  T.eq("no CHANGED part way", w.proxy:changed(), {})
  w.run(4000)
  T.eq("CHANGED at its end", w.proxy:changed(), { 80 })
  T.eq("the device there", K.devicePercent(w), 80)
  w.restore()
end)

T.section("a rated on from off on a device that keeps its level opens with a 0-time pre-on at the bottom step")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.target(w, 80, 2000)
  local first, second = w.m.sent[1] or {}, w.m.sent[2] or {}
  T.eq(
    "a pre-on first, at once",
    { first.kind, first.transitionMs, first.on, first.fromOff },
    { "preOn", 0, true, true }
  )
  T.check("at the bottom step", first.level ~= nil and first.level <= 0.01, first.level)
  T.eq(
    "then the change, over the rate",
    { second.kind, second.transitionMs, second.fromOff },
    { "change", 2000, false }
  )
  local changing = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.check("told CHANGING from the bottom", (changing.LIGHT_BRIGHTNESS_CURRENT or 99) <= 1, changing)
  T.eq("to the target, over the rate", { changing.LIGHT_BRIGHTNESS_TARGET, changing.RATE }, { 80, 2000 })
  w.run(1000)
  T.eq("told once", w.proxy:count("LIGHT_BRIGHTNESS_CHANGING"), 1)
  w.run(5000)
  T.eq("lands", { w.proxy.level, K.devicePercent(w) }, { 80, 80 })
  w.restore()
end)

T.section("a device that does not keep its level takes a rated on from off in one command")
case(function()
  local w = K.world(K.ES, { fade = { kind = "device", curve = "linear", preOn = false } }, 0)
  K.target(w, 80, 2000)
  T.eq("one command", #w.m.sent, 1)
  T.eq("the change, lighting it", { w.m.sent[1].kind, w.m.sent[1].fromOff }, { "change", true })
  w.run(5000)
  T.eq("lands", K.devicePercent(w), 80)
  w.restore()
end)

T.section("a stop part way holds the light at the estimate: one stop command, CHANGED there")
case(function()
  local w = K.world(K.ES, { fade = { kind = "device", curve = "linear", preOn = true } }, 20)
  K.target(w, 80, 4000)
  w.run(2000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  local stop = w.m.sent[1] or {}
  T.eq("a stop", { #w.m.sent, stop.kind }, { 1, "stop" })
  T.check("at the estimate", near(stop.level, 0.5, 0.02), stop.level)
  T.check("told CHANGED there", near(w.proxy:changed()[1], 50, 1), w.proxy:changed())
  w.run(5000)
  T.check("the device holds there", near(K.devicePercent(w), 50, 2), K.devicePercent(w))
  T.eq("and nothing more is told", #w.proxy:changed(), 1)
  w.restore()
end)

T.section("smootherstep: a stop a quarter of the way holds where the curve has it")
case(function()
  local w = K.world(K.ES, {}, 20)
  K.target(w, 80, 4000)
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("SET_BRIGHTNESS_STOP")
  local p = 0.25
  local eased = p * p * p * (p * (p * 6 - 15) + 10)
  local want = 0.2 + 0.6 * eased
  T.check("the stop at the curve's level", near((w.m.sent[1] or {}).level, want, 0.02), (w.m.sent[1] or {}).level)
  T.check("not the straight line's", not near((w.m.sent[1] or {}).level, 0.35, 0.03))
  w.restore()
end)

T.section("own lengths: commands carry no fade time, and the proxy is told CHANGING over the device's own")
case(function()
  local w = K.world(K.OWN, {}, 0)
  w.proxy:send("ON")
  T.eq("no fade time on the wire", (w.m.sent[1] or {}).transitionMs, 0)
  T.eq("CHANGING over the on length", (w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}).RATE, 400)
  w.run(2000)
  T.eq("CHANGED at its end", w.proxy.level, 100)
  w.proxy:mark()
  K.target(w, 50, 5000)
  T.eq(
    "a rate the device cannot take is its change length",
    (w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}).RATE,
    300
  )
  w.run(2000)
  w.proxy:mark()
  w.proxy:send("OFF")
  T.eq("an off over the off length", (w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}).RATE, 800)
  w.run(2000)
  T.eq("off", w.proxy.level, 0)
  w.restore()
end)

T.section("own 0: every change is told CHANGED alone, as the command goes out (section 6: hatch)")
case(function()
  local w = K.world(K.HOLD, {}, 0)
  K.target(w, 60, 3000)
  T.eq("no CHANGING", w.proxy:count("LIGHT_BRIGHTNESS_CHANGING"), 0)
  T.eq("CHANGED at once", w.proxy:changed(), { 60 })
  T.eq("no fade time on the wire", (w.m.sent[1] or {}).transitionMs, 0)
  w.run(10000)
  T.eq("the device's echo tells nothing more", w.proxy:changed(), { 60 })
  w.restore()
end)

T.section("the walk: a fade goes as 0-time steps every stepMs, at most duration / stepMs + 2, ending at the target")
case(function()
  local w = K.world(K.WALK, {}, 20)
  K.target(w, 80, 2000)
  T.eq("CHANGING told once, over the rate", (w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}).RATE, 2000)
  w.run(4000)
  local timed, falling, last = 0, false, nil
  for _, c in ipairs(w.m.sent) do
    if c.transitionMs ~= 0 then
      timed = timed + 1
    end
    if last and c.level < last - 1e-9 then
      falling = true
    end
    last = c.level
  end
  T.eq("every step takes no time", timed, 0)
  T.check("about one step per 100 ms", #w.m.sent >= 10 and #w.m.sent <= 22, #w.m.sent)
  T.falsy("each step at or past the one before", falling)
  T.check("the last at the target", near(last, 0.8, 0.011), last)
  T.eq("CHANGED at the end", w.proxy:changed(), { 80 })
  T.eq("the device there", K.devicePercent(w), 80)
  w.restore()
end)

T.section("the walk: a stop sends one last 0-time step at the estimate (section 6: tplink Fades=Driver)")
case(function()
  local w = K.world(K.WALK, {}, 20)
  K.target(w, 80, 2000)
  w.run(1000)
  local before = #w.m.sent
  w.proxy:send("SET_BRIGHTNESS_STOP")
  local stop = w.m.sent[#w.m.sent] or {}
  T.eq("one more command", #w.m.sent, before + 1)
  T.eq("a 0-time stop", { stop.kind, stop.transitionMs }, { "stop", 0 })
  T.check("at the estimate", near(stop.level, 0.5, 0.03), stop.level)
  w.run(3000)
  T.eq("and no step after it", #w.m.sent, before + 1)
  T.check("told CHANGED there", near(w.proxy.level, 50, 2), w.proxy.level)
  w.restore()
end)

T.section("a relay: on and off with no fade time; SET_LEVEL 0 is off; Toggle switches it")
case(function()
  local w = K.world(K.RELAY, {}, 0)
  w.proxy:send("ON")
  T.eq("on, at once", { (w.m.sent[1] or {}).on, (w.m.sent[1] or {}).transitionMs }, { true, 0 })
  w.run(2000)
  T.eq("told 100", w.proxy.level, 100)
  w.proxy:send("SET_LEVEL", { LEVEL = 0 })
  w.run(2000)
  T.eq("SET_LEVEL 0 is off", { w.proxy.level, K.device(w).on }, { 0, false })
  w.proxy:send("TOGGLE")
  w.run(2000)
  T.eq("a Toggle turns it on", K.device(w).on, true)
  w.proxy:send("TOGGLE")
  w.run(2000)
  T.eq("and off", K.device(w).on, false)
  w.restore()
end)

T.section("a light that does not dim has no level ramp: a rated level is told CHANGED alone")
case(function()
  local w = K.world(K.RELAY, {}, 0)
  K.target(w, 60, 2000)
  T.eq("no CHANGING", w.proxy:count("LIGHT_BRIGHTNESS_CHANGING"), 0)
  w.run(2000)
  T.eq("on at full", w.proxy.level, 100)
  w.restore()
end)

T.section("the proxy's level commands: RAMP_TO_LEVEL takes its TIME, and a target keeps its preset id")
case(function()
  local w = K.world(K.ES, {}, 20)
  w.proxy:send("RAMP_TO_LEVEL", { LEVEL = 60, TIME = 1500 })
  T.eq("over its TIME", (w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}).RATE, 1500)
  w.run(5000)
  w.proxy:mark()
  w.proxy:send(
    "SET_BRIGHTNESS_TARGET",
    { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 1000, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 3 }
  )
  T.eq(
    "the preset id told with it",
    (w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}).LIGHT_BRIGHTNESS_TARGET_PRESET_ID,
    3
  )
  w.run(5000)
  T.eq("lands", w.proxy.level, 40)
  w.restore()
end)

T.section("a target with no rate takes the brightness rate default")
case(function()
  local w = K.world(K.ES, {}, 20)
  w.proxy:send("UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = 1200 })
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70 })
  T.eq("over the default", (w.m.sent[#w.m.sent] or {}).transitionMs, 1200)
  w.run(5000)
  w.restore()
end)

T.section("Min and Max On remap every level sent and shown, and show() gives the adapter the range")
case(function()
  local w = K.world(K.ES, {}, 50)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 20 })
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  local shown = w.m.shown[#w.m.shown] or {}
  T.eq("the adapter shown the range", { shown.minOn, shown.maxOn }, { 20, 80 })
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(5000)
  T.eq("100 is the Max On", K.devicePercent(w), 80)
  w.proxy:send("SET_LEVEL", { LEVEL = 1 })
  w.run(5000)
  T.check("1 is the Min On", near(K.devicePercent(w), 20, 1), K.devicePercent(w))
  T.eq("the proxy shows the Control4 level", w.proxy.level, 1)
  w.restore()
end)

T.section("show(): at the connection's first report, and when a shown field changes, not otherwise")
case(function()
  local w = K.world(K.ES, {})
  T.eq("once at the first report", #w.m.shown, 1)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.run(5000)
  T.eq("not for a level", #w.m.shown, 1)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 10 })
  T.eq("again when the Min changes", #w.m.shown, 2)
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 10 })
  T.eq("not for the same Min", #w.m.shown, 2)
  w.restore()
end)

T.section("a device's longest rate is the proxy's rate maximum")
case(function()
  local w = K.world(K.ES, { fade = { kind = "device", preOn = true, maxMs = 60000 } })
  T.eq("brightness_rate_max", (w.proxy.caps or {}).brightness_rate_max, 60000)
  w.restore()
end)

T.finish()
