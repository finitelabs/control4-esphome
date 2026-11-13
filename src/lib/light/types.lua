--- The light library's contract: what a Light V2 driver gives the library and what it gets back.
---
--- A driver states its proxy surface once (LightProfile), writes an adapter for its transport
--- (LightAdapter), declares the facts of each device it connects to (LightDevice) and hands the light
--- every device state (LightReport). The library owns everything the proxy and the links are told.
---
--- Everything above "The library's own shapes" is the contract. A change of meaning there bumps Types.API,
--- and every light driver's adapter follows it; an added optional fact keeps it. tests/light/test_contract.lua
--- holds a hash of that text, so no edit to it goes unnoticed. The shapes below that line are the library's own.
---
--- How the contract grows: every fact states its default, so no field's absence selects a behavior; a new
--- fact names the parts that read it, and the fuzzer covers it.

local Types = {}

--- The contract's version. A profile names it, and Light.new raises on any other.
--- @type integer
Types.API = 1

-----------------------------------------------------------------------------------------------------
-- Values
-----------------------------------------------------------------------------------------------------

--- @alias LightColorMode "xy"|"cct"
--- @alias LightFadeKind "device"|"own"|"walk"
--- @alias LightCurve "linear"|"smootherstep"
--- @alias LightMidChange "target"|"position"
--- @alias LightColorWhileOff "send"|"hold"
--- @alias LightReportKind "push"|"moving"|"final"|"seed"
--- @alias LightCommandKind "preOn"|"change"|"stop"
--- @alias LightAspect "on"|"level"|"color"

--- A color as CIE 1931 xy. lib.light.color converts it to and from RGB, HSV and Kelvin.
--- @class LightColor
--- @field x number
--- @field y number
--- @field mode LightColorMode "cct" for a white on the black-body locus, else "xy".
--- @field kelvin integer|nil Set on a command when mode is "cct", already clamped to the device's range. A report
---   may leave it out.

--- @class LightCctRange
--- @field minK integer
--- @field maxK integer

-----------------------------------------------------------------------------------------------------
-- The profile: the driver's proxy surface, static
-----------------------------------------------------------------------------------------------------

--- The three Button Link bindings, by id.
--- @class LightLinks
--- @field top integer
--- @field toggle integer
--- @field bottom integer

--- What the driver offers the proxy, the same for every device it connects to. Light.new checks it once,
--- and the build writes driver.xml's light capabilities from it. Every boolean defaults to false.
--- @class LightProfile
--- @field api integer Must equal Types.API.
--- @field proxy integer|nil The light_v2 proxy binding. Default 5001.
--- @field links LightLinks|nil The Button Link bindings (has_button_events); nil: none.
--- @field dims boolean|nil
--- @field color boolean|nil
--- @field cct LightCctRange|boolean|nil A range: every device has it. true: each device names its own.
--- @field known boolean|nil Every device is as the profile says: its capabilities never change at runtime.
--- @field fades boolean|nil Some device can fade: stops, click and hold rates, color_rate_behavior 1.
--- @field maxMs integer|nil The longest rate the static capabilities offer, for every device. Default 65535.
--- @field defaultOn boolean|nil supports_default_on. Without it an ON with no on mode resumes at the device's level.
--- @field scenes boolean|nil Advanced Lighting Scenes.
--- @field onModes boolean|nil The brightness and color on modes.
--- @field flash boolean|nil Scene flash elements (disable_flash false).
--- @field extras boolean|nil has_extras. The driver sends EXTRAS_* and handles EXTRA_SET itself.

-----------------------------------------------------------------------------------------------------
-- The device: the facts of one connection
-----------------------------------------------------------------------------------------------------

--- The lengths of a device that takes no fade time from a command and runs its own (0: at once).
--- @class LightOwnFade
--- @field onMs integer Off to on.
--- @field offMs integer On to off.
--- @field changeMs integer On to another level or color.

--- How the device moves. Read by Motion and Caps only. Caps.check rejects a field set for the wrong kind
--- and fills the defaults, so no reader sees a contradictory combination.
--- @class LightFade
--- @field kind LightFadeKind|nil Default "device": fades over the time each command asks. "own": takes none and
---   runs `own`. "walk": changes at once, and the library walks a fade in 0-time steps.
--- @field curve LightCurve|nil "device" only. Default "linear".
--- @field preOn boolean|nil "device" only, default false. A rated on from off starts from the level the device
---   kept, so the library opens it with a 0-time on at the bottom step.
--- @field retimes boolean|nil "device" only, default false. A command restarts every channel over its own time,
---   named or not, so a command for one aspect re-times the other's running ramp. False: each aspect keeps its own.
--- @field maxMs integer|nil The longest rate the proxy may offer. Default 65535.
--- @field own LightOwnFade|nil Required for "own", nil otherwise.
--- @field stepMs integer|nil "walk" only: the time between steps. Default 100.

--- How the device's reports behave. Read by Ledger only.
--- @class LightFeedback
--- @field shows LightMidChange|nil What a report sent while a change runs shows. Default "target": where the change
---   ends. "position": where the light has got to.
--- @field waitMs integer|nil How long after a change lands a report may still predate it. Default 1000.
--- @field refresh boolean|nil Default false. refresh() is cheap enough for the library to call while a command
---   is out (false only where a refresh re-enumerates the device).

--- The facts of one connection, given to light:declare before its first report and again on any change.
--- A device offers no more than the profile: a capability beyond it is dropped and an error logged.
--- @class LightDevice
--- @field dims boolean
--- @field color boolean
--- @field cct LightCctRange|nil
--- @field colorWhileOff LightColorWhileOff|nil Default "send". "hold": the device drops a color sent while off or
---   with an off, so such a color is told, not sent, and the next on carries it.
--- @field levelSteps integer|nil The device's brightness steps from off to full. Default 255.
--- @field fade LightFade|nil Default: a "device" fade with every default, or an "own" fade of 0/0/0 under a
---   profile without fades, where any other fade is dropped with an error.
--- @field feedback LightFeedback|nil Default: every default.

-----------------------------------------------------------------------------------------------------
-- What goes to the adapter
-----------------------------------------------------------------------------------------------------

--- Where the library estimates the light is as a command goes out.
--- @class LightFrom
--- @field level number
--- @field color LightColor|nil

--- One command, carrying the full state the light is at or heading to, so no adapter keeps a base.
--- @class LightCommand
--- @field kind LightCommandKind "preOn": the 0-time on at the bottom step that opens a rated on from off; its
---   "change" follows in the same send. "change": go to level and color. "stop": hold where the change has got
---   to; level and color are the estimate.
--- @field on boolean Power after the command.
--- @field fromOff boolean True only on the first command of a send that lights a light the library holds off.
---   Never on a stop.
--- @field level number Device brightness 0-1 on the Min/Max On line; while off, the level kept; 1 on a light
---   that does not dim.
--- @field color LightColor|nil Nil only on a device with neither color nor CCT.
--- @field setsLevel boolean This command sets the light's output, its power or its level, an unchanged one too. Every
---   off has it, with `level` the level kept, and so does every command with fromOff. Without it `level` is only
---   carried for a wire that couples level and color, and `on` is unchanged: on false, the light stays off. On a stop,
---   setsLevel and setsColor name the aspects stopped.
--- @field setsColor boolean This command changes the color. With fromOff, only when a held color or an on mode's
---   color goes with the on; otherwise the light comes on in the color it kept, and `color` is carried. An off
---   with it fades to that color as it goes dark (Dim-To-Warm's Dim color).
--- @field transitionMs integer "device" fades only, else 0. 0 on a preOn. On a stop, the other aspect's time left
---   when a ramp of its own continues.
--- @field from LightFrom
--- @field colorUnchosen boolean The color only follows an on mode (Previous On's, the proxy's follow-up of it,
---   Dim-To-Warm's). A device that shows its own list of colors keeps them.

--- What send returns when the device rests where the command did not say, by its own doing: a favorite that
--- sets its own volume, or a stop the adapter held where its own wire fade had got to. Never for rounding.
--- The library writes it into the command before anything else sees the command. A rest says where the aspect
--- rests; the library still decides whether its ramp ends.
--- @class LightRest
--- @field level number|nil
--- @field color LightColor|nil

--- What the proxy shows that a device page may mirror.
--- @class LightShown
--- @field kelvin integer|nil The Kelvin the proxy shows; nil in full color or without CCT.
--- @field minOn integer Min On Level, 1-100.
--- @field maxOn integer Max On Level, 1-100.

-----------------------------------------------------------------------------------------------------
-- What comes from the device
-----------------------------------------------------------------------------------------------------

--- @class LightValues
--- @field on boolean|nil
--- @field level number|nil Device brightness 0-1 when on, or the level kept while off.
--- @field color LightColor|nil

--- One device state. A nil field is one the report does not carry, so a partial report is judged only on
--- the aspects it holds.
--- @class LightReport : LightValues
--- @field kind LightReportKind "push": unasked, or a cache's re-push; may predate the newest command. "moving":
---   answers a read made after the newest command reached the device, while its change may still run. "final":
---   answers a read made after that change ended. "seed": a re-push of a cache that holds the newest command
---   rather than the device's word; it fills only aspects not yet heard.

-----------------------------------------------------------------------------------------------------
-- The adapter
-----------------------------------------------------------------------------------------------------

--- The driver's adapter: a plain class (Adapter.__index = Adapter) with all three methods. Light.new raises
--- if one is missing and never branches on which an adapter has.
---
--- An adapter holds transport state only: queues, the request in flight, the wire form it last sent (whole or per leg),
--- its own wire fade, the wire form the device last reported, and memos it persists under keys of its own. A wire-form
--- memo lives for one connection: lost and reset end it; a memo persisted under its own keys keeps the lifetime its
--- driver gives it. It may make one judgement: a reported value that is the wire form of a command it sent and has not
--- yet seen answered, within the wire's rounding, is reported per aspect as that command's value. It may stop the rest
--- of its own multi-part send when a report is not that wire form. It never decides whose a report is, never ends a
--- ramp, and keeps no level, color or on that the library keeps. It may use the pure modules lib.light.color and
--- lib.light.range.
--- @class LightAdapter
--- @field send fun(self: LightAdapter, cmd: LightCommand): LightRest|nil Put one command on the wire. It must not
---   raise: one it cannot deliver is logged and dropped. The library calls it once per command, in order (a
---   preOn and its change back to back), and only after the connection's first report.
--- @field refresh fun(self: LightAdapter) Ask for the whole state, which comes back through light:report. Called
---   once by start and by reset, and otherwise only when feedback.refresh is true, at most once per window.
--- @field show fun(self: LightAdapter, shown: LightShown) Called at each connection's first report and whenever a
---   field changes. Empty without a device page.

-----------------------------------------------------------------------------------------------------
-- The driver's calls
-----------------------------------------------------------------------------------------------------
--
-- Light.new(adapter, profile): Light
--   Once, at the driver chunk's top level, where the build finds it: the build loads the chunk and writes
--   driver.xml's light capabilities from the profile, beside any capability the driver keeps. driver.xml
--   carries none of the light's capability keys itself. Just above its capabilities element it carries
--   "<!-- The light's capabilities are the build's, written from the profile the driver gives Light.new. -->",
--   and the build stops without it. Raises on a profile.api other than Types.API, a
--   profile field of the wrong type, or an adapter without send, refresh and show.
--
-- light:start()
--   From OnDriverLateInit. Reads the proxy (GET_SETUP, 6661, 1001/1110, 1200/1210), tells offline until the
--   device's first report, and asks refresh() once. Reports given before it are taken then, in order.
--
-- light:declare(device)
--   Each connection, before its first report, and on any change. The same facts do nothing. Capabilities
--   alone: re-tells the capabilities and keeps the run. A changed fade also ends running ramps at their targets
--   and closes the windows. Stored while offline.
--
-- light:report(report)
--   Every device state, of any kind. Returns nothing: the library alone decides whose a report is. A report
--   made inside send or refresh waits until the library's follow-up ends. One with a non-finite or out-of-range
--   value, or an unknown kind, is dropped whole with an error logged.
--
-- light:lost(suspended)
--   The connection is gone, and the run ends: no send until the next report. true (stopped on purpose: an
--   account's suspend, an unbind) keeps the level the proxy shows. false (a loss) reads off once per outage,
--   also after an earlier lost(true) and when no report came since start. Idempotent.
--
-- light:reset()
--   Reset Driver. Ends the run (ramps, windows, picks, presses, scene steps), tells offline until the next
--   report, and asks refresh() once. The proxy's settings stay.
--
-----------------------------------------------------------------------------------------------------
-- What the library owns, and a driver never does
-----------------------------------------------------------------------------------------------------
--
-- Bindings. The library sets RFP[profile.proxy] and RFP[id] for each link, with the native signature. A
-- driver sets neither, and no command-keyed RFP for a command the library handles. A proxy command the
-- library does not handle (EXTRA_SET) is the driver's, as a command-keyed RFP: the dispatcher tries that
-- before the binding's function.
--
-- Notifies. Every notify to the proxy and the links: LIGHT_*, DYNAMIC_CAPABILITIES_CHANGED, ONLINE_CHANGED,
-- the link LEDs and button colors, and the answers to GET_CONNECTED_STATE and GET_LIGHT_LEVEL. EXTRAS_*
-- stay the driver's.
--
-- State. The light's level, color, on, ramps and what the proxy was told, and its Connected variable. No
-- driver or adapter keeps a copy of any of them.
--
-- Persist keys. An adapter's own keys never take one of these names:
--   Settings: preset_level, click_rate_up, click_rate_down, hold_rate_up, hold_rate_down,
--     brightness_rate_default, color_rate_default, brightness_on_mode, button_colors, brightness_presets,
--     color_presets, color_on_mode, previous_color, brightness_on_mode_preset, max_on_level, min_on_level
--   Scenes: scenes

-----------------------------------------------------------------------------------------------------
-- The library's own shapes
-----------------------------------------------------------------------------------------------------

--- @alias LightIntentKind "on"|"off"|"toggle"|"level"|"color"|"stopLevel"|"stopColor"|"stop"
--- @alias LightSource "proxy"|"button"|"scene"

--- What a proxy command, a link press or a scene step asks of the light.
--- @class LightIntent
--- @field kind LightIntentKind
--- @field level integer|nil C4 level 0-100, for "level".
--- @field color LightColor|nil For "color".
--- @field rateMs integer|nil The proxy's rate; nil takes the default.
--- @field presetId integer|nil Told back to the proxy as the preset that set it.
--- @field presetOrigin integer|nil The preset's origin, told with its id.
--- @field source LightSource Light skips the cancel of the part it came from.
--- @field ramp boolean|nil A hold or a scene ramp, which sets Toggle's next hold direction.

--- OnColor.choose's answer for an intent that lights the light, or for the proxy's follow-up of one.
--- @class LightOnChoice
--- @field level integer C4 level the on goes to.
--- @field color LightColor|nil The on's color.
--- @field unchosen boolean The color only follows an on mode.
--- @field presetId integer|nil The preset the color is, told back with it.
--- @field presetOrigin integer|nil That preset's origin.
--- @field from LightColor|nil Where an on from off has the color start: its own color, or under Dim-To-Warm
---   the Dim color, the mix at level 0.
--- @field followUp boolean A color intent that is the proxy's follow-up of an on that already chose its color:
---   Motion keeps the on's color and moves nothing.

--- What OnColor.choose reads, as plain values from the parts that hold them. lib.light.oncolor declares
--- LightOnSettings and LightOnPicks.
--- @class LightOnInputs
--- @field now LightNow
--- @field device LightDevice
--- @field settings LightOnSettings
--- @field picks LightOnPicks

--- Motion's model of the level changing over time.
--- @class LightLevelRamp
--- @field from number
--- @field to number
--- @field startMs integer
--- @field ms integer
--- @field set boolean The ramp set a color of its own.
--- @field merged LightColor|nil The color the ramp carries (Dim-To-Warm or an on color).
--- @field unchosen boolean A stop of this ramp sends colorUnchosen.
--- @field stepSent number|nil "walk" only: the last step sent.
--- @field placesColor boolean|nil The device fades the color from the one it kept while the library has it in the on
---   mode's color all along, so a stop sends the color.

--- Motion's model of the color changing over time.
--- @class LightColorRamp
--- @field from LightColor
--- @field to LightColor
--- @field startMs integer
--- @field ms integer
--- @field carried boolean A color carried from a replaced level ramp; it belongs to the level.
--- @field unchosen boolean A stop of this ramp sends colorUnchosen.
--- @field stepSent LightColor|nil "walk" only: the last step sent.

--- What Motion reads from Settings, passed in with each call that needs it, so Motion holds no other part.
--- @class LightMotionSettings
--- @field lo integer Min On Level, 1-100.
--- @field hi integer Max On Level, 1-100.
--- @field rate integer The brightness rate default, ms.
--- @field colorRate integer The color rate default, ms.
--- @field on LightOnSettings For Dim-To-Warm at each walk step.

--- What Ledger compares a report with: Motion's value per aspect, a ramp's end while one runs; during a walk, the
--- newest step sent.
--- @class LightNow : LightValues
--- @field levelRamping boolean
--- @field colorRamping boolean
--- @field colorHeld boolean A "hold" device is off with a color told but not sent: the next on carries it.

--- What LightProxy tells from. It sends only what differs from what it told. Levels are device brightness
--- 0-1, as everywhere in the library; LightProxy maps them to C4 levels on the Min/Max On line.
--- @class LightView
--- @field on boolean
--- @field level number Where the light is now: the estimate while a ramp runs.
--- @field levelTarget number|nil The level ramp's end; nil when none runs.
--- @field levelMs integer Its time left; 0 when none.
--- @field color LightColor|nil
--- @field colorTarget LightColor|nil
--- @field colorMs integer
--- @field levelPreset integer|nil
--- @field colorPreset integer|nil
--- @field colorPresetOrigin integer|nil

--- One value sent for an aspect.
--- @class LightSent
--- @field value boolean|number|LightColor
--- @field landing integer C4:GetTime() ms when the change it belongs to ends.

--- "command": opened by a command. "learning": an on another hand made, waiting for its level. "asked": a
--- refresh is out, and the first push or final settles.
--- @alias LightWindowKind "command"|"learning"|"asked"

--- Ledger's record of one aspect from a command to its deadline.
--- @class LightWindow
--- @field kind LightWindowKind
--- @field sent LightSent[] Newest last; empty for a learning window.
--- @field before boolean|number|LightColor|nil What the library held when the window opened.
--- @field held boolean|number|LightColor|nil The latest report held.
--- @field heard boolean A report carrying the aspect arrived.
--- @field echoed boolean The newest command's echo has come.
--- @field asked boolean A refresh was asked in this window.
--- @field extended boolean The deadline was extended once.
--- @field deadline integer
--- @field landed boolean|nil What is held is a position no command sent, reported once the newest change had landed.

--- What start read from the proxy, which Motion starts from and the first report is weighed against.
--- @class LightSeed
--- @field level number|nil Device brightness 0-1 from 1001, when 1110 equals it; else nil.
--- @field color LightColor|nil From 1200, when 1210 equals it; else nil.

--- Ledger's answer to a report or a deadline.
--- @class LightHeard
--- @field settle LightValues Values to adopt; a ramp still running on that aspect ends there.
--- @field foreign LightAspect[] The aspects another hand moved.
--- @field ask boolean Call adapter:refresh() once.
--- @field form LightColor|nil The running color ramp's end in the form the light echoed it.
--- @field first LightAspect[] The aspects this was the first report of since a start or a loss, a match included:
---   each is told to the proxy, changed or not.

return Types
