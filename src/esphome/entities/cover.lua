local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto-schema")

--- @class CoverEntity:Entity
local CoverEntity = {
  TYPE = ESPHomeClient.EntityType.COVER,
}

--- Create a new instance of the cover entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return CoverEntity entity A new instance of the CoverEntity entity.
function CoverEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties CoverEntity
  return properties
end

--- Handle the discovery of a cover entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function CoverEntity:discovered(entity)
  log:trace("CoverEntity:discovered(%s)", entity)
  local supportsStop = toboolean(entity.supports_stop)
  local supportsPosition = toboolean(entity.supports_position)

  -- Contacts
  assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "cover_closed_" .. entity.key,
      "PROXY",
      true,
      entity.name .. " Closed",
      "CONTACT_SENSOR"
    )
  )
  assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "cover_open_" .. entity.key,
      "PROXY",
      true,
      entity.name .. " Open",
      "CONTACT_SENSOR"
    )
  )

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
        log:warn("Unknown binding id %s for %s.%s", idBinding, entity.entity_type, entity.object_id)
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
        log:warn("Unknown binding id %s for %s.%s", idBinding, entity.entity_type, entity.object_id)
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
          log:debug("Command %s sent to %s.%s", coverCommand, entity.entity_type, entity.object_id)
        end, function(error)
          log:error(
            "An error occurred sending command %s to %s.%s; %s",
            coverCommand,
            entity.entity_type,
            entity.object_id,
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

  -- Update the cover state contacts
  local coverOpenBinding = bindings:getDynamicBinding(self.TYPE, "cover_open_" .. entity.key)
  if coverOpenBinding ~= nil then
    SendToProxy(coverOpenBinding.bindingId, coverOpen and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
  local coverClosedBinding = bindings:getDynamicBinding(self.TYPE, "cover_closed_" .. entity.key)
  if coverClosedBinding ~= nil then
    SendToProxy(coverClosedBinding.bindingId, coverClosed and "CLOSED" or "OPENED", {}, "NOTIFY")
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
