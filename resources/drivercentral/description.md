<img src="https://drivercentral.io/images/companies/61/ESPHome/facts-strip-2400x136.png?1794019653122" alt="" width="1200" height="68" />

## Overview

*This software is neither affiliated with nor endorsed by either Control4 or
ESPHome.*

Integrate [ESPHome-based devices](https://devices.esphome.io/) into Control4.
ESPHome is an open-source system that turns common microcontrollers into smart
home devices through simple YAML configuration. This driver connects to each
ESPHome device on your local network and brings its lights, fans, locks, climate
controls, switches, sensors and buttons into Control4, with no cloud service in
between. An ESPHome device can also serve as a Bluetooth proxy, so Bluetooth
devices near it join the project too.

## Features

- Local control over your network, with no cloud service, encrypted when the
  device has an encryption key
- Real-time updates from every supported entity on the device
- Lights, fans, locks, climate and water heaters as native Control4 devices
  through the included sub-drivers
- Switches and covers as Control4 relays, and binary sensors as contact sensors
- Device events as keypad buttons that drive loads, with a light on the device
  as the button's LED
- Bluetooth proxy support for SwitchBot, BTHome, Govee, Yale and August, and
  SereneScent devices, with the Bluetooth Coordinator to combine several proxies
- Sensors and other readings as variables for Control4 programming

## Included drivers

### ESPHome

Add one for each ESPHome device. It connects to the device and brings in its
switches, covers, sensors, buttons and events, and its light, fan, lock and
climate entities bind to the drivers below.

### ESPHome Light, Fan, Lock and Climate

A native Control4 light, fan, lock or thermostat for one of the device's
entities, bound to the ESPHome driver. ESPHome Climate also covers water
heaters.

### ESPHome Bluetooth Coordinator

Combines several ESPHome Bluetooth proxies, and reaches each Bluetooth device
through the proxy that hears it best.

### ESPHome SwitchBot, BTHome, Govee, Yale and SereneScent

A Control4 driver for each kind of Bluetooth device, reached through an ESPHome
Bluetooth proxy. The tables below list what each covers.

## System requirements

- Control4 OS 3.3+
- ESPHome devices on the controller's local network

## Compatibility

### Verified devices

The driver works with any ESPHome device, and we have tested it extensively with
the ones below.

- [ratgdo](https://ratcloud.llc)
- konnected Smart Garage Door Opener
  [blaQ](https://konnected.io/products/smart-garage-door-opener-blaq-myq-alternative)/[White](https://konnected.io/products/smart-garage-door-opener)

Both are relay-based garage door controllers; the Garage Door Configuration
Guide in the documentation covers their setup.

### Supported Bluetooth devices

As a Bluetooth proxy, an ESPHome device brings in the Bluetooth devices below
through their sub-drivers.

| Protocol    | Sub-Driver          | Example Devices                                      |
| ----------- | ------------------- | ---------------------------------------------------- |
| SwitchBot   | ESPHome SwitchBot   | Bot, Plug Mini, Relay Switch, Meter, Motion, Contact |
| BTHome      | ESPHome BTHome      | Shelly BLU Button/Door/Motion/H&T, DIY sensors       |
| Govee       | ESPHome Govee       | Temperature/humidity monitors, meat thermometers     |
| Yale/August | ESPHome Yale        | Yale and August smart locks                          |
| SereneScent | ESPHome SereneScent | Homedics SereneScent Diffuser                        |

See the individual sub-driver documentation for device-specific details.

### Supported ESPHome entities

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

*\* Voice Assistant requires a speech-to-text and intent processing pipeline,
which Control4 does not provide, so this entity type is not supported.*
