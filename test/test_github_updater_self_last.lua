-- Tests that updateAll sends the running driver's own c4z LAST over the
-- UpdateProjectC4i socket. Updating the running driver reloads it and tears the
-- send loop (and its socket) down, so any companion queued after it would be
-- stranded a version behind.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_self_last.lua

local T = require("testlib")
local F = require("c4_fixtures")

local updater = require("lib.github-updater")
require("drivers-common-public.global.lib")
JSON = require("JSON")
local deferred = require("deferred")
local semver = require("version")
local http = require("lib.http")

local RUNNING = C4:GetDriverFileName()
local COMPANION_A = "example_companion_a.c4z"
local COMPANION_B = "example_companion_b.c4z"

-- Everything in the batch is installed, and every current version is older than
-- the release so all three are downloaded.
C4.GetDevicesByC4iName = function()
  return { 1 }
end
GetDriverVersion = function()
  return "1.0.0"
end

-- The release lists the running driver in the MIDDLE. A naive send order would
-- reload it before COMPANION_B, stranding COMPANION_B.
updater.getLatestRelease = function()
  return deferred.new():resolve({
    version = semver("2.0.0"),
    assets = {
      { name = COMPANION_A, browser_download_url = "https://example.invalid/a" },
      { name = RUNNING, browser_download_url = "https://example.invalid/self" },
      { name = COMPANION_B, browser_download_url = "https://example.invalid/b" },
    },
  })
end
http.get = function()
  return deferred.new():resolve({ body = "payload" })
end

-- Capture the order filenames are handed to UpdateProjectC4i.
local tcp = F.captureTcpClient()

updater:updateAll("finitelabs/example", { COMPANION_A, RUNNING, COMPANION_B }, false, false)

tcp.restore()

local sent = {}
for _, data in ipairs(tcp.writes) do
  local name = data:match("([%w_]+%.c4z)")
  if name then
    table.insert(sent, name)
  end
end

T.check("all three drivers were sent", #sent == 3, string.format("sent %d: %s", #sent, table.concat(sent, ", ")))
T.check("the running driver is sent last", sent[#sent] == RUNNING, "order: " .. table.concat(sent, ", "))

local runningIndex, companionBIndex
for i, name in ipairs(sent) do
  if name == RUNNING then
    runningIndex = i
  elseif name == COMPANION_B then
    companionBIndex = i
  end
end
T.check(
  "no companion is sent after the running driver",
  runningIndex ~= nil and companionBIndex ~= nil and runningIndex > companionBIndex,
  "order: " .. table.concat(sent, ", ")
)

T.finish()
