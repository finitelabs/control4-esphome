-- A fake ESPHome device for the bridge driver (drivers/esphome/driver.lua).
--
-- The driver runs its own RefreshStatus chain and only the socket is replaced:
-- every reply goes through the client's framing and the vendored protobuf
-- decoder, and every request the driver writes is decoded back for assertions.
--
-- Usage:
--   local E = require("esphome_fixtures")
--   E.boot()
--   E.refresh({ info = { name = "office-plug" }, entities = { ... }, states = { ... } })

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.lib")

local pb = require("protobuf")
local Schema = require("esphome.proto_schema")

local E = {}

-- Resolved against this file: make test runs from the repo root, run_test.sh from test/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/esphome/driver.lua"

--- The controller's persistent storage. It survives E.boot(), as PersistData
--- survives a Director restart; E.wipe() empties it.
E.store = {}
function C4:PersistGetValue(key)
  return E.store[key]
end
function C4:PersistSetValue(key, value)
  E.store[key] = value
end
function C4:PersistDeleteValue(key)
  E.store[key] = nil
end

local shimConfigInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  local info = { minimum_os_version = "3.3.0", model = "ESPHome", version = "test" }
  if info[section] ~= nil then
    return info[section]
  end
  return shimConfigInfo(self, section)
end
function C4:GetDevicesByC4iName()
  return {}
end
function C4:UpdatePropertyList() end
package.preload["cloud-client-byte"] = function()
  return {}
end
Properties["Driver Status"] = ""

--- @param hex string
--- @return string bytes
function E.unhex(hex)
  return (hex:gsub("%s", ""):gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

--- A message as the device sends it: `payload` is raw wire bytes when a test
--- needs ESPHome's exact encoding, else `body` is encoded here.
--- @param message { message: string, body: table?, payload: string? }
--- @return string frame A plaintext API frame.
local function frame(message)
  local schema = assert(Schema.Message[message.message], message.message)
  local payload = message.payload or pb.encode(Schema, schema, message.body or {})
  return "\0" .. pb.encode_varint(#payload) .. pb.encode_varint(schema.options.id) .. payload
end

local function schemaById(id)
  for _, schema in pairs(Schema.Message) do
    if schema.options and schema.options.id == id then
      return schema
    end
  end
end

--- The device the socket answers for.
local device = { info = {}, entities = {}, states = {} }
local inbound = {}
local written = {}

local socket = {}
function socket:Write(data)
  local size, pos = pb.decode_varint(data, 2)
  local id, start = pb.decode_varint(data, pos)
  local schema = schemaById(id)
  local body = pb.decode(Schema, schema, data:sub(start, start + size - 1))
  written[#written + 1] = { message = schema.name, body = body }

  local replies = {}
  if schema.name == "DeviceInfoRequest" then
    replies = { { message = "DeviceInfoResponse", body = device.info } }
  elseif schema.name == "ListEntitiesRequest" then
    for _, entity in ipairs(device.entities) do
      replies[#replies + 1] = entity
    end
    replies[#replies + 1] = { message = "ListEntitiesDoneResponse" }
  elseif schema.name == "SubscribeStatesRequest" then
    replies = device.states or {}
  end
  for _, reply in ipairs(replies) do
    inbound[#inbound + 1] = frame(reply)
  end
end
function socket:Close() end

--- Feed whatever the device has queued through the client's receive path.
function E.pump()
  while #inbound > 0 do
    E.client._buffer = E.client._buffer .. table.remove(inbound, 1)
    E.client:_processBuffer()
  end
end

--- Deliver more messages from the device, e.g. state changes after a refresh.
--- @param messages { message: string, body: table?, payload: string? }[]
function E.send(messages)
  for _, message in ipairs(messages) do
    inbound[#inbound + 1] = frame(message)
  end
  E.pump()
end

--- Requests the driver has written since the last call, decoded.
--- @param messageName? string Only requests of this message type.
--- @return { message: string, body: table }[]
function E.written(messageName)
  local out = {}
  for _, request in ipairs(written) do
    if messageName == nil or request.message == messageName then
      out[#out + 1] = request
    end
  end
  written = {}
  return out
end

--- Load the bridge as Director does after a restart: modules fresh, persisted
--- data kept, no variables, dynamic bindings or events left over, then
--- OnDriverInit and OnDriverLateInit.
--- @param keepEvents? boolean Leave Director's declared events in place.
function E.boot(keepEvents)
  for name in pairs(package.loaded) do
    if name:match("^lib%.") or name:match("^esphome%.") or name == "constants" then
      package.loaded[name] = nil
    end
  end
  Variables = {}
  ShimResetDynamicBindings()
  if not keepEvents then
    ShimResetEvents()
  end
  inbound, written = {}, {}

  local ESPHomeClient = require("esphome.client")
  local new = ESPHomeClient.new
  ESPHomeClient.new = function(self)
    E.client = new(self)
    return E.client
  end
  dofile(DRIVER)
  ESPHomeClient.new = new

  -- Handler failures are caught and logged by the driver, so collect them.
  E.errors = {}
  require("lib.logging").error = function(_, text, ...)
    local parts = { tostring(text) }
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    E.errors[#E.errors + 1] = table.concat(parts, " ")
  end

  OnDriverInit()
  OnDriverLateInit()

  -- After LateInit: its Connect() finds no IP address and disconnects.
  E.client._client = socket
  E.client._connected = true
end

--- Forget everything the controller stored, as a new install would.
function E.wipe()
  E.store = {}
end

--- One status refresh, answered by `spec`.
--- @param spec { info: table, entities: table[], states: table[]? }
function E.refresh(spec)
  device = spec
  RefreshStatus()
  ShimFireTimers() -- the 3 s debounce
  E.pump()
end

--- Declared Control4 variable names, sorted.
--- @return string[]
function E.variableNames()
  local names = {}
  for name in pairs(Variables) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- The dynamic binding with this display name, or nil.
--- @return { id: integer, name: string, class: string }|nil
function E.bindingNamed(name)
  for _, binding in pairs(ShimDynamicBindings()) do
    if binding.name == name then
      return binding
    end
  end
end

--- Declared event names, sorted.
--- @return string[]
function E.eventNames()
  local names = {}
  for _, event in pairs(ShimEvents()) do
    names[#names + 1] = event.name
  end
  table.sort(names)
  return names
end

return E
