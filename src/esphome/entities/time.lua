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

--- The variable's write callback: a valid value goes to the device, and an invalid one or one it rejects goes
--- back to its last report.
--- @param self TimeEntity
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return fun(newValue: string|integer|number): void
local function writer(self, entity)
  return function(newValue)
    local reported = Select(values:getValue(entity.name), "value") or ""
    local hour, minute, second = (newValue or ""):match("^(%d%d):(%d%d):(%d%d)$")
    if not hour then
      log:error(
        "Invalid time format for %s: %s (expected HH:MM:SS)",
        ESPHomeClient.describeEntity(entity),
        newValue or ""
      )
      values:update(entity.name, reported, "STRING")
      return
    end
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.time_command, {
        key = entity.key,
        device_id = entity.device_id,
        hour = tonumber(hour),
        minute = tonumber(minute),
        second = tonumber(second),
      })
      :next(function()
        log:info("Time updated to %s for %s", newValue, ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error("Failed to update time for %s: %s", ESPHomeClient.describeEntity(entity), error)
        values:update(entity.name, reported, "STRING")
      end)
  end
end

--- Handle the discovery of a time entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function TimeEntity:discovered(entity)
  log:trace("TimeEntity:discovered(%s)", entity)
  local kept = values:getValue(entity.name)
  values:update(entity.name, kept and not kept.deleted and kept.value or "", "STRING", writer(self, entity))
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
  values:update(entity.name, formatted, "STRING", writer(self, entity))
end

return TimeEntity
