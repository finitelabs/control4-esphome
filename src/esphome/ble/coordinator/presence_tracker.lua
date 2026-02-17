--- Presence Tracker for Bluetooth Coordinator.
--- Implements ESPresence-style room presence detection with anti-flapping.

local log = require("lib.logging")
local events = require("lib.events")
local values = require("lib.values")
local bindings = require("lib.bindings")
local proxyRegistry = require("esphome.ble.coordinator.proxy_registry")
local deviceRegistry = require("esphome.ble.coordinator.device_registry")

--- @class PresenceDeviceConfig
--- @field mac string MAC address
--- @field name string Display name
--- @field type string Device type (phone, watch, beacon, etc.)
--- @field txPower number Reference RSSI at 1 meter

--- @class PresenceDeviceState
--- @field room string|nil Current room name
--- @field roomId integer|nil Current room ID
--- @field lastSeen integer? Timestamp of last sighting
--- @field pendingTransition PendingTransition|nil Pending room change
--- @field isHome boolean Whether device is considered "home"

--- @class PendingTransition
--- @field targetRoom string The room we might transition to
--- @field targetRoomId integer The room ID
--- @field startTime number When we first saw this room as best
--- @field rssiReadings number[] RSSI readings during dwell period

--- @class RSSIState
--- @field smoothedRssi number EMA-smoothed RSSI value
--- @field lastRawRssi number Most recent raw reading
--- @field lastUpdate number Timestamp of last update

--- @class PresenceTracker
--- @field _presenceDevices table<string, PresenceDeviceConfig?> MAC -> config
--- @field _smoothingAlpha number EMA smoothing factor (0.1-0.5)
--- @field _hysteresisMargin number dBm margin for room changes
--- @field _dwellTime number Seconds to dwell before committing room change
--- @field _awayTimeout number Seconds without signal before marking away
--- @field _minRoomRssi number Minimum RSSI to assign room (-100 = disabled)
--- @field _deviceState table<string, PresenceDeviceState?> MAC -> state
--- @field _rssiState table<string, RSSIState?> "mac_proxyDeviceId" -> state
--- @field _roomOccupancy table<integer, table<string, boolean?>?> roomId -> {mac -> true}
--- @field _roomBindings table<integer, integer?> roomId -> bindingId
--- @field _deviceBindings table<string, integer?> mac -> bindingId
--- @field _roomNames table<integer, string?> roomId -> roomName (for cleanup)
local PresenceTracker = {}
PresenceTracker.__index = PresenceTracker

local NAMESPACE = "presence"
local BINDINGS_NAMESPACE = "presence"

--- Generate a unique display name with partial MAC suffix
--- @param name string Base display name
--- @param mac string MAC address
--- @return string uniqueName The name with partial MAC, e.g., "John's Phone [AABBCCDDEEFF]"
local function makeUniqueName(name, mac)
  local cleanMac = mac:gsub(":", "")
  return name .. " [" .. cleanMac .. "]"
end

--- Generate a unique room display name with room ID suffix
--- @param roomName string The base room name
--- @param roomId integer The room ID
--- @return string uniqueName The name with room ID, e.g., "Kitchen [123]"
local function makeUniqueRoomName(roomName, roomId)
  return roomName .. " [" .. tostring(roomId) .. "]"
end

--- Create a new PresenceTracker instance
--- @return PresenceTracker
function PresenceTracker:new()
  local instance = setmetatable({}, self)

  -- Configuration
  instance._presenceDevices = {}
  instance._smoothingAlpha = 0.2
  instance._hysteresisMargin = 6
  instance._dwellTime = 5
  instance._awayTimeout = 120
  instance._minRoomRssi = -100 -- Global minimum RSSI to assign a room (-100 = disabled)

  -- State
  instance._deviceState = {}
  instance._rssiState = {}
  instance._roomOccupancy = {}

  -- Bindings for presence sensors
  instance._roomBindings = {}
  instance._deviceBindings = {}
  instance._roomNames = {}

  return instance
end

--- Configure presence tracking settings
--- @param settings table Settings from properties
function PresenceTracker:configure(settings)
  if settings.smoothingAlpha then
    self._smoothingAlpha = tonumber(settings.smoothingAlpha) or 0.2
  end
  if settings.hysteresisMargin then
    self._hysteresisMargin = tonumber(settings.hysteresisMargin) or 6
  end
  if settings.dwellTime then
    self._dwellTime = tonumber(settings.dwellTime) or 5
  end
  if settings.awayTimeout then
    self._awayTimeout = tonumber(settings.awayTimeout) or 120
  end
  if settings.minRoomRssi then
    self._minRoomRssi = tointeger(settings.minRoomRssi) or -100
  end

  log:info(
    "Presence settings: smoothing=%.2f, hysteresis=%ddBm, dwell=%ds, away=%ds, minRoomRssi=%ddBm",
    self._smoothingAlpha,
    self._hysteresisMargin,
    self._dwellTime,
    self._awayTimeout,
    self._minRoomRssi
  )
end

--- Add a device to track for presence
--- @param mac string MAC address
--- @param config PresenceDeviceConfig Configuration
function PresenceTracker:trackDevice(mac, config)
  self._presenceDevices[mac] = config

  -- Initialize state
  self._deviceState[mac] = {
    room = nil,
    roomId = nil,
    lastSeen = nil,
    pendingTransition = nil,
    isHome = false,
  }

  local uniqueName = makeUniqueName(config.name, mac)

  -- Create dynamic binding for this device's presence
  self:_createDeviceBinding(mac, uniqueName)

  -- Create events for this device
  self:_createDeviceEvents(mac, uniqueName)

  -- Create variables for this device
  values:update("Presence " .. uniqueName .. " Room", "", "STRING")
  values:update("Presence " .. uniqueName .. " Distance", "0", "NUMBER")
  values:update("Presence " .. uniqueName .. " RSSI", "-999", "NUMBER")
  --values:update("Presence " .. uniqueName .. " Last Seen", "", "STRING")

  log:info("Added presence device: %s (%s)", uniqueName, mac)
end

--- Remove a device from presence tracking
--- @param mac string MAC address
function PresenceTracker:untrackDevice(mac)
  local config = self._presenceDevices[mac]
  if not config then
    return
  end

  local uniqueName = makeUniqueName(config.name, mac)
  local macKey = mac:gsub(":", "")

  -- Clean up state
  self._deviceState[mac] = nil
  self._presenceDevices[mac] = nil

  -- Clean up RSSI state
  for key in pairs(self._rssiState) do
    if key:match("^" .. mac .. "_") then
      self._rssiState[key] = nil
    end
  end

  -- Remove binding
  if self._deviceBindings[mac] then
    bindings:deleteBinding(BINDINGS_NAMESPACE, "device_" .. macKey)
    self._deviceBindings[mac] = nil
  end

  -- Remove events
  events:deleteEvent(NAMESPACE, "device_" .. macKey .. "_home")
  events:deleteEvent(NAMESPACE, "device_" .. macKey .. "_away")
  events:deleteEvent(NAMESPACE, "device_" .. macKey .. "_entered_room")
  events:deleteEvent(NAMESPACE, "device_" .. macKey .. "_left_room")

  -- Remove variables
  values:delete("Presence " .. uniqueName .. " Room")
  values:delete("Presence " .. uniqueName .. " Distance")
  values:delete("Presence " .. uniqueName .. " RSSI")
  --values:delete("Presence " .. uniqueName .. " Last Seen")

  log:info("Removed presence device: %s", mac)
end

--- Create a contact sensor binding for a presence device
--- @param mac string MAC address
--- @param name string Display name
--- @private
function PresenceTracker:_createDeviceBinding(mac, name)
  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    "device_" .. mac:gsub(":", ""),
    "PROXY",
    true,
    name .. " Present",
    "CONTACT_SENSOR"
  )

  if binding then
    self._deviceBindings[mac] = binding.bindingId
  end
end

--- Create events for a presence device
--- @param mac string MAC address
--- @param name string Display name
--- @private
--- @diagnostic disable-next-line: unused
function PresenceTracker:_createDeviceEvents(mac, name)
  local macKey = mac:gsub(":", "")

  events:getOrAddEvent(
    NAMESPACE,
    "device_" .. macKey .. "_home",
    name .. " Home",
    "Fired when " .. name .. " arrives home"
  )

  events:getOrAddEvent(
    NAMESPACE,
    "device_" .. macKey .. "_away",
    name .. " Away",
    "Fired when " .. name .. " leaves home"
  )

  events:getOrAddEvent(
    NAMESPACE,
    "device_" .. macKey .. "_entered_room",
    name .. " Entered Room",
    "Fired when " .. name .. " enters a room (check 'Last Presence Room' variable)"
  )

  events:getOrAddEvent(
    NAMESPACE,
    "device_" .. macKey .. "_left_room",
    name .. " Left Room",
    "Fired when " .. name .. " leaves a room"
  )
end

--- Ensure room bindings and events exist for a room
--- @param roomId integer Room ID
--- @param roomName string Room name
--- @private
function PresenceTracker:_ensureRoomSetup(roomId, roomName)
  -- Check if room already exists
  local existingName = self._roomNames[roomId]
  if existingName then
    if existingName ~= roomName then
      -- Different proxies reporting different names for same room ID
      -- This usually means misconfigured "Bluetooth Proxy Room" properties
      -- Just use the existing name and don't recreate resources
      log:debug(
        "Room %d has conflicting names from different proxies: '%s' vs '%s' (using '%s')",
        roomId,
        existingName,
        roomName,
        existingName
      )
    end
    return -- Already set up
  end

  local uniqueRoomName = makeUniqueRoomName(roomName, roomId)

  -- Create binding for room occupancy
  local binding = bindings:getOrAddDynamicBinding(
    BINDINGS_NAMESPACE,
    "room_" .. tostring(roomId),
    "PROXY",
    true,
    uniqueRoomName .. " Occupied",
    "CONTACT_SENSOR"
  )

  if binding then
    self._roomBindings[roomId] = binding.bindingId
  end

  -- Create events for room
  events:getOrAddEvent(
    NAMESPACE,
    "room_" .. tostring(roomId) .. "_occupied",
    uniqueRoomName .. " Occupied",
    "Fired when " .. uniqueRoomName .. " becomes occupied"
  )

  events:getOrAddEvent(
    NAMESPACE,
    "room_" .. tostring(roomId) .. "_empty",
    uniqueRoomName .. " Empty",
    "Fired when " .. uniqueRoomName .. " becomes empty"
  )

  -- Create variables for room
  values:update(uniqueRoomName .. " Occupied", "false", "STRING")
  values:update(uniqueRoomName .. " Occupant Count", "0", "NUMBER")
  values:update(uniqueRoomName .. " Occupants", "", "STRING")

  -- Initialize occupancy tracking
  self._roomOccupancy[roomId] = {}

  -- Store room name for cleanup
  self._roomNames[roomId] = roomName

  log:info("Set up presence tracking for room: %s (%d)", uniqueRoomName, roomId)
end

--- Clean up a room's presence tracking resources
--- @param roomId integer Room ID
--- @private
function PresenceTracker:_cleanupRoom(roomId)
  local roomName = self._roomNames[roomId]
  if not roomName then
    return -- Room was never set up
  end

  local uniqueRoomName = makeUniqueRoomName(roomName, roomId)
  log:info("Cleaning up presence tracking for room: %s (%d)", uniqueRoomName, roomId)

  -- Remove binding
  if self._roomBindings[roomId] then
    bindings:deleteBinding(BINDINGS_NAMESPACE, "room_" .. tostring(roomId))
    self._roomBindings[roomId] = nil
  end

  -- Remove events
  events:deleteEvent(NAMESPACE, "room_" .. tostring(roomId) .. "_occupied")
  events:deleteEvent(NAMESPACE, "room_" .. tostring(roomId) .. "_empty")

  -- Remove variables
  values:delete(uniqueRoomName .. " Occupied")
  values:delete(uniqueRoomName .. " Occupant Count")
  values:delete(uniqueRoomName .. " Occupants")

  -- Remove occupancy tracking
  self._roomOccupancy[roomId] = nil

  -- Remove room name tracking
  self._roomNames[roomId] = nil
end

--- Clean up rooms that are no longer used by any proxy
--- Should be called when proxies disconnect or change rooms
function PresenceTracker:cleanupUnusedRooms()
  local usedRoomIds = {}

  -- Get all room IDs currently in use by connected proxies
  for _, proxy in ipairs(proxyRegistry:getConnectedProxies()) do
    if proxy.roomId then
      usedRoomIds[proxy.roomId] = true
    end
  end

  -- Clean up rooms that are no longer in use
  for roomId, _ in pairs(self._roomNames) do
    if not usedRoomIds[roomId] then
      self:_cleanupRoom(roomId)
    end
  end
end

--- Calculate estimated distance from RSSI using log-distance path loss model
--- @param rssi number Measured RSSI in dBm
--- @param txPower number? Reference RSSI at 1 meter (default -59)
--- @param pathLoss number? Path loss exponent (default 2.5 for indoor)
--- @return number Estimated distance in meters
--- @private
--- @diagnostic disable-next-line: unused
function PresenceTracker:_estimateDistance(rssi, txPower, pathLoss)
  txPower = txPower or -59
  pathLoss = pathLoss or 2.5
  return 10 ^ ((txPower - rssi) / (10 * pathLoss))
end

--- Update smoothed RSSI for a device from a specific proxy
--- @param mac string MAC address
--- @param proxyDeviceId integer Proxy device ID
--- @param rawRssi number Raw RSSI value
--- @return number smoothedRssi The smoothed RSSI value
--- @private
function PresenceTracker:_updateSmoothedRSSI(mac, proxyDeviceId, rawRssi)
  local key = mac .. "_" .. tostring(proxyDeviceId)
  local state = self._rssiState[key]
  local now = os.time()

  if state == nil then
    -- First reading - initialize with raw value
    self._rssiState[key] = {
      smoothedRssi = rawRssi,
      lastRawRssi = rawRssi,
      lastUpdate = now,
    }
    return rawRssi
  else
    -- Apply exponential moving average
    state.smoothedRssi = self._smoothingAlpha * rawRssi + (1 - self._smoothingAlpha) * state.smoothedRssi
    state.lastRawRssi = rawRssi
    state.lastUpdate = now
    return state.smoothedRssi
  end
end

--- Get current room RSSI for a device
--- @param mac string MAC address
--- @param roomId integer Room ID
--- @return number|nil rssi The current RSSI, or nil if not available
--- @private
function PresenceTracker:_getCurrentRoomRSSI(mac, roomId)
  local proxies = proxyRegistry:getProxiesByRoom(roomId)
  local bestRssi = nil

  for _, proxy in ipairs(proxies) do
    local key = mac .. "_" .. tostring(proxy.deviceId)
    local state = self._rssiState[key]
    if state and (not bestRssi or state.smoothedRssi > bestRssi) then
      bestRssi = state.smoothedRssi
    end
  end

  return bestRssi
end

--- Determine which room a device is in based on RSSI
--- @param mac string MAC address
--- @return string|nil room Room name
--- @return integer|nil roomId Room ID
--- @return number|nil rssi Best RSSI
--- @return integer|nil proxyDeviceId The proxy device ID with best signal
--- @private
--- @diagnostic disable-next-line: unused
function PresenceTracker:_determineRoom(mac)
  local rssiMaxAge = 30 -- Only consider recent readings
  local bestRssi, bestDeviceId = deviceRegistry:getBestRSSI(mac, rssiMaxAge)

  if not bestDeviceId then
    return nil, nil, nil, nil
  end

  local proxy = proxyRegistry:getProxy(bestDeviceId)
  if not proxy or not proxy.roomId then
    return nil, nil, bestRssi, bestDeviceId
  end

  -- Get effective minimum RSSI threshold (per-proxy override or global default)
  local threshold = self._minRoomRssi
  if proxy.minRssiOverride and proxy.minRssiOverride > -100 then
    threshold = proxy.minRssiOverride
  end

  -- Check minimum RSSI threshold for room assignment
  -- Device with signal below threshold is "home" but not in any room
  if bestRssi and bestRssi < threshold then
    log:debug(
      "Device %s RSSI %d below threshold %d (proxy %s), no room assigned",
      mac,
      bestRssi,
      threshold,
      proxy.roomName or "Unknown"
    )
    return nil, nil, bestRssi, bestDeviceId
  end

  return proxy.roomName, proxy.roomId, bestRssi, bestDeviceId
end

--- Check if room change should occur (hysteresis check)
--- @param mac string MAC address
--- @param currentRoomId integer|nil Current room ID
--- @param newRoomId integer New room ID
--- @param newRssi number New room's RSSI
--- @return boolean shouldChange
--- @private
function PresenceTracker:_shouldChangeRoom(mac, currentRoomId, newRoomId, newRssi)
  if currentRoomId == nil then
    return true -- No current room, accept new one
  end

  if currentRoomId == newRoomId then
    return false -- Same room
  end

  local currentRssi = self:_getCurrentRoomRSSI(mac, currentRoomId)
  if currentRssi == nil then
    return true -- No current room signal, accept new one
  end

  -- Only switch if new room is significantly stronger
  -- (Remember: RSSI is negative, so -50 > -60)
  return newRssi > (currentRssi + self._hysteresisMargin)
end

--- Process a potential room transition with dwell time
--- @param mac string MAC address
--- @param candidateRoom string|nil Candidate room name
--- @param candidateRoomId integer|nil Candidate room ID
--- @param rssi number RSSI value
--- @return string|nil room Final room (may be unchanged)
--- @return integer|nil roomId Final room ID
--- @private
function PresenceTracker:_processRoomCandidate(mac, candidateRoom, candidateRoomId, rssi)
  local state = self._deviceState[mac]
  if not state then
    return candidateRoom, candidateRoomId
  end

  local currentRoom = state.room
  local currentRoomId = state.roomId
  local now = os.time()

  -- Same room - reset any pending transition
  if candidateRoomId == currentRoomId then
    state.pendingTransition = nil
    return currentRoom, currentRoomId
  end

  -- No candidate room
  if candidateRoomId == nil then
    state.pendingTransition = nil
    return currentRoom, currentRoomId
  end

  -- Check hysteresis
  if not self:_shouldChangeRoom(mac, currentRoomId, candidateRoomId, rssi) then
    state.pendingTransition = nil
    return currentRoom, currentRoomId
  end

  -- Guard: if we're changing rooms, candidateRoom must be valid
  if not candidateRoom or not candidateRoomId then
    return currentRoom, currentRoomId
  end

  -- Start or continue pending transition
  local pending = state.pendingTransition

  if pending == nil or pending.targetRoomId ~= candidateRoomId then
    -- Start new pending transition
    --- @type PendingTransition
    local transition = {
      targetRoom = candidateRoom,
      targetRoomId = candidateRoomId,
      startTime = now,
      rssiReadings = { rssi },
    }
    state.pendingTransition = transition
    return currentRoom, currentRoomId -- Not yet committed
  end

  -- Continue existing pending transition
  table.insert(pending.rssiReadings, rssi)

  -- Check if dwell time has passed
  if (now - pending.startTime) >= self._dwellTime then
    -- Commit the transition
    log:info("Device %s transitioning from %s to %s (dwell complete)", mac, currentRoom or "Unknown", candidateRoom)

    local previousRoom = currentRoom
    local previousRoomId = currentRoomId

    state.room = candidateRoom
    state.roomId = candidateRoomId
    state.pendingTransition = nil

    -- Fire events and update state
    self:_onDeviceEnteredRoom(mac, candidateRoom, candidateRoomId, previousRoom, previousRoomId, rssi)

    return candidateRoom, candidateRoomId
  end

  return currentRoom, currentRoomId -- Still dwelling
end

--- Process an advertisement for a presence device
--- @param mac string MAC address
--- @param proxyDeviceId integer The proxy device ID that saw this device
--- @param rssi number RSSI value
function PresenceTracker:onAdvertisement(mac, proxyDeviceId, rssi)
  local config = self._presenceDevices[mac]
  if not config then
    return -- Not a tracked presence device
  end

  local state = self._deviceState[mac]
  if not state then
    return
  end

  -- Update smoothed RSSI
  self:_updateSmoothedRSSI(mac, proxyDeviceId, rssi)

  -- Update last seen
  state.lastSeen = os.time()

  -- Check if this is a "home" event
  if not state.isHome then
    state.isHome = true
    self:_onDeviceHome(mac, config.name)
  end

  -- Determine best room
  local candidateRoom, candidateRoomId, bestRssi, _ = self:_determineRoom(mac)

  -- Ensure room is set up (use candidateRoom from _determineRoom, not the reporting proxy's room)
  if candidateRoomId and candidateRoom then
    self:_ensureRoomSetup(candidateRoomId, candidateRoom)
  end

  -- Handle signal dropping below threshold - device "left room" but still "home"
  -- This happens when _determineRoom returns nil room due to RSSI below threshold
  if candidateRoom == nil and state.room ~= nil then
    log:info("Device %s signal below threshold, leaving room %s but staying home", mac, state.room)
    -- Fire left_room event
    local macKey = mac:gsub(":", "")
    events:fire(NAMESPACE, "device_" .. macKey .. "_left_room")
    events:fire(NAMESPACE, "any_device_left_room")

    -- Update last event context
    local uniqueName = makeUniqueName(config.name, mac)
    values:update("Last Presence Device MAC", mac, "STRING")
    values:update("Last Presence Device Name", uniqueName, "STRING")
    values:update("Last Presence Room", "Home", "STRING") -- Not in a room, but home
    values:update("Last Presence Previous Room", state.room, "STRING")

    -- Update room occupancy
    if state.roomId then
      self:_updateRoomOccupancy(state.roomId, mac, false)
    end

    -- Clear room state
    state.room = nil
    state.roomId = nil
    state.pendingTransition = nil

    -- Update variables
    local distance = self:_estimateDistance(bestRssi or rssi, config.txPower)
    values:update("Presence " .. uniqueName .. " Room", "Home", "STRING") -- "Home" not "Away"
    values:update("Presence " .. uniqueName .. " Distance", string.format("%.1f", distance), "NUMBER")
    return
  end

  -- Process room transition with anti-flapping
  local finalRoom, _finalRoomId = self:_processRoomCandidate(mac, candidateRoom, candidateRoomId, bestRssi or rssi)

  -- Update variables
  local uniqueName = makeUniqueName(config.name, mac)
  local distance = self:_estimateDistance(bestRssi or rssi, config.txPower)
  values:update("Presence " .. uniqueName .. " Room", finalRoom or "Home", "STRING")
  values:update("Presence " .. uniqueName .. " Distance", string.format("%.1f", distance), "NUMBER")
  values:update("Presence " .. uniqueName .. " RSSI", tostring(bestRssi or rssi), "NUMBER")
  --values:update("Presence " .. uniqueName .. " Last Seen", os.date("%Y-%m-%d %H:%M:%S"), "STRING")
end

--- Check for away status on all devices
--- Call this periodically (e.g., every 30 seconds)
function PresenceTracker:checkAwayStatus()
  local now = os.time()

  for mac, state in pairs(self._deviceState) do
    local config = self._presenceDevices[mac]
    if config and state.isHome then
      if state.lastSeen and (now - state.lastSeen) > self._awayTimeout then
        -- Device has gone away
        local previousRoom = state.room
        local previousRoomId = state.roomId

        state.room = nil
        state.roomId = nil
        state.pendingTransition = nil
        state.isHome = false

        self:_onDeviceAway(mac, config.name, previousRoom, previousRoomId)
      end
    end
  end
end

--- Handle device entering a room
--- @param mac string MAC address
--- @param room string Room name
--- @param roomId integer Room ID
--- @param previousRoom string|nil Previous room name
--- @param previousRoomId integer|nil Previous room ID
--- @param rssi number RSSI value
--- @private
function PresenceTracker:_onDeviceEnteredRoom(mac, room, roomId, previousRoom, previousRoomId, rssi)
  local config = self._presenceDevices[mac]
  if not config then
    return
  end

  local uniqueName = makeUniqueName(config.name, mac)
  local distance = self:_estimateDistance(rssi, config.txPower)

  -- Update per-device state variables
  values:update("Presence " .. uniqueName .. " Room", room, "STRING")
  values:update("Presence " .. uniqueName .. " Distance", string.format("%.1f", distance), "NUMBER")

  -- Update last event context (for programming)
  values:update("Last Presence Device MAC", mac, "STRING")
  values:update("Last Presence Device Name", uniqueName, "STRING")
  values:update("Last Presence Room", room, "STRING")
  values:update("Last Presence Previous Room", previousRoom or "Away", "STRING")
  values:update("Last Presence Distance", string.format("%.1f", distance), "NUMBER")

  -- Update room occupancy
  self:_updateRoomOccupancy(roomId, mac, true)
  if previousRoomId then
    self:_updateRoomOccupancy(previousRoomId, mac, false)
  end

  -- Fire device-specific event
  local macKey = mac:gsub(":", "")
  events:fire(NAMESPACE, "device_" .. macKey .. "_entered_room")

  -- Fire generic event
  events:fire(NAMESPACE, "any_device_entered_room")

  -- Update device binding (contact sensor: CLOSED = present in tracked room)
  local bindingId = self._deviceBindings[mac]
  if bindingId then
    SendToProxy(bindingId, "CLOSED", {}, "NOTIFY")
  end
end

--- Handle device going away
--- @param mac string MAC address
--- @param name string Device name (base name, not unique)
--- @param previousRoom string|nil Previous room
--- @param previousRoomId integer|nil Previous room ID
--- @private
function PresenceTracker:_onDeviceAway(mac, name, previousRoom, previousRoomId)
  local uniqueName = makeUniqueName(name, mac)
  log:info("Device %s (%s) has gone away", uniqueName, mac)

  -- Update variables
  values:update("Presence " .. uniqueName .. " Room", "Away", "STRING")

  -- Update last event context
  values:update("Last Presence Device MAC", mac, "STRING")
  values:update("Last Presence Device Name", uniqueName, "STRING")
  values:update("Last Presence Room", "Away", "STRING")
  values:update("Last Presence Previous Room", previousRoom or "Unknown", "STRING")

  -- Update room occupancy
  if previousRoomId then
    self:_updateRoomOccupancy(previousRoomId, mac, false)
  end

  -- Fire events
  local macKey = mac:gsub(":", "")
  events:fire(NAMESPACE, "device_" .. macKey .. "_away")

  if previousRoom then
    events:fire(NAMESPACE, "device_" .. macKey .. "_left_room")
    events:fire(NAMESPACE, "any_device_left_room")
  end

  -- Update device binding (contact sensor: OPENED = not present)
  local bindingId = self._deviceBindings[mac]
  if bindingId then
    SendToProxy(bindingId, "OPENED", {}, "NOTIFY")
  end
end

--- Handle device coming home
--- @param mac string MAC address
--- @param name string Device name
--- @private
--- @diagnostic disable-next-line: unused
function PresenceTracker:_onDeviceHome(mac, name)
  log:info("Device %s (%s) has arrived home", name, mac)

  local macKey = mac:gsub(":", "")
  events:fire(NAMESPACE, "device_" .. macKey .. "_home")
end

--- Update room occupancy tracking
--- @param roomId integer Room ID
--- @param mac string MAC address
--- @param present boolean Whether device is present
--- @private
function PresenceTracker:_updateRoomOccupancy(roomId, mac, present)
  if not self._roomOccupancy[roomId] then
    self._roomOccupancy[roomId] = {}
  end

  local wasPreviouslyOccupied = next(self._roomOccupancy[roomId]) ~= nil

  if present then
    self._roomOccupancy[roomId][mac] = true
  else
    self._roomOccupancy[roomId][mac] = nil
  end

  local isNowOccupied = next(self._roomOccupancy[roomId]) ~= nil
  local occupantCount = 0
  local occupantNames = {}

  for occupantMac in pairs(self._roomOccupancy[roomId]) do
    occupantCount = occupantCount + 1
    local config = self._presenceDevices[occupantMac]
    if config then
      table.insert(occupantNames, config.name)
    end
  end

  -- Find room name
  --- @type string?
  local roomName = nil
  for _, p in ipairs(proxyRegistry:getConnectedProxies()) do
    if p.roomId == roomId then
      roomName = p.roomName
      break
    end
  end

  if roomName then
    -- Update room variables using unique room name
    local uniqueRoomName = makeUniqueRoomName(roomName, roomId)
    values:update(uniqueRoomName .. " Occupied", isNowOccupied and "true" or "false", "STRING")
    values:update(uniqueRoomName .. " Occupant Count", tostring(occupantCount), "NUMBER")
    values:update(uniqueRoomName .. " Occupants", table.concat(occupantNames, ", "), "STRING")
  end

  -- Update room binding
  local bindingId = self._roomBindings[roomId]
  if bindingId then
    if isNowOccupied then
      SendToProxy(bindingId, "CLOSED", {}, "NOTIFY") -- Occupied
    else
      SendToProxy(bindingId, "OPENED", {}, "NOTIFY") -- Empty
    end
  end

  -- Fire room events on transition
  if not wasPreviouslyOccupied and isNowOccupied then
    events:fire(NAMESPACE, "room_" .. tostring(roomId) .. "_occupied")
  elseif wasPreviouslyOccupied and not isNowOccupied then
    events:fire(NAMESPACE, "room_" .. tostring(roomId) .. "_empty")
  end
end

--- Get all tracked presence devices
--- @return table<string, PresenceDeviceConfig?>
function PresenceTracker:getPresenceDevices()
  return self._presenceDevices
end

--- Handle proxy room update (when proxy's room assignment changes)
--- Recalculates presence for all tracked devices since room mappings may have changed
--- @param proxyDeviceId integer The proxy device ID that was updated
function PresenceTracker:onProxyUpdated(proxyDeviceId)
  log:trace("PresenceTracker:onProxyUpdated(%s)", proxyDeviceId)

  -- Clear pending transitions that might be based on stale room info
  for mac, state in pairs(self._deviceState) do
    if state.pendingTransition then
      log:debug("Clearing pending transition for %s due to proxy room change", mac)
      state.pendingTransition = nil
    end
  end

  -- Recalculate presence for all tracked devices
  -- The next advertisement will use the updated room info, but we can
  -- proactively recalculate now using cached RSSI data
  for mac, config in pairs(self._presenceDevices) do
    -- Re-determine which room the device is in using current RSSI data
    local candidateRoom, candidateRoomId, bestRssi, _ = self:_determineRoom(mac)

    if candidateRoomId and candidateRoom then
      self:_ensureRoomSetup(candidateRoomId, candidateRoom)
    end

    -- Process room transition (this will handle state changes and events)
    local state = self._deviceState[mac]
    if state and state.roomId then
      local finalRoom, _ = self:_processRoomCandidate(mac, candidateRoom, candidateRoomId, bestRssi or -999)

      -- Update the room variable
      local uniqueName = makeUniqueName(config.name, mac)
      values:update("Presence " .. uniqueName .. " Room", finalRoom or "Away", "STRING")
    end
  end
end

--- Clear RSSI state for a specific proxy (when proxy disconnects)
--- @param proxyDeviceId integer The proxy device ID
function PresenceTracker:clearProxyRSSI(proxyDeviceId)
  local suffix = "_" .. tostring(proxyDeviceId)
  local cleared = 0

  for key in pairs(self._rssiState) do
    if key:sub(-#suffix) == suffix then
      self._rssiState[key] = nil
      cleared = cleared + 1
    end
  end

  if cleared > 0 then
    log:debug("Cleared presence RSSI state for proxy device %d (%d entries)", proxyDeviceId, cleared)
  end

  -- Reset pending transitions that might rely on the disconnected proxy
  for _mac, state in pairs(self._deviceState) do
    if state.pendingTransition then
      -- If the pending transition was based on the disconnected proxy's room,
      -- we should re-evaluate. For safety, just clear the pending transition.
      state.pendingTransition = nil
    end
  end
end

--- Create generic presence events
--- @diagnostic disable-next-line: unused
function PresenceTracker:createGenericEvents()
  events:getOrAddEvent(
    NAMESPACE,
    "any_device_entered_room",
    "Any Device Entered Room",
    "Fired when any device enters a room. Read 'Last Presence' variables for details."
  )

  events:getOrAddEvent(
    NAMESPACE,
    "any_device_left_room",
    "Any Device Left Room",
    "Fired when any device leaves a room. Read 'Last Presence' variables for details."
  )

  -- Create last event context variables
  values:update("Last Presence Device MAC", "", "STRING")
  values:update("Last Presence Device Name", "", "STRING")
  values:update("Last Presence Room", "", "STRING")
  values:update("Last Presence Previous Room", "", "STRING")
  values:update("Last Presence Distance", "0", "NUMBER")
end

return PresenceTracker:new()
