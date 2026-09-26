-- A stored binding with no name in lib/bindings.lua. Older esphome builds saved
-- one for an unnamed entity, and C4:AddDynamicBinding raises on a nil name, so
-- every restoreBindings() stopped there: the bindings after it were not added and
-- the sweep of unknown ones never ran.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_bindings_unnamed.lua

local T = require("testlib")

local persist = require("lib.persist")
local bindings = require("lib.bindings")

-- Declared by global/handlers.lua, which nothing here loads.
_G.RFP = _G.RFP or {}
_G.OBC = _G.OBC or {}

local ME = C4:GetDeviceID()

local function liveName(bindingId)
  for _, record in ipairs(C4:GetBindingsByDevice(ME).bindings or {}) do
    if record.bindingid == bindingId then
      return record.name
    end
  end
end

--------------------------------------------------------------------------------
T.section("restoring a stored binding with no name")
do
  ShimResetDynamicBindings()
  ShimSetStaticBindings({})
  persist:set("ConnectionBindings", {
    switch = {
      kitchen = {
        key = "kitchen",
        bindingId = 5012,
        type = "PROXY",
        provider = true,
        displayName = "Kitchen",
        class = "RELAY",
      },
      -- As the esphome build saved it: every field but the name.
      unnamed = { key = "unnamed", bindingId = 5013, type = "PROXY", provider = true, class = "RELAY" },
      porch = {
        key = "porch",
        bindingId = 5014,
        type = "PROXY",
        provider = true,
        displayName = "Porch",
        class = "RELAY",
      },
    },
  })

  local ok, err = pcall(bindings.restoreBindings, bindings)
  T.check("restore does not raise", ok, err)
  T.eq("every named binding is added", { liveName(5012), liveName(5014) }, { "Kitchen", "Porch" })

  local named = bindings:getOrAddDynamicBinding("switch", "unnamed", "PROXY", true, "Hall", "RELAY")
  T.eq("the driver naming it adds it at its id", { named and named.bindingId, liveName(5013) }, { 5013, "Hall" })
end

T.finish()
