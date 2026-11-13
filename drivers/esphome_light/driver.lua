require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
--#ifndef DRIVERCENTRAL
local mainDriverCatchup = require("esphome.main_driver_catchup")
--#endif

JSON = require("JSON")

local log = require("lib.logging")
--#ifdef DRIVERCENTRAL
local updateSettings = require("lib.update-settings")
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
local values = require("lib.values")
local Light = require("lib.light")
local Types = require("lib.light.types")
local LightAdapter = require("esphome.light_adapter")

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------

local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

---------------------------------------------------------------------------
-- The light
---------------------------------------------------------------------------

local adapter = LightAdapter.new(ESPHOME_BINDING)

local light = Light.new(adapter, {
  api = Types.API,
  proxy = PROXY_BINDING,
  links = { top = 300, toggle = 301, bottom = 302 },
  dims = true,
  color = true,
  cct = true,
  fades = true,
  defaultOn = true,
  scenes = true,
  onModes = true,
  flash = true,
})

-- The entity the light last listed; nil until its first report since a load, bind or disconnect.
local ENTITY

local function updateStatus(status)
  log:trace("updateStatus(%s)", status)
  UpdateProperty("Driver Status", status)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

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
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end
  gInitialized = true
  updateStatus("Disconnected")
  light:start()
  --#ifndef DRIVERCENTRAL
  mainDriverCatchup.schedule()
  --#endif
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

---------------------------------------------------------------------------
-- Property handlers
---------------------------------------------------------------------------

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

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
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

---------------------------------------------------------------------------
-- The ESPHome connection
---------------------------------------------------------------------------

function RFP.UPDATE_STATE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s)", idBinding, strCommand, tParams)
  -- Late init asks for the state again once the light has started.
  if not gInitialized then
    return
  end
  local entity = DeserializeSafe(Select(tParams, "entity"))
  local state = DeserializeSafe(Select(tParams, "state"))
  if IsEmpty(entity) or IsEmpty(state) then
    log:error("RFP.UPDATE_STATE called with invalid parameters: %s", tParams)
    return
  end
  if ENTITY == nil then
    adapter:learn(entity)
    light:declare(adapter:device())
    updateStatus("Connected")
  end
  ENTITY = entity
  light:report(adapter:report(entity, state))
end

function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s, %s)", idBinding, strCommand, tParams)
  ENTITY = nil
  adapter:reset()
  updateStatus("Disconnected")
  -- A device that drops off has usually lost power, so it reads off. A suspended one is as it was.
  light:lost(toboolean(Select(tParams, "suspended")))
end

OBC[ESPHOME_BINDING] = function(_idBinding, _strClass, isBound)
  ENTITY = nil
  adapter:reset(not isBound)
  light:lost(true)
  if not isBound then
    updateStatus("Disconnected")
  end
end
