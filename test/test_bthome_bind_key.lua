--- Tests that a BTHome Bind Key that isn't 32 hex characters is cleared and
--- reported in Driver Status. Composer masks the field, so an error written into
--- it can't be read there.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_bthome_bind_key.lua

local T = require("testlib")
local H = require("ble_driver_harness")

--- Set a property on the loaded driver the way Composer does.
local function setProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

H.use("esphome_bthome")
H.test("a Bind Key that isn't 32 hex characters is cleared and reported in Driver Status", function()
  H.boot()
  setProperty("Bind Key", "0123456789abcdef")
  T.eq("Driver Status", Properties["Driver Status"], "Error: Bind Key must be 32 hex characters")
  T.eq("the field is cleared", Properties["Bind Key"], "")
end)

H.test("a 32 hex character Bind Key is kept", function()
  H.boot()
  setProperty("Bind Key", "0123456789abcdef0123456789abcdef")
  T.eq("Driver Status", Properties["Driver Status"], "Waiting for data")
  T.eq("the field keeps the key", Properties["Bind Key"], "0123456789abcdef0123456789abcdef")
end)

T.finish()
