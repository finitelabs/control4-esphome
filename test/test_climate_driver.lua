#!/usr/bin/env luajit
--- Unit tests for the esphome_climate driver's preset, scheduling, hold and
--- swing logic, driven through its RFP entry points against the C4 shim with
--- SendToProxy captured.
---
--- Run: ./run_test.sh test_climate_driver.lua --timeout 30
---
--- OnDriverInit is never called: its --#ifdef DRIVERCENTRAL arms are plain
--- comments in unpreprocessed source, so both would run and require
--- "cloud-client-byte". The RFP handlers under test do not need it.

-- Resolved against this file rather than the working directory: run_test.sh
-- cds into test/, make test runs from the repo root, and dofile takes a path
-- rather than going through LUA_PATH.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/esphome_climate/driver.lua"

---------------------------------------------------------------------------
-- Tiny assertion harness
---------------------------------------------------------------------------

local passed, failed = 0, 0
local currentTest = "?"

local function check(condition, description)
  if condition then
    passed = passed + 1
    print(string.format("  ok   - %s", description))
  else
    failed = failed + 1
    print(string.format("  FAIL - %s", description))
  end
end

local function checkEqual(actual, expected, description)
  local ok = actual == expected
  check(ok, description .. (ok and "" or string.format(" (expected %s, got %s)", tostring(expected), tostring(actual))))
end

local function test(name, fn)
  currentTest = name
  print("\n" .. name)
  local ok, err = pcall(fn)
  if not ok then
    failed = failed + 1
    print(string.format("  FAIL - threw: %s", tostring(err)))
  end
end

---------------------------------------------------------------------------
-- Load the driver and capture its proxy traffic
---------------------------------------------------------------------------

-- Properties the driver writes to during a state update. Director would have
-- created these from driver.xml; seed them so UpdateProperty is not noise.
Properties["Driver Status"] = ""
Properties["Driver Version"] = ""

-- OnDriverLateInit gates on CheckMinimumVersion, which reads driver config the
-- shim answers with nil. Return what driver.xml declares so the restore path is
-- reachable from a test.
function C4:GetDriverConfigInfo(key)
  local info = {
    minimum_os_version = "3.3.0",
    model = "ESPHome Climate",
    version = "test",
  }
  return info[key]
end

dofile(DRIVER)

local sent = {}
local originalSendToProxy = SendToProxy

function SendToProxy(idBinding, strCommand, tParams, strMessage)
  sent[#sent + 1] = { binding = idBinding, command = strCommand, params = tParams or {} }
end

local function resetSent()
  sent = {}
end

--- Most recent emission of a command, or nil.
local function lastSent(command)
  for i = #sent, 1, -1 do
    if sent[i].command == command then
      return sent[i]
    end
  end
end

--- Newest record for one binding, so a test can prove WHERE a value was
--- published rather than only that it was published at all.
local function lastSentOn(binding, command)
  for i = #sent, 1, -1 do
    if sent[i].binding == binding and sent[i].command == command then
      return sent[i]
    end
  end
end

--- Newest record for `command` that carries `key`. sendCapabilities emits several
--- DYNAMIC_CAPABILITIES_CHANGED messages, so lastSent() alone may return one
--- without the field.
local function lastSentWith(command, key)
  for i = #sent, 1, -1 do
    if sent[i].command == command and sent[i].params ~= nil and sent[i].params[key] ~= nil then
      return sent[i]
    end
  end
end

--- Decoded body of the most recent ENTITY_COMMAND (what went to the device).
local function lastCommandBody()
  local entry = lastSent("ENTITY_COMMAND")
  return entry and DeserializeSafe(entry.params.body) or nil
end

---------------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------------

local Mode = { OFF = 0, HEAT_COOL = 1, COOL = 2, HEAT = 3, FAN_ONLY = 4, DRY = 5 }
local Fan = { ON = 0, OFF = 1, AUTO = 2, LOW = 3, MEDIUM = 4, HIGH = 5, MIDDLE = 6, QUIET = 9 }
local Swing = { OFF = 0, BOTH = 1, VERTICAL = 2, HORIZONTAL = 3 }

local PROXY, ESPHOME = 5001, 5002

--- A Mitsubishi-shaped single-setpoint head: six modes, six fan speeds, all
--- four swing options.
local function singleSetpointEntity()
  return {
    key = 1,
    name = "Test Climate",
    supported_modes = { Mode.OFF, Mode.HEAT_COOL, Mode.COOL, Mode.HEAT, Mode.FAN_ONLY, Mode.DRY },
    supported_fan_modes = { Fan.AUTO, Fan.LOW, Fan.MEDIUM, Fan.HIGH, Fan.MIDDLE, Fan.QUIET },
    supported_swing_modes = { Swing.OFF, Swing.BOTH, Swing.VERTICAL, Swing.HORIZONTAL },
    visual_min_temperature = 16,
    visual_max_temperature = 31,
    visual_target_temperature_step = 1,
    supports_two_point_target_temperature = false,
    supports_current_humidity = false,
  }
end

--- A two-point thermostat, as the bundled dummy_climate.yaml reports itself.
local function dualSetpointEntity()
  local entity = singleSetpointEntity()
  entity.supports_two_point_target_temperature = true
  return entity
end

local function escapeXml(text)
  return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- Build the SET_PRESETS payload the proxy sends: a preset list whose fields
--- ride as escaped XML inside a preset_fields attribute.
--- @param presets table Array of { name = string, previous = string?, fields = table }
local function presetsXml(presets)
  local parts = { "<presets>" }
  for _, preset in ipairs(presets) do
    local fieldParts = { "<preset_fields>" }
    for id, value in pairs(preset.fields) do
      fieldParts[#fieldParts + 1] = string.format('<field id="%s" value="%s"/>', id, value)
    end
    fieldParts[#fieldParts + 1] = "</preset_fields>"
    parts[#parts + 1] = string.format(
      '<preset name="%s"%s preset_fields="%s"/>',
      preset.name,
      preset.previous and string.format(' previous_name="%s"', preset.previous) or "",
      escapeXml(table.concat(fieldParts))
    )
  end
  parts[#parts + 1] = "</presets>"
  return table.concat(parts)
end

--- Capabilities are published once per connection, so a test that needs to see
--- them must first drop the connection the way the bridge would.
local function disconnect()
  RFP.UPDATE_DISCONNECT(ESPHOME, "UPDATE_DISCONNECT", {})
end

local function updateState(entity, state)
  RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", { entity = entity, state = state })
end

--- Same as updateState, but through the real bridge->child serialization
--- (SerializeSafe/DeserializeSafe), the only path a NaN or infinity reading has
--- to survive.
local function updateStateSerialized(entity, state)
  RFP.UPDATE_STATE(ESPHOME, "UPDATE_STATE", { entity = SerializeSafe(entity), state = SerializeSafe(state) })
end

--- Put the driver back into "not holding". Hold notifications are edge
--- triggered, so a test asserting that a hold ENGAGES must start from Off or it
--- sees nothing and blames the driver.
local function clearHold()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Off" })
  resetSent()
end

local function setPresets(presets)
  RFP.SET_PRESETS(PROXY, "SET_PRESETS", { XML = presetsXml(presets) })
end

--- Forget any scheduled preset an earlier test left in force, the way deleting
--- the schedule does, so the next SET_EVENT is a genuine change rather than
--- the proxy repeating itself.
local function clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

test("Swing selector is published as an Extras section", function()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })

  local caps = nil
  for _, entry in ipairs(sent) do
    if entry.command == "DYNAMIC_CAPABILITIES_CHANGED" and entry.params.HAS_EXTRAS ~= nil then
      caps = entry
    end
  end
  check(caps ~= nil and caps.params.HAS_EXTRAS == true, "HAS_EXTRAS flipped on at runtime")

  local setup = lastSent("EXTRAS_SETUP_CHANGED")
  check(setup ~= nil, "EXTRAS_SETUP_CHANGED emitted")
  if setup then
    local xml = setup.params.XML
    check(xml:find('command="SET_MODE_SWING"', 1, true) ~= nil, "selector invokes SET_MODE_SWING")
    check(xml:find('value="Vertical"', 1, true) ~= nil, "Vertical offered")
    check(xml:find('value="Horizontal"', 1, true) ~= nil, "Horizontal offered")
    check(xml:find('value="Both"', 1, true) ~= nil, "Both offered")
  end

  check(lastSent("CONNECTION") ~= nil, "CONNECTION announced so the proxy resends presets")
end)

test("Swing selection reaches the device as a swing_mode command", function()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL })
  resetSent()

  RFP.SET_MODE_SWING(PROXY, "SET_MODE_SWING", { value = "Vertical" })

  local body = lastCommandBody()
  check(body ~= nil, "a device command was sent")
  if body then
    check(body.has_swing_mode == true, "has_swing_mode set")
    checkEqual(body.swing_mode, Swing.VERTICAL, "swing_mode is VERTICAL")
  end
  check(lastSent("EXTRAS_STATE_CHANGED") ~= nil, "extras state echoed so the UI settles")
end)

test("Applying a preset sends every field in one command", function()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({
    {
      name = "Movie Night",
      fields = { hvac_mode = "Cool", single_setpoint_c = "22", fan_mode = "Quiet", swing = "Vertical" },
    },
  })
  resetSent()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Movie Night" })

  local body = lastCommandBody()
  check(body ~= nil, "a device command was sent")
  if body then
    checkEqual(body.mode, Mode.COOL, "mode COOL")
    checkEqual(body.target_temperature, 22, "setpoint 22C")
    checkEqual(body.fan_mode, Fan.QUIET, "fan QUIET")
    checkEqual(body.swing_mode, Swing.VERTICAL, "swing VERTICAL")
  end
  -- The device's own report is what announces a preset, not the command going
  -- out, so nothing is claimed until the device confirms.
  check(lastSent("PRESET_CHANGED") == nil, "nothing announced before the device confirms")
  updateState(
    singleSetpointEntity(),
    { mode = Mode.COOL, target_temperature = 22, fan_mode = Fan.QUIET, swing_mode = Swing.VERTICAL }
  )
  local changed = lastSent("PRESET_CHANGED")
  check(changed ~= nil and changed.params.NAME == "Movie Night", "the confirming report names the preset")
end)

test("Two-point devices get low/high, never target_temperature", function()
  resetSent()
  updateState(
    dualSetpointEntity(),
    { mode = Mode.HEAT_COOL, target_temperature_low = 20, target_temperature_high = 24 }
  )
  setPresets({
    { name = "Comfort", fields = { hvac_mode = "Auto", heat_setpoint_c = "20", cool_setpoint_c = "24" } },
  })
  resetSent()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Comfort" })

  local body = lastCommandBody()
  check(body ~= nil, "a device command was sent")
  if body then
    checkEqual(body.target_temperature_low, 20, "heat setpoint -> target_temperature_low")
    checkEqual(body.target_temperature_high, 24, "cool setpoint -> target_temperature_high")
    check(body.target_temperature == nil, "single target_temperature NOT sent to a two-point device")
  end
end)

test("The setpoint model follows what the entity declares", function()
  -- supports_two_point_target_temperature is the device's own declaration; a
  -- mini-split offers HEAT and COOL while holding one target. Auto rides on hvac_modes.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })

  local caps = nil
  for _, entry in ipairs(sent) do
    if entry.command == "DYNAMIC_CAPABILITIES_CHANGED" and entry.params.HAS_SINGLE_SETPOINT ~= nil then
      caps = entry.params
    end
  end
  check(caps ~= nil, "setpoint capabilities published")
  if caps then
    check(caps.HAS_SINGLE_SETPOINT == true, "one-target device reports SINGLE even with heat+cool modes")
    check(caps.CAN_HEAT == false, "C4 requires can_heat false alongside has_single_setpoint")
    check(caps.CAN_COOL == false, "C4 requires can_cool false alongside has_single_setpoint")
    check(caps.CAN_AUTO == false, "C4 requires can_do_auto false alongside has_single_setpoint")
  end

  -- A genuine two-point device must keep its pair.
  disconnect()
  resetSent()
  updateState(
    dualSetpointEntity(),
    { mode = Mode.HEAT_COOL, target_temperature_low = 20, target_temperature_high = 24 }
  )
  local dual = nil
  for _, entry in ipairs(sent) do
    if entry.command == "DYNAMIC_CAPABILITIES_CHANGED" and entry.params.HAS_SINGLE_SETPOINT ~= nil then
      dual = entry.params
    end
  end
  check(dual ~= nil and dual.HAS_SINGLE_SETPOINT == false, "supports_two_point device stays DUAL")
  -- A two-point device keeps its deadband; it must not be flattened.
  check(dual ~= nil and dual.CAN_AUTO == true, "a real two-point device keeps heat/cool/auto")
end)

test("Preset field template is pushed and matches the setpoint mode", function()
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })

  local tpl = lastSent("PRESET_FIELDS_CHANGED")
  check(tpl ~= nil, "PRESET_FIELDS_CHANGED emitted")
  if tpl then
    local xml = tpl.params.XML
    -- One declared target: the template must carry single_setpoint, or the editor
    -- offers a heat/cool pair the device silently halves.
    check(xml:find('id="single_setpoint_c"', 1, true) ~= nil, "single_setpoint_c offered")
    check(xml:find('id="single_setpoint_f"', 1, true) ~= nil, "single_setpoint_f offered")
    check(xml:find("heat_setpoint", 1, true) == nil, "heat_setpoint NOT offered in single mode")
    check(xml:find("cool_setpoint", 1, true) == nil, "cool_setpoint NOT offered in single mode")
    check(xml:find('id="hvac_mode"', 1, true) ~= nil, "hvac_mode offered")
    check(xml:find('id="fan_mode"', 1, true) ~= nil, "fan_mode offered")
    check(xml:find('id="swing"', 1, true) ~= nil, "swing offered")
    check(xml:find('value="Quiet"', 1, true) ~= nil, "device-specific Quiet fan speed present")
    -- HEAT_COOL and AUTO both map to "Auto"; it must appear once, not twice.
    local count = select(2, xml:gsub('value="Auto"', ""))
    checkEqual(count, 2, "Auto appears once per list (hvac_mode + fan_mode), not duplicated")
    check(xml:find('min="16"', 1, true) ~= nil, "range taken from the device (16C)")
  end

  -- A real two-point device gets the opposite template.
  disconnect()
  resetSent()
  updateState(
    dualSetpointEntity(),
    { mode = Mode.HEAT_COOL, target_temperature_low = 20, target_temperature_high = 24 }
  )
  local dualTpl = lastSent("PRESET_FIELDS_CHANGED")
  check(dualTpl ~= nil, "template pushed for the two-point device too")
  if dualTpl then
    local xml = dualTpl.params.XML
    check(xml:find('id="heat_setpoint_c"', 1, true) ~= nil, "heat_setpoint_c offered when genuinely dual")
    check(xml:find('id="cool_setpoint_c"', 1, true) ~= nil, "cool_setpoint_c offered when genuinely dual")
    check(xml:find("single_setpoint", 1, true) == nil, "single_setpoint NOT offered when dual")
  end
end)

test("A lone Off swing mode is withheld from the preset template", function()
  disconnect()
  resetSent()
  local entity = singleSetpointEntity()
  -- A head advertising only CLIMATE_SWING_OFF gets no Extras selector; the preset
  -- template must agree or the editor shows a Swing dropdown with one entry.
  entity.supported_swing_modes = { Swing.OFF }
  updateState(entity, { mode = Mode.COOL, target_temperature = 22 })

  local tpl = lastSent("PRESET_FIELDS_CHANGED")
  check(tpl ~= nil, "PRESET_FIELDS_CHANGED emitted")
  if tpl then
    local xml = tpl.params.XML
    check(xml:find('id="swing"', 1, true) == nil, "swing withheld when only Off is offered")
    check(xml:find('id="fan_mode"', 1, true) ~= nil, "fan_mode still offered")
    check(xml:find('id="hvac_mode"', 1, true) ~= nil, "hvac_mode still offered")
  end
end)

test("Humidity publishes on a binding outside the library's managed range", function()
  disconnect()
  resetSent()
  local entity = singleSetpointEntity()
  entity.supports_current_humidity = true
  updateState(entity, { mode = Mode.COOL, target_temperature = 22, current_temperature = 21, current_humidity = 57 })

  -- 5012 is PROXY_BINDING_START in src/lib/bindings.lua, so a static connection
  -- there sits on the first id of a range restoreBindings() is entitled to
  -- delete. 5011 is above CONTROL_BINDING_END and below that start, so it is in
  -- no managed range at all, the way Temperature 5010 already is.
  local humidity = lastSentOn(5011, "VALUE_CHANGED")
  check(humidity ~= nil, "humidity published on 5011")
  if humidity then
    checkEqual(humidity.params.VALUE, "57", "carries the current humidity")
  end
  check(lastSentOn(5012, "VALUE_CHANGED") == nil, "nothing published on the managed-range id")
  check(lastSentOn(5010, "VALUE_CHANGED") ~= nil, "temperature still publishes on 5010")
end)

test("Heat/cool preset fields collapse to the device's single setpoint", function()
  -- A preset saved with a heat/cool pair, before the device was declared
  -- single-setpoint, must collapse onto the one target.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22.5 })
  setPresets({
    { name = "Chill", fields = { hvac_mode = "Cool", heat_setpoint_c = "19", cool_setpoint_c = "23" } },
  })
  resetSent()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Chill" })

  local body = lastCommandBody()
  check(body ~= nil, "a device command was sent")
  if body then
    checkEqual(body.target_temperature, 23, "Cool preset uses the cool setpoint")
    check(body.target_temperature_low == nil, "no low setpoint on a single-setpoint device")
    check(body.target_temperature_high == nil, "no high setpoint on a single-setpoint device")
  end
end)

test("A Heat preset uses the heat setpoint on the same device", function()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.HEAT, target_temperature = 21 })
  setPresets({
    { name = "Warm", fields = { hvac_mode = "Heat", heat_setpoint_c = "19", cool_setpoint_c = "23" } },
  })
  resetSent()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Warm" })

  local body = lastCommandBody()
  check(body ~= nil, "a device command was sent")
  if body then
    checkEqual(body.target_temperature, 19, "Heat preset uses the heat setpoint")
  end
end)

test("Parses a verbatim SET_PRESETS payload captured from a real controller", function()
  -- Kept byte-for-byte: real attribute escaping, the proxy's auto-inserted
  -- second temperature scale, and a preset omitting hvac_mode.
  local REAL = '<presets><preset name="Finally" preset_fields="&lt;preset_fields&gt;'
    .. "&lt;field id=&quot;cool_setpoint_f&quot; value=&quot;72&quot;/&gt;"
    .. "&lt;field id=&quot;fan_mode&quot; value=&quot;Auto&quot;/&gt;"
    .. "&lt;field id=&quot;cool_setpoint_c&quot; value=&quot;22&quot;/&gt;"
    .. '&lt;/preset_fields&gt;"/></presets>'

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 24 })
  RFP.SET_PRESETS(PROXY, "SET_PRESETS", { XML = REAL })
  resetSent()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Finally" })

  local body = lastCommandBody()
  check(body ~= nil, "the captured preset applies")
  if body then
    -- Celsius wins over the auto-inserted Fahrenheit: 72F would round to 22.2C.
    checkEqual(body.target_temperature, 22, "uses cool_setpoint_c (22C), not 72F round-tripped")
    checkEqual(body.fan_mode, Fan.AUTO, "fan Auto")
    check(body.mode == nil, "no mode sent when the preset omits hvac_mode")
  end
end)

test("SET_EVENTS is stored, not applied (the proxy keeps time)", function()
  -- The proxy keeps the schedule clock: it announces each event through SET_EVENT
  -- and is silent at a boundary that re-selects the preset in force. The list is
  -- kept only to know a schedule exists, which decides whether holds are offered.
  local REAL = '<events><event preset="Cool after work" weekday="5" hour="15" minute="5"/></events>'

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Cool after work", fields = { hvac_mode = "Cool", cool_setpoint_c = "24" } },
  })
  clearSchedule()
  resetSent()

  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = REAL })

  check(lastCommandBody() == nil, "SET_EVENTS alone sends no device command")
  local modes = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  check(modes ~= nil and modes.params.MODES ~= "", "but a schedule existing is what offers the hold modes")
end)

test("REGRESSION: the proxy's next event applies its preset and clears the hold", function()
  -- A hold raised by hand must be released when the proxy announces the next event.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Cool after work", fields = { hvac_mode = "Cool", cool_setpoint_c = "24" } },
    { name = "Evening", fields = { hvac_mode = "Cool", cool_setpoint_c = "26" } },
  })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Cool after work" weekday="5" hour="15" minute="5"/>'
      .. '<event preset="Evening" weekday="5" hour="20" minute="0"/></events>',
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Cool after work" })
  -- The device confirms the scheduled preset.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 24 })
  clearHold()

  -- User diverges by hand; the hold engages.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 21 })
  local engaged = lastSent("HOLD_MODE_CHANGED")
  check(engaged ~= nil and engaged.params.MODE ~= "Off", "manual change engaged a hold")
  resetSent()

  -- The proxy announces the next event.
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Evening" })

  local body = lastCommandBody()
  check(body ~= nil, "the head was commanded at the event")
  if body then
    checkEqual(body.target_temperature, 26, "the announced preset's setpoint applied")
  end
  local hold = lastSent("HOLD_MODE_CHANGED")
  check(hold ~= nil and hold.params.MODE == "Off", "hold released at the next event")
end)

test("A malformed schedule event is skipped, not fatal", function()
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Ghost"/><event preset="Good" weekday="2" hour="7" minute="30"/></events>',
  })
  check(true, "handler survived a malformed event")
end)

test("SET_EVENT applies the preset the proxy announces", function()
  -- SET_EVENT arrives on save and at every boundary where the scheduled preset
  -- changes; nothing else tells the driver a boundary has passed.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Morning" weekday="1" hour="6" minute="0"/></events>',
  })
  clearHold()

  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
  local body = lastCommandBody()
  check(body ~= nil and body.target_temperature == 21, "SET_EVENT commands the announced preset")

  -- And it is tracked, or hold reconciliation has no reference.
  updateState(singleSetpointEntity(), { mode = Mode.HEAT, target_temperature = 21 })
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 30 })
  local held = lastSent("HOLD_MODE_CHANGED")
  check(held ~= nil and held.params.MODE ~= "Off", "it is tracked as the scheduled preset")
end)

test("Diverging from the scheduled preset holds, returning to it releases", function()
  local entity = singleSetpointEntity()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
  updateState(entity, { mode = Mode.HEAT, target_temperature = 21 })
  clearHold()

  -- The user nudges the setpoint away from the scheduled preset.
  resetSent()
  updateState(entity, { mode = Mode.HEAT, target_temperature = 25 })
  local held = lastSent("HOLD_MODE_CHANGED")
  check(held ~= nil and held.params.MODE == "Until Next", "diverging trips 'Until Next'")

  -- State comes back onto the preset.
  resetSent()
  updateState(entity, { mode = Mode.HEAT, target_temperature = 21 })
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released ~= nil and released.params.MODE == "Off", "returning releases the hold")
end)

test("REGRESSION: zero-valued enums are omitted by protobuf, not unknown", function()
  -- Off/Off preset matched against a frame omitting mode and swing_mode, which is
  -- what the wire carries at their zero values. Absence must read as zero, not unknown.
  local entity = singleSetpointEntity()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "All Off", fields = { hvac_mode = "Off", swing = "Off" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "All Off" })

  resetSent()
  updateState(entity, { current_temperature = 22.5 }) -- no mode, no swing_mode

  local held = lastSent("HOLD_MODE_CHANGED")
  check(held == nil or held.params.MODE == "Off", "state matching the preset does NOT trip a hold")

  local changed = lastSent("PRESET_CHANGED")
  check(changed ~= nil and changed.params.NAME == "All Off", "preset still reported as active")
end)

test("Renaming a preset keeps the schedule attached without re-running it", function()
  local entity = singleSetpointEntity()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })

  -- Renamed in the C4 UI; the proxy resends the list carrying previous_name.
  resetSent()
  setPresets({
    { name = "Early", previous = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  check(lastCommandBody() == nil, "a rename alone does NOT re-run the preset")

  -- Tracking must have followed the rename. Editing the renamed preset's VALUES
  -- re-applies it only if the driver still considers it the active one.
  resetSent()
  setPresets({
    { name = "Early", fields = { hvac_mode = "Heat", single_setpoint_c = "19" } },
  })
  local body = lastCommandBody()
  check(body ~= nil and body.target_temperature == 19, "still tracked as active under the new name")
end)

test("REGRESSION: adding a schedule must not run the preset immediately", function()
  -- SET_PRESETS arrives on any list change, including attaching a schedule event;
  -- only a real value change may re-apply.
  local entity = singleSetpointEntity()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "Evening", fields = { hvac_mode = "Cool", cool_setpoint_c = "20" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Evening" })

  -- User schedules a second preset; the list is resent unchanged in values.
  resetSent()
  setPresets({
    { name = "Evening", fields = { hvac_mode = "Cool", cool_setpoint_c = "20" } },
    { name = "Bedtime", fields = { hvac_mode = "Cool", cool_setpoint_c = "18" } },
  })
  check(lastCommandBody() == nil, "scheduling another preset sends NO device command")

  -- And the user's own change must survive the next list resend.
  resetSent()
  RFP.SET_SETPOINT_COOL(PROXY, "SET_SETPOINT_COOL", { CELSIUS = "25" })
  resetSent()
  setPresets({
    { name = "Evening", fields = { hvac_mode = "Cool", cool_setpoint_c = "20" } },
    { name = "Bedtime", fields = { hvac_mode = "Cool", cool_setpoint_c = "18" } },
  })
  check(lastCommandBody() == nil, "a manual change is not snapped back by a list resend")
end)

test("Editing the ACTIVE preset's values does re-apply it", function()
  local entity = singleSetpointEntity()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "Evening", fields = { hvac_mode = "Cool", cool_setpoint_c = "20" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Evening" })

  resetSent()
  setPresets({
    { name = "Evening", fields = { hvac_mode = "Cool", cool_setpoint_c = "17" } },
  })
  local body = lastCommandBody()
  check(body ~= nil, "an edit to the running preset takes effect immediately")
  if body then
    checkEqual(body.target_temperature, 17, "new value applied")
  end
end)

test("An unknown preset name is refused, not silently applied", function()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({ { name = "Known", fields = { hvac_mode = "Heat" } } })
  resetSent()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Nonexistent" })
  check(lastCommandBody() == nil, "no device command sent for an unknown preset")
end)

test("Preset setpoint fields follow the modes the device reports", function()
  -- Each setpoint field is gated on the mode that would use it; can_preset is
  -- off in driver.xml and raised here once an entity is attached.
  disconnect()
  resetSent()
  local coolOnly = dualSetpointEntity()
  coolOnly.supported_modes = { Mode.OFF, Mode.COOL }
  updateState(coolOnly, { mode = Mode.COOL, target_temperature_high = 24 })

  local tpl = lastSent("PRESET_FIELDS_CHANGED")
  check(tpl ~= nil, "PRESET_FIELDS_CHANGED emitted")
  if tpl then
    local xml = tpl.params.XML
    check(xml:find("cool_setpoint_c", 1, true) ~= nil, "cool-capable device is offered a cool setpoint")
    check(xml:find("heat_setpoint", 1, true) == nil, "cool-only device is NOT offered a heat setpoint")
  end

  local caps = nil
  for _, entry in ipairs(sent) do
    if entry.command == "DYNAMIC_CAPABILITIES_CHANGED" and entry.params.CAN_PRESET ~= nil then
      caps = entry.params
    end
  end
  check(caps ~= nil and caps.CAN_PRESET == true, "presets enabled at runtime once an entity attaches")
end)

local function TableContainsValue(t, v)
  for _, x in ipairs(t) do
    if x == v then
      return true
    end
  end
  return false
end

test("An unrelated state report between apply and confirm does not clear the preset", function()
  -- matchAnyPreset runs on every state report, and an ambient push can land
  -- between the command and the device moving.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Cool 18", fields = { hvac_mode = "Cool", single_setpoint_c = "18" } } })

  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Cool 18" })
  -- Ambient temperature report: the setpoint has NOT moved yet.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, current_temperature = 24 })
  -- Now the device confirms.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 18 })

  local announced = {}
  for _, entry in ipairs(sent) do
    if entry.command == "PRESET_CHANGED" then
      announced[#announced + 1] = entry.params.NAME
    end
  end
  check(
    not TableContainsValue(announced, "None"),
    "the app is never told 'no preset' while the requested one is landing: " .. table.concat(announced, ", ")
  )
end)

test("A preset is announced once, by the device's report", function()
  -- The state report is the only announcer; applyPreset says nothing.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Cool 18", fields = { hvac_mode = "Cool", single_setpoint_c = "18" } } })

  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Cool 18" })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 18 })

  local announced = 0
  for _, entry in ipairs(sent) do
    if entry.command == "PRESET_CHANGED" and entry.params.NAME == "Cool 18" then
      announced = announced + 1
    end
  end
  checkEqual(announced, 1, "PRESET_CHANGED sent once across apply and confirmation")
end)

test("PRESET_CHANGED is sent on transitions only, including leaving a preset", function()
  -- Report the active preset on transitions only, including the move off it.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Cool 22", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local first = lastSent("PRESET_CHANGED")
  check(first ~= nil and first.params.NAME == "Cool 22", "entering a preset reports it")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  check(lastSent("PRESET_CHANGED") == nil, "staying in the preset sends nothing further")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 25 })
  local left = lastSent("PRESET_CHANGED")
  check(left ~= nil and left.params.NAME == "None", "leaving the preset clears it")
end)

test("Device supplied fan mode names are escaped before reaching the preset XML", function()
  -- supported_custom_fan_modes comes from device YAML; an unescaped & or quote
  -- would break the attribute and the whole preset editor.
  disconnect()
  resetSent()
  local entity = singleSetpointEntity()
  entity.supported_custom_fan_modes = { 'Turbo & "Boost"', "Eco<mode>" }
  updateState(entity, { mode = Mode.COOL, target_temperature = 22 })

  local tpl = lastSent("PRESET_FIELDS_CHANGED")
  check(tpl ~= nil, "PRESET_FIELDS_CHANGED emitted")
  if tpl then
    local xml = tpl.params.XML
    check(xml:find("Turbo &amp; &quot;Boost&quot;", 1, true) ~= nil, "ampersand and quotes escaped")
    check(xml:find("Eco&lt;mode&gt;", 1, true) ~= nil, "angle brackets escaped")
    check(xml:find('value="Turbo & "', 1, true) == nil, "no raw ampersand left in an attribute")
    -- The escaped template has to survive a round trip through the parser the
    -- driver uses on the way back in.
    local parsed = C4:ParseXml(xml)
    check(parsed ~= nil, "escaped template still parses")
  end
end)

test("REGRESSION: a persisted schedule is restored without OnDriverLateInit throwing", function()
  -- Guards the restore path resolving SCHEDULE to a global when the local is
  -- declared below OnDriverLateInit.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({ { name = "Night", fields = { hvac_mode = "Heat", single_setpoint_c = "18" } } })

  -- Persist a schedule the way RFP.SET_EVENTS does, then reload.
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Night" weekday="1" hour="6" minute="30"/></events>',
  })
  check(C4:PersistGetValue("Schedule") ~= nil, "schedule was persisted")

  local ok, err = pcall(OnDriverLateInit)
  check(ok, "OnDriverLateInit does not throw with a persisted schedule" .. (ok and "" or ": " .. tostring(err)))
end)

test("A preset that constrains nothing is not stored", function()
  -- An all-empty preset parses to {} and would match every state.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Empty", fields = { hvac_mode = "", single_setpoint_c = "" } },
  })

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.HEAT, target_temperature = 30 })
  local announced = lastSent("PRESET_CHANGED")
  local name = announced and announced.params.NAME or nil
  check(name ~= "Empty", "a preset constraining nothing is never announced as active")
end)

test("A hold the user raised survives the next state report", function()
  -- reconcileHold runs on every report. A hold raised from the UI without a
  -- change leaves state matching the preset; an unconditional release cancelled it.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Cool 22", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Cool 22" })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  clearHold()

  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Until Next" })
  resetSent()
  -- An ambient temperature push: state still matches the scheduled preset.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, current_temperature = 24 })
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released == nil, "the user's hold is not cancelled by a matching report")
end)

test("Water heaters are not offered presets", function()
  -- The preset template is climate-shaped and not published for water heaters;
  -- CAN_PRESET must not be declared for them either.
  local wh = singleSetpointEntity()
  wh.is_water_heater = true
  disconnect()
  resetSent()
  updateState(wh, { mode = Mode.HEAT, target_temperature = 50 })

  local sawPresetCap = nil
  for _, entry in ipairs(sent) do
    if entry.command == "DYNAMIC_CAPABILITIES_CHANGED" and entry.params.CAN_PRESET ~= nil then
      sawPresetCap = entry.params.CAN_PRESET
    end
  end
  checkEqual(sawPresetCap, false, "CAN_PRESET is withheld from a water heater")
  check(lastSent("PRESET_FIELDS_CHANGED") == nil, "no preset template is published either")
end)

test("Releasing a hold with no schedule clears the held preset", function()
  -- HOLD_PRESET must clear on release even with no schedule, or a later edit re-applies it.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Manual", fields = { hvac_mode = "Cool", single_setpoint_c = "20" } },
  })
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Manual" })
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Off" })

  resetSent()
  -- Edit that preset's values. With HOLD_PRESET still set this re-applied it.
  setPresets({
    { name = "Manual", fields = { hvac_mode = "Cool", single_setpoint_c = "28" } },
  })
  check(lastCommandBody() == nil, "an edit after release does not command the device")
end)

test("Preset setpoints are snapped to the entity's own step", function()
  -- Template authors at 0.5 C; a device quantising to 1 C echoes 22 for 21.5 and
  -- matchPreset allows 0.25 C, so the echo must be snapped before comparing.
  local entity = singleSetpointEntity()
  entity.visual_target_temperature_step = 1
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Half", fields = { hvac_mode = "Cool", single_setpoint_c = "21.5" } },
  })
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Half" })

  local body = lastCommandBody()
  check(body ~= nil, "the preset commanded the device")
  if body then
    checkEqual(body.target_temperature, 22, "21.5 snapped onto the device's 1 degree step")
  end
end)

--- Schedule XML for one or more events; weekday and time are never inspected here.
local function eventsXml(entries)
  local parts = { "<events>" }
  for _, e in ipairs(entries) do
    parts[#parts + 1] =
      string.format('<event preset="%s" weekday="1" hour="%d" minute="%d"/>', e.preset, e.hour or 6, e.minute or 0)
  end
  parts[#parts + 1] = "</events>"
  return table.concat(parts)
end

test("An event naming a preset not yet delivered is applied when the list arrives", function()
  -- The proxy can announce a preset the driver does not have yet (SET_PRESETS
  -- resends only once a device connects); the name is kept and applied on arrival.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Later" } }) })

  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Later" })
  check(lastCommandBody() == nil, "an unknown preset commands nothing when announced")

  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Later", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } },
  })
  local body = lastCommandBody()
  check(body ~= nil, "the announced preset is applied once it is known")
  if body then
    checkEqual(body.target_temperature, 26, "with the announced preset's value")
  end
end)

test("An event announced while the device is down is applied on reconnect", function()
  -- The bridge rejects ENTITY_COMMAND while disconnected, and a plain SET_PRESETS
  -- resend is not a signature change; the announced name must be kept.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Known", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Known" } }) })

  disconnect()
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Known" })
  check(lastCommandBody() == nil, "nothing is commanded at a device that is down")

  -- Reconnect alone must run it. Deliberately no SET_PRESETS here: the presets
  -- never left memory, so nothing would make the proxy resend them.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  check(body ~= nil, "the announced preset is applied once the device is back")
  if body then
    checkEqual(body.target_temperature, 26, "with the scheduled preset's value")
  end
end)

test("A pending event is not consumed while the device is still down", function()
  -- SET_PRESETS can arrive while the device is offline; consuming the pending
  -- event there hands the command to a bridge that only logs it.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Late" } }) })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Late" })

  disconnect()
  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "21" } },
    { name = "Late", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } },
  })
  check(lastCommandBody() == nil, "nothing is commanded at a device that is down")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  check(body ~= nil, "the pending event survives the outage and runs on reconnect")
  if body then
    checkEqual(body.target_temperature, 26, "with the announced preset's value")
  end
end)

test("A rename carries a pending event with it", function()
  -- A pending event under the old name must follow a rename, or the list that
  -- renames it can never satisfy it.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Before" } }) })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Before" })

  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "After", previous = "Before", fields = { hvac_mode = "Cool", single_setpoint_c = "27" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "After" } }) })

  local body = lastCommandBody()
  check(body ~= nil, "the renamed preset still runs its pending event")
  if body then
    checkEqual(body.target_temperature, 27, "with the renamed preset's value")
  end
end)

test("A preset still matches after the device echoes a CLAMPED setpoint", function()
  -- Same as the snapped case, for clamping: a preset above the device's range
  -- echoes back at the clamp boundary and must still match.
  local entity = singleSetpointEntity()
  entity.visual_max_temperature = 30
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.COOL, target_temperature = 22 })
  -- 35 is above the device maximum; it can only ever come back as 30.
  setPresets({ { name = "TooHot", fields = { hvac_mode = "Cool", single_setpoint_c = "35" } } })

  resetSent()
  updateState(entity, { mode = Mode.COOL, target_temperature = 30 })
  local announced = lastSent("PRESET_CHANGED")
  check(announced ~= nil and announced.params.NAME == "TooHot", "the preset matches its own clamped value")
end)

test("Setpoints snap on a device that reports only target_temperature_step", function()
  -- snapToStep must use the same visual_target_temperature_step ->
  -- target_temperature_step fallback as the resolution publisher.
  resetSent()
  local entity = singleSetpointEntity()
  entity.visual_target_temperature_step = nil
  entity.target_temperature_step = 1
  updateState(entity, { mode = Mode.COOL, target_temperature = 22 })

  setPresets({ { name = "Half", fields = { hvac_mode = "Cool", single_setpoint_c = "21.5" } } })
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Half" })
  local body = lastCommandBody()
  check(body ~= nil, "the preset is commanded")
  if body then
    checkEqual(body.target_temperature, 22, "snapped to the step the device does report")
  end
end)

test("Losing the device retracts the connection, not just ONLINE_CHANGED", function()
  -- CONNECTED = false must be sent on comms loss, or the proxy holds the device
  -- as connected for the rest of the session.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()

  disconnect()
  local conn = lastSent("CONNECTION")
  check(conn ~= nil, "a CONNECTION update is sent when the device is lost")
  if conn then
    checkEqual(tostring(conn.params.CONNECTED), "false", "and it retracts the connection")
  end
end)

test("Connection state is truthful at every stage of the lifecycle", function()
  -- CONNECTED must be sent false as well as true, or the proxy holds the device present forever.
  local function connectedNow()
    local c = lastSent("CONNECTION")
    return c and tostring(c.params.CONNECTED) or "none"
  end

  -- 1. Cold start, nothing ever seen.
  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  resetSent()
  OnDriverLateInit()
  checkEqual(connectedNow(), "false", "cold start declares the device absent")

  -- 2. The device shows up.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  checkEqual(connectedNow(), "true", "a live device declares present")

  -- 3. It goes away.
  resetSent()
  disconnect()
  checkEqual(connectedNow(), "false", "losing the device retracts presence")

  -- 4. It comes back.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  checkEqual(connectedNow(), "true", "reconnecting declares present again")

  -- 5. Driver reloads while the device is down. Nothing has connected since the
  --    reload, so the declaration at LateInit is the only thing speaking.
  dofile(DRIVER)
  resetSent()
  OnDriverLateInit()
  checkEqual(connectedNow(), "false", "a reload with the device down stays absent")
end)

test("Unbinding the device retracts the connection", function()
  -- Removing the ESPHome connection in Composer must also retract IS_CONNECTED.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()

  -- 5002 is ESPHOME_BINDING; isBound = false is the unbind.
  OBC[5002](5002, "ESPHOME", false)

  local conn = lastSent("CONNECTION")
  check(conn ~= nil, "an unbind declares a connection state")
  if conn then
    checkEqual(tostring(conn.params.CONNECTED), "false", "and it declares the device absent")
  end
end)

test("Rebinding the driver keeps the user's presets", function()
  -- Presets are proxy-owned configuration; a rebind (which an update cycles) must not clear them.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Keeper", fields = { hvac_mode = "Cool", single_setpoint_c = "24" } } })

  -- 5002 is ESPHOME_BINDING; false then true is the unbind/rebind an update does.
  OBC[5002](5002, "ESPHOME", false)
  OBC[5002](5002, "ESPHOME", true)

  check(C4:PersistGetValue("Presets") ~= nil, "the persisted preset list survives a rebind")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Keeper" })
  local body = lastCommandBody()
  check(body ~= nil, "and the preset still applies after the rebind")
  if body then
    checkEqual(body.target_temperature, 24, "with its saved value")
  end
end)

test("Schedule and presets both survive a reload during an outage", function()
  -- Presets must persist alongside the schedule: the proxy resends the list only
  -- once a device attaches, so a reload during an outage must still know them.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Survivor", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Survivor" } }) })

  -- Reload with the device still absent: no UPDATE_STATE, no SET_PRESETS.
  dofile(DRIVER)
  resetSent()
  OnDriverLateInit()

  check(C4:PersistGetValue("Schedule") ~= nil, "the schedule is persisted")
  check(C4:PersistGetValue("Presets") ~= nil, "and so is the preset list")

  -- The distinguishing claim: applyPreset works BY NAME with no SET_PRESETS resend.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Survivor" })
  local body = lastCommandBody()
  check(body ~= nil, "a persisted preset can be applied without the proxy resending it")
  if body then
    checkEqual(body.target_temperature, 26, "with the value it was saved with")
  end
end)

test("A driver that has never seen a device still reports itself offline", function()
  -- thermostatV2 starts IS_CONNECTED true unless has_connection_status is
  -- declared, so a fresh install must declare offline without a cached shape.
  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  resetSent()
  OnDriverLateInit()

  check(lastSent("DYNAMIC_CAPABILITIES_CHANGED") == nil, "no capabilities are invented")
  local conn = lastSent("CONNECTION")
  check(conn ~= nil, "but the connection state IS declared with no cache at all")
  if conn then
    checkEqual(tostring(conn.params.CONNECTED), "false", "declaring the device absent")
  end
end)

test("Heat engages on a water heater that has never stored a mode", function()
  -- persist:get returns an EMPTY sentinel, not nil; it must not restore as {} and be sent as an enum.
  C4:PersistDeleteValue("LastWaterHeaterMode")
  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  OnDriverLateInit()

  disconnect()
  local heater = singleSetpointEntity()
  heater.is_water_heater = true
  heater.supported_modes = { 0, 1 }
  updateState(heater, { mode = Mode.HEAT, target_temperature = 49 })

  resetSent()
  RFP.SET_MODE_HEAT(PROXY, "SET_MODE_HEAT")
  local body = lastCommandBody()
  check(body ~= nil, "a water heater command is sent")
  if body then
    checkEqual(type(body.mode), "number", "and the mode is an enum, not the persist sentinel table")
  end
end)

test("A device with nothing to put in Extras has the section withdrawn", function()
  -- HAS_EXTRAS must go false for a modeless water heater, or a stale Swing selector stays.
  disconnect()
  local bare = singleSetpointEntity()
  bare.supported_swing_modes = {}
  updateState(bare, { mode = Mode.COOL, target_temperature = 22 })

  local extras = lastSentWith("DYNAMIC_CAPABILITIES_CHANGED", "HAS_EXTRAS")
  check(extras ~= nil, "HAS_EXTRAS is published either way")
  if extras then
    checkEqual(tostring(extras.params.HAS_EXTRAS), "false", "and it is withdrawn when there are no extras")
  end
end)

test("A pending event is dropped when its schedule is deleted", function()
  -- With the schedule gone a pending announcement must be dropped, not fired later.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Ghost" } }) })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Ghost" })

  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })

  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Ghost", fields = { hvac_mode = "Cool", single_setpoint_c = "18" } },
  })
  check(lastCommandBody() == nil, "the orphaned announcement does not command the device")
end)

test("After a reload the proxy's re-announcement applies a preset still pending", function()
  -- A pending announcement need not survive a reload (the proxy re-announces on
  -- connect); the last APPLIED preset must, so that repeat is recognised.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Persisted" } }) })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Persisted" })

  dofile(DRIVER)
  local ok, err = pcall(OnDriverLateInit)
  check(ok, "OnDriverLateInit survives the restore" .. (ok and "" or ": " .. tostring(err)))

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Persisted", fields = { hvac_mode = "Cool", single_setpoint_c = "24" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Persisted" })
  local body = lastCommandBody()
  check(body ~= nil, "the re-announced preset is applied after the reload")
  if body then
    checkEqual(body.target_temperature, 24, "with its value")
  end
end)

test("A reload does not re-apply the preset the proxy re-announces", function()
  -- The proxy re-announces on every connection; a remembered last-applied preset stops a re-command.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  setPresets({ { name = "Comfort", fields = { single_setpoint_c = "22" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  check(lastCommandBody() ~= nil, "the first announcement applies the preset")
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })

  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  OnDriverLateInit()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  checkEqual(lastCommandBody(), nil, "the same announcement after a reload is left alone")

  -- Still tracked: a divergence is held against it.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 30 })
  local held = lastSent("HOLD_MODE_CHANGED")
  check(held ~= nil and held.params.MODE ~= "Off", "and it is still the scheduled preset for hold purposes")
  clearHold()
end)

test("A preset still matches after the device echoes the SNAPPED setpoint", function()
  -- 21.5 authored, 22 echoed: matching must snap the comparison side.
  local entity = singleSetpointEntity()
  entity.visual_target_temperature_step = 1
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Half", fields = { hvac_mode = "Cool", single_setpoint_c = "21.5" } } })

  resetSent()
  updateState(entity, { mode = Mode.COOL, target_temperature = 22 })
  local announced = lastSent("PRESET_CHANGED")
  check(announced ~= nil and announced.params.NAME == "Half", "the preset matches its own snapped value")
end)

test("One stale report after a scheduled event does not flap the hold", function()
  -- A report between command and confirmation describes the OLD state; exactly
  -- one is suppressed, more could wedge.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Evening", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Evening" } }) })
  clearHold()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Evening" })

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  check(lastSent("HOLD_MODE_CHANGED") == nil, "the stale report does not raise a hold")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  check(lastSent("HOLD_MODE_CHANGED") ~= nil, "a genuine divergence still raises one on the next report")
end)

test("A lone Off swing mode produces no Extras state echo", function()
  -- No EXTRAS_STATE_CHANGED for an Extras object that was never published (lone Off).
  local entity = singleSetpointEntity()
  entity.supported_swing_modes = { Swing.OFF }
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.COOL, target_temperature = 22, swing_mode = Swing.OFF })
  check(lastSent("EXTRAS_STATE_CHANGED") == nil, "no swing echo for a device with nowhere to swing")

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, swing_mode = Swing.VERTICAL })
  check(lastSent("EXTRAS_STATE_CHANGED") ~= nil, "a multi-mode device still echoes its vane state")
end)

test("A reading the device has not taken is not forwarded as a temperature", function()
  -- ESPHome reports NaN for an unsupplied float. Raw tables here; the
  -- SerializeSafe round trip is the test below.
  local NAN = 0 / 0
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), {
    mode = Mode.COOL,
    current_temperature = NAN,
    target_temperature = math.huge,
    current_humidity = NAN,
    target_humidity = -math.huge,
  })
  check(lastSent("TEMPERATURE_CHANGED") == nil, "no temperature for a NaN reading")
  check(lastSentOn(5010, "VALUE_CHANGED") == nil, "nothing on the temperature output either")
  check(lastSent("SINGLE_SETPOINT_CHANGED") == nil, "no setpoint for an infinite target")
  check(lastSent("HUMIDITY_CHANGED") == nil, "no humidity for a NaN reading")
  check(lastSentOn(5011, "VALUE_CHANGED") == nil, "nothing on the humidity output either")
  check(lastSent("HUMIDIFY_SETPOINT_CHANGED") == nil, "no humidity setpoint for an infinite target")

  -- A nudge from an unknown setpoint starts from zero; the sentinel must never seed it.
  resetSent()
  RFP.INC_SETPOINT_SINGLE(PROXY, "INC_SETPOINT_SINGLE")
  local body = lastCommandBody()
  check(body ~= nil, "the nudge still commands the device")
  if body then
    checkEqual(body.target_temperature, 16, "a nudge from an unknown setpoint is not seeded by the sentinel")
  end
end)

test("A NaN reading still is not forwarded once it has crossed the real bridge serialization", function()
  -- JSON has no NaN literal; a NaN must survive SerializeSafe or stateFloat reads
  -- an absent key and reports 0 for a declared dimension. Dimensions must be declared.
  local NAN = 0 / 0
  local entity = singleSetpointEntity()
  entity.supports_current_temperature = true
  entity.supports_current_humidity = true
  entity.supports_target_humidity = true
  disconnect()
  resetSent()
  updateStateSerialized(entity, {
    mode = Mode.COOL,
    current_temperature = NAN,
    target_temperature = math.huge,
    current_humidity = NAN,
    target_humidity = -math.huge,
  })
  check(lastSent("TEMPERATURE_CHANGED") == nil, "no temperature for a NaN reading, once serialized")
  check(lastSent("SINGLE_SETPOINT_CHANGED") == nil, "no setpoint for an infinite target, once serialized")
  check(lastSent("HUMIDITY_CHANGED") == nil, "no humidity for a NaN reading, once serialized")
  check(lastSent("HUMIDIFY_SETPOINT_CHANGED") == nil, "no humidity setpoint for an infinite target, once serialized")
end)

test("Deleting the schedule releases the hold it was held against", function()
  -- Emptying the schedule must forget the scheduled preset and release the hold.
  local entity = singleSetpointEntity()
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Morning" weekday="1" hour="6" minute="0"/></events>',
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
  updateState(entity, { mode = Mode.HEAT, target_temperature = 21 })
  clearHold()

  updateState(entity, { mode = Mode.HEAT, target_temperature = 25 })
  local held = lastSent("HOLD_MODE_CHANGED")
  check(held ~= nil and held.params.MODE == "Until Next", "diverging from the schedule holds")

  -- The user deletes every event.
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released ~= nil and released.params.MODE == "Off", "an emptied schedule releases the hold")

  -- Nothing is left to diverge from, so a further change raises no hold...
  resetSent()
  updateState(entity, { mode = Mode.HEAT, target_temperature = 27 })
  check(lastSent("HOLD_MODE_CHANGED") == nil, "no hold is raised against a deleted schedule")

  -- ...and releasing a hold has nothing to re-apply.
  resetSent()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Off" })
  check(lastCommandBody() == nil, "Hold Off no longer re-applies the deleted preset")
end)

--- A schedule with one event, a preset to hold, and the hold cleared to a known
--- Off so an engaging hold is observable.
local function heldUnderSchedule(mode)
  local entity = singleSetpointEntity()
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Morning" weekday="1" hour="6" minute="0"/></events>',
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
  updateState(entity, { mode = Mode.HEAT, target_temperature = 21 })
  clearHold()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = mode })
end

test("Deleting the schedule releases even the hold the user raised", function()
  -- An "until next" hold cannot outlive the schedule: no next event ends it and
  -- the hold modes are withdrawn, so nothing could release it.
  heldUnderSchedule("Until Next")

  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released ~= nil, "deleting the last event releases the hold")
  if released ~= nil then
    checkEqual(released.params.MODE, "Off", "reported off")
  end
  clearHold()
end)

test("A Permanent hold is the one that survives the schedule", function()
  -- It never ran until an event, so deleting the events takes nothing away from
  -- it. It is deliberate, and the user or programming ends it.
  heldUnderSchedule("Permanent")

  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  checkEqual(lastSent("HOLD_MODE_CHANGED"), nil, "a permanent hold is not released with the schedule")
  clearHold()
end)

test("A hold with no schedule at all is refused rather than stranded", function()
  -- Reachable from programming; accepting it would leave a hold nothing releases.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({ { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  clearHold()

  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Until Next" })
  local reported = lastSent("HOLD_MODE_CHANGED")
  check(reported == nil or reported.params.MODE == "Off", "no hold is raised without a schedule")

  -- And the refusal must not teach the driver a new name for a hold.
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Morning" weekday="1" hour="6" minute="0"/></events>',
  })
  local offered = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  check(offered ~= nil, "hold modes return with the schedule")
  if offered ~= nil then
    checkEqual(offered.params.MODES, "Off,Until Next", "still offering the wording it had")
  end
  clearHold()
end)

test("A timed or permanent hold does not become the driver's word for a hold", function()
  -- The wording is learned only from the hold meaning "until the next event";
  -- learning it from a two hour hold would mislabel every divergence.
  heldUnderSchedule("2 Hours")

  -- Release it, then diverge from the scheduled preset so the DRIVER raises a
  -- hold of its own. That is the string the learning affects.
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Off" })
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 29 })
  local raised = lastSent("HOLD_MODE_CHANGED")
  check(raised ~= nil, "diverging from the scheduled preset raises a hold")
  if raised ~= nil then
    checkEqual(raised.params.MODE, "Until Next", "and the timed hold did not rename it")
  end
  clearHold()
end)

test("Preset lists that differ only in where a preset ends are told apart", function()
  -- Length-prefixed tokens alone do not mark preset boundaries: one preset with
  -- four fields digested like three with one each.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "a", fields = { b = "c", d = "e", f = "g", h = "i" } },
  })
  setPresets({
    { name = "a", fields = { b = "c" } },
    { name = "d", fields = { e = "f" } },
    { name = "g", fields = { h = "i" } },
  })
  local stored = Deserialize(C4:PersistGetValue("Presets"))
  check(type(stored) == "table" and stored.g ~= nil, "the second list reached persistent storage")
end)

test("A fresh install does not forward a bound sensor before the proxy enables it", function()
  -- persist:get's EMPTY sentinel is truthy; a fresh install must not read as in use.
  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  OnDriverLateInit()
  Properties["Remote Temperature Service"] = "set_remote_temperature"
  local SENSOR = 5100
  registerSensorBindingHandlers(SENSOR)

  resetSent()
  RFP[SENSOR](SENSOR, "VALUE_CHANGED", { CELSIUS = "21.5" })
  check(lastSent("SET_REMOTE_TEMPERATURE") == nil, "a reading before SET_REMOTE_SENSOR is not forwarded")

  RFP.SET_REMOTE_SENSOR(PROXY, "SET_REMOTE_SENSOR", { IN_USE = "True" })
  resetSent()
  RFP[SENSOR](SENSOR, "VALUE_CHANGED", { CELSIUS = "21.5" })
  local forwarded = lastSentOn(ESPHOME, "SET_REMOTE_TEMPERATURE")
  check(
    forwarded ~= nil and forwarded.params.temperature == "21.5",
    "and is forwarded once the proxy says the sensor is in use"
  )
  Properties["Remote Temperature Service"] = nil
end)

test("Preset scheduling is published at runtime, not left to the manifest", function()
  -- The static can_preset_schedule in driver.xml does not reach the proxy; it
  -- has to be pushed.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })

  local published = lastSentWith("DYNAMIC_CAPABILITIES_CHANGED", "CAN_PRESET_SCHEDULE")
  check(published ~= nil, "CAN_PRESET_SCHEDULE is published on connect")
  if published ~= nil then
    checkEqual(published.params.CAN_PRESET_SCHEDULE, true, "and it is enabled for a climate device")
    checkEqual(published.binding, PROXY, "on the proxy binding")
  end

  -- Re-asserted on every connection: a reload has told the proxy nothing and the
  -- restored schedule arrives without a SET_EVENTS.
  local holdModes = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  check(holdModes ~= nil, "and the hold modes are re-asserted on the same connection")
end)

test("A water heater is offered neither a preset schedule nor hold modes", function()
  -- Scheduling on a device never offered presets gives a UI that cannot complete.
  local heater = singleSetpointEntity()
  heater.is_water_heater = true
  disconnect()
  resetSent()
  updateState(heater, { mode = Mode.HEAT, target_temperature = 50 })

  local published = lastSentWith("DYNAMIC_CAPABILITIES_CHANGED", "CAN_PRESET_SCHEDULE")
  check(published ~= nil, "CAN_PRESET_SCHEDULE is still stated for a water heater")
  if published ~= nil then
    checkEqual(published.params.CAN_PRESET_SCHEDULE, false, "and it is disabled, matching CAN_PRESET")
  end
  checkEqual(lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil, "and no hold modes are offered at all")
end)

test("Hold modes are published with the schedule and withdrawn without it", function()
  -- hold_modes in driver.xml never reaches the proxy; it must be pushed.
  disconnect()
  setPresets({ { name = "Comfort", fields = { single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  resetSent()

  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  local raised = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  check(raised ~= nil, "saving a schedule publishes the hold modes")
  if raised ~= nil then
    checkEqual(raised.params.MODES, "Off,Until Next", "as Off plus the proxy's own hold wording")
  end

  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local withdrawn = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  check(withdrawn ~= nil, "deleting the last event withdraws them")
  if withdrawn ~= nil then
    checkEqual(withdrawn.params.MODES, "", "leaving nothing to hold until")
  end
end)

test("An unchanged schedule does not re-publish the hold modes", function()
  -- SET_EVENTS is resent on every reconnect; without the dedupe each is a flash write.
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  checkEqual(lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil, "the same list is published once, not again")
end)

--- Put a schedule, two presets and an attached device in place, with "Comfort"
--- recorded as the preset the schedule currently has in force.
local function scheduledFixture()
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  setPresets({
    { name = "Comfort", fields = { single_setpoint_c = "22" } },
    { name = "Away", fields = { single_setpoint_c = "18" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  clearHold()
end

test("Choosing a preset by hand holds, and does not replace the schedule", function()
  -- A preset chosen by hand is a hold on top of the schedule; clearing the scheduled
  -- preset would disable hold reporting and leave the release nothing to restore.
  scheduledFixture()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Away" })
  local hold = lastSent("HOLD_MODE_CHANGED")
  check(hold ~= nil, "selecting a preset raises a hold")
  if hold ~= nil then
    checkEqual(hold.params.MODE, "Until Next", "reported as a hold until the next event")
  end
  local body = lastCommandBody()
  checkEqual(body and body.target_temperature, 18, "and the chosen preset reaches the device")

  -- Proven by what a release restores, not by reading internals.
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "" })
  local restored = lastCommandBody()
  checkEqual(restored and restored.target_temperature, 22, "and releasing it restores the scheduled preset")
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released ~= nil and released.params.MODE == "Off", "reporting the hold off")
end)

test("The next scheduled event releases a preset hold", function()
  -- The one release the user does not have to ask for.
  scheduledFixture()
  setPresets({
    { name = "Comfort", fields = { single_setpoint_c = "22" } },
    { name = "Away", fields = { single_setpoint_c = "18" } },
    { name = "Night", fields = { single_setpoint_c = "16" } },
  })
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Away" })
  checkEqual(lastSent("HOLD_MODE_CHANGED").params.MODE, "Until Next", "a hold is standing")

  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Night" })
  local body = lastCommandBody()
  checkEqual(body and body.target_temperature, 16, "the announced preset is applied")
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released ~= nil and released.params.MODE == "Off", "and the hold is released")
end)

test("Selecting the preset the schedule already holds still reads as a hold", function()
  -- State matches the scheduled preset from the very first report, so a hold
  -- that is not marked as the user's would be released by that report.
  scheduledFixture()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Comfort" })
  checkEqual(lastSent("HOLD_MODE_CHANGED").params.MODE, "Until Next", "the hold is raised")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  checkEqual(lastSent("HOLD_MODE_CHANGED"), nil, "and a matching state report does not release it")
end)

test("The proxy repeating the scheduled preset on reconnect does not undo a user's hold", function()
  -- Re-announcement on every connection must not release a user hold or re-command the device.
  scheduledFixture()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Until Next" })
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  checkEqual(lastCommandBody(), nil, "the repeated announcement commands nothing")
  checkEqual(lastSent("HOLD_MODE_CHANGED"), nil, "and leaves the hold standing")
  clearHold()
end)

test("Clearing the applied preset writes an empty marker rather than deleting the key", function()
  -- A delete then a write of this key from the proxy-command path left the key
  -- unreadable; an empty table marker avoids the delete.
  scheduledFixture()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local stored = C4:PersistGetValue("ScheduledPreset")
  check(stored ~= nil, "the key survives the clear")
  local marker = stored and Deserialize(stored)
  check(type(marker) == "table" and marker.preset == nil, "and holds no preset")

  -- A reload reads the marker as no preset, so the next announcement applies.
  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  OnDriverLateInit()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  setPresets({ { name = "Comfort", fields = { single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  local body = lastCommandBody()
  check(body ~= nil and body.target_temperature == 22, "the announcement after a reload from the marker applies")
  clearHold()
end)

test("With no schedule, choosing a preset raises no hold", function()
  -- Without a schedule the hold modes are withdrawn, so no hold may be reported.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  setPresets({ { name = "Solo", fields = { single_setpoint_c = "19" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  clearHold()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Solo" })
  local hold = lastSent("HOLD_MODE_CHANGED")
  check(hold == nil or hold.params.MODE == "Off", "no hold is reported")
  local body = lastCommandBody()
  checkEqual(body and body.target_temperature, 19, "but the preset still reaches the device")
end)

test("A rename reaches the SCHEDULE entries", function()
  -- The rename must carry the SCHEDULE array too, or the stale list persists under the old name.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Morning" } }) })

  setPresets({
    { name = "Early", previous = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })

  local stored = Deserialize(C4:PersistGetValue("Schedule"))
  check(
    type(stored) == "table" and stored[1] ~= nil and stored[1].preset == "Early",
    "the persisted schedule carries the new name"
  )
  clearHold()
end)

test("Deleting the scheduled preset does not strand an unclearable hold", function()
  -- A scheduled preset removed by a rebuild while other events remain must be
  -- forgotten, or matchPreset fails forever and the hold can never be cleared.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  setPresets({
    { name = "Morning", fields = { single_setpoint_c = "22" } },
    { name = "Evening", fields = { single_setpoint_c = "18" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = eventsXml({ { preset = "Morning" }, { preset = "Evening", hour = 20 } }),
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  clearHold()

  -- Diverge first so a hold is genuinely standing; setHoldMode dedupes, so
  -- clearing an already-Off hold emits nothing either way.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  local standing = lastSent("HOLD_MODE_CHANGED")
  check(standing ~= nil and standing.params.MODE == "Until Next", "a hold is standing against Morning")

  -- Morning is deleted in the app. Evening remains, so the schedule is still
  -- non-empty and the emptied branch does not fire.
  resetSent()
  setPresets({
    { name = "Evening", fields = { single_setpoint_c = "18" } },
  })
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released ~= nil and released.params.MODE == "Off", "the hold is taken down when its preset goes")

  -- The distinguishing claim: a later state report must not raise it again.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  local raised = lastSent("HOLD_MODE_CHANGED")
  check(raised == nil, "and a later state report does not raise it again")
  clearHold()
end)

test("A reload republishes hold mode and active preset even when they read as empty", function()
  -- Seeding HOLD_MODE "Off" / ACTIVE_PRESET nil would swallow the first report
  -- after a reload while the proxy still shows the stale value.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Comfort", fields = { single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })

  -- Reload. Every driver local is re-seeded; the proxy is untouched and still
  -- shows whatever it was last told.
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  dofile(DRIVER)
  OnDriverLateInit()

  -- A matching report reconciles to "Off", the value a seed would already believe.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local hold = lastSent("HOLD_MODE_CHANGED")
  check(hold ~= nil and hold.params.MODE == "Off", "the first report after a reload states the hold mode")

  -- Mirror case: a no-match report resolves to "none"; both sentinels need exercising.
  dofile(DRIVER)
  OnDriverLateInit()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 30 })
  local preset = lastSent("PRESET_CHANGED")
  check(preset ~= nil and preset.params.NAME == "None", "and states that no preset is active")
  clearHold()
end)

test("The proxy's own hold wording survives a reload", function()
  -- The learned hold wording must survive a reload. Asserted on the list the
  -- driver offers afterwards, not on storage.
  scheduledFixture()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Next Event" })

  local stored = Deserialize(C4:PersistGetValue("HoldWording"))
  check(type(stored) == "table", "the learned wording persists in a form that deserialises")
  checkEqual(stored and stored.mode, "Next Event", "and it round-trips to what the proxy said")

  -- A real reload: the in-memory value is still set, so only re-loading the chunk observes the restore.
  dofile(DRIVER)
  local ok, err = pcall(OnDriverLateInit)
  check(ok, "OnDriverLateInit survives the restore" .. (ok and "" or ": " .. tostring(err)))

  resetSent()
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  local offered = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  check(offered ~= nil, "the hold modes are published on the connection after the reload")
  if offered ~= nil then
    checkEqual(offered.params.MODES, "Off,Next Event", "using the wording the proxy taught it")
  end
end)

test("Two presets that both match are decided by specificity, not hash order", function()
  -- "Basic" is a subset of "Zoned" and both match. Specificity must decide, not
  -- pairs order or alphabetical order (which would pick "Basic").
  disconnect()
  resetSent()
  setPresets({
    { name = "Basic", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Zoned", fields = { hvac_mode = "Cool", single_setpoint_c = "22", fan_mode = "Quiet" } },
  })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, custom_fan_mode = "Quiet" })

  local reported = lastSent("PRESET_CHANGED")
  check(reported ~= nil, "a matching preset is reported")
  if reported ~= nil then
    checkEqual(reported.params.NAME, "Zoned", "the preset that pins down more of the state wins")
  end

  -- Stable across a rebuild that delivers the list in a different order.
  resetSent()
  setPresets({
    { name = "Zoned", fields = { hvac_mode = "Cool", single_setpoint_c = "22", fan_mode = "Quiet" } },
    { name = "Basic", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
  })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, custom_fan_mode = "Quiet" })
  local again = lastSent("PRESET_CHANGED")
  check(again == nil or again.params.NAME == "Zoned", "and it does not flip when the list is rebuilt")
end)

test("A reading of exactly zero is reported, not dropped", function()
  -- Protobuf omits a zero-valued field, so a device at 0 C sends no
  -- current_temperature; absence means zero for a declared dimension.
  local entity = singleSetpointEntity()
  entity.supports_current_temperature = true
  entity.supports_current_humidity = true
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.HEAT })

  local temp = lastSent("TEMPERATURE_CHANGED")
  check(temp ~= nil, "an omitted temperature on a device that measures one is a reading of zero")
  if temp ~= nil then
    checkEqual(temp.params.TEMPERATURE, "0", "reported as zero")
  end
  local humidity = lastSent("HUMIDITY_CHANGED")
  check(humidity ~= nil, "and the same for humidity")
  if humidity ~= nil then
    checkEqual(humidity.params.HUMIDITY, "0", "reported as zero percent")
  end
end)

test("A dimension the device does not have stays absent", function()
  -- Substituting zero for every missing float would invent a humidity reading.
  local entity = singleSetpointEntity()
  entity.supports_current_temperature = false
  entity.supports_current_humidity = false
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.HEAT })

  checkEqual(lastSent("TEMPERATURE_CHANGED"), nil, "no temperature is invented")
  checkEqual(lastSent("HUMIDITY_CHANGED"), nil, "and no humidity is invented")
end)

test("An unreadable schedule frame leaves the stored schedule alone", function()
  -- A frame that does not parse must not be read as an empty schedule; deleting
  -- every event arrives as a well-formed empty document.
  disconnect()
  resetSent()
  setPresets({ { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Morning" weekday="1" hour="6" minute="0"/></events>',
  })

  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "this is not xml" })

  local stored = Deserialize(C4:PersistGetValue("Schedule"))
  check(type(stored) == "table" and #stored == 1, "the stored schedule survives an unreadable frame")
  checkEqual(lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil, "and the hold modes are not withdrawn")

  -- The real clear still works.
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local withdrawn = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  check(withdrawn ~= nil and withdrawn.params.MODES == "", "an empty document still clears the schedule")
end)

test("A preset chosen while the device is down changes nothing and claims nothing", function()
  -- The bridge rejects a command while disconnected; no hold or mode change may
  -- be reported for a preset that never reached the device.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Comfort", fields = { hvac_mode = "Heat", single_setpoint_c = "24" } },
    { name = "Away", fields = { hvac_mode = "Heat", single_setpoint_c = "18" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Comfort" weekday="1" hour="6" minute="0"/></events>',
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  clearHold()

  disconnect()
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Away" })

  checkEqual(lastCommandBody(), nil, "no command is sent to an absent device")
  checkEqual(lastSent("HOLD_MODE_CHANGED"), nil, "and no hold is claimed for it")
  checkEqual(lastSent("HVAC_MODE_CHANGED"), nil, "and no mode change is reported")

  -- Releasing a hold must work while the device is down.
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Until Next" })
  resetSent()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Off" })
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released ~= nil and released.params.MODE == "Off", "a hold can still be released while disconnected")
  clearHold()
end)

test("A reload does not rewrite a schedule and preset list that have not changed", function()
  -- Digests seeded empty on reload rewrote unchanged lists: two flash writes per reload.
  disconnect()
  resetSent()
  setPresets({ { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } } })
  local events = '<events><event preset="Morning" weekday="1" hour="6" minute="0"/></events>'
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = events })

  dofile(DRIVER)
  local ok = pcall(OnDriverLateInit)
  check(ok, "OnDriverLateInit survives the restore")

  -- Count writes only for the two keys under test, from here on.
  local writes = 0
  local realWrite = C4.PersistSetValue
  C4.PersistSetValue = function(self, key, value, encrypted)
    if key == "Schedule" or key == "Presets" then
      writes = writes + 1
    end
    return realWrite(self, key, value, encrypted)
  end

  -- Exactly what the proxy sends on the connection after a reload: both lists,
  -- unchanged.
  setPresets({ { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = events })
  C4.PersistSetValue = realWrite

  checkEqual(writes, 0, "an unchanged resend after a reload writes nothing to flash")
end)

test("The proxy is not sent a notification it does not implement", function()
  -- ONLINE_CHANGED is absent from the thermostat notification set and Control4's
  -- own thermostat never sends it. Connection state travels on CONNECTION.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  checkEqual(lastSent("ONLINE_CHANGED"), nil, "no ONLINE_CHANGED on a state report")
  local connection = lastSentWith("CONNECTION", "CONNECTED")
  check(connection ~= nil, "and the connection is still announced")
end)

test("A water heater ignores a schedule inherited from a climate entity", function()
  -- Repointing from a climate entity to a water heater leaves the schedule
  -- restored and announced; applying it would command the heater with presets.
  disconnect()
  resetSent()
  setPresets({ { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } } })
  clearSchedule()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Morning" } }) })

  local heater = singleSetpointEntity()
  heater.is_water_heater = true
  updateState(heater, { mode = Mode.HEAT })

  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
  checkEqual(lastCommandBody(), nil, "the inherited event does not command the water heater")
  checkEqual(lastSent("HOLD_MODE_CHANGED"), nil, "and does not move its hold state")
  local stored = C4:PersistGetValue("ScheduledPreset")
  local marker = stored and Deserialize(stored)
  check(not (type(marker) == "table" and marker.preset == "Morning"), "and does not record it as applied")
  -- A schedule edit that reaches it must not offer a hold control either. The
  -- list goes empty and back so that, ungated, it would have to be re-sent.
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Morning" } }) })
  checkEqual(lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil, "and a schedule edit offers a water heater no hold modes")
end)

test("Editing the scheduled preset while the device is down is applied on reconnect", function()
  -- Suppression must be set only after a command goes out; a refused apply
  -- otherwise loses the edit and swallows the first report after reconnect.
  scheduledFixture()
  disconnect()
  resetSent()
  setPresets({
    { name = "Comfort", fields = { single_setpoint_c = "24" } },
    { name = "Away", fields = { single_setpoint_c = "18" } },
  })
  checkEqual(lastCommandBody(), nil, "nothing is commanded at a device that is down")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  check(body ~= nil and body.target_temperature == 24, "the edit is applied once the device is back")
  clearHold()
end)

test("A scheduled preset commanded just before a drop is sent again on reconnect", function()
  -- The name is persisted as applied when the command goes out, before confirmation;
  -- a drop in that window must mark it pending or the reconnect repeat is ignored.
  scheduledFixture()
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Away" })
  local sent = lastCommandBody()
  check(sent ~= nil and sent.target_temperature == 18, "the event is commanded")

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local again = lastCommandBody()
  check(again ~= nil and again.target_temperature == 18, "and sent again to a device that came back unconfirmed")
  clearHold()
end)

---------------------------------------------------------------------------

SendToProxy = originalSendToProxy

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
