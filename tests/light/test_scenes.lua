-- lib.light.scenes alone: what each scene command and each step asks of Motion, and when the steps run.
-- A fake Light takes each step's intent as Light:_sceneStep does.

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local persist = require("lib.persist")
local Scenes = require("lib.light.scenes")

--- A scene's steps, as the proxy pushes them.
local function elements(steps)
  local xml = {}
  for _, s in ipairs(steps) do
    local parts = { "<element><delay>" .. (s.delay or 0) .. "</delay>" }
    if s.level then
      parts[#parts + 1] = "<brightnessEnabled>True</brightnessEnabled><brightness>" .. s.level .. "</brightness>"
      parts[#parts + 1] = "<brightnessRate>" .. (s.rate or 0) .. "</brightnessRate>"
    end
    if s.color then
      parts[#parts + 1] = "<colorEnabled>True</colorEnabled><colorX>" .. s.color.x .. "</colorX><colorY>" .. s.color.y
      parts[#parts + 1] = "</colorY><colorMode>" .. (s.color.mode or 0) .. "</colorMode>"
      parts[#parts + 1] = "<colorRate>" .. (s.colorRate or s.rate or 0) .. "</colorRate>"
    end
    parts[#parts + 1] = "</element>"
    xml[#xml + 1] = table.concat(parts)
  end
  return table.concat(xml)
end

local NOW = { on = true, level = 0.5, levelRamping = false, colorRamping = false }

--- Scenes over a fake Light on a virtual clock. `w.got` holds every intent a step gave, with its time.
local function world(profile)
  persist:set("scenes", {})
  local w = { clock = F.virtualClock(), got = {} }
  local light = {}
  function light:_sceneStep(id)
    local intent = w.scenes:step(id, NOW)
    if intent then
      w.got[#w.got + 1] = { at = w.clock.now() - w.start, intent = intent }
    end
  end
  w.scenes = Scenes.new(light, profile or { flash = true })
  w.start = w.clock.now()
  function w.push(id, steps, extra)
    local tParams = { SCENE_ID = tostring(id), ELEMENTS = elements(steps), FLASH = "False" }
    for k, v in pairs(extra or {}) do
      tParams[k] = v
    end
    return w.scenes:push(tParams, NOW)
  end
  function w.activate(id)
    local intent = w.scenes:activate({ SCENE_ID = tostring(id) }, NOW)
    if intent then
      w.got[#w.got + 1] = { at = w.clock.now() - w.start, intent = intent }
    end
    return intent
  end
  --- The levels the steps gave, in order.
  function w.levels()
    local levels = {}
    for _, g in ipairs(w.got) do
      levels[#levels + 1] = g.intent.level or "-"
    end
    return levels
  end
  return w
end

T.section("a step is one intent, of the step's level, color or both, at its own rate")
do
  local w = world()
  w.push(1, {
    { level = 60, rate = 3000 },
    { level = 40, rate = 1000, color = { x = 0.6, y = 0.3 } },
    { color = { x = 0.45, y = 0.41, mode = 1 }, rate = 500 },
  })
  T.eq("activate gives the first step at once", w.activate(1), {
    kind = "level",
    level = 60,
    rateMs = 3000,
    source = "scene",
  })
  w.clock.run(3000)
  T.eq("a level and a color go as one level intent with its color", w.got[2].intent, {
    kind = "level",
    level = 40,
    color = { x = 0.6, y = 0.3, mode = "xy" },
    rateMs = 1000,
    source = "scene",
  })
  w.clock.run(1000)
  T.eq("a color alone is a color intent, color mode 1 a color temperature", w.got[3].intent, {
    kind = "color",
    color = { x = 0.45, y = 0.41, mode = "cct" },
    rateMs = 500,
    source = "scene",
  })
  T.eq("each step went when the step before it had run its own rate", { w.got[2].at, w.got[3].at }, { 3000, 4000 })
  w.clock.run(10000)
  T.eq("and the run ends after the last", #w.got, 3)
  w.clock.restore()
end

T.section("a step waits its delay; the longer of its two rates times the next")
do
  local w = world()
  w.push(1, {
    { level = 60, rate = 1000, color = { x = 0.3, y = 0.3 }, colorRate = 2500 },
    { level = 20, rate = 0, delay = 5000 },
    { delay = 700 },
    { level = 80 },
  })
  T.eq("the step's rate is the longer of the two", w.activate(1).rateMs, 2500)
  w.clock.run(7499)
  T.eq("the second waits out its delay after the first's rate", #w.got, 1)
  w.clock.run(1)
  T.eq("and goes at 7500", w.got[2].at, 7500)
  w.clock.run(700)
  T.eq("a step that only waits gives no intent, and the next waits on it", #w.got, 2)
  w.clock.run(2)
  -- Each step with no rate hands on after 1 ms, the shortest timer Director takes.
  T.eq("then the next goes", { w.got[3] and w.got[3].at, w.got[3] and w.got[3].intent.level }, { 8202, 80 })
  w.clock.restore()
end

T.section("steps with no delay and no rate each go, in order, 1 ms apart: the shortest timer Director takes")
do
  local w = world()
  w.push(1, { { level = 10 }, { level = 20 }, { level = 30 } })
  w.activate(1)
  w.clock.run(2)
  T.eq("every step gave its own intent", w.levels(), { 10, 20, 30 })
  T.eq("each a ms after the one before", { w.got[2] and w.got[2].at, w.got[3] and w.got[3].at }, { 1, 2 })
  w.clock.run(10000)
  T.eq("and nothing more", #w.got, 3)
  w.clock.restore()
end

T.section("a stop, another hand's level and a new scene end the run; another hand's color does not")
do
  local cases = {
    {
      name = "stopSteps",
      act = function(w)
        w.scenes:stopSteps()
      end,
      steps = 1,
    },
    {
      name = "another hand's level",
      act = function(w)
        w.scenes:foreign({ "level" })
      end,
      steps = 1,
    },
    {
      name = "another hand's on",
      act = function(w)
        w.scenes:foreign({ "on" })
      end,
      steps = 1,
    },
    {
      name = "another hand's color",
      act = function(w)
        w.scenes:foreign({ "color" })
      end,
      steps = 2,
    },
    {
      name = "reset",
      act = function(w)
        w.scenes:reset()
      end,
      steps = 1,
    },
    {
      name = "deactivate",
      act = function(w)
        w.scenes:deactivate({ SCENE_ID = "1" }, NOW)
      end,
      steps = 1,
    },
    {
      name = "removing the running scene",
      act = function(w)
        w.scenes:remove({ SCENE_ID = "1" }, NOW)
      end,
      steps = 1,
    },
    {
      name = "clearing every scene",
      act = function(w)
        w.scenes:clear({}, NOW)
      end,
      steps = 1,
    },
    {
      name = "storing the running scene again",
      act = function(w)
        w.push(1, { { level = 5 } })
      end,
      steps = 1,
    },
  }
  for _, case in ipairs(cases) do
    local w = world()
    w.push(1, { { level = 60, rate = 3000 }, { level = 20, delay = 5000 } })
    w.activate(1)
    w.clock.run(4000)
    case.act(w)
    w.clock.run(20000)
    T.eq(case.name, #w.got, case.steps)
    w.clock.restore()
  end
end

T.section("activating a scene ends the one running")
do
  local w = world()
  w.push(1, { { level = 60, rate = 3000 }, { level = 20, delay = 5000 } })
  w.push(2, { { level = 90, rate = 1000 }, { level = 30, delay = 1000 } })
  w.activate(1)
  w.clock.run(500)
  w.activate(2)
  w.clock.run(20000)
  T.eq("only scene 2's steps follow", w.levels(), { 60, 90, 30 })
  w.clock.restore()
end

T.section("a timer from a stopped run takes nothing, even one already due")
do
  local w = world()
  w.push(1, { { level = 60 }, { level = 20 } })
  local calls = 0
  local light = {}
  function light:_sceneStep()
    calls = calls + 1
  end
  w.scenes.light = light
  w.activate(1)
  w.scenes:stopSteps()
  w.clock.run(1000)
  T.eq("the 0 ms timer the first step armed called nothing", calls, 0)
  w.clock.restore()
end

T.section("a flash scene starts over, but one whose pass takes no time plays once")
do
  local w = world()
  w.push(1, { { level = 100, rate = 500 }, { level = 0, rate = 500 } }, { FLASH = "True" })
  w.activate(1)
  w.clock.run(2999)
  T.eq("a flash that waits keeps going", w.levels(), { 100, 0, 100, 0, 100, 0 })
  w.scenes:stopSteps()
  w.clock.restore()

  w = world()
  w.push(1, { { level = 100 }, { level = 0 } }, { FLASH = "True" })
  w.activate(1)
  w.clock.run(10000)
  T.eq("a flash with no delay or rate plays one pass", w.levels(), { 100, 0 })
  w.clock.restore()

  w = world({ flash = false })
  w.push(1, { { level = 100, rate = 500 }, { level = 0, rate = 500 } }, { FLASH = "True" })
  w.activate(1)
  w.clock.run(10000)
  T.eq("a profile without flash plays a flash scene once", w.levels(), { 100, 0 })
  w.clock.restore()
end

T.section("scene ramps: up heads for full, down for off, at the command's rate; a stop stops the level")
do
  local w = world()
  w.push(1, { { level = 60, rate = 3000 }, { level = 20, delay = 5000 } })
  w.push(2, { { level = 60 } }, { IGNORE_RAMP = "True" })
  local cases = {
    {
      "rampUp",
      { SCENE_ID = "1", RATE = "4000" },
      { kind = "level", level = 100, rateMs = 4000, source = "scene", ramp = true },
    },
    {
      "rampDown",
      { SCENE_ID = "1", RATE = "2000" },
      { kind = "level", level = 0, rateMs = 2000, source = "scene", ramp = true },
    },
    { "rampUp", { RATE = "1000" }, { kind = "level", level = 100, rateMs = 1000, source = "scene", ramp = true } },
    { "stopRamp", { SCENE_ID = "1" }, { kind = "stop", source = "scene" } },
    { "rampUp", { SCENE_ID = "2", RATE = "1000" }, nil },
    { "rampDown", { SCENE_ID = "2", RATE = "1000" }, nil },
    { "stopRamp", { SCENE_ID = "2" }, nil },
  }
  for _, case in ipairs(cases) do
    T.eq(case[1] .. " " .. tostring(case[2].SCENE_ID), w.scenes[case[1]](w.scenes, case[2], NOW), case[3])
  end
  T.eq("a stop with no scene ramp running sends no stop", w.scenes:stopRamp({ SCENE_ID = "1" }, NOW), nil)
  w.scenes:rampUp({ SCENE_ID = "1", RATE = "1000" }, NOW)
  w.scenes:foreign({ "level" })
  T.eq("nor after another source took the ramp", w.scenes:stopRamp({ SCENE_ID = "1" }, NOW), nil)
  w.scenes:rampUp({ SCENE_ID = "1", RATE = "1000" }, NOW)
  T.eq("a scene that ignores ramps still has its ramp stopped", w.scenes:stopRamp({ SCENE_ID = "2" }, NOW), {
    kind = "stop",
    source = "scene",
  })
  w.activate(1)
  w.scenes:rampUp({ SCENE_ID = "1", RATE = "1000" }, NOW)
  w.clock.run(20000)
  T.eq("a ramp ends the run", #w.got, 1)
  w.clock.restore()
end

T.section("a scene ramp carries the color of the scene's last element")
do
  local w = world()
  w.push(
    3,
    { { level = 60, color = { x = 0.6, y = 0.32 } }, { level = 20, color = { x = 0.15, y = 0.06 }, delay = 2000 } }
  )
  local up = w.scenes:rampUp({ SCENE_ID = "3", RATE = "3000" }, NOW)
  T.eq(
    "the last element's color, with the ramp to full",
    { up.level, up.color and up.color.x, up.ramp },
    { 100, 0.15, true }
  )
  w.push(4, { { level = 60, color = { x = 0.6, y = 0.32 } }, { level = 20 } })
  T.eq("none when the last element sets no color", w.scenes:rampDown({ SCENE_ID = "4", RATE = "3000" }, NOW).color, nil)
  w.clock.restore()
end

T.section("TOGGLE_SCENE activates; an unknown or missing id does nothing")
do
  local w = world()
  w.push(1, { { level = 60 } })
  T.eq("toggle", w.scenes:toggle({ SCENE_ID = "1" }, NOW).level, 60)
  T.eq("an unknown scene", w.scenes:activate({ SCENE_ID = "9" }, NOW), nil)
  T.eq("no id", w.scenes:activate({}, NOW), nil)
  T.eq("a push with no id stores nothing", w.scenes:push({ ELEMENTS = elements({ { level = 1 } }) }, NOW), nil)
  T.eq("so the store holds scene 1 alone", persist:get("scenes")["9"], nil)
  w.clock.restore()
end

T.section("the store keeps the shape every release stored")
do
  local w = world()
  w.push(4, { { level = 40, rate = 1000, delay = 200 }, { color = { x = 0.5, y = 0.4 }, rate = 300 } }, {
    FLASH = "True",
    IGNORE_RAMP = "False",
    FROM_GROUP = "True",
  })
  T.eq("scene 4 as stored", persist:get("scenes")["4"], {
    elements = {
      {
        delay = 200,
        brightnessRate = 1000,
        colorRate = 1000,
        level = 40,
        levelEnabled = true,
        colorEnabled = false,
      },
      {
        delay = 0,
        brightnessRate = 0,
        colorRate = 300,
        levelEnabled = false,
        colorEnabled = true,
        colorX = 0.5,
        colorY = 0.4,
        colorMode = 0,
      },
    },
    flash = true,
    ignoreRamp = false,
    fromGroup = true,
    state = 0,
  })
  w.scenes:push({ SCENE_ID = "5", ELEMENTS = "<element><level>30</level></element><element></element>" }, NOW)
  T.eq(
    "an older schema's bare level is a level step, and an empty step is dropped",
    persist:get("scenes")["5"].elements,
    {
      { delay = 0, brightnessRate = 0, colorRate = 0, level = 30, levelEnabled = true, colorEnabled = false },
    }
  )
  w.clock.restore()
end

T.finish()
