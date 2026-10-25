-- Tests that updateAll sends one UpdateProjectC4i at a time and waits for
-- Director's reply before the next. Director drops commands still queued on a
-- socket that closes, so a burst followed by a close strands every driver after
-- the first.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_one_at_a_time.lua

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

C4.GetDevicesByC4iName = function()
  return { 1 }
end
GetDriverVersion = function()
  return "1.0.0"
end
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

local function sentNames(tcp)
  local names = {}
  for _, data in ipairs(tcp.writes) do
    table.insert(names, data:match("([%w_]+%.c4z)"))
  end
  return table.concat(names, ", ")
end

T.section("each update waits for Director's reply")
local tcp = F.captureTcpClient({ holdReplies = true })
local result = {}
updater:updateAll("finitelabs/example", { COMPANION_A, RUNNING, COMPANION_B }, false, false):next(function(updated)
  result.updated = updated
end)
T.eq("only the first update is sent before a reply", sentNames(tcp), COMPANION_A)
T.check("updateAll waits while companions are pending", result.updated == nil)
tcp.reply()
T.eq("the reply sends the next companion", sentNames(tcp), COMPANION_A .. ", " .. COMPANION_B)
T.check("updateAll still waits", result.updated == nil)
tcp.reply()
T.eq("the running driver goes last", sentNames(tcp), COMPANION_A .. ", " .. COMPANION_B .. ", " .. RUNNING)
T.check("updateAll resolves once the running driver is sent", result.updated ~= nil)
tcp.reply()
T.eq("nothing follows the running driver", #tcp.writes, 3)
tcp.restore()

T.section("without the running driver it resolves after the last reply")
tcp = F.captureTcpClient({ holdReplies = true })
result = {}
updater:updateAll("finitelabs/example", { COMPANION_A, COMPANION_B }, false, false):next(function(updated)
  result.updated = updated
end)
tcp.reply()
T.check("updateAll waits for the last companion", result.updated == nil)
tcp.reply()
T.eq("updateAll resolves with both companions", result.updated, { COMPANION_A, COMPANION_B })
tcp.restore()

T.finish()
