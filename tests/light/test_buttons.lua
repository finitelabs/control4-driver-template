-- lib.light.buttons alone: what each press, hold and click asks of Motion, and when. A fake Light takes
-- the gate's end as Light:_gateEnded does.

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local Buttons = require("lib.light.buttons")

local TOP, BOTTOM, TOGGLE = Buttons.TOP, Buttons.BOTTOM, Buttons.TOGGLE
local HOLD, PRESS, CLICK = Buttons.RELEASE_HOLD, Buttons.PRESS, Buttons.RELEASE_CLICK

local RATES = { clickUp = 500, clickDown = 400, holdUp = 3000, holdDown = 2000 }

--- The light at a C4 level on a 1-100 range: off at 0.
local function at(level)
  if level <= 0 then
    return { on = false, level = 0.5, levelRamping = false, colorRamping = false }
  end
  return { on = true, level = (1 + (level - 1) * 99 / 99) / 100, levelRamping = false, colorRamping = false }
end

--- Buttons over a fake Light and settings on a virtual clock. `w.got` holds the intents, with their times.
local function world(lo, hi)
  local w = { clock = F.virtualClock(), got = {}, now = at(0) }
  local settings = {}
  function settings:onRange()
    return lo or 1, hi or 100
  end
  function settings:clickRate(up)
    return up and RATES.clickUp or RATES.clickDown
  end
  function settings:holdRate(up)
    return up and RATES.holdUp or RATES.holdDown
  end
  local light = {}
  function light:_gateEnded()
    local intent = w.buttons:gateEnded(w.now)
    if intent then
      w.got[#w.got + 1] = { at = w.clock.now() - w.start, intent = intent }
    end
  end
  w.buttons = Buttons.new(light, settings)
  w.start = w.clock.now()
  function w.act(button, action)
    local intent = w.buttons:action(button, action, w.now)
    if intent then
      w.got[#w.got + 1] = { at = w.clock.now() - w.start, intent = intent }
    end
    return intent
  end
  return w
end

T.section("a click inside the gate sends only its own command, and no hold starts")
do
  local cases = {
    { "Top from off", TOP, 0, { kind = "on", rateMs = RATES.clickUp, source = "button" } },
    { "Top while on", TOP, 40, { kind = "on", rateMs = RATES.clickUp, source = "button" } },
    { "Bottom while on", BOTTOM, 40, { kind = "off", rateMs = RATES.clickDown, source = "button" } },
    { "Toggle while on", TOGGLE, 40, { kind = "off", rateMs = RATES.clickDown, source = "button" } },
    { "Toggle from off", TOGGLE, 0, { kind = "on", rateMs = RATES.clickUp, source = "button" } },
  }
  for _, case in ipairs(cases) do
    local w = world()
    w.now = at(case[3])
    T.eq(case[1] .. ": the press asks nothing", w.act(case[2], PRESS), nil)
    w.clock.run(110)
    T.eq(case[1] .. ": the click", w.act(case[2], CLICK), case[4])
    w.clock.run(5000)
    T.eq(case[1] .. ": and only the click", #w.got, 1)
    w.clock.restore()
  end
end

T.section("a hold starts 250 ms after its press, over the hold rate scaled by the distance left")
do
  local cases = {
    { "Top from off", TOP, 0, { kind = "level", level = 100, rateMs = 3000, source = "button" } },
    { "Top from 40", TOP, 40, { kind = "level", level = 100, rateMs = 1800, source = "button" } },
    { "Top at full", TOP, 100, { kind = "level", level = 100, rateMs = 0, source = "button" } },
    { "Bottom from 100", BOTTOM, 100, { kind = "level", level = 0, rateMs = 2000, source = "button" } },
    { "Bottom from 25", BOTTOM, 25, { kind = "level", level = 0, rateMs = 500, source = "button" } },
  }
  for _, case in ipairs(cases) do
    local w = world()
    w.now = at(case[3])
    w.act(case[2], PRESS)
    w.clock.run(249)
    T.eq(case[1] .. ": nothing before 250 ms", #w.got, 0)
    w.clock.run(1)
    T.eq(case[1] .. ": the hold at 250 ms", w.got[1] and { w.got[1].at, w.got[1].intent }, { 250, case[4] })
    w.clock.restore()
  end
end

T.section("a release after a hold stops the level; one inside the gate stops nothing")
do
  local w = world()
  w.now = at(50)
  w.act(TOP, PRESS)
  w.clock.run(1000)
  T.eq("the release stops the hold", w.act(TOP, HOLD), { kind = "stopLevel", source = "button" })
  w.clock.restore()

  w = world()
  w.now = at(50)
  w.act(TOP, PRESS)
  w.clock.run(200)
  T.eq("a release inside the gate", w.act(TOP, HOLD), nil)
  w.clock.run(1000)
  T.eq("and no hold starts after it", #w.got, 0)
  w.clock.restore()

  w = world()
  T.eq("a release with no press", w.act(TOP, HOLD), nil)
  w.clock.restore()
end

T.section("a click after the gate decides from the level its press found")
do
  local w = world()
  w.now = at(40)
  w.act(TOGGLE, PRESS)
  w.clock.run(300)
  T.eq("the Toggle hold went down", w.got[1].intent.level, 0)
  w.now = at(35)
  T.eq("a late click still turns the light off, from 40", w.act(TOGGLE, CLICK).kind, "off")
  w.clock.restore()

  w = world()
  w.now = at(0)
  w.act(TOGGLE, PRESS)
  w.clock.run(300)
  w.now = at(3)
  T.eq("and from off a late click turns it on, though the hold lit it", w.act(TOGGLE, CLICK).kind, "on")
  w.clock.restore()
end

T.section("another source's command leaves the gate, as the button is still down, but takes the hold's ramp")
do
  local w = world()
  w.now = at(50)
  w.act(TOP, PRESS)
  w.clock.run(100)
  w.buttons:cancel()
  w.clock.run(150)
  T.eq("the hold still starts at 250 ms", #w.got, 1)
  w.buttons:cancel()
  T.eq("but after a command takes the ramp, its release stops nothing", w.act(TOP, HOLD), nil)
  w.clock.restore()
end

T.section("a second press ends the first press's gate")
do
  local w = world()
  w.now = at(50)
  w.act(TOP, PRESS)
  w.clock.run(100)
  w.act(BOTTOM, PRESS)
  w.clock.run(249)
  T.eq("nothing from the first", #w.got, 0)
  w.clock.run(1)
  T.eq("the second's hold, 250 ms after it", { w.got[1].at, w.got[1].intent.level }, { 350, 0 })
  w.clock.restore()
end

T.section("a Toggle hold alternates: after a hold down the next goes up; at full it goes down, at off up")
do
  local w = world()
  local function hold(level)
    w.now = at(level)
    w.got = {}
    w.act(TOGGLE, PRESS)
    w.clock.run(300)
    w.act(TOGGLE, HOLD)
    return w.got[1].intent.level
  end
  T.eq("the first from a lit light goes down", hold(60), 0)
  T.eq("the next goes up", hold(30), 100)
  T.eq("then down", hold(70), 0)
  T.eq("at full it goes down", hold(100), 0)
  T.eq("so the next goes up", hold(50), 100)
  T.eq("at off it goes up", hold(0), 100)
  T.eq("so the next goes down", hold(50), 0)
  w.buttons:reset()
  T.eq("after a reset, a lit light goes down again", hold(50), 0)
  w.act(BOTTOM, PRESS)
  w.clock.run(300)
  w.act(BOTTOM, HOLD)
  T.eq("a Bottom hold between leaves the Toggle's turn", hold(50), 100)
  w.clock.restore()
end

T.section("the level a press finds follows the Min and Max On line")
do
  local w = world(20, 60)
  w.now = { on = true, level = 0.4, levelRamping = false, colorRamping = false }
  w.act(TOP, PRESS)
  w.clock.run(250)
  T.eq("0.4 on a 20-60 line is level 51: the hold up crosses 49 of 100", w.got[1].intent.rateMs, 1470)
  w.clock.restore()
end

T.section("an unknown button or action asks nothing")
do
  local w = world()
  T.eq("button 7", w.act(7, PRESS), nil)
  T.eq("action 9", w.act(TOP, 9), nil)
  w.clock.run(1000)
  T.eq("and no gate ran", #w.got, 0)
  w.clock.restore()
end

T.section("the Button Links map to the buttons")
do
  local links = { top = 300, toggle = 301, bottom = 302 }
  T.eq("top", Buttons.forLink(links, 300), TOP)
  T.eq("toggle", Buttons.forLink(links, 301), TOGGLE)
  T.eq("bottom", Buttons.forLink(links, 302), BOTTOM)
  T.eq("another binding", Buttons.forLink(links, 5001), nil)
  T.eq("no links", Buttons.forLink(nil, 300), nil)
end

T.finish()
