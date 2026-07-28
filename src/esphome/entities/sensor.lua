local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")

--- @class SensorBindingConfig
--- @field bindingClass string The C4 binding class for the sensor (e.g., "TEMPERATURE_VALUE")
--- @field scale string The default scale reported alongside the value (e.g., "CELSIUS")

--- Sensor binding configurations.
--- Maps ESPHome device classes to C4 binding classes. Sensors whose device
--- class is not listed here stay variable-only, as they have always been.
--- @type table<string, SensorBindingConfig?>
local SENSOR_BINDINGS = {
  temperature = {
    bindingClass = "TEMPERATURE_VALUE",
    scale = "CELSIUS",
  },
  humidity = {
    bindingClass = "HUMIDITY_VALUE",
    scale = "PERCENT",
  },
}

--- Temperature units mapped to C4 scales, keyed by normalized unit
--- (lowercased, whitespace and degree signs stripped).
--- @type table<string, string>
local TEMPERATURE_SCALES = {
  c = "CELSIUS",
  f = "FAHRENHEIT",
  k = "KELVIN",
}

--- Resolve the scale to report for an entity, honoring its declared unit: an
--- ESPHome sensor converted to Fahrenheit in its config reports Fahrenheit
--- values with unit_of_measurement riding along.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param config SensorBindingConfig The binding configuration.
--- @return string scale The scale to report alongside the value.
local function getScale(entity, config)
  if config.bindingClass ~= "TEMPERATURE_VALUE" then
    return config.scale
  end
  local unit = (entity.unit_of_measurement or ""):gsub("°", ""):gsub("%s", ""):lower()
  return TEMPERATURE_SCALES[unit] or config.scale
end

--- @class SensorEntity:Entity
local SensorEntity = {
  TYPE = ESPHomeClient.EntityType.SENSOR,
}
SensorEntity.__index = SensorEntity

--- Create a new instance of the sensor entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return SensorEntity entity A new instance of the SensorEntity entity.
function SensorEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Last value pushed per binding this session. In-memory on purpose: a
--- driver restart clears it, so bound consumers are re-notified even when the
--- first reading matches the persisted variable.
--- @type table<string, number>
local lastPushed = {}

--- Build the dynamic binding key for a sensor entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return string key The dynamic binding key.
local function getBindingKey(entity)
  return "sensor_" .. entity.key
end

--- Look up the binding configuration for a sensor entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return SensorBindingConfig|nil config The configuration, or nil when unmapped.
local function getBindingConfig(entity)
  return SENSOR_BINDINGS[entity.device_class or ""]
end

--- Send the last known value to a bound consumer.
--- @param bindingId integer The binding to send on.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param config SensorBindingConfig The binding configuration.
--- @return void
local function sendCachedValue(bindingId, entity, config)
  local cached = values:getValue(entity.name)
  if cached == nil or cached.value == nil then
    return
  end
  SendToProxy(bindingId, "VALUE_CHANGED", {
    VALUE = cached.value,
    SCALE = getScale(entity, config),
  })
end

--- Handle the discovery of a sensor entity.
--- Sensors reporting a mapped device class get a provider binding so they can
--- be connected to thermostats and other consumers of that value class.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function SensorEntity:discovered(entity)
  log:trace("SensorEntity:discovered(%s)", entity)
  local config = getBindingConfig(entity)
  if config == nil then
    return
  end

  local binding = bindings:getOrAddDynamicBinding(
    self.TYPE,
    getBindingKey(entity),
    "CONTROL",
    true, -- provider
    entity.name,
    config.bindingClass
  )
  if binding == nil then
    log:error("Failed to create %s binding for %s", config.bindingClass, ESPHomeClient.describeEntity(entity))
    return
  end
  log:info(
    "Created %s binding for %s (id=%s)",
    config.bindingClass,
    ESPHomeClient.describeEntity(entity),
    binding.bindingId
  )

  -- Answer value requests from consumers.
  RFP[binding.bindingId] = function(idBinding, strCommand, _tParams, _args)
    log:trace("RFP[%s](%s, %s)", binding.bindingId, idBinding, strCommand)
    if strCommand == "GET_VALUE" then
      sendCachedValue(idBinding, entity, config)
    end
  end

  -- Seed the consumer with the current value as soon as it binds.
  OBC[binding.bindingId] = function(idBinding, _strClass, bIsBound, _otherDeviceId, _otherBindingId)
    log:trace("OBC[%s](%s, %s)", binding.bindingId, idBinding, bIsBound)
    if bIsBound then
      sendCachedValue(idBinding, entity, config)
    end
  end
end

--- Handle updates to the sensor entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function SensorEntity:updated(entity, state)
  log:trace("SensorEntity:updated(%s, %s)", entity, state)
  local value = round(tonumber(state.state) or 0, 1)
  values:update(entity.name, value, "NUMBER")

  local config = getBindingConfig(entity)
  if config == nil then
    return
  end

  local bindingKey = getBindingKey(entity)
  if lastPushed[bindingKey] == value then
    return
  end

  local binding = bindings:getDynamicBinding(self.TYPE, bindingKey)
  if binding ~= nil then
    lastPushed[bindingKey] = value
    SendToProxy(binding.bindingId, "VALUE_CHANGED", {
      VALUE = value,
      SCALE = getScale(entity, config),
    })
  end
end

return SensorEntity
