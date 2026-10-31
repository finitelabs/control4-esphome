--- The Support Code opens a DriverCentral build's Lua window, which the build closes with `C4:AllowExecute(false)`.
--- The code changes every UTC day: an HMAC of the date under a build secret, which only DriverCentral builds carry
--- and `make support-code` reads to print the day's code.

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")

--- @class SupportCode
--- @field _secret string The build secret the day's code comes from.
--- @field _open boolean Whether this code opened the Lua window.
--- @field _onChange? fun(open: boolean) Called as the code opens and closes the window.
local SupportCode = {}
SupportCode.__index = SupportCode

--#ifdef DRIVERCENTRAL
local SECRET = "__SUPPORT_CODE_SECRET__"
--#else
local SECRET = ""
--#endif

--- Shorter is an unset or unsubstituted secret, whose codes anyone could work out.
local MIN_SECRET_LENGTH = 32

--- Crockford's Base32: no I, L, O or U, so a code read aloud or retyped survives.
local ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

--- A code just after midnight UTC is still taken for this long.
local GRACE_SECONDS = 3600

--- Creates a new `SupportCode` instance.
--- @param secret? string The build secret; the one the build substituted unless given.
--- @return SupportCode supportCode A new `SupportCode` instance.
function SupportCode:new(secret)
  local instance = setmetatable({}, self)
  instance._secret = secret or SECRET
  instance._open = false
  return instance
end

--- The code for a UTC day, without its dash.
--- @param day string The day, `YYYY-MM-DD`.
--- @return string|nil code Ten Crockford Base32 characters, or nil when the secret is unset.
function SupportCode:codeFor(day)
  if #self._secret < MIN_SECRET_LENGTH then
    return nil
  end
  local hex = C4:HMAC("SHA256", self._secret, "Support Code " .. day)
  -- 13 hex digits are 52 bits, exact in a double; the code takes the low 50.
  local n = tonumber(hex:sub(1, 13), 16)
  local code = ""
  for _ = 1, 10 do
    local digit = n % 32
    code = ALPHABET:sub(digit + 1, digit + 1) .. code
    n = (n - digit) / 32
  end
  return code
end

--- Whether a typed value is the code for today, or for yesterday within the grace after midnight.
--- @param value string What was typed.
--- @return boolean accepted
function SupportCode:accepts(value)
  local typed = value:upper():gsub("[^%w]", ""):gsub("O", "0"):gsub("[IL]", "1")
  local now = os.time()
  for _, t in ipairs({ now, now - GRACE_SECONDS }) do
    local code = self:codeFor(os.date("!%Y-%m-%d", t))
    if code and typed == code then
      return true
    end
  end
  return false
end

--- Calls `callback(true)` each time the code opens the Lua window and `callback(false)` each time it closes, for a
--- driver that shows more while it is open.
--- @param callback fun(open: boolean)
function SupportCode:onChange(callback)
  self._onChange = callback
end

--- Takes what was typed into the Support Code property. The property is cleared at once, so the code is never left
--- in the project. Today's code opens the Lua window for an hour, or closes it while open.
--- @param value string The property's value.
function SupportCode:enter(value)
  if value == nil or value == "" then
    return
  end
  UpdateProperty("Support Code", "")
  -- print, not the log: the answer shows in the Lua output whatever Log Mode is.
  if #self._secret < MIN_SECRET_LENGTH then
    print("The Support Code is off in this build")
  elseif not self:accepts(value) then
    print("Support Code not accepted")
  elseif self._open then
    self:close()
  else
    self._open = true
    C4:AllowExecute(true)
    SetTimer("SupportCode", ONE_HOUR, function()
      self:close()
    end)
    print("Support Code accepted: the Lua window is open for an hour, or until the code is entered again")
    if self._onChange then
      self._onChange(true)
    end
  end
end

--- Closes the Lua window the code opened.
function SupportCode:close()
  CancelTimer("SupportCode")
  self._open = false
  C4:AllowExecute(false)
  print("The Lua window is closed")
  if self._onChange then
    self._onChange(false)
  end
end

return SupportCode:new()
