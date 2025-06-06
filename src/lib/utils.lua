--- @module "lib.utils"
--- Utility module for managing devices, their bindings, properties, data, and general device-related operations in a Control4-driven environment.

local deferred = require("vendor.deferred")

local log = require("lib.logging")

local constants = require("constants")

--- Checks if the current OS version meets the minimum required version as defined in the driver configuration.
--- @param statusProperty string The property to update with the status message if the version check fails.
--- @return boolean meetsMinVersion True if the version check passes, false otherwise.
function CheckMinimumVersion(statusProperty)
  if not C4.GetDriverConfigInfo or not (VersionCheck(C4:GetDriverConfigInfo("minimum_os_version"))) then
    --- @cast C4.GetDriverConfigInfo -nil
    C4:UpdateProperty(
      statusProperty,
      table.concat({
        "DRIVER DISABLED - ",
        C4:GetDriverConfigInfo("model"),
        "driver",
        C4:GetDriverConfigInfo("version"),
        "requires at least C4 OS",
        C4:GetDriverConfigInfo("minimum_os_version"),
        ": current C4 OS is",
        C4:GetVersionInfo().version,
      }, " ")
    )
    for p, _ in pairs(Properties) do
      C4:SetPropertyAttribs(p, constants.HIDE_PROPERTY)
    end
    C4:SetPropertyAttribs(statusProperty, constants.SHOW_PROPERTY)
    return false
  end
  return true
end

--- Gets the version of a driver from its driver.xml file.
--- @param filename string The filename of the driver.
--- @return string|nil version The version of the driver, or nil if not found.
function GetDriverVersion(filename)
  local basename, _ = filename:match("(.*)%.(.*)")
  C4:FileSetDir("C4Z_ROOT", basename)
  return Select(ParseXml(FileRead("driver.xml")) or {}, "devicedata", "version") or nil
end

--- Logs function calls and arguments for debugging purposes.
--- @param funcName string The name of the function being logged.
--- @vararg any A variable number of arguments passed to the function.
local function LogC4Send(funcName, ...)
  local numArgs = select("#", ...)
  local args = { ... }

  local logArgsFmt = ""
  for i, _ in pairs(args) do
    logArgsFmt = logArgsFmt .. "%s"
    if i ~= numArgs then
      logArgsFmt = logArgsFmt .. ", "
    end
  end
  log:trace("%s(" .. logArgsFmt .. ")", funcName, unpack(args))
end

--- Sends a Control4 CommandMessage to a specified Control4 device driver.
--- @param deviceId number|string The ID of the driver to send the command to.
--- @param strCommand string The command to send.
--- @param tParams table A table containing parameters for the command.
--- @param allowEmptyValues? boolean Allows empty strings as parameter values (optional). Defaults to false.
--- @param logCommand? boolean If false, prevents logging of the command's content (optional). Defaults to true.
function SendToDevice(...)
  LogC4Send("C4:SendToDevice", ...)
  return C4:SendToDevice(...)
end

--- Sends a Control4 BindMessage to a proxy with the specified binding ID.
--- @param idBinding number The proxy binding to send the message to.
--- @param strCommand string The command to send.
--- @param tParams table A table containing parameters for the command.
--- @param strMessage? string Overrides message type ("COMMAND" or "NOTIFY") (optional). Defaults to "COMMAND".
--- @param allowEmptyValues? boolean Allows empty values in message parameters (optional).
function SendToProxy(...)
  LogC4Send("C4:SendToProxy", ...)
  return C4:SendToProxy(...)
end

--- Sends an HTTP request to a network binding.
--- @param idBinding number The ID of the network binding to send to.
--- @param nPort number The port to use for the request.
--- @param strData string The data to send with the HTTP request.
function SendToNetwork(...)
  LogC4Send("C4:SendToNetwork", ...)
  return C4:SendToNetwork(...)
end

--- Sends a UI Request to another driver.
--- @param id number The ID of the driver receiving the request.
--- @param request string The request to send.
--- @param tParams table A table of parameters to send with the request. Use `{}` if no parameters.
--- @return string response The response to the request in XML format.
function SendUIRequest(...)
  LogC4Send("C4:SendUIRequest", ...)
  return C4:SendUIRequest(...)
end

--- Retrieves the bindings for a given device, optionally filtered by type, provider, display name, and class.
--- @param deviceId number The ID of the device to retrieve bindings for.
--- @param typeFilter string|nil Optional filter for the binding type.
--- @param providerFilter boolean|nil Optional filter for the binding provider.
--- @param displayNameFilter string|nil Optional filter for the binding display name.
--- @param classFilter string|nil Optional filter for the binding class.
--- @return table<number, DeviceBinding> bindings A table of matched bindings, where the keys are binding IDs and the values are binding details.
function GetDeviceBindings(deviceId, typeFilter, providerFilter, displayNameFilter, classFilter)
  log:trace(
    "GetDeviceBindings(%s, %s, %s, %s, %s)",
    deviceId,
    typeFilter,
    providerFilter,
    displayNameFilter,
    classFilter
  )
  --- @type DeviceBinding[]
  local deviceBindings = Select(C4:GetBindingsByDevice(deviceId), "bindings") or {}
  --- @type table<number, DeviceBinding>
  local matchedBindings = {}
  for _, binding in pairs(deviceBindings) do
    if
      (providerFilter == nil or Select(binding, "provider") == providerFilter)
      and (typeFilter == nil or Select(binding, "type") == typeFilter)
      and (displayNameFilter == nil or Select(binding, "name") == displayNameFilter)
    then
      for _, bindingClass in pairs(Select(binding, "bindingclasses") or {}) do
        local bindingId = tointeger(Select(binding, "bindingid"))
        if bindingId ~= nil and (classFilter == nil or Select(bindingClass, "class") == classFilter) then
          matchedBindings[bindingId] = binding
        end
      end
    end
  end
  return matchedBindings
end

local xml2lua = require("vendor.xml.xml2lua")
local handler = require("vendor.xml.xmlhandler.tree")

--- Parses an XML string and converts it into a Lua table.
--- Makes use of an external XML parser library.
--- @param xmlStr string The XML string to parse.
--- @return table xml A Lua table representation of the XML structure.
function ParseXml(xmlStr)
  if IsEmpty(xmlStr) then
    return {}
  end
  local h = handler:new()
  local parser = xml2lua.parser(h)
  parser:parse(xmlStr)
  return h.root
end

--- Removes unnecessary whitespace and newlines from an XML string.
--- Minifies the XML for more compact storage or processing.
--- @param s string|nil The XML string to minify.
--- @return string xml The minified XML string.
function MinifyXml(s)
  s = string.gsub(s or "", "\r?\n[ ]*", "")
  s = string.gsub(s, "^[ ]*", "")
  return s
end

--- Clamps a numeric value within a specified range.
--- Adjusts numbers below `min` up to the minimum or above `max` down to the maximum.
--- @param n number|nil The number to clamp.
--- @param min? number The lower bound (optional).
--- @param max? number The upper bound (optional).
--- @return number|nil value The clamped value.
--- @overload fun(n: number, min?: number, max?: number): number
function InRange(n, min, max)
  if n == nil then
    return nil
  end
  if min ~= nil then
    n = math.max(min, n)
  end
  if max ~= nil then
    n = math.min(max, n)
  end
  return n
end

--- Rounds a number to a specified number of decimal places.
--- @param num number The number to round.
--- @param numDecimalPlaces? number The number of decimal places to retain (optional). Defaults to 0.
--- @return number value The rounded number.
function round(num, numDecimalPlaces)
  local mult = 10 ^ (numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end

--- Rounds a number to the nearest half (0.5).
--- @param num number The number to round.
--- @return number value The number rounded to the nearest half.
function roundNearestHalf(num)
  return round(round(num * 2) / 2, 1)
end

--- Computes the number of elements in a table.
--- Works for any table type, not just array-like tables.
--- @param t table The table to measure.
--- @return number length The number of elements in the table.
function TableLength(t)
  if type(t) ~= "table" then
    return 0
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

--- Retrieves all keys from a table as an array.
--- @param t table The table to extract keys from.
--- @return table keys A list of all keys in the table.
function TableKeys(t)
  if type(t) ~= "table" then
    return {}
  end
  local keys = {}
  for key, _ in pairs(t) do
    table.insert(keys, key)
  end
  return keys
end

--- Retrieves all values from a table as an array.
--- @param t table The table to extract values from.
--- @return table values  A list of all values in the table.
function TableValues(t)
  if type(t) ~= "table" then
    return {}
  end
  local values = {}
  for _, value in pairs(t) do
    table.insert(values, value)
  end
  return values
end

--- Maps a function over each key-value pair in a table.
--- The function can modify both the keys and values.
--- @param t table The table to map over.
--- @param func fun(value: any, key: any): any Function to apply to each pair (value, key).
--- @return table mappedTable A new table containing the transformed pairs.
function TableMap(t, func)
  if IsEmpty(t) then
    return {}
  end
  local retValue = {}
  for k, v in pairs(t) do
    local new_v, new_k = func(v, k)
    if new_v ~= nil then
      retValue[new_k or k] = new_v
    end
  end
  return retValue
end

local comp_func_default = function(a, b)
  return a < b
end

--- Binary insert a value into a sorted table.
--- @param t table The sorted table to insert into
--- @param value any The value to insert
--- @param comp_func? (fun(a: any, b: any):boolean) Optional comparison function (optional).
--- @return number insertedIndex The index where the value was inserted
function bininsert(t, value, comp_func)
  comp_func = comp_func or comp_func_default
  local iStart, iEnd, iMid, iState = 1, #t, 1, 0
  while iStart <= iEnd do
    iMid = math.floor((iStart + iEnd) / 2)
    if comp_func(value, t[iMid]) then
      iEnd, iState = iMid - 1, 0
    else
      iStart, iState = iMid + 1, 1
    end
  end
  table.insert(t, (iMid + iState), value)
  return (iMid + iState)
end

--- Reverses the keys and values in a table.
--- Produces a new table with values as keys and keys as values.
--- @param t table The table to reverse.
--- @return table reversedTable A new table with keys and values swapped.
function TableReverse(t)
  local r = {}
  for k, v in pairs(t) do
    r[v] = k
  end
  return r
end

--- Deep copies a table, capturing nested tables and ensuring circular references are handled.
--- @param t table|nil The table to be deep-copied.
--- @param seen? table Tracks tables already copied (internal use).
--- @return table|nil copiedTable A deep-copied version of the input table.
--- @overload fun(t: table, seen?: table): table
function TableDeepCopy(t, seen)
  seen = seen or {}
  if t == nil then
    return nil
  end
  if seen[t] then
    return seen[t]
  end

  local copy
  if type(t) == "table" then
    copy = {}
    seen[t] = copy

    for k, v in next, t, nil do
      copy[TableDeepCopy(k, seen)] = TableDeepCopy(v, seen)
    end
    setmetatable(copy, TableDeepCopy(getmetatable(t), seen))
  else -- number, string, boolean, etc
    copy = t
  end
  return copy
end

--- Produces a list containing only unique values from the input table.
--- Removes duplicate values while maintaining the original order.
--- @param t table Array-like table to process
--- @return table uniqueList New table containing unique values
function UniqueList(t)
  if type(t) ~= "table" then
    return {}
  end
  local seen = {}
  local list = {}

  for _, v in ipairs(t) do
    if not seen[v] then
      table.insert(list, v)
      seen[v] = true
    end
  end
  return list
end

--- Concatenates multiple lists (tables) into one.
--- The provided tables are appended sequentially.
--- @param ... table Tables to concatenate
--- @return table combinedList Combined table containing all elements
function ConcatLists(...)
  local c = {}
  for _, t in pairs({ ... }) do
    if type(t) == "table" then
      for _, v in ipairs(t) do
        table.insert(c, v)
      end
    end
  end
  return c
end

--- Sort a list in place.
--- @param t table Array-like table to sort
--- @return table sortedList The sorted table
function SortList(t)
  table.sort(t)
  return t
end

--- Checks if a given table behaves as a list (sequential integer keys).
--- Ensures there are no gaps in the indexing of the table keys.
--- @param t any Value to check
--- @return boolean isList True if the value is an array-like table
function IsList(t)
  if type(t) ~= "table" then
    return false
  end
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then
      return false
    end
  end
  return true
end

--- Checks if a given value is empty.
--- Supports strings, tables, numbers, booleans, and `nil` values.
--- @param value any The value to check.
--- @return boolean isEmpty Returns true if the value is considered empty; otherwise false.
function IsEmpty(value)
  if value == nil then
    return true
  end
  if type(value) == "string" then
    return value == ""
  end
  if type(value) == "table" then
    return next(value) == nil
  end
  if type(value) == "number" then
    return value == 0
  end
  if type(value) == "boolean" then
    return not value
  end
  return false
end

--- Finds the value in a list closest to a given number.
--- @param table table<number, number> A list of numbers to search through.
--- @param number number The target number to find the closest match for.
--- @return number|nil nearestValueIndex The index of the closest match, or `nil` if the table is empty.
--- @return number|nil nearestValue The value of the closest match, or `nil` if the table is empty.
function NearestValue(table, number)
  local smallestSoFar, smallestIndex
  for i, y in ipairs(table) do
    if not smallestSoFar or (math.abs(number - y) < smallestSoFar) then
      smallestSoFar = math.abs(number - y)
      smallestIndex = i
    end
  end
  if smallestIndex == nil then
    return nil, nil
  end
  return smallestIndex, table[smallestIndex]
end

--- Converts a value to a boolean, interpreting common truthy/falsy strings and numbers.
--- Recognizes `"true"`, `"yes"`, `"1"`, and `"on"` as truthy values.
--- @param val any The value to convert.
--- @return boolean `true` or `false` based on the input value.
function toboolean(val)
  if
    type(val) == "string"
    and (string.lower(val) == "true" or string.lower(val) == "yes" or val == "1" or string.lower(val) == "on")
  then
    return true
  elseif type(val) == "number" and val ~= 0 then
    return true
  elseif type(val) == "boolean" then
    return val
  end

  return false
end

--- Converts a value to a valid integer.
--- Rounds fractional numbers and validates string representations.
--- @param value any The value to convert to an integer. Can be a number or a string that represents a number.
--- @return number|nil Returns the rounded integer if the conversion is successful, or `nil` if the value cannot be converted.
function tointeger(value)
  local nval = tonumber(value)
  if nval == nil then
    return nil
  end
  return (nval >= 0) and math.floor(nval + 0.5) or math.ceil(nval - 0.5)
end

function tonumber_locale(str, base)
  local s
  local num
  if type(str) == "string" then
    s = str:gsub(",", ".")
    num = tonumber(s, base)
    if num == nil then
      s = str:gsub("%.", ",")
      num = tonumber(s, base)
    end
  else
    num = tonumber(str, base)
  end
  return num
end

--- Converts a value to a valid network port number.
--- Ensures the resulting number is within the range (1-65535).
--- @param value any The value to convert to a port number.
--- @return number|nil Returns the port number if valid (1-65535), or `nil` if the value is invalid.
function toport(value)
  value = tointeger(value)
  if value == nil or value <= 0 or value > 65535 then
    return nil
  else
    return value
  end
end

--- Creates a delay for a specified number of milliseconds.
--- Uses deferred objects to resolve after the delay.
--- @param ms number The duration of the delay in milliseconds.
--- @return Deferred<void, void> A deferred object that resolves after the delay.
function delay(ms)
  --- @type Deferred<void, void>
  local d = deferred.new()
  if IsEmpty(ms) or ms <= 0 then
    return d:resolve(nil)
  end

  SetTimer(C4:UUID("Random"), ms, function()
    d:resolve(nil)
  end)
  return d
end

function reject(error)
  return deferred.new():reject(error)
end

function resolve(value)
  return deferred.new():resolve(value)
end

--- Escapes special characters in a string for safe use in regular expressions.
--- Handles meta-characters like `*`, `.`, `+`, and others.
--- @param x string The string to escape.
--- @return string An escaped version of the input string.
function RegexEscape(x)
  if type(x) ~= "string" or IsEmpty(x) then
    return ""
  end
  return (
    x:gsub("%%", "%%%%")
      :gsub("^%^", "%%^")
      :gsub("%$$", "%%$")
      :gsub("%(", "%%(")
      :gsub("%)", "%%)")
      :gsub("%.", "%%.")
      :gsub("%[", "%%[")
      :gsub("%]", "%%]")
      :gsub("%*", "%%*")
      :gsub("%+", "%%+")
      :gsub("%-", "%%-")
      :gsub("%?", "%%?")
  )
end
