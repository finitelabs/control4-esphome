--- Lets a companion driver install an ESPHome driver update that the ESPHome
--- driver's own updater wrote to disk but Director never applied.
---
--- Through v20261024 the updater sent every update in one burst on a socket it
--- closed at once, and Director applied only the first one or two. The ESPHome
--- driver goes last, so with two or more companions installed it never updated.
--- The companions that did update find its new c4z on disk and send it alone.

local log = require("lib.logging")
local version = require("version")

local MAIN_FILENAME = "esphome.c4z"
local MAIN_DIRNAME = "esphome"
local TIMER_ID = "MainDriverCatchUp"
-- Long enough for a working updater to reach the ESPHome driver after its companions.
local CHECK_DELAY_MS = 60 * 1000
-- Spreads companions that load together by device id, so one installs and the rest find it current.
local CHECK_SPREAD_S = 60

local M = {}

--- Reads a little-endian unsigned integer.
--- @param s string
--- @param pos integer 1-based position of the first byte.
--- @param n integer Byte count.
--- @return integer
local function readLE(s, pos, n)
  local value = 0
  for i = n, 1, -1 do
    value = value * 256 + s:byte(pos + i - 1)
  end
  return value
end

--- Reads bytes from a file in the current directory.
--- @param name string
--- @param offset integer 0-based offset.
--- @param count integer
--- @return string
local function readAt(name, offset, count)
  local fh = C4:FileOpen(name)
  C4:FileSetPos(fh, offset)
  local data = C4:FileRead(fh, count)
  C4:FileClose(fh)
  return data
end

--- Size of a file in the current directory.
--- @param name string
--- @return integer|nil size Nil when the file is missing.
local function fileSize(name)
  if not C4:FileExists(name) then
    return nil
  end
  local fh = C4:FileOpen(name)
  local size = C4:FileGetSize(fh)
  C4:FileClose(fh)
  return size
end

--- The uncompressed size a zip's central directory records for one entry.
--- @param name string Zip file in the current directory.
--- @param entry string Entry name inside the zip.
--- @return integer|nil size Nil when the file, its central directory or the entry is missing.
function M.zipEntrySize(name, entry)
  local size = fileSize(name)
  if size == nil or size < 22 then
    return nil
  end
  -- The end-of-central-directory record is 22 bytes plus a comment of up to 65535.
  local tailLength = math.min(size, 22 + 65535)
  local tail = readAt(name, size - tailLength, tailLength)
  local eocd
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == "PK\5\6" then
      eocd = i
      break
    end
  end
  if eocd == nil then
    return nil
  end
  local entries = readLE(tail, eocd + 10, 2)
  local directory = readAt(name, readLE(tail, eocd + 16, 4), readLE(tail, eocd + 12, 4))
  local pos = 1
  for _ = 1, entries do
    if directory:sub(pos, pos + 3) ~= "PK\1\2" then
      return nil
    end
    local nameLength = readLE(directory, pos + 28, 2)
    if directory:sub(pos + 46, pos + 45 + nameLength) == entry then
      return readLE(directory, pos + 24, 4)
    end
    pos = pos + 46 + nameLength + readLE(directory, pos + 30, 2) + readLE(directory, pos + 32, 2)
  end
  return nil
end

--- Whether an ESPHome driver newer than the installed one is waiting on disk.
--- @return boolean
function M.mainUpdateWaiting()
  if IsEmpty(C4:GetDevicesByC4iName(MAIN_FILENAME) or {}) then
    return false
  end
  local mainVersion = version(GetDriverVersion(MAIN_FILENAME) or "")
  local ownVersion = version(C4:GetDriverConfigInfo("version") or "")
  if mainVersion == nil or ownVersion == nil or not (mainVersion < ownVersion) then
    return false
  end
  -- A release changes the driver's code, so the size of driver.lua tells the waiting copy from the installed one.
  UnlockC4ZRoot()
  C4:FileSetDir("C4Z_ROOT", MAIN_DIRNAME)
  local installedSize = fileSize("driver.lua")
  C4:FileSetDir("C4Z_ROOT")
  local waitingSize = M.zipEntrySize(MAIN_FILENAME, "driver.lua")
  return installedSize ~= nil and waitingSize ~= nil and installedSize ~= waitingSize
end

--- Asks Director to install the ESPHome driver's c4z from disk.
local function installMain()
  local c4soap = XMLTag(
    "c4soap",
    XMLTag("param", MAIN_FILENAME, nil, nil, { name = "name", type = "string" }),
    false,
    false,
    { name = "UpdateProjectC4i", session = "0", operation = "RWX", category = "composer", async = "0" }
  ) .. "\0"
  C4:CreateTCPClient()
    :OnConnect(function(client)
      client:Write(c4soap)
      client:ReadUntil("\0")
    end)
    :OnRead(function(client, data)
      client:Close()
      log:info("Director answered the ESPHome driver update: %s", data)
    end)
    :OnError(function(client, errCode, errMsg)
      client:Close()
      log:warn("Could not install the waiting ESPHome driver update: %s %s", errCode, errMsg)
    end)
    :Connect("127.0.0.1", 5020)
end

--- Whether this is the lowest-numbered instance of its driver.
--- @param deviceId integer
--- @return boolean
local function isFirstInstance(deviceId)
  for id, _ in pairs(C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}) do
    if tointeger(id) < deviceId then
      return false
    end
  end
  return true
end

--- Schedules a check that installs a waiting ESPHome driver update from the lowest-numbered instance.
function M.schedule()
  if not C4.GetDriverFileName then
    -- Without it the ESPHome driver's updater cannot send itself last, so it is never the one left behind.
    return
  end
  local deviceId = C4:GetDeviceID()
  SetTimer(TIMER_ID, CHECK_DELAY_MS + (deviceId % CHECK_SPREAD_S) * 1000, function()
    local ok, waiting = pcall(function()
      return isFirstInstance(deviceId) and M.mainUpdateWaiting()
    end)
    if not ok then
      log:warn("Could not check for a waiting ESPHome driver update: %s", waiting)
    elseif waiting then
      log:info("The ESPHome driver is older than this driver and its update is waiting; installing it")
      installMain()
    end
  end)
end

return M
