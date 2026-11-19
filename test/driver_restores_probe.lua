--- One driver's restores, for test/test_driver_restores.lua, which runs this in a fresh process per driver so no
--- other driver's load hides what this one's code loads. arg[1] is the repo root and arg[2] the driver folder.
---
--- Loads drivers/<folder>/driver.lua as its OSS build compiles it, notes each library its code loads that declares
--- a LibraryRestore, runs OnDriverInit and then OnDriverLateInit, and prints what it saw, one fact per line.

local F = require("c4_fixtures")

--- Every line the test reads starts with this.
local MARK = "@@restore "

local root, folder = arg[1], arg[2]
local dir = root .. "/drivers/" .. folder
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

--- @param text any
--- @return string
local function oneLine(text)
  return (tostring(text):gsub("%s*\n.*", ""))
end

--- @param value any
--- @return LibraryRestore|nil
local function restoreOf(value)
  if type(value) ~= "table" then
    return nil
  end
  return type(value.RESTORE) == "table" and value.RESTORE or nil
end

local file = io.open(dir .. "/driver.xml", "rb")
local xml = file and file:read("*a") or ""
if file then
  file:close()
end
F.seedProperties(xml)
F.answerConfig(xml)

for name, module in pairs(package.loaded) do
  if restoreOf(module) then
    print(MARK .. "PRELOADED " .. name)
  end
end

--- A library the driver's code loaded that declares a restore, and the init each call of that restore came in.
--- @class RestoreSeen
--- @field name string
--- @field restore LibraryRestore
--- @field ran string[]

--- @type RestoreSeen[]
local seen = {}
local phase = "the chunk"

local loadModule = require
require = function(name, ...)
  local fresh = package.loaded[name] == nil
  local module, extra = loadModule(name, ...)
  local restore = fresh and restoreOf(module) or nil
  if restore then
    --- @type RestoreSeen
    local entry = { name = name, restore = restore, ran = {} }
    seen[#seen + 1] = entry
    local method = module[restore.method]
    module[restore.method] = function(self, ...)
      entry.ran[#entry.ran + 1] = phase
      return method(self, ...)
    end
  end
  return module, extra
end

local loaded, loadErr = pcall(F.dofileBuild, dir .. "/driver.lua", "oss")
print(MARK .. "LOAD " .. (loaded and "ok" or oneLine(loadErr)))
if loaded then
  phase = "OnDriverInit"
  if type(OnDriverInit) == "function" then
    local ok, err = pcall(OnDriverInit)
    print(MARK .. "RAN OnDriverInit " .. (ok and "ok" or oneLine(err)))
  end
  phase = "OnDriverLateInit"
  if type(OnDriverLateInit) == "function" then
    local ok, err = pcall(ShimLateInit)
    print(MARK .. "RAN OnDriverLateInit " .. (ok and "ok" or oneLine(err)))
  end
end
for _, entry in ipairs(seen) do
  print(
    string.format(
      "%sRESTORE %s %s %s %s",
      MARK,
      entry.name,
      entry.restore.method,
      entry.restore.phase,
      table.concat(entry.ran, ",")
    )
  )
end
