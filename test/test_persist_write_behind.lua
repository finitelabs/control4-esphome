-- Write-behind in lib/persist.lua and its lib/values.lua hooks: a registered key's
-- sets inside persist:defer() wait for one timed flush; everything else writes at once.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_write_behind.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.lib") -- Serialize

-- Every storage call, in order, as "set <key>" or "delete <key>", and the
-- encrypted flag of each key's last write.
local calls, encryptedFlag = {}, {}
local realSet, realDelete = C4.PersistSetValue, C4.PersistDeleteValue
function C4:PersistSetValue(key, value, encrypted)
  table.insert(calls, "set " .. key)
  encryptedFlag[key] = encrypted
  return realSet(self, key, value, encrypted)
end
function C4:PersistDeleteValue(key)
  table.insert(calls, "delete " .. key)
  return realDelete(self, key)
end

local timers = {}
local realSetTimer = C4.SetTimer
function C4:SetTimer(ms, ...)
  table.insert(timers, ms)
  return realSetTimer(self, ms, ...)
end

local function reset()
  calls, timers, encryptedFlag = {}, {}, {}
end

local function stored(key)
  return Deserialize(C4:PersistGetValue(key))
end

-- A fresh instance per section, so no cache, registration or timer carries over.
local function newPersist()
  ShimFireTimers() -- an earlier instance's timer must not write into this section
  reset()
  return getmetatable(require("lib.persist")):new()
end

-- ── Default: write-through, even inside defer ────────────────────────────────

T.section("a key not registered for write-behind writes every set at once")
local p = newPersist()
p:defer(function()
  p:set("Plain", { n = 1 })
  p:set("Plain", { n = 2 })
end)
T.eq("each set is its own write", calls, { "set Plain", "set Plain" })
T.eq("the bytes are the value serialized, as before", C4:PersistGetValue("Plain"), Serialize({ n = 2 }))
T.eq("and no timer is armed", #timers, 0)

-- ── Deferred writes ──────────────────────────────────────────────────────────

T.section("inside defer, a registered key reaches storage once per interval")
p = newPersist()
p:set("Hot", { n = 0 })
p:setWriteBehind("Hot", 60000)
reset()
p:defer(function()
  for n = 1, 5 do
    p:set("Hot", { n = n })
  end
end)
T.eq("five sets write nothing yet", calls, {})
T.eq("the cache already has the latest", p:get("Hot"), { n = 5 })
T.eq("storage still has the old value", stored("Hot"), { n = 0 })
T.eq("one timer, at the interval", timers, { 60000 })
ShimFireTimers()
T.eq("the timer writes once", calls, { "set Hot" })
T.eq("with the latest value", stored("Hot"), { n = 5 })
reset()
ShimFireTimers()
T.eq("nothing is left to write", calls, {})
p:defer(p.set, p, "Hot", { n = 6 })
T.eq("the next deferred set arms a new timer", timers, { 60000 })

T.section("a set outside defer writes at once and takes the pending change with it")
p = newPersist()
p:setWriteBehind("Hot", 60000)
p:defer(p.set, p, "Hot", { n = 1 })
p:set("Hot", { n = 2 })
T.eq("one write, at once", calls, { "set Hot" })
ShimFireTimers()
T.eq("the timer finds nothing pending", calls, { "set Hot" })

T.section("flush writes what is pending, once")
p = newPersist()
p:setWriteBehind("Hot", 60000)
p:setWriteBehind("Warm", 60000)
p:defer(function()
  p:set("Hot", { n = 1 })
  p:set("Warm", { n = 1 })
end)
p:flush("Hot")
T.eq("flush(key) writes that key only", calls, { "set Hot" })
p:flush()
T.eq("flush() writes the rest", calls, { "set Hot", "set Warm" })
p:flush()
ShimFireTimers()
T.eq("a second flush and the timer write nothing", #calls, 2)

p = newPersist()
p:setWriteBehind("Secret", 60000)
p:setWriteBehind("Hot", 60000)
p:defer(function()
  p:set("Secret", { n = 1 }, true)
  p:set("Hot", { n = 1 })
end)
p:flush()
T.eq("each keeps its encrypted flag", encryptedFlag, { Secret = true, Hot = false })

-- ── Delete and reset with a write pending ────────────────────────────────────

T.section("a delete is immediate and a pending write does not bring the key back")
p = newPersist()
p:setWriteBehind("Hot", 60000)
p:defer(function()
  p:set("Hot", { n = 1 })
  p:delete("Hot")
end)
T.eq("the delete went out inside defer", calls, { "delete Hot" })
ShimFireTimers()
p:flush()
T.eq("neither the timer nor flush writes it again", calls, { "delete Hot" })
T.eq("storage has no key", C4:PersistGetValue("Hot"), nil)

p = newPersist()
p:setWriteBehind("Hot", 60000)
p:setWriteBehind("Warm", 60000)
p:defer(function()
  p:set("Hot", { n = 1 })
  p:set("Warm", { n = 1 })
end)
p:reset({ "Hot", "Warm" })
ShimFireTimers()
T.eq("reset drops every pending write", calls, { "delete Hot", "delete Warm" })

-- ── The scope ────────────────────────────────────────────────────────────────

T.section("defer passes results through, nests, and closes on an error")
p = newPersist()
p:setWriteBehind("Hot", 60000)
local a, b = p:defer(function(x, y)
  return y, x
end, 1, 2)
T.eq("it returns what fn returns", { a, b }, { 2, 1 })
p:defer(function()
  p:defer(function() end)
  p:set("Hot", { n = 1 })
end)
T.eq("an inner scope ending does not end the outer one", calls, {})
T.raises("an error in fn is rethrown", function()
  p:defer(error, "boom")
end, "boom")
p:set("Hot", { n = 2 })
T.eq("and the scope is closed after it", calls, { "set Hot" })

-- ── lib/values.lua ───────────────────────────────────────────────────────────

T.section("values: an update waits unless it adds or removes a variable")
T.unload("^lib%.persist$", "^lib%.values$")
local persist = require("lib.persist")
local values = require("lib.values")
values:update("Setting", "a", "STRING")
values:update("Json", "{}")
values:setWriteBehind(60000)
reset()

persist:defer(function()
  values:update("Setting", "b", "STRING")
  values:update("Setting", "c", "STRING")
  values:update("Json", '{"x":1}')
  values:update("Json2", "{}")
end)
T.eq("updates and a new value with no variable wait", calls, {})
T.eq("the variable is current", Variables["Setting"], "c")

persist:defer(values.update, values, "Reading", "1", "NUMBER")
T.eq("a new variable is written at once", calls, { "set Values" })
T.eq("with the waiting updates in it", stored("Values").Setting.value, "c")

persist:defer(values.update, values, "Reading", "1")
T.eq("so is a variable becoming a plain value", #calls, 2)

persist:defer(values.update, values, "Setting", "d", "STRING")
values:update("Json", '{"x":2}')
T.eq("an update outside defer writes at once", #calls, 3)
T.eq("and carries the waiting update", stored("Values").Setting.value, "d")

persist:defer(values.update, values, "Setting", "e", "STRING")
values:flush()
T.eq("values:flush writes it", stored("Values").Setting.value, "e")

reset()
persist:defer(values.delete, values, "Json")
T.eq("deleting a value with no variable waits", calls, {})
persist:defer(values.delete, values, "Setting")
T.eq("deleting a variable is written at once", calls, { "set Values" })
persist:defer(values.update, values, "Setting", "f", "STRING")
T.eq("and so is bringing it back", #calls, 2)

C4.PersistSetValue, C4.PersistDeleteValue, C4.SetTimer = realSet, realDelete, realSetTimer

T.finish()
