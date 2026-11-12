--- Masks credentials in values bound for a log line or a diagnostics report.

local log = require("lib.logging")

-- JSON, which bodies are decoded with.
require("drivers-common-public.global.lib")

--- Placeholder substituted for any credential-bearing value before it is logged.
--- @type string
local REDACTED = "***REDACTED***"

--- Key fragments specific enough to match anywhere in the key. Matched against
--- the key with every non-alphanumeric character stripped, so "X-Api-Key" ->
--- "xapikey" and "client_secret" -> "clientsecret" both match.
--- @type string[]
local SENSITIVE_SUBSTRINGS = {
  "password",
  "passwd",
  "secret",
  "credential",
  "apikey",
  "authorization",
  "accesstoken",
  "refreshtoken",
  "sessiontoken",
  "idtoken",
  "signature",
}

--- Fragments too generic to match as substrings. These match only as the final
--- word of the key, which is where naming conventions put them ("X-Auth",
--- "access_token", "Set-Cookie"). Anchoring to the last word is what keeps
--- "AuthFlow", "AuthParameters" and "author" readable: those carry no secret,
--- and blanking them hides the diagnostics an installer needs during exactly
--- the auth failure this redaction exists for.
--- @type string[]
local SENSITIVE_LAST_WORDS = {
  "auth",
  "token",
  "cookie",
  "sig",
  "stok", -- TP-Link's session token, sent in the URL path as "/stok=<token>/".
  "pin", -- a HomeKit setup code or a lock PIN.
}

--- Compound credential names, matched against the end of the key with every non-alphanumeric character stripped,
--- so "setupCode", "USER_CODES", "TP_SESSIONID" and "Encryption_Key" match while "passcode_type", "MaxPINCodeLength"
--- and "error_code" stay readable. A plural matches too.
--- @type string[]
local SENSITIVE_SUFFIXES = {
  "passcode",
  "pincode",
  "setupcode",
  "accesscode",
  "usercode",
  "lockcode",
  "sessionid",
  "encryptionkey",
}

--- Nouns that turn a generic fragment anywhere in the key into a credential.
--- Last-word anchoring alone drops "X-Auth-Key" (Cloudflare's global API key
--- header), "auth_key" and "authKey", whose final word is the noun rather than
--- the fragment. Requiring the noun keeps "AuthFlow", "AuthParameters" and
--- "author" out, which is the whole point of the anchoring.
--- @type string[]
local CREDENTIAL_NOUNS = {
  "key",
  "secret",
  "value",
  "hash",
}

--- Split a key into lowercase words, breaking on punctuation and camelCase, so
--- "X-HatchBaby-Auth" -> { "x", "hatch", "baby", "auth" }.
--- @param key any
--- @return string[]
local function keyWords(key)
  local spaced = tostring(key):gsub("(%l)(%u)", "%1_%2"):gsub("(%d)(%a)", "%1_%2"):gsub("(%a)(%d)", "%1_%2")
  local words = {}
  for word in spaced:lower():gmatch("[%a%d]+") do
    words[#words + 1] = word
  end
  return words
end

--- Does this key name mark its value as a credential?
--- @param key any
--- @return boolean
local function isSensitiveKey(key)
  local normalized = tostring(key):lower():gsub("[^%a%d]", "")
  for _, fragment in ipairs(SENSITIVE_SUBSTRINGS) do
    if normalized:find(fragment, 1, true) then
      return true
    end
  end
  for _, suffix in ipairs(SENSITIVE_SUFFIXES) do
    if normalized:sub(-#suffix) == suffix or normalized:sub(-#suffix - 1) == suffix .. "s" then
      return true
    end
  end
  local words = keyWords(key)
  local last = words[#words]
  if not last then
    return false
  end
  for _, fragment in ipairs(SENSITIVE_LAST_WORDS) do
    if last == fragment then
      return true
    end
  end
  -- "<generic fragment> ... <credential noun>", e.g. X-Auth-Key, auth_key.
  local isNoun = false
  for _, noun in ipairs(CREDENTIAL_NOUNS) do
    if last == noun then
      isNoun = true
      break
    end
  end
  if isNoun then
    for _, word in ipairs(words) do
      for _, fragment in ipairs(SENSITIVE_LAST_WORDS) do
        if word == fragment then
          return true
        end
      end
    end
  end
  return false
end

--- Does this value look like a bearer credential regardless of its key? Catches
--- JWTs (three base64url segments), which arrive under innocuous keys such as
--- the identity-provider name in a Cognito `Logins` map.
--- @param value any
--- @return boolean
local function looksLikeSecret(value)
  return type(value) == "string" and value:match("^[%w_-]+%.[%w_-]+%.[%w_-]+$") ~= nil and #value > 60
end

--- Mask the credential in each key=value pair: form-encoded bodies, query
--- strings, and URL path segments such as "/stok=<token>/ds".
--- @param text string
--- @return string
local function redactPairs(text)
  local parts, pos = {}, 1
  while true do
    local at, keyEnd, key = text:find("([%w_%-%.]+)=", pos)
    if not at then
      break
    end
    -- A path segment's value ends at the next "/", "?" or "#"; a query value keeps its "/" since base64 uses it.
    local inPath = text:sub(at - 1, at - 1) == "/"
    local value = text:match(inPath and "^[^/?#&%s]*" or "^[^&%s]*", keyEnd + 1)
    local shown = (value ~= "" and isSensitiveKey(key)) and REDACTED or value
    parts[#parts + 1] = text:sub(pos, at - 1) .. key .. "=" .. shown
    pos = keyEnd + 1 + #value
  end
  parts[#parts + 1] = text:sub(pos)
  return table.concat(parts)
end

--- Mask credentials inside an already-encoded body, query string, or URL.
--- @param text string
--- @return string
local function redactSerialized(text)
  -- JSON object members: "password":"hunter2"
  text = text:gsub('("[%w_%-%.]-")(%s*:%s*)"[^"]*"', function(key, separator)
    if isSensitiveKey(key) then
      return key .. separator .. '"' .. REDACTED .. '"'
    end
  end)
  -- A URL's login: rtsp://user:pass@host. As a browser reads it, the login runs to the last "@" before the
  -- host ends at "/", "?" or "#", so a raw "@" in a password is masked whole and one in a query is left alone.
  text = text:gsub('(://)[^/?#%s"]+@', "%1" .. REDACTED .. "@")
  return redactPairs(text)
end

--- Maximum table nesting redacted before the value is masked outright.
--- @type number
local MAX_REDACT_DEPTH = 8

--- Copy `value` with every credential masked, so secrets never reach the log.
--- Tables are copied rather than mutated, leaving the caller's request intact.
---
--- Both guards below fail closed, returning REDACTED rather than the original
--- value: a redaction control that stops redacting is worse than one that hides
--- too much, and the raw table would otherwise reach JSON:encode intact. The
--- cycle guard also keeps a self-referencing table from throwing in the encoder,
--- which it did before this function existed.
--- @param value any
--- @param depth? number Current nesting level.
--- @param seen? table<table, boolean> Tables already being redacted on this path.
--- @return any
local function redact(value, depth, seen)
  depth = (depth or 0) + 1
  if type(value) == "string" then
    if looksLikeSecret(value) then
      return REDACTED
    end
    -- Decode JSON bodies and redact the table, rather than pattern-matching the
    -- text. The serialized fallback's `[^"]*` stops at the first escaped quote,
    -- so a credential containing one kept its tail and produced invalid JSON;
    -- Lua patterns cannot express escape-aware string matching. Falls back to
    -- the text path when the body is not JSON or does not decode.
    local trimmed = value:match("^%s*(.-)%s*$")
    if JSON and (trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[") then
      local ok, decoded = pcall(function()
        return JSON:decode(trimmed)
      end)
      if ok and type(decoded) == "table" then
        local encodedOk, reencoded = pcall(function()
          return JSON:encode(redact(decoded, depth, seen))
        end)
        if encodedOk and type(reencoded) == "string" then
          return reencoded
        end
      end
    end
    return redactSerialized(value)
  end
  if type(value) ~= "table" then
    return value
  end
  if depth > MAX_REDACT_DEPTH then
    return REDACTED
  end
  seen = seen or {}
  if seen[value] then
    return REDACTED
  end
  seen[value] = true
  local copy = {}
  for k, v in pairs(value) do
    if isSensitiveKey(k) or looksLikeSecret(v) then
      -- Mask the whole subtree, never recurse into it. Recursing would expose
      -- children whose own key is not recognized ("credentials" holding "key"
      -- and "pass"), where the parent key was the only thing protecting them.
      -- That is the same fail-open direction the guards above exist to prevent.
      copy[k] = REDACTED
    else
      copy[k] = redact(v, depth, seen)
    end
  end
  seen[value] = nil
  return copy
end

--- What a log line shows of a value: masked as `value` masks it, except at Ultra, which prints everything as it is.
--- Anything that leaves the controller, such as a Cloud Monitoring report, uses `value`.
--- @param value any
--- @return any
local function forLog(value)
  if log:getLogLevel() >= log.LogLevel.ULTRA then
    return value
  end
  return redact(value)
end

return {
  REDACTED = REDACTED,
  value = redact,
  forLog = forLog,
  text = redactSerialized,
  isSensitiveKey = isSensitiveKey,
}
