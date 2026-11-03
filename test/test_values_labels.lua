-- Property labels in lib/values.lua: a value's property can show the driver's
-- text for each value, such as On/Off for a BOOL, while its variable keeps what
-- programming reads.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_values_labels.lua

local T = require("testlib")
local H = require("values_harness")

local ON_OFF = { [true] = "On", [false] = "Off" }

-- Director keeps Properties current with each write; the shim's UpdateProperty does nothing.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

--- A clean install, loaded, with each named property present and empty.
local function fresh(...)
  H.wipe()
  local values = H.load("restart")
  for _, name in ipairs({ ... }) do
    Properties[name] = ""
  end
  return values
end

--- Counts the writes of the stored values while `fn` runs.
local function writesDuring(fn)
  local set, writes = C4.PersistSetValue, 0
  C4.PersistSetValue = function(self, key, ...)
    writes = writes + (key == "Values" and 1 or 0)
    return set(self, key, ...)
  end
  fn()
  ShimPersistLand()
  C4.PersistSetValue = set
  return writes
end

T.section("a BOOL's property shows its label while the variable reads 0 or 1")
local values = fresh("Output 1 State")
values:update("Output 1 State", true, "BOOL", nil, ON_OFF)
T.eq("the variable", Variables["Output 1 State"], "1")
T.eq("the property", Properties["Output 1 State"], "On")
values:update("Output 1 State", false, "BOOL", nil, ON_OFF)
T.eq("off: the variable", Variables["Output 1 State"], "0")
T.eq("off: the property", Properties["Output 1 State"], "Off")

T.section("labels keyed by the variable's text work the same")
values = fresh("State")
values:update("State", true, "BOOL", nil, { ["1"] = "Open", ["0"] = "Closed" })
T.eq("the property", Properties["State"], "Open")

T.section("a value the labels do not list shows as the variable reads")
values = fresh("Mode")
values:update("Mode", "Eco", "STRING", nil, { Comfort = "Comfort mode" })
T.eq("the property", Properties["Mode"], "Eco")
values:update("Mode", "Comfort", "STRING", nil, { Comfort = "Comfort mode" })
T.eq("a listed one shows its label", Properties["Mode"], "Comfort mode")

T.section("a string is still a suffix")
values = fresh("Humidity")
values:update("Humidity", 41, "NUMBER", nil, " %")
T.eq("the property", Properties["Humidity"], "41 %")
T.eq("the variable", Variables["Humidity"], "41")

T.section("the same labels again are not a change and write nothing")
values = fresh("Output 1 State")
values:update("Output 1 State", true, "BOOL", nil, ON_OFF)
local changed
local writes = writesDuring(function()
  changed = values:update("Output 1 State", true, "BOOL", nil, { [true] = "On", [false] = "Off" })
end)
T.eq("an equal table built anew", changed, false)
T.eq("with no write", writes, 0)

T.section("a change of labels changes the record, as a suffix change does, but not the value")
values = fresh("Output 1 State")
values:update("Output 1 State", true, "BOOL", nil, ON_OFF)
local valueChanged, recordChanged =
  values:update("Output 1 State", true, "BOOL", nil, { [true] = "Closed", [false] = "Open" })
T.eq("other text: the value is the same", valueChanged, false)
T.eq("other text: the record changed", recordChanged, true)
T.eq("shows the new label", Properties["Output 1 State"], "Closed")
valueChanged, recordChanged = values:update("Output 1 State", true, "BOOL", nil, " x")
T.eq("labels to a suffix: the value is the same", valueChanged, false)
T.eq("labels to a suffix: the record changed", recordChanged, true)
T.eq("shows the suffix", Properties["Output 1 State"], "1 x")
valueChanged, recordChanged = values:update("Output 1 State", true, "BOOL", nil, ON_OFF)
T.eq("a suffix to labels: the value is the same", valueChanged, false)
T.eq("a suffix to labels: the record changed", recordChanged, true)
T.eq("shows the label again", Properties["Output 1 State"], "On")

T.section("a driver adopting labels on an update sees no value change for the same value")
values = fresh("Output 1 State")
values:update("Output 1 State", true, "BOOL")
T.eq(
  "the first update with labels, same value: no value change",
  (values:update("Output 1 State", true, "BOOL", nil, ON_OFF)),
  false
)
T.eq("a new value with the labels is a change", (values:update("Output 1 State", false, "BOOL", nil, ON_OFF)), true)
T.eq("and shows its label", Properties["Output 1 State"], "Off")

T.section("restore shows the labels before the driver updates the value again")
values = fresh("Output 1 State")
values:update("Output 1 State", false, "BOOL", nil, ON_OFF)
T.eq("storage keeps them by variable text", H.blob()["Output 1 State"].labels, { ["0"] = "Off", ["1"] = "On" })
T.eq("and no suffix", H.blob()["Output 1 State"].suffix, nil)
for _, how in ipairs({ "update", "restart" }) do
  Properties["Output 1 State"] = ""
  values = H.load(how)
  T.eq("after a " .. how .. ": the property", Properties["Output 1 State"], "Off")
  T.eq("after a " .. how .. ": the variable", Variables["Output 1 State"], "0")
  T.eq(
    "and the driver's next update with the same labels is not a change",
    values:update("Output 1 State", false, "BOOL", nil, ON_OFF),
    false
  )
end

T.finish()
