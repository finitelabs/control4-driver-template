--- The Light V2 proxy's commands and the button links' DO_* commands, registered on the RFP table
--- as closures over one light. Dispatch is by command name before binding, so each checks its binding.

local log = require("lib.logging")
local Settings = require("lib.light.settings")

require("drivers-common-public.global.handlers")

local ACTIONS = Settings.ACTIONS

--- The proxy commands, and the method of the light each one runs with its parameters.
local PROXY_COMMANDS = {
  SET_BRIGHTNESS_TARGET = "_setBrightnessTarget",
  ON = "_on",
  OFF = "_off",
  TOGGLE = "_toggle",
  -- Navigators from OS 3.3.2 send these for a generic on or off; the on modes already apply.
  DYNAMIC_ON = "_on",
  DYNAMIC_OFF = "_off",
  SET_LEVEL = "_setLevel",
  RAMP_TO_LEVEL = "_rampToLevel",
  SET_COLOR_TARGET = "_setColorTarget",
  SET_BRIGHTNESS_STOP = "_setBrightnessStop",
  SET_COLOR_STOP = "_setColorStop",
  SET_MAX_ON_LEVEL = "_setMaxOnLevel",
  SET_MIN_ON_LEVEL = "_setMinOnLevel",
  GET_CONNECTED_STATE = "_getConnectedState",
  GET_LIGHT_LEVEL = "_getLightLevel",
  PUSH_SCENE = "_pushScene",
  REMOVE_SCENE = "_removeScene",
  CLEAR_ALL_SCENES = "_clearAllScenes",
  ACTIVATE_SCENE = "_activateScene",
  DEACTIVATE_SCENE = "_deactivateScene",
  RAMP_SCENE_UP = "_rampSceneUp",
  RAMP_SCENE_DOWN = "_rampSceneDown",
  STOP_SCENE_RAMP = "_stopSceneRamp",
  TOGGLE_SCENE = "_toggleScene",
  SET_PRESET_LEVEL = "_setPresetLevel",
  UPDATE_BRIGHTNESS_ON_MODE = "_updateBrightnessOnMode",
  SET_BRIGHTNESS_ON_MODE = "_setBrightnessOnMode",
  UPDATE_BRIGHTNESS_PRESET = "_updateBrightnessPreset",
  UPDATE_BRIGHTNESS_RATE_DEFAULT = "_updateBrightnessRateDefault",
  UPDATE_COLOR_RATE_DEFAULT = "_updateColorRateDefault",
  UPDATE_COLOR_PRESET = "_updateColorPreset",
  UPDATE_COLOR_ON_MODE = "_updateColorOnMode",
  SET_CLICK_RATE_UP = "_setClickRateUp",
  SET_CLICK_RATE_DOWN = "_setClickRateDown",
  SET_HOLD_RATE_UP = "_setHoldRateUp",
  SET_HOLD_RATE_DOWN = "_setHoldRateDown",
  REQUEST_BUTTON_COLORS = "_requestButtonColors",
  SET_BUTTON_COLOR = "_setButtonColor",
  BUTTON_ACTION = "_onButtonAction",
}

-- Commands the light takes and acts on not at all: the proxy's mark that it has pushed its scenes,
-- and SET_COLOR_ON_MODE, whose mode UPDATE_COLOR_ON_MODE's presets already pick.
local IGNORED = { "ALL_SCENES_PUSHED", "SET_COLOR_ON_MODE" }

local LINK_COMMANDS = {
  DO_PUSH = ACTIONS.PRESS,
  DO_CLICK = ACTIONS.RELEASE_CLICK,
  DO_RELEASE = ACTIONS.RELEASE_HOLD,
}

--- @class LightHandlers
local Handlers = {}

--- ON and DYNAMIC_ON, at the default rate of an on: at once.
--- @private
function Handlers:_on()
  self:_lightOn()
end

--- @private
function Handlers:_off()
  self:_lightOff()
end

--- @private
function Handlers:_toggle()
  self:_lightToggle()
end

--- @private
function Handlers:_rampSceneUp(tParams)
  self:_rampScene(tParams, true)
end

--- @private
function Handlers:_rampSceneDown(tParams)
  self:_rampScene(tParams, false)
end

--- GET_CONNECTED_STATE: whether the light can be reached.
--- @private
function Handlers:_getConnectedState()
  self:_notifyOnline(self.told.online)
end

--- Register every proxy and link handler on RFP for this light.
--- @private
function Handlers:_register()
  local proxy = self.opts.proxy
  for command, method in pairs(PROXY_COMMANDS) do
    RFP[command] = function(idBinding, strCommand, tParams)
      log:trace("RFP.%s(%s, %s, %s)", command, idBinding, strCommand, tParams)
      if idBinding ~= proxy then
        return
      end
      self:_guard(self[method], tParams or {})
    end
  end
  -- The published name is STOP_RAMP_SCENE; older code sends STOP_SCENE_RAMP. Both reach the light.
  RFP.STOP_RAMP_SCENE = RFP.STOP_SCENE_RAMP
  for _, command in ipairs(IGNORED) do
    RFP[command] = function(idBinding, strCommand, tParams)
      log:trace("RFP.%s(%s, %s, %s)", command, idBinding, strCommand, tParams)
    end
  end
  if not self.opts.links then
    return
  end
  for command, action in pairs(LINK_COMMANDS) do
    RFP[command] = function(idBinding, strCommand)
      log:trace("RFP.%s(%s, %s)", command, idBinding, strCommand)
      self:_guard(self._onLink, idBinding, action)
    end
  end
end

return Handlers
