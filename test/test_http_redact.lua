-- Tests for the credential redaction in src/lib/http.lua.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_http_redact.lua

local T = require("testlib")

-- The shim supplies the C4 surface. lib.http pulls in lib.utils (IsEmpty,
-- InRange) and global.lib (tostring_return_period, JSON) through its own
-- requires, so nothing is restubbed here.
require("c4_shim")

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
    T.check("<encode threw>", false, out)
    return "\0<encode failed>\0"
  end
  return out
end

--------------------------------------------------------------------------------
T.section("Credential keys are masked")
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
  T.excludes("password masked", out, "hunter2")
  T.excludes("client_secret masked", out, "sh-abc")
  T.excludes("X-Api-Key masked", out, "key-123")
  T.excludes("Authorization masked", out, "Bearer abc")
  T.excludes("Set-Cookie masked", out, "session=xyz")
  T.excludes("access_token masked", out, "tok_live_1")
  T.excludes("X-HatchBaby-Auth masked", out, "member-token")
  T.excludes("X-Amz-Signature masked", out, "deadbeef")
  T.contains("non-secret email preserved", out, "user@example.com")
end

--------------------------------------------------------------------------------
T.section("Generic fragments do not over-match (review item 4)")
--------------------------------------------------------------------------------
do
  T.check("AuthFlow is not sensitive", not isSensitiveKey("AuthFlow"))
  T.check("AuthParameters is not sensitive", not isSensitiveKey("AuthParameters"))
  T.check("author is not sensitive", not isSensitiveKey("author"))
  T.check("tokenizer is not sensitive", not isSensitiveKey("tokenizer"))
  T.check("Authorization IS sensitive", isSensitiveKey("Authorization"))
  T.check("X-HatchBaby-Auth IS sensitive", isSensitiveKey("X-HatchBaby-Auth"))
  T.check("access_token IS sensitive", isSensitiveKey("access_token"))

  -- The real Cognito shape: the diagnostic values stay readable, the secret does not.
  local out = encoded(redact({
    AuthFlow = "USER_PASSWORD_AUTH",
    AuthParameters = { USERNAME = "user@example.com", PASSWORD = "hunter2" },
    ClientId = "abc123",
  }))
  T.contains("AuthFlow value readable", out, "USER_PASSWORD_AUTH")
  T.contains("USERNAME under sensitive parent preserved", out, "user@example.com")
  T.excludes("PASSWORD under sensitive parent masked", out, "hunter2")
  T.contains("ClientId preserved", out, "abc123")
end

--------------------------------------------------------------------------------
T.section("Bare JWTs are caught regardless of key (Cognito Logins map)")
--------------------------------------------------------------------------------
do
  local jwt = "eyJhbGciOiJIUzI1NiJ9." .. string.rep("a", 48) .. ".sig_value_here"
  local out = encoded(redact({ Logins = { ["cognito-identity.amazonaws.com"] = jwt } }))
  T.excludes("JWT under an innocuous key masked", out, jwt)

  local short = "abc.def.ghi"
  T.check("short dotted value left alone", redact(short) == short, redact(short))
end

--------------------------------------------------------------------------------
T.section("Serialized bodies, query strings and URLs")
--------------------------------------------------------------------------------
do
  local body = '{"email":"user@example.com","password":"hunter2"}'
  local out = redact(body)
  T.excludes("JSON body password masked", out, "hunter2")
  T.contains("JSON body email preserved", out, "user@example.com")

  local form = "username=alice&password=hunter2&remember=1"
  out = redact(form)
  T.excludes("form password masked", out, "hunter2")
  T.contains("form username preserved", out, "alice")

  local url = "https://example.com/api?user=alice&access_token=tok_live_1"
  out = redact(url)
  T.excludes("URL query token masked", out, "tok_live_1")
  T.contains("URL path preserved", out, "example.com/api")
end

--------------------------------------------------------------------------------
T.section("Guards fail closed (review items 2 and 3)")
--------------------------------------------------------------------------------
do
  -- Secret buried below the depth cap must not print.
  local deep = { access_token = "tok_live_DEEP", password = "hunter2" }
  for _ = 1, 12 do
    deep = { lvl = deep }
  end
  local out = encoded(redact(deep))
  T.excludes("secret past depth cap not leaked", out, "tok_live_DEEP")
  T.excludes("password past depth cap not leaked", out, "hunter2")
  T.contains("depth cap emits marker", out, REDACTED)

  -- A cyclic table must neither leak nor throw in the encoder.
  local cyclic = { name = "root", password = "hunter2" }
  cyclic.self = cyclic
  local encodedCyclic = encoded(redact(cyclic))
  T.excludes("cyclic table does not throw", encodedCyclic, "encode error")
  T.excludes("cyclic table password masked", encodedCyclic, "hunter2")
end

--------------------------------------------------------------------------------
T.section("Caller's tables are never mutated")
--------------------------------------------------------------------------------
do
  local original = { password = "hunter2", nested = { token = "t1" } }
  redact(original)
  T.check("top-level value untouched", original.password == "hunter2", original.password)
  T.check("nested value untouched", original.nested.token == "t1", original.nested.token)
end

--------------------------------------------------------------------------------
T.section("Non-table, non-string values pass through")
--------------------------------------------------------------------------------
do
  T.check("nil passes through", redact(nil) == nil)
  T.check("number passes through", redact(42) == 42)
  T.check("boolean passes through", redact(true) == true)
end

--------------------------------------------------------------------------------
T.section("A sensitive key masks its whole subtree, never recurses into it")
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
  T.excludes("credentials subtree key masked", out, "AKIA_LEAK")
  T.excludes("credentials subtree pass masked", out, "p_LEAK")
  T.excludes("secret subtree masked", out, "s_LEAK")
  T.excludes("auth subtree masked", out, "a_LEAK")
  T.excludes("cookie subtree masked", out, "c_LEAK")
  T.contains("unrelated subtree preserved", out, "keep me")
end

--------------------------------------------------------------------------------
T.section("Generic fragment plus a credential noun (X-Auth-Key and friends)")
--------------------------------------------------------------------------------
do
  T.check("X-Auth-Key IS sensitive", isSensitiveKey("X-Auth-Key"))
  T.check("auth_key IS sensitive", isSensitiveKey("auth_key"))
  T.check("authKey IS sensitive", isSensitiveKey("authKey"))
  T.check("token_secret IS sensitive", isSensitiveKey("token_secret"))
  -- The noun rule must not undo the anchoring.
  T.check("AuthFlow still not sensitive", not isSensitiveKey("AuthFlow"))
  T.check("AuthParameters still not sensitive", not isSensitiveKey("AuthParameters"))
  T.check("author still not sensitive", not isSensitiveKey("author"))
  T.check("primary_key not sensitive on its own", not isSensitiveKey("primary_key"))

  local out = encoded(redact({ ["X-Auth-Key"] = "CF_GLOBAL_KEY_LEAK", ["Content-Type"] = "application/json" }))
  T.excludes("X-Auth-Key value masked", out, "CF_GLOBAL_KEY_LEAK")
  T.contains("Content-Type preserved", out, "application/json")
end

--------------------------------------------------------------------------------
T.section("JSON bodies are decoded, not pattern matched")
--------------------------------------------------------------------------------
do
  -- `[^"]*` stopped at the first escaped quote, leaving the tail of the
  -- credential in the output and producing invalid JSON.
  local body = '{"password":"he said \\"hi\\" ok","next":"visible"}'
  local out = redact(body)
  T.excludes("escaped-quote password fully masked", out, "hi")
  T.contains("sibling still present", out, "visible")
  T.check("output is valid JSON", (pcall(function()
    return JSON:decode(out)
  end)), out)

  -- Numbers must survive encoding: this is what makes the assertions above real.
  local withNumber = encoded(redact({ expires = 3600, password = "hunter2" }))
  T.contains("numeric field encodes", withNumber, "3600")
  T.excludes("password beside a number masked", withNumber, "hunter2")
end

T.finish()
