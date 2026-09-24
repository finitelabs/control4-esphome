-- Tests that entities sharing an ESPHome key stay apart.
--
-- ESPHome makes a key unique only within one platform on one device: it is the
-- hash of the entity's name, so a sensor and a text sensor both named "Status",
-- every unnamed entity of a device, and "Temperature" on two sub-devices all
-- share one. Each must keep its own state, connections and variables. When two
-- would get the same name in Control4, the one ESPHome lists last keeps it, or
-- its type's twin on the main device, which that one's commands reached, and the
-- others are told apart.
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
local K_BUTTON = 977454165 -- fnv1_hash_object_id("Button")
local K_KITCHEN_TEMP = 4203696312 -- fnv1_hash_object_id("Kitchen Temperature")
local KITCHEN = 870733615 -- fnv1a_32bit_hash("kitchen")
local BEDROOM = 385580919 -- fnv1a_32bit_hash("bedroom")

--- The commands the driver wrote since the last call, as { message, key, device_id }.
local function commands()
  local got = {}
  for _, request in ipairs(E.written()) do
    got[#got + 1] = { request.message, request.body.key, request.body.device_id }
  end
  return got
end

local function writeVariable(name, value)
  Variables[name] = value
  OnVariableChanged(name)
end

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
  E.send({ { message = "SensorStateResponse", payload = E.unhex("0d48626f01") } })
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
  T.eq("the main device keeps the name", Variables["Temperature"], "20")
  T.eq("kitchen is told apart by its sub-device", Variables["Kitchen Temperature"], "21.5")
  T.eq("bedroom is told apart by its sub-device", Variables["Bedroom Temperature"], "18")
  local main, kitchen, bedroom =
    E.bindingNamed("Temperature"), E.bindingNamed("Kitchen Temperature"), E.bindingNamed("Bedroom Temperature")
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
  -- alone: one connection for all three, with a thermostat connected.
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
  local main = E.bindingNamed("Temperature")
  T.eq("the main device keeps the connection", main and main.id, 10)
  T.eq("and what was connected to it", #ShimConnections(), 1)
  T.eq("the main device keeps the variable", Variables["Temperature"], "20")
  T.eq("at the same place", require("lib.values"):getValue("Temperature").index, before)
  T.eq("the connection carries only the main device", valuesSentTo(main), { 20 })
  local kitchen, bedroom = E.bindingNamed("Kitchen Temperature"), E.bindingNamed("Bedroom Temperature")
  T.check("kitchen gets a new connection", kitchen ~= nil and kitchen.id ~= 10)
  T.check("bedroom gets a new connection", bedroom ~= nil and bedroom.id ~= 10)
end

-- A relay, a button and a doorbell on the main device and on sub-device Kitchen.
-- A command without device_id reaches the main device.
local function shop(mainFirst)
  local function twins(message, key, name, extra)
    local main, kitchen = { key = key, name = name }, { key = key, name = name, device_id = KITCHEN }
    for field, value in pairs(extra or {}) do
      main[field], kitchen[field] = value, value
    end
    local first, second = main, kitchen
    if not mainFirst then
      first, second = kitchen, main
    end
    return { message = message, body = first }, { message = message, body = second }
  end
  local entities = {}
  for _, pair in ipairs({
    { twins("ListEntitiesSwitchResponse", 500, "Relay") },
    { twins("ListEntitiesButtonResponse", 600, "Chime") },
    { twins("ListEntitiesEventResponse", 990, "Doorbell", { event_types = { "press" } }) },
  }) do
    entities[#entities + 1] = pair[1]
    entities[#entities + 1] = pair[2]
  end
  return {
    info = { name = "shop", friendly_name = "Shop", devices = { { device_id = KITCHEN, name = "Kitchen" } } },
    entities = entities,
    states = {
      { message = "SwitchStateResponse", body = { key = 500, state = true } },
      { message = "SwitchStateResponse", body = { key = 500, device_id = KITCHEN, state = false } },
    },
  }
end

T.section("Twins with one on the main device: what was set up still reaches the main device")
for _, mainFirst in ipairs({ true, false }) do
  local label = mainFirst and "main device listed first" or "main device listed last"
  -- What the driver kept when entities were stored by key alone: one connection,
  -- event and variable per key, whose commands reached the main device.
  E.wipe()
  E.boot()
  require("lib.persist"):set("ConnectionBindings", {
    switch = {
      switch_500 = {
        key = "switch_500",
        bindingId = 5012,
        type = "PROXY",
        provider = true,
        displayName = "Relay",
        class = "RELAY",
      },
    },
    button = {
      button_600 = {
        key = "button_600",
        bindingId = 10,
        type = "CONTROL",
        provider = true,
        displayName = "Chime",
        class = "BUTTON_LINK",
      },
    },
  })
  require("lib.persist"):set("Events", {
    event_990 = { press = { eventId = 10, name = "Doorbell: press", description = "Doorbell press event" } },
  })
  require("lib.values"):update("Relay State", "0", "BOOL")
  local before = require("lib.values"):getValue("Relay State").index
  E.boot()
  E.refresh(shop(mainFirst))
  T.eq(label .. ": no handler failed", E.errors, {})
  E.written()

  ReceivedFromProxy(5012, "ON", {})
  T.eq(label .. ": the relay connection", commands(), { { "SwitchCommandRequest", 500 } })
  writeVariable("Relay State", "1")
  T.eq(label .. ": the relay variable", commands(), { { "SwitchCommandRequest", 500 } })
  T.eq(label .. ": at the same place", require("lib.values"):getValue("Relay State").index, before)
  ReceivedFromProxy(10, "DO_CLICK", {})
  T.eq(label .. ": the button connection", commands(), { { "ButtonCommandRequest", 600 } })
  EC.Press_Button({ Button = "Chime" })
  T.eq(label .. ": Press Button", commands(), { { "ButtonCommandRequest", 600 } })
  E.send({ { message = "EventResponse", body = { key = 990, event_type = "press" } } })
  T.eq(label .. ": the doorbell event", E.fired, { 10 })

  local relay = E.bindingNamed("Kitchen Relay")
  T.check(label .. ": the kitchen relay gets a new connection", relay ~= nil and relay.id ~= 5012)
  ReceivedFromProxy(relay and relay.id or 0, "ON", {})
  T.eq(label .. ": which reaches the kitchen", commands(), { { "SwitchCommandRequest", 500, KITCHEN } })
  E.fired = {}
  E.send({ { message = "EventResponse", body = { key = 990, device_id = KITCHEN, event_type = "press" } } })
  T.check(label .. ": the kitchen doorbell fires its own event", #E.fired == 1 and E.fired[1] ~= 10)
end

T.section("Twins with one on the main device: on a new install it has the name")
for _, mainFirst in ipairs({ true, false }) do
  local label = mainFirst and "main device listed first" or "main device listed last"
  E.wipe()
  E.boot()
  E.refresh(shop(mainFirst))
  T.eq(label .. ": main relay", Variables["Relay State"], "1")
  T.eq(label .. ": kitchen relay", Variables["Kitchen Relay State"], "0")
  T.eq(label .. ": events", E.eventNames(), { "Doorbell: press", "Kitchen Doorbell: press" })
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

T.section("Only a twin of its own type on the main device takes the name from the one listed last")
do
  -- The sensor on the main device is not the text sensor's twin, so the text sensor keeps it.
  E.wipe()
  E.boot()
  E.refresh({
    info = TEMPERATURES.info,
    entities = {
      STATUS.entities[2],
      { message = "ListEntitiesTextSensorResponse", body = { key = K_STATUS, name = "Status", device_id = KITCHEN } },
    },
    states = {
      { message = "SensorStateResponse", body = { key = K_STATUS, state = 1 } },
      { message = "TextSensorStateResponse", body = { key = K_STATUS, device_id = KITCHEN, state = "OK" } },
    },
  })
  T.eq("kitchen text sensor, listed last", Variables["Status"], "OK")
  T.eq("main-device sensor is told apart", Variables["Multisensor Status"], "1")
end

T.section("Event twins on two sub-devices: each has its own events")
do
  E.wipe()
  E.boot()
  local function button(deviceId)
    return {
      message = "ListEntitiesEventResponse",
      body = { key = K_BUTTON, name = "Button", device_id = deviceId, event_types = { "press" } },
    }
  end
  E.refresh({
    info = {
      name = "remote",
      devices = { { device_id = KITCHEN, name = "Kitchen" }, { device_id = BEDROOM, name = "Bedroom" } },
    },
    entities = { button(KITCHEN), button(BEDROOM) },
    states = {},
  })
  T.eq("no handler failed", E.errors, {})
  T.eq("events", E.eventNames(), { "Button: press", "Kitchen Button: press" })
  local ids = {}
  for id, event in pairs(ShimEvents()) do
    ids[event.name] = id
  end
  E.send({ { message = "EventResponse", body = { key = K_BUTTON, device_id = KITCHEN, event_type = "press" } } })
  T.eq("a kitchen press fires the kitchen event only", E.fired, { ids["Kitchen Button: press"] })
  T.eq("kitchen last event", Variables["Kitchen Button Last Event"], "press")
  T.eq("bedroom last event untouched", Variables["Button Last Event"], "")
end

T.section("A twin that arrives later does not take a key part in use")
do
  E.wipe()
  E.boot()
  local function temperature(deviceId)
    return {
      message = "ListEntitiesSensorResponse",
      body = { key = K_TEMP, name = "Temperature", device_class = "temperature", device_id = deviceId },
    }
  end
  E.refresh({ info = TEMPERATURES.info, entities = { temperature(KITCHEN) }, states = {} })
  E.boot()
  E.refresh({
    info = TEMPERATURES.info,
    entities = { temperature(KITCHEN), temperature(BEDROOM) },
    states = {
      { message = "SensorStateResponse", body = { key = K_TEMP, device_id = KITCHEN, state = 21 } },
      { message = "SensorStateResponse", body = { key = K_TEMP, device_id = BEDROOM, state = 17 } },
    },
  })
  local kitchen, bedroom = E.bindingNamed("Temperature"), E.bindingNamed("Bedroom Temperature")
  T.check("two connections", kitchen ~= nil and bedroom ~= nil and kitchen.id ~= bedroom.id)
  T.eq("kitchen keeps its name", Variables["Temperature"], "21")
  T.eq("bedroom is told apart", Variables["Bedroom Temperature"], "17")
end

T.section("Reset Driver chooses the names again")
do
  E.wipe()
  E.boot()
  E.refresh(STATUS)
  local grown = {
    info = STATUS.info,
    entities = {
      STATUS.entities[2],
      STATUS.entities[3],
      { message = "ListEntitiesSelectResponse", body = { key = K_STATUS, name = "Status", options = { "a" } } },
    },
    states = {
      { message = "TextSensorStateResponse", body = { key = K_STATUS, state = "T" } },
      { message = "SelectStateResponse", body = { key = K_STATUS, state = "a" } },
    },
  }
  E.refresh(grown)
  T.eq("before, the text sensor keeps the name", Variables["Status"], "T")
  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  E.attach()
  E.refresh(grown)
  T.eq("after, the select, listed last, has it", Variables["Status"], "a")
  T.eq("and the text sensor is told apart", Variables["Status (Text Sensor)"], "T")
end

T.section("A name that starts with its sub-device's name gets no second prefix")
do
  E.wipe()
  E.boot()
  E.refresh({
    info = TEMPERATURES.info,
    entities = {
      { message = "ListEntitiesSensorResponse", body = { key = K_KITCHEN_TEMP, name = "Kitchen Temperature" } },
      {
        message = "ListEntitiesSensorResponse",
        body = { key = K_KITCHEN_TEMP, name = "Kitchen Temperature", device_id = KITCHEN },
      },
    },
    states = {
      { message = "SensorStateResponse", body = { key = K_KITCHEN_TEMP, state = 2 } },
      { message = "SensorStateResponse", body = { key = K_KITCHEN_TEMP, device_id = KITCHEN, state = 3 } },
    },
  })
  T.eq("main device", Variables["Kitchen Temperature"], "2")
  T.eq("kitchen is told apart by its type", Variables["Kitchen Temperature (Sensor)"], "3")
end

T.section("Text and date entities share a sensor's variable names")
do
  local cases = {
    {
      list = "ListEntitiesDateResponse",
      state = { message = "DateStateResponse", body = { key = K_STATUS, year = 2026, month = 9, day = 24 } },
      value = "2026-09-24",
    },
    {
      list = "ListEntitiesTextResponse",
      state = { message = "TextStateResponse", body = { key = K_STATUS, state = "hello" } },
      value = "hello",
    },
  }
  for _, case in ipairs(cases) do
    E.wipe()
    E.boot()
    E.refresh({
      info = STATUS.info,
      entities = { STATUS.entities[2], { message = case.list, body = { key = K_STATUS, name = "Status" } } },
      states = { { message = "SensorStateResponse", body = { key = K_STATUS, state = 7 } }, case.state },
    })
    T.eq(case.list .. ": listed last, keeps the name", Variables["Status"], case.value)
    T.eq(case.list .. ": the sensor is told apart", Variables["Status (Sensor)"], "7")
  end
end

T.section("When every other name is taken, a number")
do
  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "dev", friendly_name = "Dev" },
    entities = {
      { message = "ListEntitiesSensorResponse", body = { key = 1, name = "Status (Sensor)" } },
      { message = "ListEntitiesSensorResponse", body = { key = 2, name = "Dev Status (Sensor)" } },
      STATUS.entities[2],
      STATUS.entities[3],
    },
    states = { { message = "SensorStateResponse", body = { key = K_STATUS, state = 5 } } },
  })
  T.eq("the sensor", Variables["Status (Sensor) 2"], "5")
end

T.finish()
