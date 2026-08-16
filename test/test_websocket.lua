-- Tests for the local fork deltas in vendor/drivers-common-public/module/websocket.lua:
--   1. per-endpoint network binding reuse
--   2. Send(s, opcode), additive, default 0x81
--   3. Host header omits the default port
--   4. 64-bit extended-length field uses %016X
--
-- Run from the template root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" luajit test/test_websocket.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

--------------------------------------------------------------------------------
-- C4 surface
--
-- Every call this file needs is DriverWorks, so it comes from the shim instead
-- of being redeclared here. Redeclaring is how the two copies of C4:KillTimer
-- drifted: one gained an error level and the other kept the old one.
--------------------------------------------------------------------------------
require("c4_shim")

local bindingAddress, bindingPort = ShimNetworkBindings()
local sentFrames = ShimSentFrames()

-- websocket.lua logs on every frame, which would bury the results.
function C4:DebugLog() end

--- Fire every pending timer, which is what makes the 3-second close timer run.
--- ShimFireTimers ignores the clock, so this works with or without luasocket.
local fireTimers = ShimFireTimers

-- C4 global: hex string -> packed bytes
function tohex(s)
  return (tostring(s):gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

ONE_SECOND = 1000
OCS, RFN = {}, {}

local WebSocket = require("drivers-common-public.module.websocket")

--- Close a socket the way the module does, without driving the timer. Used by
--- the cases that only care about the registry state; the reuse cases below go
--- through the real delete() path instead.
local function simulateClose(ws)
  if WebSocket.Sockets then
    WebSocket.Sockets[ws.url] = nil
    WebSocket.Sockets[ws.netBinding] = nil
  end
  ws.connected = false
end

local function bindingsInUse()
  local n = 0
  for _ in pairs(bindingAddress) do
    n = n + 1
  end
  return n
end

local function resetBindings()
  ShimResetBindings()
end

--------------------------------------------------------------------------------
print("\n[1] Send() default opcode unchanged (0x81 text frame)")
--------------------------------------------------------------------------------
do
  local ws = WebSocket:new("wss://text.example.com/ws")
  ws.connected = true
  ShimResetSentFrames()
  ws:Send("hello")
  local first = sentFrames[1] and sentFrames[1].data:byte(1)
  check("legacy Send(s) still emits 0x81", first == 0x81, string.format("got 0x%02X", first or 0))

  ShimResetSentFrames()
  ws:Send("hello", 0x82)
  first = sentFrames[1] and sentFrames[1].data:byte(1)
  check("Send(s, 0x82) emits binary frame", first == 0x82, string.format("got 0x%02X", first or 0))

  ShimResetSentFrames()
  ws:Send(string.rep("x", 300)) -- 126 extended-length branch
  first = sentFrames[1] and sentFrames[1].data:byte(1)
  check("126-branch keeps 0x81 default", first == 0x81, string.format("got 0x%02X", first or 0))
  simulateClose(ws)
end

--------------------------------------------------------------------------------
print("\n[2] 64-bit extended-length field is exactly 8 bytes (%016X)")
--------------------------------------------------------------------------------
do
  local ws = WebSocket:new("wss://big.example.com/ws")
  ws.connected = true

  local payload = string.rep("y", 70000) -- > 65535, so the 127 branch
  ShimResetSentFrames()
  ws:Send(payload)
  local data = sentFrames[1] and sentFrames[1].data or ""

  -- opcode(1) + 0xFF(1) + length(8) + mask(4) = 14 bytes of header
  check("header is 14 bytes", #data - #payload == 14, string.format("%d bytes", #data - #payload))
  check("length marker is 127", data:byte(2) == bit.bor(127, 0x80), string.format("0x%02X", data:byte(2) or 0))

  local decoded = 0
  for i = 3, 10 do
    decoded = decoded * 256 + (data:byte(i) or 0)
  end
  check("length field decodes to payload size", decoded == 70000, decoded)
  check("no space padding in length field", not data:sub(3, 10):find(" ", 1, true), "contains 0x20")
  simulateClose(ws)
end

--------------------------------------------------------------------------------
print("\n[3] Binding reuse across reconnects, through the REAL delete() path")
--------------------------------------------------------------------------------
do
  resetBindings()
  -- The load-bearing detail lives in Close(): its 3-second timer clears
  -- Sockets[netBinding] BEFORE invoking onDeleteComplete. That ordering is the
  -- only reason the liveness guard lets a reconnect reuse the slot, so this case
  -- drives delete() for real instead of clearing the registry by hand. Both
  -- consumers reconnect from inside the delete callback.
  local first, last
  local ws = WebSocket:new("wss://iot.example.com/mqtt?sig=0")
  first = ws.netBinding

  for i = 1, 5 do
    local current = ws
    current.connected = false
    current:delete(function()
      ws = WebSocket:new("wss://iot.example.com/mqtt?sig=" .. i) -- presigned: url differs each time
      last = ws.netBinding
    end)
    fireTimers()
  end

  check("reconnect from inside delete() reuses one binding", first == last, tostring(first) .. " vs " .. tostring(last))
  check("pool holds exactly 1 slot across 5 reconnects", bindingsInUse() == 1, bindingsInUse() .. " slots")
  simulateClose(ws)
end

--------------------------------------------------------------------------------
print("\n[4] Reconnecting BEFORE the close timer fires still allocates (documented)")
--------------------------------------------------------------------------------
do
  resetBindings()
  -- Not a regression: this is the pre-fix behaviour, preserved. A consumer that
  -- opens the replacement without waiting for delete() to complete cannot reuse
  -- the slot, because the old socket still owns it. Pinned here so the ordering
  -- inside Close() cannot be changed without a test noticing.
  local ws = WebSocket:new("wss://eager.example.com/ws?sig=0")
  ws.connected = false
  ws:delete() -- close timer NOT fired
  local replacement = WebSocket:new("wss://eager.example.com/ws?sig=1")
  check("live owner is not evicted", replacement.netBinding ~= ws.netBinding, replacement.netBinding)
  fireTimers()
  simulateClose(replacement)
end

--------------------------------------------------------------------------------
print("\n[5] Same host, DIFFERENT ports, both live (home-connect multi-bridge)")
--------------------------------------------------------------------------------
do
  resetBindings()
  local a = WebSocket:new("ws://192.168.1.50:8581/socket.io/?a=1")
  local b = WebSocket:new("ws://192.168.1.50:8582/socket.io/?b=1")
  check("distinct ports get distinct bindings", a.netBinding ~= b.netBinding, a.netBinding .. " vs " .. b.netBinding)
  check(
    "each socket owns its own callbacks",
    WebSocket.Sockets[a.netBinding] == a and WebSocket.Sockets[b.netBinding] == b
  )
  simulateClose(a)
  simulateClose(b)
end

--------------------------------------------------------------------------------
print("\n[6] Concurrent socket to the same endpoint does not steal the cache slot")
--------------------------------------------------------------------------------
do
  resetBindings()
  -- A transient second socket (home-connect opens one per plugin install) must
  -- not re-point the endpoint at its own binding, which would orphan the
  -- long-lived socket's slot for the controller's lifetime.
  local main = WebSocket:new("wss://same.example.com/ws?main=1")
  local transient = WebSocket:new("wss://same.example.com/ws?install=1")
  check("concurrent sockets are not merged", main.netBinding ~= transient.netBinding, main.netBinding)
  check("first socket keeps its callbacks", WebSocket.Sockets[main.netBinding] == main)

  simulateClose(transient)
  simulateClose(main)

  local reconnect = WebSocket:new("wss://same.example.com/ws?main=2")
  check(
    "reconnect returns to the ORIGINAL slot, not the transient one",
    reconnect.netBinding == main.netBinding,
    string.format("got %s, wanted %s", tostring(reconnect.netBinding), tostring(main.netBinding))
  )
  check("only 2 slots consumed total", bindingsInUse() == 2, bindingsInUse() .. " slots")
  simulateClose(reconnect)
end

--------------------------------------------------------------------------------
print("\n[7] Sequential transients reclaim a binding instead of leaking one each")
--------------------------------------------------------------------------------
do
  resetBindings()
  -- One transient cannot tell a single cached binding apart from a list, because
  -- either way it allocates one. The SECOND transient is what separates them: a
  -- single binding pinned to the first claimant never records the transient's
  -- binding, so every later transient allocates another and the pool bleeds one
  -- slot per overlap. The list reclaims the freed transient binding.
  local main = WebSocket:new("wss://busy.example.com/ws?main=1")
  for i = 1, 6 do
    local transient = WebSocket:new("wss://busy.example.com/ws?install=" .. i)
    simulateClose(transient) -- each finishes before the next begins
  end
  check("long-lived socket keeps its own binding", WebSocket.Sockets[main.netBinding] == main, main.netBinding)
  check(
    "6 sequential transients consume 1 slot between them",
    bindingsInUse() == 2,
    bindingsInUse() .. " slots (pinned-single would be 7)"
  )
  simulateClose(main)
end

--------------------------------------------------------------------------------
print("\n[8] Host header: default port omitted, others preserved")
--------------------------------------------------------------------------------
do
  local function hostHeaderOf(url)
    local ws = WebSocket:new(url)
    local h = ws:MakeHeaders()
    if type(h) == "table" then
      h = table.concat(h, "\r\n")
    end
    simulateClose(ws)
    return tostring(h):match("Host: ([^\r\n]+)")
  end
  check("wss default 443 omits port", hostHeaderOf("wss://a.example.com/ws") == "a.example.com")
  check("ws default 80 omits port", hostHeaderOf("ws://b.example.com/ws") == "b.example.com")
  check("wss non-default keeps port", hostHeaderOf("wss://c.example.com:8443/ws") == "c.example.com:8443")
  check("ws non-default keeps port", hostHeaderOf("ws://d.example.com:8581/ws") == "d.example.com:8581")
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
