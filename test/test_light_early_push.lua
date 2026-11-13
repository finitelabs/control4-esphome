-- A state the ESPHome driver pushes before the light's late init must not leave Driver Status at Disconnected
-- while the light is online.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_light_early_push.lua
--
-- The ESPHome driver forwards a light's state as soon as it has one, which can be before this driver's
-- OnDriverLateInit. Late init writes Disconnected and starts the light, whose refresh brings the state back,
-- so a push before it is dropped and the refresh's answer writes Connected.

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local P = require("light_proxy_fake")
local D = require("light_drivers")
local ColorMode = require("esphome.proto_schema").Enum.ColorMode

local ESPHOME = 5002
local root = D.root()
local driverPath = root .. "/drivers/esphome_light/driver.lua"
local rig = require("light_rigs").rigs.esphome_light[5]
T.eq("the rig is the RGB one", rig.name, "RGB")
rig.folder = "esphome_light"

--- Load the driver on the RGB rig, optionally with a state push just before late init.
--- @param early boolean Push a state before OnDriverLateInit.
--- @param source string|nil The driver's source to load in place of the file.
--- @return string[] statuses Each Driver Status written, in order.
--- @return string|nil status The last Driver Status written.
local function load(early, source)
  local clock = F.virtualClock()
  local proxy = P.install(clock, {})
  local xml = D.xml(root, "esphome_light") or ""
  D.seedProperties(xml)
  local restoreConfig = D.answerConfig(xml)

  local statuses = {}
  local update = UpdateProperty
  UpdateProperty = function(name, value, ...)
    if name == "Driver Status" then
      statuses[#statuses + 1] = tostring(value)
    end
    return update(name, value, ...)
  end
  local lateInit = ShimLateInit
  ShimLateInit = function(...)
    if early then
      local entity = { key = 1, name = "Light", supported_color_modes = { ColorMode.COLOR_MODE_RGB } }
      local state =
        { state = true, brightness = 0.5, color_mode = ColorMode.COLOR_MODE_RGB, red = 1, green = 0, blue = 0 }
      ReceivedFromProxy(ESPHOME, "UPDATE_STATE", { entity = SerializeSafe(entity), state = SerializeSafe(state) })
    end
    return lateInit(...)
  end
  local realDofile = dofile
  if source then
    dofile = function(path, ...)
      if path:match("/drivers/esphome_light/driver%.lua$") then
        return assert(loadstring(source, "driver.lua"))()
      end
      return realDofile(path, ...)
    end
  end

  local ok, err = pcall(rig.load, { clock = clock, proxy = proxy }, nil)
  dofile, ShimLateInit = realDofile, lateInit
  T.check("the driver loads", ok, err)
  clock.run(17000)
  UpdateProperty = update
  local status = statuses[#statuses]
  restoreConfig()
  proxy:restore()
  clock.restore()
  return statuses, status
end

T.section("a push before late init")
local statuses, status = load(true)
T.eq("Driver Status ends Connected", status, "Connected")
T.eq("after late init's Initializing and Disconnected", statuses, { "Initializing", "Disconnected", "Connected" })

T.section("no push before late init, the control")
statuses, status = load(false)
T.eq("Driver Status ends Connected", status, "Connected")
T.eq("the same writes", statuses, { "Initializing", "Disconnected", "Connected" })

T.section("without the guard, the push leaves Driver Status Disconnected")
local fh = assert(io.open(driverPath, "r"))
local src = fh:read("*a")
fh:close()
local guard = "  -- Late init asks for the state again once the light has started.\n"
  .. "  if not gInitialized then\n    return\n  end\n"
local at = src:find(guard, 1, true)
T.check("the guard was found", at ~= nil, "no match")
local unguarded = at and (src:sub(1, at - 1) .. src:sub(at + #guard)) or src
statuses, status = load(true, unguarded)
T.eq("Driver Status ends Disconnected", status, "Disconnected")

T.finish()
