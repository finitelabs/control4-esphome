-- Tests how src/lib/utils.lua and src/lib/github-updater.lua address driver directories:
-- the running driver's own version reads through the C4Z alias with no unlock, companion
-- drivers unlock C4Z_ROOT first, and the download write unlocks for itself rather than
-- inheriting an unlock from the version loop.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_alias.lua

local T = require("testlib")

-- tools/gen-squishy.lua bundles from package.loaded, so github-updater.lua has to require
-- lib.utils itself rather than relying on a driver's driver.lua to have required it first.
-- Deliberately no GetDriverVersion stub; requiring lib.github-updater must be enough.
T.check(
  "GetDriverVersion is not defined before lib.github-updater is required",
  GetDriverVersion == nil,
  "a stub would void this check"
)

-- The modules return already-constructed instances, not the classes.
local updater = require("lib.github-updater")

T.check(
  "requiring lib.github-updater loads lib.utils",
  package.loaded["lib.utils"] ~= nil,
  "utils.lua is absent from package.loaded, so gen-squishy would omit it from the .c4z"
)
T.check(
  "GetDriverVersion is callable after requiring lib.github-updater",
  type(GetDriverVersion) == "function",
  string.format("GetDriverVersion is %s; the version loop would fail with a nil-call", type(GetDriverVersion))
)

-- utils.lua calls Select and FileRead, which drivers-common-public defines as globals.
require("drivers-common-public.global.lib")

JSON = require("JSON")
local deferred = require("deferred")
local semver = require("version")

local UNLOCK_KEY = "c29tZXNwZWNpYWxrZXk=++11"
local RUNNING_DRIVER = C4:GetDriverFileName()
local COMPANION_DRIVER = "example_companion.c4z"

--- Records every C4:FileSetDir argument so each scenario can assert the order it unlocked
--- and addressed the alias in. The shim's latch stays on once set, so ordering is what
--- distinguishes "unlocked for itself" from "inherited an earlier unlock".
local dirCalls = {}
local realFileSetDir = C4.FileSetDir
function C4:FileSetDir(dir, ...)
  table.insert(dirCalls, dir)
  return realFileSetDir(self, dir, ...)
end

local function resetDirCalls()
  dirCalls = {}
end

local function indexOf(value)
  for i, dir in ipairs(dirCalls) do
    if dir == value then
      return i
    end
  end
  return nil
end

local function dirCallList()
  return table.concat(dirCalls, ", ")
end

--- downloadOutdatedDrivers rejects with a table of messages indexed by number.
local function describeError(err)
  if type(err) ~= "table" then
    return tostring(err)
  end
  local parts = {}
  for _, message in pairs(err) do
    table.insert(parts, tostring(message))
  end
  return table.concat(parts, "; ")
end

--- driver.xml is not served by the shim, so the parsed version is nil and semver would
--- reject it. Every scenario here is about which directory was addressed.
local realGetDriverVersion = GetDriverVersion
local versionCalls = {}
local versionError = nil
function GetDriverVersion(filename)
  table.insert(versionCalls, filename)
  local ok, err = pcall(realGetDriverVersion, filename)
  if not ok then
    versionError = err
    error(err, 0)
  end
  return "1.0.0"
end

local http = require("lib.http")

-- Guards against passing on a no-op shim.
T.check("C4Z_ROOT is locked before anything runs", not pcall(function()
  C4:FileSetDir("C4Z_ROOT")
end), "shim accepted C4Z_ROOT with no unlock, so this suite cannot detect the defect")

---------------------------------------------------------------------------
-- The running driver's own version read
---------------------------------------------------------------------------

resetDirCalls()
pcall(realGetDriverVersion, RUNNING_DRIVER)

T.check("the running driver reads through C4Z", indexOf("C4Z") ~= nil, "addressed " .. dirCallList())
T.check(
  "the running driver never unlocks C4Z_ROOT",
  indexOf(UNLOCK_KEY) == nil and indexOf("C4Z_ROOT") == nil,
  "addressed " .. dirCallList()
)

---------------------------------------------------------------------------
-- The download write, on a project running a single driver from the repo
---------------------------------------------------------------------------

-- Runs before any companion read, so C4Z_ROOT is still locked and an unlock the write
-- fails to perform surfaces as a real "Invalid alias" rather than a passing assertion.
function updater:getLatestRelease()
  return deferred.new():resolve({
    version = semver("2.0.0"),
    assets = { { name = RUNNING_DRIVER, browser_download_url = "https://example.invalid/" .. RUNNING_DRIVER } },
  })
end
function http:get()
  return deferred.new():resolve({ body = "driver payload" })
end

resetDirCalls()
local downloaded, downloadError
updater:downloadOutdatedDrivers("C4Z_ROOT", "finitelabs/example", { RUNNING_DRIVER }, false, false):next(function(names)
  downloaded = names
end, function(err)
  downloadError = err
end)

T.check(
  "the single-driver version loop leaves C4Z_ROOT locked",
  indexOf("C4Z") ~= nil and (indexOf(UNLOCK_KEY) == nil or indexOf(UNLOCK_KEY) > indexOf("C4Z")),
  "addressed " .. dirCallList()
)
T.check(
  "the download write unlocks C4Z_ROOT before addressing it",
  indexOf(UNLOCK_KEY) ~= nil and indexOf("C4Z_ROOT") ~= nil and indexOf(UNLOCK_KEY) < indexOf("C4Z_ROOT"),
  "addressed " .. dirCallList()
)
T.check(
  "the asset was written",
  type(downloaded) == "table" and downloaded[1] == RUNNING_DRIVER,
  downloadError and describeError(downloadError) or "the download chain did not resolve"
)

---------------------------------------------------------------------------
-- A companion driver's version read
---------------------------------------------------------------------------

resetDirCalls()
pcall(realGetDriverVersion, COMPANION_DRIVER)

T.check(
  "a companion driver unlocks C4Z_ROOT before addressing it",
  indexOf(UNLOCK_KEY) ~= nil and indexOf("C4Z_ROOT") ~= nil and indexOf(UNLOCK_KEY) < indexOf("C4Z_ROOT"),
  "addressed " .. dirCallList()
)
T.check("a companion driver does not read through C4Z", indexOf("C4Z") == nil, "addressed " .. dirCallList())

---------------------------------------------------------------------------
-- The version loop still covers every filename
---------------------------------------------------------------------------

function updater:getLatestRelease()
  return deferred.new():resolve({ version = semver("0.0.1"), assets = {} })
end

versionCalls = {}
versionError = nil
local ok, err = pcall(function()
  updater:getOutdatedDriverAssets("finitelabs/example", { RUNNING_DRIVER, COMPANION_DRIVER }, false, false)
end)

T.check("getOutdatedDriverAssets does not fail on the alias", ok, err)
T.check("no Invalid alias error was raised", versionError == nil, versionError)
T.check(
  "every driver filename was resolved",
  #versionCalls == 2,
  string.format("expected 2 GetDriverVersion calls, got %d", #versionCalls)
)

---------------------------------------------------------------------------
-- Controllers without C4:GetDriverFileName
---------------------------------------------------------------------------

local realGetDriverFileName = C4.GetDriverFileName
C4.GetDriverFileName = nil

resetDirCalls()
pcall(realGetDriverVersion, RUNNING_DRIVER)

T.check(
  "without C4:GetDriverFileName the running driver falls back to C4Z_ROOT",
  indexOf(UNLOCK_KEY) ~= nil and indexOf("C4Z_ROOT") ~= nil and indexOf(UNLOCK_KEY) < indexOf("C4Z_ROOT"),
  "addressed " .. dirCallList()
)
T.check("the fallback does not read through C4Z", indexOf("C4Z") == nil, "addressed " .. dirCallList())

C4.GetDriverFileName = realGetDriverFileName

T.finish()
