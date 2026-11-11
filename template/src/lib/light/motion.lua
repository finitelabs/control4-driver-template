--- Where the light is and where it is heading: ramp records and their estimates, retargets and
--- stops, the pre-on, the colors a level carries (merged, carried and on colors), the follow-up
--- window and the same-level re-send. The device fades itself; the library tracks each ramp on the
--- clock so a stop, a retarget or Get Light Level reads where the light has got to. A device that
--- re-times (fade.retimes) runs one transition for every channel: a command that names one aspect
--- takes the other on to its target over the command's own time, and a stop holds the other aspect
--- over the time it has left.

local log = require("lib.logging")
local persist = require("lib.persist")
local Color = require("lib.light.color")
local Fade = require("lib.light.fade")
local Range = require("lib.light.range")
local Settings = require("lib.light.settings")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local FULL, CCT = Color.FULL, Color.CCT

-- A proxy follows a level with the color it already set within this window, which a merged color
-- dedupes: 250 ms covers its usual gap of 6 to 50 ms.
local FOLLOW_UP_MS = 250

--- @class LightMotion
local Motion = {}

---------------------------------------------------------------------------
-- Levels on the range
---------------------------------------------------------------------------

--- The device brightness (0 to 1) a Control4 level (0 to 100) sends.
--- @private
function Motion:_toDevice(level)
  return Range.toDevice(level, self:_onRange())
end

--- Whether a level read back is the level shown.
--- @private
function Motion:_sameLevel(a, b)
  local lo, hi = self:_onRange()
  return Range.sameLevel(a, b, lo, hi, self:_levelSteps())
end

--- The Control4 level (0 to 100) of an on or off and a brightness (0 to 1); one that is on is at least 1.
--- @private
function Motion:_toLevel(on, brightness)
  if not on then
    return 0
  end
  if not self:_dims() then
    return 100
  end
  return Range.toLevel(brightness, self:_onRange())
end

--- Whether a light on at a brightness is outside the range, as a new one can leave it: it shows the
--- range's end, which it is not at. At the device's step for an end it is at that end.
--- @private
function Motion:_outsideRange(brightness)
  local steps = self:_levelSteps()
  if not steps then
    -- A continuous light's report of an end is a float a hair past it, which is still that end.
    return brightness > 0 and (brightness < self:_toDevice(1) - 1e-5 or brightness > self:_toDevice(100) + 1e-5)
  end
  local step = Range.step(brightness, steps)
  return brightness > 0
    and (step < Range.step(self:_toDevice(1), steps) or step > Range.step(self:_toDevice(100), steps))
end

--- Where a light outside the range sits on the range's line: nil inside it, or on a range with no width.
--- @private
function Motion:_outsideAt(brightness)
  return self:_outsideRange(brightness) and Range.linePlace(brightness, self:_onRange()) or nil
end

--- The brightness at a ramp's end: off, its level, or its place outside the range.
--- @private
function Motion:_endBrightness(level, at)
  return at and Range.lineBrightness(at, self:_onRange()) or self:_toDevice(level)
end

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------

--- The color as it goes on the wire, or nil where the light cannot take it: a color temperature
--- carries its kelvin, and anything else goes as a full color on a light with color.
--- @private
--- @return table|nil color { x, y, mode, kelvin }
function Motion:_wireColor(x, y, mode)
  if x == nil or y == nil then
    return nil
  end
  if mode == CCT and self:_hasCct() then
    local k = Color.kelvin(x, y)
    if not k then
      return nil
    end
    return { x = x, y = y, mode = mode, kelvin = k }
  end
  if self:_hasColor() then
    -- Mode 1 always carries its kelvin: a white with none goes as the full color of its point.
    return { x = x, y = y, mode = mode == CCT and FULL or mode }
  end
  return nil
end

--- The ms a ramp has left.
--- @private
--- @param ramp table
--- @return number
function Motion:_timeLeft(ramp)
  return math.max(0, ramp.durationMs - (C4:GetTime() - ramp.startTime))
end

--- Where the adapter's channelsAt has the device's color mid-fade.
--- @private
--- @param now number|nil
--- @return table|nil color { x, y, mode }
function Motion:_colorAt(now)
  local adapter = self.adapter
  if not adapter.channelsAt then
    return nil
  end
  return adapter:channelsAt(now or C4:GetTime())
end

--- The least time a stop must take now: fade.darkBetweenModes while a color ramp in flight crosses
--- between color modes, which the device runs through dark; nil otherwise.
--- @private
--- @return number|nil stopMs
function Motion:_darkStopMs()
  local decl, ramp = self.device.live, self.aim.color
  local dark = decl and decl.fade.darkBetweenModes
  if dark and ramp and ramp.startMode ~= ramp.targetMode then
    return dark
  end
  return nil
end

--- Where a color leaves the light: the adapter's shows says, for a device that holds some colors
--- elsewhere (a color temperature past its range at the range's end).
--- @private
--- @return number x, number y
function Motion:_held(x, y, mode)
  if not self.adapter.shows then
    return x, y
  end
  local held = self.adapter:shows({ x = x, y = y, mode = mode })
  return held.x, held.y
end

--- Whether the light, with Dim-To-Warm, is in or on its way to a color other than the one `level` carries.
--- @private
function Motion:_awayFromFadeColor(level)
  local fade = level > 0 and self:_colorOnModeKind() == Settings.COLOR_ON_MODE_FADE and self:_fadeColor(level)
  if not fade or not self:_wireColor(fade.x, fade.y, fade.mode) then
    return false
  end
  local told, ramp = self.told, self.aim.color
  local x, y, mode = told.x, told.y, told.mode
  if ramp then
    x, y, mode = ramp.targetX, ramp.targetY, ramp.targetMode
  end
  return not Color.same(x, y, mode, fade.x, fade.y, fade.mode)
end

--- The light is "logically on" if a ramp in flight is heading for an on level, or with none in flight
--- if it is told on. A color command sends this state: the other would switch a light off in a fade
--- up, or send an On to one fading to off.
--- @private
function Motion:_isLogicallyOn()
  local ramp = self.aim.level
  if ramp then
    return (ramp.targetLevel or 0) > 0
  end
  return self.told.level > 0
end

---------------------------------------------------------------------------
-- A command whose send raised
---------------------------------------------------------------------------

--- What a command may change before it sends: the ramps and what they carry, the levels and color told,
--- the press and the scene run.
--- @private
--- @return table kept
function Motion:_keep()
  local aim, told, ramp = self.aim, self.told, self.aim.level
  return {
    level = ramp,
    carried = ramp and { mergedColor = ramp.mergedColor, onColor = ramp.onColor, colorSet = ramp.colorSet },
    color = aim.color,
    prePress = aim.prePress,
    mergedUntil = aim.mergedUntil,
    told = { level = told.level, x = told.x, y = told.y, mode = told.mode, levelPreset = told.levelPreset },
    colorPreset = told.colorPreset,
    generation = self.scenes.generation,
  }
end

--- Put the model back as it was kept, each ramp with its end.
--- @private
--- @param k table
function Motion:_putBack(k)
  local aim, told = self.aim, self.told
  aim.level, aim.color, aim.prePress, aim.mergedUntil = k.level, k.color, k.prePress, k.mergedUntil
  for key, value in pairs(k.told) do
    told[key] = value
  end
  told.colorPreset = k.colorPreset
  self.scenes.generation = k.generation
  local now = C4:GetTime()
  local ramp, color = aim.level, aim.color
  if ramp then
    ramp.mergedColor, ramp.onColor, ramp.colorSet = k.carried.mergedColor, k.carried.onColor, k.carried.colorSet
  end
  -- A scene step's ramp ends with its scene's timer, but on a device that re-times, where it has its own.
  local timed = self:_retimes()
  if ramp and (timed or not ramp.step) then
    SetTimer("Light.BrightnessRamp", math.max(0, ramp.startTime + ramp.durationMs - now), function()
      self:_brightnessRampFinished(ramp.targetLevel)
    end, false)
  elseif not ramp then
    CancelTimer("Light.BrightnessRamp")
  end
  if color and (timed or not color.step) then
    SetTimer("Light.ColorRamp", math.max(0, color.startTime + color.durationMs - now), function()
      self:_colorRampFinished(color.targetX, color.targetY, color.targetMode)
    end, false)
  elseif not color then
    CancelTimer("Light.ColorRamp")
  end
end

--- Run what a proxy command or a scene step does. A send in it that raises sent nothing, so the model is
--- put back as it was, and the error is raised again.
--- @private
--- @param fn function Called as fn(self, ...).
function Motion:_guard(fn, ...)
  local kept = self:_keep()
  local ok, result = pcall(fn, self, ...)
  if not ok then
    self:_putBack(kept)
    error(result, 0)
  end
  return result
end

---------------------------------------------------------------------------
-- Level commands
---------------------------------------------------------------------------

--- Send the light a level, with the color it carries: Dim-To-Warm's for any level, or the on
--- color for an on from off, whose rated form goes after a pre-on. `at` holds a light outside the
--- range at its place on the range's line.
--- @private
--- @param level integer
--- @param rateMs integer|nil
--- @param keepColor boolean|nil A stop holds the level alone when the color is not its ramp's to send again.
--- @param at number|nil
function Motion:_setDeviceBrightness(level, rateMs, keepColor, at)
  local hasRate = rateMs and rateMs > 0
  local goingOn = level > 0 and self.told.level == 0

  local brightness = self:_endBrightness(level, at)
  local cmd = {
    on = level > 0,
    level = level > 0 and brightness or nil,
    -- A rate of 0 goes too, so it ends a transition in flight rather than fall back to the device's default.
    ms = hasRate and rateMs or 0,
  }

  -- The color rides the level so the two move as one transition: Dim-To-Warm's for any level
  -- (Light V2 _7.2: a color set lasts until the next level), and the on color for an on from off.
  local mergedColor = nil
  if not keepColor then
    if level > 0 and self:_colorOnModeKind() == Settings.COLOR_ON_MODE_FADE then
      mergedColor = self:_fadeColor(level)
    elseif goingOn then
      mergedColor = self:_onColor(level)
    end
  end
  local wire = mergedColor and self:_wireColor(mergedColor.x, mergedColor.y, mergedColor.mode)
  if wire then
    cmd.color = wire
    -- The proxy's follow-up SET_COLOR_TARGET for this color is taken as already sent.
    self.aim.mergedUntil = C4:GetTime() + FOLLOW_UP_MS
    -- The color is the on mode's, not one the proxy set: told as the preset it is, if any, which
    -- the proxy's own follow-up names too; a Dim-To-Warm mix is no preset's.
    self.told.colorPreset = mergedColor.preset
    -- A level change's color is told at the ramp's end; an on's was told at once, and only matches
    -- the proxy's follow-up.
    local ramp = self.aim.level
    if ramp then
      local color = { x = mergedColor.x, y = mergedColor.y, mode = mergedColor.mode, preset = mergedColor.preset }
      if goingOn then
        ramp.onColor = color
      else
        ramp.mergedColor = color
      end
    end
  end
  local preOnLevel = goingOn and hasRate and self:_preOnLevel()
  local preOn = preOnLevel and { preOn = true, on = true, level = preOnLevel, color = wire, ms = 0 } or nil
  local now = C4:GetTime()
  self:_command(cmd, { target = level, brightness = brightness }, preOn)
  -- The proxy does not always send a color of its own (Dim-To-Warm drives it from the formula),
  -- so the color's CHANGING or CHANGED mirrors the level's.
  if wire then
    -- The color sent last is the one the light goes to, so a color ramp in flight ends here: its
    -- end would tell the proxy, and re-send, a color the light has left.
    self:_leaveColorRamp(now)
    if hasRate and not goingOn then
      -- The ramp's end makes the target current, so CHANGING carries the color the light is leaving.
      self:_notifyColorChanging(mergedColor.x, mergedColor.y, mergedColor.mode, rateMs)
    else
      self:_notifyColorChanged(mergedColor.x, mergedColor.y, mergedColor.mode)
    end
  elseif self:_retimes() then
    self:_retimeColor(cmd.ms, keepColor, now)
  end
end

--- The level a ramp has the light at, and its place on the range's line outside it. To or from off the light is on
--- from half a level above off (a pre-on would dip it); a `stop` below level 1 holds at the Min, or off under half way.
--- @private
--- @param stop boolean|nil
--- @param now number|nil When a command that re-times the ramp went out.
--- @return integer level, number|nil at
function Motion:_interpolatedBrightness(stop, now)
  local ramp = self.aim.level
  if not ramp or ramp.durationMs <= 0 then
    return self.told.level
  end
  local elapsed = (now or C4:GetTime()) - ramp.startTime
  if elapsed <= 0 then
    return ramp.startLevel, ramp.startAt
  end
  if elapsed >= ramp.durationMs then
    return ramp.targetLevel, ramp.targetAt
  end
  -- The light runs along the line, off at brightness 0's place below level 1.
  local lo, hi = self:_onRange()
  local off = Range.linePlace(0, lo, hi) or 0
  local from = ramp.startLevel > 0 and (ramp.startAt or ramp.startLevel) or off
  local to = ramp.targetLevel > 0 and (ramp.targetAt or ramp.targetLevel) or off
  local at = Fade.along(from, to, self:_curve(elapsed / ramp.durationMs))
  local lit = ramp.startLevel > 0 and ramp.targetLevel > 0
  if not lit and at < (stop and (1 + off) / 2 or off + 0.5) then
    return 0
  end
  local outside = at > 100 or (at < 1 and (lit or not stop))
  return math.max(1, math.min(100, math.floor(at + 0.5))), outside and at or nil
end

--- Hand the color a level ramp carries to the color ramp: the light goes on to it at the ramp's
--- pace whatever replaces the ramp, and what sends a color of its own ends it where it has got to.
--- @private
function Motion:_leaveMergedColor()
  local ramp = self.aim.level
  local merged = ramp and ramp.mergedColor
  if not merged then
    return
  end
  ramp.mergedColor = nil
  local left = ramp.startTime + ramp.durationMs - C4:GetTime()
  if left <= 0 then
    self:_notifyColorChanged(merged.x, merged.y, merged.mode) -- its time is up: the color has arrived
    return
  end
  local told = self.told
  self.aim.color = {
    startTime = ramp.startTime,
    startX = told.x,
    startY = told.y,
    startMode = told.mode,
    targetX = merged.x,
    targetY = merged.y,
    targetMode = merged.mode,
    durationMs = ramp.durationMs,
    carried = true,
  }
  -- The light may be off by then, so its end tells the proxy and sends nothing.
  SetTimer("Light.ColorRamp", left, function()
    self:_colorRampFinished(merged.x, merged.y, merged.mode)
  end, false)
end

--- End a level ramp where it has got to: what replaces it starts there.
--- @private
--- @param now number|nil When the command that replaces it went out.
--- @return number|nil outside The light's place on the range's line where it is outside the range.
--- @return table|nil ramp The ramp it ended.
function Motion:_leaveBrightnessRamp(now)
  local outside = self:_outsideAt(self:_aimBrightness())
  local ramp = self.aim.level
  if ramp then
    local at
    at, outside = self:_interpolatedBrightness(nil, now)
    if at == 0 and self.told.level > 0 then
      self:_endOnCycle() -- a fade retargeted as it reaches off has ended its on cycle
    end
    self.told.level = at
    self:_leaveMergedColor()
  end
  CancelTimer("Light.BrightnessRamp")
  self.aim.level = nil
  return outside, ramp
end

--- A level command on a device that re-times: a color still on its way runs on to its target over
--- the command's time, at once with none, and is told so unless the command is a stop's hold.
--- @private
--- @param ms integer
--- @param held boolean|nil
--- @param now number When the command went out.
function Motion:_retimeColor(ms, held, now)
  local ramp = self.aim.color
  if not ramp then
    return
  end
  self:_leaveColorRamp(now)
  self:_carryColor(ramp.targetX, ramp.targetY, ramp.targetMode, ms, ramp, now)
  if self.aim.color and not ramp.told and not held then
    self:_notifyColorChanging(ramp.targetX, ramp.targetY, ramp.targetMode, ms)
  end
end

--- A color the light is already on its way to, with no command of its own: its end only tells.
--- @private
--- @param from table|nil The ramp it carries on, whose flags it keeps.
--- @param now number|nil When the command that re-timed it went out.
function Motion:_carryColor(x, y, mode, ms, from, now)
  local told = self.told
  local toldAtOff = from and from.told
  if toldAtOff then
    told.x, told.y, told.mode = x, y, mode -- an off told it, so it is the color told
  end
  if ms <= 0 then
    if not toldAtOff then
      self:_notifyColorChanged(x, y, mode)
    end
    return
  end
  self.aim.color = {
    startTime = now or C4:GetTime(),
    startX = told.x,
    startY = told.y,
    startMode = told.mode,
    targetX = x,
    targetY = y,
    targetMode = mode,
    durationMs = ms,
    carried = not from or from.carried,
    told = toldAtOff,
  }
  SetTimer("Light.ColorRamp", ms, function()
    self:_colorRampFinished(x, y, mode)
  end, false)
end

--- A color command on a device that re-times: a level still on its way runs on to its target over
--- the command's time, and is told so unless the command is a stop's hold or a color for an off.
--- @private
--- @param ms integer
--- @param held boolean|nil
--- @param now number When the command went out.
function Motion:_retimeBrightness(ms, held, now)
  local startAt, ramp = self:_leaveBrightnessRamp(now)
  if not ramp then
    return
  end
  local told = self.told
  -- Outside the range a light can show its target level and still be moving.
  if ms <= 0 or (told.level == ramp.targetLevel and startAt == ramp.targetAt) then
    self:_notifyBrightnessChanged(ramp.targetLevel)
    return
  end
  local level = {
    startTime = now,
    startLevel = told.level,
    startAt = startAt,
    targetLevel = ramp.targetLevel,
    targetAt = ramp.targetAt,
    from = self:_endBrightness(told.level, startAt),
    to = ramp.to,
    durationMs = ms,
    colorSet = ramp.colorSet,
  }
  self.aim.level = level
  if not held then
    self:_notifyBrightnessChanging(level.targetLevel, ms)
  end
  SetTimer("Light.BrightnessRamp", ms, function()
    self:_brightnessRampFinished(level.targetLevel)
  end, false)
end

--- A level ramp has run its time: tell its end, and the color it carried.
--- @private
--- @param targetLevel integer
function Motion:_brightnessRampFinished(targetLevel)
  CancelTimer("Light.BrightnessRamp")
  local ramp = self.aim.level
  local mergedColor = ramp and ramp.mergedColor
  self.aim.level = nil
  self:_notifyBrightnessChanged(targetLevel)
  if mergedColor then
    self:_notifyColorChanged(mergedColor.x, mergedColor.y, mergedColor.mode)
  end
end

--- Halt the light's level where its ramp has got to.
--- @private
function Motion:_brightnessRampStopped()
  CancelTimer("Light.BrightnessRamp")
  local ramp = self.aim.level
  if not ramp then
    return
  end
  local stoppedAt, at = self:_interpolatedBrightness(true)
  -- A color still ramping, or set since the ramp began, is not the level's to replace. One a
  -- replaced ramp carried is the level's own. An on from off is lit in its color, which only Dim-To-Warm moves.
  local colorRamp = self.aim.color
  local keepColor = (colorRamp and not colorRamp.carried)
    or ramp.colorSet
    or (ramp.startLevel == 0 and self:_colorOnModeKind() ~= Settings.COLOR_ON_MODE_FADE)
  if self:_retimes() then
    self:_heldBrightnessStop(stoppedAt, at, keepColor)
    return
  end
  self.aim.level = nil
  -- A command at once at the estimate: the light halts there.
  self:_setDeviceBrightness(stoppedAt, 0, keepColor, at)
  self:_notifyBrightnessChanged(stoppedAt)
end

--- A level stop on a device that re-times: a kept color runs on over the time it has left, and a
--- light dark between color modes eases back up over fade.darkBetweenModes.
--- @private
function Motion:_heldBrightnessStop(stoppedAt, at, keepColor)
  local stopMs = self:_darkStopMs()
  local dimmed = not keepColor and stoppedAt > 0 and stopMs ~= nil
  if dimmed then
    self:_leaveMergedColor()
    if self.aim.color then
      -- The color in flight is the level's own: one command holds both where the light is.
      self.aim.level = nil
      self.told.level = stoppedAt
      self:_colorRampStopped(stoppedAt, at)
      self:_notifyBrightnessChanged(stoppedAt)
      return
    end
  end
  local colorRamp = self.aim.color
  local hold = keepColor and colorRamp and self:_timeLeft(colorRamp) or 0
  if dimmed then
    hold = stopMs
  end
  self.aim.level = nil
  if hold > 0 and stoppedAt > 0 then
    self.told.level = stoppedAt -- a hold, not a turn-on: no pre-on
  end
  self:_setDeviceBrightness(stoppedAt, hold, keepColor, at)
  self:_notifyBrightnessChanged(stoppedAt)
end

--- Take the light to a level over a rate. `startAt` is where a click's press found a light outside
--- the range, the press's ramp being gone.
--- @private
--- @param level number
--- @param rate number|nil
--- @param presetId integer|nil The brightness preset driving this level; any other caller clears it.
--- @param startAt number|nil
--- @param pressRamp table|nil A click's press's hold ramp, which the click replaces.
function Motion:_rampToBrightness(level, rate, presetId, startAt, pressRamp)
  level = math.max(0, math.min(100, math.floor((level or 0) + 0.5)))
  rate = self:_rate(math.max(0, tointeger(rate) or 0))

  log:debug("rampToBrightness(%s, %s) from %s", level, rate, self.told.level)

  -- A light that does not dim switches at once, whatever the rate, as it does for an On or an Off.
  if not self:_dims() then
    self.told.levelPreset = presetId
    self:_switchLight(level > 0)
    return
  end

  self:_stopSceneSteps()

  self.told.levelPreset = presetId

  local leftAt, left = self:_leaveBrightnessRamp()
  startAt = leftAt or startAt
  local replaced = left or pressRamp

  local startingLevel = self.told.level
  -- A light outside the range is not at the level it shows: it goes there.
  if level == startingLevel and not startAt then
    -- A ramp this replaces, or a command still settling, has the light on its way to another level:
    -- this brings it back, as it does a light outside a range with no width. With Dim-To-Warm it
    -- brings the level's color back too, from one set since.
    if
      (replaced and replaced.targetLevel ~= level)
      or self:_aimDiffers(level)
      or self:_awayHeard()
      or self:_outsideRange(self:_aimBrightness())
      or self:_awayFromFadeColor(level)
    then
      self:_setDeviceBrightness(level, 0)
    end
    self:_notifyBrightnessChanged(level)
    return
  end

  if rate == 0 then
    self:_setDeviceBrightness(level, 0)
    self:_notifyBrightnessChanged(level)
    return
  end

  local ramp = {
    startTime = C4:GetTime(),
    startLevel = startingLevel,
    startAt = startAt,
    targetLevel = level,
    from = self:_endBrightness(startingLevel, startAt),
    to = self:_toDevice(level),
    durationMs = rate,
  }
  self.aim.level = ramp
  self:_setDeviceBrightness(level, rate)
  self:_notifyBrightnessChanging(level, rate)
  SetTimer("Light.BrightnessRamp", rate, function()
    self:_brightnessRampFinished(ramp.targetLevel) -- a new range moves it
  end, false)
end

---------------------------------------------------------------------------
-- Color commands
---------------------------------------------------------------------------

--- Send the light a color, saying whether it is lit.
--- @private
--- @param stop table|nil A color stop: { level, at } for a level stopped with it.
function Motion:_sendColor(x, y, mode, rateMs, stop)
  local unread = self:_unsure()
  local cmd = { on = self:_colorLit() }
  cmd.color = self:_wireColor(x, y, mode)
  cmd.ms = (rateMs and rateMs > 0) and rateMs or 0
  local intent = {}
  if stop then
    cmd.stop = "color"
    if stop.level then
      intent.target = stop.level
      intent.brightness = self:_endBrightness(stop.level, stop.at)
      cmd.level = intent.brightness
    end
  end
  self:_command(cmd, intent)
  if unread then
    self:_learnLevel() -- the read under way answers from before this command, which is no answer after it
  end
end

--- Where a color ramp has the light. From a full color to a white the light passes through colors:
--- a point off the line of whites is told and sent as a full color.
--- @private
--- @param now number|nil When a command that re-times the ramp went out.
--- @return number x, number y, integer mode
function Motion:_interpolatedColor(now)
  local ramp, told = self.aim.color, self.told
  if not ramp or ramp.durationMs <= 0 then
    return told.x, told.y, told.mode
  end
  now = now or C4:GetTime()
  local elapsed = now - ramp.startTime
  if elapsed >= ramp.durationMs then
    return ramp.targetX, ramp.targetY, ramp.targetMode
  end
  local at = self:_colorAt(now)
  if at then
    return at.x, at.y, at.mode
  end
  local progress = self:_curve(Fade.progress(elapsed, ramp.durationMs))
  -- The light fades between the colors it holds, from where the ramp found it.
  local fromX, fromY = ramp.startX, ramp.startY
  if elapsed > 0 then
    fromX, fromY = self:_held(fromX, fromY, ramp.startMode)
  end
  local toX, toY = self:_held(ramp.targetX, ramp.targetY, ramp.targetMode)
  local x = fromX + (toX - fromX) * progress
  local y = fromY + (toY - fromY) * progress
  if ramp.startMode == FULL and ramp.targetMode == CCT then
    local whiteX, whiteY = self:_taken(x, y, CCT)
    if not Color.same(x, y, CCT, whiteX, whiteY, CCT) then
      return x, y, FULL
    end
  end
  return x, y, ramp.targetMode
end

--- End a color ramp where it has got to: what replaces it starts there.
--- @private
--- @param now number|nil When the command that replaces it went out.
function Motion:_leaveColorRamp(now)
  local told = self.told
  told.x, told.y, told.mode = self:_interpolatedColor(now)
  CancelTimer("Light.ColorRamp")
  self.aim.color = nil
end

--- A color ramp has run its time: tell its end unless an off already told it.
--- @private
function Motion:_colorRampFinished(targetX, targetY, targetMode)
  CancelTimer("Light.ColorRamp")
  local ramp = self.aim.color
  local told = ramp and ramp.told -- at an off, with the preset id the off then dropped
  self.aim.color = nil
  if not told then
    self:_notifyColorChanged(targetX, targetY, targetMode)
  end
end

--- Halt the light's color where its ramp has got to.
--- @private
--- @param level integer|nil A level stopped with it, in one command.
--- @param at number|nil That level's place outside the range.
function Motion:_colorRampStopped(level, at)
  CancelTimer("Light.ColorRamp")
  if not self.aim.color then
    return
  end
  local x, y, mode = self:_interpolatedColor()
  if self:_retimes() then
    self:_heldColorStop(x, y, mode, level, at)
    return
  end
  self.aim.color = nil
  -- The light is sent where the ramp should have got to, and holds there: a bulb has been seen to answer Stop
  -- Move Step and fade on, reading back the target, so neither that stop nor a read-back can hold or place it.
  self:_sendColor(x, y, mode, 0)
  local told = self.told
  told.x, told.y, told.mode = x, y, mode
  self:_notifyColorChanged(x, y, mode)
end

--- A color stop on a device that re-times: held over the level's time left, or fade.darkBetweenModes
--- while the light is dark between color modes, and the level re-timed to end with it.
--- @private
function Motion:_heldColorStop(x, y, mode, level, at)
  local now = C4:GetTime()
  if self.adapter.shows then
    x, y, mode = self:_taken(x, y, mode)
  end
  local levelRamp = self.aim.level
  local hold = levelRamp and self:_timeLeft(levelRamp) or 0
  local stopMs = self:_darkStopMs()
  if stopMs then
    hold = math.max(hold, stopMs)
  end
  self.aim.color = nil
  self:_sendColor(x, y, mode, hold, { level = level, at = at })
  local told = self.told
  told.x, told.y, told.mode = x, y, mode
  self:_notifyColorChanged(x, y, mode)
  self:_retimeBrightness(hold, true, now)
end

--- Take the light to a color over a rate.
--- @private
function Motion:_rampToColor(targetX, targetY, targetMode, rate)
  rate = self:_rate(math.max(0, tointeger(rate) or 0))
  local now = C4:GetTime()

  -- The target replaces the on color a level ramp carries, which would otherwise show at its end.
  self:_leaveMergedColor()
  self:_leaveColorRamp()
  -- A stop of the level ramp in flight keeps this color, and the on's color asked for after it is news.
  local levelRamp = self.aim.level
  if levelRamp then
    levelRamp.colorSet, levelRamp.onColor = true, nil
  end

  local told = self.told
  local retimes = self:_retimes()
  -- Off or fading to off, a device that re-times takes the color over what the fade to off has left.
  local off = retimes and not self:_isLogicallyOn()
  if off then
    rate = levelRamp and self:_timeLeft(levelRamp) or 0
  end
  if off or (retimes and rate == 0) then
    told.x, told.y, told.mode = targetX, targetY, targetMode
    self:_sendColor(targetX, targetY, targetMode, rate)
    self:_notifyColorChanged(targetX, targetY, targetMode)
    self:_retimeBrightness(rate, off, now)
    return
  end
  if rate == 0 then
    told.x, told.y, told.mode = targetX, targetY, targetMode
    self:_sendColor(targetX, targetY, targetMode, 0)
    self:_notifyColorChanged(targetX, targetY, targetMode)
    return
  end

  self.aim.color = {
    startTime = C4:GetTime(),
    startX = told.x,
    startY = told.y,
    startMode = told.mode,
    targetX = targetX,
    targetY = targetY,
    targetMode = targetMode,
    durationMs = rate,
  }
  self:_sendColor(targetX, targetY, targetMode, rate)
  self:_notifyColorChanging(targetX, targetY, targetMode, rate)
  -- Mode change is logically instantaneous; mid-ramp the xy is interpolated.
  told.mode = targetMode
  -- Its end sends nothing: a bulb can take longer than the time asked, and a color sent then would jump it there.
  SetTimer("Light.ColorRamp", rate, function()
    self:_colorRampFinished(targetX, targetY, targetMode)
  end, false)
  if retimes then
    self:_retimeBrightness(rate, nil, now)
  end
end

---------------------------------------------------------------------------
-- On, off and toggle
---------------------------------------------------------------------------

--- An On/Off-only light switches at once, and has no level ramp to replace. On a device that re-times the
--- switch, at once, takes a color on its way with it.
--- @private
function Motion:_switchLight(on)
  local level = on and 100 or 0
  self:_stopSceneSteps()
  local now = C4:GetTime()
  self:_command({ on = on }, { target = level })
  if self:_retimes() then
    self:_retimeColor(0, nil, now)
  end
  self:_notifyBrightnessChanged(level)
end

--- @private
function Motion:_lightOn(rate)
  local level = self:_onBrightness()
  if not self:_dims() then
    self:_switchLight(true)
    return
  end
  -- The color on modes ride the level's own commands, a rated on's pre-on too: a separate color
  -- command would queue two, and the second would restart the transition in flight.
  self:_rampToBrightness(level, rate or 0)
end

--- @private
function Motion:_lightOff(rate)
  if self:_dims() then
    self:_rampToBrightness(0, rate or 0)
  else
    self:_switchLight(false)
  end
end

--- @private
function Motion:_lightToggle(rate)
  if self:_interpolatedBrightness() > 0 then
    self:_lightOff(rate)
  else
    self:_lightOn(rate)
  end
end

---------------------------------------------------------------------------
-- Proxy commands
---------------------------------------------------------------------------

--- SET_BRIGHTNESS_TARGET, with the preset that drives it (Light V2 _2.1) told back on each CHANGED.
--- @private
function Motion:_setBrightnessTarget(tParams)
  local level = tonumber(Select(tParams, "LIGHT_BRIGHTNESS_TARGET")) or 0
  local rate = tointeger(Select(tParams, "RATE")) or self:_defaultRate()
  local presetId = tointeger(Select(tParams, "LIGHT_BRIGHTNESS_TARGET_PRESET_ID"))
  self:_rampToBrightness(level, rate, presetId)
end

--- SET_LEVEL: at once.
--- @private
function Motion:_setLevel(tParams)
  local level = tointeger(Select(tParams, "LEVEL")) or 0
  if self:_dims() then
    self:_rampToBrightness(level, 0)
  elseif level > 0 then
    self:_lightOn()
  else
    self:_lightOff()
  end
end

--- RAMP_TO_LEVEL, the legacy form older programming and Alexa Voice Scenes send.
--- @private
function Motion:_rampToLevel(tParams)
  self:_setBrightnessTarget({
    LIGHT_BRIGHTNESS_TARGET = Select(tParams, "LEVEL"),
    RATE = Select(tParams, "TIME"),
  })
end

--- SET_COLOR_TARGET, by xy, by kelvin, or by a preset the light stores.
--- @private
function Motion:_setColorTarget(tParams)
  local kelvin = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE"))
  local x = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_X"))
  local y = tonumber(Select(tParams, "LIGHT_COLOR_TARGET_Y"))
  local incomingMode = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_MODE"))
  local rate = tointeger(
    Select(tParams, "LIGHT_COLOR_TARGET_COLOR_RATE")
      or Select(tParams, "LIGHT_COLOR_TARGET_RATE")
      or Select(tParams, "RATE")
  ) or self:_defaultColorRate()

  -- A preset named with no coordinates is looked up here, so the light still gets a color (Light V2 _3.1).
  local presetId = tointeger(Select(tParams, "LIGHT_COLOR_TARGET_PRESET_ID"))
  if presetId ~= nil and not (x and y) and not (kelvin and kelvin > 0) then
    local preset = persist:get(Settings.P_COLOR_PRESETS, {})[tostring(presetId)]
    if preset then
      x = preset.x
      y = preset.y
      incomingMode = preset.mode
    else
      log:warn("SET_COLOR_TARGET: unknown LIGHT_COLOR_TARGET_PRESET_ID=%s", presetId)
      return
    end
  end
  self.told.colorPreset = presetId

  local targetX, targetY, targetMode
  if kelvin and kelvin > 0 and self:_hasCct() then
    targetX, targetY = C4:ColorCCTtoXY(kelvin)
    targetMode = CCT
  elseif incomingMode == CCT and self:_hasCct() and x and y then
    if not Color.kelvin(x, y) then
      log:warn("SET_COLOR_TARGET: ColorXYtoCCT(%s, %s) gave no color temperature", x, y)
      return
    end
    targetX, targetY, targetMode = self:_taken(x, y, CCT)
  elseif x and y and self:_hasColor() then
    targetX, targetY, targetMode = self:_taken(x, y, FULL)
  else
    log:warn(
      "SET_COLOR_TARGET ignored (kelvin=%s x=%s y=%s mode=%s color=%s cct=%s)",
      tostring(kelvin),
      tostring(x),
      tostring(y),
      tostring(incomingMode),
      tostring(self:_hasColor()),
      tostring(self:_hasCct())
    )
    return
  end

  -- The color a level command just merged would restart its transition if sent again. An on's was
  -- told at once, and is told again only in another preset the proxy names.
  local now = C4:GetTime()
  local ramp = self.aim.level
  local merged = ramp and (ramp.mergedColor or ramp.onColor)
  if
    now < self.aim.mergedUntil
    and merged
    and Color.same(merged.x, merged.y, merged.mode, targetX, targetY, targetMode)
  then
    log:debug("SET_COLOR_TARGET deduped (%sms remaining in merged-color window)", self.aim.mergedUntil - now)
    if not ramp.onColor then
      ramp.mergedColor = { x = targetX, y = targetY, mode = targetMode }
    elseif presetId and presetId ~= ramp.onColor.preset then
      self:_notifyColorChanged(targetX, targetY, targetMode)
    end
    return
  end

  self:_rampToColor(targetX, targetY, targetMode, rate)
end

--- SET_BRIGHTNESS_STOP: a light told to stop is not then moved by a later scene step.
--- @private
function Motion:_setBrightnessStop()
  self:_stopSceneSteps()
  self:_brightnessRampStopped()
end

--- SET_COLOR_STOP.
--- @private
function Motion:_setColorStop()
  self:_colorRampStopped()
end

--- A new range moves the level the light's own brightness shows at, on the device's page at once and
--- here; one a command still waits on shows when it settles. A ramp in flight runs on between the
--- same brightnesses, whose places move.
--- @private
function Motion:_remapLevel()
  self:_tellRange()
  local ramp = self.aim.level
  if ramp then
    ramp.startLevel, ramp.startAt = self:_toLevel(ramp.from > 0, ramp.from), self:_outsideAt(ramp.from)
    ramp.targetLevel, ramp.targetAt = self:_toLevel(ramp.to > 0, ramp.to), self:_outsideAt(ramp.to)
    return
  end
  if self:_policy() == "echo" then
    -- The newest command listed, or the light's own word, read through the new range.
    local brightness = self:_aimBrightness()
    local level = brightness > 0 and self:_toLevel(true, brightness) or 0
    if self:_dims() and not self:_sameLevel(level, self.told.level) then
      self:_notifyBrightnessChanged(level)
    end
    return
  end
  local level = self:_knownLevel()
  if not self:_pending() and level ~= nil and level ~= self.told.level then
    self:_notifyBrightnessChanged(level)
  end
end

--- GET_LIGHT_LEVEL, the legacy read: where a ramp has got to as CHANGING, else the level as CHANGED.
--- @private
function Motion:_getLightLevel()
  local ramp = self.aim.level
  if ramp then
    -- A CHANGED level is one the light has stopped at.
    local left = ramp.startTime + ramp.durationMs - C4:GetTime()
    self:_notifyBrightnessChanging(ramp.targetLevel, math.max(0, left), self:_interpolatedBrightness())
    return
  end
  self:_notifyBrightnessChanged(self.told.level)
end

return Motion
