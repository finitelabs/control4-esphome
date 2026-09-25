-- Tests the names and refs listEntities() gives the entities a device lists.
--
-- ESPHome makes a key unique only within one type on one device: a sensor and a
-- text sensor with one name, the unnamed entities of a plug, and "Temperature"
-- on two sub-devices all share one. The driver once kept one entity per key, so
-- that entity keeps its name and its key as ref, which its connections, variables
-- and events are keyed by on an existing install.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_entity_names.lua

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
local T = require("testlib")

local deferred = require("deferred")
local pb = require("protobuf")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local KITCHEN = 870733615
local BEDROOM = 385580919

local client = ESPHomeClient:new()
function client:callServiceMethod()
  return deferred.new():resolve(nil)
end

--- Hand the client a message as the device encodes it.
local function receive(messageName, body)
  local schema = ESPHomeProtoSchema.Message[messageName]
  client:_processPayload(schema.options.id, pb.encode(ESPHomeProtoSchema, schema, body))
end

--- List `responses` for a device described by `deviceInfo`, returning each
--- entity's "name [ref]" by its id.
local function list(deviceInfo, responses)
  client._deviceInfo = deviceInfo
  local entities
  client:listEntities():next(function(result)
    entities = result
  end)
  for _, response in ipairs(responses) do
    receive(response[1], response[2])
  end
  receive("ListEntitiesDoneResponse", {})
  local listed = {}
  for id, entity in pairs(entities) do
    listed[id] = string.format("%s [%s]", entity.name, entity.ref)
  end
  return listed, entities
end

local PLUG =
  { name = "office-plug", friendly_name = "Office Plug", devices = { { device_id = KITCHEN, name = "Kitchen" } } }

T.section("An unnamed entity takes its sub-device's name, else the device's")
do
  local listed = list(PLUG, {
    -- ESPHome 2026.3 and older leave the name off; 2026.4 and newer send it empty.
    { "ListEntitiesSwitchResponse", { key = 1 } },
    { "ListEntitiesLightResponse", { key = 2, name = "", device_id = KITCHEN } },
    { "ListEntitiesSensorResponse", { key = 3, name = "Power" } },
  })
  T.eq("names", listed, {
    ["switch:0:1"] = "Office Plug [1]",
    ["light:870733615:2"] = "Kitchen [2]",
    ["sensor:0:3"] = "Power [3]",
  })

  listed = list({ name = "office-plug", friendly_name = "" }, { { "ListEntitiesSwitchResponse", { key = 1 } } })
  T.eq("without a friendly name, the node name", listed, { ["switch:0:1"] = "office-plug [1]" })

  listed = list({}, { { "ListEntitiesSwitchResponse", { key = 1 } } })
  T.eq("without any name, the listing still completes", listed, { ["switch:0:1"] = "nil [1]" })
end

T.section("Entities that share a key on one device each keep their own entry")
do
  -- ESPHome's own entity_different_platforms fixture, listed in platform order.
  local listed = list({ name = "status" }, {
    { "ListEntitiesBinarySensorResponse", { key = 9, name = "Status" } },
    { "ListEntitiesSensorResponse", { key = 9, name = "Status" } },
    { "ListEntitiesTextSensorResponse", { key = 9, name = "Status" } },
  })
  T.eq("the one listed last keeps the name, one sharing its variable is told apart by type", listed, {
    ["binary_sensor:0:9"] = "Status [9]",
    ["sensor:0:9"] = "Status (Sensor) [9]",
    ["text_sensor:0:9"] = "Status [9]",
  })

  -- An unnamed entity's key is its device name's, so a plug's unnamed entities share it.
  listed = list(PLUG, {
    { "ListEntitiesBinarySensorResponse", { key = 7 } },
    { "ListEntitiesSensorResponse", { key = 7 } },
    { "ListEntitiesSwitchResponse", { key = 7 } },
  })
  T.eq("unnamed entities of one device", listed, {
    ["binary_sensor:0:7"] = "Office Plug (Binary Sensor) [7]",
    ["sensor:0:7"] = "Office Plug [7]",
    ["switch:0:7"] = "Office Plug [7]",
  })
end

T.section("Twins on sub-devices are told apart by their sub-device")
do
  local listed = list({
    name = "multisensor",
    devices = { { device_id = KITCHEN, name = "Kitchen" }, { device_id = BEDROOM, name = "Bedroom" } },
  }, {
    { "ListEntitiesSensorResponse", { key = 5, name = "Temperature" } },
    { "ListEntitiesSensorResponse", { key = 5, name = "Temperature", device_id = KITCHEN } },
    { "ListEntitiesSensorResponse", { key = 5, name = "Temperature", device_id = BEDROOM } },
  })
  T.eq("names and refs", listed, {
    ["sensor:0:5"] = "Temperature [5]",
    ["sensor:870733615:5"] = "Kitchen Temperature [5@870733615]",
    ["sensor:385580919:5"] = "Bedroom Temperature [5@385580919]",
  })

  -- Its name is its sub-device's already, so the type tells it apart instead.
  listed = list(PLUG, {
    { "ListEntitiesSwitchResponse", { key = 6, name = "Kitchen" } },
    { "ListEntitiesSwitchResponse", { key = 6, device_id = KITCHEN } },
  })
  T.eq("an unnamed twin", listed, {
    ["switch:0:6"] = "Kitchen [6]",
    ["switch:870733615:6"] = "Kitchen (Switch) [6@870733615]",
  })
end

T.section("The entity the driver kept by key keeps its name and ref")
do
  -- Commands without a device_id reached the main device, whichever twin was listed last.
  for _, mainFirst in ipairs({ true, false }) do
    local main = { "ListEntitiesSwitchResponse", { key = 500, name = "Relay" } }
    local kitchen = { "ListEntitiesSwitchResponse", { key = 500, name = "Relay", device_id = KITCHEN } }
    local listed = list(PLUG, mainFirst and { main, kitchen } or { kitchen, main })
    T.eq(mainFirst and "main device listed first" or "main device listed last", listed, {
      ["switch:0:500"] = "Relay [500]",
      ["switch:870733615:500"] = "Kitchen Relay [500@870733615]",
    })
  end

  local listed = list({
    name = "multisensor",
    devices = { { device_id = KITCHEN, name = "Kitchen" }, { device_id = BEDROOM, name = "Bedroom" } },
  }, {
    { "ListEntitiesSensorResponse", { key = 5, name = "Temperature", device_id = KITCHEN } },
    { "ListEntitiesSensorResponse", { key = 5, name = "Temperature", device_id = BEDROOM } },
  })
  T.eq("with no twin on the main device, the one listed last", listed, {
    ["sensor:870733615:5"] = "Kitchen Temperature [5@870733615]",
    ["sensor:385580919:5"] = "Temperature [5]",
  })

  listed = list(PLUG, {
    { "ListEntitiesSensorResponse", { key = 9, name = "Status" } },
    { "ListEntitiesTextSensorResponse", { key = 9, name = "Status", device_id = KITCHEN } },
  })
  T.eq("a main-device entity of another type is not its twin", listed, {
    ["sensor:0:9"] = "Status (Sensor) [9]",
    ["text_sensor:870733615:9"] = "Status [9]",
  })
end

T.section("A name of an entity's own goes before a device's")
do
  -- ESPHome 2025.7 to 2025.12 key an unnamed sub-device entity by its sub-device, so it
  -- and an entity named after that sub-device are both kept. Keys are from a 2025.7.5 device.
  local LAB = { name = "lab-b", friendly_name = "Lab B", devices = { { device_id = 662577719, name = "Kitchen" } } }
  local named = { "ListEntitiesSwitchResponse", { key = 1586158131, name = "Kitchen" } }
  for _, namedFirst in ipairs({ true, false }) do
    local unnamed = { "ListEntitiesSwitchResponse", { key = 3641885443, device_id = 662577719 } }
    local listed = list(LAB, namedFirst and { named, unnamed } or { unnamed, named })
    T.eq(namedFirst and "named listed first" or "unnamed listed first", listed, {
      ["switch:0:1586158131"] = "Kitchen [1586158131]",
      ["switch:662577719:3641885443"] = "Kitchen (Switch) [3641885443]",
    })
  end

  local listed = list(LAB, {
    { "ListEntitiesBinarySensorResponse", { key = 3641885443, device_id = 662577719 } },
    named,
  })
  T.eq("an unnamed entity of another type listed first", listed, {
    ["binary_sensor:662577719:3641885443"] = "Kitchen (Binary Sensor) [3641885443]",
    ["switch:0:1586158131"] = "Kitchen [1586158131]",
  })
end

T.section("A made-up name never repeats another entity's variable")
do
  -- "Kitchen Open" and "Kitchen State" are variables of the cover and the switch.
  local listed = list(PLUG, {
    { "ListEntitiesCoverResponse", { key = 1, name = "Kitchen" } },
    { "ListEntitiesSensorResponse", { key = 2, name = "Open" } },
    { "ListEntitiesSensorResponse", { key = 2, name = "Open", device_id = KITCHEN } },
  })
  T.eq("a cover's Open value", listed, {
    ["cover:0:1"] = "Kitchen [1]",
    ["sensor:0:2"] = "Open [2]",
    ["sensor:870733615:2"] = "Open (Sensor) [2@870733615]",
  })

  listed = list(PLUG, {
    { "ListEntitiesSensorResponse", { key = 4, name = "State", device_id = KITCHEN } },
    { "ListEntitiesSensorResponse", { key = 4, name = "State" } },
    { "ListEntitiesSwitchResponse", { key = 3, name = "Kitchen" } },
  })
  T.eq("a switch's State", listed, {
    ["sensor:870733615:4"] = "State (Sensor) [4@870733615]",
    ["sensor:0:4"] = "State [4]",
    ["switch:0:3"] = "Kitchen [3]",
  })
end

T.section("A same-named entity of another type keeps its name")
do
  -- Their variables, "Temperature" and "Temperature State", never collided.
  local listed = list(PLUG, {
    { "ListEntitiesSensorResponse", { key = 1, name = "Temperature" } },
    { "ListEntitiesBinarySensorResponse", { key = 2, name = "Temperature" } },
  })
  T.eq("a sensor and a binary sensor", listed, {
    ["sensor:0:1"] = "Temperature [1]",
    ["binary_sensor:0:2"] = "Temperature [2]",
  })

  -- A button writes no variable, and Press Button looks up buttons alone.
  listed = list(PLUG, {
    { "ListEntitiesButtonResponse", { key = 3, name = "Doorbell" } },
    { "ListEntitiesEventResponse", { key = 4, name = "Doorbell" } },
  })
  T.eq("a button and an event", listed, {
    ["button:0:3"] = "Doorbell [3]",
    ["event:0:4"] = "Doorbell [4]",
  })
end

T.section("Twins that write no variable are told apart too")
do
  -- Press Button finds a button by its name alone.
  local listed = list({
    name = "multisensor",
    devices = { { device_id = KITCHEN, name = "Kitchen" }, { device_id = BEDROOM, name = "Bedroom" } },
  }, {
    { "ListEntitiesButtonResponse", { key = 11, name = "Restart", device_id = BEDROOM } },
    { "ListEntitiesButtonResponse", { key = 11, name = "Restart", device_id = KITCHEN } },
  })
  T.eq("buttons on sub-devices", listed, {
    ["button:870733615:11"] = "Restart [11]",
    ["button:385580919:11"] = "Bedroom Restart [11@385580919]",
  })

  listed = list(PLUG, {
    { "ListEntitiesLightResponse", { key = 12, name = "Lamp" } },
    { "ListEntitiesLightResponse", { key = 13, name = "Lamp" } },
  })
  T.eq("lights on the main device", listed, {
    ["light:0:12"] = "Lamp [12]",
    ["light:0:13"] = "Lamp (Light) [13]",
  })
end

T.section("A name is told apart when another entity already writes its variable")
do
  local listed = list(PLUG, {
    { "ListEntitiesSensorResponse", { key = 14, name = "Doorbell Last Event" } },
    { "ListEntitiesEventResponse", { key = 15, name = "Doorbell" } },
  })
  T.eq("an event's Last Event", listed, {
    ["sensor:0:14"] = "Doorbell Last Event [14]",
    ["event:0:15"] = "Doorbell (Event) [15]",
  })
end

T.section("A state response finds its own entity")
do
  local _, entities = list(PLUG, {
    { "ListEntitiesSensorResponse", { key = 9, name = "Status" } },
    { "ListEntitiesTextSensorResponse", { key = 9, name = "Status" } },
    { "ListEntitiesSensorResponse", { key = 9, name = "Status", device_id = KITCHEN } },
  })
  local function find(messageName, state)
    local entity = entities[ESPHomeClient.getEntityId(ESPHomeProtoSchema.Message[messageName], state)]
    return entity and entity.name
  end
  T.eq("sensor", find("SensorStateResponse", { key = 9, state = 1 }), "Status")
  T.eq("text sensor", find("TextSensorStateResponse", { key = 9, state = "OK" }), "Status (Text Sensor)")
  T.eq("kitchen sensor", find("SensorStateResponse", { key = 9, device_id = KITCHEN, state = 2 }), "Kitchen Status")
end

T.finish()
