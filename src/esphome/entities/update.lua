local log = require("lib.logging")
local values = require("lib.values")
local deferred = require("deferred")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")
local constants = require("constants")

--- Registry of discovered update entities for programming commands.
--- Maps display name to { key = number, client = ESPHomeClient }
--- @type table<string, { key: number, client: ESPHomeClient }>
local updateRegistry = {}

--- @class UpdateEntity:Entity
local UpdateEntity = {
  TYPE = ESPHomeClient.EntityType.UPDATE,
}
UpdateEntity.__index = UpdateEntity

--- Create a new instance of the update entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return UpdateEntity entity A new instance of the UpdateEntity entity.
function UpdateEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of an update entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function UpdateEntity:discovered(entity)
  log:trace("UpdateEntity:discovered(%s)", entity)

  -- Show Automatic Device Updates property now that we know we have update entities
  if next(updateRegistry) == nil then
    C4:SetPropertyAttribs("Automatic Device Updates", constants.SHOW_PROPERTY)
  end

  -- Register update entity for programming commands
  updateRegistry[entity.name] = {
    key = entity.key,
    client = self.client,
  }
end

--- Handle updates to the update entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function UpdateEntity:updated(entity, state)
  log:trace("UpdateEntity:updated(%s, %s)", entity, state)

  if toboolean(state.missing_state) then
    return
  end

  local currentVersion = state.current_version or ""
  local latestVersion = state.latest_version or ""
  local updateAvailable = latestVersion ~= "" and currentVersion ~= latestVersion

  values:update(entity.name .. " Current Version", currentVersion, "STRING")
  values:update(entity.name .. " Latest Version", latestVersion, "STRING")
  -- Values:update reports whether the persisted value actually changed, which makes
  -- the auto-install below edge-triggered (fires when an update becomes available)
  -- rather than re-firing on every state dump for an already-known update.
  local availableChanged = values:update(entity.name .. " Update Available", updateAvailable and "1" or "0", "BOOL")
  values:update(entity.name .. " Update In Progress", toboolean(state.in_progress) and "1" or "0", "BOOL")

  -- Auto-install if enabled and the update just became available
  if updateAvailable and availableChanged and toboolean(Properties["Automatic Device Updates"]) then
    log:info("Automatic device update enabled, installing update for %s", ESPHomeClient.describeEntity(entity))
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.update_command, {
        key = entity.key,
        command = ESPHomeProtoSchema.Enum.UpdateCommand.UPDATE_COMMAND_UPDATE,
      })
      :next(function()
        log:info("Auto-update command sent to %s", ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error("An error occurred auto-updating %s; %s", ESPHomeClient.describeEntity(entity), error)
      end)
  end
end

--- Check whether any update entities have been discovered.
--- @return boolean hasEntities True if at least one update entity exists.
function UpdateEntity:hasEntities()
  return next(updateRegistry) ~= nil
end

--- Check all registered update entities for available updates.
--- Sends UPDATE_COMMAND_CHECK to each entity, triggering state responses
--- that will be handled by the updated() method.
--- @return Deferred A deferred that resolves when all check commands have been sent.
function UpdateEntity:checkAll()
  log:trace("UpdateEntity:checkAll()")
  local deferreds = {}
  for entityName, entry in pairs(updateRegistry) do
    log:debug("Checking for device updates: %s", entityName)
    local d = entry.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.update_command, {
        key = entry.key,
        command = ESPHomeProtoSchema.Enum.UpdateCommand.UPDATE_COMMAND_CHECK,
      })
      :next(function()
        log:debug("Check for updates sent to %s", entityName)
      end, function(error)
        log:error("An error occurred checking for updates on %s; %s", entityName, error)
      end)
    table.insert(deferreds, d)
  end
  return deferred.all(deferreds)
end

--- Get sorted list of update entity names for programming commands.
--- @return string[] names List of update entity display names.
local function getUpdateNames()
  local names = TableKeys(updateRegistry)
  table.sort(names)
  return names
end

--- Send an update command to the specified entity.
--- @param entityName string The display name of the update entity.
--- @param command number The update command enum value.
--- @param commandName string The human-readable command name for logging.
local function sendUpdateCommand(entityName, command, commandName)
  local entry = updateRegistry[entityName]
  if not entry then
    log:warn("%s command called for unknown update entity: %s", commandName, entityName)
    return
  end

  entry.client
    :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.update_command, {
      key = entry.key,
      command = command,
    })
    :next(function()
      log:debug("Command %s sent to update entity %s", commandName, entityName)
    end, function(error)
      log:error("An error occurred sending command %s to update entity %s; %s", commandName, entityName, error)
    end)
end

--- Populate the Update parameter dropdown for the Update Device command.
--- @param paramName string The parameter name being requested.
--- @return string[] list List of update entity names.
function GCPL.Update_Device(paramName)
  log:trace("GCPL.Update_Device(%s)", paramName)
  if paramName ~= "Update" then
    return {}
  end
  return getUpdateNames()
end

--- Execute the Update Device command.
--- Checks for an update first, then installs it if available. If the Update Available
--- boolean is already true, skips the check and installs immediately. Otherwise, sends
--- a check command followed by an install command (the install is a no-op if no update
--- is available after the check).
--- @param params table<string, any> Command parameters containing Update name.
function EC.Update_Device(params)
  log:trace("EC.Update_Device(%s)", params)
  local entityName = Select(params, "Update")
  if IsEmpty(entityName) then
    log:warn("Update Device command called without entity name")
    return
  end

  local entry = updateRegistry[entityName]
  if not entry then
    log:warn("Update Device command called for unknown update entity: %s", entityName)
    return
  end

  local updateAvailable = toboolean(Select(values:getValue(entityName .. " Update Available"), "value"))
  if updateAvailable then
    -- Update already known to be available, install directly
    log:info("Update available for %s, installing", entityName)
    sendUpdateCommand(entityName, ESPHomeProtoSchema.Enum.UpdateCommand.UPDATE_COMMAND_UPDATE, "Update Device")
  else
    -- Check first, then install. The check triggers a state response; if an update
    -- becomes available, the install command will act on it. If no update is available
    -- after the check, the install is a no-op on the device side.
    log:info("Checking for update on %s before installing", entityName)
    entry.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.update_command, {
        key = entry.key,
        command = ESPHomeProtoSchema.Enum.UpdateCommand.UPDATE_COMMAND_CHECK,
      })
      :next(function()
        log:debug("Check sent to %s, now sending install command", entityName)
        return entry.client:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.update_command, {
          key = entry.key,
          command = ESPHomeProtoSchema.Enum.UpdateCommand.UPDATE_COMMAND_UPDATE,
        })
      end)
      :next(function()
        log:info("Update Device command sequence completed for %s", entityName)
      end, function(error)
        log:error("An error occurred during Update Device for %s; %s", entityName, error)
      end)
  end
end

return UpdateEntity
