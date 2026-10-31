-- Tests for test/c4_shim.lua itself.
--
-- Every place the shim diverges from a controller is a place a test can go
-- green on a call that fails, or does nothing, on hardware. Two are pinned
-- here: C4:SetTimer must return userdata, or global/timer.lua CancelTimer
-- silently no-ops; and the C4 variable API must exist and behave the way
-- Director does, or lib/values.lua is unusable in a test. Expectations were
-- measured on a dev controller, not inferred from the shim.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_c4_shim.lua

local T = require("testlib")
local F = require("c4_fixtures")

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
T.section("C4:AddVariable")
--------------------------------------------------------------------------------

clearVariables()

T.check("returns true when it creates the variable", C4:AddVariable("Temp", "21.5", "NUMBER", true, false) == true)
T.check("populates Variables synchronously", Variables["Temp"] == "21.5")
T.check("stores the value as a string", type(Variables["Temp"]) == "string")

-- Nothing has been added before this point, so this is the first id the shim
-- hands out. Director starts a device's own variables at 1001.
local tempId = select(2, variableByName("Temp"))
T.check("numbers the first variable 1001", tempId == "1001", tempId)
T.check("keys by id as a string", type(tempId) == "string")
T.check(
  "records readOnly as a capitalised string",
  variableField("Temp", "readonly") == "True",
  variableField("Temp", "readonly")
)
T.check(
  "records the varType as a numeric code in a string",
  variableField("Temp", "type") == "2",
  variableField("Temp", "type")
)
T.check("reports the value", variableField("Temp", "value") == "21.5")
T.check("reports an empty description", variableField("Temp", "description") == "")

T.check("returns false when the name already exists", C4:AddVariable("Temp", "99", "NUMBER", true, false) == false)
T.check("a repeat add leaves the value alone", Variables["Temp"] == "21.5")
T.check("a repeat add leaves the type alone", variableField("Temp", "type") == "2")
T.check("a repeat add does not consume an id", select(2, variableByName("Temp")) == "1001")

C4:AddVariable("Count", 7, "INT", true, false)
T.check("accepts a number and stores tostring of it", Variables["Count"] == "7")

C4:AddVariable("Hidden", "x", "STRING", true, true)
T.check("records hidden as a capitalised string", variableField("Hidden", "hidden") == "True")
T.check("a hidden variable still appears in Variables", Variables["Hidden"] == "x")
-- Director returns hidden variables rather than omitting them, so a caller that
-- wants them gone has to read this field and skip on it.
T.check("a hidden variable is still returned by GetDeviceVariables", variableByName("Hidden") ~= nil)

C4:AddVariable("Defaults", "x", "STRING")
T.check("readOnly defaults to False", variableField("Defaults", "readonly") == "False")
T.check("hidden defaults to False", variableField("Defaults", "hidden") == "False")

C4:AddVariable(98765, "x", "STRING", true, false)
T.check("coerces a non-string name", Variables["98765"] == "x")

-- lib/values.lua reads "0"/"1" back from a BOOL because it wrote "0"/"1", not
-- because Director coerces.
C4:AddVariable("Raw", "true", "BOOL", true, false)
T.check("does not normalise a BOOL value", Variables["Raw"] == "true")

T.raises("raises on a boolean value", function()
  C4:AddVariable("Bad", true, "BOOL", true, false)
end, "strValue should be a string")
T.raises("raises on a nil value", function()
  C4:AddVariable("Bad", nil, "STRING", true, false)
end, "strValue should be a string")
T.check("a rejected add creates nothing", Variables["Bad"] == nil)

T.raises("raises on a nil varType", function()
  C4:AddVariable("Bad", "x", nil, true, false)
end, "strVarType should be a string")
T.raises("raises on an unknown varType", function()
  C4:AddVariable("Bad", "x", "DYNAMIC", true, false)
end, "Invalid variable type.")

-- Each case above breaks one rule, which leaves the order between them free.
T.raises("the value is checked before an unknown varType", function()
  C4:AddVariable("Bad", true, "DYNAMIC", true, false)
end, "strValue should be a string")
T.raises("the value is checked before a nil varType", function()
  C4:AddVariable("Bad", true, nil, true, false)
end, "strValue should be a string")
local repeatOk, repeatRet = pcall(function()
  return C4:AddVariable("Temp", "x", "DYNAMIC", true, false)
end)
T.check("an existing name returns false without validating varType", repeatOk and repeatRet == false, repeatRet)
T.raises("an existing name still checks the value", function()
  C4:AddVariable("Temp", true, "NUMBER", true, false)
end, "strValue should be a string")
T.raises("an existing name still checks that varType is a string", function()
  C4:AddVariable("Temp", "x", nil, true, false)
end, "strVarType should be a string")
T.check("a rejected repeat add leaves the value alone", Variables["Temp"] == "21.5")

T.raisesAt("a rejected add blames the caller, not the shim", function()
  C4:AddVariable("Bad", true, "STRING", true, false)
end)

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
  T.check("accepts varType " .. varType, ok and Variables["Type_" .. varType] == "1")
  local variable = variableByName("Type_" .. varType)
  T.check(
    "reports varType " .. varType .. " as type " .. code,
    variable and variable.type == code,
    variable and variable.type
  )
end

T.check(
  "NUMBER and INT collapse onto one code",
  variableField("Type_NUMBER", "type") == variableField("Type_INT", "type")
)

--------------------------------------------------------------------------------
T.section("C4:SetVariable")
--------------------------------------------------------------------------------

clearVariables()
C4:AddVariable("Temp", "21.5", "NUMBER", true, false)

C4:SetVariable("Temp", "22.0")
T.check("updates Variables synchronously", Variables["Temp"] == "22.0")
T.check("the new value is visible through GetDeviceVariables", variableField("Temp", "value") == "22.0")

C4:SetVariable("Temp", 5)
T.check("accepts a number and stores tostring of it", Variables["Temp"] == "5")

-- readOnly describes what C4 programming may do, not what the driver may do.
C4:AddVariable("Locked", "0", "BOOL", true, false)
C4:SetVariable("Locked", "1")
T.check("writes through to a readOnly variable", Variables["Locked"] == "1")

C4:SetVariable("Locked", "false")
T.check("does not normalise a BOOL value", Variables["Locked"] == "false")

T.raises("raises on a boolean value", function()
  C4:SetVariable("Temp", true)
end, "strValue should be a string")
T.raises("raises on a nil value", function()
  C4:SetVariable("Temp", nil)
end, "strValue should be a string")
T.check("a rejected set leaves the value alone", Variables["Temp"] == "5")

-- Silent, and specifically not a create: lib/values.lua relies on the
-- add-vs-set split.
local ok = pcall(function()
  C4:SetVariable("NeverAdded", "hello")
end)
T.check("does not raise on an unknown name", ok)
T.check("does not create an unknown name", Variables["NeverAdded"] == nil)

-- The value is checked before the name is looked up, so an unknown name is only
-- silent for a value the controller would have accepted.
T.raises("raises on a boolean value for an unknown name", function()
  C4:SetVariable("NeverAdded", true)
end, "strValue should be a string")
T.check("a rejected set on an unknown name creates nothing", Variables["NeverAdded"] == nil)

T.raisesAt("a rejected set blames the caller, not the shim", function()
  C4:SetVariable("Temp", true)
end)

--------------------------------------------------------------------------------
T.section("C4:DeleteVariable")
--------------------------------------------------------------------------------

clearVariables()
C4:AddVariable("Temp", "21.5", "NUMBER", true, false)
local _, deletedId = variableByName("Temp")
C4:DeleteVariable("Temp")
T.check("clears Variables synchronously", Variables["Temp"] == nil)
T.check("drops it from GetDeviceVariables", variableByName("Temp") == nil)
T.check(
  "does not raise on an unknown name",
  pcall(function()
    C4:DeleteVariable("NeverAdded")
  end)
)

C4:AddVariable("Temp", "1", "STRING", true, false)
T.check("the name is reusable after a delete", Variables["Temp"] == "1")

-- Ids come from a counter that a delete does not rewind within a driver load.
local _, reusedId = variableByName("Temp")
T.check("a re-added name gets a fresh id", reusedId ~= deletedId, reusedId)
T.check("ids only ever increase", tonumber(reusedId) > tonumber(deletedId))

--------------------------------------------------------------------------------
T.section("C4:GetDeviceVariables")
--------------------------------------------------------------------------------

clearVariables()

T.check("a device with no variables gives an empty table", next(C4:GetDeviceVariables(C4:GetDeviceID())) == nil)
T.check("returns a table rather than nil", type(C4:GetDeviceVariables(C4:GetDeviceID())) == "table")

C4:AddVariable("Scoped", "x", "STRING", false, false)
T.check("returns this device's variables", variableByName("Scoped") ~= nil)
-- A device id that does not exist is not an error on hardware, it is empty.
T.check("an unknown device gives an empty table", next(C4:GetDeviceVariables(999999)) == nil)

for _, field in ipairs({ "name", "description", "value", "type", "readonly", "hidden" }) do
  T.check("every field is a string: " .. field, type(variableField("Scoped", field)) == "string")
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
T.check("every variable has a distinct id", reported == tracked, reported .. " reported, " .. tracked .. " added")

--------------------------------------------------------------------------------
T.section("variable ids across driver loads")
--------------------------------------------------------------------------------

-- As on OS 4.3.0.
ShimRestartDirector()
local function idOf(name)
  return tonumber((select(2, variableByName(name))))
end

T.eq("a by-name add returns true and its id", { C4:AddVariable("A", "", "STRING") }, { true, 1001 })
C4:AddVariable("B", "", "STRING")
C4:AddVariable("C", "", "STRING")
C4:DeleteVariable("B")
T.eq("a freed id is not handed out again in that load", select(2, C4:AddVariable("D", "", "STRING")), 1004)
T.eq("an add by id takes exactly that id", { C4:AddVariable(1012, "", "STRING") }, { true, 1012 })
T.eq("named after it", idOf("1012"), 1012)
T.eq("and leaves the counter alone", select(2, C4:AddVariable("E", "", "STRING")), 1005)
T.eq("an add at a taken id fails", C4:AddVariable(1001, "", "STRING"), false)
C4:AddVariable("1013", "", "STRING")
T.eq("a name that reads as a number is that id", idOf("1013"), 1013)
C4:SetVariable("1013", "x")
T.eq("and a set by it reaches that id", Variables["1013"], "x")
T.raises("an id below 1 raises", function()
  C4:AddVariable("-5", "", "STRING")
end, "id must be greater than zero")

ShimUpdateDriver()
T.eq("a driver update keeps every variable", idOf("E"), 1005)
T.eq("and the new load's counter fills the gaps", select(2, C4:AddVariable("F", "", "STRING")), 1002)

ShimRestartDirector()
T.eq("a Director restart keeps no variable", next(C4:GetDeviceVariables(C4:GetDeviceID())), nil)
T.eq("and Variables is empty", next(Variables), nil)
T.eq("its counter starts at 1001", select(2, C4:AddVariable("G", "", "STRING")), 1001)

--------------------------------------------------------------------------------
T.section("C4.SetVariableName")
--------------------------------------------------------------------------------

C4:AddVariable(1010, "ten", "STRING")
T.eq("renames in place", C4:SetVariableName(1010, "Ten"), true)
T.eq("keeping the id", idOf("Ten"), 1010)
T.eq("Variables follows the new name", { Variables["Ten"], Variables["1010"] }, { "ten" })
C4:SetVariable(1010, "x")
T.eq("a set by id reaches it", Variables["Ten"], "x")
T.eq("onto a name another variable has it returns false", C4:SetVariableName(1010, "G"), false)
T.eq("so it does onto its own", C4:SetVariableName(1010, "Ten"), false)
T.eq("and for a missing id", C4:SetVariableName(1011, "Eleven"), false)
C4:AddVariable(1011, "", "STRING")
T.eq('a rename to "" returns true', C4:SetVariableName(1011, ""), true)
T.eq("but the variable keeps its number as its name", idOf("1011"), 1011)
C4:DeleteVariable(1010)
T.eq("a delete by id deletes it", Variables["Ten"], nil)
ShimVariableRename(false)
T.eq("switched off, as on an OS without it", C4.SetVariableName, nil)
ShimVariableRename(true)
ShimRestartDirector()

--------------------------------------------------------------------------------
T.section("lib/values.lua under the shim")
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
  T.check("lib.values loads", loaded, values)
end

if loaded then
  values:reset()

  T.check("update creates the C4 variable", pcall(function()
    values:update("Temperature", 21.5, "NUMBER")
  end) and Variables["Temperature"] == "21.5")

  values:update("Temperature", 22.5, "NUMBER")
  T.check("a second update sets rather than re-adds", Variables["Temperature"] == "22.5")

  values:update("Enabled", true, "BOOL")
  T.check('a BOOL value reaches C4 as "1"', Variables["Enabled"] == "1")
  values:update("Enabled", false, "BOOL")
  T.check('a false BOOL value reaches C4 as "0"', Variables["Enabled"] == "0")

  values:update("ReadOnly", "x", "STRING")
  T.check("a value with no callback is created readOnly", variableField("ReadOnly", "readonly") == "True")

  values:update("Writable", "x", "STRING", function() end)
  T.check("a value with a callback is created writable", variableField("Writable", "readonly") == "False")
  T.check("a callback is registered in OVC", type(OVC["Writable"]) == "function")

  values:delete("Temperature")
  T.check("delete removes the C4 variable", Variables["Temperature"] == nil)

  values:reset()
  T.check("reset removes every C4 variable", Variables["Enabled"] == nil and Variables["Writable"] == nil)
end

--------------------------------------------------------------------------------
T.section("C4:GetTime")
--------------------------------------------------------------------------------

do
  -- DriverWorks: milliseconds since the epoch, or the units asked for, whole unless fractional.
  local ms = C4:GetTime()
  T.check("milliseconds since the epoch", math.abs(ms / 1000 - os.time()) < 5, ms)
  T.check("whole by default", ms == math.floor(ms), ms)
  T.check("seconds where asked", math.abs(C4:GetTime("s") - ms / 1000) <= 1, C4:GetTime("s"))
  local minutes = C4:GetTime("min", true)
  T.check("a fraction where asked", math.abs(minutes - ms / 60000) < 0.1, minutes)

  -- Measured on a controller: units in any case, and a year of 365.2425 days.
  T.check("units in any case", math.abs(C4:GetTime("MIN") - ms / 60000) <= 1, C4:GetTime("MIN"))
  local years = C4:GetTime("y", true)
  T.check("a year is 365.2425 days", math.abs(years - ms / 31556952000) < 1e-6, years)
  T.raises("C4.GetTime without a receiver raises as on Director", function()
    C4.GetTime()
  end, "An unknown error occurred")
  T.raises("a nil unit raises as on Director", function()
    C4:GetTime(nil)
  end, "units should be a string")
  T.raises("a nil fractional raises as on Director", function()
    C4:GetTime("s", nil)
  end, "fractional should be a boolean")
end

--------------------------------------------------------------------------------
T.section("C4:SetTimer handles")
--------------------------------------------------------------------------------

-- global/timer.lua logs through dbg when it is given a nil timerId.
if type(dbg) ~= "function" then
  function dbg() end
end
require("drivers-common-public.global.timer")

T.raisesAt("C4:KillTimer blames the caller, not the shim", function()
  C4:KillTimer(C4:SetTimer(5000, function() end, false))
end)

for _, hasSocket in ipairs({ false, true }) do
  local label = hasSocket and "with luasocket" or "without luasocket"

  -- The two branches of the shim define C4:SetTimer separately, and CI has no
  -- luasocket while a developer machine may, so both need the same handle shape.
  local reloaded, reloadErr = F.withShim({ luasocket = hasSocket }, function(clock)
    local handle = C4:SetTimer(5000, function() end, false)

    T.check(label .. ": returns userdata", type(handle) == "userdata", type(handle))
    T.check(label .. ": carries a Cancel method", type(handle.Cancel) == "function")
    T.check(label .. ": Cancel returns nil", handle:Cancel() == nil)
    T.check(
      label .. ": Cancel is idempotent",
      pcall(function()
        handle:Cancel()
      end)
    )

    local keyed = {}
    keyed[C4:SetTimer(5000, function() end, false)] = "yes"
    T.check(
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

    T.check(label .. ": SetTimer registers the handle", TimerFunctions[t] ~= nil)
    T.check(label .. ": SetTimer records the named slot", Timer["ping"] == t)

    local returned = CancelTimer(t)
    T.check(label .. ": CancelTimer returns nil", returned == nil)
    T.check(label .. ": CancelTimer drops TimerFunctions", TimerFunctions[t] == nil)
    T.check(label .. ": CancelTimer drops the named slot", Timer["ping"] == nil)

    if hasSocket then
      clock.advance(10)
      T.check(label .. ": a cancelled callback does not fire", fired == 0, fired)

      -- Or the assertion above would pass for the wrong reason
      Timer, TimerFunctions = {}, {}
      local ran = 0
      SetTimer("live", 1000, function()
        ran = ran + 1
      end)
      clock.advance(10)
      T.check(label .. ": an uncancelled callback fires", ran == 1, ran)
    end
  end)

  if not reloaded then
    T.check("shim reload (" .. label .. ")", false, reloadErr)
  end
end

--------------------------------------------------------------------------------
-- string.pack / string.unpack lpack semantics. The shim stands in for Control4's
-- lpack, so its signedness and widths must match what the controller actually does
-- (measured on a dev controller: `b` unsigned, `c` signed8, `<L` is 4 bytes). A
-- shim that got `b` wrong would let the suite agree with a driver bug rather than
-- catch it - which is exactly what happened with the Xiaomi int8 decode.
T.section("string.pack / string.unpack (lpack-compatible)")
do
  -- Signedness of the 8-bit codes: this is the one that bit us.
  T.check(
    "b decodes 0xF6 as UNSIGNED 246",
    select(2, string.unpack("\246", "b", 1)) == 246,
    select(2, string.unpack("\246", "b", 1))
  )
  T.check(
    "c decodes 0xF6 as SIGNED -10",
    select(2, string.unpack("\246", "c", 1)) == -10,
    select(2, string.unpack("\246", "c", 1))
  )
  -- 16/32-bit signedness.
  T.check("<h is signed16", select(2, string.unpack(string.char(0xF6, 0xFF), "<h", 1)) == -10)
  T.check("<H is unsigned16", select(2, string.unpack(string.char(0xF6, 0xFF), "<H", 1)) == 65526)
  T.check("<i is signed32", select(2, string.unpack(string.char(0xF6, 0xFF, 0xFF, 0xFF), "<i", 1)) == -10)
  T.check("<I is unsigned32", select(2, string.unpack(string.char(0xF6, 0xFF, 0xFF, 0xFF), "<I", 1)) == 4294967286)
  -- Round-trip and byte order (little-endian).
  T.check("pack/unpack <H round-trips", select(2, string.unpack(string.pack("<H", 300), "<H", 1)) == 300)
  T.check(
    "<I packs 4 little-endian bytes",
    string.pack("<I", 1) == string.char(1, 0, 0, 0),
    (string.pack("<I", 1)):byte(1, 4)
  )
  -- unpack returns nextPos first (lpack signature), then the value(s).
  local np = string.unpack(string.char(0, 0), "<H", 1)
  T.check("unpack returns nextPos as its first result", np == 3, np)
  -- float32 round-trips a simple value.
  T.check("f round-trips 1.5", select(2, string.unpack(string.pack("f", 1.5), "f", 1)) == 1.5)
  -- Reference byte vectors (little-endian IEEE754, from struct.pack('<f', x)): pin the
  -- encoding to the controller's, not just self-consistency.
  local function fhex(x)
    return (string.pack("f", x):gsub(".", function(b)
      return string.format("%02x", b:byte())
    end))
  end
  T.check("f encodes 0.1 as cdcccc3d", fhex(0.1) == "cdcccc3d", fhex(0.1))
  T.check("f encodes 100.25 as 0080c842", fhex(100.25) == "0080c842", fhex(100.25))
  T.check("f encodes 255.999999 as 00008043", fhex(255.999999) == "00008043", fhex(255.999999))
  -- Mantissa rounding that carries into the next binade must bump the exponent, not
  -- halve the value (regression: 255.999999 encoded as 128.0).
  T.check("f 255.999999 -> 256", select(2, string.unpack(string.pack("f", 255.999999), "f", 1)) == 256.0)
  T.check("f 65535.99999 -> 65536", select(2, string.unpack(string.pack("f", 65535.99999), "f", 1)) == 65536.0)
  T.check("f 0.99999999 -> 1", select(2, string.unpack(string.pack("f", 0.99999999), "f", 1)) == 1.0)
  T.check("f -0.99999999 -> -1", select(2, string.unpack(string.pack("f", -0.99999999), "f", 1)) == -1.0)
  T.check("f 1e39 saturates to +inf", select(2, string.unpack(string.pack("f", 1e39), "f", 1)) == math.huge)
  -- Non-finite and out-of-range values, as string.pack("f", v) wrote them on a controller
  -- (OS 4.3.0). A NaN of either sign is the one it wrote for 0/0, so the bytes hold on any host.
  local nan = 0 / 0
  T.check("f encodes a NaN as 0000c07f", fhex(nan) == "0000c07f", fhex(nan))
  T.check("f encodes a negated NaN as 0000c07f", fhex(-nan) == "0000c07f", fhex(-nan))
  local wireNan = select(2, string.unpack("\0\0\192\255", "f", 1))
  T.check("f encodes a NaN off the wire as 0000c07f", fhex(wireNan) == "0000c07f", fhex(wireNan))
  T.check("f encodes +inf as 0000807f", fhex(math.huge) == "0000807f", fhex(math.huge))
  T.check("f encodes -inf as 000080ff", fhex(-math.huge) == "000080ff", fhex(-math.huge))
  T.check("f encodes 3.5e38 as 0000807f", fhex(3.5e38) == "0000807f", fhex(3.5e38))
  T.check("f encodes 1e-46 as 00000000", fhex(1e-46) == "00000000", fhex(1e-46))
  T.check("f encodes 0.5 as 0000003f", fhex(0.5) == "0000003f", fhex(0.5))
  local function roundTrip(x)
    return select(2, string.unpack(string.pack("f", x), "f", 1))
  end
  local rtNan, rtNegNan = roundTrip(nan), roundTrip(-nan)
  T.check("f NaN round-trips to a NaN", rtNan ~= rtNan, rtNan)
  T.check("f negated NaN round-trips to a NaN", rtNegNan ~= rtNegNan, rtNegNan)
  T.check("f +inf round-trips", roundTrip(math.huge) == math.huge, roundTrip(math.huge))
  T.check("f -inf round-trips", roundTrip(-math.huge) == -math.huge, roundTrip(-math.huge))
end

--------------------------------------------------------------------------------
-- Color conversion scales. The two reference pairs were measured on a CA-1
-- running OS 3.4; the rest pin the scale boundaries that a driver would notice.
-- RGB is 0-255 and unrounded, HSV is h 0-360 / s 0-100 / v 0-100. A shim on the
-- 0-1 RGB scale, or rounding to integers, would let a driver that scales wrong
-- pass here and wash out the color on hardware.
T.section("C4:ColorHSVtoRGB / C4:ColorRGBtoHSV")
do
  --- Round-trip through a fixed number of decimals, so a comparison is not at
  --- the mercy of the last float bit.
  local function approx(got, want)
    return math.abs(got - want) < 0.001
  end

  local r, g, b = C4:ColorHSVtoRGB(120, 75, 100)
  T.check("HSV(120,75,100) -> R 63.75", approx(r, 63.75), r)
  T.check("HSV(120,75,100) -> G 255", approx(g, 255), g)
  T.check("HSV(120,75,100) -> B 63.75", approx(b, 63.75), b)
  T.check("returns RGB unrounded", r ~= math.floor(r), r)

  local h, s, v = C4:ColorRGBtoHSV(64, 255, 64)
  T.check("RGB(64,255,64) -> H 120", approx(h, 120), h)
  T.check("RGB(64,255,64) -> S 74.902", approx(s, 74.902), s)
  T.check("RGB(64,255,64) -> V 100", approx(v, 100), v)

  -- Hue sector boundaries: each primary sits at the start of its own sector.
  T.eq("HSV(0,100,100) is pure red", { C4:ColorHSVtoRGB(0, 100, 100) }, { 255, 0, 0 })
  T.eq("HSV(120,100,100) is pure green", { C4:ColorHSVtoRGB(120, 100, 100) }, { 0, 255, 0 })
  T.eq("HSV(240,100,100) is pure blue", { C4:ColorHSVtoRGB(240, 100, 100) }, { 0, 0, 255 })
  -- 360 wraps to 0 rather than falling off the last sector and returning black.
  T.eq("hue 360 wraps to hue 0", { C4:ColorHSVtoRGB(360, 100, 100) }, { 255, 0, 0 })

  -- Value scales the whole triple, so half value is half the 0-255 range.
  T.eq("value 50 halves the RGB range", { C4:ColorHSVtoRGB(240, 100, 50) }, { 0, 0, 127.5 })

  T.eq("RGB(255,0,0) -> H 0 S 100 V 100", { C4:ColorRGBtoHSV(255, 0, 0) }, { 0, 100, 100 })
  T.eq("RGB(0,0,255) -> H 240", { C4:ColorRGBtoHSV(0, 0, 255) }, { 240, 100, 100 })
  -- Greys have no hue and no saturation, but keep their value.
  T.eq("white is S 0 V 100", { C4:ColorRGBtoHSV(255, 255, 255) }, { 0, 0, 100 })
  T.eq("black is all zero", { C4:ColorRGBtoHSV(0, 0, 0) }, { 0, 0, 0 })

  -- Hue is never negative: the red sector wraps through 360 rather than to -60.
  local negH = C4:ColorRGBtoHSV(255, 0, 128)
  T.check("hue below the red sector wraps to 0-360", negH >= 0 and negH <= 360, negH)

  -- nil is treated as 0 rather than raising, matching the other shim accessors.
  T.eq("nil arguments read as zero", { C4:ColorHSVtoRGB() }, { 0, 0, 0 })
end

--------------------------------------------------------------------------------
-- Crypto. Backed by CommonCrypto or libcrypto through the LuaJIT FFI, so it is
-- absent under plain Lua and on a host with no loadable libcrypto. The digests
-- are pinned to published reference vectors rather than to the shim's own
-- output, so a broken FFI binding fails instead of agreeing with itself.
T.section("C4:Hash / C4:Encrypt / C4:Decrypt")
do
  -- Argument checks and the unknown-digest answer involve no crypto, so they are asserted outside
  -- the backend gate below. Strings and raises are as a 4.3.0 controller gives them.
  T.eq(
    "an unknown digest returns nil and the controller's reason",
    { C4:Hash("FOO", "abc") },
    { nil, 'Failed to compute the hash: "The digest name argument specified an unknown message digest"' }
  )
  T.eq(
    "an empty digest name returns nil and its own reason",
    { C4:Hash("", "abc") },
    { nil, 'The value of the "digest" parameter is invalid' }
  )
  T.raises("nil data raises", function()
    C4:Hash("SHA256", nil)
  end, "data should be a string")
  T.raises("options that are not a table raise", function()
    C4:Hash("SHA256", "abc", "HEX")
  end, "options should be a table")
  -- Omitting options is fine; passing nil for them raises on a controller.
  T.raises("an explicit nil options argument raises", function()
    C4:Hash("SHA256", "abc", nil)
  end, "An unknown error occurred")
  T.eq(
    "undecodable HEX data returns nil and the reason",
    { C4:Hash("SHA256", "zz", { data_encoding = "HEX" }) },
    { nil, 'Failed to decode the data: "Failed to decode"' }
  )
  T.eq(
    "odd-length HEX data is undecodable",
    { C4:Hash("SHA256", "61626", { data_encoding = "HEX" }) },
    { nil, 'Failed to decode the data: "Failed to decode"' }
  )
  -- C4:Base64Decode answers "" for these; Hash refuses them instead of hashing "".
  for _, bad in ipairs({ "!!!!", "a!bc", "YWJ" }) do
    T.eq(
      "BASE64 data " .. bad .. " that decodes to nothing returns nil and the reason",
      { C4:Hash("SHA256", bad, { data_encoding = "BASE64" }) },
      { nil, 'Failed to decode the data: "Failed to decode"' }
    )
  end
  for _, encoding in ipairs({ "HEX", "BASE64" }) do
    T.eq(
      "empty " .. encoding .. " data returns nil and its own reason",
      { C4:Hash("SHA256", "", { data_encoding = encoding }) },
      { nil, 'Failed to decode the data: "The specified encoded data was empty"' }
    )
  end

  if not C4.SHIM_HAS_CRYPTO then
    -- Same shape as the lib/values.lua skip above: visible, so it cannot read as
    -- a pass, but not a failure, because a driver that never calls C4:Hash
    -- should not need libcrypto to run its suite. The template's own CI asserts
    -- the backend resolves, so the mock stays covered where it is developed.
    print("  skip no crypto backend on this host, digest and cipher assertions did not run")
  else
    T.eq("MD5 of abc", C4:Hash("MD5", "abc"), "900150983cd24fb0d6963f7d28e17f72")
    T.eq("SHA1 of abc", C4:Hash("SHA1", "abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    T.eq("SHA224 of abc", C4:Hash("SHA224", "abc"), "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7")
    T.eq("SHA256 of abc", C4:Hash("SHA256", "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    T.eq(
      "SHA256 of the empty string",
      C4:Hash("SHA256", ""),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    T.eq(
      "SHA384 of abc",
      C4:Hash("SHA384", "abc"),
      "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
    )
    T.eq(
      "SHA512 of abc",
      C4:Hash("SHA512", "abc"),
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        .. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
    )

    -- A controller answers in lower-case hex, for HEX in any case and for an encoding it does not
    -- know, and matches the digest name in any case.
    local hex = C4:Hash("SHA256", "abc")
    T.eq("HEX is the same hex", C4:Hash("SHA256", "abc", { return_encoding = "HEX" }), hex)
    T.eq("so is hex", C4:Hash("SHA256", "abc", { return_encoding = "hex" }), hex)
    T.eq("an unknown return_encoding gives hex", C4:Hash("SHA256", "abc", { return_encoding = "FOO" }), hex)
    T.eq("empty options give hex", C4:Hash("SHA256", "abc", {}), hex)
    T.eq("a lower-case digest name works", C4:Hash("sha256", "abc"), hex)
    T.eq("a number is hashed as its string", C4:Hash("SHA256", 5), C4:Hash("SHA256", "5"))

    -- return_encoding NONE gives the raw digest, which is what lib/klap.lua
    -- slices for its keys. Hex would silently double every offset.
    local raw = C4:Hash("SHA256", "abc", { return_encoding = "NONE" })
    T.check("NONE returns 32 raw bytes", #raw == 32, #raw)
    T.eq("none in lower case is raw too", C4:Hash("SHA256", "abc", { return_encoding = "none" }), raw)
    T.eq(
      "BASE64 is the Base64 digest",
      C4:Hash("SHA1", "abc", { return_encoding = "BASE64" }),
      "qZk+NkcGgWq6PiVxeFDCbJzQ2J0="
    )
    T.eq(
      "base64 in lower case too",
      C4:Hash("SHA256", "abc", { return_encoding = "base64" }),
      "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
    )
    T.eq("HEX data is decoded first", C4:Hash("SHA256", "616263", { data_encoding = "HEX" }), hex)
    T.eq("BASE64 data is decoded first", C4:Hash("SHA256", "YWJj", { data_encoding = "base64" }), hex)
    T.eq("an unknown data_encoding reads the data as is", C4:Hash("SHA256", "abc", { data_encoding = "FOO" }), hex)
    T.eq("BASE64 data is trimmed", C4:Hash("SHA256", " YWJj ", { data_encoding = "BASE64" }), hex)
    T.eq("a trailing partial BASE64 group is dropped", C4:Hash("SHA256", "YWJjZA", { data_encoding = "BASE64" }), hex)
    T.eq("==== is one zero byte", C4:Hash("SHA256", "====", { data_encoding = "BASE64" }), C4:Hash("SHA256", "\0"))
    T.eq(
      "empty data with no decoding hashes the empty string",
      C4:Hash("SHA256", "", { data_encoding = "NONE" }),
      C4:Hash("SHA256", "")
    )

    -- AES-128-CBC with PKCS7: 5 bytes pad up to one block, and the round trip
    -- recovers the plaintext exactly.
    local key, iv = string.rep("k", 16), string.rep("i", 16)
    local ciphertext, encryptErr = C4:Encrypt("AES-128-CBC", key, iv, "hello")
    -- Named failure rather than a length-of-nil error, so a backend whose
    -- digests work but whose cipher does not still reports which half broke.
    T.truthy("encrypt returns a ciphertext", ciphertext, encryptErr)
    ciphertext = ciphertext or ""
    T.check("PKCS7 pads 5 bytes to one 16-byte block", #ciphertext == 16, #ciphertext)
    T.eq("decrypt reverses encrypt", C4:Decrypt("AES-128-CBC", key, iv, ciphertext), "hello")
    T.neq("ciphertext is not the plaintext", ciphertext, "hello")

    -- NIST SP 800-38A F.2.5, CBC-AES256.Encrypt, first block, with padding off
    -- so the output is exactly the published block.
    local function unhex(h)
      return (h:gsub("..", function(b)
        return string.char(tonumber(b, 16))
      end))
    end
    local key256 = unhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
    local nistIv = unhex("000102030405060708090a0b0c0d0e0f")
    local block = unhex("6bc1bee22e409f96e93d7e117393172a")
    local nist = C4:Encrypt("AES-256-CBC", key256, nistIv, block, { padding = false })
    T.eq("AES-256-CBC matches NIST F.2.5", nist, unhex("f58c4c04d6e5f1ba779eabfb5f7bfbd6"))
    T.eq("and decrypts back", C4:Decrypt("AES-256-CBC", key256, nistIv, nist or "", { padding = false }), block)

    -- The options lib.lua's AES_ENC_DEFAULTS / AES_DEC_DEFAULTS pass: BASE64
    -- out of Encrypt and into Decrypt.
    local b64 = C4:Encrypt("AES-256-CBC", key256, nistIv, "hello", { return_encoding = "BASE64" })
    T.check("BASE64 return_encoding is Base64 text", type(b64) == "string" and b64:match("^[%w+/]+=*$") ~= nil)
    T.eq(
      "and BASE64 data_encoding reads it back",
      C4:Decrypt("AES-256-CBC", key256, nistIv, b64, { data_encoding = "BASE64" }),
      "hello"
    )

    -- A nil iv is modelled as zero; with CBC it reaches only the first block.
    local zero = C4:Encrypt("AES-256-CBC", key256, string.rep("\0", 16), "abc")
    T.eq("a nil iv is the zero iv", C4:Encrypt("AES-256-CBC", key256, nil, "abc"), zero)

    -- Arguments the controller would reject are refused, not quietly guessed.
    T.check("an unmodelled cipher is refused", C4:Encrypt("AES-256-GCM", key256, nistIv, "x") == nil)
    T.contains("and says which are", select(2, C4:Encrypt("DES-CBC", key, iv, "x")), "AES-256-CBC")
    T.check("a key the wrong size for its cipher is refused", C4:Encrypt("AES-256-CBC", key, iv, "x") == nil)
    T.check("an iv that is not 16 bytes is refused", C4:Encrypt("AES-128-CBC", key, "short", "x") == nil)
    T.check(
      "an unmodelled encoding is refused",
      C4:Encrypt("AES-128-CBC", key, iv, "x", { return_encoding = "HEX" }) == nil
    )

    -- Captured on a 4.3 controller: C4:Encrypt with lib.lua's AES_ENC_DEFAULTS
    -- options and a nil iv, and a SaltedEncrypt the shim has to read back.
    local controllerOptions = {
      return_encoding = "BASE64",
      key_encoding = "NONE",
      iv_encoding = "NONE",
      data_encoding = "NONE",
      padding = true,
    }
    T.eq(
      "a nil iv encrypts as the controller does",
      C4:Encrypt("AES-256-CBC", string.rep("k", 32), nil, "hello world, salted", controllerOptions),
      "0VC3a7Pm+wLzZuJUoix64v6kYXRJcBXg2UaPOSuBEjE="
    )
    T.eq(
      "a controller's SaltedEncrypt decrypts",
      SaltedDecrypt("device-key", "UE/lhd3fPDbBZUt4iJAtZapMTybvPQT7SF8cuL0uY40="),
      "refresh-token"
    )

    -- lib.lua's SaltedEncrypt/SaltedDecrypt, which auth_code_grant uses to store
    -- a refresh token, round trip under the shim.
    local sealed = SaltedEncrypt("device-key", "refresh-token")
    T.truthy("SaltedEncrypt returns a ciphertext", sealed)
    T.eq("SaltedDecrypt recovers the plaintext", SaltedDecrypt("device-key", sealed), "refresh-token")
    T.neq("a different key does not", SaltedDecrypt("other-key", sealed), "refresh-token")
  end
end

--------------------------------------------------------------------------------
-- Every answer here was measured on a 4.3.0 controller; the long-key vectors are
-- also RFC 4231's test case 6.
T.section("C4:HMAC")
do
  local fox = "The quick brown fox jumps over the lazy dog"
  T.eq(
    "an unknown digest returns nil and the controller's reason",
    { C4:HMAC("NOPE", "key", "abc") },
    { nil, 'Failed to compute the HMAC: "The digest name argument specified an unknown message digest"' }
  )
  T.eq(
    "an empty digest is invalid",
    { C4:HMAC("", "key", "abc") },
    { nil, 'The value of the "digest" parameter is invalid' }
  )
  T.eq(
    "an empty key is invalid",
    { C4:HMAC("SHA256", "", "abc") },
    { nil, 'The value of the "key" parameter is invalid' }
  )
  T.eq(
    "empty data is invalid",
    { C4:HMAC("SHA256", "key", "") },
    { nil, 'The value of the "data" parameter is invalid' }
  )
  T.eq(
    "even when it was to be decoded",
    { C4:HMAC("SHA256", "key", "", { data_encoding = "HEX" }) },
    { nil, 'The value of the "data" parameter is invalid' }
  )
  T.eq(
    "an undecodable key returns nil and the reason",
    { C4:HMAC("SHA256", "!!!!", "abc", { key_encoding = "BASE64" }) },
    { nil, 'Failed to decode the key: "Failed to decode"' }
  )
  T.eq(
    "so does undecodable data",
    { C4:HMAC("SHA256", "key", "zz", { data_encoding = "HEX" }) },
    { nil, 'Failed to decode the data: "Failed to decode"' }
  )
  T.raises("a nil key raises", function()
    C4:HMAC("SHA256", nil, "abc")
  end, "key should be a string")
  T.raises("nil data raises", function()
    C4:HMAC("SHA256", "key", nil)
  end, "data should be a string")
  T.raises("options that are not a table raise", function()
    C4:HMAC("SHA256", "key", "abc", "x")
  end, "options should be a table")
  T.raises("an explicit nil options argument raises", function()
    C4:HMAC("SHA256", "key", "abc", nil)
  end, "An unknown error occurred")

  if not C4.SHIM_HAS_CRYPTO then
    print("  skip no crypto backend on this host, HMAC digests did not run")
  else
    local hex = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
    T.eq("SHA256 is lower-case hex and a nil error", { C4:HMAC("SHA256", "key", fox) }, { hex, nil })
    T.eq("HEX is the same hex", C4:HMAC("SHA256", "key", fox, { return_encoding = "HEX" }), hex)
    T.eq(
      "base64 in any case is the Base64 digest",
      C4:HMAC("sha256", "key", fox, { return_encoding = "base64" }),
      "97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg="
    )
    local abc = "9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab"
    T.eq("an unknown return_encoding gives hex", C4:HMAC("SHA256", "key", "abc", { return_encoding = "X" }), abc)
    T.check("NONE returns 32 raw bytes", #C4:HMAC("SHA256", "key", "abc", { return_encoding = "NONE" }) == 32)
    T.eq("a HEX key is decoded first", C4:HMAC("SHA256", "6b6579", "abc", { key_encoding = "HEX" }), abc)
    T.eq("so is a BASE64 key", C4:HMAC("SHA256", "a2V5", "abc", { key_encoding = "BASE64" }), abc)
    T.eq("and hex data", C4:HMAC("SHA256", "key", "616263", { data_encoding = "hex" }), abc)
    T.eq(
      "a number key is its string",
      C4:HMAC("SHA256", 7, "abc"),
      "49e7cff1c83779286a9758b5f6c1ea57fca1bcce7aad655cae005a75c61e6c66"
    )
    T.eq(
      "and number data",
      C4:HMAC("SHA256", "key", 5),
      "ab20d8bbe394c193b6182ca459324966b8112064e0eb3dc53c1ac80321ffc712"
    )
    T.eq("SHA1", C4:HMAC("SHA1", "key", "abc"), "4fd0b215276ef12f2b3e4c8ecac2811498b656fc")
    T.eq(
      "SHA512",
      C4:HMAC("SHA512", "key", "abc"),
      "3926a207c8c42b0c41792cbd3e1a1aaaf5f7a25704f62dfc939c4987dd7ce060"
        .. "009c5bb1c2447355b3216f10b537e9afa7b64a4e5391b0d631172d07939e087a"
    )
    local longKey, longData = string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First"
    T.eq(
      "a key longer than the block is hashed first",
      C4:HMAC("SHA256", longKey, longData),
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
    )
    T.eq(
      "with SHA512's 128-byte block too",
      C4:HMAC("SHA512", longKey, longData),
      "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f352"
        .. "6b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598"
    )
  end
end

--------------------------------------------------------------------------------
T.section("C4:GetTemperatureScale")
--------------------------------------------------------------------------------

-- Measured on a dev controller: a Fahrenheit project answers "FAHRENHEIT", so
-- the whole word, not an initial, is what a driver has to normalize.
T.eq("defaults to the Celsius whole word", C4:GetTemperatureScale(), "CELSIUS")

ShimSetTemperatureScale("FAHRENHEIT")
T.eq("reports a scale a test set, as a whole word", C4:GetTemperatureScale(), "FAHRENHEIT")

ShimResetTemperatureScale()
T.eq("and resets back to the default", C4:GetTemperatureScale(), "CELSIUS")

--------------------------------------------------------------------------------
T.section("C4:AddEvent / C4:DeleteEvent / C4:FireEventByID")
--------------------------------------------------------------------------------

C4:AddEvent(7, "Button: press", "Fired on a press")
C4:AddEvent(8, "Button: long_press", "Fired on a long press")

T.eq("records a declared event by id", ShimEvents()[7].name, "Button: press")
T.eq("keeps its description", ShimEvents()[7].description, "Fired on a press")

-- Firing is one-way on a controller, so the shim accepts it and records nothing.
-- The assertion is that a driver firing an event does not disturb the
-- declarations, which is the half a test can read back.
C4:FireEventByID(7)
T.eq("firing leaves the declaration alone", ShimEvents()[7].name, "Button: press")

C4:DeleteEvent(7)
T.eq("delete removes it", ShimEvents()[7], nil)
T.eq("and leaves the others", ShimEvents()[8].name, "Button: long_press")

-- Measured on a controller: a nil in either position raises, a number does not.
T.raises("a nil name is refused", function()
  C4:AddEvent(9, nil, "Fired on a press")
end, "name should be a string")
T.raises("a nil description is refused", function()
  C4:AddEvent(9, "Button: press", nil)
end, "description should be a string")

-- Level 2, so the raise names the line that passed the nil. restoreEvents()
-- replays persisted records, and that caller is the one worth pointing at.
T.raisesAt("a rejected event blames the caller, not the shim", function()
  C4:AddEvent(9, nil, "Fired on a press")
end)

ShimResetEvents()
T.eq("reset clears every declaration", next(ShimEvents()), nil)

T.section("C4:ParseXml")
--------------------------------------------------------------------------------

-- The shape thermostatV2 hands a driver in SET_PRESETS: a list whose per-preset
-- field values ride as escaped XML inside an attribute.
local presetsXml = '<?xml version="1.0"?><!-- proxy --><presets>'
  .. '<preset name="Night" preset_fields="&lt;fields&gt;&lt;field id=&quot;setpoint_c&quot;&gt;20&lt;/field&gt;&lt;/fields&gt;"/>'
  .. "<preset name='Day &amp; Evening' previous_name=\"Day\"><note>kept</note></preset>"
  .. "</presets>"

local root = C4:ParseXml(presetsXml)
T.check("returns the root node", root ~= nil and root.Name == "presets", root and root.Name)
T.check("strips the prolog and comments", root ~= nil and #root.ChildNodes == 2, root and #root.ChildNodes)

local night = root and root.ChildNodes[1]
T.check("keeps child order", night ~= nil and night.Name == "preset" and night.Attributes.name == "Night")
T.check("a self-closing node has no children", night ~= nil and #night.ChildNodes == 0)
T.check(
  "unescapes an attribute so nested XML is re-parsable",
  night ~= nil and night.Attributes.preset_fields == '<fields><field id="setpoint_c">20</field></fields>',
  night and night.Attributes.preset_fields
)
local fields = night and C4:ParseXml(night.Attributes.preset_fields)
T.check("the nested XML parses in turn", fields ~= nil and fields.ChildNodes[1].Attributes.id == "setpoint_c")

local day = root and root.ChildNodes[2]
T.check(
  "single-quoted attributes and entities",
  day ~= nil and day.Attributes.name == "Day & Evening",
  day and day.Attributes.name
)
T.check("double-quoted attributes on the same node", day ~= nil and day.Attributes.previous_name == "Day")
T.check("child nodes of a paired tag", day ~= nil and #day.ChildNodes == 1 and day.ChildNodes[1].Name == "note")

local nested = C4:ParseXml("<a><a><b/></a><b/></a>")
T.check("same-name nesting closes at the matching depth", nested ~= nil and #nested.ChildNodes == 2)
T.check("the inner node keeps its own child", nested ~= nil and #nested.ChildNodes[1].ChildNodes == 1)

T.check("C4:ParseXml colon call works", C4:ParseXml("<x/>").Name == "x")
T.check("C4.ParseXml with C4 receiver works", C4.ParseXml(C4, "<x/>").Name == "x")
local ok, err = pcall(C4.ParseXml, "<x/>")
T.check("C4.ParseXml without a receiver raises as on Director", not ok and tostring(err):find("LuaC4Object expected"))
T.check("an empty string yields nil", C4:ParseXml("") == nil)
T.check("a number is accepted as its string form", C4:ParseXml(123) == nil)
ok, err = pcall(C4.ParseXml, C4, nil)
T.check("a nil argument raises as on Director", not ok and tostring(err):find("strXml should be a string"))

-- Text content tests
local soap = C4:ParseXml('<c4soap><param name="LEVEL">42</param><param name="MODE">HEAT</param></c4soap>')
local args = {}
for _, v in pairs(soap.ChildNodes) do
  args[v.Attributes.name] = v.Value
end
T.eq("text content exposed as Value (LEVEL)", args.LEVEL, "42")
T.eq("text content exposed as Value (MODE)", args.MODE, "HEAT")

-- Director sets Value on every node, "" when there is no text, so an empty
-- <param> reaches ReceivedFromProxy as a present key rather than a missing one.
-- Expectations below were measured on a controller.
local emptyParam = C4:ParseXml('<c4soap><param name="X"></param></c4soap>')
T.eq("an empty paired node has an empty Value", emptyParam.ChildNodes[1].Value, "")

local selfClose = C4:ParseXml("<x/>")
T.eq("a self-closing node has an empty Value", selfClose.Value, "")

local withChildren = C4:ParseXml("<a><b/></a>")
T.eq("a node with children has an empty Value", withChildren.Value, "")

local blank = C4:ParseXml("<a>  \n\t </a>")
T.eq("whitespace-only content collapses to an empty Value", blank.Value, "")

local mixed = C4:ParseXml("<a>lead<b/>tail</a>")
T.eq("mixed content keeps the first text run", mixed.Value, "lead")
T.eq("mixed content still yields the child", #mixed.ChildNodes, 1)
T.eq("text after a child is the Value when no text precedes it", C4:ParseXml("<a><b/>tail</a>").Value, "tail")

local cdata = C4:ParseXml("<a><![CDATA[x < y]]></a>")
T.eq("a CDATA section is the Value, unescaped", cdata.Value, "x < y")
T.eq("a CDATA section is not a child", #cdata.ChildNodes, 0)
T.eq("blank text before a CDATA section is skipped", C4:ParseXml("<a>  <![CDATA[x]]>  </a>").Value, "x")
T.eq("text before a CDATA section wins", C4:ParseXml("<a>x<![CDATA[<y>]]>z</a>").Value, "x")
T.eq("an unterminated CDATA section yields nil", C4:ParseXml("<a><![CDATA[x</a>"), nil)

local escaped = C4:ParseXml("<v>a &amp; b</v>")
T.eq("entity-unescaped text content", escaped.Value, "a & b")

T.eq("a mismatched close tag yields nil for the document", C4:ParseXml("<a><b></a>"), nil)
T.eq("an unquoted attribute value yields nil", C4:ParseXml("<a b=x/>"), nil)
T.eq("attributes without whitespace between them yield nil", C4:ParseXml('<a b="x"c="y"/>'), nil)
T.eq("a repeated attribute keeps the last value", C4:ParseXml('<a y="1" y="2"/>').Attributes.y, "2")

-- Quote-aware tag scanning tests
local quoteAttr = C4:ParseXml('<rule cond="a > b" other="z"/>')
T.check(
  "unescaped > in double-quoted attr",
  quoteAttr ~= nil and quoteAttr.Attributes.cond == "a > b" and quoteAttr.Attributes.other == "z"
)

local gtEntity = C4:ParseXml('<rule cond="a &gt; b"/>')
T.check("gt entity unescapes to >", gtEntity ~= nil and gtEntity.Attributes.cond == "a > b")

local multiline = C4:ParseXml('<a b="line1\nline2"/>')
T.eq("a newline in an attribute value normalizes to a space", multiline.Attributes.b, "line1 line2")

local pairedWithGt = C4:ParseXml('<r a=">"><c/></r>')
T.check(
  "paired tag with > in attr finds child",
  pairedWithGt ~= nil and #pairedWithGt.ChildNodes == 1 and pairedWithGt.ChildNodes[1].Name == "c"
)

-- Numeric character reference tests
local eacute = C4:ParseXml("<v>&#233;</v>")
T.eq("&#233; decodes to UTF-8 e-acute", eacute.Value, string.char(0xC3, 0xA9))

local rsquo = C4:ParseXml("<v>&#8217;</v>")
T.eq("&#8217; decodes to UTF-8 right single quote", rsquo.Value, string.char(0xE2, 0x80, 0x99))

local apos = C4:ParseXml("<v>&#x27;</v>")
T.eq("&#x27; decodes to '", apos.Value, "'")

local a = C4:ParseXml("<v>&#x41;</v>")
T.eq("&#x41; decodes to A", a.Value, "A")

local big = C4:ParseXml("<v>&#99999999;</v>")
T.eq("&#99999999; encodes to Director's four bytes", big.Value, string.char(0xFD, 0x9E, 0x83, 0xBF))

local surrogate = C4:ParseXml("<v>&#xD800;</v>")
T.eq("&#xD800; encodes to Director's three bytes", surrogate.Value, string.char(0xED, 0xA0, 0x80))

local zero = C4:ParseXml("<v>&#0;</v>")
T.eq("&#0; is dropped", zero.Value, "")

T.eq("a malformed reference stays literal", C4:ParseXml("<v>&#;</v>").Value, "&#;")

--------------------------------------------------------------------------------
T.section("C4:Base64Decode")
--------------------------------------------------------------------------------

-- Measured on 4.3.0. Deserialize reads every stored string through this, so a
-- lenient decode would hide a string lib/persist.lua cannot read back.
T.eq("decodes base64", C4:Base64Decode("eyJhIjoxfQ=="), '{"a":1}')
T.eq('a character outside the alphabet gives ""', C4:Base64Decode("Living Room"), "")
T.eq("so does a string shorter than one group", C4:Base64Decode("Den"), "")
T.eq("a trailing partial group is dropped", C4:Base64Decode("MTIzN"), "123")
T.eq("the input is trimmed", C4:Base64Decode(" MTIz "), "123")
T.eq("and cut at its first NUL", C4:Base64Decode("MTIz\0MTIz"), "123")
T.eq("a number is read as its digits", C4:Base64Decode(12345), "\215\109\248")
T.eq("so a fraction's point is outside the alphabet", C4:Base64Decode(12.5), "")
local function decodeError(...)
  return select(2, pcall(C4.Base64Decode, C4, ...))
end
T.eq("nil raises", decodeError(nil), "strDecode should be a string")
T.eq("so does a table", decodeError({}), "strDecode should be a string")
T.eq("and C4 itself, as an argument", decodeError(C4, "YQ=="), "strDecode should be a string")
T.eq("no argument at all", decodeError(), "Not enough arguments passed (expected 1: strDecode)")

local function hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end
for _, m in ipairs({
  -- Base64 with its padding.
  { "W10=", "5b5d" },
  { "YQ==", "61" },
  { "YWI=", "6162" },
  { "eyJhIjoxfQ==", "7b2261223a317d" },
  { "a+/b", "6befdb" },
  -- A partial last group is dropped, whatever it holds.
  { "", "" },
  { "1", "" },
  { "123", "" },
  { "W10", "" },
  { "YQ=", "" },
  { "1234", "d76df8" },
  { "65537", "eb9e77" },
  { "abcdefg", "69b71d" },
  { "YQ==abc", "61" },
  { "6553,", "eb9e77" },
  { "65537,", "eb9e77" },
  { "65537:1", "eb9e77" },
  { "65793:2", "eb9efd" },
  { "1234:5", "d76df8" },
  { "abcd:", "69b71d" },
  -- A whole group with a character outside the alphabet answers nothing at all.
  { "65537,65793", "" },
  { "65793:2,65537:1", "" },
  { "123,456", "" },
  { "1234:56789", "" },
  { "abcd,efgh", "" },
  { ",abcd", "" },
  { "abc!", "" },
  { "ab cd", "" },
  { "-_ab", "" },
  -- "=" inside a group reads as zero bits, and only the last group's padding trims it.
  { "=abc", "01a6dc" },
  { "ab=c", "69b01c" },
  { "abc=abcd", "69b70069b71d" },
  { "YQ==YQ==", "61000061" },
  { "a===", "68" },
  { "====", "00" },
  -- An EUI64, stored as a plain string.
  { "00124B0001CE4B21", "d34d76e01d34d35084e01db5" },
}) do
  T.eq(string.format("%q", m[1]), hex(C4:Base64Decode(m[1])), m[2])
end

--------------------------------------------------------------------------------
T.section("C4:PersistSetValue")
--------------------------------------------------------------------------------

-- Measured on 4.3.0.
C4:PersistSetValue("Nul", "a\0b")
ShimPersistLand()
T.eq("a string is cut at its first NUL", C4:PersistGetValue("Nul"), "a")
C4:PersistSetValue("NaN", 0 / 0)
ShimPersistLand()
T.eq("a NaN is stored as Director's text for it", C4:PersistGetValue("NaN"), '{":number:":null}')
C4:PersistSetValue("Plain", "x")
C4:PersistSetValue("Plain", "")
ShimPersistLand()
T.eq('a plain "" deletes the key', C4:PersistGetValue("Plain"), nil)
C4:PersistSetValue("Secret", "x", true)
C4:PersistSetValue("Secret", "", true)
ShimPersistLand()
T.eq('an encrypted "" leaves it as it was', C4:PersistGetValue("Secret", true), "x")
C4:PersistSetValue("Secret", "", false)
ShimPersistLand()
T.eq('a plain "" deletes an encrypted key', C4:PersistGetValue("Secret", true), nil)
C4:PersistSetValue("Secret", "y", true)
C4:PersistSetValue("Secret", "", false)
ShimPersistLand()
T.eq("and one still waiting, in order", C4:PersistGetValue("Secret", true), nil)
C4:PersistSetValue("Secret", "secretC", true)
ShimPersistLand()
local row = C4:PersistGetValue("Secret")
T.eq("an encrypted value reads back with the flag", C4:PersistGetValue("Secret", true), "secretC")
T.neq("and not without it", row, "secretC")
T.eq("which answers the row's base64", #C4:Base64Decode(row), 7)
C4:PersistSetValue("Copy", row, false)
ShimPersistLand()
T.eq("that text written plain reads back with the flag as the value", C4:PersistGetValue("Copy", true), "secretC")
C4:PersistSetValue("Plain", "plainK")
ShimPersistLand()
T.eq("an encrypted read of a plain value decrypts what its text decodes to", #C4:PersistGetValue("Plain", true), 3)
C4:PersistSetValue("Plain", "Den")
ShimPersistLand()
T.eq("and answers nothing when that is empty", C4:PersistGetValue("Plain", true), nil)
T.eq("an absent key answers no value at all", select("#", C4:PersistGetValue("Absent")), 0)

--------------------------------------------------------------------------------
T.section("A persist write lands later")
--------------------------------------------------------------------------------

-- Measured on 4.3.0: a write lands about 50 ms after the call.
C4:PersistSetValue("Later", "x")
T.eq("a write is not read back until it lands", C4:PersistGetValue("Later"), nil)
ShimPersistLand()
T.eq("then it is", C4:PersistGetValue("Later"), "x")
C4:PersistSetValue("Later", "y")
C4:PersistDeleteValue("Later")
T.eq("a delete is read back at once", C4:PersistGetValue("Later"), nil)
ShimPersistLand()
T.eq("and a write still waiting lands after it", C4:PersistGetValue("Later"), "y")
C4:PersistSetValue("Later", "a")
C4:PersistSetValue("Later", "b")
ShimPersistLand()
T.eq("writes land in the order they were made", C4:PersistGetValue("Later"), "b")

do
  local read
  C4:SetTimer(1000, function()
    read = C4:PersistGetValue("Later")
    C4:PersistSetValue("Later", "set by the timer")
  end)
  C4:PersistSetValue("Later", "c")
  ShimFireTimers()
  T.eq("ShimFireTimers lands the writes made before it", read, "c")
  T.eq("and one its callback makes waits", C4:PersistGetValue("Later"), "c")
end

C4:PersistSetValue("Later", "d")
ShimUpdateDriver()
T.eq("a driver update lands every write", C4:PersistGetValue("Later"), "d")
C4:PersistSetValue("Later", "e")
ShimRestartDirector()
T.eq("and so does a Director restart", C4:PersistGetValue("Later"), "e")

do
  local reloaded, reloadErr = F.withShim({ luasocket = true }, function(clock)
    C4:PersistSetValue("Later", "x")
    clock.advance(0.04)
    T.eq("by the clock, a write 40 ms old is not read back", C4:PersistGetValue("Later"), nil)
    clock.advance(0.02)
    T.eq("and one 60 ms old is", C4:PersistGetValue("Later"), "x")
  end)
  T.check("shim reload (with luasocket)", reloaded, reloadErr)
end

C4:PersistSetValue("Later", "z")
ShimPersistLater(false)
T.eq("ShimPersistLater(false) lands what waits", C4:PersistGetValue("Later"), "z")
C4:PersistSetValue("Later", "now")
T.eq("and has a write read back at once", C4:PersistGetValue("Later"), "now")
ShimPersistLater(true)
C4:PersistSetValue("Later", "later")
T.eq("ShimPersistLater(true) restores the default", C4:PersistGetValue("Later"), "now")
ShimPersistLand()

--------------------------------------------------------------------------------
T.section("C4:FileOpen / C4:FileWrite / C4:FileDelete")
--------------------------------------------------------------------------------

-- Measured on 4.3.0. FileOpen never truncates, which is why the vendored FileWrite
-- deletes a file before it overwrites it.
local fh = C4:FileOpen("shim.bin")
C4:FileWrite(fh, 6, "hello!")
C4:FileClose(fh)
fh = C4:FileOpen("shim.bin")
T.eq("a reopened file reads nothing from the end", C4:FileRead(fh, 100), "")
C4:FileSetPos(fh, 0)
C4:FileWrite(fh, 2, "XY")
C4:FileSetPos(fh, 0)
T.eq("a write lands at the position, over what is there", C4:FileRead(fh, 100), "XYllo!")
C4:FileClose(fh)
T.eq("FileDelete returns true when it deletes", C4:FileDelete("shim.bin"), true)
T.eq("the file is gone", C4:FileExists("shim.bin"), false)

--------------------------------------------------------------------------------
T.section("C4:GetDevices")
--------------------------------------------------------------------------------

-- Measured on 4.3.0, but for the empty filter, spaced names and proxies (the reference), a room's display name (as
-- GetDevice assumes) and hidden (the shim's transient failure). DeviceIds and C4iNames add up, which is why
-- lib/utils.lua GetDevice checks a driver itself.
ShimSetDevices({
  [10] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" },
  [20] = { deviceName = "Relay", driverFileName = "relaysingle_relay_c4.c4i", roomId = "10", roomName = "Kitchen" },
  [30] = {
    deviceName = "Lamp",
    driverFileName = "lamp.c4z",
    roomId = "10",
    roomName = "Kitchen",
    proxies = { [31] = { deviceName = "Lamp", driverFileName = "light_v2.c4i" } },
  },
  [31] = {
    deviceName = "Lamp",
    driverFileName = "light_v2.c4i",
    roomId = "10",
    roomName = "Kitchen",
    protocol = { [30] = { deviceName = "Lamp", driverFileName = "lamp.c4z" } },
  },
  [40] = { deviceName = "Porch Lamp", driverFileName = "lamp.c4z", roomId = "10", roomName = "Kitchen" },
})
local function listed(filter)
  local ids = {}
  for id in pairs(C4:GetDevices(filter)) do
    table.insert(ids, id)
  end
  table.sort(ids)
  return ids
end

T.eq("DeviceIds lists the ids asked for", listed({ DeviceIds = "20,31" }), { 20, 31 })
T.eq("C4iNames lists the devices of those drivers, not their proxies", listed({ C4iNames = "lamp.c4z" }), { 30, 40 })
T.eq("a name is trimmed of the space after a comma", listed({ C4iNames = "light_v2.c4i, lamp.c4z" }), { 30, 31, 40 })
T.eq("together they add up rather than narrow", listed({ DeviceIds = "20", C4iNames = "lamp.c4z" }), { 20, 30, 40 })
T.eq(
  "a proxy carries its protocol",
  (C4:GetDevices({ DeviceIds = "31" })[31] or {}).protocol,
  { [30] = { deviceName = "Lamp", driverFileName = "lamp.c4z" } }
)
T.eq(
  "and the protocol its proxies",
  (C4:GetDevices({ DeviceIds = "30" })[30] or {}).proxies,
  { [31] = { deviceName = "Lamp", driverFileName = "light_v2.c4i" } }
)
T.eq("a room is never listed", listed({ DeviceIds = "10", C4iNames = "roomdevice.c4i" }), {})
T.eq("though it has a display name", C4:GetDeviceDisplayName(10), "Kitchen")
T.eq("an empty filter lists every device", listed({}), { 20, 30, 31, 40 })
ShimSetDeviceHidden(20, true)
T.eq("a hidden device is not listed", listed({ DeviceIds = "20" }), {})
ShimResetDevices()

--------------------------------------------------------------------------------
T.section("Lua 5.1 library")
--------------------------------------------------------------------------------

-- Measured on 4.3.0: a test that calls table.unpack must fail here as it would there.
T.eq("table.unpack is absent", table.unpack, nil)

--------------------------------------------------------------------------------

T.finish()
