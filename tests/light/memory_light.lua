--- MemoryLight: a v3 LightAdapter over an in-memory device, for the light library's own suite. The device
--- fades as its LightDevice facts say (device, own or walk), reports as its feedback says (where a change
--- ends or where the light has got to), and its transport can be slow, stale, lossy or silent. M.world puts
--- one behind the fake proxy on a virtual clock, started and online.

local F = require("c4_fixtures")
local Fake = require("light_proxy_fake")

local M = {}

M.PROXY, M.LINKS = Fake.PROXY, Fake.LINKS

--- The persist keys the library keeps, cleared before each world so none carries into the next.
M.KEYS = {
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
  "light_rate_caps",
}

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
M.copy = copy

--- @param p number 0 to 1
--- @return number
local function smootherstep(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

-----------------------------------------------------------------------------------------------------
-- The device
-----------------------------------------------------------------------------------------------------

--- @class MemoryTransition
--- @field from number|LightColor
--- @field to number|LightColor
--- @field t0 integer
--- @field dur integer
--- @field off boolean|nil A level fading to off.
--- @field keep number|nil The level an off keeps.

--- @class MemoryOptions
--- @field dims boolean|nil
--- @field color boolean|nil
--- @field cct LightCctRange|nil
--- @field levelSteps integer|nil
--- @field colorWhileOff LightColorWhileOff|nil
--- @field fade LightFade|nil
--- @field feedback LightFeedback|nil
--- @field keepsLevel boolean|nil An off device keeps its last level. Default: fade.preOn.
--- @field retimes boolean|nil One transition for every channel: a command restarts the other's over its time.
--- @field latency integer|nil Ms each way. Default 40.
--- @field slow number|nil A device fade this many times slower than asked.
--- @field pushEveryMs integer|nil Under "position", a push this often while a transition runs. Default 1000.
--- @field answers boolean|nil A read is answered "moving" or "final"; otherwise "push".
--- @field readbackMs integer|nil The transport reads the device this long after a command's transition.
--- @field seeds boolean|nil After each command the transport's cache re-pushes it as a "seed".
--- @field silent boolean|nil The device pushes nothing: only reads are answered.
--- @field rest (fun(cmd: LightCommand): LightRest|nil)|nil What send returns; the device rests there.
--- @field drop (fun(kind: string): boolean)|nil Lose a frame: kind "command", "report" or "read".
--- @field delay (fun(kind: string): integer)|nil Ms more a report takes, so what follows overtakes it.
--- @field profile LightProfile|nil Default: the most the device's facts make.
--- @field links LightLinks|false|nil The profile's links; false for none. Default M.LINKS.
--- @field level number|nil The device's level at the start, 0 to 1.
--- @field on boolean|nil Whether the device is on at the start.
--- @field startColor LightColor|nil The device's color at the start.

--- @class MemoryDevice
--- @field o MemoryOptions
--- @field clock FakeClock
--- @field on boolean
--- @field level number Device brightness 0-1; while off, the level it keeps.
--- @field color LightColor
--- @field tr MemoryTransition|nil
--- @field ctr MemoryTransition|nil
--- @field took LightCommand[] Every command it took.
--- @field droppedColors integer Colors it dropped because it was off ("hold").
--- @field onChange fun(landed: boolean)
local Device = {}
Device.__index = Device

--- @param tr MemoryTransition
--- @param now integer
--- @return number
function Device:progress(tr, now)
  local p = tr.dur > 0 and math.min(1, (now - tr.t0) / tr.dur) or 1
  local fade = self.o.fade or {}
  return fade.curve == "smootherstep" and smootherstep(p) or p
end

--- The brightness now, along a transition in flight.
--- @param now integer
--- @return number
function Device:brightness(now)
  local tr = self.tr
  if not tr then
    return self.level
  end
  return tr.from + (tr.to - tr.from) * self:progress(tr, now)
end

--- The color shown now, along a color transition in flight.
--- @param now integer
--- @return LightColor
function Device:shownColor(now)
  local tr = self.ctr
  if not tr then
    return self.color
  end
  local p = self:progress(tr, now)
  return {
    x = tr.from.x + (tr.to.x - tr.from.x) * p,
    y = tr.from.y + (tr.to.y - tr.from.y) * p,
    mode = p >= 1 and tr.to.mode or "xy",
    kelvin = p >= 1 and tr.to.kelvin or nil,
  }
end

--- @return boolean
function Device:keepsLevel()
  if self.o.keepsLevel ~= nil then
    return self.o.keepsLevel
  end
  return (self.o.fade or {}).preOn == true
end

--- What the device does now, for a check: on, level (0 when off) and color.
--- @param now integer
--- @return LightValues
function Device:state(now)
  local on = self.on and not (self.tr and self.tr.off and self:progress(self.tr, now) >= 1)
  return { on = on, level = on and self:brightness(now) or 0, color = copy(self:shownColor(now)) }
end

--- The length of a command's change, by the fade kind.
--- @private
--- @param cmd LightCommand
--- @return integer
function Device:_ms(cmd)
  local fade = self.o.fade or {}
  local kind = fade.kind or "device"
  if kind == "walk" or cmd.kind == "preOn" then
    return 0
  end
  if kind == "own" then
    local own = fade.own or { onMs = 0, offMs = 0, changeMs = 0 }
    if cmd.on and not self.on then
      return own.onMs
    elseif self.on and not cmd.on then
      return own.offMs
    end
    return own.changeMs
  end
  return math.floor((cmd.transitionMs or 0) * (self.o.slow or 1))
end

--- @private
--- @param tr MemoryTransition
function Device:_landed(tr)
  if self.tr ~= tr then
    return
  end
  self.tr = nil
  if tr.off then
    self.on = false
    self.level = self:keepsLevel() and tr.keep or 0
  else
    self.level = tr.to
  end
  self.onChange(true)
end

--- @private
--- @param tr MemoryTransition
function Device:_colorLanded(tr)
  if self.ctr ~= tr then
    return
  end
  self.ctr = nil
  self.color = tr.to
  self.onChange(true)
end

--- @private
--- @param to number
--- @param ms integer
--- @param now integer
--- @param off boolean|nil
function Device:_fadeLevel(to, ms, now, off)
  local from = self:brightness(now)
  if ms > 0 and to ~= from then
    local tr = { from = from, to = to, t0 = now, dur = ms, off = off, keep = from }
    self.tr = tr
    self.clock.at(ms, function()
      self:_landed(tr)
    end)
  else
    self.tr = nil
    if off then
      self.on = false
      self.level = self:keepsLevel() and from or 0
    else
      self.level = to
    end
  end
end

--- @private
--- @param to LightColor
--- @param ms integer
--- @param now integer
function Device:_fadeColor(to, ms, now)
  if ms > 0 then
    local tr = { from = self:shownColor(now), to = copy(to), t0 = now, dur = ms }
    self.ctr = tr
    self.clock.at(ms, function()
      self:_colorLanded(tr)
    end)
  else
    self.ctr = nil
    self.color = copy(to)
  end
end

--- One transition for every channel, as an ESPHome light runs: a channel the command leaves alone runs on
--- from where it is to its target over the command's time, at once with none.
--- @private
--- @param cmd LightCommand
--- @param ms integer
--- @param now integer
function Device:_retime(cmd, ms, now)
  local tr, ctr = self.tr, self.ctr
  if tr and not cmd.setsLevel and cmd.on == self.on then
    if ms > 0 then
      self:_fadeLevel(tr.to, ms, now, tr.off)
    else
      self:_landed(tr)
    end
  end
  if ctr and not cmd.setsColor then
    if ms > 0 then
      self:_fadeColor(ctr.to, ms, now)
    else
      self:_colorLanded(ctr)
    end
  end
end

--- Take a command, resting where `rest` says when it gives one.
--- @param cmd LightCommand
--- @param now integer
--- @param rest LightRest|nil
function Device:take(cmd, now, rest)
  local o = self.o
  self.took[#self.took + 1] = copy(cmd)
  local ms = self:_ms(cmd)
  local level = rest and rest.level or cmd.level
  local color = rest and rest.color or cmd.color
  if o.retimes then
    self:_retime(cmd, ms, now)
  end
  if cmd.kind == "stop" then
    if cmd.setsLevel and o.dims then
      self.tr = nil
      self.level = level
    end
    if cmd.setsColor and color then
      self.ctr = nil
      self.color = copy(color)
    end
    self.onChange(false)
    return
  end
  if cmd.setsColor and color and (o.color or o.cct) then
    if o.colorWhileOff == "hold" and not cmd.on and not self.on then
      self.droppedColors = self.droppedColors + 1
    else
      self:_fadeColor(color, ms, now)
    end
  end
  if not o.dims then
    self.tr = nil
    self.on = cmd.on
    if cmd.on then
      self.level = 1
    end
  elseif cmd.on == false then
    if self.on then
      self:_fadeLevel(0, ms, now, true)
    end
  elseif cmd.setsLevel or not self.on or cmd.kind == "preOn" then
    if not self.on then
      self.level = self:keepsLevel() and self.level or 0
      self.on = true
    end
    self:_fadeLevel(level, ms, now)
  end
  self.onChange(false)
end

--- Another hand's change: at the wall, or in the device's own app.
--- @param state LightValues
function Device:set(state)
  if state.color then
    self.ctr = nil
    self.color = copy(state.color)
  end
  if state.level ~= nil then
    self.tr = nil
    self.level = state.level
    if state.on == nil then
      self.on = state.level > 0
    end
  end
  if state.on ~= nil then
    self.tr = nil
    self.on = state.on
  end
end

--- The device's state as a report: where its changes end under "target", where it has got to under
--- "position". An off device reports the level it keeps, if any.
--- @param now integer
--- @param target boolean
--- @return LightValues
function Device:values(now, target)
  local o = self.o
  local st = {}
  local steps = o.levelSteps or 255
  if target then
    local tr = self.tr
    st.on = self.on and not (tr and tr.off)
    st.level = tr and not tr.off and tr.to or self.level
  else
    local state = self:state(now)
    st.on = state.on
    st.level = state.on and state.level or self.level
  end
  if not o.dims then
    st.level = nil
  elseif st.level then
    st.level = math.floor(st.level * steps + 0.5) / steps
    if not st.on and st.level <= 0 then
      st.level = nil
    end
  end
  if o.color or o.cct then
    st.color = copy(target and (self.ctr and self.ctr.to or self.color) or self:shownColor(now))
  end
  return st
end

-----------------------------------------------------------------------------------------------------
-- The adapter and its transport
-----------------------------------------------------------------------------------------------------

--- @class MemoryAdapter : LightAdapter
--- @field m MemoryLight
local Adapter = {}
Adapter.__index = Adapter

--- @param cmd LightCommand
--- @return LightRest|nil
function Adapter:send(cmd)
  return self.m:_send(cmd)
end

function Adapter:refresh()
  self.m:_refresh()
end

--- @param shown LightShown
function Adapter:show(shown)
  self.m.shown[#self.m.shown + 1] = copy(shown)
end

--- @class MemoryReport
--- @field at integer
--- @field report LightReport

--- @class MemoryLight
--- @field clock FakeClock
--- @field o MemoryOptions
--- @field device MemoryDevice
--- @field adapter MemoryAdapter
--- @field light Light
--- @field online boolean The device can be reached.
--- @field sent LightCommand[] Every command sent, each with `at`.
--- @field reports MemoryReport[] Every report delivered.
--- @field shown LightShown[] Every show the adapter was given.
--- @field reads integer refresh() calls.
--- @field dropNext boolean|nil Lose the next command on its way to the device.
--- @field dropReads boolean|nil Answer no read.
local Memory = {}
Memory.__index = Memory

--- The device's facts, as the driver declares them.
--- @return LightDevice
function Memory:declaration()
  local o = self.o
  return {
    dims = o.dims == true,
    color = o.color == true,
    cct = copy(o.cct),
    colorWhileOff = o.colorWhileOff,
    levelSteps = o.levelSteps,
    fade = copy(o.fade),
    feedback = copy(o.feedback),
  }
end

--- @private
--- @return boolean
function Memory:_showsTarget()
  local feedback = self.o.feedback or {}
  return (feedback.shows or "target") == "target"
end

--- Deliver a report to the light now, if the device can be reached.
--- @param report LightReport
function Memory:deliver(report)
  if not self.online then
    return
  end
  self.reports[#self.reports + 1] = { at = self.clock.now(), report = copy(report) }
  self.light:report(report)
end

--- A report of `kind` after the latency, unless the transport loses it. A function is read as it lands.
--- @param kind LightReportKind
--- @param values LightValues|fun(): LightValues
--- @param extra integer|nil
function Memory:push(kind, values, extra)
  local o = self.o
  if o.drop and o.drop("report") then
    return
  end
  local late = o.delay and o.delay("report") or 0
  self.clock.at((o.latency or 40) + (extra or 0) + late, function()
    local v = type(values) == "function" and values() or values
    local report = copy(v)
    report.kind = kind
    self:deliver(report)
  end)
end

--- The device's own pushes as it changes: once with its targets under "target"; under "position" as it
--- moves, every pushEveryMs, and where each change lands.
--- @private
--- @param landed boolean
function Memory:_changed(landed)
  if self.o.silent then
    return
  end
  local now = self.clock.now()
  if self:_showsTarget() then
    if not landed then
      self:push("push", self.device:values(now, true))
    end
    return
  end
  self:push("push", self.device:values(now, false))
  if not landed and (self.device.tr or self.device.ctr) and not self.ticking then
    self.ticking = true
    local every = self.o.pushEveryMs or 1000
    local function tick()
      self.clock.at(every, function()
        if not (self.device.tr or self.device.ctr) then
          self.ticking = false
          return
        end
        self:push("push", self.device:values(self.clock.now(), false))
        tick()
      end)
    end
    tick()
  end
end

--- Answer a read with the whole state: "moving" or "final" when the transport tells answers apart.
--- @private
--- @param asked integer The commands sent when the read left: one sent since outdates the answer.
function Memory:_answer(asked)
  local o = self.o
  if self.dropReads or (o.drop and o.drop("read")) then
    return
  end
  self.clock.at(o.latency or 40, function()
    if #self.sent > asked then
      return
    end
    local moving = self.device.tr ~= nil or self.device.ctr ~= nil
    local kind = o.answers and (moving and "moving" or "final") or "push"
    local report = self.device:values(self.clock.now(), self:_showsTarget())
    report.kind = kind
    self:deliver(report)
  end)
end

--- @private
--- @param cmd LightCommand
--- @return LightRest|nil
function Memory:_send(cmd)
  local o = self.o
  local c = copy(cmd)
  c.at = self.clock.now()
  self.sent[#self.sent + 1] = c
  if not self.online then
    return nil
  end
  local lost = self.dropNext or (o.drop and o.drop("command"))
  self.dropNext = nil
  -- A rest says where a command the device takes leaves it, so a command lost on the way rests nowhere.
  local rest = not lost and o.rest and o.rest(cmd) or nil
  c.rest = copy(rest)
  if o.seeds then
    local seed = { on = cmd.on, level = o.dims and cmd.level or nil, color = copy(cmd.color) }
    self:push("seed", seed, -math.floor((o.latency or 40) / 2))
  end
  if not lost then
    local sentAt = #self.sent
    self.clock.at(o.latency or 40, function()
      self.device:take(cmd, self.clock.now(), rest)
      if o.readbackMs then
        local ms = self.device:_ms(cmd)
        self.clock.at(ms + o.readbackMs, function()
          self:_answer(sentAt)
        end)
      end
    end)
  end
  return copy(rest)
end

--- @private
function Memory:_refresh()
  self.reads = self.reads + 1
  if not self.online then
    return
  end
  self:_answer(#self.sent)
end

--- Bring the device online: it declares, and reports its whole state.
function Memory:connect()
  self.online = true
  self.light:declare(self:declaration())
  local report = self.device:values(self.clock.now(), self:_showsTarget())
  report.kind = "push"
  self:deliver(report)
end

--- Another hand's change, reported as a push unless `quiet`.
--- @param state LightValues
--- @param quiet boolean|nil
function Memory:other(state, quiet)
  self.device:set(state)
  if not quiet then
    self:push("push", self.device:values(self.clock.now(), false))
  end
end

--- A report delivered at an absolute virtual time.
--- @param at integer
--- @param report LightReport
function Memory:inject(at, report)
  self.clock.at(at - self.clock.now(), function()
    self:deliver(report)
  end)
end

--- The device is lost: `suspended` as light:lost takes it.
--- @param suspended boolean|nil
function Memory:drop(suspended)
  self.online = false
  self.light:lost(suspended == true)
end

--- The device reports its state again after a loss.
function Memory:back()
  self:connect()
end

--- The levels of the commands sent since the mark, as C4-like percents, pre-ons left out.
--- @return (integer|string)[]
function Memory:sentLevels()
  local out = {}
  for _, c in ipairs(self.sent) do
    if c.kind ~= "preOn" then
      out[#out + 1] = c.on == false and 0 or math.floor(c.level * 100 + 0.5)
    end
  end
  return out
end

--- The commands sent since the mark of one kind.
--- @param kind LightCommandKind
--- @return LightCommand[]
function Memory:sentOf(kind)
  local out = {}
  for _, c in ipairs(self.sent) do
    if c.kind == kind then
      out[#out + 1] = c
    end
  end
  return out
end

--- The profile a device's facts make: everything they offer, with links unless `o.links` is false.
--- @param o MemoryOptions
--- @return LightProfile
function M.profile(o)
  local Light = require("lib.light")
  local fade = o.fade or {}
  local own = fade.own
  local still = fade.kind == "own" and (not own or (own.onMs == 0 and own.offMs == 0 and own.changeMs == 0))
  local links = o.links
  if links == nil then
    links = M.LINKS
  end
  return {
    api = Light.API,
    links = links or nil,
    dims = o.dims == true,
    color = o.color == true,
    cct = o.cct and copy(o.cct) or nil,
    fades = not still,
    defaultOn = true,
    scenes = true,
    onModes = true,
    flash = true,
  }
end

--- A MemoryLight over a new device, its Light made.
--- @param clock FakeClock
--- @param o MemoryOptions
--- @param device MemoryDevice|nil A device to keep, as across a driver restart.
--- @return MemoryLight
function M.memoryLight(clock, o, device)
  local Light = require("lib.light")
  local m =
    setmetatable({ clock = clock, o = o, online = false, sent = {}, reports = {}, shown = {}, reads = 0 }, Memory)
  if not device then
    device = setmetatable({
      o = o,
      clock = clock,
      on = o.on == true,
      level = o.level or 0,
      color = copy(o.startColor) or { x = 0.3127, y = 0.329, mode = "cct", kelvin = 6500 },
      took = {},
      droppedColors = 0,
    }, Device)
    if device.on and device.level <= 0 then
      device.level = 1
    end
  end
  device.onChange = function(landed)
    m:_changed(landed)
  end
  m.device = device
  m.adapter = setmetatable({ m = m }, Adapter)
  m.light = Light.new(m.adapter, o.profile or M.profile(o))
  return m
end

-----------------------------------------------------------------------------------------------------
-- A world
-----------------------------------------------------------------------------------------------------

--- @class MemoryWorld
--- @field clock FakeClock
--- @field proxy FakeProxy
--- @field m MemoryLight
--- @field light Light
--- @field device MemoryDevice
--- @field run fun(ms: integer)
--- @field restart fun(): MemoryWorld
--- @field restore fun()

local open = {}
-- The timer callback errors of the worlds the running case closed.
local closedErrors = {}

--- @class MemoryWorldOptions : MemoryOptions
--- @field setup string|nil GET_SETUP's answer.
--- @field newLight string|nil
--- @field variables table<integer, string>|nil The proxy's variables at the start.
--- @field offline boolean|nil Leave the device unconnected.
--- @field settle integer|nil Ms run after the connect. Default 5000.
--- @field keep boolean|nil Keep the persisted settings of the case before.
--- @field noStart boolean|nil Make the light but neither start it nor connect the device.

--- A started MemoryLight behind the fake proxy, on a virtual clock.
--- @param opts MemoryWorldOptions
--- @return MemoryWorld
function M.world(opts)
  if not opts.keep then
    local persist = require("lib.persist")
    for _, key in ipairs(M.KEYS) do
      persist:delete(key)
    end
  end
  local clock = F.virtualClock()
  local proxy = Fake.install(clock, {
    setup = opts.setup,
    newLight = opts.newLight,
    links = opts.links == nil and M.LINKS or opts.links,
    variables = opts.variables,
  })
  local w = { clock = clock, proxy = proxy }
  local function build(device, restarting)
    local m = M.memoryLight(clock, opts, device)
    w.m, w.light, w.device = m, m.light, m.device
    if opts.noStart then
      return
    end
    if restarting then
      proxy:mark()
    end
    m.light:start()
    if not opts.offline then
      m:connect()
      clock.run(opts.settle or 5000)
    end
    if not restarting then
      proxy:mark()
    end
    m.sent = {}
  end
  function w.run(ms)
    clock.run(ms)
  end
  --- The driver restarts: a new Light over the same proxy, settings and device. The proxy's record starts
  --- at the restart, so a check sees what the restart told.
  function w.restart()
    w.m.online = false
    -- A restart drops every timer the old driver set.
    local names = {}
    for name in pairs(Timer or {}) do
      if type(name) == "string" then
        names[#names + 1] = name
      end
    end
    for _, name in ipairs(names) do
      CancelTimer(name)
    end
    build(w.device, true)
    return w
  end
  function w.restore()
    for i = #open, 1, -1 do
      if open[i] == w then
        table.remove(open, i)
        for _, e in ipairs(clock.errors) do
          closedErrors[#closedErrors + 1] = e
        end
        proxy:restore()
        clock.restore()
      end
    end
  end
  open[#open + 1] = w
  build(nil)
  return w
end

--- Put back every world a case left open.
function M.closeAll()
  for i = #open, 1, -1 do
    open[i].restore()
  end
end

--- Run one case: a raise in it is its failure, by name, and the next case still runs.
--- @param T table testlib
--- @param fn fun()
function M.case(T, fn)
  closedErrors = {}
  local ok, err = xpcall(fn, debug.traceback)
  M.closeAll()
  local errors = closedErrors
  if not ok then
    T.check("the case runs to its end", false, err)
  end
  if #errors > 0 then
    T.eq("no timer callback raised", errors, {})
  end
end

return M
