--- Update settings every item of the repo's drivers keeps the same, in DriverCentral and OSS builds. Only the item
--- someone changed sends the value, as a command the others set without OnPropertyChanged. Director runs
--- OnPropertyChanged for every UPDATE_PROPERTY, an unchanged value too, so each receiver of a pushed property would
--- push it on.

require("drivers-common-public.global.handlers")
require("lib.utils")
local driverFilenames = require("lib.driver-filenames")

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
--- @param name string The setting.
--- @param value string Its new value.
--- @param filenames? string[] The drivers that keep the setting the same: every driver the repo builds unless given.
function UpdateSettings:share(name, value, filenames)
  local myId = C4:GetDeviceID()
  for _, filename in ipairs(filenames or driverFilenames) do
    for id in pairs(C4:GetDevicesByC4iName(filename) or {}) do
      if tonumber(id) ~= myId then
        SendToDevice(tonumber(id), "SET_UPDATE_SETTING", { Name = name, Value = value })
      end
    end
  end
end

--- Sets an update setting another item sent with `SET_UPDATE_SETTING`, if this item has it: a companion with no
--- update settings of its own is sent them too.
--- @param params table The command's parameters: `Name` the setting, `Value` its value.
function UpdateSettings:take(params)
  if SHARED[params.Name] and Properties[params.Name] ~= nil then
    UpdateProperty(params.Name, params.Value)
  end
end

return UpdateSettings:new()
