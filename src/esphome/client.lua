--- ESPHome API Client for Control4.
--- This module provides a Lua implementation for connecting to ESPHome devices
--- using the native API protocol over TCP with protobuf encoding.
--- Supports both plaintext and encrypted (Noise protocol) communication.

local bit16 = require("bitn").bit16
local pb = require("protobuf")
local deferred = require("deferred")
local noise = require("noiseprotocol")

local log = require("lib.logging")

local ESPHomeProtoSchema = require("esphome.proto_schema")
local BLEAdvertisementParser = require("esphome.ble.parsers.advertisement")
local BLEAddress = require("esphome.ble.address")

local NULL_BYTE = "\x00"

--- @enum NoiseProtocolCallbackKey
local NoiseProtocolCallbackKey = {
  HELLO = "noise_hello",
  HANDSHAKE = "noise_handshake",
}

--- @enum NoiseState
local NoiseState = {
  HELLO = "hello",
  HANDSHAKE = "handshake",
  READY = "ready",
  ERROR = "error",
}

--- @enum Indicator
local Indicator = {
  PLAINTEXT = "\x00",
  NOISE = "\x01",
}

--- @alias CallbackKey string A key for identifying callbacks (message ID or composite)
--- @alias CallbackFunction fun(message: table<string, any>, schema?: ProtoMessageSchema): void

--- @class CallbackEntry
--- @field callback CallbackFunction The callback function to invoke
--- @field timer C4LuaTimer|nil Optional timeout timer for auto-unregistration

--- A class representing the ESPHome API client.
--- @class ESPHomeClient
--- @field EntityType EntityType
--- @field _client C4TCPClient|nil The TCP client for the ESPHome connection.
--- @field _connected boolean Indicates if the client is connected.
--- @field _ipAddress string|nil The IP address of the ESPHome device.
--- @field _port number The port of the ESPHome device.
--- @field _password string|nil The password for the ESPHome device.
--- @field _encryptionKey string|nil The encryption key for the ESPHome device.
--- @field _buffer string The buffer for incoming data.
--- @field _callbacks table<CallbackKey, CallbackEntry?> Registered callbacks keyed by message ID or composite key.
--- @field _pingTimer C4LuaTimer|nil The timer for sending ping messages.
--- @field _hs NoiseConnection|nil The Noise protocol connection for encrypted communication.
--- @field _hsState NoiseState|nil The current state of the Noise protocol handshake.
--- @field _fatalError string|nil Fatal error message (e.g., authentication failure).
--- @field _logsSubscribed boolean Whether log subscription is active.
--- @field _btConnections BluetoothConnectionState Cached Bluetooth connection state.
--- @field _btConnectionsCallbacks table<string, fun(state: BluetoothConnectionState)?> Callbacks for Bluetooth connection changes.
--- @field _btScannerState BluetoothScannerState Cached scanner state.
--- @field _btScannerStateCallbacks table<string, fun(state: BluetoothScannerState)?> Callbacks for scanner state changes.
--- @field _btAdvertisementsCallbacks table<string, fun(advertisement: BLEAdvertisement)?> Callbacks for BLE advertisements.
--- @field _btProxyInitDeferred Deferred|nil In-flight deferred for initBluetoothProxy (re-entrancy guard).
--- @field userServices table<string, number> Map of user-defined service names to their numeric keys, populated during listEntities().
local ESPHomeClient = {}
ESPHomeClient.__index = ESPHomeClient

--- @enum EntityType
ESPHomeClient.EntityType = {
  BINARY_SENSOR = "binary_sensor",
  COVER = "cover",
  FAN = "fan",
  LIGHT = "light",
  SENSOR = "sensor",
  SWITCH = "switch",
  TEXT_SENSOR = "text_sensor",
  API_NOISE = "api_noise",
  ESP32_CAMERA = "esp32_camera",
  CLIMATE = "climate",
  NUMBER = "number",
  SELECT = "select",
  SIREN = "siren",
  LOCK = "lock",
  BUTTON = "button",
  MEDIA_PLAYER = "media_player",
  BLUETOOTH_PROXY = "bluetooth_proxy",
  VOICE_ASSISTANT = "voice_assistant",
  ALARM_CONTROL_PANEL = "alarm_control_panel",
  TEXT = "text",
  DATETIME_DATE = "datetime_date",
  DATETIME_TIME = "datetime_time",
  EVENT = "event",
  VALVE = "valve",
  DATETIME_DATETIME = "datetime_datetime",
  UPDATE = "update",
  WATER_HEATER = "water_heater",
}

--- @class BluetoothConnectionState
--- @field free number Number of available connection slots
--- @field limit number Maximum number of connection slots
--- @field allocated string[] Array of MAC addresses (as "AA:BB:CC:DD:EE:FF" strings) currently connected
--- @field initialized boolean Whether the subscription has been set up

--- @class BluetoothScannerState
--- @field state ProtoBluetoothScannerState BluetoothScannerState enum value
--- @field mode ProtoBluetoothScannerMode BluetoothScannerMode enum value
--- @field initialized boolean Whether state has been received from ESPHome

--- Create a new instance of the ESPHomeClient.
--- @return ESPHomeClient client A new instance of the ESPHomeClient client.
function ESPHomeClient:new()
  log:trace("ESPHomeClient:new()")
  local instance = setmetatable({}, self)
  instance._client = nil
  instance._connected = false
  instance._ipAddress = nil
  instance._port = 6053
  instance._password = nil
  instance._encryptionKey = nil
  instance._buffer = ""
  instance._callbacks = {}
  instance._pingTimer = nil
  instance._hs = nil
  instance._hsState = nil
  instance._fatalError = nil
  instance._logsSubscribed = false
  instance._btConnections = { free = 0, limit = 0, allocated = {}, initialized = false }
  instance._btConnectionsCallbacks = {}
  instance._btScannerState = {
    state = ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_IDLE,
    mode = ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE,
    initialized = false,
  }
  instance._btScannerStateCallbacks = {}
  instance._btAdvertisementsCallbacks = {}
  instance._btProxyInitDeferred = nil
  instance.userServices = {}
  return instance
end

--- Parse the base64 encoded encryption key to 32-byte binary data.
--- @param encryptionKey string? The base64 encoded encryption key.
--- @return string|nil decodedEncryptionKey The decoded encryption key as a 32-byte binary string, or nil if invalid.
local function parseEncryptionKey(encryptionKey)
  if IsEmpty(encryptionKey) then
    return nil
  end

  if type(encryptionKey) ~= "string" then
    log:warn("Invalid encryption key type (expected string, got %s)", type(encryptionKey))
    return nil
  end

  local success, decodedEncryptionKey = pcall(C4.Base64Decode, C4, encryptionKey)
  if not success then
    log:warn("Invalid encryption key format (expected base64 encoded string)")
    return nil
  end

  if #decodedEncryptionKey ~= 32 then
    log:warn("Invalid encryption key length (expected 32 bytes, got %d bytes)", #decodedEncryptionKey)
    return nil
  end

  return decodedEncryptionKey
end

--- Set the configuration for the ESPHome API client. If the client is already
--- connected, it will disconnect before setting the configuration.
--- @param ipAddress string The IP address of the ESPHome device.
--- @param port number The port of the ESPHome device.
--- @param password? string The password for the ESPHome device (optional).
--- @param encryptionKey? string The encryption key for the ESPHome device (optional).
--- @param useOpenssl? boolean
--- @return ESPHomeClient self The ESPHomeClient instance.
function ESPHomeClient:setConfig(ipAddress, port, password, encryptionKey, useOpenssl)
  log:trace(
    "ESPHomeClient:setConfig(%s, %s, %s, %s)",
    ipAddress,
    port,
    password and "***" or nil,
    encryptionKey and "***" or nil
  )
  noise.use_openssl(toboolean(useOpenssl))
  self:disconnect()
  self._ipAddress = not IsEmpty(ipAddress) and ipAddress or nil
  self._port = toport(port) or 6053
  self._password = not IsEmpty(password) and password or nil
  self._encryptionKey = parseEncryptionKey(encryptionKey)
  self._fatalError = nil -- Clear fatal error when config changes
  return self
end

--- Check if the ESPHome API client is configured with an IP address and port.
--- @return boolean configured True if the client is configured, false otherwise.
function ESPHomeClient:isConfigured()
  log:trace("ESPHomeClient:isConfigured()")
  return not IsEmpty(self._ipAddress) and toport(self._port) ~= nil
end

--- Check if the client is connected to the ESPHome device.
--- @return boolean connected True if the client is connected, false otherwise.
function ESPHomeClient:isConnected()
  log:trace("ESPHomeClient:isConnected()")
  return self._client ~= nil and self._connected
end

--- Get the fatal error message if one occurred (e.g., authentication failure).
--- @return string|nil error The fatal error message, or nil if no fatal error.
function ESPHomeClient:getFatalError()
  return self._fatalError
end

--- Check if the client is subscribed to device logs.
--- @return boolean subscribed True if subscribed to logs, false otherwise.
function ESPHomeClient:isLogsSubscribed()
  return self._logsSubscribed
end

--- Connect to the ESPHome device.
--- Note: This establishes the TCP connection and exchanges hello/auth messages.
--- It does NOT guarantee authentication succeeded - auth failures are detected
--- asynchronously and will cause subsequent operations to fail.
--- @return Deferred<void, string> result A promise that resolves when the connection is established.
function ESPHomeClient:connect()
  log:trace("ESPHomeClient:connect()")
  --- @type Deferred<void, string>
  local d = deferred.new()

  if not self:isConfigured() then
    return d:reject("ESPHome API not configured")
  end
  --- @cast self._ipAddress -nil
  --- @cast self._port -nil

  if self:isConnected() then
    return d:resolve(nil)
  end

  -- Disconnect to clear any state
  self:disconnect()

  -- Reset fatal error on new connection attempt
  self._fatalError = nil

  -- Initialize Noise protocol state if encryption key is present
  if self._encryptionKey ~= nil then
    log:info("Noise protocol encryption enabled")
  end

  -- Add callbacks for any requests we can expect to receive from the device
  self:_registerCallback(self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.PingRequest), function(message)
    --- @cast message ProtoPingRequest
    log:debug("Received ping request: %s", message)
    self:sendMessage(ESPHomeProtoSchema.Message.PingResponse, {})
  end)
  self:_registerCallback(self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.GetTimeRequest), function(message)
    --- @cast message ProtoGetTimeRequest
    log:debug("Received get time request: %s", message)
    self:sendMessage(ESPHomeProtoSchema.Message.GetTimeResponse, {
      epoch_seconds = os.time(),
    })
  end)
  self:_registerCallback(self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.DisconnectRequest), function(message)
    --- @cast message ProtoDisconnectRequest
    log:warn("Received disconnect request: %s", message)
    self:sendMessage(ESPHomeProtoSchema.Message.DisconnectResponse, {})
    self:disconnect()
  end)

  -- Create a new TCP client
  self._client = C4:CreateTCPClient()
    :OnConnect(function(client)
      log:debug("Connected to ESPHome device at %s:%s", self._ipAddress, self._port)
      self._connected = true

      --- @type Deferred<void, string>
      local dConnect
      if not IsEmpty(self._encryptionKey) then
        dConnect = self
          :sendNoiseHello()
          :next(function()
            log:debug("Noise hello message sent successfully")
            return self:sendHandshake()
          end, function(err)
            log:error("Failed to send noise hello message: %s", err)
            return reject(err)
          end)
          :next(function()
            log:debug("Noise handshake completed")
          end, function(err)
            log:error("Failed to complete Noise Handshake: %s", err)
            return reject(err)
          end)
      else
        log:debug("No encryption key provided, using plaintext protocol")
        dConnect = deferred.new():resolve(nil)
      end

      dConnect
        :next(function()
          log:debug("Sending hello message to ESPHome device")
          -- Send the hello message
          return self:sendHello()
        end)
        :next(function()
          log:debug("Hello message sent successfully")
          -- Only authenticate when not using encryption key
          if IsEmpty(self._encryptionKey) then
            return self:sendAuthenticate()
          end
          log:debug("Skipping authentication request (using Noise encryption)")
          return deferred.new():resolve({})
        end, function(err)
          log:error("Failed to send hello message: %s", err)
          return reject(err)
        end)
        :next(function()
          log:debug("Connection established")

          -- Start ping timer to keep connection alive (only ping when idle)
          self._lastDataReceived = os.time()
          self._pingTimer = C4:SetTimer(15 * ONE_SECOND, function()
            local secondsSinceData = os.time() - (self._lastDataReceived or 0)
            if secondsSinceData < 10 then
              -- Received data recently, connection is alive, skip ping
              log:trace("Skipping ping - received data %ds ago", secondsSinceData)
              return
            end
            self:sendPing():next(nil, function()
              -- Only disconnect if we haven't received data recently
              local secondsSinceData = os.time() - (self._lastDataReceived or 0)
              if secondsSinceData < 10 then
                log:debug("Ignoring ping failure - received data %ds ago", secondsSinceData)
                return
              end
              self:disconnect()
            end)
          end, true)

          d:resolve(true)
        end, function(err)
          log:error("Failed to establish connection: %s", err)
          self:disconnect()
          d:reject(err)
        end)

      -- Start reading data from the socket
      log:debug("Starting to read data from ESPHome device")
      client:ReadUpTo(4096)
    end)
    :OnDisconnect(function()
      log:debug("Disconnected from ESPHome device")
      self:disconnect()
    end)
    :OnError(function(_, errCode, errMsg)
      log:error("ESPHome connection error: %s (%s)", errMsg, errCode)
      self:disconnect()
      d:reject(errMsg)
    end)
    :OnRead(function(client, data)
      -- Ignore stale data from old connections
      if not self._connected or client ~= self._client then
        log:trace("Ignoring %d byte(s) from stale connection", #data)
        return
      end

      -- Track last data received for keepalive logic
      self._lastDataReceived = os.time()

      log:trace("Received %d byte(s) from ESPHome device", #data)
      --log:ultra("Incoming raw data (hex): %s", to_hex(data))
      self._buffer = self._buffer .. data

      self:_processBuffer()

      client:ReadUpTo(4096)
    end)
  -- Connect to the ESPHome device
  log:debug("Connecting to ESPHome device at %s:%s", self._ipAddress, self._port)
  if self._client:Connect(self._ipAddress, self._port) == nil then
    log:error("Failed to connect to ESPHome device at %s:%s", self._ipAddress, self._port)
    self:disconnect()
    d:reject("Failed to connect to ESPHome device")
  end
  return d
end

--- Disconnect from the ESPHome device.
function ESPHomeClient:disconnect()
  log:trace("ESPHomeClient:disconnect()")

  local client = self._client
  local pingTimer = self._pingTimer

  self._connected = false
  self._client = nil
  self._hs = nil
  self._hsState = nil
  self._buffer = ""
  self._logsSubscribed = false

  -- Cancel all callback timers before clearing
  for _, entry in pairs(self._callbacks) do
    if entry and entry.timer then
      entry.timer:Cancel()
    end
  end
  self._callbacks = {}
  self._pingTimer = nil

  -- Reset Bluetooth state so subscriptions can be re-established on reconnect
  -- Note: We keep the callbacks registered by capabilities (they persist across reconnects)
  -- Only reset the cached state which will be refreshed after reconnect
  self._btConnections = { free = 0, limit = 0, allocated = {}, initialized = false }
  self._btScannerState = {
    state = ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_IDLE,
    mode = ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE,
    initialized = false,
  }
  self._btProxyInitDeferred = nil
  self.userServices = {}

  if pingTimer ~= nil then
    pingTimer:Cancel()
  end
  if client ~= nil then
    client:Close()
  end
end

--- Get device information from the ESPHome device.
--- @return Deferred<ProtoDeviceInfoResponse, string> result A promise that resolves with the device information.
function ESPHomeClient:getDeviceInfo()
  log:trace("ESPHomeClient:getDeviceInfo()")
  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.device_info, {})
end

--- Press a button entity by its key.
--- @param key number The button entity key
--- @return Deferred<nil, string> result A promise that resolves when the button is pressed.
function ESPHomeClient:pressButton(key)
  log:trace("ESPHomeClient:pressButton(%s)", key)
  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.button_command, { key = key })
end

--- List entities from the ESPHome device.
--- @return Deferred<table<string, table?>, string> result A promise that resolves with a table of entities.
function ESPHomeClient:listEntities()
  log:trace("ESPHomeClient:listEntities()")
  --- @type Deferred<table<string, table?>, string>
  local d = deferred.new()

  --- @type table<string, table?>
  local entities = {}

  -- Track the callback keys that are added so they can be removed once we receive the done message
  --- @type CallbackKey[]
  local addedCallbackKeys = {}

  for _, schema in pairs(ESPHomeProtoSchema.Message) do
    -- HACK: No reliable way to identify list_entity responses from proto definition.
    local name, _ = schema.name:match("^ListEntities(.+)Response$")
    if not IsEmpty(name) then
      if schema.name == "ListEntitiesDoneResponse" then
        -- Register callback for ListEntitiesDoneResponse with timeout
        local key = self:_registerCallback(
          self:_makeMessageCallbackKey(schema),
          function(_)
            log:debug("Received %d entities: %s", TableLength(entities), entities)
            self:_unregisterCallbacks(addedCallbackKeys)
            d:resolve(entities)
          end,
          10 * ONE_SECOND,
          function()
            self:_unregisterCallbacks(addedCallbackKeys)
            d:reject("Timeout waiting for list entities response")
          end
        )
        table.insert(addedCallbackKeys, key)
      else
        -- HACK: No reliable way to identify entity types from proto definition.
        local entityType = Select(self.EntityType, (Select(schema, "options", "ifdef") or ""):match("^USE_(.+)$"))
        if not IsEmpty(entityType) then
          log:trace("Registering %s entity callback", name)

          local key = self:_registerCallback(self:_makeMessageCallbackKey(schema), function(message)
            log:trace("Received %s entity: %s", entityType, message)
            message.entity_type = entityType
            entities[tostring(message.key)] = message
          end)
          table.insert(addedCallbackKeys, key)
        elseif schema.name == "ListEntitiesServicesResponse" then
          local key = self:_registerCallback(self:_makeMessageCallbackKey(schema), function(message)
            log:debug("Discovered user service: %s (key=%s)", message.name, message.key)
            if not IsEmpty(message.name) and message.key ~= nil then
              self.userServices[message.name] = message.key
            end
          end)
          table.insert(addedCallbackKeys, key)
        else
          log:trace("Unknown entity type for %s (ifdef=%s)", name, Select(schema, "options", "ifdef") or "nil")
        end
      end
    end
  end

  -- Send the list entities request
  self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.list_entities, {}):next(function(_)
    log:debug("List entities message sent successfully")
  end, function(err)
    if IsEmpty(err) or type(err) ~= "string" then
      err = "unknown error"
    end
    log:error("Failed to send list entities message: %s", err)
    d:reject(err)
  end)

  return d
end

--- State responses that are handled separately and should not be registered here.
--- @type table<string, boolean?>
local EXCLUDED_STATE_RESPONSES = {
  BluetoothScannerStateResponse = true, -- Managed in initBluetoothProxy()
  SubscribeHomeAssistantStateResponse = true, -- Not used
}

--- Subscribe to state updates from the ESPHome device.
--- @param callback (fun(message: table<string, any>, schema: ProtoMessageSchema?): void) The callback function to call when a state update is received.
--- @return Deferred<void, string> result A promise that resolves after subscribing to states.
function ESPHomeClient:subscribeStates(callback)
  log:trace("ESPHomeClient:subscribeStates()")
  --- @type Deferred<void, string>
  local d = deferred.new()

  for _, schema in pairs(ESPHomeProtoSchema.Message) do
    -- HACK: No reliable way to identify state responses from proto definition.
    -- Most state responses follow *StateResponse pattern, but EventResponse is an exception.
    local name, _ = schema.name:match("^(.+)StateResponse$")
    if IsEmpty(name) then
      name = schema.name:match("^(Event)Response$")
    end
    if not IsEmpty(name) and not EXCLUDED_STATE_RESPONSES[schema.name] then
      log:debug("Registering %s state callback", name)
      self:_registerCallback(self:_makeMessageCallbackKey(schema), function(message, messageSchema)
        log:debug("Received %s state update: %s", name, message)
        local callbackSuccess, err = pcall(callback, message, messageSchema)
        if not callbackSuccess then
          log:error("State callback for %s failed: %s", name, err or "unknown error")
        end
      end)
    end
  end

  self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.subscribe_states, {}):next(function()
    log:debug("Subscribe states message sent successfully")
    d:resolve(nil)
  end, function(err)
    if IsEmpty(err) or type(err) ~= "string" then
      err = "unknown error"
    end
    log:error("Failed to send subscribe states message: %s", err)
    d:reject(err)
  end)

  return d
end

--- Subscribe to log messages from the ESPHome device.
--- Can only subscribe once per connection. To stop logs, disconnect and reconnect.
--- @param callback fun(level: ProtoLogLevel?, message: string?): void The callback function to call when a log message is received. Level is ProtoLogLevel enum value.
--- @param level? ProtoLogLevel The minimum log level to receive (default: LOG_LEVEL_DEBUG = 5).
--- @param dumpConfig? boolean Whether to dump the device config first (default: false).
--- @return Deferred<nil, string> result A promise that resolves after subscribing to logs.
function ESPHomeClient:subscribeLogs(callback, level, dumpConfig)
  log:trace("ESPHomeClient:subscribeLogs(level=%s, dumpConfig=%s)", level, dumpConfig)
  --- @type Deferred<nil, string>
  local d = deferred.new()

  -- Guard against duplicate subscriptions
  if self._logsSubscribed then
    log:debug("Logs already subscribed")
    d:resolve(nil)
    return d
  end
  self._logsSubscribed = true

  -- Default to DEBUG level (5)
  level = level or ESPHomeProtoSchema.Enum.LogLevel.LOG_LEVEL_DEBUG

  -- Register callback for log responses
  self:_registerCallback(
    self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.SubscribeLogsResponse),
    function(message)
      --- @cast message ProtoSubscribeLogsResponse
      local callbackSuccess, err = pcall(callback, message.level, message.message)
      if not callbackSuccess then
        log:error("Log callback failed: %s", err or "unknown error")
      end
    end
  )

  -- Send subscription request
  self
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.subscribe_logs, {
      level = level,
      dump_config = dumpConfig or false,
    })
    :next(function()
      log:debug("Subscribe logs message sent successfully")
      d:resolve(nil)
    end, function(err)
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Failed to send subscribe logs message: %s", err)
      d:reject(err)
    end)

  return d
end

--- @class BluetoothConnectionResult
--- @field connected boolean Whether the device is connected
--- @field mtu number|nil The MTU if connected
--- @field error number|nil Error code if failed

--- Connect to a Bluetooth device via the ESPHome proxy.
--- ESPHome sends multiple responses: intermediate (connected=nil), then final (connected=true/false).
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param addressType? BLEAddressType The address type (optional).
--- @param withCache? boolean Use cached services (default true).
--- @return Deferred<BluetoothConnectionResult, string> result A promise that resolves when connected or rejects on failure.
function ESPHomeClient:bluetoothDeviceConnect(mac, addressType, withCache)
  log:trace("ESPHomeClient:bluetoothDeviceConnect(%s)", mac)

  local address = BLEAddress.fromString(mac)
  local d = deferred.new()

  -- Register callback for connection responses
  local callbackKey = self:_registerCallback(
    self:_makeBluetoothCallbackKey(ESPHomeProtoSchema.Message.BluetoothDeviceConnectionResponse, address),
    function(message)
      --- @cast message ProtoBluetoothDeviceConnectionResponse
      log:debug(
        "Bluetooth device connection response for %s: connected=%s, mtu=%s, error=%s",
        mac,
        message.connected,
        message.mtu,
        message.error
      )

      -- ESPHome sends multiple responses:
      -- - Intermediate: connected=nil (connection in progress)
      -- - Final: connected=true (success) or connected=false with error (failure)
      if message.connected == false or message.error ~= nil then
        d:reject(string.format("Connection failed with code %s", message.error or -1))
      elseif message.connected == true then
        d:resolve({ connected = true, mtu = message.mtu })
      end
      -- Ignore intermediate responses (connected=nil)
    end,
    30 * ONE_SECOND, -- timeout for BLE connections
    function()
      d:reject("Connection timeout")
    end
  )

  local requestType = (withCache == false)
      and ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITHOUT_CACHE
    or ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE

  --- @type ProtoBluetoothDeviceRequest
  local body = {
    address = address,
    request_type = requestType,
  }

  if addressType ~= nil then
    --- @cast addressType number
    body.has_address_type = true
    body.address_type = addressType
  end

  self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_device_request, body):next(nil, function(err)
    d:reject(err or "Failed to send connection request")
  end)

  return d:next(function(message)
    self:_unregisterCallback(callbackKey)
    return message
  end, function(err)
    self:_unregisterCallback(callbackKey)
    return reject(err)
  end)
end

--- Disconnect from a Bluetooth device.
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @return Deferred<nil, string> result A promise that resolves when the disconnect request is sent.
function ESPHomeClient:bluetoothDeviceDisconnect(mac)
  log:trace("ESPHomeClient:bluetoothDeviceDisconnect(%s)", mac)

  local address = BLEAddress.fromString(mac)
  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_device_request, {
    address = address,
    request_type = ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT,
  })
end

--- Get GATT services for a Bluetooth device.
--- Auto-connects if the device is not already connected.
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param addressType? BLEAddressType The address type for auto-connect (default: 0 = PUBLIC).
--- @return Deferred<ProtoBluetoothGATTService[], string> result A promise that resolves with all services or rejects with error.
function ESPHomeClient:bluetoothGattGetServices(mac, addressType)
  log:trace("ESPHomeClient:bluetoothGattGetServices(%s)", mac)

  -- Ensure device is connected before GATT operation
  return self:_ensureBleConnected(mac, addressType):next(function()
    return self:_bluetoothGattGetServicesInternal(mac)
  end)
end

--- Internal implementation of GATT service discovery (assumes device is connected).
--- @private
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @return Deferred<ProtoBluetoothGATTService[], string> result A promise that resolves with all services or rejects with error.
function ESPHomeClient:_bluetoothGattGetServicesInternal(mac)
  local address = BLEAddress.fromString(mac)
  --- @type Deferred<ProtoBluetoothGATTService[], string>
  local d = deferred.new()

  --- @type string[]
  local callbackKeys = {}

  -- Accumulate services from multiple responses
  --- @type ProtoBluetoothGATTService[]
  local allServices = {}

  table.insert(
    callbackKeys,
    self:_registerCallback(
      self:_makeBluetoothCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTGetServicesResponse, address),
      function(message)
        --- @cast message ProtoBluetoothGATTGetServicesResponse
        local services = message.services or {}
        log:debug("Bluetooth GATT services response for %s: %d services", mac, #services)
        for _, service in ipairs(services) do
          table.insert(allServices, service)
        end
      end
    )
  )

  table.insert(
    callbackKeys,
    self:_registerCallback(
      self:_makeBluetoothCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTGetServicesDoneResponse, address),
      function(message)
        --- @cast message ProtoBluetoothGATTGetServicesDoneResponse
        log:debug("Bluetooth GATT service discovery done for %s: %d total services", mac, #allServices)
        d:resolve(allServices)
      end,
      30 * ONE_SECOND,
      function()
        d:reject("GATT service discovery timeout")
      end
    )
  )

  table.insert(
    callbackKeys,
    self:_registerCallback(
      self:_makeBluetoothCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse, address),
      function(message)
        --- @cast message ProtoBluetoothGATTErrorResponse
        log:warn("Bluetooth GATT error for %s: error=%s", mac, message.error)
        d:reject(string.format("Getting GATT services failed with code %s", message.error or -1))
      end
    )
  )

  self
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_get_services, { address = address })
    :next(nil, function(err)
      d:reject(err)
    end)

  return d:next(function(message)
    self:_unregisterCallbacks(callbackKeys)
    return message
  end, function(err)
    self:_unregisterCallbacks(callbackKeys)
    return reject(err)
  end)
end

--- Read a GATT characteristic.
--- Auto-connects if the device is not already connected.
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param handle number The characteristic handle.
--- @param addressType? BLEAddressType The address type for auto-connect (default: 0 = PUBLIC).
--- @return Deferred<string, string> result A promise that resolves with data or rejects with GATT error code.
function ESPHomeClient:bluetoothGattRead(mac, handle, addressType)
  log:trace("ESPHomeClient:bluetoothGattRead(%s, %s)", mac, handle)

  -- Ensure device is connected before GATT operation
  return self:_ensureBleConnected(mac, addressType):next(function()
    return self:_bluetoothGattReadInternal(mac, handle)
  end)
end

--- Internal implementation of GATT read (assumes device is connected).
--- @private
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param handle number The characteristic handle.
--- @return Deferred<string, string> result A promise that resolves with data or rejects with GATT error code.
function ESPHomeClient:_bluetoothGattReadInternal(mac, handle)
  local address = BLEAddress.fromString(mac)
  --- @type Deferred<string, string>
  local d = deferred.new()

  --- @type string[]
  local callbackKeys = {}

  table.insert(
    callbackKeys,
    self:_registerCallback(
      self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTReadResponse, address, handle),
      function(message)
        --- @cast message ProtoBluetoothGATTReadResponse
        log:debug("Bluetooth GATT read response for %s handle %s: %d bytes", mac, handle, #(message.data or ""))
        d:resolve(message.data or "")
      end,
      10 * ONE_SECOND,
      function()
        d:reject("GATT read timeout")
      end
    )
  )

  table.insert(
    callbackKeys,
    self:_registerCallback(
      self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse, address, handle),
      function(message)
        --- @cast message ProtoBluetoothGATTErrorResponse
        log:warn("Bluetooth GATT error for %s handle %s: error=%s", mac, handle, message.error)
        d:reject(string.format("GATT read failed with code %s", message.error or -1))
      end
    )
  )

  self
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_read, { address = address, handle = handle })
    :next(nil, function(err)
      -- Service method failed (e.g., not connected)
      d:reject(err)
    end)

  return d:next(function(message)
    self:_unregisterCallbacks(callbackKeys)
    return message
  end, function(err)
    self:_unregisterCallbacks(callbackKeys)
    return reject(err)
  end)
end

--- Write to a GATT characteristic.
--- Auto-connects if the device is not already connected.
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param handle number The characteristic handle.
--- @param data string The data to write (binary string).
--- @param response? boolean Whether to wait for a write response (default false).
--- @param addressType? BLEAddressType The address type for auto-connect (default: 0 = PUBLIC).
--- @return Deferred<nil, string> result A promise that resolves on success or rejects with GATT error code.
function ESPHomeClient:bluetoothGattWrite(mac, handle, data, response, addressType)
  log:trace("ESPHomeClient:bluetoothGattWrite(%s, %s, %d bytes, response=%s)", mac, handle, #data, response)

  -- Ensure device is connected before GATT operation
  return self:_ensureBleConnected(mac, addressType):next(function()
    return self:_bluetoothGattWriteInternal(mac, handle, data, response)
  end)
end

--- Internal implementation of GATT write (assumes device is connected).
--- @private
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param handle number The characteristic handle.
--- @param data string The data to write (binary string).
--- @param response? boolean Whether to wait for a write response (default false).
--- @return Deferred<nil, string> result A promise that resolves on success or rejects with GATT error code.
function ESPHomeClient:_bluetoothGattWriteInternal(mac, handle, data, response)
  local address = BLEAddress.fromString(mac)
  --- @type Deferred<nil, string>
  local d = deferred.new()

  --- @type string[]
  local callbackKeys = {}

  if response then
    table.insert(
      callbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTWriteResponse, address, handle),
        function(message)
          --- @cast message ProtoBluetoothGATTWriteResponse
          log:debug("Bluetooth GATT write response for %s handle %s", mac, handle)
          d:resolve(nil)
        end,
        10 * ONE_SECOND,
        function()
          d:reject("GATT write timeout")
        end
      )
    )

    table.insert(
      callbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse, address, handle),
        function(message)
          --- @cast message ProtoBluetoothGATTErrorResponse
          log:warn("Bluetooth GATT write error for %s handle %s: error=%s", mac, handle, message.error)
          d:reject(string.format("GATT write failed with code %s", message.error or -1))
        end
      )
    )
  end

  self
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_write, {
      address = address,
      handle = handle,
      response = response or false,
      data = data,
    })
    :next(function()
      -- For no-response mode, resolve immediately on success, otherwise wait for callback
      if not response then
        d:resolve(nil)
      end
    end, function(err)
      d:reject(err)
    end)

  return d:next(function(message)
    self:_unregisterCallbacks(callbackKeys)
    return message
  end, function(err)
    self:_unregisterCallbacks(callbackKeys)
    return reject(err)
  end)
end

--- Write to a GATT descriptor and wait for the firmware's write response.
--- Used to write the Client Characteristic Configuration Descriptor (CCCD) for enabling
--- notifications or indications on V3 BLE connections where the ESP firmware does not
--- auto-write the CCCD.
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param handle number The descriptor handle.
--- @param data string The data to write (binary string).
--- @param addressType? BLEAddressType The address type for auto-connect (default: 0 = PUBLIC).
--- @return Deferred<nil, string> result A promise that resolves when the write completes or rejects with GATT error.
function ESPHomeClient:bluetoothGattWriteDescriptor(mac, handle, data, addressType)
  log:trace("ESPHomeClient:bluetoothGattWriteDescriptor(%s, %s, %d bytes)", mac, handle, #data)

  return self:_ensureBleConnected(mac, addressType):next(function()
    local address = BLEAddress.fromString(mac)
    --- @type Deferred<nil, string>
    local d = deferred.new()

    --- @type string[]
    local callbackKeys = {}

    -- The firmware sends BluetoothGATTWriteResponse for descriptor writes
    -- (same response type as characteristic writes).
    table.insert(
      callbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTWriteResponse, address, handle),
        function()
          log:debug("Bluetooth GATT descriptor write response for %s handle %s", mac, handle)
          d:resolve(nil)
        end,
        10 * ONE_SECOND,
        function()
          d:reject("GATT descriptor write timeout")
        end
      )
    )

    table.insert(
      callbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse, address, handle),
        function(message)
          --- @cast message ProtoBluetoothGATTErrorResponse
          log:warn("Bluetooth GATT descriptor write error for %s handle %s: error=%s", mac, handle, message.error)
          d:reject(string.format("GATT descriptor write failed with code %s", message.error or -1))
        end
      )
    )

    self
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_write_descriptor, {
        address = address,
        handle = handle,
        data = data,
      })
      :next(nil, function(err)
        d:reject(err)
      end)

    return d:next(function(message)
      self:_unregisterCallbacks(callbackKeys)
      return message
    end, function(err)
      self:_unregisterCallbacks(callbackKeys)
      return reject(err)
    end)
  end)
end

--- Subscribe to GATT characteristic notifications.
--- Auto-connects if the device is not already connected.
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param handle number The characteristic handle.
--- @param enable boolean Enable or disable notifications.
--- @param callback? fun(data: string) The callback for notification data (required when enable=true).
--- @param addressType? BLEAddressType The address type for auto-connect (default: 0 = PUBLIC).
--- @return Deferred<nil, string> result A promise that resolves when subscription is confirmed or rejects with GATT error.
function ESPHomeClient:bluetoothGattNotify(mac, handle, enable, callback, addressType)
  log:trace("ESPHomeClient:bluetoothGattNotify(%s, %s, %s)", mac, handle, enable)

  -- Ensure device is connected before GATT operation
  return self:_ensureBleConnected(mac, addressType):next(function()
    return self:_bluetoothGattNotifyInternal(mac, handle, enable, callback)
  end)
end

--- Internal implementation of GATT notify subscription (assumes device is connected).
--- @private
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param handle number The characteristic handle.
--- @param enable boolean Enable or disable notifications.
--- @param callback? fun(data: string) The callback for notification data (required when enable=true).
--- @return Deferred<nil, string> result A promise that resolves when subscription is confirmed or rejects with GATT error.
function ESPHomeClient:_bluetoothGattNotifyInternal(mac, handle, enable, callback)
  local address = BLEAddress.fromString(mac)
  --- @type Deferred<nil, string>
  local d = deferred.new()

  --- @type string[]
  local confirmCallbackKeys = {}
  local notifyCallbackKey =
    self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTNotifyDataResponse, address, handle)

  if enable then
    -- Register persistent callback for notification data
    if callback then
      self:_registerCallback(notifyCallbackKey, function(message)
        --- @cast message ProtoBluetoothGATTNotifyDataResponse
        log:debug("Bluetooth GATT notify data for %s handle %s: %d bytes", mac, handle, #(message.data or ""))
        local callbackSuccess, err = pcall(callback, message.data or "")
        if not callbackSuccess then
          log:error("Bluetooth GATT notify callback for %s handle %s failed: %s", mac, handle, err or "unknown error")
        end
      end)
    end

    -- Register one-time confirmation callback
    table.insert(
      confirmCallbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTNotifyResponse, address, handle),
        function(message)
          --- @cast message ProtoBluetoothGATTNotifyResponse
          log:debug("Bluetooth GATT notify subscription confirmed for %s handle %s", mac, handle)
          d:resolve(nil)
        end,
        10 * ONE_SECOND,
        function()
          d:reject("GATT notify subscription timeout")
        end
      )
    )

    -- Register error callback
    table.insert(
      confirmCallbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse, address, handle),
        function(message)
          --- @cast message ProtoBluetoothGATTErrorResponse
          log:warn("Bluetooth GATT notify error for %s handle %s: error=%s", mac, handle, message.error)
          d:reject(string.format("GATT notify failed with code %s", message.error or -1))
        end
      )
    )
  else
    -- Unsubscribe - clear the data callback
    self:_unregisterCallback(notifyCallbackKey)

    -- Register one-time confirmation callback for unsubscribe
    table.insert(
      confirmCallbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTNotifyResponse, address, handle),
        function(message)
          --- @cast message ProtoBluetoothGATTNotifyResponse
          log:debug("Bluetooth GATT notify unsubscribe confirmed for %s handle %s", mac, handle)
          d:resolve(nil)
        end,
        10 * ONE_SECOND,
        function()
          d:reject("GATT notify unsubscription timeout")
        end
      )
    )

    -- Register error callback
    table.insert(
      confirmCallbackKeys,
      self:_registerCallback(
        self:_makeGattCallbackKey(ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse, address, handle),
        function(message)
          --- @cast message ProtoBluetoothGATTErrorResponse
          log:warn("Bluetooth GATT notify unsubscribe error for %s handle %s: error=%s", mac, handle, message.error)
          d:reject(string.format("GATT notify failed with code %s", message.error or -1))
        end
      )
    )
  end

  self
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_notify, {
      address = address,
      handle = handle,
      enable = enable,
    })
    :next(nil, function(err)
      d:reject(err)
    end)

  return d:next(function(message)
    self:_unregisterCallbacks(confirmCallbackKeys)
    return message
  end, function(err)
    self:_unregisterCallbacks(confirmCallbackKeys)
    self:_unregisterCallback(notifyCallbackKey)
    return reject(err)
  end)
end

--- Subscribe to Bluetooth connection slot updates.
--- This tells us how many BLE connection slots are available/in use.
--- Updates cached state and notifies all registered callbacks.
--- Use addBluetoothConnectionsCallback() to register for updates.
--- @return Deferred<nil, string> result A promise that resolves when subscribed.
function ESPHomeClient:subscribeBluetoothConnectionsFree()
  log:trace("ESPHomeClient:subscribeBluetoothConnectionsFree()")

  --- @type Deferred<nil, string>
  local d = deferred.new()

  -- Timeout for initial response (callback persists for ongoing updates)
  local initialResponseTimer = C4:SetTimer(10 * ONE_SECOND, function()
    d:reject("Bluetooth connections subscription timeout")
  end)

  self:_registerCallback(
    self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.BluetoothConnectionsFreeResponse),
    function(message)
      --- @cast message ProtoBluetoothConnectionsFreeResponse
      local free = message.free or 0
      local limit = message.limit or 0
      local allocated = message.allocated or {}

      log:trace("Bluetooth connections free: %d/%d (connected devices: %d)", free, limit, #allocated)

      -- Convert uint64 addresses to MAC strings
      local allocatedMacs = {}
      for i, addr in ipairs(allocated) do
        local mac = BLEAddress.toString(addr) or "INVALID ADDRESS"
        table.insert(allocatedMacs, mac)
        log:trace("  Allocated slot %d: %s", i, mac)
      end

      -- Update cached state
      self._btConnections = {
        free = free,
        limit = limit,
        allocated = allocatedMacs,
        initialized = true,
      }

      log:trace(
        "Bluetooth connections updated: %d/%d free, %d allocated: %s",
        free,
        limit,
        #allocatedMacs,
        table.concat(allocatedMacs, ", ")
      )

      -- Notify all registered callbacks
      for callbackId, callback in pairs(self._btConnectionsCallbacks) do
        local callbackSuccess, err = pcall(callback, self._btConnections)
        if not callbackSuccess then
          log:error("Bluetooth connections callback '%s' failed: %s", callbackId, err or "unknown error")
        end
      end

      -- Resolve the deferred only after we have received our first update
      d:resolve(nil)
    end
  )

  -- Send subscription request
  self:sendMessage(ESPHomeProtoSchema.RPC.APIConnection.subscribe_bluetooth_connections_free.inputType):next(function()
    initialResponseTimer:Cancel()
  end, function(err)
    initialResponseTimer:Cancel()
    d:reject(err)
  end)

  return d
end

--- Initialize Bluetooth proxy functionality.
--- Subscribes to BLE advertisements and connection slot updates.
--- CRITICAL: The advertisement subscription establishes api_connection_ in ESPHome's
--- bluetooth_proxy. Without this, the proxy's loop() treats BLE connections as orphaned
--- and disconnects them. This subscription must remain active for BLE device connections.
--- Safe to call multiple times - only subscribes once.
--- @return Deferred<nil, string> result A promise that resolves when subscription is set up.
function ESPHomeClient:initBluetoothProxy()
  log:trace("ESPHomeClient:initBluetoothProxy()")

  -- Already fully initialized (real data received from subscription)
  if self._btConnections.initialized then
    log:debug("Bluetooth proxy already initialized")
    return deferred.new():resolve(nil)
  end

  -- Initialization already in flight - return existing deferred
  if self._btProxyInitDeferred then
    log:debug("Bluetooth proxy initialization already in progress")
    return self._btProxyInitDeferred
  end

  -- Register callback for scanner state updates
  -- ESPHome sends these when the scanner state changes (running, stopped, etc.)
  self:_registerCallback(
    self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.BluetoothScannerStateResponse),
    function(message)
      --- @cast message ProtoBluetoothScannerStateResponse
      log:debug(
        "Received BluetoothScannerStateResponse: state=%s, mode=%s, configured_mode=%s",
        message.state,
        message.mode,
        message.configured_mode
      )

      --- @type BluetoothScannerState
      self._btScannerState = {
        state = message.state or ESPHomeProtoSchema.Enum.BluetoothScannerState.BLUETOOTH_SCANNER_STATE_IDLE,
        mode = message.mode or ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE,
        initialized = true,
      }

      -- Notify all registered callbacks
      for callbackId, callback in pairs(self._btScannerStateCallbacks) do
        local callbackSuccess, err = pcall(callback, self._btScannerState)
        if not callbackSuccess then
          log:error("Bluetooth scanner state callback '%s' failed: %s", callbackId, err or "unknown error")
        end
      end
    end
  )

  -- Subscribe to BLE advertisements to establish api_connection_ in ESPHome's bluetooth_proxy.
  -- CRITICAL: Without this subscription, the proxy's loop() treats BLE connections as orphaned
  -- and disconnects them. This subscription must remain active for BLE device connections.
  -- See: https://github.com/esphome/esphome/blob/dev/esphome/components/bluetooth_proxy/bluetooth_proxy.cpp

  -- Helper to process a parsed advertisement and dispatch to all registered callbacks
  --- @param advertisement BLEAdvertisement
  local function processAdvertisement(advertisement)
    --log:trace("BLE advertisement: %s", BLEAdvertisementParser.toString(advertisement))

    -- Dispatch to all registered callbacks
    for callbackId, callback in pairs(self._btAdvertisementsCallbacks) do
      local success, err = pcall(callback, advertisement)
      if not success then
        log:error("Bluetooth advertisement callback '%s' failed: %s", callbackId, err or "unknown error")
      end
    end
  end

  -- Register callback for decoded advertisement responses (older ESPHome format)
  self:_registerCallback(
    self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.BluetoothLEAdvertisementResponse),
    function(message)
      --- @cast message ProtoBluetoothLEAdvertisementResponse
      local advertisement = BLEAdvertisementParser.parse(message)
      if not advertisement then
        log:warn("Invalid BLE advertisement: %s", message)
        return
      end
      processAdvertisement(advertisement)
    end
  )

  -- Register callback for raw advertisement responses (modern ESPHome format)
  self:_registerCallback(
    self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.BluetoothLERawAdvertisementsResponse),
    function(message)
      --- @cast message ProtoBluetoothLERawAdvertisementsResponse
      for _, rawAdvertisement in ipairs(message.advertisements or {}) do
        local advertisement = BLEAdvertisementParser.parseRaw(rawAdvertisement)
        if not advertisement then
          log:warn("Invalid raw BLE advertisement packet: %s", rawAdvertisement)
          return
        end
        processAdvertisement(advertisement)
      end
    end
  )

  -- Chain all subscription operations so the returned deferred
  -- only resolves after everything is established.
  -- Store the deferred as re-entrancy guard: concurrent calls return the same
  -- deferred, and on failure we clear it so the next call can retry.

  -- Step 1: Subscribe to BLE advertisements
  self._btProxyInitDeferred = self
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.subscribe_bluetooth_le_advertisements)
    :next(function()
      log:debug("BLE advertisement subscription established")

      -- Step 2: Set scanner mode to active (required for BTHome devices that include
      -- service data in scan responses rather than advertising packets)
      return self:setBluetoothScannerMode(true)
    end)
    :next(function()
      log:debug("Scanner mode set to active")

      -- Step 3: Subscribe to connection slot updates
      return self:subscribeBluetoothConnectionsFree()
    end)
    :next(function()
      -- Success: _btConnections.initialized is now true (set by subscription callback).
      -- Clear the in-flight deferred; future calls will see initialized=true and short-circuit.
      self._btProxyInitDeferred = nil
    end, function(err)
      -- Failed: clear the in-flight deferred so the next call can retry
      log:warn("Bluetooth proxy initialization failed, will retry on next attempt: %s", err or "unknown")
      self._btProxyInitDeferred = nil
      return deferred.new():reject(err)
    end)

  return self._btProxyInitDeferred
end

--- Get the current Bluetooth connection state (cached).
--- @return BluetoothConnectionState state The cached connection state.
function ESPHomeClient:getBluetoothConnectionState()
  log:trace("ESPHomeClient:getBluetoothConnectionState()")
  return self._btConnections
end

--- Check if a Bluetooth device is currently allocated (connected via proxy).
--- "Allocated" means the device has an active BLE connection and is using one of the
--- limited connection slots (typically 3-4 on ESP32).
--- @param mac string? MAC address
--- @return boolean isAllocated True if the device is currently connected.
function ESPHomeClient:isBluetoothDeviceAllocated(mac)
  log:trace("ESPHomeClient:isBluetoothDeviceAllocated(%s)", mac)
  if not mac then
    return false
  end
  for _, allocatedMac in ipairs(self._btConnections.allocated) do
    if allocatedMac == mac then
      return true
    end
  end
  return false
end

--- Ensure a BLE device is connected before performing GATT operations.
--- If the device already has an active connection (allocated slot), resolves immediately.
--- Otherwise, initiates a new BLE connection first. This enables on-demand connection for GATT
--- operations.
--- @private
--- @param mac string MAC address in format "AA:BB:CC:DD:EE:FF".
--- @param addressType? BLEAddressType The address type (default: 0 = PUBLIC).
--- @return Deferred<nil, string> result A promise that resolves when connected.
function ESPHomeClient:_ensureBleConnected(mac, addressType)
  log:trace("ESPHomeClient:_ensureBleConnected(%s)", mac)

  -- Check if device already has an active connection slot
  if self:isBluetoothDeviceAllocated(mac) then
    log:debug("BLE device %s already connected", mac)
    return deferred.new():resolve(nil)
  end

  -- Device not connected - initiate connection
  log:info("BLE device %s not connected, auto-connecting for GATT operation", mac)
  return self:bluetoothDeviceConnect(mac, addressType or BLEAddress.Type.PUBLIC, true):next(function()
    log:debug("BLE auto-connect successful for %s", mac)
  end)
end

--- Register a callback for Bluetooth connection state changes.
--- If state is already available, the callback is fired immediately with current state.
--- @param callbackId string Unique identifier for this callback (used for unregistering).
--- @param callback fun(state: BluetoothConnectionState) The callback function.
function ESPHomeClient:addBluetoothConnectionsCallback(callbackId, callback)
  log:trace("ESPHomeClient:addBluetoothConnectionsCallback(%s)", callbackId)
  self._btConnectionsCallbacks[callbackId] = callback

  -- Fire callback immediately if we already have state
  if self._btConnections.initialized then
    local success, err = pcall(callback, self._btConnections)
    if not success then
      log:error("Bluetooth connections callback '%s' failed: %s", callbackId, err or "unknown error")
    end
  end
end

--- Unregister a Bluetooth connection state change callback.
--- @param callbackId string The callback identifier to remove.
function ESPHomeClient:removeBluetoothConnectionsCallback(callbackId)
  log:trace("ESPHomeClient:removeBluetoothConnectionsCallback(%s)", callbackId)
  self._btConnectionsCallbacks[callbackId] = nil
end

--- Get the current Bluetooth scanner state (cached).
--- @return BluetoothScannerState state The cached scanner state { state, mode, initialized }.
function ESPHomeClient:getBluetoothScannerState()
  log:trace("ESPHomeClient:getBluetoothScannerState()")
  return self._btScannerState
end

--- Register a callback for Bluetooth scanner state changes.
--- If state is already available, the callback is fired immediately with current state.
--- @param callbackId string Unique identifier for this callback (used for unregistering).
--- @param callback fun(state: BluetoothScannerState) The callback function.
function ESPHomeClient:addBluetoothScannerStateCallback(callbackId, callback)
  log:trace("ESPHomeClient:addBluetoothScannerStateCallback(%s)", callbackId)
  self._btScannerStateCallbacks[callbackId] = callback

  -- Fire callback immediately if we already have state
  if self._btScannerState.initialized then
    local success, err = pcall(callback, self._btScannerState)
    if not success then
      log:error("Bluetooth scanner state callback '%s' failed: %s", callbackId, err or "unknown error")
    end
  end
end

--- Unregister a Bluetooth scanner state change callback.
--- @param callbackId string The callback identifier to remove.
function ESPHomeClient:removeBluetoothScannerStateCallback(callbackId)
  log:trace("ESPHomeClient:removeBluetoothScannerStateCallback(%s)", callbackId)
  self._btScannerStateCallbacks[callbackId] = nil
end

--- Register a callback for BLE advertisement notifications.
--- Advertisements are received after initBluetoothProxy() is called.
--- @param callbackId string Unique identifier for this callback.
--- @param callback fun(advertisement: BLEAdvertisement) The callback function.
function ESPHomeClient:addBluetoothAdvertisementCallback(callbackId, callback)
  log:trace("ESPHomeClient:addBluetoothAdvertisementCallback(%s)", callbackId)
  self._btAdvertisementsCallbacks[callbackId] = callback
end

--- Unregister a BLE advertisement callback.
--- @param callbackId string The callback identifier to remove.
function ESPHomeClient:removeBluetoothAdvertisementCallback(callbackId)
  log:trace("ESPHomeClient:removeBluetoothAdvertisementCallback(%s)", callbackId)
  self._btAdvertisementsCallbacks[callbackId] = nil
end

--- Set the Bluetooth scanner mode.
--- @param active boolean True for active scanning, false for passive scanning.
--- @return Deferred<nil, string> result A promise that resolves when mode is set.
function ESPHomeClient:setBluetoothScannerMode(active)
  log:trace("ESPHomeClient:setBluetoothScannerMode(%s)", active)

  local mode = active and ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_ACTIVE
    or ESPHomeProtoSchema.Enum.BluetoothScannerMode.BLUETOOTH_SCANNER_MODE_PASSIVE

  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.bluetooth_scanner_set_mode, {
    mode = mode,
  })
end

--- Send a hello message to the ESPHome device.
--- @return Deferred<ProtoHelloResponse, string> result A promise that resolves when the hello message is sent.
function ESPHomeClient:sendHello()
  log:trace("ESPHomeClient:sendHello()")
  local deviceId = C4:GetDeviceID()
  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.hello, {
    client_info = string.format(
      "Control4 - %s (ID: %d)",
      C4:GetDeviceData(deviceId, "name") or "Unknown Device",
      deviceId
    ),
    api_version_major = 1,
    api_version_minor = 0,
  })
end

--- Check if the Noise protocol handshake is in the expected state.
--- @param expectedState NoiseState The expected state of the handshake.
--- @return boolean isValid True if the handshake is in the expected state, false otherwise.
function ESPHomeClient:checkHandshakeState(expectedState)
  log:trace("ESPHomeClient:checkHandshakeState(%s)", expectedState)
  if self._hsState ~= expectedState then
    log:error("Expected Noise state %s, actual %s", expectedState, self._hsState)
    return false
  end
  return true
end

--- Send a hello message using the Noise protocol.
--- @return Deferred<void, string> result A promise that resolves when the hello message is sent.
function ESPHomeClient:sendNoiseHello()
  log:trace("ESPHomeClient:sendNoiseHello()")
  --- @type Deferred<void, string>
  local d = deferred.new()

  if not self:isConnected() then
    return d:reject("Not connected to ESPHome device")
  end
  --- @cast self._client -nil

  -- Hello message
  local frame = "\x01\x00\x00"

  self:_registerCallback(
    NoiseProtocolCallbackKey.HELLO,
    function(message)
      --- @diagnostic disable-next-line: cast-type-mismatch
      --- @cast message { node: string, mac_address: string }
      log:debug("Received SERVER_HELLO: node=%s, mac=%s", message.node, message.mac_address)
      d:resolve(nil)
    end,
    5 * ONE_SECOND,
    function()
      self._hsState = NoiseState.ERROR
      d:reject("Timeout waiting for SERVER_HELLO response")
    end
  )

  self._hsState = NoiseState.HELLO
  log:ultra("Sending CLIENT_HELLO frame (hex): %s", to_hex(frame))
  self._client:Write(frame)
  return d
end

--- Send the Noise protocol handshake message to establish encrypted communication.
--- @return Deferred<void, string> result A promise that resolves when the handshake is complete.
function ESPHomeClient:sendHandshake()
  log:trace("ESPHomeClient:sendHandshake()")
  --- @type Deferred<void, string>
  local d = deferred.new()
  if self._encryptionKey == nil then
    return d:resolve(nil)
  end

  if not self:isConnected() then
    return d:reject("Not connected to ESPHome device")
  end
  --- @cast self._client -nil

  self._hs = noise.NoiseConnection:new({
    protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
    initiator = true,
    psks = { self._encryptionKey },
    prologue = "NoiseAPIInit" .. NULL_BYTE .. NULL_BYTE,
  })
  self._hs:start_handshake()
  local handshake = NULL_BYTE .. self._hs:write_handshake_message()

  local frame = Indicator.NOISE .. bit16.u16_to_be_bytes(#handshake) .. handshake

  self:_registerCallback(
    NoiseProtocolCallbackKey.HANDSHAKE,
    function(message)
      --- @diagnostic disable-next-line: cast-type-mismatch
      --- @cast message { success: boolean, message: string? }
      self:checkHandshakeState(NoiseState.HANDSHAKE)

      if not message.success or not message.message then
        log:error("HANDSHAKE failed: %s", message.message or "empty response")
        self._hsState = NoiseState.ERROR
        d:reject(message.message or "empty handshake response")
        return
      end

      assert(self._hs):read_handshake_message(message.message)

      if not self._hs.handshake_complete then
        log:error("Handshake not completed after reading handshake message")
        self._hsState = NoiseState.ERROR
        d:reject("Handshake not completed")
        return
      end

      log:debug("Handshake completed successfully")
      self._hsState = NoiseState.READY
      d:resolve(nil)
    end,
    5 * ONE_SECOND,
    function()
      self:checkHandshakeState(NoiseState.HANDSHAKE)
      self._hsState = NoiseState.ERROR
      d:reject("Timeout waiting for HANDSHAKE response")
    end
  )

  self._hsState = NoiseState.HANDSHAKE
  log:ultra("Sending HANDSHAKE frame (hex): %s", to_hex(frame))
  self._client:Write(frame)
  return d
end

--- Send an authenticate message to the ESPHome device.
--- ESPHome 2025.8.0+ devices without password authentication don't send AuthenticationResponse.
--- Devices will either send error response (wrong password) or ignore (no password support).
--- @return Deferred<void, string> result A promise that resolves immediately after sending.
function ESPHomeClient:sendAuthenticate()
  log:trace("ESPHomeClient:sendAuthenticate()")

  -- Register async handler for AuthenticationResponse (sets fatal error on invalid password)
  local authKey = self:_makeMessageCallbackKey(ESPHomeProtoSchema.Message.AuthenticationResponse)
  self:_registerCallback(authKey, function(message)
    -- Remove callback immediately
    self:_unregisterCallback(authKey)

    if message.invalid_password then
      log:error("Connect unsuccessful (invalid password)")
      -- Set fatal error - subsequent operations will fail with this error
      self._fatalError = "Invalid password"
      self:disconnect()
    else
      log:debug("Connect successful")
    end
  end)

  -- Send AuthenticationRequest without waiting for response
  return self:sendMessage(
    ESPHomeProtoSchema.Message.AuthenticationRequest,
    { password = not IsEmpty(self._password) and self._password or "" },
    nil, -- Don't wait for response
    nil
  )
end

--- Send a ping message to the ESPHome device.
--- @return Deferred<void, string> result A promise that resolves when the ping response is received.
function ESPHomeClient:sendPing()
  log:trace("ESPHomeClient:sendPing()")
  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.ping, {}):next(function()
    log:info("Ping successful")
  end, function(err)
    if IsEmpty(err) or type(err) ~= "string" then
      err = "unknown error"
    end
    log:error("Ping failed: %s", err)
    return reject(err)
  end)
end

--- Call a service method on the ESPHome device.
--- @param method ProtoServiceMethodSchema The method to call.
--- @param body? table The request body (optional).
--- @param timeout? number The timeout for the request in milliseconds (optional). Only non-void methods support this. Default is 5 seconds.
--- @return Deferred<any, string> result A promise that resolves with the response.
function ESPHomeClient:callServiceMethod(method, body, timeout)
  log:trace("ESPHomeClient:callServiceMethod(%s, %s, %s)", method.method, body, timeout)

  -- Determine if we expect a response
  local responseSchema = nil
  if method.outputType.name ~= ESPHomeProtoSchema.Message.void.name then
    responseSchema = method.outputType
  end

  -- Use sendMessage to handle the actual sending
  return self:sendMessage(method.inputType, body, responseSchema, timeout)
end

--- Execute a user-defined ESPHome service by name.
--- The service key is resolved from the cache populated during listEntities().
--- @param name string The service name as defined in the ESPHome YAML (e.g. "set_remote_temperature").
--- @param floatValue? number Optional float argument. Pass nil for services with no arguments.
--- @return Deferred<any, string> result A promise that resolves when the service is executed.
function ESPHomeClient:executeServiceByName(name, floatValue)
  log:trace("ESPHomeClient:executeServiceByName(%s, %s)", name, floatValue)
  local key = self.userServices[name]
  if key == nil then
    log:warn("executeServiceByName: service '%s' not found (known services: %s)", name, self.userServices)
    return deferred.new():reject("Service not found: " .. tostring(name))
  end
  local body = { key = key }
  if floatValue ~= nil then
    body.args = { { float_ = floatValue } }
  end
  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.execute_service, body)
end

--- Send a message to the ESPHome device.
--- @param messageSchema ProtoMessageSchema The message to send.
--- @param body? table<string, any> The message body (optional).
--- @param responseSchema? ProtoMessageSchema The expected response schema (optional).
--- @param timeout? number The timeout for the response in milliseconds (optional).
--- @return Deferred<any, string> result A promise that resolves when the message is sent (and response received if expected).
function ESPHomeClient:sendMessage(messageSchema, body, responseSchema, timeout)
  log:trace("ESPHomeClient:sendMessage(%s, %s, %s, %s)", messageSchema.name, body, responseSchema, timeout)
  --- @type Deferred<any, string>
  local d = deferred.new()

  -- Check for fatal error first (e.g., authentication failure)
  if not IsEmpty(self._fatalError) then
    --- @cast self._fatalError -nil
    return d:reject(self._fatalError)
  end

  if not self:isConnected() then
    return d:reject("Not connected to ESPHome device")
  end
  --- @cast self._client -nil

  -- Determine the message type
  local messageType = tointeger(Select(messageSchema, "options", "id"))
  if IsEmpty(messageType) then
    return d:reject("Invalid message type")
  end
  --- @cast messageType integer

  local encodedData = pb.encode(ESPHomeProtoSchema, messageSchema, body or {})

  local frame
  if self._encryptionKey ~= nil then
    -- Noise protocol (encrypted)
    if not self:checkHandshakeState(NoiseState.READY) then
      return d:reject("Noise protocol handshake not completed")
    end
    log:trace("Using Noise protocol for encrypted message send")

    -- Combine message type, data length, and data (this will be encrypted)
    local plaintextPayload = bit16.u16_to_be_bytes(messageType) .. bit16.u16_to_be_bytes(#encodedData) .. encodedData

    -- Encrypt the payload using noise
    local success, ciphertextPayload = pcall(assert(self._hs).send_message, self._hs, plaintextPayload)
    if not success then
      log:error("Failed to encrypt payload: %s", ciphertextPayload)
      return d:reject("Encryption failed: " .. (ciphertextPayload or "unknown error"))
    end
    log:debug("Building frame for encrypted message send")

    -- Build the frame
    frame = Indicator.NOISE .. bit16.u16_to_be_bytes(#ciphertextPayload) .. ciphertextPayload
  else
    -- Plaintext protocol
    frame = Indicator.PLAINTEXT .. pb.encode_varint(#encodedData) .. pb.encode_varint(messageType) .. encodedData
  end

  -- Store callback for response if one is expected
  local responseKey
  if responseSchema then
    responseKey = self:_registerCallback(
      self:_makeMessageCallbackKey(responseSchema),
      function(message)
        log:debug("Received response to %s", messageSchema.name)
        d:resolve(message)
      end,
      timeout or (5 * ONE_SECOND),
      function()
        d:reject("Timeout waiting for response to " .. messageSchema.name)
      end
    )
  else
    -- If no response is expected, resolve immediately after sending
    d:resolve(nil)
  end

  log:debug("Sending message %s with %d byte(s) of data", messageSchema.name, #encodedData)
  -- log:ultra("Outgoing frame (hex): %s", to_hex(frame))
  self._client:Write(frame)

  return d:next(function(message)
    self:_unregisterCallback(responseKey)
    return message
  end, function(err)
    self:_unregisterCallback(responseKey)
    return reject(err)
  end)
end

--
-- Private Methods
--

--- Generate a callback key for a message schema.
--- @param messageSchema ProtoMessageSchema The message schema
--- @return CallbackKey key The generated callback key
--- @private
--- @diagnostic disable-next-line: unused
function ESPHomeClient:_makeMessageCallbackKey(messageSchema)
  local id = Select(messageSchema, "options", "id")
  assert(id, "Message schema must have options.id")
  return tostring(id)
end

--- Generate a callback key for a message schema and Bluetooth address.
--- @param messageSchema ProtoMessageSchema The message schema
--- @param address number|table The Bluetooth device address (uint64 or Int64HighLow)
--- @return CallbackKey key The generated callback key
--- @private
function ESPHomeClient:_makeBluetoothCallbackKey(messageSchema, address)
  local messageKey = self:_makeMessageCallbackKey(messageSchema)
  local addrStr = BLEAddress.toString(address)
  return string.format("%s_%s", messageKey, addrStr)
end

--- Generate a callback key for a message schema, Bluetooth address, and GATT handle.
--- @param messageSchema ProtoMessageSchema The message schema
--- @param address number|table The Bluetooth device address (uint64 or Int64HighLow)
--- @param handle number GATT handle
--- @return CallbackKey key The generated callback key
--- @private
function ESPHomeClient:_makeGattCallbackKey(messageSchema, address, handle)
  local bluetoothKey = self:_makeBluetoothCallbackKey(messageSchema, address)
  return string.format("%s_%d", bluetoothKey, handle)
end

--- Register a callback for a given key with optional timeout.
--- @param key CallbackKey The callback key
--- @param callback CallbackFunction The callback function
--- @param timeout? number Optional timeout in milliseconds for auto-unregistration
--- @param onTimeout? fun(): void Optional callback invoked on timeout (before unregistration)
--- @return CallbackKey key The registered key (for later unregistration)
--- @private
function ESPHomeClient:_registerCallback(key, callback, timeout, onTimeout)
  log:trace("ESPHomeClient:_registerCallback(%s, <fn>, %s)", key, timeout)

  -- Cancel any existing timer for this key
  local existing = self._callbacks[key]
  if existing and existing.timer then
    existing.timer:Cancel()
  end

  --- @type CallbackEntry
  local entry = {
    callback = callback,
    timer = nil,
  }

  -- Set up timeout timer if specified
  if timeout and timeout > 0 then
    entry.timer = C4:SetTimer(timeout, function()
      log:warn("Callback timeout for key: %s", key)
      if onTimeout then
        onTimeout()
      end
      self:_unregisterCallback(key)
    end)
  end

  self._callbacks[key] = entry
  log:trace("Registered callback for key: %s (timeout: %s ms)", key, timeout or "none")
  return key
end

--- Unregister a callback by key. No-op if key is nil.
--- @param key CallbackKey|nil The callback key to unregister
--- @private
function ESPHomeClient:_unregisterCallback(key)
  log:trace("ESPHomeClient:_unregisterCallback(%s)", key)
  if key == nil then
    return
  end

  local entry = self._callbacks[key]
  if entry then
    if entry.timer then
      entry.timer:Cancel()
    end
    self._callbacks[key] = nil
    log:trace("Unregistered callback for key: %s", key)
  end
end

--- Unregister multiple callbacks by key. Convenience wrapper around _unregisterCallback.
--- @param keys CallbackKey[] Array of callback keys to unregister
--- @private
function ESPHomeClient:_unregisterCallbacks(keys)
  for _, key in ipairs(keys) do
    self:_unregisterCallback(key)
  end
end

--- Find and invoke a callback for a message.
--- Uses priority lookup: GATT > Bluetooth > Message ID (most specific wins).
--- @param messageType integer The message type ID
--- @param message table<string, any> The decoded message
--- @param schema ProtoMessageSchema The message schema
--- @return boolean found True if a callback was found and invoked
--- @private
function ESPHomeClient:_invokeCallback(messageType, message, schema)
  log:trace("ESPHomeClient:_invokeCallback(%s, <msg>, %s)", messageType, schema.name)

  -- Try most specific first: message + address + handle
  if message.address ~= nil and message.handle ~= nil then
    local gattKey = self:_makeGattCallbackKey(schema, message.address, message.handle)
    if self:_invokeCallbackByKey(gattKey, message, schema) then
      return true
    end
  end

  -- Try message + address
  if message.address ~= nil then
    local btKey = self:_makeBluetoothCallbackKey(schema, message.address)
    if self:_invokeCallbackByKey(btKey, message, schema) then
      return true
    end
  end

  -- Fall back to message ID only
  return self:_invokeCallbackByKey(self:_makeMessageCallbackKey(schema), message, schema)
end

--- Invoke a callback by key with variadic arguments.
--- @param key CallbackKey The callback key
--- @param ... any Arguments to pass to the callback
--- @return boolean found True if a callback was found and invoked
--- @private
function ESPHomeClient:_invokeCallbackByKey(key, ...)
  local entry = self._callbacks[key]

  if entry and entry.callback then
    log:trace("Invoking callback for key: %s", key)

    -- Cancel the timeout timer if present (callback was invoked before timeout)
    if entry.timer then
      entry.timer:Cancel()
      entry.timer = nil
    end

    local success, err = pcall(entry.callback, ...)
    if not success then
      log:error("Callback for key %s failed: %s", key, err or "unknown error")
    end
    return true
  end

  return false
end

--- Process the current data buffer and decodes any valid packets recursively.
--- Currently only plaintext packets are supported.
--- @private
function ESPHomeClient:_processBuffer()
  log:trace("ESPHomeClient:_processBuffer()")
  -- We need at least 3 bytes to begin processing a frame
  if self._buffer == nil or #self._buffer < 3 then
    return
  end
  -- log:ultra("Processing buffer (hex): %s", to_hex(self._buffer))

  -- Process the indicator
  local indicator, indicatorEndPos = string.byte(self._buffer, 1), 2

  if indicator == string.byte(Indicator.PLAINTEXT) then
    --[[
      Plaintext Protocol Frame Structure:
        [Indicator][Payload Size VarInt][Message Type VarInt][Payload]
          1 byte         1-3 bytes           1-2 bytes       Variable

      Data Type Summary:
      +--------------+--------+-----------+----------+----------------------------+
      | Field        | Type   | Size      | Encoding | Notes                      |
      +--------------+--------+-----------+----------+----------------------------+
      | Indicator    | uint8  | 1 byte    | -        | Always 0x00                |
      | Payload Size | varint | 1-3 bytes | VarInt   | Unsigned                   |
      | Message Type | varint | 1-2 bytes | VarInt   | Unsigned, max 65535        |
      | Data         | bytes  | Variable  | -        | Protocol buffer payload    |
      +--------------+--------+-----------+----------+----------------------------+
    --]]

    -- Check for protocol mismatch: client expects encryption but device sent plaintext
    if self._encryptionKey ~= nil then
      log:error("Protocol mismatch: driver configured for encryption but device sent plaintext data")
      log:error("Check that the ESPHome device has 'api: encryption: key:' configured in its YAML")
      self._fatalError = "Encryption mismatch: device not configured for encryption"
      self:disconnect()
      return
    end

    -- Process the payload size and message type
    local payloadSize, payloadSizeEndPos = pb.decode_varint(self._buffer, indicatorEndPos)
    local messageType, messageTypeEndPos = pb.decode_varint(self._buffer, payloadSizeEndPos)

    -- Extract the payload data
    local totalFrameSize = messageTypeEndPos + payloadSize - 1
    if #self._buffer < totalFrameSize then
      -- This can happen if the message is split across multiple tcp reads
      log:trace("Incomplete plaintext frame (%d bytes expected, %d bytes received)", totalFrameSize, #self._buffer)
      return
    end
    local payload = string.sub(self._buffer, messageTypeEndPos, totalFrameSize)
    local payloadEndPos = totalFrameSize + 1

    -- Remove the processed data from the buffer
    self._buffer = string.sub(self._buffer, payloadEndPos)

    -- Update keepalive timestamp for each processed frame
    self._lastDataReceived = os.time()

    log:ultra("Plaintext frame - Message type: %d, Payload size: %d", messageType, payloadSize)
    self:_processPayload(messageType, payload)
  elseif indicator == string.byte(Indicator.NOISE) then
    --[[
      Noise Protocol Frame Structure:
        [Indicator][Encrypted Size][Encrypted Payload][MAC]
            1 byte      2 bytes         Variable      16 bytes

      Message Format:
        Unencrypted Header (3 bytes)
          Indicator: 0x01
          Encrypted payload size: 16-bit unsigned, big-endian
        Encrypted Payload
          Message type: 16-bit unsigned, big-endian (encrypted)
          Data length: 16-bit unsigned, big-endian (encrypted)
          Protocol buffer data
        MAC (16 bytes)

      During the Noise handshake, the server sends a SERVER_HELLO message:
      SERVER_HELLO format:
        [Indicator] [Size] [Protocol] [Node-Name] [MAC-Address]
            0x01      2B      0x01     null-term    null-term

      Handshake rejection format:
        [Indicator] [Size] [Error-Flag] [Error-Message]
            0x01      2B      0x01         Variable
    --]]

    -- Check for protocol mismatch: device sent noise but client not configured for encryption
    if self._encryptionKey == nil then
      log:error("Protocol mismatch: device sent encrypted data but driver not configured for encryption")
      log:error("Set Authentication Mode to 'Encryption Key' and enter the key from your ESPHome device")
      self._fatalError = "Encryption mismatch: device requires encryption key"
      self:disconnect()
      return
    end

    local encryptedSize = bit16.be_bytes_to_u16(self._buffer:sub(indicatorEndPos, indicatorEndPos + 1))
    local encryptedSizeEndPos = indicatorEndPos + 2

    -- Check if we have the complete frame in the buffer
    local totalFrameSize = encryptedSizeEndPos + encryptedSize - 1
    if #self._buffer < totalFrameSize then
      -- This can happen if the message is split across multiple tcp reads
      log:trace("Incomplete noise frame (%d bytes expected, %d bytes received)", totalFrameSize, #self._buffer)
      return
    end

    -- Extract the encrypted payload
    local encryptedPayload = string.sub(self._buffer, encryptedSizeEndPos, totalFrameSize)
    local encryptedPayloadEndPos = totalFrameSize + 1

    -- TODO: Lower logging level
    log:debug(
      "Noise frame: size=%d, totalFrameSize=%d, bufferLen=%d, remaining=%d",
      encryptedSize,
      totalFrameSize,
      #self._buffer,
      #self._buffer - totalFrameSize
    )

    -- Remove the processed data from the buffer
    self._buffer = string.sub(self._buffer, encryptedPayloadEndPos)

    -- Update keepalive timestamp for each processed frame (not just on OnRead)
    self._lastDataReceived = os.time()

    if self._hsState == NoiseState.HELLO then
      -- SERVER_HELLO message structure
      --[[
        01 00 1E 01 72 61 74 67 64 6F 33 32 2D 65 32 65 39 64 34 00 65 63 63 39 66 66 65 32 65 39 64 34 00
        ^  ^---^ ^  ^------------------ Node ------------------^ ^  ^ ---------------- MAC -----------^ ^
        |    |   |                "ratgdo32-e2e9d4               |               "ecc9ffe2e9d4"         |
        |    |   Protocol (0x01)                                 Null                                 Null
        |    Size (30 bytes, big-endian)
        Indicator
      --]]

      if string.byte(encryptedPayload, 1) ~= 0x01 then
        log:error("Invalid SERVER_HELLO message (invalid protocol byte %02X)", string.byte(encryptedPayload, 1))
        return
      end
      log:trace("Encrypted payload is a SERVER_HELLO message")

      -- Extract node name
      local nodeNullTermPos = encryptedPayload:find(NULL_BYTE, 2)
      if not nodeNullTermPos then
        log:error("Invalid SERVER_HELLO message (missing node null terminator)")
        return
      end
      -- Extract node name
      local nodeName = string.sub(encryptedPayload, 2, nodeNullTermPos - 1)

      -- Extract mac address
      local macNullTermPos = encryptedPayload:find(NULL_BYTE, nodeNullTermPos + 1)
      if not macNullTermPos then
        log:error("Invalid SERVER_HELLO message (missing mac null terminator)")
        return
      end
      -- Extract mac address
      local mac = string.sub(encryptedPayload, nodeNullTermPos + 1, macNullTermPos - 1)

      log:debug("SERVER_HELLO message - Node: %s, MAC: %s", nodeName, mac)

      -- Call the callback for SERVER_HELLO if registered
      self:_invokeCallbackByKey(NoiseProtocolCallbackKey.HELLO, {
        node = nodeName,
        mac_address = mac,
      })
    elseif self._hsState == NoiseState.HANDSHAKE then
      -- HANDSHAKE error message structure
      --[[
        01 00 10 01 48 61 6E 64 73 68 61 6B 65 20 65 72 72 6F 72
        ^  ^^^^^ ^  ^----------------Error---------------------^
        |    |   |               "Handshake error"
        |    |   Error Flag
        |    Size (16 bytes, big-endian)
        Indicator
      --]]
      -- Extract message
      local success = string.byte(encryptedPayload, 1) ~= 0x01
      log:trace("Encrypted payload is a HANDSHAKE %s message", success and "success" or "error")

      local message = encryptedPayload:sub(2)

      log:trace("HANDSHAKE message - Success: %s, Message: %s", success, to_hex(message))

      -- Call the callback for HANDSHAKE if registered
      self:_invokeCallbackByKey(NoiseProtocolCallbackKey.HANDSHAKE, {
        success = success,
        message = message,
      })
    elseif self._hsState == NoiseState.READY then
      local ok, decryptedPayload = pcall(assert(self._hs).receive_message, self._hs, encryptedPayload)
      if not ok or decryptedPayload == nil then
        if decryptedPayload == nil then
          decryptedPayload = "decryption failed"
        elseif type(decryptedPayload) ~= "string" then
          decryptedPayload = "unknown error"
        end
        log:error("Failed to decrypt noise frame: %s", decryptedPayload)
        return
      end
      --- @cast decryptedPayload string

      -- log:trace("READY message - %s", to_hex(decryptedPayload))

      -- Extract the message type and data length from the decrypted payload
      if #decryptedPayload < 4 then
        log:error("Decrypted payload too short (need at least 4 bytes)")
        return
      end

      local messageType = bit16.be_bytes_to_u16(decryptedPayload:sub(1, 2))
      local dataLength = bit16.be_bytes_to_u16(decryptedPayload:sub(3, 4))

      -- Extract the protocol buffer data
      local payload = string.sub(decryptedPayload, 5)
      if #payload ~= dataLength then
        log:error("Decrypted data length mismatch (%d bytes expected, %d bytes received)", dataLength, #payload)
        return
      end

      self:_processPayload(messageType, payload)
    else
      log:warn("Invalid Noise state: %s", self._hsState)
      return
    end
  else
    -- Unknown indicator - buffer is corrupted, clear it and disconnect
    log:error("Invalid esphome frame (unsupported indicator %02X)", indicator)
    log:error("Buffer corruption detected - first 32 bytes: %s", to_hex(self._buffer:sub(1, 32)))
    self._fatalError = "Protocol error: corrupted frame data"
    self:disconnect()
    return
  end

  -- Continue processing any remaining data in the buffer
  self:_processBuffer()
end

--- @param messageType integer
--- @param payload string
--- @private
function ESPHomeClient:_processPayload(messageType, payload)
  log:trace("ESPHomeClient:_processPayload(%s, %d bytes)", messageType, #payload)

  -- Find the message schema
  --- @type ProtoMessageSchema|nil
  local messageSchema = nil
  for _, schema in pairs(ESPHomeProtoSchema.Message) do
    if messageType == Select(schema, "options", "id") then
      messageSchema = schema
      break
    end
  end
  if messageSchema == nil then
    log:warn("Invalid esphome frame (unknown message type %d)", messageType)
    return
  end

  -- Decode the payload data
  local success, message = pcall(pb.decode, ESPHomeProtoSchema, messageSchema, payload)
  if not success then
    log:warn("Invalid esphome frame (failed to decode message type %s): %s", messageType, message or "unknown error")
    return
  end
  --- @cast message -string

  log:ultra("Decoded esphome message: %s(%s)", messageSchema.name, message)

  -- Call any registered callbacks for the message type
  self:_invokeCallback(messageType, message, messageSchema)
end

return ESPHomeClient
