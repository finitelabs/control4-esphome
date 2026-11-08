-- An ESPHome entity named like one of the driver's settings never writes that setting.
--
-- wifi_info's "IP Address" text sensor used to replace the IP Address the driver connects to,
-- which ran its handler and reconnected. The entity's variable is still made under its name.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_entity_values_leave_settings.lua

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers") -- OnPropertyChanged
local T = require("testlib")

local deferred = require("deferred")
local values = require("lib.values")

local client = {
  callServiceMethod = function()
    return deferred.new():resolve(nil)
  end,
}

local SETTINGS = {
  ["IP Address"] = "192.168.2.50",
  ["MAC Address"] = "AA:BB:CC:DD:EE:FF",
  ["Port"] = "6053",
  ["Log Level"] = "3 - Info",
}

--- The setting handlers that ran, in order.
local ran = {}
for name, value in pairs(SETTINGS) do
  Properties[name] = value
  OPC[(name:gsub(" ", "_"))] = function(propertyValue)
    table.insert(ran, name .. " = " .. tostring(propertyValue))
  end
end

--- The settings written, in order. The shim's UpdateProperty does not change Properties, so this is the check.
local written = {}
local updateProperty = C4.UpdateProperty
function C4:UpdateProperty(name, value)
  if SETTINGS[name] then
    table.insert(written, name .. " = " .. tostring(value))
  end
  return updateProperty(self, name, value)
end

local nextKey = 100
--- A new entity of `module` named `name`, discovered, then reporting `state`.
local function report(module, name, state)
  nextKey = nextKey + 1
  local Entity = require("esphome.entities." .. module)
  local entity = { key = nextKey, ref = tostring(nextKey), name = name, options = { "3 - Info", "6 - Ultra" } }
  local instance = Entity:new(client)
  if instance.discovered then
    instance:discovered(entity)
  end
  instance:updated(entity, { key = entity.key, state = state })
end

for _, case in ipairs({
  { "text_sensor", "IP Address", "192.168.2.77", "192.168.2.77" },
  { "text_sensor", "MAC Address", "11:22:33:44:55:66", "11:22:33:44:55:66" },
  { "sensor", "Port", 1234, 1234 },
  { "select", "Log Level", "6 - Ultra", "6 - Ultra" },
}) do
  local module, name, state, shown = unpack(case)
  T.section("a " .. module .. " named " .. name)
  ran, written = {}, {}
  report(module, name, state)
  T.eq("the setting is not written", written, {})
  T.eq("its handler does not run", ran, {})
  T.eq("the entity's value is kept under its name", values:getValue(name).value, shown)
end

T.section("deleting the entity's value leaves the setting too")
ran, written = {}, {}
values:delete("IP Address")
T.eq("the setting is not written", written, {})
T.eq("its handler does not run", ran, {})

T.finish()
