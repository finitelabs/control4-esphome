--- ESPHome Homedics SereneScent BLE diffuser driver.
--- Connects for each command or poll, reads the status frame and disconnects:
--- the diffuser serves one client at a time and each connection holds one of the
--- proxy's few GATT slots.
--#ifdef DRIVERCENTRAL
DC_PID = 819
DC_X = nil
DC_FILENAME = "esphome_serenescent.c4z"
--#endif
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local values = require("lib.values")
local UUID = require("esphome.ble.uuid")
local protocol = require("esphome.ble.serenescent_protocol")

--- Update the Driver Status property and the Connected variable so
--- Programming can react to connect/disconnect.
--- @param status string The human-readable connection status.
--- @param connected boolean Whether this status represents a live connection;
--- callers pass it explicitly so rewording a status can never silently flip
--- the Connected variable.
local function updateStatus(status, connected)
  log:trace("updateStatus(%s, %s)", status, connected)
  if type(connected) ~= "boolean" then
    error(string.format("updateStatus(%s): connected must be an explicit boolean", tostring(status)), 2)
  end
  UpdateProperty("Driver Status", status)
  values:update("Connected", connected, "BOOL")
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- @type integer
local ESPHOME_BINDING = 5002
--- @type integer
local RELAY_BINDING = 308

--- Static BUTTON_LINK connections from driver.xml and the action each runs.
--- @type table<integer, string>
local BUTTON_LINK_ACTIONS = {
  [300] = "on",
  [301] = "off",
  [302] = "toggle",
  [303] = "intensity_up",
  [304] = "intensity_down",
  [305] = "intensity_low",
  [306] = "intensity_medium",
  [307] = "intensity_high",
}

--- @type integer
local BUTTON_LINK_COALESCE_MS = 500
--- Settle time after a write nothing answers (the HOME mode switch), per upstream.
--- @type integer
local COMMAND_DELAY_MS = 200
--- How long upstream waits for an ack or a status reply before moving on.
--- @type integer
local RESPONSE_TIMEOUT_MS = 2000
--- Linger after the last reply so presses in quick succession share a connection.
--- @type integer
local DISCONNECT_DELAY_MS = 3000
--- Covers both connecting and subscribing to notifications.
--- @type integer
local CONNECT_TIMEOUT_MS = 30000
--- How long to wait for the proxy to answer our DISCONNECT before connecting
--- again. The standalone proxy only answers when the slot was allocated.
--- @type integer
local DISCONNECT_SETTLE_MS = 3000
--- @type integer
local ADVERTISEMENT_THROTTLE_S = 30

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

--- Last status the device reported. Nil fields have never been read.
--- @class SereneScentState
--- @field power boolean|nil
--- @field intensity string|nil
--- @field color string|nil
--- @field mode integer|nil
--- @type SereneScentState
local state = {}

--- @alias SereneScentLink "idle"|"connecting"|"subscribing"|"ready"|"disconnecting"
--- @type SereneScentLink
local link = "idle"

--- @type integer|nil
local txHandle = nil
--- @type integer|nil
local rxHandle = nil

--- Operations waiting for the connection, in the order they were asked for.
--- @class SereneScentOp
--- @field kind "power"|"intensity"|"color"|"status"
--- @field value boolean|string|nil
--- @type SereneScentOp[]
local queue = {}

--- The opcode of the write awaiting its reply, or nil when nothing is in flight.
--- @type integer|nil
local awaitingOpcode = nil

--- A control write went out since the last status reply, so the cycle must end
--- with a status query: state is only ever taken from the device's own reply.
--- @type boolean
local needsStatus = false

--- Power and intensity written since the last status reply, so a toggle or
--- step pressed before that reply builds on what was sent, not on stale state.
--- @type { power: boolean|nil, intensity: string|nil }
local written = {}

--- @type boolean
local initialStatusTriggered = false

--- @type integer
local lastAdvProcessedAt = 0

--- Last power state sent to the relay this session. In-memory on purpose: a
--- driver restart clears it, so the bound consumer is re-notified.
--- @type boolean|nil
local lastNotifiedPower = nil

--------------------------------------------------------------------------------
-- Device State
--------------------------------------------------------------------------------

local function loadState()
  local saved = persist:get("deviceState", {})
  state = {
    power = Select(saved, "power"),
    intensity = Select(saved, "intensity"),
    color = Select(saved, "color"),
    mode = Select(saved, "mode"),
  }
end

--- Notify the relay consumer of the power state, once per change this session.
local function notifyRelay()
  if state.power == nil or lastNotifiedPower == state.power then
    return
  end
  lastNotifiedPower = state.power
  SendToProxy(RELAY_BINDING, state.power and "CLOSED" or "OPENED", {}, "NOTIFY")
end

--- Mirror the last reported status into properties, variables and the relay.
--- Intensity and color read Off while the diffuser is off so a stale level is
--- not mistaken for the running one.
local function publishState()
  local function show(value)
    if state.power == false then
      return "Off"
    end
    return value or "Unknown"
  end
  local power = state.power == nil and "Unknown" or (state.power and "On" or "Off")
  values:update("Power", power, "STRING")
  values:update("Intensity", show(state.intensity), "STRING")
  values:update("Color", show(state.color), "STRING")
  notifyRelay()
end

--- @param status SereneScentStatus
local function applyStatus(status)
  log:info(
    "Status: power=%s intensity=%s color=%s schedule=%s mode=%s",
    status.power,
    status.intensity,
    status.color,
    status.schedule,
    status.mode
  )
  state.power = status.power
  state.mode = status.mode
  written = {}
  -- An unrecognised byte leaves the last known value rather than guessing one
  if status.intensity then
    state.intensity = status.intensity
  else
    log:warn("Status reported an unknown intensity; keeping %s", state.intensity)
  end
  if status.color then
    state.color = status.color
  else
    log:warn("Status reported an unknown color; keeping %s", state.color)
  end
  persist:set("deviceState", state)
  values:update("Last Seen", tostring(os.date("%Y-%m-%d %H:%M:%S")))
  publishState()
end

--------------------------------------------------------------------------------
-- Connection Management
--------------------------------------------------------------------------------

local runQueue
local initiate

--- Drop the connection state and every timer tied to it. Queued operations are
--- reported and dropped, since nothing will carry them out.
local function resetConnectionState()
  log:trace("resetConnectionState()")
  if #queue > 0 then
    log:warn("Dropping %d queued operation(s): the connection ended first", #queue)
  end
  link = "idle"
  txHandle = nil
  rxHandle = nil
  queue = {}
  awaitingOpcode = nil
  needsStatus = false
  written = {}
  CancelTimer("ConnectTimeout")
  CancelTimer("ResponseTimeout")
  CancelTimer("CommandDelay")
  CancelTimer("DisconnectDelay")
  CancelTimer("DisconnectSettle")
end

--- Arm the next poll.
--- @param connected boolean Whether the cycle that just ended was healthy;
--- drives the Connected variable across the wait.
local function schedulePoll(connected)
  local interval = tointeger(Properties["Polling Interval"]) or 5
  log:debug("Scheduling next poll in %d minutes", interval)
  updateStatus(string.format("Listening (next poll in %dm)", interval), connected)
  SetTimer("PollCycle", interval * ONE_MINUTE, function()
    log:info("Poll timer fired - requesting status")
    initiate({ kind = "status" })
  end)
end

local connect

--- The proxy has answered our DISCONNECT, or stayed silent long enough. Run
--- anything queued while we waited.
local function disconnected()
  log:trace("disconnected()")
  CancelTimer("DisconnectSettle")
  link = "idle"
  if #queue > 0 then
    connect()
  end
end

--- Send DISCONNECT and hold new connections until the proxy answers it. Its
--- DISCONNECTED can arrive after a new CONNECT has gone out, and would then
--- read as the new link dropping.
local function releaseLink()
  link = "disconnecting"
  SendToProxy(ESPHOME_BINDING, "DISCONNECT", {}, "NOTIFY")
  SetTimer("DisconnectSettle", DISCONNECT_SETTLE_MS, disconnected)
end

--- Release the connection slot and wait for the next poll.
--- @param connected boolean Whether the cycle ended healthy
local function disconnect(connected)
  log:trace("disconnect(%s)", connected)
  resetConnectionState()
  releaseLink()
  schedulePoll(connected)
end

--- End a failed cycle.
--- @param status string Why it failed, for the log and Driver Status
local function fail(status)
  log:warn("SereneScent cycle failed: %s", status)
  disconnect(false)
  -- The poll text replaced the reason in the same tick; keep the reason visible
  updateStatus(status, false)
end

connect = function()
  log:trace("connect()")
  link = "connecting"
  updateStatus("Connecting", Select(values:getValue("Connected"), "value") == true)
  SendToProxy(ESPHOME_BINDING, "CONNECT", {}, "NOTIFY")
  SetTimer("ConnectTimeout", CONNECT_TIMEOUT_MS, function()
    fail("Connection timed out")
  end)
end

--- @param data string
local function gattWrite(data)
  log:debug("GATT write: %s", C4:Encode(data, "HEX"))
  SendToProxy(ESPHOME_BINDING, "GATT_WRITE", {
    handle = tostring(txHandle),
    data = C4:Base64Encode(data),
    -- Write Command, as the vendor app and upstream send it
    response = "false",
  }, "NOTIFY")
end

--- The write in flight was answered, or needs no answer: move on.
local function replyReceived()
  CancelTimer("ResponseTimeout")
  CancelTimer("CommandDelay")
  awaitingOpcode = nil
  runQueue()
end

--- Write a frame and wait for the reply echoing `opcode`. A missing reply is not
--- fatal for a command, matching upstream: the status query that follows is
--- what decides the outcome.
--- @param data string
--- @param opcode integer
local function writeAndAwait(data, opcode)
  awaitingOpcode = opcode
  gattWrite(data)
  SetTimer("ResponseTimeout", RESPONSE_TIMEOUT_MS, function()
    awaitingOpcode = nil
    if opcode == protocol.Opcode.STATUS then
      fail("No response from device")
    else
      log:warn("No acknowledgement for opcode 0x%02X", opcode)
      runQueue()
    end
  end)
end

--- @param op SereneScentOp
--- @return string|nil frame, integer|nil opcode
local function frameFor(op)
  if op.kind == "power" then
    return protocol.powerCommand(op.value == true), op.value and protocol.Opcode.POWER_ON or protocol.Opcode.POWER_OFF
  elseif op.kind == "intensity" then
    return protocol.intensityCommand(tostring(op.value)), protocol.Opcode.INTENSITY
  elseif op.kind == "color" then
    return protocol.colorCommand(tostring(op.value)), protocol.Opcode.COLOR
  end
end

--- Send the next queued operation, or finish the cycle with a status query and
--- a delayed disconnect once the queue is empty.
runQueue = function()
  if link ~= "ready" or awaitingOpcode then
    return
  end
  CancelTimer("DisconnectDelay")

  local op = table.remove(queue, 1)
  if op == nil then
    if needsStatus then
      needsStatus = false
      writeAndAwait(protocol.statusQuery(state.mode), protocol.Opcode.STATUS)
      return
    end
    SetTimer("DisconnectDelay", DISCONNECT_DELAY_MS, function()
      disconnect(true)
    end)
    return
  end

  if op.kind == "status" then
    needsStatus = true
    runQueue()
    return
  end

  -- Intensity and color only take effect in HOME mode; upstream switches
  -- whenever the last status said otherwise, which also ends any app schedule.
  if state.mode ~= nil and state.mode ~= protocol.Mode.HOME then
    log:info("Switching diffuser to HOME mode")
    gattWrite(protocol.homeModeCommand())
    state.mode = protocol.Mode.HOME
    table.insert(queue, 1, op)
    awaitingOpcode = protocol.Opcode.MODE
    SetTimer("CommandDelay", COMMAND_DELAY_MS, replyReceived)
    return
  end

  local data, opcode = frameFor(op)
  if not data or not opcode then
    log:warn("Ignoring invalid %s value: %s", op.kind, op.value)
    runQueue()
    return
  end
  log:info("Sending %s %s", op.kind, op.value)
  needsStatus = true
  if op.kind == "power" or op.kind == "intensity" then
    written[op.kind] = op.value
  end
  writeAndAwait(data, opcode)
end

--- Queue an operation, connecting if needed.
--- @param op SereneScentOp
initiate = function(op)
  log:trace("initiate(%s %s)", op.kind, op.value)
  -- Any cycle reads status on its way out, so none is owed to an advertisement
  initialStatusTriggered = true
  CancelTimer("PollCycle")
  table.insert(queue, op)
  if link == "idle" then
    connect()
  else
    runQueue()
  end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- The power state the queue will leave behind, so a second toggle queued
--- behind the first undoes it rather than repeating it.
--- @return boolean
local function projectedPower()
  for i = #queue, 1, -1 do
    if queue[i].kind == "power" then
      return queue[i].value == true
    end
  end
  if written.power ~= nil then
    return written.power
  end
  return state.power == true
end

--- @return string|nil
local function projectedIntensity()
  for i = #queue, 1, -1 do
    if queue[i].kind == "intensity" then
      return tostring(queue[i].value)
    end
  end
  return written.intensity or state.intensity
end

--- Step the intensity one level, stopping at either end.
--- @param step integer 1 for up, -1 for down
local function stepIntensity(step)
  local levels = protocol.INTENSITIES
  local current = projectedIntensity()
  for i, level in ipairs(levels) do
    if level == current then
      local target = levels[math.max(1, math.min(#levels, i + step))]
      if target ~= current then
        initiate({ kind = "intensity", value = target })
      end
      return
    end
  end
  -- Never read: the middle level is right whichever way the user meant
  initiate({ kind = "intensity", value = "medium" })
end

--- @type table<string, fun()>
local ACTIONS = {
  on = function()
    initiate({ kind = "power", value = true })
  end,
  off = function()
    initiate({ kind = "power", value = false })
  end,
  toggle = function()
    initiate({ kind = "power", value = not projectedPower() })
  end,
  intensity_up = function()
    stepIntensity(1)
  end,
  intensity_down = function()
    stepIntensity(-1)
  end,
  intensity_low = function()
    initiate({ kind = "intensity", value = "low" })
  end,
  intensity_medium = function()
    initiate({ kind = "intensity", value = "medium" })
  end,
  intensity_high = function()
    initiate({ kind = "intensity", value = "high" })
  end,
}

--- Register the RFP handler for a static BUTTON_LINK connection.
--- @param bindingId integer
--- @param action string Key into ACTIONS
local function registerButtonLink(bindingId, action)
  local coalescing = false
  RFP[bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s) action=%s", bindingId, idBinding, strCommand, action)
    if strCommand ~= "DO_CLICK" and strCommand ~= "DO_PUSH" then
      return
    end
    -- Senders disagree on which of the pair they emit: some send only DO_CLICK,
    -- some only DO_PUSH, and a keypad tap sends DO_PUSH then DO_CLICK. Acting on
    -- the first of a burst and ignoring the rest of the window runs the action
    -- once per tap for all three, whichever command arrives first.
    if coalescing then
      log:debug("Ignoring %s within %dms of the last button action", strCommand, BUTTON_LINK_COALESCE_MS)
      return
    end
    coalescing = true
    SetTimer("ButtonLinkCoalesce" .. bindingId, BUTTON_LINK_COALESCE_MS, function()
      coalescing = false
    end)
    log:info("Button link action %s", action)
    ACTIONS[action]()
  end
end

for bindingId, action in pairs(BUTTON_LINK_ACTIONS) do
  registerButtonLink(bindingId, action)
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
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  -- Restore persisted state
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  loadState()

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  gInitialized = true
  updateStatus("Disconnected", false)

  -- Request refresh from parent driver
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
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

function OPC.Polling_Interval(propertyValue)
  log:trace("OPC.Polling_Interval('%s')", propertyValue)
  -- Only an armed poll is rescheduled; an active cycle arms its own when it
  -- ends. Carry Connected across so an interval edit cannot flap it.
  if not gInitialized or (link ~= "idle" and link ~= "disconnecting") or not Timer.PollCycle then
    return
  end
  schedulePoll(Select(values:getValue("Connected"), "value") == true)
end

--------------------------------------------------------------------------------
-- RFP Handlers - ESPHome BLE Connection
--------------------------------------------------------------------------------

--- Handle connection notification from main driver. Also arrives unasked when
--- the connection is bound or the proxy restarts, and is then used to refresh
--- status rather than left holding the slot.
function RFP.CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  local name = Select(tParams, "name")
  local mac = Select(tParams, "mac")
  log:info("Connected to SereneScent: %s", mac or "unknown")
  if not IsEmpty(name) then
    values:update("Name", name, "STRING")
  end
  if not IsEmpty(mac) then
    values:update("MAC Address", mac, "STRING")
  end

  -- Once subscribed the link is in use; while disconnecting it is on its way
  -- out. A CONNECTED during subscribing is a fresh link and starts over.
  if link == "ready" or link == "disconnecting" then
    log:debug("Ignoring CONNECTED while %s", link)
    return
  end

  local services = DeserializeSafe(Select(tParams, "services"))
  txHandle = UUID.findCharacteristicHandle(services, protocol.UUID.SERVICE, protocol.UUID.TX)
  rxHandle = UUID.findCharacteristicHandle(services, protocol.UUID.SERVICE, protocol.UUID.RX)
  if not txHandle or not rxHandle then
    fail("Error: Missing characteristics")
    return
  end
  log:debug("Found SereneScent handles: TX=%d, RX=%d", txHandle, rxHandle)

  if #queue == 0 then
    table.insert(queue, { kind = "status" })
  end
  initialStatusTriggered = true
  CancelTimer("PollCycle")
  link = "subscribing"
  -- Re-armed so a subscription that is never confirmed cannot hold the slot
  SetTimer("ConnectTimeout", CONNECT_TIMEOUT_MS, function()
    fail("Connection timed out")
  end)
  SendToProxy(ESPHOME_BINDING, "GATT_NOTIFY", {
    handle = tostring(rxHandle),
    enable = "true",
  }, "NOTIFY")
end

--- Handle notification subscription result from main driver
function RFP.GATT_NOTIFY_SUBSCRIBED(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_SUBSCRIBED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING or link ~= "subscribing" then
    return
  end
  if tointeger(Select(tParams, "handle")) ~= rxHandle then
    return
  end
  if Select(tParams, "success") ~= "true" then
    -- A second CONNECTED re-subscribes, and the proxy supersedes the first
    -- request; the newer one still answers
    local err = Select(tParams, "error") or ""
    if err:find("Superseded", 1, true) then
      log:debug("Ignoring superseded subscription")
      return
    end
    fail("Error: Notification subscription failed")
    return
  end
  CancelTimer("ConnectTimeout")
  link = "ready"
  updateStatus("Connected", true)
  runQueue()
end

--- Handle a notification from the diffuser: an ack or a status frame
function RFP.GATT_NOTIFY_DATA(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_NOTIFY_DATA(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  local data = C4:Base64Decode(Select(tParams, "data") or "") or ""
  if protocol.isFiller(data) then
    return
  end
  log:debug("GATT notify: %s", C4:Encode(data, "HEX"))

  local response, err = protocol.parseResponse(data)
  if not response then
    log:debug("Ignoring notification: %s", err)
    return
  end
  if response.status then
    applyStatus(response.status)
  end
  if awaitingOpcode ~= nil and response.opcode == awaitingOpcode then
    replyReceived()
  end
end

--- Handle GATT write result from main driver
function RFP.GATT_WRITE_RESPONSE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GATT_WRITE_RESPONSE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  if Select(tParams, "success") ~= "true" then
    log:warn("GATT write failed: %s", Select(tParams, "error") or "unknown")
  end
end

--- Handle disconnection. A disconnect this driver asked for has already been
--- accounted for; anything else ends the cycle as a failure.
function RFP.DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.DISCONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  if link == "disconnecting" then
    disconnected()
    return
  end
  if link == "idle" then
    return
  end
  fail("Disconnected: " .. (Select(tParams, "reason") or "unknown"))
end

--- Handle connection failure notification from main driver
function RFP.CONNECTION_FAILED(idBinding, strCommand, tParams, args)
  log:trace("RFP.CONNECTION_FAILED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end
  local err = Select(tParams, "error") or "unknown"
  -- Only our own attempt can fail us. The standalone proxy also connects on
  -- bind, and the attempt a later CONNECT supersedes reports failing while the
  -- newer one carries on.
  if link ~= "connecting" or err:find("Superseded", 1, true) then
    log:debug("Ignoring connection failure while %s: %s", link, err)
    return
  end
  fail("Connection failed: " .. err)
end

--- Handle incoming BLE advertisement from parent driver
function RFP.BLE_ADVERTISEMENT(idBinding, strCommand, tParams, args)
  if idBinding ~= ESPHOME_BINDING then
    return
  end

  -- The first advertisement after a start or a bind reads the status, which
  -- also starts the poll cycle when it disconnects.
  if not initialStatusTriggered and link == "idle" then
    log:info("Initial status query")
    initiate({ kind = "status" })
  end

  local now = os.time()
  if now - lastAdvProcessedAt < ADVERTISEMENT_THROTTLE_S then
    return
  end
  lastAdvProcessedAt = now

  local advertisement = DeserializeSafe(Select(tParams, "advertisement"))
  local rssi = tofinite(Select(advertisement, "rssi"))
  if rssi then
    values:update("RSSI", rssi, nil, nil, " dBm")
  end
  values:update("Last Seen", tostring(os.date("%Y-%m-%d %H:%M:%S")))
end

--------------------------------------------------------------------------------
-- RFP Handlers - Power Relay
--------------------------------------------------------------------------------

function RFP.CLOSE(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.CLOSE(%s, %s)", idBinding, strCommand)
  if idBinding == RELAY_BINDING then
    ACTIONS.on()
  end
end

function RFP.OPEN(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.OPEN(%s, %s)", idBinding, strCommand)
  if idBinding == RELAY_BINDING then
    ACTIONS.off()
  end
end

function RFP.TOGGLE(idBinding, strCommand, _tParams, _args)
  log:trace("RFP.TOGGLE(%s, %s)", idBinding, strCommand)
  if idBinding == RELAY_BINDING then
    ACTIONS.toggle()
  end
end

--------------------------------------------------------------------------------
-- OBC Handlers
--------------------------------------------------------------------------------

--- Seed a newly bound relay consumer with the last known power state.
OBC[RELAY_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId)
  log:trace("OBC[%s](%s, %s, %s, %s)", RELAY_BINDING, idBinding, strClass, bIsBound, otherDeviceId)
  if bIsBound and state.power ~= nil then
    SendToProxy(RELAY_BINDING, state.power and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end

OBC[ESPHOME_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId)
  log:trace("OBC[%s](%s, %s, %s, %s)", ESPHOME_BINDING, idBinding, strClass, bIsBound, otherDeviceId)
  resetConnectionState()
  CancelTimer("PollCycle")
  initialStatusTriggered = false
  lastNotifiedPower = nil

  if bIsBound then
    updateStatus("Waiting for data", false)
  else
    updateStatus("Disconnected", false)
  end
end

--------------------------------------------------------------------------------
-- EC Handlers (Actions and Programming Commands)
--------------------------------------------------------------------------------

function EC.Power_On()
  log:trace("EC.Power_On()")
  ACTIONS.on()
end

function EC.Power_Off()
  log:trace("EC.Power_Off()")
  ACTIONS.off()
end

function EC.Toggle_Power()
  log:trace("EC.Toggle_Power()")
  ACTIONS.toggle()
end

function EC.Set_Intensity(params)
  log:trace("EC.Set_Intensity(%s)", params)
  local level = string.lower(Select(params, "Level") or "")
  if not protocol.intensityCommand(level) then
    log:warn("Invalid intensity: %s", level)
    return
  end
  initiate({ kind = "intensity", value = level })
end

function EC.Set_Color(params)
  log:trace("EC.Set_Color(%s)", params)
  local color = string.lower(Select(params, "Color") or "")
  if not protocol.colorCommand(color) then
    log:warn("Invalid color: %s", color)
    return
  end
  initiate({ kind = "color", value = color })
end

function EC.Request_Status()
  log:trace("EC.Request_Status()")
  initiate({ kind = "status" })
end

function EC.Set_Polling_Interval(params)
  log:trace("EC.Set_Polling_Interval(%s)", params)
  local interval = tointeger(Select(params, "Interval"))
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

  local previous = link
  resetConnectionState()
  if previous == "disconnecting" then
    -- The answer to the DISCONNECT already sent is still owed; keep waiting
    -- for it so it cannot fail the next cycle
    link = "disconnecting"
    SetTimer("DisconnectSettle", DISCONNECT_SETTLE_MS, disconnected)
  elseif previous ~= "idle" then
    releaseLink()
  end
  CancelTimer("PollCycle")
  persist:delete("deviceState")
  state = {}
  initialStatusTriggered = false
  lastNotifiedPower = nil

  for propName, defaultValue in pairs(GetPropertyResetValues({ "Driver Status", "Driver Version" })) do
    UpdateProperty(propName, defaultValue, true)
  end
  updateStatus("Disconnected", false)
  -- Delete the variables after the final status write so Reset Driver does not
  -- immediately recreate the Connected variable it just removed
  values:reset()

  -- Request refresh from parent driver
  SendToProxy(ESPHOME_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end
