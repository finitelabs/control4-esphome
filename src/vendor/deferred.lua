--- A+ promises in Lua.
--- @module "vendor.deferred"
local M = {}

--- @class Deferred<S,F>
--- @generic S,F,V
--- @field next fun(self: Deferred<S,F>, success: (fun(value: S): V), failure: (fun(reason: F): V)?): Deferred<V,F>  A function for chaining promises, taking success and failure callbacks and returning a new Deferred object.
--- @field state number The current state of the promise (e.g., PENDING, RESOLVING, REJECTING, RESOLVED, REJECTED).
--- @field value S|F The resolved or rejected value of the promise.
--- @field queue table<number, Deferred<S>> A list of chained promises.
--- @field success fun(value: S)|nil The success callback function.
--- @field failure fun(reason: F)|nil The failure callback function.
local Deferred = {}
Deferred.__index = Deferred

--- Promise states
Deferred.PENDING = 0
Deferred.RESOLVING = 1
Deferred.REJECTING = 2
Deferred.RESOLVED = 3
Deferred.REJECTED = 4

--- Finalizes the promise by resolving or rejecting it.
--- @generic S,F
--- @param deferred Deferred<S,F> The deferred object.
--- @param state? number The final state of the promise (RESOLVED or REJECTED).
local function finish(deferred, state)
  state = state or Deferred.REJECTED
  for _, f in ipairs(deferred.queue) do
    if state == Deferred.RESOLVED then
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
--- @param next fun(self: Deferred<S,F>, success: (fun(value: S): V), failure: (fun(reason: F): V)?) The next function in the chain.
--- @param success function The success callback.
--- @param failure function The failure callback.
--- @param nonpromisecb function The callback for non-promise values.
local function promise(deferred, next, success, failure, nonpromisecb)
  if type(deferred) == "table" and type(deferred.value) == "table" and isfunction(next) then
    local called = false
    local ok, err = pcall(next, deferred.value, function(v)
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
  local next
  if type(deferred.value) == "table" then
    next = deferred.value.next
  end
  promise(deferred, next, function()
    deferred.state = Deferred.RESOLVING
    fire(deferred)
  end, function()
    deferred.state = Deferred.REJECTING
    fire(deferred)
  end, function()
    local ok, v
    if deferred.state == Deferred.RESOLVING and deferred.success ~= nil and isfunction(deferred.success) then
      --- @cast deferred.value S
      ok, v = pcall(deferred.success, deferred.value)
    elseif deferred.state == Deferred.REJECTING and deferred.failure ~= nil and isfunction(deferred.failure) then
      --- @cast deferred.value F
      ok, v = pcall(deferred.failure, deferred.value)
      if ok then
        deferred.state = Deferred.RESOLVING
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
      promise(deferred, next, function()
        finish(deferred, Deferred.RESOLVED)
      end, function(state)
        finish(deferred, state)
      end, function()
        finish(deferred, deferred.state == Deferred.RESOLVING and Deferred.RESOLVED or Deferred.REJECTED)
      end)
    end
  end)
end

--- Resolves or rejects the promise.
--- @generic S,F
--- @param deferred Deferred<S,F> The deferred object.
--- @param state number The state to resolve or reject to.
--- @param value S|F The value to resolve or reject with.
--- @return Deferred<S,F> deferred The deferred object.
local function resolve(deferred, state, value)
  if deferred.state == Deferred.PENDING then
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
  return resolve(self, Deferred.RESOLVING, value)
end

--- Rejects the promise with a value.
--- @generic S,F
--- @param value F The value to reject with.
--- @return Deferred<S,F> deferred The deferred object.
function Deferred:reject(value)
  return resolve(self, Deferred.REJECTING, value)
end

--- Creates a new deferred object.
--- @generic S,F
--- @param options? table Optional configuration for the deferred object.
--- @return Deferred<S,F> deferred A new deferred object.
function M.new(options)
  options = options or {}
  local d
  d = {
    next = function(_, success, failure)
      local next = M.new({ success = success, failure = failure, extend = options.extend })
      if d.state == Deferred.RESOLVED then
        next:resolve(d.value)
      elseif d.state == Deferred.REJECTED then
        next:reject(d.value)
      else
        table.insert(d.queue, next)
      end
      return next
    end,
    state = Deferred.PENDING,
    value = nil,
    queue = {},
    success = options.success,
    failure = options.failure,
  }
  d = setmetatable(d, Deferred)
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
--- @param args table<number, Deferred<S,F>> A list of promises.
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
