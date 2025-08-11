local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto-schema")

--- @class SwitchEntity:Entity
local SwitchEntity = {
  TYPE = ESPHomeClient.EntityType.SWITCH,
}

--- Create a new instance of the switch entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return SwitchEntity entity A new instance of the SwitchEntity entity.
function SwitchEntity:new(client)
  local properties = {
    client = client,
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties SwitchEntity
  return properties
end

--- Handle the discovery of a switch entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function SwitchEntity:discovered(entity)
  log:trace("SwitchEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "switch_" .. entity.key, "PROXY", true, entity.name, "RELAY")
  ).bindingId

  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    local response
    local state
    local pulseTime = 0
    if strCommand == "ON" or strCommand == "CLOSE" then
      state = true
    elseif strCommand == "OFF" or strCommand == "OPEN" then
      state = false
    elseif strCommand == "TOGGLE" then
      state = not toboolean(Select(values:getValue(entity.name .. " State"), "value"))
    elseif strCommand == "TRIGGER" then
      state = true
      pulseTime = tonumber_locale(tParams.TIME) or 0
    end

    response = self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.switch_command, {
        key = entity.key,
        state = state,
      })
      :next(function()
        log:debug("Command %s sent to %s.%s", state and "on" or "off", entity.entity_type, entity.object_id)
      end, function(error)
        log:error(
          "An error occurred sending command %s to %s.%s; %s",
          state and "on" or "off",
          entity.entity_type,
          entity.object_id,
          error
        )
      end)
    if pulseTime > 0 then
      SetTimer("FinishPulse", pulseTime, function()
        log:debug("Turning off %s.%s after pulse time of %dms", entity.entity_type, entity.object_id, pulseTime)
        self.client
          :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.switch_command, {
            key = entity.key,
            state = false,
          })
          :next(function()
            log:debug("Command off sent to %s.%s", entity.entity_type, entity.object_id)
          end, function(error)
            log:error("An error occurred sending command off to %s.%s; %s", entity.entity_type, entity.object_id, error)
          end)
      end)
    end
  end
  OBC[bindingId] = RefreshStatus
end

--- Handle updates to the switch entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function SwitchEntity:updated(entity, state)
  log:trace("SwitchEntity:updated(%s, %s)", entity, state)

  local value = toboolean(state.state)
  values:update(entity.name .. " State", value and "1" or "0", "BOOL", function(newValue)
    -- Convert the Control4 value (0/1 string) to a boolean for ESPHome
    local boolValue = toboolean(newValue)
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.switch_command, {
        key = entity.key,
        state = boolValue,
      })
      :next(function()
        log:info("Commanded %s.%s to %s", entity.entity_type, entity.object_id, boolValue and "on" or "off")
      end, function(error)
        log:error(
          "Failed to command %s.%s to %s: %s",
          entity.entity_type,
          entity.object_id,
          boolValue and "on" or "off",
          error
        )
      end)
  end)

  -- Update the relay proxy
  local relayBinding = bindings:getDynamicBinding(self.TYPE, "switch_" .. entity.key)
  if relayBinding ~= nil then
    SendToProxy(relayBinding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

return SwitchEntity
