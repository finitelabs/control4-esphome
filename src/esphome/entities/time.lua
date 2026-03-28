local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class TimeEntity:Entity
local TimeEntity = {
  TYPE = ESPHomeClient.EntityType.DATETIME_TIME,
}
TimeEntity.__index = TimeEntity

--- Create a new instance of the time entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return TimeEntity entity A new instance of the TimeEntity entity.
function TimeEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle updates to the time entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function TimeEntity:updated(entity, state)
  log:trace("TimeEntity:updated(%s, %s)", entity, state)

  if state.missing_state then
    values:update(entity.name, "", "STRING")
    return
  end

  local formatted = string.format("%02d:%02d:%02d", state.hour or 0, state.minute or 0, state.second or 0)
  values:update(entity.name, formatted, "STRING", function(newValue)
    local hour, minute, second = (newValue or ""):match("^(%d%d):(%d%d):(%d%d)$")
    if not hour then
      log:error(
        "Invalid time format for %s.%s: %s (expected HH:MM:SS)",
        entity.entity_type,
        entity.object_id,
        newValue or ""
      )
      return
    end
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.time_command, {
        key = entity.key,
        hour = tonumber(hour),
        minute = tonumber(minute),
        second = tonumber(second),
      })
      :next(function()
        log:info("Time updated to %s for %s.%s", newValue, entity.entity_type, entity.object_id)
      end, function(error)
        log:error("Failed to update time for %s.%s: %s", entity.entity_type, entity.object_id, error)
      end)
  end)
end

return TimeEntity
