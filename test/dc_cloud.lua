-- A fake DriverCentral Cloud driver for tests. It answers the real vendored cloud-client-byte over the client's
-- own encrypted channel, so a test sees the client's real behavior: DC_X 0 from its late init until an answer, a
-- ping every 10 s, a drop to 0 after six unanswered pings, and DC_OnDriverStatus on each change.
--
-- Require it after c4_shim and before the driver's OnDriverInit, then:
--   cloud.answer = { AC = 1, AS = "License Activated" } -- what each ping is answered with (nil answers nothing)
--   cloud.poll(n)        -- n of the client's 10 s pings
--   cloud.say(fields)    -- a message the Cloud driver sends unasked, as on a license change or its own update
--   cloud.silent = true  -- the Cloud driver stops answering
--   cloud.present = false -- the project has no Cloud driver

require("drivers-common-public.global.lib") -- the vendored JSON needs its tostring_return_period
local json = require("JSON")

local Cloud = { answer = nil, silent = false, present = true, sent = {}, mac = "000FFF112233" }

local CLOUD_ID = 999
local VERSION = 3 -- the client's protocol version, part of its key

function C4:GetUniqueMAC()
  return Cloud.mac
end
function C4:JsonEncode(t)
  return json:encode(t)
end
function C4:JsonDecode(s)
  return json:decode(s)
end
function C4:GetDevicesByC4iName(name)
  -- An absent driver gives an empty table on a controller (measured on OS 4.3).
  if name == "driverCentral-Cloud.c4z" and Cloud.present then
    return { [CLOUD_ID] = { name = "DriverCentral Cloud" } }
  end
  return {}
end

local getDeviceData = C4.GetDeviceData
function C4:GetDeviceData(id, key)
  if id == CLOUD_ID and key == "version" then
    return "1033"
  end
  return getDeviceData(self, id, key)
end

-- The client posts its warnings to DriverCentral's log host: kept, never sent.
Cloud.posts = {}
function C4:url()
  local request = {}
  function request:OnDone()
    return request
  end
  function request:SetOptions()
    return request
  end
  function request:Post(_, body)
    Cloud.posts[#Cloud.posts + 1] = body
    return request
  end
  function request:Get()
    return request
  end
  return request
end

local function key()
  return C4:Hash("MD5", Cloud.mac .. VERSION)
end

-- The client's clock check: its half-seconds offset, within a few seconds of the sender's.
local function stamp()
  return math.floor(os.time() / 2 + 170)
end

-- The client's ping timer is its only 10 s repeating timer set from its own compiled chunk. It is cancelled here and
-- run by Cloud.poll, so a test's ShimFireTimers never pings.
local setTimer = C4.SetTimer
function C4:SetTimer(ms, fn, repeating)
  local handle = setTimer(self, ms, fn, repeating)
  local source = type(fn) == "function" and debug.getinfo(fn, "S").source or "@"
  if ms == 10000 and repeating and source:sub(1, 1) ~= "@" then
    Cloud.ping = { fn = fn, handle = handle }
    handle:Cancel()
  end
  return handle
end

--- Delivers a message from the Cloud driver to the client, as Director's ExecuteCommand does.
--- @param fields table
function Cloud.say(fields)
  local message = { TC = stamp() }
  for k, v in pairs(fields) do
    message[k] = v
  end
  local sealed = assert(C4:Encrypt("AES-256-CBC", key(), nil, json:encode(message), { return_encoding = "BASE64" }))
  ExecuteCommand("CYPHER3", { msg = sealed })
end

local sendToDevice = C4.SendToDevice
function C4:SendToDevice(id, command, params, ...)
  if id ~= CLOUD_ID or command ~= "CYPHER3" then
    return sendToDevice(self, id, command, params, ...)
  end
  local message = json:decode(C4:Decrypt("AES-256-CBC", key(), nil, params.msg, { data_encoding = "BASE64" }))
  Cloud.sent[#Cloud.sent + 1] = message
  if message.PI and not Cloud.silent and Cloud.answer then
    local reply = { PO = true }
    for k, v in pairs(Cloud.answer) do
      reply[k] = v
    end
    Cloud.say(reply)
  end
end

--- Runs `n` of the client's 10 s pings.
--- @param n? integer
function Cloud.poll(n)
  assert(Cloud.ping, "the client never started pinging: its late init stopped early")
  for _ = 1, n or 1 do
    Cloud.ping.fn(Cloud.ping.handle, 0)
  end
end

return Cloud
