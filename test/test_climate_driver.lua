#!/usr/bin/env luajit
--- Unit tests for the esphome_climate driver's preset, scheduling, hold and
--- swing logic.
---
--- Drives the driver through its public RFP entry points against the C4 shim -
--- no device, no network, no controller. SendToProxy is captured so each test
--- asserts on what the driver actually emitted.
---
--- Run:
---   ./run_test.sh test_climate_driver.lua --timeout 30
---
--- Note: OnDriverInit is deliberately never called. Its --#ifdef DRIVERCENTRAL
--- branches are plain comments in unpreprocessed source, so both arms would
--- execute and require("cloud-client-byte") would fail. The RFP handlers under
--- test do not need it.

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

-- Capture timers so the schedule can be inspected and fired on demand instead
-- of waiting out real time.
TIMERS_ARMED = 0
local LAST_TIMER = nil

function C4:SetTimer(milliseconds, callback, repeating)
  TIMERS_ARMED = TIMERS_ARMED + 1
  LAST_TIMER = { ms = milliseconds, callback = callback, repeating = repeating }
  return {
    Cancel = function()
      LAST_TIMER = nil
    end,
  }
end

--- Fire the most recently armed timer, as the scheduler would at its due time.
local function fireTimer()
  local timer = LAST_TIMER
  if timer == nil then
    return false
  end
  LAST_TIMER = nil
  timer.callback()
  return true
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
--- four swing options. Mirrors the live entity read off real hardware.
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
  -- supports_two_point_target_temperature is the device's own declaration, not a
  -- guess. A mini-split offers HEAT and COOL as modes while holding ONE target,
  -- so mode support must not be used to infer setpoint count. Auto survives via
  -- hvac_modes, which is published independently of these capabilities.
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
  -- A real two-point device keeps whatever deadband the proxy wants; we must
  -- not flatten a device that genuinely holds two independent setpoints.
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
    -- This device declares one target, so the proxy runs single and the template
    -- must carry single_setpoint. Offering heat/cool here would render fields the
    -- device cannot honour and silently discard one of the two on apply.
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
  -- Some heads advertise CLIMATE_SWING_OFF and nothing else. The Extras selector
  -- already withholds itself in that case; the preset template has to agree, or
  -- the editor renders a Swing dropdown whose only entry is "Off".
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
  -- The real Mitsubishi case. The head has ONE target_temperature, but because it
  -- advertises both HEAT and COOL, detectSetpointCaps reports has_single_setpoint
  -- = false and the proxy runs in heat/cool mode - so presets carry
  -- heat_setpoint/cool_setpoint, never single_setpoint.
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
  -- Captured from OS 4.2.1 driving a Mitsubishi head (2026-08-06). Kept byte-for
  -- byte: it exercises the real attribute escaping, the proxy auto-inserting the
  -- second temperature scale, and a preset that omits hvac_mode entirely.
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

test("SET_EVENTS is parsed and arms a timer (the driver keeps time)", function()
  -- The proxy emits SET_EVENT only when the ACTIVE scheduled preset CHANGES, so
  -- an event re-selecting the preset already in force produces nothing. Captured
  -- from hardware: the schedule was saved at 14:59, SET_EVENT fired immediately,
  -- and the 15:05 boundary passed in silence. The driver has to run the clock.
  local REAL = '<events><event preset="Cool after work" weekday="5" hour="15" minute="5"/></events>'

  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Cool after work", fields = { hvac_mode = "Cool", cool_setpoint_c = "24" } },
  })
  resetSent()

  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = REAL })

  -- Parsing must not itself apply anything; only the timer firing may.
  check(lastCommandBody() == nil, "SET_EVENTS alone sends no device command")
  check(TIMERS_ARMED > 0, "a schedule timer was armed")
end)

test("REGRESSION: the scheduled time applies the preset and clears the hold", function()
  -- Reproduces 2026-08-07: schedule set for 15:05, setpoint nudged by hand at
  -- 14:59 (correctly entering "Until Next"), then 15:05 passed and NOTHING
  -- happened - no proxy SET_EVENT, no local timer, hold never released.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Cool after work", fields = { hvac_mode = "Cool", cool_setpoint_c = "24" } },
  })
  -- Both arrive together on a schedule save, exactly as captured at 14:59:15.
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Cool after work" weekday="5" hour="15" minute="5"/></events>',
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Cool after work" })

  -- User diverges by hand; the hold engages.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 21 })
  local engaged = lastSent("HOLD_MODE_CHANGED")
  check(engaged ~= nil and engaged.params.MODE ~= "Off", "manual change engaged a hold")
  resetSent()

  -- The scheduled minute arrives.
  check(fireTimer(), "the schedule timer fired")

  local body = lastCommandBody()
  check(body ~= nil, "the head was commanded at the scheduled time")
  if body then
    checkEqual(body.target_temperature, 24, "scheduled preset's setpoint applied")
  end
  local hold = lastSent("HOLD_MODE_CHANGED")
  check(hold ~= nil and hold.params.MODE == "Off", "hold released at the next event")
  check(TIMERS_ARMED > 0, "the next occurrence was re-armed")
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

test("REGRESSION: SET_EVENT records the scheduled preset without applying it", function()
  -- The proxy sends SET_EVENT when the schedule is SAVED as well as at a
  -- boundary. Captured 15:17:43: schedule saved for 15:20, SET_EVENT arrived
  -- 7 ms later, and applying it changed the head three minutes early.
  -- Control4's own driver only records the name; the local timer applies.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  clearHold()

  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
  check(lastCommandBody() == nil, "SET_EVENT alone sends NO device command")

  -- But it must still be tracked, or hold reconciliation has no reference.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 30 })
  local held = lastSent("HOLD_MODE_CHANGED")
  check(held ~= nil and held.params.MODE ~= "Off", "it is still tracked as the scheduled preset")
end)

test("Diverging from the scheduled preset holds, returning to it releases", function()
  local entity = singleSetpointEntity()
  resetSent()
  updateState(entity, { mode = Mode.OFF })
  setPresets({
    { name = "Morning", fields = { hvac_mode = "Heat", single_setpoint_c = "21" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Morning" })
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
  -- A preset selecting Off/Off is matched against a state frame that omits
  -- mode and swing_mode entirely - which is exactly what the wire carries when
  -- both are at their zero value. Reading absence as "unknown" made this preset
  -- unmatchable, so the hold it triggered could never be released.
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
  -- SET_PRESETS arrives whenever the preset list changes at all, including when
  -- a schedule event is attached. Re-applying on every rebuild made a preset
  -- fire the moment it was scheduled, and undid manual changes afterwards.
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
  -- Offering a heat setpoint to a cool-only device invites a preset that
  -- silently does nothing, so each setpoint field is gated on the mode that
  -- would use it. can_preset is off in driver.xml and turned on here once an
  -- entity is attached.
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
  -- matchAnyPreset runs on EVERY climate state report, not only the one that
  -- confirms the command. A thermostat pushes ambient temperature on its own
  -- schedule through that same message, so a report can land after the command
  -- and before the device has moved.
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
  -- One emitter: matchAnyPreset, driven by the state report. applyPreset sends
  -- the command and says nothing, so the confirmation is the only announcement.
  -- This catches an outbound announce being re-added without the suppression
  -- that used to accompany it. Two other guards cover the rest: "Applying a
  -- preset sends every field in one command" asserts nothing is announced before
  -- the device confirms, which is the most direct statement of the design, and
  -- "An unrelated state report between apply and confirm" catches the announce
  -- being re-added with the suppression.
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
  -- Repeating the active preset on every state report is noise, and sending
  -- nothing once state moves off it leaves the app highlighting a preset the
  -- device has already left.
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
  -- supported_custom_fan_modes comes straight from the device's YAML. An
  -- ampersand or a quote in one would close the attribute early and hand the
  -- proxy markup it cannot parse, taking the whole preset editor down with it.
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
  -- SCHEDULE, SCHEDULE_TIMER and armScheduleTimer were declared below
  -- OnDriverLateInit, so the restore path resolved both to globals: the
  -- assignment wrote a global nothing reads, and the call hit a nil. The driver
  -- only reached it when a schedule had actually been persisted, and the
  -- CONNECTION notify resent SET_EVENTS afterwards, so the schedule still ran
  -- and the crash stayed invisible.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.OFF })
  setPresets({ { name = "Night", fields = { hvac_mode = "Heat", single_setpoint_c = "18" } } })

  -- Persist a schedule the way RFP.SET_EVENTS does, then reload.
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", {
    XML = '<events><event preset="Night" weekday="1" hour="6" minute="30"/></events>',
  })
  check(C4:PersistGetValue("Schedule") ~= nil, "schedule was persisted")

  TIMERS_ARMED = 0
  local ok, err = pcall(OnDriverLateInit)
  check(ok, "OnDriverLateInit does not throw with a persisted schedule" .. (ok and "" or ": " .. tostring(err)))
  check(TIMERS_ARMED > 0, "the restored schedule arms a timer")
end)

test("A preset that constrains nothing is not stored", function()
  -- parsePresetFields drops empty-valued fields, so an all-empty preset parses to
  -- {}. matchPreset guards every field with "if preset.X ~= nil" and ends in
  -- "return true", so an empty table matches EVERY state. Stored, it would be
  -- announced as active against any state at all.
  --
  -- Deliberately the ONLY preset in the list: asserting which of several presets
  -- wins would depend on Lua's pairs order, which is not deterministic, and such
  -- a test passes or fails by luck rather than by behaviour.
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
  -- reconcileHold runs on every climate state report. Raising a hold from the UI
  -- without changing anything leaves state matching the scheduled preset, so an
  -- unconditional release cancelled the user's hold on the next ambient push -
  -- which arrives within seconds.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Cool 22", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
  })
  RFP.SET_EVENT(PROXY, "SET_EVENT", { PRESET = "Cool 22" })
  clearHold()

  RFP.SET_MODE_HOLD(PROXY, "SET_MODE_HOLD", { MODE = "Until Next" })
  resetSent()
  -- An ambient temperature push: state still matches the scheduled preset.
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22, current_temperature = 24 })
  local released = lastSent("HOLD_MODE_CHANGED")
  check(released == nil, "the user's hold is not cancelled by a matching report")
end)

test("Water heaters are not offered presets", function()
  -- The preset field template is climate shaped and is deliberately not published
  -- for water heaters. Declaring CAN_PRESET anyway serves the static driver.xml
  -- template instead, and applying one is a wire level no-op because the body
  -- serialises against WaterHeaterCommandRequest with nothing set.
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

test("Two events at the same weekday and time both fire", function()
  -- A strict "first wins" tie-break starved the later event permanently: after
  -- the winner fires both resolve to the same instant seven days out, and the
  -- same one wins again every week.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "First", fields = { hvac_mode = "Cool", single_setpoint_c = "20" } },
    { name = "Second", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } },
  })

  local t = os.date("*t", os.time() + 120)
  local xml = string.format(
    '<events><event preset="First" weekday="%d" hour="%d" minute="%d"/>'
      .. '<event preset="Second" weekday="%d" hour="%d" minute="%d"/></events>',
    t.wday - 1,
    t.hour,
    t.min,
    t.wday - 1,
    t.hour,
    t.min
  )
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = xml })
  resetSent()
  fireTimer()

  -- Both are applied in schedule order, so the last one settles the device.
  local body = lastCommandBody()
  check(body ~= nil, "the tied events commanded the device")
  if body then
    checkEqual(body.target_temperature, 26, "the second event was not starved")
  end
end)

test("Releasing a hold with no schedule clears the held preset", function()
  -- HOLD_PRESET was cleared only inside "if SCHEDULED_PRESET ~= nil", so after a
  -- release with no schedule a later edit to that preset was still pushed to the
  -- device through the activeAfter path.
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
  -- The template authors at 0.5 C. A device quantising to 1 C echoes 22 back for
  -- a 21.5 preset, and matchPreset allows only 0.25 C, so the preset never
  -- matches again: the hold sticks on and the preset stops highlighting.
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

--- Schedule XML for one or more events. The weekday/time never matter here:
--- fireTimer() invokes the armed callback directly rather than waiting.
local function eventsXml(entries)
  local parts = { "<events>" }
  for _, e in ipairs(entries) do
    parts[#parts + 1] =
      string.format('<event preset="%s" weekday="1" hour="%d" minute="%d"/>', e.preset, e.hour or 6, e.minute or 0)
  end
  parts[#parts + 1] = "</events>"
  return table.concat(parts)
end

test("A boundary naming an unknown preset is deferred, then runs when it arrives", function()
  -- SCHEDULE is persisted but PRESETS is not, and the proxy only resends
  -- SET_PRESETS after the device connects. Without a deferral the boundary is
  -- lost until the same weekday next week, because the re-arm resolves the just
  -- missed occurrence seven days out and nothing retries when presets land.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Later" } }) })

  resetSent()
  fireTimer()
  check(lastCommandBody() == nil, "an unknown preset commands nothing at the boundary")

  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Later", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } },
  })
  local body = lastCommandBody()
  check(body ~= nil, "the deferred boundary ran once its preset was known")
  if body then
    checkEqual(body.target_temperature, 26, "and it applied the deferred preset value")
  end
end)

test("A boundary crossed while the device is down is deferred, not dropped", function()
  -- The sibling of the unknown-preset case, and the more common one: an outage
  -- WITHOUT a driver reload leaves PRESETS populated, so the boundary takes the
  -- apply branch, hands ENTITY_COMMAND to a bridge that rejects it while
  -- disconnected, and only logs. Nothing recovers on reconnect either: the
  -- SET_PRESETS re-apply path needs a signature CHANGE, which a plain resend is
  -- not. The boundary would be lost for a week and AWAITING_SCHEDULED would
  -- raise a phantom hold on top.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Known", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Known" } }) })

  -- Device drops. The preset stays in memory; only the entity goes away.
  disconnect()
  resetSent()
  fireTimer()
  check(lastCommandBody() == nil, "the boundary commands nothing at a device that is down")

  -- Reconnect alone must run it. Deliberately no SET_PRESETS here: the presets
  -- never left memory, so nothing would make the proxy resend them, and a
  -- deferral that only drained through SET_PRESETS would sit here forever.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  check(body ~= nil, "the boundary is applied once the device is back")
  if body then
    checkEqual(body.target_temperature, 26, "and it applies the scheduled preset value")
  end
end)

test("A deferred boundary is NOT consumed while the device is still down", function()
  -- SET_PRESETS is proxy traffic: it arrives whenever the preset list changes at
  -- all, including a user editing some unrelated preset in the app while the
  -- device is still offline. Consuming the deferral there clears the pending name
  -- from memory AND from persist, then hands the command to a bridge that rejects
  -- it while disconnected and only logs - there is no queue and no retry. The
  -- boundary would be silently lost until the same weekday next week, which is
  -- the exact failure the deferral exists to prevent.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Late" } }) })
  fireTimer()

  disconnect()
  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "21" } },
    { name = "Late", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } },
  })
  check(lastCommandBody() == nil, "nothing is commanded at a device that is down")

  -- The claim is not merely that it stayed quiet: it is that the boundary is
  -- still owed once the device comes back. The preset list already landed during
  -- the outage, so the device is the half arriving last and the reconnect is
  -- what drains the deferral.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  local body = lastCommandBody()
  check(body ~= nil, "the deferral survived the outage and runs on reconnect")
  if body then
    checkEqual(body.target_temperature, 26, "and it applies the deferred preset value")
  end
end)

test("Renaming a preset carries a deferred boundary with it", function()
  -- The rename block already carries SCHEDULED_PRESET and HOLD_PRESET across
  -- previous_name. A deferred name has to travel too: a rename resends the list
  -- and is followed by SET_EVENTS carrying the new name, whose drop-block deletes
  -- any pending event no longer named in the schedule. Leaving it behind loses
  -- the boundary for a week.
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Before" } }) })
  fireTimer()

  -- Renamed in the C4 UI while the boundary is still deferred. The proxy resends
  -- the list carrying previous_name, then resends the schedule under the new name.
  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "After", previous = "Before", fields = { hvac_mode = "Cool", single_setpoint_c = "27" } },
  })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "After" } }) })

  local body = lastCommandBody()
  check(body ~= nil, "the renamed preset still runs its deferred boundary")
  if body then
    checkEqual(body.target_temperature, 27, "and it applies the renamed preset value")
  end
end)

test("A preset still matches after the device echoes a CLAMPED setpoint", function()
  -- Same failure as the SNAPPED case above, on the other transform.
  -- applyPresetSetpoints sends clampTemperature(snapToStep(v)), so a preset
  -- above the device's range reaches the wire at the clamp boundary and the
  -- device echoes that number back. A comparison that snaps but does not clamp
  -- never matches it: the preset stops highlighting and the hold sticks on.
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
  -- getEntityTempStep and the resolution publisher both fall back from
  -- visual_target_temperature_step to target_temperature_step. snapToStep must
  -- use the same fallback or a device that reports only the plain field goes
  -- unsnapped, keeping the quantisation bug alive for exactly that device.
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

test("A deferred boundary is dropped when its schedule is deleted", function()
  -- Nothing else clears it: with the schedule gone no future boundary can
  -- overwrite the pending name, so it would stay armed and fire against any
  -- later preset list that happens to contain that name.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Ghost" } }) })
  fireTimer()

  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = "<events></events>" })

  resetSent()
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Ghost", fields = { hvac_mode = "Cool", single_setpoint_c = "18" } },
  })
  check(lastCommandBody() == nil, "the orphaned pending event does not command the device")
end)

test("A deferred boundary survives a reload and still applies", function()
  -- Globals do not survive a driver reload, so state that has to outlive one
  -- belongs in persist. The first version of this test asserted only that the
  -- value could be read back out of persist, and passed while the restore inside
  -- OnDriverLateInit was compiling as a write to a GLOBAL of the same name,
  -- because the local was declared further down the file. Every consumer read
  -- the nil local, so the persistence was dead code and the suite was green.
  --
  -- Storage is necessary but is NOT the claim. The claim is that a deferred
  -- boundary still applies after a reload, so that is what this asserts: restore
  -- from persist, then deliver the preset, then require the device command.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Persisted" } }) })
  fireTimer()

  local stored = Deserialize(C4:PersistGetValue("PendingEvent"))
  check(type(stored) == "table", "the deferred event persists in a form that deserialises")
  checkEqual(stored and stored.preset, "Persisted", "and it round-trips to the deferred name")

  -- Simulate the reload PROPERLY. Calling OnDriverLateInit alone is not a
  -- reload: the in-memory local is still populated from fireTimer above, so the
  -- restore is a no-op and a dead restore goes unnoticed. Re-loading the chunk
  -- gives the driver fresh locals, which is what a real reload does, and is the
  -- only way this test can observe whether the restore actually lands.
  dofile(DRIVER)
  local ok, err = pcall(OnDriverLateInit)
  check(ok, "OnDriverLateInit survives the restore" .. (ok and "" or ": " .. tostring(err)))

  -- The behavioural assertion. This is the one that catches a dead restore.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({
    { name = "Other", fields = { hvac_mode = "Cool", single_setpoint_c = "22" } },
    { name = "Persisted", fields = { hvac_mode = "Cool", single_setpoint_c = "24" } },
  })
  local body = lastCommandBody()
  check(body ~= nil, "the deferred boundary applies after the reload")
  if body then
    checkEqual(body.target_temperature, 24, "and it applies the deferred value")
  end
end)

test("A preset still matches after the device echoes the SNAPPED setpoint", function()
  -- This is the whole point of snapping. The template authors at 0.5 while the
  -- device quantises to 1, so a 21.5 preset goes out as 22 and comes back as 22.
  -- Comparing the raw 21.5 fails by 0.5 against a 0.25 tolerance and the preset
  -- never matches again: the hold sticks on and the preset stops highlighting.
  -- Snapping only the outgoing command does NOT fix that; the symptom lives on
  -- the comparison side.
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

test("One stale report after a scheduled boundary does not flap the hold", function()
  -- A report landing between the command and the confirmation still describes
  -- the OLD state. Reconciling against it raises a hold that the confirmation
  -- drops a moment later: two spurious programmable events per boundary.
  -- Exactly one report is suppressed, because more than that could wedge.
  disconnect()
  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  setPresets({ { name = "Evening", fields = { hvac_mode = "Cool", single_setpoint_c = "26" } } })
  RFP.SET_EVENTS(PROXY, "SET_EVENTS", { XML = eventsXml({ { preset = "Evening" } }) })
  clearHold()
  fireTimer()

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  check(lastSent("HOLD_MODE_CHANGED") == nil, "the stale report does not raise a hold")

  resetSent()
  updateState(singleSetpointEntity(), { mode = Mode.COOL, target_temperature = 22 })
  check(lastSent("HOLD_MODE_CHANGED") ~= nil, "a genuine divergence still raises one on the next report")
end)

test("A lone Off swing mode produces no Extras state echo", function()
  -- The selector is only published when more than one mode is offered, so
  -- echoing state for a lone Off fired EXTRAS_STATE_CHANGED on every push for an
  -- object that was never declared, with no transition guard.
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

---------------------------------------------------------------------------

SendToProxy = originalSendToProxy

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
