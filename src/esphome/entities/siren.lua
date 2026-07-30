local log = require("lib.logging")
local bindings = require("lib.bindings")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- Registry of discovered siren entities for programming commands.
--- Maps display name to { key = number, tones = string[], client = ESPHomeClient }
--- @type table<string, { key: integer, tones: string[], client: ESPHomeClient }>
local sirenRegistry = {}

--- @class SirenEntity:Entity
local SirenEntity = {
  TYPE = ESPHomeClient.EntityType.SIREN,
}
SirenEntity.__index = SirenEntity

--- Create a new instance of the siren entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return SirenEntity entity A new instance of the SirenEntity entity.
function SirenEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a siren entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function SirenEntity:discovered(entity)
  log:trace("SirenEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "siren_" .. entity.key, "PROXY", true, entity.name, "RELAY")
  ).bindingId

  -- Register siren for tone programming commands if tones are available
  local tones = entity.tones or {}
  if #tones > 0 then
    sirenRegistry[entity.name] = {
      key = entity.key,
      tones = tones,
      client = self.client,
    }
  end

  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    local state
    if strCommand == "ON" or strCommand == "CLOSE" then
      state = true
    elseif strCommand == "OFF" or strCommand == "OPEN" then
      state = false
    elseif strCommand == "TOGGLE" then
      state = not toboolean(Select(values:getValue(entity.name .. " State"), "value"))
    end

    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.siren_command, {
        key = entity.key,
        has_state = true,
        state = state,
      })
      :next(function()
        log:debug("Command %s sent to %s", state and "on" or "off", ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error(
          "An error occurred sending command %s to %s; %s",
          state and "on" or "off",
          ESPHomeClient.describeEntity(entity),
          error
        )
      end)
  end
  OBC[bindingId] = RefreshStatus
end

--- Handle updates to the siren entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function SirenEntity:updated(entity, state)
  log:trace("SirenEntity:updated(%s, %s)", entity, state)

  local value = toboolean(state.state)
  values:update(entity.name .. " State", value and "1" or "0", "BOOL", function(newValue)
    -- Convert the Control4 value (0/1 string) to a boolean for ESPHome
    local boolValue = toboolean(newValue)
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.siren_command, {
        key = entity.key,
        has_state = true,
        state = boolValue,
      })
      :next(function()
        log:info("Commanded %s to %s", ESPHomeClient.describeEntity(entity), boolValue and "on" or "off")
      end, function(error)
        log:error(
          "Failed to command %s to %s: %s",
          ESPHomeClient.describeEntity(entity),
          boolValue and "on" or "off",
          error
        )
      end)
  end)

  -- Volume variable (0-100 in C4, normalized to 0.0-1.0 for ESPHome)
  if entity.supports_volume then
    values:update(entity.name .. " Volume", 0, "NUMBER", function(newValue)
      local numValue = tonumber(newValue) or 0
      -- Clamp to 0-100 and normalize to 0.0-1.0
      numValue = math.max(0, math.min(100, numValue)) / 100
      self.client
        :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.siren_command, {
          key = entity.key,
          has_volume = true,
          volume = numValue,
        })
        :next(function()
          log:info("Siren volume set to %.0f%% for %s", numValue * 100, ESPHomeClient.describeEntity(entity))
        end, function(error)
          log:error("Failed to set siren volume for %s: %s", ESPHomeClient.describeEntity(entity), error)
        end)
    end)
  end

  -- Duration variable (seconds, uint32)
  if entity.supports_duration then
    values:update(entity.name .. " Duration", 0, "NUMBER", function(newValue)
      local numValue = math.max(0, math.floor(tonumber(newValue) or 0))
      self.client
        :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.siren_command, {
          key = entity.key,
          has_duration = true,
          duration = numValue,
        })
        :next(function()
          log:info("Siren duration set to %ds for %s", numValue, ESPHomeClient.describeEntity(entity))
        end, function(error)
          log:error("Failed to set siren duration for %s: %s", ESPHomeClient.describeEntity(entity), error)
        end)
    end)
  end

  -- Update the relay proxy
  local relayBinding = bindings:getDynamicBinding(self.TYPE, "siren_" .. entity.key)
  if relayBinding ~= nil then
    SendToProxy(relayBinding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")
  end
end

--- Get sorted list of siren names that have tones for programming commands.
--- @return string[] names List of siren display names.
local function getSirenNames()
  local names = TableKeys(sirenRegistry)
  table.sort(names)
  return names
end

--- Populate the Siren parameter dropdown for the Set Siren Tone command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of siren names or tone values.
function GCPL.Set_Siren_Tone(paramName)
  log:trace("GCPL.Set_Siren_Tone(%s)", paramName)
  if paramName == "Siren" then
    return getSirenNames()
  elseif paramName == "Tone" then
    -- Return all tones from all sirens (deduplicated, sorted)
    -- C4 does not pass previously selected param values to GCPL
    local allTones = {}
    local seen = {}
    for _, entry in pairs(sirenRegistry) do
      for _, tone in ipairs(entry.tones) do
        if not seen[tone] then
          seen[tone] = true
          table.insert(allTones, tone)
        end
      end
    end
    table.sort(allTones)
    return allTones
  end
  return {}
end

--- Execute the Set Siren Tone command.
--- @param params table<string, any> Command parameters containing Siren name and Tone value.
function EC.Set_Siren_Tone(params)
  log:trace("EC.Set_Siren_Tone(%s)", params)
  local sirenName = Select(params, "Siren")
  if IsEmpty(sirenName) then
    log:warn("Set Siren Tone command called without siren name")
    return
  end

  local toneValue = Select(params, "Tone")
  if toneValue == nil then
    log:warn("Set Siren Tone command called without tone value")
    return
  end

  local entry = sirenRegistry[sirenName]
  if not entry then
    log:warn("Set Siren Tone command called for unknown siren: %s", sirenName)
    return
  end

  entry.client
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.siren_command, {
      key = entry.key,
      has_tone = true,
      tone = toneValue,
    })
    :next(function()
      log:info("Siren tone set to '%s' for %s", toneValue, sirenName)
    end, function(error)
      log:error("Failed to set siren tone for %s: %s", sirenName, error)
    end)
end

return SirenEntity
