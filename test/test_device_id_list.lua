-- Tests for the callback index handed out by ParseDeviceIdList (src/lib/utils.lua).
--
-- The third callback argument is the entry's 1-based position among the
-- non-empty entries of the device ID list (`gmatch` matches `[^,]+`, so
-- `"100,,300"` gives `300` index 2). Consumers publish it as a stable
-- identifier rather than as display ordering: control4-home-connect uses it as
-- a HomeKit outlet `Identifier`, as the key of its `outlets` table, and as part
-- of an LRU cache key, and Apple Home binds accessories and scenes to those
-- numbers. So the index a device gets
-- must not depend on whether the *other* entries in the list resolved -- if it
-- does, one transient GetDevice failure silently repoints already-published
-- accessories at different physical devices. Regression test for DRV-84.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_device_id_list.lua

local T = require("testlib")

--- A fake project. GetDevice() asks C4:GetDevices first and falls back to
--- synthesizing a room device from C4:GetDeviceDisplayName, so it returns nil
--- only when *both* come up empty. `hidden` models that: it takes a device out
--- of both lookups, which is the transient failure these tests are about. A
--- device ID absent from PROJECT entirely is unresolvable the same way.
local PROJECT = {
  [100] = { deviceName = "Outlet A", driverFileName = "control4_outlet.c4i", roomId = "1", roomName = "Office" },
  [200] = { deviceName = "Outlet B", driverFileName = "control4_outlet.c4i", roomId = "1", roomName = "Office" },
  [300] = { deviceName = "Outlet C", driverFileName = "control4_outlet.c4i", roomId = "1", roomName = "Office" },
  [400] = { deviceName = "Desk Lamp", driverFileName = "light_v2.c4i", roomId = "1", roomName = "Office" },
}

-- The shim owns C4:GetDevices / GetDeviceDisplayName, reading this project.
require("c4_shim")
ShimSetDevices(PROJECT)

require("lib.utils")

--- GetDevice memoizes into an LRU with a 180 second TTL, so a device that
--- resolved in one scenario would still resolve in the next one. DeviceUpdated
--- is the module's own invalidation hook.
local function forgetAll()
  for deviceId in pairs(PROJECT) do
    DeviceUpdated(deviceId)
  end
end

--- Parses `list` and returns a deviceId -> index map of what the callback saw.
local function indexOf(list, c4iNames)
  forgetAll()
  local indexes = {}
  ParseDeviceIdList(list, c4iNames, function(deviceId, _, index)
    indexes[deviceId] = index
  end)
  return indexes
end

local function describe(indexes)
  local parts = {}
  for deviceId, index in pairs(indexes) do
    table.insert(parts, string.format("%s=%s", deviceId, index))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

T.section("Every entry resolving numbers the list densely")
do
  local indexes = indexOf("100,200,300")
  T.check("100 is 1", indexes[100] == 1, describe(indexes))
  T.check("200 is 2", indexes[200] == 2, describe(indexes))
  T.check("300 is 3", indexes[300] == 3, describe(indexes))
end

T.section("An unresolvable entry leaves a gap instead of pulling the rest down")
do
  local indexes = indexOf("100,999,300")
  T.check("100 keeps 1", indexes[100] == 1, describe(indexes))
  T.check("300 keeps 3, not 2", indexes[300] == 3, describe(indexes))
  T.check("the unresolvable ID is not in the results", indexes[999] == nil, describe(indexes))
end

T.section("A leading unresolvable entry does not shift the list")
do
  local indexes = indexOf("999,200,300")
  T.check("200 keeps 2", indexes[200] == 2, describe(indexes))
  T.check("300 keeps 3", indexes[300] == 3, describe(indexes))
end

T.section("A device's identifier survives another device failing to resolve")
do
  local before = indexOf("100,200,300,400")
  ShimSetDeviceHidden(200, true)
  local after = indexOf("100,200,300,400")
  ShimSetDeviceHidden(200, false)

  T.check("200 resolved before it was hidden", before[200] == 2, describe(before))
  T.check("200 is gone while hidden", after[200] == nil, describe(after))
  for _, deviceId in ipairs({ 100, 300, 400 }) do
    T.check(
      string.format("%d keeps identifier %s", deviceId, tostring(before[deviceId])),
      after[deviceId] == before[deviceId],
      string.format("before %s after %s", describe(before), describe(after))
    )
  end
end

T.section("A malformed entry still consumes its slot")
do
  local indexes = indexOf("100,not-a-device-id,300")
  T.check("300 keeps 3", indexes[300] == 3, describe(indexes))
end

T.section("Empty fields are not entries and do not consume a slot")
do
  local indexes = indexOf("100,,300")
  T.check("300 is 2", indexes[300] == 2, describe(indexes))
end

T.section("A callback that errors does not shift the entries behind it")
do
  forgetAll()
  local indexes = {}
  local devices = ParseDeviceIdList("100,200,300", nil, function(deviceId, _, index)
    if deviceId == 200 then
      error("callback blew up")
    end
    indexes[deviceId] = index
    return deviceId
  end)
  T.check("300 keeps 3", indexes[300] == 3, describe(indexes))
  T.check("the failing device is absent from the results", devices[200] == nil)
  T.check("the surviving devices are present", devices[100] == 100 and devices[300] == 300)
end

T.section("Without a callback the result is keyed by device ID")
do
  forgetAll()
  local devices = ParseDeviceIdList("100,999,300")
  T.check("known devices are present", devices[100] ~= nil and devices[300] ~= nil)
  T.check("the unresolvable ID is absent", devices[999] == nil)
  T.check("the device definition carries its ID", devices[100] and devices[100].deviceId == 100)
end

T.section("A c4iNames mismatch does not make an entry unresolvable")
do
  -- 400 is a light, not an outlet, so C4:GetDevices filters it out -- but
  -- C4:GetDeviceDisplayName still names it and GetDevice synthesizes a room
  -- device from that. This is why the DRV-84 window is narrow: the filter alone
  -- is not enough to produce a nil.
  local indexes = indexOf("100,400,300", { "control4_outlet.c4i" })
  T.check("the filtered device still resolves", indexes[400] == 2, describe(indexes))
  T.check("300 keeps 3", indexes[300] == 3, describe(indexes))
end

T.section("A repeated device ID gets one slot per occurrence")
do
  forgetAll()
  local calls = {}
  ParseDeviceIdList("100,100,300", nil, function(deviceId, _, index)
    table.insert(calls, string.format("%s@%s", deviceId, index))
  end)
  T.check(
    "each occurrence is numbered by position",
    table.concat(calls, ",") == "100@1,100@2,300@3",
    table.concat(calls, ",")
  )
end

T.finish()
