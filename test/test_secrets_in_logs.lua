--- Tests that a password, a key or a lock code never reaches a driver's log,
--- even at Log Level 6 - Ultra with Log Mode Print and Log, where the shared
--- dispatcher also prints each property change and proxy message it handles.
--- A secret counts as logged if its text appears, or if a base64 run in the
--- log decodes to text that holds it (a serialized command body).
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_secrets_in_logs.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local deferred = require("deferred")
local log = require("lib.logging")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local ULTRA = { ["Log Level"] = "6 - Ultra", ["Log Mode"] = "Print and Log" }

--- Every line printed or written to the controller's log while `fn` runs.
local function captured(fn)
  local lines = {}
  local function keep(line)
    lines[#lines + 1] = tostring(line)
  end
  local realPrint, realError, realDebug = print, C4.ErrorLog, C4.DebugLog
  print = function(...) -- luacheck: ignore
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    keep(table.concat(parts, " "))
  end
  C4.ErrorLog = function(_, line)
    keep(line)
  end
  C4.DebugLog = function(_, line)
    keep(line)
  end
  local ok, err = pcall(fn)
  print, C4.ErrorLog, C4.DebugLog = realPrint, realError, realDebug -- luacheck: ignore
  assert(ok, err)
  return table.concat(lines, "\n")
end

--- Whether `text` shows `secret`, as is or inside a base64 run.
local function leaks(text, secret)
  if text:find(secret, 1, true) then
    return true
  end
  for run in text:gmatch("[%w+/]+=*") do
    if #run >= 16 then
      local ok, decoded = pcall(C4.Base64Decode, C4, run)
      if ok and type(decoded) == "string" and decoded:find(secret, 1, true) then
        return true
      end
    end
  end
  return false
end

--- Set a property on the loaded driver the way Composer does.
local function setProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

T.section("the ESPHome client's traces mask a device password and a lock code")
do
  log:setLogLevel("6 - Ultra")
  log:setLogMode("Print and Log")
  local client = ESPHomeClient:new()
  local text = captured(function()
    client:sendMessage(ESPHomeProtoSchema.Message.AuthenticationRequest, { password = "Hunter2Password" })
    client:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.lock_command, { key = 7, code = "8642" })
  end)
  T.eq("the password is not logged", leaks(text, "Hunter2Password"), false)
  T.eq("the lock code is not logged", leaks(text, "8642"), false)
  T.eq("the call itself is", text:find("lock_command", 1, true) ~= nil, true)
end

T.section("the ESPHome lock entity never logs the code in a command")
do
  log:setLogLevel("6 - Ultra")
  log:setLogMode("Print and Log")
  DEBUGPRINT = true
  local LockEntity = require("esphome.entities.lock")
  for _, outcome in ipairs({ "succeeds", "fails" }) do
    local client = {
      callServiceMethod = function()
        if outcome == "succeeds" then
          return deferred.new():resolve(nil)
        end
        return deferred.new():reject("no answer")
      end,
    }
    local entity = { key = 31, ref = "31" .. outcome, name = "Front Door " .. outcome }
    local lockEntity = LockEntity:new(client)
    lockEntity:discovered(entity)
    local bindingId = require("lib.bindings"):getDynamicBinding(LockEntity.TYPE, "lock_" .. entity.ref).bindingId
    local text = captured(function()
      ReceivedFromProxy(bindingId, "ENTITY_COMMAND", {
        body = SerializeSafe({ command = 1, has_code = true, code = "8642" }),
      })
    end)
    T.eq("a command that " .. outcome .. ": the code is not logged", leaks(text, "8642"), false)
  end
  DEBUGPRINT = false
end

H.use("esphome_lock")
H.test("the ESPHome Lock driver never logs its Lock Code", function()
  H.boot(ULTRA)
  DEBUGPRINT = true
  local text = captured(function()
    setProperty("Lock Code", "8642")
    H.rfp(5001, "LOCK")
    H.rfp(5001, "UNLOCK")
  end)
  T.eq("the commands go out", H.count("ENTITY_COMMAND", 5002), 2)
  T.eq("the code is not logged", leaks(text, "8642"), false)
end)

H.use("esphome")
H.test("the ESPHome driver never logs its Password or Encryption Key", function()
  H.boot(ULTRA)
  DEBUGPRINT = true
  local text = captured(function()
    setProperty("Password", "Hunter2Password")
    setProperty("Encryption Key", "c2VjcmV0LWtleS10aGF0LWlzLTMyLWJ5dGVzLWxvbmc=")
  end)
  T.eq("the password is not logged", leaks(text, "Hunter2Password"), false)
  T.eq("the key is not logged", leaks(text, "c2VjcmV0LWtleS10aGF0LWlzLTMyLWJ5dGVzLWxvbmc="), false)
end)

H.use("esphome_yale")
H.test("the ESPHome Yale driver never logs its Offline Key or Yale Password", function()
  H.boot(ULTRA)
  DEBUGPRINT = true
  local text = captured(function()
    setProperty("Offline Key", "00112233445566778899aabbccddeeff")
    setProperty("Yale Password", "Hunter2Password")
  end)
  T.eq("the offline key is not logged", leaks(text, "00112233445566778899aabbccddeeff"), false)
  T.eq("the password is not logged", leaks(text, "Hunter2Password"), false)
end)

H.use("esphome_bthome")
H.test("the ESPHome BTHome driver never logs its Bind Key", function()
  H.boot(ULTRA)
  local text = captured(function()
    setProperty("Bind Key", "231d39c1d7cc1ab1aee224cd096db932")
  end)
  T.eq("the bind key is not logged", leaks(text, "231d39c1d7cc1ab1aee224cd096db932"), false)
end)

H.use("esphome_switchbot")
H.test("the ESPHome SwitchBot driver never logs its Encryption Key or SwitchBot Password", function()
  H.boot(ULTRA)
  local text = captured(function()
    setProperty("Encryption Key", "0123456789abcdef0123456789abcdef")
    setProperty("SwitchBot Password", "Hunter2Password")
  end)
  T.eq("the key is not logged", leaks(text, "0123456789abcdef0123456789abcdef"), false)
  T.eq("the password is not logged", leaks(text, "Hunter2Password"), false)
end)

T.finish()
