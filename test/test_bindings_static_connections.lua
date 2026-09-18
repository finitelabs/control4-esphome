-- Static driver.xml connections share the dynamic-binding id space with the ones
-- lib/bindings.lua hands out, and are not in its store, so restoreBindings()'s
-- managed-range sweep has to read them out of GetDriverConfigInfo("connections")
-- to leave them alone.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_bindings_static_connections.lua

local T = require("testlib")

local bindings = require("lib.bindings")

-- Declared by global/handlers.lua, which nothing here loads.
_G.RFP = _G.RFP or {}
_G.OBC = _G.OBC or {}

local ME = C4:GetDeviceID()

-- 5012 is PROXY_BINDING_START and 300 is inside CONTROL 10-999. The digit in
-- "Button Link 12" is what an unscoped scrape of the block reads as an id.
local STATIC_CONNECTIONS = {
  { id = 5001, type = "PROXY", provider = true, name = "Thermostat", class = "THERMOSTAT" },
  { id = 5012, type = "PROXY", provider = true, name = "Humidity", class = "HUMIDITY" },
  { id = 300, type = "CONTROL", provider = false, name = "Button Link 12", class = "BUTTON_LINK" },
}

local function liveBinding(bindingId)
  for _, record in ipairs(C4:GetBindingsByDevice(ME).bindings or {}) do
    if record.bindingid == bindingId then
      return record
    end
  end
end

--------------------------------------------------------------------------------
T.section("restoring over a driver that declares static connections")
do
  bindings:reset()
  ShimResetDynamicBindings()
  ShimSetStaticBindings(STATIC_CONNECTIONS)

  local stored = bindings:getOrAddDynamicBinding("ns", "relay", "CONTROL", true, "Relay", "RELAY")
  -- Added outside the lib, so they are live but not in its store.
  C4:AddDynamicBinding(12, "CONTROL", true, "Stale", "RELAY")
  C4:AddDynamicBinding(20, "CONTROL", true, "Stale", "RELAY")
  C4:AddDynamicBinding(5500, "PROXY", true, "Stale", "HUMIDITY")

  bindings:restoreBindings()

  T.truthy("the stored binding is restored", liveBinding(stored.bindingId))
  T.truthy("a static connection at the proxy range start survives", liveBinding(5012))
  T.truthy("a static connection inside the control range survives", liveBinding(300))
  T.truthy("a static connection below the proxy range survives", liveBinding(5001))
  T.falsy("an unknown binding inside the proxy range is removed", liveBinding(5500))
  T.falsy("an unknown binding inside the control range is removed", liveBinding(20))
  T.falsy("a digit inside a connection name is not read as a connection id", liveBinding(12))
end

--------------------------------------------------------------------------------
T.section("restoring over a driver that declares none")
do
  bindings:reset()
  ShimResetDynamicBindings()
  ShimSetStaticBindings({})

  C4:AddDynamicBinding(300, "CONTROL", false, "Button Link 12", "BUTTON_LINK")
  bindings:restoreBindings()

  T.falsy("the id kept above is swept once it is undeclared", liveBinding(300))
end

T.finish()
