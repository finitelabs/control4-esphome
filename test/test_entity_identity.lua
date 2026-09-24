-- Tests that entities sharing an ESPHome key stay apart.
--
-- ESPHome makes a key unique only within one platform on one device: it is the
-- hash of the entity's name, so a sensor and a text sensor both named "Status",
-- every unnamed entity of a device, and "Temperature" on two sub-devices all
-- share one. Each must keep its own state, connections and variables, and when
-- two would get the same name in Control4, the one ESPHome lists last keeps it
-- (as it did when only that one was kept) and the others are told apart.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_entity_identity.lua

local T = require("testlib")
local E = require("esphome_fixtures")

local K_STATUS = 939730931 -- fnv1_hash_object_id("Status")
local K_OFFICE = 24076872 -- fnv1_hash_object_id("Office Plug")
local K_TEMP = 899752953 -- fnv1_hash_object_id("Temperature")
local KITCHEN = 870733615 -- fnv1a_32bit_hash("kitchen")
local BEDROOM = 385580919 -- fnv1a_32bit_hash("bedroom")

--- The VALUE of every VALUE_CHANGED sent to a binding.
local function valuesSentTo(binding)
  local values = {}
  for _, send in ipairs(E.sent) do
    if binding ~= nil and send.binding == binding.id and send.command == "VALUE_CHANGED" then
      values[#values + 1] = send.params.VALUE
    end
  end
  return values
end

-- ESPHome's own fixture, entity_different_platforms.yaml, listed in platform order.
local STATUS = {
  info = { name = "test-different-platforms" },
  entities = {
    { message = "ListEntitiesBinarySensorResponse", body = { key = K_STATUS, name = "Status" } },
    { message = "ListEntitiesSensorResponse", body = { key = K_STATUS, name = "Status" } },
    { message = "ListEntitiesTextSensorResponse", body = { key = K_STATUS, name = "Status" } },
  },
  states = {
    { message = "BinarySensorStateResponse", body = { key = K_STATUS, state = true } },
    { message = "SensorStateResponse", body = { key = K_STATUS, state = 1 } },
    { message = "TextSensorStateResponse", body = { key = K_STATUS, state = "OK" } },
    { message = "SensorStateResponse", body = { key = K_STATUS, state = 2 } },
  },
}

T.section("Same name on three platforms: each keeps its own state")
do
  E.wipe()
  E.boot()
  E.refresh(STATUS)
  T.eq("no handler failed", E.errors, {})
  T.eq("binary sensor", Variables["Status State"], "1")
  T.eq("text sensor, listed last, keeps the name", Variables["Status"], "OK")
  T.eq("sensor is told apart by its type", Variables["Status (Sensor)"], "2")
  local contact = E.bindingNamed("Status")
  T.eq("binary sensor connection", contact and contact.class, "CONTACT_SENSOR")
end

T.section("Unnamed entities of one device: each keeps its own state")
do
  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "office-plug", friendly_name = "Office Plug" },
    entities = {
      { message = "ListEntitiesBinarySensorResponse", body = { key = K_OFFICE } },
      { message = "ListEntitiesSensorResponse", body = { key = K_OFFICE } },
      { message = "ListEntitiesSwitchResponse", body = { key = K_OFFICE } },
    },
    states = {
      { message = "BinarySensorStateResponse", body = { key = K_OFFICE, state = true } },
      { message = "SensorStateResponse", body = { key = K_OFFICE, state = 12.3 } },
      { message = "SwitchStateResponse", body = { key = K_OFFICE, state = true } },
    },
  })
  T.eq("no handler failed", E.errors, {})
  T.eq("switch keeps the device name", Variables["Office Plug State"], "1")
  T.eq("binary sensor is told apart", Variables["Office Plug (Binary Sensor) State"], "1")
  T.eq("sensor", Variables["Office Plug"], "12.3")
  local relay = E.bindingNamed("Office Plug")
  T.eq("relay connection", relay and relay.class, "RELAY")
  T.eq("contact connection", (E.bindingNamed("Office Plug (Binary Sensor)") or {}).class, "CONTACT_SENSOR")

  -- A float 0 is left off the wire; the relay used to take that for "off".
  E.sent = {}
  E.send({ { message = "SensorStateResponse", body = { key = K_OFFICE, state = 0 } } })
  T.eq("a power reading does not reach the relay", E.sentTo(relay.id), {})
  T.eq("switch state unchanged", Variables["Office Plug State"], "1")
end

-- ESPHome's own test_entity_duplicate_validator_with_devices allows this.
local TEMPERATURES = {
  info = {
    name = "multisensor",
    friendly_name = "Multisensor",
    devices = { { device_id = KITCHEN, name = "Kitchen" }, { device_id = BEDROOM, name = "Bedroom" } },
  },
  entities = {
    {
      message = "ListEntitiesSensorResponse",
      body = { key = K_TEMP, name = "Temperature", device_class = "temperature" },
    },
    {
      message = "ListEntitiesSensorResponse",
      body = { key = K_TEMP, name = "Temperature", device_class = "temperature", device_id = KITCHEN },
    },
    {
      message = "ListEntitiesSensorResponse",
      body = { key = K_TEMP, name = "Temperature", device_class = "temperature", device_id = BEDROOM },
    },
  },
  states = {
    { message = "SensorStateResponse", body = { key = K_TEMP, state = 20 } },
    { message = "SensorStateResponse", body = { key = K_TEMP, state = 21.5, device_id = KITCHEN } },
    { message = "SensorStateResponse", body = { key = K_TEMP, state = 18, device_id = BEDROOM } },
  },
}

T.section("Same name on sub-devices: each keeps its own state and connection")
do
  E.wipe()
  E.boot()
  E.refresh(TEMPERATURES)
  T.eq("no handler failed", E.errors, {})
  T.eq("bedroom, listed last, keeps the name", Variables["Temperature"], "18")
  T.eq("kitchen is told apart by its sub-device", Variables["Kitchen Temperature"], "21.5")
  T.eq("main device is told apart by its device", Variables["Multisensor Temperature"], "20")
  local main, kitchen, bedroom =
    E.bindingNamed("Multisensor Temperature"), E.bindingNamed("Kitchen Temperature"), E.bindingNamed("Temperature")
  T.eq("connection ids follow the listing", { main and main.id, kitchen and kitchen.id, bedroom and bedroom.id }, {
    10,
    11,
    12,
  })
  T.eq("main connection", valuesSentTo(main), { 20 })
  T.eq("kitchen connection", valuesSentTo(kitchen), { 21.5 })
  T.eq("bedroom connection", valuesSentTo(bedroom), { 18 })
end

T.section("An install from before: what it had stays where it was")
do
  -- What the driver kept for TEMPERATURES when entities were stored by key
  -- alone: only the bedroom sensor, listed last, with a thermostat connected.
  E.wipe()
  E.boot()
  require("lib.persist"):set("ConnectionBindings", {
    sensor = {
      ["sensor_" .. K_TEMP] = {
        key = "sensor_" .. K_TEMP,
        bindingId = 10,
        type = "CONTROL",
        provider = true,
        displayName = "Temperature",
        class = "TEMPERATURE_VALUE",
      },
    },
  })
  require("lib.values"):update("Temperature", 22, "NUMBER")
  local before = require("lib.values"):getValue("Temperature").index
  E.boot()
  C4:Bind(C4:GetDeviceID(), 10, 999, 1, "TEMPERATURE_VALUE")
  E.refresh(TEMPERATURES)
  local bedroom = E.bindingNamed("Temperature")
  T.eq("bedroom keeps its connection", bedroom and bedroom.id, 10)
  T.eq("and what was connected to it", #ShimConnections(), 1)
  T.eq("bedroom keeps its variable", Variables["Temperature"], "18")
  T.eq("at the same place", require("lib.values"):getValue("Temperature").index, before)
  T.eq("the connection carries only the bedroom", valuesSentTo(bedroom), { 18 })
  local kitchen = E.bindingNamed("Kitchen Temperature")
  T.check("kitchen gets a new connection", kitchen ~= nil and kitchen.id ~= 10)
end

T.section("A name, once given, stays when entities come and go")
do
  E.wipe()
  E.boot()
  E.refresh(STATUS)
  -- A select, listed after the text sensor, that would take the name back.
  local grown = {
    info = STATUS.info,
    entities = {
      STATUS.entities[1],
      STATUS.entities[2],
      STATUS.entities[3],
      { message = "ListEntitiesSelectResponse", body = { key = K_STATUS, name = "Status", options = { "a" } } },
    },
    states = {
      { message = "SensorStateResponse", body = { key = K_STATUS, state = 3 } },
      { message = "TextSensorStateResponse", body = { key = K_STATUS, state = "FINE" } },
      { message = "SelectStateResponse", body = { key = K_STATUS, state = "a" } },
    },
  }
  E.refresh(grown)
  T.eq("text sensor keeps the name", Variables["Status"], "FINE")
  T.eq("sensor keeps its name", Variables["Status (Sensor)"], "3")
  T.eq("the newcomer is told apart", Variables["Status (Select)"], "a")

  -- The text sensor goes; the others keep what they have across a restart.
  E.boot()
  E.refresh({
    info = STATUS.info,
    entities = { STATUS.entities[2], grown.entities[4] },
    states = {
      { message = "SensorStateResponse", body = { key = K_STATUS, state = 4 } },
      { message = "SelectStateResponse", body = { key = K_STATUS, state = "a" } },
    },
  })
  T.eq("sensor still", Variables["Status (Sensor)"], "4")
  T.eq("select still", Variables["Status (Select)"], "a")
  -- The gone text sensor's variable stays, as variables do, and nothing writes it.
  T.eq("nobody took the freed name", Variables["Status"], "FINE")

  -- A newcomer takes the free name; the text sensor, back again, is a newcomer too.
  local number = { message = "ListEntitiesNumberResponse", body = { key = K_STATUS, name = "Status" } }
  E.refresh({ info = STATUS.info, entities = { STATUS.entities[2], number, grown.entities[4] }, states = {} })
  E.refresh({
    info = STATUS.info,
    entities = { STATUS.entities[2], STATUS.entities[3], number, grown.entities[4] },
    states = {
      { message = "NumberStateResponse", body = { key = K_STATUS, state = 9 } },
      { message = "TextSensorStateResponse", body = { key = K_STATUS, state = "BACK" } },
    },
  })
  T.eq("the newcomer has the name", Variables["Status"], "9")
  T.eq("the text sensor comes back told apart", Variables["Status (Text Sensor)"], "BACK")
end

T.section("Entities with different keys keep their own names")
do
  -- Both were set up before: they share the value "Door Open", but renaming
  -- either would move a named entity's variable.
  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "garage" },
    entities = {
      { message = "ListEntitiesCoverResponse", body = { key = 1, name = "Door" } },
      { message = "ListEntitiesSensorResponse", body = { key = 2, name = "Door Open" } },
    },
    states = { { message = "SensorStateResponse", body = { key = 2, state = 5 } } },
  })
  T.eq("sensor keeps its name", Variables["Door Open"], "5")
  T.truthy("cover keeps its name", E.bindingNamed("Open Door"))

  -- A name the driver made up is kept, even from an entity really called that.
  E.wipe()
  E.boot()
  E.refresh(TEMPERATURES)
  E.refresh({
    info = TEMPERATURES.info,
    entities = {
      TEMPERATURES.entities[1],
      TEMPERATURES.entities[2],
      TEMPERATURES.entities[3],
      { message = "ListEntitiesSensorResponse", body = { key = 3, name = "Kitchen Temperature" } },
    },
    states = {
      { message = "SensorStateResponse", body = { key = K_TEMP, state = 21.5, device_id = KITCHEN } },
      { message = "SensorStateResponse", body = { key = 3, state = 30 } },
    },
  })
  T.eq("made-up name kept", Variables["Kitchen Temperature"], "21.5")
  T.eq("the real one is told apart", Variables["Multisensor Kitchen Temperature"], "30")
end

T.section("A made-up name never repeats a cover's Open or Closed value")
do
  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "garage", friendly_name = "Garage", devices = { { device_id = KITCHEN, name = "Kitchen" } } },
    entities = {
      { message = "ListEntitiesCoverResponse", body = { key = 1, name = "Kitchen" } },
      { message = "ListEntitiesSensorResponse", body = { key = 2, name = "Open", device_id = KITCHEN } },
      { message = "ListEntitiesSensorResponse", body = { key = 2, name = "Open" } },
    },
    states = { { message = "SensorStateResponse", body = { key = 2, state = 1, device_id = KITCHEN } } },
  })
  T.eq("kitchen sensor", Variables["Open (Sensor)"], "1")
end

T.section("A climate and a water heater on one key: each gets its own state")
do
  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "heat-pump", friendly_name = "Heat Pump" },
    entities = {
      { message = "ListEntitiesClimateResponse", body = { key = 77 } },
      { message = "ListEntitiesWaterHeaterResponse", body = { key = 77 } },
    },
    states = {
      { message = "ClimateStateResponse", body = { key = 77, current_temperature = 20 } },
      { message = "WaterHeaterStateResponse", body = { key = 77, current_temperature = 50 } },
    },
  })
  local heater, climate = E.bindingNamed("Heat Pump"), E.bindingNamed("Heat Pump (Climate)")
  T.eq("water heater, listed last, keeps the name", heater and heater.class, "ESPHOME_CLIMATE")
  T.eq("climate is told apart", climate and climate.class, "ESPHOME_CLIMATE")
  T.eq("climate state", climate and E.sentTo(climate.id), { "UPDATE_STATE" })
  T.eq("water heater state", heater and E.sentTo(heater.id), { "UPDATE_STATE" })
end

T.finish()
