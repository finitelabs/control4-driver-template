--- The light's three buttons: BUTTON_ACTION from the proxy, DO_PUSH, DO_CLICK and DO_RELEASE from
--- the button links, holds and clicks, and the button colors.

local Settings = require("lib.light.settings")

require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local BUTTONS, ACTIONS = Settings.BUTTONS, Settings.ACTIONS

--- @class LightButtons
local Buttons = {}

--- The level a click acts on, where its press found a light outside the range, and its press's hold
--- ramp. That ramp is dropped, so the click's ramp starts from where the press found the light, and
--- the click replaces it; a click with no press replaces the ramp it finds, as any command does.
--- @private
--- @return integer level, number|nil startAt, table|nil hold
function Buttons:_rewindToPrePress()
  local aim = self.aim
  local snapshot = aim.prePress
  aim.prePress = nil
  if snapshot == nil then
    return (self:_interpolatedBrightness())
  end
  local hold = aim.level
  CancelTimer("Light.BrightnessRamp")
  aim.level = nil
  return snapshot, hold and hold.startAt, hold
end

--- A button's press, hold release or click, from the proxy or a link.
--- @private
--- @param buttonId integer
--- @param action integer
function Buttons:_buttonAction(buttonId, action)
  if action == ACTIONS.PRESS then
    -- The proxy sends PRESS at button-down and decides click or hold about 110 ms later, so a click
    -- rewinds to this level before its own ramp. A ramp in flight leaves the told level where it
    -- began, so take the light's own.
    self.aim.prePress = self:_interpolatedBrightness()
    if not self:_dims() then
      if buttonId == BUTTONS.TOP then
        self:_lightOn()
      elseif buttonId == BUTTONS.BOTTOM then
        self:_lightOff()
      elseif buttonId == BUTTONS.TOGGLE then
        self:_lightToggle()
      end
      return
    end
    -- A hold ramps toward full or off until its release stops it; a click goes to the on level.
    if buttonId == BUTTONS.TOP then
      self:_rampToBrightness(100, self:_holdRateUp())
    elseif buttonId == BUTTONS.BOTTOM then
      self:_rampToBrightness(0, self:_holdRateDown())
    elseif buttonId == BUTTONS.TOGGLE then
      if self.aim.prePress > 0 then
        self:_rampToBrightness(0, self:_holdRateDown())
      else
        self:_rampToBrightness(100, self:_holdRateUp())
      end
    end
  elseif action == ACTIONS.RELEASE_HOLD then
    self.aim.prePress = nil
    self:_brightnessRampStopped()
  elseif action == ACTIONS.RELEASE_CLICK then
    local effective, startAt, hold = self:_rewindToPrePress()
    local dims = self:_dims()
    if buttonId == BUTTONS.TOP then
      if dims then
        self:_rampToBrightness(self:_onBrightness(), self:_clickRateUp(), nil, startAt, hold)
      else
        self:_lightOn()
      end
    elseif buttonId == BUTTONS.BOTTOM then
      if dims then
        self:_rampToBrightness(0, self:_clickRateDown(), nil, startAt, hold)
      else
        self:_lightOff()
      end
    elseif buttonId == BUTTONS.TOGGLE then
      if dims then
        if effective > 0 then
          self:_rampToBrightness(0, self:_clickRateDown(), nil, startAt, hold)
        else
          self:_rampToBrightness(self:_onBrightness(), self:_clickRateUp(), nil, startAt, hold)
        end
      else
        if effective > 0 then
          self:_lightOff()
        else
          self:_lightOn()
        end
      end
    end
  end
end

--- BUTTON_ACTION, echoed after the ramp is set up: echoed first, the proxy snaps its UI to the on or
--- off target and the CHANGING after it rewinds, a visible jump.
--- @private
function Buttons:_onButtonAction(tParams)
  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local action = tointeger(Select(tParams, "ACTION"))
  self:_buttonAction(buttonId, action)
  SendToProxy(self.opts.proxy, "BUTTON_ACTION", {
    BUTTON_ID = buttonId,
    ACTION = action,
  }, "NOTIFY")
end

--- The button a link binding drives, or nil.
--- @private
--- @param idBinding integer
--- @return integer|nil buttonId
function Buttons:_linkButton(idBinding)
  local links = self.opts.links
  if not links then
    return nil
  end
  if idBinding == links.top then
    return BUTTONS.TOP
  elseif idBinding == links.bottom then
    return BUTTONS.BOTTOM
  elseif idBinding == links.toggle then
    return BUTTONS.TOGGLE
  end
  return nil
end

--- DO_PUSH, DO_CLICK or DO_RELEASE on a link. The proxy sent it, so it already knows the button fired:
--- no BUTTON_ACTION goes back.
--- @private
--- @param idBinding integer
--- @param action integer
function Buttons:_onLink(idBinding, action)
  local buttonId = self:_linkButton(idBinding)
  if buttonId == nil then
    return
  end
  self:_buttonAction(buttonId, action)
end

--- REQUEST_BUTTON_COLORS: each button's colors, then each link's LED, Bottom's lit while the light is off.
--- @private
function Buttons:_requestButtonColors()
  for _, buttonId in ipairs({ 0, 1, 2 }) do
    local onColor, offColor = self:_buttonColors(buttonId)
    SendToProxy(self.opts.proxy, "BUTTON_COLORS", {
      BUTTON_ID = buttonId,
      ON_COLOR = onColor,
      OFF_COLOR = offColor,
    }, "NOTIFY")
  end
  local links = self.opts.links
  if not links then
    return
  end
  local isOn = self.told.leds
  SendToProxy(links.top, "MATCH_LED_STATE", { STATE = isOn }, "NOTIFY", true)
  SendToProxy(links.bottom, "MATCH_LED_STATE", { STATE = not isOn }, "NOTIFY", true)
  SendToProxy(links.toggle, "MATCH_LED_STATE", { STATE = isOn }, "NOTIFY", true)
end

--- SET_BUTTON_COLOR: stored, and told back as BUTTON_INFO.
--- @private
function Buttons:_setButtonColor(tParams)
  local buttonId = tointeger(Select(tParams, "BUTTON_ID"))
  local onColor = Select(tParams, "ON_COLOR")
  local offColor = Select(tParams, "OFF_COLOR")
  if buttonId == nil then
    return
  end
  self:_setButtonColors(buttonId, onColor, offColor)
  if onColor then
    SendToProxy(self.opts.proxy, "BUTTON_INFO", { BUTTON_ID = buttonId, ON_COLOR = onColor }, "NOTIFY")
  end
  if offColor then
    SendToProxy(self.opts.proxy, "BUTTON_INFO", { BUTTON_ID = buttonId, OFF_COLOR = offColor }, "NOTIFY")
  end
end

return Buttons
