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

- Fixed the HVAC state freezing on the previous value during a heat pump's
  defrost cycle; defrosting now reports as Heating, and unmapped climate
  modes/actions log a warning instead of being silently dropped
- Fixed latch-style ESPHome locks (`supports_open`) reading as "unknown" in
  Control4 while reporting the open or opening state; both now map to unlocked
- Fixed overlapping status refreshes silently racing each other for the same
  response callbacks; refreshes are now serialized and a displaced request
  callback logs a warning
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

## v20260326 - 2026-03-26

<!-- #ifndef DRIVERCENTRAL -->

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
