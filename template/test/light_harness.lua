-- The Light V2 test kit: a virtual clock, a fake proxy that models what the real one derives, a
-- reference device and adapter (MemoryLight) whose every part is selectable, and H.contract, which
-- proves a driver's real adapter against the library's contract over a rig of its own transport.
--
-- A light driver's test/test_light_adapter.lua calls it with a rig over its real adapter and a fake
-- of its own transport:
--
--   local H = require("light_harness")
--   H.contract(T, {
--     name = "my light",
--     load = function(h) ... end, -- dofile the driver, run late init on h.clock, return the device
--     declarations = { ... },     -- every declaration the adapter can make
--     driverXml = "drivers/my_light/driver.xml",
--     settleMs = 11500,           -- how long the run waits for the light to settle, less 5 s
--     setup = H.setupFile("setup-607.xml"), -- the proxy's GET_SETUP answer; none when left out
--     holds = true,               -- with ack = "done": the outbox and ledger checks run on the hooks below
--   })
--
-- The device a rig's load returns: state() gives { on, level (0 to 1), color = { x, y } }, the
-- color with kelvin, or { kelvin } alone, for a white the device holds by its kelvin; set(state,
-- quiet) is another hand's change, and with quiet the device reports its on or off alone, so only a
-- read shows its level; drop() and back() lose and restore the device; dims, color, cct and stops
-- (false for a light that does not fade) say what it is; declaration() is what it declares. For an
-- adapter that declares ack = "done": hold(on) makes the device hold its word on a rated on from
-- off to the transition's end; loseWord() loses the next command's word; foreignWord() gives it
-- with another load's epoch instead; failWord() has the transport give up on the next command, which
-- never reaches the device, and its word says so; dropReads(on) has the device answer no read; and
-- taken() lists the level (0 to 1) of every command the device took that set one, oldest first. The
-- runner judges what the device does and what the fake proxy is told, never wire bytes. H.memoryRig
-- builds a rig over MemoryLight, the reference. Each check runs as a case (H.case): one that raises
-- fails by name, and the run goes on.

local F = require("c4_fixtures")
local Caps = require("lib.light.caps")
local Color = require("lib.light.color")
local Fade = require("lib.light.fade")
local Range = require("lib.light.range")

local H = {}

H.PROXY = 5001
H.LINKS = { top = 300, toggle = 301, bottom = 302 }
-- The proxy's own device id, which C4:GetProxyDevices answers and GET_SETUP is asked of.
H.PROXY_DEVICE = 7001

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"

--- A GET_SETUP answer from test/light_setup, as the proxy gave it on OS 4.3.0.
--- @param name string e.g. "setup-607.xml"
--- @return string xml
function H.setupFile(name)
  local f = assert(io.open(HERE .. "light_setup/" .. name, "rb"))
  local xml = f:read("*a")
  f:close()
  return xml
end

---------------------------------------------------------------------------
-- Cases
---------------------------------------------------------------------------

-- What the cases running installed and have not put back, and the clocks the innermost one made.
local open, clocks = {}, nil

--- Note what a world or a contract load installed, so a case that raises can put it back.
--- @param clock table Its virtual clock, whose callbacks' errors the case reports.
--- @param restore function Puts back what it installed.
--- @return function restore The same, done once.
local function opened(clock, restore)
  if clocks then
    clocks[#clocks + 1] = clock
  end
  open[#open + 1] = restore
  return function()
    for i = #open, 1, -1 do
      if open[i] == restore then
        table.remove(open, i)
        restore()
      end
    end
  end
end

--- Run one case of a suite or of the contract. A raise in it, or in a callback on a clock it made, is its
--- failure, named in the run; what it left installed is put back, and the next case runs.
--- @param T table testlib
--- @param fn function
--- @param name string|nil Prefixes the check's name, as the contract's are.
function H.case(T, fn, name)
  local prefix = name and (name .. ": ") or ""
  local mark, outer = #open, clocks
  clocks = {}
  local ok, err = xpcall(fn, debug.traceback)
  local made = clocks
  clocks = outer
  for i = #open, mark + 1, -1 do
    table.remove(open, i)()
  end
  local raised = {}
  for _, clock in ipairs(made) do
    for _, e in ipairs(clock.errors) do
      raised[#raised + 1] = e
    end
  end
  if not ok then
    T.check(prefix .. "the case runs to its end", false, err)
  end
  if #raised > 0 then
    T.eq(prefix .. "no callback raised", raised, {})
  end
end

---------------------------------------------------------------------------
-- The fake proxy
---------------------------------------------------------------------------

local Proxy = {}
Proxy.__index = Proxy

--- Install a fake Light V2 proxy. It records every notify to the proxy and the links, and models
--- what the real proxy derives (measured on dev 4.3.0): LIGHT_STATE follows CHANGING's CURRENT;
--- Brightness Percent steps along the line once a second after a CHANGING; Previous On is written
--- from the last level told above 0 when LIGHT_STATE goes off, and pushed back to the driver as
--- UPDATE_BRIGHTNESS_PRESET; GET_SETUP is answered from `opts.setup`, or from `opts.newLight` until
--- the proxy is told the light has color.
--- @param clock table F.virtualClock's clock.
--- @param opts table|nil { setup, newLight, links }
function H.proxy(clock, opts)
  opts = opts or {}
  local p = setmetatable({ clock = clock, links = opts.links == nil and H.LINKS or opts.links }, Proxy)
  p.setup, p.newLight = opts.setup or "", opts.newLight
  p.colorTold = false
  p:reset()
  local me = tonumber(C4:GetDeviceID())
  ShimSetDevices({
    [me] = { deviceName = "Light", proxies = { [H.PROXY_DEVICE] = {} } },
    [H.PROXY_DEVICE] = { deviceName = "Light", driverFileName = "light_v2.c4i", protocol = { [me] = {} } },
  })
  ShimSetUIRequest(function(id, request)
    if tonumber(id) == H.PROXY_DEVICE and request == "GET_SETUP" then
      p.setupReads = p.setupReads + 1
      return (not p.colorTold and p.newLight) or p.setup or ""
    end
    return ""
  end)
  local prior = C4.SendToProxy
  p.prior = prior
  C4.SendToProxy = function(self, id, cmd, params, ...)
    p:_heard(id, cmd, params)
    return prior(self, id, cmd, params, ...)
  end
  return p
end

--- Forget what was told, as at a fresh load of the proxy.
function Proxy:reset()
  self.notes = {}
  self.level = nil
  self.lit = false
  self.lastLit = nil
  self.previousOn = nil
  self.color = nil
  self.changing = nil
  self.online = nil
  self.leds = {}
  self.setupReads = 0
  self.caps = nil
end

--- Clear the record of notifies, keeping the state the proxy derived.
function Proxy:mark()
  self.notes = {}
  self.setupReads = 0
end

--- @private
function Proxy:_heard(id, cmd, params)
  local links = self.links or {}
  local now = self.clock.now()
  if id == links.top or id == links.toggle or id == links.bottom then
    if cmd == "MATCH_LED_STATE" then
      self.leds[id] = params.STATE
      self.notes[#self.notes + 1] = { at = now, binding = id, cmd = cmd, params = params }
    end
    return
  end
  if id ~= H.PROXY then
    return
  end
  self.notes[#self.notes + 1] = { at = now, binding = id, cmd = cmd, params = params }
  local wasLit = self.lit
  if cmd == "LIGHT_BRIGHTNESS_CHANGED" then
    -- A level that is no number is kept as it came, unlit, for a check to name rather than raise here.
    local level = tonumber(params.LIGHT_BRIGHTNESS_CURRENT)
    self.level, self.changing = level, nil
    self.lit = (level or 0) > 0
    if self.lit then
      self.lastLit = level
    end
  elseif cmd == "LIGHT_BRIGHTNESS_CHANGING" then
    local current = tonumber(params.LIGHT_BRIGHTNESS_CURRENT)
    self.changing =
      { from = current, to = tonumber(params.LIGHT_BRIGHTNESS_TARGET), rate = tonumber(params.RATE), at = now }
    self.lit = (current or 0) > 0
    if self.lit then
      self.lastLit = current
    end
  elseif cmd == "LIGHT_COLOR_CHANGED" then
    self.color = {
      x = params.LIGHT_COLOR_CURRENT_X,
      y = params.LIGHT_COLOR_CURRENT_Y,
      mode = params.LIGHT_COLOR_CURRENT_COLOR_MODE,
    }
  elseif cmd == "ONLINE_CHANGED" then
    self.online = params.STATE
  elseif cmd == "DYNAMIC_CAPABILITIES_CHANGED" then
    self.caps = params
    self.colorTold = self.colorTold
      or params.supports_color == true
      or params.supports_color_correlated_temperature == true
  end
  if wasLit and not self.lit and self.lastLit then
    -- The proxy rewrites its Previous On preset at every off, and tells the driver.
    local keep = self.lastLit
    self.previousOn = keep
    self.clock.at(1, function()
      local handler = RFP.UPDATE_BRIGHTNESS_PRESET
      if handler then
        handler(
          H.PROXY,
          "UPDATE_BRIGHTNESS_PRESET",
          { COMMAND = "MODIFIED", ID = 10, NAME = "Previous On", LEVEL = keep },
          {}
        )
      end
    end)
  end
end

--- Every notify of one command since the mark, in order.
--- @param cmd string
--- @return table[] params
function Proxy:told(cmd)
  local out = {}
  for _, n in ipairs(self.notes) do
    if n.cmd == cmd and n.binding == H.PROXY then
      out[#out + 1] = n.params
    end
  end
  return out
end

--- The levels told by CHANGED since the mark.
function Proxy:changed()
  local out = {}
  for _, p in ipairs(self:told("LIGHT_BRIGHTNESS_CHANGED")) do
    out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT
  end
  return out
end

--- The commands of each notify to the proxy since the mark, in order.
function Proxy:said()
  local out = {}
  for _, n in ipairs(self.notes) do
    if n.binding == H.PROXY then
      out[#out + 1] = n.cmd
    end
  end
  return out
end

--- Brightness Percent as the proxy shows it now: stepped along the line once a second after a CHANGING.
--- @return integer|nil
function Proxy:percent()
  local c = self.changing
  if not c then
    return self.level
  end
  if not c.rate or c.rate <= 0 or not c.from or not c.to then
    return c.to
  end
  local steps = math.floor((self.clock.now() - c.at) / 1000)
  local p = math.min(1, steps * 1000 / c.rate)
  return math.floor(c.from + (c.to - c.from) * p + 0.5)
end

--- Send the light a proxy command.
--- @param cmd string
--- @param params table|nil
function Proxy:send(cmd, params)
  local handler = RFP[cmd]
  assert(handler, "no handler for " .. cmd)
  handler(H.PROXY, cmd, params or {}, {})
end

--- The Control4 app's On: SET_BRIGHTNESS_TARGET at the on level over 750 ms, then the on color about
--- 18 ms later as SET_COLOR_TARGET, with its preset id and origin.
--- @param level integer
--- @param color table|nil { x, y, mode, preset, origin }
function Proxy:appOn(level, color)
  self:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level, RATE = 750 })
  if color then
    self.clock.at(18, function()
      self:send("SET_COLOR_TARGET", {
        LIGHT_COLOR_TARGET_X = color.x,
        LIGHT_COLOR_TARGET_Y = color.y,
        LIGHT_COLOR_TARGET_MODE = color.mode or 0,
        LIGHT_COLOR_TARGET_PRESET_ID = color.preset,
        LIGHT_COLOR_TARGET_PRESET_ORIGIN = color.origin,
        LIGHT_COLOR_TARGET_COLOR_RATE = 750,
      })
    end)
  end
end

--- Push an on mode or a rate default, as the proxy does: only when it changes.
--- @param cmd string UPDATE_COLOR_ON_MODE, UPDATE_BRIGHTNESS_ON_MODE or an UPDATE_*_RATE_DEFAULT
--- @param params table
function Proxy:push(cmd, params)
  self.pushed = self.pushed or {}
  local key = {}
  for k, v in pairs(params) do
    key[#key + 1] = tostring(k) .. "=" .. tostring(v)
  end
  table.sort(key)
  key = table.concat(key, ",")
  if self.pushed[cmd] == key then
    return false
  end
  self.pushed[cmd] = key
  self:send(cmd, params)
  return true
end

--- Put SendToProxy, the device registry and the GET_SETUP answer back.
function Proxy:restore()
  C4.SendToProxy = self.prior
  ShimSetUIRequest(nil)
  ShimResetDevices()
end

---------------------------------------------------------------------------
-- MemoryLight: the reference device and adapter
---------------------------------------------------------------------------

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
H.copy = copy

local Device = {}
Device.__index = Device

--- How far along a transition the device is now, along its curve.
function Device:progress(tr, now)
  local p = math.min(1, (now - tr.t0) / tr.dur)
  return self.o.curve == "eased" and Fade.eased(p) or p
end

--- The device's brightness (0 to 1) now, along a transition in flight.
function Device:brightness(now)
  local tr = self.tr
  if not tr then
    return self.level
  end
  return tr.from + (tr.to - tr.from) * self:progress(tr, now)
end

--- Its brightness as it reports it: on its own steps.
function Device:reported(now)
  local b = self:brightness(now)
  local steps = self.o.levelSteps
  return steps and math.floor(b * steps + 0.5) / steps or b
end

--- The color it shows now, along a color transition in flight.
function Device:shownColor(now)
  local tr = self.ctr
  if not tr then
    return self.color
  end
  local p = self:progress(tr, now)
  return { x = tr.from.x + (tr.to.x - tr.from.x) * p, y = tr.from.y + (tr.to.y - tr.from.y) * p, mode = tr.to.mode }
end

--- What the device is doing now: { on, level (0 to 1), color }; a white it took by its kelvin carries it.
function Device:state(now)
  local color = self:shownColor(now)
  if color == self.color and self.kelvin then
    color = { x = color.x, y = color.y, mode = color.mode, kelvin = self.kelvin }
  end
  return { on = self.on, level = self.on and self:brightness(now) or 0, color = color }
end

--- Run a change to the device: under trust its whole state goes out once, when all of it is in.
local function whole(self, change)
  self.whole = {}
  change()
  local pushed = self.whole
  self.whole = nil
  if pushed.outside ~= nil then
    self:changed(nil, pushed.outside)
  end
end

--- Take a command: the device fades itself over ms (slower than asked by `slow`), or switches at once.
--- One that re-times first restarts the channels the command leaves alone over its ms.
function Device:take(cmd, now)
  whole(self, function()
    if self.o.retimes then
      self:_retime(cmd, now)
    end
    self:_take(cmd, now)
    -- Under echo it answers every command it takes with its targets, changed or not.
    if self.o.policy == "echo" and self.whole.outside == nil then
      self.whole.outside = false
    end
  end)
end

--- One transition for every channel, as an ESPHome light runs: a transition in flight of a channel the
--- command does not set runs on from where it is to its target over the command's ms, at once with none.
--- @private
function Device:_retime(cmd, now)
  local ms = (cmd.ms or 0) * (self.o.slow or 1)
  local tr, ctr = self.tr, self.ctr
  local setsLevel = cmd.level ~= nil
    or (cmd.on ~= nil and cmd.color == nil)
    or (cmd.on == true and not self.on)
    or (cmd.on == true and tr ~= nil and tr.off)
  if tr and not setsLevel then
    if ms > 0 then
      local again = { from = self:brightness(now), to = tr.to, t0 = now, dur = ms, off = tr.off, keep = tr.keep }
      self.tr = again
      self.clock.at(ms, function()
        if self.tr == again then
          self:land(again)
        end
      end)
    else
      self:land(tr)
    end
  end
  if ctr and not cmd.color then
    if ms > 0 then
      local again = { from = self:shownColor(now), to = ctr.to, t0 = now, dur = ms }
      self.ctr = again
      self.clock.at(ms, function()
        if self.ctr == again then
          self.ctr = nil
          self:changed("color")
        end
      end)
    else
      self.ctr = nil
      self:changed("color")
    end
  end
end

--- @private
function Device:_take(cmd, now)
  local o = self.o
  if cmd.level ~= nil then
    self.took[#self.took + 1] = cmd.level
  end
  -- Under "none" a light that does not dim still fades its color: the library keeps every rate for it.
  local ms = ((o.fade == "device" or not o.dims) and cmd.ms or 0) * (o.slow or 1)
  if cmd.color and (o.color or o.cct) then
    local to = { x = cmd.color.x, y = cmd.color.y, mode = cmd.color.kelvin and 1 or 0 }
    if ms > 0 then
      local tr = { from = self:shownColor(now), to = to, t0 = now, dur = ms }
      self.ctr = tr
      self.clock.at(ms, function()
        if self.ctr == tr then
          self.ctr = nil
          self:changed("color") -- the color it ends in is a change, which it reports
        end
      end)
    else
      self.ctr = nil
    end
    self.color, self.kelvin = to, cmd.color.kelvin
    self:changed("color")
  end
  -- A color's on = true lights a light that is off, and holds one fading to off, as a device's On does.
  if cmd.on == true and cmd.level == nil and cmd.color and self.tr and self.tr.off then
    self.level, self.tr = self:brightness(now), nil
    self:changed("level")
    return
  end
  if not (cmd.level ~= nil or (cmd.on ~= nil and cmd.color == nil) or (cmd.on == true and not self.on)) then
    return
  end
  local wasOn = self.on
  if not o.dims then
    if cmd.on ~= nil then
      self.on = cmd.on
    end
  elseif cmd.on == false then
    local from = self:brightness(now)
    if ms > 0 and self.on then
      local tr = { from = from, to = 0, t0 = now, dur = ms, off = true, keep = from }
      self.tr = tr
      self.clock.at(ms, function()
        if self.tr == tr then
          self:land(tr)
        end
      end)
    else
      self.tr = nil
      self.on = false
      self.level = o.keepsLevel and from or 0
    end
  else
    local from = self.on and self:brightness(now) or (o.keepsLevel and self.level or 0)
    local to = cmd.level or (self.level > 0 and self.level or 1)
    self.on = true
    if ms > 0 and to ~= from then
      local tr = { from = from, to = to, t0 = now, dur = ms }
      self.tr = tr
      self.clock.at(ms, function()
        if self.tr == tr then
          self:land(tr)
        end
      end)
    else
      self.tr = nil
      self.level = to
    end
  end
  if self.on ~= wasOn then
    self:changed("onOff")
  end
  if o.dims and (cmd.level ~= nil or self.on ~= wasOn) then
    self:changed("level")
  end
end

--- A transition has run its time.
function Device:land(tr)
  self.tr = nil
  if tr.off then
    self.on = false
    self.level = self.o.keepsLevel and tr.keep or 0
    self:changed("onOff")
  else
    self.level = tr.to
    self:changed("level")
  end
end

--- Another hand's change: at the wall, or in the device's own app. With `quiet` a level goes unreported.
function Device:set(state, now, quiet)
  whole(self, function()
    self:_set(state, quiet)
  end)
end

--- @private
function Device:_set(state, quiet)
  if state.color then
    self.color, self.ctr = { x = state.color.x, y = state.color.y, mode = state.color.mode or 0 }, nil
    self.kelvin = nil
    self:changed("color", true)
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
    local was = self.on
    self.on = state.on
    if was ~= self.on then
      self:changed("onOff", true)
    end
  end
  if state.level ~= nil and not quiet then
    self:changed("level", true)
  end
end

--- The device's whole state, as a report: a device driver that keeps one pushes it with every control.
--- Under echo it reports its targets, as an ESPHome node answers each command.
function Device:report(now)
  if self.o.policy == "echo" then
    local tr, ctr = self.tr, self.ctr
    local st = { on = self.on and not (tr and tr.off), level = tr and not tr.off and tr.to or self.level }
    if self.o.color or self.o.cct then
      st.color = ctr and ctr.to or self.color
    end
    return st
  end
  -- Off, its level control holds the last level it was lit at, as a Zigbee bulb's CurrentLevel does.
  local level = self:reported(now)
  if self.on and level > 0 then
    self.litLevel = level
  elseif not self.on then
    level = self.litLevel or level
  end
  local st = { on = self.on, level = level }
  if self.o.color or self.o.cct then
    st.color = self:shownColor(now)
  end
  return st
end

--- A MemoryLight: a light the library drives through an in-memory device.
--- @param clock table F.virtualClock's clock.
--- @param o table What it is and how it behaves:
---   dims, color, cct ({ min, max }), levelSteps;
---   fade "device" (default) or "none"; keepsLevel (an off light keeps its last level, so it needs a pre-on);
---   policy "trust", "echo" or "settle" (required); settleMs; waitMs (echo); ack "send" or "done";
---   ackMs; match; curve and retimes (fade.curve and fade.retimes); the adapter's hooks takeColor,
---   colorAt and echoes, and token(cmd), what its send returns; sendMs (the clock moves this much in
---   each send, as on a controller slow to pass a message on);
---   latency (ms each way, default 40); readbackMs (settle's read after a transition, default 1500);
---   levelMinMs (settle: a level report at most this often in a transition, default 1000);
---   slow (a fade this many times slower than asked); news (trust: another hand's report says so);
---   pushEveryMs (trust: the whole state pushed this often too, as a provider that polls its device);
---   drop(kind, control) (lose a frame: kind "command", "report" or "read");
---   delay(kind, control) (ms more a report takes, so what follows it overtakes it);
---   hold (with ack "done": a rated on from off has its word at its transition's end, as the 3RCB01057Z);
---   holdShare (0 to 1: that share of rated commands, every so many, has its word at its transition's end);
---   reportLag (ms a report after a transition's end lands late, up to, telling the device as it is then);
---   links (Light.new's opts.links).
--- On the result, loseNext, failNext and foreignNext lose the next command's word, give it as not
--- delivered, or give it with another load's epoch; dropNext loses the next command on its way to the
--- device; dropReads has the device answer no read.
--- @return table m { light, device, adapter, sent, words, declaration, declare, report, other }
function H.memoryLight(clock, o)
  o.fade = o.fade or "device"
  o.latency = o.latency or 40
  o.readbackMs = o.readbackMs or 1500
  o.levelMinMs = o.levelMinMs or 1000
  local Light = require("lib.light")
  local m = { clock = clock, o = o, sent = {}, words = {}, reports = {}, frames = {}, reads = 0 }
  local sends = 0 -- the commands sent so far, which order a read against them
  local untaken = 0 -- the commands queued to the device that it has not taken yet
  local device = setmetatable({
    o = o,
    clock = clock,
    on = false,
    level = o.level or 0,
    color = { x = Color.D65.x, y = Color.D65.y, mode = 1 },
    took = {},
  }, Device)
  device.level = device.level > 0 and device.level or (o.keepsLevel and 1 or 0)
  m.device = device
  m.online = true

  --- The declaration this device makes.
  function m.declaration()
    local d = {
      dims = o.dims,
      color = o.color,
      cct = o.cct,
      levelSteps = o.levelSteps,
      fade = {
        by = o.fade,
        curve = o.curve,
        retimes = o.retimes,
        preOn = o.dims and o.fade == "device" and o.keepsLevel and 0.0039 or nil,
      },
      reports = {
        policy = o.policy,
        settleMs = o.policy == "settle" and (o.settleMs or o.readbackMs + 1000) or nil,
        waitMs = o.policy == "echo" and o.waitMs or nil,
        match = o.match,
      },
    }
    if o.ack then
      d.reports.ack = o.ack
      d.reports.ackMs = o.ack == "done" and o.ackMs or nil
    end
    return d
  end

  local function deliver(st, meta)
    if not m.online then
      return
    end
    m.reports[#m.reports + 1] = { at = clock.now(), state = copy(st), meta = copy(meta) }
    m.light:declare(m.declaration())
    m.lastVerdict = m.light:report(st, meta)
  end

  --- Send a report to the library after the latency, unless it is dropped. A state given as a function is
  --- read as the report lands; an answer is dropped if `since()` says a command went since its read left.
  local function push(st, meta, extra, since)
    if o.drop and o.drop("report", meta.control) then
      return
    end
    -- A delayed report is overtaken by what follows it, as on a mesh.
    local late = o.delay and o.delay("report", meta.control) or 0
    clock.at(o.latency + (extra or 0) + late, function()
      if since and since() then
        return
      end
      deliver(type(st) == "function" and st() or st, meta)
    end)
  end
  m.push = push

  -- A read: under settle each control's answer, final when no transition is in flight, and under trust one
  -- whole report, as a control and an answer are settle's. The device takes a command sent before the
  -- read first, and one sent since, which `since()` tells, outdates the answer: the device driver drops it.
  local readSeq = 0
  local function answerRead(since)
    readSeq = readSeq + 1
    local now = clock.now()
    local moving = device.tr ~= nil or device.ctr ~= nil
    local answer = moving and "moving" or "final"
    if m.dropReads or (o.drop and o.drop("read")) then
      return
    end
    if o.policy ~= "settle" then
      push(device:report(now), {}, 0, since)
      return
    end
    for _, control in ipairs({ "onOff", "level", "color" }) do
      if control ~= "color" or o.color or o.cct then
        push(device:report(now), { control = control, answer = answer }, 0, since)
      end
    end
  end

  -- What the device reports as it changes: its whole state, tagged under settle with the control that moved.
  local lastLevelAt = -1e9
  local levelHeld = false
  function device.changed(_, control, outside)
    local now = clock.now()
    if o.policy == "settle" then
      if control == "level" then
        if levelHeld then
          return
        end
        local wait = lastLevelAt + o.levelMinMs - now
        if wait > 0 then
          levelHeld = true
          clock.at(wait, function()
            levelHeld = false
            device.changed(device, "level")
          end)
          return
        end
        lastLevelAt = now
        if device.tr then
          clock.at(o.levelMinMs, function()
            if device.tr then
              device.changed(device, "level")
            end
          end)
        end
      end
      if o.reportLag and not device.tr then
        -- A late report tells the device as it is when it lands, so a newer command's reports that
        -- overtake it are not undone by the state it left with.
        push(function()
          return device:report(clock.now())
        end, { control = control }, o.reportLag)
      else
        push(device:report(now), { control = control })
      end
    elseif device.whole then
      device.whole.outside = device.whole.outside or outside == true
    else
      push(device:report(now), { news = outside and o.news or nil })
    end
  end

  -- The device side reads the light back once a command's transition has run.
  local readbackSeq = 0
  local function readAfter(mine, ms)
    clock.at(ms + o.readbackMs, function()
      if mine ~= readbackSeq then
        return
      end
      local now = clock.now()
      -- The read left a latency ago: a command sent as it went, or one still queued to the device,
      -- counts as one since.
      local leftAt = now - o.latency - 0.5
      answerRead(function()
        return untaken > 0 or (m.sentAt ~= nil and m.sentAt > leftAt)
      end)
      -- A control still in a transition answered "moving": read again after it, as the device driver does.
      local left
      for _, tr in pairs({ level = device.tr, color = device.ctr }) do
        left = math.max(left or 0, tr.t0 + tr.dur - now)
      end
      if left then
        readAfter(mine, left)
      end
    end)
  end
  local function readBack(ms)
    if o.policy ~= "settle" then
      return
    end
    readbackSeq = readbackSeq + 1
    readAfter(readbackSeq, ms)
  end

  -- The transport: at once under ack "send"; one frame at a time with a word under ack "done".
  local queue, busy = {}, false
  -- A transport made for words keeps one frame at a time even if the light stops asking for them.
  local queued = o.ack == "done"
  local function word(frame, ok)
    m.words[#m.words + 1] = { seq = frame.cmd.seq, ok = ok, at = clock.now() }
    if not frame.lose and o.ack == "done" then
      m.light:done(frame.cmd.seq, ok, frame.epoch or frame.cmd.epoch)
    end
  end
  local function nextFrame()
    if busy or #queue == 0 then
      return
    end
    busy = true
    local frame = table.remove(queue, 1)
    clock.at(o.latency, function()
      local now = clock.now()
      if frame.read then
        answerRead(function()
          return sends > frame.sends
        end)
      else
        untaken = untaken - 1
        -- A rated on from off: from off, or from the pre-on that lights it at the floor.
        local fromOff = (frame.cmd.level or 0) > 0 and (not device.on or device:brightness(now) <= 0.004)
        if not (frame.drop or (o.drop and o.drop("command"))) then
          device:take(frame.cmd, now)
          if frame.cmd.level ~= nil or frame.cmd.on ~= nil then
            readBack((frame.cmd.ms or 0) * (o.slow or 1))
          end
        end
        local ms = frame.cmd.ms or 0
        local waitMs = 3
        local shared = false
        if o.holdShare and ms > 0 then
          m.shareAcc = (m.shareAcc or 0) + o.holdShare
          if m.shareAcc >= 1 then
            m.shareAcc, shared = m.shareAcc - 1, true
          end
        end
        if o.hold and ms > 0 and (fromOff or shared) then
          waitMs = ms -- the bulb holds its word to the transition's end
        end
        if m.holdWordsUntil then
          waitMs = math.max(waitMs, m.holdWordsUntil - now)
        end
        clock.at(waitMs, function()
          if not frame.read then
            word(frame, not frame.fail)
          end
          busy = false
          nextFrame()
        end)
        return
      end
      clock.at(math.max(3, (m.holdWordsUntil or 0) - now), function()
        busy = false
        nextFrame()
      end)
    end)
  end

  local adapter = {}
  m.adapter = adapter

  function adapter:send(cmd)
    local c = copy(cmd)
    c.at = clock.now()
    m.sent[#m.sent + 1] = c
    m.sentAt, sends = c.at, sends + 1
    -- Offline, the transport drops what it cannot send, as the header asks of it.
    if not m.online then
      return nil
    end
    if queued then
      local frame = {
        cmd = c,
        lose = m.loseNext,
        fail = m.failNext,
        drop = m.dropNext,
        epoch = m.foreignNext and "another load" or m.epochOverride,
      }
      m.loseNext, m.failNext, m.foreignNext, m.dropNext = nil, nil, nil, nil
      queue[#queue + 1], untaken = frame, untaken + 1
      nextFrame()
      return
    end
    clock.at(o.latency, function()
      if o.drop and o.drop("command") then
        return
      end
      device:take(c, clock.now())
      if c.level ~= nil or c.on ~= nil then
        readBack((c.ms or 0) * (o.slow or 1))
      end
    end)
    -- A controller slow to pass a message on: the clock moves while it sends.
    if o.sendMs then
      clock.run(o.sendMs)
    end
    return o.token and o.token(c) or nil
  end
  adapter.takeColor, adapter.colorAt, adapter.echoes = o.takeColor, o.colorAt, o.echoes

  function adapter:refresh()
    m.reads = m.reads + 1
    if not m.online then
      return
    end
    if queued then
      queue[#queue + 1] = { read = true, cmd = {}, sends = sends }
      nextFrame()
      return
    end
    -- A command sent after the read, even at the same instant, is one since.
    local asked = sends
    clock.at(o.latency, function()
      answerRead(function()
        return sends > asked
      end)
    end)
  end

  function adapter:rangeChanged(lo, hi)
    m.range = { lo, hi }
  end

  m.light = Light.new(adapter, { links = o.links })

  -- A provider that relays its device pushes the whole state now and then, its polls among them.
  local pushing = false
  local function pushEvery()
    if pushing or not o.pushEveryMs then
      return
    end
    pushing = true
    local function tick()
      clock.at(o.pushEveryMs, function()
        if m.online then
          push(device:report(clock.now()), {})
        end
        tick()
      end)
    end
    tick()
  end

  --- Bring the device online: it declares, and reports its whole state.
  function m.connect()
    m.online = true
    m.light:declare(m.declaration())
    deliver(device:report(clock.now()), {})
    pushEvery()
  end

  --- A stall, as the 3RCB01057Z had them: every word waits until `untilAt` (absolute virtual time)
  --- while the device runs what it has taken, and its last `again` reports come again.
  function m.stall(untilAt, again)
    m.holdWordsUntil = untilAt
    for i = math.max(1, #m.reports - (again or 0) + 1), #m.reports do
      local r = m.reports[i]
      push(r.state, r.meta)
    end
  end

  --- A report delivered at an absolute virtual time, as a replayed take has it.
  function m.inject(at, st, meta)
    clock.at(at - clock.now(), function()
      deliver(st, meta or {})
    end)
  end

  --- Another hand's change; with `quiet` its level goes unreported.
  function m.other(state, quiet)
    device:set(state, clock.now(), quiet)
  end

  --- The device is lost, and back.
  function m.drop()
    m.online = false
    queue, busy, untaken = {}, false, 0
    m.light:offline()
  end
  function m.back()
    m.connect()
  end

  --- The device binding is unbound, and bound: the light is forgotten at each, as an adapter does in
  --- OnBindingChanged. Unbound the device cannot be reached; bound, its whole state is its first report.
  function m.unbind()
    m.online = false
    queue, busy, untaken = {}, false, 0
    m.light:forget()
  end
  function m.bind()
    m.light:forget()
    m.online = true
    clock.at(o.latency, function()
      if m.online then
        m.connect()
      end
    end)
  end

  return m
end

---------------------------------------------------------------------------
-- A world: a clock, a fake proxy and a MemoryLight, started and online
---------------------------------------------------------------------------

local function sameXY(a, b, tolerance)
  return a and b and math.abs(a.x - b.x) <= (tolerance or 0.01) and math.abs(a.y - b.y) <= (tolerance or 0.01)
end

local function levelOf(state, lo, hi, dims)
  if not state.on then
    return 0
  end
  if not dims then
    return 100
  end
  return Range.toLevel(state.level, lo, hi)
end

--- A device's color as xy: a white it gives by its kelvin, at that kelvin's point.
local function xyOf(color)
  if type(color) ~= "table" then
    return nil
  end
  if color.kelvin then
    local x, y = C4:ColorCCTtoXY(color.kelvin)
    return { x = x, y = y }
  end
  return color.x and { x = color.x, y = color.y } or nil
end

--- A color the contract sends: (x, y) as a full color on a light with color, else the white of
--- `kelvin`; with no x, that white on any light. `params(rate)` is its SET_COLOR_TARGET.
local function colorTarget(device, x, y, kelvin)
  local t = { x = x, y = y, mode = 0 }
  if not (x and device.color) then
    t.x, t.y = C4:ColorCCTtoXY(kelvin)
    t.mode, t.kelvin = 1, kelvin
  end
  function t.params(rate)
    return {
      LIGHT_COLOR_TARGET_X = t.x,
      LIGHT_COLOR_TARGET_Y = t.y,
      LIGHT_COLOR_TARGET_MODE = t.mode,
      LIGHT_COLOR_TARGET_COLOR_RATE = rate,
    }
  end
  return t
end

--- Push the proxy's color on mode: `preset` ({ x, y, mode }) as the On color, or none, so an On keeps
--- the color the light holds.
local function colorOnMode(p, preset)
  p:send("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = preset and 1 or 0,
    COLOR_PRESET_ORIGIN = preset and 1 or 0,
    COLOR_PRESET_COLOR_X = preset and preset.x,
    COLOR_PRESET_COLOR_Y = preset and preset.y,
    COLOR_PRESET_COLOR_MODE = preset and preset.mode,
    COLOR_FADE_PRESET_ID = 0,
    COLOR_FADE_PRESET_ORIGIN = 0,
  })
end

--- Where the proxy's last CHANGING of `cmd` has the light at `now`, while it runs: { level } or { x, y }.
local function estimate(p, cmd, now)
  for i = #p.notes, 1, -1 do
    local n = p.notes[i]
    if n.binding == H.PROXY and n.cmd == cmd then
      local q = n.params
      local rate = tonumber(q.RATE or q.LIGHT_COLOR_TARGET_COLOR_RATE) or 0
      if now >= n.at + rate then
        return nil
      end
      local f = math.min(1, (now - n.at) / rate)
      if cmd == "LIGHT_BRIGHTNESS_CHANGING" then
        local from, to = q.LIGHT_BRIGHTNESS_CURRENT, q.LIGHT_BRIGHTNESS_TARGET
        return { level = from + (to - from) * f }
      end
      local x, y = q.LIGHT_COLOR_CURRENT_X, q.LIGHT_COLOR_CURRENT_Y
      return { x = x + (q.LIGHT_COLOR_TARGET_X - x) * f, y = y + (q.LIGHT_COLOR_TARGET_Y - y) * f }
    end
  end
  return nil
end

--- A started MemoryLight behind a fake proxy, on a virtual clock. `opts` is H.memoryLight's, plus the
--- proxy's setup and newLight.
--- @return table w { clock, proxy, m, light, device, run, restore }
function H.world(opts)
  local clock = F.virtualClock()
  local proxy = H.proxy(clock, { setup = opts.setup, newLight = opts.newLight, links = opts.links })
  local restore = opened(clock, function()
    proxy:restore()
    clock.restore()
  end)
  local m = H.memoryLight(clock, opts)
  local w = { clock = clock, proxy = proxy, m = m, light = m.light, device = m.device, restore = restore }
  function w.run(ms)
    clock.run(ms)
  end
  --- The device's level as the proxy would show it: 0 when off.
  function w.devicePercent()
    local lo, hi = m.light:range()
    return levelOf(m.device:state(clock.now()), lo, hi, opts.dims)
  end
  m.light:start()
  if not opts.offline then
    m.connect()
    clock.run(opts.settle or 20000)
  end
  proxy:mark()
  m.sent = {}
  return w
end

---------------------------------------------------------------------------
-- The contract run
---------------------------------------------------------------------------

--- A rig for H.contract over a MemoryLight made with `o`: the reference adapter proves the runner.
--- @param name string
--- @param o table H.memoryLight's options.
--- @return table rig
function H.memoryRig(name, o)
  local rig = { name = name, settleMs = o.settleMs, links = o.links ~= false, setup = o.setup }
  local probe = H.memoryLight(F.virtualClock(), H.copy(o))
  rig.declarations = { probe.declaration() }
  ShimSetClock(nil)
  function rig.load(h)
    local m = H.memoryLight(h.clock, H.copy(o))
    h.memory, h.light = m, m.light
    m.light:start()
    m.connect()
    local device = {
      state = function()
        return m.device:state(h.clock.now())
      end,
      set = m.other,
      drop = m.drop,
      back = m.back,
      dims = o.dims,
      color = o.color,
      cct = o.cct,
      stops = o.fade ~= "none",
      declaration = m.declaration,
    }
    if o.ack == "done" then
      function device.hold(on)
        m.o.hold = on
      end
      function device.loseWord()
        m.loseNext = true
      end
      function device.foreignWord()
        m.foreignNext = true
      end
      function device.failWord()
        m.dropNext, m.failNext = true, true
      end
      function device.dropReads(on)
        m.dropReads = on
      end
      function device.taken()
        return copy(m.device.took)
      end
    end
    return device
  end
  rig.holds = o.ack == "done"
  return rig
end

--- Prove a driver's adapter against the contract. Each check loads the driver afresh through
--- `rig.load(h)`, which gets { clock, proxy } and returns the device handle.
--- @param T table testlib
--- @param rig table { name, load, declarations, driverXml, links, settleMs, setup, holds }
function H.contract(T, rig)
  local name = rig.name or "light"
  local wait = (rig.settleMs or 12000) + 5000
  local function case(fn)
    H.case(T, fn, name)
  end

  local function fresh()
    local clock = F.virtualClock()
    local proxy = H.proxy(clock, { setup = rig.setup, links = rig.links == false and false or nil })
    local h = { clock = clock, proxy = proxy }
    local errors = {}
    local log = require("lib.logging")
    local logError = log.error
    log.error = function(self, fmt, ...)
      errors[#errors + 1] = string.format(tostring(fmt), ...)
      return logError(self, fmt, ...)
    end
    h.errors = errors
    h.done = opened(clock, function()
      log.error = logError
      proxy:restore()
      clock.restore()
    end)
    h.device = rig.load(h)
    clock.run(wait)
    function h.shown()
      return proxy.level
    end
    function h.devicePercent()
      local lo, hi = 1, 100
      if h.light then
        lo, hi = h.light:range()
      end
      return levelOf(h.device.state(), lo, hi, h.device.dims)
    end
    return h
  end

  T.section(name .. ": every declaration names a policy, and declare logs no error")
  case(function()
    for i, decl in ipairs(rig.declarations or {}) do
      local checked, errors = Caps.check(decl)
      T.check(name .. ": declaration " .. i .. " is accepted", checked ~= nil, table.concat(errors, "; "))
      T.eq(name .. ": declaration " .. i .. " has no bad field", errors, {})
    end
  end)

  if rig.driverXml then
    T.section(name .. ": driver.xml declares the static block the library relies on")
    case(function()
      local f = assert(io.open(rig.driverXml, "rb"))
      local xml = f:read("*a")
      f:close()
      T.eq(
        name .. ": every static capability as the library relies on it",
        Caps.staticMismatches(xml, rig.links ~= false),
        {}
      )
    end)
  end

  T.section(name .. ": online, the proxy is told the capabilities of the declaration in force, once")
  case(function()
    local h = fresh()
    local caps = h.proxy.caps
    T.check(name .. ": the capabilities were told", caps ~= nil)
    if caps and h.device.declaration then
      T.eq(name .. ": as the declaration derives them", caps, Caps.dynamic((Caps.check(h.device.declaration()))))
    end
    T.eq(name .. ": declare logged no error", h.errors, {})
    h.done()
  end)

  T.section(name .. ": on, off, a level and a color reach the device and come back as the proxy shows")
  case(function()
    local h = fresh()
    local p = h.proxy
    p:send("ON")
    h.clock.run(wait)
    T.check(name .. ": an On lights the device", h.device.state().on == true)
    T.eq(name .. ": and the proxy shows where it is", p.level, h.devicePercent())
    p:send("OFF")
    h.clock.run(wait)
    T.check(name .. ": an Off turns it off", h.device.state().on == false)
    T.eq(name .. ": and the proxy shows it off", p.level, 0)
    if h.device.dims then
      p:send("SET_LEVEL", { LEVEL = 40 })
      h.clock.run(wait)
      T.eq(name .. ": a level reaches the device", h.devicePercent(), 40)
      T.eq(name .. ": and the proxy shows it", p.level, 40)
    end
    if h.device.color then
      p:send(
        "SET_COLOR_TARGET",
        { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
      )
      h.clock.run(wait)
      local color = h.device.state().color
      T.check(name .. ": a color reaches the device", sameXY(color, { x = 0.6, y = 0.3 }), T.show(color))
      T.check(name .. ": and the proxy shows it", sameXY(p.color, { x = 0.6, y = 0.3 }), T.show(p.color))
    end
    if h.device.cct then
      local white = colorTarget(h.device, nil, nil, 4000)
      p:send("SET_COLOR_TARGET", white.params(0))
      h.clock.run(wait)
      local color = h.device.state().color or {}
      local kelvin = color.kelvin or (color.x and C4:ColorXYtoCCT(color.x, color.y))
      T.check(
        name .. ": a color temperature reaches the device",
        kelvin ~= nil and math.abs(kelvin - 4000) <= 40,
        T.show({ device = color, kelvin = kelvin })
      )
      T.check(
        name .. ": and the proxy shows it as one",
        p.color ~= nil and p.color.mode == 1 and sameXY(p.color, white),
        T.show(p.color)
      )
    end
    T.eq(name .. ": no callback threw", h.clock.errors, {})
    h.done()
  end)

  T.section(name .. ": a color sent to a light that is off, or fading to off, does not light it, and is kept")
  case(function()
    local h = fresh()
    local p = h.proxy
    if h.device.color or h.device.cct then
      local a, b = colorTarget(h.device, 0.6, 0.3, 2700), colorTarget(h.device, 0.3, 0.5, 6000)
      colorOnMode(p, nil)
      p:send("OFF")
      h.clock.run(wait)
      p:mark()
      p:send("SET_COLOR_TARGET", a.params(0))
      h.clock.run(wait)
      T.eq(name .. ": at once to a light that is off: it stays off", h.device.state().on, false)
      p:send("SET_COLOR_TARGET", b.params(2000))
      h.clock.run(wait)
      T.eq(name .. ": over a rate: it stays off", h.device.state().on, false)
      T.eq(name .. ": and the proxy is told no level", p:changed(), {})
      p:send("ON")
      h.clock.run(wait)
      local color = xyOf(h.device.state().color)
      T.check(
        name .. ": the next On comes on in it, as the proxy shows",
        sameXY(color, b) and sameXY(p.color, b),
        T.show({ device = color, shown = p.color })
      )
      p:send("OFF")
      h.clock.run(wait)
      if h.device.dims and h.device.stops ~= false then
        p:send("SET_LEVEL", { LEVEL = 60 })
        h.clock.run(wait)
        p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
        h.clock.run(1000)
        p:send("SET_COLOR_TARGET", a.params(500))
        h.clock.run(wait)
        T.eq(name .. ": fading to off: the fade still ends off", h.device.state().on, false)
        T.eq(name .. ": as the proxy shows", p.level, 0)
      end
    end
    T.eq(name .. ": no callback threw", h.clock.errors, {})
    h.done()
  end)

  if rig.dims ~= false then
    T.section(name .. ": a rated on from off never jumps above its target, tells CHANGING from 1, keeps Previous On")
    case(function()
      local h = fresh()
      local p = h.proxy
      if h.device.dims then
        p:send("SET_LEVEL", { LEVEL = 60 })
        h.clock.run(wait)
        p:send("OFF")
        h.clock.run(wait)
        p:mark()
        p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 4000 })
        local highest = 0
        for _ = 1, 40 do
          h.clock.run(100)
          highest = math.max(highest, h.devicePercent())
        end
        h.clock.run(wait)
        T.check(name .. ": the device never goes above 50", highest <= 51, highest)
        local changing = p:told("LIGHT_BRIGHTNESS_CHANGING")[1]
        if h.device.stops == false then
          T.eq(name .. ": a light that does not fade is told no CHANGING", changing, nil)
        else
          T.eq(name .. ": CHANGING from 1", (changing or {}).LIGHT_BRIGHTNESS_CURRENT, 1)
        end
        T.eq(name .. ": it lands on 50", p.level, 50)
        p:send("OFF")
        h.clock.run(wait)
        T.eq(name .. ": the next off keeps Previous On at 50", p.previousOn, 50)
      end
      h.done()
    end)

    T.section(name .. ": a stop holds within one device step, and a retarget starts where the light is")
    case(function()
      local h = fresh()
      local p = h.proxy
      if h.device.dims and h.device.stops ~= false then
        p:send("SET_LEVEL", { LEVEL = 10 })
        h.clock.run(wait)
        p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 8000 })
        h.clock.run(4000)
        local mid = h.devicePercent()
        T.check(name .. ": half way through its rate the device is part way", mid > 30 and mid < 70, mid)
        p:send("SET_BRIGHTNESS_STOP")
        h.clock.run(wait)
        local at = h.devicePercent()
        T.check(name .. ": the device holds part way", at > 30 and at < 70, at)
        T.check(
          name .. ": the proxy shows where it holds",
          math.abs((p.level or -9) - at) <= 1,
          T.show({ shown = p.level, device = at })
        )
        p:mark()
        p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 10, RATE = 4000 })
        local changing = p:told("LIGHT_BRIGHTNESS_CHANGING")[1] or {}
        T.check(
          name .. ": a retarget's CHANGING starts where the light is",
          math.abs((changing.LIGHT_BRIGHTNESS_CURRENT or -9) - at) <= 1,
          T.show(changing)
        )
        h.clock.run(wait)
      end
      h.done()
    end)

    T.section(name .. ": a rated off fades the device over its rate, and ends off")
    case(function()
      local h = fresh()
      local p = h.proxy
      if h.device.dims and h.device.stops ~= false then
        p:send("SET_LEVEL", { LEVEL = 80 })
        h.clock.run(wait)
        p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
        h.clock.run(2000)
        local mid = h.devicePercent()
        T.check(name .. ": half way through its rate the device is lit, part way", mid > 20 and mid < 60, mid)
        h.clock.run(wait)
        T.eq(name .. ": it ends off, as the proxy shows", { h.device.state().on, p.level }, { false, 0 })
      end
      h.done()
    end)
  end

  T.section(name .. ": another hand's change is told by the declared policy's own rule, and nothing it does is hidden")
  case(function()
    local h = fresh()
    local p = h.proxy
    local declared = h.device.declaration and h.device.declaration()
    local settle = declared ~= nil and declared.reports.policy == "settle"
    if h.device.dims then
      p:send("SET_LEVEL", { LEVEL = 30 })
      h.clock.run(wait)
      h.device.set({ on = true, level = 0.7 })
      h.clock.run(wait)
      T.eq(name .. ": a level from another hand outside a ramp shows", p.level, h.devicePercent())
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 6000 })
      h.clock.run(2000)
      h.device.set({ on = true, level = 0.5 })
      h.clock.run(wait + 6000)
      T.eq(name .. ": one during a ramp, on its path, shows by the ramp's or window's end", p.level, h.devicePercent())
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90, RATE = 6000 })
      h.clock.run(2000)
      h.device.set({ on = false })
      h.clock.run(2000)
      if settle then
        T.eq(name .. ": under settle an off during a ramp shows once a read answers it", p.level, 0)
      end
      h.clock.run(wait + 6000)
      T.eq(name .. ": an off during a ramp shows by the ramp's or window's end", p.level, 0)
    end
    p:send("ON")
    h.clock.run(wait)
    local stale = p.level
    h.device.set({ on = false })
    h.clock.run(wait)
    T.eq(name .. ": an off from another hand shows", p.level, 0)
    p:mark()
    if h.device.dims then
      -- Back on at a level the device never reported, so only a read can show it.
      h.device.set({ on = true, level = stale >= 50 and 0.2 or 0.8 }, true)
    else
      h.device.set({ on = true })
    end
    h.clock.run(wait)
    T.eq(name .. ": an on after another hand's off shows, with its level", p.level, h.devicePercent())
    if h.device.dims then
      local told = {}
      for _, n in ipairs(p.notes) do
        if n.cmd == "LIGHT_BRIGHTNESS_CHANGED" or n.cmd == "LIGHT_BRIGHTNESS_CHANGING" then
          told[#told + 1] = n.params.LIGHT_BRIGHTNESS_CURRENT
        end
      end
      local shown = false
      for _, level in ipairs(told) do
        shown = shown or level == stale
      end
      T.check(name .. ": and never at the level it went off at", not shown, T.show({ stale = stale, told = told }))
    end
    T.eq(name .. ": no callback threw", h.clock.errors, {})
    h.done()
  end)

  -- The suites' "told X and nothing else": in each command's window, from its send to the next
  -- command's, the proxy is told only its target, a stop's estimate, or where the device is at the end.
  local function windows(h, steps)
    local p = h.proxy
    local runs = {}
    p:mark()
    for _, s in ipairs(steps) do
      local now = h.clock.now()
      local win = { cmd = s[1], at = now, level = s.level, color = s.color }
      -- A level stop also stops the color its ramp carries, as under Dim-To-Warm.
      if s[1] == "SET_BRIGHTNESS_STOP" then
        win.levelStop = estimate(p, "LIGHT_BRIGHTNESS_CHANGING", now)
      end
      if s[1] == "SET_BRIGHTNESS_STOP" or s[1] == "SET_COLOR_STOP" then
        win.colorStop = estimate(p, "LIGHT_COLOR_CHANGING", now)
      end
      runs[#runs + 1] = win
      p:send(s[1], s[2])
      h.clock.run(s.runMs or wait)
      win.endLevel, win.endColor = h.devicePercent(), xyOf(h.device.state().color)
    end
    local unexplained = {}
    for i, win in ipairs(runs) do
      local to = runs[i + 1] and runs[i + 1].at or math.huge
      local lastLevel, lastColor
      for _, n in ipairs(p.notes) do
        if n.binding == H.PROXY and n.at >= win.at and n.at < to then
          if n.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
            local level = n.params.LIGHT_BRIGHTNESS_CURRENT
            local stop = win.levelStop and win.levelStop.level
            local ok = level == win.level
              or (stop and math.abs(level - stop) <= 1)
              or math.abs(level - win.endLevel) <= 1
            if not ok or level == lastLevel then
              unexplained[#unexplained + 1] = win.cmd .. ": level " .. tostring(level)
            end
            lastLevel = level
          elseif n.cmd == "LIGHT_COLOR_CHANGED" then
            local c = { x = n.params.LIGHT_COLOR_CURRENT_X, y = n.params.LIGHT_COLOR_CURRENT_Y }
            local ok = sameXY(c, win.color) or sameXY(c, win.colorStop) or sameXY(c, win.endColor)
            if not ok or sameXY(c, lastColor, 1e-4) then
              unexplained[#unexplained + 1] = string.format("%s: color %.4f, %.4f", win.cmd, c.x, c.y)
            end
            lastColor = c
          end
        end
      end
    end
    return unexplained
  end

  T.section(name .. ": the model tells Control4: in each level command's window, its target, a stop's, or the device")
  case(function()
    local h = fresh()
    local dims = h.device.dims
    T.eq(
      name .. ": nothing told that the window's command, its stop or the device at its end does not explain",
      windows(h, {
        { "SET_LEVEL", { LEVEL = 25 }, level = dims and 25 or 100 },
        { "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 75, RATE = 3000 }, level = 75, runMs = 1500 },
        { "SET_BRIGHTNESS_STOP" },
        { "OFF", level = 0 },
        { "ON" },
      }),
      {}
    )
    h.done()
  end)

  T.section(name .. ": the model tells Control4: in each color command's window, its target, a stop's, or the device")
  case(function()
    local h = fresh()
    if h.device.color or h.device.cct then
      local a, b = colorTarget(h.device, 0.6, 0.3, 2700), colorTarget(h.device, 0.3, 0.5, 6000)
      local white = colorTarget(h.device, nil, nil, 4000)
      T.eq(
        name .. ": nothing told that the window's command, its stop or the device at its end does not explain",
        windows(h, {
          { "SET_LEVEL", { LEVEL = 60 }, level = h.device.dims and 60 or 100 },
          { "SET_COLOR_TARGET", a.params(0), color = a },
          { "SET_COLOR_TARGET", b.params(3000), color = b, runMs = 1500 },
          { "SET_COLOR_STOP" },
          { "SET_COLOR_TARGET", white.params(0), color = white },
        }),
        {}
      )
    end
    h.done()
  end)

  T.section(name .. ": under settle, a rated on in an on color tells it once, whatever the device reports first")
  case(function()
    local h = fresh()
    local p = h.proxy
    local declared = h.device.declaration and h.device.declaration()
    if declared and declared.reports.policy == "settle" and h.device.dims and (h.device.color or h.device.cct) then
      local on, before = colorTarget(h.device, 0.6, 0.3, 2700), colorTarget(h.device, 0.3, 0.5, 6000)
      colorOnMode(p, on)
      p:send("SET_LEVEL", { LEVEL = 60 })
      p:send("SET_COLOR_TARGET", before.params(0))
      h.clock.run(wait)
      p:send("OFF")
      h.clock.run(wait)
      p:mark()
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
      h.clock.run(3000 + wait)
      local told = {}
      for _, q in ipairs(p:told("LIGHT_COLOR_CHANGED")) do
        told[#told + 1] = { x = q.LIGHT_COLOR_CURRENT_X, y = q.LIGHT_COLOR_CURRENT_Y }
      end
      T.check(
        name .. ": the proxy is told the on color once, and never the color the device reports first",
        #told == 1 and sameXY(told[1], on),
        T.show(told)
      )
      local color = xyOf(h.device.state().color)
      T.check(name .. ": and the device is in it", sameXY(color, on), T.show(color))
      -- It persists across loads: later checks run with none, or with the on mode the rig's setup names.
      colorOnMode(p, nil)
    end
    h.done()
  end)

  T.section(name .. ": offline, the proxy is told so with the LEDs off; back, the capabilities once and a setup read")
  case(function()
    local h = fresh()
    local p = h.proxy
    p:send("ON")
    h.clock.run(wait)
    p:mark()
    h.device.drop()
    h.clock.run(wait)
    T.eq(name .. ": ONLINE_CHANGED false", p.online, false)
    T.eq(name .. ": and off", p.level, 0)
    if rig.links ~= false then
      T.eq(name .. ": the Top LED is off", p.leds[H.LINKS.top], false)
    end
    p:mark()
    h.device.back()
    h.clock.run(wait)
    T.eq(name .. ": back online", p.online, true)
    T.eq(name .. ": the capabilities told once", #p:told("DYNAMIC_CAPABILITIES_CHANGED"), 1)
    T.check(name .. ": and the setup read again", p.setupReads >= 1, p.setupReads)
    T.eq(name .. ": the proxy shows the device", p.level, h.devicePercent())
    T.eq(name .. ": no error was logged", h.errors, {})
    h.done()
  end)

  T.section(name .. ": a command the declaration rules out sends nothing")
  case(function()
    local h = fresh()
    local p = h.proxy
    if not (h.device.color or h.device.cct) then
      local before = h.device.state()
      p:send(
        "SET_COLOR_TARGET",
        { LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_COLOR_RATE = 0 }
      )
      h.clock.run(wait)
      T.eq(name .. ": a color to a light with none: no color told", p:told("LIGHT_COLOR_CHANGED"), {})
      T.eq(name .. ": and the device is as it was", h.device.state().on, before.on)
    end
    if h.device.stops == false and h.device.dims then
      p:mark()
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 5000 })
      T.eq(name .. ": a light that dims and does not fade is told no CHANGING", p:told("LIGHT_BRIGHTNESS_CHANGING"), {})
      p:send("SET_BRIGHTNESS_STOP")
      T.eq(name .. ": and a stop tells it nothing", #p:told("LIGHT_BRIGHTNESS_CHANGED"), 1)
      h.clock.run(wait)
    end
    h.done()
  end)

  if rig.holds then
    T.section(
      name .. ": the outbox: a burst while a frame is held reaches the device as the held command and the newest"
    )
    case(function()
      local h = fresh()
      local p = h.proxy
      local declared = Caps.check(h.device.declaration())
      local preOn = declared.fade.preOn
      p:send("OFF")
      h.clock.run(wait)
      h.device.hold(true)
      local before = #h.device.taken()
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
      for _, level in ipairs({ 80, 60, 40 }) do
        h.clock.run(300)
        p:send("SET_LEVEL", { LEVEL = level })
      end
      h.clock.run(wait + 5000)
      local taken, lo, hi = h.device.taken(), 1, 100
      if h.light then
        lo, hi = h.light:range()
      end
      -- Only the held command's own pre-on is left out, at the device's nearest step to it.
      local first = before + 1
      local halfStep = declared.levelSteps and 0.5 / declared.levelSteps or 1e-6
      if preOn and taken[first] and math.abs(taken[first] - preOn) <= halfStep then
        first = first + 1
      end
      local levels = {}
      for i = first, #taken do
        levels[#levels + 1] = Range.toLevel(taken[i], lo, hi)
      end
      T.eq(name .. ": the device takes the held command, then the newest, and nothing between", levels, { 100, 40 })
      T.eq(name .. ": the light lands where Control4 was told last", h.devicePercent(), 40)
      T.eq(name .. ": and the proxy shows it", p.level, 40)
      h.device.hold(false)
      h.done()
    end)

    T.section(name .. ": the ledger: another hand's Off during a held rated on from off is told after the word")
    case(function()
      local h = fresh()
      local p = h.proxy
      p:send("OFF")
      h.clock.run(wait)
      h.device.hold(true)
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
      h.clock.run(2000)
      p:mark()
      h.device.set({ on = false })
      h.clock.run(500)
      T.eq(name .. ": while the word is held the off tells nothing", p:changed(), {})
      h.clock.run(wait + 5000)
      T.eq(name .. ": after it the light shows off", p.level, 0)
      T.eq(name .. ": as the device is", h.devicePercent(), 0)
      h.device.hold(false)
      h.done()
    end)

    T.section(name .. ": the ledger: a replaced command's late report is not what the proxy ends on")
    case(function()
      local h = fresh()
      local p = h.proxy
      p:send("OFF")
      h.clock.run(wait)
      h.device.hold(true)
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
      h.clock.run(2000)
      p:mark()
      p:send("SET_LEVEL", { LEVEL = 30 })
      h.clock.run(wait + 5000)
      T.eq(name .. ": the proxy is told the newest command's level and nothing else", p:changed(), { 30 })
      T.eq(name .. ": where the device is", h.devicePercent(), 30)
      h.device.hold(false)
      h.done()
    end)

    T.section(name .. ": the ledger: a command waiting behind the held one goes at the word and supersedes the read")
    case(function()
      local h = fresh()
      local p = h.proxy
      p:send("OFF")
      h.clock.run(wait)
      h.device.hold(true)
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 })
      h.clock.run(1000)
      h.device.set({ on = false })
      h.clock.run(200)
      p:mark()
      p:send("SET_LEVEL", { LEVEL = 40 })
      h.clock.run(wait + 5000)
      T.eq(name .. ": the proxy is told that command's level and nothing else", p:changed(), { 40 })
      T.eq(name .. ": where the device is", h.devicePercent(), 40)
      h.device.hold(false)
      h.done()
    end)

    T.section(name .. ": the ledger: a read whose answer never comes does not hold back the next one")
    case(function()
      local h = fresh()
      local p = h.proxy
      local decl = Caps.check(h.device.declaration())
      p:send("OFF")
      h.clock.run(wait)
      h.device.hold(true)
      h.device.dropReads(true)
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 })
      h.clock.run(500)
      h.device.set({ on = false })
      h.clock.run(3000 + (decl.reports.settleMs or 0) + 500)
      h.device.dropReads(false)
      p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 3000 })
      h.clock.run(500)
      h.device.set({ on = false })
      -- Within a second of the word, before a read-back after the transition could show it.
      h.clock.run(3500)
      T.eq(name .. ": another hand's off after it asks a read, which shows it at the word", p.level, 0)
      h.clock.run(wait)
      T.eq(name .. ": as the device is", { p.level, h.devicePercent() }, { 0, 0 })
      h.device.hold(false)
      h.done()
    end)

    T.section(name .. ": the ledger: a word that never comes lets what waits go at the timeout, else reads the light")
    case(function()
      local h = fresh()
      local p = h.proxy
      local decl = Caps.check(h.device.declaration())
      p:send("SET_LEVEL", { LEVEL = 20 })
      h.clock.run(wait)
      h.device.loseWord()
      p:send("SET_LEVEL", { LEVEL = 50 })
      p:send("SET_LEVEL", { LEVEL = 60 })
      h.clock.run(decl.reports.ackMs - 1000)
      T.eq(name .. ": what waits holds for the word", h.devicePercent(), 50)
      h.clock.run(wait)
      T.eq(name .. ": and goes at the timeout", { p.level, h.devicePercent() }, { 60, 60 })
      h.device.loseWord()
      p:send("SET_LEVEL", { LEVEL = 30 })
      h.clock.run(1000)
      h.device.set({ on = true, level = 0.7 })
      h.clock.run(decl.reports.ackMs + wait)
      T.eq(name .. ": with nothing waiting, the timeout reads the light", p.level, h.devicePercent())
      h.done()
    end)

    T.section(name .. ": the ledger: a word saying not delivered reads the light, and shows where it is")
    case(function()
      local h = fresh()
      local p = h.proxy
      p:send("SET_LEVEL", { LEVEL = 20 })
      h.clock.run(wait)
      h.device.failWord()
      p:send("SET_LEVEL", { LEVEL = 50 })
      h.clock.run(wait)
      T.eq(name .. ": the proxy shows the level the lost command left", { p.level, h.devicePercent() }, { 20, 20 })
      h.done()
    end)

    T.section(name .. ": the ledger: a word from another load is ignored")
    case(function()
      local h = fresh()
      local p = h.proxy
      local decl = Caps.check(h.device.declaration())
      p:send("SET_LEVEL", { LEVEL = 20 })
      h.clock.run(wait)
      h.device.foreignWord()
      p:send("SET_LEVEL", { LEVEL = 70 })
      p:send("SET_LEVEL", { LEVEL = 75 })
      h.clock.run(5000)
      T.eq(name .. ": what waits still holds for the command's own word", h.devicePercent(), 70)
      h.clock.run(decl.reports.ackMs + wait)
      T.eq(name .. ": and goes at the timeout", { p.level, h.devicePercent() }, { 75, 75 })
      h.done()
    end)
  end
end

return H
