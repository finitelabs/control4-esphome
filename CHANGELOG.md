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

- Fixed ESPHome entities with no name of their own, such as a relay configured
  with `name: None`, being left out of variables, events and commands or given a
  blank name such as " State"; they now take their sub-device's or device's
  name, as Home Assistant shows them
- Fixed entities that share an ESPHome key, such as a sensor and a text sensor
  with the same name, being set up as one entity that took the state of all of
  them, so a relay could switch off on a power reading of 0. Each now gets its
  own variables and connections; existing ones stay with the entity their
  commands reached, and clashing names are resolved as the Programming Reference
  describes
- Fixed entities on an ESPHome sub-device ignoring every command from Control4
  on ESPHome 2025.8 and newer
- Fixed an event entity's Programming events not being declared when the driver
  loads, and keeping their old name after a rename on the device that keeps its
  ESPHome key, such as a change of capitals; they now load with the driver and
  follow the rename

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
