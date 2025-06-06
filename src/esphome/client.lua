--- @module "esphome.client"
--- ESPHome API Client for Control4.
--- This module provides a Lua implementation for connecting to ESPHome devices
--- using the native API protocol over TCP with protobuf encoding.

local log = require("lib.logging")
local Protobuf = require("lib.protobuf")
local ESPHomeProtoSchema = require("esphome.proto-schema")
local deferred = require("vendor.deferred")

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
    _authenticated = false, --- @type boolean Indicates if the client is authenticated.
    _ipAddress = nil, --- @type string|nil The IP address of the ESPHome device.
    _port = 6053, --- @type number The port of the ESPHome device.
    _password = nil, --- @type string|nil The password for the ESPHome device.
    _buffer = "", --- @type string The buffer for incoming data.
    _callbacks = {}, --- @type table<number, (fun(message: table<string, any>, schema: ProtoMessageSchema): void)|nil> The callback for the next expected response.
    _pingTimer = nil, --- @type C4LuaTimer|nil The timer for sending ping messages.
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties ESPHomeClient
  return properties
end

--- Set the configuration for the ESPHome API client. If the client is already
--- connected, it will disconnect before setting the configuration.
--- @param ipAddress string The IP address of the ESPHome device.
--- @param port number The port of the ESPHome device.
--- @param password? string The password for the ESPHome device (optional).
--- @return ESPHomeClient self The ESPHomeClient instance.
function ESPHomeClient:setConfig(ipAddress, port, password)
  log:trace("ESPHomeClient:setConfig(%s, %s, %s)", ipAddress, port, password and "***" or nil)
  self:disconnect()
  self._ipAddress = not IsEmpty(ipAddress) and ipAddress or nil
  self._port = toport(port) or 6053
  self._password = not IsEmpty(password) and password or nil
  return self
end

--- Check if the ESPHome API client is configured with an IP address and port.
--- @return boolean configured True if the client is configured, false otherwise.
function ESPHomeClient:isConfigured()
  log:trace("ESPHomeClient:isConfigured()")
  return not IsEmpty(self._ipAddress) and toport(self._port) ~= nil
end

--- Check if the client is connected to the ESPHome device.
--- @param authRequired? boolean Whether client needs to be authenticated (optional).
--- @return boolean connected True if the client is connected, false otherwise.
function ESPHomeClient:isConnected(authRequired)
  log:trace("ESPHomeClient:isConnected(%s)", authRequired)
  return self._client ~= nil and self._connected and (not authRequired or self._authenticated)
end

--- Connect to the ESPHome device.
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

      self
        :sendHello()
        :next(function()
          log:debug("Hello message sent successfully")
          return self:sendConnect()
        end, function(err)
          log:error("Failed to send hello message: %s", err)
          return reject(err)
        end)
        :next(function()
          log:debug("Successfully authenticated with ESPHome device")
          self._authenticated = true

          -- Start ping timer to keep connection alive
          self._pingTimer = C4:SetTimer(15000, function()
            self:sendPing()
          end, true)

          d:resolve(true)
        end, function(err)
          log:error("Failed to authenticate with ESPHome device: %s", err)
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
      log:trace("Incoming raw data (hex): %s", (data:gsub(".", function(c)
        return string.format("%02X ", string.byte(c))
      end)))
      self._buffer = self._buffer .. data

      self:_proccessBuffer()

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

  if self._pingTimer ~= nil then
    self._pingTimer:Cancel()
    self._pingTimer = nil
  end

  if self._client ~= nil then
    self._client:Close()
    self._client = nil
  end

  self._connected = false
  self._authenticated = false
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

--- Send a hello message to the ESPHome device.
--- @return Deferred<table, string> result A promise that resolves when the hello message is sent.
function ESPHomeClient:sendHello()
  log:trace("ESPHomeClient:sendHello()")
  local d = self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.hello, {
    client_info = "Control4",
    api_version_major = 1,
    api_version_minor = 0,
  }, false)

  --- @cast d Deferred<table, string>
  return d
end

--- Send a connect message to the ESPHome device.
--- @return Deferred<void, string> result A promise that resolves when the connect response is received.
function ESPHomeClient:sendConnect()
  log:trace("ESPHomeClient:sendConnect()")
  local d = self
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.connect, {
      password = not IsEmpty(self._password) and self._password or "",
    }, false)
    :next(function(message)
      if message.invalid_password then
        log:error("Connect unsuccessful (invalid password)")
        return reject("Invalid password")
      else
        log:debug("Connect successful")
      end
    end, function(err)
      if IsEmpty(err) or type(err) ~= "string" then
        err = "unknown error"
      end
      log:error("Connect failed; %s", err)
      return reject(err)
    end)

  --- @cast d Deferred<void, string>
  return d
end

--- Send a ping message to the ESPHome device.
--- @return Deferred<void, string> result A promise that resolves when the ping response is received.
function ESPHomeClient:sendPing()
  log:trace("ESPHomeClient:sendPing()")
  local d = self:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.ping, {}, false):next(function()
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
--- @param authRequired? boolean Whether authentication is required to call the method (optional).
--- @param timeout? number The timeout for the request in milliseconds (optional). Only non-void methods support this. Default is 5 seconds.
--- @return Deferred<table|nil, string> result A promise that resolves with the response.
function ESPHomeClient:callServiceMethod(method, body, authRequired, timeout)
  log:trace("ESPHomeClient:callServiceMethod(%s, %s, %s)", method.method, body, authRequired)
  if authRequired == nil then
    authRequired = true
  end
  if timeout == nil then
    timeout = ONE_SECOND * 5
  end

  --- @type Deferred<table|nil, string>
  local d = deferred.new()

  if not self:isConnected(authRequired) then
    return d:reject("Not connected to ESPHome device")
  end
  --- @cast self._client -nil

  -- Encode the input message
  local messageType = tointeger(Select(method.inputType, "options", "id"))
  if IsEmpty(messageType) then
    return d:reject("Invalid request message ID")
  end
  --- @cast messageType integer

  -- Encode parts and build the frame (see _proccessBuffer for frame details)
  local indicator = string.char(0) -- Only plaintext is supported
  local encodedMessageType = Protobuf.encode_varint(messageType)
  local encodedData = Protobuf.encode(ESPHomeProtoSchema, method.inputType, body)
  local encodedPayloadSize = Protobuf.encode_varint(#encodedData)
  local frame = indicator .. encodedPayloadSize .. encodedMessageType .. encodedData

  -- Store callback for response if one is expected
  if method.outputType.name ~= ESPHomeProtoSchema.Message.void.name then
    local timeoutTimer = C4:SetTimer(timeout, function()
      log:warn("Timeout waiting for %s.%s() response", method.service, method.method)
      -- Remove the callback for the response
      self._callbacks[method.outputType.options.id] = nil
      d:reject("Timeout waiting for " .. method.service .. "." .. method.method .. "() response")
    end)
    self._callbacks[method.outputType.options.id] = function(message)
      log:trace("Received response for %s.%s()", method.service, method.method)
      timeoutTimer:Cancel()
      d:resolve(message)
    end
  else
    -- If the method has no output type, we don't need to wait for a response
    d:resolve(nil)
  end
  log:debug("Calling service method %s.%s() with %d byte(s) of data", method.service, method.method, #encodedData)
  log:trace("Outgoing raw data (hex): %s", (frame:gsub(".", function(c)
    return string.format("%02X ", string.byte(c))
  end)))
  self._client:Write(frame)
  return d
end

--- Send a message to the ESPHome device.
--- @param messageSchema ProtoMessageSchema The message to send.
--- @param body? table The message body (optional).
--- @return Deferred<void, string> result A promise that resolves when the message is sent.
function ESPHomeClient:sendMessage(messageSchema, body)
  log:trace("ESPHomeClient:sendMessage(%s, %s)", messageSchema, body)
  --- @type Deferred<void, string>
  local d = deferred.new()

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

  -- Encode parts and build the frame (see _proccessBuffer for frame details)
  local indicator = string.char(0) -- Only plaintext is supported
  local encodedMessageType = Protobuf.encode_varint(messageType)
  local encodedData = Protobuf.encode(ESPHomeProtoSchema, messageSchema, body)
  local encodedPayloadSize = Protobuf.encode_varint(#encodedData)
  local frame = indicator .. encodedPayloadSize .. encodedMessageType .. encodedData

  self._client:Write(frame)
  return d:resolve(nil)
end

--- Process the current data buffer and decodes any valid packets recursively.
--- Currently only plaintext packets are supported.
--- @return void
function ESPHomeClient:_proccessBuffer()
  log:trace("ESPHomeClient:_proccessBuffer()")
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
  if IsEmpty(self._buffer) then
    return
  end

  -- Process the indicator
  local indicator, indicatorEndPos = Protobuf.decode_varint(self._buffer, 1)
  if indicator ~= 0 then
    log:warn("Invalid esphome frame (unsupported indicator %02X)", indicator)
    self._buffer = ""
    return
  end

  -- Process the payload size and message type
  local payloadSize, payloadSizeEndPos = Protobuf.decode_varint(self._buffer, indicatorEndPos)
  local messageType, messageTypeEndPos = Protobuf.decode_varint(self._buffer, payloadSizeEndPos)
  local messageSchema = nil
  for _, schema in pairs(ESPHomeProtoSchema.Message) do
    if messageType == Select(schema, "options", "id") then
      messageSchema = schema
      break
    end
  end
  if messageSchema == nil then
    log:warn("Invalid esphome frame (unknown message type %d)", messageType)
    self._buffer = ""
    return
  end

  -- Extract the payload data
  local data = string.sub(self._buffer, messageTypeEndPos, messageTypeEndPos + payloadSize - 1)
  if #data ~= payloadSize then
    -- This can happen if the message is split across multiple tcp reads
    log:debug("Incomplete esphome frame (%d bytes expected, %d bytes received)", payloadSize, #data)
    return
  end

  -- Remove the processed data from the buffer
  self._buffer = string.sub(self._buffer, messageTypeEndPos + payloadSize)

  -- Decode the payload data
  local success, message = pcall(Protobuf.decode, ESPHomeProtoSchema, messageSchema, data)
  if not success then
    log:warn(
      "Invalid esphome frame (failed to decode message type %s); raw data: %s",
      messageType,
      message,
      (data:gsub(".", function(c)
        return string.format("%02X ", string.byte(c))
      end))
    )
    self._buffer = ""
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
  end

  -- Continue processing any remaining data in the buffer
  self:_proccessBuffer()
end

return ESPHomeClient
