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

-- Ids come from a counter that a delete does not rewind. This is the behaviour
-- lib/values.lua works around: it restores hidden placeholders for deleted
-- values so the surviving ones keep their ids across a reset.
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

T.finish()
