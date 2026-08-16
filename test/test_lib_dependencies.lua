-- Tests that src/lib modules pull in the modules defining the globals they call,
-- rather than relying on a driver's driver.lua to have required them first.
--
-- Run from the driver root:
--   make test
-- or:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/src/?/init.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_lib_dependencies.lua
--
-- tools/gen-squishy.lua bundles from package.loaded, so a module nothing
-- requires is absent from the .c4z and fails as a nil-call in the field.
--
-- The required set is derived from the sources rather than listed here, because a
-- listed one would go stale the first time a module gained a call. A module can
-- also reach a global transitively through a sibling it requires, so the runtime
-- check alone passes on a missing declaration; the source check is what holds each
-- module to declaring what it uses itself.

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local function dirOf(module)
  local path = package.searchpath(module, package.path)
  return path and path:match("^(.*)[/\\][^/\\]+$")
end

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function ls(dir)
  local names = {}
  local pipe = io.popen(string.format("ls %q 2>/dev/null", dir))
  if not pipe then
    return names
  end
  for name in pipe:lines() do
    table.insert(names, name)
  end
  pipe:close()
  return names
end

--- Lua has no comment-aware lexer here; dropping to end of line over a source with
--- no inline `--` inside strings is enough to keep doc comments from reading as calls.
local function stripComments(src)
  local out = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(out, (line:gsub("%-%-.*$", "")))
  end
  return table.concat(out, "\n")
end

local function definedIn(src)
  local names = {}
  for name in src:gmatch("function%s+([%a_][%w_]*)%s*%(") do
    names[name] = true
  end
  return names
end

local libDir = dirOf("lib.logging")
local dcpDir = dirOf("drivers-common-public.global.lib")

check("src/lib is on package.path", libDir ~= nil, "cannot locate lib.logging")
check("drivers-common-public is on package.path", dcpDir ~= nil, "cannot locate the global modules")

if libDir and dcpDir then
  -- global name -> the drivers-common-public module that defines it
  local owner = {}
  for _, name in ipairs(ls(dcpDir)) do
    local mod = name:match("^(.+)%.lua$")
    local body = mod and readFile(dcpDir .. "/" .. name)
    if body then
      -- Leading %s* so indented defs (e.g. globals inside a `do` block) are seen,
      -- not just column-0 ones. `local function` stays excluded: `local` breaks it.
      for fn in stripComments(body):gmatch("\n%s*function%s+([%a_][%w_]*)%s*%(") do
        owner[fn] = "drivers-common-public.global." .. mod
      end
    end
  end
  check("the global modules define globals to check for", next(owner) ~= nil)

  -- src/lib modules define globals too (utils.lua's IsEmpty, InRange, ...) that
  -- siblings call. Map those the same way, so an intra-lib missing require is
  -- caught as well -- the DRV-97 class one level in. A module defining a global
  -- is excluded from needing it below via `own`, so self-references don't flag.
  for _, name in ipairs(ls(libDir)) do
    local mod = name:match("^(.+)%.lua$")
    local body = mod and readFile(libDir .. "/" .. name)
    if body then
      for fn in stripComments(body):gmatch("\n%s*function%s+([%a_][%w_]*)%s*%(") do
        owner[fn] = "lib." .. mod
      end
    end
  end

  for _, name in ipairs(ls(libDir)) do
    local mod = name:match("^(.+)%.lua$")
    local raw = mod and readFile(libDir .. "/" .. name)
    if raw then
      local src = stripComments(raw)
      local own = definedIn(src)

      -- drivers-common-public modules this file needs, by the globals it calls
      local needed, order = {}, {}
      for fn in src:gmatch("[^%w_.:]([%a_][%w_]*)%s*%(") do
        if owner[fn] and not own[fn] and not needed[owner[fn]] then
          needed[owner[fn]] = fn
          table.insert(order, owner[fn])
        end
      end
      table.sort(order)

      for _, dep in ipairs(order) do
        check(
          string.format("src/lib/%s declares require(%q)", name, dep),
          raw:find(string.format('require("%s")', dep), 1, true) ~= nil,
          string.format("calls %s but never requires the module defining it", needed[dep])
        )
      end

      if #order > 0 then
        -- Stand in for a driver.lua that required nothing: drop every module this
        -- one could reach so the require under test has to supply the globals.
        for loaded in pairs(package.loaded) do
          if loaded:match("^lib%.") or loaded:match("^drivers%-common%-public%.") then
            package.loaded[loaded] = nil
          end
        end
        for fn in pairs(needed) do
          _G[fn] = nil
        end
        for _, dep in ipairs(order) do
          _G[needed[dep]] = nil
        end

        local ok, err = pcall(require, "lib." .. mod)
        check(string.format("src/lib/%s requires cleanly with no driver.lua setup", name), ok, err)

        if ok then
          for _, dep in ipairs(order) do
            local fn = needed[dep]
            check(
              string.format("src/lib/%s: %s is callable after the require", name, fn),
              type(_G[fn]) == "function",
              string.format("%s is %s; the call site would fail with a nil-call", fn, type(_G[fn]))
            )
          end
        end
      end
    end
  end
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
