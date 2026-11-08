local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local entityValues = require("esphome.entity_values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local StateTell = require("esphome.state_tell")

local told = StateTell:new("CoverContactStates")

--- Trigger relays told they read open this load, by binding ID.
--- @type table<number, boolean>
local triggersTold = {}

--- @class CoverEntity:Entity
local CoverEntity = {
  TYPE = ESPHomeClient.EntityType.COVER,
}
CoverEntity.__index = CoverEntity

--- Forget the contact states told (driver reset).
function CoverEntity.clearNotifiedState()
  told:reset()
  triggersTold = {}
end

--- Register a bind-time seeder that tells a newly bound consumer the last known
--- contact state, silently.
--- @param bindingId number The contact binding ID.
--- @param valueName string The values key holding the contact state.
local function registerContactSeeder(bindingId, valueName)
  OBC[bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s)", bindingId, idBinding, bIsBound)
    if not bIsBound then
      return
    end
    local state = Select(values:getValue(valueName), "value")
    if not IsEmpty(state) then
      SendToProxy(bindingId, "STATE_" .. state, {}, "NOTIFY")
    end
  end
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

  -- Contacts
  local coverClosedContactId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "cover_closed_" .. entity.ref,
      "PROXY",
      true,
      entity.name .. " Closed",
      "CONTACT_SENSOR"
    )
  ).bindingId
  local coverOpenContactId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "cover_open_" .. entity.ref,
      "PROXY",
      true,
      entity.name .. " Open",
      "CONTACT_SENSOR"
    )
  ).bindingId
  registerContactSeeder(coverClosedContactId, entity.name .. " Closed")
  registerContactSeeder(coverOpenContactId, entity.name .. " Open")

  -- Relays
  local openCoverBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "open_cover_" .. entity.ref,
      "PROXY",
      true,
      "Open " .. entity.name,
      "RELAY"
    )
  ).bindingId
  local closeCoverBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "close_cover_" .. entity.ref,
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
        "stop_cover_" .. entity.ref,
        "PROXY",
        true,
        "Stop " .. entity.name,
        "RELAY"
      )
    ).bindingId
  end

  local commandRfp = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    local positionCommand = nil
    local stopCommand = nil
    local coverCommand = nil
    -- ESPHome takes open and close as positions 1 and 0 on every cover, with or without position support.
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

    -- We only trigger when the relays are turned on
    if strCommand == "ON" or strCommand == "CLOSE" or strCommand == "TOGGLE" or strCommand == "TRIGGER" then
      self.client
        :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.cover_command, {
          key = entity.key,
          device_id = entity.device_id,
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

  -- The relays only trigger the cover, so they always read open. Told once at bind, silently.
  local triggerObc = function(idBinding, _strClass, bIsBound)
    if bIsBound then
      triggersTold[idBinding] = true
      SendToProxy(idBinding, "STATE_OPENED", {}, "NOTIFY")
    end
    RefreshStatus()
  end
  RFP[openCoverBindingId] = commandRfp
  OBC[openCoverBindingId] = triggerObc
  RFP[closeCoverBindingId] = commandRfp
  OBC[closeCoverBindingId] = triggerObc
  if stopCoverBindingId ~= nil then
    RFP[stopCoverBindingId] = commandRfp
    OBC[stopCoverBindingId] = triggerObc
  end

  -- At a controller start Director binds before the cover is discovered, so a relay bound then is told here, once
  for _, triggerId in ipairs({ openCoverBindingId, closeCoverBindingId, stopCoverBindingId }) do
    if not triggersTold[triggerId] and not IsEmpty(C4:GetBoundConsumerDevices(C4:GetDeviceID(), triggerId)) then
      triggersTold[triggerId] = true
      SendToProxy(triggerId, "STATE_OPENED", {}, "NOTIFY")
    end
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
  -- ESPHome sends every cover's state as a position, 0 or 1 for one without position support, and NaN for a
  -- position the device has not reported.
  local position = tointeger((tofinite(state.position) or 0) * 100)

  if coverOperation == ESPHomeProtoSchema.Enum.CoverOperation.COVER_OPERATION_IDLE then
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

  entityValues.update(entity.name .. " State", stateString, "STRING")

  local coverOpenBinding = bindings:getDynamicBinding(self.TYPE, "cover_open_" .. entity.ref)
  if coverOpenBinding ~= nil then
    local coverOpenState = coverOpen and "CLOSED" or "OPENED"
    entityValues.update(entity.name .. " Open", coverOpenState)
    told:tell("open_" .. entity.ref, coverOpenBinding.bindingId, coverOpenState)
  end
  local coverClosedBinding = bindings:getDynamicBinding(self.TYPE, "cover_closed_" .. entity.ref)
  if coverClosedBinding ~= nil then
    local coverClosedState = coverClosed and "CLOSED" or "OPENED"
    entityValues.update(entity.name .. " Closed", coverClosedState)
    told:tell("closed_" .. entity.ref, coverClosedBinding.bindingId, coverClosedState)
  end
end

return CoverEntity
