--- The Light V2 library. It owns every Light V2 proxy behavior: the proxy's commands and
--- notifications, presets, brightness and color on modes, Dim-To-Warm and Previous On, Advanced
--- Lighting Scenes, the button links and their LEDs, Min and Max On Level, the GET_SETUP read and
--- the capabilities Composer reads. A light driver is a small adapter that puts the library's device
--- commands on its transport and reports what the device says.
---
--- ## What you write
---
--- An adapter table with `send(cmd)`, `refresh()` under the settle policy, and any other hook below
--- that your transport needs.
---
--- ```lua
--- local Light = require("lib.light")
--- local adapter = {}
--- function adapter:send(cmd) end -- put a LightCommand on the wire, or queue it, and return
--- local light = Light.new(adapter) -- once, in the driver chunk
--- function OnDriverLateInit()
---   light:start()
--- end
--- ```
---
--- ## What you call
---
--- - `Light.new(adapter, opts)` once, at the top level of driver.lua. `opts.proxy` is the proxy
---   binding (5001); `opts.links` is `{ top = 300, toggle = 301, bottom = 302 }`, or false for none.
--- - `light:start()` from OnDriverLateInit.
--- - `light:declare(caps)` on every connection before its first report, and whenever the device's
---   capabilities change. Name the report policy every time (`reports.policy`): there is no default.
--- - `light:report(state, meta)` for every state the device gives, in the order it gave them. A color
---   the device took comes back in the terms it was sent, xy or kelvin, within `reports.match` of it:
---   one that differs is told as another hand's change. Under `echo` the color may be a function of
---   its verdict's kind, for a reading that depends on whose the report is; `echoes` then judges it.
--- - `light:offline()` when the device cannot be reached: it drops the declaration, so declare again
---   before the next report. `light:forget()` when the device binding is bound, unbound or replaced:
---   Director binds it at every controller start, so the proxy is told only that the light is offline,
---   with the button LEDs off, and the light's first report then tells it where the light is.
--- - `light:done(seq, ok, epoch)` with your transport's word on each command, only if you declared
---   `reports.ack = "done"`: once for every command `send` was given, with the seq and epoch it carried,
---   and none for one whose send raised; `ok` false when the transport gave up. A command that put nothing
---   on the wire is done at once: call done for it inside send.
--- - `light:range()` for the Min and Max On Level, `lo, hi` in percent of the device's brightness: the
---   Control4 levels 1 to 100 run between them.
--- - `Light.FULL` and `Light.CCT`, the color modes 0 and 1, and `Light.color`, the color helpers
---   (xy, kelvin, mireds, RGB and HSV) the library converts with, for your transport's own terms.
---   `Light.eased(p)` is the curve `fade.curve = "eased"` runs, for a model of your device's channels.
---
--- ## What you never do
---
--- - Send to the Light V2 proxy binding or the button link bindings, or define a handler for a proxy
---   command: the library registers the proxy's 41 commands, STOP_RAMP_SCENE and the links' DO_PUSH,
---   DO_CLICK and DO_RELEASE on RFP. One light per driver: handlers are global by command name.
--- - Keep light state: levels, ramps, presets, on modes, or the colors the proxy was told.
--- - Call light:done from a timer of your own: the library's timeout covers a word that never comes.
---
--- ## Hooks the library calls
---
--- - `adapter:send(cmd)` (required): every device command, as the outbox lets it go. It is also called
---   while offline and before any declaration, the command judged as for an on/off light: drop what
---   your transport cannot send. Inside it call only light:done, light:offline and light:forget: an
---   offline there leaves the command as one sent while offline, and a report or a declaration there is
---   refused, with an error. Under `echo` it may return a token, a table: `token.level`, the brightness
---   that went on the wire (0 for an off), and `token.color`, set when a color or color mode did, say
---   which lists the command joins; with none it joins those of the aspects the outbox holds it by, so a
---   color's on joins no level list. The token is what `echoes` and the verdict's `since` give back.
--- - `adapter:refresh()` (required under `settle`): ask the device for its whole state. Its answer
---   comes later, through report from your transport's own events: inside refresh, as inside send,
---   call only light:done, light:offline and light:forget. Called at start(), and under `settle` after
---   a turn-on by another hand, for an unasked off while a command's target is above 0, and with
---   `ack = "done"` for the core's reads.
--- - `adapter:rangeChanged(lo, hi)`: at start() and every Min or Max On Level change, with the range
---   light:range() returns. A device driver that shows a level as the proxy does maps a brightness to
---   the Control4 levels 1 to 100 with `lib.light.range`, which it can bundle alone.
--- - `adapter:takeColor(color, ctx)`: the color the device will show, { x, y, mode }, for a color the
---   library is about to send or tell. Return it as given, or in your own form: a mode above 1 is your
---   own kind of full color, told as 0 and kept as given. `ctx.asked` is the color as the proxy asked
---   it, `ctx.ends` the Dim-To-Warm presets a point between them comes from, `ctx.stop` a stop's
---   estimate, and `ctx.held` asks where the device holds a color, such as a color temperature past
---   its range at the range's end, for a fade's ends. Without it the library applies Color.taken.
--- - `adapter:colorAt(now, to)`: where the device's color is when the library's estimate would mislead,
---   { x, y, mode } or nil, and as a second value the least time in ms a stop must take now, while the
---   light is dark between color modes, or nil. `to` is the color the ramp in flight heads to. With a
---   stop time, a level stop above 0 whose ramp keeps no color of its own also stops the color it
---   carries, in one command, and every stop is held over at least that time.
--- - `adapter:echoes(aspect, token, raw)`: under `echo`, whether a report matches one entry of an
---   aspect's list, on your own wire fields; nil leaves it to the library's reading. `aspect` is "level"
---   or "color", `token` what send returned (for the list's head, the last report's `meta.raw`), and
---   `raw` this report's `meta.raw`.
---
--- ## The declaration (LightCaps)
---
--- ```lua
--- light:declare({
---   dims = true, -- level control; false for an on/off relay
---   color = true, -- full color (xy)
---   cct = { min = 2000, max = 6500 }, -- color temperature range in kelvin
---   levelSteps = 254, -- the device's brightness steps from off to full; nil is continuous
---   tolerance = 2, -- color_trace_tolerance (default 2)
---   fade = { by = "device", preOn = 0.0039 }, -- "device" (default) or "none"; preOn needs dims
---   reports = { policy = "settle", settleMs = 11500 }, -- "trust", "echo" or "settle"
--- })
--- ```
---
--- - `fade.by = "device"`: the device fades itself over each command's `ms`, along its `curve`,
---   "linear" (default) or "eased". With `preOn`, a light that keeps its last level while off is first
---   lit at that brightness, at once and in its on color, ahead of a rated on from off.
--- - `fade.retimes`: the device runs one transition for every channel, and each command restarts them
---   all from where they are. A command that names one aspect takes the other on to its target over its
---   own time, told again; a stop holds the other over the time it has left; a color for a light off or
---   fading to off goes over the time the fade has left, told at once; and each ramp a scene step begins
---   ends by its own timer.
--- - `fade.by = "none"`: no level moves. A light that dims takes every change at once, told as CHANGED
---   only; its stops send nothing and the capabilities hide them. One that does not dim keeps every
---   rate, so its color still goes over its rate.
--- - `reports.policy = "trust"`: for a device whose reports carry no provenance. A report of a ramp's
---   own aspect is ignored during the ramp and otherwise told when it differs; news comes only from
---   `meta.news`, and ends the ramps of the aspects it carries.
--- - `reports.policy = "echo"`: for a device that answers every command with a report of its targets,
---   in order. Each aspect keeps a list headed by its last report, then each command that put it on the
---   wire since. A report matching the last entry is own; one matching an earlier entry, the head
---   included, is history and waits up to `reports.waitMs` (default 1000) after the newest command for
---   its echo, told at the end if none came; one matching none is another hand's, told at once, ending
---   the ramps of its aspect, or of both with `retimes`. Nothing is listed while the light is offline.
--- - `reports.policy = "settle"`: for a device that reports progress and answers reads with
---   provenance. A command opens a window of its transition plus `settleMs` in which the proxy keeps
---   the target; a report settles it on an answer saying off, the final answers for each control the
---   command set, or a report of the target; anything else is held and shown when the window ends.
--- - `reports.ack`: `"send"` (default), a command is done when send returns; `"done"`, it is done on
---   light:done or at its timeout, its send plus 1.5 times its transition plus `reports.ackMs`
---   (default 40000). With "done", under trust or settle a report heard before the newest command's word
---   is history, unless it answers a read, and under echo the lists judge it; under each a command
---   waiting to go has no word yet, and sets its aspect when it goes.
--- - `reports.match`: the color match tolerance in xy (default 5e-3).
---
--- A declaration without a policy is refused whole, with an error, and the last one accepted stays in
--- force. An unknown field or a bad value is logged as an error and ignored. A declaration takes effect
--- at the connection's first report. During a connection a change of capabilities, or of `ack` to
--- "done", waits for the next one, and the rest of `reports` takes effect at once: a change of policy
--- resets the old one's state, though what waits still goes; a change of `ack` to "send" stops waiting;
--- and a new `settleMs`, `match` or `ackMs` judges what comes next. The policy of the last declaration
--- accepted stays in force through offline and forget.
---
--- ## Shapes
---
--- LightCaps, LightCommand, LightColor, LightState, LightReportMeta, LightVerdict and LightAspectVerdict
--- are defined below.
---
--- ## What the library guarantees
---
--- - One command per change: the only pair is a pre-on and its ramp. With ack = "done" a change can
---   also send nothing, when a newer one replaces it before it goes.
--- - Nothing the declaration rules out: no color to a light with neither color nor cct, a kelvin only
---   to a light that declared cct, no pre-on unless fade.preOn and dims.
--- - No color turns a light on: a color sent without a level says whether the light is lit. A color
---   relay has no level to send, so a scene step that turns it on goes as an on with the step's color.
--- - A level only with on = true; an off is { on = false, ms }. A light that does not dim switches with
---   no ms, but for a scene step, which keeps its rate.
--- - At most one command in flight per aspect with ack = "done"; what waits goes with the time its
---   rate has left. With ack = "send" every command goes at once.
--- - A ramp's end sends nothing. A report before start() is dropped, and so is one with no declaration.
--- - An error raised in send or refresh reaches the caller once, and leaves nothing refusing: a command
---   whose send raised went nowhere, and what waits after it still goes.
--- - Control4 is told only from the library's model, never straight from a report.
--- - Global names stay yours. The library's timers are Light.BrightnessRamp, Light.ColorRamp,
---   Light.Scene.<id>, Light.Ack.<seq>, Light.EchoLevel and Light.EchoColor. Its persisted keys are
---   preset_level, click_rate_up, click_rate_down, hold_rate_up, hold_rate_down, brightness_rate_default,
---   color_rate_default, brightness_on_mode, brightness_on_mode_preset, brightness_presets, color_presets,
---   color_on_mode, previous_color, button_colors, scenes, max_on_level and min_on_level.

local log = require("lib.logging")
local Caps = require("lib.light.caps")
local Color = require("lib.light.color")
local Fade = require("lib.light.fade")

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

--- What the device can do, and how it fades and reports. The header's example shows each field.
--- @class LightCaps
--- @field dims boolean|nil
--- @field color boolean|nil
--- @field cct table|nil { min, max } in kelvin.
--- @field levelSteps integer|nil
--- @field tolerance number|nil
--- @field fade LightFade|nil
--- @field reports LightReports

--- @class LightFade
--- @field by "device"|"none"|nil
--- @field curve "linear"|"eased"|nil
--- @field retimes boolean|nil
--- @field preOn number|nil

--- @class LightReports
--- @field policy "trust"|"echo"|"settle" Required.
--- @field settleMs integer|nil Required under settle.
--- @field waitMs integer|nil Echo: how long a report from before the newest command waits for its echo.
--- @field ack "send"|"done"|nil
--- @field ackMs integer|nil
--- @field match number|nil

--- One color. Mode 0 is full color, 1 a color temperature, and above 1 an adapter's own kind of full
--- color. In a command mode 1 always carries its kelvin, and a color that goes as xy is mode 0 or the
--- adapter's own.
--- @class LightColor
--- @field x number CIE x
--- @field y number CIE y
--- @field mode integer
--- @field kelvin integer|nil With mode 1 on a light that declared cct: the color temperature it goes as. It goes
---   as asked, even outside the declared range, for now.

--- One command for the device. A field left out means leave it as it is.
--- @class LightCommand
--- @field seq integer Rises with every command sent, and starts again at each load.
--- @field epoch string The same for every command of one load: with seq it names a command across reloads.
--- @field on boolean|nil True: on, or rising. False with no color: off over ms. False with a color and no
---   level: the light is off, or fading to off; set the color and leave it so. Left out with a color only
---   while the light's on or off is unread (settle).
--- @field level number|nil Device brightness 0 to 1, already through Min and Max On; only with on = true.
--- @field color LightColor|nil
--- @field ms integer|nil Transition in ms; 0 is at once and ends a transition in flight for what it names. Left
---   out for the on or off of a light that does not dim, which switches as the device does by default; its
---   scene steps keep their rate.
--- @field preOn boolean|nil The first half of a rated on from off: on, level = fade.preOn, ms = 0.
--- @field stop "color"|nil A color stop, on a device that re-times: hold the color where it is, with the
---   level stopped with it when the command carries one; ms is the hold.
--- @field scene boolean|nil One step of a scene: its level and color as the step sets them, as one transition.

--- What the device says. Any field may be missing; NaN and infinities are no reading.
--- @class LightState
--- @field on boolean|nil
--- @field level number|nil Device brightness 0 to 1.
--- @field color table|function|nil { x, y } or { x, y, mode } for a color, or { kelvin } for a white. Under echo
---   it may be a function of the color's verdict kind that returns one.

--- Where a report came from. Never set a field without knowing.
--- @class LightReportMeta
--- @field control "onOff"|"level"|"color"|nil Settle: the control the report is of. Its other fields may ride
---   along, as a device driver that pushes its whole state sends them: on and level are taken only from their
---   own control's report, and a color from any. Nil is a whole report.
--- @field answer "final"|"moving"|nil Settle: an answer to a read sent after the newest command, after or
---   during its transition.
--- @field snapshot boolean|nil A replayed snapshot (a re-bind): it seeds a connection's first word, and after
---   that its on and level are no news; a color in it that differs is told.
--- @field news boolean|nil Trust: you know another hand moved the light.
--- @field raw any|nil Echo: your own report, passed back to adapter:echoes.

--- What report() made of a report, per aspect.
--- @class LightVerdict
--- @field level LightAspectVerdict|nil Nil when the report carried no on or level.
--- @field color LightAspectVerdict|nil Nil when it carried no color.

--- What report() made of one aspect of a report.
--- @class LightAspectVerdict
--- @field kind "first"|"own"|"history"|"hand" The first report on a connection, one that fits the newest
---   command, one from before it, or another hand's change.
--- @field seq integer|nil The newest command the report answers; under echo the command its match stands for.
--- @field since table[]|nil Echo: the tokens of the commands left in the aspect's list after the match, oldest
---   first.

-- Every part is required here, at load: the build bundles only what package.loaded holds after init.
local PARTS = {
  require("lib.light.settings"),
  require("lib.light.notify"),
  Fade,
  require("lib.light.motion"),
  require("lib.light.outbox"),
  require("lib.light.reports"),
  require("lib.light.scenes"),
  require("lib.light.buttons"),
  require("lib.light.handlers"),
}
require("lib.light.range")

--- A Light V2 light over one adapter.
--- @class Light
--- @field adapter table
--- @field opts table { proxy, links }
--- @field started boolean
--- @field told table What the proxy was told: level, color, preset ids, LEDs and online.
--- @field aim table Where the light heads: the ramps, the pre-press level, the follow-up window.
--- @field device table The declaration, the device's word, the policy's windows, the outbox and the ledger.
--- @field scenes table How far each scene's steps have run, and the run generation.
local Light = {}
Light.__index = Light

Light.FULL, Light.CCT = Color.FULL, Color.CCT

--- Color helpers for adapters.
Light.color = Color

--- The eased curve `fade.curve = "eased"` runs, for an adapter's own model of its channels.
Light.eased = Fade.eased

-- Only the parts' methods join the class: a part's own helpers, such as Fade.along, stay off it.
for _, part in ipairs(PARTS) do
  for name, fn in pairs(part) do
    if type(fn) == "function" and name:sub(1, 1) == "_" then
      Light[name] = fn
    end
  end
end

-- The loads in this Lua process, which tell two loads at one virtual time apart in a command's epoch.
local loads = 0

local DEFAULT_LINKS = { top = 300, toggle = 301, bottom = 302 }

--- Create the light and register its proxy and link handlers. Call it once, in the driver chunk.
--- @param adapter table The adapter: send(cmd), and any optional hooks.
--- @param opts table|nil { proxy = 5001, links = { top = 300, toggle = 301, bottom = 302 } or false }
--- @return Light light
function Light.new(adapter, opts)
  opts = opts or {}
  loads = loads + 1
  local links = opts.links
  if links == nil then
    links = DEFAULT_LINKS
  end
  local self = setmetatable({
    adapter = adapter,
    opts = { proxy = opts.proxy or 5001, links = links },
    started = false,
    told = {
      level = 0,
      x = Color.D65.x,
      y = Color.D65.y,
      mode = Color.CCT,
      leds = false,
      online = false,
    },
    aim = { preOnTold = false, mergedUntil = 0 },
    device = {
      word = {},
      ack = "send",
      seq = 0,
      epoch = string.format("%d.%d", C4:GetTime(), loads),
      ledger = { level = {}, color = {} },
      echo = { level = {}, color = {}, levelUntil = 0, colorUntil = 0 },
      outbox = { flight = {}, waiting = {}, order = {}, units = {} },
    },
    scenes = { generation = 0, progress = {} },
  }, Light)
  self:_register()
  return self
end

--- Start the light, from OnDriverLateInit: it is offline until its first report.
function Light:start()
  self.started = true
  self:_notifyOnline(false)
  self:_refresh()
  self:_tellRange()
  self:_readSetup()
end

--- Declare what the device can do, and how it fades and reports.
--- @param caps LightCaps
--- @return boolean accepted False when it is refused whole; the last one accepted stays in force.
function Light:declare(caps)
  local inside = self.device.inside
  if inside then
    log:error("Light:declare: inside %s, so it is refused; declare from your transport's own events", inside)
    return false
  end
  local decl, errors = Caps.check(caps)
  for _, err in ipairs(errors) do
    log:error("Light:declare: %s", err)
  end
  if not decl then
    return false
  end
  local dev = self.device
  if Caps.same(decl, dev.decl) then
    return true
  end
  dev.decl = decl
  if dev.policy ~= decl.reports.policy then
    if dev.policy ~= nil then
      -- A new policy starts from nothing: what the old one held is not told. The outbox is the
      -- transport's, so what waits still goes.
      self:_resetPolicy()
    end
    dev.policy = decl.reports.policy
  end
  if decl.reports.ack == "send" and dev.ack == "done" then
    dev.ack = "send"
    self:_stopWaiting()
  end
  return true
end

--- Report a state the device gave.
--- @param state table A LightState.
--- @param meta table|nil A LightReportMeta.
--- @return table|nil verdict A LightVerdict; nil for a report dropped.
function Light:report(state, meta)
  if not self.started then
    return nil
  end
  local dev = self.device
  if dev.inside then
    log:error("Light:report: inside %s, so the report is dropped; report from your transport's own events", dev.inside)
    return nil
  end
  if not dev.decl then
    log:error("Light:report: no declaration, so the report is dropped; declare comes first on every connection")
    return nil
  end
  meta = meta or {}
  local first = not self.told.online
  if first then
    -- The first report on a connection brings the light online: ONLINE_CHANGED before the capabilities.
    self.told.online = true
    dev.live = dev.decl
    dev.ack = dev.live.reports.ack
    self:_notifyOnline(true)
    self:_notifyCapabilities(dev.live)
  end
  local verdict = self:_heard(state or {}, meta, first)
  if meta.answer then
    self:_answered()
  end
  return verdict
end

--- The device cannot be reached: the proxy is told it is offline and off, with the LEDs off.
function Light:offline()
  self:_drop()
  self:_notifyOnline(false)
  self:_notifyBrightnessChanged(0) -- the LED state is kept, so the button LEDs go off too
end

--- The device binding is bound, unbound or replaced, as Director binds it at every controller start: the
--- proxy is told only that the light is offline, since an off would run its Off programming, and the button
--- LEDs go off. The light is forgotten, its color D65 again.
function Light:forget()
  self:_drop()
  local told = self.told
  told.x, told.y, told.mode = Color.D65.x, Color.D65.y, Color.CCT
  self:_notifyOnline(false)
  self:_matchLedState(false)
end

--- Drop what the light knows of its device and what the proxy was told of it, telling nothing.
--- @private
function Light:_drop()
  local dev, aim, told = self.device, self.aim, self.told
  self:_emptyOutbox()
  CancelTimer("Light.BrightnessRamp")
  CancelTimer("Light.ColorRamp")
  aim.level, aim.color = nil, nil
  self:_stopAllScenes()
  dev.word = {}
  self:_resetPolicy()
  dev.decl, dev.live, dev.ack = nil, nil, "send"
  told.online = false
  told.level = 0
  aim.prePress = nil
  aim.mergedUntil = 0
  told.levelPreset, told.colorPreset = nil, nil
end

--- Your transport's word on a command, with reports.ack = "done".
--- @param seq integer The command's seq.
--- @param ok boolean|nil False when the transport gave up on it.
--- @param epoch string The command's epoch: a word from another load is ignored.
function Light:done(seq, ok, epoch)
  self:_word(seq, ok, epoch)
end

--- The Min and Max On Level, in percent of the device's brightness: the Control4 levels 1 to 100 run
--- between them.
--- @return number lo, number hi
function Light:range()
  return self:_onRange()
end

--- @private
function Light:_dims()
  local decl = self.device.live
  return decl ~= nil and decl.dims
end

--- @private
function Light:_hasColor()
  local decl = self.device.live
  return decl ~= nil and decl.color
end

--- @private
function Light:_hasCct()
  local decl = self.device.live
  return decl ~= nil and decl.cct ~= nil
end

--- @private
function Light:_levelSteps()
  local decl = self.device.live
  return decl and decl.levelSteps
end

--- The report policy in force.
--- @private
function Light:_policy()
  return self.device.policy
end

--- Tell the adapter the range, so its device can show a level as the proxy does.
--- @private
function Light:_tellRange()
  if self.adapter.rangeChanged then
    self.adapter:rangeChanged(self:_onRange())
  end
end

return Light
