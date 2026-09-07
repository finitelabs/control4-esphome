--- Shim layer to replace Control4-specific functions with native Lua equivalents
--- for debugging and testing outside the Control4 environment.
---
--- When luasocket is available, provides full networking and timer support.
--- Without luasocket, provides stubs sufficient for module loading and static analysis.

-- Try to load luasocket (optional dependency)
local has_socket, socket = pcall(require, "socket")

-- Lua 5.2+ compatibility: loadstring was removed in favor of load
if not loadstring then
  loadstring = load
end

-- Minimal lpack-compatible string.pack/string.unpack for the format codes the ZCL
-- codec uses (all little-endian); the '<' endian marker is accepted and ignored.
-- Signature AND code semantics match Control4's lpack, verified on a controller
-- (Lua 5.1): b unsigned8, c signed8 (NOT the 5.3 convention where b is signed),
-- h/H signed/unsigned16, i/I signed/unsigned32, l/L signed/unsigned long (4 bytes on
-- the 32-bit Directors; driver code uses i/I so the width is fixed across ILP32/LP64).
-- B is kept as an unsigned8 alias. This must track the controller, not the 5.3 stdlib
-- (which LuaJIT lacks anyway), or a test would agree with a driver bug instead of
-- catching it.
if not string.pack then
  local function packInt(v, size) -- signedness is irrelevant: two's-complement wrap below
    v = (v >= 0) and math.floor(v + 0.5) or math.ceil(v - 0.5) -- round half away from zero
    v = v % (2 ^ (8 * size))
    local out = {}
    for _ = 1, size do
      out[#out + 1] = string.char(v % 256)
      v = math.floor(v / 256)
    end
    return table.concat(out)
  end
  local function unpackInt(data, pos, size, signed)
    local v = 0
    for i = 0, size - 1 do
      v = v + string.byte(data, pos + i) * 2 ^ (8 * i)
    end
    if signed and v >= 2 ^ (8 * size - 1) then
      v = v - 2 ^ (8 * size)
    end
    return pos + size, v
  end
  local function packFloat(x)
    if x == 0 then
      return string.char(0, 0, 0, 0)
    end
    local sign = 0
    if x < 0 then
      sign = 0x80
      x = -x
    end
    local mant, expo = math.frexp(x) -- x = mant * 2^expo, 0.5 <= mant < 1
    expo = expo + 126 -- IEEE754 biased exponent (mant in [0.5,1) => 1.f = 2*mant)
    if expo <= 0 then
      -- Underflow: flush to zero. Denormals are out of scope (ZCL floats do not use
      -- them); unpackFloat still decodes them, so the pair is intentionally asymmetric.
      return string.char(0, 0, 0, sign)
    end
    mant = math.floor((mant * 2 - 1) * 2 ^ 23 + 0.5)
    if mant == 2 ^ 23 then
      -- Rounding carried the mantissa into the next binade (e.g. 255.999999): the
      -- implicit leading 1 must increment the exponent, not be masked off b3.
      mant = 0
      expo = expo + 1
    end
    if expo >= 255 then
      return string.char(0, 0, 0x80, sign + 0x7F)
    end
    local b1 = mant % 256
    local b2 = math.floor(mant / 256) % 256
    local b3 = math.floor(mant / 65536) % 128 + (expo % 2) * 128
    local b4 = math.floor(expo / 2) + sign
    return string.char(b1, b2, b3, b4)
  end
  local function unpackFloat(data, pos)
    local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
    local sign = (b4 >= 128) and -1 or 1
    local expo = (b4 % 128) * 2 + math.floor(b3 / 128)
    local mant = (b3 % 128) * 65536 + b2 * 256 + b1
    local v
    if expo == 0 then
      v = mant / 2 ^ 23 * 2 ^ -126
    elseif expo == 255 then
      v = (mant == 0) and math.huge or (0 / 0)
    else
      v = (1 + mant / 2 ^ 23) * 2 ^ (expo - 127)
    end
    return pos + 4, sign * v
  end
  -- code -> { size, signed }. b is UNSIGNED (lpack), c is signed8.
  local CODE = {
    b = { 1, false },
    B = { 1, false },
    c = { 1, true },
    h = { 2, true },
    H = { 2, false },
    i = { 4, true },
    I = { 4, false },
    l = { 4, true },
    L = { 4, false },
  }
  function string.pack(fmt, ...)
    local args, i, out = { ... }, 0, {}
    for c in fmt:gmatch(".") do
      if c == "<" or c == ">" or c == "=" then -- endian marker: ignore (LE)
      elseif c == "f" then
        i = i + 1
        out[#out + 1] = packFloat(args[i])
      elseif CODE[c] then
        i = i + 1
        out[#out + 1] = packInt(args[i], CODE[c][1])
      else
        error("shim string.pack: unsupported code '" .. c .. "'")
      end
    end
    return table.concat(out)
  end
  function string.unpack(data, fmt, pos)
    pos = pos or 1
    local out = {}
    for c in fmt:gmatch(".") do
      if c == "<" or c == ">" or c == "=" then
      elseif c == "f" then
        local v
        pos, v = unpackFloat(data, pos)
        out[#out + 1] = v
      elseif CODE[c] then
        local v
        pos, v = unpackInt(data, pos, CODE[c][1], CODE[c][2])
        out[#out + 1] = v
      else
        error("shim string.unpack: unsupported code '" .. c .. "'")
      end
    end
    return pos, (table.unpack or unpack)(out)
  end
end

-- Global C4 object shim
C4 = {}
Properties = {}
Variables = {}

-- Stub C4 functions that are called but not needed for testing
function C4:GetDeviceID()
  return 12345
end
function C4:GetDeviceData(deviceId, key)
  if key == "name" then
    return "Test Device"
  end
  return nil
end
function C4:AllowExecute() end
function C4:UpdateProperty() end
function C4:SetPropertyAttribs() end
-- url.lua parses .version at load time; a non-numeric stub selects the pre-OS-3.0 path.
function C4:GetVersionInfo()
  return { version = "4.2.1.757028-res", builddate = "2026-06-11", buildtime = "23:35:14", buildtype = "" }
end
-- Returns the running driver's filename, extension included.
function C4:GetDriverFileName()
  return "example.c4z"
end
-- Mirrors the controller: C4Z_ROOT errors until unlocked with the key below, and
-- every other argument is a no-op.
local FILE_SET_DIR_UNLOCK_KEY = "c29tZXNwZWNpYWxrZXk=++11"
local c4zRootUnlocked = false
function C4:FileSetDir(dir)
  if dir == FILE_SET_DIR_UNLOCK_KEY then
    c4zRootUnlocked = true
  elseif dir == "C4Z_ROOT" and not c4zRootUnlocked then
    error("Invalid alias: C4Z_ROOT", 2)
  end
end
function C4:SendToDevice() end
function C4:SendToProxy() end

---------------------------------------------------------------------------
-- Network bindings
-- Recorded rather than dropped, so a test can assert what a driver opened and
-- sent without defining these itself. C4:GetBindingAddress is the controller's
-- own accessor for the address; the frame log has no controller equivalent, so
-- ShimSentFrames stands in and is named to be unmistakable.
---------------------------------------------------------------------------

local binding_address = {}
local binding_port = {}
local sent_frames = {}

function C4:CreateNetworkConnection(binding, host, _type)
  binding_address[binding] = host
end

function C4:GetBindingAddress(binding)
  return binding_address[binding] or ""
end

-- Deliberately a no-op: the controller re-resolves the host and re-populates
-- the address, so clearing it here would model a slot being freed that is not.
function C4:SetBindingAddress() end

function C4:NetPortOptions(binding, port, _type, _options)
  binding_port[binding] = port
end

function C4:NetConnect() end
function C4:NetDisconnect() end

function C4:SendToNetwork(binding, port, data)
  sent_frames[#sent_frames + 1] = { binding = binding, port = port, data = data }
end

--- @return table frames Every frame passed to C4:SendToNetwork, in order.
function ShimSentFrames()
  return sent_frames
end

--- @return table addresses, table ports Keyed by binding id.
function ShimNetworkBindings()
  return binding_address, binding_port
end

local function clear(t)
  for k in pairs(t) do
    t[k] = nil
  end
end

--- Clear the recorded bindings, leaving the frame log alone. Separate from
--- ShimResetSentFrames because a test that frees bindings mid-run is usually
--- still counting frames across that point. Cleared in place so a table a test
--- already holds stays the live one.
function ShimResetBindings()
  clear(binding_address)
  clear(binding_port)
end

--- Clear the recorded frames.
function ShimResetSentFrames()
  clear(sent_frames)
end

---------------------------------------------------------------------------
-- Dynamic bindings and the connections between them
-- Shapes and return values were measured on a controller; where the
-- DriverWorks reference disagrees it is noted at the method. CONTROL and PROXY
-- surface as type 1 and 2, and removing a binding also drops its connections.
---------------------------------------------------------------------------

--- @type table<integer, table>
local dynamic_bindings = {}

--- The driver.xml <connections>, which the get methods return alongside the
--- dynamic ones.
--- @type table<integer, table>
local static_bindings = {}

--- The same connections as driver.xml declares them, behind
--- C4:GetDriverConfigInfo. Separate from the live records above because a
--- controller keeps listing a connection here after the live binding is gone.
--- @type table<integer, table>
local static_manifest = {}

--- @type { provider: integer, providerBinding: integer, consumer: integer, consumerBinding: integer, class: string }[]
local connections = {}

local BINDING_TYPE_IDS = { CONTROL = 1, PROXY = 2 }

function C4:AddDynamicBinding(idBinding, strType, bIsProvider, strName, strClass, bHidden, bAutoBind)
  dynamic_bindings[idBinding] = {
    id = idBinding,
    type = strType,
    provider = bIsProvider,
    name = strName,
    class = strClass,
    hidden = bHidden or false,
    autoBind = bAutoBind or false,
  }
end

local function resolveDeviceId(deviceId)
  deviceId = tonumber(deviceId)
  if deviceId == 0 then
    return tonumber(C4:GetDeviceID())
  end
  return deviceId
end

local function dropConnections(matches)
  for i = #connections, 1, -1 do
    if matches(connections[i]) then
      table.remove(connections, i)
    end
  end
end

--- A controller removes a static driver.xml connection as readily as a dynamic one.
function C4:RemoveDynamicBinding(idBinding)
  dynamic_bindings[idBinding] = nil
  static_bindings[idBinding] = nil
  local me = tonumber(C4:GetDeviceID())
  dropConnections(function(c)
    return (c.provider == me and c.providerBinding == idBinding)
      or (c.consumer == me and c.consumerBinding == idBinding)
  end)
end

function C4:Bind(idDeviceProvider, idBindingProvider, idDeviceConsumer, idBindingConsumer, strClass)
  local provider, consumer = resolveDeviceId(idDeviceProvider), resolveDeviceId(idDeviceConsumer)
  for _, c in ipairs(connections) do
    if
      c.provider == provider
      and c.providerBinding == idBindingProvider
      and c.consumer == consumer
      and c.consumerBinding == idBindingConsumer
    then
      return
    end
  end
  connections[#connections + 1] = {
    provider = provider,
    providerBinding = idBindingProvider,
    consumer = consumer,
    consumerBinding = idBindingConsumer,
    class = strClass,
  }
end

function C4:Unbind(idDeviceConsumer, idBindingConsumer)
  local consumer = resolveDeviceId(idDeviceConsumer)
  dropConnections(function(c)
    return c.consumer == consumer and c.consumerBinding == idBindingConsumer
  end)
end

local function boundPeer(deviceId, bindingId, class)
  return {
    bindingid = bindingId,
    deviceid = deviceId,
    name = C4:GetDeviceDisplayName(deviceId) or ("Device " .. tostring(deviceId)),
    boundclasses = { class },
  }
end

local function bindingRecord(deviceId, binding)
  local record = {
    bindingid = binding.id,
    deviceid = deviceId,
    name = binding.name,
    provider = binding.provider == true,
    type = BINDING_TYPE_IDS[binding.type] or binding.type,
    bindingclasses = {
      { class = binding.class, rank = 0, autobind = binding.autoBind == true, excludeids = {} },
    },
    isbound = false,
    flags = 0,
    binding_info = "",
  }
  for _, c in ipairs(connections) do
    if record.provider and c.provider == deviceId and c.providerBinding == binding.id then
      record.isbound = true
      record.boundconsumers = record.boundconsumers or {}
      record.boundconsumers[#record.boundconsumers + 1] = boundPeer(c.consumer, c.consumerBinding, c.class)
    elseif not record.provider and c.consumer == deviceId and c.consumerBinding == binding.id then
      record.isbound = true
      record.boundprovider = { bound = boundPeer(c.provider, c.providerBinding, c.class) }
    end
  end
  return record
end

--- Device 0 is deliberately not resolved: the reference says it means the
--- current device here, a controller returns nothing for it.
function C4:GetBindingsByDevice(deviceId)
  local bindings = {}
  if tonumber(deviceId) == tonumber(C4:GetDeviceID()) then
    for _, source in ipairs({ static_bindings, dynamic_bindings }) do
      for _, binding in pairs(source) do
        bindings[#bindings + 1] = bindingRecord(tonumber(deviceId), binding)
      end
    end
    table.sort(bindings, function(a, b)
      return a.bindingid < b.bindingid
    end)
  end
  return { bindings = bindings }
end

--- @return table|nil devices The bound consumers as { [deviceId] = name }. Nil,
--- not an empty table, when unbound.
function C4:GetBoundConsumerDevices(deviceId, bindingId)
  deviceId = resolveDeviceId(deviceId)
  local devices, found = {}, false
  for _, c in ipairs(connections) do
    if c.provider == deviceId and c.providerBinding == bindingId then
      devices[c.consumer] = C4:GetDeviceDisplayName(c.consumer) or ("Device " .. tostring(c.consumer))
      found = true
    end
  end
  if not found then
    return nil
  end
  return devices
end

--- @return integer deviceId The providing device, 0 when unbound. A device id,
--- not the id/name table the reference documents. Asked about a bound provider
--- binding, a controller answers with the querying device itself.
function C4:GetBoundProviderDevice(deviceId, bindingId)
  deviceId = resolveDeviceId(deviceId)
  for _, c in ipairs(connections) do
    if c.consumer == deviceId and c.consumerBinding == bindingId then
      return c.provider
    end
    if c.provider == deviceId and c.providerBinding == bindingId then
      return deviceId
    end
  end
  return 0
end

--- @param section string A driver.xml section. Only "connections" is modelled.
--- @return string|nil xml The section as XML.
function C4:GetDriverConfigInfo(section)
  if section ~= "connections" then
    return nil
  end
  local ids = {}
  for id in pairs(static_manifest) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local out = { "<connections>" }
  for _, id in ipairs(ids) do
    local connection = static_manifest[id]
    out[#out + 1] = string.format(
      "<connection><id>%d</id><facing>6</facing><connectionname>%s</connectionname>"
        .. "<type>%d</type><consumer>%s</consumer>"
        .. "<classes><class><classname>%s</classname></class></classes></connection>",
      id,
      connection.name or "",
      BINDING_TYPE_IDS[connection.type] or 0,
      connection.provider and "False" or "True",
      connection.class or ""
    )
  end
  out[#out + 1] = "</connections>"
  return table.concat(out)
end

--- @return table bindings Every live dynamic binding, keyed by binding id.
function ShimDynamicBindings()
  return dynamic_bindings
end

--- @return table connections Every live connection, in the order Bind made them.
function ShimConnections()
  return connections
end

--- Seed the driver.xml <connections>, as { id, type, provider, name, class } records.
function ShimSetStaticBindings(bindings)
  clear(static_bindings)
  clear(static_manifest)
  for _, binding in pairs(bindings or {}) do
    static_bindings[binding.id] = binding
    static_manifest[binding.id] = binding
  end
end

--- Clear the recorded dynamic bindings and their connections, in place so a
--- table a test already holds stays the live one.
function ShimResetDynamicBindings()
  clear(dynamic_bindings)
  clear(connections)
end

function C4:SendUIRequest()
  return ""
end
function C4:RegisterVariableListener() end
function C4:UnregisterVariableListener() end
function C4:UnregisterAllVariableListeners() end
function C4:RegisterDeviceEvent() end
function C4:UnregisterDeviceEvent() end
function C4:FileExists()
  return false
end
function C4:FileOpen()
  return nil
end
function C4:FileGetSize()
  return 0
end
function C4:FileSetPos() end
function C4:FileRead()
  return ""
end
function C4:FileClose() end
function C4:FileDelete() end
function C4:FileWrite()
  return 0
end

--- Logging functions for C4 compatibility
function C4:ErrorLog(message)
  io.stderr:write(message .. "\n")
  io.stderr:flush()
end

function C4:DebugLog(message)
  print(message)
end

--- Base64 encoding/decoding
local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode_impl(data)
  if type(data) ~= "string" then
    return nil
  end
  return (
    (data:gsub(".", function(x)
      local r, b = "", x:byte()
      for i = 8, 1, -1 do
        r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
      if #x < 6 then
        return ""
      end
      local c = 0
      for i = 1, 6 do
        c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
      end
      return base64_chars:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1]
  )
end

local function base64_decode_impl(data)
  if type(data) ~= "string" then
    error("Invalid base64 data type")
  end
  data = string.gsub(data, "[^" .. base64_chars .. "=]", "")
  return (
    data
      :gsub(".", function(x)
        if x == "=" then
          return ""
        end
        local r, f = "", (base64_chars:find(x) - 1)
        for i = 6, 1, -1 do
          r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return r
      end)
      :gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then
          return ""
        end
        local c = 0
        for i = 1, 8 do
          c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
        end
        return string.char(c)
      end)
  )
end

-- Handle both C4:Base64Encode() and C4.Base64Encode(C4, ...) calling styles
function C4:Base64Encode(data, ...)
  if type(data) == "table" and data == C4 then
    local realData = select(1, ...)
    return base64_encode_impl(realData)
  else
    return base64_encode_impl(data)
  end
end

-- Handle both C4:Base64Decode() and C4.Base64Decode(C4, ...) calling styles
function C4:Base64Decode(data, ...)
  -- If called as C4.Base64Decode(C4, data), first arg is C4
  -- If called as C4:Base64Decode(data), first arg is data
  if type(data) == "table" and data == C4 then
    -- Called as C4.Base64Decode(C4, data) - get the real data argument
    local realData = select(1, ...)
    return base64_decode_impl(realData)
  else
    -- Called as C4:Base64Decode(data)
    return base64_decode_impl(data)
  end
end

---------------------------------------------------------------------------
-- Color conversions (C4:ColorHSVtoRGB, C4:ColorRGBtoHSV)
-- Pure-Lua ports matching the on-controller behavior, verified against a
-- CA-1 running OS 3.4: RGB is on the 0-255 scale (float, unrounded), HSV is
-- h 0-360 / s 0-100 / v 0-100. E.g. ColorHSVtoRGB(120, 75, 100) returns
-- (63.75, 255, 63.75); ColorRGBtoHSV(64, 255, 64) returns (120, 74.902, 100).
---------------------------------------------------------------------------

function C4:ColorHSVtoRGB(h, s, v)
  local sf, vf = (s or 0) / 100, (v or 0) / 100
  local c = vf * sf
  local hh = ((h or 0) / 60) % 6
  local x = c * (1 - math.abs((hh % 2) - 1))
  local m = vf - c
  local r, g, b = 0, 0, 0
  if hh < 1 then
    r, g, b = c, x, 0
  elseif hh < 2 then
    r, g, b = x, c, 0
  elseif hh < 3 then
    r, g, b = 0, c, x
  elseif hh < 4 then
    r, g, b = 0, x, c
  elseif hh < 5 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  return (r + m) * 255, (g + m) * 255, (b + m) * 255
end

function C4:ColorRGBtoHSV(r, g, b)
  r, g, b = (r or 0) / 255, (g or 0) / 255, (b or 0) / 255
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then
      h = 60 * (((g - b) / d) % 6)
    elseif mx == g then
      h = 60 * ((b - r) / d + 2)
    else
      h = 60 * ((r - g) / d + 4)
    end
  end
  if h < 0 then
    h = h + 360
  end
  local s = mx > 0 and (d / mx) * 100 or 0
  return h, s, mx * 100
end

--- Generate a UUID (simplified version)
local uuid_counter = 0
function C4:UUID(prefix)
  uuid_counter = uuid_counter + 1
  return string.format("%s-%d-%d", prefix or "UUID", os.time(), uuid_counter)
end

---------------------------------------------------------------------------
-- Variables
-- Mirrors the controller rather than accommodating callers: values are always
-- strings, updates are synchronous, and nothing is coerced or auto-created.
-- test/test_c4_shim.lua pins each behaviour, measured on a dev controller.
---------------------------------------------------------------------------

-- Accepted on hardware. The controller's error message names only four types.
-- Each maps to the code C4:GetDeviceVariables reports, measured one varType at
-- a time: NUMBER and INT share 2, and nothing observed reports 7.
local var_type_codes = {
  STRING = 1,
  INT = 2,
  NUMBER = 2,
  FLOAT = 3,
  BOOL = 4,
  LEVEL = 5,
  STATE = 6,
  TIME = 8,
  ROOM = 9,
  MEDIA = 10,
  LIST = 11,
  ULONG = 12,
  XML = 13,
  DEVICE = 14,
}

-- Director numbers each device's variables from 1001 and never reuses an id, so
-- a deleted name returns at the end of the range. lib/values.lua restores hidden
-- placeholders to keep that range stable, which is what makes ids worth modelling.
local next_variable_id = 1001

--- Id and attributes per variable name, behind C4:GetDeviceVariables. The value
--- is read from Variables at call time so a SetVariable needs no bookkeeping here.
--- @type table<string, { id: string, type: string, readonly: string, hidden: string }>
local variable_meta = {}

-- Strings and numbers only; nil means the controller would reject the value.
local function var_value(value)
  if type(value) == "string" then
    return value
  elseif type(value) == "number" then
    return tostring(value)
  end
end

-- Checks run in the controller's order: the value, then that varType is a
-- string, then the existing-name return, and only then whether varType names a
-- real type. An existing name returns false without ever validating varType.
function C4:AddVariable(name, value, varType, readOnly, hidden)
  local strValue = var_value(value)
  if strValue == nil then
    error("strValue should be a string", 2)
  end
  if type(varType) ~= "string" then
    error("strVarType should be a string", 2)
  end

  name = tostring(name)

  -- Already present: the controller keeps the existing value and type
  if Variables[name] ~= nil then
    return false
  end

  if not var_type_codes[varType] then
    error("Invalid variable type.  Valid types include: BOOL, LEVEL, NUMBER, STRING.", 2)
  end

  Variables[name] = strValue
  variable_meta[name] = {
    id = tostring(next_variable_id),
    type = tostring(var_type_codes[varType]),
    readonly = readOnly == true and "True" or "False",
    hidden = hidden == true and "True" or "False",
  }
  next_variable_id = next_variable_id + 1
  return true
end

-- The value is checked before the name is looked up, so a bad value raises even
-- on a name that was never added.
function C4:SetVariable(name, value)
  local strValue = var_value(value)
  if strValue == nil then
    error("strValue should be a string", 2)
  end
  name = tostring(name)

  -- Never added: silently does nothing, and does not create it
  if Variables[name] == nil then
    return
  end

  Variables[name] = strValue
end

function C4:DeleteVariable(name)
  name = tostring(name)
  Variables[name] = nil
  variable_meta[name] = nil
end

-- Keyed by id as a string, with every field a string: `type` is a numeric code,
-- `readonly` and `hidden` are "True"/"False", and `description` is always empty
-- because AddVariable cannot set one. A device with no variables and a device
-- that does not exist both give an empty table, and hidden variables are
-- returned rather than filtered out.
---------------------------------------------------------------------------
-- Project temperature scale
-- The controller answers with the whole word, "CELSIUS" or "FAHRENHEIT", never
-- an initial, so a driver that never normalizes still reads as correct against
-- an initial. Celsius by default because callers idiomatically end `... or "F"`:
-- under a Fahrenheit default that yields "F" whether their normalization works
-- or not, and the test cannot tell the two apart.
---------------------------------------------------------------------------

local DEFAULT_TEMPERATURE_SCALE = "CELSIUS"
local temperature_scale = DEFAULT_TEMPERATURE_SCALE

function C4:GetTemperatureScale()
  return temperature_scale
end

--- Harness, not a controller API: C4 is userdata on a controller, so assigning
--- the scale there raises rather than taking effect. Named to be unmistakable.
function ShimSetTemperatureScale(scale)
  temperature_scale = scale
end

--- Restore the default. A scale a test leaves set carries into every later test
--- in the process, and under Fahrenheit a scale assertion can no longer fail.
function ShimResetTemperatureScale()
  temperature_scale = DEFAULT_TEMPERATURE_SCALE
end

---------------------------------------------------------------------------
-- Project devices
-- C4:GetDevices / GetDeviceDisplayName / GetDeviceVariables read a registry a
-- test populates with ShimSetDevices. An id absent from it is the nameless,
-- unresolvable case: GetDeviceDisplayName returns no value (arity 0, not nil),
-- which is what the controller does and what a driver must tolerate.
---------------------------------------------------------------------------

--- @type table<number, table>
local shim_devices = {}

--- @param devices table<number, table> id -> { deviceName?, driverFileName?, roomId?, roomName?, variables?, hidden? }
function ShimSetDevices(devices)
  shim_devices = devices or {}
end

function ShimResetDevices()
  shim_devices = {}
end

--- Take a device out of every lookup, modelling a transient resolution failure.
function ShimSetDeviceHidden(deviceId, hidden)
  local device = shim_devices[tonumber(deviceId)]
  if device then
    device.hidden = hidden and true or nil
  end
end

function C4:GetDevices(filter)
  local deviceId = tonumber(filter and filter.DeviceIds)
  local device = deviceId ~= nil and shim_devices[deviceId] or nil
  if device == nil or device.hidden then
    return {}
  end
  if filter.C4iNames ~= nil then
    local matched = false
    for c4iName in string.gmatch(filter.C4iNames, "([^,]+)") do
      if c4iName == device.driverFileName then
        matched = true
        break
      end
    end
    if not matched then
      return {}
    end
  end
  return { [deviceId] = device }
end

function C4:GetDeviceDisplayName(deviceId)
  local device = shim_devices[tonumber(deviceId)]
  if device and not device.hidden and device.deviceName ~= nil then
    return device.deviceName
  end
  -- Absent or nameless: return no value, matching the controller.
end

function C4:GetDeviceVariables(deviceId)
  local device = shim_devices[tonumber(deviceId)]
  if device and device.variables then
    return device.variables
  end
  -- The running driver's own variables, as created through C4:AddVariable.
  local variables = {}
  if tonumber(deviceId) == tonumber(C4:GetDeviceID()) then
    for name, meta in pairs(variable_meta) do
      variables[meta.id] = {
        name = name,
        description = "",
        value = Variables[name],
        type = meta.type,
        readonly = meta.readonly,
        hidden = meta.hidden,
      }
    end
  end
  return variables
end

-- The C4:Persist* SDK methods, backed by an in-memory store. The bare
-- PersistGetValue/SetValue/DeleteValue globals belong to global/lib.lua, whose
-- wrappers delegate here when C4.PersistSetValue exists; stubbing the globals
-- instead would be paved over the moment any module requires global.lib.
local persist_store = {}

function C4:PersistGetValue(key, encrypted)
  return persist_store[key]
end

function C4:PersistSetValue(key, value, encrypted)
  persist_store[key] = value
end

function C4:PersistDeleteValue(key)
  persist_store[key] = nil
end

---------------------------------------------------------------------------
-- Timer handles
-- A controller returns userdata from C4:SetTimer, and global/timer.lua only
-- resolves a handle when `type(timerId) == "userdata"`, so a table handle
-- makes every CancelTimer a silent no-op under test. newproxy(true) is the
-- only way to mint userdata from Lua; LuaJIT keeps it.
---------------------------------------------------------------------------

local timer_handle_count = 0

--- @param cancel fun(): nil Invoked by handle:Cancel().
--- @return userdata handle A stand-in for the controller's C4LuaTimer.
local function new_timer_handle(cancel)
  timer_handle_count = timer_handle_count + 1
  local serial = timer_handle_count
  local handle = newproxy(true)
  local mt = getmetatable(handle)
  mt.__index = {
    Cancel = function()
      cancel()
      -- Returns nil, so global/timer.lua clears its slot on cancel
      return nil
    end,
  }
  -- Distinct per handle, like the controller's address-bearing rendering
  mt.__tostring = function()
    return string.format("C4LuaTimer (shim #%d)", serial)
  end
  return handle
end

---------------------------------------------------------------------------
-- Socket-dependent features (timers, TCP client, event loop)
-- Only available when luasocket is installed.
---------------------------------------------------------------------------

local timers = {}
local timer_id = 0

local function clock()
  return has_socket and socket.gettime() or 0
end

function C4:SetTimer(delay_ms, callback, repeating)
  timer_id = timer_id + 1
  local id = timer_id

  local handle = new_timer_handle(function()
    if timers[id] then
      timers[id].cancelled = true
      timers[id] = nil
    end
  end)

  timers[id] = {
    id = id,
    delay = delay_ms / 1000,
    callback = callback,
    repeating = repeating or false,
    next_fire = clock() + (delay_ms / 1000),
    cancelled = false,
    handle = handle,
  }
  return handle
end

--- Fire whatever the clock says is due. Without luasocket there is no clock, so
--- nothing is ever due and ShimFireTimers is the only way to drive a timer.
function C4:ProcessTimers()
  if not has_socket then
    return
  end
  local now = socket.gettime()
  for id, timer in pairs(timers) do
    if not timer.cancelled and now >= timer.next_fire then
      timer.callback(timer.handle, 0)
      if timer.repeating then
        timer.next_fire = now + timer.delay
      else
        timers[id] = nil
      end
    end
  end
end

--- Harness, not a controller API: fire every pending timer now regardless of its
--- delay, so a test can drive a long timeout without waiting for it. Works on
--- both branches, which is what lets a test avoid defining its own SetTimer.
--- The slot is cleared before the callback runs, so a callback that re-arms the
--- same timer is not immediately fired again.
function ShimFireTimers()
  local due = {}
  for id, timer in pairs(timers) do
    if not timer.cancelled then
      due[id] = timer
    end
  end
  for id, timer in pairs(due) do
    if timers[id] then
      if timer.repeating then
        timer.next_fire = clock() + timer.delay
      else
        timers[id] = nil
      end
      timer.callback(timer.handle, 0)
    end
  end
end

if has_socket then
  --- TCP Client implementation
  local TCPClient = {}
  TCPClient.__index = TCPClient

  local active_clients = {}
  local client_id_counter = 0

  function C4:CreateTCPClient()
    client_id_counter = client_id_counter + 1
    local client = {
      id = client_id_counter,
      socket = nil,
      on_connect = nil,
      on_disconnect = nil,
      on_error = nil,
      on_read = nil,
      connected = false,
    }
    setmetatable(client, TCPClient)
    active_clients[client.id] = client
    return client
  end

  function TCPClient:OnConnect(callback)
    self.on_connect = callback
    return self
  end

  function TCPClient:OnDisconnect(callback)
    self.on_disconnect = callback
    return self
  end

  function TCPClient:OnError(callback)
    self.on_error = callback
    return self
  end

  function TCPClient:OnRead(callback)
    self.on_read = callback
    return self
  end

  function TCPClient:Connect(host, port)
    self.socket = socket.tcp()
    if not self.socket then
      if self.on_error then
        self.on_error(self, -1, "Failed to create socket")
      end
      return nil
    end

    self.socket:settimeout(5)
    local success, err = self.socket:connect(host, port)

    if not success then
      if self.on_error then
        self.on_error(self, -1, err or "Connection failed")
      end
      return nil
    end

    self.socket:settimeout(0)
    self.connected = true

    if self.on_connect then
      C4:SetTimer(10, function()
        if self.on_connect then
          self.on_connect(self)
        end
      end, false)
    end

    return self
  end

  function TCPClient:Close()
    if self.socket then
      self.socket:close()
      self.socket = nil
    end
    self.connected = false
    if self.id then
      active_clients[self.id] = nil
    end
    if self.on_disconnect then
      self.on_disconnect(self)
    end
  end

  function TCPClient:Write(data)
    if not self.socket then
      return false
    end
    local sent, err = self.socket:send(data)
    if not sent then
      if self.on_error then
        self.on_error(self, -1, err or "Write failed")
      end
      return false
    end
    return true
  end

  function TCPClient:ReadUpTo(max_bytes)
    if not self.socket then
      return
    end
    self.want_read = true
    self.max_read_bytes = max_bytes
  end

  function TCPClient:DoRead()
    if not self.socket or not self.want_read then
      return
    end
    local data, err, partial = self.socket:receive(self.max_read_bytes or 4096)
    if data and #data > 0 then
      if self.on_read then
        self.on_read(self, data)
      end
    elseif partial and #partial > 0 then
      if self.on_read then
        self.on_read(self, partial)
      end
    elseif err and err ~= "timeout" and err ~= "wantread" then
      if self.on_error then
        self.on_error(self, -1, err)
      end
      self:Close()
    end
  end

  function ShimSleep(seconds)
    socket.sleep(seconds)
  end

  function ShimProcessEventLoop()
    C4:ProcessTimers()
    for _, client in pairs(active_clients) do
      if client.DoRead then
        client:DoRead()
      end
    end
  end

  --- Run the event loop until os.exit() or signal.
  function ShimRunEventLoop()
    while true do
      ShimProcessEventLoop()
      socket.sleep(0.01)
    end
  end
else
  function C4:CreateTCPClient()
    return setmetatable({}, {
      __index = function()
        return function() end
      end,
    })
  end

  function ShimSleep() end
  function ShimProcessEventLoop() end
  function ShimRunEventLoop() end
end

-- Mirrors the controller rather than accommodating callers. Measured on a dev
-- controller: C4:SetTimer returns userdata carrying :Cancel(), C4:AddTimer
-- returns a number, and C4:KillTimer takes that number. Passing a SetTimer
-- handle raises "idTimer should be a number", so this does too: a shim that
-- accepted it would let a call that fails on hardware pass in tests.
function C4:KillTimer(idTimer)
  if type(idTimer) ~= "number" then
    error("idTimer should be a number", 2)
  end
end

---------------------------------------------------------------------------
-- Crypto (C4:Hash, C4:Encrypt, C4:Decrypt)
-- Backed by CommonCrypto (macOS) or libcrypto (Linux) via LuaJIT FFI.
-- Unavailable under plain Lua (gen-squishy); calls then return nil + error.
---------------------------------------------------------------------------

local has_ffi, ffi = pcall(require, "ffi")
local crypto_backend = nil

if has_ffi then
  if ffi.os == "OSX" then
    local ok = pcall(function()
      ffi.cdef([[
        unsigned char *CC_MD5(const void *data, uint32_t len, unsigned char *md);
        unsigned char *CC_SHA1(const void *data, uint32_t len, unsigned char *md);
        unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *md);
        int CCCrypt(uint32_t op, uint32_t alg, uint32_t options,
                    const void *key, size_t keyLength, const void *iv,
                    const void *dataIn, size_t dataInLength,
                    void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved);
      ]])
    end)
    if ok then
      local C = ffi.C
      local digests = {
        MD5 = { fn = C.CC_MD5, len = 16 },
        SHA1 = { fn = C.CC_SHA1, len = 20 },
        SHA256 = { fn = C.CC_SHA256, len = 32 },
      }
      crypto_backend = {
        hash = function(algorithm, data)
          local digest = digests[string.upper(algorithm)]
          if not digest then
            return nil, "unsupported hash: " .. tostring(algorithm)
          end
          local buf = ffi.new("unsigned char[?]", digest.len)
          digest.fn(data, #data, buf)
          return ffi.string(buf, digest.len)
        end,
        -- AES-128-CBC with PKCS7 padding (kCCAlgorithmAES128=0, kCCOptionPKCS7Padding=1)
        aes128cbc = function(encrypt, key, iv, data)
          local outLen = #data + 16
          local buf = ffi.new("unsigned char[?]", outLen)
          local moved = ffi.new("size_t[1]")
          local status = C.CCCrypt(encrypt and 0 or 1, 0, 1, key, 16, iv, data, #data, buf, outLen, moved)
          if status ~= 0 then
            return nil, "CCCrypt failed: " .. tonumber(status)
          end
          return ffi.string(buf, tonumber(moved[0]))
        end,
      }
    end
  else
    -- ffi.load("crypto") resolves "libcrypto.so", which ships in libssl-dev
    -- rather than the runtime package, so the bare name misses on a stock
    -- host (including the CI runners). Fall back to the versioned sonames,
    -- which are the ones actually installed.
    local libcrypto
    for _, soname in ipairs({ "crypto", "libcrypto.so.3", "libcrypto.so.1.1" }) do
      local loaded, handle = pcall(ffi.load, soname)
      if loaded then
        libcrypto = handle
        break
      end
    end
    if libcrypto then
      local declared = pcall(function()
        ffi.cdef([[
          unsigned char *MD5(const unsigned char *d, size_t n, unsigned char *md);
          unsigned char *SHA1(const unsigned char *d, size_t n, unsigned char *md);
          unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);
          typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
          const void *EVP_aes_128_cbc(void);
          EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
          void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
          int EVP_CipherInit_ex(EVP_CIPHER_CTX *ctx, const void *cipher, void *impl,
                                const unsigned char *key, const unsigned char *iv, int enc);
          int EVP_CipherUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
                               const unsigned char *in, int inl);
          int EVP_CipherFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
        ]])
      end)
      if declared then
        local digests = {
          MD5 = { fn = libcrypto.MD5, len = 16 },
          SHA1 = { fn = libcrypto.SHA1, len = 20 },
          SHA256 = { fn = libcrypto.SHA256, len = 32 },
        }
        crypto_backend = {
          hash = function(algorithm, data)
            local digest = digests[string.upper(algorithm)]
            if not digest then
              return nil, "unsupported hash: " .. tostring(algorithm)
            end
            local buf = ffi.new("unsigned char[?]", digest.len)
            digest.fn(data, #data, buf)
            return ffi.string(buf, digest.len)
          end,
          aes128cbc = function(encrypt, key, iv, data)
            local ctx = libcrypto.EVP_CIPHER_CTX_new()
            if ctx == nil then
              return nil, "EVP_CIPHER_CTX_new failed"
            end
            local out = ffi.new("unsigned char[?]", #data + 16)
            local outl = ffi.new("int[1]")
            local finl = ffi.new("int[1]")
            local result = nil
            if libcrypto.EVP_CipherInit_ex(ctx, libcrypto.EVP_aes_128_cbc(), nil, key, iv, encrypt and 1 or 0) == 1 then
              if libcrypto.EVP_CipherUpdate(ctx, out, outl, data, #data) == 1 then
                if libcrypto.EVP_CipherFinal_ex(ctx, out + outl[0], finl) == 1 then
                  result = ffi.string(out, outl[0] + finl[0])
                end
              end
            end
            libcrypto.EVP_CIPHER_CTX_free(ctx)
            if not result then
              return nil, "EVP cipher failed"
            end
            return result
          end,
        }
      end
    end
  end
end

--- Whether the FFI crypto backend resolved. False under plain Lua, and on a host
--- with no loadable CommonCrypto/libcrypto.
C4.SHIM_HAS_CRYPTO = crypto_backend ~= nil

local function to_hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02X", c:byte())
  end))
end

--- C4:Hash(algorithm, data, options) — raw ("NONE") or, with no return_encoding,
--- hex. Any other value is refused rather than answered in hex, since the shim
--- has never been measured against one and a wrong-encoding digest still looks
--- like a digest. Checked ahead of the backend, so the refusal also holds on a
--- host with no crypto at all.
function C4:Hash(algorithm, data, options)
  local encoding = type(options) == "table" and options.return_encoding or nil
  if encoding ~= nil and string.upper(encoding) ~= "NONE" then
    return nil, "C4 shim: return_encoding " .. tostring(encoding) .. " is not modelled (only NONE, or absent for hex)"
  end
  if not crypto_backend then
    return nil, "C4 shim: no crypto backend (requires LuaJIT + CommonCrypto/libcrypto)"
  end
  local raw, err = crypto_backend.hash(algorithm, data or "")
  if not raw then
    return nil, err
  end
  if encoding ~= nil then
    return raw
  end
  return to_hex(raw)
end

local function aes_options_ok(cipher, key, iv)
  return string.upper(cipher or "") == "AES-128-CBC" and type(key) == "string" and #key == 16 and type(iv) == "string"
end

--- C4:Encrypt(cipher, key, iv, data, options) — AES-128-CBC/PKCS7, raw in/out.
function C4:Encrypt(cipher, key, iv, data, options)
  if not crypto_backend then
    return nil, "C4 shim: no crypto backend"
  end
  if not aes_options_ok(cipher, key, iv) then
    return nil, "C4 shim: only raw AES-128-CBC is supported"
  end
  return crypto_backend.aes128cbc(true, key, iv, data or "")
end

--- C4:Decrypt(cipher, key, iv, data, options) — AES-128-CBC/PKCS7, raw in/out.
function C4:Decrypt(cipher, key, iv, data, options)
  if not crypto_backend then
    return nil, "C4 shim: no crypto backend"
  end
  if not aes_options_ok(cipher, key, iv) then
    return nil, "C4 shim: only raw AES-128-CBC is supported"
  end
  return crypto_backend.aes128cbc(false, key, iv, data or "")
end

print("C4 shim layer loaded" .. (has_socket and " (with luasocket)" or " (stubs only)"))

return C4
