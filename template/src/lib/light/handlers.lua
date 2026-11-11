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
local IGNORED = { ALL_SCENES_PUSHED = "scenes", SET_COLOR_ON_MODE = "onModes" }

-- The commands that move or ask the device. With no state from its device the light drops them: from
-- a load, a bind, a change of device binding or a loss until the device's next state.
local DEVICE = {
  SET_BRIGHTNESS_TARGET = true,
  ON = true,
  OFF = true,
  TOGGLE = true,
  DYNAMIC_ON = true,
  DYNAMIC_OFF = true,
  SET_LEVEL = true,
  RAMP_TO_LEVEL = true,
  SET_COLOR_TARGET = true,
  SET_BRIGHTNESS_STOP = true,
  SET_COLOR_STOP = true,
  GET_LIGHT_LEVEL = true,
  ACTIVATE_SCENE = true,
  DEACTIVATE_SCENE = true,
  RAMP_SCENE_UP = true,
  RAMP_SCENE_DOWN = true,
  STOP_SCENE_RAMP = true,
  TOGGLE_SCENE = true,
  BUTTON_ACTION = true,
}

-- The families a profile can leave out, and their commands: a family not offered has no handlers.
local FAMILY = {
  PUSH_SCENE = "scenes",
  REMOVE_SCENE = "scenes",
  CLEAR_ALL_SCENES = "scenes",
  ACTIVATE_SCENE = "scenes",
  DEACTIVATE_SCENE = "scenes",
  RAMP_SCENE_UP = "scenes",
  RAMP_SCENE_DOWN = "scenes",
  STOP_SCENE_RAMP = "scenes",
  TOGGLE_SCENE = "scenes",
  UPDATE_BRIGHTNESS_ON_MODE = "onModes",
  SET_BRIGHTNESS_ON_MODE = "onModes",
  UPDATE_COLOR_ON_MODE = "onModes",
  REQUEST_BUTTON_COLORS = "links",
  SET_BUTTON_COLOR = "links",
  BUTTON_ACTION = "links",
}

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

--- Whether the profile offers a family.
--- @private
--- @param family string|nil
--- @return boolean
function Handlers:_offers(family)
  if family == "links" then
    return self.opts.links ~= false
  end
  return family == nil or self.profile[family] ~= false
end

--- A command on a binding the light does not own goes to the driver's own handler for that binding.
--- @param idBinding integer
--- @param strCommand string
--- @param tParams table|nil
local function passOn(idBinding, strCommand, tParams)
  local own = RFP[idBinding]
  if type(own) == "function" then
    return own(idBinding, strCommand, tParams)
  end
end

--- Register on RFP the handler of every proxy and link command this light's profile offers.
--- @private
function Handlers:_register()
  local proxy = self.opts.proxy
  for command, method in pairs(PROXY_COMMANDS) do
    if self:_offers(FAMILY[command]) then
      RFP[command] = function(idBinding, strCommand, tParams)
        log:trace("RFP.%s(%s, %s, %s)", command, idBinding, strCommand, tParams)
        if idBinding ~= proxy then
          return passOn(idBinding, strCommand, tParams)
        end
        if self.destroyed then
          return
        end
        if DEVICE[command] and not self.device.present then
          log:debug("RFP.%s dropped: no state from the device yet", command)
          return
        end
        self:_guard(self[method], tParams or {})
      end
    end
  end
  -- The published name is STOP_RAMP_SCENE; older code sends STOP_SCENE_RAMP. Both reach the light.
  RFP.STOP_RAMP_SCENE = RFP.STOP_SCENE_RAMP
  for command, family in pairs(IGNORED) do
    if self:_offers(family) then
      RFP[command] = function(idBinding, strCommand, tParams)
        log:trace("RFP.%s(%s, %s, %s)", command, idBinding, strCommand, tParams)
        if idBinding ~= proxy then
          return passOn(idBinding, strCommand, tParams)
        end
      end
    end
  end
  if not self.opts.links then
    return
  end
  local own = {}
  for _, id in pairs(self.opts.links) do
    own[id] = true
  end
  for command, action in pairs(LINK_COMMANDS) do
    RFP[command] = function(idBinding, strCommand, tParams)
      log:trace("RFP.%s(%s, %s)", command, idBinding, strCommand)
      if not own[idBinding] then
        return passOn(idBinding, strCommand, tParams)
      end
      if self.destroyed or not self.device.present then
        return
      end
      self:_guard(self._onLink, idBinding, action)
    end
  end
end

return Handlers
