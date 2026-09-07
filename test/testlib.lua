-- Generic test harness: assertions, grouping, and the pass/fail pipeline.
--
-- Plain Lua with no Control4 in it. A test that drives driver code also requires
-- c4_shim (the C4 environment mock) and, for the C4 seams, c4_fixtures.
--
-- Usage:
--   local T = require("testlib")
--   T.section("What is under test")
--   T.eq("name", got, want)
--   T.finish()

local T = {}

-- Held from load so output still reaches stdout inside T.capture, which swaps
-- the global print.
local emit = print

local passed, failed = 0, 0
local sections = 0

--- A value rendered for a failure message. Tables print sorted, one level of
--- nesting deep, so a mismatch names the differing field.
local function show(value, depth)
  depth = depth or 0
  if type(value) ~= "table" then
    if type(value) == "string" then
      return string.format("%q", value)
    end
    return tostring(value)
  end
  if depth >= 2 then
    return "{...}"
  end
  local parts = {}
  for k, v in pairs(value) do
    table.insert(parts, string.format("%s = %s", tostring(k), show(v, depth + 1)))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end
T.show = show

local function deepEqual(a, b, seen)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  seen = seen or {}
  seen[a] = seen[a] or {}
  if seen[a][b] then
    return true
  end
  seen[a][b] = true
  for k, v in pairs(a) do
    if not deepEqual(v, b[k], seen) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end
T.deepEqual = deepEqual

--- Record one result. Never throws and never aborts, so a run reports every
--- failure rather than only the first.
function T.check(name, ok, detail)
  if ok then
    passed = passed + 1
    emit(string.format("  ok   %s", name))
  else
    failed = failed + 1
    emit(string.format("  FAIL %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
  return ok and true or false
end

function T.section(name)
  sections = sections + 1
  emit(string.format("\n[%d] %s", sections, name))
end

function T.truthy(name, value, detail)
  return T.check(name, value ~= nil and value ~= false, detail ~= nil and detail or show(value))
end

function T.falsy(name, value, detail)
  return T.check(name, value == nil or value == false, detail ~= nil and detail or show(value))
end

function T.eq(name, got, want)
  return T.check(name, deepEqual(got, want), string.format("got %s, want %s", show(got), show(want)))
end

function T.neq(name, got, unwanted)
  return T.check(name, not deepEqual(got, unwanted), string.format("got %s, want anything else", show(got)))
end

function T.contains(name, haystack, needle)
  local text = tostring(haystack)
  return T.check(name, text:find(needle, 1, true) ~= nil, string.format("%s does not contain %q", show(text), needle))
end

function T.excludes(name, haystack, needle)
  local text = tostring(haystack)
  return T.check(name, text:find(needle, 1, true) == nil, string.format("%s contains %q", show(text), needle))
end

--- Assert fn() raises, and that the message contains `expected` when given.
function T.raises(name, fn, expected)
  local ok, err = pcall(fn)
  if ok then
    return T.check(name, false, "did not raise")
  end
  err = tostring(err)
  if expected and not err:find(expected, 1, true) then
    return T.check(name, false, "raised " .. err)
  end
  return T.check(name, true)
end

--- Assert fn() raises with the error attributed to the file calling this, not to
--- the file that raised. Catches a callee raising at the wrong stack level.
--- Call it directly from the test file: the expected filename is the immediate
--- caller's, so wrapping this in a helper asserts against the helper's file.
function T.raisesAt(name, fn)
  local caller = debug.getinfo(2, "S").short_src:match("([^/\\]+)$")
  local ok, err = pcall(fn)
  if ok then
    return T.check(name, false, "did not raise")
  end
  err = tostring(err)
  return T.check(name, err:find(caller .. ":", 1, true) ~= nil, "raised " .. err)
end

--- Run fn() with the global print collected instead of written.
--- Returns pcall's ok and error plus the collected output as one string.
function T.capture(fn)
  local lines = {}
  local restore = print
  print = function(...) -- luacheck: ignore
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    table.insert(lines, table.concat(parts, " "))
  end
  local ok, err = pcall(fn)
  print = restore -- luacheck: ignore
  return ok, err, table.concat(lines, "\n")
end

--- Drop every package.loaded entry matching any of the Lua patterns, so the next
--- require re-runs the module and rebuilds whatever state it caches.
function T.unload(...)
  local patterns = { ... }
  for name in pairs(package.loaded) do
    for _, pattern in ipairs(patterns) do
      if name:match(pattern) then
        package.loaded[name] = nil
        break
      end
    end
  end
end

function T.counts()
  return passed, failed
end

--- Print the summary and exit. Every test file ends with this.
function T.finish()
  emit(string.format("\n%d passed, %d failed", passed, failed))
  os.exit(failed == 0 and 0 or 1)
end

return T
