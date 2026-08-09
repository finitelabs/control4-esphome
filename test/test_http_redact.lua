-- Tests for the credential redaction in src/lib/http.lua.
--
-- Run from the template root:
--   LUA_PATH="$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" luajit test/test_http_redact.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

-- Minimal C4 surface required to load lib.logging / lib.http.
C4 = {}
function C4:ErrorLog() end
function C4:DebugLog() end
function C4:GetDeviceID()
  return 1
end
function C4:GetDeviceData()
  return ""
end
function C4:AllowExecute() end
function InRange(v)
  return v
end
function IsEmpty(v)
  return v == nil or v == ""
end
function urlDo() end

-- vendor/JSON.lua calls this for every number it encodes. Without it any fixture
-- containing a number makes encode throw, and since nearly every assertion below
-- is `not contains(out, secret)`, they would all pass against the error text
-- rather than the payload. Defining it keeps those assertions meaningful.
function tostring_return_period(value)
  return tostring(value)
end

-- Global, not local: src/lib/http.lua reads JSON as a runtime global the way the
-- driver environment provides it.
JSON = require("JSON")
local Http = require("lib.http")

local redact = Http._redact
local isSensitiveKey = Http._isSensitiveKey

local REDACTED = "***REDACTED***"

--- Encode the way lib.logging does, so assertions look at real log output. An
--- encode failure is surfaced as a failed check rather than swallowed into a
--- string, which negative assertions would otherwise pass against.
local function encoded(value)
  local ok, out = pcall(function()
    return JSON:encode(value)
  end)
  if not ok then
    fail = fail + 1
    print(string.format("  FAIL <encode threw>  -> %s", tostring(out)))
    return "\0<encode failed>\0"
  end
  return out
end

local function contains(haystack, needle)
  return tostring(haystack):find(needle, 1, true) ~= nil
end

--------------------------------------------------------------------------------
print("\n[1] Credential keys are masked")
--------------------------------------------------------------------------------
do
  local out = encoded(redact({
    email = "user@example.com",
    password = "hunter2",
    client_secret = "sh-abc",
    ["X-Api-Key"] = "key-123",
    ["Authorization"] = "Bearer abc.def.ghi",
    ["Set-Cookie"] = "session=xyz",
    access_token = "tok_live_1",
    ["X-HatchBaby-Auth"] = "member-token",
    ["X-Amz-Signature"] = "deadbeef",
  }))
  check("password masked", not contains(out, "hunter2"), out)
  check("client_secret masked", not contains(out, "sh-abc"), out)
  check("X-Api-Key masked", not contains(out, "key-123"), out)
  check("Authorization masked", not contains(out, "Bearer abc"), out)
  check("Set-Cookie masked", not contains(out, "session=xyz"), out)
  check("access_token masked", not contains(out, "tok_live_1"), out)
  check("X-HatchBaby-Auth masked", not contains(out, "member-token"), out)
  check("X-Amz-Signature masked", not contains(out, "deadbeef"), out)
  check("non-secret email preserved", contains(out, "user@example.com"), out)
end

--------------------------------------------------------------------------------
print("\n[2] Generic fragments do not over-match (review item 4)")
--------------------------------------------------------------------------------
do
  check("AuthFlow is not sensitive", not isSensitiveKey("AuthFlow"))
  check("AuthParameters is not sensitive", not isSensitiveKey("AuthParameters"))
  check("author is not sensitive", not isSensitiveKey("author"))
  check("tokenizer is not sensitive", not isSensitiveKey("tokenizer"))
  check("Authorization IS sensitive", isSensitiveKey("Authorization"))
  check("X-HatchBaby-Auth IS sensitive", isSensitiveKey("X-HatchBaby-Auth"))
  check("access_token IS sensitive", isSensitiveKey("access_token"))

  -- The real Cognito shape: the diagnostic values stay readable, the secret does not.
  local out = encoded(redact({
    AuthFlow = "USER_PASSWORD_AUTH",
    AuthParameters = { USERNAME = "user@example.com", PASSWORD = "hunter2" },
    ClientId = "abc123",
  }))
  check("AuthFlow value readable", contains(out, "USER_PASSWORD_AUTH"), out)
  check("USERNAME under sensitive parent preserved", contains(out, "user@example.com"), out)
  check("PASSWORD under sensitive parent masked", not contains(out, "hunter2"), out)
  check("ClientId preserved", contains(out, "abc123"), out)
end

--------------------------------------------------------------------------------
print("\n[3] Bare JWTs are caught regardless of key (Cognito Logins map)")
--------------------------------------------------------------------------------
do
  local jwt = "eyJhbGciOiJIUzI1NiJ9." .. string.rep("a", 48) .. ".sig_value_here"
  local out = encoded(redact({ Logins = { ["cognito-identity.amazonaws.com"] = jwt } }))
  check("JWT under an innocuous key masked", not contains(out, jwt), out)

  local short = "abc.def.ghi"
  check("short dotted value left alone", redact(short) == short, redact(short))
end

--------------------------------------------------------------------------------
print("\n[4] Serialized bodies, query strings and URLs")
--------------------------------------------------------------------------------
do
  local body = '{"email":"user@example.com","password":"hunter2"}'
  local out = redact(body)
  check("JSON body password masked", not contains(out, "hunter2"), out)
  check("JSON body email preserved", contains(out, "user@example.com"), out)

  local form = "username=alice&password=hunter2&remember=1"
  out = redact(form)
  check("form password masked", not contains(out, "hunter2"), out)
  check("form username preserved", contains(out, "alice"), out)

  local url = "https://example.com/api?user=alice&access_token=tok_live_1"
  out = redact(url)
  check("URL query token masked", not contains(out, "tok_live_1"), out)
  check("URL path preserved", contains(out, "example.com/api"), out)
end

--------------------------------------------------------------------------------
print("\n[5] Guards fail closed (review items 2 and 3)")
--------------------------------------------------------------------------------
do
  -- Secret buried below the depth cap must not print.
  local deep = { access_token = "tok_live_DEEP", password = "hunter2" }
  for _ = 1, 12 do
    deep = { lvl = deep }
  end
  local out = encoded(redact(deep))
  check("secret past depth cap not leaked", not contains(out, "tok_live_DEEP"), out)
  check("password past depth cap not leaked", not contains(out, "hunter2"), out)
  check("depth cap emits marker", contains(out, REDACTED), out)

  -- A cyclic table must neither leak nor throw in the encoder.
  local cyclic = { name = "root", password = "hunter2" }
  cyclic.self = cyclic
  local encodedCyclic = encoded(redact(cyclic))
  check("cyclic table does not throw", not contains(encodedCyclic, "encode error"), encodedCyclic)
  check("cyclic table password masked", not contains(encodedCyclic, "hunter2"), encodedCyclic)
end

--------------------------------------------------------------------------------
print("\n[6] Caller's tables are never mutated")
--------------------------------------------------------------------------------
do
  local original = { password = "hunter2", nested = { token = "t1" } }
  redact(original)
  check("top-level value untouched", original.password == "hunter2", original.password)
  check("nested value untouched", original.nested.token == "t1", original.nested.token)
end

--------------------------------------------------------------------------------
print("\n[7] Non-table, non-string values pass through")
--------------------------------------------------------------------------------
do
  check("nil passes through", redact(nil) == nil)
  check("number passes through", redact(42) == 42)
  check("boolean passes through", redact(true) == true)
end

--------------------------------------------------------------------------------
print("\n[8] A sensitive key masks its whole subtree, never recurses into it")
--------------------------------------------------------------------------------
do
  -- Children whose own key is unrecognized are protected only by the parent key.
  -- Recursing into a matched parent exposed every one of these.
  local out = encoded(redact({
    credentials = { key = "AKIA_LEAK", pass = "p_LEAK" },
    secret = { data = "s_LEAK" },
    auth = { user = "alice", pass = "a_LEAK" },
    cookie = { jar = "c_LEAK" },
    visible = { note = "keep me" },
  }))
  check("credentials subtree masked", not contains(out, "AKIA_LEAK") and not contains(out, "p_LEAK"), out)
  check("secret subtree masked", not contains(out, "s_LEAK"), out)
  check("auth subtree masked", not contains(out, "a_LEAK"), out)
  check("cookie subtree masked", not contains(out, "c_LEAK"), out)
  check("unrelated subtree preserved", contains(out, "keep me"), out)
end

--------------------------------------------------------------------------------
print("\n[9] Generic fragment plus a credential noun (X-Auth-Key and friends)")
--------------------------------------------------------------------------------
do
  check("X-Auth-Key IS sensitive", isSensitiveKey("X-Auth-Key"))
  check("auth_key IS sensitive", isSensitiveKey("auth_key"))
  check("authKey IS sensitive", isSensitiveKey("authKey"))
  check("token_secret IS sensitive", isSensitiveKey("token_secret"))
  -- The noun rule must not undo the anchoring.
  check("AuthFlow still not sensitive", not isSensitiveKey("AuthFlow"))
  check("AuthParameters still not sensitive", not isSensitiveKey("AuthParameters"))
  check("author still not sensitive", not isSensitiveKey("author"))
  check("primary_key not sensitive on its own", not isSensitiveKey("primary_key"))

  local out = encoded(redact({ ["X-Auth-Key"] = "CF_GLOBAL_KEY_LEAK", ["Content-Type"] = "application/json" }))
  check("X-Auth-Key value masked", not contains(out, "CF_GLOBAL_KEY_LEAK"), out)
  check("Content-Type preserved", contains(out, "application/json"), out)
end

--------------------------------------------------------------------------------
print("\n[10] JSON bodies are decoded, not pattern matched")
--------------------------------------------------------------------------------
do
  -- `[^"]*` stopped at the first escaped quote, leaving the tail of the
  -- credential in the output and producing invalid JSON.
  local body = '{"password":"he said \\"hi\\" ok","next":"visible"}'
  local out = redact(body)
  check("escaped-quote password fully masked", not contains(out, "hi"), out)
  check("sibling still present", contains(out, "visible"), out)
  check("output is valid JSON", (pcall(function()
    return JSON:decode(out)
  end)), out)

  -- Numbers must survive encoding: this is what makes the assertions above real.
  local withNumber = encoded(redact({ expires = 3600, password = "hunter2" }))
  check("numeric field encodes", contains(withNumber, "3600"), withNumber)
  check("password beside a number masked", not contains(withNumber, "hunter2"), withNumber)
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
