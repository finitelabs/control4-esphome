-- Tests for test/c4_shim.lua itself.
--
-- Every place the shim diverges from a controller is a place a test can go
-- green on a call that fails, or does nothing, on hardware. Two are pinned
-- here: C4:SetTimer must return userdata, or global/timer.lua CancelTimer
-- silently no-ops; and the C4 variable API must exist and behave the way
-- Director does, or lib/values.lua is unusable in a test. Expectations were
-- measured on a dev controller, not inferred from the shim.
--
-- Run from the template root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_c4_shim.lua

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

local function section(name)
  print("\n[" .. name .. "]")
end

--- Assert that fn() raises, and that the message ends with `expected`. The
--- controller's messages arrive unprefixed; Lua prepends "file:line:".
local function raises(fn, expected)
  local ok, err = pcall(fn)
  if ok then
    return false, "did not raise"
  end
  err = tostring(err)
  if expected and not err:find(expected, 1, true) then
    return false, "raised " .. err
  end
  return true
end

--- Assert that fn() raises, and that the message points at the line that called
--- the shim rather than at a line inside it.
local function raises_at_caller(fn)
  local ok, err = pcall(fn)
  if ok then
    return false, "did not raise"
  end
  err = tostring(err)
  if not err:find("test_c4_shim.lua:", 1, true) then
    return false, "raised " .. err
  end
  return true
end

local function clearVariables()
  for name in pairs(Variables) do
    C4:DeleteVariable(name)
  end
end

--- The variable of the given name as C4:GetDeviceVariables reports it, plus its
--- id. Director keys by id rather than by name, so a name lookup is a scan.
local function variableByName(name)
  for id, variable in pairs(C4:GetDeviceVariables(C4:GetDeviceID())) do
    if variable.name == name then
      return variable, id
    end
  end
end

--- One field of a variable, or nil if the name is absent. Indexing the record
--- directly turns a missing variable into an error that ends the run, and a run
--- that ended early is hard to tell from one that passed.
local function variableField(name, field)
  local variable = variableByName(name)
  return variable and variable[field]
end

--------------------------------------------------------------------------------
section("C4:AddVariable")
--------------------------------------------------------------------------------

clearVariables()

check("returns true when it creates the variable", C4:AddVariable("Temp", "21.5", "NUMBER", true, false) == true)
check("populates Variables synchronously", Variables["Temp"] == "21.5")
check("stores the value as a string", type(Variables["Temp"]) == "string")

-- Nothing has been added before this point, so this is the first id the shim
-- hands out. Director starts a device's own variables at 1001.
local tempId = select(2, variableByName("Temp"))
check("numbers the first variable 1001", tempId == "1001", tempId)
check("keys by id as a string", type(tempId) == "string")
check(
  "records readOnly as a capitalised string",
  variableField("Temp", "readonly") == "True",
  variableField("Temp", "readonly")
)
check(
  "records the varType as a numeric code in a string",
  variableField("Temp", "type") == "2",
  variableField("Temp", "type")
)
check("reports the value", variableField("Temp", "value") == "21.5")
check("reports an empty description", variableField("Temp", "description") == "")

check("returns false when the name already exists", C4:AddVariable("Temp", "99", "NUMBER", true, false) == false)
check("a repeat add leaves the value alone", Variables["Temp"] == "21.5")
check("a repeat add leaves the type alone", variableField("Temp", "type") == "2")
check("a repeat add does not consume an id", select(2, variableByName("Temp")) == "1001")

C4:AddVariable("Count", 7, "INT", true, false)
check("accepts a number and stores tostring of it", Variables["Count"] == "7")

C4:AddVariable("Hidden", "x", "STRING", true, true)
check("records hidden as a capitalised string", variableField("Hidden", "hidden") == "True")
check("a hidden variable still appears in Variables", Variables["Hidden"] == "x")
-- Director returns hidden variables rather than omitting them, so a caller that
-- wants them gone has to read this field and skip on it.
check("a hidden variable is still returned by GetDeviceVariables", variableByName("Hidden") ~= nil)

C4:AddVariable("Defaults", "x", "STRING")
check("readOnly defaults to False", variableField("Defaults", "readonly") == "False")
check("hidden defaults to False", variableField("Defaults", "hidden") == "False")

C4:AddVariable(98765, "x", "STRING", true, false)
check("coerces a non-string name", Variables["98765"] == "x")

-- lib/values.lua reads "0"/"1" back from a BOOL because it wrote "0"/"1", not
-- because Director coerces.
C4:AddVariable("Raw", "true", "BOOL", true, false)
check("does not normalise a BOOL value", Variables["Raw"] == "true")

check(
  "raises on a boolean value",
  raises(function()
    C4:AddVariable("Bad", true, "BOOL", true, false)
  end, "strValue should be a string")
)
check(
  "raises on a nil value",
  raises(function()
    C4:AddVariable("Bad", nil, "STRING", true, false)
  end, "strValue should be a string")
)
check("a rejected add creates nothing", Variables["Bad"] == nil)

check(
  "raises on a nil varType",
  raises(function()
    C4:AddVariable("Bad", "x", nil, true, false)
  end, "strVarType should be a string")
)
check(
  "raises on an unknown varType",
  raises(function()
    C4:AddVariable("Bad", "x", "DYNAMIC", true, false)
  end, "Invalid variable type.")
)

-- Each case above breaks one rule, which leaves the order between them free.
check(
  "the value is checked before an unknown varType",
  raises(function()
    C4:AddVariable("Bad", true, "DYNAMIC", true, false)
  end, "strValue should be a string")
)
check(
  "the value is checked before a nil varType",
  raises(function()
    C4:AddVariable("Bad", true, nil, true, false)
  end, "strValue should be a string")
)
local repeatOk, repeatRet = pcall(function()
  return C4:AddVariable("Temp", "x", "DYNAMIC", true, false)
end)
check("an existing name returns false without validating varType", repeatOk and repeatRet == false, repeatRet)
check(
  "an existing name still checks the value",
  raises(function()
    C4:AddVariable("Temp", true, "NUMBER", true, false)
  end, "strValue should be a string")
)
check(
  "an existing name still checks that varType is a string",
  raises(function()
    C4:AddVariable("Temp", "x", nil, true, false)
  end, "strVarType should be a string")
)
check("a rejected repeat add leaves the value alone", Variables["Temp"] == "21.5")

check(
  "a rejected add blames the caller, not the shim",
  raises_at_caller(function()
    C4:AddVariable("Bad", true, "STRING", true, false)
  end)
)

-- The controller's error message names four types but accepts all of these. The
-- code each reports was measured by adding one variable per varType on a dev
-- controller and dumping C4:GetDeviceVariables. Two results worth stating: the
-- mapping is not 1:1, and no varType produced 7.
for _, case in ipairs({
  { "STRING", "1" },
  { "INT", "2" },
  { "NUMBER", "2" },
  { "FLOAT", "3" },
  { "BOOL", "4" },
  { "LEVEL", "5" },
  { "STATE", "6" },
  { "TIME", "8" },
  { "ROOM", "9" },
  { "MEDIA", "10" },
  { "LIST", "11" },
  { "ULONG", "12" },
  { "XML", "13" },
  { "DEVICE", "14" },
}) do
  local varType, code = case[1], case[2]
  local ok = pcall(function()
    C4:AddVariable("Type_" .. varType, "1", varType, true, false)
  end)
  check("accepts varType " .. varType, ok and Variables["Type_" .. varType] == "1")
  local variable = variableByName("Type_" .. varType)
  check(
    "reports varType " .. varType .. " as type " .. code,
    variable and variable.type == code,
    variable and variable.type
  )
end

check(
  "NUMBER and INT collapse onto one code",
  variableField("Type_NUMBER", "type") == variableField("Type_INT", "type")
)

--------------------------------------------------------------------------------
section("C4:SetVariable")
--------------------------------------------------------------------------------

clearVariables()
C4:AddVariable("Temp", "21.5", "NUMBER", true, false)

C4:SetVariable("Temp", "22.0")
check("updates Variables synchronously", Variables["Temp"] == "22.0")
check("the new value is visible through GetDeviceVariables", variableField("Temp", "value") == "22.0")

C4:SetVariable("Temp", 5)
check("accepts a number and stores tostring of it", Variables["Temp"] == "5")

-- readOnly describes what C4 programming may do, not what the driver may do.
C4:AddVariable("Locked", "0", "BOOL", true, false)
C4:SetVariable("Locked", "1")
check("writes through to a readOnly variable", Variables["Locked"] == "1")

C4:SetVariable("Locked", "false")
check("does not normalise a BOOL value", Variables["Locked"] == "false")

check(
  "raises on a boolean value",
  raises(function()
    C4:SetVariable("Temp", true)
  end, "strValue should be a string")
)
check(
  "raises on a nil value",
  raises(function()
    C4:SetVariable("Temp", nil)
  end, "strValue should be a string")
)
check("a rejected set leaves the value alone", Variables["Temp"] == "5")

-- Silent, and specifically not a create: lib/values.lua relies on the
-- add-vs-set split.
local ok = pcall(function()
  C4:SetVariable("NeverAdded", "hello")
end)
check("does not raise on an unknown name", ok)
check("does not create an unknown name", Variables["NeverAdded"] == nil)

-- The value is checked before the name is looked up, so an unknown name is only
-- silent for a value the controller would have accepted.
check(
  "raises on a boolean value for an unknown name",
  raises(function()
    C4:SetVariable("NeverAdded", true)
  end, "strValue should be a string")
)
check("a rejected set on an unknown name creates nothing", Variables["NeverAdded"] == nil)

check(
  "a rejected set blames the caller, not the shim",
  raises_at_caller(function()
    C4:SetVariable("Temp", true)
  end)
)

--------------------------------------------------------------------------------
section("C4:DeleteVariable")
--------------------------------------------------------------------------------

clearVariables()
C4:AddVariable("Temp", "21.5", "NUMBER", true, false)
local _, deletedId = variableByName("Temp")
C4:DeleteVariable("Temp")
check("clears Variables synchronously", Variables["Temp"] == nil)
check("drops it from GetDeviceVariables", variableByName("Temp") == nil)
check(
  "does not raise on an unknown name",
  pcall(function()
    C4:DeleteVariable("NeverAdded")
  end)
)

C4:AddVariable("Temp", "1", "STRING", true, false)
check("the name is reusable after a delete", Variables["Temp"] == "1")

-- Ids come from a counter that a delete does not rewind. This is the behaviour
-- lib/values.lua works around: it restores hidden placeholders for deleted
-- values so the surviving ones keep their ids across a reset.
local _, reusedId = variableByName("Temp")
check("a re-added name gets a fresh id", reusedId ~= deletedId, reusedId)
check("ids only ever increase", tonumber(reusedId) > tonumber(deletedId))

--------------------------------------------------------------------------------
section("C4:GetDeviceVariables")
--------------------------------------------------------------------------------

clearVariables()

check("a device with no variables gives an empty table", next(C4:GetDeviceVariables(C4:GetDeviceID())) == nil)
check("returns a table rather than nil", type(C4:GetDeviceVariables(C4:GetDeviceID())) == "table")

C4:AddVariable("Scoped", "x", "STRING", false, false)
check("returns this device's variables", variableByName("Scoped") ~= nil)
-- A device id that does not exist is not an error on hardware, it is empty.
check("an unknown device gives an empty table", next(C4:GetDeviceVariables(999999)) == nil)

for _, field in ipairs({ "name", "description", "value", "type", "readonly", "hidden" }) do
  check("every field is a string: " .. field, type(variableField("Scoped", field)) == "string")
end

-- Keying by id means a repeated id drops a variable from the table instead of
-- reporting one, so the count is what catches it rather than any single lookup.
C4:AddVariable("Second", "x", "STRING", false, false)
C4:AddVariable("Third", "x", "STRING", false, false)
local reported, tracked = 0, 0
for _ in pairs(C4:GetDeviceVariables(C4:GetDeviceID())) do
  reported = reported + 1
end
for _ in pairs(Variables) do
  tracked = tracked + 1
end
check("every variable has a distinct id", reported == tracked, reported .. " reported, " .. tracked .. " added")

--------------------------------------------------------------------------------
section("lib/values.lua under the shim")
--------------------------------------------------------------------------------

require("drivers-common-public.global.handlers") -- OVC and the other handler tables
require("drivers-common-public.global.lib") -- Select, Serialize, Deserialize
require("lib.utils") -- IsEmpty, toboolean, tointeger

clearVariables()

-- lib.values is gated on lib_modules; a render without it is valid, not broken.
local loaded, values
if package.searchpath("lib.values", package.path) == nil then
  print("  skip lib/values.lua is not in this render")
else
  loaded, values = pcall(require, "lib.values")
  check("lib.values loads", loaded, values)
end

if loaded then
  values:reset()

  check("update creates the C4 variable", pcall(function()
    values:update("Temperature", 21.5, "NUMBER")
  end) and Variables["Temperature"] == "21.5")

  values:update("Temperature", 22.5, "NUMBER")
  check("a second update sets rather than re-adds", Variables["Temperature"] == "22.5")

  values:update("Enabled", true, "BOOL")
  check('a BOOL value reaches C4 as "1"', Variables["Enabled"] == "1")
  values:update("Enabled", false, "BOOL")
  check('a false BOOL value reaches C4 as "0"', Variables["Enabled"] == "0")

  values:update("ReadOnly", "x", "STRING")
  check("a value with no callback is created readOnly", variableField("ReadOnly", "readonly") == "True")

  values:update("Writable", "x", "STRING", function() end)
  check("a value with a callback is created writable", variableField("Writable", "readonly") == "False")
  check("a callback is registered in OVC", type(OVC["Writable"]) == "function")

  values:delete("Temperature")
  check("delete removes the C4 variable", Variables["Temperature"] == nil)

  values:reset()
  check("reset removes every C4 variable", Variables["Enabled"] == nil and Variables["Writable"] == nil)
end

--------------------------------------------------------------------------------
section("C4:SetTimer handles")
--------------------------------------------------------------------------------

--- Reload the shim with luasocket forced present or absent. The two branches
--- define C4:SetTimer separately, and CI has no luasocket while a developer
--- machine may, so both need the same handle shape.
local function withShim(hasSocket, body)
  local saved = {
    C4 = C4,
    Variables = Variables,
    Properties = Properties,
    socketLoaded = package.loaded["socket"],
    socketPreload = package.preload["socket"],
    shim = package.loaded["c4_shim"],
    Timer = Timer,
    TimerFunctions = TimerFunctions,
  }

  local now = 1000
  package.loaded["socket"] = nil
  if hasSocket then
    package.preload["socket"] = function()
      return {
        gettime = function()
          return now
        end,
        sleep = function() end,
        tcp = function()
          return nil
        end,
      }
    end
  else
    package.preload["socket"] = function()
      error("luasocket not installed")
    end
  end

  package.loaded["c4_shim"] = nil
  require("c4_shim")

  -- global/timer.lua keeps its registries in globals, so reset them too
  Timer, TimerFunctions = {}, {}

  local ok, err = pcall(body, function(seconds)
    now = now + (seconds or 1)
    C4:ProcessTimers()
  end)

  package.loaded["socket"] = saved.socketLoaded
  package.preload["socket"] = saved.socketPreload
  package.loaded["c4_shim"] = saved.shim
  -- The id counter and the attribute table are locals in the shim, so the reload
  -- gets its own and restoring C4 restores the originals along with it.
  C4, Variables, Properties = saved.C4, saved.Variables, saved.Properties
  Timer, TimerFunctions = saved.Timer, saved.TimerFunctions

  if not ok then
    check("shim reload (luasocket " .. tostring(hasSocket) .. ")", false, err)
  end
end

-- global/timer.lua logs through dbg when it is given a nil timerId.
if type(dbg) ~= "function" then
  function dbg() end
end
require("drivers-common-public.global.timer")

check(
  "C4:KillTimer blames the caller, not the shim",
  raises_at_caller(function()
    C4:KillTimer(C4:SetTimer(5000, function() end, false))
  end)
)

for _, hasSocket in ipairs({ false, true }) do
  local label = hasSocket and "with luasocket" or "without luasocket"

  withShim(hasSocket, function(tick)
    local handle = C4:SetTimer(5000, function() end, false)

    check(label .. ": returns userdata", type(handle) == "userdata", type(handle))
    check(label .. ": carries a Cancel method", type(handle.Cancel) == "function")
    check(label .. ": Cancel returns nil", handle:Cancel() == nil)
    check(
      label .. ": Cancel is idempotent",
      pcall(function()
        handle:Cancel()
      end)
    )

    local keyed = {}
    keyed[C4:SetTimer(5000, function() end, false)] = "yes"
    check(
      label .. ": usable as a table key",
      (function()
        for k, v in pairs(keyed) do
          return type(k) == "userdata" and v == "yes"
        end
      end)()
    )

    -- The defect itself: with a table handle nothing is cancelled and the
    -- TimerFunctions entry leaks.
    Timer, TimerFunctions = {}, {}
    local fired = 0
    local t = SetTimer("ping", 5000, function()
      fired = fired + 1
    end)

    check(label .. ": SetTimer registers the handle", TimerFunctions[t] ~= nil)
    check(label .. ": SetTimer records the named slot", Timer["ping"] == t)

    local returned = CancelTimer(t)
    check(label .. ": CancelTimer returns nil", returned == nil)
    check(label .. ": CancelTimer drops TimerFunctions", TimerFunctions[t] == nil)
    check(label .. ": CancelTimer drops the named slot", Timer["ping"] == nil)

    if hasSocket then
      tick(10)
      check(label .. ": a cancelled callback does not fire", fired == 0, fired)

      -- Or the assertion above would pass for the wrong reason
      Timer, TimerFunctions = {}, {}
      local ran = 0
      SetTimer("live", 1000, function()
        ran = ran + 1
      end)
      tick(10)
      check(label .. ": an uncancelled callback fires", ran == 1, ran)
    end
  end)
end

--------------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
