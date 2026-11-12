-- The light library's behavior over MemoryLight behind the fake proxy: how reports are weighed against
-- the commands sent, what a LightRest tells, and when the device is asked. The
-- template's own test: no driver repo gets it.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local K = require("behavior_kit")

local function case(fn)
  K.case(T, fn)
end

local near = K.near

--- A world whose device pushes nothing of its own: reports come only as a section injects them, or as
--- answers to reads.
--- @param base MemoryOptions
--- @param level integer|nil
--- @return MemoryWorld
local function quiet(base, level)
  local w = K.world(base, {}, level)
  w.m.o.silent = true
  w.m.o.readbackMs = nil
  return w
end

--- A push now.
--- @param w MemoryWorld
--- @param values LightValues
--- @param kind LightReportKind|nil
local function report(w, values, kind)
  local r = K.copy(values)
  r.kind = kind or "push"
  w.m:deliver(r)
end

--------------------------------------------------------------------------------
-- Echoes and positions
--------------------------------------------------------------------------------

T.section("target feedback: an echo during a ramp ends nothing; the ramp is told CHANGED at its own end")
case(function()
  local w = K.world(K.ES, {}, 20)
  K.target(w, 80, 3000)
  w.run(1500)
  T.eq("the device's echo of the target tells nothing part way", w.proxy:changed(), {})
  w.run(3000)
  T.eq("CHANGED once, at the ramp's end", w.proxy:changed(), { 80 })
  w.restore()
end)

T.section("position feedback: a device that lands before the ramp's time ends the ramp, told at its report")
case(function()
  local w = K.world(K.ZB, { slow = 0.5 }, 20)
  K.target(w, 80, 4000)
  w.run(2600)
  T.eq("told at the landing push", w.proxy:changed(), { 80 })
  w.run(5000)
  T.eq("and nothing more at the ramp's own time", w.proxy:changed(), { 80 })
  w.restore()
end)

T.section("position feedback: a push on the way tells nothing while the ramp runs")
case(function()
  local w = K.world(K.ZB, {}, 20)
  K.target(w, 80, 4000)
  w.run(3000)
  T.check("the device pushed its way", #w.m.reports > 1, #w.m.reports)
  T.eq("nothing told part way", w.proxy:changed(), {})
  w.run(5000)
  T.eq("CHANGED at the end", w.proxy:changed(), { 80 })
  w.restore()
end)

--------------------------------------------------------------------------------
-- Read answers
--------------------------------------------------------------------------------

T.section("a final answer ends a running ramp at its value, whatever it shows")
case(function()
  local w = quiet(K.ZB, 20)
  K.target(w, 80, 4000)
  w.run(1000)
  report(w, { on = true, level = 0.5 }, "final")
  T.eq("told at once", w.proxy:changed(), { 50 })
  w.run(10000)
  T.eq("the ramp told nothing more", w.proxy:changed(), { 50 })
  w.restore()
end)

T.section("a moving answer is held, and the deadline reads the device before adopting it")
case(function()
  local w = quiet(K.ZB, 20)
  K.target(w, 80, 2000)
  w.run(500)
  report(w, { on = true, level = 0.4 }, "moving")
  T.eq("held: nothing told", w.proxy:changed(), {})
  w.run(1600)
  T.eq("the ramp's end is told", w.proxy:changed(), { 80 })
  -- A held position may lag the light: the deadline reads it once, and the device's answer, its ramp's end,
  -- settles, so the stale 40 is never told.
  w.run(5600)
  T.eq("the read's answer stands: nothing more told", w.proxy:changed(), { 80 })
  w.restore()
end)

--------------------------------------------------------------------------------
-- Another hand, and history
--------------------------------------------------------------------------------

T.section("another hand's change with no window open is adopted and told at once")
for _, base in ipairs({ K.ES, K.ZB, K.HOLD, K.WALK }) do
  case(function()
    local w = K.world(base, {}, 50)
    w.run(10000)
    w.proxy:mark()
    w.m:other({ on = true, level = 0.3 })
    w.run(500)
    T.eq("told", w.proxy:changed(), { 30 })
    w.restore()
  end)
end

T.section("another hand's off is adopted, and the LEDs follow")
case(function()
  local w = K.world(K.ES, {}, 50)
  w.run(10000)
  w.proxy:mark()
  w.m:other({ on = false })
  w.run(500)
  T.eq("off told", w.proxy:changed(), { 0 })
  T.eq("every link dark with it", w.proxy.leds[require("memory_light").LINKS.bottom], false)
  w.restore()
end)

T.section("target feedback: a push matching nothing in a window is another hand's: adopted, the ramp ends")
case(function()
  local w = quiet(K.ES, 20)
  K.target(w, 80, 3000)
  w.run(500)
  report(w, { on = true, level = 0.3 })
  T.eq("told at once", w.proxy:changed(), { 30 })
  w.run(5000)
  T.eq("the ramp ended there", w.proxy:changed(), { 30 })
  w.restore()
end)

T.section("a push of an older command is history: held, and the newest's echo clears it")
case(function()
  local w = quiet(K.ES, 20)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  report(w, { on = true, level = 0.5 })
  T.eq("the older level tells nothing", w.proxy:changed(), { 50, 70 })
  report(w, { on = true, level = 0.7 })
  w.run(5000)
  T.eq("the newest's echo stands", w.proxy.level, 70)
  T.eq("nothing more told", #w.proxy:changed(), 2)
  w.restore()
end)

T.section("history held to the deadline, with no echo of the newest, is adopted then")
case(function()
  local w = quiet(K.ES, 20)
  w.proxy:send("SET_LEVEL", { LEVEL = 50 })
  w.proxy:send("SET_LEVEL", { LEVEL = 70 })
  report(w, { on = true, level = 0.5 })
  w.run(5000)
  T.eq("the device's word stands at the deadline", w.proxy.level, 50)
  w.restore()
end)

--------------------------------------------------------------------------------
-- Silence and asks
--------------------------------------------------------------------------------

T.section("a command nothing contradicts is never reverted")
for _, base in ipairs({ K.ES, K.HOLD }) do
  case(function()
    local w = quiet(base, 20)
    w.m.dropReads = true
    w.m.dropNext = true
    w.proxy:send("SET_LEVEL", { LEVEL = 60 })
    w.run(20000)
    T.eq("the command stands", w.proxy.level, 60)
    w.restore()
  end)
end

T.section("silence on a refresh device asks one read at the deadline and waits once more")
case(function()
  local w = quiet(K.OWN, 20)
  w.m.dropReads = true
  local reads = w.m.reads
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(500)
  T.eq("no read before the deadline", w.m.reads, reads)
  w.run(1000)
  T.eq("one read at it", w.m.reads, reads + 1)
  w.run(10000)
  T.eq("and no more", w.m.reads, reads + 1)
  T.eq("then the command stands", w.proxy.level, 60)
  w.restore()
end)

T.section("silence on a device whose refresh is costly asks nothing")
case(function()
  local w = quiet(K.ES, 20)
  local reads = w.m.reads
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(10000)
  T.eq("no read", w.m.reads, reads)
  T.eq("the command stands", w.proxy.level, 60)
  w.restore()
end)

T.section("a write the device dropped is put right by the answer to the deadline's read")
case(function()
  local w = quiet(K.OWN, 20)
  w.m.dropNext = true
  w.proxy:send("SET_LEVEL", { LEVEL = 60 })
  w.run(10000)
  T.eq("the device's word at the read", w.proxy.level, 20)
  w.restore()
end)

T.section("another hand's turn-on with no level asks one read, and the on is told with the level it brings")
case(function()
  local w = quiet(K.ZB, 0)
  local reads = w.m.reads
  w.device:set({ on = true, level = 0.7 })
  report(w, { on = true })
  T.eq("one read asked", w.m.reads, reads + 1)
  w.run(5000)
  T.eq("the on told with the read's level", w.proxy:changed(), { 70 })
  w.restore()
end)

T.section("on a refresh device, an off held against a command that lights the light asks one read")
case(function()
  local w = quiet(K.ZB, 0)
  local reads = w.m.reads
  w.proxy:send("ON")
  report(w, { on = false })
  report(w, { on = false })
  T.eq("one read for both", w.m.reads, reads + 1)
  w.run(10000)
  w.restore()
end)

--------------------------------------------------------------------------------
-- Seeds, matching and partial reports
--------------------------------------------------------------------------------

T.section("a seed after the aspect's first report is dropped")
case(function()
  local w = quiet(K.ZB, 50)
  w.run(10000)
  w.proxy:mark()
  report(w, { on = true, level = 0.9 }, "seed")
  w.run(5000)
  T.eq("nothing told", w.proxy:changed(), {})
  w.restore()
end)

T.section("a seed as the first report fills the aspects not yet heard")
case(function()
  local w = K.world(K.ZB, { offline = true })
  w.m.online = true
  w.light:declare(w.m:declaration())
  report(w, { on = true, level = 0.4 }, "seed")
  w.run(1000)
  T.eq("told", w.proxy.level, 40)
  w.restore()
end)

T.section("matching is in device units: a level within the device's step tells nothing")
case(function()
  local w = quiet(K.ZB, 50)
  w.run(10000)
  w.proxy:mark()
  report(w, { on = true, level = 0.5 + 0.4 / 254 })
  w.run(1000)
  T.eq("nothing told", w.proxy:changed(), {})
  report(w, { on = true, level = 0.5 + 3 / 254 })
  w.run(1000)
  T.eq("three steps away is another hand's", #w.proxy:changed(), 1)
  w.restore()
end)

T.section("a report says only what it carries: a level alone says nothing of color or on")
case(function()
  local w = quiet(K.ES, 50)
  K.color(w, K.RED.x, K.RED.y)
  w.run(10000)
  w.proxy:mark()
  report(w, { level = 0.5 })
  w.run(1000)
  T.eq("no color told", w.proxy:count("LIGHT_COLOR_CHANGED"), 0)
  T.eq("no level told", w.proxy:changed(), {})
  w.restore()
end)

--------------------------------------------------------------------------------
-- LightRest
--------------------------------------------------------------------------------

T.section("LightRest: a favorite's own level is told once, as the command goes out, and its echo tells nothing (F2)")
case(function()
  local o = K.copy(K.HOLD)
  o.color = false
  o.rest = function(cmd)
    if cmd.fromOff then
      return { level = 0.4 }
    end
  end
  local w = K.world(o, {}, 0)
  w.proxy:send("SET_LEVEL", { LEVEL = 80 })
  T.eq("one CHANGED, at the rest", w.proxy:changed(), { 40 })
  w.run(10000)
  T.eq("the device's echo tells nothing more", w.proxy:changed(), { 40 })
  T.eq("the device rests there", K.devicePercent(w), 40)
  w.restore()
end)

T.section("LightRest: a stop held where the adapter's own fade had got to is told there")
case(function()
  local o = K.copy(K.ES)
  o.rest = function(cmd)
    if cmd.kind == "stop" then
      return { level = 0.3 }
    end
  end
  local w = K.world(o, {}, 20)
  K.target(w, 80, 4000)
  w.run(2000)
  w.proxy:send("SET_BRIGHTNESS_STOP")
  T.eq("told at the rest, once", w.proxy:changed(), { 30 })
  w.run(5000)
  T.eq("and nothing after", w.proxy:changed(), { 30 })
  w.restore()
end)

T.section("an off 5 ms into a ramp from off: the turn-on's late echo tells nothing")
for _, base in ipairs({ K.ES, K.ZB, K.WALK, K.OWN }) do
  K.case(T, function()
    local w = K.world(base, {}, 0)
    w.proxy:mark()
    K.target(w, 60, 2000)
    w.run(5)
    w.proxy:send("OFF")
    w.run(15000)
    local told = w.proxy:changed()
    T.eq("it ends at 0", told[#told], 0)
    T.check("and tells no lit level after the off", #told <= 2, K.story(w))
    T.eq("the device is off", K.device(w).on, false)
    w.restore()
  end)
end
T.finish()
