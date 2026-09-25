-- Tests that an ESPHome entity with no name of its own is named after its
-- device, as Home Assistant names it.
--
-- ESPHome sends such an entity with the name field left off (2026.3.x and
-- older) or empty (2026.4.0 on). The decoder fills no proto3 defaults, so the
-- first arrives as nil; every handler must still create its variables,
-- connections, events and command entries.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_unnamed_entities.lua

local T = require("testlib")
local E = require("esphome_fixtures")

-- fnv1_hash_object_id("Office Plug"): an unnamed entity's key is its device name's.
local KEY = 24076872
local INFO = { name = "office-plug", friendly_name = "Office Plug" }
-- A named entity, which must keep its name.
local UPTIME = { message = "ListEntitiesSensorResponse", body = { key = 1718212937, name = "Uptime" } }
local UPTIME_STATE = { message = "SensorStateResponse", body = { key = 1718212937, state = 42 } }

--- Set a variable as programming would, and return the switch commands it sent as { key, device_id }.
local function commanded(variable)
  E.written()
  Variables[variable] = "1"
  OnVariableChanged(variable)
  local got = {}
  for _, request in ipairs(E.written("SwitchCommandRequest")) do
    got[#got + 1] = { request.body.key, request.body.device_id }
  end
  return got
end

local function noHandlerFailed(label)
  T.eq(label .. ": no handler failed", E.errors, {})
end

local function noBlankVariable(label)
  local bad = {}
  for _, name in ipairs(E.variableNames()) do
    if name == "" or name:match("^%s") then
      bad[#bad + 1] = name
    end
  end
  T.eq(label .. ": no variable is blank or starts with a space", bad, {})
end

T.section("ESPHome's own bytes for an unnamed switch, before and after 2026.4.0")
do
  -- api_pb2.cpp encodes ListEntitiesSwitchResponse without field 3 up to 2026.3.3
  -- and with an empty field 3 (and field 1) from 2026.4.0.
  local wire = {
    ["2026.3.3"] = "15 48626f01",
    ["2026.4.0"] = "0a00 15 48626f01 1a00",
  }
  for _, version in ipairs({ "2026.3.3", "2026.4.0" }) do
    E.wipe()
    E.boot()
    E.refresh({
      info = INFO,
      entities = { { message = "ListEntitiesSwitchResponse", payload = E.unhex(wire[version]) } },
      states = { { message = "SwitchStateResponse", body = { key = KEY, state = true } } },
    })
    noHandlerFailed(version)
    T.eq(version .. ": state variable", Variables["Office Plug State"], "1")
    local relay = E.bindingNamed("Office Plug")
    T.eq(version .. ": relay connection", relay and relay.class, "RELAY")
  end
end

-- One unnamed entity of each platform, with the name left off and then empty.
local PLATFORMS = {
  {
    list = "ListEntitiesBinarySensorResponse",
    state = { message = "BinarySensorStateResponse", body = { key = KEY, state = true } },
    variables = { ["Office Plug State"] = "1" },
    bindings = { ["Office Plug"] = "CONTACT_SENSOR" },
  },
  {
    list = "ListEntitiesButtonResponse",
    bindings = { ["Office Plug"] = "BUTTON_LINK" },
    check = function(label)
      T.eq(label .. ": Press Button list", GCPL.Press_Button("Button"), { "Office Plug" })
    end,
  },
  {
    list = "ListEntitiesClimateResponse",
    bindings = { ["Office Plug"] = "ESPHOME_CLIMATE" },
  },
  {
    list = "ListEntitiesCoverResponse",
    state = { message = "CoverStateResponse", body = { key = KEY, legacy_state = 1 } },
    variables = { ["Office Plug State"] = "closed" },
    bindings = {
      ["Office Plug Closed"] = "CONTACT_SENSOR",
      ["Office Plug Open"] = "CONTACT_SENSOR",
      ["Open Office Plug"] = "RELAY",
      ["Close Office Plug"] = "RELAY",
    },
  },
  {
    list = "ListEntitiesDateResponse",
    state = { message = "DateStateResponse", body = { key = KEY, year = 2026, month = 9, day = 24 } },
    variables = { ["Office Plug"] = "2026-09-24" },
  },
  {
    list = "ListEntitiesDateTimeResponse",
    state = { message = "DateTimeStateResponse", body = { key = KEY, epoch_seconds = 0 } },
    variables = { ["Office Plug"] = os.date("%Y-%m-%d %H:%M:%S", 0) },
  },
  {
    list = "ListEntitiesEventResponse",
    extra = { event_types = { "press" } },
    state = { message = "EventResponse", body = { key = KEY, event_type = "press" } },
    variables = { ["Office Plug Last Event"] = "press" },
    bindings = { ["Office Plug press"] = "BUTTON_LINK" },
    check = function(label)
      T.eq(label .. ": programming event", E.eventNames(), { "Office Plug: press" })
    end,
  },
  {
    list = "ListEntitiesFanResponse",
    bindings = { ["Office Plug"] = "ESPHOME_FAN_1_SPEED" },
  },
  {
    list = "ListEntitiesLightResponse",
    bindings = { ["Office Plug"] = "ESPHOME_LIGHT" },
  },
  {
    list = "ListEntitiesLockResponse",
    bindings = { ["Office Plug"] = "ESPHOME_LOCK" },
  },
  {
    list = "ListEntitiesNumberResponse",
    state = { message = "NumberStateResponse", body = { key = KEY, state = 4.5 } },
    variables = { ["Office Plug"] = "4.5" },
  },
  {
    list = "ListEntitiesSelectResponse",
    extra = { options = { "eco", "boost" } },
    state = { message = "SelectStateResponse", body = { key = KEY, state = "eco" } },
    variables = { ["Office Plug"] = "eco" },
    check = function(label)
      T.eq(label .. ": Set Select list", GCPL.Set_Select("Select"), { "Office Plug" })
    end,
  },
  {
    list = "ListEntitiesSensorResponse",
    extra = { device_class = "temperature" },
    state = { message = "SensorStateResponse", body = { key = KEY, state = 21.5 } },
    variables = { ["Office Plug"] = "21.5" },
    bindings = { ["Office Plug"] = "TEMPERATURE_VALUE" },
  },
  {
    list = "ListEntitiesSwitchResponse",
    state = { message = "SwitchStateResponse", body = { key = KEY, state = true } },
    variables = { ["Office Plug State"] = "1" },
    bindings = { ["Office Plug"] = "RELAY" },
  },
  {
    list = "ListEntitiesTextResponse",
    state = { message = "TextStateResponse", body = { key = KEY, state = "hello" } },
    variables = { ["Office Plug"] = "hello" },
  },
  {
    list = "ListEntitiesTextSensorResponse",
    state = { message = "TextSensorStateResponse", body = { key = KEY, state = "ok" } },
    variables = { ["Office Plug"] = "ok" },
  },
  {
    list = "ListEntitiesTimeResponse",
    state = { message = "TimeStateResponse", body = { key = KEY, hour = 7, minute = 30 } },
    variables = { ["Office Plug"] = "07:30:00" },
  },
  {
    list = "ListEntitiesWaterHeaterResponse",
    bindings = { ["Office Plug"] = "ESPHOME_CLIMATE" },
  },
}

T.section("Every platform names an unnamed entity after its device")
for _, platform in ipairs(PLATFORMS) do
  for _, form in ipairs({ { label = "left off" }, { label = "empty", name = "" } }) do
    local label = string.format("%s, name %s", platform.list:match("^ListEntities(.-)Response$"), form.label)
    local body = { key = KEY, name = form.name }
    for field, value in pairs(platform.extra or {}) do
      body[field] = value
    end
    E.wipe()
    E.boot()
    E.refresh({
      info = INFO,
      entities = { UPTIME, { message = platform.list, body = body } },
      states = { UPTIME_STATE, platform.state },
    })
    noHandlerFailed(label)
    noBlankVariable(label)
    for name, value in pairs(platform.variables or {}) do
      T.eq(string.format("%s: variable %q", label, name), Variables[name], value)
    end
    for name, class in pairs(platform.bindings or {}) do
      local binding = E.bindingNamed(name)
      T.eq(string.format("%s: connection %q", label, name), binding and binding.class, class)
    end
    if platform.check then
      platform.check(label)
    end
    T.eq(label .. ": the named sensor keeps its name", Variables["Uptime"], "42")
  end
end

T.section("On a sub-device, the entity takes the sub-device's name")
do
  local kitchen = 662577719
  E.wipe()
  E.boot()
  E.refresh({
    info = {
      name = "office-plug",
      friendly_name = "Office Plug",
      devices = { { device_id = kitchen, name = "Kitchen" } },
    },
    entities = {
      { message = "ListEntitiesSwitchResponse", body = { key = 1111, device_id = kitchen } },
      -- A device_id the device info does not list falls back to the device's name.
      { message = "ListEntitiesSensorResponse", body = { key = 2222, device_id = 5 } },
    },
    states = {
      { message = "SwitchStateResponse", body = { key = 1111, device_id = kitchen, state = true } },
      { message = "SensorStateResponse", body = { key = 2222, device_id = 5, state = 3 } },
    },
  })
  noHandlerFailed("sub-device")
  T.eq("sub-device switch", Variables["Kitchen State"], "1")
  T.eq("unknown sub-device", Variables["Office Plug"], "3")

  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "office-plug", friendly_name = "Office Plug", devices = { { device_id = kitchen, name = "" } } },
    entities = { { message = "ListEntitiesSwitchResponse", body = { key = 1111, device_id = kitchen } } },
    states = { { message = "SwitchStateResponse", body = { key = 1111, device_id = kitchen, state = true } } },
  })
  T.eq("a sub-device with no name", Variables["Office Plug State"], "1")
end

T.section("An unnamed entity does not take the name of a named one")
do
  -- ESPHome 2025.7.5's listing: before 2026.1 an unnamed sub-device entity's key
  -- is the hash of the sub-device's YAML id (kitchen_dev), not of its name.
  local SUB = 662577719
  local NAMED, UNNAMED = 1586158131, 3641885443
  local named = { message = "ListEntitiesSwitchResponse", body = { key = NAMED, name = "Kitchen" } }
  local unnamed = { message = "ListEntitiesSwitchResponse", body = { key = UNNAMED, device_id = SUB } }
  local function device(entities)
    return {
      info = { name = "rp-collide", friendly_name = "RP Collide", devices = { { device_id = SUB, name = "Kitchen" } } },
      entities = entities,
      states = {
        { message = "SwitchStateResponse", body = { key = NAMED, state = true } },
        { message = "SwitchStateResponse", body = { key = UNNAMED, device_id = SUB, state = false } },
      },
    }
  end
  for _, order in ipairs({ { "named first", { named, unnamed } }, { "unnamed first", { unnamed, named } } }) do
    local label = order[1]
    E.wipe()
    E.boot()
    E.refresh(device(order[2]))
    noHandlerFailed(label)
    T.eq(label .. ": the named switch keeps its variable", Variables["Kitchen State"], "1")
    T.eq(label .. ": the unnamed switch is told apart", Variables["Kitchen (Switch) State"], "0")
    T.eq(label .. ": named connection", (E.bindingNamed("Kitchen") or {}).class, "RELAY")
    T.eq(label .. ": unnamed connection", (E.bindingNamed("Kitchen (Switch)") or {}).class, "RELAY")
    T.eq(label .. ": the named switch's variable commands it", commanded("Kitchen State"), { { NAMED } })
  end

  -- An unnamed entity keeps a name it was given before a named one arrived.
  E.wipe()
  E.boot()
  E.refresh(device({ unnamed }))
  E.refresh(device({ named, unnamed }))
  T.eq("the unnamed switch keeps its variable", Variables["Kitchen State"], "0")
  T.eq("and what it commands", commanded("Kitchen State"), { { UNNAMED, SUB } })
  T.eq("the newcomer is told apart", Variables["RP Collide Kitchen State"], "1")
end

T.section("An unnamed entity keeps the name over its named twin on a sub-device")
do
  -- Named like the main device, the sub-device switch shares the unnamed one's key, and
  -- the key-only store's "Shop State" commanded the main device's switch.
  local GARAGE, SHOP = 12345, 251412225 -- fnv1_hash_object_id("Shop")
  local unnamed = { message = "ListEntitiesSwitchResponse", body = { key = SHOP } }
  local named = { message = "ListEntitiesSwitchResponse", body = { key = SHOP, name = "Shop", device_id = GARAGE } }
  for _, order in ipairs({ { "named listed last", { unnamed, named } }, { "named listed first", { named, unnamed } } }) do
    local label = order[1]
    E.wipe()
    E.boot()
    E.refresh({
      info = { name = "shop", friendly_name = "Shop", devices = { { device_id = GARAGE, name = "Garage" } } },
      entities = order[2],
      states = {
        { message = "SwitchStateResponse", body = { key = SHOP, state = true } },
        { message = "SwitchStateResponse", body = { key = SHOP, device_id = GARAGE, state = false } },
      },
    })
    T.eq(label .. ": the main-device switch", Variables["Shop State"], "1")
    T.eq(label .. ": the garage switch is told apart", Variables["Garage Shop State"], "0")
    T.eq(label .. ": its variable commands the main device", commanded("Shop State"), { { SHOP } })
  end
end

T.section("Without a friendly name, the entity takes the node name")
do
  E.wipe()
  E.boot()
  E.refresh({
    info = { name = "office-plug", friendly_name = "" },
    entities = { { message = "ListEntitiesSwitchResponse", body = { key = 3333 } } },
    states = { { message = "SwitchStateResponse", body = { key = 3333, state = false } } },
  })
  T.eq("node name", Variables["office-plug State"], "0")
end

T.section("With no device name at all, the entity's type and key")
do
  local client = require("esphome.client"):new()
  T.eq("water heater", client:getEntityName({ entity_type = "water_heater", key = 7 }), "Water Heater 7")
  T.eq("date", client:getEntityName({ entity_type = "datetime_date", key = 8 }), "Date 8")
  T.eq("date and time", client:getEntityName({ entity_type = "datetime_datetime", key = 9 }), "Date Time 9")

  E.wipe()
  E.boot()
  E.refresh({
    info = {},
    entities = { { message = "ListEntitiesBinarySensorResponse", body = { key = 3333 } } },
    states = { { message = "BinarySensorStateResponse", body = { key = 3333, state = true } } },
  })
  T.eq("from a listing", Variables["Binary Sensor 3333 State"], "1")
end

T.section("A connection saved with no name is renamed in place")
do
  -- What the driver saved for this switch on 2026.3.x firmware before the fix.
  E.wipe()
  E.boot()
  require("lib.persist"):set("ConnectionBindings", {
    switch = {
      ["switch_" .. KEY] = {
        key = "switch_" .. KEY,
        bindingId = 5012,
        type = "PROXY",
        provider = true,
        class = "RELAY",
      },
    },
  })
  E.boot()
  E.refresh({
    info = INFO,
    entities = { { message = "ListEntitiesSwitchResponse", body = { key = KEY } } },
    states = {},
  })
  local relay = E.bindingNamed("Office Plug")
  T.eq("same connection id", relay and relay.id, 5012)
end

T.finish()
