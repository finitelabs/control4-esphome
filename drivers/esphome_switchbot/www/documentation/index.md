[copyright]: # "Copyright 2026 Finite Labs, LLC. All rights reserved."

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="ESPHome SwitchBot" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4, ESPHome, or SwitchBot.

<!-- #endif -->

Control all SwitchBot devices from Control4 through an ESPHome Bluetooth Proxy.
This unified driver supports Bot, Plug Mini, Relay Switches, Meters, Motion
Sensors, Contact Sensors, and Water Leak Detectors.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
  - [Supported Devices](#supported-devices)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Adding the Driver](#adding-the-driver)
  - [Binding to ESPHome Proxy](#binding-to-esphome-proxy)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
    - [Encryption Settings](#encryption-settings)
    - [Device Info](#device-info)
    - [Device Data](#device-data)
  - [Driver Actions](#driver-actions)
- [Device Types](#device-types)
  - [Bot](#bot)
  - [Plug Mini](#plug-mini)
  - [Relay Switches](#relay-switches)
  - [Meters](#meters)
  - [Motion and Presence Sensors](#motion-and-presence-sensors)
  - [Contact Sensor](#contact-sensor)
  - [Water Leak Detector](#water-leak-detector)
- [Programming](#programming)
  - [Events](#events)
  - [Variables](#variables)
  - [Connections](#connections)
- [Troubleshooting](#troubleshooting)
<!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)
<!-- #endif -->
- [Support](#support)
- [Changelog](#changelog)

</div>

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">System Requirements</span>

- Control4 OS 3.3+
- ESPHome driver configured with Bluetooth Proxy enabled
- ESP32 device with `bluetooth_proxy` component

# <span style="color:#17BCF2">Features</span>

- **Unified driver** for all SwitchBot device types
- **Active and passive** BLE connection modes
- **Encryption support** for Relay Switch devices
- **Automatic key fetching** from SwitchBot cloud
- **Dynamic bindings** created based on device type
- **Event programming** for sensors and contact devices
- **Control4 proxy integration** (Relay, Contact Sensor, Temperature, Humidity)

> **Connection Types:** Active devices (Bot, Plug, Relay) use one of the ESP32's
> limited connection slots (typically 3 available). Passive devices (Meters,
> Sensors) use advertisement monitoring and don't consume slots.

# <span style="color:#17BCF2">Compatibility</span>

## Supported Devices

| Device               | Mode    | Bindings                              | Encryption |
| -------------------- | ------- | ------------------------------------- | ---------- |
| Bot                  | Active  | RELAY + BUTTON_LINK (mode-dependent)  | No         |
| Plug Mini            | Active  | RELAY                                 | No         |
| Relay Switch 1       | Active  | RELAY                                 | Yes        |
| Relay Switch 1PM     | Active  | RELAY                                 | Yes        |
| Relay Switch 2PM     | Active  | RELAY x2                              | Yes        |
| Meter / Meter Plus   | Passive | TEMPERATURE_VALUE, HUMIDITY_VALUE     | No         |
| Meter Pro / CO2      | Passive | TEMPERATURE_VALUE, HUMIDITY_VALUE     | No         |
| Indoor/Outdoor Meter | Passive | TEMPERATURE_VALUE, HUMIDITY_VALUE     | No         |
| Motion Sensor        | Passive | CONTACT_SENSOR + Events               | No         |
| Presence Sensor      | Passive | CONTACT_SENSOR + Events               | No         |
| Contact Sensor       | Passive | CONTACT_SENSOR + BUTTON_LINK + Events | No         |
| Water Leak Detector  | Passive | CONTACT_SENSOR + Events               | No         |
| Remote               | Passive | (advertisement parsing only)          | No         |

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Installer Setup</span>

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

> If you already have the
> [DriverCentral Cloud driver](https://drivercentral.io/platforms/control4-drivers/utility/drivercentral-cloud-driver/)
> installed in your project you can continue to
> [Adding the Driver](#adding-the-driver).

This driver relies on the DriverCentral Cloud driver to manage licensing and
automatic updates. If you are new to using DriverCentral you can refer to their
[Cloud Driver](https://help.drivercentral.io/407519-Cloud-Driver) documentation
for setting it up.

<!-- #endif -->

## Adding the Driver

<!-- #ifdef DRIVERCENTRAL -->

1. Download the latest `control4-esphome.zip` from
   [DriverCentral](https://drivercentral.io/platforms/control4-drivers/utility/esphome).
2. Extract and install the `esphome_switchbot.c4z` driver.
3. Use the "Search" tab to find "ESPHome SwitchBot" and add it to your project.

<!-- #else -->

1. Download the latest `control4-esphome.zip` from
   [Github](https://github.com/finitelabs/control4-esphome/releases/latest).
2. Extract and install the `esphome_switchbot.c4z` driver.
3. Use the "Search" tab to find "ESPHome SwitchBot" and add it to your project.

<!-- #endif -->

## Binding to ESPHome Proxy

1. Ensure the main ESPHome driver is connected and Bluetooth Proxy shows
   available connection slots (for active devices).
2. In the main ESPHome driver properties, select "Refresh List" from the "Select
   Bluetooth Devices" dropdown.
3. Select your SwitchBot device from the list. A connection binding will be
   automatically created.
4. Go to the "Connections" tab and bind the ESPHome SwitchBot driver to the
   newly created SwitchBot connection.

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates [ Off | **_On_** ]

Enables or disables automatic driver updates via DriverCentral.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level [ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra ]

Sets the logging level. Default is `3 - Info`.

#### Log Mode [ **_Off_** | Print | Log | Print and Log ]

Sets the logging mode. Default is `Off`.

### Encryption Settings

> These properties are only shown for Relay Switch devices that require
> encryption.

#### Encryption Status (read-only)

Displays the current encryption status.

#### SwitchBot Username

Your SwitchBot account email address. Used to automatically fetch encryption
keys from SwitchBot cloud.

#### SwitchBot Password

Your SwitchBot account password.

#### Key ID (read-only)

The encryption key ID retrieved from SwitchBot cloud.

#### Encryption Key (read-only)

The encryption key retrieved from SwitchBot cloud.

### Device Info

#### Name (read-only)

Displays the name of the bound SwitchBot device.

#### Device Type (read-only)

Displays the detected SwitchBot device type.

#### MAC Address (read-only)

Displays the MAC address of the bound SwitchBot device.

#### Last Seen (read-only)

Displays the timestamp of the last communication with the device.

#### RSSI (read-only)

Displays the signal strength of the Bluetooth connection.

#### Last Received (read-only)

Displays a summary of the most recently received device data.

### Device Data

Properties shown here depend on the detected device type. Only properties
relevant to the connected device will be shown.

#### Bot

| Property | Description                   |
| -------- | ----------------------------- |
| State    | Current state (On/Off)        |
| Battery  | Battery level (%)             |
| Mode     | Operating mode (Press/Switch) |

#### Plug Mini / Relay Switches

| Property        | Description                          |
| --------------- | ------------------------------------ |
| Channel 1 State | Channel 1 relay state (On/Off)       |
| Channel 1 Power | Channel 1 power consumption (W)      |
| Channel 2 State | Channel 2 relay state (On/Off, 2PM)  |
| Channel 2 Power | Channel 2 power consumption (W, 2PM) |

#### Meters

| Property      | Unit | Description                      |
| ------------- | ---- | -------------------------------- |
| Temperature C | °C   | Current temperature (Celsius)    |
| Temperature F | °F   | Current temperature (Fahrenheit) |
| Humidity      | %    | Relative humidity                |
| CO2           | ppm  | Carbon dioxide level (Pro CO2)   |
| Battery       | %    | Battery level                    |

#### Motion / Presence Sensors

| Property    | Description                   |
| ----------- | ----------------------------- |
| Motion      | Motion state (Detected/Clear) |
| Light Level | Ambient light level           |
| Battery     | Battery level (%)             |

#### Contact Sensor

| Property | Description                 |
| -------- | --------------------------- |
| Contact  | Contact state (Open/Closed) |
| Battery  | Battery level (%)           |

#### Water Leak Detector

| Property      | Description        |
| ------------- | ------------------ |
| Leak Detected | Leak state         |
| Tamper        | Tamper state       |
| Battery       | Battery level (%)  |
| Battery Low   | Low battery status |

## Driver Actions

### Reset Driver

Resets the driver state to defaults.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Device Types</span>

## Bot

The SwitchBot Bot is a physical button pusher that operates in two modes:

### Press Mode

- Arm extends and immediately returns
- Ideal for doorbells, elevator buttons, momentary switches
- Single "Press" BUTTON_LINK binding created

### Switch Mode

- Arm moves to and stays in on/off position
- Ideal for light switches, toggle switches
- "Turn On", "Turn Off", "Toggle" BUTTON_LINK bindings created
- State tracking (On/Off)

> **Note:** Mode can only be changed in the SwitchBot app. The driver
> automatically detects the current mode.

**Properties shown:** State, Battery, Mode

## Plug Mini

Smart plug with power monitoring. Does not require encryption.

**Properties shown:** Channel 1 State, Channel 1 Power

**Bindings:** RELAY

## Relay Switches

The Relay Switch family provides in-wall relay control. All Relay Switches
require encryption keys from SwitchBot cloud.

| Model            | Channels | Power Monitoring |
| ---------------- | -------- | ---------------- |
| Relay Switch 1   | 1        | No               |
| Relay Switch 1PM | 1        | Yes              |
| Relay Switch 2PM | 2        | Yes              |

**Properties shown:** Channel 1/2 State, Channel 1/2 Power (1PM/2PM only)

**Bindings:** RELAY (Channel 2 creates dynamic binding for 2PM)

### Encryption Setup

1. Enter your SwitchBot account email in "SwitchBot Username"
2. Enter your SwitchBot account password in "SwitchBot Password"
3. Keys are automatically fetched when both credentials are provided
4. Check "Encryption Status" to confirm keys were retrieved

## Meters

Passive temperature and humidity sensors. The driver automatically creates
TEMPERATURE_VALUE and HUMIDITY_VALUE bindings.

| Model                | Features                             |
| -------------------- | ------------------------------------ |
| Meter                | Temperature, Humidity                |
| Meter Plus           | Temperature, Humidity                |
| Meter Pro            | Temperature, Humidity                |
| Meter Pro CO2        | Temperature, Humidity, CO2           |
| Indoor/Outdoor Meter | Temperature, Humidity (dual sensors) |

**Properties shown:** Temperature C, Temperature F, Humidity, CO2, Battery

## Motion and Presence Sensors

Passive motion detection sensors with light level sensing.

**Properties shown:** Motion, Light Level, Battery

**Bindings:** CONTACT_SENSOR (motion = closed)

**Events:**

- Motion Detected - Motion was detected
- Motion Cleared - Motion cleared

## Contact Sensor

Door/window contact sensor with physical button.

**Properties shown:** Contact, Battery

**Bindings:** CONTACT_SENSOR, BUTTON_LINK (for physical button)

**Events:**

- Contact Opened - Contact was opened
- Contact Closed - Contact was closed
- Button Pressed - Physical button was pressed

## Water Leak Detector

Water leak detection sensor with tamper detection.

**Properties shown:** Leak Detected, Tamper, Battery, Battery Low

**Bindings:** CONTACT_SENSOR (leak = closed)

**Events:**

- Leak Detected - Water leak detected
- Leak Cleared - Water leak cleared
- Tamper Detected - Tamper detected
- Tamper Cleared - Tamper cleared
- Low Battery - Battery is low
- Battery OK - Battery restored to normal

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Programming</span>

## Events

Events are created dynamically based on device type:

| Device Type     | Events                                                                                |
| --------------- | ------------------------------------------------------------------------------------- |
| Motion/Presence | Motion Detected, Motion Cleared                                                       |
| Contact         | Contact Opened, Contact Closed, Button Pressed                                        |
| Water Leak      | Leak Detected, Leak Cleared, Tamper Detected, Tamper Cleared, Low Battery, Battery OK |

## Variables

The following variables are available for programming (varies by device type):

### Common Variables

| Variable    | Type   | Devices      | Description          |
| ----------- | ------ | ------------ | -------------------- |
| Battery     | NUMBER | Most devices | Battery level (%)    |
| Battery Low | STRING | Water Leak   | Low battery status   |
| Device Type | STRING | All          | Detected device type |
| MAC Address | STRING | All          | Device MAC address   |
| Name        | STRING | All          | Device name          |

### Bot Variables

| Variable | Type   | Description                   |
| -------- | ------ | ----------------------------- |
| State    | STRING | Current state (On/Off)        |
| Mode     | STRING | Operating mode (Press/Switch) |

### Switch/Relay Variables

| Variable        | Type   | Devices          | Description            |
| --------------- | ------ | ---------------- | ---------------------- |
| Channel 1 State | STRING | All switches     | Relay 1 state (On/Off) |
| Channel 1 Power | NUMBER | Plug, 1PM, 2PM   | Channel 1 power (W)    |
| Channel 2 State | STRING | Relay Switch 2PM | Relay 2 state (On/Off) |
| Channel 2 Power | NUMBER | Relay Switch 2PM | Channel 2 power (W)    |

### Meter Variables

| Variable      | Type   | Devices       | Description               |
| ------------- | ------ | ------------- | ------------------------- |
| Temperature C | NUMBER | All meters    | Temperature in Celsius    |
| Temperature F | NUMBER | All meters    | Temperature in Fahrenheit |
| Humidity      | NUMBER | All meters    | Relative humidity (%)     |
| CO2           | NUMBER | Meter Pro CO2 | CO2 level (ppm)           |

### Sensor Variables

| Variable      | Type   | Devices         | Description                   |
| ------------- | ------ | --------------- | ----------------------------- |
| Motion        | STRING | Motion/Presence | Motion state (Detected/Clear) |
| Light Level   | STRING | Motion/Presence | Ambient light level           |
| Contact       | STRING | Contact Sensor  | Contact state (Open/Closed)   |
| Leak Detected | STRING | Water Leak      | Leak state (Yes/No)           |
| Tamper        | STRING | Water Leak      | Tamper state                  |

## Connections

### ESPHome SwitchBot (consumer)

Bind this connection to the SwitchBot device binding exposed by the main ESPHome
driver after selecting the SwitchBot device from the "Select Bluetooth Devices"
dropdown.

### Dynamic Bindings (provider)

The driver dynamically creates bindings based on the detected device type:

| Binding Class     | Devices                         | Description              |
| ----------------- | ------------------------------- | ------------------------ |
| RELAY             | Bot, Plug Mini, Relay Switches  | Relay on/off control     |
| BUTTON_LINK       | Bot (mode-dependent), Contact   | Button press events      |
| CONTACT_SENSOR    | Motion, Presence, Contact, Leak | Open/closed sensor state |
| TEMPERATURE_VALUE | Meters                          | Temperature in Celsius   |
| HUMIDITY_VALUE    | Meters                          | Humidity percentage      |

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Troubleshooting</span>

## Device Not Responding

If the device doesn't respond to commands:

1. Check that the Bluetooth Proxy has available connection slots (active
   devices)
2. Verify the device is within BLE range of the ESP32
3. Check the battery level - low battery can cause connection issues
4. For Relay Switches, ensure encryption keys are configured

## Encryption Key Errors

If you see encryption errors for Relay Switches:

1. Verify your SwitchBot account credentials are correct
2. Clear and re-enter the username and password to trigger key fetch
3. Ensure the device is registered to your SwitchBot account
4. Check that the MAC address is correctly detected
5. Check "Encryption Status" property for detailed error messages

## Sensor Not Updating

If passive sensors aren't showing data:

1. Passive devices rely on BLE advertisements
2. Ensure the device is within range of the ESP32
3. Check that the device has battery remaining
4. Some devices only advertise periodically (every few seconds)

## Wrong Device Type Detected

If the driver detects the wrong device type:

1. Use "Reset Driver" action to clear state
2. Unbind and rebind the device connection
3. Ensure you're binding to the correct device

<div style="page-break-after: always"></div>

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#17BCF2">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC. For the latest information, please visit
https://drivercentral.io/platforms/control4-drivers/utility/esphome

<!-- #endif -->

# <span style="color:#17BCF2">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4 or
SwitchBot devices, you can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-esphome/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
