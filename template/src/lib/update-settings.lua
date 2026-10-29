--- Update settings every item of a set of drivers keeps the same. Only the item someone changed sends the value, as a
--- command the others set without OnPropertyChanged. Director runs OnPropertyChanged for every UPDATE_PROPERTY, an
--- unchanged value too, so each receiver of a pushed property would push it on.

require("drivers-common-public.global.handlers")
require("lib.utils")

--- @class UpdateSettings
local UpdateSettings = {}
UpdateSettings.__index = UpdateSettings

--- The settings an item takes from another.
local SHARED = { ["Automatic Updates"] = true, ["Update Channel"] = true }

--- Creates a new `UpdateSettings` instance.
--- @return UpdateSettings updateSettings A new `UpdateSettings` instance.
function UpdateSettings:new()
  return setmetatable({}, self)
end

--- Sends a change made on this item to every other installed item of `filenames`, as `SET_UPDATE_SETTING`.
--- @param filenames string[] The drivers whose items keep the setting the same.
--- @param name string The setting.
--- @param value string Its new value.
function UpdateSettings:share(filenames, name, value)
  local myId = C4:GetDeviceID()
  for _, filename in ipairs(filenames) do
    for id in pairs(C4:GetDevicesByC4iName(filename) or {}) do
      if tonumber(id) ~= myId then
        SendToDevice(tonumber(id), "SET_UPDATE_SETTING", { Name = name, Value = value })
      end
    end
  end
end

--- Sets an update setting another item sent with `SET_UPDATE_SETTING`.
--- @param params table The command's parameters: `Name` the setting, `Value` its value.
function UpdateSettings:take(params)
  if SHARED[params.Name] then
    UpdateProperty(params.Name, params.Value)
  end
end

return UpdateSettings:new()
