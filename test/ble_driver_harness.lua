-- Loads one BLE sub-driver (drivers/<name>/driver.lua) on the C4 shim and drives it
-- through the entry points Director calls, with its proxy traffic captured at
-- C4:SendToProxy and its timers fired by hand.
--
-- The driver's real driver.xml backs C4:GetDriverConfigInfo("config") and seeds
-- Properties, so a property the Lua writes that the XML does not declare, or a
-- value outside a declared range, shows up as an UpdateProperty error.
--
-- OnDriverInit is never called: its --#ifdef DRIVERCENTRAL arms are plain comments
-- in unpreprocessed source, so both would run and require "cloud-client-byte".
-- boot() leaves gInitialized as OnDriverInit would; nothing else under test needs it.

local T = require("testlib")

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local values = require("lib.values")

-- Resolved against this file rather than the working directory: run_test.sh cds
-- into test/, make test runs from the repo root, and dofile takes a path rather
-- than going through LUA_PATH.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

local H = {}

--- Everything sent since the last boot or H.clearSent().
H.sent = {}

local driverPath
local config = ""
local defaults = {}

local function readFile(path)
  local fh = assert(io.open(path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end

function C4:GetDriverConfigInfo(key)
  if key == "config" then
    return config
  end
  local info = { minimum_os_version = "3.3.0", model = "test", version = "test" }
  return info[key]
end

-- Director keeps Properties current; the shim's UpdateProperty is a no-op.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

-- The shim has neither; the drivers only use HEX (keys, and bytes in log lines).
function C4:Encode(data)
  return (data:gsub(".", function(c)
    return string.format("%02X", c:byte())
  end))
end

function C4:Decode(data)
  return (data:gsub("%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

C4.SendToProxy = function(_, idBinding, strCommand, tParams, strMessage)
  table.insert(H.sent, { binding = idBinding, command = strCommand, params = tParams or {}, message = strMessage })
end

-- Handler and property errors are printed, not raised; collect them so a test can
-- fail on them instead of on a missing side effect.
local errors = {}
local realPrint = print
print = function(...) -- luacheck: ignore
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring((select(i, ...)))
  end
  local line = table.concat(parts, " ")
  if line:find("error", 1, true) then
    table.insert(errors, line)
  end
  realPrint(line)
end

--- Point the harness at drivers/<name>.
--- @param name string The driver directory, e.g. "esphome_yale".
function H.use(name)
  driverPath = HERE .. "/../drivers/" .. name .. "/driver.lua"
  config = readFile(HERE .. "/../drivers/" .. name .. "/driver.xml"):match("<config>(.*)</config>")
  defaults = {}
  for block in config:gmatch("<property>(.-)</property>") do
    defaults[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
end

function H.clearSent()
  H.sent = {}
end

--- How many times `command` was sent, on `binding` if given.
function H.count(command, binding)
  local n = 0
  for _, s in ipairs(H.sent) do
    if s.command == command and (binding == nil or s.binding == binding) then
      n = n + 1
    end
  end
  return n
end

function H.armed(name)
  return Timer[name] ~= nil
end

--- Fire one named timer now, as the controller would when it fell due.
function H.fire(name)
  local handle = Timer[name]
  local fn = handle and TimerFunctions[handle]
  if not fn then
    return false
  end
  CancelTimer(name)
  fn(handle, 0)
  return true
end

local function clearTimers()
  local names = {}
  for name in pairs(Timer) do
    if type(name) == "string" then
      table.insert(names, name)
    end
  end
  for _, name in ipairs(names) do
    CancelTimer(name)
  end
end

function H.variable(name)
  return Select(values:getValue(name), "value")
end

function H.rfp(binding, command, params)
  ReceivedFromProxy(binding, command, params or {})
end

--- A 128-bit UUID string as the proxy's {high, low} uint64 pairs.
function H.uuidPairs(uuid)
  local h = uuid:gsub("-", "")
  local function word(i)
    return tonumber(h:sub(i, i + 7), 16)
  end
  return { { word(1), word(9) }, { word(17), word(25) } }
end

--- Load the driver as a controller boot does: no timers, variables gone,
--- Properties at their driver.xml defaults overlaid with `properties`.
--- @param properties table<string, string>|nil Properties to set before the load.
--- @param prepare fun()|nil Runs after the reset and before the load, to seed
--- what an earlier session would have left (persisted values, stored handles).
function H.boot(properties, prepare)
  clearTimers()
  for name in pairs(Properties) do
    Properties[name] = nil
  end
  for name, value in pairs(defaults) do
    Properties[name] = value
  end
  for name, value in pairs(properties or {}) do
    Properties[name] = value
  end
  values:reset()
  if prepare then
    prepare()
  end
  gInitialized = false
  dofile(driverPath)
  OnDriverLateInit()
  H.sent = {}
end

--- Name a group and run it, so a throw inside one case is one recorded failure
--- rather than the end of the run.
function H.test(name, fn)
  T.section(name)
  errors = {}
  local ok, err = pcall(fn)
  T.check("ran without throwing", ok, err)
  T.check("no handler or property errors", #errors == 0, table.concat(errors, "\n"))
end

return H
