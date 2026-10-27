-- What lib/persist.lua traces for an encrypted key. Every shipped build traced
-- the value of each write and the default of each read, so a lock code, token
-- or password stored encrypted was printed in plain text with Log Mode on.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_encrypted_trace.lua

local T = require("testlib")

require("c4_shim")

local log = require("lib.logging")

-- Obviously fake secrets: a trace that shows any of these has leaked it.
local CODE = "FAKE-CODE-0000"
local TOKEN = "not-a-real-token"

-- A fresh instance has an empty cache, so get() reads storage as it does after a reload.
local function reload()
  ShimPersistLand()
  return getmetatable(require("lib.persist")):new()
end

-- Migrations load at the first get() of the process, so this is in place before any.
package.preload["migrations"] = function()
  return {
    Migrated = function(value)
      value.token = TOKEN
      return value
    end,
  }
end

--- Everything lib.logging prints at trace level while fn runs.
local function traced(fn)
  log:setLogLevel("5 - Trace")
  log:setLogMode("Print")
  local ok, err, output = T.capture(fn)
  log:setLogMode("")
  T.truthy("runs without error", ok, err)
  return output
end

T.section("a write to an encrypted key traces the key, not the value")
local p = reload()
local output = traced(function()
  p:set("AdminCode", CODE, true)
  p:set("Users", { [1] = { name = "User 1", code = CODE } }, true)
end)
T.contains("the key and that it was written", output, "Persist:set(AdminCode, ***REDACTED***, true)")
T.contains("a table value the same", output, "Persist:set(Users, ***REDACTED***, true)")
T.excludes("and never the value", output, CODE)
T.eq("the value is still stored", reload():get("AdminCode", nil, true), CODE)

T.section("a read of an encrypted key traces the key, not the default")
output = traced(function()
  reload():get("Pin", CODE, true)
end)
T.contains("in get", output, "Persist:get(Pin, ***REDACTED***, true)")
T.contains("and in _get", output, "Persist:_get(Pin, ***REDACTED***, true)")
T.excludes("and never the default", output, CODE)

T.section("a delete of an encrypted key traces no value")
output = traced(function()
  p:set("AdminCode", nil, true)
  p:set("Pin", "", true)
  p:delete("Users")
end)
T.contains("a set to nil shows nil", output, "Persist:set(AdminCode, nil, true)")
T.contains("a set to empty shows the delete it is", output, "Persist:set(Pin, , true)")
T.contains("a delete names the key", output, "Persist:delete(Users)")
T.excludes("and neither shows the value", output, CODE)

T.section("an encrypted key's migration and write-behind trace no value")
C4:PersistSetValue("Migrated", Serialize({ name = "Account" }), true)
output = traced(function()
  local q = reload()
  q:get("Migrated", nil, true)
  q:setWriteBehind("Session", 1000)
  q:defer(function()
    q:set("Session", TOKEN, true)
  end)
  q:flush()
end)
T.contains("the migration's write", output, "Persist:set(Migrated, ***REDACTED***, true)")
T.contains("the deferred write", output, "Persist:set(Session, ***REDACTED***, true)")
T.excludes("and neither shows the value", output, TOKEN)
T.eq("the migrated value is stored", reload():get("Migrated", nil, true), { name = "Account", token = TOKEN })
T.eq("and the deferred one", reload():get("Session", nil, true), TOKEN)

T.section("a plain key still traces its value")
output = traced(function()
  p:set("Room", "Den")
  reload():get("Level", 5)
end)
T.contains("in set", output, "Persist:set(Room, Den, nil)")
T.contains("and the default in get", output, "Persist:get(Level, 5, nil)")

T.finish()
