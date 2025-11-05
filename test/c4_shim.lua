--- @module "c4_shim"
--- Shim layer to replace Control4-specific functions with native Lua equivalents
--- for debugging and testing outside the Control4 environment.
---
--- This shim provides ONLY C4-specific functions. All other utilities (JSON, Select, etc.)
--- should be loaded from the actual source files (lib.utils, vendor files) after loading this shim.

-- Standard Lua socket library for TCP
local socket = require("socket")

-- Global C4 object shim
C4 = {}

-- Stub C4 functions that are called but not needed for testing
function C4:GetDriverConfigInfo() return nil end
function C4:UpdateProperty() end
function C4:SetPropertyAttribs() end
function C4:GetVersionInfo() return {version = "test"} end
function C4:FileSetDir() end
function C4:SendToDevice() end
function C4:SendToProxy() end
function C4:SendToNetwork() end
function C4:SendUIRequest() return "" end
function C4:GetBindingsByDevice() return {} end
function C4:FileExists() return false end
function C4:FileOpen() return nil end
function C4:FileGetSize() return 0 end
function C4:FileSetPos() end
function C4:FileRead() return "" end
function C4:FileClose() end
function C4:FileDelete() end
function C4:FileWrite() return 0 end

--- Logging functions for C4 compatibility
function C4:ErrorLog(message)
  io.stderr:write(message .. "\n")
  io.stderr:flush()
end

function C4:DebugLog(message)
  print(message)
end

--- Base64 encoding/decoding
local base64_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64_decode_impl(data)
  if type(data) ~= "string" then
    error("Invalid base64 data type")
  end
  data = string.gsub(data, '[^'..base64_chars..'=]', '')
  return (data:gsub('.', function(x)
    if (x == '=') then return '' end
    local r, f = '', (base64_chars:find(x) - 1)
    for i = 6, 1, -1 do
      r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0')
    end
    return r;
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if (#x ~= 8) then return '' end
    local c = 0
    for i = 1, 8 do
      c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0)
    end
    return string.char(c)
  end))
end

-- Handle both C4:Base64Decode() and C4.Base64Decode(C4, ...) calling styles
function C4:Base64Decode(data, ...)
  -- If called as C4.Base64Decode(C4, data), first arg is C4
  -- If called as C4:Base64Decode(data), first arg is data
  if type(data) == "table" and data == C4 then
    -- Called as C4.Base64Decode(C4, data) - get the real data argument
    local realData = select(1, ...)
    return base64_decode_impl(realData)
  else
    -- Called as C4:Base64Decode(data)
    return base64_decode_impl(data)
  end
end

--- Generate a UUID (simplified version)
local uuid_counter = 0
function C4:UUID(prefix)
  uuid_counter = uuid_counter + 1
  return string.format("%s-%d-%d", prefix or "UUID", os.time(), uuid_counter)
end

--- Timer implementation using socket.select
local timers = {}
local timer_id = 0

function C4:SetTimer(delay_ms, callback, repeating)
  timer_id = timer_id + 1
  local id = timer_id
  local timer = {
    id = id,
    delay = delay_ms / 1000, -- Convert to seconds
    callback = callback,
    repeating = repeating or false,
    next_fire = socket.gettime() + (delay_ms / 1000),
    cancelled = false
  }

  timers[id] = timer

  -- Return a timer object with Cancel method
  return {
    Cancel = function()
      if timers[id] then
        timers[id].cancelled = true
        timers[id] = nil
      end
    end
  }
end

-- Process timers (must be called periodically)
function C4:ProcessTimers()
  local now = socket.gettime()
  for id, timer in pairs(timers) do
    if not timer.cancelled and now >= timer.next_fire then
      timer.callback()

      if timer.repeating then
        timer.next_fire = now + timer.delay
      else
        timers[id] = nil
      end
    end
  end
end

--- TCP Client implementation
--- @class C4TCPClient
local TCPClient = {}
TCPClient.__index = TCPClient

-- Global registry of active TCP clients
local active_clients = {}
local client_id_counter = 0

function C4:CreateTCPClient()
  client_id_counter = client_id_counter + 1
  local client = {
    id = client_id_counter,
    socket = nil,
    on_connect = nil,
    on_disconnect = nil,
    on_error = nil,
    on_read = nil,
    connected = false
  }
  setmetatable(client, TCPClient)
  active_clients[client.id] = client
  return client
end

function TCPClient:OnConnect(callback)
  self.on_connect = callback
  return self
end

function TCPClient:OnDisconnect(callback)
  self.on_disconnect = callback
  return self
end

function TCPClient:OnError(callback)
  self.on_error = callback
  return self
end

function TCPClient:OnRead(callback)
  self.on_read = callback
  return self
end

function TCPClient:Connect(host, port)
  self.socket = socket.tcp()
  if not self.socket then
    if self.on_error then
      self.on_error(self, -1, "Failed to create socket")
    end
    return nil
  end

  -- Use blocking mode for simplicity
  self.socket:settimeout(5)

  local success, err = self.socket:connect(host, port)

  if not success then
    if self.on_error then
      self.on_error(self, -1, err or "Connection failed")
    end
    return nil
  end

  -- Now set to non-blocking for reads/writes
  self.socket:settimeout(0)
  self.connected = true

  -- Schedule connection callback
  if self.on_connect then
    -- Use a timer to simulate async connection
    C4:SetTimer(10, function()
      if self.on_connect then
        self.on_connect(self)
      end
    end, false)
  end

  return self
end

function TCPClient:Close()
  if self.socket then
    self.socket:close()
    self.socket = nil
  end
  self.connected = false

  -- Remove from active clients
  if self.id then
    active_clients[self.id] = nil
  end

  if self.on_disconnect then
    self.on_disconnect(self)
  end
end

function TCPClient:Write(data)
  if not self.socket then
    return false
  end

  local sent, err = self.socket:send(data)
  if not sent then
    if self.on_error then
      self.on_error(self, -1, err or "Write failed")
    end
    return false
  end
  return true
end

function TCPClient:ReadUpTo(max_bytes)
  if not self.socket then
    return
  end

  -- In Control4, ReadUpTo triggers async read. We'll simulate this by
  -- marking that we want to read, and the main loop will handle it
  self.want_read = true
  self.max_read_bytes = max_bytes
end

-- Perform actual socket read (called from main loop)
function TCPClient:DoRead()
  if not self.socket or not self.want_read then
    return
  end

  local data, err, partial = self.socket:receive(self.max_read_bytes or 4096)

  -- If we got data or partial data, call the callback
  if data and #data > 0 then
    if self.on_read then
      self.on_read(self, data)
    end
  elseif partial and #partial > 0 then
    if self.on_read then
      self.on_read(self, partial)
    end
  elseif err and err ~= "timeout" and err ~= "wantread" then
    -- Only treat as error if it's a real error
    if self.on_error then
      self.on_error(self, -1, err)
    end
    self:Close()
  end
end

-- Global sleep function using luasocket
function sleep(seconds)
  socket.sleep(seconds)
end

-- Global event loop processor - call this in test main loops
function processEventLoop()
  -- Process timers
  C4:ProcessTimers()

  -- Process socket reads for all active TCP clients
  for _, client in pairs(active_clients) do
    if client.DoRead then
      client:DoRead()
    end
  end
end

print("C4 shim layer loaded successfully")

return C4