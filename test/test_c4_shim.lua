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
  -- Refusing an encoding is argument validation with no crypto in it, so it is
  -- asserted outside the backend gate below, where it is the only part of the
  -- contract a backend-less host can still observe. The one BASE64 hash caller
  -- in the vendored tree is module/websocket.lua:605, which no test reaches.
  local base64Digest, base64Err = C4:Hash("SHA1", "abc", { return_encoding = "BASE64" })
  T.falsy("BASE64 is refused rather than returned as hex", base64Digest)
  T.contains("and the reason names the encoding", base64Err, "BASE64")

  if not C4.SHIM_HAS_CRYPTO then
    -- Same shape as the lib/values.lua skip above: visible, so it cannot read as
    -- a pass, but not a failure, because a driver that never calls C4:Hash
    -- should not need libcrypto to run its suite. The template's own CI asserts
    -- the backend resolves, so the mock stays covered where it is developed.
    print("  skip no crypto backend on this host, digest and cipher assertions did not run")
  else
    T.eq("MD5 of abc", C4:Hash("MD5", "abc"), "900150983CD24FB0D6963F7D28E17F72")
    T.eq("SHA1 of abc", C4:Hash("SHA1", "abc"), "A9993E364706816ABA3E25717850C26C9CD0D89D")
    T.eq("SHA256 of abc", C4:Hash("SHA256", "abc"), "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
    T.eq(
      "SHA256 of the empty string",
      C4:Hash("SHA256", ""),
      "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
    )

    -- Hex is upper case and twice the digest length; drivers slice these by
    -- byte offset, so the width is part of the contract.
    T.check("hex is upper case", C4:Hash("SHA256", "abc"):upper() == C4:Hash("SHA256", "abc"))
    T.check("SHA256 hex is 64 chars", #C4:Hash("SHA256", "abc") == 64)

    -- return_encoding NONE gives the raw digest, which is what lib/klap.lua
    -- slices for its keys. Hex would silently double every offset.
    local raw = C4:Hash("SHA256", "abc", { return_encoding = "NONE" })
    T.check("NONE returns 32 raw bytes", #raw == 32, #raw)
    T.check("NONE is not the hex string", raw ~= C4:Hash("SHA256", "abc"))

    -- An unsupported digest returns nil plus a reason rather than a wrong hash.
    T.check("an unsupported algorithm returns nil", C4:Hash("SHA512", "abc") == nil)
    T.contains("and says which one", select(2, C4:Hash("SHA512", "abc")), "SHA512")

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

    -- Everything outside raw AES-128-CBC is refused rather than quietly
    -- mis-encrypted: SaltedEncrypt in global/lib.lua asks for AES-256-CBC with
    -- no iv, and a shim that guessed would hand back an unusable result.
    T.check("AES-256-CBC is refused", C4:Encrypt("AES-256-CBC", key, iv, "x") == nil)
    T.contains("and says why", select(2, C4:Encrypt("AES-256-CBC", key, iv, "x")), "AES-128-CBC")
    T.check("a key that is not 16 bytes is refused", C4:Encrypt("AES-128-CBC", "short", iv, "x") == nil)
    T.check("a nil iv is refused", C4:Encrypt("AES-128-CBC", key, nil, "x") == nil)
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

--------------------------------------------------------------------------------
T.section("C4:PersistSetValue")
--------------------------------------------------------------------------------

-- Measured on 4.3.0.
C4:PersistSetValue("Nul", "a\0b")
T.eq("a string is cut at its first NUL", C4:PersistGetValue("Nul"), "a")
C4:PersistSetValue("NaN", 0 / 0)
T.eq("a NaN is stored as Director's text for it", C4:PersistGetValue("NaN"), '{":number:":null}')
C4:PersistSetValue("Plain", "x")
C4:PersistSetValue("Plain", "")
T.eq('"" deletes a plain key', C4:PersistGetValue("Plain"), nil)
C4:PersistSetValue("Secret", "x", true)
C4:PersistSetValue("Secret", "", true)
T.eq("and leaves an encrypted one as it was", C4:PersistGetValue("Secret", true), "x")

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

T.finish()
