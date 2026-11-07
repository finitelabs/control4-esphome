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

--- The variable's write callback: a valid value goes to the device, and an invalid one or one it rejects goes
--- back to its last report.
--- @param self DateEntity
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return fun(newValue: string|integer|number): void
local function writer(self, entity)
  return function(newValue)
    local reported = Select(values:getValue(entity.name), "value") or ""
    local year, month, day = (newValue or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not year then
      log:error(
        "Invalid date format for %s: %s (expected YYYY-MM-DD)",
        ESPHomeClient.describeEntity(entity),
        newValue or ""
      )
      values:update(entity.name, reported, "STRING")
      return
    end
    self.client
      :callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.date_command, {
        key = entity.key,
        device_id = entity.device_id,
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
      })
      :next(function()
        log:info("Date updated to %s for %s", newValue, ESPHomeClient.describeEntity(entity))
      end, function(error)
        log:error("Failed to update date for %s: %s", ESPHomeClient.describeEntity(entity), error)
        values:update(entity.name, reported, "STRING")
      end)
  end
end

--- Handle the discovery of a date entity.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function DateEntity:discovered(entity)
  log:trace("DateEntity:discovered(%s)", entity)
  local kept = values:getValue(entity.name)
  values:update(entity.name, kept and not kept.deleted and kept.value or "", "STRING", writer(self, entity))
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
  values:update(entity.name, formatted, "STRING", writer(self, entity))
end

return DateEntity
