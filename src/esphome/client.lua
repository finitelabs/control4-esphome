--- @module "esphome.client"
--- ESPHome API Client for Control4.
--- This module provides a Lua implementation for connecting to ESPHome devices
--- using the native API protocol over TCP with protobuf encoding.
--- Supports both plaintext and encrypted (Noise protocol) communication.

local log = require("lib.logging")
local bit16 = require("lib.bit16")
local pb = require("lib.protobuf")
local ESPHomeProtoSchema = require("esphome.proto-schema")
local deferred = require("vendor.deferred")
local noise = require("vendor.noiseprotocol")

local NULL_BYTE = "\x00"

--- @enum NoiseProtocolCallback
local NoiseProtocolCallback = {
  -- These are negative values to avoid conflicts with message IDs
  HELLO = -1,
  HANDSHAKE = -2,
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

--- A class representing the ESPHome API client.
--- @class ESPHomeClient
--- @field EntityType EntityType
local ESPHomeClient = {}

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
}

--- Create a new instance of the ESPHomeClient.
--- @return ESPHomeClient client A new instance of the ESPHomeClient client.
function ESPHomeClient:new()
  local properties = {
    _client = nil, --- @type C4TCPClient|nil The TCP client for the ESPHome connection.
    _connected = false, --- @type boolean Indicates if the client is connected.
    _ipAddress = nil, --- @type string|nil The IP address of the ESPHome device.
    _port = 6053, --- @type number The port of the ESPHome device.
    _password = nil, --- @type string|nil The password for the ESPHome device.
    _encryptionKey = nil, --- @type string|nil The encryption key for the ESPHome device.
    _buffer = "", --- @type string The buffer for incoming data.
    _callbacks = {}, --- @type table<number, (fun(message: table<string, any>, schema: ProtoMessageSchema): void)|nil> The callback for the next expected response.
    _pingTimer = nil, --- @type C4LuaTimer|nil The timer for sending ping messages.
    _hs = nil, --- @type NoiseConnection|nil The Noise protocol connection for encrypted communication.
    _hsState = nil, --- @type NoiseState|nil The current state of the Noise protocol handshake.
    _fatalError = nil, --- @type string|nil Fatal error message (e.g., authentication failure).
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties ESPHomeClient
  return properties
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
  self._callbacks[ESPHomeProtoSchema.Message.PingRequest.options.id] = function(message)
    log:debug("Received ping request: %s", message)
    self:sendMessage(ESPHomeProtoSchema.Message.PingResponse, {})
  end
  self._callbacks[ESPHomeProtoSchema.Message.GetTimeRequest.options.id] = function(message)
    log:debug("Received get time request: %s", message)
    self:sendMessage(ESPHomeProtoSchema.Message.GetTimeResponse, {
      epoch_seconds = os.time(),
    })
  end
  self._callbacks[ESPHomeProtoSchema.Message.DisconnectRequest.options.id] = function(message)
    log:warn("Received disconnect request: %s", message)
    self:sendMessage(ESPHomeProtoSchema.Message.DisconnectResponse, {})
    self:disconnect()
  end

  -- Create a new TCP client
  self._client = C4:CreateTCPClient()
    :OnConnect(function(client)
      log:debug("Connected to ESPHome device at %s:%s", self._ipAddress, self._port)
      self._connected = true

      ---@type Deferred<void, string>
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
          log:debug("Connection established (authentication request sent)")

          -- Start ping timer to keep connection alive
          self._pingTimer = C4:SetTimer(15000, function()
            self:sendPing()
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
      log:debug("Received %d byte(s) from ESPHome device", #data)
      log:trace("Incoming raw data (hex): %s", to_hex(data))
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
--- @return void
function ESPHomeClient:disconnect()
  log:trace("ESPHomeClient:disconnect()")

  -- Prevent infinite recursion - check if already disconnected
  if not self._connected and self._client == nil then
    log:trace("Already disconnected, skipping")
    return
  end

  -- Set to disconnected state first to prevent re-entry
  self._connected = false

  if self._pingTimer ~= nil then
    self._pingTimer:Cancel()
    self._pingTimer = nil
  end

  -- Store client reference and clear it before closing to prevent OnDisconnect recursion
  local client = self._client
  self._client = nil

  if client ~= nil then
    client:Close()
  end

  self._hs = nil
  self._hsState = nil
  self._buffer = ""
  self._callbacks = {}
end

--- Get device information from the ESPHome device.
--- @return Deferred<table<string, any>, string> result A promise that resolves with the device information.
function ESPHomeClient:getDeviceInfo()
  log:trace("ESPHomeClient:getDeviceInfo()")
  return self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.device_info, {})
end

--- List entities from the ESPHome device.
--- @return Deferred<table<string, table>, string> result A promise that resolves with a table of entities.
function ESPHomeClient:listEntities()
  log:trace("ESPHomeClient:listEntities()")
  --- @type Deferred<table<string, table>, string>
  local d = deferred.new()

  --- @type table<string, table>
  local entities = {}

  -- Track the callbacks that are added so they can be removed once we receive the done message
  --- @type number[]
  local addedCallbacks = {}

  for _, schema in pairs(ESPHomeProtoSchema.Message) do
    -- HACK: No reliable way to identify list_entity responses from proto definition.
    local name, _ = schema.name:match("^ListEntities(.+)Response$")
    if not IsEmpty(name) then
      -- HACK: No reliable way to identify entity types from proto definition.
      local entityType = Select(self.EntityType, (Select(schema, "options", "ifdef") or ""):match("^USE_(.+)$"))
      if IsEmpty(entityType) then
        log:warn("Unknown entity type for %s", name)
      elseif schema.name ~= "ListEntitiesDoneResponse" then
        log:trace("Registering %s entity callback", name)

        table.insert(addedCallbacks, schema.options.id)
        self._callbacks[schema.options.id] = function(message)
          log:trace("Received %s entity: %s", entityType, message)
          message.entity_type = entityType
          entities[tostring(message.key)] = message
        end
      else
        table.insert(addedCallbacks, schema.options.id)
        local function removeCallbacks()
          -- Remove the callbacks for the entities
          for _, id in ipairs(addedCallbacks) do
            self._callbacks[id] = nil
          end
        end
        -- Add a timeout to the list entities request to prevent unresolved promises
        local timeoutTimer = C4:SetTimer(ONE_SECOND * 10, function()
          log:warn("Timeout waiting for list entities response")
          removeCallbacks()
          d:reject("Timeout waiting for list entities response")
        end)
        self._callbacks[schema.options.id] = function(_)
          log:debug("Received %d entities: %s", TableLength(entities), entities)
          timeoutTimer:Cancel()
          removeCallbacks()
          d:resolve(entities)
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
    log:error("Failed to send list entities message; %s", err)
    d:reject(err)
  end)

  return d
end

--- Subscribe to state updates from the ESPHome device.
--- @param callback (fun(message: table<string, any>, schema: ProtoMessageSchema): void) The callback function to call when a state update is received.
--- @return Deferred<void, string> result A promise that resolves after subscribing to states.
function ESPHomeClient:subscribeStates(callback)
  log:trace("ESPHomeClient:subscribeStates()")
  --- @type Deferred<void, string>
  local d = deferred.new()

  for _, schema in pairs(ESPHomeProtoSchema.Message) do
    -- HACK: No reliable way to identify state responses from proto definition.
    local name, _ = schema.name:match("^(.+)StateResponse$")
    if not IsEmpty(name) then
      log:debug("Registering %s state callback", name)
      self._callbacks[schema.options.id] = function(message, messageSchema)
        log:debug("Received %s state update: %s", name, message)
        local callbackSuccess, err = pcall(callback, message, messageSchema)
        if not callbackSuccess then
          if IsEmpty(err) or type(err) ~= "string" then
            err = "unknown error"
          end
          log:error("State callback for %s failed; %s", name, err)
        end
      end
    end
  end

  self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.subscribe_states, {}):next(function()
    log:debug("Subscribe states message sent successfully")
    d:resolve(nil)
  end, function(err)
    if IsEmpty(err) or type(err) ~= "string" then
      err = "unknown error"
    end
    log:error("Failed to send subscribe states message; %s", err)
    return d:reject(err)
  end)

  return d
end

--- Subscribe to Bluetooth LE advertisements from the ESPHome proxy.
--- @param callback fun(message: table<string, any>, schema: ProtoMessageSchema): void The callback function for advertisements.
--- @param flags? number Advertisement filtering flags (optional).
--- @return Deferred<void, string> result A promise that resolves when the subscription is successful.
function ESPHomeClient:subscribeBluetoothAdvertisements(callback, flags)
  log:trace("ESPHomeClient:subscribeBluetoothAdvertisements()")

  -- Register callback for raw advertisement responses
  local rawAdvSchema = ESPHomeProtoSchema.Message.BluetoothLERawAdvertisementsResponse
  self._callbacks[rawAdvSchema.options.id] = function(message, messageSchema)
    log:debug("Received Bluetooth advertisements: %d devices", #(message.advertisements or {}))
    local callbackSuccess, err = pcall(callback, message, messageSchema)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Bluetooth advertisement callback failed; %s", err)
    end
  end

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.subscribe_bluetooth_le_advertisements,
    { flags = flags or 0 }
  )
end

--- Unsubscribe from Bluetooth LE advertisements.
--- @return Deferred<void, string> result A promise that resolves when unsubscribed.
function ESPHomeClient:unsubscribeBluetoothAdvertisements()
  log:trace("ESPHomeClient:unsubscribeBluetoothAdvertisements()")
  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.unsubscribe_bluetooth_le_advertisements,
    {}
  )
end

--- Parse raw BLE advertisement data according to Bluetooth Core Specification GAP format.
--- @param data string The raw advertisement data bytes.
--- @return table parsed A table with name, service_uuids, service_data, manufacturer_data fields.
local function parseBLEAdvertisementData(data)
  local parsed = {
    name = nil,
    service_uuids = {},
    service_data = {},
    manufacturer_data = {},
  }

  if not data or #data == 0 then
    return parsed
  end

  local pos = 1
  while pos <= #data do
    -- Read length byte
    local length = string.byte(data, pos)
    if not length or length == 0 then
      break -- End of data
    end

    pos = pos + 1
    if pos + length - 1 > #data then
      log:warn("BLE advertisement data truncated at position %d", pos)
      break
    end

    -- Read AD type
    local ad_type = string.byte(data, pos)
    pos = pos + 1
    local ad_data_len = length - 1

    -- Extract AD data
    local ad_data = string.sub(data, pos, pos + ad_data_len - 1)
    pos = pos + ad_data_len

    -- Parse based on AD type
    if ad_type == 0x08 or ad_type == 0x09 then
      -- Shortened or Complete Local Name
      parsed.name = ad_data
    elseif ad_type == 0x02 or ad_type == 0x03 then
      -- Incomplete or Complete List of 16-bit Service UUIDs
      for i = 1, #ad_data, 2 do
        local uuid16 = string.byte(ad_data, i) + string.byte(ad_data, i + 1) * 256
        table.insert(parsed.service_uuids, string.format("%04x", uuid16))
      end
    elseif ad_type == 0x06 or ad_type == 0x07 then
      -- Incomplete or Complete List of 128-bit Service UUIDs
      for i = 1, #ad_data, 16 do
        local uuid_bytes = string.sub(ad_data, i, i + 15)
        if #uuid_bytes == 16 then
          -- Format as UUID string
          local uuid = string.format(
            "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            string.byte(uuid_bytes, 4), string.byte(uuid_bytes, 3), string.byte(uuid_bytes, 2), string.byte(uuid_bytes, 1),
            string.byte(uuid_bytes, 6), string.byte(uuid_bytes, 5),
            string.byte(uuid_bytes, 8), string.byte(uuid_bytes, 7),
            string.byte(uuid_bytes, 9), string.byte(uuid_bytes, 10),
            string.byte(uuid_bytes, 11), string.byte(uuid_bytes, 12), string.byte(uuid_bytes, 13),
            string.byte(uuid_bytes, 14), string.byte(uuid_bytes, 15), string.byte(uuid_bytes, 16)
          )
          table.insert(parsed.service_uuids, uuid)
        end
      end
    elseif ad_type == 0x16 then
      -- Service Data - 16-bit UUID
      if #ad_data >= 2 then
        local uuid16 = string.byte(ad_data, 1) + string.byte(ad_data, 2) * 256
        local svc_data = string.sub(ad_data, 3)
        table.insert(parsed.service_data, {
          uuid = string.format("%04x", uuid16),
          data = svc_data
        })
      end
    elseif ad_type == 0xFF then
      -- Manufacturer Specific Data
      if #ad_data >= 2 then
        local company_id = string.byte(ad_data, 1) + string.byte(ad_data, 2) * 256
        local mfg_data = string.sub(ad_data, 3)
        table.insert(parsed.manufacturer_data, {
          uuid = company_id,
          data = mfg_data
        })
      end
    end
    -- Ignore other AD types (flags, TX power, etc.)
  end

  return parsed
end

--- Subscribe to Bluetooth LE advertisement messages.
--- This handles both decoded (BluetoothLEAdvertisementResponse) and raw (BluetoothLERawAdvertisementsResponse) formats.
--- Modern ESPHome versions (2024+) use the raw format which needs to be decoded.
--- @param callback fun(message: table<string, any>): void The callback for advertisement messages.
--- @return Deferred<void, string> result A promise that resolves when subscription starts.
function ESPHomeClient:subscribeBluetoothLEAdvertisements(callback)
  log:trace("ESPHomeClient:subscribeBluetoothLEAdvertisements()")

  -- Register callback for decoded advertisement responses (older ESPHome format)
  local advSchema = ESPHomeProtoSchema.Message.BluetoothLEAdvertisementResponse
  self._callbacks[advSchema.options.id] = function(message, messageSchema)
    log:debug("Bluetooth LE advertisement from %s: %s, RSSI: %s", message.address, message.name or "(unnamed)", message.rssi)
    local callbackSuccess, err = pcall(callback, message)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Bluetooth LE advertisement callback failed; %s", err)
    end
  end

  -- Register callback for raw advertisement responses (modern ESPHome format)
  local rawAdvSchema = ESPHomeProtoSchema.Message.BluetoothLERawAdvertisementsResponse
  self._callbacks[rawAdvSchema.options.id] = function(message, messageSchema)
    log:debug("Received raw Bluetooth advertisements: %d packets", #(message.advertisements or {}))

    -- Decode each raw advertisement
    for _, rawAdv in ipairs(message.advertisements or {}) do
      -- Decode the raw advertisement protobuf data
      local success, decoded = pcall(pb.decode, ESPHomeProtoSchema,
        ESPHomeProtoSchema.Message.BluetoothLERawAdvertisement, rawAdv)

      if success and decoded then
        -- Parse the raw BLE advertisement data to extract name, services, etc.
        local parsed = parseBLEAdvertisementData(decoded.data or "")

        -- Merge parsed fields into decoded message
        decoded.name = parsed.name
        decoded.service_uuids = parsed.service_uuids
        decoded.service_data = parsed.service_data
        decoded.manufacturer_data = parsed.manufacturer_data

        log:debug("Decoded advertisement from %s: %s, RSSI: %s",
          tostring(decoded.address), decoded.name or "(unnamed)", decoded.rssi)

        -- Call the user's callback with the decoded advertisement
        local callbackSuccess, err = pcall(callback, decoded)
        if not callbackSuccess then
          if IsEmpty(err) or type(err) ~= "string" then
            err = "unknown error"
          end
          log:error("Bluetooth LE advertisement callback failed; %s", err)
        end
      else
        log:warn("Failed to decode raw advertisement: %s", tostring(decoded))
      end
    end
  end

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.subscribe_bluetooth_le_advertisements,
    {}
  )
end

--- Connect to a Bluetooth device via the ESPHome proxy.
--- @param address number The 48-bit Bluetooth MAC address as a number.
--- @param callback fun(message: table<string, any>, schema: ProtoMessageSchema): void The callback for connection responses.
--- @param addressType? number The address type (optional).
--- @param withCache? boolean Use cached services (default true).
--- @return Deferred<void, string> result A promise that resolves when the connection request is sent.
function ESPHomeClient:bluetoothDeviceConnect(address, callback, addressType, withCache)
  log:trace("ESPHomeClient:bluetoothDeviceConnect(%s)", address)

  -- Register callback for connection responses
  local connSchema = ESPHomeProtoSchema.Message.BluetoothDeviceConnectionResponse
  if not self._callbacks[connSchema.options.id] then
    self._callbacks[connSchema.options.id] = {}
  end
  -- Store callback by address since multiple devices can be connected
  self._callbacks[connSchema.options.id][address] = function(message, messageSchema)
    log:debug("Bluetooth device connection response for %s: connected=%s, mtu=%s, error=%s",
      address, message.connected, message.mtu, message.error)
    local callbackSuccess, err = pcall(callback, message, messageSchema)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Bluetooth connection callback failed; %s", err)
    end
  end

  local requestType = (withCache == false)
    and ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITHOUT_CACHE
    or ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE

  local body = {
    address = address,
    request_type = requestType,
  }

  if addressType ~= nil then
    body.has_address_type = true
    body.address_type = addressType
  end

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_device_request,
    body
  )
end

--- Disconnect from a Bluetooth device.
--- @param address number The 48-bit Bluetooth MAC address as a number.
--- @return Deferred<void, string> result A promise that resolves when the disconnect request is sent.
function ESPHomeClient:bluetoothDeviceDisconnect(address)
  log:trace("ESPHomeClient:bluetoothDeviceDisconnect(%s)", address)

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_device_request,
    {
      address = address,
      request_type = ESPHomeProtoSchema.Enum.BluetoothDeviceRequestType.BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT,
    }
  )
end

--- Get GATT services for a connected Bluetooth device.
--- @param address number The 48-bit Bluetooth MAC address as a number.
--- @param callback fun(services: table[], done: boolean): void The callback for service responses.
--- @return Deferred<void, string> result A promise that resolves when the request is sent.
function ESPHomeClient:bluetoothGattGetServices(address, callback)
  log:trace("ESPHomeClient:bluetoothGattGetServices(%s)", address)

  -- Register callbacks for service discovery
  local servicesSchema = ESPHomeProtoSchema.Message.BluetoothGATTGetServicesResponse
  local doneSchema = ESPHomeProtoSchema.Message.BluetoothGATTGetServicesDoneResponse

  if not self._callbacks[servicesSchema.options.id] then
    self._callbacks[servicesSchema.options.id] = {}
  end
  if not self._callbacks[doneSchema.options.id] then
    self._callbacks[doneSchema.options.id] = {}
  end

  self._callbacks[servicesSchema.options.id][address] = function(message, messageSchema)
    log:debug("Bluetooth GATT services response for %s: %d services", address, #(message.services or {}))
    local callbackSuccess, err = pcall(callback, message.services or {}, false)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Bluetooth GATT services callback failed; %s", err)
    end
  end

  self._callbacks[doneSchema.options.id][address] = function(message, messageSchema)
    log:debug("Bluetooth GATT service discovery done for %s", address)
    local callbackSuccess, err = pcall(callback, {}, true)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Bluetooth GATT services done callback failed; %s", err)
    end
  end

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_get_services,
    { address = address }
  )
end

--- Read a GATT characteristic.
--- @param address number The 48-bit Bluetooth MAC address as a number.
--- @param handle number The characteristic handle.
--- @param callback fun(data: string, error: number|nil): void The callback for read response.
--- @return Deferred<void, string> result A promise that resolves when the request is sent.
function ESPHomeClient:bluetoothGattRead(address, handle, callback)
  log:trace("ESPHomeClient:bluetoothGattRead(%s, %s)", address, handle)

  -- Register callbacks for read responses
  local readSchema = ESPHomeProtoSchema.Message.BluetoothGATTReadResponse
  local errorSchema = ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse

  if not self._callbacks[readSchema.options.id] then
    self._callbacks[readSchema.options.id] = {}
  end
  if not self._callbacks[errorSchema.options.id] then
    self._callbacks[errorSchema.options.id] = {}
  end

  local callbackKey = address .. "_" .. handle

  self._callbacks[readSchema.options.id][callbackKey] = function(message, messageSchema)
    log:debug("Bluetooth GATT read response for %s handle %s: %d bytes", address, handle, #(message.data or ""))
    local callbackSuccess, err = pcall(callback, message.data or "", nil)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Bluetooth GATT read callback failed; %s", err)
    end
    -- Clear one-time callback
    self._callbacks[readSchema.options.id][callbackKey] = nil
  end

  self._callbacks[errorSchema.options.id][callbackKey] = function(message, messageSchema)
    log:warn("Bluetooth GATT error for %s handle %s: error=%s", address, handle, message.error)
    local callbackSuccess, err = pcall(callback, "", message.error or -1)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Bluetooth GATT error callback failed; %s", err)
    end
    -- Clear one-time callback
    self._callbacks[errorSchema.options.id][callbackKey] = nil
  end

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_read,
    { address = address, handle = handle }
  )
end

--- Write to a GATT characteristic.
--- @param address number The 48-bit Bluetooth MAC address as a number.
--- @param handle number The characteristic handle.
--- @param data string The data to write (binary string).
--- @param response? boolean Whether to wait for a write response (default false).
--- @param callback? fun(success: boolean, error: number|nil): void Optional callback for write response.
--- @return Deferred<void, string> result A promise that resolves when the request is sent.
function ESPHomeClient:bluetoothGattWrite(address, handle, data, response, callback)
  log:trace("ESPHomeClient:bluetoothGattWrite(%s, %s, %d bytes, response=%s)", address, handle, #data, response)

  if callback then
    local writeSchema = ESPHomeProtoSchema.Message.BluetoothGATTWriteResponse
    local errorSchema = ESPHomeProtoSchema.Message.BluetoothGATTErrorResponse

    if not self._callbacks[writeSchema.options.id] then
      self._callbacks[writeSchema.options.id] = {}
    end
    if not self._callbacks[errorSchema.options.id] then
      self._callbacks[errorSchema.options.id] = {}
    end

    local callbackKey = address .. "_" .. handle

    self._callbacks[writeSchema.options.id][callbackKey] = function(message, messageSchema)
      log:debug("Bluetooth GATT write response for %s handle %s", address, handle)
      local callbackSuccess, err = pcall(callback, true, nil)
      if not callbackSuccess then
        if IsEmpty(err) or type(err) ~= "string" then
          err = "unknown error"
        end
        log:error("Bluetooth GATT write callback failed; %s", err)
      end
      self._callbacks[writeSchema.options.id][callbackKey] = nil
    end

    self._callbacks[errorSchema.options.id][callbackKey] = function(message, messageSchema)
      log:warn("Bluetooth GATT write error for %s handle %s: error=%s", address, handle, message.error)
      local callbackSuccess, err = pcall(callback, false, message.error or -1)
      if not callbackSuccess then
        if IsEmpty(err) or type(err) ~= "string" then
          err = "unknown error"
        end
        log:error("Bluetooth GATT write error callback failed; %s", err)
      end
      self._callbacks[errorSchema.options.id][callbackKey] = nil
    end
  end

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_write,
    {
      address = address,
      handle = handle,
      response = response or false,
      data = data,
    }
  )
end

--- Subscribe to GATT characteristic notifications.
--- @param address number The 48-bit Bluetooth MAC address as a number.
--- @param handle number The characteristic handle.
--- @param enable boolean Enable or disable notifications.
--- @param callback fun(data: string): void The callback for notification data.
--- @return Deferred<void, string> result A promise that resolves when the request is sent.
function ESPHomeClient:bluetoothGattNotify(address, handle, enable, callback)
  log:trace("ESPHomeClient:bluetoothGattNotify(%s, %s, %s)", address, handle, enable)

  if enable and callback then
    local notifyDataSchema = ESPHomeProtoSchema.Message.BluetoothGATTNotifyDataResponse
    local notifyRespSchema = ESPHomeProtoSchema.Message.BluetoothGATTNotifyResponse

    if not self._callbacks[notifyDataSchema.options.id] then
      self._callbacks[notifyDataSchema.options.id] = {}
    end
    if not self._callbacks[notifyRespSchema.options.id] then
      self._callbacks[notifyRespSchema.options.id] = {}
    end

    local callbackKey = address .. "_" .. handle

    -- Register persistent callback for notifications
    self._callbacks[notifyDataSchema.options.id][callbackKey] = function(message, messageSchema)
      log:debug("Bluetooth GATT notify data for %s handle %s: %d bytes", address, handle, #(message.data or ""))
      local callbackSuccess, err = pcall(callback, message.data or "")
      if not callbackSuccess then
        if IsEmpty(err) or type(err) ~= "string" then
          err = "unknown error"
        end
        log:error("Bluetooth GATT notify callback failed; %s", err)
      end
    end

    -- Log when notification subscription is confirmed
    self._callbacks[notifyRespSchema.options.id][callbackKey] = function(message, messageSchema)
      log:debug("Bluetooth GATT notify subscription confirmed for %s handle %s", address, handle)
      -- Clear this one-time confirmation callback
      self._callbacks[notifyRespSchema.options.id][callbackKey] = nil
    end
  else
    -- Unsubscribe - clear the callback
    local notifyDataSchema = ESPHomeProtoSchema.Message.BluetoothGATTNotifyDataResponse
    if self._callbacks[notifyDataSchema.options.id] then
      local callbackKey = address .. "_" .. handle
      self._callbacks[notifyDataSchema.options.id][callbackKey] = nil
    end
  end

  return self:callServiceMethod(
    ESPHomeProtoSchema.RPC.APIConnection.bluetooth_gatt_notify,
    {
      address = address,
      handle = handle,
      enable = enable,
    }
  )
end

--- Send a hello message to the ESPHome device.
--- @return Deferred<table, string> result A promise that resolves when the hello message is sent.
function ESPHomeClient:sendHello()
  log:trace("ESPHomeClient:sendHello()")
  local d = self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.hello, {
    client_info = "Control4",
    api_version_major = 1,
    api_version_minor = 0,
  })

  --- @cast d Deferred<table, string>
  return d
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
  --- @type Deferred<table<string,any>, string>
  local d = deferred.new()

  if not self:isConnected() then
    return d:reject("Not connected to ESPHome device")
  end
  --- @cast self._client -nil

  -- Hello message
  local frame = "\x01\x00\x00"

  local timeoutTimer = C4:SetTimer(ONE_SECOND * 5, function()
    -- Remove the callback for the response
    self._callbacks[NoiseProtocolCallback.HELLO] = nil
    self._hsState = NoiseState.ERROR
    d:reject("Timeout waiting for SERVER_HELLO response")
  end)
  self._callbacks[NoiseProtocolCallback.HELLO] = function(message)
    log:debug("Received SERVER_HELLO: node=%s, mac=%s", message.node, message.mac_address)
    timeoutTimer:Cancel()
    d:resolve(nil)
  end

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

  local timeoutTimer = C4:SetTimer(ONE_SECOND * 5, function()
    self:checkHandshakeState(NoiseState.HANDSHAKE)

    -- Remove the callback for the response
    self._callbacks[NoiseProtocolCallback.HANDSHAKE] = nil
    self._hsState = NoiseState.ERROR
    d:reject("Timeout waiting for HANDSHAKE response")
  end)
  self._callbacks[NoiseProtocolCallback.HANDSHAKE] = function(success, message)
    timeoutTimer:Cancel()
    self:checkHandshakeState(NoiseState.HANDSHAKE)

    if not success then
      log:error("HANDSHAKE failed: %s", message)
      self._hsState = NoiseState.ERROR
      return d:reject(message)
    end

    assert(self._hs):read_handshake_message(message)

    if not self._hs.handshake_complete then
      log:error("Handshake not completed after reading handshake message")
      self._hsState = NoiseState.ERROR
      return d:reject("Handshake not completed")
    end

    log:debug("Handshake completed successfully")
    self._hsState = NoiseState.READY
    d:resolve(nil)
  end

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
  self._callbacks[ESPHomeProtoSchema.Message.AuthenticationResponse.options.id] = function(message)
    -- Remove callback immediately
    self._callbacks[ESPHomeProtoSchema.Message.AuthenticationResponse.options.id] = nil

    if message.invalid_password then
      log:error("Connect unsuccessful (invalid password)")
      -- Set fatal error - subsequent operations will fail with this error
      self._fatalError = "Invalid password"
      self:disconnect()
    else
      log:debug("Connect successful")
    end
  end

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
  local d = self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.ping, {}):next(function()
    log:info("Ping successful")
  end, function(err)
    if IsEmpty(err) or type(err) ~= "string" then
      err = "unknown error"
    end
    log:error("Ping failed; %s", err)
    return reject(err)
  end)

  --- @cast d Deferred<void, string>
  return d
end

--- Call a service method on the ESPHome device.
--- @param method ProtoServiceMethodSchema The method to call.
--- @param body? table The request body (optional).
--- @param timeout? number The timeout for the request in milliseconds (optional). Only non-void methods support this. Default is 5 seconds.
--- @return Deferred<table|nil, string> result A promise that resolves with the response.
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

--- Send a message to the ESPHome device.
--- @param messageSchema ProtoMessageSchema The message to send.
--- @param body? table<string, any> The message body (optional).
--- @param responseSchema? ProtoMessageSchema The expected response schema (optional).
--- @param timeout? number The timeout for the response in milliseconds (optional).
--- @return Deferred<table|nil, string> result A promise that resolves when the message is sent (and response received if expected).
function ESPHomeClient:sendMessage(messageSchema, body, responseSchema, timeout)
  log:trace("ESPHomeClient:sendMessage(%s, %s, %s, %s)", messageSchema.name, body, responseSchema, timeout)
  --- @type Deferred<table|nil, string>
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
  if responseSchema then
    local timeoutTimer = C4:SetTimer(timeout or ONE_SECOND * 5, function()
      log:warn("Timeout waiting for response to %s", messageSchema.name)
      -- Remove the callback for the response
      self._callbacks[responseSchema.options.id] = nil
      d:reject("Timeout waiting for response to " .. messageSchema.name)
    end)
    self._callbacks[responseSchema.options.id] = function(message)
      log:debug("Received response to %s", messageSchema.name)
      timeoutTimer:Cancel()
      d:resolve(message)
    end
  else
    -- If no response is expected, resolve immediately after sending
    d:resolve(nil)
  end

  log:debug("Sending message %s with %d byte(s) of data", messageSchema.name, #encodedData)
  log:ultra("Outgoing frame (hex): %s", to_hex(frame))
  self._client:Write(frame)
  return d
end

--- Process the current data buffer and decodes any valid packets recursively.
--- Currently only plaintext packets are supported.
--- @return void
function ESPHomeClient:_processBuffer()
  log:trace("ESPHomeClient:_processBuffer()")
  -- We need at least 3 bytes to begin processing a frame
  if self._buffer == nil or #self._buffer < 3 then
    return
  end
  log:ultra("Processing buffer (hex): %s", to_hex(self._buffer))

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
    -- Process the payload size and message type
    local payloadSize, payloadSizeEndPos = pb.decode_varint(self._buffer, indicatorEndPos)
    local messageType, messageTypeEndPos = pb.decode_varint(self._buffer, payloadSizeEndPos)

    -- Extract the payload data
    local totalFrameSize = messageTypeEndPos + payloadSize - 1
    if #self._buffer < totalFrameSize then
      -- This can happen if the message is split across multiple tcp reads
      log:debug("Incomplete plaintext frame (%d bytes expected, %d bytes received)", totalFrameSize, #self._buffer)
      return
    end
    local payload = string.sub(self._buffer, messageTypeEndPos, totalFrameSize)
    local payloadEndPos = totalFrameSize + 1

    -- Remove the processed data from the buffer
    self._buffer = string.sub(self._buffer, payloadEndPos)

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

    local encryptedSize = bit16.be_bytes_to_u16(self._buffer:sub(indicatorEndPos, indicatorEndPos + 1))
    local encryptedSizeEndPos = indicatorEndPos + 2

    -- Check if we have the complete frame in the buffer
    local totalFrameSize = encryptedSizeEndPos + encryptedSize - 1
    if #self._buffer < totalFrameSize then
      -- This can happen if the message is split across multiple tcp reads
      log:debug("Incomplete noise frame (%d bytes expected, %d bytes received)", totalFrameSize, #self._buffer)
      return
    end

    -- Extract the encrypted payload
    local encryptedPayload = string.sub(self._buffer, encryptedSizeEndPos, totalFrameSize)
    local encryptedPayloadEndPos = totalFrameSize + 1

    -- Remove the processed data from the buffer
    self._buffer = string.sub(self._buffer, encryptedPayloadEndPos)

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
      local macAddress = string.sub(encryptedPayload, nodeNullTermPos + 1, macNullTermPos - 1)

      log:debug("SERVER_HELLO message - Node: %s, MAC: %s", nodeName, macAddress)

      -- Call the callback for SERVER_HELLO if registered
      if type(self._callbacks[NoiseProtocolCallback.HELLO]) == "function" then
        self._callbacks[NoiseProtocolCallback.HELLO]({
          node = nodeName,
          mac_address = macAddress,
        })
      end
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
      if type(self._callbacks[NoiseProtocolCallback.HANDSHAKE]) == "function" then
        self._callbacks[NoiseProtocolCallback.HANDSHAKE](success, message)
      end
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

      log:trace("READY message - %s", success, to_hex(decryptedPayload))

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
    -- Unknown indicator
    log:warn("Invalid esphome frame (unsupported indicator %02X)", indicator)
    return
  end

  -- Continue processing any remaining data in the buffer
  self:_processBuffer()
end

function ESPHomeClient:_processPayload(messageType, payload)
  log:trace("ESPHomeClient:_processPayload(%s, %d bytes)", messageType, #payload)

  -- Find the message schema
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
    log:warn("Invalid esphome frame (failed to decode message type %s): %s", messageType, message)
    return
  end

  log:debug("Decoded esphome message: %s(%s)", messageSchema.name, message)

  -- Call any registered callbacks for the message type
  if type(self._callbacks[messageType]) == "function" then
    log:debug("Calling registered callback for message type %s", messageType)
    local callbackSuccess, err = pcall(self._callbacks[messageType], message, messageSchema)
    if not callbackSuccess then
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Callback for message type %s failed; %s", messageType, err)
    end
  elseif type(self._callbacks[messageType]) == "table" then
    -- Handle nested callbacks (e.g., Bluetooth callbacks keyed by address or address_handle)
    log:debug("Message type %s has nested callbacks, looking for matching key", messageType)

    -- Try different callback key strategies based on the message content
    local callbackKeys = {}

    -- Strategy 1: Just address (for connection responses)
    if message.address then
      table.insert(callbackKeys, message.address)
      log:debug("  Trying address key: %s (type: %s)", message.address, type(message.address))
    end

    -- Strategy 2: address_handle (for GATT operations)
    if message.address and message.handle then
      local key = message.address .. "_" .. message.handle
      table.insert(callbackKeys, key)
      log:debug("  Trying address_handle key: %s", key)
    end

    -- Debug: show all registered keys
    local registered_keys = {}
    for key in pairs(self._callbacks[messageType]) do
      table.insert(registered_keys, tostring(key))
    end
    log:debug("  Registered callback keys: %s", table.concat(registered_keys, ", "))

    -- Try each callback key
    local callback_found = false
    for _, key in ipairs(callbackKeys) do
      if type(self._callbacks[messageType][key]) == "function" then
        log:debug("  Found matching callback for key: %s", key)
        callback_found = true
        local callbackSuccess, err = pcall(self._callbacks[messageType][key], message, messageSchema)
        if not callbackSuccess then
          if IsEmpty(err) or type(err) ~= "string" then
            err = "unknown error"
          end
          log:error("Callback for message type %s key %s failed; %s", messageType, key, err)
        end
        break
      end
    end

    if not callback_found then
      log:warn("No matching callback found for message type %s with any of the attempted keys", messageType)
    end
  end
end

return ESPHomeClient
