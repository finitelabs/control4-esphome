--- Tests that the ESPHome client waits for a plaintext frame header split across TCP reads.
--- The header is an indicator byte and two varints, up to 6 bytes, so a read can end inside
--- either varint.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_client_split_header.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")
local ESPHomeClient = require("esphome.client")

--- A client whose payloads are recorded instead of decoded.
local function newClient()
  local client = ESPHomeClient:new()
  client._buffer = ""
  client.received = {}
  function client:_processPayload(messageType, payload)
    table.insert(self.received, { type = messageType, size = #payload })
  end
  return client
end

--- Hand the client one read, as the connection does; whether it raised, and its error.
local function read(client, data)
  client._buffer = client._buffer .. data
  return pcall(client._processBuffer, client)
end

-- Plaintext frames: indicator 0, a payload size varint, a message type varint (150 is 96 01).
local SMALL = { header = "\0\200\1\150\1", size = 200 } -- size 200 is C8 01
local LARGE = { header = "\0\128\128\1\150\1", size = 16384 } -- size 16384 is 80 80 01

for _, case in ipairs({
  { "inside the message type", SMALL, 4 },
  { "between the payload size and the message type", SMALL, 3 },
  { "inside the payload size", LARGE, 3 },
}) do
  local name, frameOf, cut = case[1], case[2], case[3]
  T.section("a read that ends " .. name)
  local client = newClient()
  local frame = frameOf.header .. string.rep("x", frameOf.size)
  local ok, err = read(client, frame:sub(1, cut))
  T.check("the first read does not raise", ok, err)
  T.eq("and nothing is handled yet", #client.received, 0)
  ok, err = read(client, frame:sub(cut + 1))
  T.check("the rest does not raise", ok, err)
  T.eq("the frame is handled once", #client.received, 1)
  T.eq("with its message type", client.received[1] and client.received[1].type, 150)
  T.eq("and its whole payload", client.received[1] and client.received[1].size, frameOf.size)
end

T.section("a whole frame in one read is handled as before")
local client = newClient()
local ok, err = read(client, SMALL.header .. string.rep("x", SMALL.size))
T.check("it does not raise", ok, err)
T.eq("it is handled", #client.received, 1)

T.finish()
