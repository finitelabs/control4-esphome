local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class ValveEntity:Entity
local ValveEntity = {
  TYPE = ESPHomeClient.EntityType.VALVE,
}
ValveEntity.__index = ValveEntity

--- Create a new instance of the valve entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return ValveEntity entity A new instance of the ValveEntity entity.
function ValveEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a valve entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function ValveEntity:discovered(entity)
  log:trace("ValveEntity:discovered(%s)", entity)
  local supportsStop = toboolean(entity.supports_stop)
  local supportsPosition = toboolean(entity.supports_position)

  -- Contacts
  assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "valve_closed_" .. entity.key,
      "PROXY",
      true,
      entity.name .. " Closed",
      "CONTACT_SENSOR"
    )
  )
  assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "valve_open_" .. entity.key,
      "PROXY",
      true,
      entity.name .. " Open",
      "CONTACT_SENSOR"
    )
  )

  -- Relays
  local openValveBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "open_valve_" .. entity.key,
      "PROXY",
      true,
      "Open " .. entity.name,
      "RELAY"
    )
  ).bindingId
  local closeValveBindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "close_valve_" .. entity.key,
      "PROXY",
      true,
      "Close " .. entity.name,
      "RELAY"
    )
  ).bindingId
  local stopValveBindingId
  if supportsStop then
    stopValveBindingId = assert(
      bindings:getOrAddDynamicBinding(
        self.TYPE,
        "stop_valve_" .. entity.key,
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
    local valveCommand = nil
    if supportsPosition then
      if idBinding == openValveBindingId then
        positionCommand = 1.0
        valveCommand = "open"
      elseif idBinding == closeValveBindingId then
        positionCommand = 0.0
        valveCommand = "close"
      elseif idBinding == stopValveBindingId then
        stopCommand = true
        valveCommand = "stop"
      else
        log:warn("Unknown binding id %s for %s", idBinding, ESPHomeClient.describeEntity(entity))
        return
      end
    else
      -- Without position support, use position 1.0/0.0 as simple open/close
      if idBinding == openValveBindingId then
        positionCommand = 1.0
        valveCommand = "open"
      elseif idBinding == closeValveBindingId then
        positionCommand = 0.0
        valveCommand = "close"
      elseif idBinding == stopValveBindingId then
        stopCommand = true
        valveCommand = "stop"
      else
        log:warn("Unknown binding id %s for %s", idBinding, ESPHomeClient.describeEntity(entity))
        return
      end
    end

    -- We only trigger when the relays are turned on
    if strCommand == "ON" or strCommand == "CLOSE" or strCommand == "TOGGLE" or strCommand == "TRIGGER" then
      self.client
        :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.valve_command, {
          key = entity.key,
          has_position = positionCommand ~= nil,
          position = positionCommand,
          stop = stopCommand,
        })
        :next(function()
          log:debug("Command %s sent to %s", valveCommand, ESPHomeClient.describeEntity(entity))
        end, function(error)
          log:error(
            "An error occurred sending command %s to %s; %s",
            valveCommand,
            ESPHomeClient.describeEntity(entity),
            error
          )
        end)
    end
  end

  RFP[openValveBindingId] = commandRfp
  OBC[openValveBindingId] = RefreshStatus
  RFP[closeValveBindingId] = commandRfp
  OBC[closeValveBindingId] = RefreshStatus
  if stopValveBindingId ~= nil then
    RFP[stopValveBindingId] = commandRfp
    OBC[stopValveBindingId] = RefreshStatus
  end
end

--- Handle updates to the valve entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function ValveEntity:updated(entity, state)
  log:trace("ValveEntity:updated(%s, %s)", entity, state)
  local stateString = "unknown"
  local valveOpen = true -- When both open and closed, relay controller drivers will report "unknown"
  local valveClosed = true
  local valveOperation = tointeger(state.current_operation) or 0
  local position = tointeger((tonumber(state.position) or 0) * 100)

  if valveOperation == nil or valveOperation == ESPHomeProtoSchema.Enum.ValveOperation.VALVE_OPERATION_IDLE then
    if position == 0 then
      stateString = "closed"
      valveOpen = false
      valveClosed = true
    else
      stateString = "open"
      valveOpen = true
      valveClosed = false
    end
  elseif valveOperation == ESPHomeProtoSchema.Enum.ValveOperation.VALVE_OPERATION_IS_OPENING then
    stateString = "opening"
    valveOpen = false
    valveClosed = false
  elseif valveOperation == ESPHomeProtoSchema.Enum.ValveOperation.VALVE_OPERATION_IS_CLOSING then
    stateString = "closing"
    valveOpen = false
    valveClosed = false
  end

  values:update(entity.name .. " State", stateString, "STRING")

  -- Update the valve state contacts (only notify when state changes)
  local valveOpenBinding = bindings:getDynamicBinding(self.TYPE, "valve_open_" .. entity.key)
  if valveOpenBinding ~= nil then
    local valveOpenState = valveOpen and "CLOSED" or "OPENED"
    if values:update(entity.name .. " Open", valveOpenState) then
      SendToProxy(valveOpenBinding.bindingId, valveOpenState, {}, "NOTIFY")
    end
  end
  local valveClosedBinding = bindings:getDynamicBinding(self.TYPE, "valve_closed_" .. entity.key)
  if valveClosedBinding ~= nil then
    local valveClosedState = valveClosed and "CLOSED" or "OPENED"
    if values:update(entity.name .. " Closed", valveClosedState) then
      SendToProxy(valveClosedBinding.bindingId, valveClosedState, {}, "NOTIFY")
    end
  end

  -- Always open the relays since they're just used to trigger the valve
  local openValveBinding = bindings:getDynamicBinding(self.TYPE, "open_valve_" .. entity.key)
  if openValveBinding ~= nil then
    SendToProxy(openValveBinding.bindingId, "OPENED", {}, "NOTIFY")
  end
  local closeValveBinding = bindings:getDynamicBinding(self.TYPE, "close_valve_" .. entity.key)
  if closeValveBinding ~= nil then
    SendToProxy(closeValveBinding.bindingId, "OPENED", {}, "NOTIFY")
  end
  local stopValveBinding = bindings:getDynamicBinding(self.TYPE, "stop_valve_" .. entity.key)
  if stopValveBinding ~= nil then
    SendToProxy(stopValveBinding.bindingId, "OPENED", {}, "NOTIFY")
  end
end

return ValveEntity
