DRIVER_GITHUB_REPO = "finitelabs/control4-esphome"
DRIVER_FILENAMES = {
  "esphome.c4z",
  "esphome_light.c4z",
  "esphome_lock.c4z",
  "esphome_switchbot.c4z",
}
--
--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome.c4z"
--#endif
require("lib.utils")
require("vendor.drivers-common-public.global.handlers")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")
require("vendor.drivers-common-public.global.url")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local githubUpdater = require("lib.github-updater")
local values = require("lib.values")

local ESPHomeClient = require("esphome.client")
local BinarySensorEntity = require("esphome.entities.binary_sensor")
local ButtonEntity = require("esphome.entities.button")
local CoverEntity = require("esphome.entities.cover")
local LightEntity = require("esphome.entities.light")
local LockEntity = require("esphome.entities.lock")
local NumberEntity = require("esphome.entities.number")
local SensorEntity = require("esphome.entities.sensor")
local SwitchEntity = require("esphome.entities.switch")
local TextEntity = require("esphome.entities.text")
local TextSensorEntity = require("esphome.entities.text_sensor")

local constants = require("constants")

local esphome = ESPHomeClient:new()

--- @type table<EntityType, Entity>
local Entities = {
  [BinarySensorEntity.TYPE] = BinarySensorEntity:new(esphome),
  [ButtonEntity.TYPE] = ButtonEntity:new(esphome),
  [CoverEntity.TYPE] = CoverEntity:new(esphome),
  [LightEntity.TYPE] = LightEntity:new(esphome),
  [LockEntity.TYPE] = LockEntity:new(esphome),
  [NumberEntity.TYPE] = NumberEntity:new(esphome),
  [SensorEntity.TYPE] = SensorEntity:new(esphome),
  [SwitchEntity.TYPE] = SwitchEntity:new(esphome),
  [TextEntity.TYPE] = TextEntity:new(esphome),
  [TextSensorEntity.TYPE] = TextSensorEntity:new(esphome),
}

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("vendor.cloud-client-byte")
  C4:AllowExecute(false)
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

  -- Firmaware version is usually an entity and will be picked up by state updates
  C4:SetPropertyAttribs("Firmware Version", constants.HIDE_PROPERTY)

  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")
  bindings:restoreBindings()
  values:restoreValues()

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err ~= nil then
      log:error(err)
    end
  end
  gInitialized = true
  Connect()
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
  end
end

function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  Connect()
end

function OPC.Port(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  Connect()
end

function OPC.Authentication_Mode(propertyValue)
  log:trace("OPC.Authentication_Mode('%s')", propertyValue)
  if propertyValue == "None" then
    UpdateProperty("Password", "")
    UpdateProperty("Encryption Key", "")
    C4:SetPropertyAttribs("Password", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Encryption Key", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Use OpenSSL", constants.HIDE_PROPERTY)
  end
  if propertyValue == "Password" then
    UpdateProperty("Encryption Key", "")
    C4:SetPropertyAttribs("Password", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Encryption Key", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Use OpenSSL", constants.HIDE_PROPERTY)
  end
  if propertyValue == "Encryption Key" then
    UpdateProperty("Password", "")
    C4:SetPropertyAttribs("Password", constants.HIDE_PROPERTY)
    C4:SetPropertyAttribs("Encryption Key", constants.SHOW_PROPERTY)
    C4:SetPropertyAttribs("Use OpenSSL", constants.SHOW_PROPERTY)
  end
  Connect()
end

function OPC.Password(propertyValue)
  log:trace("OPC.Password('%s')", not IsEmpty(propertyValue) and "****" or "")
  Connect()
end

function OPC.Encryption_Key(propertyValue)
  log:trace("OPC.Encryption_Key('%s')", not IsEmpty(propertyValue) and "****" or "")
  Connect()
end

function OPC.Use_OpenSSL(propertyValue)
  log:trace("OPC.Use_OpenSSL('%s')", propertyValue)
  Connect()
end

local function updateStatus(status)
  UpdateProperty("Driver Status", not IsEmpty(status) and status or "Unknown")
end

function Connect()
  log:trace("Connect()")
  if not gInitialized then
    updateStatus("Initializing...")
    return
  end

  esphome:setConfig(
    Properties["IP Address"],
    Properties["Port"],
    Properties["Password"],
    Properties["Encryption Key"],
    Properties["Use OpenSSL"] == "Yes"
  )

  local lastUpdateTime = os.time() -- Don't check for updates on the first cycle

  local heartbeat = function()
    --#ifdef DRIVERCENTRAL
    if DC_X == 0 then
      updateStatus("No active license")
      esphome:disconnect()
      return
    end
    --#endif
    if not esphome:isConfigured() then
      updateStatus("Not configured")
      esphome:disconnect()
      CancelTimer("heartbeat")
      return
    end

    local now = os.time()
    local secondsSinceLastUpdate = now - lastUpdateTime
    if toboolean(Properties["Automatic Updates"]) and secondsSinceLastUpdate > (30 * 60) then
      log:info("Checking for driver update (timer expired)")
      lastUpdateTime = now
      UpdateDrivers()
    elseif not esphome:isConnected() then
      updateStatus("Connecting")
      esphome:connect():next(function()
        -- If using password authentication, show "waiting for authentication" status
        -- until first successful operation confirms auth succeeded
        if Properties["Authentication Mode"] == "Password" and not IsEmpty(Properties["Password"]) then
          updateStatus("Connection established, waiting for authentication")
        else
          updateStatus("Connected")
        end
        RefreshStatus()
      end, function(reason)
        updateStatus("Connection failed: " .. reason)
      end)
    else
      updateStatus("Connected")
    end
  end
  -- Perform the initial refresh then schedule it on a repeating timer
  SetTimer("heartbeat", 10 * ONE_SECOND, heartbeat, true)
  heartbeat()
end

function RefreshStatus()
  log:trace("RefreshStatus()")
  -- Debounce the status refresh calls
  SetTimer("RefreshStatus", ONE_SECOND * 3, function()
    esphome
      :getDeviceInfo()
      :next(function(deviceInfo)
        log:debug("Device Info: %s", deviceInfo)
        -- First successful operation confirms authentication succeeded
        updateStatus("Connected")
        values:update("Name", Select(deviceInfo, "friendly_name") or Select(deviceInfo, "name") or "N/A", "STRING")
        values:update("Model", Select(deviceInfo, "model") or "N/A", "STRING")
        values:update("Manufacturer", Select(deviceInfo, "manufacturer") or "N/A", "STRING")
        values:update("MAC Address", Select(deviceInfo, "mac_address") or "N/A", "STRING")
      end)
      :next(function()
        return esphome:listEntities()
      end)
      :next(function(entities)
        -- Call registered handler for each entity type
        for _, entity in pairs(entities) do
          if Entities[entity.entity_type] ~= nil and type(Entities[entity.entity_type].discovered) == "function" then
            log:debug("Calling Entities['%s']:discovered(%s) handler", entity.entity_type, entity)
            local success, ret = xpcall(function()
              Entities[entity.entity_type]:discovered(entity)
            end, debug.traceback)
            local errMessage = ""
            if not success then
              if type(ret) == "string" and ret ~= "" then
                errMessage = errMessage .. "; " .. ret
              end
              log:error("Entities['%s']:discovered() handler failed%s", entity.entity_type, errMessage)
            end
          else
            log:debug("No Entities['%s']:discovered() handler", entity.entity_type)
          end
        end

        return entities
      end)
      :next(function(entities)
        return esphome:subscribeStates(function(state)
          local key = Select(state, "key")
          if type(key) ~= "number" then
            log:warn("Received state update with an invalid key: %s", state)
            return
          end
          if toboolean(Select(state, "missing_state")) then
            log:debug("Received a missing state update for key %s", key)
            return
          end

          local entity = Select(entities, tostring(key))
          if IsEmpty(Select(entity, "entity_type")) or IsEmpty(Select(entity, "object_id")) then
            log:warn("Received state update for unknown entity with key %s", state.key)
            return
          end
          --- @cast entity -nil

          state.key = nil -- Just remove this as its no longer needed

          log:info("State update for %s.%s entity -> %s", entity.entity_type, entity.object_id, state)

          if Entities[entity.entity_type] ~= nil and type(Entities[entity.entity_type].updated) == "function" then
            log:debug("Calling Entities['%s']:updated(%s, %s) handler", entity.entity_type, entity, state)
            local success, ret = xpcall(function()
              Entities[entity.entity_type]:updated(entity, state)
            end, debug.traceback)
            local errMessage = ""
            if not success then
              if type(ret) == "string" and ret ~= "" then
                errMessage = errMessage .. "; " .. ret
              end
              log:error("Entities['%s']:updated() handler failed%s", entity.entity_type, errMessage)
            end
          else
            log:debug("No Entities['%s']:updated() handler", entity.entity_type)
          end
        end)
      end)
      :next(function()
        log:info("Successfully refreshed device status")
      end, function(error)
        if type(error) ~= "string" then
          error = "unknown error"
        end
        log:error("An error occurred refreshing device status; %s", error)
        updateStatus("Refresh failed: " .. error)
        esphome:disconnect()
      end)
  end)
end

function EC.ResetConnectionsAndVariables(params)
  log:trace("EC.ResetConnectionsAndVariables(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting connections and variables")

  for ns, nsBindings in pairs(bindings:getBindings()) do
    for bindingKey, binding in pairs(nsBindings) do
      log:info("Deleting connection '%s'", binding.displayName)
      bindings:deleteBinding(ns, bindingKey)
    end
  end

  for name, _ in pairs(Variables or {}) do
    log:info("Deleting variable '%s'", name)
    values:delete(name)
  end

  RefreshStatus()
end

function EC.UpdateDrivers()
  log:trace("EC.UpdateDrivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

-- Switchbot Bluetooth Proxy Support
-- Track connected Switchbot devices
local switchbotDevices = {}

--- Handle Switchbot connection request from sub-driver
function RFP.SWITCHBOT_CONNECT(idBinding, strCommand, tParams, args)
  log:trace("RFP.SWITCHBOT_CONNECT(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)

  local address = tonumber(Select(tParams, "address"))
  if not address then
    log:error("SWITCHBOT_CONNECT: Invalid address")
    return
  end

  log:info("Connecting to Switchbot device at address 0x%012X", address)

  -- Initialize device tracking
  if not switchbotDevices[address] then
    switchbotDevices[address] = {
      bindingId = idBinding,
      connected = false,
      services = nil,
    }
  else
    switchbotDevices[address].bindingId = idBinding
  end

  -- Connect to the device
  esphome:bluetoothDeviceConnect(
    address,
    function(message, schema)
      log:debug("Switchbot connection response: connected=%s, mtu=%s, error=%s", message.connected, message.mtu, message.error)

      if message.connected then
        switchbotDevices[address].connected = true

        -- Discover GATT services
        esphome:bluetoothGattGetServices(address, function(services, done)
          if done then
            log:info("Switchbot GATT service discovery complete")

            -- Send connection success to sub-driver with services
            SendToProxy(idBinding, "SWITCHBOT_CONNECTED", {
              connected = "true",
              services = Serialize(switchbotDevices[address].services or {}),
            }, "NOTIFY")
          else
            -- Accumulate services
            if not switchbotDevices[address].services then
              switchbotDevices[address].services = {}
            end
            for _, service in ipairs(services) do
              table.insert(switchbotDevices[address].services, service)
            end
            log:debug("Received %d GATT services for Switchbot", #services)
          end
        end)
      else
        log:error("Failed to connect to Switchbot: error=%s", message.error)
        switchbotDevices[address].connected = false

        -- Send connection failure to sub-driver
        SendToProxy(idBinding, "SWITCHBOT_CONNECTED", {
          connected = "false",
          services = Serialize({}),
        }, "NOTIFY")
      end
    end,
    nil,
    true
  )
end

--- Handle Switchbot write request from sub-driver
function RFP.SWITCHBOT_WRITE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SWITCHBOT_WRITE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)

  local address = tonumber(Select(tParams, "address"))
  local handle = tonumber(Select(tParams, "handle"))
  local data = Deserialize(Select(tParams, "data"))

  if not address or not handle or not data then
    log:error("SWITCHBOT_WRITE: Invalid parameters (address=%s, handle=%s, data=%s)", address, handle, data)
    return
  end

  if not switchbotDevices[address] or not switchbotDevices[address].connected then
    log:error("SWITCHBOT_WRITE: Device not connected")
    SendToProxy(idBinding, "SWITCHBOT_WRITE_RESPONSE", {
      success = "false",
    }, "NOTIFY")
    return
  end

  log:debug("Writing %d bytes to Switchbot handle %d", #data, handle)

  esphome:bluetoothGattWrite(address, handle, data, true, function(success, error)
    log:debug("Switchbot write %s", success and "successful" or "failed")

    SendToProxy(idBinding, "SWITCHBOT_WRITE_RESPONSE", {
      success = success and "true" or "false",
    }, "NOTIFY")
  end)
end

--- Handle Switchbot read request from sub-driver
function RFP.SWITCHBOT_READ(idBinding, strCommand, tParams, args)
  log:trace("RFP.SWITCHBOT_READ(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)

  local address = tonumber(Select(tParams, "address"))
  local handle = tonumber(Select(tParams, "handle"))

  if not address or not handle then
    log:error("SWITCHBOT_READ: Invalid parameters (address=%s, handle=%s)", address, handle)
    return
  end

  if not switchbotDevices[address] or not switchbotDevices[address].connected then
    log:error("SWITCHBOT_READ: Device not connected")
    return
  end

  log:debug("Reading from Switchbot handle %d", handle)

  esphome:bluetoothGattRead(address, handle, function(data, error)
    if error then
      log:error("Switchbot read failed: error=%s", error)
    else
      log:debug("Switchbot read successful: %d bytes", #data)
      SendToProxy(idBinding, "SWITCHBOT_READ_RESPONSE", {
        data = Serialize(data),
      }, "NOTIFY")
    end
  end)
end

--- Update the driver from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if the driver is up to date (optional).
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers: %s", error)
    end)
end
