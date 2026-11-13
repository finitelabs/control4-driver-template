-- The light library's behavior over MemoryLight behind the fake proxy: the buttons and their 250 ms
-- gate, the Button Links and their LEDs, scenes, and what the profile offers. The template's own test:
-- no driver repo gets it.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local K = require("behavior_kit")
local M = require("memory_light")
local F = require("light_proxy_fake")

local function case(fn)
  K.case(T, fn)
end

local near = K.near
local TOP, BOTTOM, TOGGLE = 0, 1, 2
local RELEASE_HOLD, PRESS, RELEASE_CLICK = 0, 1, 2

--- The commands sent since the mark that change the level, pre-ons and stops left out.
--- @param w MemoryWorld
--- @return LightCommand[]
local function changes(w)
  local out = {}
  for _, c in ipairs(w.m.sent) do
    if c.kind == "change" and c.setsLevel then
      out[#out + 1] = c
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- The buttons and the 250 ms gate
--------------------------------------------------------------------------------

T.section("the gate: a press and its release inside 250 ms is a click: only its level, over the click rate")
case(function()
  local w = K.world(K.ES, {}, 30)
  w.proxy:send("SET_CLICK_RATE_UP", { RATE = 600 })
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 90 })
  K.button(w, TOP, PRESS)
  T.eq("the press sends nothing yet", #w.m.sent, 0)
  w.run(100)
  K.button(w, TOP, RELEASE_CLICK)
  local moved = changes(w)
  T.eq("one change", #moved, 1)
  T.eq(
    "to the on level over the click rate",
    { near((moved[1] or {}).level, 0.9, 0.01), (moved[1] or {}).transitionMs },
    {
      true,
      600,
    }
  )
  w.run(5000)
  T.eq("lands", w.proxy.level, 90)
  w.restore()
end)

T.section("a click goes over the default click rate when the setup's click rates are 0")
for _, button in ipairs({ BOTTOM, TOGGLE }) do
  K.case(T, function()
    local w = K.world(K.ZB, { setup = F.setupFile("setup-607.xml") }, 80)
    K.button(w, button, PRESS)
    w.run(100)
    K.button(w, button, RELEASE_CLICK)
    local moved = changes(w)
    T.eq("one change, to off over 750 ms", { #moved, (moved[1] or {}).on, (moved[1] or {}).transitionMs }, {
      1,
      false,
      750,
    })
    local changing = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")
    T.eq("the proxy is told the fade to off", { #changing, (changing[1] or {}).RATE }, { 1, 750 })
    w.run(5000)
    T.eq("it lands off", w.proxy.level, 0)
    w.restore()
  end)
end

T.section("the gate: a hold starts 250 ms after the press, toward full, until released")
case(function()
  local w = K.world(K.ES, {}, 30)
  w.proxy:send("SET_HOLD_RATE_UP", { RATE = 4000 })
  K.button(w, TOP, PRESS)
  w.run(200)
  T.eq("nothing before 250 ms", #w.m.sent, 0)
  w.run(100)
  local moved = changes(w)
  T.eq("then the ramp toward full", #moved, 1)
  T.check("to full", near((moved[1] or {}).level, 1, 0.01), moved[1])
  T.eq("told CHANGING to 100", (w.proxy:last("LIGHT_BRIGHTNESS_CHANGING") or {}).LIGHT_BRIGHTNESS_TARGET, 100)
  w.run(1000)
  K.button(w, TOP, RELEASE_HOLD)
  T.eq("the release stops it", #w.m:sentOf("stop"), 1)
  w.run(5000)
  local held = w.proxy.level
  T.check("part way", held > 30 and held < 100, held)
  w.restore()
end)

T.section("the proxy is told BUTTON_ACTION after the light's CHANGING")
case(function()
  local w = K.world(K.ES, {}, 30)
  K.button(w, TOP, PRESS)
  w.run(100)
  K.button(w, TOP, RELEASE_CLICK)
  local said = w.proxy:said()
  local changing, action
  for i, cmd in ipairs(said) do
    if cmd == "LIGHT_BRIGHTNESS_CHANGING" and not changing then
      changing = i
    elseif cmd == "BUTTON_ACTION" then
      action = i
    end
  end
  T.check("BUTTON_ACTION told", action ~= nil, said)
  T.check("after the CHANGING", action ~= nil and (changing == nil or action > changing), said)
  w.run(5000)
  w.restore()
end)

T.section("a hold's time is scaled by the distance left")
case(function()
  local w = K.world(K.ES, {}, 50)
  w.proxy:send("SET_HOLD_RATE_UP", { RATE = 3000 })
  K.button(w, TOP, PRESS)
  w.run(300)
  local ms = (changes(w)[1] or {}).transitionMs
  T.check("half the way, half the hold rate", ms ~= nil and math.abs(ms - 1500) <= 100, ms)
  K.button(w, TOP, RELEASE_HOLD)
  w.run(5000)
  w.restore()
end)

T.section("a Toggle hold alternates its direction")
case(function()
  local w = K.world(K.ES, {}, 50)
  K.button(w, TOGGLE, PRESS)
  w.run(300)
  local first = w.m.sent[#w.m.sent] or {}
  K.button(w, TOGGLE, RELEASE_HOLD)
  w.run(3000)
  w.m.sent = {}
  K.button(w, TOGGLE, PRESS)
  w.run(300)
  local second = w.m.sent[#w.m.sent] or {}
  K.button(w, TOGGLE, RELEASE_HOLD)
  w.run(3000)
  T.check("the first, from on, goes down", first.on == false, first)
  T.check("the second goes up", second.on == true and near(second.level, 1, 0.01), second)
  w.restore()
end)

T.section("a Toggle click turns a lit light off, and an off one on")
case(function()
  local w = K.world(K.ES, {}, 60)
  K.button(w, TOGGLE, PRESS)
  w.run(50)
  K.button(w, TOGGLE, RELEASE_CLICK)
  w.run(5000)
  T.eq("off", w.proxy.level, 0)
  K.button(w, TOGGLE, PRESS)
  w.run(50)
  K.button(w, TOGGLE, RELEASE_CLICK)
  w.run(5000)
  T.check("on", w.proxy.level > 0, w.proxy.level)
  w.restore()
end)

--------------------------------------------------------------------------------
-- The Button Links
--------------------------------------------------------------------------------

T.section("the links: DO_PUSH and DO_CLICK on a link act as its button does")
case(function()
  local w = K.world(K.ES, {}, 0)
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 80 })
  w.proxy:link(M.LINKS.toggle, "DO_PUSH")
  w.run(50)
  w.proxy:link(M.LINKS.toggle, "DO_CLICK")
  w.run(5000)
  T.eq("the Toggle link turns it on", w.proxy.level, 80)
  w.proxy:link(M.LINKS.bottom, "DO_PUSH")
  w.run(50)
  w.proxy:link(M.LINKS.bottom, "DO_CLICK")
  w.run(5000)
  T.eq("the Bottom link turns it off", w.proxy.level, 0)
  w.restore()
end)

--- A keypad's tap on a link: DO_PUSH, then DO_CLICK 150 ms later.
--- @param w MemoryWorld
--- @param link integer
local function linkTap(w, link)
  w.proxy:link(link, "DO_PUSH")
  w.run(150)
  w.proxy:link(link, "DO_CLICK")
end

--- A keypad's hold on a link: DO_PUSH, then DO_RELEASE when it lets go.
--- @param w MemoryWorld
--- @param link integer
--- @param ms integer
local function linkHold(w, link, ms)
  w.proxy:link(link, "DO_PUSH")
  w.run(ms)
  w.proxy:link(link, "DO_RELEASE")
end

--- Dim-To-Warm's mix at a level, as a color temperature.
--- @param level number
--- @return number x
--- @return number y
local function mix(level)
  local b = level / 100
  return C4:ColorCCTtoXY(C4:ColorXYtoCCT(K.DIM.x + (K.WARM.x - K.DIM.x) * b, K.DIM.y + (K.WARM.y - K.DIM.y) * b))
end

--- @param w MemoryWorld
--- @param x number
--- @param y number
--- @param tolerance number
--- @return boolean
local function toldNear(w, x, y, tolerance)
  local c = w.proxy.color or {}
  return near(c.x, x, tolerance) and near(c.y, y, tolerance)
end

T.section("link taps under the on modes: Default On in a preset's color, and Dim-To-Warm's mix (dev 2026-11-13, 967)")
case(function()
  local w = K.world(K.ES, {}, 0)
  w.proxy:presetLevel(60)
  w.run(10)
  K.onMode(w, K.ON_PRESET)
  linkTap(w, M.LINKS.top)
  w.run(5000)
  T.eq("the On link from off: Default On's level", w.proxy.level, 60)
  T.check("in the preset's color", toldNear(w, K.ON_PRESET.x, K.ON_PRESET.y, 0.003), w.proxy.color)
  linkTap(w, M.LINKS.toggle)
  w.run(5000)
  T.eq("the Toggle link while lit: off", w.proxy.level, 0)
  K.onMode(w, K.WARM, K.DIM)
  linkTap(w, M.LINKS.toggle)
  w.run(5000)
  T.eq("the Toggle link from off under Dim-To-Warm: Default On's level", w.proxy.level, 60)
  local x, y = mix(60)
  T.check("in the mix for it", toldNear(w, x, y, 0.003), w.proxy.color)
  linkTap(w, M.LINKS.bottom)
  w.run(5000)
  T.eq("the Off link: off", w.proxy.level, 0)
  w.restore()
end)

T.section("a link tap under Previous: the level and the color the light was last on in (dev 2026-11-13, 967)")
case(function()
  local w = K.world(K.ES, {}, 35)
  K.color(w, K.GREEN.x, K.GREEN.y)
  w.run(3000)
  w.proxy:send("OFF")
  w.run(3000)
  K.onMode(w, { id = 10, origin = 1, x = K.GREEN.x, y = K.GREEN.y })
  w.proxy:send("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = 10, BRIGHTNESS_PRESET_LEVEL = 35 })
  linkTap(w, M.LINKS.top)
  w.run(5000)
  T.eq("the level it was last on at", w.proxy.level, 35)
  T.check("in the color it was last on in", toldNear(w, K.GREEN.x, K.GREEN.y, 0.01), w.proxy.color)
  w.restore()
end)

T.section("a link hold on a lit light under Dim-To-Warm stops in the mix for its level (dev 2026-11-13, 967)")
case(function()
  local w = K.world(K.ES, {}, 0)
  w.proxy:send("SET_HOLD_RATE_UP", { RATE = 5000 })
  w.proxy:send("SET_HOLD_RATE_DOWN", { RATE = 5000 })
  K.onMode(w, K.WARM, K.DIM)
  w.proxy:presetLevel(60)
  w.run(10)
  linkTap(w, M.LINKS.top)
  w.run(5000)
  linkHold(w, M.LINKS.bottom, 800)
  w.run(3000)
  local down = w.proxy.level
  T.check("the Off link's hold stops part way down", down > 0 and down < 60, down)
  local x, y = mix(down)
  T.check("in the mix for that level", toldNear(w, x, y, 0.005), w.proxy.color)
  linkHold(w, M.LINKS.top, 1500)
  w.run(3000)
  local up = w.proxy.level
  T.check("the On link's hold stops part way up", up > down + 15 and up < 100, up)
  x, y = mix(up)
  T.check("in the mix for that level", toldNear(w, x, y, 0.005), w.proxy.color)
  w.restore()
end)

T.section("the link LEDs: told once per change, every link showing the light's own state")
case(function()
  local w = K.world(K.ES, {}, 0)
  w.proxy:send("ON")
  w.run(5000)
  T.eq(
    "lit: every link lit",
    { w.proxy.leds[M.LINKS.top], w.proxy.leds[M.LINKS.toggle], w.proxy.leds[M.LINKS.bottom] },
    { true, true, true }
  )
  local function ledNotes()
    local n = 0
    for _, note in ipairs(w.proxy.notes) do
      if note.cmd == "MATCH_LED_STATE" then
        n = n + 1
      end
    end
    return n
  end
  w.proxy:mark()
  w.proxy:send("SET_LEVEL", { LEVEL = 40 })
  w.run(5000)
  T.eq("a level while lit tells no LED", ledNotes(), 0)
  w.proxy:send("OFF")
  w.run(5000)
  T.eq(
    "off: every link dark",
    { w.proxy.leds[M.LINKS.top], w.proxy.leds[M.LINKS.toggle], w.proxy.leds[M.LINKS.bottom] },
    { false, false, false }
  )
  w.restore()
end)

T.section("a light with no links takes no link command and tells no LED")
case(function()
  -- RFP is global: put back what an earlier case's light set on the link bindings, as a fresh load has.
  RFP[M.LINKS.top], RFP[M.LINKS.toggle], RFP[M.LINKS.bottom] = nil, nil, nil
  local w = K.world(K.ES, { links = false }, 0)
  T.check("no handler on the link bindings", type(RFP[M.LINKS.top]) ~= "function")
  w.proxy:send("ON")
  w.run(5000)
  local leds = 0
  for _, note in ipairs(w.proxy.notes) do
    if note.cmd == "MATCH_LED_STATE" then
      leds = leds + 1
    end
  end
  T.eq("no LED told", leds, 0)
  w.restore()
end)

T.section("button colors are stored and told back, and Request Button Colors answers each button")
case(function()
  local w = K.world(K.ES, {}, 50)
  w.proxy:send("SET_BUTTON_COLOR", { BUTTON_ID = 1, ON_COLOR = "ff0000", OFF_COLOR = "00ff00" })
  w.proxy:mark()
  w.proxy:send("REQUEST_BUTTON_COLORS")
  local colors = w.proxy:told("BUTTON_COLORS")
  T.eq("each button answered", #colors, 3)
  local bottom
  for _, c in ipairs(colors) do
    if tonumber(c.BUTTON_ID) == 1 then
      bottom = c
    end
  end
  T.eq("with the colors stored", bottom and { bottom.ON_COLOR, bottom.OFF_COLOR }, { "ff0000", "00ff00" })
  w.restore()
end)

--------------------------------------------------------------------------------
-- Scenes
--------------------------------------------------------------------------------

T.section("a scene runs its steps, each over its rate; a level command takes the light out of it")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.scene(w, 1, { { level = 60, rate = 3000 }, { level = 20, rate = 0, delay = 5000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  local first = w.proxy:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
  T.eq("the first step over its rate", { first.LIGHT_BRIGHTNESS_TARGET, first.RATE }, { 60, 3000 })
  w.run(4000)
  T.eq("told once", w.proxy:count("LIGHT_BRIGHTNESS_CHANGING"), 1)
  T.eq("lands", w.proxy.level, 60)
  w.run(5000)
  T.eq("the second after the first's rate and its own delay", w.proxy.level, 20)
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(4000)
  w.proxy:send("SET_LEVEL", { LEVEL = 90 })
  local sent = #w.m.sent
  w.run(10000)
  T.eq("after a level command no step goes", #w.m.sent, sent)
  T.eq("the level stands", w.proxy.level, 90)
  w.restore()
end)

T.section("a flash scene runs its steps once; Deactivate stops a scene")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.scene(w, 2, { { level = 100 }, { level = 0 } }, true)
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 2 })
  w.run(10)
  T.eq("with nothing to wait on, each step once", w.m:sentLevels(), { 100, 0 })
  w.run(5000)
  T.eq("and no more", w.m:sentLevels(), { 100, 0 })
  K.scene(w, 3, { { level = 60, rate = 0 }, { level = 20, rate = 0, delay = 2000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 3 })
  w.run(500)
  w.proxy:send("DEACTIVATE_SCENE", { SCENE_ID = 3 })
  local sent = #w.m.sent
  w.run(5000)
  T.eq("after Deactivate no step goes", #w.m.sent, sent)
  w.restore()
end)

T.section("another client's level ends a scene's steps only where it ends a running ramp")
case(function()
  local w = K.world(K.ES, {}, 0)
  K.scene(w, 1, { { level = 60, rate = 3000 }, { level = 20, rate = 0, delay = 5000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(1500)
  w.m:other({ on = true, level = 0.9 })
  local sent = #w.m.sent
  w.run(8000)
  T.eq("a level during the step's ramp: no step after it", #w.m.sent, sent)
  T.eq("the proxy shows that level", w.proxy.level, 90)
  w.restore()
end)
case(function()
  local w = K.world(K.ES, {}, 0)
  K.scene(w, 1, { { level = 60, rate = 3000 }, { level = 20, rate = 0, delay = 5000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(4000)
  w.m:other({ on = true, level = 0.9 })
  w.run(5000)
  T.eq("a level between steps: the next step still goes", w.proxy.level, 20)
  w.restore()
end)
case(function()
  local w = K.world(K.ES, {}, 0)
  K.scene(w, 1, { { level = 60, rate = 3000 }, { level = 20, rate = 0, delay = 5000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(4000)
  w.m:other({ color = { x = K.GREEN.x, y = K.GREEN.y, mode = "xy" } })
  w.run(5000)
  T.eq("after a color the next step runs", w.proxy.level, 20)
  w.restore()
end)

T.section("Ramp Scene Up goes to full, whatever the on mode; Stop Scene Ramp holds it")
case(function()
  local w = K.world(K.ES, {}, 30)
  w.proxy:send("SET_PRESET_LEVEL", { LEVEL = 50 })
  K.scene(w, 1, { { level = 40, rate = 0 } })
  w.proxy:send("RAMP_SCENE_UP", { SCENE_ID = 1, RATE = 4000 })
  local moved = changes(w)
  T.check("toward full", near((moved[#moved] or {}).level, 1, 0.01), moved)
  w.run(1000)
  w.proxy:send("STOP_SCENE_RAMP", { SCENE_ID = 1 })
  T.eq("the stop holds it", #w.m:sentOf("stop"), 1)
  w.run(5000)
  local held = w.proxy.level
  T.check("part way", held > 30 and held < 100, held)
  w.restore()
end)

T.section("Stop Scene Ramp stops the steps and leaves a step's own fade running to its end")
case(function()
  local w = K.world(K.ES, {}, 60)
  K.color(w, K.RED.x, K.RED.y)
  w.run(5000)
  K.scene(w, 1, { { color = { x = K.GREEN.x, y = K.GREEN.y }, rate = 4000 }, { level = 20, delay = 6000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(1000)
  w.m.sent = {}
  w.proxy:send("STOP_SCENE_RAMP", { SCENE_ID = 1 })
  T.eq("no stop goes out for a step's fade", #w.m:sentOf("stop"), 0)
  w.run(12000)
  local y = (w.proxy.color or {}).y
  T.check("the proxy shows the step's color", near(y, K.GREEN.y, 0.01), y)
  local device = w.m.device:state(w.clock.now())
  T.check("and the device rests there too", near((device.color or {}).y, K.GREEN.y, 0.01), device)
  T.eq("and no later step runs", w.proxy.level, 60)
  w.restore()
end)

T.section("a Toggle link click with no push, on a light fading to off but still lit, turns it off")
case(function()
  local w = K.world(K.ES, {}, 100)
  K.target(w, 0, 4000)
  w.run(3000)
  w.proxy:link(M.LINKS.toggle, "DO_CLICK")
  w.run(5000)
  T.eq("it ends off", w.proxy.level, 0)
  w.restore()
end)

T.section("a scene step's delay is its own, not the device's fade length")
case(function()
  local w = K.world(K.OWN, {}, 0)
  K.scene(w, 1, { { level = 80, rate = 0 }, { level = 20, rate = 0, delay = 3000 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(2000)
  T.eq("the first step", w.proxy.level, 80)
  w.run(2000)
  T.eq("the second at its delay", w.proxy.level, 20)
  w.restore()
end)

--------------------------------------------------------------------------------
-- The profile
--------------------------------------------------------------------------------

T.section("a family the profile leaves out has no handler: a scene does nothing")
case(function()
  local o = K.copy(K.ES)
  local profile = M.profile(o)
  profile.scenes = false
  o.profile = profile
  local w = K.world(o, {}, 0)
  K.scene(w, 1, { { level = 60, rate = 0 } })
  w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = 1 })
  w.run(3000)
  T.eq("nothing sent", #w.m.sent, 0)
  w.restore()
end)

T.section("a proxy command the library does not handle is the driver's: a command-keyed RFP takes it")
case(function()
  local w = K.world(K.ES, {}, 50)
  local got
  RFP.EXTRA_SET = function(idBinding, strCommand)
    got = { idBinding, strCommand }
  end
  w.proxy:send("EXTRA_SET", { ID = 1, VALUE = "x" })
  T.eq("the driver's handler took it", got, { 5001, "EXTRA_SET" })
  RFP.EXTRA_SET = nil
  local ok, err = pcall(function()
    w.proxy:send("EXTRA_SET", { ID = 1, VALUE = "x" })
  end)
  T.check("without one, the library drops it without raising", ok, err)
  w.restore()
end)

T.section("Light.new: the profile names the contract's API, and the adapter has send, refresh and show")
case(function()
  local Light = require("lib.light")
  local adapter = {
    send = function() end,
    refresh = function() end,
    show = function() end,
  }
  T.raises("a profile with another API", function()
    Light.new(adapter, { api = Light.API + 1, dims = true })
  end)
  T.raises("an adapter without show", function()
    Light.new({ send = adapter.send, refresh = adapter.refresh }, { api = Light.API, dims = true })
  end)
end)

T.finish()
