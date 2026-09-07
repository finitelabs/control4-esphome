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

- Added presets to the climate driver. A preset stores a setpoint, HVAC mode,
  fan mode and vane position, and can be applied from the app or from
  programming.
- Added preset scheduling. Presets can be scheduled by weekday and time. The
  schedule is kept by Control4, and the driver applies each scheduled preset
  when Control4 announces it, including when a schedule change alters the preset
  in force.
- Added holds. Changing the thermostat by hand, or choosing a preset by hand,
  holds the new setting until the next scheduled event, which then releases it.
  Clearing a held preset before then returns to the preset the schedule has in
  force. The hold options appear once a schedule exists and are withdrawn when
  the last scheduled event is deleted, since there is then no next event to hold
  until.
- Added vane control for climate devices that report swing modes, in the Extras
  tab.

### Changed

- Climate devices that report a single setpoint now show one setpoint instead of
  a heat and cool pair. Most heat pumps and mini splits work this way: they hold
  one target and decide internally whether to heat or cool toward it, so the
  pair could never be honored. Auto is unaffected. A preset saved before this
  release that carried a separate heat and cool value still works: the driver
  uses whichever of the two suits the mode. The preset editor no longer offers
  the second field, so re-saving such a preset keeps only the one setpoint.
- The climate driver's humidity output has moved to a different connection. This
  is a breaking change: if you had the humidity output connected to anything,
  that connection is lost when you update and has to be made again. The move was
  necessary because the position it previously occupied is the first slot the
  driver uses for connections it creates itself, so a driver that created one
  could remove the humidity connection without warning.

### Fixed

- Fixed Heat never engaging on a water heater that had not yet stored an
  operating mode.
- Fixed the climate driver's temperature and humidity outputs appearing as audio
  connections in Composer instead of control connections.
- A temperature, setpoint or humidity the device has not measured yet is no
  longer shown. The protocol decoder turned such a reading into a number near
  5.1e38, which the climate driver displayed as-is and which a setpoint nudge
  then clamped to the maximum. Sensor values were affected the same way and are
  now left unchanged until a real reading arrives.
- Deleting every scheduled event now releases the hold, including one the user
  set. The last scheduled preset stayed armed, so later manual changes kept
  raising "Until Next" against a schedule that no longer existed, and releasing
  the hold re-applied the deleted preset. A hold the user set was left standing
  with no hold control on screen to clear it, since a hold that runs until the
  next event has nothing to run until once the events are gone. A Permanent hold
  is deliberate and still survives.
- A newly installed climate driver no longer forwards a bound temperature
  sensor's readings to the device before the thermostat has enabled the remote
  sensor.
- A scheduled change that fell due while the controller was restarting now runs
  once the system is back, instead of being skipped until the same time next
  week. Only the most recent missed change is applied.
- After a restart the thermostat now re-states its hold and its active preset,
  rather than leaving on screen whatever it had last been told. A hold that
  ended during the restart, or a preset the device had since left, could stay
  displayed indefinitely.
- Renaming a preset no longer detaches it from the schedule. The schedule kept
  the old name, so every later occurrence of that event silently failed to run
  and the schedule stopped working for good.
- Deleting a preset that the schedule uses no longer leaves a hold that cannot
  be cleared. The thermostat kept asking to hold against the deleted preset, and
  releasing the hold re-raised it on the next update.
- The wording the thermostat uses for a hold now survives a restart. The driver
  takes that wording from the first hold the thermostat sets and reuses it, but
  after a restart it fell back to its starting guess, so a thermostat that calls
  a hold "Next Event" was offered a hold it does not use.
- A hold can no longer be set when there is no schedule at all. Nothing could
  have released it: a hold runs until the next scheduled event, and the
  thermostat offers no hold control while there are no events.
- A two hour or permanent hold no longer renames the hold the driver raises for
  itself. The thermostat's own wording is still adopted, but only from a hold
  that means "until the next event".
- The preset shown as active no longer flips between two presets that both match
  what the thermostat is doing. Where one preset is contained in another, the
  one that pins down more of the settings is now the one reported, and a preset
  being held or scheduled is preferred over both.
- A reading of exactly zero is no longer dropped. Zero degrees or zero percent
  arrives as an omitted value, which was read as "not measured", so freezing
  point disappeared from the thermostat and a preset at zero could never match.
- A schedule the thermostat sends in an unreadable form no longer erases the
  stored schedule. It was indistinguishable from an empty schedule, so a single
  bad message stopped the schedule running until the thermostat happened to send
  it again.
- Choosing a preset while the device is unreachable no longer reports a hold and
  an HVAC mode change that never happened. The command cannot be delivered, so
  nothing is claimed for it. Releasing a hold still works while the device is
  away.
- Pointing a driver at a water heater no longer runs a schedule left over from a
  climate device. The old schedule stays stored, so pointing it back restores
  it.
- A preset that asks for an HVAC mode the device does not offer now says so in
  the log instead of applying the rest in silence.
- A restart no longer rewrites the stored schedule and preset list when nothing
  has changed.

<!-- #ifndef DRIVERCENTRAL -->

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.
- Fixed thermostats and water heaters always showing Fahrenheit. They now follow
  the project's temperature scale, and the Celsius/Fahrenheit setting in
  Composer can be used to override it for an individual thermostat.
- Fixed thermostats and water heaters staying shown as connected after the
  ESPHome device went offline.
- Fixed an "Error setting default color rate from driver" message in Composer
  when opening the properties of an ESPHome light.
- Fixed Composer's test panel greying out the dimming controls for ESPHome
  lights that do support brightness. Dimming from the Control4 app was never
  affected.
- Fixed lights, thermostats, water heaters, fans and locks still showing as
  connected after the ESPHome driver's IP address, port or credentials were
  changed or cleared. They now go offline with the device until it reconnects.

### Changed

- Documented the `Connected` variable that every driver publishes, so it can be
  used in Programming to show whether a device is online.

<!-- #endif -->

## v20260816 - 2026-08-16

### Added

- Added the konnected Smart Garage Door Opener to the verified devices, and
  generalized the ratgdo setup into a shared Garage Door Configuration guide
  that covers both.

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
  no longer sends the deprecated `object_id` field. The driver no longer reads
  `object_id`, and log messages now identify entities as `type 'Name' (key=N)`.
- Bumped the ESPHome native API version advertised in `HelloRequest` from 1.0 to
  1.14 so devices no longer log `using outdated API 1.0, update to 1.14+` on
  every connection

## v20260711 - 2026-07-11

### Fixed

- Fixed Bluetooth Coordinator connections to ESPHome proxies (and other
  dynamically created connections) disappearing after a controller reboot or
  Director restart. Dynamic bindings are now restored early enough in driver
  startup for Director to reconnect them.
- Declare ESPHome light hardware capabilities (dimming, color, color
  temperature) conservatively in the static baseline and enable them at runtime
  from the entity's discovered color modes. A full static baseline advertised
  brightness and color for an on/off-only ESPHome light to capability consumers
  that read the static declaration instead of the runtime-narrowed set.
- Fixed BOOL variables (`<Entity> State` for binary_sensor and switch, plus all
  BTHome boolean sensors) staying as `False` in the Variables Agent even when
  the underlying state was changing. Variables now serialize as `"0"`/`"1"`
  matching what Control4 expects.
- Fixed ESPHome fan `Designate Preset` command: the handler now reads the
  correct `PRESET` param (was `SPEED`), clamps to the driver's speed count,
  persists the value across driver restarts, notifies the proxy so Composer and
  Navigator reflect the designated preset, and applies the preset when the fan
  is turned on so `Turn On Fan` runs at the designated speed.

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
- Improved password authentication failure detection and error reporting

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
