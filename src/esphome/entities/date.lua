local log = require("lib.logging")
local values = require("lib.values")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

--- @class DateEntity:Entity
local DateEntity = {
  TYPE = ESPHomeClient.EntityType.DATETIME_DATE,
}
DateEntity.__index = DateEntity

--- Create a new instance of the date entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return DateEntity entity A new instance of the DateEntity entity.
function DateEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle updates to the date entity state.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function DateEntity:updated(entity, state)
  log:trace("DateEntity:updated(%s, %s)", entity, state)

  if state.missing_state then
    values:update(entity.name, "", "STRING")
    return
  end

  local formatted = string.format("%04d-%02d-%02d", state.year or 0, state.month or 0, state.day or 0)
  values:update(entity.name, formatted, "STRING", function(newValue)
    local year, month, day = (newValue or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not year then
      log:error(
        "Invalid date format for %s: %s (expected YYYY-MM-DD)",
        ESPHomeClient.describeEntity(entity),
        newValue or ""
      )
      return
    end
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.date_command, {
        key = entity.key,
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
      })
      :next(function()
        log:info("Date updated to %s for %s", newValue, ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error("Failed to update date for %s: %s", ESPHomeClient.describeEntity(entity), error)
      end)
  end)
end

return DateEntity
