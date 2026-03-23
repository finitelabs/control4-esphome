# <span style="color:#17BCF2">Changelog</span>

<!-- prettier-ignore-start -->
[//]: # "## v[Version] - YYY-MM-DD"
[//]: # "### Added"
[//]: # "- Added"
[//]: # "### Fixed"
[//]: # "- Fixed"
[//]: # "### Changed"
[//]: # "- Changed"
[//]: # "### Removed"
[//]: # "- Removed"
<!-- prettier-ignore-end -->

## Unreleased

### Fixed

- Fixed DoorSense contact sensor sending duplicate "Closed" notifications on
  every poll cycle by tracking last known door status and only reporting on
  actual state changes

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
