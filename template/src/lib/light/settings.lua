--- The proxy's settings a light keeps: presets, on modes, rates, the Min and Max On Level, the
--- Dim-To-Warm line and the button colors, and the read of the proxy's setup that rebuilds them.
--- Every setting is read through lib.persist at each use, never kept on the instance: a test may
--- delete a key under a live light and expect the default next time.

local log = require("lib.logging")
local persist = require("lib.persist")
local Color = require("lib.light.color")

require("lib.utils")
require("drivers-common-public.global.lib")

--- @class LightSettings
local Settings = {}

-- The persisted keys, verbatim, so an existing install keeps its presets, scenes and rates.
Settings.P_PRESET_LEVEL = "preset_level"
Settings.P_CLICK_RATE_UP = "click_rate_up"
Settings.P_CLICK_RATE_DOWN = "click_rate_down"
Settings.P_HOLD_RATE_UP = "hold_rate_up"
Settings.P_HOLD_RATE_DOWN = "hold_rate_down"
Settings.P_RATE_DEFAULT = "brightness_rate_default"
Settings.P_COLOR_RATE_DEFAULT = "color_rate_default"
Settings.P_ON_MODE = "brightness_on_mode"
Settings.P_BUTTON_COLORS = "button_colors"
Settings.P_SCENES = "scenes"
Settings.P_BRIGHTNESS_PRESETS = "brightness_presets"
Settings.P_COLOR_PRESETS = "color_presets"
Settings.P_COLOR_ON_MODE = "color_on_mode"
Settings.P_PREVIOUS_COLOR = "previous_color"
Settings.P_BRIGHTNESS_ON_MODE_PRESET = "brightness_on_mode_preset"
Settings.P_MAX_ON_LEVEL = "max_on_level"
Settings.P_MIN_ON_LEVEL = "min_on_level"

-- Color on-mode kinds, as the presets UPDATE_COLOR_ON_MODE names tell them apart.
Settings.COLOR_ON_MODE_NONE = 0
Settings.COLOR_ON_MODE_FADE = 1 -- Dim-To-Warm
Settings.COLOR_ON_MODE_PREVIOUS = 2
Settings.COLOR_ON_MODE_PRESET = 3

-- The proxy's three buttons, and the actions BUTTON_ACTION and the links report.
Settings.BUTTONS = { TOP = 0, BOTTOM = 1, TOGGLE = 2 }
Settings.ACTIONS = { RELEASE_HOLD = 0, PRESS = 1, RELEASE_CLICK = 2 }

-- The proxy's own Previous On color and level presets: id 10 among its device presets (origin 1).
Settings.PRESET_ORIGIN_DEVICE = 1
Settings.PREVIOUS_ON_PRESET_ID = 10

local DEFAULT_PRESET_LEVEL = 100
local DEFAULT_CLICK_RATE = 500
local DEFAULT_HOLD_RATE = 3000
local DEFAULT_RATE = 500

--- The Min and Max On Level, percent of the device's brightness.
--- @private
--- @return number lo, number hi
function Settings:_onRange()
  local lo = math.max(1, tonumber(persist:get(Settings.P_MIN_ON_LEVEL, 1)) or 1)
  return lo, math.max(lo, tonumber(persist:get(Settings.P_MAX_ON_LEVEL, 100)) or 100)
end

--- The preset level, as a usable on level: anything under 1 is the default, so an On never turns
--- the light off.
--- @private
--- @return integer level
function Settings:_presetLevel()
  local v = tointeger(persist:get(Settings.P_PRESET_LEVEL))
  if not v or v < 1 then
    return DEFAULT_PRESET_LEVEL
  end
  return math.min(v, 100)
end

--- The level an On turns the light on at: the brightness on mode's, else the preset level.
--- @private
--- @return integer level
function Settings:_onBrightness()
  local onMode = persist:get(Settings.P_ON_MODE)
  local level = onMode and tointeger(onMode.level)
  if level and level >= 1 then
    return math.min(level, 100)
  end
  return self:_presetLevel()
end

--- @private
function Settings:_defaultRate()
  return persist:get(Settings.P_RATE_DEFAULT, DEFAULT_RATE)
end

--- The color rate default: color_rate_behavior 1 gives one rate for brightness and color.
--- @private
function Settings:_defaultColorRate()
  return persist:get(Settings.P_COLOR_RATE_DEFAULT, DEFAULT_RATE)
end

--- @private
function Settings:_clickRateUp()
  return persist:get(Settings.P_CLICK_RATE_UP, DEFAULT_CLICK_RATE)
end

--- @private
function Settings:_clickRateDown()
  return persist:get(Settings.P_CLICK_RATE_DOWN, DEFAULT_CLICK_RATE)
end

--- @private
function Settings:_holdRateUp()
  return persist:get(Settings.P_HOLD_RATE_UP, DEFAULT_HOLD_RATE)
end

--- @private
function Settings:_holdRateDown()
  return persist:get(Settings.P_HOLD_RATE_DOWN, DEFAULT_HOLD_RATE)
end

--- A button's saved on and off colors, or blue and black.
--- @private
--- @param buttonId integer
--- @return string onColor, string offColor
function Settings:_buttonColors(buttonId)
  local colors = persist:get(Settings.P_BUTTON_COLORS, {})
  local key = tostring(buttonId)
  if colors[key] then
    return colors[key].on_color or "0000ff", colors[key].off_color or "000000"
  end
  return "0000ff", "000000"
end

--- @private
--- @param buttonId integer
--- @param onColor string|nil
--- @param offColor string|nil
function Settings:_setButtonColors(buttonId, onColor, offColor)
  local colors = persist:get(Settings.P_BUTTON_COLORS, {})
  local key = tostring(buttonId)
  local existing = colors[key] or {}
  colors[key] = {
    on_color = onColor or existing.on_color or "0000ff",
    off_color = offColor or existing.off_color or "000000",
  }
  persist:set(Settings.P_BUTTON_COLORS, colors)
end

--- A color in the form the light takes it: the adapter's takeColor, else Color.taken.
--- @private
--- @param x number
--- @param y number
--- @param mode integer
--- @param ctx table|nil For takeColor: `asked`, the color as the proxy asked it; `ends`, the
---   Dim-To-Warm presets a point between them comes from; `stop`, a stop's estimate.
--- @return number x, number y, integer mode
function Settings:_taken(x, y, mode, ctx)
  local adapter = self.adapter
  if adapter.takeColor then
    local color = adapter:takeColor({ x = x, y = y, mode = mode }, ctx or {})
    return color.x, color.y, color.mode
  end
  return Color.taken(x, y, mode, self:_hasColor(), self:_hasCct())
end

--- The Dim-To-Warm color for a level (Light V2 _7.2): the Dim color at 1 % to the On color at 100 %.
--- @private
--- @param brightness number A Control4 level.
--- @return table|nil color { x, y, mode }, or nil without both presets.
function Settings:_fadeColor(brightness)
  local mode = persist:get(Settings.P_COLOR_ON_MODE)
  if not mode then
    return nil
  end
  local onPreset = mode.onPreset
  local dimPreset = mode.fadePreset
  if not onPreset or not dimPreset then
    return nil
  end
  if onPreset.x == nil or onPreset.y == nil or dimPreset.x == nil or dimPreset.y == nil then
    return nil
  end
  local b = math.max(0, math.min(100, brightness)) * 0.01
  local x, y, colorMode = self:_taken(
    dimPreset.x + (onPreset.x - dimPreset.x) * b,
    dimPreset.y + (onPreset.y - dimPreset.y) * b,
    onPreset.mode or Color.FULL,
    { ends = { on = onPreset, dim = dimPreset } }
  )
  return { x = x, y = y, mode = colorMode }
end

--- Which color on mode is in force: one of the COLOR_ON_MODE_* kinds.
--- @private
--- @return integer kind
function Settings:_colorOnModeKind()
  if not (self:_hasColor() or self:_hasCct()) then
    return Settings.COLOR_ON_MODE_NONE
  end
  local mode = persist:get(Settings.P_COLOR_ON_MODE)
  if not mode or not mode.fadePreset then
    return Settings.COLOR_ON_MODE_NONE
  end
  local fadeOrigin = mode.fadePreset.origin
  if fadeOrigin and fadeOrigin > 0 then
    -- A fade preset with an origin is Dim-To-Warm (origin 1 the device's, 2 an agent's).
    return Settings.COLOR_ON_MODE_FADE
  end
  local onPreset = mode.onPreset
  if
    onPreset
    and onPreset.id == Settings.PREVIOUS_ON_PRESET_ID
    and onPreset.origin == Settings.PRESET_ORIGIN_DEVICE
  then
    return Settings.COLOR_ON_MODE_PREVIOUS
  end
  if onPreset and onPreset.x then
    return Settings.COLOR_ON_MODE_PRESET
  end
  return Settings.COLOR_ON_MODE_NONE
end

--- The color a light turning on from off takes, by the color on mode.
--- @private
--- @param brightnessLevel number The Control4 level it turns on at.
--- @return table|nil color { x, y, mode, preset }
function Settings:_onColor(brightnessLevel)
  if not (self:_hasColor() or self:_hasCct()) then
    return nil
  end
  local kind = self:_colorOnModeKind()
  if kind == Settings.COLOR_ON_MODE_FADE then
    return self:_fadeColor(brightnessLevel)
  end
  local mode = persist:get(Settings.P_COLOR_ON_MODE)
  local onPreset = mode and mode.onPreset
  -- The device preset the color is, which the proxy names it by.
  local preset = onPreset and onPreset.origin == Settings.PRESET_ORIGIN_DEVICE and onPreset.id or nil
  if kind == Settings.COLOR_ON_MODE_PREVIOUS then
    local prev = persist:get(Settings.P_PREVIOUS_COLOR)
    if prev and prev.x and prev.y then
      local x, y, colorMode = prev.x, prev.y, prev.mode or Color.FULL
      -- An adapter's own form of it, as the proxy's follow-up SET_COLOR_TARGET is taken, so it dedupes.
      if self.adapter.takeColor then
        x, y, colorMode = self:_taken(x, y, colorMode)
      end
      return { x = x, y = y, mode = colorMode, preset = preset }
    end
  end
  if kind == Settings.COLOR_ON_MODE_PRESET and onPreset and onPreset.x and onPreset.y then
    local x, y, colorMode = self:_taken(onPreset.x, onPreset.y, onPreset.mode or Color.FULL)
    return { x = x, y = y, mode = colorMode, preset = preset }
  end
  return nil
end

--- The level the proxy's Previous On preset holds, as it last sent it.
--- @private
--- @return number|nil level
function Settings:_previousOnLevel()
  local preset = persist:get(Settings.P_BRIGHTNESS_PRESETS, {})[tostring(Settings.PREVIOUS_ON_PRESET_ID)]
  return preset and tonumber(preset.level)
end

--- The attributes of the element in `list` with this id, and this origin where one is given.
local function setupPreset(list, id, origin)
  list = list or {}
  for _, element in ipairs(IsList(list) and list or { list }) do
    local attr = element._attr or {}
    if tointeger(attr.id) == id and (origin == nil or tointeger(attr.origin) == origin) then
      return attr
    end
  end
end

--- Read the proxy's setup. The proxy tells its on modes and default rates only when they change,
--- with no push at start, so a light whose own were never changed has never heard them.
--- @private
function Settings:_readSetup()
  local ok, setup = pcall(function()
    return Select(ParseXml(SendUIRequest(C4:GetProxyDevices(), "GET_SETUP", {})), "setup")
  end)
  if not ok or type(setup) ~= "table" then
    log:warn("The proxy's setup could not be read: %s", ok and "no setup in its answer" or setup)
    return
  end

  -- A preset id means one preset only with its origin: the device's own and the Color Agent's both count from 1.
  local colors = Select(setup, "colors", "color")
  local onId, onOrigin =
    tointeger(setup.light_color_on_mode_preset_id), tointeger(setup.light_color_on_mode_preset_origin)
  local fadeId = tointeger(setup.light_color_on_mode_fade_preset_id)
  local fadeOrigin = tointeger(setup.light_color_on_mode_fade_preset_origin)
  local on = onId and onOrigin and setupPreset(colors, onId, onOrigin)
  local fade = fadeId and (fadeOrigin or 0) > 0 and setupPreset(colors, fadeId, fadeOrigin) or nil
  if on and fadeOrigin and (fadeOrigin == 0 or fade) then
    fade = fade or {}
    self:_updateColorOnMode({
      COLOR_PRESET_ID = onId,
      COLOR_PRESET_ORIGIN = onOrigin,
      COLOR_PRESET_COLOR_X = on.color_x,
      COLOR_PRESET_COLOR_Y = on.color_y,
      COLOR_PRESET_COLOR_MODE = on.color_mode,
      COLOR_FADE_PRESET_ID = fadeId,
      COLOR_FADE_PRESET_ORIGIN = fadeOrigin,
      COLOR_FADE_PRESET_COLOR_X = fade.color_x,
      COLOR_FADE_PRESET_COLOR_Y = fade.color_y,
      COLOR_FADE_PRESET_COLOR_MODE = fade.color_mode,
    })
  end

  local levels = Select(setup, "brightnesses", "level") or {}
  local levelId = tointeger(setup.light_brightness_on_mode_preset_id)
  local level = levelId and setupPreset(levels, levelId)
  if level and tonumber(level.level) then
    self:_updateBrightnessOnMode({ BRIGHTNESS_PRESET_ID = levelId, BRIGHTNESS_PRESET_LEVEL = level.level })
  end
  -- A preset's level is sent only when it changes, so the setup holds Previous On's, which an unlit ramp's end keeps.
  for _, element in ipairs(IsList(levels) and levels or { levels }) do
    local attr = element._attr or {}
    if tointeger(attr.id) and tonumber(attr.level) then
      self:_updateBrightnessPreset({ ID = attr.id, NAME = attr.name, LEVEL = attr.level })
    end
  end

  local rate = tointeger(setup.light_brightness_rate_default)
  if rate then
    self:_updateBrightnessRateDefault({ RATE = rate })
  end
  rate = tointeger(setup.light_color_rate_default)
  if rate then
    self:_updateColorRateDefault({ RATE = rate })
  end
end

--- SET_PRESET_LEVEL. The notify takes the level as a plain string: a table makes the proxy revert it to 0.
--- @private
function Settings:_setPresetLevel(tParams)
  local level = tointeger(Select(tParams, "LEVEL")) or DEFAULT_PRESET_LEVEL
  persist:set(Settings.P_PRESET_LEVEL, level)
  SendToProxy(self.opts.proxy, "PRESET_LEVEL", tostring(level), "NOTIFY")
end

--- UPDATE_BRIGHTNESS_ON_MODE: the on level, and the preset whose edits it follows.
--- @private
function Settings:_updateBrightnessOnMode(tParams)
  local presetId = tointeger(Select(tParams, "BRIGHTNESS_PRESET_ID"))
  local presetLevel = tonumber(Select(tParams, "BRIGHTNESS_PRESET_LEVEL")) or DEFAULT_PRESET_LEVEL
  persist:set(Settings.P_ON_MODE, { id = presetId, level = presetLevel })
  persist:set(Settings.P_BRIGHTNESS_ON_MODE_PRESET, presetId)
end

--- SET_BRIGHTNESS_ON_MODE: the preset an On goes to, at its level as stored.
--- @private
function Settings:_setBrightnessOnMode(tParams)
  local presetId = tointeger(Select(tParams, "PRESET_ID"))
  if presetId == nil then
    return
  end
  persist:set(Settings.P_BRIGHTNESS_ON_MODE_PRESET, presetId)
  local presets = persist:get(Settings.P_BRIGHTNESS_PRESETS, {})
  local preset = presets[tostring(presetId)]
  if preset and preset.level then
    persist:set(Settings.P_ON_MODE, { id = presetId, level = preset.level })
  end
end

--- UPDATE_BRIGHTNESS_PRESET. The on level follows an edit of the preset the on mode names.
--- @private
function Settings:_updateBrightnessPreset(tParams)
  local command = Select(tParams, "COMMAND")
  local presetId = tointeger(Select(tParams, "ID"))
  local level = tonumber(Select(tParams, "LEVEL"))
  local name = Select(tParams, "NAME")
  if presetId == nil then
    return
  end
  local presets = persist:get(Settings.P_BRIGHTNESS_PRESETS, {})
  local key = tostring(presetId)
  if command == "REMOVED" then
    presets[key] = nil
  else
    presets[key] = { id = presetId, name = name, level = level }
  end
  persist:set(Settings.P_BRIGHTNESS_PRESETS, presets)
  local activeId = tointeger(persist:get(Settings.P_BRIGHTNESS_ON_MODE_PRESET))
  if activeId ~= nil and activeId == presetId then
    if level == nil then
      persist:delete(Settings.P_ON_MODE)
    else
      persist:set(Settings.P_ON_MODE, { id = presetId, level = level })
    end
  end
end

--- UPDATE_BRIGHTNESS_RATE_DEFAULT. color_rate_behavior 1 shares one rate, so both keys take it.
--- @private
function Settings:_updateBrightnessRateDefault(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(Settings.P_RATE_DEFAULT, rate)
  persist:set(Settings.P_COLOR_RATE_DEFAULT, rate)
end

--- @private
function Settings:_updateColorRateDefault(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_RATE
  persist:set(Settings.P_COLOR_RATE_DEFAULT, rate)
  persist:set(Settings.P_RATE_DEFAULT, rate)
end

--- UPDATE_COLOR_PRESET, kept by id for a command the proxy does not start (a link, a scene).
--- @private
function Settings:_updateColorPreset(tParams)
  local command = Select(tParams, "COMMAND")
  local presetId = tointeger(Select(tParams, "ID"))
  if presetId == nil then
    return
  end
  local presets = persist:get(Settings.P_COLOR_PRESETS, {})
  local key = tostring(presetId)
  if command == "REMOVED" then
    presets[key] = nil
  else
    presets[key] = {
      id = presetId,
      name = Select(tParams, "NAME"),
      x = tonumber(Select(tParams, "COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_MODE")),
    }
  end
  persist:set(Settings.P_COLOR_PRESETS, presets)
  -- The on and dim colors follow an edit of the device preset the on mode names.
  local onMode = persist:get(Settings.P_COLOR_ON_MODE, {})
  if onMode.onPreset and presets[key] then
    for _, p in ipairs({ onMode.onPreset, onMode.fadePreset }) do
      if p.id == presetId and p.origin == Settings.PRESET_ORIGIN_DEVICE then
        p.x, p.y, p.mode = presets[key].x, presets[key].y, presets[key].mode
      end
    end
    persist:set(Settings.P_COLOR_ON_MODE, onMode)
  end
end

--- UPDATE_COLOR_ON_MODE: the On preset, and the Dim one for Dim-To-Warm.
--- @private
function Settings:_updateColorOnMode(tParams)
  local mode = {
    onPreset = {
      id = tointeger(Select(tParams, "COLOR_PRESET_ID")),
      origin = tointeger(Select(tParams, "COLOR_PRESET_ORIGIN")),
      x = tonumber(Select(tParams, "COLOR_PRESET_COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_PRESET_COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_PRESET_COLOR_MODE")),
    },
    fadePreset = {
      id = tointeger(Select(tParams, "COLOR_FADE_PRESET_ID")),
      origin = tointeger(Select(tParams, "COLOR_FADE_PRESET_ORIGIN")),
      x = tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_X")),
      y = tonumber(Select(tParams, "COLOR_FADE_PRESET_COLOR_Y")),
      mode = tointeger(Select(tParams, "COLOR_FADE_PRESET_COLOR_MODE")),
    },
  }
  persist:set(Settings.P_COLOR_ON_MODE, mode)
end

--- SET_CLICK_RATE_UP. Rate notifies take a plain string, as PRESET_LEVEL does.
--- @private
function Settings:_setClickRateUp(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_CLICK_RATE
  persist:set(Settings.P_CLICK_RATE_UP, rate)
  SendToProxy(self.opts.proxy, "CLICK_RATE_UP", tostring(rate), "NOTIFY")
end

--- @private
function Settings:_setClickRateDown(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_CLICK_RATE
  persist:set(Settings.P_CLICK_RATE_DOWN, rate)
  SendToProxy(self.opts.proxy, "CLICK_RATE_DOWN", tostring(rate), "NOTIFY")
end

--- @private
function Settings:_setHoldRateUp(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_HOLD_RATE
  persist:set(Settings.P_HOLD_RATE_UP, rate)
  SendToProxy(self.opts.proxy, "HOLD_RATE_UP", tostring(rate), "NOTIFY")
end

--- @private
function Settings:_setHoldRateDown(tParams)
  local rate = tointeger(Select(tParams, "RATE")) or DEFAULT_HOLD_RATE
  persist:set(Settings.P_HOLD_RATE_DOWN, rate)
  SendToProxy(self.opts.proxy, "HOLD_RATE_DOWN", tostring(rate), "NOTIFY")
end

--- SET_MAX_ON_LEVEL: every level sent and read back is remapped through the range.
--- @private
function Settings:_setMaxOnLevel(tParams)
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 100))
  persist:set(Settings.P_MAX_ON_LEVEL, level)
  SendToProxy(self.opts.proxy, "MAX_ON", tostring(level), "NOTIFY")
  self:_remapLevel()
end

--- @private
function Settings:_setMinOnLevel(tParams)
  local level = math.max(0, math.min(100, tointeger(Select(tParams, "LEVEL")) or 0))
  persist:set(Settings.P_MIN_ON_LEVEL, level)
  SendToProxy(self.opts.proxy, "MIN_ON", tostring(level), "NOTIFY")
  self:_remapLevel()
end

return Settings
