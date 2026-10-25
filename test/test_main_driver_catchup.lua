-- Tests that a companion installs an ESPHome driver update left waiting on disk,
-- and sends nothing when the ESPHome driver is current, when the copy on disk is
-- the installed one, or when another instance of the companion will check.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_main_driver_catchup.lua

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.lib")
local catchup = require("esphome.main_driver_catchup")

local OWN_FILENAME = "esphome_light.c4z"

local function le(value, bytes)
  local out = {}
  for _ = 1, bytes do
    table.insert(out, string.char(value % 256))
    value = math.floor(value / 256)
  end
  return table.concat(out)
end

--- A zip holding only what the reader looks at: a central directory and its end record.
local function zipWith(entries)
  local body = string.rep("\0", 64)
  local directory = {}
  for _, entry in ipairs(entries) do
    local extra = entry.extra or ""
    table.insert(
      directory,
      "PK\1\2"
        .. string.rep("\0", 16)
        .. le(1, 4)
        .. le(entry.size, 4)
        .. le(#entry.name, 2)
        .. le(#extra, 2)
        .. le(0, 2)
        .. string.rep("\0", 12)
        .. entry.name
        .. extra
    )
  end
  local cd = table.concat(directory)
  local eocd = "PK\5\6" .. le(0, 4) .. le(#entries, 2) .. le(#entries, 2) .. le(#cd, 4) .. le(#body, 4) .. le(0, 2)
  return body .. cd .. eocd
end

local devices, timers, sent, ownVersion, deviceId

C4.GetDriverFileName = function()
  return OWN_FILENAME
end
C4.GetDevicesByC4iName = function(_, name)
  return devices[name]
end
C4.GetDeviceID = function()
  return deviceId
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "version" then
    return ownVersion
  end
end
SetTimer = function(id, delay, fn)
  table.insert(timers, { id = id, delay = delay, fn = fn })
end
C4.CreateTCPClient = function()
  local client = {}
  function client:OnConnect(callback)
    self._onConnect = callback
    return self
  end
  function client:OnRead(callback)
    self._onRead = callback
    return self
  end
  function client:OnError()
    return self
  end
  function client:Write(data)
    table.insert(sent, data)
  end
  function client:ReadUntil()
    self._onRead(self, '<c4soap name="UpdateProjectC4i" result="1"/>\0')
  end
  function client:Close() end
  function client:Connect()
    self._onConnect(self)
    return self
  end
  return client
end

--- An ESPHome driver at mainVersion with a driver.lua of installedSize, and a c4z on disk recording waitingSize.
local function setUp(mainVersion, installedSize, waitingSize)
  devices = { ["esphome.c4z"] = { [5] = "ESPHome" }, [OWN_FILENAME] = { [42] = "Light" } }
  deviceId = 42
  ownVersion = "20261031"
  timers, sent = {}, {}
  local installed = ShimFiles("C4Z_ROOT/esphome")
  installed["driver.xml"] = "<devicedata><version>" .. mainVersion .. "</version></devicedata>"
  installed["driver.lua"] = string.rep("x", installedSize)
  local root = ShimFiles("C4Z_ROOT")
  root["esphome.c4z"] = waitingSize
      and zipWith({ { name = "driver.xml", size = 100 }, { name = "driver.lua", size = waitingSize } })
    or nil
end

local function runCheck()
  catchup.schedule()
  for _, timer in ipairs(timers) do
    timer.fn()
  end
end

T.section("a stuck ESPHome driver is installed from the copy on disk")
setUp("20260926", 1000, 2000)
runCheck()
T.eq("one check is scheduled", #timers, 1)
T.check("it waits at least a minute", timers[1].delay >= 60 * 1000, "delay " .. tostring(timers[1].delay))
T.eq("one update is sent", #sent, 1)
T.check("it is UpdateProjectC4i", sent[1]:find('name="UpdateProjectC4i"', 1, true) ~= nil, sent[1])
T.check("it names the ESPHome driver", sent[1]:find(">esphome.c4z<", 1, true) ~= nil, sent[1])

T.section("nothing is sent when the ESPHome driver is current")
setUp("20261031", 1000, 2000)
runCheck()
T.eq("no update is sent", #sent, 0)

T.section("nothing is sent when the copy on disk is the installed one")
setUp("20260926", 2000, 2000)
runCheck()
T.eq("no update is sent", #sent, 0)

T.section("nothing is sent without a c4z on disk")
setUp("20260926", 1000, nil)
runCheck()
T.eq("no update is sent", #sent, 0)

T.section("nothing is sent when the ESPHome driver is not installed")
setUp("20260926", 1000, 2000)
devices["esphome.c4z"] = nil
runCheck()
T.eq("no update is sent", #sent, 0)

T.section("only the lowest-numbered instance checks")
setUp("20260926", 1000, 2000)
devices[OWN_FILENAME] = { [42] = "Light", [17] = "Light 2" }
runCheck()
T.eq("no update is sent", #sent, 0)

T.section("companions that load together check at different times")
setUp("20260926", 1000, 2000)
catchup.schedule()
deviceId = 43
devices[OWN_FILENAME] = { [43] = "Light" }
catchup.schedule()
T.check("the delays differ", timers[1].delay ~= timers[2].delay, timers[1].delay .. " and " .. timers[2].delay)

T.section("the zip reader")
local root = ShimFiles("C4Z_ROOT")
root["probe.zip"] = zipWith({
  { name = "driver.xml", size = 8508, extra = "12345" },
  { name = "www/icons/a.png", size = 7 },
  { name = "driver.lua", size = 1475963 },
})
root["junk.zip"] = string.rep("x", 100)
UnlockC4ZRoot()
C4:FileSetDir("C4Z_ROOT")
T.eq("finds an entry after one with an extra field", catchup.zipEntrySize("probe.zip", "driver.lua"), 1475963)
T.eq("finds the first entry", catchup.zipEntrySize("probe.zip", "driver.xml"), 8508)
T.eq("a missing entry is nil", catchup.zipEntrySize("probe.zip", "driver.js"), nil)
T.eq("a file that is not a zip is nil", catchup.zipEntrySize("junk.zip", "driver.lua"), nil)
T.eq("a missing file is nil", catchup.zipEntrySize("absent.zip", "driver.lua"), nil)

T.finish()
