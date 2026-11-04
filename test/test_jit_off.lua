-- Tests that loading lib.utils turns LuaJIT's compiler off for the driver's Lua VM, so no
-- hot loop waits on a compiler that can't place its machine code.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_jit_off.lua

local T = require("testlib")

jit.on()
T.unload("^lib%.utils$")
require("lib.utils")
T.falsy("loading lib.utils turns the JIT compiler off", (jit.status()))

T.finish()
