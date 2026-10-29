-- lib.update-settings: which items a change is sent to, and what an item does with a setting it is sent.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_update_settings.lua

local T = require("testlib")

require("c4_shim")
package.loaded["lib.driver-filenames"] = { "a.c4z", "b.c4z", "c.c4z" } -- what the build writes in
local updateSettings = require("lib.update-settings")

-- Director's project: two items of one driver, one of another, and the repo's third driver not installed.
local ITEMS = { ["a.c4z"] = { 601, 602 }, ["b.c4z"] = { 611 } }
local me = 601
function C4:GetDeviceID()
  return me
end
function C4:GetDevicesByC4iName(filename)
  local found
  for _, id in ipairs(ITEMS[filename] or {}) do
    found = found or {}
    found[id] = "Item " .. id
  end
  return found
end

local sent, written = {}, {}
function C4:SendToDevice(id, cmd, params)
  sent[#sent + 1] = string.format("%d %s %s %s", id, cmd, params.Name, params.Value)
end
-- Director keeps Properties current with what a driver writes.
function C4:UpdateProperty(name, value)
  Properties[name] = value
  written[#written + 1] = name .. " " .. value
end
function C4:GetDriverConfigInfo(section)
  if section == "config" then
    return table.concat({
      "<properties>",
      "<property><name>Automatic Updates</name><type>LIST</type><items><item>Off</item><item>On</item></items></property>",
      "<property><name>Log Level</name><type>STRING</type></property>",
      "</properties>",
    })
  end
end
Properties["Automatic Updates"], Properties["Log Level"] = "On", "3 - Info"

local function commands()
  table.sort(sent)
  return sent
end

T.section("A change goes to every other item of the repo's drivers, once")
updateSettings:share("Automatic Updates", "Off")
T.eq(
  "each other item is sent it, and this one is not",
  commands(),
  { "602 SET_UPDATE_SETTING Automatic Updates Off", "611 SET_UPDATE_SETTING Automatic Updates Off" }
)
sent = {}
updateSettings:share("Automatic Updates", "Off", { "a.c4z" })
T.eq(
  "or of the drivers given, for a driver that stands alone",
  sent,
  { "602 SET_UPDATE_SETTING Automatic Updates Off" }
)

T.section("A setting another item sends is set, and goes no further")
sent, written = {}, {}
local ran = 0
OPC.Automatic_Updates = function()
  ran = ran + 1
end
updateSettings:take({ Name = "Automatic Updates", Value = "Off" })
T.eq("it reads Off", Properties["Automatic Updates"], "Off")
T.eq("written as the driver writes a property", written, { "Automatic Updates Off" })
T.eq("which runs no OnPropertyChanged", ran, 0)
T.eq("so nothing is sent", sent, {})

T.section("Only an update setting the item has, and only a value it offers, is taken")
written = {}
T.capture(function()
  updateSettings:take({ Name = "Automatic Updates", Value = "Maybe" })
end)
T.eq("a value the setting does not offer is not set", Properties["Automatic Updates"], "Off")
updateSettings:take({ Name = "Log Level", Value = "6 - Trace" })
T.eq("nor is a setting other than an update setting", Properties["Log Level"], "3 - Info")
local _, _, output = T.capture(function()
  updateSettings:take({ Name = "Update Channel", Value = "Prerelease" })
end)
T.eq("an update setting the item does not have is passed over", Properties["Update Channel"], nil)
T.eq("without a word", output, "")
T.eq("and none of them is written", written, {})

T.finish()
