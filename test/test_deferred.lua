-- Tests for vendor/deferred.lua: resolve and reject, chaining, M.all(), M.first(), M.map()
-- and the extend option.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_deferred.lua

local T = require("testlib")

local M = require("deferred")

-- deferred.lua keeps its states private; these are its values.
local DeferredState = {
  PENDING = 0,
  RESOLVING = 1,
  REJECTING = 2,
  RESOLVED = 3,
  REJECTED = 4,
}

--- Runs self-tests to verify the functionality of the Deferred module.
--- @return boolean success True if all tests passed.
local function selftest()
  print("Running Deferred test vectors...")
  local passed = 0
  local failed = 0

  local function assert_eq(actual, expected, msg)
    if actual == expected then
      passed = passed + 1
      print("  PASS: " .. msg)
      return true
    else
      failed = failed + 1
      print("  FAIL: " .. msg .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
      return false
    end
  end

  local function assert_true(cond, msg)
    return assert_eq(cond, true, msg)
  end

  -- ==========================================
  -- BASIC RESOLVE/REJECT TESTS
  -- ==========================================

  -- Test: resolve with value
  do
    local d = M.new()
    local result = nil
    d:next(function(v)
      result = v
    end)
    d:resolve("hello")
    assert_eq(result, "hello", "resolve with value")
    assert_eq(d.state, DeferredState.RESOLVED, "state after resolve")
  end

  -- Test: reject with value
  do
    local d = M.new()
    local result = nil
    d:next(nil, function(v)
      result = v
    end)
    d:reject("error")
    assert_eq(result, "error", "reject with value")
    assert_eq(d.state, DeferredState.REJECTED, "state after reject")
  end

  -- Test: resolve only fires once
  do
    local d = M.new()
    local count = 0
    d:next(function()
      count = count + 1
    end)
    d:resolve("first")
    d:resolve("second")
    assert_eq(count, 1, "resolve only fires once")
  end

  -- ==========================================
  -- CHAINING TESTS
  -- ==========================================

  -- Test: next() returns transformed value
  do
    local d = M.new()
    local result = nil
    d:next(function(v)
      return v * 2
    end):next(function(v)
      result = v
    end)
    d:resolve(21)
    assert_eq(result, 42, "next() transforms value")
  end

  -- Test: next() with returned Deferred (flattening)
  do
    local d = M.new()
    local result = nil
    d:next(function(v)
      local inner = M.new()
      inner:resolve(v .. " world")
      return inner
    end):next(function(v)
      result = v
    end)
    d:resolve("hello")
    assert_eq(result, "hello world", "next() flattens returned Deferred")
  end

  -- Test: chaining after already resolved
  do
    local d = M.new()
    d:resolve("immediate")
    local result = nil
    d:next(function(v)
      result = v
    end)
    assert_eq(result, "immediate", "chaining after already resolved")
  end

  -- Test: error in callback rejects chain
  do
    local d = M.new()
    local errorResult = nil
    d:next(function()
      error("test error")
    end):next(nil, function(e)
      errorResult = e
    end)
    d:resolve("trigger")
    assert_true(errorResult ~= nil, "error in callback rejects chain")
  end

  -- Test: rejection recovery
  do
    local d = M.new()
    local result = nil
    d:next(nil, function()
      return "recovered"
    end):next(function(v)
      result = v
    end)
    d:reject("error")
    assert_eq(result, "recovered", "rejection can be recovered")
  end

  -- ==========================================
  -- M.all() TESTS
  -- ==========================================

  -- Test: all() with all resolved
  do
    local d1, d2, d3 = M.new(), M.new(), M.new()
    --- @type string[]?
    local results = nil
    M.all({ d1, d2, d3 }):next(function(v)
      results = v
    end)
    d1:resolve("a")
    d2:resolve("b")
    d3:resolve("c")
    assert_true(results ~= nil, "all() resolves when all resolve")
    --- @cast results -nil
    assert_eq(results[1], "a", "all() result[1]")
    assert_eq(results[2], "b", "all() result[2]")
    assert_eq(results[3], "c", "all() result[3]")
  end

  -- Test: all() with empty array
  do
    local results = nil
    M.all({}):next(function(v)
      results = v
    end)
    assert_true(results ~= nil, "all([]) resolves immediately")
    assert_eq(#results, 0, "all([]) resolves with empty array")
  end

  -- Test: all() with rejection
  do
    local d1, d2 = M.new(), M.new()
    local rejected = nil
    M.all({ d1, d2 }):next(nil, function(v)
      rejected = v
    end)
    d1:resolve("ok")
    d2:reject("fail")
    assert_true(rejected ~= nil, "all() rejects if any reject")
  end

  -- ==========================================
  -- M.first() TESTS
  -- ==========================================

  -- Test: first() resolves with first resolved
  do
    local d1, d2 = M.new(), M.new()
    local result = nil
    M.first({ d1, d2 }):next(function(v)
      result = v
    end)
    d2:resolve("second wins")
    assert_eq(result, "second wins", "first() resolves with first resolved")
  end

  -- ==========================================
  -- M.map() TESTS
  -- ==========================================

  -- Test: map() sequential processing
  do
    --- @type number[]?
    local results = nil
    M.map({ 1, 2, 3 }, function(v)
      local d = M.new()
      d:resolve(v * 10)
      return d
    end):next(function(v)
      results = v
    end)
    assert_true(results ~= nil, "map() resolves")
    --- @cast results -nil
    assert_eq(results[1], 10, "map() result[1]")
    assert_eq(results[2], 20, "map() result[2]")
    assert_eq(results[3], 30, "map() result[3]")
  end

  -- ==========================================
  -- EXTEND OPTION TESTS
  -- ==========================================

  -- Test: extend option is called
  do
    local extended = false
    M.new({
      extend = function()
        extended = true
      end,
    })
    assert_true(extended, "extend option is called")
  end

  -- Test: extend propagates to chained deferreds
  do
    local extendCount = 0
    local d = M.new({
      extend = function()
        extendCount = extendCount + 1
      end,
    })
    d:next(function()
      return "value"
    end)
    d:resolve("trigger")
    assert_true(extendCount >= 2, "extend propagates to chained deferreds")
  end

  -- ==========================================
  -- SUMMARY
  -- ==========================================
  print(string.format("\nDeferred operations: %d/%d tests passed\n", passed, passed + failed))
  return failed == 0
end

T.check("every deferred case passes", selftest())

T.finish()
