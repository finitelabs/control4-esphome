--- A logging utility module for managing log levels and output modes.

--- A logging utility class with support for multiple log levels and output modes.
--- @class Log
--- @field _logName string The name of the log.
--- @field _logLevel LogLevel The current log level.
--- @field _outputPrint boolean Whether to output logs to print.
--- @field _outputC4Log boolean Whether to output logs to C4 log.
--- @field _maxTableLevels integer The maximum depth for table rendering.
local Log = {}
Log.__index = Log

--- @enum LogLevel
Log.LogLevel = {
  PRINT = -1,
  FATAL = 0,
  ERROR = 1,
  WARN = 2,
  INFO = 3,
  DEBUG = 4,
  TRACE = 5,
  ULTRA = 6,
}

--- @type table<string, LogLevel?>
Log.NameToLevel = {
  ["0 - Fatal"] = Log.LogLevel.FATAL,
  ["1 - Error"] = Log.LogLevel.ERROR,
  ["2 - Warning"] = Log.LogLevel.WARN,
  ["3 - Info"] = Log.LogLevel.INFO,
  ["4 - Debug"] = Log.LogLevel.DEBUG,
  ["5 - Trace"] = Log.LogLevel.TRACE,
  ["6 - Ultra"] = Log.LogLevel.ULTRA,
}

--- @type table<LogLevel, string?>
Log.LevelToName = {
  [Log.LogLevel.FATAL] = "0 - Fatal",
  [Log.LogLevel.ERROR] = "1 - Error",
  [Log.LogLevel.WARN] = "2 - Warning",
  [Log.LogLevel.INFO] = "3 - Info",
  [Log.LogLevel.DEBUG] = "4 - Debug",
  [Log.LogLevel.TRACE] = "5 - Trace",
  [Log.LogLevel.ULTRA] = "6 - Ultra",
}

--- @type table<LogLevel, string?>
Log.LevelPrefix = {
  [Log.LogLevel.PRINT] = "[PRINT]",
  [Log.LogLevel.FATAL] = "[FATAL]",
  [Log.LogLevel.ERROR] = "[ERROR]",
  [Log.LogLevel.WARN] = "[WARN ]",
  [Log.LogLevel.INFO] = "[INFO ]",
  [Log.LogLevel.DEBUG] = "[DEBUG]",
  [Log.LogLevel.TRACE] = "[TRACE]",
  [Log.LogLevel.ULTRA] = "[ULTRA]",
}

--- Creates a new instance of the Log class.
--- @return Log log A new instance of the Log class.
function Log:new()
  local instance = setmetatable({}, self)
  instance._logName = ""
  instance._logLevel = Log.LogLevel.INFO
  instance._outputPrint = false
  instance._outputC4Log = false
  instance._maxTableLevels = 10
  return instance
end

--- Sets the name of the log.
--- @param logName? string The name to set for the log.
function Log:setLogName(logName)
  if type(logName) ~= "string" then
    return
  end

  self._logName = logName
end

--- Gets the name of the log.
--- @return string name The name of the log.
function Log:getLogName()
  return self._logName
end

--- Sets the log level.
--- @param level string|integer|nil The log level to set (e.g., 3 or "3 - Info" for INFO).
function Log:setLogLevel(level)
  if type(level) == "string" then
    level = self.NameToLevel[level]
  end
  if type(level) ~= "number" then
    return
  end
  self._logLevel = math.max(self.LogLevel.PRINT, math.min(self.LogLevel.ULTRA, level))
end

--- Gets the current log level.
--- @return LogLevel level The current log level.
function Log:getLogLevel()
  return self._logLevel
end

--- Sets the log output mode.
--- @param logMode? string The log mode (e.g., "Print", "Log", "Print and Log").
function Log:setLogMode(logMode)
  if logMode == nil then
    logMode = ""
  end
  if type(logMode) ~= "string" then
    return
  end
  self:setOutputPrintEnabled(logMode:find("Print") ~= nil)
  self:setOutputC4LogEnabled(logMode:find("Log") ~= nil)
end

--- Enables or disables printing log output.
--- @param value boolean Whether to enable or disable print output.
function Log:setOutputPrintEnabled(value)
  self._outputPrint = value and true or false
end

--- Enables or disables C4 log output.
--- @param value boolean Whether to enable or disable C4 log output.
function Log:setOutputC4LogEnabled(value)
  self._outputC4Log = value and true or false
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
--- @param numArgs integer The number of arguments.
--- @param args any[] The arguments to format.
--- @return string[] formattedArgs The formatted arguments.
local function fixFormatArgs(numArgs, args)
  for i = 1, numArgs do
    if args[i] == nil then
      args[i] = "nil"
    elseif type(args[i]) == "table" then
      args[i] = JSON:encode(args[i])
    elseif type(args[i]) == "number" then
      -- Use tostring_return_period to avoid scientific notation for large integers
      args[i] = tostring_return_period(args[i])
    elseif type(args[i]) ~= "string" then
      args[i] = tostring(args[i])
    end
  end
  return args
end

--- Logs a fatal message.
--- @param sLogText string The log message.
--- @param ... any Additional arguments for formatting.
function Log:fatal(sLogText, ...)
  self:_log(self.LogLevel.FATAL, sLogText, select("#", ...), { ... })
end

--- Logs an error message.
--- @param sLogText string The log message.
--- @param ... any Additional arguments for formatting.
function Log:error(sLogText, ...)
  self:_log(self.LogLevel.ERROR, sLogText, select("#", ...), { ... })
end

--- Logs a warning message.
--- @param sLogText string The log message.
--- @param ... any Additional arguments for formatting.
function Log:warn(sLogText, ...)
  self:_log(self.LogLevel.WARN, sLogText, select("#", ...), { ... })
end

--- Logs an informational message.
--- @param sLogText string The log message.
--- @param ... any Additional arguments for formatting.
function Log:info(sLogText, ...)
  self:_log(self.LogLevel.INFO, sLogText, select("#", ...), { ... })
end

--- Logs a debug message.
--- @param sLogText string The log message.
--- @param ... any Additional arguments for formatting.
function Log:debug(sLogText, ...)
  self:_log(self.LogLevel.DEBUG, sLogText, select("#", ...), { ... })
end

--- Logs a trace message.
--- @param sLogText string The log message.
--- @param ... any Additional arguments for formatting.
function Log:trace(sLogText, ...)
  self:_log(self.LogLevel.TRACE, sLogText, select("#", ...), { ... })
end

--- Logs an ultra-verbose message.
--- @param sLogText string The log message.
--- @param ... any Additional arguments for formatting.
function Log:ultra(sLogText, ...)
  self:_log(self.LogLevel.ULTRA, sLogText, select("#", ...), { ... })
end

--- Logs a message at the given numeric level.
--- @param level LogLevel A LogLevel value (e.g. Log.LogLevel.DEBUG).
--- @param sLogText any The log message.
--- @param ... any Additional arguments for formatting.
function Log:log(level, sLogText, ...)
  self:_log(level, sLogText, select("#", ...), { ... })
end

--- Logs a message directly to stdout.
--- @param sLogText any The log message.
--- @param ... any Additional arguments for formatting.
function Log:print(sLogText, ...)
  self:_log(self.LogLevel.PRINT, sLogText, select("#", ...), { ... })
end

--- Renders a table as a string for logging.
--- @param tValue table The table to render.
--- @param tableText? string The current rendered text (optional).
--- @param sIndent? string The current indentation (optional).
--- @param level? integer The current depth level (optional).
--- @return string renderedTable The rendered table as a string.
function Log:_renderTableAsString(tValue, tableText, sIndent, level)
  if tableText == nil then
    tableText = ""
  end
  if sIndent == nil then
    sIndent = ""
  end
  level = (level or 0) + 1

  if level <= self._maxTableLevels then
    if type(tValue) == "table" then
      for k, v in pairs(tValue) do
        if tableText == "" then
          tableText = sIndent .. tostring(k) .. ":  " .. tostring(v)
        else
          tableText = tableText .. "\n" .. sIndent .. tostring(k) .. ":  " .. tostring(v)
        end
        if type(v) == "table" then
          tableText = self:_renderTableAsString(v, tableText, sIndent .. "   ", level)
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
  --- @type string[]
  local lines = {}
  for s in sLogText:gmatch("[^\r\n]+") do
    table.insert(lines, sPrefix .. s)
  end
  return table.concat(lines, "\n")
end

--- Logs a message with the specified level.
--- @private
--- @param level LogLevel The log level.
--- @param sLogText any The log message.
--- @param numArgs integer The number of arguments.
--- @param args any[] The arguments for formatting.
function Log:_log(level, sLogText, numArgs, args)
  if level == self.LogLevel.PRINT or (self:isEnabled() and self._logLevel >= level) then
    args = fixFormatArgs(numArgs, args)
    if type(sLogText) == "string" then
      sLogText = string.format(sLogText, unpack(args, 1, numArgs))
    end

    if type(sLogText) == "table" then
      sLogText = self:_renderTableAsString(sLogText)
    end

    sLogText = tostring(sLogText)

    if level == self.LogLevel.PRINT or self:isPrintEnabled() then
      print(addLinePrefix(self:_getPrintPrefix(level), sLogText))
    end

    if self:isC4LogEnabled() then
      if self._logLevel < self.LogLevel.INFO then
        C4:ErrorLog(addLinePrefix(self:_getLogPrefix(level), sLogText))
      else
        C4:DebugLog(addLinePrefix(self:_getLogPrefix(level), sLogText))
      end
    end
  end
end

--- Gets the prefix for a log level.
--- @param level LogLevel The log level.
--- @return string|nil prefix The prefix for the log level.
function Log:_getLevelPrefix(level)
  local prefix = self.LevelPrefix[level]
  return prefix and (prefix .. ": ") or nil
end

--- Gets the prefix for print output.
--- @private
--- @param level LogLevel The log level.
--- @return string printPrefix The print prefix.
function Log:_getPrintPrefix(level)
  local ts = tostring(os.date("%c"))
  local prefix = self:_getLevelPrefix(level)
  return prefix and (ts .. " " .. prefix) or ts
end

--- Gets the prefix for C4 log output.
--- @private
--- @param level LogLevel The log level.
--- @return string logPrefix The C4 log prefix.
function Log:_getLogPrefix(level)
  local prefix = ""
  if self._logName ~= "" then
    prefix = "[" .. self._logName .. "]"
  end
  return prefix .. (self:_getLevelPrefix(level) or "")
end

return Log:new()
