-- Tests that a command to an entity on an ESPHome sub-device carries its device_id.
--
-- ESPHome 2025.8 and newer find a commanded entity by key and device_id, which
-- defaults to 0, the main device, so a command without it never reaches a
-- sub-device entity. A main-device command keeps no device_id, as before.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sub_device_commands.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local ButtonEntity = require("esphome.entities.button")
local LightEntity = require("esphome.entities.light")
local SelectEntity = require("esphome.entities.select")
local SwitchEntity = require("esphome.entities.switch")

local KITCHEN = 870733615

--- Every command sent, as { method, key, device_id }.
local sent = {}
local client = {
  callServiceMethod = function(_, method, body)
    sent[#sent + 1] = { method.method, body.key, body.device_id }
    return deferred.new():resolve(nil)
  end,
}

--- The commands sent since the last call.
local function commands()
  local got = sent
  sent = {}
  return got
end

local main = { key = 500, ref = "500", name = "Relay" }
local kitchen = { key = 500, ref = "500@870733615", name = "Kitchen Relay", device_id = KITCHEN }

T.section("A switch's commands carry its device_id")
do
  local switch = SwitchEntity:new(client)
  for _, entity in ipairs({ main, kitchen }) do
    switch:discovered(entity)
    RFP[bindings:getDynamicBinding(SwitchEntity.TYPE, "switch_" .. entity.ref).bindingId](nil, "ON", {})
  end
  T.eq("relay connection", commands(), { { "switch_command", 500 }, { "switch_command", 500, KITCHEN } })
end

T.section("Press Button and Set Select carry the device_id")
do
  local button = ButtonEntity:new(client)
  button:discovered({ key = 600, ref = "600", name = "Chime" })
  button:discovered({ key = 600, ref = "600@870733615", name = "Kitchen Chime", device_id = KITCHEN })
  EC.Press_Button({ Button = "Chime" })
  EC.Press_Button({ Button = "Kitchen Chime" })
  T.eq("press button", commands(), { { "button_command", 600 }, { "button_command", 600, KITCHEN } })

  local select = SelectEntity:new(client)
  select:discovered({
    key = 700,
    ref = "700@870733615",
    name = "Kitchen Mode",
    options = { "Eco" },
    device_id = KITCHEN,
  })
  EC.Set_Select({ Select = "Kitchen Mode", Option = "Eco" })
  T.eq("set select", commands(), { { "select_command", 700, KITCHEN } })
end

T.section("A sub-driver's command gets the entity's device_id")
do
  local light = LightEntity:new(client)
  local entity = { key = 800, ref = "800@870733615", name = "Kitchen Lamp", device_id = KITCHEN }
  light:discovered(entity)
  RFP[bindings:getDynamicBinding(LightEntity.TYPE, "light_" .. entity.ref).bindingId](nil, "ENTITY_COMMAND", {
    command = "light_command",
    body = SerializeSafe({ state = true }),
  })
  T.eq("light command", commands(), { { "light_command", 800, KITCHEN } })
end

T.finish()
