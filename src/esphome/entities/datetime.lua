local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class DateTimeEntity:Entity
local DateTimeEntity = {
  TYPE = ESPHomeClient.EntityType.DATETIME_DATETIME,
}
DateTimeEntity.__index = DateTimeEntity

--- Create a new instance of the datetime entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return DateTimeEntity entity A new instance of the DateTimeEntity entity.
function DateTimeEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle updates to the datetime entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function DateTimeEntity:updated(entity, state)
  log:trace("DateTimeEntity:updated(%s, %s)", entity, state)

  if state.missing_state then
    values:update(entity.name, "", "STRING")
    return
  end

  -- The wire uses UTC epoch; format in the project's local time (os.date defaults to local)
  -- so the variable round-trips with os.time on write.
  local epochSeconds = state.epoch_seconds or 0
  local t = os.date("*t", epochSeconds)
  local formatted = string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
  values:update(entity.name, formatted, "STRING", function(newValue)
    local year, month, day, hour, minute, second = (newValue or ""):match(
      "^(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)$"
    )
    if not year then
      log:error(
        "Invalid datetime format for %s: %s (expected YYYY-MM-DD HH:MM:SS)",
        ESPHomeClient.describeEntity(entity),
        newValue or ""
      )
      return
    end
    local epoch = os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = tonumber(hour),
      min = tonumber(minute),
      sec = tonumber(second),
    })
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.datetime_command, {
        key = entity.key,
        epoch_seconds = epoch,
      })
      :next(function()
        log:info("Datetime updated to %s for %s", newValue, ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error("Failed to update datetime for %s: %s", ESPHomeClient.describeEntity(entity), error)
      end)
  end)
end

return DateTimeEntity
