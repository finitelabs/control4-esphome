--- @module "lib.logging"
--- A logging utility module for managing log levels and output modes.

--- @class Log
--- A logging utility class with support for multiple log levels and output modes.
local Log = {}

--- Creates a new instance of the Log class.
--- @return Log log A new instance of the Log class.
function Log:new()
  local properties = {
    _logName = "", --- @type string The name of the log.
    _logLevel = 5, --- @type number The current log level (default is 5).
    _outputPrint = false, --- @type boolean Whether to output logs to print.
    _outputC4Log = false, --- @type boolean Whether to output logs to C4 log.
    _maxTableLevels = 10, --- @type number The maximum depth for table rendering.
  }
  setmetatable(properties, self)
  self.__index = self
  --- @cast properties Log
  return properties
end

--- Sets the name of the log.
--- @param logName string The name to set for the log.
function Log:setLogName(logName)
  if logName == nil or logName == "" then
    logName = ""
  else
    logName = logName .. ": "
  end

  self._logName = logName
end

--- Gets the name of the log.
--- @return string name The name of the log.
function Log:getLogName()
  return self._logName
end

--- Sets the log level.
--- @param level string|number|nil The log level to set (e.g., 3 or "3 - Info" for INFO).
function Log:setLogLevel(level)
  self._logLevel = tonumber(string.sub(level or "", 1, 1)) or self._logLevel
end

--- Gets the current log level.
--- @return number level The current log level.
function Log:getLogLevel()
  return self._logLevel
end

--- Sets the log output mode.
--- @param logMode string The log mode (e.g., "Print", "Log", "Print and Log").
function Log:setLogMode(logMode)
  logMode = logMode or ""
  self:setOutputPrintEnabled(logMode:find("Print") ~= nil)
  self:setOutputC4LogEnabled(logMode:find("Log") ~= nil)
end

--- Enables or disables printing log output.
--- @param value boolean Whether to enable or disable print output.
function Log:setOutputPrintEnabled(value)
  self._outputPrint = value
end

--- Enables or disables C4 log output.
--- @param value boolean Whether to enable or disable C4 log output.
function Log:setOutputC4LogEnabled(value)
  self._outputC4Log = value
end

--- Checks if any log output is enabled.
--- @return boolean enabled True if any log output is enabled, false otherwise.
function Log:isEnabled()
  return self:isPrintEnabled() or self:isC4LogEnabled()
end

--- Checks if print output is enabled.
--- @return boolean printEnabled True if print output is enabled, false otherwise.
function Log:isPrintEnabled()
  return self._outputPrint
end

--- Checks if C4 log output is enabled.
--- @return boolean logEnabled True if C4 log output is enabled, false otherwise.
function Log:isC4LogEnabled()
  return self._outputC4Log
end

--- Formats and fixes arguments for logging, ensuring they are strings or numbers.
--- @param numArgs number The number of arguments.
--- @param args table The arguments to format.
--- @return table formattedArgs The formatted arguments.
local function fixFormatArgs(numArgs, args)
  for i = 1, numArgs + 1 do
    if args[i] == nil then
      args[i] = "nil"
    end
    if type(args[i]) == "table" then
      args[i] = JSON:encode(args[i])
    end
    if type(args[i]) ~= "string" and type(args[i]) ~= "number" then
      args[i] = tostring(args[i])
    end
  end
  return args
end

--- Logs a fatal message.
--- @param sLogText string The log message.
--- @vararg any Additional arguments for formatting.
function Log:fatal(sLogText, ...)
  self:_log(0, sLogText, select("#", ...), { ... })
end

--- Logs an error message.
--- @param sLogText string The log message.
--- @vararg any Additional arguments for formatting.
function Log:error(sLogText, ...)
  self:_log(1, sLogText, select("#", ...), { ... })
end

--- Logs a warning message.
--- @param sLogText string The log message.
--- @vararg any Additional arguments for formatting.
function Log:warn(sLogText, ...)
  self:_log(2, sLogText, select("#", ...), { ... })
end

--- Logs an informational message.
--- @param sLogText string The log message.
--- @vararg any Additional arguments for formatting.
function Log:info(sLogText, ...)
  self:_log(3, sLogText, select("#", ...), { ... })
end

--- Logs a debug message.
--- @param sLogText string The log message.
--- @vararg any Additional arguments for formatting.
function Log:debug(sLogText, ...)
  self:_log(4, sLogText, select("#", ...), { ... })
end

--- Logs a trace message.
--- @param sLogText string The log message.
--- @vararg any Additional arguments for formatting.
function Log:trace(sLogText, ...)
  self:_log(5, sLogText, select("#", ...), { ... })
end

--- Logs an ultra-verbose message.
--- @param sLogText string The log message.
--- @vararg any Additional arguments for formatting.
function Log:ultra(sLogText, ...)
  self:_log(6, sLogText, select("#", ...), { ... })
end

--- Logs a message directly to stdout.
--- @param sLogText any The log message.
--- @vararg any Additional arguments for formatting.
function Log:print(sLogText, ...)
  self:_log(-1, sLogText, select("#", ...), { ... })
end

local maxTableLevels = 10

--- Renders a table as a string for logging.
--- @param tValue table The table to render.
--- @param tableText? string The current rendered text (optional).
--- @param sIndent? string The current indentation (optional).
--- @param level? number The current depth level (optional).
--- @return string renderedTable The rendered table as a string.
local function _renderTableAsString(tValue, tableText, sIndent, level)
  tableText = tableText or ""
  level = (level or 0) + 1
  sIndent = sIndent or ""

  if level <= maxTableLevels then
    if type(tValue) == "table" then
      for k, v in pairs(tValue) do
        if tableText == "" then
          tableText = sIndent .. tostring(k) .. ":  " .. tostring(v)
          if sIndent == ".   " then
            sIndent = "    "
          end
        else
          tableText = tableText .. "\n" .. sIndent .. tostring(k) .. ":  " .. tostring(v)
        end
        if type(v) == "table" then
          tableText = _renderTableAsString(v, tableText, sIndent .. "   ", level)
        end
      end
    else
      tableText = tableText .. "\n" .. sIndent .. tostring(tValue)
    end
  end

  return tableText
end

--- Adds a prefix to each line of a log message.
--- @param sPrefix string The prefix to add.
--- @param sLogText string The log message.
--- @return string prefixedLine The log message with prefixes added.
local function addLinePrefix(sPrefix, sLogText)
  --- @type table<number, string>
  local lines = {}
  for s in sLogText:gmatch("[^\r\n]+") do
    table.insert(lines, sPrefix .. s)
  end
  return table.concat(lines, "\n")
end

--- Logs a message with the specified level.
--- @param level number The log level.
--- @param sLogText any The log message.
--- @param numArgs number The number of arguments.
--- @param args table The arguments for formatting.
function Log:_log(level, sLogText, numArgs, args)
  if level == -1 or (self:isEnabled() and self._logLevel >= level) then
    args = fixFormatArgs(numArgs, args)
    if type(sLogText) == "string" then
      sLogText = string.format(sLogText, unpack(args))
    end

    if type(sLogText) == "table" then
      sLogText = _renderTableAsString(sLogText)
    end

    sLogText = tostring(sLogText)

    if level == -1 or self:isPrintEnabled() then
      print(addLinePrefix(self:_getPrintPrefix(level), sLogText))
    end

    if self:isC4LogEnabled() then
      if self._logLevel < 3 then
        C4:ErrorLog(addLinePrefix(self:_getLogPrefix(level), sLogText))
      else
        C4:DebugLog(addLinePrefix(self:_getLogPrefix(level), sLogText))
      end
    end
  end
end

--- Gets the prefix for a log level.
--- @param level number The log level.
--- @return string prefix The prefix for the log level.
local function _getLevelPrefix(level)
  local levelNames = {
    [-1] = "[PRINT]",
    [0] = "[FATAL]",
    [1] = "[ERROR]",
    [2] = "[WARN ]",
    [3] = "[INFO ]",
    [4] = "[DEBUG]",
    [5] = "[TRACE]",
    [6] = "[ULTRA]",
  }
  return (levelNames[level] or "[UKNWN]") .. ": "
end

--- Gets the prefix for print output.
--- @param level number The log level.
--- @return string printPrefix The print prefix.
function Log:_getPrintPrefix(level)
  --- @diagnostic disable-next-line: missing-parameter
  return os.date() .. " " .. _getLevelPrefix(level)
end

--- Gets the prefix for C4 log output.
--- @param level number The log level.
--- @return string logPrefix The C4 log prefix.
function Log:_getLogPrefix(level)
  local prefix = ""
  if not IsEmpty(self._logName) then
    prefix = "[" .. self._logName .. "]"
  end
  return prefix .. _getLevelPrefix(level)
end

return Log:new()
