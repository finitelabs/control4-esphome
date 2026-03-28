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
  local displayName = entity.name
  if IsEmpty(displayName) then
    if not IsEmpty(entity.object_id) then
      displayName = entity.object_id:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
      end)
    else
      displayName = "Water Heater " .. entity.key
    end
  end
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(
      self.TYPE,
      "water_heater_" .. entity.key,
      "PROXY",
      true,
      displayName,
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
          "Method %s.%s(%s) called by entity %s.%s",
          command.service,
          command.method,
          body,
          entity.entity_type,
          entity.object_id
        )
      end, function(error)
        log:error(
          "An error occurred calling method %s.%s(%s) by entity %s.%s; %s",
          command.service,
          command.method,
          body,
          entity.entity_type,
          entity.object_id,
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
--- @param messageSchema table<string, any>|nil The proto message schema (used to filter stale ClimateStateResponse in dual-platform case).
function WaterHeaterEntity:updated(entity, state, messageSchema)
  log:trace("WaterHeaterEntity:updated(%s, %s)", entity, state)
  -- Dual-platform case: third-party ESPHome components may register both climate
  -- and water_heater platforms for the same entity key. If the water_heater entity
  -- overwrites the climate entity during discovery (same key), ClimateStateResponse
  -- will route here with stale data. Ignore it.
  if messageSchema and messageSchema.name ~= "WaterHeaterStateResponse" then
    log:debug("Ignoring %s for water heater entity %s", messageSchema.name, entity.object_id)
    return
  end
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
  if state.target_temperature and state.target_temperature > 1e10 then
    state.target_temperature = nil
  end
  if state.target_temperature_high and state.target_temperature_high > 1e10 then
    state.target_temperature_high = nil
  end
  if state.target_temperature_low and state.target_temperature_low > 1e10 then
    state.target_temperature_low = nil
  end
  local binding = bindings:getDynamicBinding(self.TYPE, "water_heater_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = SerializeSafe(entity),
      state = SerializeSafe(state),
    }, "NOTIFY")
  end
end

return WaterHeaterEntity
