--- ESPHome Yale/August BLE Lock Driver
--- Hybrid of esphome_lock (lock proxy) and esphome_switchbot (BLE GATT).
--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_yale.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

JSON = require("JSON")

local deferred = require("deferred")
local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local persist = require("lib.persist")
local constants = require("constants")
local UUID = require("esphome.ble.uuid")
local yale_protocol = require("esphome.ble.yale_protocol")
local http = require("lib.http")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- Binding IDs
local PROXY_BINDING = 5001
local ESPHOME_BINDING = 5002

--- Namespace for dynamic bindings
local BINDINGS_NAMESPACE = "Yale"

--- Disconnect delay after command completion (ms)
local DISCONNECT_DELAY_MS = 5000

--- Keepalive interval for persistent connection (ms) - poll status to keep BLE alive
local KEEPALIVE_INTERVAL_MS = 20000 -- 20 seconds

--- Status poll delay after lock/unlock command (ms)
local STATUS_POLL_DELAY_MS = 1500

--- Post-operation jam detection delay (ms) - re-query lock status to catch late jams
local JAM_CHECK_DELAY_MS = 10000

--- Handshake timeout (ms) - abort and retry if lock doesn't respond
local HANDSHAKE_TIMEOUT_MS = 10000

--- Minimum delay between GATT writes (ms) per Yale BLE protocol
local GATT_WRITE_COOLDOWN_MS = 250

--- August Cloud API
local AUGUST_API = {
  BASE_URL = "https://api-production.august.com",
  API_KEY = "7cab4bbd-2693-4fc1-b99b-dec0fb20f9d4",
  HEADERS = {
    ["Content-Type"] = "application/json",
    ["Accept-Version"] = "0.0.1",
    ["User-Agent"] = "August/Luna-3.2.2 (Android; SDK 31; Pixel 5)",
  },
}

--------------------------------------------------------------------------------
-- Handshake State
--------------------------------------------------------------------------------

--- @enum HandshakeState
local HANDSHAKE_STATE = {
  IDLE = 0,
  AWAITING_KEY_EXCHANGE_RESPONSE = 1,
  AWAITING_INIT_RESPONSE = 2,
  COMPLETE = 3,
}

--------------------------------------------------------------------------------
-- Connection Mode
--------------------------------------------------------------------------------

--- @enum ConnectionMode
local CONNECTION_MODE = {
  PERSISTENT = "Persistent",
  POLL = "Poll",
}

--- Current connection mode
--- @type string
local connectionMode = CONNECTION_MODE.POLL

--------------------------------------------------------------------------------
-- Global State
--------------------------------------------------------------------------------

--- Connection state
--- @type HandshakeState
local handshakeState = HANDSHAKE_STATE.IDLE
--- @type string|nil 16 random bytes for handshake
local handshakeKeys = nil
--- @type YaleSecureSession|nil
local secureSession = nil
--- @type YaleSession|nil
local session = nil

--- GATT notification subscription tracking
--- @type boolean
local secureReadSubscribed = false
--- @type boolean
local regularReadSubscribed = false

--- Pending command to execute after handshake
--- @type string|nil "lock", "unlock", "status"
local pendingCommand = nil

--- What command response we're awaiting (nil = none)
--- @type string|nil "lock", "unlock", "status_lock", "status_door", "status_battery"
local awaitingResponse = nil

--- GATT write queue for 250ms cooldown enforcement
--- @type table[]
local gattWriteQueue = {}

--- Current lock status for toggle logic
--- @type string|nil "locked", "unlocked", etc.
local currentLockStatus = nil

--- Whether DoorSense is detected as configured on the lock
--- @type boolean|nil nil = unknown, true = configured, false = not configured
local doorSenseConfigured = nil

--- Reconnect backoff tracking (Persistent mode)
--- @type integer
local reconnectAttempts = 0
local MAX_RECONNECT_ATTEMPTS = 5
local BASE_RECONNECT_MS = 5000

--- Whether initial status query has been triggered (for Poll mode first-advertisement)
--- @type boolean
local initialStatusTriggered = false

--- August cloud session token (for key fetching)
--- @type string|nil
local augustSessionToken = nil

--------------------------------------------------------------------------------
-- Handle Management
--------------------------------------------------------------------------------

--- Get BLE handles from persist
--- @return integer|nil writeHandle
--- @return integer|nil readHandle
--- @return integer|nil secureWriteHandle
--- @return integer|nil secureReadHandle
local function getHandles()
  return tointeger(persist:get("WRITE_HANDLE")),
    tointeger(persist:get("READ_HANDLE")),
    tointeger(persist:get("SECURE_WRITE_HANDLE")),
    tointeger(persist:get("SECURE_READ_HANDLE"))
end

--- Save BLE handles to persist
local function saveHandles(writeHandle, readHandle, secureWriteHandle, secureReadHandle)
  persist:set("WRITE_HANDLE", writeHandle)
  persist:set("READ_HANDLE", readHandle)
  persist:set("SECURE_WRITE_HANDLE", secureWriteHandle)
  persist:set("SECURE_READ_HANDLE", secureReadHandle)
end

--- Reset connection state
--- @param clearHandles boolean|nil If true, also clear persisted BLE handles
local function resetConnectionState(clearHandles)
  log:trace("resetConnectionState(%s)", clearHandles)
  handshakeState = HANDSHAKE_STATE.IDLE
  handshakeKeys = nil
  secureSession = nil
  session = nil
  secureReadSubscribed = false
  regularReadSubscribed = false
  pendingCommand = nil
  awaitingResponse = nil
  gattWriteQueue = {}
  CancelTimer("GattWriteDrain")
  CancelTimer("HandshakeTimeout")
  CancelTimer("Keepalive")
  CancelTimer("Reconnect")
  CancelTimer("PollCycle")
  CancelTimer("JamCheck")
  CancelTimer("CleanDisconnect")
  CancelTimer("DisconnectDelay")
  CancelTimer("StatusPoll")
  CancelTimer("DoorPoll")
  CancelTimer("BatteryPoll")

  if clearHandles then
    saveHandles(nil, nil, nil, nil)
  end
end

local findCharacteristicHandle = UUID.findCharacteristicHandle

--------------------------------------------------------------------------------
-- GATT Write Helpers
--------------------------------------------------------------------------------

--- Send the next queued GATT write and schedule the next drain
local function drainGattWriteQueue()
  if #gattWriteQueue == 0 then
    return
  end

  local entry = table.remove(gattWriteQueue, 1)
  log:info(
    "GATT write: handle=%d, %d bytes, hex=%s (%d queued)",
    entry.handle,
    #entry.data,
    C4:Encode(entry.data, "HEX"),
    #gattWriteQueue
  )
  SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
    handle = tostring(entry.handle),
    data = C4:Base64Encode(entry.data),
    response = "true",
  }, "NOTIFY")

  if #gattWriteQueue > 0 then
    SetTimer("GattWriteDrain", GATT_WRITE_COOLDOWN_MS, drainGattWriteQueue)
  end
end

--- Queue a GATT write, draining at 250ms intervals
--- @param handle integer GATT handle
--- @param data string Binary data to write
local function gattWrite(handle, data)
  gattWriteQueue[#gattWriteQueue + 1] = { handle = handle, data = data }

  if #gattWriteQueue == 1 then
    drainGattWriteQueue()
  end
end

--------------------------------------------------------------------------------
-- Connection Management
--------------------------------------------------------------------------------

--- Request GATT connection from parent driver
local function requestConnection()
  log:trace("requestConnection()")
  SendToProxy(ESPHOME_BINDING, "CONNECT", {}, "NOTIFY")
end

--- Actually perform the GATT disconnection
local function doDisconnect()
  log:trace("doDisconnect()")
  resetConnectionState()
  SendToProxy(ESPHOME_BINDING, "DISCONNECT", {}, "NOTIFY")
end

--- Send a clean disconnect command via secure session before GATT disconnect
local function sendCleanDisconnect()
  log:trace("sendCleanDisconnect()")

  if not secureSession or handshakeState ~= HANDSHAKE_STATE.COMPLETE then
    doDisconnect()
    return
  end

  local _, _, secureWriteHandle = getHandles()
  if not secureWriteHandle then
    doDisconnect()
    return
  end

  -- Build disconnect command (opcode 0x05, byte 0x11 = 0x00)
  local cmd = yale_protocol.buildSecureCommand(yale_protocol.Opcode.SEC_DISCONNECT, 0x00)

  -- Recompute security checksum
  local cmdBytes = {}
  for i = 1, 18 do
    cmdBytes[i] = string.byte(cmd, i)
  end
  yale_protocol.writeSecurityChecksum(cmdBytes)

  local chars = {}
  for i = 1, 18 do
    chars[i] = string.char(cmdBytes[i])
  end
  local packet = table.concat(chars)

  local encrypted = secureSession:encrypt(packet)
  gattWrite(secureWriteHandle, encrypted)

  -- Disconnect after a short delay regardless of response
  SetTimer("CleanDisconnect", 500, doDisconnect)
end

--- Request GATT disconnection (debounced)
local function requestDisconnect()
  log:debug("requestDisconnect() - will disconnect in %dms", DISCONNECT_DELAY_MS)
  CancelTimer("Keepalive")
  SetTimer("DisconnectDelay", DISCONNECT_DELAY_MS, function()
    log:debug("DisconnectDelay timer fired - sending clean disconnect")
    sendCleanDisconnect()
  end)
end

--- Cancel any pending disconnect
local function cancelPendingDisconnect()
  log:trace("cancelPendingDisconnect()")
  CancelTimer("DisconnectDelay")
end

--- Start keepalive timer for persistent connection.
--- Periodically polls lock status to keep the BLE connection alive
--- and detect state changes from unsolicited notifications.
local function startKeepalive()
  log:info("Persistent connection established - starting keepalive")
  UpdateProperty("Driver Status", "Connected")
  CancelTimer("DisconnectDelay")
  SetTimer("Keepalive", KEEPALIVE_INTERVAL_MS, function()
    if handshakeState == HANDSHAKE_STATE.COMPLETE and session and session:isReady() then
      log:debug("Keepalive: polling lock status")
      pendingCommand = "status"
      executePendingCommand()
    else
      log:warn("Keepalive: session not ready, connection may have dropped")
    end
  end, true) -- repeat=true
end

--- Schedule next poll cycle (Poll mode only).
--- Sets a one-shot timer that connects, queries status, then disconnects.
local function schedulePoll()
  local interval = tointeger(Properties["Polling Interval"]) or 60
  log:info("Scheduling next poll in %d seconds", interval)
  UpdateProperty("Driver Status", string.format("Listening (next poll in %ds)", interval))
  CancelTimer("PollCycle")
  SetTimer("PollCycle", interval * 1000, function()
    log:info("Poll timer fired - querying status")
    initiateCommand("status")
  end)
end

--- Called when the status chain completes (lock -> door -> battery done).
--- Replaces direct startKeepalive() calls — branches on connection mode.
local function onStatusChainComplete()
  log:debug("onStatusChainComplete() mode=%s", connectionMode)
  if connectionMode == CONNECTION_MODE.PERSISTENT then
    startKeepalive()
  else
    -- Poll mode: disconnect immediately after query
    sendCleanDisconnect()
  end
end

--- Transition to a new connection mode. Cancels all timers, disconnects if connected,
--- resets toggle tracking, and sets the new mode.
--- @param newMode string One of CONNECTION_MODE values
local function setConnectionMode(newMode)
  log:info("Setting connection mode: %s -> %s", connectionMode, newMode)

  -- Cancel all mode-related timers
  CancelTimer("Keepalive")
  CancelTimer("Reconnect")
  CancelTimer("PollCycle")
  CancelTimer("DisconnectDelay")

  -- Disconnect if connected
  if handshakeState ~= HANDSHAKE_STATE.IDLE then
    doDisconnect()
  end

  -- Reset state
  reconnectAttempts = 0
  initialStatusTriggered = false

  -- Set new mode
  connectionMode = newMode

  -- Show/hide Polling Interval property
  if newMode == CONNECTION_MODE.POLL then
    C4:SetPropertyAttribs("Polling Interval", constants.SHOW_PROPERTY)
  else
    C4:SetPropertyAttribs("Polling Interval", constants.HIDE_PROPERTY)
  end

  UpdateProperty("Driver Status", "Listening")
end

--- Subscribe to GATT notifications on a handle
--- @param handle integer GATT characteristic handle
local function subscribeNotifications(handle)
  log:debug("Subscribing to GATT notifications on handle %s", handle)
  SendToProxy(ESPHOME_BINDING, "GATT_NOTIFY", {
    handle = tostring(handle),
    enable = "true",
  }, "NOTIFY")
end

--------------------------------------------------------------------------------
-- Value Helpers
--------------------------------------------------------------------------------

local function updateLastSeen()
  values:update("Last Seen", tostring(os.date("%Y-%m-%d %H:%M:%S")))
end

--- @param rssi string|number RSSI value
local function updateRSSI(rssi)
  local rssiNum = tonumber(rssi) or -999
  if rssiNum > -999 then
    values:update("RSSI", rssiNum, nil, nil, " dBm")
  end
end

--------------------------------------------------------------------------------
-- Offline Key Validation
--------------------------------------------------------------------------------

--- Get the offline key as a 16-byte binary string
--- @return string|nil key 16-byte key or nil if not configured
local function getOfflineKey()
  local hex = Properties["Offline Key"]
  if type(hex) ~= "string" or #hex ~= 32 then
    return nil
  end
  -- Validate hex characters
  if not hex:match("^%x+$") then
    return nil
  end
  return (C4:Decode(hex, "HEX"))
end

--- Get the key slot index
--- @return integer keySlot Key slot (default 1)
local function getKeySlot()
  return tointeger(Properties["Key Slot"]) or 1
end

--- Check if authentication is configured
--- @return boolean configured True if offline key is set
local function isAuthConfigured()
  return getOfflineKey() ~= nil
end

--- Schedule reconnect or poll after a connection/handshake failure.
--- Centralizes recovery logic used by DISCONNECTED, CONNECTION_FAILED, and handshake errors.
--- @param status string Driver status message to display
--- @param savedCommand string|nil Command to retry on reconnect (e.g. "lock", "unlock", "status")
local function scheduleRecovery(status, savedCommand)
  if connectionMode == CONNECTION_MODE.PERSISTENT then
    if not isAuthConfigured() then
      UpdateProperty("Driver Status", "Listening")
      return
    end
    reconnectAttempts = reconnectAttempts + 1
    if reconnectAttempts > MAX_RECONNECT_ATTEMPTS then
      log:warn("Max reconnect attempts (%d) reached: %s", MAX_RECONNECT_ATTEMPTS, status)
      UpdateProperty("Driver Status", "Listening (reconnect failed)")
      reconnectAttempts = 0
      return
    end
    local delay = BASE_RECONNECT_MS * (2 ^ (reconnectAttempts - 1))
    log:info("Retrying in %ds (attempt %d/%d): %s", delay / 1000, reconnectAttempts, MAX_RECONNECT_ATTEMPTS, status)
    UpdateProperty("Driver Status", string.format("Reconnecting (%d/%d)", reconnectAttempts, MAX_RECONNECT_ATTEMPTS))
    local retryCommand = savedCommand or "status"
    SetTimer("Reconnect", delay, function()
      initiateCommand(retryCommand)
    end)
  elseif connectionMode == CONNECTION_MODE.POLL then
    UpdateProperty("Driver Status", status)
    schedulePoll()
  else
    UpdateProperty("Driver Status", status)
  end
end

--------------------------------------------------------------------------------
-- Lock Status Updates
--------------------------------------------------------------------------------

--- Update the lock status and notify the proxy
--- @param status string C4 lock status ("locked", "unlocked", "fault")
local function updateLockStatus(status)
  log:info("Lock status: %s", status)
  currentLockStatus = status
  UpdateProperty("Lock Status", status)
  SendToProxy(PROXY_BINDING, "LOCK_STATUS_CHANGED", { LOCK_STATUS = status }, "NOTIFY")
end

--- Enable or disable DoorSense contact sensor based on detection.
--- When DoorSense is configured on the lock, creates a dynamic CONTACT_SENSOR binding
--- and shows the Door Status property. When not configured, removes the binding and hides it.
--- @param configured boolean Whether DoorSense is configured
local function setDoorSenseConfigured(configured)
  if doorSenseConfigured == configured then
    return
  end
  doorSenseConfigured = configured

  if configured then
    log:info("DoorSense detected - creating contact sensor binding")
    bindings:getOrAddDynamicBinding(BINDINGS_NAMESPACE, "door", "PROXY", true, "Door", "CONTACT_SENSOR")
    C4:SetPropertyAttribs("Door Status", constants.SHOW_PROPERTY)
  else
    log:info("DoorSense not configured - removing contact sensor binding")
    bindings:deleteBinding(BINDINGS_NAMESPACE, "door")
    UpdateProperty("Door Status", "")
    C4:SetPropertyAttribs("Door Status", constants.HIDE_PROPERTY)
  end
end

--- Update the door status and notify dynamic contact sensor binding.
--- Persists state via the values lib so it survives reboots/driver updates.
--- Deduplicates: only sends a proxy notification when the state actually changes.
--- @param doorStatus string "CLOSED" or "OPENED"
local function updateDoorStatus(doorStatus)
  setDoorSenseConfigured(true)

  if not values:update("Door Status", doorStatus) then
    return
  end

  log:info("Door status: %s", doorStatus)

  local binding = bindings:getDynamicBinding(BINDINGS_NAMESPACE, "door")
  if binding then
    SendToProxy(binding.bindingId, doorStatus, {}, "NOTIFY")
  end
end

--- Update battery percentage
--- @param percentage integer Battery percentage (0-100)
local function updateBattery(percentage)
  log:info("Battery: %d%%", percentage)
  values:update("Battery", percentage, "NUMBER", nil, " %")
end

--------------------------------------------------------------------------------
-- Handshake State Machine
--------------------------------------------------------------------------------

--- Generate 16 random bytes
--- @return string randomBytes 16 random bytes
local function generateRandomBytes()
  local bytes = {}
  for i = 1, 16 do
    bytes[i] = string.char(math.random(0, 255))
  end
  return table.concat(bytes)
end

--- Start the Yale BLE handshake
local function startHandshake()
  log:info("Starting Yale BLE handshake")

  local offlineKey = getOfflineKey()
  if not offlineKey then
    log:error("Cannot start handshake: offline key not configured")
    UpdateProperty("Driver Status", "Error: Offline key required")
    requestDisconnect()
    return
  end

  -- Initialize sessions
  secureSession = yale_protocol.SecureSession:new(offlineKey)
  session = yale_protocol.Session:new()

  -- Step 1: Generate 16 random bytes
  handshakeKeys = generateRandomBytes()

  -- Step 2: Build SEC_LOCK_TO_MOBILE_KEY_EXCHANGE command
  local cmd = yale_protocol.buildSecureCommand(yale_protocol.Opcode.SEC_LOCK_TO_MOBILE_KEY_EXCHANGE, getKeySlot())

  -- Copy first 8 bytes of handshakeKeys to offset 0x04 (bytes 5-12)
  local cmdBytes = {}
  for i = 1, 18 do
    cmdBytes[i] = string.byte(cmd, i)
  end
  for i = 1, 8 do
    cmdBytes[4 + i] = string.byte(handshakeKeys, i)
  end

  -- Recompute security checksum (LE u32 sum method)
  yale_protocol.writeSecurityChecksum(cmdBytes)

  local chars = {}
  for i = 1, 18 do
    chars[i] = string.char(cmdBytes[i])
  end
  local packet = table.concat(chars)

  log:info("Handshake plaintext: %s", C4:Encode(packet, "HEX"))

  -- Encrypt with secure session (ECB)
  local encrypted = secureSession:encrypt(packet)

  log:info("Handshake encrypted: %s", C4:Encode(encrypted, "HEX"))

  -- Send on secure write characteristic
  local _, _, secureWriteHandle = getHandles()
  if not secureWriteHandle then
    log:error("Secure write handle not available")
    requestDisconnect()
    return
  end

  log:info("Sending KEY_EXCHANGE to handle %d (%d bytes)", secureWriteHandle, #encrypted)
  handshakeState = HANDSHAKE_STATE.AWAITING_KEY_EXCHANGE_RESPONSE
  gattWrite(secureWriteHandle, encrypted)

  -- Timeout if lock doesn't respond to handshake
  SetTimer("HandshakeTimeout", HANDSHAKE_TIMEOUT_MS, function()
    if handshakeState ~= HANDSHAKE_STATE.IDLE and handshakeState ~= HANDSHAKE_STATE.COMPLETE then
      log:warn("Handshake timeout - no response after %dms", HANDSHAKE_TIMEOUT_MS)
      local savedCommand = pendingCommand
      doDisconnect()
      scheduleRecovery("Error: Handshake timeout", savedCommand)
    end
  end)
end

--- Handle handshake key exchange response
--- @param data string 18-byte response from secure read
local function handleKeyExchangeResponse(data)
  log:info("Received key exchange response")

  if not secureSession or not handshakeKeys then
    log:error("Handshake state lost")
    requestDisconnect()
    return
  end

  -- Decrypt the response
  local decrypted = secureSession:decrypt(data)
  local opcode = string.byte(decrypted, 1)

  if opcode ~= yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP then
    log:error(
      "Unexpected handshake response opcode: 0x%02X (expected 0x%02X)",
      opcode,
      yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP
    )
    log:warn("Offline key may have been rotated - re-fetch keys from Yale Cloud")
    UpdateProperty("Yale Cloud Status", "Key mismatch - re-fetch keys")
    requestDisconnect()
    return
  end

  -- Extract lock's 8 bytes from offset 0x04 (bytes 5-12)
  local lockBytes = decrypted:sub(5, 12)

  -- Derive session key: handshakeKeys[1:8] || lockBytes[1:8]
  local sessionKey = handshakeKeys:sub(1, 8) .. lockBytes:sub(1, 8)

  -- Re-key both sessions
  secureSession:setKey(sessionKey)
  session:setKey(sessionKey)

  -- Step 6: Send SEC_INITIALIZATION_COMMAND
  local cmd = yale_protocol.buildSecureCommand(yale_protocol.Opcode.SEC_INITIALIZATION_COMMAND, getKeySlot())

  -- Copy handshakeKeys[9:16] to offset 0x04 (bytes 5-12)
  local cmdBytes = {}
  for i = 1, 18 do
    cmdBytes[i] = string.byte(cmd, i)
  end
  for i = 1, 8 do
    cmdBytes[4 + i] = string.byte(handshakeKeys, 8 + i)
  end

  -- Recompute security checksum (LE u32 sum method)
  yale_protocol.writeSecurityChecksum(cmdBytes)

  local chars = {}
  for i = 1, 18 do
    chars[i] = string.char(cmdBytes[i])
  end
  local packet = table.concat(chars)

  -- Encrypt with secure session (now using session key)
  local encrypted = secureSession:encrypt(packet)

  local _, _, secureWriteHandle = getHandles()
  if not secureWriteHandle then
    log:error("Secure write handle not available")
    requestDisconnect()
    return
  end

  handshakeState = HANDSHAKE_STATE.AWAITING_INIT_RESPONSE
  gattWrite(secureWriteHandle, encrypted)
end

--- Handle handshake initialization response
--- @param data string 18-byte response from secure read
local function handleInitResponse(data)
  log:info("Received initialization response")

  if not secureSession then
    log:error("Handshake state lost")
    requestDisconnect()
    return
  end

  local decrypted = secureSession:decrypt(data)
  local opcode = string.byte(decrypted, 1)

  if opcode ~= yale_protocol.Opcode.SEC_INITIALIZATION_RESP then
    log:error(
      "Unexpected init response opcode: 0x%02X (expected 0x%02X)",
      opcode,
      yale_protocol.Opcode.SEC_INITIALIZATION_RESP
    )
    log:warn("Offline key may have been rotated - re-fetch keys from Yale Cloud")
    UpdateProperty("Yale Cloud Status", "Key mismatch - re-fetch keys")
    requestDisconnect()
    return
  end

  log:info("Handshake complete - session established")
  CancelTimer("HandshakeTimeout")
  handshakeState = HANDSHAKE_STATE.COMPLETE
  reconnectAttempts = 0
  UpdateProperty("Driver Status", "Connected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")

  -- Per yalexs-ble: subscribe regular read AFTER handshake completes
  local _, readHandle = getHandles()
  if readHandle and not regularReadSubscribed then
    subscribeNotifications(readHandle)
  else
    -- Already subscribed (shouldn't happen in normal flow)
    executePendingCommand()
  end
end

--------------------------------------------------------------------------------
-- Command Execution
--------------------------------------------------------------------------------

--- Execute the pending command (called after handshake completes)
function executePendingCommand()
  log:trace("executePendingCommand()")
  if not pendingCommand then
    log:debug("No pending command, requesting status")
    pendingCommand = "status"
  end

  if handshakeState ~= HANDSHAKE_STATE.COMPLETE then
    log:debug("Handshake not complete, deferring command")
    return
  end

  if not session or not session:isReady() then
    log:error("Session not ready for command execution")
    requestDisconnect()
    return
  end

  local writeHandle = getHandles()
  if not writeHandle then
    log:error("Write handle not available")
    requestDisconnect()
    return
  end

  local cmd = pendingCommand
  pendingCommand = nil

  if cmd == "lock" then
    log:info("Sending LOCK command")
    local packet = yale_protocol.buildCommand(yale_protocol.Opcode.LOCK)
    local encrypted = session:encrypt(packet)
    awaitingResponse = "lock"
    gattWrite(writeHandle, encrypted)
  elseif cmd == "unlock" then
    log:info("Sending UNLOCK command")
    local packet = yale_protocol.buildCommand(yale_protocol.Opcode.UNLOCK)
    local encrypted = session:encrypt(packet)
    awaitingResponse = "unlock"
    gattWrite(writeHandle, encrypted)
  elseif cmd == "status" then
    log:info("Sending GET_STATUS command (lock only)")
    local packet =
      yale_protocol.buildOperationCommand(yale_protocol.Opcode.GET_STATUS, yale_protocol.StatusType.LOCK_ONLY)
    local encrypted = session:encrypt(packet)
    awaitingResponse = "status_lock"
    gattWrite(writeHandle, encrypted)
  elseif cmd == "door" then
    log:info("Sending GET_STATUS command (door only)")
    local packet =
      yale_protocol.buildOperationCommand(yale_protocol.Opcode.GET_STATUS, yale_protocol.StatusType.DOOR_ONLY)
    local encrypted = session:encrypt(packet)
    awaitingResponse = "status_door"
    gattWrite(writeHandle, encrypted)
  elseif cmd == "battery" then
    log:info("Sending battery status command")
    local packet =
      yale_protocol.buildOperationCommand(yale_protocol.Opcode.GET_STATUS, yale_protocol.StatusType.BATTERY)
    local encrypted = session:encrypt(packet)
    awaitingResponse = "status_battery"
    gattWrite(writeHandle, encrypted)
  end
end

--- Initiate a lock/unlock command - connect if needed, then execute
--- @param command string "lock", "unlock", or "status"
function initiateCommand(command)
  log:info("Initiating command: %s", command)
  cancelPendingDisconnect()
  CancelTimer("PollCycle")
  pendingCommand = command

  if handshakeState == HANDSHAKE_STATE.COMPLETE and session and session:isReady() then
    -- Already connected and authenticated, execute immediately
    executePendingCommand()
  elseif handshakeState ~= HANDSHAKE_STATE.IDLE then
    -- Handshake already in progress - pendingCommand is set above,
    -- it will execute when the current handshake completes
    log:info("Handshake in progress (state=%d), command queued", handshakeState)
  else
    -- Not connected, need to connect first
    requestConnection()
  end
end

--- Queue a status poll after lock/unlock command
local function queueStatusPoll()
  SetTimer("StatusPoll", STATUS_POLL_DELAY_MS, function()
    if handshakeState == HANDSHAKE_STATE.COMPLETE then
      pendingCommand = "status"
      executePendingCommand()
    end
  end)
end

--- Queue a door status poll after lock status
local function queueDoorPoll()
  SetTimer("DoorPoll", STATUS_POLL_DELAY_MS, function()
    if handshakeState == HANDSHAKE_STATE.COMPLETE then
      pendingCommand = "door"
      executePendingCommand()
    end
  end)
end

--- Queue a battery poll after door status
local function queueBatteryPoll()
  SetTimer("BatteryPoll", STATUS_POLL_DELAY_MS, function()
    if handshakeState == HANDSHAKE_STATE.COMPLETE then
      pendingCommand = "battery"
      executePendingCommand()
    end
  end)
end

--------------------------------------------------------------------------------
-- Response Handling
--------------------------------------------------------------------------------

--- Handle a command response from the regular read characteristic.
--- This is called for ALL notifications on the regular read handle (not just
--- solicited ones) because we must always decrypt to keep the CBC IV chain in sync.
--- @param data string 18-byte encrypted response
local function handleCommandResponse(data)
  if not session or not session:isReady() then
    log:error("Session not ready for response decryption")
    return
  end

  -- Always decrypt to keep CBC IV chain in sync
  local decrypted = session:decrypt(data)
  log:info("Decrypted response hex: %s", C4:Encode(decrypted, "HEX"))

  -- Validate simple checksum on decrypted response
  local expectedChecksum = yale_protocol.simpleChecksum(decrypted)
  local actualChecksum = string.byte(decrypted, 4)
  if expectedChecksum ~= actualChecksum then
    log:warn("Response checksum mismatch: expected=0x%02X, got=0x%02X", expectedChecksum, actualChecksum)
  end

  local response = yale_protocol.parseResponse(decrypted)

  if not response then
    log:warn("Failed to parse response (decryption kept IV in sync)")
    return
  end

  log:debug("Response: flag=0x%02X, opcode=0x%02X", response.flag, response.opcode)

  -- Determine if this response matches what we're awaiting.
  -- Only consume awaitingResponse when the response type matches,
  -- so unsolicited notifications don't steal the solicited flag.
  local wasSolicited = false
  if awaitingResponse then
    if response.flag == 0xAA and (awaitingResponse == "lock" or awaitingResponse == "unlock") then
      wasSolicited = true
      awaitingResponse = nil
    elseif response.flag == 0xBB and response.opcode == yale_protocol.Opcode.GET_STATUS then
      if awaitingResponse == "status_lock" and response.statusType == yale_protocol.StatusType.LOCK_ONLY then
        wasSolicited = true
        awaitingResponse = nil
      elseif awaitingResponse == "status_door" and response.statusType == yale_protocol.StatusType.DOOR_ONLY then
        wasSolicited = true
        awaitingResponse = nil
      elseif awaitingResponse == "status_battery" and response.statusType == yale_protocol.StatusType.BATTERY then
        wasSolicited = true
        awaitingResponse = nil
      end
    end
  end

  log:debug("Response is %s", wasSolicited and "solicited" or "unsolicited")

  -- Status response
  if response.flag == 0xBB then
    if response.lockStatus then
      local c4Status = yale_protocol.toC4LockStatus(response.lockStatus)
      local statusStr = yale_protocol.parseLockStatus(response.lockStatus)
      log:info("Lock status: %s (0x%02X) -> C4: %s", statusStr, response.lockStatus, c4Status)
      updateLockStatus(c4Status)
    end

    if response.doorStatus then
      local doorStr = yale_protocol.parseDoorStatus(response.doorStatus)
      if doorStr ~= "UNKNOWN" then
        updateDoorStatus(doorStr)
      else
        setDoorSenseConfigured(false)
      end
    end

    if response.batteryMillivolts then
      local battery = yale_protocol.parseBattery(response.batteryMillivolts)
      if battery > 0 then
        updateBattery(battery)
      end
    end

    updateLastSeen()

    -- Only drive the command state machine for solicited responses
    if wasSolicited then
      if response.opcode == yale_protocol.Opcode.GET_STATUS then
        if response.statusType == yale_protocol.StatusType.LOCK_ONLY then
          queueDoorPoll()
        elseif response.statusType == yale_protocol.StatusType.DOOR_ONLY then
          queueBatteryPoll()
        else
          -- Status chain complete (battery done)
          onStatusChainComplete()
        end
      else
        onStatusChainComplete()
      end
    end
    return
  end

  -- Acknowledgment response (lock/unlock completed)
  if response.flag == 0xAA then
    -- ACK means command succeeded: infer status from opcode
    if response.opcode == yale_protocol.Opcode.LOCK then
      updateLockStatus("locked")
    elseif response.opcode == yale_protocol.Opcode.UNLOCK then
      updateLockStatus("unlocked")
    end
    updateLastSeen()

    -- Poll for full status after command, then schedule jam check
    if wasSolicited then
      queueStatusPoll()
      -- Re-query lock status after 10s to catch late-reported jams
      SetTimer("JamCheck", JAM_CHECK_DELAY_MS, function()
        if handshakeState == HANDSHAKE_STATE.COMPLETE then
          log:debug("Jam check: re-querying lock status")
          pendingCommand = "status"
          executePendingCommand()
        elseif connectionMode == CONNECTION_MODE.POLL then
          log:debug("Jam check: connecting to query status")
          initiateCommand("status")
        end
      end)
    end
    return
  end

  -- Unknown response — just log it, don't disconnect
  log:debug("Unknown response flag: 0x%02X (CBC IV chain kept in sync)", response.flag)
end

--------------------------------------------------------------------------------
-- Yale Cloud API Key Fetching
--------------------------------------------------------------------------------

--- Request a verification code from the August API.
--- @return Deferred deferred Resolves on success, rejects with error string on failure
local function requestVerificationCode()
  log:trace("requestVerificationCode()")
  local d = deferred.new()

  local email = Properties["Yale Email"]
  local password = Properties["Yale Password"]

  if IsEmpty(email) then
    return d:reject("Email required")
  end
  if IsEmpty(password) then
    return d:reject("Password required")
  end

  UpdateProperty("Yale Cloud Status", "Creating session...")

  local sessionUrl = AUGUST_API.BASE_URL .. "/session"
  local headers = {}
  for k, v in pairs(AUGUST_API.HEADERS) do
    headers[k] = v
  end
  headers["x-august-api-key"] = AUGUST_API.API_KEY

  local sessionData = JSON:encode({
    identifier = "email:" .. email,
    installId = "C4-" .. tostring(C4:GetDeviceID()),
    password = password,
  })

  http
    :post(sessionUrl, sessionData, headers)
    :next(function(response)
      local token = Select(response.headers, "x-august-access-token")
        or Select(response.headers, "X-August-Access-Token")
      if IsEmpty(token) then
        return d:reject("No access token in session response")
      end
      augustSessionToken = token
      log:info("August session created")

      -- Send verification code
      UpdateProperty("Yale Cloud Status", "Sending verification code...")
      local validateUrl = AUGUST_API.BASE_URL .. "/validation/email"
      local validateHeaders = {}
      for k, v in pairs(AUGUST_API.HEADERS) do
        validateHeaders[k] = v
      end
      validateHeaders["x-august-api-key"] = AUGUST_API.API_KEY
      validateHeaders["x-august-access-token"] = token

      local validateData = JSON:encode({ value = email })
      return http:post(validateUrl, validateData, validateHeaders)
    end)
    :next(function()
      log:info("Verification code sent to %s", Properties["Yale Email"])
      d:resolve(true)
    end, function(err)
      return d:reject(err)
    end)

  return d
end

--- Verify the code and fetch offline keys.
--- @param code string The verification code from the action param
--- @return Deferred deferred Resolves with { offlineKey, keySlot } on success, rejects with error string on failure
local function verifyAndFetchKeys(code)
  log:trace("verifyAndFetchKeys()")
  local d = deferred.new()

  local email = Properties["Yale Email"]

  if IsEmpty(augustSessionToken) then
    return d:reject("Request verification code first")
  end
  if IsEmpty(code) then
    return d:reject("Verification code required")
  end

  UpdateProperty("Yale Cloud Status", "Verifying code...")

  local headers = {}
  for k, v in pairs(AUGUST_API.HEADERS) do
    headers[k] = v
  end
  headers["x-august-api-key"] = AUGUST_API.API_KEY
  headers["x-august-access-token"] = augustSessionToken

  -- Validate the code
  local validateUrl = AUGUST_API.BASE_URL .. "/validate/email"
  local validateData = JSON:encode({ code = code, email = email })

  http
    :post(validateUrl, validateData, headers)
    :next(function(response)
      -- Check for updated token in response
      local newToken = Select(response.headers, "x-august-access-token")
        or Select(response.headers, "X-August-Access-Token")
      if not IsEmpty(newToken) then
        augustSessionToken = newToken
        headers["x-august-access-token"] = newToken
      end

      UpdateProperty("Yale Cloud Status", "Fetching locks...")
      local locksUrl = AUGUST_API.BASE_URL .. "/users/locks/mine"
      return http:get(locksUrl, headers)
    end)
    :next(function(response)
      local locks = response.body
      if type(locks) == "string" then
        locks = JSON:decode(locks)
      end
      if type(locks) ~= "table" then
        return d:reject("Invalid locks response")
      end

      -- Find the first lock (or match by MAC if we have one)
      local mac = Properties["MAC Address"]
      local targetLockId = nil

      for lockId, lockInfo in pairs(locks) do
        if type(lockInfo) == "table" then
          -- Check if MAC matches (if we have one)
          if not IsEmpty(mac) and mac ~= "Unknown" then
            local lockMac = Select(lockInfo, "macAddress") or ""
            lockMac = lockMac:upper():gsub("[:-]", "")
            local ourMac = mac:upper():gsub("[:-]", "")
            if lockMac == ourMac then
              targetLockId = lockId
              break
            end
          end
          -- Otherwise use first lock found
          if not targetLockId then
            targetLockId = lockId
          end
        end
      end

      if not targetLockId then
        return d:reject("No locks found in account")
      end

      UpdateProperty("Yale Cloud Status", "Fetching key for lock " .. targetLockId .. "...")
      local lockUrl = AUGUST_API.BASE_URL .. "/locks/" .. targetLockId
      return http:get(lockUrl, headers)
    end)
    :next(function(response)
      local lockInfo = response.body
      log:debug("Lock info response type: %s", type(lockInfo))
      if type(lockInfo) == "string" then
        lockInfo = JSON:decode(lockInfo)
      end
      if type(lockInfo) ~= "table" then
        return d:reject("Invalid lock info response (type: " .. type(lockInfo) .. ")")
      end

      -- Extract offline key from OfflineKeys.loaded
      log:debug("Lock info keys: %s", lockInfo)
      local offlineKeys = Select(lockInfo, "OfflineKeys") or {}
      local loaded = offlineKeys.loaded
      local offlineKey, keySlot
      if loaded and #loaded > 0 then
        offlineKey = loaded[1].key
        keySlot = tostring(loaded[1].slot or 1)
      end

      if IsEmpty(offlineKey) then
        -- Check if key exists but hasn't been loaded onto the lock yet
        local created = offlineKeys.created
        if created and #created > 0 then
          return d:reject(
            "Offline key is provisioned but not yet loaded on the lock. Operate the lock once from the Yale app, then retry."
          )
        end
        return d:reject("No offline key found for this lock")
      end

      d:resolve({ offlineKey = offlineKey, keySlot = keySlot })
    end, function(err)
      return d:reject(err)
    end)

  return d
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  math.randomseed(os.time() + C4:GetDeviceID())
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

  bindings:restoreBindings()
  values:restoreValues()

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Disconnected")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")

  -- Restore lock status from persisted property
  local savedStatus = Properties["Lock Status"]
  if not IsEmpty(savedStatus) and savedStatus ~= "Unknown" then
    currentLockStatus = savedStatus
  end

  -- Set initial lock status so the proxy doesn't show "?"
  local initialStatus = currentLockStatus or "unknown"
  SendToProxy(PROXY_BINDING, "LOCK_STATUS_CHANGED", { LOCK_STATUS = initialStatus }, "NOTIFY")

  -- Restore DoorSense state from persisted bindings
  local doorBinding = bindings:getDynamicBinding(BINDINGS_NAMESPACE, "door")
  if doorBinding then
    doorSenseConfigured = true
    C4:SetPropertyAttribs("Door Status", constants.SHOW_PROPERTY)
  else
    doorSenseConfigured = nil
    C4:SetPropertyAttribs("Door Status", constants.HIDE_PROPERTY)
  end
end

--------------------------------------------------------------------------------
-- Property Changed Handlers
--------------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
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
end

function OPC.Connection_Mode(propertyValue)
  log:trace("OPC.Connection_Mode('%s')", propertyValue)
  if not gInitialized then
    -- On init, just set the variable without triggering transitions
    connectionMode = propertyValue or CONNECTION_MODE.POLL
    if connectionMode == CONNECTION_MODE.POLL then
      C4:SetPropertyAttribs("Polling Interval", constants.SHOW_PROPERTY)
    else
      C4:SetPropertyAttribs("Polling Interval", constants.HIDE_PROPERTY)
    end
    return
  end
  setConnectionMode(propertyValue or CONNECTION_MODE.POLL)
end

function OPC.Polling_Interval(propertyValue)
  log:trace("OPC.Polling_Interval('%s')", propertyValue)
  if not gInitialized then
    return
  end
  -- Reschedule poll timer if currently in Poll mode and idle
  if connectionMode == CONNECTION_MODE.POLL and handshakeState == HANDSHAKE_STATE.IDLE then
    schedulePoll()
  end
end

function OPC.Offline_Key(propertyValue)
  log:trace("OPC.Offline_Key('%s')", not IsEmpty(propertyValue) and "****" or "")
end

function OPC.Key_Slot(propertyValue)
  log:trace("OPC.Key_Slot('%s')", propertyValue)
end

function OPC.Yale_Email(propertyValue)
  log:trace("OPC.Yale_Email('%s')", propertyValue and "***" or "nil")
end

function OPC.Yale_Password(propertyValue)
  log:trace("OPC.Yale_Password('%s')", propertyValue and "***" or "nil")
end

--------------------------------------------------------------------------------
-- RFP Handlers - Lock Proxy (binding 5001)
--------------------------------------------------------------------------------

function RFP.LOCK(idBinding, strCommand)
  log:trace("RFP.LOCK(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  initiateCommand("lock")
end

function RFP.UNLOCK(idBinding, strCommand)
  log:trace("RFP.UNLOCK(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  initiateCommand("unlock")
end

function RFP.TOGGLE(idBinding, strCommand)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding ~= PROXY_BINDING then
    return
  end
  if currentLockStatus == "locked" then
    initiateCommand("unlock")
  else
    initiateCommand("lock")
  end
end

--------------------------------------------------------------------------------
-- RFP Handlers - BLE Connection (binding 5002)
--------------------------------------------------------------------------------

--- Handle active GATT connection from parent driver
function RFP.CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local name = Select(tParams, "name")
  local mac = Select(tParams, "mac")
  local services = DeserializeSafe(Select(tParams, "services"))

  log:info("Connected to Yale lock: %s", mac or "unknown")
  CancelTimer("ConnectionTimeout")

  if not IsEmpty(name) then
    values:update("Name", name, "STRING")
  end
  if mac then
    values:update("MAC Address", mac, "STRING")
  end

  if services then
    local writeHandle = findCharacteristicHandle(services, yale_protocol.UUID.SERVICE, yale_protocol.UUID.WRITE)
    local readHandle = findCharacteristicHandle(services, yale_protocol.UUID.SERVICE, yale_protocol.UUID.READ)
    local secureWriteHandle =
      findCharacteristicHandle(services, yale_protocol.UUID.SERVICE, yale_protocol.UUID.SECURE_WRITE)
    local secureReadHandle =
      findCharacteristicHandle(services, yale_protocol.UUID.SERVICE, yale_protocol.UUID.SECURE_READ)

    if writeHandle and readHandle and secureWriteHandle and secureReadHandle then
      log:info(
        "Found Yale handles: W=%d, R=%d, SW=%d, SR=%d",
        writeHandle,
        readHandle,
        secureWriteHandle,
        secureReadHandle
      )
      saveHandles(writeHandle, readHandle, secureWriteHandle, secureReadHandle)

      secureReadSubscribed = false
      regularReadSubscribed = false

      -- Subscribe to notifications on secure read first, then regular read
      subscribeNotifications(secureReadHandle)
    else
      log:error("Could not find all Yale GATT characteristics")
      -- Try cached handles
      local cW, cR, cSW, cSR = getHandles()
      if cW and cR and cSW and cSR then
        log:warn("Using cached handles as fallback")
        secureReadSubscribed = false
        regularReadSubscribed = false
        subscribeNotifications(cSR)
      else
        UpdateProperty("Driver Status", "Error: Missing characteristics")
      end
    end
  else
    log:error("No services provided in CONNECTED message")
    UpdateProperty("Driver Status", "Error: Missing services")
  end
end

--- Timestamp of last advertisement processing (for throttling)
--- @type number
local lastAdvProcessedAt = 0

--- Handle incoming BLE advertisement
function RFP.BLE_ADVERTISEMENT(idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  -- Go online on first advertisement if still disconnected
  local driverStatus = Properties["Driver Status"]
  if driverStatus == "Disconnected" then
    UpdateProperty("Driver Status", "Listening")
    SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
    if currentLockStatus then
      SendToProxy(PROXY_BINDING, "LOCK_STATUS_CHANGED", { LOCK_STATUS = currentLockStatus }, "NOTIFY")
    end
  end

  -- Mode-specific connection logic
  if connectionMode == CONNECTION_MODE.PERSISTENT then
    -- Auto-connect when idle and auth is configured
    if
      (driverStatus == "Disconnected" or driverStatus == "Listening")
      and handshakeState == HANDSHAKE_STATE.IDLE
      and isAuthConfigured()
    then
      log:info("Auto-connecting to Yale lock (Persistent mode)")
      initiateCommand("status")
      return
    end
  elseif connectionMode == CONNECTION_MODE.POLL then
    -- On first advertisement with auth configured, trigger initial status query
    -- which starts the poll scheduling cycle via the disconnect handler
    if
      not initialStatusTriggered
      and (driverStatus == "Disconnected" or driverStatus == "Listening")
      and handshakeState == HANDSHAKE_STATE.IDLE
      and isAuthConfigured()
    then
      log:info("Initial status query (Poll mode)")
      initialStatusTriggered = true
      initiateCommand("status")
      return
    end
  end

  -- Throttle RSSI/Last Seen updates
  local throttleSeconds = 30
  local now = os.time()
  if now - lastAdvProcessedAt < throttleSeconds then
    return
  end
  lastAdvProcessedAt = now

  -- Deserialize advertisement (if not already done above)
  local advStr = Select(tParams, "advertisement")
  if not advStr or advStr == "" then
    return
  end

  local advertisement = DeserializeSafe(advStr)
  if not advertisement then
    return
  end

  -- Update device info
  local mac = Select(tParams, "mac")
  if mac then
    values:update("MAC Address", mac, "STRING")
  end

  -- Update RSSI
  if advertisement.rssi then
    updateRSSI(advertisement.rssi)
  end

  updateLastSeen()
end

--- Handle disconnection
function RFP.DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.DISCONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local reason = Select(tParams, "reason") or "unknown"
  log:info("Disconnected from Yale lock: %s", reason)

  -- Preserve user-initiated commands (lock/unlock) so they can be retried
  local savedCommand = pendingCommand
  if savedCommand ~= "lock" and savedCommand ~= "unlock" then
    savedCommand = nil
  end

  resetConnectionState()
  scheduleRecovery("Disconnected: " .. reason, savedCommand)
end

--- Handle connection failure
function RFP.CONNECTION_FAILED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTION_FAILED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local errMsg = Select(tParams, "error") or "unknown"
  log:error("Connection failed: %s", errMsg)
  resetConnectionState()
  scheduleRecovery("Connection failed: " .. errMsg)
end

--------------------------------------------------------------------------------
-- RFP Handlers - GATT
--------------------------------------------------------------------------------

--- Handle GATT write response
function RFP.GATT_WRITE_RESPONSE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_WRITE_RESPONSE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local success = Select(tParams, "success") == "true"
  local errorCode = Select(tParams, "error")

  if success then
    log:debug("Write command successful")
    updateLastSeen()
  else
    log:error("Write command failed: error=%s", errorCode)
    if handshakeState ~= HANDSHAKE_STATE.COMPLETE then
      log:error("Handshake write failed, disconnecting")
      doDisconnect()
      scheduleRecovery("Error: Handshake failed")
    end
  end
end

--- Handle GATT notification subscription confirmation
function RFP.GATT_NOTIFY_SUBSCRIBED(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_SUBSCRIBED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local handle = tointeger(Select(tParams, "handle"))
  local success = Select(tParams, "success") == "true"

  if not success then
    log:error("GATT notification subscription failed on handle %s", handle)
    return
  end

  local _, readHandle, _, secureReadHandle = getHandles()

  if handle == secureReadHandle then
    log:info("Secure read notifications subscribed")
    secureReadSubscribed = true
    -- Per yalexs-ble: subscribe secure read, then start handshake immediately
    -- Regular read is subscribed AFTER handshake completes
    if isAuthConfigured() then
      startHandshake()
    else
      log:warn("Authentication not configured")
      UpdateProperty("Driver Status", "Error: Offline key required")
      requestDisconnect()
    end
  elseif handle == readHandle then
    log:info("Regular read notifications subscribed")
    regularReadSubscribed = true
    -- Regular read is ready after handshake — execute pending command
    executePendingCommand()
  end
end

--- Handle GATT notification data
function RFP.GATT_NOTIFY_DATA(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_DATA(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local handle = tointeger(Select(tParams, "handle"))
  local data = Select(tParams, "data")

  if not data then
    log:debug("GATT_NOTIFY with no data")
    return
  end

  local binaryData = C4:Base64Decode(data)
  if not binaryData or #binaryData == 0 then
    log:debug("GATT_NOTIFY with empty data after decode")
    return
  end

  log:debug("GATT_NOTIFY_DATA: handle=%s, %d bytes", handle or "nil", #binaryData)

  local _, readHandle, _, secureReadHandle = getHandles()

  -- Route based on handle and handshake state
  if handle == secureReadHandle then
    -- Secure read notifications are for handshake
    if handshakeState == HANDSHAKE_STATE.AWAITING_KEY_EXCHANGE_RESPONSE then
      handleKeyExchangeResponse(binaryData)
      return
    elseif handshakeState == HANDSHAKE_STATE.AWAITING_INIT_RESPONSE then
      handleInitResponse(binaryData)
      return
    end
  elseif handle == readHandle then
    -- Always decrypt regular read notifications to keep CBC IV chain in sync.
    -- Per yalexs-ble: the lock's CBC encryptor advances on every notification,
    -- so we must decrypt every one, even if we're not awaiting a response.
    if session and session:isReady() then
      handleCommandResponse(binaryData)
    else
      log:debug("Regular read notification but session not ready, ignoring")
    end
    return
  end

  log:debug("Unexpected notification data on handle %s (handshake=%d)", handle or "nil", handshakeState)
end

--------------------------------------------------------------------------------
-- OBC Handlers
--------------------------------------------------------------------------------

OBC[ESPHOME_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId)
  log:trace("OBC[%s](%s, %s, %s, %s)", ESPHOME_BINDING, idBinding, strClass, bIsBound, otherDeviceId)
  resetConnectionState(true)

  if bIsBound then
    UpdateProperty("Driver Status", "Waiting for data")
  else
    UpdateProperty("Driver Status", "Disconnected")
  end
end

--------------------------------------------------------------------------------
-- EC Handlers (Actions)
--------------------------------------------------------------------------------

function EC.Request_Verification_Code()
  log:trace("EC.Request_Verification_Code()")
  requestVerificationCode():next(function()
    UpdateProperty("Yale Cloud Status", "Verification code sent - run 'Verify and Fetch Keys' and enter the code")
  end, function(err)
    log:error("Failed to request verification code: %s", err)
    UpdateProperty("Yale Cloud Status", "Error: " .. tostring(err))
  end)
end

function EC.Verify_And_Fetch_Keys(params)
  log:trace("EC.Verify_And_Fetch_Keys(%s)", params)
  verifyAndFetchKeys(Select(params, "Verification Code")):next(function(result)
    UpdateProperty("Offline Key", result.offlineKey)
    UpdateProperty("Key Slot", tostring(result.keySlot))
    UpdateProperty("Yale Cloud Status", "Keys fetched successfully")
    log:info("Successfully fetched offline key (slot %s)", result.keySlot)
  end, function(err)
    log:error("Failed to fetch keys: %s", err)
    UpdateProperty("Yale Cloud Status", "Error: " .. tostring(err))
  end)
end

function EC.Request_Status()
  log:info("Status refresh requested via programming")
  initiateCommand("status")
end

function EC.Set_Connection_Mode(params)
  local mode = Select(params, "Mode")
  log:info("Connection mode change requested via programming: %s", mode)
  if mode then
    UpdateProperty("Connection Mode", mode, true)
  end
end

function EC.Set_Polling_Interval(params)
  local interval = tointeger(Select(params, "Interval"))
  log:info("Polling interval change requested via programming: %s", interval)
  if interval then
    UpdateProperty("Polling Interval", tostring(interval), true)
  end
end

function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")

  bindings:reset()
  values:reset()
  resetConnectionState(true)
  initialStatusTriggered = false
  doorSenseConfigured = nil

  -- Restore connection mode from property
  connectionMode = Properties["Connection Mode"] or CONNECTION_MODE.POLL
  if connectionMode ~= CONNECTION_MODE.POLL then
    C4:SetPropertyAttribs("Polling Interval", constants.HIDE_PROPERTY)
  else
    C4:SetPropertyAttribs("Polling Interval", constants.SHOW_PROPERTY)
  end

  UpdateProperty("Driver Status", "Disconnected")
  UpdateProperty("Lock Status", "Unknown")
  UpdateProperty("Door Status", "")
  C4:SetPropertyAttribs("Door Status", constants.HIDE_PROPERTY)
  UpdateProperty("Battery", "")
  UpdateProperty("Yale Cloud Status", "")
end
