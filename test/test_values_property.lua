-- A value whose name matches a property: lib/values copies it into the property unless the
-- update says `property = false`, as for a value named by a device, which could match one of
-- the driver's settings. The choice is kept, so a restore and a delete leave the property too.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_values_property.lua

local T = require("testlib")
local H = require("values_harness")

local SETTING = "192.168.1.20"
local NO_PROPERTY = { property = false }

-- Director keeps Properties current with each write and runs OnPropertyChanged for one that
-- asks; the shim's do neither, so each is recorded here.
local writes, shown = {}, {}
function C4:UpdateProperty(name, value)
  Properties[name] = value
  writes[#writes + 1] = name
end
function C4:SetPropertyAttribs(name, attribs)
  shown[name] = attribs
end

--- A clean install, loaded, with the installer's IP Address set.
local function fresh()
  H.wipe()
  local values = H.load("restart")
  Properties["IP Address"] = SETTING
  writes, shown = {}, {}
  return values
end

T.section("by default the property takes the value, as before")
do
  local values = fresh()
  values:update("IP Address", "10.0.0.5", "STRING")
  T.eq("the variable", Variables["IP Address"], "10.0.0.5")
  T.eq("the property", Properties["IP Address"], "10.0.0.5")
end

T.section("property = false writes the variable and leaves the property")
do
  local values = fresh()
  values:update("IP Address", "10.0.0.5", "STRING", nil, nil, NO_PROPERTY)
  T.eq("the variable", Variables["IP Address"], "10.0.0.5")
  T.eq("the property keeps the installer's setting", Properties["IP Address"], SETTING)
  T.eq("nothing is written to it", writes, {})
  T.eq("nor shown", shown["IP Address"], nil)
  values:update("IP Address", "10.0.0.6", "STRING", nil, nil, NO_PROPERTY)
  T.eq("a later value too", { Variables["IP Address"], Properties["IP Address"] }, { "10.0.0.6", SETTING })

  values = H.load("restart")
  T.eq("a restart restores the variable", Variables["IP Address"], "10.0.0.6")
  T.eq("and leaves the property", Properties["IP Address"], SETTING)
  T.eq("unwritten", writes, {})

  values:delete("IP Address")
  T.eq("a delete removes the variable", Variables["IP Address"], nil)
  T.eq("and leaves the property", Properties["IP Address"], SETTING)
  T.eq("still unwritten and not hidden", { #writes, shown["IP Address"] }, { 0, nil })
end

T.section("the update decides: one without the option copies to the property again")
do
  local values = fresh()
  values:update("IP Address", "10.0.0.5", "STRING", nil, nil, NO_PROPERTY)
  local changed, recordChanged = values:update("IP Address", "10.0.0.5", "STRING")
  T.eq("which changes the record but not the value", { changed, recordChanged }, { false, true })
  T.eq("and the property takes it", Properties["IP Address"], "10.0.0.5")
end

T.finish()
