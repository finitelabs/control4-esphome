--- A+ promises in Lua.
--- @module "deferred"
local M = {}

--- Global hook called when a promise is rejected with no downstream handlers.
--- Set this to a function(value) to capture unhandled rejections externally.
--- @type fun(value: any)|nil
ON_UNHANDLED_REJECTION = ON_UNHANDLED_REJECTION

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
  if
    state == DeferredState.REJECTED
    and #deferred.queue == 0
    and ON_UNHANDLED_REJECTION
    and (deferred.success ~= nil or deferred.failure ~= nil)
  then
    ON_UNHANDLED_REJECTION(deferred.value)
  end
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
  d.extend = options.extend -- Store for chained deferreds

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

return M
