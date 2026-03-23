--- Utility module for managing devices, their bindings, properties, data, and general device-related operations in a Control4-driven environment.

local deferred = require("deferred")

local log = require("lib.logging")
local lru = require("lib.lru")

local constants = require("constants")

--- @alias DeviceId integer|string

do
  --- @type table<string, fun(paramName: string): string[]>
  --- Global table mapping command names to functions.
  --- Each function takes a parameter name and returns a list of parameter values.
  GCPL = GCPL or {}
end

--- Retrieves a list of command parameters for a given command name.
--- @param commandName string The name of the command to retrieve parameters for.
--- @param paramName string The specific parameter to retrieve associated with the command.
--- @return any|nil parameters Returns the list of parameters if successful; nil otherwise.
function GetCommandParamList(commandName, paramName)
  commandName = string.gsub(commandName, "%W", "_")
  commandName = string.gsub(commandName, "[_]+", "_")
  commandName = string.gsub(commandName, "^[_| ]+", "")
  commandName = string.gsub(commandName, "[_| ]+$", "")

  local init = {
    "GetCommandParamList: " .. commandName,
    paramName,
  }
  HandlerDebug(init)

  local success, ret

  if GCPL and GCPL[commandName] and type(GCPL[commandName]) == "function" then
    success, ret = xpcall(function()
      return GCPL[commandName](paramName)
    end, debug.traceback)
  end

  if success == true then
    return ret
  elseif success == false then
    print("GetCommandParamList error: ", ret, commandName, paramName)
    if ON_HANDLER_ERROR then
      ON_HANDLER_ERROR("GCPL." .. commandName, ret)
    end
  end
end

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

--- Logs and invokes a C4 method, trimming trailing nil arguments.
--- @param methodName string The C4 method name
--- @param ... any Arguments to pass
--- @return any
local function C4Call(methodName, ...)
  local numArgs = select("#", ...)
  local args = { ... }

  -- Single pass: build format string and find last non-nil
  local lastNonNil = 0
  local fmtParts = {}
  for i = 1, numArgs do
    if args[i] ~= nil then
      lastNonNil = i
    end
    fmtParts[i] = "%s"
  end

  log:trace("C4:" .. methodName .. "(" .. table.concat(fmtParts, ", ") .. ")", unpack(args, 1, numArgs))
  return C4[methodName](C4, unpack(args, 1, lastNonNil))
end

--- Sends a Control4 CommandMessage to a specified Control4 device driver.
--- @param deviceId DeviceId The ID of the driver to send the command to.
--- @param strCommand string The command to send.
--- @param tParams table A table containing parameters for the command.
--- @param allowEmptyValues? boolean Allows empty strings as parameter values (optional). Defaults to false.
--- @param logCommand? boolean If false, prevents logging of the command's content (optional). Defaults to true.
function SendToDevice(deviceId, strCommand, tParams, allowEmptyValues, logCommand)
  return C4Call("SendToDevice", deviceId, strCommand, tParams, allowEmptyValues, logCommand)
end

--- Sends a Control4 BindMessage to a proxy with the specified binding ID.
--- @param idBinding number The proxy binding to send the message to.
--- @param strCommand string The command to send.
--- @param tParams table A table containing parameters for the command.
--- @param strMessage? string Overrides message type ("COMMAND" or "NOTIFY") (optional). Defaults to "COMMAND".
--- @param allowEmptyValues? boolean Allows empty values in message parameters (optional).
function SendToProxy(idBinding, strCommand, tParams, strMessage, allowEmptyValues)
  return C4Call("SendToProxy", idBinding, strCommand, tParams, strMessage, allowEmptyValues)
end

--- Sends an HTTP request to a network binding.
--- @param idBinding number The ID of the network binding to send to.
--- @param nPort number The port to use for the request.
--- @param strData string The data to send with the HTTP request.
function SendToNetwork(idBinding, nPort, strData)
  return C4Call("SendToNetwork", idBinding, nPort, strData)
end

--- Sends a UI Request to another driver.
--- @param id DeviceId The ID of the driver receiving the request.
--- @param request string The request to send.
--- @param tParams table A table of parameters to send with the request. Use `{}` if no parameters.
--- @return string response The response to the request in XML format.
function SendUIRequest(id, request, tParams)
  return C4Call("SendUIRequest", id, request, tParams)
end

--- @type LRUCache<string,ExtendedDeviceDefinition|nil>
local devicesCache = lru:new(1000, 180)

--- @type LRUCache<string,table|nil>
local devicesDataCache = lru:new(1000, 180)

--- @type LRUCache<string,integer|nil>
local agentIdCache = lru:new(1000, 180)

--- Clears the specific device ID from the cache.
--- @param deviceId DeviceId The ID of the device to clear from the cache.
function DeviceUpdated(deviceId)
  log:trace("DeviceUpdated(%s)", deviceId)
  devicesCache:remove(tostring(deviceId))
  devicesDataCache:remove(tostring(deviceId))
end

--- @class ExtendedDeviceDefinition
--- @field driverFileName string
--- @field deviceName string
--- @field roomId string
--- @field roomName string
--- @field protocol? table<number, ProtocolDefinition>
--- @field deviceId DeviceId
--- @field displayName string
--- @field ignoreRoomName? boolean Whether to ignore the room name prefix for this device.

--- Retrieves an extended device definition by device ID.
--- @param deviceId DeviceId|nil The ID of the device.
--- @param c4iNames? string[]|string List of C4i names to filter results.
--- @return ExtendedDeviceDefinition|nil device The device definition if found; else nil.
function GetDevice(deviceId, c4iNames)
  log:trace("GetDevice(%s, %s)", deviceId, c4iNames)
  return devicesCache:getOrSet(tostring(deviceId), function()
    local deviceIdInt = tointeger(deviceId)
    if deviceIdInt == nil or deviceIdInt < 1 then
      return nil
    end
    --- @type DeviceFilter
    local tFilter = { DeviceIds = tostring(deviceIdInt) }
    if not IsEmpty(c4iNames) then
      --- @cast c4iNames -nil
      if IsList(c4iNames) then
        --- @cast c4iNames string[]
        c4iNames = table.concat(c4iNames, ",")
      end
      --- @cast c4iNames -string[]
      tFilter.C4iNames = c4iNames
    end
    local device = C4:GetDevices(tFilter)[deviceIdInt]
    if device == nil then
      -- Make a synthetic device for a room
      local deviceName = C4:GetDeviceDisplayName(deviceIdInt)
      if not IsEmpty(deviceName) then
        --- @type ExtendedDeviceDefinition
        device = {
          roomId = tostring(deviceIdInt),
          roomName = deviceName,
          deviceName = deviceName,
          driverFileName = "roomdevice.c4i",
        }
      else
        log:warn("GetDevice -> Unknown device %s", deviceIdInt)
        return nil
      end
    end
    local displayName = device.deviceName
    if not IsEmpty(device.roomName) then
      displayName = string.format("%s > %s", device.roomName, device.deviceName)
    end
    --- @type ExtendedDeviceDefinition
    return {
      driverFileName = device.driverFileName,
      deviceName = device.deviceName,
      roomId = device.roomId,
      roomName = device.roomName,
      protocol = device.protocol,
      -- Extended fields
      deviceId = deviceIdInt,
      displayName = displayName,
    }
  end)
end

--- Retrieves device data for a given device ID and specified properties.
--- @param deviceId DeviceId The ID of the device to retrieve data for.
--- @param ... string? Nested keys to retrieve specific properties from the device data.
--- @return table data
function GetDeviceData(deviceId, ...)
  log:trace("GetDeviceData(%s, %s)", deviceId, table.concat({ ... }, ","))
  local deviceIdInt = tointeger(deviceId)
  if deviceIdInt == nil then
    return {}
  end
  return Select(
    devicesDataCache:getOrSet(tostring(deviceId), function()
      return ParseXml(C4:GetDeviceData(deviceIdInt))
    end),
    unpack({ ... })
  )
end

--- Retrieves the bindings for a given device, optionally filtered by type, provider, display name, and class.
--- @param deviceId integer The ID of the device to retrieve bindings for.
--- @param typeFilter string|nil Optional filter for the binding type.
--- @param providerFilter boolean|nil Optional filter for the binding provider.
--- @param displayNameFilter string|nil Optional filter for the binding display name.
--- @param classFilter string|nil Optional filter for the binding class.
--- @return table<integer, DeviceBinding> bindings A table of matched bindings, where the keys are binding IDs and the values are binding details.
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
  --- @type table<integer, DeviceBinding>
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

--- Retrieves the agent ID for a given C4i name.
--- @param c4iName string The C4i name to look up.
--- @return integer|nil agentId The ID of the agent if found, otherwise nil.
function GetAgentId(c4iName)
  log:trace("GetAgentId(%s)", c4iName)
  return agentIdCache:getOrSet(c4iName, function()
    local agents = Select(ParseXml(C4:GetProjectItems("AGENTS")), "systemitems", "item") or {}
    if not IsList(agents) then
      agents = { agents }
    end
    for _, agent in pairs(agents) do
      if not IsEmpty(agent) and agent.c4i == c4iName and not IsEmpty(agent.id) then
        return tointeger(agent.id)
      end
    end
    return nil
  end)
end

--- Retrieves device properties for a given device ID.
--- @param deviceId integer The ID of the device to retrieve properties for.
--- @return table<string, string> properties A table mapping property names to their values.
function GetDeviceProperties(deviceId)
  log:trace("GetDeviceProperties(%s)", deviceId)
  local strValues = SendUIRequest(deviceId, "GET_PROPERTIES_SYNC", {})
  if IsEmpty(strValues) then
    strValues = SendUIRequest(deviceId, "GET_PROPERTIES", {})
  end
  local propertiesList = Select(ParseXml(strValues), "properties", "property")
  local propertiesMap = {}
  for _, property in pairs(propertiesList or {}) do
    propertiesMap[property.name] = property.value
  end
  return propertiesMap
end

--- Sets device properties for a given device ID.
--- @param deviceId integer The ID of the device to set properties on.
--- @param properties table<string, string> A table mapping property names to their values.
--- @param onlyIfChanged? boolean If true, only update properties that have changed.
function SetDeviceProperties(deviceId, properties, onlyIfChanged)
  log:trace("SetDeviceProperties(%s, %s, %s)", deviceId, properties, onlyIfChanged)
  local currentProps = onlyIfChanged and GetDeviceProperties(deviceId) or {}
  for name, value in pairs(properties) do
    if not onlyIfChanged or currentProps[name] ~= value then
      SendToDevice(deviceId, "UPDATE_PROPERTY", { Name = name, Value = value })
    end
  end
end

--- @alias GenericCallback fun(deviceId: DeviceId, device: table, index: number): any

--- Removes unknown device IDs and optionally processes known ones using a callback.
--- This function iterates through device IDs parsed from the `propertyStr` and processes each using the optional callback.
--- If `deleteUnknownDeviceIds` is `true`, invalid device IDs are removed from the property list.
--- @generic T
--- @param propertyStr string The name of the property that stores the device IDs to parse.
--- @param callback? fun(deviceId: DeviceId, device: table, index: integer): T Optional callback function that processes each valid device.
--- @param deleteUnknownDeviceIds? boolean When set to `true`, deletes invalid device IDs from the property list.
--- @return table<DeviceId, T>|nil devices Returns a table of processed device data or `nil` if parsing fails.
function ParseDeviceIdPropertyList(propertyStr, callback, deleteUnknownDeviceIds)
  if deleteUnknownDeviceIds == nil then
    deleteUnknownDeviceIds = true
  end
  log:trace("ParseDeviceIdPropertyList(%s, <callback>, %s)", propertyStr, deleteUnknownDeviceIds)
  local properties = Select(ParseXml(C4:GetDeviceData(C4:GetDeviceID(), "properties")), "property")
  if not IsList(properties) then
    properties = { properties }
  end
  for _, property in pairs(properties) do
    if not IsEmpty(property) and property.name == propertyStr then
      if property.type ~= "DEVICE_SELECTOR" then
        log:error("Failed to parse '%s'; only DEVICE_SELECTOR properties can be parsed", propertyStr)
        return nil
      end
      local c4iNames = {}
      if not IsEmpty(property.items) and not IsEmpty(property.items.item) then
        local items = property.items.item
        if type(items) == "string" then
          items = { items }
        end
        for _, item in pairs(items) do
          if not IsEmpty(item) then
            table.insert(c4iNames, item)
          end
        end
      end
      if IsEmpty(c4iNames) then
        log:error("Failed to parse '%s'; no c4i name items were found", propertyStr)
        return nil
      end

      -- Remove any invalid devices from the property
      local currentPropertyValue = Properties[propertyStr] or ""
      if deleteUnknownDeviceIds then
        local currentPropertyValueLength = string.len(currentPropertyValue)
        local validDeviceIds = TableKeys(ParseDeviceIdList(currentPropertyValue, c4iNames))
        table.sort(validDeviceIds)
        local newPropertyValue = table.concat(validDeviceIds, ",")
        local newPropertyValueLength = string.len(newPropertyValue)
        if currentPropertyValueLength ~= newPropertyValueLength then
          UpdateProperty(propertyStr, newPropertyValue)
          currentPropertyValue = newPropertyValue
        end
      end

      return ParseDeviceIdList(currentPropertyValue, c4iNames, callback)
    end
  end
  log:error("Failed to parse '%s'; property was not found", propertyStr)
  return nil
end

--- Parses a comma-separated list of device IDs and processes them.
--- Each device ID in the list is retrieved, checked for validity, and optionally passed to a callback function for processing.
--- @param deviceIdListStr string The string of comma-separated device IDs.
--- @param c4iNames? string[] Optional list of C4i names to filter devices.
--- @param callback? fun(deviceId: DeviceId, device: table, index: integer): any Optional callback to process each device.
--- @return table<DeviceId, any> devices Returns a table of processed devices, keyed by device ID.
function ParseDeviceIdList(deviceIdListStr, c4iNames, callback)
  log:trace("ParseDeviceIdList(%s, %s, <callback>)", deviceIdListStr, c4iNames)
  local devices = {}
  local i = 1
  for deviceIdStr in string.gmatch(deviceIdListStr or "", "([^,]+)") do
    local device = GetDevice(deviceIdStr, c4iNames)
    if device ~= nil then
      if type(callback) == "function" then
        local success, result = pcall(callback, device.deviceId, device, i)
        i = i + 1
        if success then
          devices[device.deviceId] = result
        else
          log:error("Error parsing ids '%s'; %s", deviceIdListStr, result)
        end
      else
        devices[device.deviceId] = device
      end
    else
      log:warn("Unknown device with id '%s'", deviceIdStr)
    end
  end
  return devices
end

local xml2lua = require("xml.xml2lua")
local handler = require("xml.xmlhandler.tree")

--- Parses an XML string and converts it into a Lua table.
--- Makes use of an external XML parser library.
--- @param xmlStr string|nil The XML string to parse.
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

--- Gets default values for all read-only properties from driver config XML.
--- Parses the driver's config XML and returns a table mapping property names
--- to their default values for all read-only, non-label properties.
--- Use this for resetting driver state without hardcoding property lists.
--- @param exclude? string[] Optional list of property names to exclude (e.g., user input fields)
--- @return table<string, string> defaults Map of property name to default value
function GetPropertyResetValues(exclude)
  local configXML = C4:GetDriverConfigInfo("config")
  if IsEmpty(configXML) then
    return {}
  end

  -- Parse the config XML
  local parsed = ParseXml("<root>" .. configXML .. "</root>")
  local propsArray = Select(parsed, "root", "properties", "property") or {}

  -- Ensure it's a list (xml2lua returns single element if only one)
  if not IsList(propsArray) then
    propsArray = { propsArray }
  end

  -- Build exclusion set for fast lookup
  local excludeSet = {}
  for _, name in ipairs(exclude or {}) do
    excludeSet[name] = true
  end

  -- Helper to get string value (handles empty table from xml parser)
  local function getString(val)
    if val == nil then
      return nil
    end
    if type(val) == "table" then
      return ""
    end
    return tostring(val)
  end

  -- Parse properties and collect read-only defaults
  local defaults = {}
  for _, prop in ipairs(propsArray) do
    local name = getString(Select(prop, "name"))
    if name and name ~= "" then
      local propType = getString(Select(prop, "type")) or ""
      local readonly = getString(Select(prop, "readonly")) == "true"
      local password = getString(Select(prop, "password")) == "true"

      -- Include only read-only, non-label, non-password, non-excluded properties
      if readonly and propType ~= "LABEL" and not password and not excludeSet[name] then
        defaults[name] = getString(Select(prop, "default")) or ""
      end
    end
  end

  return defaults
end

--- Clamps a numeric value within a specified range.
--- Adjusts numbers below `min` up to the minimum or above `max` down to the maximum.
--- @param n number|nil The number to clamp.
--- @param min? number The lower bound (optional).
--- @param max? number The upper bound (optional).
--- @return number|nil value The clamped value.
--- @overload fun(n: number, min?: number, max?: number): number
--- @overload fun(n: number, min: number, max?: number): number
--- @overload fun(n: number, min?: number, max: number): number
--- @overload fun(n: number, min: number, max: number): number
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
--- @return integer length The number of elements in the table.
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
--- @return table values A list of all values in the table.
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
--- @generic K,V,K_NEW,V_NEW
--- @param t table<K,V> The table to map over.
--- @param func fun(value: V, key?: K): V_NEW, K_NEW? Function to apply to each pair. Returns (new_value, new_key?).
--- @return table<K_NEW, V_NEW> mappedTable A new table containing the transformed pairs.
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
--- @generic T: table
--- @param t T|nil The table to be deep-copied.
--- @param seen? table Tracks tables already copied (internal use).
--- @return T|nil copiedTable A deep-copied version of the input table.
--- @overload fun(t: T, seen?: table): T
--- @overload fun(t: T): T
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
--- @param mapper? fun(value: any): any Optional function to map values before checking for uniqueness.
--- @return table uniqueList New table containing unique values
function UniqueList(t, mapper)
  if type(t) ~= "table" then
    return {}
  end
  if type(mapper) ~= "function" then
    mapper = function(v)
      return v
    end
  end

  local seen = {}
  local list = {}

  for _, v in ipairs(t) do
    local key = mapper(v)
    if not seen[key] then
      table.insert(list, v)
      seen[key] = true
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
--- @return integer|nil int Returns the rounded integer if the conversion is successful, or `nil` if the value cannot be converted.
--- @overload fun(value: number): integer
function tointeger(value)
  value = tonumber(value)
  if value == nil then
    return nil
  end
  return (value >= 0) and math.floor(value + 0.5) or math.ceil(value - 0.5)
end

--- Asserts that a value is an integer, narrowing the type from DeviceId.
--- @param value DeviceId The value to narrow.
--- @return integer int The integer value.
function assertInt(value)
  local int = tointeger(value)
  assert(int ~= nil, "expected integer, got: " .. tostring(value))
  return int
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
--- @return Deferred<nil, nil> A deferred object that resolves after the delay.
function delay(ms)
  --- @type Deferred<nil, nil>
  local d = deferred.new()
  if IsEmpty(ms) or ms <= 0 then
    return d:resolve(nil)
  end

  SetTimer(C4:UUID("Random"), ms, function()
    d:resolve(nil)
  end)
  return d
end

--- Creates a deferred object that is immediately rejected with an error.
--- @generic F
--- @param err F The error to reject the deferred object with.
--- @return Deferred<any,F> rejected The rejected deferred object.
function reject(err)
  return deferred.new():reject(err)
end

--- Creates a deferred object that is immediately resolved with a value.
--- @generic T
--- @param value T|nil The value to resolve the deferred object with.
--- @return Deferred<T|nil,any> resolved The resolved deferred object.
--- @overload fun(value: T): Deferred<T, any>
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

--- Convert string to hex representation for debugging
--- @param str string The string to convert
--- @return string hex The hex representation
function to_hex(str)
  if str == nil then
    return "nil"
  end
  return (str:gsub(".", function(c)
    return string.format("%02X ", string.byte(c))
  end))
end

--- Convert Fahrenheit to Celsius, rounded to 1 decimal place
--- Overrides the vendor lib function which rounds to nearest 0.5
--- @param f number Temperature in Fahrenheit
--- @return number|nil Temperature in Celsius, or nil if input is not a number
function f2c(f)
  if type(f) ~= "number" then
    return nil
  end
  local c = (f - 32) * (5 / 9)
  return round(c, 1)
end

--- Convert Celsius to Fahrenheit, rounded to 1 decimal place
--- Overrides the vendor lib function which rounds to nearest integer
--- @param c number Temperature in Celsius
--- @return number|nil Temperature in Fahrenheit, or nil if input is not a number
function c2f(c)
  if type(c) ~= "number" then
    return nil
  end
  local f = (c * (9 / 5)) + 32
  return round(f, 1)
end

--------------------------------------------------------------------------------
-- Binary-safe serialization
--------------------------------------------------------------------------------

--- Marker key for base64-encoded binary strings.
--- Using an unlikely key to avoid collisions with real data.
local BINARY_MARKER = "__b64"

--- Sentinel value for nil (since Lua tables can't store nil values).
local NIL_SENTINEL = "__null__"

--- Check if a byte is binary (unsafe for transport).
--- Safe: 0x09 (tab), 0x0A (LF), 0x0D (CR), 0x20-0x7E (printable ASCII)
--- @param b number The byte value
--- @return boolean isBinary True if the byte is binary/unsafe
local function isBinaryByte(b)
  if b <= 8 then
    return true
  end -- 0x00-0x08
  if b == 11 or b == 12 then
    return true
  end -- 0x0B, 0x0C
  if b >= 14 and b <= 31 then
    return true
  end -- 0x0E-0x1F
  if b >= 127 then
    return true
  end -- 0x7F-0xFF
  return false
end

--- Check if a string contains binary data that needs encoding.
--- Catches null bytes (truncated by C4 proxy), control chars, and high bytes.
--- @param s string The string to check
--- @return boolean needsEncoding True if the string contains binary data
local function needsBase64(s)
  for i = 1, #s do
    if isBinaryByte(string.byte(s, i)) then
      return true
    end
  end
  return false
end

--- Recursively encode binary strings in a table for safe JSON serialization.
--- Strings containing binary data are wrapped as {__b64 = "base64data"}.
--- nil values are converted to a sentinel string.
--- @param value any The value to process
--- @return any encoded The processed value with binary strings wrapped
local function encodeBinaryStrings(value)
  if value == nil then
    return NIL_SENTINEL
  end
  local t = type(value)
  if t == "string" then
    -- Encode if binary OR if it equals the sentinel (to avoid collision)
    if needsBase64(value) or value == NIL_SENTINEL then
      return { [BINARY_MARKER] = C4:Base64Encode(value) }
    end
    return value
  elseif t == "table" then
    local result = {}
    for k, v in pairs(value) do
      result[k] = encodeBinaryStrings(v)
    end
    return result
  else
    return value
  end
end

--- Recursively decode binary strings in a table after JSON deserialization.
--- Unwraps {__b64 = "base64data"} back to original binary strings.
--- Converts sentinel values back to nil.
--- @param value any The value to process
--- @return any decoded The processed value with binary strings unwrapped
local function decodeBinaryStrings(value)
  if value == NIL_SENTINEL then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end
  -- Check if this is a binary marker wrapper
  local b64 = value[BINARY_MARKER]
  if b64 ~= nil and type(b64) == "string" then
    -- This is a wrapped binary string, decode it
    return C4:Base64Decode(b64)
  end
  -- Regular table, recurse into children
  local result = {}
  for k, v in pairs(value) do
    result[k] = decodeBinaryStrings(v)
  end
  return result
end

--- Wrapper key for serialized values.
--- Using a short key to minimize overhead.
local WRAPPER_KEY = "__v"

--- Binary-safe serialization for any value.
--- Wraps the value in a container, encodes binary strings, then JSON + base64 encodes.
--- Handles tables, strings (binary or plain), numbers, booleans, and nil uniformly.
--- Use DeserializeSafe to decode.
--- @param value any The value to serialize
--- @return string serialized The serialized string
function SerializeSafe(value)
  local wrapped = { [WRAPPER_KEY] = encodeBinaryStrings(value) }
  return C4:Base64Encode(JSON:encode(wrapped))
end

--- Binary-safe deserialization that reverses SerializeSafe.
--- Detects and decodes values serialized by SerializeSafe.
--- Returns the original value if it wasn't serialized by SerializeSafe.
--- @param serialized any The serialized string from SerializeSafe
--- @return any value The deserialized value with binary strings restored
function DeserializeSafe(serialized)
  if type(serialized) ~= "string" then
    return serialized
  end
  local decoded = C4:Base64Decode(serialized)
  if decoded == "" then
    return serialized -- invalid base64, not ours
  end
  local success, wrapped = pcall(JSON.decode, JSON, decoded)
  if not success or type(wrapped) ~= "table" or wrapped[WRAPPER_KEY] == nil then
    return serialized -- not ours
  end
  return decodeBinaryStrings(wrapped[WRAPPER_KEY])
end
