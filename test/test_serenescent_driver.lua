--- Tests the esphome_serenescent driver's connection cycle, command queue and
--- bindings, driven through the same entry points Director calls
--- (ReceivedFromProxy, ExecuteCommand, OnBindingChanged) with the proxy traffic
--- captured at C4:SendToProxy.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_serenescent_driver.lua
---
--- Nobody on the project owns a diffuser, so the device side is the Home Assistant
--- integration's recorded behaviour: an ack echoes the command byte, the status
--- reply is the one real capture in its PROTOCOL.md (varied a field at a time),
--- and control commands only take in HOME mode.
---
--- The driver's real driver.xml backs C4:GetDriverConfigInfo("config") and seeds
--- Properties, so a property the Lua writes that the XML does not declare, or a
--- value outside a declared range, shows up as an UpdateProperty error here.
---
--- OnDriverInit is never called: its --#ifdef DRIVERCENTRAL arms are plain
--- comments in unpreprocessed source, so both would run and require
--- "cloud-client-byte". Nothing under test needs it.

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

-- Resolved against this file rather than the working directory: run_test.sh cds
-- into test/, make test runs from the repo root, and dofile takes a path rather
-- than going through LUA_PATH.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/esphome_serenescent/driver.lua"
local XML = HERE .. "/../drivers/esphome_serenescent/driver.xml"

local protocol = require("esphome.ble.serenescent_protocol")
local persist = require("lib.persist")
local values = require("lib.values")

local ESPHOME, RELAY = 5002, 308
local TX, RX = 12, 14

local function readFile(path)
  local fh = assert(io.open(path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end

local function hex(data)
  return ((data:gsub(".", function(c)
    return string.format("%02X ", c:byte())
  end)):gsub(" $", ""))
end

---------------------------------------------------------------------------
-- Environment
---------------------------------------------------------------------------

local CONFIG = readFile(XML):match("<config>(.*)</config>")

function C4:GetDriverConfigInfo(key)
  if key == "config" then
    return CONFIG
  end
  local info = { minimum_os_version = "3.3.0", model = "ESPHome SereneScent", version = "test" }
  return info[key]
end

-- Director keeps Properties current; the shim's UpdateProperty is a no-op.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

-- Only used to render bytes into log lines.
function C4:Encode(data)
  return hex(data)
end

-- Every property driver.xml declares, at its default, as Director seeds them.
for block in CONFIG:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end

-- Handler and property errors are printed, not raised; collect them so a test
-- can fail on them instead of on a missing side effect.
local errors = {}
local realPrint = print
print = function(...) -- luacheck: ignore
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring((select(i, ...)))
  end
  local line = table.concat(parts, " ")
  if line:find("error", 1, true) then
    table.insert(errors, line)
  end
  realPrint(line)
end

--- Everything sent since the last reset, captured at the far end of the
--- SendToProxy wrapper.
local sent = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams, strMessage)
  table.insert(sent, { binding = idBinding, command = strCommand, params = tParams or {}, message = strMessage })
end

local function count(command, binding)
  local n = 0
  for _, s in ipairs(sent) do
    if s.command == command and (binding == nil or s.binding == binding) then
      n = n + 1
    end
  end
  return n
end

--- The GATT writes sent since the last reset, decoded, as hex strings.
local function writes()
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == "GATT_WRITE" then
      T.eq("GATT_WRITE goes to the TX handle", s.params.handle, tostring(TX))
      T.eq("GATT_WRITE is a write without response", s.params.response, "false")
      table.insert(out, hex(C4:Base64Decode(s.params.data)))
    end
  end
  return out
end

local function lastWrite()
  local w = writes()
  return w[#w]
end

local function clearTimers()
  local names = {}
  for name in pairs(Timer) do
    if type(name) == "string" then
      table.insert(names, name)
    end
  end
  for _, name in ipairs(names) do
    CancelTimer(name)
  end
end

local function armed(name)
  return Timer[name] ~= nil
end

--- The delay each named timer was last armed with.
local delays = {}
local realSetTimer = SetTimer
SetTimer = function(id, delay, fn, repeating) -- luacheck: ignore
  delays[id] = delay
  return realSetTimer(id, delay, fn, repeating)
end

--- The timers that belong to one connection cycle; none may outlive it.
local CYCLE_TIMERS = { "ConnectTimeout", "ResponseTimeout", "CommandDelay", "DisconnectDelay", "DisconnectSettle" }

local function armedCycleTimers()
  local out = {}
  for _, name in ipairs(CYCLE_TIMERS) do
    if armed(name) then
      table.insert(out, name)
    end
  end
  return out
end

--- Fire one named timer now, as the controller would when it fell due.
local function fire(name)
  local handle = Timer[name]
  local fn = handle and TimerFunctions[handle]
  if not fn then
    return false
  end
  CancelTimer(name)
  fn(handle, 0)
  return true
end

local function variable(name)
  return Select(values:getValue(name), "value")
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local F = {
  POWER_ON = hex(protocol.powerCommand(true)),
  POWER_OFF = hex(protocol.powerCommand(false)),
  STATUS_HOME = "FF FA 40 05 00",
  STATUS_SCHEDULE = "FF FA 40 05 01",
  MODE_HOME = "FF FA 43 05 00",
  LOW = hex(protocol.intensityCommand("low")),
  MEDIUM = hex(protocol.intensityCommand("medium")),
  HIGH = hex(protocol.intensityCommand("high")),
  RED = hex(protocol.colorCommand("red")),
}

--- PROTOCOL.md's capture: powered on, LOW, WHITE, schedule off, HOME.
local CAPTURED =
  string.char(0xFF, 0xFB, 0x40, 0x06, 0x00, 0x16, 0x00, 0x00, 0x0A, 0x00, 0xF0, 0x7F, 0x02, 0x00, 0x01, 0x00)

--- The capture with fields replaced, by 0-indexed offset.
local function statusFrame(fields)
  local bytes = { CAPTURED:byte(1, -1) }
  local offsets = { intensity = 8, color = 12, schedule = 13, power = 14, mode = 15 }
  for field, value in pairs(fields or {}) do
    bytes[offsets[field] + 1] = value
  end
  return string.char(unpack(bytes))
end

local function ack(opcode)
  return string.char(0xFF, 0xFB, opcode)
end

--- A 128-bit UUID string as the proxy's {high, low} uint64 pairs.
local function uuidPairs(uuid)
  local h = uuid:gsub("-", "")
  local function word(i)
    return tonumber(h:sub(i, i + 7), 16)
  end
  return { { word(1), word(9) }, { word(17), word(25) } }
end

local SERVICES = SerializeSafe({
  {
    uuid = uuidPairs(protocol.UUID.SERVICE),
    characteristics = {
      { uuid = uuidPairs(protocol.UUID.TX), handle = TX },
      { uuid = uuidPairs(protocol.UUID.RX), handle = RX },
    },
  },
})

---------------------------------------------------------------------------
-- Director entry points
---------------------------------------------------------------------------

local function rfp(command, params, binding)
  ReceivedFromProxy(binding or ESPHOME, command, params or {})
end

local function advertise(rssi)
  rfp("BLE_ADVERTISEMENT", { advertisement = SerializeSafe({ rssi = rssi or -60 }) })
end

local function connected(services)
  rfp("CONNECTED", { name = "ARMH-972", mac = "AA:BB:CC:DD:EE:FF", services = services or SERVICES })
end

local function subscribed(success)
  rfp("GATT_NOTIFY_SUBSCRIBED", { handle = tostring(RX), success = success == false and "false" or "true" })
end

local function notify(data)
  rfp("GATT_NOTIFY_DATA", { handle = tostring(RX), data = C4:Base64Encode(data) })
end

local function command(name, params)
  ExecuteCommand(name, params or {})
end

--- Reload the driver as a controller boot does: module state is new, persisted
--- state is what the last session left.
local function boot()
  clearTimers()
  dofile(DRIVER)
  OnDriverLateInit()
  sent = {}
end

--- A fresh install: nothing persisted from an earlier run.
local function install()
  persist:delete("deviceState")
  values:reset()
  boot()
end

--- Up to the point the status query is on the wire.
local function openLink()
  connected()
  subscribed()
end

--- Answer every write the way the device does until the status query goes out,
--- and return everything written. Seeing the whole sequence is what shows an
--- action ran exactly once rather than once plus a duplicate queued behind it.
local function drain()
  for _ = 1, 20 do
    local last = lastWrite()
    local opcode = last and tonumber(last:sub(7, 8), 16)
    if not opcode or opcode == protocol.Opcode.STATUS then
      break
    elseif opcode == protocol.Opcode.MODE then
      fire("CommandDelay")
    else
      notify(ack(opcode))
    end
  end
  return writes()
end

--- The coordinator's immediate answer to our DISCONNECT.
local function answerDisconnect()
  rfp("DISCONNECTED", { reason = "Requested" })
end

--- A whole healthy cycle for a status read, leaving the slot released.
local function readStatus(frame)
  command("Request Status")
  openLink()
  notify(frame or CAPTURED)
  fire("DisconnectDelay")
  answerDisconnect()
end

--- Name a group and run it, so a throw inside one case is one recorded failure
--- rather than the end of the run.
local function test(name, fn)
  T.section(name)
  errors = {}
  local ok, err = pcall(fn)
  T.check("ran without throwing", ok, err)
  T.check("no handler or property errors", #errors == 0, table.concat(errors, "\n"))
end

---------------------------------------------------------------------------
-- Connection cycle
---------------------------------------------------------------------------

test("a cold start reads status on the first advertisement, then frees the slot", function()
  install()
  T.eq("starts disconnected", Properties["Driver Status"], "Disconnected")
  T.eq("Connected is false", variable("Connected"), false)

  advertise(-61)
  T.eq("the first advertisement connects", count("CONNECT"), 1)
  T.eq("and shows the RSSI", Properties["RSSI"], "-61 dBm")
  -- Property only, like every BLE sibling
  T.eq("RSSI is not a variable", Variables["RSSI"], nil)
  T.eq("Last Seen is not a variable", Variables["Last Seen"], nil)
  advertise()
  T.eq("a second advertisement does not connect again", count("CONNECT"), 1)

  connected()
  T.eq("CONNECTED subscribes to the RX handle", count("GATT_NOTIFY"), 1)
  T.eq("on the RX handle", sent[#sent].params.handle, tostring(RX))
  T.eq("nothing is written before notifications are on", #writes(), 0)

  T.truthy("the connect timeout covers subscribing", armed("ConnectTimeout"))
  subscribed()
  T.falsy("and is disarmed once subscribed", armed("ConnectTimeout"))
  T.eq("Connected is true once subscribed", variable("Connected"), true)
  T.check("the status query goes out", T.deepEqual(writes(), { F.STATUS_HOME }), T.show(writes()))

  notify(CAPTURED)
  T.falsy("the reply disarms its timeout", armed("ResponseTimeout"))
  T.eq("a status reply leaves Last Seen a property only", Variables["Last Seen"], nil)
  T.eq("Power", variable("Power"), "On")
  T.eq("Intensity", variable("Intensity"), "low")
  T.eq("Color", variable("Color"), "white")
  T.eq("the property mirrors the variable", Properties["Power"], "On")
  T.eq("the name comes from CONNECTED", Properties["Name"], "ARMH-972")
  T.eq("the MAC comes from CONNECTED", Properties["MAC Address"], "AA:BB:CC:DD:EE:FF")
  T.eq("it lingers before disconnecting", count("DISCONNECT"), 0)

  T.truthy("a delayed disconnect is armed", fire("DisconnectDelay"))
  T.eq("then releases the slot", count("DISCONNECT"), 1)
  T.eq("and waits for the next poll", Properties["Driver Status"], "Listening (next poll in 5m)")
  T.eq("a healthy cycle stays Connected", variable("Connected"), true)
  T.truthy("the poll is armed", armed("PollCycle"))

  -- The proxy answers our DISCONNECT; that is not a failure.
  answerDisconnect()
  T.eq("the answering DISCONNECTED changes nothing", Properties["Driver Status"], "Listening (next poll in 5m)")
  T.eq("and keeps Connected", variable("Connected"), true)
  T.truthy("and keeps the poll", armed("PollCycle"))
  T.check("and no cycle timer is left", #armedCycleTimers() == 0, T.show(armedCycleTimers()))

  sent = {}
  fire("PollCycle")
  T.eq("the poll connects again", count("CONNECT"), 1)
  T.eq("Connected stays true while the poll connects", variable("Connected"), true)
end)

test("a CONNECTED nobody asked for reads status instead of holding the slot", function()
  -- The standalone proxy connects an active device as soon as it is bound.
  install()
  OnBindingChanged(ESPHOME, "ESPHOME_SERENESCENT", true, 100, 1)
  T.eq("binding waits for data", Properties["Driver Status"], "Waiting for data")
  sent = {}

  openLink()
  T.check("it queries status", T.deepEqual(writes(), { F.STATUS_HOME }), T.show(writes()))
  notify(CAPTURED)
  fire("DisconnectDelay")
  T.eq("and releases the slot", count("DISCONNECT"), 1)
  T.truthy("and starts polling", armed("PollCycle"))
  answerDisconnect()

  -- The advertisement after it must not start a second read of its own.
  sent = {}
  advertise()
  T.eq("the first advertisement does not reconnect", count("CONNECT"), 0)
  T.truthy("and leaves the poll armed", armed("PollCycle"))
end)

test("a fresh bind through the coordinator starts reading on the first advertisement", function()
  -- The coordinator never connects on bind; it waits for CONNECT.
  install()
  OnBindingChanged(ESPHOME, "ESPHOME_SERENESCENT", true, 100, 1)
  sent = {}
  advertise()
  T.eq("the advertisement connects", count("CONNECT"), 1)
end)

test("a duplicate CONNECTED is ignored", function()
  install()
  command("Request Status")
  openLink()
  local before = #sent
  connected()
  T.eq("no second subscription", #sent, before)
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

test("commands queued while connecting are all sent, in order, then one status query", function()
  install()
  readStatus()
  sent = {}

  command("Power Off")
  command("Set Color", { Color = "Red" })
  command("Set Intensity", { Level = "high" })
  T.eq("one connection for all three", count("CONNECT"), 1)

  openLink()
  T.check("the first command is written", T.deepEqual(writes(), { F.POWER_OFF }), T.show(writes()))
  notify(ack(0x11))
  T.check("its ack releases the next", T.deepEqual(writes(), { F.POWER_OFF, F.RED }), T.show(writes()))
  notify(ack(0x16))
  notify(ack(0x17))
  T.check(
    "and the cycle ends with a single status query",
    T.deepEqual(writes(), { F.POWER_OFF, F.RED, F.HIGH, F.STATUS_HOME }),
    T.show(writes())
  )
end)

test("state is taken from the device's reply, never assumed from the command", function()
  install()
  readStatus(statusFrame({ power = 0 }))
  T.eq("starts off", variable("Power"), "Off")
  sent = {}

  command("Power On")
  openLink()
  notify(ack(0x10))
  T.eq("an ack alone does not turn it on", variable("Power"), "Off")
  T.eq("nor notifies the relay", count("CLOSED", RELAY), 0)

  -- The device acked but did not turn on (e.g. another app holds it).
  notify(statusFrame({ power = 0 }))
  T.eq("the reply wins", variable("Power"), "Off")
  T.eq("so the relay is never told CLOSED", count("CLOSED", RELAY), 0)
end)

test("an ack that never comes does not stall the queue", function()
  install()
  readStatus()
  sent = {}
  command("Set Color", { Color = "Red" })
  openLink()
  T.truthy("the ack timeout is armed", fire("ResponseTimeout"))
  T.check("the status query still goes out", T.deepEqual(writes(), { F.RED, F.STATUS_HOME }), T.show(writes()))
end)

test("only the awaited ack moves the queue on; filler and strays do not", function()
  install()
  readStatus()
  sent = {}
  command("Power Off")
  command("Set Color", { Color = "Red" })
  openLink()
  notify(string.rep("\255", 20))
  notify(string.rep("\0", 20))
  notify(ack(0x10))
  T.check("still waiting on the power-off ack", T.deepEqual(writes(), { F.POWER_OFF }), T.show(writes()))
  notify(ack(0x11))
  T.check("which then releases the next", T.deepEqual(writes(), { F.POWER_OFF, F.RED }), T.show(writes()))
end)

test("SCHEDULE mode: queries in its own form, switches to HOME before a control write", function()
  install()
  readStatus(statusFrame({ mode = 1, schedule = 1 }))
  sent = {}

  command("Request Status")
  openLink()
  T.check(
    "a status read uses the schedule query and does not change the mode",
    T.deepEqual(writes(), { F.STATUS_SCHEDULE }),
    T.show(writes())
  )
  notify(statusFrame({ mode = 1, schedule = 1 }))
  fire("DisconnectDelay")
  answerDisconnect()
  sent = {}

  command("Set Intensity", { Level = "high" })
  openLink()
  T.check("the mode switch goes first", T.deepEqual(writes(), { F.MODE_HOME }), T.show(writes()))
  T.truthy("and settles before the command", fire("CommandDelay"))
  T.check("then the command", T.deepEqual(writes(), { F.MODE_HOME, F.HIGH }), T.show(writes()))
  notify(ack(0x17))
  T.check(
    "and the status query is the HOME form",
    T.deepEqual(writes(), { F.MODE_HOME, F.HIGH, F.STATUS_HOME }),
    T.show(writes())
  )
end)

test("an ack for the mode switch cannot release a later write early", function()
  install()
  readStatus(statusFrame({ mode = 1 }))
  sent = {}
  command("Power On")
  command("Set Color", { Color = "Red" })
  openLink()
  -- The switch is answered before its settle time is up; the next write goes.
  notify(ack(0x43))
  T.check("the switch's ack sends the command", T.deepEqual(writes(), { F.MODE_HOME, F.POWER_ON }), T.show(writes()))
  T.falsy("and cancels the settle timer", armed("CommandDelay"))
  T.check("which is still awaiting its own ack", T.deepEqual(writes(), { F.MODE_HOME, F.POWER_ON }), T.show(writes()))
end)

test("toggle and intensity steps build on what is already queued", function()
  install()
  readStatus(statusFrame({ power = 0, intensity = 10 }))
  sent = {}

  command("Toggle Power")
  command("Toggle Power")
  command("Set Intensity", { Level = "medium" })
  ReceivedFromProxy(303, "DO_CLICK", {})
  ReceivedFromProxy(303, "DO_CLICK", {})
  openLink()
  local got = drain()
  T.check(
    "two toggles undo each other; up steps from the queued level",
    T.deepEqual(got, { F.POWER_ON, F.POWER_OFF, F.MEDIUM, F.HIGH, F.STATUS_HOME }),
    T.show(got)
  )
end)

test("intensity steps clamp at both ends", function()
  install()
  readStatus(statusFrame({ intensity = 30 }))
  sent = {}
  ReceivedFromProxy(303, "DO_CLICK", {})
  T.eq("up at high sends nothing", count("CONNECT"), 0)

  readStatus(statusFrame({ intensity = 10 }))
  sent = {}
  ReceivedFromProxy(304, "DO_CLICK", {})
  T.eq("down at low sends nothing", count("CONNECT"), 0)
end)

test("an intensity never read steps to medium", function()
  install()
  ReceivedFromProxy(304, "DO_CLICK", {})
  openLink()
  T.check("medium", T.deepEqual(writes(), { F.MEDIUM }), T.show(writes()))
end)

test("invalid programming values are refused before connecting", function()
  install()
  command("Set Intensity", { Level = "max" })
  command("Set Color", { Color = "pink" })
  command("Set Color", {})
  T.eq("nothing connects", count("CONNECT"), 0)
end)

test("an unknown status byte keeps the last known value", function()
  install()
  readStatus(statusFrame({ intensity = 20, color = 3 }))
  readStatus(statusFrame({ intensity = 15, color = 9 }))
  T.eq("intensity", variable("Intensity"), "medium")
  T.eq("color", variable("Color"), "red")
end)

test("intensity and color read Off while the diffuser is off", function()
  install()
  readStatus(statusFrame({ power = 0 }))
  T.eq("power", variable("Power"), "Off")
  T.eq("intensity", variable("Intensity"), "Off")
  T.eq("color", variable("Color"), "Off")
end)

---------------------------------------------------------------------------
-- Failures
---------------------------------------------------------------------------

test("a failed connection drops the queue and falls back to polling", function()
  install()
  command("Power On")
  rfp("CONNECTION_FAILED", { error = "No connection slots available" })
  T.eq("status says why", Properties["Driver Status"], "Connection failed: No connection slots available")
  T.eq("Connected is false", variable("Connected"), false)
  T.truthy("the poll is armed", armed("PollCycle"))
  -- The standalone proxy does not answer a DISCONNECT for a slot it never allocated
  T.truthy("the settle fallback is armed", fire("DisconnectSettle"))
  T.eq("and with nothing queued it does not reconnect", count("CONNECT"), 1)

  sent = {}
  advertise()
  T.eq("a later advertisement does not reconnect either", count("CONNECT"), 0)
  fire("PollCycle")
  openLink()
  T.check("the dropped command is not replayed later", T.deepEqual(writes(), { F.STATUS_HOME }), T.show(writes()))
end)

test("a connection that never answers times out and releases the slot", function()
  install()
  command("Power On")
  T.truthy("the connect timeout is armed", fire("ConnectTimeout"))
  T.eq("it sends DISCONNECT so the proxy frees the slot", count("DISCONNECT"), 1)
  T.eq("status says why", Properties["Driver Status"], "Connection timed out")
  T.truthy("the poll is armed", armed("PollCycle"))
end)

test("missing characteristics or a failed subscription release the slot", function()
  install()
  command("Request Status")
  connected(SerializeSafe({}))
  T.eq("missing characteristics disconnect", count("DISCONNECT"), 1)
  T.eq("and say so", Properties["Driver Status"], "Error: Missing characteristics")
  answerDisconnect()

  sent = {}
  command("Request Status")
  connected()
  subscribed(false)
  T.eq("a failed subscription disconnects", count("DISCONNECT"), 1)
  T.eq("and says so", Properties["Driver Status"], "Error: Notification subscription failed")
  T.eq("Connected is false", variable("Connected"), false)
end)

test("no status reply ends the cycle as a failure", function()
  install()
  command("Request Status")
  openLink()
  T.truthy("the reply timeout is armed", fire("ResponseTimeout"))
  T.eq("it disconnects", count("DISCONNECT"), 1)
  T.eq("status says why", Properties["Driver Status"], "No response from device")
  T.eq("Connected is false", variable("Connected"), false)
  T.truthy("the poll is armed", armed("PollCycle"))
end)

test("the device dropping the link mid-cycle is a failure", function()
  install()
  command("Power On")
  openLink()
  rfp("DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("status says why", Properties["Driver Status"], "Disconnected: BLE connection closed")
  T.eq("Connected is false", variable("Connected"), false)
  T.truthy("the poll is armed", armed("PollCycle"))
  T.falsy("the reply timeout is cancelled", armed("ResponseTimeout"))
end)

---------------------------------------------------------------------------
-- Connection edges
---------------------------------------------------------------------------

test("the proxy's answer to our DISCONNECT cannot fail the next cycle", function()
  -- The standalone proxy answers from its allocation callback, which can land
  -- after a new command has already asked to connect.
  install()
  command("Request Status")
  openLink()
  notify(CAPTURED)
  fire("DisconnectDelay")
  sent = {}

  command("Power Off")
  T.eq("a command while the answer is pending does not connect yet", count("CONNECT"), 0)
  rfp("DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("the answer releases it", count("CONNECT"), 1)
  T.eq("and is not reported as a failure", variable("Connected"), true)
  openLink()
  local got = drain()
  T.check("the command is written", T.deepEqual(got, { F.POWER_OFF, F.STATUS_HOME }), T.show(got))
end)

test("with no answer to our DISCONNECT, the settle fallback releases queued commands", function()
  install()
  command("Request Status")
  openLink()
  notify(CAPTURED)
  fire("DisconnectDelay")
  sent = {}
  command("Power Off")
  T.eq("waiting", count("CONNECT"), 0)
  T.truthy("the fallback is armed", fire("DisconnectSettle"))
  T.eq("then it connects", count("CONNECT"), 1)
  connected()
  T.eq("and the new link is used", count("GATT_NOTIFY"), 1)
end)

test("a CONNECTED while disconnecting is not mistaken for the next link", function()
  install()
  command("Request Status")
  openLink()
  notify(CAPTURED)
  fire("DisconnectDelay")
  sent = {}
  connected()
  T.eq("it does not subscribe", count("GATT_NOTIFY"), 0)
end)

test("a subscription that is never confirmed times out and releases the slot", function()
  install()
  OnBindingChanged(ESPHOME, "ESPHOME_SERENESCENT", true, 100, 1)
  sent = {}
  -- The unsolicited CONNECTED on bind arms nothing else that could rescue it
  connected()
  T.truthy("the timeout covers subscribing", fire("ConnectTimeout"))
  T.eq("it disconnects", count("DISCONNECT"), 1)
  T.eq("status says why", Properties["Driver Status"], "Connection timed out")
  T.truthy("and the poll is armed", armed("PollCycle"))
end)

test("a fresh CONNECTED while subscribing starts the subscription over", function()
  install()
  command("Request Status")
  connected()
  connected()
  T.eq("it subscribes again", count("GATT_NOTIFY"), 2)
  subscribed()
  T.check("and carries on", T.deepEqual(writes(), { F.STATUS_HOME }), T.show(writes()))
end)

test("a connection failure that is not our attempt's is ignored", function()
  install()
  command("Request Status")
  openLink()
  rfp("CONNECTION_FAILED", { error = "GATT discovery failed" })
  T.eq("a live cycle carries on", Properties["Driver Status"], "Connected")
  notify(CAPTURED)
  T.eq("and reads its status", variable("Power"), "On")
  fire("DisconnectDelay")
  answerDisconnect()

  -- The attempt a later CONNECT supersedes reports failing; the newer one continues
  sent = {}
  command("Power Off")
  rfp("CONNECTION_FAILED", { error = "Superseded by a newer request" })
  T.eq("a superseded attempt does not fail ours", count("DISCONNECT"), 0)
  openLink()
  T.check("which completes", T.deepEqual(writes(), { F.POWER_OFF }), T.show(writes()))

  -- Nothing to fail while idle
  install()
  rfp("CONNECTION_FAILED", { error = "No connection slots available" })
  T.eq("an idle driver ignores it", count("DISCONNECT"), 0)
end)

test("a command during the linger reuses the connection", function()
  install()
  command("Request Status")
  openLink()
  notify(CAPTURED)
  T.truthy("the linger is armed", armed("DisconnectDelay"))
  sent = {}
  command("Power Off")
  T.eq("no new connection", count("CONNECT"), 0)
  T.falsy("the linger is cancelled", armed("DisconnectDelay"))
  local got = drain()
  T.check("the command then a status query", T.deepEqual(got, { F.POWER_OFF, F.STATUS_HOME }), T.show(got))
end)

test("toggle and steps build on a write already sent but not yet confirmed", function()
  install()
  readStatus(statusFrame({ power = 0, intensity = 10 }))
  sent = {}
  command("Toggle Power")
  openLink()
  T.check("the first toggle is on the wire", T.deepEqual(writes(), { F.POWER_ON }), T.show(writes()))
  command("Toggle Power")
  notify(ack(0x10))
  ReceivedFromProxy(303, "DO_CLICK", {})
  ReceivedFromProxy(303, "DO_CLICK", {})
  local got = drain()
  -- The coalescing window swallows the second click on the same link
  T.check(
    "the second toggle undoes the first; up steps from low",
    T.deepEqual(got, { F.POWER_ON, F.POWER_OFF, F.MEDIUM, F.STATUS_HOME }),
    T.show(got)
  )
  notify(CAPTURED)
  fire("ButtonLinkCoalesce303")
  fire("DisconnectDelay")
  answerDisconnect()
  sent = {}
  ReceivedFromProxy(303, "DO_CLICK", {})
  openLink()
  T.check("once the reply is in, it is the reply that counts", T.deepEqual(writes(), { F.MEDIUM }), T.show(writes()))
end)

test("unbinding mid-cycle leaves nothing running", function()
  install()
  command("Power On")
  openLink()
  OnBindingChanged(ESPHOME, "ESPHOME_SERENESCENT", false, 100, 1)
  T.check("no cycle timer is left", #armedCycleTimers() == 0, T.show(armedCycleTimers()))
  T.falsy("nor a poll", armed("PollCycle"))
  T.eq("status", Properties["Driver Status"], "Disconnected")
  notify(ack(0x10))
  T.eq("a late ack writes nothing", count("GATT_WRITE"), 1)
end)

test("Reset Driver while waiting for the proxy's answer keeps waiting for it", function()
  install()
  command("Request Status")
  openLink()
  notify(CAPTURED)
  fire("DisconnectDelay")
  sent = {}
  command("LUA_ACTION", { ACTION = "Reset_Driver", ["Are You Sure?"] = "Yes" })
  -- The coordinator answers every DISCONNECT, so a second would leave a stray answer
  T.eq("no second DISCONNECT", count("DISCONNECT"), 0)
  sent = {}
  advertise()
  command("Power On")
  T.eq("nothing connects before the answer", count("CONNECT"), 0)
  rfp("DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("the answer releases it", count("CONNECT"), 1)
  openLink()
  local got = drain()
  T.check("and the command is written", T.deepEqual(got, { F.POWER_ON, F.STATUS_HOME }), T.show(got))
end)

test("a superseded subscription does not fail the cycle", function()
  install()
  command("Request Status")
  connected()
  connected()
  rfp("GATT_NOTIFY_SUBSCRIBED", { handle = tostring(RX), success = "false", error = "Superseded by a newer request" })
  T.eq("no disconnect", count("DISCONNECT"), 0)
  subscribed()
  T.check("the newer subscription carries on", T.deepEqual(writes(), { F.STATUS_HOME }), T.show(writes()))
end)

test("intensity steps build on a level sent but not yet confirmed", function()
  install()
  readStatus(statusFrame({ intensity = 10 }))
  sent = {}
  command("Set Intensity", { Level = "medium" })
  openLink()
  ReceivedFromProxy(303, "DO_CLICK", {})
  local got = drain()
  T.check("up steps from the medium on the wire", T.deepEqual(got, { F.MEDIUM, F.HIGH, F.STATUS_HOME }), T.show(got))
end)

test("a status reply, not the write, is the base once it arrives", function()
  install()
  readStatus(statusFrame({ intensity = 10 }))
  sent = {}
  command("Set Intensity", { Level = "medium" })
  openLink()
  notify(ack(0x17))
  -- The device refused: it still reports low
  notify(statusFrame({ intensity = 10 }))
  sent = {}
  ReceivedFromProxy(303, "DO_CLICK", {})
  T.check("up steps from the reported low", T.deepEqual(writes(), { F.MEDIUM }), T.show(writes()))
end)

test("a failed cycle forgets what it wrote", function()
  install()
  readStatus(statusFrame({ power = 0 }))
  sent = {}
  command("Toggle Power")
  openLink()
  T.check("on is on the wire", T.deepEqual(writes(), { F.POWER_ON }), T.show(writes()))
  rfp("DISCONNECTED", { reason = "BLE connection closed" })
  fire("DisconnectSettle")
  sent = {}
  command("Toggle Power")
  openLink()
  T.check("the next toggle builds on the reported off", T.deepEqual(writes(), { F.POWER_ON }), T.show(writes()))
end)

test("changing the polling interval while the proxy answers our DISCONNECT still takes", function()
  install()
  command("Request Status")
  openLink()
  notify(CAPTURED)
  fire("DisconnectDelay")
  Properties["Polling Interval"] = "8"
  OnPropertyChanged("Polling Interval")
  T.eq("the wait shows the new interval", Properties["Driver Status"], "Listening (next poll in 8m)")
  T.eq("and the poll uses it", delays.PollCycle, 8 * 60 * 1000)
  Properties["Polling Interval"] = "5"
end)

test("every timer is armed with its declared duration", function()
  install()
  delays = {}
  command("Request Status")
  T.eq("connect timeout", delays.ConnectTimeout, 30000)
  connected()
  T.eq("connect timeout again for subscribing", delays.ConnectTimeout, 30000)
  subscribed()
  T.eq("reply timeout", delays.ResponseTimeout, 2000)
  notify(statusFrame({ mode = 1 }))
  T.eq("linger", delays.DisconnectDelay, 3000)
  fire("DisconnectDelay")
  T.eq("settle fallback", delays.DisconnectSettle, 3000)
  T.eq("poll, in minutes from the property", delays.PollCycle, 5 * 60 * 1000)
  answerDisconnect()
  command("Power On")
  openLink()
  T.eq("mode switch settle", delays.CommandDelay, 200)
  ReceivedFromProxy(300, "DO_CLICK", {})
  T.eq("button link coalescing", delays.ButtonLinkCoalesce300, 500)
end)

---------------------------------------------------------------------------
-- Bindings
---------------------------------------------------------------------------

test("every button link runs its action once per tap, for every sender shape", function()
  local CASES = {
    { 300, F.POWER_ON },
    { 301, F.POWER_OFF },
    { 302, F.POWER_OFF }, -- toggle from on
    { 303, F.MEDIUM }, -- up from low
    { 304, nil }, -- down from low: clamped, nothing sent
    { 305, F.LOW },
    { 306, F.MEDIUM },
    { 307, F.HIGH },
  }
  for _, case in ipairs(CASES) do
    local binding, frame = case[1], case[2]
    for _, shape in ipairs({ { "DO_PUSH", "DO_CLICK" }, { "DO_CLICK", "DO_PUSH" }, { "DO_CLICK" }, { "DO_PUSH" } }) do
      install()
      readStatus()
      sent = {}
      for _, cmd in ipairs(shape) do
        ReceivedFromProxy(binding, cmd, {})
      end
      openLink()
      local want = frame and { frame, F.STATUS_HOME } or { F.STATUS_HOME }
      local got = drain()
      T.check(string.format("%d %s", binding, table.concat(shape, "+")), T.deepEqual(got, want), T.show(got))
    end
  end
end)

test("a second tap after the coalescing window acts again; DO_RELEASE never does", function()
  install()
  readStatus(statusFrame({ power = 0 }))
  sent = {}
  ReceivedFromProxy(302, "DO_PUSH", {})
  ReceivedFromProxy(302, "DO_CLICK", {})
  ReceivedFromProxy(302, "DO_RELEASE", {})
  T.truthy("the window is armed", fire("ButtonLinkCoalesce302"))
  ReceivedFromProxy(302, "DO_PUSH", {})
  ReceivedFromProxy(302, "DO_RELEASE", {})
  openLink()
  local got = drain()
  T.check("on, then off", T.deepEqual(got, { F.POWER_ON, F.POWER_OFF, F.STATUS_HOME }), T.show(got))
end)

test("the relay drives power and reports it once per change", function()
  install()
  readStatus(statusFrame({ power = 0 }))
  T.eq("the first reading after a start notifies the relay", count("OPENED", RELAY), 1)
  readStatus(statusFrame({ power = 0 }))
  T.eq("an unchanged reading does not", count("OPENED", RELAY), 1)
  readStatus()
  T.eq("a change does", count("CLOSED", RELAY), 1)

  sent = {}
  ReceivedFromProxy(RELAY, "OPEN", {})
  openLink()
  T.check("OPEN turns it off", T.deepEqual(writes(), { F.POWER_OFF }), T.show(writes()))

  install()
  readStatus()
  sent = {}
  ReceivedFromProxy(RELAY, "TOGGLE", {})
  ReceivedFromProxy(301, "TOGGLE", {})
  openLink()
  local toggled = drain()
  T.check(
    "TOGGLE toggles, and only on the relay",
    T.deepEqual(toggled, { F.POWER_OFF, F.STATUS_HOME }),
    T.show(toggled)
  )

  install()
  sent = {}
  ReceivedFromProxy(RELAY, "CLOSE", {})
  openLink()
  T.check("CLOSE turns it on", T.deepEqual(writes(), { F.POWER_ON }), T.show(writes()))
end)

test("a newly bound relay consumer is seeded with the last known state", function()
  install()
  OnBindingChanged(RELAY, "RELAY", true, 200, 1)
  T.eq("nothing is seeded before the first reading", #sent, 0)
  readStatus()
  sent = {}
  OnBindingChanged(RELAY, "RELAY", true, 200, 1)
  T.eq("STATE_CLOSED once the diffuser is known to be on", count("STATE_CLOSED", RELAY), 1)
end)

test("a restart re-notifies the relay and toggles from the persisted state", function()
  install()
  readStatus()
  T.eq("CLOSED in the first session", count("CLOSED", RELAY), 1)

  clearTimers()
  dofile(DRIVER)
  sent = {}
  OnDriverLateInit()
  T.eq("persisted state is not replayed at boot", count("CLOSED", RELAY), 0)
  T.eq("the boot asks the proxy for a refresh", count("REFRESH_STATE", ESPHOME), 1)
  sent = {}
  command("Toggle Power")
  openLink()
  T.check("toggle uses the persisted power state", T.deepEqual(writes(), { F.POWER_OFF }), T.show(writes()))
  notify(ack(0x11))
  notify(CAPTURED)
  T.eq("the first reading after the restart notifies again", count("CLOSED", RELAY), 1)
end)

test("unbinding and rebinding the ESPHome connection starts over", function()
  install()
  readStatus()
  OnBindingChanged(ESPHOME, "ESPHOME_SERENESCENT", false, 100, 1)
  T.eq("unbound reads Disconnected", Properties["Driver Status"], "Disconnected")
  T.falsy("and stops polling", armed("PollCycle"))

  OnBindingChanged(ESPHOME, "ESPHOME_SERENESCENT", true, 100, 1)
  sent = {}
  advertise()
  T.eq("the first advertisement after a rebind reads status", count("CONNECT"), 1)
end)

---------------------------------------------------------------------------
-- Properties and actions
---------------------------------------------------------------------------

test("changing the polling interval re-arms an idle wait and leaves a cycle alone", function()
  install()
  readStatus()
  Properties["Polling Interval"] = "10"
  OnPropertyChanged("Polling Interval")
  T.eq("the wait shows the new interval", Properties["Driver Status"], "Listening (next poll in 10m)")
  T.eq("and keeps Connected", variable("Connected"), true)

  command("Request Status")
  openLink()
  OnPropertyChanged("Polling Interval")
  T.eq("an active cycle is left alone", Properties["Driver Status"], "Connected")
end)

test("Set Polling Interval updates the property", function()
  install()
  command("Set Polling Interval", { Interval = "7" })
  T.eq("the property", Properties["Polling Interval"], "7")
end)

test("Reset Driver releases a live connection and forgets the device", function()
  install()
  command("Request Status")
  openLink()
  notify(CAPTURED)
  command("LUA_ACTION", { ACTION = "Reset_Driver", ["Are You Sure?"] = "Yes" })
  T.eq("the live connection is released", count("DISCONNECT"), 1)
  T.eq("status", Properties["Driver Status"], "Disconnected")
  T.eq("properties return to their defaults", Properties["Power"], "Unknown")
  T.eq("the Connected variable is gone", variable("Connected"), nil)
  -- persist:get returns a shared empty table for a missing key, so ask for a sentinel
  T.eq("persisted state is gone", persist:get("deviceState", false), false)
  T.falsy("no poll outlives it", armed("PollCycle"))
  T.check(
    "only the wait for the proxy's answer is left",
    T.deepEqual(armedCycleTimers(), { "DisconnectSettle" }),
    T.show(armedCycleTimers())
  )

  sent = {}
  command("LUA_ACTION", { ACTION = "Reset_Driver", ["Are You Sure?"] = "No" })
  T.eq("No does nothing", #sent, 0)

  -- Forgotten in memory too, not only in storage
  answerDisconnect()
  sent = {}
  OnBindingChanged(RELAY, "RELAY", true, 200, 1)
  T.eq("a relay bound after the reset is not seeded", count("STATE_CLOSED", RELAY) + count("STATE_OPENED", RELAY), 0)
  command("Toggle Power")
  openLink()
  T.check("toggle no longer knows the diffuser was on", T.deepEqual(writes(), { F.POWER_ON }), T.show(writes()))
end)

test("every action and command in driver.xml has a handler", function()
  local seen = {}
  for name in CONFIG:gmatch("<command>([%w_]+)</command>") do
    seen[name] = true
  end
  for block in CONFIG:gmatch("<command>%s*<name>(.-)</name>") do
    seen[(block:gsub("%s+", "_"))] = true
  end
  for name in pairs(seen) do
    T.eq(name, type(EC[name]), "function")
  end
  T.check("some were found", next(seen) ~= nil)
end)

test("every static connection in driver.xml has a handler", function()
  local connections = {}
  for id, class in CONFIG:gmatch("<id>(%d+)</id>.-<classname>([%w_]+)</classname>") do
    connections[tonumber(id)] = class
  end
  -- The <connections> block sits outside <config>; read the whole file for it.
  for id, class in readFile(XML):gmatch("<id>(%d+)</id>.-<classname>([%w_]+)</classname>") do
    connections[tonumber(id)] = class
  end
  for id = 300, 307 do
    T.eq(id .. " is a BUTTON_LINK", connections[id], "BUTTON_LINK")
    T.eq(id .. " has an RFP handler", type(RFP[id]), "function")
  end
  T.eq("308 is a RELAY", connections[RELAY], "RELAY")
  T.eq("5002 is the ESPHome connection", connections[ESPHOME], "ESPHOME_SERENESCENT")
end)

test("the package carries the documentation and icons driver.xml points at", function()
  -- The build and every other check pass without them, so only this catches it
  local proj = readFile(HERE .. "/../drivers/esphome_serenescent/driver.c4zproj")
  T.contains("www is packaged", proj, 'name="www" recurse="true" exclude="false"')
  local xml = readFile(XML)
  for _, path in ipairs({ "icons/device_sm.png", "icons/device_lg.png", "documentation/index.md" }) do
    T.check(path .. " exists under www", io.open(HERE .. "/../drivers/esphome_serenescent/www/" .. path) ~= nil, path)
  end
  T.contains("driver.xml points at the packaged documentation", xml, 'file="www/documentation/index.html"')
end)

T.finish()
