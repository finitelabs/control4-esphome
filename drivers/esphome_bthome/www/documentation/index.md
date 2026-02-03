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

<img alt="ESPHome BTHome" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4, ESPHome, or BTHome.

<!-- #endif -->

Integrate BTHome-compatible BLE devices into Control4 through an ESPHome
Bluetooth Proxy. BTHome is an open standard for BLE sensor data, supported by
many manufacturers and DIY devices. This driver receives data from BTHome
devices via the ESPHome Bluetooth Proxy and exposes sensor values and events to
Control4.

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
    - [Device Settings](#device-settings)
    - [Device Info](#device-info)
    - [Device Data](#device-data)
  - [Driver Actions](#driver-actions)
- [Programming](#programming)
  - [Events](#events)
  - [Variables](#variables)
  - [Connections](#connections)
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

- Dynamic property creation based on received sensor data
- Real-time updates from BTHome advertisements
- Support for BTHome v2 sensor types
- Variable programming support for all sensor values
- Event-based programming for binary sensors

> **Important:** BTHome devices do not have a discovery mechanism for their
> supported entities. The driver learns what a device supports only when it
> receives a broadcast advertisement containing that data. This means
> properties, variables, events, and connections are created dynamically as data
> is observed — they will **not** appear until the device has broadcast at least
> once with that data. For example, a button's press events won't show up in
> programming until the button has been pressed at least once. Most sensors
> broadcast periodically on their own, but event-based devices like buttons only
> broadcast when activated.

# <span style="color:#17BCF2">Compatibility</span>

## Supported Devices

This driver supports any device compatible with the BTHome protocol. See
[https://bthome.io](https://bthome.io) for the full compatibility list.

Common BTHome devices include:

| Manufacturer | Device Types                                         |
| ------------ | ---------------------------------------------------- |
| Shelly       | BLU Button, BLU Door/Window, BLU Motion, BLU H&T     |
| Xiaomi       | Sensors with BTHome firmware (custom flash required) |
| b-parasite   | Open-source soil moisture sensor                     |
| DIY          | ESP32-based sensors with BTHome firmware             |

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
2. Extract and install the `esphome_bthome.c4z` driver.
3. Use the "Search" tab to find "ESPHome BTHome" and add it to your project.

<!-- #else -->

1. Download the latest `control4-esphome.zip` from
   [Github](https://github.com/finitelabs/control4-esphome/releases/latest).
2. Extract and install the `esphome_bthome.c4z` driver.
3. Use the "Search" tab to find "ESPHome BTHome" and add it to your project.

<!-- #endif -->

## Binding to ESPHome Proxy

1. Ensure the main ESPHome driver is connected and Bluetooth Proxy is ready.
2. In the main ESPHome driver properties, select "Refresh List" from the "Select
   Bluetooth Devices" dropdown.
3. Select your BTHome device from the list. A connection binding will be
   automatically created.
4. Go to the "Connections" tab and bind the ESPHome BTHome driver to the newly
   created BTHome connection.

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

### Device Settings

#### Bind Key

Optional 32-character hex key for encrypted BTHome devices. Enter the bind key
if your device uses BTHome encryption.

### Device Info

#### Name (read-only)

Displays the name of the bound BTHome device.

#### Device Type (read-only)

Displays the detected BTHome device type.

#### Device Type ID (read-only)

Displays the BTHome device type identifier.

#### Firmware Version (read-only)

Displays the device firmware version (if available).

#### MAC Address (read-only)

Displays the MAC address of the bound BTHome device.

#### Last Seen (read-only)

Displays the timestamp of the last received advertisement.

#### Last Received (read-only)

Displays the parsed data from the last received advertisement.

### Device Data

Properties are created dynamically based on the data received from the device.
Only properties relevant to the connected device will be shown.

> **Note:** These properties will only appear after the device has broadcast
> data containing the corresponding sensor values. If you don't see an expected
> property, trigger the device (e.g., press a button, open a door) or wait for
> its next periodic broadcast.

#### Primary Sensors

| Property      | Unit | Description              |
| ------------- | ---- | ------------------------ |
| Battery       | %    | Battery level            |
| Temperature C | °C   | Temperature (Celsius)    |
| Temperature F | °F   | Temperature (Fahrenheit) |
| Humidity      | %    | Relative humidity        |
| Illuminance   | lux  | Light level              |
| Pressure      | hPa  | Barometric pressure      |
| Dew Point     | °C   | Dew point temperature    |
| Moisture      | %    | Soil moisture            |

#### Binary Sensors

| Property                 | Description               |
| ------------------------ | ------------------------- |
| Light Detected           | Light detected            |
| Motion                   | Motion detected           |
| Door                     | Door open/closed          |
| Window                   | Window open/closed        |
| Opening                  | Opening detected          |
| Occupancy                | Occupancy detected        |
| Presence                 | Presence detected         |
| Vibration Detected       | Vibration detected        |
| Smoke Detected           | Smoke detected            |
| Gas Detected             | Gas detected              |
| Carbon Monoxide Detected | CO detected               |
| Moisture Detected        | Water/moisture detected   |
| Tamper                   | Tamper detected           |
| Moving                   | Device is moving          |
| Lock Unlocked            | Lock is unlocked          |
| Garage Door              | Garage door open/closed   |
| Cold                     | Cold temperature detected |
| Heat                     | High temperature detected |
| Running                  | Device is running         |
| Safety                   | Safety issue detected     |
| Problem                  | Problem detected          |
| Sound Detected           | Sound detected            |
| Plug                     | Plug connected            |
| Power On                 | Power is on               |
| Generic Boolean          | Generic boolean value     |
| Battery Low              | Low battery warning       |
| Battery Charging         | Battery is charging       |
| Connectivity             | Connection status         |

#### Power/Energy

| Property | Unit | Description        |
| -------- | ---- | ------------------ |
| Voltage  | V    | Voltage reading    |
| Current  | A    | Current reading    |
| Power    | W    | Power consumption  |
| Energy   | kWh  | Energy consumption |

#### Air Quality

| Property | Unit  | Description                      |
| -------- | ----- | -------------------------------- |
| CO2      | ppm   | Carbon dioxide level             |
| TVOC     | µg/m³ | Total volatile organic compounds |
| PM2.5    | µg/m³ | Particulate matter 2.5           |
| PM10     | µg/m³ | Particulate matter 10            |

#### Distance/Volume

| Property         | Unit | Description      |
| ---------------- | ---- | ---------------- |
| Distance         | m    | Distance reading |
| Volume           | L    | Volume           |
| Volume Storage   | L    | Storage volume   |
| Volume Flow Rate | L/s  | Flow rate        |
| Water            | L    | Water volume     |
| Gas              | m³   | Gas volume       |

#### Motion/Orientation

| Property         | Unit | Description       |
| ---------------- | ---- | ----------------- |
| Acceleration     | m/s² | Acceleration      |
| Gyroscope        | °/s  | Angular velocity  |
| Speed            | m/s  | Speed             |
| Rotational Speed | RPM  | Rotational speed  |
| Direction        | °    | Direction/heading |
| Rotation         | °    | Rotation angle    |

#### Miscellaneous

| Property      | Unit | Description             |
| ------------- | ---- | ----------------------- |
| Count         | -    | Event counter           |
| Duration      | s    | Duration                |
| UV Index      | -    | UV index                |
| Mass          | kg   | Mass/weight             |
| Conductivity  | µS   | Electrical conductivity |
| Timestamp     | -    | Timestamp value         |
| Precipitation | mm   | Precipitation amount    |
| Text          | -    | Text value              |
| RSSI          | dBm  | Signal strength         |

## Driver Actions

### Reset Driver

Resets the driver state and clears cached sensor values.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Programming</span>

## Events

> **Note:** Events are created dynamically and will only appear in Composer Pro
> programming after the device has broadcast the corresponding event at least
> once. For example, you must press a button before its press events become
> available. Once an event has been observed, it remains available for
> programming even if the device has not broadcast recently.

### Button Events

For BTHome button devices (e.g., Shelly BLU Button), the following events are
created dynamically:

| Event             | Description                      |
| ----------------- | -------------------------------- |
| Single Press      | Button pressed once              |
| Double Press      | Button pressed twice             |
| Triple Press      | Button pressed three times       |
| Long Press        | Button held for ~2 seconds       |
| Long Double Press | Button held then pressed twice   |
| Long Triple Press | Button held then pressed 3 times |
| Hold Press        | Button is being held             |

### Dimmer Events

For BTHome dimmer/rotary devices:

| Event        | Description               |
| ------------ | ------------------------- |
| Rotate Left  | Rotated counter-clockwise |
| Rotate Right | Rotated clockwise         |

### Binary Sensors

Binary sensors (motion, door, window, occupancy, etc.) create **CONTACT_SENSOR
bindings** instead of events. These bindings send OPENED/CLOSED states to
Control4, allowing integration with the Contact Sensor proxy.

> **Note:** Events are created dynamically based on the device's capabilities.
> Multi-button devices will have separate events for each button (e.g., "Button
> 1 Single Press", "Button 2 Single Press").

## Variables

All sensor values are exposed as variables for programming. Variables are
created dynamically based on the data received from the device. Variable names
match the property names shown in Composer Pro.

> **Note:** Variables will only appear after the device has broadcast data
> containing the corresponding values. If an expected variable is missing,
> trigger the device or wait for its next periodic broadcast.

### Common Variables

| Variable    | Type   | Description                     |
| ----------- | ------ | ------------------------------- |
| Last Seen   | STRING | Timestamp of last advertisement |
| RSSI        | NUMBER | Signal strength (dBm)           |
| Name        | STRING | Device name                     |
| Device Type | STRING | Detected BTHome device type     |
| MAC Address | STRING | Device MAC address              |

### Primary Sensor Variables

| Variable      | Type   | Description               |
| ------------- | ------ | ------------------------- |
| Battery       | NUMBER | Battery level (%)         |
| Temperature C | NUMBER | Temperature (Celsius)     |
| Temperature F | NUMBER | Temperature (Fahrenheit)  |
| Humidity      | NUMBER | Relative humidity (%)     |
| Illuminance   | NUMBER | Light level (lux)         |
| Pressure      | NUMBER | Barometric pressure (hPa) |
| Dew Point     | NUMBER | Dew point temperature     |
| Moisture      | NUMBER | Soil moisture (%)         |

### Binary Sensor Variables

| Variable                 | Type | Description               |
| ------------------------ | ---- | ------------------------- |
| Light Detected           | BOOL | Light detected            |
| Motion                   | BOOL | Motion detected           |
| Door                     | BOOL | Door open/closed          |
| Window                   | BOOL | Window open/closed        |
| Opening                  | BOOL | Opening detected          |
| Occupancy                | BOOL | Occupancy detected        |
| Presence                 | BOOL | Presence detected         |
| Vibration Detected       | BOOL | Vibration detected        |
| Smoke Detected           | BOOL | Smoke detected            |
| Gas Detected             | BOOL | Gas detected              |
| Carbon Monoxide Detected | BOOL | CO detected               |
| Moisture Detected        | BOOL | Water/moisture detected   |
| Tamper                   | BOOL | Tamper detected           |
| Moving                   | BOOL | Device is moving          |
| Lock Unlocked            | BOOL | Lock is unlocked          |
| Garage Door              | BOOL | Garage door open/closed   |
| Cold                     | BOOL | Cold temperature detected |
| Heat                     | BOOL | High temperature detected |
| Running                  | BOOL | Device is running         |
| Safety                   | BOOL | Safety status             |
| Problem                  | BOOL | Problem detected          |
| Sound Detected           | BOOL | Sound detected            |
| Plug                     | BOOL | Plug connected            |
| Power On                 | BOOL | Power is on               |
| Generic Boolean          | BOOL | Generic boolean value     |
| Battery Low              | BOOL | Low battery warning       |
| Battery Charging         | BOOL | Battery is charging       |
| Connectivity             | BOOL | Connection status         |

### Power/Energy Variables

| Variable | Type   | Description  |
| -------- | ------ | ------------ |
| Voltage  | NUMBER | Voltage (V)  |
| Current  | NUMBER | Current (A)  |
| Power    | NUMBER | Power (W)    |
| Energy   | NUMBER | Energy (kWh) |

### Air Quality Variables

| Variable | Type   | Description                      |
| -------- | ------ | -------------------------------- |
| CO2      | NUMBER | Carbon dioxide (ppm)             |
| TVOC     | NUMBER | Total volatile organic compounds |
| PM2.5    | NUMBER | Particulate matter 2.5 (µg/m³)   |
| PM10     | NUMBER | Particulate matter 10 (µg/m³)    |

### Distance/Volume Variables

| Variable         | Type   | Description    |
| ---------------- | ------ | -------------- |
| Distance         | NUMBER | Distance       |
| Volume           | NUMBER | Volume         |
| Volume Storage   | NUMBER | Storage volume |
| Volume Flow Rate | NUMBER | Flow rate      |
| Water            | NUMBER | Water volume   |
| Gas              | NUMBER | Gas volume     |

### Motion/Orientation Variables

| Variable         | Type   | Description       |
| ---------------- | ------ | ----------------- |
| Acceleration     | NUMBER | Acceleration      |
| Gyroscope        | NUMBER | Angular velocity  |
| Speed            | NUMBER | Speed             |
| Rotational Speed | NUMBER | Rotational speed  |
| Direction        | NUMBER | Direction/heading |
| Rotation         | NUMBER | Rotation angle    |

### Miscellaneous Variables

| Variable         | Type   | Description             |
| ---------------- | ------ | ----------------------- |
| Count            | NUMBER | Event counter           |
| Duration         | NUMBER | Duration                |
| UV Index         | NUMBER | UV index                |
| Mass             | NUMBER | Mass/weight             |
| Conductivity     | NUMBER | Electrical conductivity |
| Timestamp        | NUMBER | Timestamp value         |
| Precipitation    | NUMBER | Precipitation amount    |
| Text             | STRING | Text value              |
| Device Type ID   | NUMBER | BTHome device type ID   |
| Firmware Version | STRING | Device firmware version |

## Connections

### ESPHome BTHome (consumer)

Bind this connection to the BTHome device binding exposed by the main ESPHome
driver after selecting the device from "Select Bluetooth Devices".

### Dynamic Bindings (provider)

The driver creates bindings dynamically based on received sensor data. Bindings
will only appear after the device has broadcast data of the corresponding type.

> **Tip:** If you don't see the expected bindings after adding the driver,
> trigger the device (e.g., press a button, open a door sensor) to generate a
> broadcast. Sensor devices that report periodically (temperature, humidity,
> etc.) will create their bindings automatically after the next broadcast cycle.

| Data Type      | Binding Class     | Description                     |
| -------------- | ----------------- | ------------------------------- |
| Temperature    | TEMPERATURE_VALUE | Temperature readings in Celsius |
| Humidity       | HUMIDITY_VALUE    | Humidity percentage             |
| Binary Sensors | CONTACT_SENSOR    | Motion, door, window, occupancy |
| Button         | BUTTON_LINK       | Button press events             |

Binary sensor bindings (CONTACT_SENSOR) integrate with Control4's Contact Sensor
proxy for programming and automation.

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
BTHome devices, you can contact us at
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
