--- The rig interface: what a repo's test/light_rigs.lua gives the light conformance run. A rig loads its
--- driver as it ships and fakes only its transport, and the cases drive and read the device it returns.
--- A change to the fields below raises Rig.VERSION, and every repo's rigs follow it.

local Rig = {}

--- The version of the rig interface. A rig file names it.
--- @type integer
Rig.VERSION = 1

--- F.virtualClock's clock, as a case uses it.
--- @class LightRigClock
--- @field now fun(): integer The virtual time, ms.
--- @field run fun(ms: integer) Fire what falls due in the next ms, and end there.
--- @field at fun(ms: integer, fn: fun()) Call fn that far ahead.
--- @field errors string[] Errors the timers and promises raised.
--- @field restore fun() Put the real timers back.

--- The device a rig fakes, as the cases drive and read it.
--- @class LightRigDevice
--- @field state fun(): LightValues Where the device is now: on, level 0-1, color with x and y or kelvin.
--- @field set fun(state: LightValues, quiet: boolean|nil) Another hand's change. quiet: the device reports its
---   on or off alone, so only a read shows its level.
--- @field drop fun() The connection is lost, and the driver calls light:lost(false).
--- @field back fun() The connection is back.
--- @field suspend fun()|nil The connection is stopped on purpose, and the driver calls light:lost(true).
--- @field resume fun()|nil

--- What one case holds.
--- @class LightRigHarness
--- @field clock LightRigClock
--- @field proxy FakeProxy
--- @field light Light|nil The light the driver's chunk made.
--- @field device LightRigDevice
--- @field errors string[] What the library and the driver logged as errors.
--- @field lo integer The Min On Level the case set. Default 1.
--- @field hi integer The Max On Level the case set. Default 100.
--- @field done fun() Puts back what the case installed.

--- A rig for one light_v2 driver.
--- @class LightRig
--- @field name string|nil What its checks are named by. Default the folder and the rig's index.
--- @field folder string The driver folder, which the runner sets.
--- @field load fun(h: LightRigHarness, state: LightValues|nil): LightRigDevice Load the driver on h.clock behind
---   h.proxy with the device in `state` (nil: the rig's own start), run OnDriverInit and OnDriverLateInit,
---   and return the device.
--- @field setup string|nil GET_SETUP's answer, as P.setupFile("setup-607.xml"). Default none.
--- @field settleMs integer|nil How long the light takes to settle after a command, less 5 s. Default 12000.
--- @field rest fun(h: LightRigHarness)|nil Sends the proxy command after which the adapter returns a
---   LightRest; nil when it never does.

--- What test/light_rigs.lua returns.
--- @class LightRigFile
--- @field version integer Rig.VERSION, as the file was written for.
--- @field rigs table<string, LightRig[]> The rigs for each light_v2 driver folder.

return Rig
