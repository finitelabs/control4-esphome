local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- WaterHeaterMode enum to standard ESPHome preset name
local WATER_HEATER_MODE_NAMES = {
  [ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_OFF] = "Off",
  [ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_ECO] = "Eco Mode",
  [ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_ELECTRIC] = "Electric",
  [ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_PERFORMANCE] = "Performance",
  [ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_HIGH_DEMAND] = "High Demand",
  [ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_HEAT_PUMP] = "Heat Pump",
  [ESPHomeProtoSchema.Enum.WaterHeaterMode.WATER_HEATER_MODE_GAS] = "Gas",
}

--- @class WaterHeaterEntity:Entity
local WaterHeaterEntity = {
  TYPE = ESPHomeClient.EntityType.WATER_HEATER,
}
WaterHeaterEntity.__index = WaterHeaterEntity

--- @param client ESPHomeClient
--- @return WaterHeaterEntity
function WaterHeaterEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a water heater entity.
--- @param entity table<string, any> The entity data from ListEntitiesWaterHeaterResponse.
function WaterHeaterEntity:discovered(entity)
  log:trace("WaterHeaterEntity:discovered(%s)", entity)
  entity.is_water_heater = true
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "water_heater_" .. entity.ref,
      "PROXY",
      true,
      entity.name,
      "ESPHOME_CLIMATE"
    )
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "REFRESH_STATE" then
      RefreshStatus()
    elseif strCommand == "SET_REMOTE_TEMPERATURE" then
      local serviceName = Select(tParams, "service_name")
      local temperature = tonumber(Select(tParams, "temperature"))
      if not IsEmpty(serviceName) then
        self.client:executeServiceByName(serviceName, temperature):next(function()
          log:debug("Remote temperature service '%s' called (temp=%s)", serviceName, temperature)
        end, function(err)
          log:error("Failed to call remote temperature service '%s': %s", serviceName, err)
        end)
      end
    elseif strCommand == "ENTITY_COMMAND" then
      local command = ESPHomeProtoSchema.RPC.APIConnection[Select(tParams, "command")]
        or ESPHomeProtoSchema.RPC.APIConnection.water_heater_command
      local body = DeserializeSafe(Select(tParams, "body")) or {}
      body.key = body.key or entity.key
      self.client:callServiceMethod(command, body):next(function()
        log:debug(
          "Method %s.%s(%s) called by entity %s",
          command.service,
          command.method,
          body,
          ESPHomeClient.describeEntity(entity)
        )
      end, function(error)
        log:error(
          "An error occurred calling method %s.%s(%s) by entity %s; %s",
          command.service,
          command.method,
          body,
          ESPHomeClient.describeEntity(entity),
          error
        )
      end)
    end
  end
  OBC[bindingId] = RefreshStatus

  -- Send discovered user-defined services to the child driver
  local serviceNames = {}
  for name, _ in pairs(self.client.userServices) do
    table.insert(serviceNames, name)
  end
  table.sort(serviceNames)
  if #serviceNames > 0 then
    log:debug(
      "Sending %d user services to water heater driver (binding %s): %s",
      #serviceNames,
      bindingId,
      serviceNames
    )
    SendToProxy(bindingId, "UPDATE_USER_SERVICES", {
      service_names = SerializeSafe(serviceNames),
    }, "NOTIFY")
  end
end

--- Handle updates to the water heater entity state.
--- Translates WaterHeaterMode to ClimateMode + custom_preset so the
--- thermostatV2 sub-driver can process it without water-heater-specific logic.
--- @param entity table<string, any> The entity data.
--- @param state table<string, any> The state data from WaterHeaterStateResponse.
function WaterHeaterEntity:updated(entity, state)
  log:trace("WaterHeaterEntity:updated(%s, %s)", entity, state)
  -- Translate WaterHeaterMode to ClimateMode + custom_preset
  local WaterHeaterMode = ESPHomeProtoSchema.Enum.WaterHeaterMode
  local ClimateMode = ESPHomeProtoSchema.Enum.ClimateMode
  -- Protobuf does not encode zero values, so mode=0 (OFF) arrives as nil
  local whMode = state.mode or WaterHeaterMode.WATER_HEATER_MODE_OFF
  if whMode == WaterHeaterMode.WATER_HEATER_MODE_OFF then
    state.mode = ClimateMode.CLIMATE_MODE_OFF
  else
    state.mode = ClimateMode.CLIMATE_MODE_HEAT
  end
  state.custom_preset = WATER_HEATER_MODE_NAMES[whMode]
  -- Clean up unset protobuf float sentinel values
  local target = tofinite(state.target_temperature)
  if target == nil or target > 1e10 then
    state.target_temperature = nil
  end
  local targetHigh = tofinite(state.target_temperature_high)
  if targetHigh == nil or targetHigh > 1e10 then
    state.target_temperature_high = nil
  end
  local targetLow = tofinite(state.target_temperature_low)
  if targetLow == nil or targetLow > 1e10 then
    state.target_temperature_low = nil
  end
  local binding = bindings:getDynamicBinding(self.TYPE, "water_heater_" .. entity.ref)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = SerializeSafe(entity),
      state = SerializeSafe(state),
    }, "NOTIFY")
  end
end

--- Notify sub-drivers that the ESPHome device has disconnected.
--- Water heaters share the ESPHome Climate sub-driver but bind under their own
--- entity type, so ClimateEntity:disconnected() does not reach them.
--- @return void
function WaterHeaterEntity:disconnected()
  log:trace("WaterHeaterEntity:disconnected()")
  for _, binding in pairs(bindings:getDynamicBindings(self.TYPE)) do
    SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
  end
end

return WaterHeaterEntity
