-- Tests for ParseDeviceIdList (src/lib/utils.lua): the callback index it hands
-- out, the IDs whose callback raised, and the GetDevice filter beneath it.
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

--- A fake project. Without a filter, GetDevice() asks C4:GetDevices first and
--- falls back to synthesizing a room device from C4:GetDeviceDisplayName, so it
--- returns nil only when *both* come up empty. `hidden` models that: it takes a
--- device out of both lookups, which is the transient failure these tests are
--- about. A device ID absent from PROJECT entirely is unresolvable the same way.
local ROOM = 1
local PROJECT = {
  -- The room the devices are in: C4:GetDevices never lists it.
  [ROOM] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  [100] = { deviceName = "Outlet A", driverFileName = "control4_outlet.c4i", roomId = "1", roomName = "Office" },
  [200] = { deviceName = "Outlet B", driverFileName = "control4_outlet.c4i", roomId = "1", roomName = "Office" },
  [300] = { deviceName = "Outlet C", driverFileName = "control4_outlet.c4i", roomId = "1", roomName = "Office" },
  [400] = { deviceName = "Desk Lamp", driverFileName = "light_v2.c4i", roomId = "1", roomName = "Office" },
  [501] = {
    deviceName = "Garage Door",
    driverFileName = "relaysingle_garagedoor_c4.c4i",
    roomId = "1",
    roomName = "Office",
    protocol = { [500] = { deviceName = "Garage Opener", driverFileName = "garage_opener.c4z" } },
  },
  [600] = { deviceName = "Hall Thermostat", driverFileName = "thermostatV2.c4i", roomId = "1", roomName = "Office" },
  [701] = {
    deviceName = "Side Gate",
    driverFileName = "relaysingle_garagedoor_c4.c4i",
    roomId = "1",
    roomName = "Office",
    protocol = {
      [700] = { deviceName = "Gate Opener", driverFileName = "gate_opener.c4z" },
      [702] = { deviceName = "Gate Sensor", driverFileName = "gate_sensor.c4z" },
    },
  },
}

-- The shim owns C4:GetDevices / GetDeviceDisplayName, reading this project.
require("c4_shim")
ShimSetDevices(PROJECT)

local shimGetDeviceData = C4.GetDeviceData
function C4:GetDeviceData(deviceId, key)
  if key == "properties" then
    return "<property><name>Select Outlets</name><type>DEVICE_SELECTOR</type>"
      .. "<items><item>control4_outlet.c4i</item></items></property>"
  end
  return shimGetDeviceData(self, deviceId, key)
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

--- The filter of each C4:GetDevices call.
local asked = {}
local shimGetDevices = C4.GetDevices
function C4:GetDevices(filter)
  table.insert(asked, { DeviceIds = filter.DeviceIds, C4iNames = filter.C4iNames })
  return shimGetDevices(self, filter)
end

require("lib.utils")
local log = require("lib.logging")

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

T.section("A callback that raises is reported apart from an unresolvable ID")
do
  forgetAll()
  local _, failed = ParseDeviceIdList("100,200,999,300", nil, function(deviceId)
    if deviceId == 200 then
      error("callback blew up")
    end
    return deviceId
  end)
  T.eq("only the raising ID is reported", failed, { [200] = true })
end

T.section("Nothing is reported failed without a callback")
do
  forgetAll()
  local _, failed = ParseDeviceIdList("100,999")
  T.eq("an empty set", failed, {})
end

T.section("A raising callback and an unresolvable ID are still logged")
do
  forgetAll()
  log:setLogMode("Print")
  local _, _, output = T.capture(function()
    ParseDeviceIdList("100,200,999", nil, function(deviceId)
      if deviceId == 200 then
        error("callback blew up")
      end
    end)
  end)
  log:setLogMode("")
  T.contains("the raise as an error parsing the ids", output, "Error parsing ids '100,200,999'")
  T.contains("the unresolvable ID as unknown", output, "Unknown device with id '999'")
end

T.section("ParseDeviceIdPropertyList reports the raising ID and keeps it in the property")
do
  forgetAll()
  Properties["Select Outlets"] = "100,200,999"
  local _, failed = ParseDeviceIdPropertyList("Select Outlets", function(deviceId)
    if deviceId == 200 then
      error("callback blew up")
    end
    return deviceId
  end)
  T.eq("the raising ID is reported", failed, { [200] = true })
  T.eq("only the unresolvable ID leaves the property", Properties["Select Outlets"], "100,200")
end

T.section("Without a callback the result is keyed by device ID")
do
  forgetAll()
  local devices = ParseDeviceIdList("100,999,300")
  T.check("known devices are present", devices[100] ~= nil and devices[300] ~= nil)
  T.check("the unresolvable ID is absent", devices[999] == nil)
  T.check("the device definition carries its ID", devices[100] and devices[100].deviceId == 100)
end

T.section("A device the filter excludes leaves a gap")
do
  local indexes = indexOf("100,400,300", { "control4_outlet.c4i" })
  T.check("the light is not an outlet", indexes[400] == nil, describe(indexes))
  T.check("300 keeps 3", indexes[300] == 3, describe(indexes))
end

T.section("Under a filter a device is found only if its driver is named")
do
  forgetAll()
  T.eq("the light is not an outlet", GetDevice(400, { "control4_outlet.c4i" }), nil)
  T.eq("nor is the thermostat", GetDevice(600, "control4_outlet.c4i"), nil)
  T.eq("an outlet is", Select(GetDevice(100, { "control4_outlet.c4i" }), "deviceId"), 100)
  T.eq("and so is the light under its own", Select(GetDevice(400, { "light_v2.c4i" }), "deviceId"), 400)
end

T.section("Without a filter a device of any driver is found")
do
  forgetAll()
  for _, deviceId in ipairs({ 100, 400, 501, 600 }) do
    T.eq(PROJECT[deviceId].deviceName, Select(GetDevice(deviceId), "deviceId"), deviceId)
  end
end

T.section("GetDevice answers each filter for itself")
do
  forgetAll()
  GetDevice(400)
  T.eq("an unfiltered find does not answer for an outlet", GetDevice(400, { "control4_outlet.c4i" }), nil)
  forgetAll()
  GetDevice(400, { "control4_outlet.c4i" })
  T.eq("a filtered miss does not answer unfiltered", Select(GetDevice(400), "driverFileName"), "light_v2.c4i")
  forgetAll()
  asked = {}
  GetDevice(400)
  GetDevice(400, { "control4_outlet.c4i" })
  GetDevice(400)
  T.eq("nor does it drop the unfiltered answer", asked, { { DeviceIds = "400" }, { DeviceIds = "400" } })
end

T.section("The same names in another order or form are one filter")
do
  forgetAll()
  GetDevice(400)
  asked = {}
  GetDevice(400, { "light_v2.c4i", "control4_outlet.c4i" })
  GetDevice(400, " control4_outlet.c4i, light_v2.c4i,light_v2.c4i")
  T.eq("C4:GetDevices is asked once", asked, { { DeviceIds = "400" } })
end

T.section("A filter keeps the case of a driver's file name")
do
  forgetAll()
  T.eq("thermostatV2.c4i is found by its own name", Select(GetDevice(600, { "thermostatV2.c4i" }), "deviceId"), 600)
end

T.section("A room is found without a filter, or with one naming roomdevice.c4i")
do
  forgetAll()
  T.eq("without a filter", Select(GetDevice(ROOM), "driverFileName"), "roomdevice.c4i")
  T.eq("as a room", Select(GetDevice(ROOM, { "roomdevice.c4i", "light_v2.c4i" }), "roomName"), "Office")
  T.eq("not as an outlet", GetDevice(ROOM, { "control4_outlet.c4i" }), nil)
  T.eq("and a device is not a room", GetDevice(400, { "roomdevice.c4i" }), nil)
end

T.section("A room is named once, and a device in it is named with the room")
do
  forgetAll()
  PROJECT[401] = { deviceName = "Office", driverFileName = "tv.c4i", roomId = "1", roomName = "Office" }
  T.eq("the room", Select(GetDevice(ROOM), "displayName"), "Office")
  T.eq("a device in the room", Select(GetDevice(400), "displayName"), "Office > Desk Lamp")
  T.eq("a device named like its room keeps the room", Select(GetDevice(401), "displayName"), "Office > Office")
  PROJECT[401] = nil
end

T.section("An ID that is neither a device nor a room is not made a room")
do
  forgetAll()
  T.eq("under roomdevice.c4i", GetDevice(999, { "roomdevice.c4i" }), nil)
end

T.section("A room a filter keeps out is logged as kept out, not as unknown")
do
  forgetAll()
  log:setLogMode("Print")
  local _, _, output = T.capture(function()
    GetDevice(ROOM, { "control4_outlet.c4i" })
    GetDevice(999, { "control4_outlet.c4i" })
  end)
  log:setLogMode("")
  T.contains("the room", output, "GetDevice -> Device 1 is not one of control4_outlet.c4i")
  T.contains("and an ID that is neither as unknown", output, "GetDevice -> Unknown device 999")
end

T.section("A proxy is found by its protocol driver's name")
do
  forgetAll()
  local door = GetDevice(501, { "garage_opener.c4z" })
  T.eq("as itself", Select(door, "driverFileName"), "relaysingle_garagedoor_c4.c4i")
  T.eq("and by its own", Select(GetDevice(501, { "relaysingle_garagedoor_c4.c4i" }), "deviceId"), 501)
  T.eq("but not by another driver's", GetDevice(501, { "other_opener.c4z" }), nil)
end

T.section("A proxy of two protocol drivers is found by either's name")
do
  forgetAll()
  T.eq("the opener's", Select(GetDevice(701, { "gate_opener.c4z" }), "deviceId"), 701)
  T.eq("and the sensor's", Select(GetDevice(701, { "gate_sensor.c4z" }), "deviceId"), 701)
end

T.section("A filtered lookup asks C4:GetDevices for the device alone")
do
  -- Given the names too, it would list every outlet in the project and still list the light.
  forgetAll()
  asked = {}
  GetDevice(100, { "control4_outlet.c4i" })
  T.eq("for a device it finds", asked, { { DeviceIds = "100" } })
  asked = {}
  GetDevice(400, { "control4_outlet.c4i" })
  T.eq("and once for one it keeps out", asked, { { DeviceIds = "400" } })
end

T.section("ParseDeviceIdPropertyList removes a device of another driver from the property")
do
  forgetAll()
  local function each(deviceId)
    return deviceId
  end
  Properties["Select Outlets"] = "100,400,200"
  T.eq(
    "the callback is given the outlets",
    ParseDeviceIdPropertyList("Select Outlets", each),
    { [100] = 100, [200] = 200 }
  )
  T.eq("and the light leaves the property", Properties["Select Outlets"], "100,200")
  forgetAll()
  Properties["Select Outlets"] = "100,400"
  T.eq(
    "without the delete pass the callback is given the outlet",
    ParseDeviceIdPropertyList("Select Outlets", each, false),
    { [100] = 100 }
  )
  T.eq("and the light stays in the property", Properties["Select Outlets"], "100,400")
end

T.section("DeviceUpdated forgets a device under every filter")
do
  forgetAll()
  GetDevice(100, { "control4_outlet.c4i" })
  DeviceUpdated(100)
  asked = {}
  GetDevice(100, { "control4_outlet.c4i" })
  T.eq("it is asked for again", asked, { { DeviceIds = "100" } })
end

T.section("DeviceUpdated forgets a device however its ID was written")
do
  forgetAll()
  GetDevice(" 100", { "control4_outlet.c4i" })
  DeviceUpdated(100)
  asked = {}
  GetDevice(" 100", { "control4_outlet.c4i" })
  T.eq("when it was looked up as ' 100'", asked, { { DeviceIds = "100" } })
  DeviceUpdated(" 100")
  asked = {}
  GetDevice(100, { "control4_outlet.c4i" })
  T.eq("and when it is forgotten as ' 100'", asked, { { DeviceIds = "100" } })
end

T.section("A device that did not resolve is looked up again")
do
  forgetAll()
  ShimSetDeviceHidden(200, true)
  local whileHidden = GetDevice(200, { "control4_outlet.c4i" })
  ShimSetDeviceHidden(200, false)
  T.eq("it is not found while hidden", whileHidden, nil)
  T.eq("and is found once it is back", Select(GetDevice(200, { "control4_outlet.c4i" }), "deviceId"), 200)
end

T.section("A filtered find answers the unfiltered lookup too")
do
  forgetAll()
  GetDevice(100, { "control4_outlet.c4i" })
  asked = {}
  T.eq("the same device", Select(GetDevice(100), "deviceName"), "Outlet A")
  T.eq("without asking again", asked, {})
end

T.section("A miss asks C4:GetDevices once")
do
  forgetAll()
  asked = {}
  GetDevice(999)
  T.eq("without a filter", asked, { { DeviceIds = "999" } })
  asked = {}
  GetDevice(999, { "control4_outlet.c4i" })
  T.eq("and with one", asked, { { DeviceIds = "999" } })
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

T.section("A repeated ID whose callback raises once is in both tables")
do
  forgetAll()
  local seen = {}
  local devices, failed = ParseDeviceIdList("100,100,300,300", nil, function(deviceId, _, index)
    seen[deviceId] = (seen[deviceId] or 0) + 1
    -- 100 raises on its first occurrence, 300 on its second
    if (deviceId == 100 and seen[deviceId] == 1) or (deviceId == 300 and seen[deviceId] == 2) then
      error("callback blew up")
    end
    return index
  end)
  T.eq("each keeps the occurrence that succeeded", devices, { [100] = 2, [300] = 3 })
  T.eq("and each is reported", failed, { [100] = true, [300] = true })
end

T.finish()
