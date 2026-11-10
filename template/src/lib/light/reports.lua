--- The ledger and the report policies. Every command handed to the transport joins the ledger of
--- each aspect it names, with the path it implies; every report is judged against it, per aspect,
--- by the declared policy's own rules:
---
--- - `trust`: a report of a ramp's own aspect is ignored during the ramp and told otherwise when it
---   differs; news comes only from `meta.news`.
--- - `settle`: a command opens a window of its transition plus `settleMs`, in which the proxy keeps
---   the target; a report settles it on an answer saying off, the final answers for each control
---   the command set, or a report of the target; anything else is held and shown when it ends. A
---   command waiting in the outbox has its window from the ask.
--- - `echo`: each aspect keeps a list headed by its last report, then each command that put it on
---   the wire since, as send's token says. A report that matches the last entry is the light's own,
---   one that matches an earlier entry is history and waits up to `waitMs` for the newest echo, and
---   one that matches none is another hand's, which ends the ramps and is told at once.
---
--- With `reports.ack = "done"`, under trust or settle, a report of an aspect heard before the word of
--- the newest command for it is history and is dropped, unless it answers a read; a command waiting in
--- the outbox has no word yet. Under echo the lists judge it, and a command waiting sets its aspect. An
--- off while that command's target is above 0, or a level off every path, still asks the light to be
--- read, unless a level command waits to go: it sets the level, or asks the read itself when it goes
--- with nothing to send. One away from where that command landed the light has it read at its word, and
--- a command for that level asked since goes again. Control4 is told only from the model: no report
--- reaches a notify but through these rules.

local log = require("lib.logging")
local Color = require("lib.light.color")

require("lib.utils")
require("drivers-common-public.global.timer")

local FULL, CCT = Color.FULL, Color.CCT

--- @class LightReportPolicies
local Reports = {}

---------------------------------------------------------------------------
-- The device's word and the queries the motion code asks
---------------------------------------------------------------------------

--- The device's last word as a Control4 level, or nil before it said anything.
--- @private
function Reports:_knownLevel()
  local word = self.device.word
  if word.on == nil then
    return nil
  end
  return self:_toLevel(word.on, word.brightness)
end

--- The brightness (0 to 1) a light that dims is at or going to: what a command still settling sent
--- it, or one sent since its own word, or under echo the newest command listed, else that word; 0 for
--- off or not yet read.
--- @private
--- @return number
function Reports:_aimBrightness()
  if self:_policy() == "echo" then
    local aim = self.device.echo.aim
    return aim and aim.level or 0
  end
  local s = self.device.settle
  if s then
    return s.brightness or 0
  end
  local word = self.device.word
  local n = self:_newest("level")
  if self:_dims() and n and n.target ~= nil and n.at >= (word.at or -math.huge) then
    return n.target > 0 and (n.brightness or self:_toDevice(n.target)) or 0
  end
  return self:_dims() and word.on and (tonumber(word.brightness) or 1) or 0
end

--- Whether a command still settles on a level other than `level`, or on none, or the device has said
--- since it went that the light is off its way there: the light is at another, or on its way to one, so
--- a command for the level it shows is sent again.
--- @private
--- @param level integer
--- @return boolean
function Reports:_aimDiffers(level)
  if self:_policy() == "echo" then
    -- A command whose echo has not come is the light's heading, as the level it asked.
    local aim = self.device.echo.aim
    return aim ~= nil and not aim.head and aim.target ~= nil and aim.target ~= level
  end
  local s = self.device.settle
  if s == nil then
    return false
  end
  if s.target ~= level then
    return true
  end
  local known = self:_knownLevel()
  if not ((s.seen.onOff or s.seen.level) and known ~= nil and s.from ~= nil) then
    return false
  end
  -- Past its transition, and at once for a command with none, the light is at the target, or elsewhere.
  local from = C4:GetTime() < s.lands and s.from or s.target
  return self:_offPath(known, from, s.target)
end

--- Whether a level is off the path of a command from one level to another, as no report of the light on
--- its way is.
--- @private
--- @return boolean
function Reports:_offPath(level, from, to)
  local lo, hi = math.min(from, to), math.max(from, to)
  return not ((level >= lo and level <= hi) or self:_sameLevel(level, lo) or self:_sameLevel(level, hi))
end

--- Whether the light's on or off is unread: a report said on, and the read after it has not answered.
--- @private
--- @return boolean
function Reports:_unsure()
  local s = self.device.settle
  return s ~= nil and s.target == nil
end

--- Whether a command still waits on its report. Under settle that is its window, or a command with no
--- word yet; under trust a command not yet landed or not yet acknowledged.
--- @private
--- @return boolean
function Reports:_pending()
  local settle = self:_policy() == "settle"
  if settle and self.device.settle then
    return true
  end
  local now = C4:GetTime()
  for _, aspect in ipairs({ "level", "color" }) do
    local n = self:_newest(aspect)
    if self:_unconfirmed(n) or (not settle and n and now < (n.word or n.at) + n.ms) then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- The ledger
---------------------------------------------------------------------------

--- The newest command of an aspect, or nil.
--- @private
--- @param aspect "level"|"color"
--- @return table|nil entry
function Reports:_newest(aspect)
  local entries = self.device.ledger[aspect]
  return entries[#entries]
end

--- Whether a command waits on its word: sent, with no word and no timeout yet.
--- @private
--- @param entry table|nil
--- @return boolean
function Reports:_unconfirmed(entry)
  return entry ~= nil and entry.word == nil and not entry.timedOut
end

--- Drop the entries no report can still be judged against: each one older than one that has landed
--- and the late margin past it.
--- @private
function Reports:_pruneLedger(now)
  local margin = self:_settleMs()
  for _, aspect in ipairs({ "level", "color" }) do
    local entries = self.device.ledger[aspect]
    local keep = 1
    for i = #entries, 2, -1 do
      local e = entries[i]
      if e.word and now >= e.word + (e.ms or 0) + margin then
        keep = i
        break
      end
    end
    for _ = 1, keep - 1 do
      table.remove(entries, 1)
    end
  end
end

--- A command joins the echo lists of the aspects it put on the wire, by its token: the level list
--- with `token.level`, the color list with `token.color`. With no token it joins the lists of the
--- aspects it holds in the outbox, so a color's on, which says whether the light is lit, joins none.
--- Nothing is listed while the light is offline: no report would come back.
--- @private
--- @param aspects table { level, color } as the outbox holds the command.
function Reports:_listEcho(cmd, intent, token, aspects)
  if not self.told.online then
    return
  end
  local dev = self.device
  local level, color
  if token then
    level, color = token.level, token.color
  else
    if aspects.level then
      level = cmd.on and (cmd.level or 1) or 0
    end
    color = cmd.color
  end
  local now = C4:GetTime()
  local waitMs = dev.decl.reports.waitMs
  if level ~= nil then
    local entry = { token = token or cmd, level = level, target = intent.target, seq = cmd.seq }
    table.insert(dev.echo.level, entry)
    dev.echo.aim = entry
    dev.echo.levelUntil = now + waitMs
    CancelTimer("Light.EchoLevel")
  end
  if color ~= nil then
    table.insert(dev.echo.color, { token = token or cmd, color = color, seq = cmd.seq })
    dev.echo.colorUntil = now + waitMs
    CancelTimer("Light.EchoColor")
  end
end

--- A command the transport gave up on leaves the echo lists: no echo of it will come. Where it was the
--- newest of an aspect, with none waiting, the ramp in flight is its own, which the device never began.
--- @private
--- @param seq integer
function Reports:_unlistEcho(seq)
  local dev = self.device
  local echo = dev.echo
  for _, aspect in ipairs({ "level", "color" }) do
    local list = echo[aspect]
    local newest = list[#list]
    for i = #list, 1, -1 do
      if list[i].seq == seq and not list[i].head then
        table.remove(list, i)
      end
    end
    local ramp = self.aim[aspect]
    if ramp and newest and newest.seq == seq and not newest.head and not dev.outbox.waiting[aspect] then
      ramp.unheard = true
    end
  end
  if echo.aim and echo.aim.seq == seq and not echo.aim.head then
    echo.aim = echo.level[#echo.level]
  end
end

--- A command has been handed to the transport: it joins the ledger, and the policy opens what it waits with.
--- @private
--- @param cmd table The neutral command, with its seq.
--- @param intent table { target, brightness, preOn } from the motion code.
--- @param word number|nil The time of the transport's word, nil while it is owed.
--- @param token table|nil What send returned.
--- @return table entry The command's ledger entry, in each aspect's list it joined.
function Reports:_sent(cmd, intent, word, token)
  local now = C4:GetTime()
  local aspects = self:_aspectsOf(cmd, intent)
  local told = self.told
  local entry = {
    seq = cmd.seq,
    at = now,
    word = word,
    ms = cmd.ms or 0,
    target = intent.target,
    brightness = intent.brightness,
    from = told.level,
    color = cmd.color,
  }
  if aspects.level then
    table.insert(self.device.ledger.level, entry)
  end
  if aspects.color then
    table.insert(self.device.ledger.color, entry)
  end
  self:_pruneLedger(now)
  if self:_policy() == "echo" then
    self:_listEcho(cmd, intent, token, aspects)
  end
  -- Offline the command reaches no device, so nothing settles on it.
  if self:_policy() == "settle" and not intent.preOn and told.online then
    if intent.target ~= nil then
      self:_expectBrightness(intent.target, cmd.ms or 0, intent.brightness, told.level)
    end
    if cmd.color then
      self:_expectColor(cmd.color.x, cmd.color.y, cmd.color.kelvin and CCT or FULL, cmd.ms or 0)
    end
  end
  return entry
end

---------------------------------------------------------------------------
-- settle
---------------------------------------------------------------------------

--- The ms after a transition a read-back can still arrive: from the newest declaration, 0 with none.
--- @private
function Reports:_settleMs()
  local decl = self.device.decl
  return decl and decl.reports.settleMs or 0
end

--- Settled by an answer saying off, the read-back's answers, or a report of the target. Only a
--- level report confirms a dimmed target: an OnOff report carries what an earlier one left, and a
--- report outside the range, which reads as its end, confirms only a command sent outside it.
--- @private
function Reports:_settled(s)
  local word = self.device.word
  if s.answered.off then
    return true
  end
  if s.target == nil then
    return s.seen.level == true or word.on == false
  end
  local dims = self:_dims()
  if s.answered.onOff and (s.answered.level or not dims) then
    return true
  end
  if s.target == 0 or not dims then
    return s.seen.onOff == true and self:_knownLevel() == s.target
  end
  local brightness = tonumber(word.brightness) or 1
  return s.seen.level == true
    and word.on == true
    and brightness > 0 -- on at 0 is on its way up from off
    and self:_sameLevel(self:_knownLevel(), s.target)
    and self:_outsideRange(brightness) == self:_outsideRange(s.brightness or self:_toDevice(s.target))
end

--- End on what the device has said since the command, and on the command for the rest.
--- @private
function Reports:_settleFinish()
  local s = self.device.settle
  local word = self.device.word
  self.device.settle = nil
  if s.target ~= nil then
    if not s.seen.onOff then
      word.on = s.target > 0
    end
    if not s.seen.level and word.on and s.target > 0 then
      word.brightness = s.brightness or self:_toDevice(s.target)
    end
  end
  local level = self:_knownLevel()
  if s.target ~= nil and level ~= nil and self:_sameLevel(level, s.target) then
    level = s.target -- the device's step for it
  end
  log:debug("settled at %s (target %s)", level, s.target)
  if self.aim.level then
    self:_brightnessRampFinished(level) -- the device ended the ramp before its timer
  elseif level ~= self.told.level then
    self:_notifyBrightnessChanged(level)
  end
end

--- @private
function Reports:_openSettle(s, waitMs)
  self.device.settle = s
  delay(waitMs):next(function()
    if self.device.settle == s then
      self:_settleFinish()
    end
  end)
end

--- @private
--- @param from integer The level the command leaves.
function Reports:_expectBrightness(target, transitionMs, brightness, from)
  self:_openSettle({
    target = target,
    brightness = brightness,
    from = from,
    lands = C4:GetTime() + (transitionMs or 0),
    seen = {},
    answered = {},
  }, (transitionMs or 0) + self:_settleMs())
end

--- A turn-on the library did not send carries the level an earlier report left: read it.
--- @private
function Reports:_learnLevel()
  self:_openSettle({ seen = {}, answered = {} }, self:_settleMs())
  self:_askRead() -- the core's read, so a color that supersedes it asks it again
end

--- @private
--- @param wasOn boolean|nil The device's word on its on or off before the report.
function Reports:_settleHeard(s, control, answer, wasOn)
  local word = self.device.word
  if control then
    -- A level heard while the light is off is the level it keeps, which confirms no dimmed target.
    s.seen[control] = s.seen[control] or control ~= "level" or word.on ~= false
    if answer then
      s.asking = nil
      s.answered.off = s.answered.off or (control == "onOff" and word.on == false)
      s.answered[control] = s.answered[control] or answer == "final"
    end
  end
  if self:_settled(s) then
    return self:_settleFinish()
  end
  log:trace("report %s held: device at %s, expecting %s", control or "snapshot", self:_knownLevel(), s.target)
  -- Off while a command turns it on, or a turn-on while one turns it off that leaves the level unread: an
  -- Off or an On since, or a report from before it. A read tells.
  local offNow = word.on == false and (s.target or 0) > 0
  local onNow = wasOn == false and word.on == true and s.target == 0 and self:_dims()
  if control == "onOff" and not answer and (offNow or onNow) and not s.asking then
    s.asking = true
    self:_refresh()
  end
end

--- Wait on the color a command sets, in the mode it went out in.
--- @private
function Reports:_expectColor(x, y, mode, transitionMs)
  local s = { x = x, y = y, mode = mode, lands = C4:GetTime() + transitionMs }
  self.device.colorSettle = s
  delay(transitionMs + self:_settleMs()):next(function()
    if self.device.colorSettle == s then
      self.device.colorSettle = nil
      if s.held then
        self:_tellColor(s.held) -- the read-back is overdue, so the device's own report stands
      end
    end
  end)
end

--- Whether a report's color waits on the one a command set. The device's state holds that color
--- from the command on, so a push repeating it confirms nothing: only its answer to the read-back is its word.
--- @private
function Reports:_colorHeld(color, control, answer)
  local s = self.device.colorSettle
  if s == nil then
    return false
  end
  local same = Color.same(color.x, color.y, color.mode, s.x, s.y, s.mode, self:_match())
  if control ~= "color" then
    return not same -- a push of another attribute repeats the color last set or reported
    -- Final only past the color's own transition: an answer in it is to a later command's read.
  elseif answer == "final" and C4:GetTime() >= s.lands then
    self.device.colorSettle = nil
    return false
  end
  s.held = color
  return not same
end

---------------------------------------------------------------------------
-- Telling the device's word
---------------------------------------------------------------------------

--- The color tolerance a report is judged with: from the newest declaration, as settleMs is.
--- @private
function Reports:_match()
  local decl = self.device.decl
  return decl and decl.reports.match or Color.TOLERANCE
end

--- Show the device's color where the proxy has another. A ramp tells its own color at its end.
--- @private
--- @param color table { x, y, mode }
--- @param seed boolean|nil The first report on a connection: told even when unchanged.
function Reports:_tellColor(color, seed)
  local aim, told = self.aim, self.told
  if aim.color or (aim.level and aim.level.mergedColor) then
    return
  end
  if seed or not Color.same(color.x, color.y, color.mode, told.x, told.y, told.mode, self:_match()) then
    -- A change made outside: no preset drives it, so no stale preset id goes with it.
    told.colorPreset = nil
    self:_notifyColorChanged(color.x, color.y, color.mode)
  end
end

local function finite(v)
  v = tonumber(v)
  return v and v == v and v > -math.huge and v < math.huge and v or nil
end

--- A reported color as { x, y, mode }, or nil for none.
--- @param c table|nil { x, y } or { x, y, mode }, or { kelvin }.
--- @return table|nil
local function readColor(c)
  if type(c) ~= "table" then
    return nil
  end
  local kelvin = finite(c.kelvin)
  if kelvin and kelvin > 0 then
    local x, y = C4:ColorCCTtoXY(kelvin)
    return { x = x, y = y, mode = CCT }
  end
  local x, y = finite(c.x), finite(c.y)
  if x and y then
    return { x = x, y = y, mode = tointeger(c.mode) or FULL }
  end
  return nil
end

--- A report's state in the library's terms: finite numbers only, and its color as { x, y, mode }. A
--- color given as a function of whose the report is is read once the verdict says.
--- @param state table
--- @return table state { on, level, color, colorOf }
local function readState(state)
  local out = { on = state.on }
  out.level = finite(state.level)
  if type(state.color) == "function" then
    out.colorOf = state.color
  else
    out.color = readColor(state.color)
  end
  return out
end

--- Take the device's word on its on and level, by the control behind the report. A snapshot holds
--- nothing a report has not already brought, so it only seeds.
--- @private
local function takeWord(self, state, meta)
  local word = self.device.word
  local control = meta.control
  local whole = control == nil and not meta.snapshot
  local wasOn = word.on
  if wasOn == nil or control == "onOff" or (whole and state.on ~= nil) then
    word.on = state.on == true
    word.at = C4:GetTime()
  end
  if wasOn == nil or control == "level" or whole then
    word.brightness = state.level or word.brightness
    word.at = C4:GetTime()
  end
  return wasOn
end

--- A report heard as history whose on or off is the newest level command's says the device took it: that
--- on or off is the device's word, which a level heard after it is judged by.
local function takeOn(self, state, meta)
  local n, control = self:_newest("level"), meta.control
  if not (n and n.target ~= nil) then
    return -- a pre-on left alone by its ramp's raise has no window to judge a level by: its word asks a read
  end
  local lit = n.target > 0
  if state.on == lit and not meta.snapshot and (control == nil or control == "onOff") then
    self.device.word.on = lit
  end
end

--- What the settle policy makes of a report.
--- @private
function Reports:_heardSettle(state, meta, first, skip)
  local control = meta.control
  if not skip.level then
    local wasOn = takeWord(self, state, meta)
    local word = self.device.word
    local s = self.device.settle
    if s and not first then
      self:_settleHeard(s, control, meta.answer, wasOn)
    elseif self:_dims() and control == "onOff" and wasOn == false and word.on and not first then
      self:_learnLevel()
    elseif first or not self:_sameLevel(self:_knownLevel(), self.told.level) then
      -- The first report on a connection is told even when unchanged, so the proxy is seeded.
      self:_notifyBrightnessChanged(self:_knownLevel())
    end
  end
  -- A light keeps its color while off, so a ramp or a stop starts from it whether or not it is lit.
  local color = not skip.color and (self:_hasColor() or self:_hasCct()) and state.color or nil
  if color and self:_colorHeld(color, control, meta.answer) then
    log:trace("report %s color held: device at %.4f, %.4f", control or "snapshot", color.x, color.y)
  elseif color then
    self:_tellColor(color, first)
  end
end

--- What the trust policy makes of a report: a ramp's own aspect is ignored during it, and any other
--- report told when it differs. News ends the ramps of the aspects it carries and is told at once.
--- @private
function Reports:_heardTrust(state, meta, first, skip)
  local aim, told = self.aim, self.told
  local carriesLevel = state.on ~= nil or state.level ~= nil
  -- News of an aspect heard as history is from before the newest command, so it ends no ramp.
  local levelNews = meta.news and carriesLevel and not skip.level and aim.level ~= nil
  local colorNews = meta.news
    and state.color ~= nil
    and not skip.color
    and (aim.color ~= nil or (aim.level and aim.level.mergedColor))
  if levelNews then
    CancelTimer("Light.BrightnessRamp")
    aim.level = nil
  end
  if colorNews then
    CancelTimer("Light.ColorRamp")
    aim.color = nil
    if aim.level then
      aim.level.mergedColor = nil
    end
  end
  if carriesLevel and not skip.level then
    takeWord(self, state, meta)
    local level = self:_knownLevel()
    if aim.level then
      log:trace("report level %s ignored (ramping)", level)
    elseif level ~= nil and (first or levelNews or not self:_sameLevel(level, told.level)) then
      self:_notifyBrightnessChanged(level)
    end
  end
  local color = not skip.color and (self:_hasColor() or self:_hasCct()) and state.color or nil
  if color then
    self:_tellColor(color, first or colorNews)
  end
end

---------------------------------------------------------------------------
-- echo
---------------------------------------------------------------------------

--- Match a report against one aspect's list, head included. A match drops the entries before it and
--- the ones straight after it the report also matches; the report becomes the list's new head.
--- @param list table[]
--- @param matches fun(entry: table): boolean
--- @param head table The report as the list's new head.
--- @param first boolean
--- @return table verdict { kind, seq, since }
local function matchEcho(list, matches, head, first)
  local matched
  for i, entry in ipairs(list) do
    if matches(entry) then
      matched = entry
      for _ = 2, i do
        table.remove(list, 1)
      end
      while list[2] and matches(list[2]) do
        table.remove(list, 2)
      end
      break
    end
  end
  head.seq = matched and matched.seq
  list[1] = head
  local since = {}
  for i = 2, #list do
    since[#since + 1] = list[i].token
  end
  local kind = first and "first" or not matched and "hand" or #list > 1 and "history" or "own"
  return { kind = kind, seq = head.seq, since = since }
end

--- Whether a report matches an entry of an aspect's list: the adapter's echoes, else the library's
--- reading of a level and its color match.
--- @private
function Reports:_echoes(aspect, entry, raw, default)
  local adapter = self.adapter
  if adapter.echoes and entry.token ~= nil then
    local verdict = adapter:echoes(aspect, entry.token, raw)
    if verdict ~= nil then
      return verdict
    end
  end
  return default(entry)
end

--- What the echo policy makes of a report. Another hand's change of either aspect ends both ramps on
--- a device that re-times, and every ramp of its own aspect otherwise; a report from before the
--- newest command waits up to waitMs for that command's echo; an own report differing outside a ramp
--- is told.
--- @private
--- @return table verdict { level, color }
function Reports:_heardEcho(state, meta, first)
  local dev, aim, told = self.device, self.aim, self.told
  local raw = meta.raw
  local lists = dev.echo
  local word = dev.word
  -- A report says only what it carries. An on left out is the light's last word, and an on with no
  -- reading of the level keeps the last one read, or is at full, as under the other policies.
  local carriesLevel = state.on ~= nil or state.level ~= nil
  local on, b = state.on, state.level
  if on == nil then
    on = word.on == true
  end
  if on and b == nil then
    b = word.brightness
  end
  local function matched(v)
    return v == nil or v.kind == "own" or v.kind == "history"
  end
  local level, levelVerdict
  if carriesLevel then
    word.on, word.brightness = on, b or word.brightness
    level = self:_toLevel(on, b)
    local function readLevel(e)
      return e > 0 and self:_toLevel(true, e) or 0
    end
    local head = { head = true, token = raw, level = on and (self:_dims() and b or 1) or 0 }
    levelVerdict = matchEcho(lists.level, function(entry)
      return self:_echoes("level", entry, raw, function(e)
        return readLevel(e.level) == level
      end)
    end, head, first)
    -- The light heads for the newest command its report follows; another hand's, for the report.
    lists.aim = matched(levelVerdict) and lists.level[#lists.level] or head
  end
  local color = state.color
  local colorVerdict
  if color or state.colorOf or raw ~= nil then
    colorVerdict = matchEcho(lists.color, function(entry)
      return self:_echoes("color", entry, raw, function(e)
        local c = e.color
        return color ~= nil and c ~= nil and Color.same(color.x, color.y, color.mode, c.x, c.y, c.mode, self:_match())
      end)
    end, { head = true, token = raw, color = color }, first)
    if state.colorOf then
      color = readColor(state.colorOf(colorVerdict.kind))
    end
  end
  local retimes = self:_retimes()
  -- With no command listed after it the report is where the light heads, so a ramp whose command the
  -- transport gave up on is over.
  local function unheard(v, ramp)
    return v ~= nil and v.kind == "own" and ramp ~= nil and ramp.unheard == true
  end
  local levelUnheard = unheard(levelVerdict, aim.level)
  local levelNews = carriesLevel
    and (not matched(levelVerdict) or (retimes and not matched(colorVerdict)) or levelUnheard)
  local colorNews = not matched(colorVerdict)
    or (retimes and not matched(levelVerdict))
    or unheard(colorVerdict, aim.color)
  local fading = aim.color or (aim.level and aim.level.mergedColor)
  local now = C4:GetTime()
  -- A command waiting in the outbox sets its aspect when it goes, as under the other policies.
  local waiting = dev.outbox.waiting
  -- The color a level ramp carries went with its command, so the light never took it either.
  local carriedUnheard = levelUnheard and aim.level.mergedColor ~= nil

  if carriesLevel and not waiting.level then
    local levelWait = matched(levelVerdict) and #lists.level > 1 and lists.levelUntil - now or 0
    if levelWait <= 0 then
      CancelTimer("Light.EchoLevel")
    end
    if aim.level and levelNews then
      self:_leaveBrightnessRamp()
      self:_notifyBrightnessChanged(level)
    elseif aim.level then
      log:trace("report level %s ignored (ramping)", level)
    elseif levelWait > 0 then
      log:trace("report level %s held: a level was sent since", level)
      SetTimer("Light.EchoLevel", levelWait, function()
        if #dev.echo.level > 1 and not self:_sameLevel(level, self.told.level) then
          self:_notifyBrightnessChanged(level)
        end
      end)
    elseif first or not self:_sameLevel(level, told.level) then
      self:_notifyBrightnessChanged(level)
    end
  end

  -- A light keeps its color while off, so its color is read whether or not it is lit.
  local colorTaken = (colorNews and fading or carriedUnheard) and not waiting.color
  if colorTaken then
    self:_leaveColorRamp()
    if aim.level then
      aim.level.mergedColor = nil -- another hand's color is the light's, as under trust
    end
  end
  local merged = aim.level and aim.level.mergedColor
  if (self:_hasColor() or self:_hasCct()) and not aim.color and not merged and not waiting.color then
    -- A color ramp news ends is told from the report at once, as its level is.
    local wait = not colorTaken and matched(colorVerdict) and #lists.color > 1 and lists.colorUntil - now or 0
    if wait > 0 then
      SetTimer("Light.EchoColor", wait, function()
        if #dev.echo.color > 1 and color then
          self:_tellColor(color)
        end
      end)
    else
      CancelTimer("Light.EchoColor")
      if color then
        self:_tellColor(color, first or colorTaken)
      end
    end
  end
  return { level = levelVerdict, color = colorVerdict }
end

---------------------------------------------------------------------------
-- The verdict
---------------------------------------------------------------------------

--- What a report is, for one aspect, against the newest command of that aspect.
--- @private
--- @return table verdict { kind, seq }
function Reports:_verdictFor(aspect, state, meta, first, history)
  if first then
    return { kind = "first" }
  end
  local n = self:_newest(aspect)
  if history then
    -- A command still waiting has no seq yet.
    return { kind = "history", seq = not self.device.outbox.waiting[aspect] and n and n.seq or nil }
  end
  if meta.news then
    return { kind = "hand" }
  end
  if self:_policy() == "trust" then
    return { kind = "own", seq = n and n.seq }
  end
  local told = self.told
  if aspect == "color" then
    local c = state.color
    local target = n and n.color or told
    local fits = Color.same(c.x, c.y, c.mode, target.x, target.y, target.mode, self:_match())
      or (n ~= nil and C4:GetTime() < (n.word or n.at) + n.ms)
    return { kind = fits and "own" or "hand", seq = fits and n and n.seq or nil }
  end
  -- The level aspect under settle: an OnOff report fits only the command's on or off, and a level
  -- report is judged only while the light is lit; an off light keeps the level it went off at.
  local target = n and n.target
  if target == nil then
    target = told.level
  end
  local fits
  if state.level == nil or meta.control == "onOff" then
    fits = (state.on == true) == (target > 0)
  elseif not self.device.word.on and told.level == 0 then
    fits = true
  else
    local level = self:_toLevel(true, state.level)
    local landing = n and (n.word or n.at) + n.ms
    if n and C4:GetTime() < landing then
      local lo, hi = math.min(n.from or 0, target), math.max(n.from or 0, target)
      fits = level >= lo - 1 and level <= hi + 1
    else
      fits = self:_sameLevel(level, target)
    end
  end
  return { kind = fits and "own" or "hand", seq = fits and n and n.seq or nil }
end

---------------------------------------------------------------------------
-- A report, judged
---------------------------------------------------------------------------

--- Judge a report by the ledger and the policy, and tell what the policy's rules tell.
--- @private
--- @param raw table The adapter's report.
--- @param meta table
--- @param first boolean The first report on a connection.
--- @return table verdict { level, color }
function Reports:_heard(raw, meta, first)
  local state = readState(raw)
  if state.colorOf and self:_policy() ~= "echo" then
    state.color = readColor(state.colorOf(nil))
  end
  local carries = { level = state.on ~= nil or state.level ~= nil, color = state.color ~= nil or state.colorOf ~= nil }
  local waiting = self.device.outbox.waiting
  local history = {}
  -- Before the newest command's word the device has not taken it, and a command still waiting has not
  -- gone. Only ack = "done" leaves a word owed or a command waiting. An answer is to a read sent after
  -- the newest command, so it is of the light after it whatever the word.
  for _, aspect in ipairs({ "level", "color" }) do
    local owed = not meta.answer and self:_unconfirmed(self:_newest(aspect))
    if carries[aspect] and (waiting[aspect] or owed) then
      history[aspect] = true
    end
  end
  -- A level command waiting to go sets the level, or asks the read at its go when it sends nothing.
  if history.level then
    if not waiting.level then
      self:_readAfterHistory(state, meta)
    end
    self:_heardAway(state, meta)
    takeOn(self, state, meta)
  elseif carries.level and self:_acks() then
    self:_heardAway(state, meta, "movedAt")
  end
  local skip = {
    level = history.level or (not carries.level and history.color),
    color = history.color,
  }
  if self:_policy() == "echo" then
    return self:_heardEcho(state, meta, first)
  end
  local verdict = {}
  for _, aspect in ipairs({ "level", "color" }) do
    if carries[aspect] then
      verdict[aspect] = self:_verdictFor(aspect, state, meta, first, history[aspect])
    end
  end
  if not (skip.level and (skip.color or not carries.color)) then
    if self:_policy() == "settle" then
      self:_heardSettle(state, meta, first, skip)
    else
      self:_heardTrust(state, meta, first, skip)
    end
  end
  return verdict
end

--- A report dropped as history still asks the light to be read when it is an off while the newest
--- command's target is above 0, or a level off every path in the ledger.
--- @private
function Reports:_readAfterHistory(state, meta)
  if meta.snapshot then
    return
  end
  local n = self:_newest("level")
  -- An on and a level count only from their own control's report, or a whole one, as takeWord takes them.
  local control = meta.control
  if state.on == false and (control == nil or control == "onOff") then
    -- An off while the newest command lights the light: an Off since, or a report from before it.
    if (n.target or 0) > 0 then
      self:_askRead()
    end
    return
  end
  if state.level == nil or state.on == false or (control ~= nil and control ~= "level") then
    return -- a turn-on while the command turns it off asks nothing: its read-back shows it
  end
  local level = self:_toLevel(true, state.level)
  for _, e in ipairs(self.device.ledger.level) do
    if e.target ~= nil and not self:_offPath(level, e.from or 0, e.target) then
      return
    end
  end
  self:_askRead()
end

--- Whether a report heard as history since the newest level command said the light is away from where
--- that command lands it, or that command is a pre-on whose ramp raised: the level shown then goes again.
--- @private
--- @return boolean
function Reports:_awayHeard()
  local n, away = self:_newest("level"), self.device.awayAt
  return away ~= nil and n ~= nil and away >= n.at
end

--- Note when a report heard as history first says the light is away from where the newest command landed
--- it: the light is read at that command's word, and a command asked since goes, though it asks that level.
--- One heard as it is, under `field` movedAt, says so only to a level waiting for that one.
--- @private
--- @param field string|nil
function Reports:_heardAway(state, meta, field)
  local n = self:_newest("level")
  if not n or n.target == nil or meta.snapshot or C4:GetTime() < n.at + n.ms then
    return
  end
  -- An on and a level count only from their own control's report, or a whole one, as takeWord takes them.
  local control = meta.control
  local offOn = state.on ~= nil and (control == nil or control == "onOff") and state.on ~= (n.target > 0)
  local level = state.on ~= false and (control == nil or control == "level") and state.level
  if offOn or (level and n.target > 0 and not self:_sameLevel(self:_toLevel(true, level), n.target)) then
    field = field or "awayAt"
    local at = self.device[field]
    -- The first time since that command: the light heard away again later hides no time before an ask.
    if not (at and at >= n.at) then
      self.device[field] = C4:GetTime()
    end
  end
end

--- Forget the policy's state: its windows, what it held, and the ledger.
--- @private
function Reports:_resetPolicy()
  local dev = self.device
  dev.settle = nil
  dev.colorSettle = nil
  dev.ledger = { level = {}, color = {} }
  dev.echo = { level = {}, color = {}, levelUntil = 0, colorUntil = 0 }
  CancelTimer("Light.EchoLevel")
  CancelTimer("Light.EchoColor")
end

return Reports
