-- Tests that updateAll sends the running driver's own c4z LAST over the
-- UpdateProjectC4i socket. Updating the running driver reloads it and tears the
-- send loop (and its socket) down, so any companion queued after it would be
-- stranded a version behind.
--
-- Run from the template root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_github_updater_self_last.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

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
local sent = {}
C4.CreateTCPClient = function()
  local client = {}
  function client:OnConnect(cb)
    self._onConnect = cb
    return self
  end
  function client:OnError()
    return self
  end
  function client:Write(data)
    local name = data:match("([%w_]+%.c4z)")
    if name then
      table.insert(sent, name)
    end
  end
  function client:Close() end
  function client:Connect()
    if self._onConnect then
      self._onConnect(self)
    end
    return self
  end
  return client
end

updater:updateAll("finitelabs/example", { COMPANION_A, RUNNING, COMPANION_B }, false, false)

check("all three drivers were sent", #sent == 3, string.format("sent %d: %s", #sent, table.concat(sent, ", ")))
check("the running driver is sent last", sent[#sent] == RUNNING, "order: " .. table.concat(sent, ", "))

local runningIndex, companionBIndex
for i, name in ipairs(sent) do
  if name == RUNNING then
    runningIndex = i
  elseif name == COMPANION_B then
    companionBIndex = i
  end
end
check(
  "no companion is sent after the running driver",
  runningIndex ~= nil and companionBIndex ~= nil and runningIndex > companionBIndex,
  "order: " .. table.concat(sent, ", ")
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
