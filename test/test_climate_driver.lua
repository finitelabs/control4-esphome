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

local T = require("testlib")

--- Name a group and run it, so a throw inside one case is one recorded failure
--- rather than the end of the run.
local function test(name, fn)
  print("\n" .. name)
  local ok, err = pcall(fn)
  if not ok then
    T.check(name .. " threw: " .. tostring(err), false)
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
  T.check("HAS_EXTRAS flipped on at runtime", caps ~= nil and caps.params.HAS_EXTRAS == true)

  local setup = lastSent("EXTRAS_SETUP_CHANGED")
  T.check("EXTRAS_SETUP_CHANGED emitted", setup ~= nil)
  if setup then
    local xml = setup.params.XML
    T.check("selector invokes SET_MODE_SWING", xml:find('command="SET_MODE_SWING"', 1, true) ~= nil)
    T.check("Vertical offered", xml:find('value="Vertical"', 1, true) ~= nil)
    T.check("Horizontal offered", xml:find('value="Horizontal"', 1, true) ~= nil)
    T.check("Both offered", xml:find('value="Both"', 1, true) ~= nil)
  end

  T.check("CONNECTION announced so the proxy resends presets", lastSent("CONNECTION") ~= nil)
end)

test("Swing selection reaches the device as a swing_mode command", function()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL })
  resetSent()

  RFP.SET_MODE_SWING(PROXY, "SET_MODE_SWING", { value = "Vertical" })

  local body = lastCommandBody()
  T.check("a device command was sent", body ~= nil)
  if body then
    T.check("has_swing_mode set", body.has_swing_mode == true)
    T.eq("swing_mode is VERTICAL", body.swing_mode, Swing.VERTICAL)
  end
  T.check("extras state echoed so the UI settles", lastSent("EXTRAS_STATE_CHANGED") ~= nil)
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
  T.check("a device command was sent", body ~= nil)
  if body then
    T.eq("mode COOL", body.mode, Mode.COOL)
    T.eq("setpoint 22C", body.target_temperature, 22)
    T.eq("fan QUIET", body.fan_mode, Fan.QUIET)
    T.eq("swing VERTICAL", body.swing_mode, Swing.VERTICAL)
  end
  -- The device's own report is what announces a preset, not the command going
  -- out, so nothing is claimed until the device confirms.
  T.check("nothing announced before the device confirms", lastSent("PRESET_CHANGED") == nil)
  updateState(
    singleSetpointEntity(),
    { mode = Mode.COOL, target_temperature = 22, fan_mode = Fan.QUIET, swing_mode = Swing.VERTICAL }
  )
  local changed = lastSent("PRESET_CHANGED")
  T.check("the confirming report names the preset", changed ~= nil and changed.params.NAME == "Movie Night")
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
  T.check("a device command was sent", body ~= nil)
  if body then
    T.eq("heat setpoint -> target_temperature_low", body.target_temperature_low, 20)
    T.eq("cool setpoint -> target_temperature_high", body.target_temperature_high, 24)
    T.check("single target_temperature NOT sent to a two-point device", body.target_temperature == nil)
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
  T.check("setpoint capabilities published", caps ~= nil)
  if caps then
    T.check("one-target device reports SINGLE even with heat+cool modes", caps.HAS_SINGLE_SETPOINT == true)
    T.check("C4 requires can_heat false alongside has_single_setpoint", caps.CAN_HEAT == false)
    T.check("C4 requires can_cool false alongside has_single_setpoint", caps.CAN_COOL == false)
    T.check("C4 requires can_do_auto false alongside has_single_setpoint", caps.CAN_AUTO == false)
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
  T.check("supports_two_point device stays DUAL", dual ~= nil and dual.HAS_SINGLE_SETPOINT == false)
  -- A two-point device keeps its deadband; it must not be flattened.
  T.check("a real two-point device keeps heat/cool/auto", dual ~= nil and dual.CAN_AUTO == true)
end)

test("Preset field template is pushed and matches the setpoint mode", function()
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })

  local tpl = lastSent("PRESET_FIELDS_CHANGED")
  T.check("PRESET_FIELDS_CHANGED emitted", tpl ~= nil)
  if tpl then
    local xml = tpl.params.XML
    -- One declared target: the template must carry single_setpoint, or the editor
    -- offers a heat/cool pair the device silently halves.
    T.check("single_setpoint_c offered", xml:find('id="single_setpoint_c"', 1, true) ~= nil)
    T.check("single_setpoint_f offered", xml:find('id="single_setpoint_f"', 1, true) ~= nil)
    T.check("heat_setpoint NOT offered in single mode", xml:find("heat_setpoint", 1, true) == nil)
    T.check("cool_setpoint NOT offered in single mode", xml:find("cool_setpoint", 1, true) == nil)
    T.check("hvac_mode offered", xml:find('id="hvac_mode"', 1, true) ~= nil)
    T.check("fan_mode offered", xml:find('id="fan_mode"', 1, true) ~= nil)
    T.check("swing offered", xml:find('id="swing"', 1, true) ~= nil)
    T.check("device-specific Quiet fan speed present", xml:find('value="Quiet"', 1, true) ~= nil)
    -- HEAT_COOL and AUTO both map to "Auto"; it must appear once, not twice.
    local count = select(2, xml:gsub('value="Auto"', ""))
    T.eq("Auto appears once per list (hvac_mode + fan_mode), not duplicated", count, 2)
    T.check("range taken from the device (16C)", xml:find('min="16"', 1, true) ~= nil)
  end

  -- A real two-point device gets the opposite template.
  disconnect()
  resetSent()
  updateState(
    dualSetpointEntity(),
    { mode = Mode.HEAT_COOL, target_temperature_low = 20, target_temperature_high = 24 }
  )
  local dualTpl = lastSent("PRESET_FIELDS_CHANGED")
  T.check("template pushed for the two-point device too", dualTpl ~= nil)
  if dualTpl then
    local xml = dualTpl.params.XML
    T.check("heat_setpoint_c offered when genuinely dual", xml:find('id="heat_setpoint_c"', 1, true) ~= nil)
    T.check("cool_setpoint_c offered when genuinely dual", xml:find('id="cool_setpoint_c"', 1, true) ~= nil)
    T.check("single_setpoint NOT offered when dual", xml:find("single_setpoint", 1, true) == nil)
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
  T.check("PRESET_FIELDS_CHANGED emitted", tpl ~= nil)
  if tpl then
    local xml = tpl.params.XML
    T.check("swing withheld when only Off is offered", xml:find('id="swing"', 1, true) == nil)
    T.check("fan_mode still offered", xml:find('id="fan_mode"', 1, true) ~= nil)
    T.check("hvac_mode still offered", xml:find('id="hvac_mode"', 1, true) ~= nil)
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
  T.check("humidity published on 5011", humidity ~= nil)
  if humidity then
    T.eq("carries the current humidity", humidity.params.VALUE, "57")
  end
  T.check("nothing published on the managed-range id", lastSentOn(5012, "VALUE_CHANGED") == nil)
  T.check("temperature still publishes on 5010", lastSentOn(5010, "VALUE_CHANGED") ~= nil)
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
  T.check("a device command was sent", body ~= nil)
  if body then
    T.eq("Cool preset uses the cool setpoint", body.target_temperature, 23)
    T.check("no low setpoint on a single-setpoint device", body.target_temperature_low == nil)
    T.check("no high setpoint on a single-setpoint device", body.target_temperature_high == nil)
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
  T.check("a device command was sent", body ~= nil)
  if body then
    T.eq("Heat preset uses the heat setpoint", body.target_temperature, 19)
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
  T.check("the captured preset applies", body ~= nil)
  if body then
    -- Celsius wins over the auto-inserted Fahrenheit: 72F would round to 22.2C.
    T.eq("uses cool_setpoint_c (22C), not 72F round-tripped", body.target_temperature, 22)
    T.eq("fan Auto", body.fan_mode, Fan.AUTO)
    T.check("no mode sent when the preset omits hvac_mode", body.mode == nil)
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

  T.check("SET_EVENTS alone sends no device command", lastCommandBody() == nil)
  local modes = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  T.check("but a schedule existing is what offers the hold modes", modes ~= nil and modes.params.MODES ~= "")
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
  T.check("manual change engaged a hold", engaged ~= nil and engaged.params.MODE ~= "Off")
  resetSent()

  -- The proxy announces the next event.
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Evening" })

  local body = lastCommandBody()
  T.check("the head was commanded at the event", body ~= nil)
  if body then
    T.eq("the announced preset's setpoint applied", body.target_temperature, 26)
  end
  local hold = lastSent("HOLD_MODE_CHANGED")
  T.check("hold released at the next event", hold ~= nil and hold.params.MODE == "Off")
end)

test("A malformed schedule event is skipped, not fatal", function()
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Ghost"/><event preset="Good" weekday="2" hour="7" minute="30"/></events>',
  })
  T.check("handler survived a malformed event", true)
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
  T.check("SET_EVENT commands the announced preset", body ~= nil and body.target_temperature == 21)

  -- And it is tracked, or hold reconciliation has no reference.
  updateState(singleSetpointEntity(), { mode = Mode.HEAT, target_temperature = 21 })
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 30 })
  local held = lastSent("HOLD_MODE_CHANGED")
  T.check("it is tracked as the scheduled preset", held ~= nil and held.params.MODE ~= "Off")
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
  T.check("diverging trips 'Until Next'", held ~= nil and held.params.MODE == "Until Next")

  -- State comes back onto the preset.
  resetSent()
  updateState(entity, { mode = Mode.HEAT, target_temperature = 21 })
  local released = lastSent("HOLD_MODE_CHANGED")
  T.check("returning releases the hold", released ~= nil and released.params.MODE == "Off")
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
  T.check("state matching the preset does NOT trip a hold", held == nil or held.params.MODE == "Off")

  local changed = lastSent("PRESET_CHANGED")
  T.check("preset still reported as active", changed ~= nil and changed.params.NAME == "All Off")
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
  T.check("a rename alone does NOT re-run the preset", lastCommandBody() == nil)

  -- Tracking must have followed the rename. Editing the renamed preset's VALUES
  -- re-applies it only if the driver still considers it the active one.
  resetSent()
  setPresets({
    { name = "Early", fields = { hvac_mode = "Heat", single_setpoint_c = "19" } },
  })
  local body = lastCommandBody()
  T.check("still tracked as active under the new name", body ~= nil and body.target_temperature == 19)
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
  T.check("scheduling another preset sends NO device command", lastCommandBody() == nil)

  -- And the user's own change must survive the next list resend.
  resetSent()
  RFP.SET_SETPOINT_COOL(PROXY, "SET_SETPOINT_COOL", { CELSIUS = "25" })
  resetSent()
  setPresets({
    { name = "Evening", fields = { hvac_mode = "Cool", cool_setpoint_c = "20" } },
    { name = "Bedtime", fields = { hvac_mode = "Cool", cool_setpoint_c = "18" } },
  })
  T.check("a manual change is not snapped back by a list resend", lastCommandBody() == nil)
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
  T.check("an edit to the running preset takes effect immediately", body ~= nil)
  if body then
    T.eq("new value applied", body.target_temperature, 17)
  end
end)

test("An unknown preset name is refused, not silently applied", function()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({ { name = "Known", fields = { hvac_mode = "Heat" } } })
  resetSent()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Nonexistent" })
  T.check("no device command sent for an unknown preset", lastCommandBody() == nil)
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
  T.check("PRESET_FIELDS_CHANGED emitted", tpl ~= nil)
  if tpl then
    local xml = tpl.params.XML
    T.check("cool-capable device is offered a cool setpoint", xml:find("cool_setpoint_c", 1, true) ~= nil)
    T.check("cool-only device is NOT offered a heat setpoint", xml:find("heat_setpoint", 1, true) == nil)
  end

  local caps = nil
  for _, entry in ipairs(sent) do
    if entry.command == "DYNAMIC_CAPABILITIES_CHANGED" and entry.params.CAN_PRESET ~= nil then
      caps = entry.params
    end
  end
  T.check("presets enabled at runtime once an entity attaches", caps ~= nil and caps.CAN_PRESET == true)
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
  T.check(
    "the app is never told 'no preset' while the requested one is landing: " .. table.concat(announced, ", "),
    not TableContainsValue(announced, "None")
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
  T.eq("PRESET_CHANGED sent once across apply and confirmation", announced, 1)
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
  T.check("entering a preset reports it", first ~= nil and first.params.NAME == "Cool 22")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  T.check("staying in the preset sends nothing further", lastSent("PRESET_CHANGED") == nil)

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 25 })
  local left = lastSent("PRESET_CHANGED")
  T.check("leaving the preset clears it", left ~= nil and left.params.NAME == "None")
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
  T.check("PRESET_FIELDS_CHANGED emitted", tpl ~= nil)
  if tpl then
    local xml = tpl.params.XML
    T.check("ampersand and quotes escaped", xml:find("Turbo &amp; &quot;Boost&quot;", 1, true) ~= nil)
    T.check("angle brackets escaped", xml:find("Eco&lt;mode&gt;", 1, true) ~= nil)
    T.check("no raw ampersand left in an attribute", xml:find('value="Turbo & "', 1, true) == nil)
    -- The escaped template has to survive a round trip through the parser the
    -- driver uses on the way back in.
    local parsed = C4:ParseXml(xml)
    T.check("escaped template still parses", parsed ~= nil)
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
  T.check("schedule was persisted", C4:PersistGetValue("Schedule") ~= nil)

  local ok, err = pcall(OnDriverLateInit)
  T.check("OnDriverLateInit does not throw with a persisted schedule" .. (ok and "" or ": " .. tostring(err)), ok)
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
  T.check("a preset constraining nothing is never announced as active", name ~= "Empty")
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
  T.check("the user's hold is not cancelled by a matching report", released == nil)
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
  T.eq("CAN_PRESET is withheld from a water heater", sawPresetCap, false)
  T.check("no preset template is published either", lastSent("PRESET_FIELDS_CHANGED") == nil)
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
  T.check("an edit after release does not command the device", lastCommandBody() == nil)
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
  T.check("the preset commanded the device", body ~= nil)
  if body then
    T.eq("21.5 snapped onto the device's 1 degree step", body.target_temperature, 22)
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
  T.check("an unknown preset commands nothing when announced", lastCommandBody() == nil)

  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Later", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } },
  })
  local body = lastCommandBody()
  T.check("the announced preset is applied once it is known", body ~= nil)
  if body then
    T.eq("with the announced preset's value", body.target_temperature, 26)
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
  T.check("nothing is commanded at a device that is down", lastCommandBody() == nil)

  -- Reconnect alone must run it. Deliberately no SET_PRESETS here: the presets
  -- never left memory, so nothing would make the proxy resend them.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  T.check("the announced preset is applied once the device is back", body ~= nil)
  if body then
    T.eq("with the scheduled preset's value", body.target_temperature, 26)
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
  T.check("nothing is commanded at a device that is down", lastCommandBody() == nil)

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  T.check("the pending event survives the outage and runs on reconnect", body ~= nil)
  if body then
    T.eq("with the announced preset's value", body.target_temperature, 26)
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
  T.check("the renamed preset still runs its pending event", body ~= nil)
  if body then
    T.eq("with the renamed preset's value", body.target_temperature, 27)
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
  T.check("the preset matches its own clamped value", announced ~= nil and announced.params.NAME == "TooHot")
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
  T.check("the preset is commanded", body ~= nil)
  if body then
    T.eq("snapped to the step the device does report", body.target_temperature, 22)
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
  T.check("a CONNECTION update is sent when the device is lost", conn ~= nil)
  if conn then
    T.eq("and it retracts the connection", tostring(conn.params.CONNECTED), "false")
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
  T.eq("cold start declares the device absent", connectedNow(), "false")

  -- 2. The device shows up.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  T.eq("a live device declares present", connectedNow(), "true")

  -- 3. It goes away.
  resetSent()
  disconnect()
  T.eq("losing the device retracts presence", connectedNow(), "false")

  -- 4. It comes back.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  T.eq("reconnecting declares present again", connectedNow(), "true")

  -- 5. Driver reloads while the device is down. Nothing has connected since the
  --    reload, so the declaration at LateInit is the only thing speaking.
  dofile(DRIVER)
  resetSent()
  OnDriverLateInit()
  T.eq("a reload with the device down stays absent", connectedNow(), "false")
end)

test("Unbinding the device retracts the connection", function()
  -- Removing the ESPHome connection in Composer must also retract IS_CONNECTED.
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()

  -- 5002 is ESPHOME_BINDING; isBound = false is the unbind.
  OBC[5002](5002, "ESPHOME", false)

  local conn = lastSent("CONNECTION")
  T.check("an unbind declares a connection state", conn ~= nil)
  if conn then
    T.eq("and it declares the device absent", tostring(conn.params.CONNECTED), "false")
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

  T.check("the persisted preset list survives a rebind", C4:PersistGetValue("Presets") ~= nil)

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Keeper" })
  local body = lastCommandBody()
  T.check("and the preset still applies after the rebind", body ~= nil)
  if body then
    T.eq("with its saved value", body.target_temperature, 24)
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

  T.check("the schedule is persisted", C4:PersistGetValue("Schedule") ~= nil)
  T.check("and so is the preset list", C4:PersistGetValue("Presets") ~= nil)

  -- The distinguishing claim: applyPreset works BY NAME with no SET_PRESETS resend.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Survivor" })
  local body = lastCommandBody()
  T.check("a persisted preset can be applied without the proxy resending it", body ~= nil)
  if body then
    T.eq("with the value it was saved with", body.target_temperature, 26)
  end
end)

test("A driver that has never seen a device still reports itself offline", function()
  -- thermostatV2 starts IS_CONNECTED true unless has_connection_status is
  -- declared, so a fresh install must declare offline without a cached shape.
  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  resetSent()
  OnDriverLateInit()

  T.check("no capabilities are invented", lastSent("DYNAMIC_CAPABILITIES_CHANGED") == nil)
  local conn = lastSent("CONNECTION")
  T.check("but the connection state IS declared with no cache at all", conn ~= nil)
  if conn then
    T.eq("declaring the device absent", tostring(conn.params.CONNECTED), "false")
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
  T.check("a water heater command is sent", body ~= nil)
  if body then
    T.eq("and the mode is an enum, not the persist sentinel table", type(body.mode), "number")
  end
end)

test("A device with nothing to put in Extras has the section withdrawn", function()
  -- HAS_EXTRAS must go false for a modeless water heater, or a stale Swing selector stays.
  disconnect()
  local bare = singleSetpointEntity()
  bare.supported_swing_modes = {}
  updateState(bare, { mode = Mode.COOL, target_temperature = 22 })

  local extras = lastSentWith("DYNAMIC_CAPABILITIES_CHANGED", "HAS_EXTRAS")
  T.check("HAS_EXTRAS is published either way", extras ~= nil)
  if extras then
    T.eq("and it is withdrawn when there are no extras", tostring(extras.params.HAS_EXTRAS), "false")
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
  T.check("the orphaned announcement does not command the device", lastCommandBody() == nil)
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
  T.check("OnDriverLateInit survives the restore" .. (ok and "" or ": " .. tostring(err)), ok)

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Persisted", fields = { hvac_mode = "Cool", single_setpoint_c = "24" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Persisted" })
  local body = lastCommandBody()
  T.check("the re-announced preset is applied after the reload", body ~= nil)
  if body then
    T.eq("with its value", body.target_temperature, 24)
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
  T.check("the first announcement applies the preset", lastCommandBody() ~= nil)
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })

  package.loaded["lib.persist"] = nil
  dofile(DRIVER)
  OnDriverLateInit()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  T.eq("the same announcement after a reload is left alone", lastCommandBody(), nil)

  -- Still tracked: a divergence is held against it.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 30 })
  local held = lastSent("HOLD_MODE_CHANGED")
  T.check("and it is still the scheduled preset for hold purposes", held ~= nil and held.params.MODE ~= "Off")
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
  T.check("the preset matches its own snapped value", announced ~= nil and announced.params.NAME == "Half")
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
  T.check("the stale report does not raise a hold", lastSent("HOLD_MODE_CHANGED") == nil)

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  T.check("a genuine divergence still raises one on the next report", lastSent("HOLD_MODE_CHANGED") ~= nil)
end)

test("A lone Off swing mode produces no Extras state echo", function()
  -- No EXTRAS_STATE_CHANGED for an Extras object that was never published (lone Off).
  local entity = singleSetpointEntity()
  entity.supported_swing_modes = { Swing.OFF }
  disconnect()
  resetSent()
  updateState(entity, { mode = Mode.COOL, target_temperature = 22, swing_mode = Swing.OFF })
  T.check("no swing echo for a device with nowhere to swing", lastSent("EXTRAS_STATE_CHANGED") == nil)

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, swing_mode = Swing.VERTICAL })
  T.check("a multi-mode device still echoes its vane state", lastSent("EXTRAS_STATE_CHANGED") ~= nil)
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
  T.check("no temperature for a NaN reading", lastSent("TEMPERATURE_CHANGED") == nil)
  T.check("nothing on the temperature output either", lastSentOn(5010, "VALUE_CHANGED") == nil)
  T.check("no setpoint for an infinite target", lastSent("SINGLE_SETPOINT_CHANGED") == nil)
  T.check("no humidity for a NaN reading", lastSent("HUMIDITY_CHANGED") == nil)
  T.check("nothing on the humidity output either", lastSentOn(5011, "VALUE_CHANGED") == nil)
  T.check("no humidity setpoint for an infinite target", lastSent("HUMIDIFY_SETPOINT_CHANGED") == nil)

  -- A nudge from an unknown setpoint starts from zero; the sentinel must never seed it.
  resetSent()
  RFP.INC_SETPOINT_SINGLE(PROXY, "INC_SETPOINT_SINGLE")
  local body = lastCommandBody()
  T.check("the nudge still commands the device", body ~= nil)
  if body then
    T.eq("a nudge from an unknown setpoint is not seeded by the sentinel", body.target_temperature, 16)
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
  T.check("no temperature for a NaN reading, once serialized", lastSent("TEMPERATURE_CHANGED") == nil)
  T.check("no setpoint for an infinite target, once serialized", lastSent("SINGLE_SETPOINT_CHANGED") == nil)
  T.check("no humidity for a NaN reading, once serialized", lastSent("HUMIDITY_CHANGED") == nil)
  T.check("no humidity setpoint for an infinite target, once serialized", lastSent("HUMIDIFY_SETPOINT_CHANGED") == nil)
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
  T.check("diverging from the schedule holds", held ~= nil and held.params.MODE == "Until Next")

  -- The user deletes every event.
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local released = lastSent("HOLD_MODE_CHANGED")
  T.check("an emptied schedule releases the hold", released ~= nil and released.params.MODE == "Off")

  -- Nothing is left to diverge from, so a further change raises no hold...
  resetSent()
  updateState(entity, { mode = Mode.HEAT, target_temperature = 27 })
  T.check("no hold is raised against a deleted schedule", lastSent("HOLD_MODE_CHANGED") == nil)

  -- ...and releasing a hold has nothing to re-apply.
  resetSent()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Off" })
  T.check("Hold Off no longer re-applies the deleted preset", lastCommandBody() == nil)
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
  T.check("deleting the last event releases the hold", released ~= nil)
  if released ~= nil then
    T.eq("reported off", released.params.MODE, "Off")
  end
  clearHold()
end)

test("A Permanent hold is the one that survives the schedule", function()
  -- It never ran until an event, so deleting the events takes nothing away from
  -- it. It is deliberate, and the user or programming ends it.
  heldUnderSchedule("Permanent")

  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  T.eq("a permanent hold is not released with the schedule", lastSent("HOLD_MODE_CHANGED"), nil)
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
  T.check("no hold is raised without a schedule", reported == nil or reported.params.MODE == "Off")

  -- And the refusal must not teach the driver a new name for a hold.
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Morning" weekday="1" hour="6" minute="0"/></events>',
  })
  local offered = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  T.check("hold modes return with the schedule", offered ~= nil)
  if offered ~= nil then
    T.eq("still offering the wording it had", offered.params.MODES, "Off,Until Next")
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
  T.check("diverging from the scheduled preset raises a hold", raised ~= nil)
  if raised ~= nil then
    T.eq("and the timed hold did not rename it", raised.params.MODE, "Until Next")
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
  T.check("the second list reached persistent storage", type(stored) == "table" and stored.g ~= nil)
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
  T.check("a reading before SET_REMOTE_SENSOR is not forwarded", lastSent("SET_REMOTE_TEMPERATURE") == nil)

  RFP.SET_REMOTE_SENSOR(PROXY, "SET_REMOTE_SENSOR", { IN_USE = "True" })
  resetSent()
  RFP[SENSOR](SENSOR, "VALUE_CHANGED", { CELSIUS = "21.5" })
  local forwarded = lastSentOn(ESPHOME, "SET_REMOTE_TEMPERATURE")
  T.check(
    "and is forwarded once the proxy says the sensor is in use",
    forwarded ~= nil and forwarded.params.temperature == "21.5"
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
  T.check("CAN_PRESET_SCHEDULE is published on connect", published ~= nil)
  if published ~= nil then
    T.eq("and it is enabled for a climate device", published.params.CAN_PRESET_SCHEDULE, true)
    T.eq("on the proxy binding", published.binding, PROXY)
  end

  -- Re-asserted on every connection: a reload has told the proxy nothing and the
  -- restored schedule arrives without a SET_EVENTS.
  local holdModes = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  T.check("and the hold modes are re-asserted on the same connection", holdModes ~= nil)
end)

test("A water heater is offered neither a preset schedule nor hold modes", function()
  -- Scheduling on a device never offered presets gives a UI that cannot complete.
  local heater = singleSetpointEntity()
  heater.is_water_heater = true
  disconnect()
  resetSent()
  updateState(heater, { mode = Mode.HEAT, target_temperature = 50 })

  local published = lastSentWith("DYNAMIC_CAPABILITIES_CHANGED", "CAN_PRESET_SCHEDULE")
  T.check("CAN_PRESET_SCHEDULE is still stated for a water heater", published ~= nil)
  if published ~= nil then
    T.eq("and it is disabled, matching CAN_PRESET", published.params.CAN_PRESET_SCHEDULE, false)
  end
  T.eq("and no hold modes are offered at all", lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil)
end)

test("Hold modes are published with the schedule and withdrawn without it", function()
  -- hold_modes in driver.xml never reaches the proxy; it must be pushed.
  disconnect()
  setPresets({ { name = "Comfort", fields = { single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  resetSent()

  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  local raised = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  T.check("saving a schedule publishes the hold modes", raised ~= nil)
  if raised ~= nil then
    T.eq("as Off plus the proxy's own hold wording", raised.params.MODES, "Off,Until Next")
  end

  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local withdrawn = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  T.check("deleting the last event withdraws them", withdrawn ~= nil)
  if withdrawn ~= nil then
    T.eq("leaving nothing to hold until", withdrawn.params.MODES, "")
  end
end)

test("An unchanged schedule does not re-publish the hold modes", function()
  -- SET_EVENTS is resent on every reconnect; without the dedupe each is a flash write.
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Comfort" } }) })
  T.eq("the same list is published once, not again", lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil)
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
  T.check("selecting a preset raises a hold", hold ~= nil)
  if hold ~= nil then
    T.eq("reported as a hold until the next event", hold.params.MODE, "Until Next")
  end
  local body = lastCommandBody()
  T.eq("and the chosen preset reaches the device", body and body.target_temperature, 18)

  -- Proven by what a release restores, not by reading internals.
  resetSent()
  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "" })
  local restored = lastCommandBody()
  T.eq("and releasing it restores the scheduled preset", restored and restored.target_temperature, 22)
  local released = lastSent("HOLD_MODE_CHANGED")
  T.check("reporting the hold off", released ~= nil and released.params.MODE == "Off")
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
  T.eq("a hold is standing", lastSent("HOLD_MODE_CHANGED").params.MODE, "Until Next")

  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Night" })
  local body = lastCommandBody()
  T.eq("the announced preset is applied", body and body.target_temperature, 16)
  local released = lastSent("HOLD_MODE_CHANGED")
  T.check("and the hold is released", released ~= nil and released.params.MODE == "Off")
end)

test("Selecting the preset the schedule already holds still reads as a hold", function()
  -- State matches the scheduled preset from the very first report, so a hold
  -- that is not marked as the user's would be released by that report.
  scheduledFixture()

  RFP.SET_PRESET(PROXY, "SET_PRESET", { NAME = "Comfort" })
  T.eq("the hold is raised", lastSent("HOLD_MODE_CHANGED").params.MODE, "Until Next")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  T.eq("and a matching state report does not release it", lastSent("HOLD_MODE_CHANGED"), nil)
end)

test("The proxy repeating the scheduled preset on reconnect does not undo a user's hold", function()
  -- Re-announcement on every connection must not release a user hold or re-command the device.
  scheduledFixture()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Until Next" })
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Comfort" })
  T.eq("the repeated announcement commands nothing", lastCommandBody(), nil)
  T.eq("and leaves the hold standing", lastSent("HOLD_MODE_CHANGED"), nil)
  clearHold()
end)

test("Clearing the applied preset writes an empty marker rather than deleting the key", function()
  -- A delete then a write of this key from the proxy-command path left the key
  -- unreadable; an empty table marker avoids the delete.
  scheduledFixture()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local stored = C4:PersistGetValue("ScheduledPreset")
  T.check("the key survives the clear", stored ~= nil)
  local marker = stored and Deserialize(stored)
  T.check("and holds no preset", type(marker) == "table" and marker.preset == nil)

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
  T.check("the announcement after a reload from the marker applies", body ~= nil and body.target_temperature == 22)
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
  T.check("no hold is reported", hold == nil or hold.params.MODE == "Off")
  local body = lastCommandBody()
  T.eq("but the preset still reaches the device", body and body.target_temperature, 19)
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
  T.check(
    "the persisted schedule carries the new name",
    type(stored) == "table" and stored[1] ~= nil and stored[1].preset == "Early"
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
  T.check("a hold is standing against Morning", standing ~= nil and standing.params.MODE == "Until Next")

  -- Morning is deleted in the app. Evening remains, so the schedule is still
  -- non-empty and the emptied branch does not fire.
  resetSent()
  setPresets({
    { name = "Evening", fields = { single_setpoint_c = "18" } },
  })
  local released = lastSent("HOLD_MODE_CHANGED")
  T.check("the hold is taken down when its preset goes", released ~= nil and released.params.MODE == "Off")

  -- The distinguishing claim: a later state report must not raise it again.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  local raised = lastSent("HOLD_MODE_CHANGED")
  T.check("and a later state report does not raise it again", raised == nil)
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
  T.check("the first report after a reload states the hold mode", hold ~= nil and hold.params.MODE == "Off")

  -- Mirror case: a no-match report resolves to "none"; both sentinels need exercising.
  dofile(DRIVER)
  OnDriverLateInit()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 30 })
  local preset = lastSent("PRESET_CHANGED")
  T.check("and states that no preset is active", preset ~= nil and preset.params.NAME == "None")
  clearHold()
end)

test("The proxy's own hold wording survives a reload", function()
  -- The learned hold wording must survive a reload. Asserted on the list the
  -- driver offers afterwards, not on storage.
  scheduledFixture()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Next Event" })

  local stored = Deserialize(C4:PersistGetValue("HoldWording"))
  T.check("the learned wording persists in a form that deserialises", type(stored) == "table")
  T.eq("and it round-trips to what the proxy said", stored and stored.mode, "Next Event")

  -- A real reload: the in-memory value is still set, so only re-loading the chunk observes the restore.
  dofile(DRIVER)
  local ok, err = pcall(OnDriverLateInit)
  T.check("OnDriverLateInit survives the restore" .. (ok and "" or ": " .. tostring(err)), ok)

  resetSent()
  disconnect()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 20 })
  local offered = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  T.check("the hold modes are published on the connection after the reload", offered ~= nil)
  if offered ~= nil then
    T.eq("using the wording the proxy taught it", offered.params.MODES, "Off,Next Event")
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
  T.check("a matching preset is reported", reported ~= nil)
  if reported ~= nil then
    T.eq("the preset that pins down more of the state wins", reported.params.NAME, "Zoned")
  end

  -- Stable across a rebuild that delivers the list in a different order.
  resetSent()
  setPresets({
    { name = "Zoned", fields = { hvac_mode = "Cool", single_setpoint_c = "22", fan_mode = "Quiet" } },
    { name = "Basic", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
  })
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, custom_fan_mode = "Quiet" })
  local again = lastSent("PRESET_CHANGED")
  T.check("and it does not flip when the list is rebuilt", again == nil or again.params.NAME == "Zoned")
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
  T.check("an omitted temperature on a device that measures one is a reading of zero", temp ~= nil)
  if temp ~= nil then
    T.eq("reported as zero", temp.params.TEMPERATURE, "0")
  end
  local humidity = lastSent("HUMIDITY_CHANGED")
  T.check("and the same for humidity", humidity ~= nil)
  if humidity ~= nil then
    T.eq("reported as zero percent", humidity.params.HUMIDITY, "0")
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

  T.eq("no temperature is invented", lastSent("TEMPERATURE_CHANGED"), nil)
  T.eq("and no humidity is invented", lastSent("HUMIDITY_CHANGED"), nil)
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
  T.check("the stored schedule survives an unreadable frame", type(stored) == "table" and #stored == 1)
  T.eq("and the hold modes are not withdrawn", lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil)

  -- The real clear still works.
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  local withdrawn = lastSent("ALLOWED_HOLD_MODES_CHANGED")
  T.check("an empty document still clears the schedule", withdrawn ~= nil and withdrawn.params.MODES == "")
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

  T.eq("no command is sent to an absent device", lastCommandBody(), nil)
  T.eq("and no hold is claimed for it", lastSent("HOLD_MODE_CHANGED"), nil)
  T.eq("and no mode change is reported", lastSent("HVAC_MODE_CHANGED"), nil)

  -- Releasing a hold must work while the device is down.
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Until Next" })
  resetSent()
  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Off" })
  local released = lastSent("HOLD_MODE_CHANGED")
  T.check("a hold can still be released while disconnected", released ~= nil and released.params.MODE == "Off")
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
  T.check("OnDriverLateInit survives the restore", ok)

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

  T.eq("an unchanged resend after a reload writes nothing to flash", writes, 0)
end)

test("The proxy is not sent a notification it does not implement", function()
  -- ONLINE_CHANGED is absent from the thermostat notification set and Control4's
  -- own thermostat never sends it. Connection state travels on CONNECTION.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  T.eq("no ONLINE_CHANGED on a state report", lastSent("ONLINE_CHANGED"), nil)
  local connection = lastSentWith("CONNECTION", "CONNECTED")
  T.check("and the connection is still announced", connection ~= nil)
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
  T.eq("the inherited event does not command the water heater", lastCommandBody(), nil)
  T.eq("and does not move its hold state", lastSent("HOLD_MODE_CHANGED"), nil)
  local stored = C4:PersistGetValue("ScheduledPreset")
  local marker = stored and Deserialize(stored)
  T.check("and does not record it as applied", not (type(marker) == "table" and marker.preset == "Morning"))
  -- A schedule edit that reaches it must not offer a hold control either. The
  -- list goes empty and back so that, ungated, it would have to be re-sent.
  resetSent()
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Morning" } }) })
  T.eq("and a schedule edit offers a water heater no hold modes", lastSent("ALLOWED_HOLD_MODES_CHANGED"), nil)
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
  T.eq("nothing is commanded at a device that is down", lastCommandBody(), nil)

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  T.check("the edit is applied once the device is back", body ~= nil and body.target_temperature == 24)
  clearHold()
end)

test("A scheduled preset commanded just before a drop is sent again on reconnect", function()
  -- The name is persisted as applied when the command goes out, before confirmation;
  -- a drop in that window must mark it pending or the reconnect repeat is ignored.
  scheduledFixture()
  resetSent()
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Away" })
  local sent = lastCommandBody()
  T.check("the event is commanded", sent ~= nil and sent.target_temperature == 18)

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local again = lastCommandBody()
  T.check("and sent again to a device that came back unconfirmed", again ~= nil and again.target_temperature == 18)
  clearHold()
end)

---------------------------------------------------------------------------

SendToProxy = originalSendToProxy

T.finish()
