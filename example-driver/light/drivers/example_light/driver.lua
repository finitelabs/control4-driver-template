require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local Light = require("lib.light")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local updateSettings = require("lib.update-settings")
--#endif

-- The light this driver drives, in memory so the example needs no device: a color bulb that
-- fades itself from where it is over the time each command asks, and reports its state when the
-- fade has run. Off, it keeps the level it was lit at.
local bulb = {
  on = false,
  level = 1,
  color = { x = 0.3127, y = 0.329, mode = Light.CCT },
  fade = { at = 0, ms = 0, level = 0, color = { x = 0.3127, y = 0.329 } },
}

--- The bulb's state at `now`: part way along a fade in flight, lit until a fade to off has run.
--- @param now number
--- @return LightState
local function stateAt(now)
  local fade = bulb.fade
  local t = fade.ms > 0 and math.min(1, (now - fade.at) / fade.ms) or 1
  local to = bulb.on and bulb.level or 0
  local level = fade.level + (to - fade.level) * t
  local color = {
    x = fade.color.x + (bulb.color.x - fade.color.x) * t,
    y = fade.color.y + (bulb.color.y - fade.color.y) * t,
    mode = bulb.color.mode,
  }
  if level > 0 and (bulb.on or t < 1) then
    return { on = true, level = level, color = color }
  end
  return { on = false, level = bulb.level, color = color }
end

-- What the bulb can do. It pushes its state when it likes, saying nothing of which command a push
-- follows, so its reports are taken as they come (trust).
local DECLARATION = {
  dims = true,
  color = true,
  cct = { min = 2000, max = 6500 },
  fade = { by = "device" },
  reports = { policy = "trust" },
}

-- A report comes this long after the fade has run, as one over a network does.
local REPORT_MS = 40

local light

local function reportState()
  light:report(stateAt(C4:GetTime()))
end

local adapter = {}

--- Put a command on the bulb: it fades from where it is now. A field the command leaves out stays as it is.
--- @param cmd LightCommand
function adapter:send(cmd)
  local now = C4:GetTime()
  local from = stateAt(now)
  bulb.fade = { at = now, ms = cmd.ms or 0, level = from.on and from.level or 0, color = from.color }
  if cmd.on ~= nil then
    bulb.on = cmd.on
  end
  if cmd.level then
    bulb.level = cmd.level
  end
  if cmd.color then
    bulb.color = { x = cmd.color.x, y = cmd.color.y, mode = cmd.color.mode }
  end
  SetTimer("ExampleLight.Report", (cmd.ms or 0) + REPORT_MS, reportState)
end

--- Ask the bulb for its whole state.
function adapter:refresh()
  SetTimer("ExampleLight.Report", REPORT_MS, reportState)
end

-- The bulb is the only device this driver drives, so its profile is fixed: what it can do, exactly.
light = Light.new(adapter, {
  api = 1,
  profile = { dims = true, color = true, cct = { min = 2000, max = 6500 }, fixed = true },
})

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged once per property to set initial globals. The router runs each
  -- handler in its own xpcall and reports a failure itself, so one property's error doesn't
  -- stop the rest.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end
  gInitialized = true
  -- The bulb is always there: declared before the start, its first report brings the light online.
  light:declare(DECLARATION)
  light:start()
  UpdateProperty("Driver Status", "Online")
  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(licensed)
    UpdateProperty("Driver Status", licensed and "Online" or drivercentral.UNLICENSED_STATUS)
  end)
  --#endif
end

function OnDriverDestroyed()
  light:destroy()
end

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

--#ifdef DRIVERCENTRAL
function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end
--#endif

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end
