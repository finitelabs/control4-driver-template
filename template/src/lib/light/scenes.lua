--- Advanced Lighting Scenes: the elements the proxy pushes, their steps run on timers, and the
--- ramp and stop commands. A scene's steps are kept in lib.persist; how far one has run is kept on
--- the instance, since a restart drops its timers anyway.

local log = require("lib.logging")
local persist = require("lib.persist")
local Color = require("lib.light.color")
local Settings = require("lib.light.settings")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local FULL, CCT = Color.FULL, Color.CCT

--- @class LightScenes
local Scenes = {}

local function getScenes()
  return persist:get(Settings.P_SCENES, {})
end

local function saveScenes(scenes)
  persist:set(Settings.P_SCENES, scenes)
end

local function timerName(sceneId)
  return "Light.Scene." .. tostring(sceneId)
end

--- The steps of a scene's <element> XML, normalised; a step that sets nothing and waits nothing is dropped.
--- @param elementsXml string|nil
--- @return table[] steps
local function parseSceneElements(elementsXml)
  local steps = {}
  if IsEmpty(elementsXml) then
    return steps
  end
  local parsed = ParseXml("<root>" .. elementsXml .. "</root>")
  local elementList = Select(parsed, "root", "element") or {}
  if not IsList(elementList) then
    elementList = { elementList }
  end
  for _, el in ipairs(elementList) do
    if type(el) == "table" then
      local rawBrightnessEnabled = Select(el, "brightnessEnabled")
      local rawColorEnabled = Select(el, "colorEnabled")
      local step = {
        delay = tointeger(Select(el, "delay")) or 0,
        brightnessRate = tointeger(Select(el, "brightnessRate") or Select(el, "rate")) or 0,
        colorRate = tointeger(Select(el, "colorRate")) or 0,
        level = tointeger(Select(el, "brightness") or Select(el, "level")),
        levelEnabled = toboolean(rawBrightnessEnabled),
        colorEnabled = toboolean(rawColorEnabled),
        colorX = tonumber(Select(el, "colorX")),
        colorY = tonumber(Select(el, "colorY")),
        colorMode = tointeger(Select(el, "colorMode")),
      }
      -- Legacy schemas put <level> at the element root with no <brightnessEnabled> wrapper. Only
      -- promote when the wrapper is truly absent: toboolean reads nil and "false" alike.
      if rawBrightnessEnabled == nil and rawColorEnabled == nil and step.level ~= nil then
        step.levelEnabled = true
      end
      if step.colorRate == 0 and step.brightnessRate > 0 then
        step.colorRate = step.brightnessRate
      end
      if step.levelEnabled or step.colorEnabled or step.delay > 0 then
        table.insert(steps, step)
      end
    end
  end
  log:debug("parseSceneElements: %d step(s) parsed", #steps)
  return steps
end

--- A level command takes the light out of a scene, as on Control4's own lights: no later step runs.
--- The step in flight still ends the ramps of its own that the command left.
--- @private
function Scenes:_stopSceneSteps()
  self.scenes.generation = self.scenes.generation + 1
end

--- @private
function Scenes:_stopAllScenes()
  self.scenes.generation = self.scenes.generation + 1
  for sceneId, _ in pairs(getScenes()) do
    CancelTimer(timerName(sceneId))
  end
  -- A step's ramps have only its timer to end them: each runs on to its own end, as the device does, but
  -- a level ramp under settle, which its settle ends. On a device that re-times each has its own timer.
  if self:_retimes() then
    return
  end
  local settle = self:_policy() == "settle"
  local ramp = self.aim.color
  if ramp and ramp.step then
    SetTimer("Light.ColorRamp", math.max(0, ramp.startTime + ramp.durationMs - C4:GetTime()), function()
      self:_colorRampFinished(ramp.targetX, ramp.targetY, ramp.targetMode)
    end, false)
  end
  local level = self.aim.level
  if level and level.step and not settle then
    SetTimer("Light.BrightnessRamp", math.max(0, level.startTime + level.durationMs - C4:GetTime()), function()
      self:_brightnessRampFinished(level.targetLevel)
    end, false)
  end
end

--- Take one step: one command, so the light moves its level and color as one transition, over
--- the longer of the two rates. On a device that re-times, what the step does not set runs on to its
--- target over the step's time, each ramp it primes has its own timer, and the proxy hears the level first.
--- @private
--- @return integer rate The step's ramp, 0 for one taken at once.
function Scenes:_applySceneStep(step)
  if not step.levelEnabled and not step.colorEnabled then
    return 0
  end
  local retimes = self:_retimes()
  local cmd = {}
  local rate = self:_rate(math.max(step.brightnessRate or 0, step.colorRate or 0))
  local startTime = C4:GetTime()
  -- A level of 0 is off: the color is for the next on, and goes with no color so the light turns off.
  local turningOff = step.levelEnabled and step.level == 0
  local replaced = false
  local told, aim = self.told, self.aim
  -- A color ramp, or the color a level ramp carries, that the proxy has been told is on its way.
  local colorInFlight = aim.color or (aim.level and aim.level.mergedColor)
  local goingOn = false
  local primed = false
  local dims = self:_dims()
  -- The level the step leaves the light at: an On/Off-only light is on or off.
  local level = nil
  if step.levelEnabled and step.level ~= nil then
    level = dims and step.level or (step.level > 0 and 100 or 0)
    cmd.on = step.level > 0
    if step.level > 0 and dims then
      cmd.level = self:_toDevice(step.level)
    end
    -- A step that drives the level clears the brightness preset id; a color alone leaves it.
    told.levelPreset = nil
    -- A step that sets the level replaces a level ramp in flight, from the level it has got to.
    -- One that sets a color alone leaves it running, as the bulb does.
    replaced = aim.level ~= nil
    local startAt = self:_leaveBrightnessRamp()
    goingOn = level > 0 and told.level == 0
    -- A ramp only when the level moves, as it does for a light outside the range. An On/Off-only light
    -- has no level to ramp through: it switches at once, whatever the rate.
    if dims and rate > 0 and (level ~= told.level or startAt) then
      primed = true
      aim.level = {
        startTime = startTime,
        startLevel = told.level,
        startAt = startAt,
        targetLevel = level,
        from = self:_endBrightness(told.level, startAt),
        to = self:_toDevice(level),
        durationMs = rate,
        step = step,
      }
    end
  end
  -- A step that turns the light on over its time sends a pre-on, which lights it in the step's color at once.
  local preOnLevel = goingOn and rate > 0 and self:_preOnLevel()
  local color = nil
  if step.colorEnabled and step.colorX and step.colorY then
    local x, y, mode = self:_taken(step.colorX, step.colorY, step.colorMode or FULL)
    color = { x = x, y = y, mode = mode }
  end
  local ownColor = color
  -- A step that sets a level alone takes the color a level command would: Dim-To-Warm's for the
  -- level, or the Color On Mode's when it turns the light on.
  if not color and (level or 0) > 0 then
    if self:_colorOnModeKind() == Settings.COLOR_ON_MODE_FADE then
      color = self:_fadeColor(step.level)
    elseif goingOn then
      color = self:_onColor(step.level)
    end
  end
  -- A color the light cannot take is none: the step then sets none.
  local wire = color and self:_wireColor(color.x, color.y, color.mode or FULL)
  if not wire then
    color, ownColor = nil, nil
  end
  -- A color alone, for a light that is off or fading to off, is the color it next comes on in, as a
  -- color command's is: the step does not turn it on.
  if ownColor and level == nil and not self:_isLogicallyOn() then
    told.colorPreset = nil
    self:_rampToColor(color.x, color.y, color.mode, rate)
    return rate
  end
  -- What the step tells of its color once it is sent: a ramp, or a color at once.
  local colorRamp, colorAtOnce = nil, nil
  if color and not turningOff then
    -- The step's color replaces the on color a level ramp carries and a color ramp in flight, from
    -- where each has got to; the step's own ramp then holds the light's color reports back.
    self:_leaveMergedColor()
    self:_leaveColorRamp()
    -- A color of the step's own is the light's for a level ramp in flight, the step's or one it
    -- leaves running: a stop keeps it, and the on's color asked for after it is news.
    if ownColor and aim.level then
      aim.level.colorSet, aim.level.onColor = true, nil
    end
    local mode = color.mode or FULL
    cmd.color = wire
    if level == nil then
      cmd.on = self:_colorLit() -- a color alone says whether the light is lit, as a color command's does
    end
    told.colorPreset = nil
    local colorChanged = math.abs(color.x - told.x) > 1e-4 or math.abs(color.y - told.y) > 1e-4 or mode ~= told.mode
    if rate > 0 and colorChanged and not preOnLevel then
      aim.color = {
        startTime = startTime,
        startX = told.x,
        startY = told.y,
        startMode = told.mode,
        targetX = color.x,
        targetY = color.y,
        targetMode = mode,
        durationMs = rate,
        step = step,
      }
      colorRamp = function()
        self:_notifyColorChanging(color.x, color.y, mode, rate)
        if retimes then
          SetTimer("Light.ColorRamp", rate, function()
            self:_colorRampFinished(color.x, color.y, mode)
          end, false)
        end
      end
    elseif (colorChanged and (preOnLevel or retimes)) or colorInFlight then
      -- At once for a pre-on, which lights it in the color, or to end a ramp the proxy was told of: no
      -- report need differ from where that ramp got to. A device that re-times shows it as it takes it.
      colorAtOnce = function()
        self:_notifyColorChanged(color.x, color.y, mode)
      end
    end
  else
    cmd.color = nil
  end
  if next(cmd) == nil then
    return rate
  end
  -- A rate of 0 goes too, so the device does not ramp at its default.
  cmd.ms = rate
  cmd.scene = true
  local preOn = preOnLevel and { preOn = true, on = true, level = preOnLevel, color = cmd.color, ms = 0, scene = true }
    or nil
  local now, ramp = C4:GetTime(), primed and aim.level or nil
  self:_command(cmd, { target = level, brightness = cmd.level }, preOn)
  -- The step is told once sent, as a command is, so one whose send raised told nothing. The level is
  -- told after the color, so a step from off comes up in that color, but on a device that re-times.
  if retimes then
    self:_retimedStepSent(ramp, colorRamp, rate, not cmd.color, level == nil, now)
  else
    local tellColor = colorRamp or colorAtOnce
    if tellColor then
      tellColor()
    end
    if primed then
      self:_notifyBrightnessChanging(level, rate)
    end
  end
  -- A step taken at once is where the light is: the next step or command starts from it. At the
  -- level a ramp it replaced has got to, at any rate, it is still that ramp's end for the proxy.
  if level ~= nil and not aim.level and (level ~= told.level or replaced) then
    self:_notifyBrightnessChanged(level)
  end
  if retimes and colorAtOnce then
    colorAtOnce()
  end
  return rate
end

--- A step sent to a device that re-times: the level ramp it primed is told first, each ramp ends by its
--- own timer, and an aspect the step does not set runs on over the step's time.
--- @private
--- @param ramp table|nil The level ramp the step primed.
--- @param colorRamp function|nil Tells the color ramp the step primed, and times it.
--- @param rate integer
--- @param keepsColor boolean The step sent no color.
--- @param keepsLevel boolean The step set no level.
--- @param now number When the step went out.
function Scenes:_retimedStepSent(ramp, colorRamp, rate, keepsColor, keepsLevel, now)
  if ramp then
    self:_notifyBrightnessChanging(ramp.targetLevel, rate)
    SetTimer("Light.BrightnessRamp", rate, function()
      self:_brightnessRampFinished(ramp.targetLevel)
    end, false)
  end
  if colorRamp then
    colorRamp()
  end
  if keepsColor then
    self:_retimeColor(rate, nil, now)
  end
  if keepsLevel then
    self:_retimeBrightness(rate, nil, now)
  end
end

--- Run a scene's steps from where it has got to, until one has to wait on a delay or a ramp.
--- @private
--- @param sceneId integer
--- @param generation integer|nil The run this call belongs to; nil starts one.
function Scenes:_runScene(sceneId, generation)
  local scenes = self.scenes
  if generation ~= nil and generation ~= scenes.generation then
    return
  end
  local gen = generation or scenes.generation
  local scene = getScenes()[tostring(sceneId)]
  if not scene then
    log:warn("Scene %s not found", sceneId)
    return
  end
  local name = timerName(sceneId)
  CancelTimer(name)

  -- Steps run here without waiting: a flash scene whose every step has no delay or rate ends
  -- after one pass, where it would otherwise loop here forever.
  local ran = 0
  while true do
    if gen ~= scenes.generation then
      return
    end
    local idx = (scenes.progress[sceneId] or 0) + 1
    if idx > #scene.elements then
      if scene.flash and ran < #scene.elements then
        idx = 1
      else
        scenes.progress[sceneId] = 0
        return
      end
    end
    local step = scene.elements[idx]
    local wait = math.max(0, step.delay or 0)
    scenes.progress[sceneId] = idx

    -- When the step's ramp elapses, finish the ramps it primed so their CHANGED notifies fire before
    -- the next step is applied. One a command has replaced, or the step left running, is not its to finish.
    local function advanceAfter(rampMs)
      local level = self.aim.level and self.aim.level.step == step and self.aim.level
      local color = self.aim.color and self.aim.color.step == step and self.aim.color
      SetTimer(name, rampMs, function()
        if level and self.aim.level == level then
          self:_brightnessRampFinished(level.targetLevel)
        end
        if color and self.aim.color == color then
          self:_colorRampFinished(color.targetX, color.targetY, color.targetMode)
        end
        self:_runScene(sceneId, gen)
      end)
    end

    if wait > 0 then
      SetTimer(name, wait, function()
        if gen ~= scenes.generation then
          return
        end
        local rampMs = self:_guard(self._applySceneStep, step)
        if rampMs > 0 then
          advanceAfter(rampMs)
        else
          self:_runScene(sceneId, gen)
        end
      end)
      return
    end

    local rampMs = self:_guard(self._applySceneStep, step)
    if rampMs > 0 then
      advanceAfter(rampMs)
      return
    end
    -- otherwise loop synchronously to the next element
    ran = ran + 1
  end
end

--- PUSH_SCENE: store a scene's steps, in the shape every release stored them.
--- @private
function Scenes:_pushScene(tParams)
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  local elements = Select(tParams, "ELEMENTS")
  local scenes = getScenes()
  scenes[tostring(sceneId)] = {
    elements = parseSceneElements(elements),
    flash = toboolean(Select(tParams, "FLASH")),
    ignoreRamp = toboolean(Select(tParams, "IGNORE_RAMP")),
    fromGroup = toboolean(Select(tParams, "FROM_GROUP")),
    state = 0,
  }
  saveScenes(scenes)
  self.scenes.progress[sceneId] = nil
  log:debug("Stored scene %s with %d element(s)", sceneId, #scenes[tostring(sceneId)].elements)
end

--- @private
function Scenes:_removeScene(tParams)
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  CancelTimer(timerName(sceneId))
  local scenes = getScenes()
  scenes[tostring(sceneId)] = nil
  saveScenes(scenes)
  self.scenes.progress[sceneId] = nil
end

--- @private
function Scenes:_clearAllScenes()
  self:_stopAllScenes()
  saveScenes({})
  self.scenes.progress = {}
end

--- @private
function Scenes:_activateScene(tParams)
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  if sceneId == nil then
    return
  end
  self:_stopAllScenes()
  if not getScenes()[tostring(sceneId)] then
    log:warn("ACTIVATE_SCENE: unknown scene id %s", sceneId)
    return
  end
  self.scenes.progress[sceneId] = 0
  self:_runScene(sceneId)
end

--- DEACTIVATE_SCENE marks a scene off in the agent's own bookkeeping: the light only stops its steps.
--- @private
function Scenes:_deactivateScene()
  self:_stopAllScenes()
end

--- RAMP_SCENE_UP and RAMP_SCENE_DOWN, unless the scene ignores ramps.
--- @private
--- @param up boolean
function Scenes:_rampScene(tParams, up)
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local rate = tointeger(Select(tParams, "RATE")) or 0
  local scene = sceneId and getScenes()[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  self:_stopAllScenes()
  if self:_dims() then
    self:_rampToBrightness(up and self:_onBrightness() or 0, rate)
  elseif up then
    self:_lightOn()
  else
    self:_lightOff()
  end
end

--- STOP_SCENE_RAMP, and its published name STOP_RAMP_SCENE.
--- @private
function Scenes:_stopSceneRamp(tParams)
  local sceneId = tointeger(Select(tParams, "SCENE_ID"))
  local scene = sceneId and getScenes()[tostring(sceneId)]
  if scene and scene.ignoreRamp then
    return
  end
  -- The stops halt the light where its ramp has got to, which they read from the state stopAllScenes drops.
  self:_brightnessRampStopped()
  self:_colorRampStopped()
  self:_stopAllScenes()
end

--- TOGGLE_SCENE: the light keeps no scene's active state, so it activates; the agent tracks the toggle.
--- @private
function Scenes:_toggleScene(tParams)
  self:_activateScene(tParams)
end

return Scenes
