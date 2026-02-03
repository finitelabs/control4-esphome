--- A+ promises in Lua.
--- @module "deferred"
local M = {}

--- @generic S,F
--- @class Deferred<S,F>
--- @field state DeferredState The current state of the promise
--- @field value S|F The resolved or rejected value
--- @field queue Deferred<S,F>[] A list of chained promises
--- @field success (fun(value: S))? The success callback function
--- @field failure (fun(reason: F))? The failure callback function
--- @field extend (fun(d: Deferred<S,F>))? Optional extension function
local Deferred = {}
Deferred.__index = Deferred

--- Deferred states
--- @enum DeferredState
local DeferredState = {
  PENDING = 0,
  RESOLVING = 1,
  REJECTING = 2,
  RESOLVED = 3,
  REJECTED = 4,
}

--- Chains a callback to be executed when the promise resolves.
--- When the callback returns a Deferred, the result is flattened.
--- @generic S, F, V
--- @param success (fun(value: S): Deferred<V,F>)? Callback that returns a Deferred
--- @param failure (fun(reason: F): Deferred<V,F>)?
--- @return Deferred<V,F>
--- @overload fun(self: Deferred<S,F>, success: (fun(value: S): V)?, failure: (fun(reason: F): V)?): Deferred<V,F>
function Deferred:next(success, failure)
  local nextFn = M.new({ success = success, failure = failure, extend = self.extend })
  if self.state == DeferredState.RESOLVED then
    nextFn:resolve(self.value)
  elseif self.state == DeferredState.REJECTED then
    nextFn:reject(self.value)
  else
    table.insert(self.queue, nextFn)
  end
  return nextFn
end

--- Finalizes the promise by resolving or rejecting it.
--- @generic S,F
--- @param deferred Deferred<S,F> The deferred object.
--- @param state? DeferredState The final state of the promise (RESOLVED or REJECTED).
local function finish(deferred, state)
  if state == nil then
    state = DeferredState.REJECTED
  end
  for _, f in ipairs(deferred.queue) do
    if state == DeferredState.RESOLVED then
      --- @cast deferred.value S
      f:resolve(deferred.value)
    else
      --- @cast deferred.value F
      f:reject(deferred.value)
    end
  end
  deferred.state = state
end

--- Checks if a value is a callable function or table with a `__call` metamethod.
--- @param f any The value to check.
--- @return boolean isFunction True if the value is callable, false otherwise.
local function isfunction(f)
  if type(f) == "table" then
    local mt = getmetatable(f)
    return mt ~= nil and type(mt.__call) == "function"
  end
  return type(f) == "function"
end

--- Handles promise chaining and resolution.
--- @generic S,V,F
--- @param deferred Deferred<S,F> The deferred object.
--- @param nextFn fun(self: Deferred<S,F>, success: (fun(value: S): V?)?, failure: (fun(reason: F): V?)?)? The next function in the chain.
--- @param success function The success callback.
--- @param failure function The failure callback.
--- @param nonpromisecb function The callback for non-promise values.
local function promise(deferred, nextFn, success, failure, nonpromisecb)
  if type(deferred) == "table" and type(deferred.value) == "table" and isfunction(nextFn) then
    --- @cast nextFn -nil
    --- @cast deferred.value Deferred<S,F>
    local called = false
    local ok, err = pcall(nextFn, deferred.value, function(v)
      if called then
        return
      end
      called = true
      deferred.value = v
      success()
    end, function(v)
      if called then
        return
      end
      called = true
      deferred.value = v
      failure()
    end)
    if not ok and not called then
      deferred.value = err
      failure()
    end
  else
    nonpromisecb()
  end
end

--- Fires the promise resolution or rejection process.
--- @generic S,F
--- @param deferred Deferred<S,F> The deferred object.
local function fire(deferred)
  local nextFn
  if type(deferred.value) == "table" then
    nextFn = deferred.value.next
  end
  promise(deferred, nextFn, function()
    deferred.state = DeferredState.RESOLVING
    fire(deferred)
  end, function()
    deferred.state = DeferredState.REJECTING
    fire(deferred)
  end, function()
    local ok, v
    if deferred.state == DeferredState.RESOLVING and deferred.success ~= nil and isfunction(deferred.success) then
      --- @cast deferred.value S
      ok, v = pcall(deferred.success, deferred.value)
    elseif deferred.state == DeferredState.REJECTING and deferred.failure ~= nil and isfunction(deferred.failure) then
      --- @cast deferred.value F
      ok, v = pcall(deferred.failure, deferred.value)
      if ok then
        deferred.state = DeferredState.RESOLVING
      end
    end

    if ok ~= nil then
      if ok then
        deferred.value = v
      else
        deferred.value = v
        return finish(deferred)
      end
    end

    if deferred.value == deferred then
      deferred.value = pcall(error, "resolving promise with itself")
      return finish(deferred)
    else
      promise(deferred, nextFn, function()
        finish(deferred, DeferredState.RESOLVED)
      end, function(state)
        finish(deferred, state)
      end, function()
        finish(deferred, deferred.state == DeferredState.RESOLVING and DeferredState.RESOLVED or DeferredState.REJECTED)
      end)
    end
  end)
end

--- Resolves or rejects the promise.
--- @generic S,F
--- @param deferred Deferred<S,F> The deferred object.
--- @param state DeferredState The state to resolve or reject to.
--- @param value S|F The value to resolve or reject with.
--- @return Deferred<S,F> deferred The deferred object.
local function resolve(deferred, state, value)
  if deferred.state == DeferredState.PENDING then
    deferred.value = value
    deferred.state = state
    fire(deferred)
  end
  return deferred
end

--- Resolves the promise with a value.
--- @generic S,F
--- @param value S The value to resolve with.
--- @return Deferred<S,F> deferred The deferred object.
function Deferred:resolve(value)
  return resolve(self, DeferredState.RESOLVING, value)
end

--- Rejects the promise with a value.
--- @generic S,F
--- @param value F The value to reject with.
--- @return Deferred<S,F> deferred The deferred object.
function Deferred:reject(value)
  return resolve(self, DeferredState.REJECTING, value)
end

--- Creates a new deferred object.
--- @generic S,F
--- @param options? table Optional configuration for the deferred object.
--- @return Deferred<S,F> deferred A new deferred object.
function M.new(options)
  options = options or {}
  --- @type Deferred<S,F>
  local d = setmetatable({}, Deferred)
  d.state = DeferredState.PENDING
  d.value = nil
  d.queue = {}
  d.success = options.success
  d.failure = options.failure
  d.extend = options.extend  -- Store for chained deferreds

  if isfunction(options.extend) then
    options.extend(d)
  end
  return d
end

--- Resolves when all promises in the list are resolved or rejected.
--- @generic S,F
--- @param args Deferred<S,F>[] A list of promises.
--- @return Deferred<S[], table<number, F>> deferred A new promise.
function M.all(args)
  --- @type Deferred<S|F[], S|F[]>>
  local d = M.new()
  if #args == 0 then
    return d:resolve({})
  end
  local pending = #args

  local hasRejections = false
  --- @type table<number, S>
  local resolves = {}
  --- @type table<number, F>
  local rejects = {}

  --- @param i integer
  --- @param resolved boolean
  --- @return fun(value: S|F): void
  local function synchronizer(i, resolved)
    return function(value)
      if not resolved then
        hasRejections = true
        rejects[i] = value
      else
        resolves[i] = value
      end
      pending = pending - 1
      if pending == 0 then
        --- @diagnostic disable-next-line: unnecessary-if
        if hasRejections then
          d:reject(rejects)
        else
          d:resolve(resolves)
        end
      end
    end
  end

  for i = 1, pending do
    assert(args[i]):next(synchronizer(i, true), synchronizer(i, false))
  end
  return d
end

--- Resolves with the values of sequential application of a function to each element in the list.
--- @generic S,F
--- @param args table A list of values.
--- @param fn function A function that returns a promise for each value.
--- @return Deferred<S,F> deferred A new promise.
function M.map(args, fn)
  local d = M.new()
  local results = {}
  local function donext(i)
    if i > #args then
      d:resolve(results)
    else
      fn(args[i]):next(function(res)
        table.insert(results, res)
        donext(i + 1)
      end, function(err)
        d:reject(err)
      end)
    end
  end
  donext(1)
  return d
end

--- Resolves as soon as the first promise in the list is resolved or rejected.
--- @generic S,F
--- @param args Deferred<S,F>[] A list of promises.
--- @return Deferred<S,F> deferred A new promise.
function M.first(args)
  --- @type Deferred<S,F>
  local d = M.new()
  for _, v in ipairs(args) do
    v:next(function(res)
      d:resolve(res)
    end, function(err)
      d:reject(err)
    end)
  end
  return d
end

--- Runs self-tests to verify the functionality of the Deferred module.
--- @return boolean success True if all tests passed.
function M.selftest()
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
    d:next(function(v) result = v end)
    d:resolve("hello")
    assert_eq(result, "hello", "resolve with value")
    assert_eq(d.state, DeferredState.RESOLVED, "state after resolve")
  end

  -- Test: reject with value
  do
    local d = M.new()
    local result = nil
    d:next(nil, function(v) result = v end)
    d:reject("error")
    assert_eq(result, "error", "reject with value")
    assert_eq(d.state, DeferredState.REJECTED, "state after reject")
  end

  -- Test: resolve only fires once
  do
    local d = M.new()
    local count = 0
    d:next(function() count = count + 1 end)
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
    d:next(function(v) return v * 2 end)
      :next(function(v) result = v end)
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
    d:next(function(v) result = v end)
    assert_eq(result, "immediate", "chaining after already resolved")
  end

  -- Test: error in callback rejects chain
  do
    local d = M.new()
    local errorResult = nil
    d:next(function() error("test error") end)
      :next(nil, function(e) errorResult = e end)
    d:resolve("trigger")
    assert_true(errorResult ~= nil, "error in callback rejects chain")
  end

  -- Test: rejection recovery
  do
    local d = M.new()
    local result = nil
    d:next(nil, function() return "recovered" end)
      :next(function(v) result = v end)
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
    M.all({ d1, d2, d3 }):next(function(v) results = v end)
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
    M.all({}):next(function(v) results = v end)
    assert_true(results ~= nil, "all([]) resolves immediately")
    assert_eq(#results, 0, "all([]) resolves with empty array")
  end

  -- Test: all() with rejection
  do
    local d1, d2 = M.new(), M.new()
    local rejected = nil
    M.all({ d1, d2 }):next(nil, function(v) rejected = v end)
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
    M.first({ d1, d2 }):next(function(v) result = v end)
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
    end):next(function(v) results = v end)
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
    M.new({ extend = function() extended = true end })
    assert_true(extended, "extend option is called")
  end

  -- Test: extend propagates to chained deferreds
  do
    local extendCount = 0
    local d = M.new({ extend = function() extendCount = extendCount + 1 end })
    d:next(function() return "value" end)
    d:resolve("trigger")
    assert_true(extendCount >= 2, "extend propagates to chained deferreds")
  end

  -- ==========================================
  -- SUMMARY
  -- ==========================================
  print(string.format("\nDeferred operations: %d/%d tests passed\n", passed, passed + failed))
  return failed == 0
end

return M
