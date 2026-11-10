<img src="https://drivercentral.io/images/companies/61/ESPHome/facts-strip-2400x136.png?1794019653122" alt="" width="1200" height="68" />

## Overview

*Disclaimer: This software is neither affiliated with nor endorsed by either
Control4 or ESPHome.*

Integrate [ESPHome-based devices](https://devices.esphome.io/) into Control4.
ESPHome is an open-source system that transforms common microcontrollers, like
ESP8266 and ESP32, into smart home devices through simple YAML configuration.
ESPHome devices can be set up, monitored, and controlled using a web browser,
Home Assistant, or other compatible platforms. This driver monitors and controls
ESPHome devices directly from your Control4 system.

## Features

- Local network communication requiring no cloud services
- Real-time updates from all supported entities exposed by the device
- Supports encrypted connections using the device encryption key
- Variable Programming Support

## System requirements

- Control4 OS 3.3+

## Compatibility

### Verified Devices

This driver will generically work with any ESPHome device, but we have tested
extensively with the following devices:

- [ratgdo](https://ratcloud.llc)
- konnected Smart Garage Door Opener
  [blaQ](https://konnected.io/products/smart-garage-door-opener-blaq-myq-alternative)/[White](https://konnected.io/products/smart-garage-door-opener)

Both are relay-based garage door controllers; the Garage Door Configuration
Guide in the documentation covers their setup.

### Supported Bluetooth Devices

When used as a Bluetooth proxy, this driver supports the following BLE device
types through sub-drivers:

| Protocol    | Sub-Driver          | Example Devices                                      |
| ----------- | ------------------- | ---------------------------------------------------- |
| SwitchBot   | ESPHome SwitchBot   | Bot, Plug Mini, Relay Switch, Meter, Motion, Contact |
| BTHome      | ESPHome BTHome      | Shelly BLU Button/Door/Motion/H&T, DIY sensors       |
| Govee       | ESPHome Govee       | Temperature/humidity monitors, meat thermometers     |
| Yale/August | ESPHome Yale        | Yale and August smart locks                          |
| SereneScent | ESPHome SereneScent | Homedics SereneScent Diffuser                        |

See the individual sub-driver documentation for device-specific details.

### Supported ESPHome Entities

| Entity Type         | Supported |
| ------------------- | --------- |
| Alarm Control Panel | ❌        |
| API Noise           | ✅        |
| Binary Sensor       | ✅        |
| Bluetooth Proxy     | ✅        |
| Button              | ✅        |
| Camera              | ❌        |
| Climate             | ✅        |
| Cover               | ✅        |
| Date                | ✅        |
| Datetime            | ✅        |
| Event               | ✅        |
| Fan                 | ✅        |
| Light               | ✅        |
| Lock                | ✅        |
| Media Player        | ❌        |
| Number              | ✅        |
| Select              | ✅        |
| Sensor              | ✅        |
| Siren               | ❌        |
| Switch              | ✅        |
| Text                | ✅        |
| Text Sensor         | ✅        |
| Time                | ✅        |
| Update              | ❌        |
| Valve               | ❌        |
| Voice Assistant     | ❌\*      |
| Water Heater        | ✅        |

*\* Voice Assistant requires a speech-to-text and intent processing pipeline
(e.g. Home Assistant Assist). Control4 does not natively provide voice intent
handling, so this entity type is not supported.*
