--- Tests what Encryption Status says when the SwitchBot driver's cloud key fetch fails: the reason, with no Lua file
--- position in front of it.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_switchbot_key_fetch_errors.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local SwitchBot = require("esphome.ble.parsers.switchbot")
local deferred = require("deferred")
local http = require("lib.http")
local values = require("lib.values")

H.use("esphome_switchbot")

--- The cloud's answer to each request, as response bodies: login, user info and keys.
local answers
local post = http.post
function http:post(url, data)
  local body
  if url:find("wonderlabs", 1, true) then
    body = answers[3]
  elseif data == "{}" then
    body = answers[2]
  else
    body = answers[1]
  end
  return deferred.new():resolve({ code = 200, body = body or {} })
end

--- Starts a Relay Switch with no keys, enters a cloud login, which fetches them, with the cloud answering
--- `bodies`, and returns its Encryption Status.
--- @param bodies table[] The login, user info and keys answers.
local function fetchWith(bodies)
  answers = bodies
  H.boot({ ["MAC Address"] = "AA:BB:CC:DD:EE:05" }, function()
    values:update("Device Type", SwitchBot.DEVICE_NAMES[SwitchBot.DeviceTypeCode.RELAY_1], "STRING")
  end)
  Properties["SwitchBot Username"] = "test-user@example.test"
  Properties["SwitchBot Password"] = "not-a-real-password"
  OnPropertyChanged("SwitchBot Password")
  return Properties["Encryption Status"]
end

local OK = { statusCode = 100 }

H.test("a refused login says its status", function()
  T.eq("Encryption Status", fetchWith({ { statusCode = 401 } }), "Error: Login status 401")
end)

H.test("a login refused with a message says the message", function()
  T.eq("Encryption Status", fetchWith({ { statusCode = 190, message = "wrong password" } }), "Error: wrong password")
end)

H.test("a login with no token says so", function()
  T.eq("Encryption Status", fetchWith({ OK }), "Error: No access token in response")
end)

H.test("a refused user info request says its status", function()
  local login = { statusCode = 100, body = { access_token = "token" } }
  T.eq("Encryption Status", fetchWith({ login, { statusCode = 500 } }), "Error: User info status 500")
end)

H.test("a user info answer with no region says so", function()
  local login = { statusCode = 100, body = { access_token = "token" } }
  T.eq("Encryption Status", fetchWith({ login, OK }), "Error: No region in response")
end)

H.test("a refused key request says its status, and missing keys say so", function()
  local login = { statusCode = 100, body = { access_token = "token" } }
  local region = { statusCode = 100, body = { botRegion = "us" } }
  T.eq("refused", fetchWith({ login, region, { statusCode = 403 } }), "Error: Get keys status 403")
  T.eq("missing", fetchWith({ login, region, OK }), "Error: Missing keys in response")
end)

http.post = post
T.finish()
