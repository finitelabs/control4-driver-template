-- The light library under seeded random runs: proxy commands, link presses, scenes, settings, another
-- hand's changes and a slow, late, lossy or silent transport, over MemoryLight in every device the
-- contract's facts make (types.lua). Each run is judged by the invariants below once it is at rest.
--
-- The template's own test: no driver repo gets it. Against a render with the light token:
--   "$R/test/run_test.sh" "$PWD/tests/light/fuzz.lua"
-- LIGHT_FUZZ_RUNS sets the count (20,000 by default), LIGHT_FUZZ_SEED the first seed (1). A failure prints
-- its seed and a replay line; LIGHT_FUZZ_TRACE=1 prints each step of the runs, and LIGHT_FUZZ_TIMELINE=1
-- each run's commands, reports, notifies and deadlines in time order.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local K = require("behavior_kit")
local M = require("memory_light")
local Fake = require("light_proxy_fake")
local Range = require("lib.light.range")
local log = require("lib.logging")

local RUNS = tonumber(os.getenv("LIGHT_FUZZ_RUNS")) or 20000
local SEED = tonumber(os.getenv("LIGHT_FUZZ_SEED")) or 1
local TRACE = os.getenv("LIGHT_FUZZ_TRACE") == "1"
local SHOW = tonumber(os.getenv("LIGHT_FUZZ_SHOW")) or 3

local SETUPS = { "setup-607.xml", "setup-626.xml", "setup-643.xml", "setup-727.xml", "setup-732.xml" }
local GAPS = { 0, 0, 5, 18, 60, 110, 300, 700, 1200, 2500, 6000 }
local RATES = { 0, 0, 250, 750, 2000, 5000 }
-- The longest change a run asks: a rate, a hold, a scene step or an own length.
local LONGEST = 5000
-- Long enough after the last action for every fade, wait, ask and answer to have run out.
local QUIET = 30000

--- @class FuzzInvariant
--- @field name string
--- @field says string

--- @type FuzzInvariant[]
local INVARIANTS = {
  { name = "rest", says = "at rest the proxy shows the device's on, level and color, and the light online" },
  { name = "latest", says = "the last level asked is where the light ends, with nothing after it" },
  { name = "told", says = "no level is told CHANGED that no command spanned and the device never reached" },
  {
    name = "ramps",
    says = "a CHANGING starts where the proxy last saw the light, and a ramp run out ends at its target",
  },
  { name = "once", says = "one CHANGING per ramp per aspect (review P5)" },
  {
    name = "binds",
    says = "while lost the proxy hears only offline, at most one off and dark LEDs, and nothing is sent",
  },
  { name = "commands", says = "every command keeps to the contract's shape for its device" },
  { name = "sends", says = "a walk sends at most one step per stepMs, plus two" },
  { name = "asks", says = "the library asks a refresh only of a device that offers it, at most once per window" },
  { name = "quiet", says = "a level command the device takes plainly tells at most one CHANGED per aspect" },
  { name = "window", says = "no deadline falls before its aspect's ramp has ended" },
  { name = "malformed", says = "a malformed report changes nothing and logs one error (review T9)" },
  { name = "errors", says = "no error escapes: no raise, no timer callback raise, no logged error" },
}

--------------------------------------------------------------------------------
-- A seeded draw of its own, so nothing else that calls math.random moves a run
--------------------------------------------------------------------------------

--- @class FuzzRandom
--- @field float fun(): number
--- @field int fun(a: integer, b: integer): integer
--- @field pick fun(t: any[]): any
--- @field chance fun(p: number): boolean

--- @param seed integer
--- @return FuzzRandom
local function rng(seed)
  -- Spread consecutive seeds apart, then let the first draws go: a small seed's first draws are near 0.
  local x = (seed * 7919 + 104729) % 2147483646 + 1
  local r = {}
  function r.float()
    x = x * 48271 % 2147483647
    return (x - 1) / 2147483646
  end
  function r.int(a, b)
    return a + math.floor(r.float() * (b - a + 1))
  end
  function r.pick(t)
    return t[r.int(1, #t)]
  end
  function r.chance(p)
    return r.float() < p
  end
  for _ = 1, 8 do
    r.float()
  end
  return r
end

--- @param t any
--- @return any
local function copy(t)
  if type(t) ~= "table" then
    return t
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = copy(v)
  end
  return out
end

--------------------------------------------------------------------------------
-- A run's device, transport and profile
--------------------------------------------------------------------------------

--- What a run is, besides the world options MemoryLight takes.
--- @class FuzzDraw
--- @field o MemoryWorldOptions
--- @field kind string
--- @field rest boolean The adapter returns a LightRest.
--- @field inside boolean The adapter reports inside send.
--- @field drops number The chance a frame is lost.
--- @field delays boolean The transport delays some reports.

--- @param r FuzzRandom
--- @return FuzzDraw
local function draw(r)
  local kind = r.pick({ "relay", "dimmer", "white", "color", "full", "color relay" })
  local o = {}
  o.dims = kind ~= "relay" and kind ~= "color relay"
  o.color = kind == "color" or kind == "full" or kind == "color relay"
  if kind == "white" or kind == "full" or (kind == "color relay" and r.chance(0.5)) then
    o.cct = r.pick({ { minK = 2700, maxK = 6500 }, { minK = 2000, maxK = 6500 } })
  end
  o.levelSteps = r.pick({ 100, 254, 255 })
  if o.color or o.cct then
    o.colorWhileOff = r.pick({ "send", "hold" })
  end
  local fadeKind = r.pick({ "device", "device", "own", "walk" })
  if fadeKind == "device" then
    o.fade = {
      kind = "device",
      curve = r.pick({ "linear", "smootherstep" }),
      preOn = o.dims and r.chance(0.5),
      retimes = r.chance(0.5),
      maxMs = r.pick({ 65535, 86400000 }),
    }
    o.retimes = o.fade.retimes
  elseif fadeKind == "own" then
    o.fade = {
      kind = "own",
      own = { onMs = r.pick({ 0, 0, 300, 1000 }), offMs = r.pick({ 0, 0, 300, 1000 }), changeMs = r.pick({ 0, 500 }) },
    }
  else
    o.fade = { kind = "walk", stepMs = r.pick({ 50, 100, 250 }) }
  end
  o.feedback = {
    shows = r.pick({ "target", "position" }),
    waitMs = r.pick({ 300, 1000, 2500, 5000 }),
    refresh = r.chance(0.6),
  }
  o.latency = r.pick({ 0, 20, 40, 150 })
  o.answers = r.chance(0.5)
  o.readbackMs = r.chance(0.3) and r.pick({ 300, 1500 }) or nil
  o.seeds = r.chance(0.15)
  o.silent = r.chance(0.1)
  o.slow = r.chance(0.1) and 1.5 or nil
  o.pushEveryMs = r.pick({ 250, 1000 })
  o.links = r.chance(0.8) and M.LINKS or false
  o.on = r.chance(0.5)
  o.level = r.pick({ 0, 0.3, 1 })
  o.setup = Fake.setupFile(r.pick(SETUPS))
  o.settle = 5000
  local profile = M.profile(o)
  profile.scenes = r.chance(0.8)
  profile.onModes = r.chance(0.8)
  profile.flash = r.chance(0.7)
  profile.defaultOn = r.chance(0.7)
  o.profile = profile
  return {
    o = o,
    kind = kind,
    rest = o.dims and r.chance(0.1),
    inside = r.chance(0.1),
    drops = r.chance(0.15) and r.pick({ 0.05, 0.2 }) or 0,
    delays = r.chance(0.15),
  }
end

--- @param d FuzzDraw
--- @return string
local function describe(d)
  local o = d.o
  local fade = o.fade
  local parts = {
    d.kind,
    "steps " .. o.levelSteps,
    "fade " .. fade.kind,
    fade.curve or "",
    fade.preOn and "preOn" or "",
    fade.retimes and "retimes" or "",
    fade.stepMs and ("step " .. fade.stepMs) or "",
    "shows " .. o.feedback.shows,
    "wait " .. o.feedback.waitMs,
    o.feedback.refresh and "refresh" or "no refresh",
    o.colorWhileOff or "",
    "latency " .. o.latency,
    o.answers and "answers" or "",
    o.readbackMs and ("readback " .. o.readbackMs) or "",
    o.seeds and "seeds" or "",
    o.silent and "silent" or "",
    o.slow and "slow" or "",
    o.links and "links" or "no links",
    d.rest and "rest" or "",
    d.inside and "reports inside send" or "",
    d.drops > 0 and ("drops " .. d.drops) or "",
    d.delays and "delays" or "",
  }
  local out = {}
  for _, p in ipairs(parts) do
    if p ~= "" then
      out[#out + 1] = p
    end
  end
  return table.concat(out, ", ")
end

--------------------------------------------------------------------------------
-- A run: what it did and saw, by virtual time
--------------------------------------------------------------------------------

--- @class FuzzAction
--- @field at integer
--- @field name string
--- @field rate integer The longest change it asks, ms.
--- @field level integer|nil An absolute level it asks, for the quiet check.
--- @field online boolean

--- @class FuzzLoss
--- @field from integer
--- @field to integer|nil
--- @field suspended boolean
--- @field fromNote integer The notes before the loss.
--- @field dropEnd integer The notes once the loss was told.
--- @field toNote integer|nil The notes before the device came back.
--- @field fromSent integer
--- @field toSent integer|nil

--- @class FuzzRange
--- @field at integer
--- @field lo integer
--- @field hi integer

--- @class FuzzRun
--- @field seed integer
--- @field r FuzzRandom
--- @field d FuzzDraw
--- @field w MemoryWorld
--- @field trace string[]
--- @field actions FuzzAction[]
--- @field notes FakeProxyNote[] Every notify since the world was made, across restarts.
--- @field sent LightCommand[] Every command the adapter was given, each with `at`.
--- @field reports MemoryReport[]
--- @field reached table<integer, boolean> The device's C4 levels, as it passed them.
--- @field ranges FuzzRange[]
--- @field losses FuzzLoss[]
--- @field asks integer[] When the Ledger asked a refresh.
--- @field dues {at: integer, aspect: LightAspect, late: boolean}[]
--- @field errors string[] Errors logged that no malformed report explains.
--- @field malformed integer Errors a malformed report explains.
--- @field violations table<string, string[]>
--- @field judged table<string, boolean>
--- @field faithful boolean The transport loses and delays nothing: the tail.
--- @field blind boolean The light may have missed another hand's change for good, or a device's own
---   resting place: a quiet change, a lost frame, or a silent device with no refresh.
--- @field late boolean A report was delayed, so it may have overtaken a newer one.
--- @field online boolean
--- @field seenNotes integer
--- @field seenSent integer
--- @field seenReports integer
--- @field quietLast boolean The last action was a plain level, after nothing the light could mishear.

--- @param run FuzzRun
--- @param name string
--- @param fmt string
local function violate(run, name, fmt, ...)
  local list = run.violations[name] or {}
  run.violations[name] = list
  local ok, text = pcall(string.format, fmt, ...)
  list[#list + 1] = ok and text or fmt
end

--- @param run FuzzRun
--- @param fmt string
local function step(run, fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  run.trace[#run.trace + 1] = string.format("%d %s", run.w.clock.now(), ok and text or fmt)
  if TRACE then
    print("  " .. run.trace[#run.trace])
  end
end

--- The Min and Max On in force at a time.
--- @param run FuzzRun
--- @param at integer
--- @return integer lo, integer hi
local function rangeAt(run, at)
  local lo, hi = 1, 100
  for _, rg in ipairs(run.ranges) do
    if rg.at <= at then
      lo, hi = rg.lo, rg.hi
    end
  end
  return lo, hi
end

--- @param run FuzzRun
--- @param at integer
--- @return integer
local function slackAt(run, at)
  local lo, hi = rangeAt(run, at)
  return Range.slack(lo, hi, run.d.o.levelSteps) + 1
end

--- Take what the world recorded since the last look: its notes, sends and reports.
--- @param run FuzzRun
local function collect(run)
  local w = run.w
  for i = run.seenNotes + 1, #w.proxy.notes do
    run.notes[#run.notes + 1] = w.proxy.notes[i]
  end
  run.seenNotes = #w.proxy.notes
  for i = run.seenSent + 1, #w.m.sent do
    run.sent[#run.sent + 1] = w.m.sent[i]
  end
  run.seenSent = #w.m.sent
  for i = run.seenReports + 1, #w.m.reports do
    run.reports[#run.reports + 1] = w.m.reports[i]
  end
  run.seenReports = #w.m.reports
end

--- The device's level now, as a C4 level under the range in force.
--- @param run FuzzRun
local function sample(run)
  local w = run.w
  local now = w.clock.now()
  local state = w.device:state(now)
  local lo, hi = rangeAt(run, now)
  run.reached[state.on and Range.toLevel(state.level, lo, hi) or 0] = true
end

--- Record the range in force after something that may change it.
--- @param run FuzzRun
local function noteRange(run)
  local lo, hi = run.w.light.settings:onRange()
  local last = run.ranges[#run.ranges]
  if not last or last.lo ~= lo or last.hi ~= hi then
    run.ranges[#run.ranges + 1] = { at = run.w.clock.now(), lo = lo, hi = hi }
  end
end

--- Watch the world's light and MemoryLight: the asks, the deadlines, and a report made inside send.
--- @param run FuzzRun
local function instrument(run)
  local w = run.w
  local light, m = w.light, w.m
  local heard = light._heard
  light._heard = function(self, h)
    if h.ask then
      run.asks[#run.asks + 1] = w.clock.now()
    end
    return heard(self, h)
  end
  local due = light._due
  light._due = function(self, aspect)
    local now = w.clock.now()
    local ramp = aspect == "color" and self.motion.colorRamp or (aspect == "level" and self.motion.levelRamp or nil)
    local open = self.ledger.windows[aspect] ~= nil
    run.dues[#run.dues + 1] =
      { at = now, aspect = aspect, late = open and ramp ~= nil and ramp.startMs + ramp.ms > now + 1 }
    return due(self, aspect)
  end
  local send = m._send
  m._send = function(self, cmd)
    local rest = send(self, cmd)
    if run.d.inside and self.online and not run.faithful then
      local report = self.device:values(self.clock.now(), self:_showsTarget())
      report.kind = "push"
      self:deliver(report)
    end
    return rest
  end
  local onChange = w.device.onChange
  w.device.onChange = function(landed)
    onChange(landed)
    sample(run)
  end
end

--- One step of a run, its raise caught.
--- @param run FuzzRun
--- @param name string
--- @param fn fun()
--- @param rate integer|nil
--- @param level integer|nil
local function act(run, name, fn, rate, level)
  step(run, "%s", name)
  local a = { at = run.w.clock.now(), name = name, rate = rate or 0, level = level, online = run.online }
  run.actions[#run.actions + 1] = a
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    violate(run, "errors", "%s raised: %s", name, tostring(err))
  end
  noteRange(run)
  sample(run)
  collect(run)
end

--- Run the clock, sampling the device as it goes.
--- @param run FuzzRun
--- @param ms integer
local function wait(run, ms)
  local w = run.w
  local stop = w.clock.now() + ms
  while w.clock.now() < stop do
    w.run(math.min(100, stop - w.clock.now()))
    sample(run)
  end
  collect(run)
end

--------------------------------------------------------------------------------
-- What a run does
--------------------------------------------------------------------------------

--- @param r FuzzRandom
--- @return integer
local function level(r)
  return r.pick({ 0, 1, 100, r.int(1, 100), r.int(1, 100), r.int(1, 100) })
end

--- @param r FuzzRandom
--- @return {x: number, y: number, mode: integer}
local function color(r, o)
  if o.cct and (not o.color or r.chance(0.4)) then
    local k = r.int(o.cct.minK, o.cct.maxK)
    local x, y = C4:ColorCCTtoXY(k)
    return { x = x, y = y, mode = K.CCT }
  end
  return { x = 0.15 + r.float() * 0.5, y = 0.1 + r.float() * 0.5, mode = K.FULL }
end

--- A report of the device's state from before, as a cache can re-push it.
--- @param run FuzzRun
local function stale(run)
  local w = run.w
  local old = run.snapshot or w.device:values(w.clock.now(), true)
  local report = copy(old)
  report.kind = "push"
  w.m:inject(w.clock.now() + run.r.pick({ 0, 50, 400 }), report)
end

--- A report no device makes: the library must drop it whole, with one error logged.
--- @param run FuzzRun
local function malformed(run)
  local w = run.w
  local bad = run.r.pick({
    { kind = "push", level = 0 / 0 },
    { kind = "push", level = 2 },
    { kind = "push", level = math.huge },
    { kind = "sometime", on = true },
    { kind = "push", on = "yes" },
    { kind = "push", color = { x = math.huge, y = 0.3, mode = "xy" } },
    { kind = "push", color = { x = 0.3, y = 0.3, mode = "rgb" } },
    { kind = "push", color = { x = 0.3, y = 0.3, mode = "cct", kelvin = -5 } },
  })
  collect(run)
  local before = { notes = #w.proxy.notes, sent = #w.m.sent, now = copy(w.light.motion:now()) }
  local errors = run.malformedSeen
  run.expectMalformed = true
  w.light:report(bad)
  run.expectMalformed = false
  run.judged.malformed = true
  if #w.proxy.notes ~= before.notes or #w.m.sent ~= before.sent then
    violate(run, "malformed", "a malformed report (%s) told or sent something", T.show(bad))
  end
  if T.show(w.light.motion:now()) ~= T.show(before.now) then
    violate(run, "malformed", "a malformed report (%s) moved the light", T.show(bad))
  end
  if run.malformedSeen ~= errors + 1 then
    violate(run, "malformed", "a malformed report (%s) logged %d errors", T.show(bad), run.malformedSeen - errors)
  end
end

--- What a run can do, each with its weight.
--- @param run FuzzRun
--- @return {[1]: integer, [2]: fun()}[]
local function moves(run)
  local r, o, w = run.r, run.d.o, run.w
  local function rate()
    return r.pick(RATES)
  end
  local function proxy(cmd, params, ms, lvl)
    act(run, cmd .. " " .. T.show(params or {}), function()
      w.proxy:send(cmd, params)
    end, ms, lvl)
  end
  local list = {
    {
      6,
      function()
        local l = level(r)
        proxy("SET_LEVEL", { LEVEL = l }, 0, l)
      end,
    },
    {
      8,
      function()
        local ms = rate()
        proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level(r), RATE = ms }, ms)
      end,
    },
    {
      2,
      function()
        local ms = rate()
        proxy("RAMP_TO_LEVEL", { LEVEL = level(r), TIME = ms }, ms)
      end,
    },
    {
      3,
      function()
        proxy("ON")
      end,
    },
    {
      3,
      function()
        proxy("OFF")
      end,
    },
    {
      3,
      function()
        proxy("TOGGLE")
      end,
    },
    {
      2,
      function()
        proxy("SET_BRIGHTNESS_STOP")
      end,
    },
    {
      2,
      function()
        local l = r.int(1, 100)
        act(run, "the app's On at " .. l, function()
          local c = (o.color or o.cct) and r.chance(0.6) and color(r, o) or nil
          if c then
            c.preset, c.origin = r.pick({ 1, 10 }), 1
          end
          w.proxy:appOn(l, c)
        end, 750)
      end,
    },
    {
      3,
      function()
        act(run, "another hand", function()
          local state = {}
          if r.chance(0.6) then
            state.on = r.chance(0.6)
          end
          if o.dims and r.chance(0.6) then
            state.level = r.pick({ 0.2, 0.5, 0.9, r.float() })
          end
          if (o.color or o.cct) and r.chance(0.4) then
            local c = color(r, o)
            state.color = { x = c.x, y = c.y, mode = c.mode == K.CCT and "cct" or "xy" }
          end
          local quiet = r.chance(0.1)
          run.blind = run.blind or quiet
          w.m:other(state, quiet)
        end)
      end,
    },
    {
      1,
      function()
        act(run, "a stale push", function()
          stale(run)
        end)
      end,
    },
    {
      1,
      function()
        malformed(run)
      end,
    },
    {
      2,
      function()
        run.snapshot = w.device:values(w.clock.now(), true)
      end,
    },
    {
      2,
      function()
        proxy("SET_MIN_ON_LEVEL", { LEVEL = r.pick({ 0, 1, 10, 30 }) })
      end,
    },
    {
      2,
      function()
        proxy("SET_MAX_ON_LEVEL", { LEVEL = r.pick({ 100, 100, 90, 60 }) })
      end,
    },
    {
      1,
      function()
        proxy("SET_PRESET_LEVEL", { LEVEL = r.int(1, 100) })
      end,
    },
    {
      1,
      function()
        proxy(
          "UPDATE_BRIGHTNESS_ON_MODE",
          { BRIGHTNESS_PRESET_ID = r.pick({ 0, 10 }), BRIGHTNESS_PRESET_LEVEL = r.int(1, 100) }
        )
      end,
    },
  }
  if o.color or o.cct then
    list[#list + 1] = {
      6,
      function()
        local c, ms = color(r, o), rate()
        local params = {
          LIGHT_COLOR_TARGET_X = c.x,
          LIGHT_COLOR_TARGET_Y = c.y,
          LIGHT_COLOR_TARGET_MODE = c.mode,
          LIGHT_COLOR_TARGET_COLOR_RATE = ms,
        }
        if r.chance(0.2) then
          params.LIGHT_COLOR_TARGET_PRESET_ID, params.LIGHT_COLOR_TARGET_PRESET_ORIGIN = r.pick({ 1, 10 }), 1
        end
        proxy("SET_COLOR_TARGET", params, ms)
      end,
    }
    list[#list + 1] = {
      1,
      function()
        proxy("SET_COLOR_STOP")
      end,
    }
    list[#list + 1] = {
      1,
      function()
        act(run, "a color on mode", function()
          local pick = r.int(1, 3)
          if pick == 1 then
            K.onMode(w, K.ON_PRESET)
          elseif pick == 2 then
            K.onMode(w, K.WARM, K.DIM)
          else
            K.onMode(w, { id = 0, origin = 0 })
          end
        end)
      end,
    }
  end
  if o.links then
    list[#list + 1] = {
      4,
      function()
        local binding = r.pick({ M.LINKS.top, M.LINKS.toggle, M.LINKS.bottom })
        local cmd = r.pick({ "DO_PUSH", "DO_CLICK", "DO_RELEASE" })
        act(run, cmd .. " on link " .. binding, function()
          w.proxy:link(binding, cmd)
        end, 3000)
      end,
    }
    list[#list + 1] = {
      2,
      function()
        local button, action = r.int(0, 2), r.int(0, 2)
        act(run, string.format("BUTTON_ACTION %d %d", button, action), function()
          K.button(w, button, action)
        end, 3000)
      end,
    }
  end
  list[#list + 1] = {
    3,
    function()
      local id = r.int(1, 3)
      local steps = {}
      for i = 1, r.int(1, 4) do
        steps[i] = {
          delay = r.pick({ 0, 0, 200, 1500 }),
          level = (o.dims or r.chance(0.5)) and r.pick({ 0, 20, 60, 100 }) or nil,
          color = (o.color or o.cct) and r.chance(0.4) and color(r, o) or nil,
          rate = r.pick({ 0, 500, 2000 }),
        }
      end
      act(run, "a scene " .. id .. " pushed and run", function()
        K.scene(w, id, steps, r.chance(0.3))
        w.proxy:send("ACTIVATE_SCENE", { SCENE_ID = id })
      end, LONGEST)
    end,
  }
  list[#list + 1] = {
    2,
    function()
      local cmd = r.pick({ "DEACTIVATE_SCENE", "RAMP_SCENE_UP", "RAMP_SCENE_DOWN", "STOP_SCENE_RAMP", "TOGGLE_SCENE" })
      proxy(cmd, { SCENE_ID = r.int(1, 3) }, LONGEST)
    end,
  }
  list[#list + 1] = {
    1,
    function()
      if not run.online then
        return
      end
      local suspended = r.chance(0.5)
      collect(run)
      local loss = { from = w.clock.now(), suspended = suspended, fromNote = #run.notes, fromSent = #run.sent }
      act(run, suspended and "the device is suspended" or "the device is lost", function()
        w.m:drop(suspended)
      end)
      loss.dropEnd = #run.notes
      run.online = false
      run.losses[#run.losses + 1] = loss
    end,
  }
  list[#list + 1] = {
    2,
    function()
      if run.online then
        return
      end
      collect(run)
      local loss = run.losses[#run.losses]
      loss.to, loss.toNote, loss.toSent = w.clock.now(), #run.notes, #run.sent
      act(run, "the device is back", function()
        w.m:back()
      end)
      run.online = true
    end,
  }
  list[#list + 1] = {
    1,
    function()
      if not run.online then
        return
      end
      act(run, "Reset Driver", function()
        w.light:reset()
      end)
    end,
  }
  return list
end

--- The driver restarts at a quiet point: a new Light over the same proxy, settings and device.
--- @param run FuzzRun
local function restart(run)
  wait(run, QUIET)
  collect(run)
  step(run, "the driver restarts")
  local ok, err = xpcall(function()
    run.w.restart()
  end, debug.traceback)
  run.seenNotes, run.seenSent, run.seenReports = 0, 0, 0
  if not ok then
    violate(run, "errors", "the restart raised: %s", tostring(err))
    return
  end
  instrument(run)
  noteRange(run)
  collect(run)
end

--------------------------------------------------------------------------------
-- The invariants, judged once the run is at rest
--------------------------------------------------------------------------------

--- @param a {x: number, y: number}|nil
--- @param b {x: number, y: number}|nil
--- @return boolean
local function sameXY(a, b)
  return a ~= nil and b ~= nil and math.abs(a.x - b.x) <= 0.01 and math.abs(a.y - b.y) <= 0.01
end

--- The color the proxy shows now: the last CHANGED, or a CHANGING's target once its rate has run.
--- @param run FuzzRun
--- @return {x: number, y: number}|nil
local function shownColor(run)
  local c
  for _, n in ipairs(run.notes) do
    local p = n.params
    if n.cmd == "LIGHT_COLOR_CHANGED" then
      c = { x = tonumber(p.LIGHT_COLOR_CURRENT_X), y = tonumber(p.LIGHT_COLOR_CURRENT_Y) }
    elseif n.cmd == "LIGHT_COLOR_CHANGING" then
      c = { x = tonumber(p.LIGHT_COLOR_TARGET_X), y = tonumber(p.LIGHT_COLOR_TARGET_Y) }
    end
  end
  return c
end

--- @param run FuzzRun
local function judgeRest(run)
  local w, o = run.w, run.d.o
  run.judged.rest = true
  local now = w.clock.now()
  if w.proxy.online ~= true then
    violate(run, "rest", "the proxy shows the light offline at rest")
  end
  local state = w.device:state(now)
  local lo, hi = rangeAt(run, now)
  local want = state.on and Range.toLevel(state.level, lo, hi) or 0
  local shown = w.proxy.level or -1
  if math.abs(shown - want) > slackAt(run, now) or (shown > 0) ~= (want > 0) then
    violate(run, "rest", "the proxy shows %s at rest, the device is at %s", tostring(w.proxy.level), want)
  end
  if not (o.color or o.cct) or (o.colorWhileOff == "hold" and not state.on) then
    return
  end
  local c = shownColor(run)
  if c and not sameXY(c, state.color) then
    violate(run, "rest", "the proxy shows the color %s at rest, the device shows %s", T.show(c), T.show(state.color))
  end
end

--- The run's last action is SET_LEVEL at a known level, with a faithful transport after it.
--- @param run FuzzRun
--- @param asked integer
local function judgeLatest(run, asked)
  local w, o = run.w, run.d.o
  if run.d.rest then
    return
  end
  run.judged.latest = true
  local now = w.clock.now()
  local state = w.device:state(now)
  local lo, hi = rangeAt(run, now)
  if state.on ~= (asked > 0) then
    violate(run, "latest", "SET_LEVEL %d was last, the device is %s", asked, state.on and "on" or "off")
    return
  end
  if o.dims and asked > 0 and math.abs(Range.toLevel(state.level, lo, hi) - asked) > slackAt(run, now) then
    violate(run, "latest", "SET_LEVEL %d was last, the device ends at %s", asked, Range.toLevel(state.level, lo, hi))
  end
end

--- @param run FuzzRun
local function judgeTold(run)
  for i, n in ipairs(run.notes) do
    -- Where the light is said to be. A CHANGING's target is where a proxy command asked it to head.
    local lvl
    if n.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
      lvl = tonumber(n.params.LIGHT_BRIGHTNESS_CURRENT)
    end
    if n.binding == M.PROXY and lvl and lvl > 0 then
      run.judged.told = true
      local slack = slackAt(run, n.at)
      local lo, hi = rangeAt(run, n.at)
      local seen = false
      for l = math.max(1, lvl - slack), math.min(100, lvl + slack) do
        seen = seen or run.reached[l] == true
      end
      -- A walk sends its first step a stepMs after the intent it was told for.
      local walk = run.d.o.fade.kind == "walk" and (run.d.o.fade.stepMs or 100) or 0
      for _, c in ipairs(run.sent) do
        if c.at <= n.at + walk and not seen then
          local a = Range.toLevel(c.level, lo, hi)
          local b = Range.toLevel(c.from and c.from.level or c.level, lo, hi)
          seen = lvl >= math.min(a, b) - slack and lvl <= math.max(a, b) + slack
          -- A rest the adapter returned is where it said the device rests, told as the command goes out.
          if not seen and c.rest and c.rest.level then
            seen = math.abs(lvl - Range.toLevel(c.rest.level, lo, hi)) <= slack
          end
        end
      end
      for j = 1, i - 1 do
        local p = run.notes[j]
        seen = seen or (p.cmd == "LIGHT_BRIGHTNESS_CHANGED" and tonumber(p.params.LIGHT_BRIGHTNESS_CURRENT) == lvl)
      end
      for _, rep in ipairs(run.reports) do
        local rl = rep.report.level
        if not seen and rep.at <= n.at and rl and rep.report.on ~= false then
          seen = math.abs(Range.toLevel(rl, lo, hi) - lvl) <= slack
        end
      end
      local previous = run.w.light.settings:previousOnLevel()
      seen = seen or (previous ~= nil and math.abs(previous - lvl) <= slack)
      if not seen then
        violate(run, "told", "%s %s at %d: no command spanned it and the device never reached it", n.cmd, lvl, n.at)
      end
    end
  end
end

--- @param run FuzzRun
--- @param from integer
--- @param to integer
--- @return boolean
local function heardBetween(run, from, to)
  for _, rep in ipairs(run.reports) do
    if rep.at > from and rep.at <= to then
      return true
    end
  end
  for _, a in ipairs(run.actions) do
    if a.at > from and a.at <= to then
      return true
    end
  end
  return false
end

--- @param run FuzzRun
local function judgeRamps(run)
  local prev
  for _, n in ipairs(run.notes) do
    if n.binding == M.PROXY and (n.cmd == "LIGHT_BRIGHTNESS_CHANGING" or n.cmd == "LIGHT_BRIGHTNESS_CHANGED") then
      local p = n.params
      local slack = slackAt(run, n.at)
      local keep = n.cmd == "LIGHT_BRIGHTNESS_CHANGING" and (tonumber(p.RATE) or 0) == 0
      if n.cmd == "LIGHT_BRIGHTNESS_CHANGING" and prev and not keep then
        run.judged.ramps = true
        local current = tonumber(p.LIGHT_BRIGHTNESS_CURRENT) or -1
        local q = prev.params
        local ok
        if prev.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
          local was = tonumber(q.LIGHT_BRIGHTNESS_CURRENT) or -1
          ok = math.abs(current - was) <= slack or (was == 0 and current <= 1)
        else
          local a, b = tonumber(q.LIGHT_BRIGHTNESS_CURRENT) or 0, tonumber(q.LIGHT_BRIGHTNESS_TARGET) or 0
          ok = current >= math.min(a, b) - slack and current <= math.max(a, b) + slack
        end
        if not ok and not heardBetween(run, prev.at - 1, n.at) then
          violate(run, "ramps", "a CHANGING at %d starts at %s, the proxy last saw %s", n.at, current, T.show(q))
        end
      end
      if n.cmd == "LIGHT_BRIGHTNESS_CHANGED" and prev and prev.cmd == "LIGHT_BRIGHTNESS_CHANGING" then
        local q = prev.params
        local rate = tonumber(q.RATE) or 0
        local target = tonumber(q.LIGHT_BRIGHTNESS_TARGET) or -1
        local level = tonumber(p.LIGHT_BRIGHTNESS_CURRENT) or -1
        -- A LightRest rests the light where the adapter says, not at the ramp's target.
        if rate > 0 and n.at >= prev.at + rate - 2 and not run.d.rest and not heardBetween(run, prev.at, n.at) then
          run.judged.ramps = true
          if math.abs(level - target) > slack then
            violate(run, "ramps", "a ramp to %s from %d ran out and ended at %s", target, prev.at, level)
          end
        end
      end
      prev = n
    end
  end
end

--- @param run FuzzRun
local function judgeOnce(run)
  local level, color
  for _, n in ipairs(run.notes) do
    local p = n.params
    local mine = n.binding == M.PROXY
    -- A rate-0 CHANGING to 0 is the Previous On keep an off tells first, not a ramp.
    if mine and n.cmd == "LIGHT_BRIGHTNESS_CHANGING" and (tonumber(p.RATE) or 0) > 0 then
      run.judged.once = true
      local key = { to = p.LIGHT_BRIGHTNESS_TARGET, ends = n.at + (tonumber(p.RATE) or 0) }
      if level and level.to == key.to and math.abs(level.ends - key.ends) <= 1 then
        violate(run, "once", "the level ramp to %s ending at %d was told CHANGING twice", tostring(key.to), key.ends)
      end
      level = key
    elseif mine and n.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
      level = nil
    elseif mine and n.cmd == "LIGHT_COLOR_CHANGING" then
      run.judged.once = true
      local rate = tonumber(p.LIGHT_COLOR_TARGET_COLOR_RATE) or 0
      local key = { x = p.LIGHT_COLOR_TARGET_X, y = p.LIGHT_COLOR_TARGET_Y, ends = n.at + rate }
      if color and color.x == key.x and color.y == key.y and math.abs(color.ends - key.ends) <= 1 then
        violate(run, "once", "the color ramp ending at %d was told CHANGING twice", key.ends)
      end
      color = key
    elseif mine and n.cmd == "LIGHT_COLOR_CHANGED" then
      color = nil
    end
  end
end

--- @param run FuzzRun
local function judgeBinds(run)
  for _, loss in ipairs(run.losses) do
    if loss.to then
      run.judged.binds = true
      local offs = 0
      for i = loss.fromNote + 1, loss.toNote do
        local n = run.notes[i]
        local p = n.params
        local atLoss = i <= loss.dropEnd
        local ok = false
        if n.binding ~= M.PROXY then
          ok = n.cmd == "MATCH_LED_STATE" and p.STATE == false
        elseif n.cmd == "ONLINE_CHANGED" then
          ok = p.STATE == false
        elseif n.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
          ok = not loss.suspended and atLoss
          offs = offs + ((tonumber(p.LIGHT_BRIGHTNESS_CURRENT) or -1) == 0 and 1 or 0)
        elseif n.cmd == "LIGHT_COLOR_CHANGED" then
          ok = not loss.suspended and atLoss
        elseif n.cmd == "LIGHT_BRIGHTNESS_CHANGING" then
          -- The Previous On keep an off tells first.
          ok = not loss.suspended and atLoss and (tonumber(p.RATE) or 0) == 0
        end
        if not ok then
          violate(run, "binds", "%s at %d while lost from %d: %s", n.cmd, n.at, loss.from, T.show(p))
        end
      end
      if offs > 1 then
        violate(run, "binds", "the off was told %d times for the loss at %d", offs, loss.from)
      end
      for i = loss.fromSent + 1, loss.toSent do
        violate(run, "binds", "a command went at %d while lost from %d", run.sent[i].at, loss.from)
      end
    end
  end
end

--- @param run FuzzRun
local function judgeCommands(run)
  local o = run.d.o
  local kind = o.fade.kind
  for i, c in ipairs(run.sent) do
    run.judged.commands = true
    local function bad(why)
      violate(run, "commands", "command %d at %d %s: %s", i, c.at, T.show(c), why)
    end
    if c.kind ~= "preOn" and c.kind ~= "change" and c.kind ~= "stop" then
      bad("an unknown kind")
    end
    if type(c.on) ~= "boolean" or type(c.fromOff) ~= "boolean" then
      bad("on and fromOff are booleans")
    end
    if type(c.level) ~= "number" or c.level < 0 or c.level > 1 then
      bad("the level is 0 to 1")
    end
    if not o.dims and c.on and c.level ~= 1 then
      bad("a light that does not dim is sent level 1")
    end
    if c.kind == "stop" and c.fromOff then
      bad("fromOff on a stop")
    end
    if c.fromOff and not c.setsLevel then
      bad("fromOff without setsLevel")
    end
    if c.kind == "stop" and not (c.setsLevel or c.setsColor) then
      bad("a stop that names no aspect")
    end
    if c.kind ~= "stop" and not c.on and not c.setsLevel and not c.setsColor then
      bad("an off command that changes nothing")
    end
    if kind ~= "device" and (c.transitionMs or 0) ~= 0 then
      bad("a timed command to an " .. kind .. " fade")
    end
    if c.kind == "preOn" then
      local nxt = run.sent[i + 1]
      if (c.transitionMs or 0) ~= 0 then
        bad("a timed preOn")
      end
      if not nxt or nxt.at ~= c.at or nxt.kind ~= "change" then
        bad("a preOn without its change")
      end
    end
    if o.colorWhileOff == "hold" and not c.on and c.setsColor and not c.setsLevel then
      bad("a color alone to an off hold device")
    end
    if (o.color or o.cct) and not c.color then
      bad("no color for a device with color")
    end
    if c.color then
      if c.color.mode ~= "xy" and c.color.mode ~= "cct" then
        bad("an unknown color mode")
      elseif not o.color and c.color.mode ~= "cct" then
        bad("a full color to a white-only device")
      elseif c.color.mode == "cct" and o.cct then
        local k = c.color.kelvin
        if not k or k < o.cct.minK or k > o.cct.maxK then
          bad("a white without a Kelvin in the device's range")
        end
      end
    end
  end
end

--- @param run FuzzRun
local function judgeSends(run)
  local fade = run.d.o.fade
  if fade.kind ~= "walk" then
    return
  end
  local stepMs = fade.stepMs or 100
  local cuts = {}
  for _, a in ipairs(run.actions) do
    cuts[#cuts + 1] = a.at
  end
  cuts[#cuts + 1] = math.huge
  for k = 1, #cuts - 1 do
    local from, to = cuts[k], cuts[k + 1]
    local n = 0
    for _, c in ipairs(run.sent) do
      if c.at >= from and c.at < to then
        n = n + 1
      end
    end
    -- A run's changes last at most LONGEST: scene steps chain, so allow each of up to four.
    local bound = math.floor(math.min(to - from, 4 * LONGEST) / stepMs) + 2 + 2 * 4
    run.judged.sends = true
    if n > bound then
      violate(run, "sends", "%d commands between %d and %d on a %d ms walk", n, from, to, stepMs)
    end
  end
end

--- @param run FuzzRun
local function judgeAsks(run)
  run.judged.asks = true
  if not run.d.o.feedback.refresh and #run.asks > 0 then
    violate(run, "asks", "%d refreshes asked of a device that offers none", #run.asks)
    return
  end
  local cuts = { -math.huge }
  for _, c in ipairs(run.sent) do
    cuts[#cuts + 1] = c.at
  end
  cuts[#cuts + 1] = math.huge
  for k = 1, #cuts - 1 do
    local n, heard = 0, 0
    for _, at in ipairs(run.asks) do
      if at >= cuts[k] and at < cuts[k + 1] then
        n = n + 1
      end
    end
    for _, rep in ipairs(run.reports) do
      if rep.at >= cuts[k] and rep.at < cuts[k + 1] then
        heard = heard + 1
      end
    end
    if n > 3 + heard then
      violate(run, "asks", "%d refreshes between commands at %s and %s", n, tostring(cuts[k]), tostring(cuts[k + 1]))
    end
  end
end

--- A plain level command on a faithful transport, with nothing after it for long: one CHANGED per aspect.
--- @param run FuzzRun
--- @param a FuzzAction
--- @param to integer
local function judgeQuiet(run, a, to)
  run.judged.quiet = true
  local levels, colors = 0, 0
  for _, n in ipairs(run.notes) do
    if n.binding == M.PROXY and n.at >= a.at and n.at < to then
      levels = levels + (n.cmd == "LIGHT_BRIGHTNESS_CHANGED" and 1 or 0)
      colors = colors + (n.cmd == "LIGHT_COLOR_CHANGED" and 1 or 0)
    end
  end
  if levels > 1 or colors > 1 then
    violate(run, "quiet", "%s at %d told %d level and %d color CHANGED", a.name, a.at, levels, colors)
  end
end

--- @param run FuzzRun
local function judgeWindow(run)
  for _, d in ipairs(run.dues) do
    run.judged.window = true
    if d.late then
      violate(run, "window", "the %s deadline at %d fell while its ramp still ran", d.aspect, d.at)
    end
  end
end

--- @param run FuzzRun
local function judgeErrors(run)
  run.judged.errors = true
  for _, e in ipairs(run.errors) do
    violate(run, "errors", "logged: %s", e)
  end
  for _, e in ipairs(run.w.clock.errors) do
    violate(run, "errors", "a timer callback raised: %s", tostring(e))
  end
end

--- Print a run's commands, reports, notifies, actions and deadlines in time order, for a replay.
--- @param run FuzzRun
local function timeline(run)
  --- @type {at: integer, i: integer, text: string}[]
  local events = {}
  local function add(at, text)
    events[#events + 1] = { at = at, i = #events + 1, text = text }
  end
  for _, a in ipairs(run.actions) do
    add(a.at, "action " .. a.name)
  end
  for _, n in ipairs(run.notes) do
    if n.binding == M.PROXY and n.cmd:match("^LIGHT_") then
      local q = n.params
      add(
        n.at,
        string.format(
          "told %s level %s->%s rate %s color %s->%s",
          n.cmd,
          tostring(q.LIGHT_BRIGHTNESS_CURRENT),
          tostring(q.LIGHT_BRIGHTNESS_TARGET),
          tostring(q.RATE or q.LIGHT_COLOR_TARGET_COLOR_RATE),
          tostring(q.LIGHT_COLOR_CURRENT_X),
          tostring(q.LIGHT_COLOR_TARGET_X)
        )
      )
    end
  end
  for _, c in ipairs(run.sent) do
    add(
      c.at,
      string.format(
        "sent %s on=%s level=%.3f setsLevel=%s setsColor=%s ms=%s fromOff=%s",
        c.kind,
        tostring(c.on),
        c.level,
        tostring(c.setsLevel),
        tostring(c.setsColor),
        tostring(c.transitionMs),
        tostring(c.fromOff)
      )
    )
  end
  for _, rep in ipairs(run.reports) do
    local q = rep.report
    add(rep.at, string.format("report %s on=%s level=%s", q.kind, tostring(q.on), tostring(q.level)))
  end
  for _, du in ipairs(run.dues) do
    add(du.at, "deadline " .. du.aspect .. (du.late and " while its ramp runs" or ""))
  end
  table.sort(events, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    return a.i < b.i
  end)
  for _, e in ipairs(events) do
    print(string.format("  %d %s", e.at, e.text))
  end
end

--------------------------------------------------------------------------------
-- One run
--------------------------------------------------------------------------------

--- @param seed integer
--- @return FuzzRun
local function fuzz(seed)
  local r = rng(seed)
  local d = draw(r)
  local run = {
    seed = seed,
    r = r,
    d = d,
    trace = {},
    actions = {},
    notes = {},
    sent = {},
    reports = {},
    reached = {},
    ranges = {},
    losses = {},
    asks = {},
    dues = {},
    errors = {},
    malformedSeen = 0,
    violations = {},
    judged = {},
    faithful = false,
    blind = d.drops > 0 or (d.o.silent and not d.o.feedback.refresh),
    late = false,
    online = true,
    seenNotes = 0,
    seenSent = 0,
    seenReports = 0,
  }
  local o = d.o
  if d.drops > 0 then
    o.drop = function()
      return not run.faithful and r.chance(d.drops)
    end
  end
  if d.delays then
    o.delay = function()
      if run.faithful or not r.chance(0.3) then
        return 0
      end
      local ms = r.pick({ 200, 800, o.feedback.waitMs + 500 })
      -- A delayed report can overtake a newer one with no command out, which no rule can tell apart.
      run.late = true
      return ms
    end
  end
  if d.rest then
    o.rest = function(cmd)
      if cmd.kind == "change" and cmd.setsLevel and cmd.on and cmd.level > 0.2 then
        return { level = math.floor(cmd.level * 90 + 0.5) / 100 }
      end
      return nil
    end
  end
  local ok, err = xpcall(function()
    run.w = M.world(o)
  end, debug.traceback)
  if not ok then
    violate(run, "errors", "the world raised at its start: %s", tostring(err))
    return run
  end
  local w = run.w
  local errorFn = log.error
  log.error = function(_, fmt, ...)
    local okf, text = pcall(string.format, tostring(fmt), ...)
    if run.expectMalformed then
      run.malformedSeen = run.malformedSeen + 1
    else
      run.errors[#run.errors + 1] = okf and text or tostring(fmt)
    end
  end
  step(run, "%s", describe(d))
  instrument(run)
  noteRange(run)
  collect(run)
  local list = moves(run)
  local total = 0
  for _, mv in ipairs(list) do
    total = total + mv[1]
  end
  local count = r.int(6, 30)
  for _ = 1, count do
    if r.chance(0.03) and run.online then
      restart(run)
    else
      local roll = r.float() * total
      for _, mv in ipairs(list) do
        roll = roll - mv[1]
        if roll <= 0 then
          mv[2]()
          break
        end
      end
    end
    wait(run, r.pick(GAPS))
  end
  -- The tail: the transport turns faithful, the device comes back, and every change runs out.
  run.faithful = true
  if not run.online then
    collect(run)
    local loss = run.losses[#run.losses]
    loss.to, loss.toNote, loss.toSent = w.clock.now(), #run.notes, #run.sent
  end
  if not run.online or not w.light.online then
    act(run, "the device is back", function()
      w.m:back()
    end)
    run.online = true
  end
  wait(run, QUIET)
  local final = r.pick({ 0, 1, 100, r.int(1, 100), r.int(1, 100) })
  act(run, "the last SET_LEVEL " .. final, function()
    w.proxy:send("SET_LEVEL", { LEVEL = final })
  end, 0, final)
  wait(run, QUIET)
  -- A plain level after a quiet tail, on a transport that heard everything, tells once.
  if not run.blind and not run.late and not o.slow and not d.rest and not d.inside then
    judgeQuiet(run, run.actions[#run.actions], w.clock.now())
  end
  if os.getenv("LIGHT_FUZZ_TIMELINE") == "1" then
    timeline(run)
  end
  if not run.blind and not run.late then
    judgeLatest(run, final)
    judgeRest(run)
  end
  judgeTold(run)
  judgeRamps(run)
  judgeOnce(run)
  judgeBinds(run)
  judgeCommands(run)
  judgeSends(run)
  judgeAsks(run)
  judgeWindow(run)
  judgeErrors(run)
  log.error = errorFn
  return run
end

--------------------------------------------------------------------------------
-- The runs
--------------------------------------------------------------------------------

local printEnabled = log:isPrintEnabled()
log:setOutputPrintEnabled(false)
local failed = {}
local judged = {}
local started = os.clock()
for i = 0, RUNS - 1 do
  local seed = SEED + i
  if TRACE then
    print(string.format("run seed %d", seed))
  end
  local ok, run = xpcall(function()
    return fuzz(seed)
  end, debug.traceback)
  M.closeAll()
  if not ok then
    failed.errors = failed.errors or {}
    failed.errors[#failed.errors + 1] = { seed = seed, why = tostring(run), trace = {} }
  else
    for name in pairs(run.judged) do
      judged[name] = (judged[name] or 0) + 1
    end
    for name, list in pairs(run.violations) do
      failed[name] = failed[name] or {}
      failed[name][#failed[name] + 1] = { seed = seed, why = list[1], trace = run.trace, more = #list - 1 }
    end
  end
end
log:setOutputPrintEnabled(printEnabled)
print(string.format("%d runs from seed %d in %.1f s", RUNS, SEED, os.clock() - started))

T.section("the light library under seeded random runs")
for _, inv in ipairs(INVARIANTS) do
  local list = failed[inv.name] or {}
  local detail = {}
  for k = 1, math.min(SHOW, #list) do
    local f = list[k]
    detail[#detail + 1] = string.format(
      "seed %d: %s%s\n    replay: LIGHT_FUZZ_SEED=%d LIGHT_FUZZ_RUNS=1 LIGHT_FUZZ_TIMELINE=1\n    %s",
      f.seed,
      f.why,
      (f.more or 0) > 0 and string.format(" (and %d more in the run)", f.more) or "",
      f.seed,
      table.concat(f.trace or {}, "\n    ", 1, math.min(#(f.trace or {}), 40))
    )
  end
  T.check(
    string.format("%s: %s (%d failing runs of %d judged)", inv.name, inv.says, #list, judged[inv.name] or 0),
    #list == 0,
    table.concat(detail, "\n  ")
  )
end
-- An invariant no run was in a state to judge has not been shown to hold.
for _, inv in ipairs(INVARIANTS) do
  T.check(inv.name .. " was judged by some run", RUNS < 50 or (judged[inv.name] or 0) > 0)
end
T.finish()
