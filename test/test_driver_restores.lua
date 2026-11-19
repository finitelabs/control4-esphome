-- Every driver restores each library it loads that keeps saved state, in the init that library names in its
-- RESTORE: lib.values and lib.bindings from OnDriverInit, lib.events from OnDriverLateInit. The template owns this
-- file.
--
-- For each drivers/*/driver.lua, test/driver_restores_probe.lua loads the driver in a fresh process, as its OSS
-- build compiles it, and runs OnDriverInit and OnDriverLateInit. Loading such a library is what owes its restore,
-- so a driver that loads none owes none.

local F = require("c4_fixtures")
local T = require("testlib")

local MARK = "@@restore "

--- The interpreter this run is under, as make test or run_test.sh started it.
--- @return string
local function interpreter()
  local i = 0
  while arg[i - 1] ~= nil do
    i = i - 1
  end
  return arg[i]
end

--- @param text string
--- @return string
local function quote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

--- What the probe saw of one driver.
--- @class RestoreProbe
--- @field load string|nil "ok", or why the driver did not load.
--- @field ran table<string, string> Each init the driver defines: "ok", or what it raised.
--- @field restores { name: string, method: string, phase: string, ran: string[] }[]
--- @field preloaded string[] Libraries with a restore that were loaded before the driver.

--- @param root string
--- @param folder string
--- @return RestoreProbe
local function probe(root, folder)
  local command = string.format(
    "cd %s && %s -e %s %s %s %s 2>&1",
    quote(root),
    quote(interpreter()),
    quote("require('c4_shim')"),
    quote(root .. "/test/driver_restores_probe.lua"),
    quote(root),
    quote(folder)
  )
  local pipe = assert(io.popen(command))
  --- @type RestoreProbe
  local seen = { ran = {}, restores = {}, preloaded = {} }
  local lines = {}
  for line in pipe:lines() do
    lines[#lines + 1] = line
    local fact = line:sub(1, #MARK) == MARK and line:sub(#MARK + 1) or nil
    if fact then
      local load = fact:match("^LOAD (.*)$")
      local init, outcome = fact:match("^RAN (%S+) (.*)$")
      local name, method, phase, ran = fact:match("^RESTORE (%S+) (%S+) (%S+) ?(%S*)$")
      local preloaded = fact:match("^PRELOADED (%S+)$")
      if load then
        seen.load = load
      elseif init then
        seen.ran[init] = outcome
      elseif name then
        local calls = {}
        for each in ran:gmatch("[^,]+") do
          calls[#calls + 1] = each
        end
        seen.restores[#seen.restores + 1] = { name = name, method = method, phase = phase, ran = calls }
      elseif preloaded then
        seen.preloaded[#seen.preloaded + 1] = preloaded
      end
    end
  end
  pipe:close()
  if not seen.load then
    seen.load = "the probe printed no result: " .. table.concat(lines, " | ")
  end
  return seen
end

local root = F.repoRoot()
local folders = {}
local pipe = assert(io.popen(string.format("cd %s && ls -d drivers/*/ 2>/dev/null", quote(root))))
for line in pipe:lines() do
  local folder = line:match("^drivers/([^/]+)/$")
  local file = folder and io.open(string.format("%s/drivers/%s/driver.lua", root, folder))
  if file then
    file:close()
    folders[#folders + 1] = folder
  end
end
pipe:close()
table.sort(folders)

if #folders == 0 then
  print("No drivers/*/driver.lua: nothing to prove.")
  T.finish()
  return
end

for _, folder in ipairs(folders) do
  T.section(folder .. ": restores each library it loads that keeps saved state, in the init that library names")
  local seen = probe(root, folder)
  T.check(folder .. ": driver.lua loads", seen.load == "ok", seen.load)
  T.eq(folder .. ": no library with a restore is loaded before the driver", seen.preloaded, {})
  if seen.load == "ok" then
    for _, restore in ipairs(seen.restores) do
      local inPhase = false
      for _, init in ipairs(restore.ran) do
        inPhase = inPhase or init == restore.phase
      end
      local detail
      if not inPhase then
        detail = #restore.ran == 0 and "never called" or ("called from " .. table.concat(restore.ran, ", "))
        local outcome = seen.ran[restore.phase]
        if outcome and outcome ~= "ok" then
          detail = detail .. ", and " .. restore.phase .. " raised: " .. outcome
        elseif not outcome then
          detail = detail .. ", and driver.lua defines no " .. restore.phase
        end
      end
      T.check(
        string.format("%s: loads %s, and calls its %s in %s", folder, restore.name, restore.method, restore.phase),
        inPhase,
        detail
      )
    end
    if #seen.restores == 0 then
      T.check(folder .. ": loads no library with a restore, so owes none", true)
    end
  end
end

T.finish()
