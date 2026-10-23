--- Tests that the esphome_yale driver keeps its Yale cloud session after Verify
--- and Fetch Keys and reads the lock's offline key again when it may have
--- changed: once a day, and at once when the lock turns the key down.
---
--- The key used to be fetched once by hand. When it changed, the lock dropped
--- the link at the key exchange and the driver only showed it waiting for the
--- next poll.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_yale_key_refresh.lua

local T = require("testlib")
local H = require("ble_driver_harness")
local yale_protocol = require("esphome.ble.yale_protocol")
local persist = require("lib.persist")
local http = require("lib.http")
local JSON = require("JSON")

H.use("esphome_yale")

local PROXY, ESPHOME = 5001, 5002
local MAC = "AA:BB:CC:DD:EE:FF"
local OLD_KEY = string.rep("0123456789abcdef", 2)
local NEW_KEY = string.rep("fedcba9876543210", 2)
local LOCK_ID = "LOCK1"
local API = "https://api-production.august.com"
local ONE_DAY_S = 24 * 60 * 60

local SERVICES = SerializeSafe({
  {
    uuid = H.uuidPairs(yale_protocol.UUID.SERVICE),
    characteristics = {
      { uuid = H.uuidPairs(yale_protocol.UUID.WRITE), handle = 20 },
      { uuid = H.uuidPairs(yale_protocol.UUID.READ), handle = 22 },
      { uuid = H.uuidPairs(yale_protocol.UUID.SECURE_WRITE), handle = 24 },
      { uuid = H.uuidPairs(yale_protocol.UUID.SECURE_READ), handle = 26 },
    },
  },
})

-- The shim has only padded AES-128-CBC: pass blocks through so the lock's
-- answers can be written as plaintext
function C4:Encrypt(_cipher, _key, _iv, data)
  return data
end
function C4:Decrypt(_cipher, _key, _iv, data)
  return data
end

--- A token shaped like the cloud's: a JWT whose payload carries "exp".
local function jwt(name, expiresIn)
  local payload = C4:Base64Encode(JSON:encode({ exp = os.time() + expiresIn, sub = name }))
  return "eyJhbGciOiJIUzI1NiJ9." .. payload:gsub("+", "-"):gsub("/", "_"):gsub("=", "") .. ".sig"
end

local FRESH_TOKEN = jwt("fresh", 60 * ONE_DAY_S)

--------------------------------------------------------------------------------
-- The cloud, answering from a table of routes
--------------------------------------------------------------------------------

--- Requests the driver made: { method, path, token, body }
local requests = {}
--- "METHOD /path" -> function(request) returning a response, or an error with `code`
local routes = {}

local function answer(method, url, data, headers)
  local path = url:sub(#API + 1)
  local request = { method = method, path = path, token = headers and headers["x-august-access-token"], body = data }
  table.insert(requests, request)
  local route = routes[method .. " " .. path]
  if not route then
    return reject({ error = "no route for " .. method .. " " .. path, code = 500 })
  end
  local result = route(request)
  if result.error then
    return reject(result)
  end
  return resolve({ url = url, code = 200, headers = result.headers or {}, body = result.body })
end

function http:get(url, headers)
  return answer("GET", url, nil, headers)
end
function http:post(url, data, headers)
  return answer("POST", url, data, headers)
end

local function count(method, path)
  local n = 0
  for _, r in ipairs(requests) do
    if r.method == method and r.path == path then
      n = n + 1
    end
  end
  return n
end

--- The lock's detail, carrying `key` as its loaded offline key.
local function lockDetail(key, slot)
  return function()
    return { body = JSON:encode({ LockID = LOCK_ID, OfflineKeys = { loaded = { { key = key, slot = slot or 1 } } } }) }
  end
end

--------------------------------------------------------------------------------
-- Driver helpers
--------------------------------------------------------------------------------

--- Boot with the given properties and, unless `session` is false, a kept
--- session holding `session` as its token.
local function boot(properties, session)
  local props = {
    ["Offline Key"] = OLD_KEY,
    ["MAC Address"] = MAC,
    ["Yale Email"] = "me@example.com",
    ["Yale Password"] = "secret",
  }
  for k, v in pairs(properties or {}) do
    props[k] = v
  end
  H.boot(props, function()
    if session == false then
      persist:delete("YALE_ACCESS_TOKEN")
      persist:delete("YALE_LOCK_ID")
    else
      persist:set("YALE_ACCESS_TOKEN", session or FRESH_TOKEN, true)
      persist:set("YALE_LOCK_ID", LOCK_ID)
    end
  end)
  requests = {}
  routes = {}
end

local function keptToken()
  return persist:get("YALE_ACCESS_TOKEN", nil, true)
end

local function lock()
  H.rfp(PROXY, "LOCK")
end

--- Up to the key exchange being on the wire, awaiting the lock's answer.
local function startHandshake()
  H.rfp(ESPHOME, "CONNECTED", { name = "Front Door", mac = MAC, services = SERVICES })
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "26", success = "true" })
end

local function secureAnswer(opcode)
  return C4:Base64Encode(string.char(opcode) .. string.rep("\0", 3) .. "LOCKBYTE" .. string.rep("\0", 6))
end

--- The lock answering the handshake: it took the key.
local function handshakeAnswered()
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", {
    handle = "26",
    data = secureAnswer(yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP),
  })
  H.rfp(
    ESPHOME,
    "GATT_NOTIFY_DATA",
    { handle = "26", data = secureAnswer(yale_protocol.Opcode.SEC_INITIALIZATION_RESP) }
  )
end

--- The lock dropping the link after the key exchange: it could not decrypt it.
local function keyRefused()
  startHandshake()
  H.rfp(ESPHOME, "GATT_WRITE_RESPONSE", { success = "true", error = "0" })
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
end

--- The lock answering the handshake with the wrong opcode at `step`.
local function handshakeMismatched(step)
  startHandshake()
  H.rfp(ESPHOME, "GATT_WRITE_RESPONSE", { success = "true", error = "0" })
  if step == "init" then
    H.rfp(ESPHOME, "GATT_NOTIFY_DATA", {
      handle = "26",
      data = secureAnswer(yale_protocol.Opcode.SEC_MOBILE_TO_LOCK_KEY_EXCHANGE_RESP),
    })
  end
  H.rfp(ESPHOME, "GATT_NOTIFY_DATA", { handle = "26", data = secureAnswer(0x7F) })
end

--- The lock and unlock commands written to the lock, in order.
local function lockWrites()
  local writes = {}
  for _, s in ipairs(H.sent) do
    if s.command == "GATT_WRITE" and s.params.handle == "20" then
      local opcode = string.byte(C4:Base64Decode(s.params.data), 2)
      if opcode == yale_protocol.Opcode.LOCK then
        table.insert(writes, "LOCK")
      elseif opcode == yale_protocol.Opcode.UNLOCK then
        table.insert(writes, "UNLOCK")
      end
    end
  end
  return table.concat(writes, ",")
end

--------------------------------------------------------------------------------
-- Verify and Fetch Keys
--------------------------------------------------------------------------------

local function signInRoutes(locks)
  routes["POST /session"] = function()
    return { headers = { ["x-august-access-token"] = "unvalidated" } }
  end
  routes["POST /validation/email"] = function()
    return {}
  end
  routes["POST /validate/email"] = function()
    return { headers = { ["x-august-access-token"] = FRESH_TOKEN } }
  end
  routes["GET /users/locks/mine"] = function()
    return { body = JSON:encode(locks) }
  end
end

local TWO_LOCKS = {
  OTHER = { LockName = "Back Door", macAddress = "11:22:33:44:55:66" },
  [LOCK_ID] = { LockName = "Front Door", macAddress = MAC },
}

H.test("Verify and Fetch Keys keeps the session and checks daily", function()
  boot(nil, false)
  signInRoutes(TWO_LOCKS)
  routes["GET /locks/" .. LOCK_ID] = lockDetail(NEW_KEY, 2)

  EC.Request_Verification_Code()
  EC.Verify_And_Fetch_Keys({ ["Verification Code"] = "123456" })
  T.eq("the lock matching the MAC gives the key", Properties["Offline Key"], NEW_KEY)
  T.eq("and the slot", Properties["Key Slot"], "2")
  T.eq("status reports it", Properties["Yale Cloud Status"], "Keys fetched successfully")
  T.eq("the validated token is kept", keptToken(), FRESH_TOKEN)
  T.eq("with the lock's ID", persist:get("YALE_LOCK_ID"), LOCK_ID)
  T.truthy("a key check is armed", H.armed("KeyCheck"))
  T.eq("for a day out", H.delay("KeyCheck"), ONE_DAY)
end)

H.test("several locks and no MAC to match is an error, not a guess", function()
  boot({ ["MAC Address"] = "Unknown" }, false)
  signInRoutes(TWO_LOCKS)
  EC.Request_Verification_Code()
  EC.Verify_And_Fetch_Keys({ ["Verification Code"] = "123456" })
  T.eq("no lock's key is fetched", count("GET", "/locks/" .. LOCK_ID) + count("GET", "/locks/OTHER"), 0)
  T.eq("the key is left alone", Properties["Offline Key"], OLD_KEY)
  T.truthy(
    "status says to connect first",
    tostring(Properties["Yale Cloud Status"]):find("connect to this one once", 1, true) ~= nil
  )
  T.eq("and no session is kept", keptToken(), nil)
end)

H.test("an account with one lock uses it before its MAC is known", function()
  boot({ ["MAC Address"] = "Unknown" }, false)
  signInRoutes({ [LOCK_ID] = { LockName = "Front Door", macAddress = MAC } })
  routes["GET /locks/" .. LOCK_ID] = lockDetail(NEW_KEY)
  EC.Request_Verification_Code()
  EC.Verify_And_Fetch_Keys({ ["Verification Code"] = "123456" })
  T.eq("the only lock's key is fetched", Properties["Offline Key"], NEW_KEY)
end)

H.test("an HTTP failure shows its message", function()
  boot(nil, false)
  routes["POST /session"] = function()
    return { error = "HTTP POST request to /session failed with status code 401", code = 401 }
  end
  EC.Request_Verification_Code()
  T.eq(
    "status shows the failure, not a table",
    Properties["Yale Cloud Status"],
    "Error: HTTP POST request to /session failed with status code 401"
  )
end)

--------------------------------------------------------------------------------
-- The daily check
--------------------------------------------------------------------------------

H.test("the first check comes a few minutes after the driver starts", function()
  boot()
  T.truthy("a key check is armed", H.armed("KeyCheck"))
  T.eq("five minutes out", H.delay("KeyCheck"), 5 * ONE_MINUTE)
end)

H.test("without a session nothing is checked", function()
  boot(nil, false)
  T.falsy("no key check is armed", H.armed("KeyCheck"))
end)

H.test("a check that finds a new key sets it and connects with it", function()
  boot()
  routes["GET /locks/" .. LOCK_ID] = lockDetail(NEW_KEY)
  T.truthy("the check fires", H.fire("KeyCheck"))
  T.eq("the token is fresh, so it is not renewed", count("GET", "/users/houses/mine"), 0)
  T.eq("the request is signed in", requests[1].token, FRESH_TOKEN)
  T.eq("the new key is set", Properties["Offline Key"], NEW_KEY)
  T.truthy("status says so", tostring(Properties["Yale Cloud Status"]):find("^Keys updated") ~= nil)
  T.eq("and the lock is connected at once", H.count("CONNECT", ESPHOME), 1)
  T.eq("the next check is a day out", H.delay("KeyCheck"), ONE_DAY)
end)

H.test("a check that finds the same key changes nothing", function()
  boot()
  routes["GET /locks/" .. LOCK_ID] = lockDetail(OLD_KEY:upper())
  H.fire("KeyCheck")
  T.eq("the key is kept", Properties["Offline Key"]:lower(), OLD_KEY)
  T.truthy("status shows the check", tostring(Properties["Yale Cloud Status"]):find("^Keys checked") ~= nil)
  T.eq("nothing connects", H.count("CONNECT", ESPHOME), 0)
  T.truthy("the next check is armed", H.armed("KeyCheck"))
end)

H.test("a token near expiry is renewed before the check", function()
  local expiring = jwt("expiring", 2 * ONE_DAY_S)
  boot(nil, expiring)
  routes["GET /users/houses/mine"] = function()
    return { headers = { ["x-august-access-token"] = FRESH_TOKEN } }
  end
  routes["GET /locks/" .. LOCK_ID] = lockDetail(OLD_KEY)
  H.fire("KeyCheck")
  T.eq("it is renewed", count("GET", "/users/houses/mine"), 1)
  T.eq("with the expiring token", requests[1].token, expiring)
  T.eq("the renewed token is kept", keptToken(), FRESH_TOKEN)
  T.eq("and signs the lock request", requests[2].token, FRESH_TOKEN)
end)

for _, code in ipairs({ 401, 403 }) do
  H.test("a token the cloud turns down with " .. code .. " ends the session", function()
    boot()
    routes["GET /locks/" .. LOCK_ID] = function()
      return { error = "HTTP GET request failed with status code " .. code, code = code }
    end
    H.fire("KeyCheck")
    T.eq("the token is dropped", keptToken(), nil)
    T.eq(
      "status says to sign in again",
      Properties["Yale Cloud Status"],
      "Sign-in expired - run Request Verification Code"
    )
    T.falsy("and nothing more is checked", H.armed("KeyCheck"))
    T.eq("the key is left alone", Properties["Offline Key"], OLD_KEY)
  end)
end

H.test("a failed request keeps the session for the next check", function()
  boot()
  routes["GET /locks/" .. LOCK_ID] = function()
    return { error = "HTTP GET request failed; timeout" }
  end
  H.fire("KeyCheck")
  T.eq("the token is kept", keptToken(), FRESH_TOKEN)
  T.eq("status shows the failure", Properties["Yale Cloud Status"], "Error: HTTP GET request failed; timeout")
  T.truthy("and the next check is armed", H.armed("KeyCheck"))
end)

H.test("a session without a lock ID finds the lock again", function()
  boot()
  persist:delete("YALE_LOCK_ID")
  routes["GET /users/locks/mine"] = function()
    return { body = JSON:encode(TWO_LOCKS) }
  end
  routes["GET /locks/" .. LOCK_ID] = lockDetail(OLD_KEY)
  H.fire("KeyCheck")
  T.eq("it lists the locks", count("GET", "/users/locks/mine"), 1)
  T.eq("and keeps the one matching the MAC", persist:get("YALE_LOCK_ID"), LOCK_ID)
end)

--------------------------------------------------------------------------------
-- The lock turning the key down
--------------------------------------------------------------------------------

H.test("a lock that drops the link at the key exchange gets the new key at once", function()
  boot()
  routes["GET /locks/" .. LOCK_ID] = lockDetail(NEW_KEY)
  lock()
  H.clearSent()
  keyRefused()
  T.eq("the cloud is asked at once", count("GET", "/locks/" .. LOCK_ID), 1)
  T.eq("the new key is set", Properties["Offline Key"], NEW_KEY)
  T.eq("and the lock is connected again with it", H.count("CONNECT", ESPHOME), 1)
end)

H.test("a lock the rejected key held up goes out with the new key", function()
  boot()
  routes["GET /locks/" .. LOCK_ID] = lockDetail(NEW_KEY)
  lock()
  keyRefused()
  T.eq("the new key is set", Properties["Offline Key"], NEW_KEY)
  startHandshake()
  handshakeAnswered()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "true" })
  T.eq("the lock is what goes out", lockWrites(), "LOCK")
end)

H.test("in Persistent mode the held-up lock goes out once", function()
  boot({ ["Connection Mode"] = "Persistent" })
  routes["GET /locks/" .. LOCK_ID] = lockDetail(NEW_KEY)
  lock()
  keyRefused()
  T.eq("the new key is set", Properties["Offline Key"], NEW_KEY)
  T.eq("the backoff retry is dropped", H.armed("Reconnect"), false)
  startHandshake()
  handshakeAnswered()
  H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "true" })
  T.eq("the lock goes out once", lockWrites(), "LOCK")
end)

for _, step in ipairs({ "key exchange", "init" }) do
  H.test("a wrong reply to the " .. step .. " drops the link and retries with the new key", function()
    boot()
    routes["GET /locks/" .. LOCK_ID] = lockDetail(NEW_KEY)
    lock()
    H.clearSent()
    handshakeMismatched(step)
    T.eq("the link is dropped at once", H.count("DISCONNECT", ESPHOME), 1)
    T.eq("the new key is set", Properties["Offline Key"], NEW_KEY)
    T.eq("and the lock is connected again with it", H.count("CONNECT", ESPHOME), 1)

    local status = Properties["Yale Cloud Status"]
    H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
    T.eq("the old link's drop is not a second refusal", count("GET", "/locks/" .. LOCK_ID), 1)
    T.eq("and leaves the status alone", Properties["Yale Cloud Status"], status)

    startHandshake()
    handshakeAnswered()
    H.rfp(ESPHOME, "GATT_NOTIFY_SUBSCRIBED", { handle = "22", success = "true" })
    T.eq("the lock goes out", lockWrites(), "LOCK")
  end)
end

H.test("a key refused five times in a row with nothing newer in the cloud says so", function()
  boot()
  routes["GET /locks/" .. LOCK_ID] = lockDetail(OLD_KEY)
  lock()
  keyRefused()
  T.eq("the cloud is asked at the first refusal", count("GET", "/locks/" .. LOCK_ID), 1)
  local checked = Properties["Yale Cloud Status"]
  T.truthy("one refusal is not reported", checked:find("^Keys checked "))
  T.eq("nothing connects early", H.count("CONNECT", ESPHOME), 1)

  for _ = 2, 4 do
    H.fire("PollCycle")
    keyRefused()
  end
  T.eq("nor are four", Properties["Yale Cloud Status"], checked)
  T.eq("and the cloud is not asked again within 15 minutes", count("GET", "/locks/" .. LOCK_ID), 1)

  H.fire("PollCycle")
  keyRefused()
  T.eq(
    "the fifth is",
    Properties["Yale Cloud Status"],
    "Lock rejected the offline key - no newer key in the Yale cloud"
  )

  local realTime = os.time
  os.time = function(...) -- luacheck: ignore
    if select("#", ...) > 0 then
      return realTime(...)
    end
    return realTime() + 16 * 60
  end
  local ok, err = pcall(function()
    H.fire("PollCycle")
    keyRefused()
  end)
  os.time = realTime -- luacheck: ignore
  assert(ok, err)
  T.eq("one after fifteen minutes asks again", count("GET", "/locks/" .. LOCK_ID), 2)
  T.eq(
    "and still says so",
    Properties["Yale Cloud Status"],
    "Lock rejected the offline key - no newer key in the Yale cloud"
  )

  H.fire("PollCycle")
  startHandshake()
  handshakeAnswered()
  T.eq("once the lock takes the key the earlier status is back", Properties["Yale Cloud Status"], checked)
end)

H.test("a handshake the lock takes starts the count again", function()
  boot()
  routes["GET /locks/" .. LOCK_ID] = lockDetail(OLD_KEY)
  lock()
  for _ = 1, 4 do
    keyRefused()
    H.fire("PollCycle")
  end
  startHandshake()
  handshakeAnswered()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  local status = Properties["Yale Cloud Status"]
  H.fire("PollCycle")
  keyRefused()
  T.eq("a refusal after it is not reported", Properties["Yale Cloud Status"], status)
end)

H.test("a key refused five times without a session says to fetch keys again", function()
  boot(nil, false)
  lock()
  local status = Properties["Yale Cloud Status"]
  keyRefused()
  T.eq("nothing is asked of the cloud", #requests, 0)
  for _ = 2, 4 do
    H.fire("PollCycle")
    keyRefused()
  end
  T.eq("four refusals are not reported", Properties["Yale Cloud Status"], status)
  H.fire("PollCycle")
  keyRefused()
  T.eq("the fifth says what to do", Properties["Yale Cloud Status"], "Lock rejected the offline key - fetch keys again")
end)

H.test("a link lost after the lock took the key is not a refusal", function()
  boot()
  lock()
  startHandshake()
  handshakeAnswered()
  H.rfp(ESPHOME, "DISCONNECTED", { reason = "BLE connection closed" })
  T.eq("nothing is asked of the cloud", #requests, 0)
end)

--------------------------------------------------------------------------------
-- Signing out
--------------------------------------------------------------------------------

H.test("Reset Driver signs out of the cloud", function()
  boot()
  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  T.eq("the token is dropped", keptToken(), nil)
  T.eq("and the lock ID", persist:get("YALE_LOCK_ID"), nil)
  T.falsy("no key check is left", H.armed("KeyCheck"))
end)

H.test("a new Yale Email signs out of the old account", function()
  boot()
  Properties["Yale Email"] = "someone-else@example.com"
  OnPropertyChanged("Yale Email")
  T.eq("the token is dropped", keptToken(), nil)
  T.falsy("no key check is left", H.armed("KeyCheck"))
end)

T.finish()
