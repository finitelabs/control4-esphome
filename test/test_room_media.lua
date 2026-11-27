-- Tests room media: the device's `control4.media` commands become room commands, and the room's state goes to the
-- device's control4_media and control4_sources actions.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_room_media.lua

require("drivers-common-public.global.lib")
require("drivers-common-public.global.handlers")
require("c4_shim")

local T = require("testlib")
local deferred = require("deferred")
local RoomMedia = require("esphome.room_media")

local ROOM, OTHER_ROOM = 21, 22
local DIGITAL_AUDIO = 900
local SPOTIFY, APPLE_TV = 301, 302

-- The controller: room variables, device names, room commands sent, UI requests answered.
local variables = {
  [ROOM] = { [1000] = "0", [1010] = "0", [1011] = "35", [1018] = "0", [1031] = "" },
  [OTHER_ROOM] = { [1000] = "0", [1010] = "0", [1011] = "10", [1018] = "0", [1031] = "" },
  [DIGITAL_AUDIO] = { [1004] = "", [1006] = "" },
}
function C4:GetDevicesByC4iName(name)
  if name == "digital_audio.c4i" then
    return { [DIGITAL_AUDIO] = "Digital Media" }
  end
end
local names = { [ROOM] = "Entrance", [OTHER_ROOM] = "Kitchen", [SPOTIFY] = "Spotify", [APPLE_TV] = "Apple TV" }
local roomCommands, uiRequests, listeners = {}, {}, {}
function C4:RoomGetId()
  return ROOM
end
function C4:GetDeviceVariable(device, id)
  return (variables[device] or {})[id]
end
function C4:GetDeviceDisplayName(id)
  return names[tonumber(id)]
end
function C4:SendToDevice(device, command, params)
  roomCommands[#roomCommands + 1] = { device = device, command = command, params = params }
end
function C4:GetControllerNetworkAddress()
  return "192.168.1.10"
end
function C4:SendUIRequest(device, request)
  uiRequests[#uiRequests + 1] = request
  if device == ROOM and request == "GET_LISTEN_DEVICES" then
    return "<devices><device><id>" .. SPOTIFY .. "</id><name>Spotify</name></device></devices>"
  elseif device == ROOM and request == "GET_WATCH_DEVICES" then
    return "<devices><device><id>" .. APPLE_TV .. "</id><name>Apple TV</name></device></devices>"
  end
  return ""
end
function C4:RegisterVariableListener(device, id)
  listeners[device .. ":" .. id] = true
end
function C4:UnregisterVariableListener(device, id)
  listeners[device .. ":" .. id] = nil
end
local function changed(device, id, value)
  variables[device][id] = value
  OnWatchedVariableChanged(device, id, value)
end

-- The device: which actions it declares, what it was sent, and its action subscription.
local declared = {}
local calls = {}
local actionCallback
local connected = true
local client = {
  isConnected = function()
    return connected
  end,
  hasService = function(_, name)
    return declared[name] == true
  end,
  executeServiceWithArgs = function(_, name, args)
    calls[#calls + 1] = { name = name, args = args }
    return deferred.new():resolve()
  end,
  subscribeActions = function(_, callback)
    actionCallback = callback
    return deferred.new():resolve()
  end,
}
local function lastCall(name)
  for i = #calls, 1, -1 do
    if calls[i].name == name then
      return calls[i].args
    end
  end
end
local function lastCommand()
  return roomCommands[#roomCommands]
end

Properties["Media Room"] = ""
Properties["Media Sources"] = ""
local media = RoomMedia:new(client)

--------------------------------------------------------------------------------
T.section("A device without the media actions is left alone")
--------------------------------------------------------------------------------

media:connected()
T.eq("no action subscription", actionCallback, nil)
T.eq("no room watched", next(listeners), nil)
T.eq("nothing sent", #calls, 0)

--------------------------------------------------------------------------------
T.section("A connect watches the driver's room and shows its state")
--------------------------------------------------------------------------------

declared.control4_media = true
declared.control4_sources = true
media:connected()
T.truthy("subscribed to the device's actions", actionCallback)
T.truthy("watches power", listeners[ROOM .. ":1010"])
T.truthy("watches volume", listeners[ROOM .. ":1011"])
T.truthy("watches media info", listeners[ROOM .. ":1031"])
local info = lastCall("control4_media")
T.eq("room off", info.room_on, false)
T.eq("volume", info.volume, 35)
T.eq("no source", info.source, "")
local sources = lastCall("control4_sources")
T.eq("sources from the room's listen and watch lists", sources.sources, "Spotify\nApple TV")
T.eq("none selected", sources.selected, -1)

--------------------------------------------------------------------------------
T.section("Room changes go to the device")
--------------------------------------------------------------------------------

variables[ROOM][1031] =
  "<mediainfo><title>So What</title><artist>Miles Davis</artist><album>Kind of Blue</album><img>/images/art.jpg</img></mediainfo>"
changed(ROOM, 1000, tostring(SPOTIFY))
changed(ROOM, 1010, "1")
info = lastCall("control4_media")
T.eq("room on", info.room_on, true)
T.eq("source name", info.source, "Spotify")
T.eq("title", info.title, "So What")
T.eq("artist", info.artist, "Miles Davis")
T.eq("album", info.album, "Kind of Blue")
T.eq("image on the controller gets its address", info.image_url, "http://192.168.1.10/images/art.jpg")
T.eq("selected source", lastCall("control4_sources").selected, 0)

local before = #calls
changed(ROOM, 1010, "1")
T.eq("an unchanged room is not resent", #calls, before)

changed(ROOM, 1018, "1")
T.eq("mute", lastCall("control4_media").muted, true)
changed(ROOM, 1011, "62")
T.eq("volume", lastCall("control4_media").volume, 62)

--------------------------------------------------------------------------------
T.section("Media service style media info: LINE1..LINE3 and a Base64 IMAGEURL")
--------------------------------------------------------------------------------

local title, artist, album, image = RoomMedia.parseMediaInfo(
  "<info><LINE1>Holnap hajnalban</LINE1><LINE2>Kispál és a Borz</LINE2><LINE3>Ágy, asztal, tv</LINE3><IMAGEURL>"
    .. C4:Base64Encode("http://192.168.1.20/art/1.jpg")
    .. "</IMAGEURL></info>"
)
T.eq("LINE1 is the title", title, "Holnap hajnalban")
T.eq("LINE2 the artist", artist, "Kispál és a Borz")
T.eq("LINE3 the album", album, "Ágy, asztal, tv")
T.eq("the image URL decoded", image, "http://192.168.1.20/art/1.jpg")

--------------------------------------------------------------------------------
T.section("Commands become room commands")
--------------------------------------------------------------------------------

actionCallback("control4.media", { command = "volume_up" })
T.eq("volume up", lastCommand().command, "PULSE_VOL_UP")
T.eq("to the room", lastCommand().device, ROOM)
actionCallback("control4.media", { command = "volume_down" })
T.eq("volume down", lastCommand().command, "PULSE_VOL_DOWN")
actionCallback("control4.media", { command = "mute_toggle" })
T.eq("mute", lastCommand().command, "MUTE_TOGGLE")
actionCallback("control4.media", { command = "next" })
T.eq("next", lastCommand().command, "SKIP_FWD")
actionCallback("control4.media", { command = "previous" })
T.eq("previous", lastCommand().command, "SKIP_REV")

actionCallback("control4.media", { command = "play_pause" })
T.eq("a room that turned on is taken as playing: play_pause pauses", lastCommand().command, "PAUSE")
T.eq("and says it is not playing", lastCall("control4_media").playing, false)
actionCallback("control4.media", { command = "play_pause" })
T.eq("then plays", lastCommand().command, "PLAY")

actionCallback("control4.media", { command = "set_volume", level = "120" })
T.eq("set volume", lastCommand().command, "SET_VOLUME_LEVEL")
T.eq("clamped", lastCommand().params.LEVEL, 100)

actionCallback("control4.media", { command = "select_source", index = "1" })
T.eq("a watch source is a video selection", lastCommand().command, "SELECT_VIDEO_DEVICE")
T.eq("of its device", lastCommand().params.deviceid, APPLE_TV)
actionCallback("control4.media", { command = "select_source", index = "0" })
T.eq("a listen source is an audio selection", lastCommand().command, "SELECT_AUDIO_DEVICE")

actionCallback("control4.media", { command = "room_command", name = "SCAN_FWD", SPEED = "2" })
T.eq("any room command by name", lastCommand().command, "SCAN_FWD")
T.eq("with its values", lastCommand().params.SPEED, "2")

before = #roomCommands
actionCallback("control4.media", { command = "nonsense" })
actionCallback("control4.media", { command = "select_source", index = "9" })
actionCallback("other.action", { command = "volume_up" })
T.eq("unknown commands, missing sources and other actions send nothing", #roomCommands, before)

actionCallback("control4.media", { command = "room_off" })
T.eq("room off", lastCommand().command, "ROOM_OFF")

--------------------------------------------------------------------------------
T.section("The play state Control4 reports wins over the toggle")
--------------------------------------------------------------------------------

T.truthy("watches the queue status", listeners[DIGITAL_AUDIO .. ":1006"])
changed(ROOM, 1010, "1")
changed(
  DIGITAL_AUDIO,
  1006,
  "<queues><queue><state>PLAY</state><rooms><id>"
    .. ROOM
    .. "</id></rooms></queue><queue><state>STOP</state><rooms><id>99</id></rooms></queue></queues>"
)
T.eq("playing, from the room's queue", lastCall("control4_media").playing, true)
actionCallback("control4.media", { command = "play_pause" })
T.eq("so play_pause pauses", lastCommand().command, "PAUSE")
actionCallback("control4.media", { command = "play_pause" })
T.eq("and keeps pausing until Control4 says otherwise", lastCommand().command, "PAUSE")
changed(DIGITAL_AUDIO, 1006, '<queues><queue state="PAUSE"><rooms><id>' .. ROOM .. "</id></rooms></queue></queues>")
T.eq("paused, from an attribute", lastCall("control4_media").playing, false)
actionCallback("control4.media", { command = "play_pause" })
T.eq("so play_pause plays", lastCommand().command, "PLAY")

T.eq(
  "a queue without the room says nothing",
  RoomMedia.parseQueueState("<queue><state>PLAY</state><room>7</room></queue>", ROOM),
  nil
)
T.eq(
  "media info's own state counts too",
  RoomMedia.parseQueueState("<q><status>Playing</status><roomid>21</roomid></q>", 21),
  true
)
changed(DIGITAL_AUDIO, 1006, "")

--------------------------------------------------------------------------------
T.section("A source driver's own play state variable counts")
--------------------------------------------------------------------------------

local SONOS = 272
names[SONOS] = "Sonos"
local sonosVars =
  { ["1001"] = { name = "PLAY_STATE", value = "PLAYING" }, ["1002"] = { name = "VOLUME", value = "20" } }
local shimDeviceVariables = C4.GetDeviceVariables
function C4:GetDeviceVariables(id)
  if tonumber(id) == SONOS then
    return sonosVars
  end
  return shimDeviceVariables(self, id)
end
changed(ROOM, 1000, tostring(SONOS))
T.truthy("watches the source's variables", listeners[SONOS .. ":1001"])
T.eq("playing, from the source", lastCall("control4_media").playing, true)
actionCallback("control4.media", { command = "play_pause" })
T.eq("so play_pause pauses", lastCommand().command, "PAUSE")
sonosVars["1001"].value = "PAUSED_PLAYBACK"
OnWatchedVariableChanged(SONOS, 1001, "PAUSED_PLAYBACK")
T.eq("paused, from the source", lastCall("control4_media").playing, false)
changed(ROOM, 1000, tostring(SPOTIFY))
T.falsy("stops watching the old source", listeners[SONOS .. ":1001"])

--------------------------------------------------------------------------------
T.section("With nothing reporting it, a room that turns on is playing")
--------------------------------------------------------------------------------

changed(ROOM, 1010, "0")
changed(ROOM, 1000, "0")
T.eq("off is not playing", lastCall("control4_media").playing, false)
changed(ROOM, 1000, tostring(SPOTIFY))
changed(ROOM, 1010, "1")
T.eq("turned on: playing", lastCall("control4_media").playing, true)
actionCallback("control4.media", { command = "play_pause" })
T.eq("so the first tap pauses", lastCommand().command, "PAUSE")

--------------------------------------------------------------------------------
T.section("Media Room and Media Sources")
--------------------------------------------------------------------------------

Properties["Media Room"] = tostring(OTHER_ROOM)
Properties["Media Sources"] = tostring(SPOTIFY) .. ", " .. APPLE_TV .. ":video"
media:settingsChanged()
T.falsy("stops watching the old room", listeners[ROOM .. ":1010"])
T.truthy("watches the chosen room", listeners[OTHER_ROOM .. ":1010"])
T.eq("its volume", lastCall("control4_media").volume, 10)
T.eq("sources from the property", lastCall("control4_sources").sources, "Spotify\nApple TV")
actionCallback("control4.media", { command = "volume_up" })
T.eq("commands go to the chosen room", lastCommand().device, OTHER_ROOM)
actionCallback("control4.media", { command = "select_source", index = "1" })
T.eq(":video selects as video", lastCommand().command, "SELECT_VIDEO_DEVICE")

--------------------------------------------------------------------------------
T.section("A reconnect shows the device everything again")
--------------------------------------------------------------------------------

media:disconnected()
before = #calls
media:connected()
T.eq("media and sources resent", #calls, before + 2)

T.finish()
