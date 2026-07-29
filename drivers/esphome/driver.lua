--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-esphome"
DRIVER_FILENAMES = {
  "esphome.c4z",
  "esphome_bluetooth_coordinator.c4z",
  "esphome_govee.c4z",
  "esphome_bthome.c4z",
  -- #variant-filenames esphome_fan
  "esphome_climate.c4z",
  "esphome_light.c4z",
  "esphome_lock.c4z",
  "esphome_switchbot.c4z",
  "esphome_yale.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

local log = require("lib.logging")
local bindings = require("lib.bindings")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif
local values = require("lib.values")

local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local LocalScannerNode = require("esphome.ble.local_scanner_node")

local bleScanner = require("esphome.ble.scanner")
local bleScannerProperties = require("esphome.ble.scanner_properties")

local BluetoothProxyCapability = require("esphome.capabilities.bluetooth_proxy")

local BinarySensorEntity = require("esphome.entities.binary_sensor")
local ButtonEntity = require("esphome.entities.button")
local ClimateEntity = require("esphome.entities.climate")
local CoverEntity = require("esphome.entities.cover")
local DateEntity = require("esphome.entities.date")
local DateTimeEntity = require("esphome.entities.datetime")
local EventEntity = require("esphome.entities.event")
local FanEntity = require("esphome.entities.fan")
local LightEntity = require("esphome.entities.light")
local LockEntity = require("esphome.entities.lock")
local NumberEntity = require("esphome.entities.number")
local SensorEntity = require("esphome.entities.sensor")
local SwitchEntity = require("esphome.entities.switch")
local SelectEntity = require("esphome.entities.select")
local TextEntity = require("esphome.entities.text")
local TextSensorEntity = require("esphome.entities.text_sensor")
local TimeEntity = require("esphome.entities.time")
local WaterHeaterEntity = require("esphome.entities.water_heater")

local constants = require("constants")

local esphome = ESPHomeClient:new()
local localScannerNode = LocalScannerNode:new(esphome)

bleScanner:addNode(localScannerNode)

local bluetoothProxyCapability = BluetoothProxyCapability:new(esphome)

--- @type table<EntityType, Entity>
local Entities = {
  [BinarySensorEntity.TYPE] = BinarySensorEntity:new(esphome),
  [ButtonEntity.TYPE] = ButtonEntity:new(esphome),
  [ClimateEntity.TYPE] = ClimateEntity:new(esphome),
  [CoverEntity.TYPE] = CoverEntity:new(esphome),
  [DateEntity.TYPE] = DateEntity:new(esphome),
  [DateTimeEntity.TYPE] = DateTimeEntity:new(esphome),
  [EventEntity.TYPE] = EventEntity:new(esphome),
  [FanEntity.TYPE] = FanEntity:new(esphome),
  [LightEntity.TYPE] = LightEntity:new(esphome),
  [LockEntity.TYPE] = LockEntity:new(esphome),
  [NumberEntity.TYPE] = NumberEntity:new(esphome),
  [SelectEntity.TYPE] = SelectEntity:new(esphome),
  [SensorEntity.TYPE] = SensorEntity:new(esphome),
  [SwitchEntity.TYPE] = SwitchEntity:new(esphome),
  [TextEntity.TYPE] = TextEntity:new(esphome),
  [TextSensorEntity.TYPE] = TextSensorEntity:new(esphome),
  [TimeEntity.TYPE] = TimeEntity:new(esphome),
  [WaterHeaterEntity.TYPE] = WaterHeaterEntity:new(esphome),
}

--- Get all ESPHome driver instances sorted by device ID
--- @return integer[] deviceIds Sorted list of device IDs
local function getESPHomeDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  --- @type integer[]
  local ids = {}
  for id, _ in pairs(drivers) do
    table.insert(ids, tointeger(id))
  end
  table.sort(ids)
  return ids
end

--- Sync a property value to all other ESPHome driver instances
--- Only syncs if the other instance has a different value (avoids infinite loops)
--- @param propertyName string The property name to sync
--- @param propertyValue string The property value to sync
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local ids = getESPHomeDriverIds()
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(ids) do
    if deviceId ~= myId then
      log:info("Syncing property '%s' = '%s' to device %d", propertyName, propertyValue, deviceId)
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore persisted state
  values:restoreValues()
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  -- Firmware version is usually an entity and will be picked up by state updates
  C4:SetPropertyAttribs("Firmware Version", constants.HIDE_PROPERTY)

  -- Hide Bluetooth Proxy properties until we detect support
  bluetoothProxyCapability:setPropertiesAttribs(constants.HIDE_PROPERTY)

  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end
  gInitialized = true
  Connect()
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    -- If log mode is disabled and we're subscribed to logs, disconnect to stop logs
    if esphome:isLogsSubscribed() then
      esphome:disconnect()
    end
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
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
  -- If subscribed to logs, disconnect to resubscribe at new level
  if esphome:isLogsSubscribed() then
    esphome:disconnect()
  end
end

function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  if not gInitialized then
    return
  end
  Connect()
end

function OPC.Port(propertyValue)
  log:trace("OPC.Port('%s')", propertyValue)
  if not gInitialized then
    return
  end
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
  if not gInitialized then
    return
  end
  Connect()
end

function OPC.Password(propertyValue)
  log:trace("OPC.Password('%s')", not IsEmpty(propertyValue) and "****" or "")
  if not gInitialized then
    return
  end
  Connect()
end

function OPC.Encryption_Key(propertyValue)
  log:trace("OPC.Encryption_Key('%s')", not IsEmpty(propertyValue) and "****" or "")
  if not gInitialized then
    return
  end
  Connect()
end

function OPC.Use_OpenSSL(propertyValue)
  log:trace("OPC.Use_OpenSSL('%s')", propertyValue)
  if not gInitialized then
    return
  end
  Connect()
end

--- Map ESPHome log levels to driver log methods
--- @type table<ProtoLogLevel, fun(log: Log, format: string, ...: any)>
local ESPHOME_LOG_LEVEL_MAP = {
  [ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_ERROR] = log.error,
  [ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_WARN] = log.warn,
  [ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_INFO] = log.info,
  [ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_CONFIG] = log.info,
  [ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_DEBUG] = log.debug,
  [ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_VERBOSE] = log.trace,
  [ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_VERY_VERBOSE] = log.ultra,
}

--- Map driver log level (0-6) to ESPHome log level for subscription.
--- Driver levels: 0-Fatal, 1-Error, 2-Warning, 3-Info, 4-Debug, 5-Trace, 6-Ultra
--- ESPHome levels: 0-NONE, 1-ERROR, 2-WARN, 3-INFO, 4-CONFIG, 5-DEBUG, 6-VERBOSE, 7-VERY_VERBOSE
--- @type table<integer, ProtoLogLevel?>
local DRIVER_TO_ESPHOME_LOG_LEVEL = {
  [0] = ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_ERROR, -- Fatal -> ERROR
  [1] = ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_ERROR, -- Error -> ERROR
  [2] = ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_WARN, -- Warning -> WARN
  [3] = ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_INFO, -- Info -> INFO
  [4] = ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_DEBUG, -- Debug -> DEBUG
  [5] = ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_VERBOSE, -- Trace -> VERBOSE
  [6] = ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_VERY_VERBOSE, -- Ultra -> VERY_VERBOSE
}

--- Strip ANSI escape codes from a string.
--- @param str string The string to strip
--- @return string stripped The string without ANSI codes
local function stripAnsiCodes(str)
  -- Match ANSI escape sequences: ESC [ ... m (where ... is digits/semicolons)
  return (str:gsub("\027%[[0-9;]*m", ""))
end

--- Subscribe to ESPHome device logs and forward them to the driver log.
--- Uses the current driver log level to determine ESPHome subscription level.
local function subscribeToDeviceLogs()
  if not esphome:isConnected() then
    log:debug("Cannot subscribe to device logs: not connected")
    return
  end

  -- Map driver log level to ESPHome log level
  local driverLevel = log:getLogLevel()
  local esphomeLevel = DRIVER_TO_ESPHOME_LOG_LEVEL[driverLevel] or ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_DEBUG

  esphome
    :subscribeLogs(function(level, message)
      local logMethod = level and ESPHOME_LOG_LEVEL_MAP[level] or log.debug
      logMethod(log, "[ESPHome] %s", stripAnsiCodes(message or ""))
    end, esphomeLevel)
    :next(function()
      log:info("Subscribed to ESPHome device logs at level %d", esphomeLevel)
    end, function(err)
      log:error("Failed to subscribe to device logs: %s", err)
    end)
end

function OPC.Device_Log_Forwarding(propertyValue)
  log:trace("OPC.Device_Log_Forwarding('%s')", propertyValue)
  if not gInitialized then
    return
  end

  if toboolean(propertyValue) and log:isEnabled() then
    subscribeToDeviceLogs()
  elseif esphome:isLogsSubscribed() then
    -- Disconnect to stop the log stream (no API to unsubscribe)
    -- Heartbeat timer will automatically reconnect without log subscription
    esphome:disconnect()
  end
end

function OPC.Select_Bluetooth_Devices(propertyValue)
  log:trace("OPC.Select_Bluetooth_Devices('%s')", propertyValue)
  if not gInitialized then
    return
  end

  bleScannerProperties:handleSelection(BluetoothProxyCapability.PROPERTY_NAME, propertyValue)
end

function OPC.Bluetooth_Scan_Duration(propertyValue)
  log:trace("OPC.Bluetooth_Scan_Duration('%s')", propertyValue)
  bleScanner:setScanDuration(propertyValue)
end

function OPC.Bluetooth_Proxy_Room(propertyValue)
  log:trace("OPC.Bluetooth_Proxy_Room('%s')", propertyValue)
  if not gInitialized then
    return
  end
  -- Notify coordinator of room change
  bluetoothProxyCapability:onRoomChanged()
end

function OPC.Minimum_Room_RSSI_Override_dBm(propertyValue)
  log:trace("OPC.Minimum_Room_RSSI_Override_dBm('%s')", propertyValue)
  if not gInitialized then
    return
  end
  -- Notify coordinator of minRssiOverride change
  bluetoothProxyCapability:onMinRssiOverrideChanged()
end

local function updateStatus(status)
  log:trace("updateStatus(%s)", status)
  UpdateProperty("Driver Status", not IsEmpty(status) and status or "Unknown")
end

--- Backoff period in seconds after a fatal connection error before retrying.
local FATAL_ERROR_BACKOFF = 120

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
  local lastFatalErrorTime = 0 -- Track when the last fatal error occurred
  local wasConnected = false -- Track connection state transitions

  local function notifyEntitiesDisconnected()
    for _, handler in pairs(Entities) do
      if type(handler.disconnected) == "function" then
        local success, err = pcall(handler.disconnected, handler)
        if not success then
          log:error("Entity disconnected handler failed: %s", err or "unknown error")
        end
      end
    end
  end

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

    local connected = esphome:isConnected()
    if wasConnected and not connected then
      log:info("Connection lost, notifying sub-drivers")
      notifyEntitiesDisconnected()
    end
    wasConnected = connected

    local now = os.time()
    local secondsSinceLastUpdate = now - lastUpdateTime
    -- Recompute leader each cycle in case the previous leader was removed
    local isLeaderInstance = Select(getESPHomeDriverIds(), 1) == C4:GetDeviceID()
    -- Only the leader instance (lowest device ID) performs update checks
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) and secondsSinceLastUpdate > (30 * 60) then
      log:info("Checking for driver update (leader instance)")
      lastUpdateTime = now
      UpdateDrivers()
    elseif not esphome:isConnected() then
      -- Check for fatal error and apply backoff
      local fatalError = esphome:getFatalError()
      if fatalError then
        if lastFatalErrorTime == 0 then
          -- First time seeing this error, record the time
          lastFatalErrorTime = now
        end
        local secondsSinceFailure = now - lastFatalErrorTime
        if secondsSinceFailure < FATAL_ERROR_BACKOFF then
          local remaining = FATAL_ERROR_BACKOFF - secondsSinceFailure
          updateStatus(fatalError .. " (retry in " .. remaining .. "s)")
          return
        end
        -- Backoff period elapsed, reset and try again
        lastFatalErrorTime = 0
      end

      updateStatus("Connecting")
      esphome:connect():next(function()
        lastFatalErrorTime = 0 -- Clear on successful connection
        wasConnected = true
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
        values:update("Name", esphome:getDeviceName() or "N/A", "STRING")
        values:update("Model", Select(deviceInfo, "model") or "N/A", "STRING")
        values:update("Manufacturer", Select(deviceInfo, "manufacturer") or "N/A", "STRING")
        values:update("MAC Address", Select(deviceInfo, "mac_address") or "N/A", "STRING")

        bluetoothProxyCapability:discovered(deviceInfo)
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

          -- Detect restart button for scanner recovery
          if entity.entity_type == "button" then
            local buttonName = entity.name or ""
            if buttonName:lower():find("restart") then
              log:info("Found restart button entity: %s", ESPHomeClient.describeEntity(entity))
              bluetoothProxyCapability:setRestartButtonKey(entity.key)
            end
          end
        end

        return entities
      end)
      :next(function(entities)
        return esphome:subscribeStates(function(state, messageSchema)
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
          if IsEmpty(Select(entity, "entity_type")) then
            log:warn("Received state update for unknown entity with key %s", state.key)
            return
          end
          --- @cast entity -nil

          state.key = nil -- Just remove this as its no longer needed

          log:info("State update for %s entity -> %s", ESPHomeClient.describeEntity(entity), state)

          if Entities[entity.entity_type] ~= nil and type(Entities[entity.entity_type].updated) == "function" then
            log:debug("Calling Entities['%s']:updated(%s, %s) handler", entity.entity_type, entity, state)
            local success, ret = xpcall(function()
              Entities[entity.entity_type]:updated(entity, state, messageSchema)
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
        -- Subscribe to device logs if forwarding is enabled and log mode is on
        if toboolean(Properties["Device Log Forwarding"]) and log:isEnabled() then
          subscribeToDeviceLogs()
        end
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

--- Property values for reset.
--- @type table<string, string>
local RESET_PROPERTY_VALUES = {
  ["Driver Status"] = "Reset - Reconnecting...",
  ["Driver Version"] = "",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
  ["Automatic Updates"] = "On",
  ["Update Channel"] = "Production",
  ["Device Log Forwarding"] = "Off",
  ["Use OpenSSL"] = "Yes",
  ["Bluetooth Proxy Status"] = "",
  ["Bluetooth Scan Duration"] = "30",
  ["Name"] = "N/A",
  ["Model"] = "N/A",
  ["Manufacturer"] = "N/A",
  ["MAC Address"] = "N/A",
  ["Firmware Version"] = "N/A",
}

function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  -- Reset all dynamic bindings
  bindings:reset()

  -- Drop the entity notify memos so the recreated bindings are notified on the
  -- next state update instead of deduping against the destroyed ones
  CoverEntity.clearNotifiedState()

  -- Reset all values (variables and properties)
  values:reset()

  -- Reset BLE scanner state
  bleScanner:abortScan()
  bleScanner:reset()

  -- Reset scanner properties (clears device selections)
  bleScannerProperties:reset()

  -- Reset properties to default values
  for propName, defaultValue in pairs(RESET_PROPERTY_VALUES) do
    UpdateProperty(propName, defaultValue, true)
  end

  -- Hide Bluetooth Proxy properties until capability is re-detected
  bluetoothProxyCapability:setPropertiesAttribs(constants.HIDE_PROPERTY)

  -- Hide Firmware Version property (usually comes from entity)
  C4:SetPropertyAttribs("Firmware Version", constants.HIDE_PROPERTY)

  -- Trigger Authentication Mode handler to set correct visibility for
  -- Password, Encryption Key, and Use OpenSSL based on preserved setting
  OnPropertyChanged("Authentication Mode")

  RefreshStatus()
end

-- GATT command handlers for Bluetooth Coordinator
-- These route ExecuteCommand calls to the bluetooth_proxy capability

function EC.GATT_CONNECT(tParams)
  log:trace("EC.GATT_CONNECT(%s)", tParams)
  bluetoothProxyCapability:handleCoordinatorCommand("GATT_CONNECT", tParams)
end

function EC.GATT_DISCONNECT(tParams)
  log:trace("EC.GATT_DISCONNECT(%s)", tParams)
  bluetoothProxyCapability:handleCoordinatorCommand("GATT_DISCONNECT", tParams)
end

function EC.GATT_WRITE(tParams)
  log:trace("EC.GATT_WRITE(%s)", tParams)
  bluetoothProxyCapability:handleCoordinatorCommand("GATT_WRITE", tParams)
end

function EC.GATT_READ(tParams)
  log:trace("EC.GATT_READ(%s)", tParams)
  bluetoothProxyCapability:handleCoordinatorCommand("GATT_READ", tParams)
end

function EC.GATT_NOTIFY(tParams)
  log:trace("EC.GATT_NOTIFY(%s)", tParams)
  bluetoothProxyCapability:handleCoordinatorCommand("GATT_NOTIFY", tParams)
end

--#ifndef DRIVERCENTRAL
-- Action: Update Drivers
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
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
--#endif
