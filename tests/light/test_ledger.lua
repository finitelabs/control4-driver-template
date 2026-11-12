-- The Ledger's rules J1 to J6 (design v3, section 3), case by case: what each report and deadline
-- tells Light to adopt, which aspects another hand moved, and when it asks the device.
--
-- Run against a render with the light token:
--   "$RENDER/test/run_test.sh" "$PWD/tests/light/test_ledger.lua"

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local Ledger = require("lib.light.ledger")

local clock = F.virtualClock()

local RED = { x = 0.64, y = 0.33, mode = "xy" }
local BLUE = { x = 0.15, y = 0.06, mode = "xy" }
local NEAR_RED = { x = 0.644, y = 0.326, mode = "xy" }
local PAST_RED = { x = 0.646, y = 0.33, mode = "xy" }

--- @class LedgerCaseDevice
--- @field shows LightMidChange|nil
--- @field waitMs integer|nil
--- @field refresh boolean|nil
--- @field colorWhileOff LightColorWhileOff|nil
--- @field levelSteps integer|nil

--- A checked device: every default but the case's own.
--- @param o LedgerCaseDevice|nil
--- @return LightDevice
local function device(o)
  o = o or {}
  return {
    dims = true,
    color = true,
    colorWhileOff = o.colorWhileOff or "send",
    levelSteps = o.levelSteps or 255,
    fade = { kind = "device", curve = "linear", preOn = false, maxMs = 65535 },
    feedback = { shows = o.shows or "target", waitMs = o.waitMs or 1000, refresh = o.refresh == true },
  }
end

--- @class LedgerCaseCommand
--- @field on boolean|nil Default true.
--- @field fromOff boolean|nil
--- @field level number|nil
--- @field color LightColor|nil
--- @field fromLevel number|nil Default 0.5.
--- @field fromColor LightColor|nil
--- @field setsLevel boolean|nil Default: a level, an off or an on from off. false: the on is only carried.

--- A command: a level when it names one, a color when it names one.
--- @param o LedgerCaseCommand
--- @return LightCommand
local function command(o)
  return {
    kind = "change",
    on = o.on ~= false,
    fromOff = o.fromOff == true,
    level = o.level or 0.5,
    color = o.color,
    -- Every off and every on from off changes the output (types.lua, setsLevel).
    setsLevel = o.setsLevel ~= false and (o.level ~= nil or o.on == false or o.fromOff == true),
    setsColor = o.color ~= nil,
    transitionMs = 0,
    from = { level = o.fromLevel or 0.5, color = o.fromColor },
    colorUnchosen = false,
  }
end

--- @class LedgerOut
--- @field due LightAspect|nil The deadline's aspect; nil for a report.
--- @field heard LightHeard

--- @param o table|nil { settle, foreign, ask }
--- @param due LightAspect|nil
--- @return LedgerOut
local function H(o, due)
  o = o or {}
  return { due = due, heard = { settle = o.settle or {}, foreign = o.foreign or {}, ask = o.ask == true } }
end

--- @class LedgerStep
--- @field now LightNow|nil Changes to Motion's values before the step.
--- @field send LedgerCaseCommand|nil
--- @field land integer|nil The command's landing, ms from now.
--- @field hear LightReport|nil
--- @field run integer|nil

--- @class LedgerCase
--- @field name string
--- @field dev LedgerCaseDevice|nil
--- @field now LightNow|nil Motion's values at the start; by default on at 0.5 in red.
--- @field unknown LightAspect[]|nil Aspects Motion does not know at the start.
--- @field fresh boolean|nil Start before the first report, so J2 applies.
--- @field steps LedgerStep[]
--- @field want LedgerOut[]

--- Run one case and return what each report and deadline said.
--- @param case LedgerCase
--- @return LedgerOut[]
local function run(case)
  local outs = {}
  local now = { on = true, level = 0.5, color = RED, levelRamping = false, colorRamping = false }
  for k, v in pairs(case.now or {}) do
    now[k] = v
  end
  for _, aspect in ipairs(case.unknown or {}) do
    now[aspect] = nil
  end
  local ledger
  local light = {}
  function light._due(_, aspect)
    outs[#outs + 1] = { due = aspect, heard = ledger:due(aspect, now) }
  end
  ledger = Ledger.new(light)
  ledger:declare(device(case.dev))
  if not case.fresh then
    ledger:heard({ kind = "push", on = now.on, level = now.level, color = now.color }, now)
  end
  for _, step in ipairs(case.steps) do
    for k, v in pairs(step.now or {}) do
      now[k] = v
    end
    if step.send then
      local cmd = command(step.send)
      local landing = clock.now() + (step.land or 0)
      ledger:sent(cmd, { on = landing, level = landing, color = landing })
      now.on = cmd.on
      if cmd.setsLevel then
        now.level = cmd.level
      end
      if cmd.setsColor then
        now.color = cmd.color
      end
    elseif step.hear then
      outs[#outs + 1] = { heard = ledger:heard(step.hear, now) }
    elseif step.run then
      clock.run(step.run)
    end
  end
  ledger:closeAll()
  return outs
end

--- @type table<string, LedgerCase[]>
local CASES = {}

CASES["J1: a held color"] = {
  {
    name = "while a color is held, an off report carries no color news, its first included",
    dev = { colorWhileOff = "hold" },
    now = { on = false, colorHeld = true },
    fresh = true,
    steps = {
      { hear = { kind = "push", on = false, level = 0.5, color = BLUE } },
      { hear = { kind = "push", on = true, color = RED } },
    },
    -- The color's first report is the lit one, and it matches the color the proxy shows.
    want = { H(), H({ settle = { on = true }, foreign = { "on" } }) },
  },
  {
    name = "a report with no on, while a color is held, carries no color news",
    dev = { colorWhileOff = "hold" },
    now = { on = false, colorHeld = true },
    steps = { { hear = { kind = "push", color = BLUE } } },
    want = { H() },
  },
  {
    name = "a hold device off with no color held takes the color an off report brings (a vendor app's pick)",
    dev = { colorWhileOff = "hold" },
    now = { on = false },
    steps = { { hear = { kind = "push", on = false, color = BLUE } } },
    want = { H({ settle = { color = BLUE }, foreign = { "color" } }) },
  },
  {
    name = "a report that says on carries its color even while one is held",
    dev = { colorWhileOff = "hold" },
    now = { on = false, colorHeld = true },
    steps = { { hear = { kind = "push", on = true, color = BLUE } } },
    -- The held color kept the start's report from being the color's first: this one is, so J2 adopts it.
    want = { H({ settle = { on = true, color = BLUE }, foreign = { "on" } }) },
  },
  {
    name = "a send device takes the color an off report carries",
    now = { on = false },
    fresh = true,
    steps = { { hear = { kind = "push", on = false, color = BLUE } } },
    want = { H({ settle = { color = BLUE } }) },
  },
}

CASES["J2: the first report"] = {
  {
    name = "a match with what the library holds tells nothing",
    fresh = true,
    steps = { { hear = { kind = "push", on = true, level = 0.5, color = RED } } },
    want = { H() },
  },
  {
    name = "a difference is adopted, and is no other hand's",
    fresh = true,
    steps = { { hear = { kind = "final", on = false, level = 0.3 } } },
    want = { H({ settle = { on = false, level = 0.3 } }) },
  },
  {
    name = "a seed counts as the first",
    fresh = true,
    steps = { { hear = { kind = "seed", level = 0.3 } } },
    want = { H({ settle = { level = 0.3 } }) },
  },
  {
    name = "each aspect has a first of its own",
    fresh = true,
    steps = {
      { hear = { kind = "push", level = 0.5 } },
      { hear = { kind = "push", level = 0.3, color = BLUE } },
    },
    want = { H(), H({ settle = { level = 0.3, color = BLUE }, foreign = { "level" } }) },
  },
  {
    name = "within the device's step is a match",
    dev = { levelSteps = 100 },
    fresh = true,
    steps = { { hear = { kind = "push", level = 0.504 } } },
    want = { H() },
  },
  {
    name = "a value the library does not know is a difference",
    unknown = { "level" },
    fresh = true,
    steps = { { hear = { kind = "push", level = 0.4 } } },
    want = { H({ settle = { level = 0.4 } }) },
  },
  {
    name = "a full color at the xy the library holds as a white is news: colors compare with their mode",
    fresh = true,
    now = { color = { x = 0.64, y = 0.33, mode = "cct" } },
    steps = { { hear = { kind = "push", on = true, level = 0.5, color = RED } } },
    want = { H({ settle = { color = RED } }) },
  },
}

CASES["J3: seeds"] = {
  {
    name = "a seed after the first fills nothing",
    steps = { { hear = { kind = "seed", level = 0.3, color = BLUE } } },
    want = { H() },
  },
  {
    name = "nor inside a window",
    steps = { { send = { level = 0.8 } }, { hear = { kind = "seed", level = 0.3 } } },
    want = { H() },
  },
}

CASES["J4: no window"] = {
  {
    name = "a report of what the library holds is nothing",
    steps = { { hear = { kind = "push", level = 0.5 } } },
    want = { H() },
  },
  {
    name = "another hand's value is adopted and named",
    steps = { { hear = { kind = "push", level = 0.2 } } },
    want = { H({ settle = { level = 0.2 }, foreign = { "level" } }) },
  },
  {
    name = "a final or a moving answer outside a window is weighed the same",
    steps = { { hear = { kind = "final", level = 0.2 } }, { hear = { kind = "moving", level = 0.3 } } },
    want = {
      H({ settle = { level = 0.2 }, foreign = { "level" } }),
      H({ settle = { level = 0.3 }, foreign = { "level" } }),
    },
  },
  {
    name = "on a refresh device, an on with no level asks, and is told with the level",
    dev = { refresh = true },
    now = { on = false },
    steps = { { hear = { kind = "push", on = true } }, { hear = { kind = "push", level = 0.7 } } },
    want = { H({ foreign = { "on" }, ask = true }), H({ settle = { level = 0.7, on = true } }) },
  },
  {
    name = "with no level by the deadline, the on is told at the level last known",
    dev = { refresh = true },
    now = { on = false },
    steps = { { hear = { kind = "push", on = true } }, { run = 1000 } },
    want = { H({ foreign = { "on" }, ask = true }), H({ settle = { on = true } }, "on"), H(nil, "level") },
  },
  {
    name = "a device that cannot refresh has its on adopted at once",
    now = { on = false },
    steps = { { hear = { kind = "push", on = true } } },
    want = { H({ settle = { on = true }, foreign = { "on" } }) },
  },
  {
    name = "a color sent while the on waits for its level opens no on window, and the level asks again",
    dev = { refresh = true },
    now = { on = false },
    steps = {
      { hear = { kind = "push", on = true } },
      { send = { on = false, setsLevel = false, color = BLUE } },
      { run = 1000 },
      { hear = { kind = "final", level = 0.7 } },
    },
    want = {
      H({ foreign = { "on" }, ask = true }),
      H({ settle = { on = true } }, "on"),
      H({ ask = true }, "level"),
      H({ ask = true }, "color"),
      H({ settle = { level = 0.7 } }),
    },
  },
  {
    name = "a level sent while the on waits for its level is a command's, and the on stands as lit for it",
    dev = { refresh = true },
    now = { on = false },
    steps = {
      { hear = { kind = "push", on = true } },
      { send = { fromOff = true, level = 0.8 } },
      { hear = { kind = "push", level = 0.8 } },
      { run = 1000 },
    },
    want = { H({ foreign = { "on" }, ask = true }), H(), H({ settle = { on = true } }, "on") },
  },
  {
    name = "an on answered alone waits for its level: the on is told with the level, never at the level kept",
    dev = { refresh = true, shows = "position" },
    now = { on = false },
    steps = {
      { hear = { kind = "push", on = true } },
      { hear = { kind = "seed", on = true, level = 1 } },
      { hear = { kind = "final", on = true } },
      { hear = { kind = "final", level = 0.2 } },
    },
    want = { H({ foreign = { "on" }, ask = true }), H(), H(), H({ settle = { level = 0.2, on = true } }) },
  },
}

CASES["J5a, J5b: answers to a read"] = {
  {
    name = "a final settles whatever it shows, and the window closes",
    steps = { { send = { level = 0.8 }, land = 500 }, { hear = { kind = "final", level = 0.6 } }, { run = 3000 } },
    want = { H({ settle = { level = 0.6 } }) },
  },
  {
    name = "a final during a ramp ends it there",
    steps = {
      { send = { level = 0.8 }, land = 3000, now = { levelRamping = true } },
      { hear = { kind = "final", level = 0.6 } },
    },
    want = { H({ settle = { level = 0.6 } }) },
  },
  {
    name = "a moving answer is held, and adopted at the deadline",
    dev = { shows = "position", refresh = true },
    steps = { { send = { level = 0.8 }, land = 500 }, { hear = { kind = "moving", level = 0.6 } }, { run = 1500 } },
    want = { H(), H({ settle = { level = 0.6 } }, "level") },
  },
  {
    name = "a final that matches the newest sent in device steps settles on the sent value, not its rounding",
    dev = { shows = "position" },
    steps = { { send = { level = 0.5 } }, { hear = { kind = "final", level = 0.5013 } } },
    want = { H({ settle = { level = 0.5 } }) },
  },
}

CASES["J5c: the newest command's echo"] = {
  {
    name = "under target with no ramp running, it closes the window",
    steps = { { send = { level = 0.8 } }, { hear = { kind = "push", level = 0.8 } }, { run = 2000 } },
    want = { H() },
  },
  {
    name = "under target during a ramp, it keeps the window open and drops what was held",
    steps = {
      { send = { level = 0.8 }, land = 3000, now = { levelRamping = true } },
      { hear = { kind = "push", level = 0.5 } },
      { hear = { kind = "push", level = 0.8 } },
      { run = 5000 },
    },
    want = { H(), H(), H(nil, "level") },
  },
  {
    name = "under position, the light is at the end, so a running ramp ends there",
    dev = { shows = "position" },
    steps = {
      { send = { level = 0.8 }, land = 3000, now = { levelRamping = true } },
      { hear = { kind = "push", level = 0.8 } },
      { run = 5000 },
    },
    want = { H({ settle = { level = 0.8 } }) },
  },
  {
    name = "a color within the tolerance is the echo",
    steps = { { send = { color = RED } }, { hear = { kind = "push", color = NEAR_RED } }, { run = 2000 } },
    want = { H() },
  },
  {
    name = "an off's echo closes its window, after a stale on from before it was held",
    steps = {
      { send = { on = false } },
      { hear = { kind = "push", on = true } },
      { hear = { kind = "push", on = false } },
      { run = 2000 },
    },
    want = { H(), H() },
  },
}

CASES["J5d: history"] = {
  {
    name = "an older command's value is held, and the newest's echo clears it",
    steps = {
      { send = { level = 0.8 } },
      { send = { level = 0.3 } },
      { hear = { kind = "push", level = 0.8 } },
      { hear = { kind = "push", level = 0.3 } },
      { run = 2000 },
    },
    want = { H(), H() },
  },
  {
    name = "the value from before the window, with no echo after, is adopted at the deadline",
    steps = { { send = { level = 0.8 } }, { hear = { kind = "push", level = 0.5 } }, { run = 1000 } },
    want = { H(), H({ settle = { level = 0.5 } }, "level") },
  },
  {
    name = "on a refresh device, an off held against an on asks once",
    dev = { refresh = true },
    now = { on = false },
    steps = {
      { send = { on = true, fromOff = true } },
      { hear = { kind = "push", on = false } },
      { hear = { kind = "push", on = false } },
    },
    want = { H({ ask = true }), H() },
  },
  {
    name = "a device that cannot refresh holds it without asking",
    now = { on = false },
    steps = { { send = { on = true, fromOff = true } }, { hear = { kind = "push", on = false } }, { run = 1000 } },
    -- The on from off set the level too: its window closes on the command at the deadline.
    want = { H(), H({ settle = { on = false } }, "on"), H(nil, "level") },
  },
  {
    name = "once the newest command's echo is heard, the value from before is another hand's",
    steps = {
      { send = { level = 0.3, fromLevel = 1.0 }, land = 5000, now = { levelRamping = true } },
      { hear = { kind = "push", level = 0.3 } },
      { hear = { kind = "push", level = 1.0 } },
    },
    want = { H(), H({ settle = { level = 1.0 }, foreign = { "level" } }) },
  },
  {
    name = "under target, history during the aspect's ramp is dropped, so the deadline keeps the ramp",
    steps = {
      { send = { color = BLUE, fromColor = RED, setsLevel = false }, land = 5000, now = { colorRamping = true } },
      { hear = { kind = "push", color = RED } },
      { run = 6000 },
    },
    want = { H(), H(nil, "color") },
  },
  {
    name = "under position the same report may be the light on its way: held, and adopted at the deadline",
    dev = { shows = "position" },
    steps = {
      { send = { color = BLUE, fromColor = RED, setsLevel = false }, land = 5000, now = { colorRamping = true } },
      { hear = { kind = "push", color = RED } },
      { run = 6000 },
    },
    want = { H(), H({ settle = { color = RED } }, "color") },
  },
  {
    name = "a report another hand made is its state whole: an on held as history comes with its foreign level",
    now = { on = false },
    steps = {
      { send = { on = true, fromOff = true, level = 0.6 } },
      { send = { on = false } },
      { hear = { kind = "push", on = true, level = 0.8 } },
    },
    want = { H({ settle = { level = 0.8, on = true }, foreign = { "level", "on" } }) },
  },
  {
    name = "an off held as history carries that stale state's kept level, never a lit one",
    now = { on = false },
    steps = {
      { send = { on = true, fromOff = true, level = 0.6 } },
      { hear = { kind = "push", on = false, level = 0.87 } },
    },
    want = { H() },
  },
}

CASES["J5e: a value no command sent"] = {
  {
    name = "under target, it is another hand's and closes the window",
    steps = { { send = { level = 0.8 } }, { hear = { kind = "push", level = 0.2 } }, { run = 2000 } },
    want = { H({ settle = { level = 0.2 }, foreign = { "level" } }) },
  },
  {
    name = "under position, it may be the light on its way, and is held",
    dev = { shows = "position" },
    steps = { { send = { level = 0.8 }, land = 1000 }, { hear = { kind = "push", level = 0.6 } }, { run = 3000 } },
    want = { H(), H({ settle = { level = 0.6 } }, "level") },
  },
  {
    name = "a color past the tolerance is another hand's",
    steps = { { send = { color = RED } }, { hear = { kind = "push", color = PAST_RED } } },
    want = { H({ settle = { color = PAST_RED }, foreign = { "color" } }) },
  },
  {
    name = "a command that keeps the light on opens no on window, so an off is another hand's",
    steps = { { send = { level = 0.8 } }, { hear = { kind = "push", on = false } } },
    want = { H({ settle = { on = false }, foreign = { "on" } }) },
  },
}

CASES["J5g: after the deadline's ask"] = {
  {
    name = "the first push settles, even one that reads as history",
    dev = { refresh = true },
    steps = {
      { send = { level = 0.8 } },
      { run = 1000 },
      { hear = { kind = "push", level = 0.5 } },
      { run = 3000 },
    },
    want = { H({ ask = true }, "level"), H({ settle = { level = 0.5 } }) },
  },
  {
    name = "a moving answer after it is still held",
    dev = { refresh = true, shows = "position" },
    steps = {
      { send = { level = 0.8 } },
      { run = 1000 },
      { hear = { kind = "moving", level = 0.6 } },
      { run = 1000 },
    },
    want = { H({ ask = true }, "level"), H(), H({ settle = { level = 0.6 } }, "level") },
  },
}

CASES["J6: the deadline"] = {
  {
    name = "heard with nothing held keeps the command",
    steps = {
      { send = { level = 0.8 }, land = 2000, now = { levelRamping = true } },
      { hear = { kind = "push", level = 0.8 } },
      { run = 3000 },
    },
    want = { H(), H(nil, "level") },
  },
  {
    name = "silence on a refresh device asks once and extends once, then keeps the command",
    dev = { refresh = true },
    steps = { { send = { level = 0.8 } }, { run = 1000 }, { run = 1000 }, { run = 5000 } },
    want = { H({ ask = true }, "level"), H(nil, "level") },
  },
  {
    name = "silence on a device that cannot refresh keeps the command",
    steps = { { send = { level = 0.8 } }, { run = 1000 } },
    want = { H(nil, "level") },
  },
  {
    name = "it falls at the landing plus the wait",
    dev = { waitMs = 500 },
    steps = { { send = { level = 0.8 }, land = 2000 }, { run = 2499 }, { hear = { kind = "moving" } }, { run = 1 } },
    -- The empty report marks the time: nothing came due before it.
    want = { H(), H(nil, "level") },
  },
  {
    name = "a second command extends the window and moves its deadline",
    steps = {
      { send = { level = 0.8 } },
      { run = 600 },
      { send = { level = 0.3 } },
      { run = 900 },
      { hear = { kind = "moving" } },
      { run = 100 },
    },
    want = { H(), H(nil, "level") },
  },
  {
    name = "an off ends the window of the level before it: that level's deadline never comes",
    steps = { { send = { level = 0.7 } }, { send = { on = false, level = 0.7 } }, { run = 2000 } },
    want = { H(nil, "on") },
  },
}

local ORDER = {
  "J1: a held color",
  "J2: the first report",
  "J3: seeds",
  "J4: no window",
  "J5a, J5b: answers to a read",
  "J5c: the newest command's echo",
  "J5d: history",
  "J5e: a value no command sent",
  "J5g: after the deadline's ask",
  "J6: the deadline",
}

for _, title in ipairs(ORDER) do
  T.section(title)
  for _, case in ipairs(CASES[title]) do
    T.eq(case.name, run(case), case.want)
  end
end

T.section("Windows and the run")
do
  local outs = {}
  local now = { on = true, level = 0.5, color = RED, levelRamping = false, colorRamping = false }
  local ledger
  local light = {}
  function light._due(_, aspect)
    outs[#outs + 1] = ledger:due(aspect, now)
  end
  ledger = Ledger.new(light)
  ledger:declare(device({ refresh = true }))
  ledger:heard({ kind = "push", on = true, level = 0.5, color = RED }, now)

  local at = clock.now()
  ledger:sent(command({ level = 0.8, color = BLUE }), { on = at, level = at, color = at })
  T.check("a command opens a window per aspect it changes", ledger.windows.level ~= nil and ledger.windows.color ~= nil)
  T.eq("and none for an on it keeps", ledger.windows.on, nil)
  ledger:closeAll()
  clock.run(5000)
  T.eq("closeAll stops every deadline", #outs, 0)

  ledger:sent(command({ level = 0.8 }), { on = at, level = clock.now(), color = at })
  ledger:reset()
  clock.run(5000)
  T.eq("reset stops them too", #outs, 0)
  T.eq(
    "and the next report is a first again: a difference is adopted, not another hand's",
    ledger:heard({ kind = "push", level = 0.2 }, now),
    { settle = { level = 0.2 }, foreign = {}, ask = false }
  )
  T.eq(
    "the deadline timers are named for their aspect",
    (function()
      ledger:sent(command({ level = 0.8 }), { on = at, level = clock.now(), color = at })
      local named = Timer["Light.Wait.level"] ~= nil
      ledger:closeAll()
      return named and Timer["Light.Wait.level"] == nil
    end)(),
    true
  )
end

clock.restore()
T.finish()
