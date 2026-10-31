-- Tests the commands a switch's RELAY connection accepts from its bound consumer.
--
-- A switch command with no state reads as off on the device, so GET_STATE
-- answers from the last known state and other unknown commands never reach
-- the device.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_switch_relay_commands.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local SwitchEntity = require("esphome.entities.switch")

--- Every switch command sent to the device, as { key, state }.
local sent = {}
local client = {
  callServiceMethod = function(_, method, body)
    if method.method == "switch_command" then
      sent[#sent + 1] = { body.key, body.state }
    end
    return deferred.new():resolve(nil)
  end,
}

--- Every message sent to a binding, as { binding, command, type }.
local told = {}
C4.SendToProxy = function(_, idBinding, strCommand, _tParams, strMessage)
  told[#told + 1] = { idBinding, strCommand, strMessage }
end

--- The device commands and binding messages since the last call.
local function drain()
  local commands, messages = sent, told
  sent, told = {}, {}
  return commands, messages
end

local entity = { key = 900, ref = "900", name = "Porch Relay" }
local switch = SwitchEntity:new(client)
switch:discovered(entity)
local relay = bindings:getDynamicBinding(SwitchEntity.TYPE, "switch_" .. entity.ref).bindingId

--- Send a command to the relay connection as its consumer would.
local function command(strCommand, tParams)
  RFP[relay](relay, strCommand, tParams or {})
end

T.section("GET_STATE before any state from the device")
do
  command("GET_STATE")
  local commands, messages = drain()
  T.eq("nothing sent to the device", commands, {})
  T.eq("nothing told to the consumer", messages, {})
end

T.section("GET_STATE answers with the last known state")
do
  switch:updated(entity, { state = true })
  drain()
  command("GET_STATE")
  local commands, messages = drain()
  T.eq("on: nothing sent to the device", commands, {})
  T.eq("on: told STATE_CLOSED", messages, { { relay, "STATE_CLOSED", "NOTIFY" } })

  switch:updated(entity, { state = false })
  drain()
  command("GET_STATE")
  commands, messages = drain()
  T.eq("off: nothing sent to the device", commands, {})
  T.eq("off: told STATE_OPENED", messages, { { relay, "STATE_OPENED", "NOTIFY" } })
end

T.section("An unknown command leaves the switch alone")
do
  switch:updated(entity, { state = true })
  drain()
  for _, unknown in ipairs({ "GET_RELAY_STATE", "QUERY", "FOO" }) do
    command(unknown)
  end
  local commands, messages = drain()
  T.eq("nothing sent to the device", commands, {})
  T.eq("nothing told to the consumer", messages, {})
end

T.section("The switching commands still switch")
do
  for _, case in ipairs({
    { "ON", true },
    { "CLOSE", true },
    { "OFF", false },
    { "OPEN", false },
  }) do
    command(case[1])
    T.eq(case[1], (drain()), { { 900, case[2] } })
  end

  switch:updated(entity, { state = true })
  drain()
  command("TOGGLE")
  T.eq("TOGGLE from on", (drain()), { { 900, false } })

  switch:updated(entity, { state = false })
  drain()
  command("TOGGLE")
  T.eq("TOGGLE from off", (drain()), { { 900, true } })

  command("TRIGGER", {})
  T.eq("TRIGGER with no time", (drain()), { { 900, true } })
end

T.finish()
