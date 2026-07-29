local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- Last contact state notified per binding this session. In-memory on
--- purpose: a driver restart clears it, so bound consumers are re-notified
--- even when the state matches the persisted variable.
--- @type table<string, string>
local lastNotified = {}

--- @class CoverEntity:Entity
local CoverEntity = {
  TYPE = ESPHomeClient.EntityType.COVER,
}
CoverEntity.__index = CoverEntity

--- Send the last known contact state to a consumer that just bound, so it does
--- not sit unknown until the cover next moves. Bypasses the session memo (the
--- state may already have been notified to an earlier consumer) and refreshes
--- it, since every consumer on the binding receives this send.
--- @param bindingId integer The binding to send on.
--- @param memoKey string The `lastNotified` key backing this contact.
--- @param valueName string The value holding the cached contact state.
--- @return void
local function sendCachedContactState(bindingId, memoKey, valueName)
  local cached = values:getValue(valueName)
  if cached == nil or cached.value == nil then
    return
  end
  lastNotified[memoKey] = cached.value
  SendToProxy(bindingId, cached.value, {}, "NOTIFY")
end

--- Create a new instance of the cover entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return CoverEntity entity A new instance of the CoverEntity entity.
function CoverEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a cover entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function CoverEntity:discovered(entity)
  log:trace("CoverEntity:discovered(%s)", entity)
  local supportsStop = toboolean(entity.supports_stop)
  local supportsPosition = toboolean(entity.supports_position)

  -- Contacts
  local coverClosedBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "cover_closed_" .. entity.key,
      "PROXY",
      true,
      entity.name .. " Closed",
      "CONTACT_SENSOR"
    )
  ).bindingId
  local coverOpenBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "cover_open_" .. entity.key,
      "PROXY",
      true,
      entity.name .. " Open",
      "CONTACT_SENSOR"
    )
  ).bindingId

  OBC[coverClosedBindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s)", coverClosedBindingId, idBinding, bIsBound)
    if bIsBound then
      sendCachedContactState(idBinding, "closed_" .. entity.key, entity.name .. " Closed")
    end
  end
  OBC[coverOpenBindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s)", coverOpenBindingId, idBinding, bIsBound)
    if bIsBound then
      sendCachedContactState(idBinding, "open_" .. entity.key, entity.name .. " Open")
    end
  end

  -- Relays
  local openCoverBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "open_cover_" .. entity.key,
      "PROXY",
      true,
      "Open " .. entity.name,
      "RELAY"
    )
  ).bindingId
  local closeCoverBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "close_cover_" .. entity.key,
      "PROXY",
      true,
      "Close " .. entity.name,
      "RELAY"
    )
  ).bindingId
  local stopCoverBindingId
  if supportsStop then
    stopCoverBindingId = assert(
      bindings:getOrAddDynamicBinding(
        self.TYPE,
        "stop_cover_" .. entity.key,
        "PROXY",
        true,
        "Stop " .. entity.name,
        "RELAY"
      )
    ).bindingId
  end

  local commandRfp = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    local legacyCommand = nil
    local positionCommand = nil
    local stopCommand = nil
    local coverCommand = nil
    if supportsPosition then
      if idBinding == openCoverBindingId then
        positionCommand = 1.0
        coverCommand = "open"
      elseif idBinding == closeCoverBindingId then
        positionCommand = 0.0
        coverCommand = "close"
      elseif idBinding == stopCoverBindingId then
        stopCommand = true
        coverCommand = "stop"
      else
        log:warn("Unknown binding id %s for %s", idBinding, ESPHomeClient.describeEntity(entity))
        return
      end
    else
      if idBinding == openCoverBindingId then
        legacyCommand = ESPHomeProtoSchema.Enum.LegacyCoverCommand.LEGACY_COVER_COMMAND_OPEN
        coverCommand = "open"
      elseif idBinding == closeCoverBindingId then
        legacyCommand = ESPHomeProtoSchema.Enum.LegacyCoverCommand.LEGACY_COVER_COMMAND_CLOSE
        coverCommand = "close"
      elseif idBinding == stopCoverBindingId then
        legacyCommand = ESPHomeProtoSchema.Enum.LegacyCoverCommand.LEGACY_COVER_COMMAND_STOP
        coverCommand = "stop"
      else
        log:warn("Unknown binding id %s for %s", idBinding, ESPHomeClient.describeEntity(entity))
        return
      end
    end

    -- We only trigger when the relays are turned on
    if strCommand == "ON" or strCommand == "CLOSE" or strCommand == "TOGGLE" or strCommand == "TRIGGER" then
      self.client
        :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.cover_command, {
          key = entity.key,
          has_legacy_command = legacyCommand ~= nil,
          legacy_command = legacyCommand,
          has_position = positionCommand ~= nil,
          position = positionCommand,
          has_tilt = false,
          stop = stopCommand,
        })
        :next(function()
          log:debug("Command %s sent to %s", coverCommand, ESPHomeClient.describeEntity(entity))
        end, function(error)
          log:error(
            "An error occurred sending command %s to %s; %s",
            coverCommand,
            ESPHomeClient.describeEntity(entity),
            error
          )
        end)
    end
  end

  RFP[openCoverBindingId] = commandRfp
  OBC[openCoverBindingId] = RefreshStatus
  RFP[closeCoverBindingId] = commandRfp
  OBC[closeCoverBindingId] = RefreshStatus
  if stopCoverBindingId ~= nil then
    RFP[stopCoverBindingId] = commandRfp
    OBC[stopCoverBindingId] = RefreshStatus
  end
end

--- Handle updates to the cover entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function CoverEntity:updated(entity, state)
  log:trace("CoverEntity:updated(%s, %s)", entity, state)
  local stateString = "unknown"
  local coverOpen = true -- When both open and closed, relay controller drivers will report "unknown"
  local coverClosed = true
  local coverOperation = tointeger(state.current_operation) or 0
  local supportsPosition = toboolean(entity.supports_position)
  local position = tointeger((tonumber(state.position) or 0) * 100)
  local legacyState = tointeger(state.legacy_state)

  if supportsPosition then
    if coverOperation == nil or coverOperation == ESPHomeProtoSchema.Enum.CoverOperation.COVER_OPERATION_IDLE then
      if position == 0 then
        stateString = "closed"
        coverOpen = false
        coverClosed = true
      else
        stateString = "open"
        coverOpen = true
        coverClosed = false
      end
    elseif coverOperation == ESPHomeProtoSchema.Enum.CoverOperation.COVER_OPERATION_IS_OPENING then
      stateString = "opening"
      coverOpen = false
      coverClosed = false
    elseif coverOperation == ESPHomeProtoSchema.Enum.CoverOperation.COVER_OPERATION_IS_CLOSING then
      stateString = "closing"
      coverOpen = false
      coverClosed = false
    end
  else
    if legacyState == ESPHomeProtoSchema.Enum.LegacyCoverState.LEGACY_COVER_STATE_OPEN then
      stateString = "open"
      coverOpen = true
      coverClosed = false
    elseif legacyState == ESPHomeProtoSchema.Enum.LegacyCoverState.LEGACY_COVER_STATE_CLOSED then
      stateString = "closed"
      coverOpen = false
      coverClosed = true
    end
  end

  values:update(entity.name .. " State", stateString, "STRING")

  -- Update the cover state contacts (only notify when state changes)
  local coverOpenBinding = bindings:getDynamicBinding(self.TYPE, "cover_open_" .. entity.key)
  if coverOpenBinding ~= nil then
    local coverOpenState = coverOpen and "CLOSED" or "OPENED"
    values:update(entity.name .. " Open", coverOpenState)
    if lastNotified["open_" .. entity.key] ~= coverOpenState then
      lastNotified["open_" .. entity.key] = coverOpenState
      SendToProxy(coverOpenBinding.bindingId, coverOpenState, {}, "NOTIFY")
    end
  end
  local coverClosedBinding = bindings:getDynamicBinding(self.TYPE, "cover_closed_" .. entity.key)
  if coverClosedBinding ~= nil then
    local coverClosedState = coverClosed and "CLOSED" or "OPENED"
    values:update(entity.name .. " Closed", coverClosedState)
    if lastNotified["closed_" .. entity.key] ~= coverClosedState then
      lastNotified["closed_" .. entity.key] = coverClosedState
      SendToProxy(coverClosedBinding.bindingId, coverClosedState, {}, "NOTIFY")
    end
  end

  -- Always open the relays since its just used to trigger the cover
  local openCoverBinding = bindings:getDynamicBinding(self.TYPE, "open_cover_" .. entity.key)
  if openCoverBinding ~= nil then
    SendToProxy(openCoverBinding.bindingId, "OPENED", {}, "NOTIFY")
  end
  local closeCoverBinding = bindings:getDynamicBinding(self.TYPE, "close_cover_" .. entity.key)
  if closeCoverBinding ~= nil then
    SendToProxy(closeCoverBinding.bindingId, "OPENED", {}, "NOTIFY")
  end
  local stopCoverBinding = bindings:getDynamicBinding(self.TYPE, "stop_cover_" .. entity.key)
  if stopCoverBinding ~= nil then
    SendToProxy(stopCoverBinding.bindingId, "OPENED", {}, "NOTIFY")
  end
end

return CoverEntity
