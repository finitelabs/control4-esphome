#!/usr/bin/env lua
--- Auto-generate squishy files for Control4 drivers.
---
--- Loads a driver's driver.lua using the C4 shim, inspects package.loaded to
--- discover all dependencies, and uses package.searchpath to map module names
--- back to file paths. This produces a squishy file containing only the modules
--- actually used by each driver, without hardcoding any path mappings.
---
--- Usage: Run from a driver directory in the build output:
---   cd build/drivercentral/drivers/<name>
---   lua ../../../../tools/gen-squishy.lua
---
--- Or pass the condition explicitly:
---   lua ../../../../tools/gen-squishy.lua --condition drivercentral

local condition = nil

-- Parse arguments
local i = 1
while i <= #arg do
  if arg[i] == "--condition" then
    i = i + 1
    condition = arg[i]
  end
  i = i + 1
end

-- Derive driver name from current directory
local cwd = io.popen("pwd"):read("*l")
local driver_name = cwd:match("([^/]+)/?$")

if not driver_name then
  io.stderr:write("Error: Could not determine driver name from current directory\n")
  os.exit(1)
end

-- Derive condition from path if not provided
if not condition then
  condition = cwd:match("/build/([%w%-]+)/drivers/")
  if not condition then
    io.stderr:write("Error: Could not determine build condition from path.\n")
    io.stderr:write("Either run from build/{condition}/drivers/{name}/ or pass --condition\n")
    os.exit(1)
  end
end

-- Set package.path to resolve modules from the build's src/ and vendor/ dirs.
-- Since we run from the driver directory, the relative paths match exactly what
-- squishy needs.
package.path = table.concat({
  "../../src/?.lua",
  "../../src/?/init.lua",
  "../../vendor/?.lua",
  "../../vendor/?/init.lua",
  "./?.lua",
  "./?/init.lua",
}, ";")

-- Load the C4 shim (stubs only, no luasocket needed)
dofile("../../../../test/c4_shim.lua")

-- Snapshot package.loaded before loading the driver
local pre_loaded = {}
for k in pairs(package.loaded) do
  pre_loaded[k] = true
end

-- Load the driver
dofile("driver.lua")

-- Call C4 lifecycle callbacks to trigger any lazy requires (e.g., cloud-client-byte
-- is required inside OnDriverInit in drivercentral builds)
if OnDriverInit then
  pcall(OnDriverInit)
end
if OnDriverLateInit then
  pcall(OnDriverLateInit)
end

-- Discover newly loaded modules and resolve their file paths using
-- package.searchpath, which applies the same dot-to-separator conversion
-- that require uses, so "some.module" finds "../../src/some/module.lua"
local modules = {}
for modname in pairs(package.loaded) do
  if not pre_loaded[modname] then
    local path = package.searchpath(modname, package.path)
    if path then
      table.insert(modules, { name = modname, path = path })
    end
  end
end

-- Sort by path for consistent, grouped output
table.sort(modules, function(a, b)
  return a.path < b.path
end)

-- Build squishy content
local lines = {}
table.insert(lines, 'Main "driver.lua"')
table.insert(lines, "")

local last_dir = nil
for _, mod in ipairs(modules) do
  -- Add blank line between different directory prefixes for readability
  local dir = mod.path:match("^(.+/)[^/]+$") or ""
  if last_dir and dir ~= last_dir then
    table.insert(lines, "")
  end
  last_dir = dir

  table.insert(lines, string.format('Module "%s" "%s"', mod.name, mod.path))
end

table.insert(lines, "")
table.insert(lines, string.format('Output "../../../../dist/%s/%s.lua"', condition, driver_name))
table.insert(lines, 'Option "minify" "true"')
table.insert(lines, 'Option "minify_level" "none"')
table.insert(lines, 'Option "minify_comments" "true"')
table.insert(lines, 'Option "minify_emptylines" "true"')
table.insert(lines, "")

-- Write squishy file
local f = io.open("squishy", "w")
f:write(table.concat(lines, "\n"))
f:close()

io.stderr:write(string.format("Generated squishy for %s (%s): %d modules\n", driver_name, condition, #modules))
