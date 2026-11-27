-- lib.companions: which companion each binding gets, what is added, named, shown and bound, and what is left alone.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_companions.lua

local T = require("testlib")

require("c4_shim")
local F = require("c4_fixtures")
local companions = require("lib.companions")

local ME = C4:GetDeviceID()
local LIGHT = "example_light.c4z"
local KITCHEN, OFFICE = 10, 11
local OTHER_HUB = 200

local refreshed, shown = 0, {}
function RefreshNavs()
  refreshed = refreshed + 1
end
function C4:SendToDevice(id, command, params)
  if command == "SET_DEVICE_HIDDEN_STATE" then
    shown[#shown + 1] = string.format("%d %d %s", id, params.DEVICE_ID, tostring(params.IS_HIDDEN))
  end
end

--- @param binding integer
--- @param name? string
--- @param room? integer
--- @return CompanionNeed
local function need(binding, name, room)
  return {
    binding = binding,
    file = LIGHT,
    consumer = 5002,
    class = "EXAMPLE_LIGHT",
    name = name or "Pendant",
    room = room,
  }
end

--- A project with two rooms and the companions given, each with its proxy one id above it; this driver is in the
--- kitchen.
--- @param devices? table<integer, table>
local function project(devices)
  ShimResetDynamicBindings()
  local all = {
    [KITCHEN] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" },
    [OFFICE] = { deviceName = "Office", driverFileName = "roomdevice.c4i" },
  }
  for id, device in pairs(devices or {}) do
    device.proxies = { [id + 1] = true }
    all[id] = device
    all[id + 1] = { deviceName = device.deviceName, driverFileName = "proxy.c4i", roomId = device.roomId }
  end
  ShimSetDevices(all)
  ShimSetRoom(KITCHEN)
  ShimSetDriverFiles({ LIGHT })
  companions:reset()
  refreshed, shown = 0, {}
end

--- A companion already in the project.
--- @param name string
--- @param room integer
local function existing(name, room)
  return { deviceName = name, driverFileName = LIGHT, roomId = room }
end

--- Runs a setup to its end, answering every add and firing every timer as it goes.
--- @param needs CompanionNeed[]
--- @param options? CompanionOptions
--- @return CompanionResult|nil result
local function run(needs, options)
  local result
  companions:setup(needs, options):next(function(r)
    result = r
  end)
  for _ = 1, 20 do
    if result then
      break
    end
    ShimAnswerAdds()
    ShimFireTimers()
  end
  return result
end

--- Whether a proxy was shown in the kitchen's Navigators and hidden in the office's.
--- @param proxy integer
--- @return boolean
local function shownOnlyInKitchen(proxy)
  local seen = {}
  for _, line in ipairs(shown) do
    seen[line] = true
  end
  return seen[string.format("%d %d false", KITCHEN, proxy)] == true
    and seen[string.format("%d %d true", OFFICE, proxy)] == true
end

local function consumerOf(binding)
  return next(C4:GetBoundConsumerDevices(ME, binding) or {})
end

T.section("A binding with no companion gets a new one, named, in this driver's room, shown only there")
project()
local result = run({ need(5012, "Kitchen Pendant") })
local light = consumerOf(5012)
T.eq("one was added", result and result.added, 1)
T.eq("it is bound to the binding", light and C4:GetBoundProviderDevice(light, 5002), ME)
T.eq("its proxy has the need's name", light and C4:GetDeviceDisplayName(light + 1), "Kitchen Pendant")
T.eq("it is in this driver's room", light and C4:GetDevices({ DeviceIds = tostring(light) })[light].roomId, KITCHEN)
table.sort(shown)
T.eq("it is shown in the kitchen and hidden in the office", shown, {
  string.format("%d %d false", KITCHEN, light + 1),
  string.format("%d %d true", OFFICE, light + 1),
})
T.eq("Navigators are refreshed once", refreshed, 1)

T.section("A need's own room is where a new one goes")
project()
run({ need(5012, "Desk Lamp", OFFICE) })
light = consumerOf(5012)
T.eq("it is in the office", light and C4:GetDevices({ DeviceIds = tostring(light) })[light].roomId, OFFICE)

T.section("A binding already bound is left alone, its companion and name too")
project({ [500] = existing("Island", KITCHEN) })
Bind(ME, 5012, 500, 5002, "EXAMPLE_LIGHT")
result = run({ need(5012, "Kitchen Pendant") })
T.eq("it is kept", result and result.kept, 1)
T.eq("nothing is added", ShimPendingAdds(), 0)
T.eq("the companion keeps its name", C4:GetDeviceDisplayName(500), "Island")
T.eq("Navigators are not refreshed", refreshed, 0)

T.section("A binding removed in Connections is bound again to the same companion")
C4:Unbind(500, 5002)
result = run({ need(5012, "Kitchen Pendant") })
T.eq("it is bound again", result and result.rebound, 1)
T.eq("to the companion it had", consumerOf(5012), 500)
T.eq("nothing is added", result and result.added, 0)

T.section("A companion bound to another hub is left there, and the binding gets a new one")
project()
run({ need(5012) })
local first = consumerOf(5012)
C4:Unbind(first, 5002)
Bind(OTHER_HUB, 7000, first, 5002, "EXAMPLE_LIGHT")
result = run({ need(5012) })
T.eq("a new one is added", result and result.added, 1)
T.neq("the binding has the new one", consumerOf(5012), first)
T.eq("the first stays with the other hub", C4:GetBoundProviderDevice(first, 5002), OTHER_HUB)

T.section("A deleted companion is replaced")
project()
run({ need(5012) })
first = consumerOf(5012)
C4:Unbind(first, 5002)
ShimSetDeviceHidden(first, true)
result = run({ need(5012) })
T.eq("a new one is added", result and result.added, 1)
T.neq("and bound", consumerOf(5012), first)

T.section("A missing driver file adds nothing, and is tried once")
project()
ShimSetDriverFiles({})
local adds = 0
local addDevice = C4.AddDevice
C4.AddDevice = function(...)
  adds = adds + 1
  return addDevice(...)
end
result = run({ need(5012), need(5013) })
C4.AddDevice = addDevice
T.eq("it is reported missing, once", result and result.missing, { LIGHT })
T.eq("one add was tried", adds, 1)
T.eq("nothing is bound", consumerOf(5012) or consumerOf(5013), nil)
T.eq("Navigators are not refreshed", refreshed, 0)

T.section("Spares: none by default")
project({ [500] = existing("Pantry", KITCHEN) })
result = run({ need(5012) })
T.eq("a new one is added", result and result.added, 1)
T.eq("the spare stays bound to nothing", C4:GetBoundProviderDevice(500, 5002), 0)

T.section("Spares: one in the need's room is taken and keeps its name")
project({ [500] = existing("Pantry", KITCHEN), [510] = existing("Desk", OFFICE) })
result = run({ need(5012, "Kitchen Pendant") }, { spares = "room" })
T.eq("the kitchen spare is bound", consumerOf(5012), 500)
T.eq("it keeps its name", C4:GetDeviceDisplayName(500), "Pantry")
T.eq("nothing is added", result and result.added, 0)
T.eq("Navigators are refreshed", refreshed, 1)

T.section("Spares: one in another room is left alone under 'room'")
project({ [510] = existing("Desk", OFFICE) })
result = run({ need(5012) }, { spares = "room" })
T.eq("a new one is added", result and result.added, 1)
T.eq("the office spare stays bound to nothing", C4:GetBoundProviderDevice(510, 5002), 0)

T.section("Spares: 'any' takes one from any room, renamed with renameSpares")
project({ [510] = existing("Desk", OFFICE) })
result = run({ need(5012, "Kitchen Pendant") }, { spares = "any", renameSpares = true })
T.eq("the office spare is bound", consumerOf(5012), 510)
T.eq("it is renamed", C4:GetDeviceDisplayName(510), "Kitchen Pendant")

T.section("A companion another binding had is not a spare")
project({ [500] = existing("Pantry", KITCHEN) })
Bind(ME, 5012, 500, 5002, "EXAMPLE_LIGHT")
run({ need(5012) })
C4:Unbind(500, 5002)
result = run({ need(5013) }, { spares = "any" })
T.eq("a new one is added for the other binding", result and result.added, 1)
T.eq("the first binding's companion stays bound to nothing", C4:GetBoundProviderDevice(500, 5002), 0)

T.section("Adds go one at a time, spaced")
project()
local done
companions:setup({ need(5012), need(5013) }):next(function(r)
  done = r
end)
T.eq("one add at a time", ShimPendingAdds(), 1)
ShimAnswerAdds()
T.eq("the next waits for the spacing", ShimPendingAdds(), 0)
ShimFireTimers()
T.eq("then it is added", ShimPendingAdds(), 1)
ShimAnswerAdds()
ShimFireTimers()
T.eq("both are added", done and done.added, 2)

T.section("A second setup while one runs is refused")
project()
local refused
companions:setup({ need(5012) })
companions:setup({ need(5013) }):next(nil, function(err)
  refused = err
end)
T.eq("it is refused", refused, "a companion setup is already running")
ShimAnswerAdds()
ShimFireTimers()

local function lights()
  local n = 0
  for _ in pairs(C4:GetDevices({ C4iNames = LIGHT })) do
    n = n + 1
  end
  return n
end

T.section("An add that answers after its timeout fails, the next goes on, and the late one takes its binding")
project()
done = nil
companions:setup({ need(5012), need(5013) }):next(function(r)
  done = r
end)
ShimFireTimers()
T.eq("the second is asked for while the first has no answer", ShimPendingAdds(), 2)
ShimAnswerAdds()
ShimFireTimers()
T.eq("one failed and one was added", done and { done.failed, done.added }, { 1, 1 })
light = consumerOf(5012)
T.truthy("the late one is bound to the first binding", light)
T.truthy("and shown only in its room", light and shownOnlyInKitchen(light + 1))
result = run({ need(5012), need(5013) })
T.eq("a second setup keeps both", result and { result.kept, result.added }, { 2, 0 })
T.eq("the project has two", lights(), 2)

T.section("A late answer and a second setup's add for the same binding leave one companion on it")
project()
companions:setup({ need(5012) })
ShimFireTimers()
done = nil
companions:setup({ need(5012) }):next(function(r)
  done = r
end)
T.eq("both adds are unanswered", ShimPendingAdds(), 2)
ShimAnswerAdds()
ShimFireTimers()
local onBinding = 0
for _ in pairs(C4:GetBoundConsumerDevices(ME, 5012) or {}) do
  onBinding = onBinding + 1
end
T.eq("one companion is on the binding", onBinding, 1)
T.eq("the second setup's add counts failed", done and { done.added, done.failed }, { 0, 1 })
local left
for id in pairs(C4:GetDevices({ C4iNames = LIGHT })) do
  if C4:GetBoundProviderDevice(id, 5002) == 0 then
    left = id
  end
end
T.truthy("the one left bound to nothing is shown only in its room", left and shownOnlyInKitchen(left + 1))

T.section("A companion whose bind does not hold is bound again by the next setup, not added beside")
project()
local bind = C4.Bind
C4.Bind = function() end
result = run({ need(5012) })
C4.Bind = bind
T.eq("it failed", result and result.failed, 1)
local only = next(C4:GetDevices({ C4iNames = LIGHT }))
T.truthy("it is shown only in its room", only and shownOnlyInKitchen(only + 1))
result = run({ need(5012) })
T.eq("the next setup binds it again", result and { result.rebound, result.added }, { 1, 0 })
T.eq("the project has one", lights(), 1)

-- The companion's .c4z as the host carries it in its own package.
local CARRIED = "example_light package 20261125"

--- Sets up the controller's driver store and the host's package. `stored` is what the store holds, `running` is the
--- version the project's companions run, `version` is the host's own version, and `carried` is the copy the host
--- carries. Returns a function that undoes the setup.
--- @param opts { stored?: string, running?: string, carried?: string, version?: string }
local function store(opts)
  local root, package, unpacked = ShimFiles("C4Z_ROOT"), ShimFiles("C4Z/c4z"), ShimFiles("C4Z_ROOT/example_light")
  root[LIGHT], package[LIGHT], unpacked["driver.xml"] = opts.stored, opts.carried, nil
  if opts.running then
    unpacked["driver.xml"] = "<devicedata><version>" .. opts.running .. "</version></devicedata>"
  end
  local config = C4.GetDriverConfigInfo
  function C4:GetDriverConfigInfo(section)
    if section == "version" then
      return opts.version
    end
    return config(self, section)
  end
  return function()
    C4.GetDriverConfigInfo = config
  end
end

--- @param capture table
--- @return integer count The update requests sent for the companion's file.
local function updatesSent(capture)
  local count = 0
  for _, write in ipairs(capture.writes) do
    if write:find("UpdateProjectC4i", 1, true) and write:find(LIGHT, 1, true) then
      count = count + 1
    end
  end
  return count
end

--- Installs the copy the host carries, as a host does at start.
--- @return string|nil refused The reason the install was refused, or nil if it wasn't.
local function install()
  local refused
  InstallDrivers({ { name = LIGHT } }):next(nil, function(err)
    refused = err
  end)
  return refused
end

T.section("A companion the host carries is put in the store and added when the store has none")
project()
ShimSetDriverFiles({})
local restore = store({ carried = CARRIED, version = "20261125" })
local tcp = F.captureTcpClient()
result = run({ need(5012, "Kitchen Pendant") })
T.eq("the store has the carried copy", ShimFiles("C4Z_ROOT")[LIGHT], CARRIED)
T.eq("one was added", result and { result.added, #result.missing }, { 1, 0 })
T.eq("no update is asked for, with no companion in the project", updatesSent(tcp), 0)
tcp.restore()
restore()

T.section("A companion the host does not carry, and the store does not have, is missing")
project()
ShimSetDriverFiles({})
restore = store({ version = "20261125" })
result = run({ need(5012) })
T.eq("it is missing", result and result.missing, { LIGHT })
T.eq("nothing is put in the store", ShimFiles("C4Z_ROOT")[LIGHT], nil)
restore()

T.section("Companions on an older version are updated to the one the host carries")
project({ [500] = existing("Island", KITCHEN) })
restore = store({ stored = "older package", running = "20261101", carried = CARRIED, version = "20261125" })
tcp = F.captureTcpClient()
T.eq("the install is not refused", install(), nil)
T.eq("the store has the carried copy", ShimFiles("C4Z_ROOT")[LIGHT], CARRIED)
T.eq("Director is asked to update them once", updatesSent(tcp), 1)
tcp.restore()
restore()

T.section("Companions on the host's version or newer are left alone, and so is the store")
for _, running in ipairs({ "20261125", "20261201" }) do
  restore = store({ stored = "their package", running = running, carried = CARRIED, version = "20261125" })
  tcp = F.captureTcpClient()
  T.eq("the install is not refused, running " .. running, install(), nil)
  T.eq("the store keeps its copy, running " .. running, ShimFiles("C4Z_ROOT")[LIGHT], "their package")
  T.eq("no update is asked for, running " .. running, updatesSent(tcp), 0)
  tcp.restore()
  restore()
end

T.section("A copy in the store with no companion of it in the project is left as it is")
restore = store({ stored = "newer package 20261201", carried = CARRIED, version = "20261125" })
T.eq("the install is not refused", install(), nil)
T.eq("the store keeps its copy", ShimFiles("C4Z_ROOT")[LIGHT], "newer package 20261201")
restore()

T.section("An update lost on an earlier start is asked for again")
project({ [500] = existing("Island", KITCHEN) })
restore = store({ stored = CARRIED, running = "20261101", carried = CARRIED, version = "20261125" })
tcp = F.captureTcpClient()
install()
T.eq("Director is asked to update them", updatesSent(tcp), 1)
tcp.restore()
restore()

T.section("When a write fails, the install is refused and the store keeps what it had")
local write = C4.FileWrite
local function refuseWrites()
  C4.FileWrite = function()
    return -1
  end
end
restore = store({ carried = CARRIED, version = "20261125" })
refuseWrites()
T.eq("with no copy, the install is refused", install(), "failed to write " .. LIGHT)
T.eq("the store has none", ShimFiles("C4Z_ROOT")[LIGHT], nil)
C4.FileWrite = write
restore()
restore = store({ stored = "older package", running = "20261101", carried = CARRIED, version = "20261125" })
tcp = F.captureTcpClient()
local writes = 0
C4.FileWrite = function(...)
  writes = writes + 1
  if writes == 1 then
    return -1
  end
  return write(...)
end
T.eq("with an older copy, the install is refused", install(), "failed to write " .. LIGHT)
T.eq("the older copy is put back", ShimFiles("C4Z_ROOT")[LIGHT], "older package")
T.eq("no update is asked for", updatesSent(tcp), 0)
C4.FileWrite = write
tcp.restore()
restore()

T.section("Two needs for one file put it in the store and ask for its update once")
project({ [500] = existing("Island", KITCHEN) })
restore = store({ stored = "older package", running = "20261101", carried = CARRIED, version = "20261125" })
tcp = F.captureTcpClient()
run({ need(5012, "Kitchen Pendant"), need(5013, "Island") })
T.eq("Director is asked once", updatesSent(tcp), 1)
tcp.restore()
restore()

T.section("Setup still works when the controller won't open the store")
project()
local setDir = C4.FileSetDir
C4.FileSetDir = function(self, dir, ...)
  if dir == "C4Z_ROOT" then
    error("Invalid alias: C4Z_ROOT")
  end
  return setDir(self, dir, ...)
end
T.truthy("the install is refused", install())
result = run({ need(5012, "Kitchen Pendant") })
T.eq("a setup still adds", result and result.added, 1)
result = run({ need(5013, "Island") })
T.eq("and the next setup runs too", result and result.added, 1)
C4.FileSetDir = setDir

T.finish()
