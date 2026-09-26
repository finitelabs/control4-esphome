-- url.lua decoding a response whose Content-Type says JSON. Snap One's json.lua
-- returned nil for a body it could not parse; the JSON.lua vendored here raises,
-- so ProcessResponse threw before urlDo's callback ran and Http:request never
-- settled.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_url_json.lua

local T = require("testlib")

require("c4_shim")
local http = require("lib.http")

-- urlDo otherwise builds it from driver.xml fields the shim does not model.
USER_AGENT = "test"

--- Answer each C4:url() transfer with one JSON-typed response carrying body. On the
--- controller OnDone runs after Get has returned, so an error in it never reaches the caller.
local function respond(body)
  C4.url = function()
    local transfer = {}
    function transfer:SetOptions() end
    function transfer:OnDone(callback)
      self.onDone = callback
    end
    function transfer:Get()
      local response = { code = 200, headers = { ["Content-Type"] = "application/json" }, body = body }
      pcall(self.onDone, self, { response }, 0, nil)
    end
    return transfer
  end
end

--- GET a response carrying body and report how the request settled.
local function get(body)
  respond(body)
  local result = { settled = false }
  http:get("https://example.invalid/api"):next(function(response)
    result.settled, result.body = true, response.body
  end, function(err)
    result.settled, result.err = true, err
  end)
  return result
end

T.section("a body that is not JSON reaches the callback as { body }")
for _, body in ipairs({ "<html>502 Bad Gateway</html>", '{"a":1' }) do
  local result = get(body)
  T.check("the request settles for " .. body, result.settled)
  T.eq("with the body wrapped for " .. body, result.body, { body })
end

T.section("a JSON body is decoded")
T.eq("an object", get('{"a":1,"b":[true]}').body, { a = 1, b = { true } })
T.eq("false stays false", get("false").body, false)

T.finish()
