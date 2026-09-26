-- Tests that updateAll writes nothing until every .c4z has downloaded, and reads
-- back each one it writes. The vendored FileWrite returns nothing, so a write that
-- failed was still sent to Director to install.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_write.lua

local T = require("testlib")
local F = require("c4_fixtures")

local updater = require("lib.github-updater")
require("drivers-common-public.global.lib")
JSON = require("JSON")
local deferred = require("deferred")
local semver = require("version")
local http = require("lib.http")

local RUNNING = C4:GetDriverFileName()
local INSTALLED = "installed payload"
local RELEASE = "release payload"

C4.GetDevicesByC4iName = function()
  return { 1 }
end
GetDriverVersion = function()
  return "1.0.0"
end
updater.getLatestRelease = function()
  return deferred.new():resolve({
    version = semver("2.0.0"),
    assets = { { name = RUNNING, browser_download_url = "https://example.invalid/self" } },
  })
end
http.get = function()
  return deferred.new():resolve({ body = RELEASE })
end

local root = ShimFiles("C4Z_ROOT")
local realFileWrite = C4.FileWrite

--- Run updateAll over the installed drivers and report what it did.
local function update(filenames)
  root[RUNNING] = INSTALLED
  local tcp = F.captureTcpClient()
  local result = {}
  updater:updateAll("finitelabs/example", filenames, false, false):next(function(updated)
    result.updated = updated
  end, function(err)
    result.err = err
  end)
  tcp.restore()
  result.sent = #tcp.writes
  return result
end

T.section("a write that reads back is sent to Director")
local result = update({ RUNNING })
T.eq("updateAll resolves with the driver", result.updated, { RUNNING })
T.eq("it is sent to Director", result.sent, 1)
T.eq("the release is on disk", root[RUNNING], RELEASE)

T.section("a failed write is put back and not sent")
C4.FileWrite = function(self, fh, count, data)
  if data == RELEASE then
    return -1
  end
  return realFileWrite(self, fh, count, data)
end
result = update({ RUNNING })
T.truthy("updateAll rejects", result.err)
T.eq("nothing is sent to Director", result.sent, 0)
T.eq("the installed file is put back", root[RUNNING], INSTALLED)

T.section("a short write is put back and not sent")
C4.FileWrite = function(self, fh, count, data)
  return realFileWrite(self, fh, data == RELEASE and 3 or count, data)
end
result = update({ RUNNING })
T.truthy("updateAll rejects", result.err)
T.eq("nothing is sent to Director", result.sent, 0)
T.eq("the installed file is put back", root[RUNNING], INSTALLED)
C4.FileWrite = realFileWrite

T.section("a failed download writes nothing")
local COMPANION = "example_companion.c4z"
updater.getLatestRelease = function()
  return deferred.new():resolve({
    version = semver("2.0.0"),
    assets = {
      { name = RUNNING, browser_download_url = "https://example.invalid/self" },
      { name = COMPANION, browser_download_url = "https://example.invalid/companion" },
    },
  })
end
http.get = function(_, url)
  if url:find("companion", 1, true) then
    return deferred.new():reject({ error = "timeout" })
  end
  return deferred.new():resolve({ body = RELEASE })
end
result = update({ RUNNING, COMPANION })
T.truthy("updateAll rejects", result.err)
T.eq("nothing is sent to Director", result.sent, 0)
T.eq("the driver that did download is not written", root[RUNNING], INSTALLED)

T.finish()
