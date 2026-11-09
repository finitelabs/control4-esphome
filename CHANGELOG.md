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

### Fixed

- Fixed a Yale lock in Persistent mode never reconnecting after its reconnect
  attempts ran out. It now tries again when the lock is heard, at most every
  five minutes.
- Fixed a Yale lock still showing online after its reconnect attempts ran out or
  its connection to the ESPHome driver or Bluetooth Coordinator was removed
- Fixed a Yale lock in Poll mode with no Offline Key connecting to the lock at
  every poll. It now waits for a key and Driver Status says one is required.
- Fixed Bluetooth sub-drivers still showing connected, and the Bluetooth
  Coordinator still using a proxy, after the ESPHome device acting as that proxy
  went offline
- Fixed a Bluetooth sub-driver that controls its device starting its connection
  over whenever another driver bound to the same ESPHome device loaded or asked
  for its state
- Fixed Bluetooth sub-drivers showing Waiting for data after a driver update
  until their device next advertised
- Fixed the Govee, BTHome and SwitchBot drivers hiding their readings in
  Composer after a driver start until the device next reported them
- Fixed the SwitchBot driver's Encryption Status putting Lua file and line
  details in front of the reason when fetching its keys from the SwitchBot cloud
  failed
- Fixed the Bluetooth Coordinator's RSSI Freshness setting having no effect when
  it picked a proxy for a device
- Fixed ESPHome entity variables ignoring a value set from programming until the
  device reported a value of its own
- Fixed a relay bound to an ESPHome cover's Open, Close or Stop connection
  showing its state as unconfirmed after a controller restart
- Fixed Composer showing the Yale Offline Key, the BTHome Bind Key, the ESPHome
  lock driver's Lock Code and the SwitchBot Key ID and Encryption Key in plain
  text. A BTHome Bind Key that isn't 32 hex characters is now cleared and Driver
  Status says why.
- Fixed the Bluetooth Coordinator firing a device's Entered Room events and
  changing its room variables at every driver update or controller restart when
  the device had not moved
- Fixed the SwitchBot Contact Sensor showing a door as closed while it was open
- Fixed an ESPHome entity named like one of the ESPHome driver's own settings
  writing its reading into that setting, which could point the driver at the
  wrong IP address
- Fixed the ESPHome driver logging a Lua error when a message from an
  unencrypted device arrived in pieces
- Fixed a light running on to the end of its ramp when Control4 stopped it part
  way. A light already in a project gets this at its next controller restart.
- Fixed a color set on a light while it is off giving way to the light's Color
  On Mode at its next on. The light now comes on in that color, from a Navigator
  as from programming or a scene, and Dim-To-Warm leaves it until the light
  turns off.
- Fixed an ESPHome light or lock showing offline after a controller restart,
  until its device next reconnected, when the ESPHome driver had connected first
- Fixed a light briefly showing its earlier color again when a white was set
  right after another color
- Fixed a keypad button on a light's Off Button Link showing its lit color while
  the light was on, and keypad buttons on a light's Button Links now show the
  project's button LED colors in place of defaults

### Changed

<!-- #ifdef DRIVERCENTRAL -->

- Changed Log Level to stop at 4 - Debug unless Finite Labs support has opened
  the Lua tab with a Support Code
  <!-- #endif -->
- Changed Reset Driver on the ESPHome driver to leave Automatic Updates and
  Update Channel as they are

## v20261106 - 2026-11-06

### Added

- Added a Restart Bluetooth Proxy When Stuck property, off by default, which
  presses the restart button you choose when a Bluetooth proxy stops answering,
  at most once every 6 hours
  <!-- #ifdef DRIVERCENTRAL -->
- Added a Support Code property to the ESPHome driver and its sub-drivers. A
  code from Finite Labs support opens the driver's Lua tab in Composer for an
  hour.
- Added a Cloud Monitoring property, on by default, and a Diagnostics Snapshot
  action to every driver. Cloud Monitoring sends Finite Labs an hourly report of
  the driver's memory use and a report of each error it hits.
  <!-- #endif -->

### Fixed

- Fixed an ESPHome climate device that does not report what it is doing never
  setting the thermostat's HVAC state. The state now follows the mode, and a
  water heater reads Heating while it is on and Off while it is off.
- Fixed a Bluetooth proxy that held a device connected but no longer answered it
  going unreported. Bluetooth Proxy Status now asks for a power cycle, and the
  device shows that the proxy needs a restart.
- Fixed a SwitchBot command sent while the device was still connecting failing,
  and a two-channel SwitchBot relay turning on only one channel when a scene set
  both
- Fixed a Yale lock or unlock in Persistent mode being dropped, not retried,
  when the connection failed
- Fixed an ESPHome switch turning off when a relay driver bound to it asked for
  its state, and a relay driver bound to an ESPHome switch or cover running its
  programming each time the device reconnected or the cover updated
- Fixed a pulsed ESPHome switch staying on when another switch on the same
  device was pulsed before it finished
- Fixed a light's color in Navigator and in its variables staying on the old
  color after a color preset was picked, or after the light turned on with Color
  On Mode set to Previous or to a preset
- Fixed a light reporting its capability and color variables as changed each
  time its driver started or its device reconnected, with nothing changed
  <!-- #ifndef DRIVERCENTRAL -->
- Fixed changing Automatic Updates or Update Channel on an ESPHome driver
  briefly holding up every other ESPHome driver, longer in a project with many,
  while the change was copied to them
  <!-- #endif -->
  <!-- #ifdef DRIVERCENTRAL -->
- Fixed an ESPHome driver logging an error every 30 minutes while Automatic
  Updates was On, and waiting a little longer to reconnect a device each time
  <!-- #endif -->
- Fixed button link LEDs staying lit when a light was bound to another device
  that reports off
- Fixed contact sensors, relays and Bluetooth presence running their programming
  again after a driver start, a reconnect or a bind when nothing had changed. A
  device or room not heard again after a restart now reads away or empty once
  the Away Timeout passes.
- Fixed passwords, keys and lock codes appearing in a driver's log at the higher
  log levels
- Fixed Reset Driver leaving part of a driver's setup behind and clearing a
  device's encryption keys. It now removes every connection, variable and event
  the driver made and resets its settings, keeping only the address, login and
  keys that reach the same device.
- Fixed a Bluetooth Coordinator room deleting its Occupied and Empty events, and
  the programming on them, when its last Bluetooth proxy was removed or moved to
  another room
- Fixed the Bluetooth Coordinator starting on a controller below its minimum OS
  instead of showing that it is disabled, as the other drivers do
- Fixed locks adding a history line and running their programming for a status
  that had not changed, and a fan telling Control4 it turned on or off after a
  driver start or a reconnect when it had not
- Fixed a lock in Persistent mode going back to its old status for a while after
  a lock or unlock, with a history line for it, when its periodic status check
  came while the bolt was still moving
- Fixed a cover without position control on ESPHome 2025.8 or later reading
  unknown and ignoring Open, Close and Stop
- Fixed an ESPHome switch, climate device or water heater that had not reported
  a state yet reading as off, or with its default settings, on ESPHome 2026.9 or
  later

### Changed

- Changed a color set on a Dim-To-Warm light while it is on to stay until the
  light turns off, through dimming and brightening, instead of until the next
  brightness command
  <!-- #ifdef DRIVERCENTRAL -->
- Changed Automatic Updates to one setting shared by the ESPHome driver and its
  sub-drivers, so changing it on any of them changes it on all of them
  <!-- #endif -->
- Changed ESPHome Lock and ESPHome Yale to Composer's Locks category, where
  Control4's own lock drivers are listed

## v20261027 - 2026-10-27

### Added

- Added Button LEDs to the ESPHome driver, which light one of the device's
  lights in a bound load's button colors, the way a Control4 keypad lights its
  buttons
- Added the ESPHome Light driver's button LED colors to Composer, for keypad
  buttons linked to the light

### Fixed

- Fixed a keypad button linked to an ESPHome light showing the wrong LED state
  until the light next changed
- Fixed a Yale lock or unlock, or a SwitchBot press, running minutes after it
  was tapped on a slow connection. A command still waiting after 60 seconds is
  now dropped and reported as failed.

<!-- #ifndef DRIVERCENTRAL -->

## v20261025 - 2026-10-25

### Fixed

- Fixed automatic updates leaving drivers a version behind when two or more
  drivers from this repository were installed. Each driver now updates in turn,
  and a system left behind catches up on its own.

<!-- #endif -->

## v20261024 - 2026-10-24

### Added

- Added the ESPHome SereneScent sub-driver for Homedics SereneScent BLE
  diffusers, with power, mist intensity and light color control, keypad button
  links and a power relay
- Added automatic offline key updates to the Yale driver, which checks the Yale
  cloud for a new key daily and whenever the lock rejects its key

### Fixed

- Fixed a Yale lock bound to the Bluetooth Coordinator failing every connection
- Fixed a device connected through the Bluetooth Coordinator not noticing when
  its connection closed, which made a Yale lock wait out a 10-second timeout
  each time
- Fixed the SwitchBot and Yale drivers waiting forever when a Bluetooth proxy or
  the coordinator never finished a connection request. The proxy now fails a
  connection after 30 seconds, the coordinator tries the next proxy, and the
  driver gives up after about three minutes.
- Fixed a Yale lock in Persistent mode counting a failed or timed-out handshake
  as two failures, using up its reconnect attempts twice as fast and retrying a
  lock or unlock that hit it as a status read instead
- Fixed the SwitchBot and Yale drivers keeping the proxy's connection slot and
  getting stuck when a connection came up without the device's Bluetooth
  characteristics. They now disconnect, free the slot and treat it as a failed
  connection.
- Fixed a SwitchBot Bot holding one of the ESPHome device's Bluetooth connection
  slots after it was bound, or after the device reconnected, until its next
  press
- Fixed a Yale lock abandoning its connection, and a SwitchBot showing
  Connection Failed for a press that went through, when a connection failure was
  reported after the device had connected
- Fixed one failed Bluetooth connection using up two of a Yale lock's reconnect
  attempts in Persistent mode, and taking a SwitchBot from Connection Failed
  straight to Listening
- Fixed a Yale lock dropping a lock or unlock tapped while it waited for its
  first connection after a restart or a change of Connection Mode
- Fixed a Yale lock newly bound to the Bluetooth Coordinator showing Waiting for
  data until it was locked or unlocked
- Fixed a Yale lock keeping the proxy's connection slot and stopping polling or
  reconnecting when a notification subscription failed or went unanswered
- Fixed the Bluetooth Coordinator trying a proxy with no free connection slot,
  and a slow connection taking minutes. The coordinator now skips a full proxy,
  and one proxy's attempt takes about a minute at most.
- Fixed a Bluetooth connection that failed or gave up leaving the proxy's
  connection slot in use, which could keep other devices on that proxy from
  connecting
- Fixed Advanced Lighting Scenes on an ESPHome light, where a flash scene with
  no delay or ramp hung the driver, Stop Scene Ramp did not stop the light, and
  a scene kept moving a light that was sent another command. A scene step now
  starts where the light is and fades over its own ramp time.
- Fixed overlapping ramps, fades, scene steps and stops starting from or showing
  the wrong level or color, or not stopping the light. A stop now holds the
  light where it is.
- Fixed a ramped On that changes a light's color starting in the old color,
  which kept some lights dark for most of the ramp, or restarting a moment in,
  and a color sent right after it being dropped
- Fixed a held Top or Toggle button ramping toward the Default On level instead
  of full, and a button pressed during a ramp acting on the level it began from
- Fixed a light ignoring its Color On Mode, on level and default ramp rate until
  one was changed in Composer, and Color On Mode not applying a color preset or
  the right Previous color. A color sent while the light is off now waits for
  its next on.
- Fixed a cold and warm white light coming on dimmer and warmer than asked with
  Dim-To-Warm, a Dim-To-Warm light being shown in two colors at every level
  change, and a light's On or Dim-To-Warm color being undone by a scene's color
  or one set while it was off
- Fixed ESPHome lights with a separate white keeping the white lit under a color
  and the color lit under a color temperature, and mixing whites from red, green
  and blue. A color at or near white now lights the white.
- Fixed Max On Level and Min On Level having no effect. A light's 1 to 100 % now
  runs between them, as on a Control4 dimmer.
- Fixed a light's level or color set outside Control4 being undone when a
  Control4 ramp ended, or not shown while the light was off
- Fixed a light sent a level and then a color being shown for a moment in the
  color it had before
- Fixed a light turned on over a ramp time being shown as off until the ramp
  ended
- Fixed a light asked for its level during a ramp being shown as stopped where
  the ramp began, or as off in a ramp up from off
- Fixed the keypad LEDs on a light's button links showing it off while it was
  turned on over a ramp time, and staying lit when the light went offline
- Fixed a light stopped or turned off during a ramp up from off saving 1 % as
  its Previous On level instead of the one it had, or the level it had reached
- Fixed a light sent two levels in quick succession being shown for a moment at
  the first, which a stop could then save as its Previous On level
- Fixed a light being shown as off, and running its Light Off Programming and
  then its Light On Programming, when Log Level, Log Mode or Device Log
  Forwarding was changed while the device's logs were forwarded, as when Log
  Mode turns itself off after three hours
- Fixed a light asked for its level before its ESPHome device had reported being
  shown as off
- Fixed a light running its Brightness Changed, Level Change or Color Changed
  Programming after a controller restart, and a full color light running its
  Color Changed Programming after a driver update, a bind or a device report,
  when nothing had changed. Control4 itself still reports a color light's color
  variables as changed after a controller restart.
- Fixed a light that only turns on and off being shown as off, and running its
  Light Off Programming and then its Light On Programming, when its driver was
  updated while it was on
- Fixed a light sent a command while its ESPHome device was offline, or its
  ESPHome Light connection was removed, being shown at the level sent and
  running its Light On or Light Off Programming. It now shows only what the
  device reports.
- Fixed a thermostat being shown in an HVAC mode, vane position or water heater
  mode sent while its ESPHome device was offline, or its ESPHome Climate
  connection was removed, which the device never took
- Fixed a light, fan or lock still being shown online after its ESPHome Light,
  ESPHome Fan or ESPHome Lock connection was removed
- Fixed a switch, number, select, text, date, time or datetime variable keeping
  a value the device never took, set while it was offline or as a date or time
  in another format. It now goes back to the device's value.
- Fixed the ESPHome driver's Driver Status reading Refresh failed for a few
  seconds, in place of why it was not connected, when a connection was made or a
  sub-driver loaded while the device was offline
- Fixed a device selected only under Select Presence Devices on the Bluetooth
  Coordinator never being placed in a room. Every presence device's room now
  comes from the signal each proxy reports for it, smoothed by the RSSI
  Smoothing Factor.
- Fixed a presence device on the Bluetooth Coordinator staying in a room whose
  proxy no longer saw it, until it went Away, whenever the proxy that did see it
  was not stronger than its last signal there by the Room Change Hysteresis
- Fixed a Bluetooth Coordinator presence device's RSSI variable showing a long
  fraction or another proxy's raw reading. It now shows, in whole dBm, the
  signal that Minimum Room RSSI is checked against.
- Fixed a presence device on the Bluetooth Coordinator moving to another room on
  one weak signal from a proxy that had last heard it close by, more than 30
  seconds before
- Fixed a Bluetooth Coordinator presence device's Present binding staying open
  while the device was home but in no room
- Fixed the Bluetooth Coordinator's Last Presence variables still describing the
  previous event when Left Room and Any Device Left Room fired for a device
  whose signal dropped below Minimum Room RSSI
- Fixed a presence device on the Bluetooth Coordinator staying in a room after
  that room's proxy was disconnected from the coordinator. The device now leaves
  the room, stays Home and is placed again by its next signal.
- Fixed a room on the Bluetooth Coordinator staying Occupied after its last
  presence device was removed from Select Presence Devices, which kept later
  occupants from firing its Occupied or Empty events
- Fixed Yale locks failing almost every connection since v20260802, so Poll mode
  never read the lock and Persistent mode gave up after its retries
- Fixed a Yale lock showing an unknown state for a moment after every lock and
  unlock. A lock or unlock that jams now shows a fault.
- Fixed a Yale lock showing as unlocked for a moment just after it locked, and
  as locked just after it unlocked
- Fixed Verify and Fetch Keys taking another lock's key in a Yale account with
  several locks when this lock's MAC address was not known yet
- Fixed Yale Cloud Status showing a meaningless word in place of a Yale cloud
  error
- Fixed the Yale driver writing the lock's offline key to the log at Debug level
  when fetching keys
- Fixed a SwitchBot Relay Switch ignoring the device's reply to every command,
  so a command it refused, as with an incorrect encryption key, went unreported
- Fixed the programming events of an ESPHome event entity, a BTHome button or
  dimmer and a Govee probe or sensor error leaving the device's name out of
  their title in Composer Pro
- Fixed a Yale lock or unlock sent while the driver was still connecting being
  lost, and a lock or unlock retried after a failed connection undoing one sent
  since

### Changed

- Changed a color set on a Dim-To-Warm light to last until the next brightness
  command, even one for the level the light is already at, instead of until the
  light is turned off

## v20260926 - 2026-09-26

### Fixed

- Fixed event, BTHome and SwitchBot button links not activating Advanced
  Lighting scenes
- Fixed entities with no name of their own being left out or given a blank name
  instead of their device's name
- Fixed entities that share an ESPHome key being set up as one entity instead of
  each getting its own variables and connections
- Fixed commands to entities on an ESPHome sub-device being ignored on ESPHome
  2025.8 and newer
- Fixed an event entity's Programming events disappearing after a controller
  reboot, or keeping their old name after a rename

## v20260922 - 2026-09-22

### Added

- Added presets to the climate driver, each storing a setpoint, HVAC mode, fan
  mode and vane position, and applicable from Navigator or from Programming
- Added preset scheduling by weekday and time, kept by Control4, with the driver
  applying each preset as it falls due
- Added holds, so a setting or preset chosen by hand holds until the next
  scheduled event, and a Permanent hold, with or without a schedule, stays until
  it is cleared by hand or from Programming
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
  connected after the driver's IP address, port or credentials were changed or
  cleared, and thermostats and water heaters after the ESPHome device went
  offline
- Fixed thermostats and water heaters always showing Fahrenheit. They now follow
  the project's temperature scale, and a setting in Composer can override it for
  one thermostat.
- Fixed a thermostat staying on its last mode after the unit was turned off
  outside Control4. It now shows Off, shows when heating or cooling stops, and
  shows the fan switched to On.
- Fixed a thermostat never showing whether it is heating, cooling, idle, drying
  or running the fan only
- Fixed Heat never engaging on a water heater that had not yet stored an
  operating mode
- Fixed a temperature of exactly 0°C, or a humidity of 0%, not being shown
- Fixed a temperature, setpoint, humidity or sensor value the device had not
  measured yet showing as a huge number, which a setpoint nudge then clamped to
  the maximum. It is now blank until a real reading arrives.
- Fixed a newly installed climate driver forwarding a bound temperature sensor's
  readings to the device before the thermostat had enabled the remote sensor
- Fixed the climate driver's temperature and humidity outputs appearing as audio
  connections in Composer instead of control connections. Nothing needs
  reconnecting, since the audio ones could not be connected to anything.
- Fixed an "Error setting default color rate from driver" message in Composer
  when opening the properties of an ESPHome light
- Fixed Composer's test panel graying out the dimming controls for ESPHome
  lights that support brightness
- Fixed a BTHome or SwitchBot button doing nothing to a dimmer it was linked to.
  A button now reports a press and then a click, as a Control4 keypad does, so
  every linked load responds.
- Fixed a SwitchBot Bot running its action twice for a single press of a linked
  keypad button, which turned a toggle back to where it started
- Fixed Bluetooth proxy recovery needing a button with restart in its name and
  rebooting the whole device. It now restarts the scanner itself on any proxy
  that reports its scanner state, keeping its Bluetooth connections up.
  <!-- #ifndef DRIVERCENTRAL -->
- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime
  <!-- #endif -->

### Changed

- Changed climate devices that report a single target to show one setpoint
  instead of a heat and cool pair, which they could never honor. Auto is
  unaffected.
- Changed the documentation to cover the Connected variable every driver
  publishes, which programming can use to show whether a device is online

## v20260816 - 2026-08-16

### Added

- Added the konnected Smart Garage Door Opener to the verified devices, and
  generalized the ratgdo setup into a shared Garage Door Configuration guide
  that covers both

### Fixed

- Fixed Bluetooth proxies logging a spurious "Property 'Select Bluetooth
  Devices' not registered" warning at every driver startup
- Fixed a proxy's Bluetooth device selection being erased when it was bound to a
  Bluetooth Coordinator, instead of kept for when it is unbound
- Fixed Bluetooth proxies in Coordinator Mode reporting their connection slots
  as oversubscribed

## v20260802 - 2026-08-02

### Added

- Added a Connected variable to the main driver and every sub-driver with a
  Driver Status, so programming can react when a device connects or disconnects
- Added an Open Latch action to the ESPHome Lock driver for locks that support
  opening the latch

### Fixed

- Fixed a slow connection attempt tearing down the healthy connection that
  replaced it
- Fixed the HVAC state freezing during a heat pump's defrost cycle, which now
  reads as Heating. An unknown climate mode or action now logs a warning instead
  of being dropped.
- Fixed latch-style ESPHome locks reading as unknown in Control4 while open or
  opening. Both now read as unlocked.
- Fixed cover contacts and Yale DoorSense sending nothing to a newly bound
  consumer until the state changed. A consumer now gets the last known state
  when it is bound.
- Fixed Reset Driver leaving bound sensors, cover contacts, BTHome bindings and
  Yale DoorSense stale until the next state change
- Fixed a refresh or Bluetooth request hanging forever when the connection
  dropped mid-request. It now fails at once with a Disconnected error.
- Fixed SwitchBot channel relays and motion, contact, leak and tamper sensors
  leaving bound consumers stale after a driver restart until the next state
  change
- Fixed a request hanging forever when a second request for the same response
  started before it finished, which could leave entity or Bluetooth service
  discovery empty
- Fixed a superseded status refresh being reported as "Refresh failed" and
  dropping the device connection out from under the refresh that replaced it

## v20260728 - 2026-07-28

### Added

- Added temperature and humidity value connections for temperature and humidity
  sensors, in the sensor's own unit, so they can be bound to thermostats and
  other drivers

### Fixed

- Fixed cover contacts, Yale DoorSense, BTHome bindings, and the SwitchBot Bot
  relay leaving bound consumers stale after a driver restart or update until the
  next state change
- Fixed every entity's state appearing frozen in Control4 on ESPHome 2026.7 and
  later, with covers stuck on Unknown and sensor variables never updating
- Fixed devices logging an outdated API warning on every connection

## v20260711 - 2026-07-11

### Fixed

- Fixed Bluetooth Coordinator connections to ESPHome proxies, and other
  connections the driver creates, disappearing after a controller reboot or
  Director restart
- Fixed an ESPHome light that only turns on and off advertising brightness and
  color to drivers that read its declared capabilities
- Fixed true or false variables for binary sensors, switches and BTHome sensors
  staying False in the Variables Agent while the state changed
- Fixed the ESPHome fan's Designate Preset command, which now keeps the preset
  across driver restarts, shows it in Composer and Navigator, and turns the fan
  on at that speed

## v20260512 - 2026-05-12

### Added

- Added brightness and dimming support to ESPHome lights with smooth ramping,
  preset management, and hold-to-dim button control
- Added color and color temperature support to ESPHome lights in every ESPHome
  color mode
- Added Advanced Lighting Scenes support to ESPHome lights so they can
  participate in lighting scenes alongside other Control4 dimmers

## v20260418 - 2026-04-18

### Added

- Added event entities, which create Control4 events for programming and keep
  the last event type in a variable
- Added date, time and datetime entities as writable string variables
- Added climate entities as Control4 thermostats with HVAC mode, setpoints, fan
  mode, presets and humidity control
- Added select entities as a writable string variable that holds the current
  option
- Added a Set Select programming command

<!-- #ifndef DRIVERCENTRAL -->

## v20260326 - 2026-03-26

### Fixed

- Fixed automatic driver updates not working when the leader instance is removed
  from the project

<!-- #endif -->

## v20260325 - 2026-03-25

### Fixed

- Fixed cover contact sensors sending duplicate notifications while opening or
  closing
- Fixed Yale DoorSense contact sensor sending duplicate "Closed" notifications
  on every poll cycle by tracking the last known door status and only reporting
  on actual state changes

## v20260319 - 2026-03-19

### Fixed

- Fixed an issue where entities were no longer being detected reliably on
  connection

## v20260318 - 2026-03-18

### Fixed

- Fixed the Bluetooth Coordinator failing to connect through proxies to the
  Bluetooth devices it controls

## v20260314 - 2026-03-14

### Added

- Added fan support with on and off, speed control, direction and oscillation
- Added the ESPHome Yale sub-driver for Yale and August Bluetooth smart locks,
  with lock and unlock, door sense and battery monitoring

## v20260217 - 2026-02-17

### Added

- Added Bluetooth proxy support
- Added the ESPHome Bluetooth Coordinator driver, which uses several Bluetooth
  proxies together and moves a device to another proxy when one fails
- Added room presence tracking by Bluetooth signal strength, with contact sensor
  bindings
- Added ESPHome BTHome sub-driver for Shelly BLU and BTHome v1 and v2 sensors
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

- Fixed the driver failing to read messages that carry fields it does not know

## v20251019 - 2025-10-19

### Added

- Added OpenSSL support for the Encryption Key authentication mode

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
