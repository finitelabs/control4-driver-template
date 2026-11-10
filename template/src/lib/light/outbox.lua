--- The outbox: one per aspect, level and color, between the motion code and adapter:send.
---
--- With `reports.ack = "send"`, the default, a command is done when send returns, so every command
--- goes at once and the outbox holds nothing. With `"done"` a command is done on the adapter's
--- light:done(seq, ok, epoch) or at its timeout (timer Light.Ack.<seq>): its send plus 1.5 times its
--- transition plus `reports.ackMs`. A command for an aspect in flight waits; a newer one replaces the
--- fields of one still waiting, aspect by aspect; and what waits goes when its aspects are done, with
--- the time its rate has left, so it lands when Control4 was told. A wait under 50 ms takes nothing off.

local log = require("lib.logging")

require("lib.utils")
require("drivers-common-public.global.timer")

-- A wait shorter than this takes nothing off a command's rate: a wire that rounds to tenths would
-- change for nothing.
local WHOLE_RATE_MS = 50

--- @class LightOutbox
local Outbox = {}

--- Whether commands wait on the adapter's word.
--- @private
--- @return boolean
function Outbox:_acks()
  return self.device.ack == "done"
end

--- The aspects a command holds in the outbox and joins the ledger by: the level for a level, an on
--- or off alone, or an on that sets the level, as a relay's scene step in a color does; the color
--- for a color. Any other color's on says whether the light is lit.
--- @private
--- @param cmd table
--- @param intent table { target } when the command sets the level.
--- @return table aspects { level, color }
function Outbox:_aspectsOf(cmd, intent)
  local level = cmd.level ~= nil or (cmd.on ~= nil and (cmd.color == nil or intent.target ~= nil))
  return { level = level, color = cmd.color ~= nil }
end

--- Whether a color command says the light is lit: as the model has it, and while a level waits, only
--- if the newest level sent lights it too, since the device has only the level commands sent. Nil
--- while the light's on or off is unread: a report that said on may be an old one.
--- @private
--- @return boolean|nil
function Outbox:_colorLit()
  if self:_unsure() then
    return nil
  end
  local on = self:_isLogicallyOn()
  local sent = self:_newest("level")
  if on and self.device.outbox.waiting.level and sent and sent.target ~= nil then
    return sent.target > 0
  end
  return on
end

--- Hand one command to the adapter, and enter it in the ledger.
--- @private
--- @param cmd table
--- @param intent table
--- @param unit table|nil Its unit in the outbox, with ack = "done": a word given inside send finds it.
--- @return table entry
function Outbox:_hand(cmd, intent, unit)
  local dev = self.device
  dev.seq = dev.seq + 1
  cmd.seq = dev.seq
  cmd.epoch = dev.epoch
  -- A read handed over before this command is answered from before it, so the device drops its answer.
  local read, reask = dev.read, dev.reask
  if read then
    dev.read = nil
    if not read.reasked and cmd.color and cmd.level == nil and cmd.on ~= true then
      dev.reask = cmd.seq -- a color sent unlit arms no read-back: read again at its word
    end
  end
  local box = dev.outbox
  if unit then
    box.units[cmd.seq] = unit
  end
  log:debug("send(%s)", cmd)
  local outer = dev.inside -- a send nests when a word given inside it lets a waiting command go
  dev.inside = "send"
  local ok, token = pcall(self.adapter.send, self.adapter, cmd)
  dev.inside = outer
  if not ok then
    -- It went nowhere: it is owed no word, and the read handed over before it is answered after all, with
    -- no read asked again at its word.
    box.units[cmd.seq] = nil
    if dev.outbox == box and dev.read == nil then
      dev.read = read
    end
    if dev.reask == cmd.seq then
      dev.reask = reask
    end
    error(token, 0) -- raised again once out of send, so later reports and declarations are taken
  end
  return self:_sent(cmd, intent, not self:_acks() and C4:GetTime() or nil, type(token) == "table" and token or nil)
end

--- Send a command, with the pre-on it follows, as the outbox lets it go.
--- @private
--- @param cmd table The LightCommand.
--- @param intent table { target, brightness } for the policy's window.
--- @param preOn table|nil The pre-on, one unit with the command.
function Outbox:_command(cmd, intent, preOn)
  if not self:_acks() then
    if preOn then
      self:_hand(preOn, { preOn = true })
    end
    local ok, err = pcall(self._hand, self, cmd, intent)
    if not ok then
      if preOn then
        self:_litAlone()
      end
      error(err, 0)
    end
    return
  end
  local box = self.device.outbox
  local aspects = self:_aspectsOf(cmd, intent)
  if aspects.color then
    for _, older in ipairs(box.order) do
      older.colorSince = true -- a color asked after a waiting level wins over an on color its go adds
    end
  end
  local busy = (aspects.level and (box.flight.level or box.waiting.level))
    or (aspects.color and (box.flight.color or box.waiting.color))
  if not busy then
    self:_launch({ cmd = cmd, intent = intent, preOn = preOn, aspects = aspects, askedAt = C4:GetTime() })
    return
  end
  local w = { cmd = cmd, intent = intent, preOn = preOn, aspects = aspects, askedAt = C4:GetTime() }
  for _, aspect in ipairs({ "level", "color" }) do
    if aspects[aspect] then
      local older = box.waiting[aspect]
      if older and older ~= w then
        self:_strip(older, aspect)
      end
      box.waiting[aspect] = w
    end
  end
  box.order[#box.order + 1] = w
  self:_waits(w)
end

--- A pre-on went and its ramp's send raised: the pre-on lit the light where the model, put back, has
--- it as before. The light is away, as a report heard as history can say: a level asked again goes.
--- @private
function Outbox:_litAlone()
  self.device.awayAt = C4:GetTime()
end

--- A newer command takes one aspect of a waiting one: what is left of it goes on its own.
--- @private
function Outbox:_strip(w, aspect)
  w.aspects[aspect] = false
  local cmd = w.cmd
  if aspect == "level" then
    cmd.level, w.preOn = nil, nil
    w.intent = {}
  else
    cmd.color = nil
    if w.preOn then
      w.preOn.color = nil
    end
  end
  if not (w.aspects.level or w.aspects.color) then
    w.gone = true
  end
end

--- Hand a unit to the transport and hold its aspects until its word.
--- @private
function Outbox:_launch(w)
  local box = self.device.outbox
  local unit = { entries = {}, aspects = w.aspects, ms = w.cmd.ms or 0, words = {}, handing = true }
  if w.preOn then
    local e = self:_hand(w.preOn, { preOn = true }, unit)
    unit.entries[#unit.entries + 1] = e
  end
  -- An offline or forget inside send empties the outbox: the rest goes as a command sent while offline.
  -- A send that raises after the pre-on went still leaves the pre-on in flight.
  local sent, e = pcall(self._hand, self, w.cmd, w.intent, self.device.outbox == box and unit or nil)
  if sent then
    unit.entries[#unit.entries + 1] = e
  end
  unit.handing = nil
  if self.device.outbox ~= box or #unit.entries == 0 then
    if not sent then
      error(e, 0)
    end
    return
  end
  for _, aspect in ipairs({ "level", "color" }) do
    if unit.aspects[aspect] then
      box.flight[aspect] = unit
    end
  end
  local last = unit.entries[#unit.entries]
  if not sent then
    unit.ms = 0 -- a pre-on left in flight alone has no transition to wait out
    self:_litAlone()
  end
  unit.timer = "Light.Ack." .. tostring(last.seq)
  unit.timeout = math.floor(1.5 * unit.ms + self.device.decl.reports.ackMs)
  SetTimer(unit.timer, unit.timeout, function()
    self:_timedOut(unit)
  end, false)
  self:_heardWords(unit) -- a command that put nothing on the wire was done inside send
  if not sent then
    error(e, 0)
  end
end

--- Free a unit's aspects once it is done, then send what waits for them.
--- @private
--- @return boolean sent Whether a waiting command went.
function Outbox:_finish(unit)
  local box = self.device.outbox
  CancelTimer(unit.timer)
  for _, entry in ipairs(unit.entries) do
    box.units[entry.seq] = nil
  end
  for _, aspect in ipairs({ "level", "color" }) do
    if box.flight[aspect] == unit then
      box.flight[aspect] = nil
    end
  end
  return self:_go()
end

--- At a timeout, the command is taken as done but unconfirmed, and reports are judged against it.
--- @private
function Outbox:_timedOut(unit)
  if self.device.outbox.units[unit.entries[#unit.entries].seq] ~= unit then
    return
  end
  log:warn("no word on command %s within %s ms", unit.entries[#unit.entries].seq, unit.timeout)
  for _, entry in ipairs(unit.entries) do
    entry.timedOut = true
  end
  -- The timeout stands for the word a read asked while it was in flight waits on, as a word does.
  local read = self.device.read
  if read and not read.endsAt then
    read.endsAt = C4:GetTime() + self:_settleMs()
  end
  if not self:_finish(unit) then
    self:_askRead()
  end
end

--- The adapter's word on a command.
--- @private
--- @param seq integer
--- @param ok boolean
--- @param epoch string
function Outbox:_word(seq, ok, epoch)
  local dev = self.device
  if epoch ~= dev.epoch or not self:_acks() then
    return
  end
  local unit = dev.outbox.units[seq]
  if not unit then
    return -- timed out, replaced, or never sent
  end
  unit.words[seq] = ok ~= false
  if not unit.handing then
    self:_heardWords(unit)
  end
end

--- A unit is done once each of its commands has its word: one not delivered leaves the ledger and
--- has the light read, and what waits for its aspects goes.
--- @private
function Outbox:_heardWords(unit)
  local dev = self.device
  for _, entry in ipairs(unit.entries) do
    if unit.words[entry.seq] == nil then
      return
    end
  end
  local now = C4:GetTime()
  local delivered = true
  for _, entry in ipairs(unit.entries) do
    entry.word = now
    delivered = delivered and unit.words[entry.seq]
  end
  if not delivered then
    -- The transport gave up: the command is out of the ledger and the echo lists, and the light is read.
    for _, entry in ipairs(unit.entries) do
      self:_forgetEntry(entry)
      self:_unlistEcho(entry.seq)
    end
  end
  local read = dev.read
  if read and not read.endsAt then
    read.endsAt = now + self:_settleMs()
  end
  local sent = self:_finish(unit)
  local away = dev.awayAt and dev.awayAt >= unit.entries[1].at
  if dev.reask and dev.reask == unit.entries[#unit.entries].seq then
    dev.reask = nil
    self:_askRead(true)
  elseif (away or not delivered) and not sent then
    self:_askRead()
  end
end

--- @private
function Outbox:_forgetEntry(entry)
  for _, aspect in ipairs({ "level", "color" }) do
    local entries = self.device.ledger[aspect]
    for i = #entries, 1, -1 do
      if entries[i] == entry then
        table.remove(entries, i)
      end
    end
  end
end

--- Where the device has the light by the commands it was sent: the newest level command's path.
--- @private
--- @return number level A Control4 level, 0 for off.
function Outbox:_deviceLevel()
  local n = self:_newest("level")
  if not n or n.target == nil then
    return self:_knownLevel() or self.told.level
  end
  local elapsed = C4:GetTime() - n.at
  if n.ms <= 0 or elapsed >= n.ms then
    return n.target
  end
  local at = (n.from or 0) + (n.target - (n.from or 0)) * elapsed / n.ms
  return at < 0.5 and 0 or at
end

--- Send what waits for aspects now free, each decided as it goes.
--- @private
--- @return boolean sent Whether anything went.
function Outbox:_go()
  local box = self.device.outbox
  local sent, raised = false, nil
  local i = 1
  while i <= #box.order do
    local w = box.order[i]
    local free = not (w.aspects.level and box.flight.level) and not (w.aspects.color and box.flight.color)
    if w.gone then
      table.remove(box.order, i)
    elseif free then
      table.remove(box.order, i)
      for _, aspect in ipairs({ "level", "color" }) do
        if box.waiting[aspect] == w then
          box.waiting[aspect] = nil
        end
      end
      -- A send or a read that raises leaves the rest to go, and is raised again once they have.
      local ok, went = pcall(function()
        if self:_settleWaiting(w) then
          self:_launch(w)
          return true
        end
        return false
      end)
      if ok then
        sent = sent or went
      else
        raised = raised or went
      end
      if self.device.outbox ~= box then
        break -- emptied inside send or refresh
      end
    else
      i = i + 1
    end
  end
  if raised then
    -- What raised never went, though the proxy was told it when it was asked: the light is read.
    self:_askRead()
    error(raised, 0)
  end
  return sent
end

--- What a waiting command sends, decided as it goes: the time its rate has left, whether a color alone
--- says lit, its pre-on from where the light is now, and nothing at all for a level the command it
--- waited behind lands on.
--- @private
--- @return boolean send
function Outbox:_settleWaiting(w)
  local cmd = w.cmd
  local waited = C4:GetTime() - w.askedAt
  if cmd.ms and waited >= WHOLE_RATE_MS then
    cmd.ms = math.max(0, cmd.ms - waited)
  end
  -- A color that holds no level decides its on as it goes: an off asked while it waited stands.
  if cmd.color and not w.aspects.level then
    cmd.on = self:_colorLit()
    return true
  end
  local target = w.intent.target
  local offNow = self:_deviceLevel() == 0
  local rated = (cmd.ms or 0) > 0 and target ~= nil and target > 0
  local preOnLevel = rated and offNow and self:_preOnLevel()
  if w.preOn and not preOnLevel then
    w.preOn = nil -- lit since it was asked: a pre-on would dip it
  elseif preOnLevel and not w.preOn then
    -- Off where it was lit when asked: the on color goes with the pre-on, and is told now, unless a
    -- color asked since, or one in flight or waiting, holds the color.
    local box = self.device.outbox
    local free = not (w.colorSince or box.flight.color or box.waiting.color)
    local on = not cmd.color and free and self:_onColor(target)
    local wire = on and self:_wireColor(on.x, on.y, on.mode)
    if wire then
      cmd.color = wire
      w.aspects.color = true
      self.told.colorPreset = on.preset
      self:_notifyColorChanged(on.x, on.y, on.mode)
    end
    w.preOn = { preOn = true, on = true, level = preOnLevel, color = cmd.color, ms = 0 }
  end
  -- A level the command it waited behind has landed on is not sent again, unless the light is away from it.
  -- One that timed out has no word that it landed at all, and one heard away from it before this was asked
  -- is not there.
  local n = self:_newest("level")
  local away = math.huge -- the first time the light was heard away since that command, either way
  for _, at in ipairs({ self.device.awayAt or -math.huge, self.device.movedAt or -math.huge }) do
    if n and at > n.at then
      away = math.min(away, at)
    end
  end
  if
    target ~= nil
    and cmd.color == nil
    and not w.preOn
    and n
    and n.target == target
    and not n.timedOut
    and not (away < w.askedAt)
    and C4:GetTime() >= n.at + n.ms
    and not (self:_unsure() or self:_outsideRange(self:_aimBrightness()) or self:_awayFromFadeColor(target))
  then
    self:_expected(cmd, w.intent)
    -- The light is there, so a ramp the model runs to it ends.
    local ramp = self.aim.level
    if ramp and ramp.targetLevel == target then
      self:_brightnessRampFinished(target)
    end
    self:_askRead() -- its reports were history while it waited, so they cannot say the light is there
    return false
  end
  return true
end

--- A command waits: settle keeps its target from the ask, so no window of a command in flight before
--- it ends on the older target. Its reports are history until it goes.
--- @private
function Outbox:_waits(w)
  local intent = w.intent
  if self:_policy() == "settle" and intent.target ~= nil then
    self.device.settle = { target = intent.target, brightness = intent.brightness, seen = {}, answered = {} }
  end
end

--- A waiting command that needs no send: its window opens as if it had gone.
--- @private
function Outbox:_expected(cmd, intent)
  if self:_policy() == "settle" and intent.target ~= nil then
    self:_expectBrightness(intent.target, cmd.ms or 0, intent.brightness, intent.target) -- the light is there
  end
end

--- Whether a read the library asked is still unanswered.
--- @private
--- @return boolean
function Outbox:_readUnanswered()
  local read = self.device.read
  if not read then
    return false
  end
  if read.endsAt and C4:GetTime() >= read.endsAt then
    self.device.read = nil
    return false
  end
  return true
end

--- Ask the light to be read, for the core's rules: one such read at a time.
--- @private
--- @param reasked boolean|nil The read asked again after a color alone superseded one; it is not asked again.
function Outbox:_askRead(reasked)
  if not self.adapter.refresh or self:_readUnanswered() then
    return
  end
  local now = C4:GetTime()
  local inFlight = self.device.outbox.flight
  local read = { at = now, reasked = reasked }
  if not (inFlight.level or inFlight.color) then
    read.endsAt = now + self:_settleMs()
  end
  self.device.read = read
  self:_refresh()
end

--- An answer to a read ends it.
--- @private
function Outbox:_answered()
  self.device.read = nil
end

--- Ask the adapter for the light's whole state. Its answer comes later, from the transport's own events.
--- @private
function Outbox:_refresh()
  if self.adapter.refresh then
    local dev = self.device
    local outer = dev.inside -- a read nests in a send when a word given there lets a go ask it
    dev.inside = "refresh"
    local ok, err = pcall(self.adapter.refresh, self.adapter)
    dev.inside = outer
    if not ok then
      error(err, 0)
    end
  end
end

--- Send nothing that waits and wait on nothing in flight, nor on a read, nor on a light heard away.
--- @private
function Outbox:_emptyOutbox()
  local box = self.device.outbox
  for _, unit in pairs(box.units) do
    CancelTimer(unit.timer)
  end
  self.device.outbox = { flight = {}, waiting = {}, order = {}, units = {} }
  self.device.read = nil
  self.device.reask = nil
  self.device.awayAt, self.device.movedAt = nil, nil
end

--- A change of ack to "send" takes effect at once: what waits goes, and nothing more waits.
--- @private
function Outbox:_stopWaiting()
  local box = self.device.outbox
  local order = box.order
  local now = C4:GetTime()
  for _, unit in pairs(box.units) do
    CancelTimer(unit.timer)
    for _, entry in ipairs(unit.entries) do
      entry.word = entry.word or now
    end
  end
  self.device.outbox = { flight = {}, waiting = {}, order = {}, units = {} }
  local emptied = self.device.outbox
  local raised
  for _, w in ipairs(order) do
    if self.device.outbox ~= emptied then
      break -- emptied again inside send
    end
    local ok, err = pcall(function()
      if not w.gone and self:_settleWaiting(w) then
        if w.preOn then
          self:_hand(w.preOn, { preOn = true })
        end
        self:_hand(w.cmd, w.intent)
      end
    end)
    raised = raised or (not ok and err) or nil
  end
  if raised then
    self:_askRead() -- what raised never went, as at a go
    error(raised, 0)
  end
end

return Outbox
