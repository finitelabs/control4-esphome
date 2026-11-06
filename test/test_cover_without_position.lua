-- Tests a cover without position support against what ESPHome sends and takes: its state comes as a position,
-- 1 open and 0 closed, which a message leaves out when it is 0, and Open and Close go to it as positions 1 and 0.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_cover_without_position.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local deferred = require("deferred")
local bindings = require("lib.bindings")
local values = require("lib.values")
local CoverEntity = require("esphome.entities.cover")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local Operation = ESPHomeProtoSchema.Enum.CoverOperation

--- Every cover command sent to the device.
local sent = {}
local client = {
  callServiceMethod = function(_, method, body)
    if method.method == "cover_command" then
      sent[#sent + 1] = body
    end
    return deferred.new():resolve(nil)
  end,
}

C4.SendToProxy = function() end

local cover = CoverEntity:new(client)
local entity = { key = 970, ref = "970", name = "Door", supports_position = false, supports_stop = true }
cover:discovered(entity)

--- The cover's State, Open and Closed variables after `state` arrives.
--- @param state table<string, any>
--- @return string[]
local function readAfter(state)
  cover:updated(entity, state)
  return {
    Select(values:getValue("Door State"), "value"),
    Select(values:getValue("Door Open"), "value"),
    Select(values:getValue("Door Closed"), "value"),
  }
end

T.section("its state comes from the position")
T.eq("position 1 reads open", readAfter({ position = 1.0 }), { "open", "CLOSED", "OPENED" })
T.eq("no position reads closed", readAfter({}), { "closed", "OPENED", "CLOSED" })
T.eq("position 0 reads closed", readAfter({ position = 0.0 }), { "closed", "OPENED", "CLOSED" })
T.eq(
  "an opening cover reads opening, neither open nor closed",
  readAfter({ position = 0.0, current_operation = Operation.COVER_OPERATION_IS_OPENING }),
  { "opening", "OPENED", "OPENED" }
)
T.eq(
  "and a closing one closing",
  readAfter({ position = 1.0, current_operation = Operation.COVER_OPERATION_IS_CLOSING }),
  { "closing", "OPENED", "OPENED" }
)

T.section("Open, Close and Stop go to it as positions 1 and 0 and a stop")
local function relay(name)
  return bindings:getDynamicBinding(CoverEntity.TYPE, name .. entity.ref).bindingId
end
for _, case in ipairs({
  { "open_cover_", { has_position = true, position = 1.0 } },
  { "close_cover_", { has_position = true, position = 0.0 } },
  { "stop_cover_", { has_position = false, stop = true } },
}) do
  sent = {}
  local binding = relay(case[1])
  RFP[binding](binding, "TRIGGER", {})
  T.eq(case[1] .. " sends one command", #sent, 1)
  for field, want in pairs(case[2]) do
    T.eq(case[1] .. " " .. field, sent[1] and sent[1][field], want)
  end
  T.eq(case[1] .. " carries no legacy command", sent[1] and sent[1].has_legacy_command, nil)
end

T.finish()
