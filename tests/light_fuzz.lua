-- The Light V2 library under seeded random runs: the proxy's commands and another hand's changes at
-- the device, over MemoryLight in every declaration the header allows, with its transport drawn per
-- run. Each run is judged by invariants, each taken from a sentence of src/lib/light.lua's header.
--
-- The template's own test: it drives only the kit's MemoryLight, so it renders into no driver repo.
-- Run against a render with the light token, from the template repo:
--   make render-light-fuzz NAME=light
-- 20,000 runs from seed 1; before a change to the library, other seeds too, a job each:
--   LIGHT_FUZZ_SEED=<n> make render-light-fuzz NAME=light
-- A failure names its seed and run; LIGHT_FUZZ_SEED=<seed> LIGHT_FUZZ_RUN=<run> replays that run alone
-- and prints its steps. LIGHT_FUZZ_RUNS sets the count, LIGHT_FUZZ_SHOW how many failures of each
-- invariant are listed.

local T = require("testlib")

require("c4_shim")

if not pcall(require, "lib.light") then
  print("This render has no lib.light.")
  return
end

local H = require("light_harness")
local Light = require("lib.light")
local Range = require("lib.light.range")
local persist = require("lib.persist")
local log = require("lib.logging")

local RUNS = tonumber(os.getenv("LIGHT_FUZZ_RUNS")) or 20000
local SEED = tonumber(os.getenv("LIGHT_FUZZ_SEED")) or 1
local ONLY = tonumber(os.getenv("LIGHT_FUZZ_RUN"))
local SHOW = tonumber(os.getenv("LIGHT_FUZZ_SHOW")) or 5

-- The error a hook raises when a run has it raise once.
local RAISE = "the hook raises once"

-- The settings the library keeps, cleared before each run so none carries into the next.
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

local SETUPS = { "setup-607.xml", "setup-626.xml", "setup-643.xml", "setup-727.xml", "setup-732.xml" }
local KINDS = { "relay", "dimmer", "white", "color", "color relay" }
local GAPS = { 0, 0, 5, 18, 60, 110, 300, 700, 1200, 2500, 6000, 15000 }
local BUTTON = { top = 0, bottom = 1, toggle = 2 }

-- The longest rate a run asks.
local MAX_RATE = 5000

local INVARIANTS = {
  { "rest", "at rest the proxy shows the device's on, level and color" },
  { "told", "the proxy is told no level the device never reached and no command asked" },
  { "flight", "at most one command in flight per aspect with ack done" },
  { "latest", "the last state asked is where the light ends, unless another hand changed it after" },
  { "errors", "no error escapes but the one a hook raises, and nothing is left refusing" },
  { "ramps", "a ramp's CHANGING starts where the light is and ends where it ends" },
  { "commands", "each command keeps to the declaration and the command's shape" },
  { "sends", "a command goes only for a proxy command, a word, a timeout or a scene step" },
  {
    "binds",
    "an unbind tells the proxy only that the light is offline, its LEDs off, a bind tells it nothing, and the first "
      .. "report after them the rest",
  },
}

--------------------------------------------------------------------------------
-- A seeded draw of its own, so nothing else that calls math.random moves a run
--------------------------------------------------------------------------------

local function rng(seed)
  local x = seed % 2147483646 + 1
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
  return r
end

--------------------------------------------------------------------------------
-- A run's light, transport and settings
--------------------------------------------------------------------------------

--- The device a run drives and how its transport behaves (H.memoryLight's options), and its settings.
local function draw(r)
  local kind = r.pick(KINDS)
  local o = {}
  o.dims = kind == "dimmer" or kind == "white" or kind == "color"
  o.color = kind == "color" or kind == "color relay"
  if kind == "white" or (o.color and r.chance(0.6)) then
    o.cct = r.pick({ { min = 2000, max = 6500 }, { min = 2700, max = 5000 } })
  end
  o.levelSteps = o.dims and r.pick({ false, 100, 254 }) or nil
  o.fade = r.pick({ "device", "device", "none" })
  o.keepsLevel = o.dims and o.fade == "device" and r.chance(0.5)
  o.policy = r.pick({ "trust", "settle", "echo" })
  -- ESPHome's model: one transition for every channel along an eased curve, each drawn alone too.
  if o.fade == "device" and r.chance(o.policy == "echo" and 0.7 or 0.3) then
    o.curve = r.chance(0.7) and "eased" or nil
    o.retimes = r.chance(0.7)
  end
  o.latency = r.pick({ 5, 20, 40, 40, 120 })
  if o.policy == "echo" then
    o.waitMs = r.pick({ false, 300, 2500 }) or nil
    o.pushEveryMs = r.chance(0.2) and r.pick({ 1000, 5000 }) or nil
    if r.chance(0.5) then
      -- send's token, as ESPHome's names what went on the wire: an off and a relay's on go as a level.
      o.tokens = true
      function o.token(cmd)
        local level = cmd.level or (cmd.on == false and 0) or (cmd.on and not o.dims and 1) or nil
        return { level = level, color = cmd.color }
      end
    end
  elseif o.policy == "settle" then
    o.readbackMs = r.pick({ 500, 1500 })
    o.reportLag = r.chance(0.3) and r.int(100, 2700) or nil
    -- An adapter's settleMs covers its read-back, its latency and its late reports.
    o.settleMs = o.readbackMs + 2 * o.latency + (o.reportLag or 0) + r.pick({ 300, 1000, 3000 })
  else
    o.news = r.chance(0.5)
    o.pushEveryMs = r.chance(0.5) and r.pick({ 500, 1000, 5000 }) or nil
  end
  o.ack = r.pick({ false, "send", "done", "done" }) or nil
  if o.ack == "done" then
    o.ackMs = r.pick({ false, 3000, 10000 }) or nil
    o.hold = r.chance(0.5)
    o.holdShare = r.chance(0.3) and r.pick({ 0.25, 0.5, 1 }) or nil
    if o.settleMs and (o.hold or o.holdShare) then
      o.settleMs = o.settleMs + MAX_RATE -- and a read that waits behind a word held to a transition's end
    end
  end
  if r.chance(0.4) then
    o.setupName = r.pick(SETUPS)
    o.setup = H.setupFile(o.setupName)
  end
  local cfg = { kind = kind, lo = 1, hi = 100 }
  if o.dims and r.chance(0.3) then
    cfg.lo, cfg.hi = r.pick({ 1, 5, 20 }), r.pick({ 100, 100, 80 })
  end
  cfg.preset = r.chance(0.3) and r.int(10, 100) or nil
  cfg.raise = r.chance(0.15) and { hook = r.pick({ "send", "refresh" }), at = r.int(1, 6) } or nil
  -- A light on a device binding the library owns, or a direct one the driver forgets at an unbind.
  o.via = r.chance(0.5) and 5002 or nil
  return o, cfg
end

--- A color the light can take: a full color, or the white of a kelvin, now and then past its range.
local function drawColor(r, o)
  if o.color and (not o.cct or r.chance(0.6)) then
    return { x = r.int(200, 600) / 1000, y = r.int(200, 500) / 1000, mode = 0 }
  end
  local range = o.cct or { min = 2000, max = 6500 }
  local x, y = C4:ColorCCTtoXY(r.int(range.min - 300, range.max + 300))
  return { x = x, y = y, mode = 1 }
end

--- A scene's steps, and how long they take with their delays.
local function drawScene(r, o)
  local steps, ms = {}, 0
  for _ = 1, r.int(1, 4) do
    local s = { delay = r.pick({ 0, 0, 300, 1500 }), rate = r.pick({ 0, 0, 500, 2000 }) }
    if r.chance(0.7) then
      s.level = r.pick({ 0, r.int(1, 100), r.int(1, 100) })
    end
    if (o.color or o.cct) and (r.chance(0.5) or not s.level) then
      s.color = drawColor(r, o)
    end
    steps[#steps + 1] = s
    ms = ms + s.delay + s.rate
  end
  return steps, ms
end

--- PUSH_SCENE, as the proxy pushes a scene's steps.
local function pushScene(proxy, id, steps, flash)
  local xml = {}
  for _, s in ipairs(steps) do
    local parts = { "<element>", "<delay>" .. s.delay .. "</delay>" }
    if s.level then
      parts[#parts + 1] = "<brightnessEnabled>True</brightnessEnabled><brightness>" .. s.level .. "</brightness>"
      parts[#parts + 1] = "<brightnessRate>" .. s.rate .. "</brightnessRate>"
    end
    if s.color then
      parts[#parts + 1] = string.format(
        "<colorEnabled>True</colorEnabled><colorX>%s</colorX><colorY>%s</colorY>"
          .. "<colorMode>%s</colorMode><colorRate>%s</colorRate>",
        s.color.x,
        s.color.y,
        s.color.mode,
        s.rate
      )
    end
    parts[#parts + 1] = "</element>"
    xml[#xml + 1] = table.concat(parts)
  end
  proxy:send(
    "PUSH_SCENE",
    { SCENE_ID = id, ELEMENTS = table.concat(xml), FLASH = flash and "True" or "False", FROM_GROUP = "False" }
  )
end

--- What a run drives, in a line.
local function describe(o, cfg)
  local parts = { cfg.kind, o.policy, "ack " .. (o.ack or "send"), "fade " .. o.fade }
  local fields = {
    "levelSteps",
    "keepsLevel",
    "curve",
    "retimes",
    "latency",
    "settleMs",
    "waitMs",
    "tokens",
    "reportLag",
    "news",
    "pushEveryMs",
    "ackMs",
    "hold",
    "holdShare",
    "setupName",
    "via",
  }
  for _, k in ipairs(fields) do
    if o[k] then
      parts[#parts + 1] = k .. " " .. tostring(o[k])
    end
  end
  if cfg.lo ~= 1 or cfg.hi ~= 100 then
    parts[#parts + 1] = string.format("range %d to %d", cfg.lo, cfg.hi)
  end
  if cfg.raise then
    parts[#parts + 1] = string.format("%s raises at call %d", cfg.raise.hook, cfg.raise.at)
  end
  return table.concat(parts, ", ")
end

local function sameXY(a, b, tolerance)
  return a ~= nil and b ~= nil and math.abs(a.x - b.x) <= tolerance and math.abs(a.y - b.y) <= tolerance
end

--- How far a color is from the segment between two others, in xy.
local function offSegment(c, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local len = dx * dx + dy * dy
  local p = len > 0 and math.max(0, math.min(1, ((c.x - a.x) * dx + (c.y - a.y) * dy) / len)) or 0
  return math.max(math.abs(c.x - (a.x + dx * p)), math.abs(c.y - (a.y + dy * p)))
end

--- Whether a value sits among values, by a margin; and the least of them.
local function within(v, values, margin)
  local lowest, highest = math.huge, -math.huge
  for _, x in ipairs(values) do
    lowest, highest = math.min(lowest, x), math.max(highest, x)
  end
  return v >= lowest - margin and v <= highest + margin, lowest
end

--------------------------------------------------------------------------------
-- What a run did and saw, by virtual time
--------------------------------------------------------------------------------

--- The device's level and color along its record: after each event, and between events along its
--- transitions.
local function timeline(run)
  local o, device = run.o, run.device
  run.samples, run.reachedAt, run.askedAt = {}, {}, {}

  --- Whether a level read from the device is the level shown, on the run's range and steps.
  function run.sameLevel(a, b)
    return Range.sameLevel(a, b, run.lo, run.hi, run.steps)
  end

  function run.levelOf(on, b)
    if not on then
      return 0
    end
    if not o.dims then
      return 100
    end
    return Range.toLevel(b, run.lo, run.hi)
  end

  local function along(s, t)
    local b, c = s.b, s.color
    if s.tr then
      local p = device:progress(s.tr, t)
      b = s.tr.from + (s.tr.to - s.tr.from) * p
    end
    if s.ctr then
      local p = device:progress(s.ctr, t)
      local from, to = s.ctr.from, s.ctr.to
      c = { x = from.x + (to.x - from.x) * p, y = from.y + (to.y - from.y) * p, mode = to.mode }
    end
    return run.levelOf(s.on, b), c
  end

  local function reach(a, b, t)
    for level = math.min(a, b), math.max(a, b) do
      run.reachedAt[level] = run.reachedAt[level] or t
    end
  end

  --- A level asked of the light at t: a proxy command's own tell, or a scene's step.
  function run.ask(level, t)
    run.askedAt[level] = run.askedAt[level] or t
  end

  function run.sample()
    local t = run.now()
    local last = run.samples[#run.samples]
    if last then
      reach(last.level, (along(last, t)), t)
    end
    local s = {
      t = t,
      on = device.on,
      b = device.level,
      tr = H.copy(device.tr),
      color = H.copy(device.color),
      ctr = H.copy(device.ctr),
    }
    s.level = (along(s, t))
    reach(s.level, s.level, t)
    if s.on ~= (last and last.on) then
      run.offSince = not s.on and t or nil
    end
    run.samples[#run.samples + 1] = s
  end

  --- The device's level and color at t: just before what happened then, or after it.
  function run.deviceBefore(t)
    for i = #run.samples, 1, -1 do
      if run.samples[i].t < t then
        return along(run.samples[i], t)
      end
    end
    return along(run.samples[1], t)
  end
  --- Whether the device was in a transition of an aspect at t.
  function run.movingAt(t, aspect)
    for i = #run.samples, 1, -1 do
      local s = run.samples[i]
      if s.t <= t then
        local tr = aspect == "level" and s.tr or s.ctr
        return tr ~= nil and t < tr.t0 + tr.dur
      end
    end
    return false
  end
  --- The level the device was heading to at t: its transition's target, or where it was.
  function run.headingAt(t)
    for i = #run.samples, 1, -1 do
      local s = run.samples[i]
      if s.t <= t then
        if s.tr then
          return s.tr.off and 0 or run.levelOf(true, s.tr.to)
        end
        return s.level
      end
    end
    return run.samples[1].level
  end
  function run.deviceAt(t)
    for i = #run.samples, 1, -1 do
      if run.samples[i].t <= t then
        return along(run.samples[i], t)
      end
    end
    return along(run.samples[1], t)
  end
end

--- The aspects a command holds by its fields: the level for a level or an on or off alone, the color
--- for a color. A color relay's scene step holds the level too, which its fields cannot tell.
local function aspectsOf(cmd)
  return { level = cmd.level ~= nil or (cmd.on ~= nil and cmd.color == nil), color = cmd.color ~= nil }
end

--- Whether an outbox unit, a command or a pre-on and its ramp, is done at t: its words, an offline, or
--- its timeout.
local function ended(u, t)
  return (u.wordsAt and u.wordsAt <= t) or (u.droppedAt and u.droppedAt <= t) or u.deadline <= t
end

--- Watch the device, the adapter's hooks, the words and what the proxy is told; judge each command as it
--- goes, and have the hook raise once where the run asks it.
local function watch(run)
  local o, m, light, clock, proxy, device = run.o, run.m, run.light, run.clock, run.proxy, run.device
  local ctx = run.ctx
  run.tells, run.sends, run.units, run.takeAt, run.preTake, run.takenAfter = {}, {}, {}, {}, {}, {}
  run.sentAt, run.sentOffline = {}, {}
  local pairing
  local raiseCalls = 0
  local perAction = {}

  local logError = log.error
  run.restoreLog = function()
    log.error = logError
  end
  log.error = function(self, fmt, ...)
    run.errors[#run.errors + 1] = "log:error " .. string.format(tostring(fmt), ...)
    return logError(self, fmt, ...)
  end

  local take, lastTake = device.take, nil
  function device.take(self, cmd, t)
    local st = self:state(t)
    run.takeAt[cmd.seq], run.preTake[cmd.seq] = t, { level = run.levelOf(st.on, st.level), color = st.color }
    run.takenAfter[cmd.seq], lastTake = lastTake == t, t -- another taken at the same instant, before it
    -- One sent before the device was lost that lands after it is a change the library did not send, and so
    -- is one sent while the light was offline: "the command judged as for an on/off light".
    local foreign = run.sentOffline[cmd.seq]
    for _, f in ipairs(run.faults) do
      local lost = f.what == "offline" or f.what == "unbind" or f.what == "rebind"
      foreign = foreign or (lost and (run.sentAt[cmd.seq] or t) <= f.at and f.at <= t)
    end
    if foreign then
      run.hands[#run.hands + 1] = { at = t, level = cmd.on ~= nil or cmd.level ~= nil, color = cmd.color ~= nil }
    end
    return take(self, cmd, t)
  end
  local at = clock.at
  clock.at = function(ms, fn)
    return at(ms, function()
      fn()
      run.sample()
    end)
  end

  -- A raise inside the kit's own word handler would stop its transport, not the library.
  local function raiseNow(hook)
    if not (run.cfg.raise and run.cfg.raise.hook == hook) or ctx.done then
      return false
    end
    raiseCalls = raiseCalls + 1
    if raiseCalls ~= run.cfg.raise.at then
      return false
    end
    run.fault(hook .. " raises")
    if hook == "send" then
      pairing = nil -- a pre-on whose ramp's send raised has no ramp
    end
    return true
  end

  local function check(cmd, c, t)
    run.checked.commands, run.checked.sends = true, true
    local function shape(okay, what)
      if not okay then
        run.violate("commands", "%s: %s at %d", what, T.show(cmd), t)
      end
    end
    if proxy.online then
      -- "Nothing the declaration rules out: no color to a light with neither color nor cct, a kelvin only
      -- to a light that declared cct, no pre-on unless fade.preOn and dims." In a command "mode 1 always
      -- carries its kelvin".
      shape(cmd.color == nil or run.hasColor, "a color to a light with neither color nor cct")
      shape(not (cmd.color and cmd.color.kelvin) or o.cct, "a kelvin to a light with no cct")
      shape(not (cmd.color and cmd.color.mode == 1) or cmd.color.kelvin, "mode 1 with no kelvin")
      shape(not cmd.preOn or (o.dims and o.keepsLevel), "a pre-on the declaration rules out")
      -- "`fade.by = "none"`: no level moves. A light that dims takes every change at once"
      shape(not (o.dims and o.fade == "none") or (cmd.ms or 0) == 0, "a rate to a light that dims and does not fade")
      -- "A light that does not dim switches with no ms, but for a scene step, which keeps its rate."
      shape(o.dims or cmd.color ~= nil or cmd.ms == nil or run.sceneMayAsk(t), "a rate on a relay's switch")
    else
      -- "The light takes no command until its device's next state": nothing goes while it is offline
      -- (T3 sent the command judged as for an on/off light).
      shape(false, "a command while the light is offline")
    end
    -- "A level only with on = true"
    shape(cmd.level == nil or (cmd.on == true and cmd.level >= 0 and cmd.level <= 1), "a level without on = true")
    -- "One command per change: the only pair is a pre-on and its ramp."
    if ctx.proxy and not ctx.scene and not cmd.preOn then
      local n = perAction[ctx.action] or { level = 0, color = 0 }
      perAction[ctx.action] = n
      local asp = aspectsOf(cmd)
      n.level, n.color = n.level + (asp.level and 1 or 0), n.color + (asp.color and 1 or 0)
      shape(n.level <= 1 and n.color <= 1, "a second command for one change")
    end
    -- "A ramp's end sends nothing": a command goes for a proxy command, a word, a timeout or a scene step.
    local atTimeout = false
    for _, u in ipairs(run.units) do
      atTimeout = atTimeout or (u.deadline == t and not (u.wordsAt and u.wordsAt < t) and not u.droppedAt)
    end
    if not (ctx.proxy or ctx.done or atTimeout or run.sceneActive(t)) then
      run.violate("sends", "a command with nothing to send it: %s at %d", T.show(cmd), t)
    end
    -- "At most one command in flight per aspect with ack = "done""
    if o.ack == "done" and proxy.online then
      run.checked.flight = true
      local asp = aspectsOf(cmd)
      local u
      if pairing and pairing.at == t and not cmd.preOn then
        u, pairing = pairing, nil
        u.aspects.color = u.aspects.color or asp.color
      else
        if pairing then
          shape(false, "a pre-on with no ramp after it")
          pairing = nil
        end
        for _, other in ipairs(run.units) do
          local both = (asp.level and other.aspects.level) or (asp.color and other.aspects.color)
          if both and not ended(other, t) then
            run.violate(
              "flight",
              "%s at %d while %s, sent at %d, is in flight",
              T.show(cmd),
              t,
              T.show(other.cmd),
              other.at
            )
          end
        end
        u = { at = t, aspects = asp, seqs = {}, words = {}, cmd = c, idx = #run.sends }
        run.units[#run.units + 1] = u
        if cmd.preOn then
          pairing = u
        end
      end
      u.seqs[cmd.seq], u.epoch = true, cmd.epoch
      u.deadline = t + math.floor(1.5 * (cmd.ms or 0) + run.ackMs)
    end
  end

  local adapter = m.adapter
  local send, refresh = adapter.send, adapter.refresh
  function adapter.send(a, cmd)
    if raiseNow("send") then
      error(RAISE, 0)
    end
    local t = run.now()
    local c = H.copy(cmd)
    c.at, c.action = t, ctx.action
    run.sends[#run.sends + 1], run.sentAt[cmd.seq] = c, t
    run.sentOffline[cmd.seq] = not proxy.online
    run.step("%d:   send %s", t, cmd)
    if m.failNext and o.ack == "done" then
      run.fault("a command is lost", t)
    end
    check(cmd, c, t)
    return send(a, cmd)
  end
  function adapter.refresh(a)
    if raiseNow("refresh") then
      error(RAISE, 0)
    end
    run.step("%d:   refresh", run.now())
    return refresh(a)
  end
  function light.report(self, state, meta)
    local rep, before = run.m.reports[#run.m.reports], #run.tells
    local verdict = Light.report(self, state, meta)
    run.step("%d:   report %s %s: %s", run.now(), state, meta, verdict)
    if rep then
      rep.told = { unpack(run.tells, before + 1) } -- what this report told the proxy
      rep.verdict = verdict
    end
    return verdict
  end
  function light.done(self, seq, okay, epoch)
    local t = run.now()
    run.step("%d:   word %s %s %s", t, seq, okay, epoch)
    for _, u in ipairs(run.units) do
      if not ended(u, t) and u.seqs[seq] and epoch == u.epoch then
        u.words[seq] = true
        local all = true
        for s in pairs(u.seqs) do
          all = all and u.words[s]
        end
        u.wordsAt = all and t or nil
      end
    end
    ctx.done = true
    local ran, e = pcall(Light.done, self, seq, okay, epoch)
    ctx.done = false
    if not ran then
      error(e, 0)
    end
  end

  -- What the proxy is told, and what the run was doing then: a proxy command's own tells are what it asks.
  local sendToProxy = C4.SendToProxy
  C4.SendToProxy = function(self, id, cmd, params, ...)
    if ctx.binding then
      local said = run.bound[ctx.action] or {}
      run.bound[ctx.action] = said
      said[#said + 1] = { id = id, cmd = cmd, params = H.copy(params) }
    end
    if id == H.PROXY and type(params) == "table" then
      local t = run.now()
      if cmd:find("^LIGHT_") then
        run.step("%d:     tell %s %s", t, cmd, params)
      end
      local tell = { at = t, cmd = cmd, params = H.copy(params), action = ctx.action, asked = ctx.asks }
      tell.sends = #run.sends
      run.tells[#run.tells + 1] = tell
      if ctx.asks then
        if cmd == "LIGHT_BRIGHTNESS_CHANGED" then
          run.lastAsk.level = { level = params.LIGHT_BRIGHTNESS_CURRENT, at = t, action = ctx.action }
          run.ask(params.LIGHT_BRIGHTNESS_CURRENT, t)
        elseif cmd == "LIGHT_BRIGHTNESS_CHANGING" and (params.RATE or 0) > 0 then
          run.lastAsk.level = { level = params.LIGHT_BRIGHTNESS_TARGET, at = t, action = ctx.action }
          run.ask(params.LIGHT_BRIGHTNESS_TARGET, t)
        elseif cmd == "LIGHT_COLOR_CHANGED" or cmd == "LIGHT_COLOR_CHANGING" then
          local changed = cmd == "LIGHT_COLOR_CHANGED"
          if ctx.colorAsk then
            run.lastAsk.color = {
              x = changed and params.LIGHT_COLOR_CURRENT_X or params.LIGHT_COLOR_TARGET_X,
              y = changed and params.LIGHT_COLOR_CURRENT_Y or params.LIGHT_COLOR_TARGET_Y,
              mode = changed and params.LIGHT_COLOR_CURRENT_COLOR_MODE or params.LIGHT_COLOR_TARGET_COLOR_MODE,
              at = t,
              action = ctx.action,
            }
          else
            -- A color a level command or a stop tells, an on cycle's or an on mode's, is no color asked,
            -- though it moves the color told after one.
            run.colorToldAt = t
          end
        end
      end
    end
    return sendToProxy(self, id, cmd, params, ...)
  end
end

--------------------------------------------------------------------------------
-- What a run does
--------------------------------------------------------------------------------

--- One step of the run: a proxy command, another hand, or the transport.
local function act(run, kind, name, fn, flags)
  flags = flags or {}
  local ctx = run.ctx
  local a = {
    id = #run.actions + 1,
    kind = kind,
    name = name,
    at = run.now(),
    online = run.proxy.online == true,
    pressAt = flags.pressAt,
    scene = flags.scene,
    binding = flags.binding,
    heard = #run.m.reports,
  }
  run.actions[a.id] = a
  run.step("%d: %s", a.at, name)
  ctx.action, ctx.proxy, ctx.scene, ctx.binding = a.id, kind == "proxy", flags.scene, flags.binding
  ctx.asks = kind == "proxy" and not flags.read
  ctx.colorAsk = name:find("^SET_COLOR_") ~= nil
  local ran, e = pcall(fn)
  ctx.action, ctx.proxy, ctx.scene, ctx.binding, ctx.asks, ctx.colorAsk = nil, nil, nil, nil, nil, nil
  if not ran then
    a.raised = true
    run.raised(e)
  end
  run.sample()
  return a
end

local function command(run, cmd, params, flags)
  return act(run, "proxy", cmd .. (params and (" " .. T.show(params)) or ""), function()
    run.proxy:send(cmd, params)
  end, flags)
end

local function link(run, binding, cmd, flags)
  return act(run, "proxy", cmd .. " on link " .. binding, function()
    RFP[cmd](binding, cmd, {}, {})
  end, flags)
end

local function lost(run)
  run.fault("offline")
  for _, u in ipairs(run.units) do
    u.droppedAt = u.droppedAt or run.now()
  end
  run.offline = true
  act(run, "transport", "the device is lost", run.m.drop)
end

local function back(run)
  run.fault("back")
  run.offline = false
  act(run, "transport", "the device is back", run.m.back)
end

--- The device binding unbound, bound, or both at once, as Director binds it at every controller start.
local function unbind(run, what)
  run.fault(what)
  for _, u in ipairs(run.units) do
    u.droppedAt = u.droppedAt or run.now()
  end
  run.offline, run.unbound = what == "unbind", what == "unbind"
  act(run, "transport", "the device binding: " .. what, function()
    run.m.unbind()
    if what == "rebind" then
      run.m.bind()
    end
  end, { binding = what })
end

local function bind(run)
  run.fault("bind")
  run.offline, run.unbound = false, false
  act(run, "transport", "the device binding: bind", run.m.bind, { binding = "bind" })
end

local function colorParams(run, rateMs)
  local c = drawColor(run.r, run.o)
  return {
    LIGHT_COLOR_TARGET_X = c.x,
    LIGHT_COLOR_TARGET_Y = c.y,
    LIGHT_COLOR_TARGET_MODE = c.mode,
    LIGHT_COLOR_TARGET_COLOR_RATE = rateMs,
  }
end

--- What a run can do, each with its weight.
local function moves(run)
  local r, o, m, device = run.r, run.o, run.m, run.device
  local function rate()
    return r.pick({ 0, 0, 250, 750, 2000, MAX_RATE })
  end
  local function level()
    return r.pick({ 0, 1, 100, r.int(1, 100), r.int(1, 100), r.int(1, 100) })
  end
  local hasColor = run.hasColor
  return {
    {
      6,
      function()
        command(run, "SET_LEVEL", { LEVEL = level() })
      end,
    },
    {
      8,
      function()
        command(run, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level(), RATE = rate() })
      end,
    },
    {
      2,
      function()
        command(run, "RAMP_TO_LEVEL", { LEVEL = level(), TIME = rate() })
      end,
    },
    {
      4,
      function()
        command(run, r.pick({ "ON", "ON", "DYNAMIC_ON" }))
      end,
    },
    {
      4,
      function()
        command(run, r.pick({ "OFF", "OFF", "DYNAMIC_OFF" }))
      end,
    },
    {
      2,
      function()
        command(run, "TOGGLE")
      end,
    },
    {
      hasColor and 6 or 1,
      function()
        command(run, "SET_COLOR_TARGET", colorParams(run, rate()))
      end,
    },
    {
      hasColor and 1 or 0,
      function()
        -- The Control4 app's On: a level over 750 ms, then its color 18 ms later.
        command(run, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = r.int(1, 100), RATE = 750 })
        run.advance(18)
        command(run, "SET_COLOR_TARGET", colorParams(run, 750))
      end,
    },
    {
      3,
      function()
        command(run, "SET_BRIGHTNESS_STOP")
      end,
    },
    {
      hasColor and 2 or 0,
      function()
        command(run, "SET_COLOR_STOP")
      end,
    },
    {
      3,
      function()
        -- A click: PRESS at button-down and the release about 110 ms later, from the proxy or a link.
        local which, pressAt = r.pick({ "top", "bottom", "toggle" }), run.now()
        if r.chance(0.5) then
          command(run, "BUTTON_ACTION", { BUTTON_ID = BUTTON[which], ACTION = 1 })
          run.advance(110)
          command(run, "BUTTON_ACTION", { BUTTON_ID = BUTTON[which], ACTION = 2 }, { pressAt = pressAt })
        else
          link(run, H.LINKS[which], "DO_PUSH")
          run.advance(110)
          link(run, H.LINKS[which], "DO_CLICK", { pressAt = pressAt })
        end
      end,
    },
    {
      2,
      function()
        local which = r.pick({ "top", "bottom", "toggle" })
        command(run, "BUTTON_ACTION", { BUTTON_ID = BUTTON[which], ACTION = 1 })
        run.advance(r.pick({ 300, 1000, 2500, 4000 }))
        command(run, "BUTTON_ACTION", { BUTTON_ID = BUTTON[which], ACTION = 0 })
      end,
    },
    {
      2,
      function()
        local id = r.int(1, 2)
        local scene = run.scenes[id]
        for _, s in ipairs(scene.steps) do
          if s.level then
            -- Offline a step is judged as for an on/off light.
            run.ask(s.level, run.now())
            run.ask(s.level > 0 and 100 or 0, run.now())
          end
        end
        run.sceneUntil = scene.flash and math.huge or run.now() + scene.ms + 50
        run.sceneFrom = run.sceneFrom or run.now()
        command(run, "ACTIVATE_SCENE", { SCENE_ID = id }, { scene = true })
      end,
    },
    {
      1,
      function()
        local cmd = r.pick({ "RAMP_SCENE_UP", "RAMP_SCENE_DOWN", "STOP_SCENE_RAMP", "DEACTIVATE_SCENE" })
        local a = command(run, cmd, { SCENE_ID = r.int(1, 2), RATE = rate() })
        -- One whose send raised leaves the model, the scene run among it, as it was.
        if (cmd == "DEACTIVATE_SCENE" or cmd == "STOP_SCENE_RAMP") and not a.raised then
          run.sceneUntil = math.min(run.sceneUntil, run.now())
        end
      end,
    },
    {
      1,
      function()
        command(run, "GET_LIGHT_LEVEL", nil, { read = true })
      end,
    },
    {
      hasColor and 1 or 0,
      function()
        -- The Color On Mode as the proxy pushes it: a preset, Previous, or none.
        local c, kind = drawColor(r, o), r.pick({ "none", "preset", "previous" })
        local set = kind ~= "none"
        run.onModeSet = true
        command(run, "UPDATE_COLOR_ON_MODE", {
          COLOR_PRESET_ID = kind == "previous" and 10 or set and 1 or 0,
          COLOR_PRESET_ORIGIN = set and 1 or 0,
          COLOR_PRESET_COLOR_X = set and c.x or nil,
          COLOR_PRESET_COLOR_Y = set and c.y or nil,
          COLOR_PRESET_COLOR_MODE = set and c.mode or nil,
          COLOR_FADE_PRESET_ID = 0,
          COLOR_FADE_PRESET_ORIGIN = 0,
        })
      end,
    },
    {
      6,
      function()
        -- Another hand, at the wall or in the device's own app.
        local st, quiet = {}, false
        local roll = r.int(1, 4)
        if not o.dims then
          st.on = not device.on
        elseif roll == 1 then
          st.on = false
        else
          st.on, st.level = true, r.int(1, 100) / 100
          -- Quiet only for a turn-on whose off was heard first: settle answers it with a read.
          local offFor = run.offSince and run.now() - run.offSince or 0
          quiet = not device.on
            and o.policy == "settle"
            and offFor > (o.reportLag or 0) + 2 * o.latency + 1100
            and r.chance(0.3)
        end
        if hasColor and (roll == 4 or r.chance(0.2)) then
          if r.chance(0.5) then
            st, quiet = {}, false
          end
          st.color = drawColor(r, o)
        end
        local hand = { at = run.now(), level = st.on ~= nil or st.level ~= nil, color = st.color ~= nil }
        hand.quiet = quiet
        run.hands[#run.hands + 1] = hand
        act(run, "hand", "another hand " .. T.show(st) .. (quiet and " quietly" or ""), function()
          m.other(st, quiet)
        end)
      end,
    },
    {
      1,
      function()
        if run.unbound then
          bind(run)
        elseif run.offline then
          back(run)
        else
          lost(run)
        end
      end,
    },
    {
      1,
      function()
        if run.offline then
          bind(run)
        else
          unbind(run, r.pick({ "unbind", "rebind" }))
        end
      end,
    },
    {
      o.ack == "done" and 2 or 0,
      function()
        local what = r.pick({ "loseNext", "loseNext", "failNext", "foreignNext", "stall" })
        run.fault(what)
        act(run, "transport", what, function()
          if what == "stall" then
            m.stall(run.now() + r.pick({ 2000, 10000, 25000 }), 0)
          elseif what == "failNext" then
            m.dropNext, m.failNext = true, true
          else
            m[what] = true
          end
        end)
      end,
    },
  }
end

--------------------------------------------------------------------------------
-- The invariants, judged once the run is at rest
--------------------------------------------------------------------------------

--- Reports made before the device took a command, and heard after the command went: under trust one is
--- told, trust's own limit, and under settle one can settle a window on the target it happens to hold. One
--- made as the device took the command may be another's taken just before it. Under echo one of another
--- hand's change is "another hand's, told at once", and the light heads for it until that command's echo:
--- each such span is listed too.
local function crossings(run)
  local out, hands = {}, {}
  for _, rep in ipairs(run.m.reports) do
    local made = rep.at - run.o.latency
    for _, s in ipairs(run.sends) do
      local took = run.takeAt[s.seq] or (s.at + run.o.latency)
      local before = took > made or (took == made and run.takenAfter[s.seq])
      local crossed = s.at <= rep.at and before and rep.at > run.t0
      if crossed and not (run.o.policy == "settle" and rep.meta.answer) then
        out[#out + 1] = rep.at
        local v = rep.verdict or {}
        if (v.level and v.level.kind == "hand") or (v.color and v.color.kind == "hand") then
          hands[#hands + 1] = { from = rep.at, to = took + run.o.latency + 5 }
        end
        break
      end
    end
  end
  return out, hands
end

--- Settle: "a report settles it on an answer saying off, the final answers for each control the command
--- set, or a report of the target; anything else is held and shown when the window ends". Trust: a report
--- of a ramp's own aspect is "ignored during the ramp and otherwise told when it differs". So at rest the
--- proxy shows the device.
local function judgeRest(run)
  local proxy, final = run.proxy, run.final
  run.checked.rest = true
  if proxy.online ~= true then
    run.violate("rest", "the proxy is told the light is offline at rest")
  end
  local shown = proxy.level or -1
  if not (run.endsAt(shown) or run.unread) then
    run.violate("rest", "the proxy shows %s at rest, the device is at %s", tostring(proxy.level), run.endLevel)
  end
  -- The proxy shows the color a CHANGING heads for once its rate has run, as it steps a level along one.
  local color = proxy.color
  for _, tell in ipairs(run.tells) do
    local q = tell.params
    if tell.cmd == "LIGHT_COLOR_CHANGED" then
      color = { x = q.LIGHT_COLOR_CURRENT_X, y = q.LIGHT_COLOR_CURRENT_Y, mode = q.LIGHT_COLOR_CURRENT_COLOR_MODE }
    elseif tell.cmd == "LIGHT_COLOR_CHANGING" then
      color = { x = q.LIGHT_COLOR_TARGET_X, y = q.LIGHT_COLOR_TARGET_Y, mode = q.LIGHT_COLOR_TARGET_COLOR_MODE }
    end
  end
  if
    run.hasColor
    and not run.colorUnread
    and not (sameXY(color, final.color, 0.01) and color.mode == final.color.mode)
  then
    run.violate("rest", "the proxy shows the color %s at rest, the device is in %s", T.show(color), T.show(final.color))
  end
end

--- "One command per change: the only pair is a pre-on and its ramp. With ack = "done" a change can also
--- send nothing, when a newer one replaces it before it goes." So the last state asked is where the light
--- ends, unless another hand changed it after, or the transport lost the command.
local function judgeLatest(run)
  local o, final = run.o, run.final
  -- A change the library cannot have heard of by the ask came after it: a report takes the latency, under
  -- settle a level report can wait levelMinMs and a late one reportLag more, with ack = "done" one heard
  -- before a word owed is history until the word, and under trust one in a ramp of its aspect is ignored
  -- until the first report after the ramp's end.
  local hearMs = o.latency + 5 + (o.policy == "settle" and (1000 + (o.reportLag or 0)) or 0)
  local function heardAt(h)
    local at = h.at + hearMs
    for _, u in ipairs(run.units) do
      if u.at <= h.at and not ended(u, h.at) then
        at = math.max(at, math.min(u.wordsAt or math.huge, u.droppedAt or math.huge, u.deadline) + hearMs)
      end
    end
    for _, tell in ipairs(run.tells) do
      local q = tell.params
      local level, color = tell.cmd == "LIGHT_BRIGHTNESS_CHANGING", tell.cmd == "LIGHT_COLOR_CHANGING"
      local rate = (level and q.RATE) or (color and q.LIGHT_COLOR_TARGET_COLOR_RATE) or 0
      local mine = (level and h.level) or (color and h.color)
      if o.policy == "trust" and mine and rate > 0 and tell.at <= h.at and h.at < tell.at + rate + o.latency then
        local next = math.huge
        for _, rep in ipairs(run.m.reports) do
          if rep.at > tell.at + rate and rep.at < next then
            next = rep.at
          end
        end
        at = math.max(at, next)
      end
    end
    return at
  end
  local function void(t, aspect)
    -- Under settle a crossing report can settle the ask's window on the target it holds.
    for _, at in ipairs(run.crossed) do
      if o.policy == "trust" or at >= t then
        return true
      end
    end
    for _, span in ipairs(run.crossedHands) do
      if o.policy == "echo" and span.from <= t and t <= span.to then
        return true
      end
    end
    -- A transition the device took before it was lost runs on past it, unknown to the light it seeds again.
    for _, s in ipairs(run.sends) do
      local took, ms = run.takeAt[s.seq], s.ms or 0
      for _, f in ipairs(run.faults) do
        local lost = f.what == "offline" or f.what == "unbind" or f.what == "rebind"
        if lost and took and took <= f.at and f.at < took + ms and took + ms + hearMs >= t then
          return true
        end
      end
    end
    for _, h in ipairs(run.hands) do
      if h[aspect] and heardAt(h) >= t then
        return true
      end
    end
    for _, f in ipairs(run.faults) do
      local delays = f.what == "loseNext" or f.what == "foreignNext" or f.what == "stall" or f.what == "failNext"
      if f.at >= t and not delays then
        return true
      end
      -- A command the transport lost may be one the ask leaned on while it was in flight.
      if f.what == "a command is lost" and f.at + run.ackMs + 1.5 * MAX_RATE >= t then
        return true
      end
    end
    return false
  end
  local la = run.lastAsk.level
  if la and run.actions[la.action].online and not void(la.at, "level") and run.sceneUntil < la.at then
    run.checked.latest = true
    if not run.endsAt(la.level) then
      local name = run.actions[la.action].name
      local level = run.endLevel
      run.violate(
        "latest",
        "the last level asked is %s (%s at %d), the device ends at %s",
        la.level,
        name,
        la.at,
        level
      )
    end
  end
  local lc = run.lastAsk.color
  if not (run.hasColor and lc and run.actions[lc.action].online) then
    return
  end
  -- An on mode's color can ride a later level command, and a scene's step can set one.
  local later = false
  for _, a in ipairs(run.actions) do
    later = later or (run.onModeSet and a.id > lc.action and a.kind == "proxy")
  end
  if later or void(lc.at, "color") or run.sceneUntil >= lc.at or run.colorToldAt >= lc.at then
    return
  end
  run.checked.latest = true
  if not (sameXY(lc, final.color, 0.01) and lc.mode == final.color.mode) then
    local name = run.actions[lc.action].name
    run.violate(
      "latest",
      "the last color asked is %s (%s at %d), the device ends in %s",
      T.show(lc),
      name,
      lc.at,
      T.show(final.color)
    )
  end
end

--- "Control4 is told only from the library's model, never straight from a report." So no level is told
--- that the device never reached and no command asked.
local function judgeTold(run)
  local slack = Range.slack(run.lo, run.hi, run.steps)
  for _, tell in ipairs(run.tells) do
    local level
    if tell.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
      level = tell.params.LIGHT_BRIGHTNESS_CURRENT
    elseif tell.cmd == "LIGHT_BRIGHTNESS_CHANGING" and (tell.params.RATE or 0) > 0 then
      level = tell.params.LIGHT_BRIGHTNESS_TARGET
    end
    if level and not tell.asked and tell.at < run.unreadAt then
      run.checked.told = true
      local seen = run.askedAt[level] and run.askedAt[level] <= tell.at
      local near = level == 0 and 0 or slack + 1
      -- The model leads the device by the latency. Under echo a report is "of its targets", so a level told
      -- from one may be where the device was heading when it made it.
      local heading = run.o.policy == "echo" and not tell.asked and run.headingAt(tell.at - run.o.latency)
      for l = math.max(0, level - near), math.min(100, level + near) do
        local reached = run.reachedAt[l]
        seen = seen or ((l > 0) == (level > 0) and reached and reached <= tell.at + run.o.latency + 5)
        seen = seen or ((l > 0) == (level > 0) and heading == l)
      end
      -- The proxy is told an offline light is off.
      for _, f in ipairs(run.faults) do
        seen = seen or (level == 0 and f.what == "offline" and f.at == tell.at)
      end
      if not seen then
        run.violate("told", "%s %s at %d: the device never reached it, no command asked it", tell.cmd, level, tell.at)
      end
    end
  end
end

--- "`fade.by = "device"`: the device fades itself over each command's `ms`, along a line." So a ramp's
--- CHANGING starts where the light is and ends where it ends; and under "none" a light that dims is
--- "told as CHANGED only". It is judged where the light is in step with the model: no word owed on an
--- older command, and nothing from another hand or the transport the model may not have heard yet.
local function judgeRamps(run)
  local o, slack = run.o, Range.slack(run.lo, run.hi, run.steps)

  --- Whether a command moves an aspect: on a device that re-times every command runs both on.
  local function moves(s, aspect)
    return o.retimes or aspectsOf(s)[aspect]
  end

  --- The command a CHANGING's ramp went as: the one sent over its rate just before it was told, which on a
  --- device that re-times may set the other aspect, else the first of its aspect after, as for one that waited.
  local function sentFor(tell, aspect)
    local own
    local q = tell.params
    local rate = aspect == "level" and q.RATE or q.LIGHT_COLOR_TARGET_COLOR_RATE
    for i, s in ipairs(run.sends) do
      if not s.preOn then
        if
          i <= tell.sends
          and moves(s, aspect)
          and s.action == tell.action
          and s.at == tell.at
          and (s.ms or 0) == rate
        then
          own = s
        elseif i > tell.sends and aspectsOf(s)[aspect] then
          return own or s
        end
      end
    end
    return own
  end

  local handLookback = (o.settleMs or 0) + 3 * MAX_RATE + 5000
  if o.policy == "trust" and not (o.news or o.pushEveryMs) then
    handLookback = math.huge -- trust shows a change during a ramp only with the next report
  end
  local faultLookback = (o.ack == "done" and run.ackMs or 0) + 3 * MAX_RATE + (o.settleMs or 0) + 5000
  local function since(times, t, lookback)
    for _, at in ipairs(times) do
      if at <= t and at >= t - lookback then
        return true
      end
    end
    return false
  end
  -- "put a LightCommand on the wire, or queue it, and return": a queued frame is taken late, and a ramp the
  -- device takes while it runs a late one's line starts from where that line has it, not the model's.
  local ownLine, newest = {}, {}
  for _, s in ipairs(run.sends) do
    local took = run.takeAt[s.seq]
    local own = not s.action or (took ~= nil and took > s.at + o.latency + 1)
    local asp = aspectsOf(s)
    for _, aspect in ipairs({ "level", "color" }) do
      local prev = newest[aspect]
      own = own
        or ((o.retimes or asp[aspect]) and took ~= nil and prev ~= nil and prev.own and took < prev.took + prev.ms)
    end
    ownLine[s.seq] = own
    for _, aspect in ipairs({ "level", "color" }) do
      if (o.retimes or asp[aspect]) and took then
        newest[aspect] = { took = took, ms = s.ms or 0, own = own }
      end
    end
  end

  --- Whether the newest tell of an aspect before this one came from a report the device made in a transition.
  local function toldOnTheWay(tell, aspect)
    local changed = aspect == "level" and "LIGHT_BRIGHTNESS_CHANGED" or "LIGHT_COLOR_CHANGED"
    local changing = aspect == "level" and "LIGHT_BRIGHTNESS_CHANGING" or "LIGHT_COLOR_CHANGING"
    local last
    for _, other in ipairs(run.tells) do
      if other == tell then
        break
      elseif other.cmd == changed or other.cmd == changing then
        last = other
      end
    end
    if not (last and last.cmd == changed and last.action == nil) then
      return false
    end
    for _, rep in ipairs(run.m.reports) do
      if rep.at == last.at and run.movingAt(rep.at - o.latency, aspect) then
        return true
      end
    end
    return false
  end

  local function inStep(tell, aspect)
    local t = tell.at
    if t <= run.t0 or since(run.crossed, t, o.policy == "trust" and math.huge or faultLookback) then
      return false
    end
    -- Offline nothing reaches the device, and back the device is the first report's.
    local offline = false
    for _, f in ipairs(run.faults) do
      local gone = f.what == "offline" or f.what == "unbind"
      local again = f.what == "back" or f.what == "bind" or f.what == "rebind"
      if f.at <= t and (gone or again) then
        offline = gone or f.at > t - faultLookback
      end
    end
    if offline then
      return false
    end
    -- A change by another hand the device takes before the ramp's command is no part of it either.
    for _, h in ipairs(run.hands) do
      if h.at <= t + o.latency + 50 and h.at >= t - handLookback then
        return false
      end
    end
    for _, f in ipairs(run.faults) do
      if f.at <= t and f.at >= t - faultLookback then
        return false
      end
    end
    -- A word owed on a command sent before the ramp's own, at the same time too.
    local own = sentFor(tell, aspect)
    for _, u in ipairs(run.units) do
      if u.idx <= tell.sends and not (own and u.seqs[own.seq]) and not ended(u, t) then
        return false
      end
    end
    -- A command that waited goes with the time its rate has left, and one the transport held behind
    -- another frame starts late: either way the device runs a line of its own, and so does a ramp that
    -- replaces it on that line.
    for _, s in ipairs(run.sends) do
      local took = run.takeAt[s.seq] or s.at
      if ownLine[s.seq] and (s.ms or 0) > 0 and s.at <= t and t < took + s.ms + 50 then
        return false
      end
    end
    -- Trust: "A report of a ramp's own aspect is ignored during the ramp and otherwise told when it differs",
    -- so one the device made on its way, heard once the ramp Control4 was told has ended, shows until the next.
    if o.policy == "trust" and toldOnTheWay(tell, aspect) then
      return false
    end
    return true
  end

  --- Whether anything but the ramp moves the light in (from, to]: a later step, another hand, the
  --- transport, or a scene.
  local function disturbed(from, to, action)
    for _, a in ipairs(run.actions) do
      if a.id ~= action and a.at > from - 1 and a.at <= to and a.id > (action or 0) then
        return true
      end
    end
    return run.sceneActive(from) or run.sceneActive(to)
  end

  -- A scene step's color at once is told with the device's report of it, so a color ramp before that
  -- report starts from the color told before.
  local function sceneColor(t)
    local wait = (o.settleMs or 0) + 2 * o.latency + (o.reportLag or 0) + 1000
    return t <= run.sceneUntil + wait and t >= (run.sceneFrom or math.huge)
  end

  -- A light coming on from off is told its on color at once, while a device that fades its color from
  -- dark gets there over the on's rate: its color then is no one's to see.
  local function offWithin(t)
    if (run.deviceBefore(t - MAX_RATE - o.latency)) == 0 then
      return true
    end
    for _, s in ipairs(run.samples) do
      if s.t >= t - MAX_RATE - o.latency and s.t <= t + o.latency and s.level == 0 then
        return true
      end
    end
    return false
  end

  -- Re-timed, "a color for a light off or fading to off goes over the time the fade has left, told at
  -- once": the light is not in it until then.
  local function darkColor(t)
    for _, s in ipairs(run.sends) do
      local took = run.takeAt[s.seq] or s.at
      if o.retimes and s.color and s.on == false and s.at <= t and t < took + (s.ms or 0) + o.latency then
        return true
      end
    end
    return false
  end

  --- When the device ends the command a CHANGING went as, and whether the run is still on by then.
  local function endOf(tell, s, rate)
    local stop = s and run.takeAt[s.seq] and run.takeAt[s.seq] + (s.ms or 0) + 5
    if not s then
      stop = tell.at + rate + o.latency + 5
    end
    return stop and stop < run.now() and not disturbed(tell.at, stop + 1, tell.action) and stop
  end

  for _, tell in ipairs(run.tells) do
    local q = tell.params
    -- A click's ramp starts where its press found the light, and the ramps that replace it inherit that
    -- start until one has run its time: in step only where the press was, with no word owed, and off
    -- the light by as far as the press's own ramp took it before the click.
    local presses, pressInStep, drift = {}, true, 0
    for _, a in ipairs(run.actions) do
      if a.pressAt and a.at <= tell.at and a.at >= tell.at - 1000 - MAX_RATE then
        presses[#presses + 1] = a.pressAt
        local found, clicked = run.deviceBefore(a.pressAt + o.latency + 1), run.deviceBefore(a.at + o.latency + 1)
        drift = math.max(drift, math.abs(found - clicked))
        for _, u in ipairs(run.units) do
          pressInStep = pressInStep and not (u.at <= a.pressAt and not ended(u, a.pressAt))
        end
      end
    end
    if tell.cmd == "LIGHT_BRIGHTNESS_CHANGING" and (q.RATE or 0) > 0 then
      if o.dims and o.fade == "none" then
        run.violate("ramps", "a light that dims and does not fade is told CHANGING at %d", tell.at)
      end
      if pressInStep and inStep(tell, "level") then
        run.checked.ramps = true
        local s = sentFor(tell, "level")
        -- Where the light is: a latency on, as the device runs the model's commands a latency late, up to
        -- its take of the ramp's command, after what went before at the same time, and from a click's press.
        local values = { (run.deviceBefore(tell.at + o.latency)) }
        if s and run.preTake[s.seq] then
          values[#values + 1] = run.preTake[s.seq].level
        end
        local lastTake
        for i = 1, tell.sends do
          local tk = run.takeAt[run.sends[i].seq]
          if tk and tk >= tell.at and (not lastTake or tk > lastTake) then
            lastTake = tk
          end
        end
        if lastTake then
          values[#values + 1] = (run.deviceAt(lastTake))
        end
        for _, pressAt in ipairs(presses) do
          values[#values + 1] = (run.deviceBefore(pressAt + o.latency + 1))
        end
        local from, to = q.LIGHT_BRIGHTNESS_CURRENT, q.LIGHT_BRIGHTNESS_TARGET
        local fits, lowest = within(from, values, slack + 1 + drift)
        -- A light on its way up from off is told from 1, lit by its pre-on.
        if not (fits or (from == 1 and lowest <= 1 and to > 0)) then
          run.violate(
            "ramps",
            "CHANGING from %s to %s at %d while the device is at %s",
            from,
            to,
            tell.at,
            T.show(values)
          )
        end
        local stop = endOf(tell, s, q.RATE)
        local there = stop and (run.deviceAt(stop))
        if there and not run.sameLevel(there, to) then
          run.violate("ramps", "CHANGING to %s at %d: the device is at %s at its end, %d", to, tell.at, there, stop)
        end
      end
    elseif tell.cmd == "LIGHT_COLOR_CHANGING" then
      local judged = not (sceneColor(tell.at) or offWithin(tell.at) or darkColor(tell.at))
      if pressInStep and inStep(tell, "color") and judged then
        run.checked.ramps = true
        local s = sentFor(tell, "color")
        local _, a = run.deviceBefore(tell.at + o.latency)
        local b = s and run.preTake[s.seq] and run.preTake[s.seq].color or a
        for _, pressAt in ipairs(presses) do
          local _, c = run.deviceBefore(pressAt + o.latency + 1)
          a = c -- a click's ramp carries its color from where its press found the light
        end
        local from = { x = q.LIGHT_COLOR_CURRENT_X, y = q.LIGHT_COLOR_CURRENT_Y }
        local to = { x = q.LIGHT_COLOR_TARGET_X, y = q.LIGHT_COLOR_TARGET_Y }
        if offSegment(from, a, b) > 0.01 then
          run.violate(
            "ramps",
            "color CHANGING from %s at %d while the device is in %s",
            T.show(from),
            tell.at,
            T.show(b)
          )
        end
        local stop = endOf(tell, s, q.LIGHT_COLOR_TARGET_COLOR_RATE)
        local _, there = run.deviceAt(stop or 0)
        if stop and not sameXY(there, to, 0.01) then
          run.violate("ramps", "color CHANGING to %s at %d: the device ends in %s", T.show(to), tell.at, T.show(there))
        end
      end
    end
  end
end

--- "`unbound`: the device binding is gone, so the LEDs go off and the proxy keeps the level"; a bind after
--- start "keeps what the device already told, and asks again". So an unbind, through `via` or a direct
--- light's forget, tells the proxy only that the light is offline, with the button LEDs off; a bind tells it
--- nothing; and the light's first report after them tells it where the light is.
local function judgeBinds(run)
  for i, a in ipairs(run.actions) do
    if a.binding then
      run.checked.binds = true
      for _, said in ipairs(run.bound[a.id] or {}) do
        local offline = said.id == H.PROXY and said.cmd == "ONLINE_CHANGED" and said.params.STATE == false
        local led = said.cmd == "MATCH_LED_STATE" and said.params.STATE == (said.id == H.LINKS.bottom)
        if not (offline or led) then
          run.violate("binds", "%s at %d tells %s %s on %d", a.name, a.at, said.cmd, T.show(said.params), said.id)
        end
      end
      -- The first report after a bind, unless the binding changed again before it.
      local first = a.binding ~= "unbind" and run.m.reports[a.heard + 1] or nil
      for j = i + 1, #run.actions do
        if run.actions[j].binding and run.actions[j].heard <= a.heard then
          first = nil
        end
      end
      if first then
        local level = run.levelOf(first.state.on, first.state.level)
        local told
        for _, tell in ipairs(first.told or {}) do
          if tell.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
            told = told or tell.params.LIGHT_BRIGHTNESS_CURRENT
          end
        end
        if not (told and run.sameLevel(told, level)) then
          run.violate(
            "binds",
            "the first report after %s at %d tells %s, the device reports %s",
            a.name,
            a.at,
            tostring(told),
            level
          )
        end
      end
    end
  end
end

--- "An error raised in send or refresh reaches the caller once, and leaves nothing refusing." So no error
--- escapes but the one a hook raises, and none is logged.
local function judgeErrors(run)
  run.checked.errors = true
  for _, e in ipairs(run.errors) do
    run.violate("errors", "%s", e)
  end
  for _, e in ipairs(run.clock.errors) do
    if tostring(e):find(RAISE, 1, true) then
      run.raises = run.raises + 1
    else
      run.violate("errors", "a callback raised: %s", e)
    end
  end
  if run.raises > 1 then
    run.violate("errors", "the hook's one raise escaped %d times", run.raises)
  end
  run.errors, run.clock.errors, run.raises = {}, {}, 0
end

--- Nothing is left refusing: with the transport sound again, a declaration is taken, and a level and a
--- color reach the device and show.
local function judgeRefusing(run)
  local m, o, final = run.m, run.o, run.final
  m.loseNext, m.failNext, m.foreignNext, m.dropNext, m.holdWordsUntil = nil, nil, nil, nil, nil
  run.cfg.raise = nil
  if not run.light:declare(m.declaration()) then
    run.violate("errors", "the declaration is refused at rest")
  end
  local finalLevel = run.levelOf(final.on, final.level)
  local probe = finalLevel == 37 and 63 or 37
  if not o.dims then
    probe = finalLevel > 0 and 0 or 100
  end
  command(run, "SET_LEVEL", { LEVEL = probe })
  if run.hasColor then
    command(run, "SET_COLOR_TARGET", colorParams(run, 0))
  end
  run.advance(run.restMs)
  local after = run.device:state(run.now())
  local level, shown = run.levelOf(after.on, after.level), run.proxy.level or -1
  if not (run.sameLevel(level, probe) and run.sameLevel(shown, probe)) then
    run.violate("errors", "a level of %s at rest: the device goes to %s, the proxy shows %s", probe, level, shown)
  end
  if run.hasColor and not sameXY(after.color, run.proxy.color, 0.01) then
    run.violate(
      "errors",
      "a color at rest: the device is in %s, the proxy shows %s",
      T.show(after.color),
      T.show(run.proxy.color)
    )
  end
  judgeErrors(run)
end

--------------------------------------------------------------------------------
-- One run
--------------------------------------------------------------------------------

--- Run one seeded sequence and judge it: its violations, what it drove, and with `trace` its steps.
local function fuzz(seed, index, trace)
  local r = rng((seed * 1000003 + index * 7919) % 2147483646)
  local o, cfg = draw(r)
  for _, key in ipairs(KEYS) do
    persist:delete(key)
  end
  local run = {
    r = r,
    o = o,
    cfg = cfg,
    about = describe(o, cfg),
    violations = {},
    trace = {},
    checked = {},
    ctx = {},
    actions = {},
    hands = {},
    faults = {},
    errors = {},
    raises = 0,
    lastAsk = {},
    bound = {},
    onModeSet = o.setup ~= nil,
    sceneUntil = -1,
    colorToldAt = -1,
    unreadAt = math.huge,
    ackMs = o.ackMs or 40000,
    hasColor = o.color or o.cct,
  }
  function run.violate(invariant, fmt, ...)
    run.violations[#run.violations + 1] = { invariant = invariant, message = string.format(fmt, ...) }
  end
  function run.step(fmt, ...)
    if trace then
      local args = { ... }
      for i = 1, select("#", ...) do
        args[i] = type(args[i]) == "table" and T.show(args[i]) or tostring(args[i])
      end
      run.trace[#run.trace + 1] = string.format(fmt, unpack(args, 1, select("#", ...)))
    end
  end
  function run.raised(e)
    if tostring(e):find(RAISE, 1, true) then
      run.raises = run.raises + 1
    else
      run.errors[#run.errors + 1] = tostring(e)
    end
  end
  function run.sceneActive(t)
    return t <= run.sceneUntil
  end
  -- A scene's step can wait in the outbox past the scene's own time.
  function run.sceneMayAsk(t)
    return t <= run.sceneUntil + (o.ack == "done" and (run.ackMs + 1.5 * MAX_RATE) or 0)
  end

  local w
  local ok, err = xpcall(function()
    w = H.world(o)
    run.m, run.light, run.clock, run.proxy, run.device = w.m, w.light, w.clock, w.proxy, w.device
    run.now = w.clock.now
    function run.fault(what, at)
      run.faults[#run.faults + 1] = { at = at or run.now(), what = what }
      if what:find("raises") then
        run.step("%d: %s", run.now(), what)
      end
    end
    function run.advance(ms)
      local stop = run.now() + ms
      repeat
        local ran, e = pcall(w.clock.run, stop - run.now())
        if not ran then
          run.raised(e)
        end
      until ran
    end

    -- The proxy's settings and scenes for this run, before anything is judged.
    if cfg.lo ~= 1 then
      w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = cfg.lo })
    end
    if cfg.hi ~= 100 then
      w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = cfg.hi })
    end
    if cfg.preset then
      w.proxy:send("SET_PRESET_LEVEL", { LEVEL = cfg.preset })
    end
    run.scenes = {}
    for id = 1, 2 do
      local steps, ms = drawScene(r, o)
      run.scenes[id] = { steps = steps, ms = ms, flash = r.chance(0.1) }
      pushScene(w.proxy, id, steps, run.scenes[id].flash)
    end
    w.run(5000)
    run.lo, run.hi = w.light:range()
    run.steps = o.levelSteps

    timeline(run)
    watch(run)
    w.proxy:mark()
    run.sample()
    run.t0 = run.now()

    local all, total = moves(run), 0
    for _, mv in ipairs(all) do
      total = total + mv[1]
    end
    for _ = 1, r.int(4, 24) do
      local pick = r.float() * total
      for _, mv in ipairs(all) do
        pick = pick - mv[1]
        if pick < 0 then
          mv[2]()
          break
        end
      end
      run.advance(r.pick(GAPS))
    end
    if run.unbound then
      bind(run)
    elseif run.offline then
      back(run)
    end
    if run.sceneUntil == math.huge then
      command(run, "DEACTIVATE_SCENE", { SCENE_ID = 1 })
      run.sceneUntil = run.now()
    end
    run.restMs = 2 * MAX_RATE + (o.settleMs or 0) + (o.reportLag or 0) + 20000
    if o.ack == "done" then
      run.restMs = run.restMs + 2 * (run.ackMs + 1.5 * MAX_RATE)
    end
    run.advance(run.restMs)
    if o.policy == "trust" then
      -- Under trust a report is "otherwise told when it differs": the device is polled, as a provider polls.
      act(run, "transport", "a poll", function()
        w.m.push(w.device:report(run.now()), {})
      end)
      run.advance(5000)
    end

    -- A change whose read raised stays unknown, as with a read lost: the light shows what the device
    -- last said, from before it. So does a command lost on the wire, read at its timeout.
    for _, f in ipairs(run.faults) do
      if f.what == "refresh raises" then
        for _, h in ipairs(run.hands) do
          if f.at >= h.at and h.level then
            run.unread, run.unreadAt = true, math.min(run.unreadAt, h.at)
          end
          run.colorUnread = run.colorUnread or (f.at >= h.at and h.color)
        end
        for _, u in ipairs(run.units) do
          if u.deadline == f.at and not u.wordsAt then
            run.unread, run.unreadAt = true, math.min(run.unreadAt, u.at)
            run.colorUnread = run.colorUnread or u.aspects.color
          end
        end
      end
    end
    run.crossed, run.crossedHands = crossings(run)
    run.final = w.device:state(run.now())
    -- Whether a level is where the device ends: the level it holds, or the one it reports at its steps.
    run.endLevel = run.levelOf(run.final.on, run.final.level)
    local reported = run.levelOf(run.final.on, w.device:reported(run.now()))
    function run.endsAt(level)
      return run.sameLevel(level, run.endLevel) or run.sameLevel(level, reported)
    end
    judgeRest(run)
    judgeLatest(run)
    judgeTold(run)
    judgeRamps(run)
    judgeBinds(run)
    judgeErrors(run)
    judgeRefusing(run)
  end, debug.traceback)
  if run.restoreLog then
    run.restoreLog()
  end
  if not ok then
    run.violate("errors", "the run raised: %s", tostring(err))
  end
  if w then
    w.restore()
  end
  return run
end

--------------------------------------------------------------------------------
-- The runs
--------------------------------------------------------------------------------

if ONLY then
  local run = fuzz(SEED, ONLY, true)
  print(string.format("run %d:%d: %s", SEED, ONLY, run.about))
  for _, s in ipairs(run.trace) do
    print("  " .. s)
  end
  for _, v in ipairs(run.violations) do
    print("  VIOLATION " .. v.invariant .. ": " .. v.message)
  end
  T.check(string.format("run %d:%d keeps every invariant", SEED, ONLY), #run.violations == 0)
  T.finish()
end

T.section(string.format("%d seeded runs from seed %d keep every invariant", RUNS, SEED))
local found, judged = {}, {}
for _, inv in ipairs(INVARIANTS) do
  found[inv[1]], judged[inv[1]] = { count = 0 }, 0
end
for index = 1, RUNS do
  local run = fuzz(SEED, index, false)
  for name in pairs(run.checked) do
    judged[name] = judged[name] + 1
  end
  for _, v in ipairs(run.violations) do
    local list = found[v.invariant]
    if #list < SHOW then
      list[#list + 1] = string.format("%d:%d (%s): %s", SEED, index, run.about, v.message)
    end
    list.count = list.count + 1
  end
end
-- An invariant no run was in a state to judge has not been shown to hold.
for _, inv in ipairs(INVARIANTS) do
  local list, runs = found[inv[1]], judged[inv[1]]
  local detail = list.count > 0 and (list.count .. ", first:\n    " .. table.concat(list, "\n    "))
    or (runs == 0 and "judged in no run")
    or nil
  T.check(inv[2], list.count == 0 and runs > 0, detail)
end
T.finish()
