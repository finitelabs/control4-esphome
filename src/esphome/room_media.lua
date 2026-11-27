--- Room media for a panel: the device controls its Control4 room's media and shows what is playing.
---
--- Commands come from the device's YAML as `homeassistant.action` calls named `control4.media`, with a `command`
--- (see ROOM_COMMANDS and RoomMedia:command) and, for some, a value. What the room is doing goes back to the
--- device's `control4_media` and `control4_sources` API actions, when it declares them, whenever it changes.
---
--- The room is the Media Room property's, else the driver's own. Its state comes from the room's own variables;
--- the parts no controller documents (the media info's format, the room's source lists) are logged raw.

require("lib.utils")
require("drivers-common-public.global.handlers")
local log = require("lib.logging")

--- @class RoomMediaSource
--- @field id integer
--- @field name string
--- @field video boolean Selected with SELECT_VIDEO_DEVICE rather than SELECT_AUDIO_DEVICE.

--- @class RoomMedia
--- @field client ESPHomeClient
--- @field room integer|nil The room being watched.
--- @field sources RoomMediaSource[]
--- @field playing boolean Whether the room is playing: as Control4 reports it when it does, else what play_pause last asked for.
--- @field playKnown boolean Whether `playing` came from Control4.
--- @field digitalAudio integer|false|nil The Digital Media agent being watched (false: none found).
--- @field lastQueue string|nil The last raw queue status logged.
--- @field source integer|nil The selected source device whose variables are watched.
--- @field wasOn boolean Whether the room was on at the last push.
--- @field sent table<string, string> What each device action was last sent this connection.
--- @field lastInfo string|nil The last raw media info logged.
local RoomMedia = {}
RoomMedia.__index = RoomMedia

--- The action the device calls, and the device's actions this calls back.
RoomMedia.COMMAND_ACTION = "control4.media"
RoomMedia.INFO_ACTION = "control4_media"
RoomMedia.SOURCES_ACTION = "control4_sources"

--- Room variables, as drivers-common-public numbers them.
RoomMedia.VAR = {
  SELECTED_DEVICE = 1000,
  POWER_STATE = 1010,
  VOLUME = 1011,
  IS_MUTED = 1018,
  MEDIA_INFO = 1031,
}

--- The Digital Media agent's queue status variables, newest format first: they say whether each room's digital
--- media queue is playing.
RoomMedia.QUEUE_VARS = { 1006, 1004 }
--- Names the Digital Media agent's driver file goes by; the first one found is used.
RoomMedia.DIGITAL_AUDIO_C4I = {
  "digital_audio.c4i",
  "control4_digitalaudio.c4i",
  "control4_digital_audio.c4i",
  "digitalaudio.c4i",
}

--- Commands that are one room command with no value.
local ROOM_COMMANDS = {
  volume_up = "PULSE_VOL_UP",
  volume_down = "PULSE_VOL_DOWN",
  mute_toggle = "MUTE_TOGGLE",
  mute_on = "MUTE_ON",
  mute_off = "MUTE_OFF",
  play = "PLAY",
  pause = "PAUSE",
  stop = "STOP",
  next = "SKIP_FWD",
  previous = "SKIP_REV",
  room_off = "ROOM_OFF",
}

--- @param client ESPHomeClient
--- @return RoomMedia
function RoomMedia:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  instance.room = nil
  instance.sources = {}
  instance.playing = false
  instance.playKnown = false
  instance.digitalAudio = nil
  instance.lastQueue = nil
  instance.source = nil
  instance.wasOn = false
  instance.sent = {}
  instance.lastInfo = nil
  return instance
end

--- The room this panel controls: the Media Room property's, else the driver's own.
--- @return integer|nil
function RoomMedia:roomId()
  local chosen = tointeger(Properties["Media Room"])
  if chosen ~= nil and chosen > 0 then
    return chosen
  end
  return tointeger(C4:RoomGetId())
end

--- @param id integer
--- @return string
local function variable(room, id)
  local value = C4:GetDeviceVariable(room, id)
  if value == nil then
    return ""
  end
  return tostring(value)
end

--- Find the first value under any of `keys` (case-insensitive) anywhere in a parsed XML table.
--- @param node any
--- @param keys table<string, boolean>
--- @param depth? integer
--- @return string|nil
local function findValue(node, keys, depth)
  depth = depth or 0
  if type(node) ~= "table" or depth > 8 then
    return nil
  end
  for k, v in pairs(node) do
    if type(k) == "string" and keys[k:lower()] then
      if type(v) == "string" or type(v) == "number" then
        return tostring(v)
      elseif type(v) == "table" and (type(v[1]) == "string" or type(v[1]) == "number") then
        return tostring(v[1])
      end
    end
  end
  for _, v in pairs(node) do
    local found = findValue(v, keys, depth + 1)
    if found ~= nil then
      return found
    end
  end
  return nil
end

local TITLE_KEYS = { title = true, songname = true, song = true, name = true }
local ARTIST_KEYS = { artist = true, subtitle = true, artistname = true }
local ALBUM_KEYS = { album = true, albumname = true }
local IMAGE_KEYS = {
  img = true,
  image = true,
  imageurl = true,
  image_url = true,
  art = true,
  coverart = true,
  cover_art = true,
}

--- An image URL the device can fetch: one on the controller ("/...") gets the controller's address.
--- @param url string|nil
--- @return string
local function absoluteUrl(url)
  if IsEmpty(url) then
    return ""
  end
  url = tostring(url)
  if url:match("^https?://") then
    return url
  end
  if url:sub(1, 1) == "/" then
    local host = C4:GetControllerNetworkAddress()
    if not IsEmpty(host) then
      return "http://" .. host .. url
    end
  end
  return ""
end

--- Read the room's CURRENT_MEDIA_INFO: XML whose tags vary by source, so the usual tag names are looked for.
--- @param raw string
--- @return string title, string artist, string album, string imageUrl
function RoomMedia.parseMediaInfo(raw)
  if IsEmpty(raw) then
    return "", "", "", ""
  end
  local ok, parsed = pcall(ParseXml, raw)
  if not ok or type(parsed) ~= "table" then
    return "", "", "", ""
  end
  local image = findValue(parsed, IMAGE_KEYS)
  if not IsEmpty(image) and not tostring(image):match("^%a+://") and tostring(image):sub(1, 1) ~= "/" then
    -- Media service drivers send IMAGEURL Base64 encoded.
    local ok, decoded = pcall(C4.Base64Decode, C4, tostring(image))
    if ok and type(decoded) == "string" and (decoded:match("^%a+://") or decoded:sub(1, 1) == "/") then
      image = decoded
    end
  end
  -- Media service drivers describe what is playing as LINE1 (title) to LINE4.
  return findValue(parsed, TITLE_KEYS) or findValue(parsed, { line1 = true }) or "",
    findValue(parsed, ARTIST_KEYS) or findValue(parsed, { line2 = true }) or "",
    findValue(parsed, ALBUM_KEYS) or findValue(parsed, { line3 = true }) or "",
    absoluteUrl(image)
end

local STATE_KEYS = { state = true, playstate = true, play_state = true, status = true, mediastate = true }

--- Whether a state string means playing (true), paused or stopped (false), or nothing known (nil).
--- @param value any
--- @return boolean|nil
local function playingFrom(value)
  if value == nil then
    return nil
  end
  local upper = tostring(value):upper()
  -- Not-playing words first: Sonos' paused state is PAUSED_PLAYBACK.
  if upper:find("PAUS") or upper:find("STOP") or upper:find("IDLE") or upper:find("NOT") or upper == "END" then
    return false
  elseif upper:find("PLAY") then
    return true
  end
  return nil
end

--- Read a room's play state from the Digital Media agent's queue status XML: the state of the queue the room
--- belongs to. The format is not documented, so any element naming the room (in a key with "room" in its name, or
--- an attribute) is taken with the nearest state above or beside it.
--- @param raw string
--- @param room integer
--- @return boolean|nil
function RoomMedia.parseQueueState(raw, room)
  if IsEmpty(raw) or room == nil then
    return nil
  end
  local ok, parsed = pcall(ParseXml, raw)
  if not ok or type(parsed) ~= "table" then
    return nil
  end
  local wanted = tostring(room)
  local function stateOf(node)
    for k, v in pairs(node) do
      if type(k) == "string" and STATE_KEYS[k:lower()] and (type(v) == "string" or type(v) == "number") then
        return playingFrom(v)
      end
    end
    if type(node._attr) == "table" then
      for k, v in pairs(node._attr) do
        if STATE_KEYS[tostring(k):lower()] then
          return playingFrom(v)
        end
      end
    end
    return nil
  end
  local function namesRoom(node)
    for k, v in pairs(node) do
      if type(k) == "string" and k:lower():find("room") then
        if tostring(v) == wanted then
          return true
        end
        if type(v) == "table" then
          for _, item in pairs(v) do
            if
              tostring(item) == wanted
              or (type(item) == "table" and (tostring(item[1]) == wanted or tostring(item.id) == wanted))
            then
              return true
            end
          end
          if tostring(v[1]) == wanted or tostring(v.id) == wanted then
            return true
          end
        end
      end
    end
    if type(node._attr) == "table" then
      for k, v in pairs(node._attr) do
        if tostring(k):lower():find("room") and tostring(v) == wanted then
          return true
        end
      end
    end
    return false
  end
  local function walk(node, inherited, depth)
    if type(node) ~= "table" or depth > 10 then
      return nil
    end
    local state = stateOf(node)
    if state == nil then
      state = inherited
    end
    if namesRoom(node) and state ~= nil then
      return state
    end
    for k, child in pairs(node) do
      if k ~= "_attr" and type(child) == "table" then
        local found = walk(child, state, depth + 1)
        if found ~= nil then
          return found
        end
      end
    end
    return nil
  end
  return walk(parsed, nil, 0)
end

--- The Digital Media agent, once found (false when there is none).
--- @return integer|nil
function RoomMedia:digitalAudioId()
  if self.digitalAudio == nil then
    local id, found
    for _, c4i in ipairs(self.DIGITAL_AUDIO_C4I) do
      id = tointeger(next(C4:GetDevicesByC4iName(c4i) or {})) or tointeger(GetAgentId(c4i))
      if id ~= nil and id > 0 then
        found = c4i
        break
      end
      id = nil
    end
    self.digitalAudio = id or false
    log:info("Room media: Digital Media agent %s", id and (id .. " (" .. found .. ")") or "not found")
  end
  return self.digitalAudio or nil
end

--- Names of source driver variables that may hold its play state.
local SOURCE_STATE_PATTERNS = { "PLAY", "TRANSPORT", "STATE", "STATUS" }

--- Whether a source device's variables say it is playing: the first variable whose name suggests a play state
--- and whose value reads as playing, paused or stopped.
--- @param device integer
--- @return boolean|nil state, string|nil name
local function sourcePlaying(device)
  local ok, variables = pcall(C4.GetDeviceVariables, C4, device)
  if not ok or type(variables) ~= "table" then
    return nil
  end
  for _, var in pairs(variables) do
    local name = tostring(Select(var, "name") or ""):upper()
    for _, pattern in ipairs(SOURCE_STATE_PATTERNS) do
      if name:find(pattern) then
        local state = playingFrom(Select(var, "value"))
        if state ~= nil then
          return state, name
        end
        break
      end
    end
  end
  return nil
end

--- Watch the selected source device's variables: a source driver may keep its play state in one of them. All are
--- logged once at Info, and their changes at Debug.
--- @param device integer
function RoomMedia:watchSource(device)
  if device == self.source then
    return
  end
  if self.source ~= nil then
    local ok, old = pcall(C4.GetDeviceVariables, C4, self.source)
    for id in pairs(ok and type(old) == "table" and old or {}) do
      UnregisterVariableListener(self.source, tointeger(id))
    end
  end
  self.source = device > 0 and device or nil
  if self.source == nil then
    return
  end
  local ok, variables = pcall(C4.GetDeviceVariables, C4, self.source)
  if not ok or type(variables) ~= "table" then
    log:info("Room media: source %s has no variables to read", self.source)
    return
  end
  local summary = {}
  for id, var in pairs(variables) do
    local name = tostring(Select(var, "name") or id)
    summary[name] = Select(var, "value")
    local varId = tointeger(id)
    if varId ~= nil then
      local source = self.source
      RegisterVariableListener(source, varId, function(_, _, value)
        log:debug("Room media: source %s variable %s (%s) = %s", source, name, varId, value)
        self:push()
      end)
    end
  end
  log:info("Room media: source %s (%s) variables: %s", self.source, C4:GetDeviceDisplayName(self.source), summary)
end

--- Whether the room is playing, from the Digital Media agent's queue status, else the media info's own state,
--- else the selected source's own variables, else nil (not reported).
--- @param mediaInfo string
--- @return boolean|nil
function RoomMedia:reportedPlaying(mediaInfo)
  if self.source ~= nil then
    local state = sourcePlaying(self.source)
    if state ~= nil then
      return state
    end
  end
  local agent = self:digitalAudioId()
  if agent ~= nil then
    for _, id in ipairs(self.QUEUE_VARS) do
      local raw = variable(agent, id)
      if not IsEmpty(raw) then
        if raw ~= self.lastQueue then
          self.lastQueue = raw
          log:info("Room media: queue status (%s): %s", id, raw)
        end
        local state = self.parseQueueState(raw, self.room)
        if state ~= nil then
          return state
        end
      end
    end
  end
  if not IsEmpty(mediaInfo) then
    local ok, parsed = pcall(ParseXml, mediaInfo)
    if ok and type(parsed) == "table" then
      return playingFrom(findValue(parsed, STATE_KEYS))
    end
  end
  return nil
end

--- The device connected: take its commands, watch its room and show it the room's state.
function RoomMedia:connected()
  self.sent = {}
  if not self:wanted() then
    return
  end
  self.client:subscribeActions(function(action, data)
    self:action(action, data)
  end)
  self:watch()
  self:loadSources()
  self:push()
end

--- The device is gone: whatever it was shown is no longer known.
function RoomMedia:disconnected()
  self.sent = {}
end

--- The Media Room or Media Sources property changed.
function RoomMedia:settingsChanged()
  self.sent = {}
  if not self.client:isConnected() or not self:wanted() then
    return
  end
  self:watch()
  self:loadSources()
  self:push()
end

--- Whether the device wants any of this: it declares one of the room media actions.
--- @return boolean
function RoomMedia:wanted()
  return self.client:hasService(self.INFO_ACTION) or self.client:hasService(self.SOURCES_ACTION)
end

--- Every room variable, by number (drivers-common-public's names), watched for the debug log: which of them
--- change on play and pause is not documented.
local ROOM_VAR_NAMES = {}
for name, id in pairs(ROOM_VARS or {}) do
  ROOM_VAR_NAMES[id] = name:gsub("%s+$", "")
end

--- Watch the room's variables, moving the listeners when the room changed.
function RoomMedia:watch()
  local room = self:roomId()
  if room == self.room then
    return
  end
  if self.room ~= nil then
    for id in pairs(ROOM_VAR_NAMES) do
      UnregisterVariableListener(self.room, id)
    end
    for _, id in pairs(self.VAR) do
      UnregisterVariableListener(self.room, id)
    end
  end
  self.room = room
  if room == nil then
    log:warn("Room media: no room to watch; set Media Room")
    return
  end
  log:info("Room media: watching room %s (%s)", room, C4:GetDeviceDisplayName(room))
  local watched = {}
  for id, name in pairs(ROOM_VAR_NAMES) do
    watched[id] = name
  end
  for _, id in pairs(self.VAR) do
    watched[id] = watched[id] or tostring(id)
  end
  for id, name in pairs(watched) do
    RegisterVariableListener(room, id, function(_, _, value)
      log:debug("Room media: room %s variable %s (%s) = %s", room, name, id, value)
      self:push()
    end)
  end
  local agent = self:digitalAudioId()
  if agent ~= nil then
    for name, id in pairs(DIGITAL_AUDIO_VARS or {}) do
      RegisterVariableListener(agent, id, function(_, _, value)
        log:debug("Room media: Digital Media variable %s (%s) = %s", name, id, value)
        self:push()
      end)
    end
    for _, id in ipairs(self.QUEUE_VARS) do
      RegisterVariableListener(agent, id, function(_, _, value)
        log:debug("Room media: Digital Media variable %s = %s", id, value)
        self:push()
      end)
    end
  end
end

--- Read a room source list (listen or watch) from a UI request's XML reply.
--- @param room integer
--- @param request string
--- @param video boolean
--- @param into RoomMediaSource[]
--- @param seen table<integer, boolean>
local function readSourceList(room, request, video, into, seen)
  local ok, reply = pcall(C4.SendUIRequest, C4, room, request, {})
  log:info("Room media: %s for room %s returned %s", request, room, ok and reply or ("an error: " .. tostring(reply)))
  if not ok or IsEmpty(reply) then
    return
  end
  local parsedOk, parsed = pcall(ParseXml, tostring(reply))
  if not parsedOk or type(parsed) ~= "table" then
    return
  end
  -- Collect every element with a device id: <device><id>..</id><name>..</name></device> or attributes.
  local function walk(node, depth)
    if type(node) ~= "table" or depth > 8 then
      return
    end
    local id = tointeger(node.id or node.deviceid or (node._attr and (node._attr.id or node._attr.deviceid)))
    if id ~= nil and id > 0 and not seen[id] then
      seen[id] = true
      local name = node.name or (node._attr and node._attr.name) or C4:GetDeviceDisplayName(id) or ("Device " .. id)
      table.insert(into, { id = id, name = tostring(name), video = video })
    end
    for _, child in pairs(node) do
      if type(child) == "table" then
        walk(child, depth + 1)
      end
    end
  end
  walk(parsed, 0)
end

--- The room's sources: the Media Sources property's device IDs (`123` listen, `456:video` watch), else the
--- room's own listen and watch lists.
function RoomMedia:loadSources()
  local sources, seen = {}, {}
  local listed = tostring(Properties["Media Sources"] or "")
  for item in listed:gmatch("[^,%s]+") do
    local id, kind = item:match("^(%d+):?(%a*)$")
    id = tointeger(id)
    if id ~= nil and not seen[id] then
      seen[id] = true
      local name = C4:GetDeviceDisplayName(id) or ("Device " .. id)
      table.insert(sources, { id = id, name = tostring(name), video = kind:lower() == "video" })
    end
  end
  if #sources == 0 and self.room ~= nil then
    readSourceList(self.room, "GET_LISTEN_DEVICES", false, sources, seen)
    readSourceList(self.room, "GET_WATCH_DEVICES", true, sources, seen)
  end
  self.sources = sources
  log:info("Room media: %d sources: %s", #sources, sources)
end

--- Call a device action with only what changed since it was last called.
--- @param action string
--- @param args table<string, any>
--- @param signature string
function RoomMedia:send(action, args, signature)
  if not self.client:hasService(action) or self.sent[action] == signature then
    return
  end
  self.sent[action] = signature
  self.client:executeServiceWithArgs(action, args):next(nil, function(error)
    self.sent[action] = nil
    log:warn("Room media: could not call '%s'; %s", action, error)
  end)
end

--- Show the device what the room is doing.
function RoomMedia:push()
  local room = self.room
  if room == nil or not self.client:isConnected() then
    return
  end
  local selected = tointeger(variable(room, self.VAR.SELECTED_DEVICE)) or 0
  local on = toboolean(variable(room, self.VAR.POWER_STATE)) or selected > 0
  local source = selected > 0 and (C4:GetDeviceDisplayName(selected) or "") or ""
  local volume = math.floor((tonumber(variable(room, self.VAR.VOLUME)) or 0) + 0.5)
  local muted = toboolean(variable(room, self.VAR.IS_MUTED)) or false
  local raw = variable(room, self.VAR.MEDIA_INFO)
  if raw ~= self.lastInfo then
    self.lastInfo = raw
    log:info("Room media: media info for room %s: %s", room, raw)
  end
  local title, artist, album, image = self.parseMediaInfo(raw)
  self:watchSource(selected)
  local reported = self:reportedPlaying(raw)
  self.playKnown = reported ~= nil
  if reported ~= nil then
    self.playing = reported
  elseif on and not self.wasOn then
    -- Nothing reports it: a room that just turned on is playing what it turned on for.
    self.playing = true
  end
  self.wasOn = on
  if not on then
    title, artist, album, image = "", "", "", ""
    self.playing = false
  end

  self:send(
    self.INFO_ACTION,
    {
      room_on = on,
      source = source,
      title = title,
      artist = artist,
      album = album,
      image_url = image,
      volume = volume,
      muted = muted,
      playing = self.playing,
    },
    table.concat(
      { tostring(on), source, title, artist, album, image, volume, tostring(muted), tostring(self.playing) },
      "|"
    )
  )

  local names, index = {}, -1
  for i, item in ipairs(self.sources) do
    names[#names + 1] = (item.name:gsub("\n", " "))
    if item.id == selected then
      index = i - 1
    end
  end
  local list = table.concat(names, "\n")
  self:send(self.SOURCES_ACTION, { sources = list, selected = index }, list .. "|" .. index)
end

--- Send a command to the room.
--- @param command string
--- @param params? table<string, any>
function RoomMedia:roomCommand(command, params)
  if self.room == nil then
    log:warn("Room media: no room for %s", command)
    return
  end
  log:info("Room media: room %s <- %s %s", self.room, command, params or {})
  C4:SendToDevice(self.room, command, params or {})
end

--- A `homeassistant.action` call from the device.
--- @param action string
--- @param data table<string, string>
function RoomMedia:action(action, data)
  if action ~= self.COMMAND_ACTION then
    log:debug("Room media: ignoring action %s", action)
    return
  end
  self:command(tostring(data.command or ""), data)
end

--- Carry out one command from the device.
--- @param command string
--- @param data table<string, string>
function RoomMedia:command(command, data)
  local roomCommand = ROOM_COMMANDS[command]
  if roomCommand ~= nil then
    self:roomCommand(roomCommand)
    if command == "play" then
      self.playing = true
    elseif command == "pause" or command == "stop" or command == "room_off" then
      self.playing = false
    end
  elseif command == "play_pause" then
    -- Pause when the room is playing, else play: as Control4 reports it, or, when it does not, alternating.
    self:roomCommand(self.playing and "PAUSE" or "PLAY")
    if not self.playKnown then
      self.playing = not self.playing
    end
  elseif command == "set_volume" then
    local level = tonumber(data.level)
    if level == nil then
      log:warn("Room media: set_volume needs a level")
      return
    end
    self:roomCommand("SET_VOLUME_LEVEL", { LEVEL = math.max(0, math.min(100, math.floor(level + 0.5))) })
  elseif command == "select_source" then
    local source = self.sources[(tointeger(data.index) or -1) + 1]
    if source == nil then
      log:warn("Room media: no source %s (have %d)", data.index, #self.sources)
      return
    end
    self:roomCommand(source.video and "SELECT_VIDEO_DEVICE" or "SELECT_AUDIO_DEVICE", { deviceid = source.id })
  elseif command == "room_command" and not IsEmpty(data.name) then
    -- Any other room command, by its Control4 name, for what this does not cover.
    local params = {}
    for k, v in pairs(data) do
      if k ~= "command" and k ~= "name" then
        params[k] = v
      end
    end
    self:roomCommand(tostring(data.name), params)
  else
    log:warn("Room media: unknown command '%s'", command)
    return
  end
  self:push()
end

return RoomMedia
