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

-- The light this driver drives, in memory so the example needs no device: a color bulb that fades itself
-- from where it is over the time each command asks, and pushes its state when a fade has run. The adapter
-- holds it, as an adapter holds its transport.

-- A report comes this long after a fade has run, as one over a network does.
local REPORT_MS = 40

--- @type LightColor
local WHITE = { x = 0.3127, y = 0.329, mode = "cct", kelvin = 6500 }

-- What the bulb is: it fades over the time each command asks, and a read of it is cheap.
--- @type LightDevice
local DEVICE = {
  dims = true,
  color = true,
  cct = { minK = 2000, maxK = 6500 },
  fade = { kind = "device" },
  feedback = { shows = "target", refresh = true },
}

--- Where the bulb's fade started from, and when.
--- @class ExampleBulbFade
--- @field at integer C4:GetTime() ms.
--- @field ms integer
--- @field level number Device brightness 0-1; 0 while off.
--- @field color LightColor

--- The bulb: where its fade heads, and the fade.
--- @class ExampleBulb
--- @field on boolean
--- @field level number Device brightness 0-1; while off, the level it keeps.
--- @field color LightColor
--- @field fade ExampleBulbFade

--- example_light's adapter, whose transport is the bulb.
--- @class ExampleLightAdapter : LightAdapter
--- @field bulb ExampleBulb
--- @field asked boolean A refresh waits for its answer.
local Adapter = {}
Adapter.__index = Adapter

--- @type Light
local light

--- @param color LightColor
--- @return LightColor
local function copyColor(color)
  return { x = color.x, y = color.y, mode = color.mode, kelvin = color.kelvin }
end

--- The bulb's state at `now`: part way along a fade in flight, lit until a fade to off has run.
--- @param now integer
--- @return LightValues
function Adapter:stateAt(now)
  local bulb = self.bulb
  local fade = bulb.fade
  local t = fade.ms > 0 and math.min(1, (now - fade.at) / fade.ms) or 1
  local level = fade.level + ((bulb.on and bulb.level or 0) - fade.level) * t
  local color = copyColor(bulb.color)
  if t < 1 then
    color = {
      x = fade.color.x + (bulb.color.x - fade.color.x) * t,
      y = fade.color.y + (bulb.color.y - fade.color.y) * t,
      mode = "xy",
    }
  end
  if level > 0 and (bulb.on or t < 1) then
    return { on = true, level = level, color = color }
  end
  return { on = false, level = bulb.level, color = color }
end

--- Hand the light the bulb's state: the answer to a waiting refresh, or a push.
function Adapter:report()
  local now = C4:GetTime()
  local state = self:stateAt(now)
  local kind = "push"
  if self.asked then
    local fade = self.bulb.fade
    kind = (fade.ms > 0 and now < fade.at + fade.ms) and "moving" or "final"
    self.asked = false
  end
  light:report({ kind = kind, on = state.on, level = state.level, color = state.color })
end

--- Put a command on the bulb: it fades from where it is over the command's time.
--- @param cmd LightCommand
function Adapter:send(cmd)
  local now = C4:GetTime()
  local from = self:stateAt(now)
  local bulb = self.bulb
  bulb.fade = { at = now, ms = cmd.transitionMs, level = from.on and from.level or 0, color = from.color }
  bulb.on = cmd.on
  bulb.level = cmd.level
  if cmd.color then
    bulb.color = copyColor(cmd.color)
  end
  SetTimer("ExampleLight.Pushed", cmd.transitionMs + REPORT_MS, function()
    self:report()
  end)
end

--- Ask the bulb for its whole state.
function Adapter:refresh()
  self.asked = true
  SetTimer("ExampleLight.Answer", REPORT_MS, function()
    self:report()
  end)
end

--- example_light has no device page.
--- @param _ LightShown
function Adapter:show(_) end

-- The bulb is the only device this driver drives, so the profile is known: every device is as it says.
light = Light.new(
  setmetatable({
    bulb = { on = false, level = 1, color = copyColor(WHITE), fade = { at = 0, ms = 0, level = 0, color = WHITE } },
    asked = false,
  }, Adapter),
  {
    api = 1,
    links = { top = 300, toggle = 301, bottom = 302 },
    dims = true,
    color = true,
    cct = { minK = 2000, maxK = 6500 },
    known = true,
    fades = true,
    defaultOn = true,
    scenes = true,
    onModes = true,
    flash = true,
  }
)

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
  light:declare(DEVICE)
  light:start()
  UpdateProperty("Driver Status", "Online")
  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(licensed)
    UpdateProperty("Driver Status", licensed and "Online" or drivercentral.UNLICENSED_STATUS)
  end)
  --#endif
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
