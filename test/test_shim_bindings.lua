-- Tests for the dynamic-binding half of test/c4_shim.lua.
--
-- lib/bindings.lua reads bindings back as much as it declares them: the rename
-- path snapshots connections out of GetBindingsByDevice and re-Binds them, and
-- Bind() asks GetBoundConsumerDevices whether a link already exists. The read
-- shapes pinned here were measured on a dev controller; where the DriverWorks
-- reference disagrees, the controller wins and the check names the divergence.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_shim_bindings.lua

local T = require("testlib")

--- Nil-safe nested lookup, so a shim regression FAILs the check rather than
--- crashing the run on the first missing field.
local function at(value, ...)
  for _, key in ipairs({ ... }) do
    if type(value) ~= "table" then
      return nil
    end
    value = value[key]
  end
  return value
end

local ME = C4:GetDeviceID()
local CONSUMER = 987

local function recordFor(deviceId, bindingId)
  for _, record in ipairs(C4:GetBindingsByDevice(deviceId).bindings or {}) do
    if record.bindingid == bindingId then
      return record
    end
  end
end

local function countBindings(deviceId)
  return #(C4:GetBindingsByDevice(deviceId).bindings or {})
end

--------------------------------------------------------------------------------
T.section("declaring a binding")
do
  ShimResetDynamicBindings()
  ShimSetStaticBindings({})
  local live = ShimDynamicBindings()

  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY", true, true)
  local b = live[10] or {}
  T.eq("add records every argument", { name = b.name, class = b.class, provider = b.provider }, {
    name = "Valve",
    class = "RELAY",
    provider = true,
  })
  T.eq("add records the trailing pair", { hidden = b.hidden, autoBind = b.autoBind }, {
    hidden = true,
    autoBind = true,
  })

  C4:AddDynamicBinding(11, "PROXY", false, "Light 1", "LIGHT_V2")
  local d = live[11] or {}
  T.eq("hidden and autoBind default false", { hidden = d.hidden, autoBind = d.autoBind }, {
    hidden = false,
    autoBind = false,
  })

  local record = recordFor(ME, 10)
  T.truthy("a declared binding reads back through GetBindingsByDevice", record)
  T.eq("the record carries the controller's field set", {
    deviceid = at(record, "deviceid"),
    name = at(record, "name"),
    provider = at(record, "provider"),
    flags = at(record, "flags"),
    binding_info = at(record, "binding_info"),
  }, { deviceid = ME, name = "Valve", provider = true, flags = 0, binding_info = "" })
  T.eq("CONTROL is type 1, PROXY is type 2", { at(record, "type"), at(recordFor(ME, 11), "type") }, { 1, 2 })
  T.check(
    "the class arrives under bindingclasses, with rank and autobind",
    at(record, "bindingclasses", 1, "class") == "RELAY"
      and at(record, "bindingclasses", 1, "rank") == 0
      and at(record, "bindingclasses", 1, "autobind") == true
      and type(at(record, "bindingclasses", 1, "excludeids")) == "table",
    T.show(at(record, "bindingclasses", 1))
  )
  T.eq(
    "an unbound binding is not bound and has no peers",
    { isbound = at(record, "isbound"), boundconsumers = at(record, "boundconsumers") },
    { isbound = false }
  )

  C4:AddDynamicBinding(10, "CONTROL", true, "Valve renamed", "RELAY")
  T.eq("a re-add under a live id replaces the record", at(recordFor(ME, 10), "name"), "Valve renamed")
end

--------------------------------------------------------------------------------
T.section("wiring a consumer to our provider binding")
do
  ShimResetDynamicBindings()
  ShimSetDevices({ [CONSUMER] = { deviceName = "Hallway Switch" } })
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")

  T.falsy("nothing is bound before Bind", C4:GetBoundConsumerDevices(ME, 10))
  T.eq("GetBoundProviderDevice answers 0, not nil, when unbound", C4:GetBoundProviderDevice(ME, 10), 0)

  C4:Bind(ME, 10, CONSUMER, 1, "RELAY")
  T.eq("Bind records one connection", #ShimConnections(), 1)
  C4:Bind(ME, 10, CONSUMER, 1, "RELAY")
  T.eq("Bind is idempotent", #ShimConnections(), 1)

  local bound = C4:GetBoundConsumerDevices(ME, 10)
  T.eq("GetBoundConsumerDevices answers { [deviceId] = name }", at(bound, CONSUMER), "Hallway Switch")
  T.eq("a device id of 0 means the current device", at(C4:GetBoundConsumerDevices(0, 10), CONSUMER), "Hallway Switch")
  T.eq("our own provider binding reports us as the provider", C4:GetBoundProviderDevice(ME, 10), ME)

  local record = recordFor(ME, 10)
  T.eq("the record now reads bound", at(record, "isbound"), true)
  T.eq("boundconsumers carries the peer's id, binding and classes", {
    count = #(at(record, "boundconsumers") or {}),
    deviceid = at(record, "boundconsumers", 1, "deviceid"),
    bindingid = at(record, "boundconsumers", 1, "bindingid"),
    name = at(record, "boundconsumers", 1, "name"),
    class = at(record, "boundconsumers", 1, "boundclasses", 1),
  }, { count = 1, deviceid = CONSUMER, bindingid = 1, name = "Hallway Switch", class = "RELAY" })

  C4:Unbind(CONSUMER, 1)
  T.check(
    "Unbind drops the connection",
    #ShimConnections() == 0 and at(recordFor(ME, 10), "isbound") == false,
    T.show({ connections = #ShimConnections(), isbound = at(recordFor(ME, 10), "isbound") })
  )
end

--------------------------------------------------------------------------------
T.section("our binding as the consumer side")
do
  ShimResetDynamicBindings()
  ShimSetDevices({ [CONSUMER] = { deviceName = "Zigbee Coordinator" } })
  C4:AddDynamicBinding(12, "PROXY", false, "Temperature", "TEMPERATURE")
  C4:Bind(CONSUMER, 7000, ME, 12, "TEMPERATURE")

  local record = recordFor(ME, 12)
  T.eq(
    "the consumer record reads bound",
    { isbound = at(record, "isbound"), boundconsumers = at(record, "boundconsumers") },
    { isbound = true }
  )
  T.eq("boundprovider nests the peer under 'bound'", {
    deviceid = at(record, "boundprovider", "bound", "deviceid"),
    bindingid = at(record, "boundprovider", "bound", "bindingid"),
    name = at(record, "boundprovider", "bound", "name"),
  }, { deviceid = CONSUMER, bindingid = 7000, name = "Zigbee Coordinator" })
  T.eq("GetBoundProviderDevice answers the providing device id", C4:GetBoundProviderDevice(ME, 12), CONSUMER)
end

--------------------------------------------------------------------------------
T.section("removing a binding")
do
  ShimResetDynamicBindings()
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")
  C4:AddDynamicBinding(11, "CONTROL", true, "Pump", "RELAY")
  C4:Bind(ME, 10, CONSUMER, 1, "RELAY")
  C4:Bind(ME, 11, CONSUMER, 2, "RELAY")

  C4:RemoveDynamicBinding(10)
  T.falsy("remove drops the binding", recordFor(ME, 10))
  T.falsy("remove drops that binding's connections", C4:GetBoundConsumerDevices(ME, 10))
  T.check(
    "remove leaves the other binding wired",
    #ShimConnections() == 1 and at(recordFor(ME, 11), "isbound") == true,
    T.show({ connections = #ShimConnections(), isbound = at(recordFor(ME, 11), "isbound") })
  )
end

--------------------------------------------------------------------------------
T.section("static bindings and reset")
do
  ShimResetDynamicBindings()
  ShimSetStaticBindings({ { id = 1, type = "CONTROL", provider = false, name = "Serial", class = "SERIAL" } })
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")

  T.eq("the get methods return statics alongside dynamics", countBindings(ME), 2)
  T.eq(
    "a static binding keeps its own shape",
    { name = at(recordFor(ME, 1), "name"), type = at(recordFor(ME, 1), "type") },
    { name = "Serial", type = 1 }
  )

  local live = ShimDynamicBindings()
  T.truthy("the held table carries the declared binding before the reset", next(live))

  ShimResetDynamicBindings()
  T.check(
    "reset clears the dynamic bindings but not the statics",
    countBindings(ME) == 1 and recordFor(ME, 1) ~= nil,
    countBindings(ME)
  )
  T.check("reset clears in place, so a held table stays live", next(live) == nil and live == ShimDynamicBindings())

  ShimSetStaticBindings({})
  T.eq("seeding an empty set clears the statics", countBindings(ME), 0)
end

--------------------------------------------------------------------------------
T.section("the driver.xml manifest")
do
  ShimResetDynamicBindings()
  ShimSetStaticBindings({ { id = 5012, type = "PROXY", provider = true, name = "Humidity", class = "HUMIDITY" } })
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")

  local xml = C4:GetDriverConfigInfo("connections")
  T.contains("a declared connection is rendered under <id>", xml, "<id>5012</id>")
  T.contains("with the fields a controller returns alongside it", xml, "<connectionname>Humidity</connectionname>")
  T.excludes("a dynamic binding is not in the manifest", xml, "<id>10</id>")
  T.falsy("a section the shim does not model returns nil", C4:GetDriverConfigInfo("proxies"))

  C4:RemoveDynamicBinding(5012)
  T.falsy("removing a static connection drops the live binding", recordFor(ME, 5012))
  T.contains("but leaves it declared in the manifest", C4:GetDriverConfigInfo("connections"), "<id>5012</id>")
end

--------------------------------------------------------------------------------
T.section("device ids the controller does not resolve")
do
  ShimResetDynamicBindings()
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")

  -- The reference says a device id of 0 is the current device here too; a
  -- controller answers with nothing.
  T.eq("GetBindingsByDevice does not resolve device 0", countBindings(0), 0)
  T.eq("another device's bindings are not ours", countBindings(CONSUMER), 0)
end

--------------------------------------------------------------------------------
ShimResetDynamicBindings()
ShimSetStaticBindings({})
ShimResetDevices()

T.finish()
