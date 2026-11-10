--- What the proxy and the button links are told: brightness and color CHANGED and CHANGING, the
--- Previous On keep, the LEDs, ONLINE_CHANGED and the capabilities. Every send is a literal
--- SendToProxy( call, since a suite may replace the global after it loads the driver.

local log = require("lib.logging")
local persist = require("lib.persist")
local Caps = require("lib.light.caps")
local Color = require("lib.light.color")
local Settings = require("lib.light.settings")

require("lib.utils")

--- @class LightNotify
local Notify = {}

--- The color mode the proxy is told: an adapter's own modes above 1 are kinds of full color.
--- @param mode integer
--- @return integer
local function toldMode(mode)
  return mode > Color.CCT and Color.FULL or mode
end

--- The light has gone from on to off.
--- @private
function Notify:_endOnCycle()
  -- A color still on its way is the one the bulb is in when it is next seen, so the proxy hears it
  -- ahead of the level: its Previous On, like the snapshot here, is the last color it was told.
  local ramp = self.aim.color
  if ramp then
    ramp.told = true
    self:_notifyColorChanged(ramp.targetX, ramp.targetY, ramp.targetMode)
  end
  -- The color a Previous color on mode restores at the next on, as the proxy tracks it (Light V2 _7.4).
  persist:set(Settings.P_PREVIOUS_COLOR, { x = self.told.x, y = self.told.y, mode = self.told.mode })
  -- Whatever drove this on cycle's color does not apply once the light is off.
  self.told.colorPreset = nil
end

--- Tell each button link's LED whether the light is on. Bottom's lights while it is off.
--- @private
--- @param on boolean
function Notify:_matchLedState(on)
  if on == self.told.leds then
    return
  end
  self.told.leds = on
  local links = self.opts.links
  if not links then
    return
  end
  SendToProxy(links.top, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
  SendToProxy(links.bottom, "MATCH_LED_STATE", { STATE = not on }, "NOTIFY", true)
  SendToProxy(links.toggle, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
end

--- Tell the proxy the level the light is at.
--- @private
--- @param level integer
function Notify:_notifyBrightnessChanged(level)
  local told = self.told
  -- At an off the proxy writes Previous On with the last level it was told, here the pre-on's 1: it is told the
  -- level to keep first, where the ramp had the light or, before it was lit, Previous On's own.
  local keep = level == 0 and self.aim.preOnTold and (told.level > 0 and told.level or self:_previousOnLevel())
  self.aim.preOnTold = false
  if keep and keep >= 1 then
    log:debug("LIGHT_BRIGHTNESS_CHANGING: %s to 0, rate=0", keep)
    SendToProxy(self.opts.proxy, "LIGHT_BRIGHTNESS_CHANGING", {
      LIGHT_BRIGHTNESS_CURRENT = keep,
      LIGHT_BRIGHTNESS_TARGET = 0,
      RATE = 0,
    }, "NOTIFY", true)
  end
  if level == 0 and told.level > 0 then
    self:_endOnCycle()
  end
  told.level = level
  log:debug("LIGHT_BRIGHTNESS_CHANGED: %s", level)
  -- The preset id that set this level, so the proxy knows the preset still owns it (Light V2 _10.2).
  SendToProxy(self.opts.proxy, "LIGHT_BRIGHTNESS_CHANGED", {
    LIGHT_BRIGHTNESS_CURRENT = level,
    LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = told.levelPreset,
  }, "NOTIFY")
  self:_matchLedState(level > 0)
end

--- Tell the proxy the light is on its way to a level.
--- @private
--- @param target integer
--- @param rate integer
--- @param current integer|nil Where it starts, the level told by default.
function Notify:_notifyBrightnessChanging(target, rate, current)
  current = current or self.told.level
  self.aim.preOnTold = target > 0 and current < 1
  -- The proxy takes the light's state from CURRENT: one on its way up from off is lit by its pre-on.
  if target > 0 then
    current = math.max(1, current)
  end
  log:debug("LIGHT_BRIGHTNESS_CHANGING: %s to %s, rate=%s", current, target, rate)
  SendToProxy(self.opts.proxy, "LIGHT_BRIGHTNESS_CHANGING", {
    LIGHT_BRIGHTNESS_CURRENT = current,
    LIGHT_BRIGHTNESS_TARGET = target,
    RATE = rate,
    LIGHT_BRIGHTNESS_TARGET_PRESET_ID = self.told.levelPreset,
  }, "NOTIFY", true)
  -- A light on its way up is on from the start of its ramp, as one fading to off is on until its end.
  if target > 0 then
    self:_matchLedState(true)
  end
end

--- Tell the proxy the color the light is in.
--- @private
--- @param x number
--- @param y number
--- @param mode integer
function Notify:_notifyColorChanged(x, y, mode)
  local told = self.told
  told.x, told.y, told.mode = x, y, mode
  log:debug("LIGHT_COLOR_CHANGED: x=%.4f y=%.4f mode=%s", x, y, mode)
  SendToProxy(self.opts.proxy, "LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = x,
    LIGHT_COLOR_CURRENT_Y = y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = toldMode(mode),
    LIGHT_COLOR_CURRENT_PRESET_ID = told.colorPreset,
  }, "NOTIFY")
end

--- Tell the proxy the light is on its way to a color.
--- @private
--- @param targetX number
--- @param targetY number
--- @param mode integer
--- @param rate integer
function Notify:_notifyColorChanging(targetX, targetY, mode, rate)
  local told = self.told
  log:debug("LIGHT_COLOR_CHANGING: x=%.4f y=%.4f mode=%s rate=%s", targetX, targetY, mode, rate)
  SendToProxy(self.opts.proxy, "LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_CURRENT_X = told.x,
    LIGHT_COLOR_CURRENT_Y = told.y,
    LIGHT_COLOR_CURRENT_COLOR_MODE = toldMode(told.mode),
    LIGHT_COLOR_TARGET_X = targetX,
    LIGHT_COLOR_TARGET_Y = targetY,
    LIGHT_COLOR_TARGET_COLOR_MODE = toldMode(mode),
    -- Light V2 _10.7 names the rate LIGHT_COLOR_TARGET_COLOR_RATE; older pages LIGHT_COLOR_TARGET_RATE.
    LIGHT_COLOR_TARGET_COLOR_RATE = rate,
    LIGHT_COLOR_TARGET_RATE = rate,
    LIGHT_COLOR_TARGET_PRESET_ID = told.colorPreset,
  }, "NOTIFY", true)
end

--- Tell the proxy whether the light can be reached.
--- @private
--- @param online boolean
function Notify:_notifyOnline(online)
  SendToProxy(self.opts.proxy, "ONLINE_CHANGED", { STATE = online }, "NOTIFY")
end

--- Tell the proxy the light's capabilities, at a connection's first report, then re-read its setup
--- and tell it the buttons and the preset level.
--- @private
--- @param decl table The declaration in force.
function Notify:_notifyCapabilities(decl)
  log:info(
    "Light caps: brightness=%s color=%s cct=%s fade=%s policy=%s",
    tostring(decl.dims),
    tostring(decl.color),
    decl.cct and string.format("[%d, %d]", decl.cct.min, decl.cct.max) or "none",
    decl.fade.by,
    decl.reports.policy
  )
  local caps = Caps.dynamic(decl)
  SendToProxy(self.opts.proxy, "DYNAMIC_CAPABILITIES_CHANGED", caps, "NOTIFY", true)
  -- A new light's setup lists no colors until the proxy hears it has color.
  self:_readSetup()

  -- The three buttons, a string per the NUMBER_BUTTONS notify, then each one's name and colors.
  SendToProxy(self.opts.proxy, "NUMBER_BUTTONS", "3", "NOTIFY")
  local ids = Settings.BUTTONS
  local buttonNames = {
    [ids.TOP] = "Top",
    [ids.BOTTOM] = "Bottom",
    [ids.TOGGLE] = "Toggle",
  }
  for buttonId, name in pairs(buttonNames) do
    local colors = persist:get(Settings.P_BUTTON_COLORS, {})
    local saved = colors[tostring(buttonId)] or {}
    SendToProxy(self.opts.proxy, "BUTTON_INFO", {
      BUTTON_ID = buttonId,
      NAME = name,
      ON_COLOR = saved.on_color or "",
      OFF_COLOR = saved.off_color or "",
    }, "NOTIFY")
  end

  -- The preset level, so the proxy is seeded after a reload.
  local presetLevel = tointeger(persist:get(Settings.P_PRESET_LEVEL))
  if presetLevel and presetLevel > 0 then
    SendToProxy(self.opts.proxy, "PRESET_LEVEL", tostring(presetLevel), "NOTIFY")
  end
end

return Notify
