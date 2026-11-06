--- Tests what StateTell tells a contact or relay binding. OPENED and CLOSED fire
--- the bound driver's programming, so they go out only for a change against the
--- state told before, which is kept across loads; anything else goes in the
--- silent STATE_ form, once per load.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_state_tell.lua

require("c4_shim")
require("lib.utils")
local T = require("testlib")

local persist = require("lib.persist")
local StateTell = require("esphome.state_tell")

local BINDING = 7001

--- Every message sent to a binding, as { binding, command }.
local told = {}
C4.SendToProxy = function(_, idBinding, strCommand)
  told[#told + 1] = { idBinding, strCommand }
end

--- The commands told since the last call.
local function sent()
  local got = {}
  for _, message in ipairs(told) do
    got[#got + 1] = message[2]
  end
  told = {}
  return got
end

T.section("A first load: nothing told before")
do
  persist:delete("TellFirst")
  local teller = StateTell:new("TellFirst")
  T.eq("not a change", teller:tell("door", BINDING, "CLOSED"), false)
  T.eq("the first state is told silently", sent(), { "STATE_CLOSED" })
  teller:tell("door", BINDING, "CLOSED")
  T.eq("the same state again (a reconnect's resend) tells nothing", sent(), {})
  T.eq("a change", teller:tell("door", BINDING, "OPENED"), true)
  T.eq("is told as one", sent(), { "OPENED" })
  teller:tell("door", BINDING, "OPENED")
  T.eq("and not again", sent(), {})
end

T.section("A restart: the state told before decides")
do
  persist:delete("TellRestart")
  StateTell:new("TellRestart"):tell("door", BINDING, "CLOSED")
  sent()

  local restarted = StateTell:new("TellRestart")
  T.eq("unchanged: not a change", restarted:tell("door", BINDING, "CLOSED"), false)
  T.eq("told silently, once", sent(), { "STATE_CLOSED" })

  local again = StateTell:new("TellRestart")
  T.eq("changed while the driver was down: a change", again:tell("door", BINDING, "OPENED"), true)
  T.eq("told as one", sent(), { "OPENED" })
end

T.section("Keys and tellers are kept apart")
do
  persist:delete("TellKeysA")
  persist:delete("TellKeysB")
  local a, b = StateTell:new("TellKeysA"), StateTell:new("TellKeysB")
  a:tell("one", BINDING, "CLOSED")
  a:tell("two", BINDING, "OPENED")
  b:tell("one", BINDING, "OPENED")
  sent()
  T.eq("each key keeps its own state", StateTell:new("TellKeysA"):tell("two", BINDING, "OPENED"), false)
  T.eq("each teller keeps its own states", StateTell:new("TellKeysB"):tell("one", BINDING, "OPENED"), false)
  sent()
end

T.section("With no binding, the state is kept and nothing is told")
do
  persist:delete("TellNoBinding")
  local teller = StateTell:new("TellNoBinding")
  T.eq("not a change the first time", teller:tell("home", nil, "CLOSED"), false)
  T.eq("a change after", teller:tell("home", nil, "OPENED"), true)
  T.eq("nothing told", sent(), {})
end

T.section("assume, forget, clear and reset")
do
  persist:delete("TellAssume")
  local teller = StateTell:new("TellAssume")
  teller:assume("room", "OPENED")
  T.eq("an assumed state makes the first different state a change", teller:tell("room", BINDING, "CLOSED"), true)
  T.eq("told as one", sent(), { "CLOSED" })

  teller:assume("room", "OPENED")
  T.eq("assume leaves a kept state alone", StateTell:new("TellAssume"):tell("room", BINDING, "CLOSED"), false)
  sent()

  teller:forget("room")
  T.eq("forget drops it, this load and before", teller:tell("room", BINDING, "OPENED"), false)
  T.eq("so the next state is told silently", sent(), { "STATE_OPENED" })

  teller:clear()
  teller:tell("room", BINDING, "OPENED")
  T.eq("clear tells the next state again, silently", sent(), { "STATE_OPENED" })

  teller:reset()
  T.eq("reset forgets every state", teller:tell("room", BINDING, "CLOSED"), false)
  T.eq("told silently", sent(), { "STATE_CLOSED" })
end

T.finish()
