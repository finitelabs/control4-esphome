# <span style="color:#17BCF2">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

### Added

- Added the ESPHome SereneScent sub-driver for Homedics SereneScent BLE
  diffusers, with power, mist intensity and light color control, keypad button
  links and a power relay

### Fixed

- Fixed the SwitchBot and Yale drivers waiting indefinitely when the Bluetooth
  proxy or coordinator never answered a connection request, as when it restarted
  mid-connect: a SwitchBot stayed Busy with the command queued, and a Yale lock
  in Poll mode stopped polling; the driver now gives up after a little over
  three minutes, frees the proxy's connection slot and handles it as a failed
  connection
- Fixed a Yale lock in Persistent mode counting a failed or timed-out handshake
  as two failures, using up its reconnect attempts twice as fast and retrying a
  lock or unlock that hit it as a status read instead
- Fixed the SwitchBot and Yale drivers keeping the proxy's connection slot when
  a connection came up without the device's Bluetooth characteristics, as can
  happen on a first connect: a Yale lock stayed on "Error: Missing
  characteristics" and stopped polling or reconnecting; the driver now
  disconnects, frees the slot and handles it as a failed connection
- Fixed a SwitchBot Relay Switch with no encryption key staying Busy and keeping
  the proxy's connection slot when a connection came up without the device's
  Bluetooth characteristics; it now disconnects and frees the slot
- Fixed an Advanced Lighting scene set to flash, with no delay or ramp time on
  any step, hanging the light's driver; it now runs its steps once and stops
- Fixed a color sent to a light right after it was ramped on, as programming
  that turns a light on and sets its color does, being dropped; the light now
  takes it and keeps it when the ramp ends
- Fixed a ramp that also changes a light's color, as a Dim-To-Warm dim does,
  reporting the new color as the one the fade starts from
- Fixed a light showing a scene's color, or going back to a color set while it
  was off, after turning on or changing level had given it its on color or
  Dim-To-Warm color
- Fixed an Advanced Lighting scene carrying on with a light after the light was
  turned on or off, set to a level or ramped: a later step of the scene took the
  light back, and a scene that flashes the light kept flashing it; the command
  now takes the light out of the scene
- Fixed a ramp or color fade started while a scene was still fading a light
  showing as finished when the scene's fade ended, while the light was still
  moving; it now shows as finished when the light gets there
- Fixed a color set on a light during a ramp being replaced by its Dim-To-Warm
  color when the ramp ended
- Fixed Color On Mode set to a color preset not being applied: the light turned
  on in the color it last went off in, as if the mode were Previous, and with no
  color of its own before it had been off once; it now turns on in the preset's
  color and follows an edit of that preset
- Fixed a light with Color On Mode set to Previous that was faded off, not
  switched off at once, turning back on in the color it had before the fade, not
  the one it faded off in
- Fixed a light that was told to stop ramping during an Advanced Lighting scene
  being moved again by the scene's next step; the stop now takes the light out
  of the scene
- Fixed a light that was told to stop ramping while its color was still fading
  being put in its Dim-To-Warm color, or the color it turns on in, with the fade
  cut short; the stop now holds the level and leaves the color fade to finish
- Fixed a light that was stopped during a ramp losing a color set since the ramp
  began
- Fixed a scene step that sets only a level leaving a light in its old color
  with Dim-To-Warm; the step now takes the Dim-To-Warm color for its level
- Fixed Stop Scene Ramp not stopping a light: the light carried on to the end of
  its ramp and was shown as still ramping; it now holds the light where the ramp
  has got to
- Fixed a held Top or Toggle button ramping a light toward its Default On level,
  which dimmed a brighter light; a hold now ramps toward full until released
- Fixed a button pressed, clicked or toggled while a light was ramping acting on
  the level the ramp began from: a light on its way up could be switched off and
  faded up again, or toggled the wrong way
- Fixed a scene step with no ramp time not being shown for a light, in level or
  color, until the light reported it, so the step, command or color fade after
  it started from the old one
- Fixed a color a light took while it was off not being picked up until it was
  next on
- Fixed Ramp Scene Up and Down, on a light already ramping, starting from the
  level that ramp began at: the light could drop to its minimum and climb, or
  not move at all
- Fixed a light that was ramping not stopping when a command asked for the level
  it had just reached: the light carried on to the end of its ramp while it was
  shown at the level asked for
- Fixed a light with Dim-To-Warm between two color temperatures being shown in
  two colors at every brightness change, the one it was sent and then the one it
  reported, and being sent the level again by a command for the level it was
  already at
- Fixed a ramped on of a color light with no color temperature restarting a
  moment in, when the light turns on in a color temperature preset
- Fixed an Advanced Lighting scene that was deactivated, cleared or removed
  while one of its steps was fading a light leaving the light shown as still
  ramping, at the level and color it had before the fade: a command for that
  level then did nothing, and a stop found nothing to stop; the fade now runs on
  and shows as finished when the light gets there
- Fixed a scene step that sets only a color, run while a light was ramping,
  making the driver lose track of the ramp: a stop then did nothing, and the
  level the light ramped to was never shown; the ramp now carries on for a stop
  to hold
- Fixed a scene step that sets a level, run while a light was ramping, starting
  from the level that ramp began at: the step's fade was shown from the wrong
  level and a stop held the light at the wrong one, and a step back to the level
  the ramp began at left the light shown as still ramping
- Fixed a scene step run while a light's color was fading: a step with a color
  of its own showed its fade from the color the earlier fade began at, and a
  step that sets only a level left the earlier fade's end never shown
- Fixed a scene step with a ramp time showing an On/Off-only light ramping to
  the step's level, and at that level when the ramp time had passed; the light
  switches at once and is now shown on or off as it does
- Fixed a scene step that turns a light on over a ramp time not fading it up
  from off as a ramped On does, and a step that sets only a level turning the
  light on without its Color On Mode color
- Fixed a light that was stopped during a scene step's fade, with Dim-To-Warm,
  losing the color the step set when the light was already in that color
- Fixed a scene step with no ramp time fading a light over the device's own
  default transition time; it is now sent as an immediate change, as a level
  command with no ramp time is
- Fixed a ramp that took over from one still changing a light's color, as a
  button's click does from its press, showing its color fade from the color the
  first ramp was heading for
- Fixed a ramped On cut short by a level command leaving the light shown as
  still changing color
- Fixed a light that was fading to a color when a ramped level change, a ramped
  Off or a scene step with no color took over being shown in that color at once,
  before the bulb had reached it
- Fixed a light turned off while its color was still fading coming back on, with
  Color On Mode set to Previous, in the color the fade began in
- Fixed a light that was stopped part way through a ramp stepping to another
  level, by up to 15 % of the ramp, and a ramp, fade or stop that took over from
  a ramp still running being shown from the wrong level or color: an ESPHome
  light eases into and out of a ramp, and the driver took it to move at a steady
  rate
- Fixed a light that was ramping and fading to a color at the same time jumping
  to the end of both when the first of the two ran out: a slow color fade begun
  during a short ramp sat almost still and then snapped to its color and level,
  and a light turned off during a color fade and faded back on jumped to full
  when the color fade would have ended
- Fixed a light that was sent a level while its color was fading, or a color
  while it was ramping, being shown as still changing for seconds after it had
  arrived: an ESPHome light takes a fade already running along with the new
  command, over that command's ramp time, and the driver now follows it and
  shows both finishing together, at once when the command has no ramp time
- Fixed a light that was told to stop ramping while its color was still fading
  jumping to the color the fade was heading for, and one told to stop a color
  fade while it was ramping jumping to the level the ramp was heading for; a
  stop now holds what it stops where the light is and leaves the other to finish
  in the time it had left
- Fixed a color set on a light that was off being dropped when the light had
  last been on in a color temperature: it was shown in the color and came on
  white
- Fixed a color sent to a light that was fading to off turning it full on in
  that color until the fade's time was up, and a color set over a ramp time on a
  light that was off making a ramped On after it jump to full early; a light
  that is off or fading to off now keeps the color for when it next comes on,
  and is shown in it at once, and an Advanced Lighting scene that sets a color
  and no level no longer turns it on
- Fixed a color change sent with no ramp time snapping to the color at once on a
  light whose default ramp rate had never been set; it now fades over the
  default half second, as a level change does
- Fixed a light that another controller of the ESPHome device, such as Home
  Assistant, set to a level or color while it was ramping from Control4 being
  put back at the ramp's level or color when the ramp's time was up; the change
  is now kept, and shown as soon as the light reports it
- Fixed a light ignoring its Color On Mode, the level it turns on to and its
  default ramp rate until one of them was next changed in Composer: turned on or
  dimmed by a keypad button, an Advanced Lighting scene or a command with no
  ramp time, it took half a second and no on color, where Composer showed three
  quarters of a second and Dim-To-Warm; the driver now reads them from the
  light's settings in the project when it starts and when the light connects, so
  a light turns on in its On Color and dims with Dim-To-Warm from the first time
  it is used
- Fixed a light that has a white as well as a color making a white On Color out
  of its red, green and blue: the On Color and Dim Color a new color light is
  given are 3200 K stored as a color, so the light turned on and dimmed in a mix
  of the three; a color that is a color temperature's own point, in the Color On
  Mode, a scene or a color set from Navigator, now lights the light's white, at
  that color temperature where the white has one
- Fixed a cold and warm white light coming on, or dimming, at a third of its
  light and warmer than asked when the level carried a color temperature, as
  every level does with Dim-To-Warm: the driver split the color temperature into
  cold and warm white itself, where the light does it with its own gamma; the
  light now works the two out, as it does for a color temperature set by itself
- Fixed a light with its color and its white in one color mode, as an ESPHome
  RGBCT or RGBWW light built without `color_interlock` has, being shown in a
  white a moment after any color was set on it: the white was then the color its
  next fade was shown from, and the color it came back on in with Color On Mode
  set to Previous; it is now shown in its color while the color is turned up at
  least as far as the white, and in its white below that
- Fixed a color temperature set on an ESPHome light with its color and its white
  in one color mode leaving the color lit: asked for 3000 K while blue, the
  light stayed blue with a warm white beside it and was shown at 3000 K; the
  color now fades out as the white fades in, a stop part way holds the light
  where it is, and only the first color set on an RGBCT light that is in its
  white-only mode, as one turned on with no Color On Mode after a restart is,
  still fades through off
- Fixed the white of an ESPHome light with its color and its white in one color
  mode, an RGBW light among them, staying lit beside every color the light was
  set to, which washed the color out; a color now turns the white off, and an
  RGBW light, which has no color temperature for Control4 to set, lights its
  white alone for a color that is the point of a color temperature from about
  2000 to 6500 K, such as the On Color a new light is given or a white picked on
  the color wheel, and its red, green and blue alone for any other color
- Fixed a color temperature set on a light that was off in a color being dropped
  by an ESPHome light whose color and white are separate color modes, as one
  built with `color_interlock` has: the light was shown at the color temperature
  and came back on in the color; it now comes on in that white
- Fixed Max On Level and Min On Level, set on a light in Composer, having no
  effect: a light set to a Max On Level of 80 still went to 100 %; the light's 1
  to 100 % now runs between the two, as on a Control4 dimmer, for every level it
  is sent and shown, and a change of either leaves the light where it is until
  its next command, shown at its level on the new range
- Fixed a stop part way through a fade between a color and a white, on an
  ESPHome light whose color and white are separate color modes, as one built
  with `color_interlock` has, sending the light a color temperature read off a
  point between the two: stopped 150 ms into a fade from red to 4000 K, the
  light went to its warmest white; it now stays in the color or white it is in,
  the one it was fading from up to half way and the one it was fading to after,
  comes back up to its level from the dip over half a second, and is shown in
  it; a level stopped part way through a ramp from a color with Dim-To-Warm, as
  when a keypad hold is let go, went to the white at once, and a fade sent part
  way through either, as by a keypad hold pressed then, came back up to its
  level at once when stopped; both now do the same
- Fixed a ramped On that changes a light's color starting in the color the light
  went off in: on an ESPHome light whose color and white are separate color
  modes, as one built with `color_interlock` has, a ramped On into a white On
  Color, or with Dim-To-Warm, from a light last in a color was dark for most of
  its ramp; the light now comes up in its On color from the start, as ESPHome
  brings up a light turned on from off, and is shown in it at once
- Fixed an ESPHome RGBW light built with `color_interlock` never lighting its
  white: its white is a color mode of its own, which the driver never named, so
  the On Color a new light is given and a white picked on the color wheel went
  out in its red, green and blue; a color that is the point of a color
  temperature from about 2000 to 6500 K now lights the white alone, as on an
  RGBW light built without `color_interlock`, and a fade between two whites
  stays in the white
- Fixed a white picked on the color wheel 1 % from its middle toward green going
  out as a mix of red, green and blue on an ESPHome light with a white beside
  its color, or being dropped by one with only a white, where one 16 % toward
  orange lit the white: a color now counts as the white of a color temperature
  inside the light's range when it is within the same distance of that white on
  every side, so the middle of the wheel and the colors within 2 % of it light
  the white where their color temperature is in the range; an orange that lies
  on the line of whites, as some of up to 75 % do, is a warm white too
- Fixed a color temperature beyond an ESPHome light's range, such as 2200 K set
  by a scene or from Navigator on a light that goes no warmer than 2700 K, being
  shown at the end of the range once the light reported it, so it no longer
  matched what was set; the light still goes to the end of its range, and is now
  shown at the color temperature that was set, which Color On Mode set to
  Previous keeps

### Changed

- Changed how long a color set on a light with Dim-To-Warm lasts: it now lasts
  until the brightness next changes, when the light takes its Dim-To-Warm color
  again, instead of until the light is turned off
- Changed a brightness command for the level a light with Dim-To-Warm is already
  at: it now returns a color set on the light to its Dim-To-Warm color instead
  of doing nothing

## v20260926 - 2026-09-26

### Fixed

- Fixed event, BTHome and SwitchBot button links not activating Advanced
  Lighting scenes; loads bound to them already worked
- Fixed entities with no name of their own, such as a relay configured with
  `name: None`, being left out or given a blank name; they now take their
  device's name
- Fixed entities that share an ESPHome key, such as a sensor and a text sensor
  with the same name, being set up as one entity; each now gets its own
  variables and connections
- Fixed commands to entities on an ESPHome sub-device being ignored on ESPHome
  2025.8 and newer
- Fixed an event entity's Programming events disappearing after a controller
  reboot, or keeping their old name after a rename

## v20260922 - 2026-09-22

### Added

- Added presets to the climate driver, each storing a setpoint, HVAC mode, fan
  mode and vane position, and applicable from Navigator or from Programming
- Added preset scheduling by weekday and time; the schedule is kept by Control4
  and the driver applies each preset as it falls due
- Added holds, so changing the thermostat or choosing a preset by hand holds
  that setting until the next scheduled event releases it; clearing a held
  preset sooner returns to the preset the schedule has in force, and a Permanent
  hold, offered with or without a schedule and released by no scheduled event,
  stays until cleared by hand or from Programming
- Added vane control in the Extras tab for climate devices that report swing
  modes
- Added a button connection for each event type an ESPHome event entity
  declares, so a touch button or gesture on the device can drive a light, scene
  or any other load without Programming
- Added a Bluetooth Proxy Status warning when the BLE scanner has stopped
  reporting devices and the driver has run out of ways to restart it, so a proxy
  that needs a power cycle no longer reads as healthy

### Fixed

- Fixed lights, thermostats, water heaters, fans and locks still showing as
  connected when they were not: after the driver's IP address, port or
  credentials were changed or cleared, and, for thermostats and water heaters,
  after the ESPHome device itself went offline; they now go offline with the
  device until it reconnects
- Fixed thermostats and water heaters always showing Fahrenheit; they now follow
  the project's temperature scale and pick up a change made in Navigator
  straight away, with the Celsius/Fahrenheit setting in Composer available to
  override it for an individual thermostat
- Fixed a thermostat staying on its last mode after the unit was turned off
  outside Control4, for example with its own remote; it now shows Off, a unit
  that reports whether it is heating or cooling shows when that stops, and
  switching the fan to On is now shown too
- Fixed a thermostat never showing whether it is heating, cooling, idle, drying
  or running the fan only
- Fixed Heat never engaging on a water heater that had not yet stored an
  operating mode
- Fixed a temperature of exactly 0°C, or a humidity of 0%, not being shown
- Fixed a temperature, setpoint or humidity the device has not measured yet
  being shown as a number near 5.1e38, which a setpoint nudge then clamped to
  the maximum; such a reading is now left blank until a real one arrives, and
  sensor values are handled the same way
- Fixed a newly installed climate driver forwarding a bound temperature sensor's
  readings to the device before the thermostat had enabled the remote sensor
- Fixed the climate driver's temperature and humidity outputs appearing as audio
  connections in Composer instead of control connections; the humidity output
  moves to a different connection as a result, but nothing needs reconnecting
  because the audio one could not be connected to anything
- Fixed an "Error setting default color rate from driver" message in Composer
  when opening the properties of an ESPHome light
- Fixed Composer's test panel graying out the dimming controls for ESPHome
  lights that do support brightness; dimming from Navigator was never affected
- Fixed a BTHome or SwitchBot button doing nothing to a dimmer it was linked to,
  where sending the press, click and release together meant the release stopped
  the dim the click had just started; a button now reports a press followed by a
  click, the same as a Control4 keypad, so linked dimmers, switches and other
  loads all respond
- Fixed a SwitchBot Bot running its action twice for a single press of a linked
  keypad button, which turned a toggle back to where it started
- Fixed Bluetooth proxy recovery looking for a button with "restart" in its name
  to clear a stalled scanner, so a proxy that names its button differently or
  exposes none at all had no recovery, and where a button was found the whole
  device was rebooted, dropping every Bluetooth connection it held; recovery now
  restarts the scanner itself on any proxy that reports its scanner state,
  leaving those connections up
  <!-- #ifndef DRIVERCENTRAL -->
- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime
  <!-- #endif -->

### Changed

- Changed the setpoint display for climate devices that report a single target:
  they now show one setpoint instead of a heat and cool pair, since most heat
  pumps and mini splits hold one target and decide internally whether to heat or
  cool toward it, so the pair could never be honored; Auto is unaffected
- Changed the documentation to cover the `Connected` variable that every driver
  publishes, so it can be used in Programming to show whether a device is online

## v20260816 - 2026-08-16

### Added

- Added the konnected Smart Garage Door Opener to the verified devices, and
  generalized the ratgdo setup into a shared Garage Door Configuration guide
  that covers both

### Fixed

- Fixed Bluetooth proxies logging a spurious "Property 'Select Bluetooth
  Devices' not registered" warning at every driver startup
- Fixed the Bluetooth device selection being permanently erased when a proxy was
  bound to a Bluetooth Coordinator; it is now kept and restored if the proxy is
  later unbound
- Fixed Bluetooth proxies in Coordinator Mode reporting their connection slots
  as "(Oversubscribed)"

## v20260802 - 2026-08-02

### Added

- Added a `Connected` (BOOL) variable to the main driver and every sub-driver
  with a Driver Status so Programming can react to connect/disconnect
- Added an "Open Latch" action to the ESPHome Lock driver for locks that support
  the open command (`supports_open`)

### Fixed

- Fixed a slow TCP connect interfering with the connection attempt that replaced
  it, which could run the handshake on the wrong socket and tear down a healthy
  connection when the stale socket closed
- Fixed the HVAC state freezing on the previous value during a heat pump's
  defrost cycle; defrosting now reports as Heating, and unmapped climate
  modes/actions log a warning instead of being silently dropped
- Fixed latch-style ESPHome locks (`supports_open`) reading as "unknown" in
  Control4 while reporting the open or opening state; both now map to unlocked
- Fixed overlapping status refreshes silently racing each other for the same
  response callbacks; refreshes are now serialized
- Fixed cover contacts and Yale DoorSense sending nothing to a newly bound
  consumer (or after a DoorSense drop and re-detect) until the state changed;
  consumers are now seeded with the last known state on bind
- Fixed the Reset Driver action leaving bound consumers stale until the next
  state change (sensor values, cover contacts, BTHome bindings, Yale DoorSense)
- Fixed pending requests (refresh, Bluetooth GATT operations) hanging forever
  when the connection dropped mid-request; they now fail immediately with a
  "Disconnected" error
- Fixed SwitchBot channel relays and contact sensors (motion, contact, leak,
  tamper) leaving bound consumers stale after a driver restart until the next
  state change
- Fixed a pending request hanging forever when a second request for the same
  response type started before it finished; the older request now fails with a
  "Superseded by a newer request" error instead of stalling, and the newer
  request is no longer left without its callbacks (which could make entity
  discovery or Bluetooth GATT service discovery return an empty result)
- Fixed a superseded status refresh being reported as "Refresh failed" and
  dropping the device connection out from under the refresh that replaced it

## v20260728 - 2026-07-28

### Added

- Added `TEMPERATURE_VALUE` and `HUMIDITY_VALUE` connections for sensors with a
  `temperature` or `humidity` device class, so they can be bound to thermostats
  and other value consumers; the reported scale honors the sensor's declared
  unit of measurement

### Fixed

- Fixed cover contacts, Yale DoorSense, BTHome bindings, and the SwitchBot Bot
  relay leaving bound consumers stale after a driver restart or update until the
  next state change
- Fixed all entity states appearing frozen in Control4 (covers stuck on
  "Unknown", sensor variables never updating) on ESPHome 2026.7+ firmware, which
  no longer sends the deprecated `object_id` field; the driver no longer reads
  `object_id`, and log messages now identify entities as `type 'Name' (key=N)`
- Fixed devices logging `using outdated API 1.0, update to 1.14+` on every
  connection; the ESPHome native API version advertised in `HelloRequest` is now
  1.14 rather than 1.0

## v20260711 - 2026-07-11

### Fixed

- Fixed Bluetooth Coordinator connections to ESPHome proxies (and other
  dynamically created connections) disappearing after a controller reboot or
  Director restart; dynamic bindings are now restored early enough in driver
  startup for Director to reconnect them
- Fixed an on/off-only ESPHome light advertising brightness and color to
  capability consumers that read the static declaration instead of the
  runtime-narrowed set; hardware capabilities (dimming, color, color
  temperature) are now declared conservatively in the static baseline and
  enabled at runtime from the entity's discovered color modes
- Fixed BOOL variables (`<Entity> State` for binary_sensor and switch, plus all
  BTHome boolean sensors) staying as `False` in the Variables Agent even when
  the underlying state was changing; variables now serialize as `"0"`/`"1"`
  matching what Control4 expects
- Fixed ESPHome fan `Designate Preset` command: the handler now reads the
  correct `PRESET` param (was `SPEED`), clamps to the driver's speed count,
  persists the value across driver restarts, notifies the proxy so Composer and
  Navigator reflect the designated preset, and applies the preset when the fan
  is turned on so `Turn On Fan` runs at the designated speed

## v20260512 - 2026-05-12

### Added

- Added brightness and dimming support to ESPHome lights with smooth ramping,
  preset management, and hold-to-dim button control
- Added color and color-temperature support to ESPHome lights for every ESPHome
  color mode (white, color-temperature, cold/warm white, RGB, RGBW, and combined
  RGB + white modes)
- Added Advanced Lighting Scenes support to ESPHome lights so they can
  participate in lighting scenes alongside other Control4 dimmers

## v20260418 - 2026-04-18

### Added

- Added Event entity support: stateless triggers (button presses, gestures,
  doorbell rings) now create Control4 events for programming and track the last
  event type in a variable
- Added Date, Time, and Datetime entity support: configurable date/time values
  on the device are exposed as writable string variables (YYYY-MM-DD, HH:MM:SS,
  YYYY-MM-DD HH:MM:SS)
- Added Climate entity support: ESPHome climate devices are exposed as
  thermostatV2 sub-drivers with HVAC mode, setpoints, fan mode, presets, and
  humidity control
- Added Select entity support: STRING variable with the current option, writable
  via programming or variable writes
- Added "Set Select" programming command with dynamic Select and Option
  dropdowns

<!-- #ifndef DRIVERCENTRAL -->

## v20260326 - 2026-03-26

### Fixed

- Fixed automatic driver updates not working when the leader instance is removed
  from the project

<!-- #endif -->

## v20260325 - 2026-03-25

### Fixed

- Fixed cover contact sensors sending duplicate notifications during open/close
  operations
- Fixed Yale DoorSense contact sensor sending duplicate "Closed" notifications
  on every poll cycle by tracking the last known door status and only reporting
  on actual state changes

## v20260319 - 2026-03-19

### Fixed

- Fixed an issue where entities were no longer being detected reliably on
  connection

## v20260318 - 2026-03-18

### Fixed

- Fixed Bluetooth Coordinator failing to connect to active BLE devices
  (SwitchBot, Yale locks) through proxies

## v20260314 - 2026-03-14

### Added

- Added fan support with on/off, speed control (1-6 speed variants), direction,
  and oscillation
- Added ESPHome Yale sub-driver for Yale/August BLE smart locks with lock/unlock
  control, door sense, and battery monitoring

## v20260217 - 2026-02-17

### Added

- Added Bluetooth proxy support with scanner infrastructure, advertisement
  parsing, and GATT connection management
- Added ESPHome Bluetooth Coordinator driver for multi-proxy aggregation with
  RSSI-based routing and connection failover
- Added room presence tracking with RSSI-based detection, anti-flapping, and
  contact sensor bindings
- Added ESPHome BTHome sub-driver for Shelly BLU and BTHome v1/v2 sensors
- Added ESPHome Govee sub-driver for temperature, humidity, and meat thermometer
  sensors
- Added ESPHome SwitchBot sub-driver for Bot, Plug Mini, Meter, Motion, and
  Contact devices
- Added device log forwarding to the ESPHome driver

## v20251031 - 2025-10-31

### Fixed

- Fixed compatibility with ESPHome 2025.10.0 for devices configured without
  passwords
- Fixed password authentication failures being poorly detected and reported

## v20251022 - 2025-10-22

### Fixed

- Fixed an issue with parsing unknown fields in protobuf messages

## v20251019 - 2025-10-19

### Added

- Added support for OpenSSL with "Encryption Key" authentication mode across all
  applicable algorithms

### Fixed

- Fixed a bug with the authentication flow in the latest 2025.10.0 firmware

## v20250811 - 2025-08-11

### Fixed

- Fixed switch entities not responding to bound relay proxies

## v20250715 - 2025-07-14

### Fixed

- Fixed bug causing entities to not be discovered on connect

## v20250714 - 2025-07-14

### Added

- Added support for encrypted connections using the device encryption key

## v20250619 - 2025-06-19

### Added

- Added ratgdo specific documentation

## v20250606 - 2025-06-06

### Added

- Initial Release
