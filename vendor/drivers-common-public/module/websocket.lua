-- Copyright 2025 Snap One, LLC. All rights reserved.

COMMON_WEBSOCKET_VER = 14

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")

--- @class WebSocket
--- @field url string The WebSocket URL.
--- @field connected boolean Whether the WebSocket is currently connected.
--- @field protocol string The WebSocket protocol (ws or wss).
--- @field host string The host address.
--- @field port number The port number.
--- @field resource string The resource path.
--- @field buf string The receive buffer.
--- @field ping_interval number The ping interval in seconds.
--- @field pong_response_interval number The pong response interval in seconds.
--- @field additionalHeaders string[] Additional headers to send.
--- @field wssOptions table WSS options.
--- @field netBinding integer? The network binding ID.
--- @field key string The WebSocket key.
--- @field deleteAfterClosing boolean Whether to delete after closing.
--- @field onDeleteComplete fun()|nil Optional callback invoked after deletion completes.
--- @field Sockets table<string|integer, WebSocket?>? Static map of active WebSocket connections.
local WebSocket = {}

do -- define globals
  DEBUG_WEBSOCKET = DEBUG_WEBSOCKET or false
end

--- DriverWorks embeds lpack which adds string.unpack(s, fmt) -> pos, ...
--- @diagnostic disable-next-line: access-invisible
--- @type fun(s: string, fmt: string): integer, ...
local sunpack = string.unpack

local realPrint = print
local function print(...)
  if DEBUG_WEBSOCKET then
    realPrint(...)
  end
end

--- Creates a new WebSocket connection.
--- @param url string The WebSocket URL.
--- @param additionalHeaders? string[] Additional headers.
--- @param wssOptions? table WSS options.
--- @return WebSocket|nil ws The WebSocket instance or nil on error.
--- @return string? error Error message if creation failed.
function WebSocket:new(url, additionalHeaders, wssOptions)
  if type(additionalHeaders) ~= "table" then
    additionalHeaders = nil
  end

  if self.Sockets and self.Sockets[url] then
    local ws = self.Sockets[url]
    ws.additionalHeaders = additionalHeaders
    return ws
  end

  -- important values to be incorporated into our WebSocket object
  local protocol, host, port, resource

  -- temporary values for parsing
  local rest, hostport

  protocol, rest = string.match(url or "", "(wss?)://(.*)")

  hostport, resource = string.match(rest or "", "(.-)(/.*)")
  if not (hostport and resource) then
    hostport = rest
    resource = "/"
  end

  host, port = string.match(hostport or "", "(.-):(.*)")

  if not (host and port) then
    host = hostport
    if protocol == "ws" then
      port = 80
    elseif protocol == "wss" then
      port = 443
    end
  end

  port = tonumber(port)

  if type(wssOptions) ~= "table" then
    wssOptions = {}
  end

  if protocol and host and port and resource then
    local ws = {
      url = url,
      protocol = protocol,
      host = host,
      port = port,
      resource = resource,
      buf = "",
      ping_interval = 30,
      pong_response_interval = 10,
      additionalHeaders = additionalHeaders or {},
      wssOptions = wssOptions,
    }

    setmetatable(ws, self)
    self.__index = self

    self.Sockets = self.Sockets or {}
    self.Sockets[url] = ws

    ws:setupC4Connection()

    return ws
  else
    return nil, "invalid WebSocket URL provided:" .. (url or "")
  end
end

--- Deletes the WebSocket connection and cleans up resources.
--- @param onComplete? fun() Optional callback invoked after cleanup completes.
function WebSocket:delete(onComplete)
  if self.deleteAfterClosing then
    -- Already deleting; chain the new callback after the existing one
    if onComplete then
      local existingCb = self.onDeleteComplete
      self.onDeleteComplete = function()
        if existingCb then
          existingCb()
        end
        onComplete()
      end
    end
    return nil
  end
  self.deleteAfterClosing = true
  self.onDeleteComplete = onComplete
  self:Close()

  return nil
end

--- Starts the WebSocket connection.
--- @return WebSocket self
function WebSocket:Start()
  print("Starting Web Socket... Opening net connection to " .. self.url)

  if self.netBinding and self.protocol and self.port then
    C4:NetDisconnect(self.netBinding, self.port)
    C4:NetConnect(self.netBinding, self.port)
  else
    print("C4 network connection not setup")
  end

  return self
end

function WebSocket:Close()
  self.running = false
  if self.connected then
    local pkt = string.char(0x88, 0x82, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8)
    if DEBUG_WEBSOCKET then
      print("TX CLOSE REQUEST")
    end
    self:sendToNetwork(pkt)
  end

  local _timer = function(timer)
    if self.netBinding then
      pcall(C4.NetDisconnect, C4, self.netBinding, self.port)
    end
    if self.deleteAfterClosing then
      self.deleteAfterClosing = nil

      if self.Sockets then
        if self.url then
          self.Sockets[self.url] = nil
        end
        if self.netBinding then
          OCS[self.netBinding] = nil
          RFN[self.netBinding] = nil
          self.Sockets[self.netBinding] = nil
        end
      end
      if self.netBinding then
        pcall(C4.SetBindingAddress, C4, self.netBinding, "")
      end
    end
    if self.onDeleteComplete then
      self.onDeleteComplete()
      self.onDeleteComplete = nil
    end
  end

  self.PingTimer = CancelTimer(self.PingTimer)
  self.PongResponseTimer = CancelTimer(self.PongResponseTimer)

  local timerId = "Websocket:" .. self.url .. ":Closing"
  SetTimer(timerId, 3 * ONE_SECOND, _timer)

  return self
end

--- Sends data through the WebSocket.
--- @param s string The data to send.
function WebSocket:Send(s)
  if self.connected then
    local len = string.len(s)
    local lenstr
    if len <= 125 then
      lenstr = string.char(0x81, bit.bor(len, 0x80))
    elseif len <= 65535 then
      lenstr = string.char(0x81, bit.bor(126, 0x80)) .. tohex(string.format("%04X", len))
    else
      lenstr = string.char(0x81, bit.bor(127, 0x80)) .. tohex(string.format("%16X", len))
    end

    local mask = {
      math.random(0, 255),
      math.random(0, 255),
      math.random(0, 255),
      math.random(0, 255),
    }

    local pkt = {
      lenstr,
      string.char(mask[1]),
      string.char(mask[2]),
      string.char(mask[3]),
      string.char(mask[4]),
    }

    table.insert(pkt, self:Mask(s, mask))

    local pkt = table.concat(pkt)
    if DEBUG_WEBSOCKET then
      local d = { "", "TX" }

      table.insert(d, "")
      table.insert(d, s)
      table.insert(d, "")

      local d = table.concat(d, "\r\n")

      print(d)
    end
    self:sendToNetwork(pkt)
  end

  return self
end

--- Sets the callback for received messages.
--- @param f fun(websocket: WebSocket, data: string) The callback function.
--- @return WebSocket self
function WebSocket:SetProcessMessageFunction(f)
  local _f = function(websocket, data)
    local success, ret = pcall(f, websocket, data)
    if success == false then
      print("WebSocket callback ProcessMessage error: ", ret, data)
    end
  end
  self.ProcessMessage = _f

  return self
end

--- Sets the callback for when the remote side closes the connection.
--- @param f fun(websocket: WebSocket) The callback function.
--- @return WebSocket self
function WebSocket:SetClosedByRemoteFunction(f)
  local _f = function(websocket)
    local success, ret = pcall(f, websocket)
    if success == false then
      print("WebSocket callback ClosedByRemote error: ", ret)
    end
  end
  self.ClosedByRemote = _f

  return self
end

--- Sets the callback for when the connection is established.
--- @param f fun(websocket: WebSocket) The callback function.
--- @return WebSocket self
function WebSocket:SetEstablishedFunction(f)
  local _f = function(websocket)
    local success, ret = pcall(f, websocket)
    if success == false then
      print("WebSocket callback Established error: ", ret)
    end
  end
  self.Established = _f

  return self
end

--- Sets the callback for when the connection goes offline.
--- @param f fun(websocket: WebSocket) The callback function.
--- @return WebSocket self
function WebSocket:SetOfflineFunction(f)
  local _f = function(websocket)
    local success, ret = pcall(f, websocket)
    if success == false then
      print("WebSocket callback Offline error: ", ret)
    end
  end
  self.Offline = _f

  return self
end

-- Functions below this line should not be called directly by users of this library

local _netBindingHighWaterMark = 6099

function WebSocket:setupC4Connection()
  local i = _netBindingHighWaterMark + 1
  while not self.netBinding and i ~= _netBindingHighWaterMark do
    local checkAddress = C4:GetBindingAddress(i)
    if checkAddress == nil or checkAddress == "" then
      self.netBinding = i
      break
    end
    i = i + 1
    if i == 6200 then
      i = 6100
      _netBindingHighWaterMark = _netBindingHighWaterMark + 1
    end
  end
  _netBindingHighWaterMark = assert(self.netBinding)

  if self.netBinding and self.protocol then
    self.Sockets = self.Sockets or {}
    self.Sockets[self.netBinding] = self

    if self.protocol == "wss" then
      C4:CreateNetworkConnection(self.netBinding, self.host, "SSL")
      C4:NetPortOptions(self.netBinding, self.port, "SSL", self.wssOptions)
    else
      C4:CreateNetworkConnection(self.netBinding, self.host)
    end

    OCS = OCS or {}
    OCS[self.netBinding] = function(idBinding, nPort, strStatus)
      self:ConnectionChanged(strStatus)
    end

    RFN = RFN or {}
    RFN[self.netBinding] = function(idBinding, nPort, strData)
      self:ParsePacket(strData)
    end
  end
  return self
end

function WebSocket:MakeHeaders()
  self.key = ""
  for i = 1, 16 do
    self.key = self.key .. string.char(math.random(33, 125))
  end
  self.key = C4:Base64Encode(self.key)

  local headers = {
    "GET " .. self.resource .. " HTTP/1.1",
    "Host: " .. self.host .. ":" .. self.port,
    "Cache-Control: no-cache",
    "Pragma: no-cache",
    "Connection: Upgrade",
    "Upgrade: websocket",
    "Sec-WebSocket-Key: " .. self.key,
    "Sec-WebSocket-Version: 13",
    "User-Agent: C4WebSocket/" .. COMMON_WEBSOCKET_VER,
  }

  for _, header in ipairs(self.additionalHeaders or {}) do
    table.insert(headers, header)
  end

  table.insert(headers, "\r\n")

  local headers = table.concat(headers, "\r\n")

  return headers
end

function WebSocket:ParsePacket(strData)
  self.buf = (self.buf or "") .. strData

  if self.running then
    self:parseWSPacket()
  else
    self:parseHTTPPacket()
  end
end

function WebSocket:parseWSPacket()
  local buflen = string.len(self.buf)
  if buflen < 2 then
    return
  end

  local _, h1, h2 = sunpack(self.buf, "bb")

  local final = (bit.band(h1, 0x80) == 0x80)
  local _rsv1 = (bit.band(h1, 0x40) == 0x40)
  local _rsv2 = (bit.band(h1, 0x20) == 0x20)
  local _rsv3 = (bit.band(h1, 0x10) == 0x10)
  local opcode = bit.band(h1, 0x0F)

  local masked = (bit.band(h2, 0x80) == 0x80)
  local mask
  local len = bit.band(h2, 0x7F)

  local msglen, headerlen
  if len <= 125 then
    msglen = len
    headerlen = 2
  elseif len == 126 then
    if buflen < 4 then
      return
    end
    local _, _, _, b1, b2 = sunpack(self.buf, "bbbb")
    msglen = b1 * 0x100 + b2
    headerlen = 4
  elseif len == 127 then
    if buflen < 10 then
      return
    end
    local _, _, _, b1, b2, b3, b4, b5, b6, b7, b8 = sunpack(self.buf, "bbbbbbbbbb")
    msglen = ((((((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4) * 0x100 + b5) * 0x100 + b6) * 0x100 + b7) * 0x100 + b8
    headerlen = 10
  else
    return
  end

  if masked then
    local maskbytes = string.sub(self.buf, headerlen + 1, headerlen + 5)
    mask = {}
    for i = 1, 4 do
      mask[i] = string.byte(string.sub(maskbytes, i, i))
    end
    headerlen = headerlen + 4
  end

  if string.len(self.buf) >= headerlen + msglen then
    local thisFragment = string.sub(self.buf, headerlen + 1, headerlen + msglen)
    if masked then
      if mask then
        thisFragment = self:Mask(thisFragment, mask)
      else
        print("masked bit set but no mask received")
        self.buf = ""
        return
      end
    end
    self.buf = string.sub(self.buf, headerlen + msglen + 1)

    if opcode == 0x08 then
      if DEBUG_WEBSOCKET then
        print("RX CLOSE REQUEST")
      end
      if self.ClosedByRemote then
        self:ClosedByRemote()
      end
    elseif opcode == 0x09 then -- ping control frame
      if DEBUG_WEBSOCKET then
        print("RX PING")
      end
      self:Pong()
    elseif opcode == 0x0A then -- pong control frame
      if DEBUG_WEBSOCKET then
        print("RX PONG")
      end
      self.PongResponseTimer = CancelTimer(self.PongResponseTimer)
    elseif opcode == 0x00 then -- continuation frame
      if not self.fragment then
        print("error: received continuation frame before start frame")
        self.buf = ""
        return
      end
      self.fragment = self.fragment .. thisFragment
    elseif opcode == 0x01 or opcode == 0x02 then -- non-control frame, beginning of fragment
      self.fragment = thisFragment
    end

    if final and opcode < 0x08 then
      local data = self.fragment
      self.fragment = nil

      if DEBUG_WEBSOCKET then
        local d = { "", "RX" }

        table.insert(d, "")
        table.insert(d, data)
        table.insert(d, "")

        local d = table.concat(d, "\r\n")

        print(d)
      end

      if self.ProcessMessage then
        self:ProcessMessage(data)
      end
    end

    if string.len(self.buf) > 0 then
      self:ParsePacket("")
    end
  end
end

function WebSocket:parseHTTPPacket()
  local headers = {}
  for line in string.gmatch(self.buf, "(.-)\r\n") do
    local k, v = string.match(line, "%s*(.-)%s*[:/*]%s*(.+)")
    if k and v then
      k = string.upper(k)
      headers[k] = v
    end
  end

  local EOH = string.find(self.buf, "\r\n\r\n")

  if EOH and headers["SEC-WEBSOCKET-ACCEPT"] then
    self.buf = string.sub(self.buf, EOH + 4)
    local check = self.key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    local hash = C4:Hash("SHA1", check, { ["return_encoding"] = "BASE64" })

    if
      headers["SEC-WEBSOCKET-ACCEPT"] == hash
      and string.lower(headers["UPGRADE"]) == "websocket"
      and string.lower(headers["CONNECTION"]) == "upgrade"
    then
      print("WS " .. self.url .. " running")

      self.running = true
      if self.Established then
        self:Established()
      end
    end
  end
end

function WebSocket:Ping()
  if self.connected then
    -- MASK of 0x00's
    local pkt = string.char(0x89, 0x80, 0x00, 0x00, 0x00, 0x00)
    if DEBUG_WEBSOCKET then
      print("TX PING")
    end

    local _timer = function(timer)
      print("WS " .. self.url .. " appears disconnected - timed out waiting for PONG")
      self:Close()
    end
    local timerId = "Websocket:" .. self.url .. ":PongResponse"
    self.PongResponseTimer = SetTimer(timerId, self.pong_response_interval * ONE_SECOND, _timer)

    self:sendToNetwork(pkt)
  end
end

function WebSocket:Pong()
  if self.connected then
    local pkt = string.char(0x8A, 0x80, 0x00, 0x00, 0x00, 0x00)
    if DEBUG_WEBSOCKET then
      print("TX PONG")
    end
    self:sendToNetwork(pkt)
  end
end

function WebSocket:ConnectionChanged(strStatus)
  self.connected = (strStatus == "ONLINE")

  self.PingTimer = CancelTimer(self.PingTimer)
  self.PongResponseTimer = CancelTimer(self.PongResponseTimer)

  if self.connected then
    local pkt = self:MakeHeaders()
    self:sendToNetwork(pkt)

    local _timer = function(timer)
      self:Ping()
    end
    local timerId = "Websocket:" .. self.url .. ":Ping"
    self.PingTimer = SetTimer(timerId, self.ping_interval * ONE_SECOND, _timer, true)
    print("WS " .. self.url .. " connected")
  else
    if self.running then
      print("WS " .. self.url .. " disconnected while running")
    else
      print("WS " .. self.url .. " disconnected while not running")
    end
    self.running = false
    if self.Offline then
      self:Offline()
    end
  end
end

function WebSocket:sendToNetwork(packet)
  C4:SendToNetwork(self.netBinding, self.port, packet)
end

function WebSocket:Mask(s, mask)
  if type(mask) == "table" then
  elseif type(mask) == "string" and string.len(mask) >= 4 then
    local m = {}
    for i = 1, string.len(mask) do
      table.insert(m, string.byte(mask[i]))
    end
    mask = m
  end

  local slen = string.len(s)
  local mlen = #mask

  local packet = {}

  for i = 1, slen do
    local pos = i % mlen
    if pos == 0 then
      pos = mlen
    end
    local maskbyte = mask[pos]
    local sbyte = string.sub(s, i, i)
    local byte = string.byte(sbyte)
    local char = string.char(bit.bxor(byte, maskbyte))
    table.insert(packet, char)
  end

  local packet = table.concat(packet)
  return packet
end

return WebSocket
