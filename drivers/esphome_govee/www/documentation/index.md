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

<img alt="ESPHome Govee" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4, ESPHome, or Govee.

<!-- #endif -->

Integrate Govee BLE devices into Control4 through an ESPHome Bluetooth Proxy.
This driver receives data from Govee temperature/humidity sensors and meat
thermometers via BLE advertisements, exposing sensor values and alarm events to
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

- Real-time temperature and humidity monitoring
- Support for multi-probe meat thermometers
- Alarm event notifications for threshold monitoring
- Battery level monitoring
- Variable programming support for all sensor values

# <span style="color:#17BCF2">Compatibility</span>

## Supported Devices

### Temperature/Humidity Sensors

| Model | Features                                     |
| ----- | -------------------------------------------- |
| H5051 | Temperature, Humidity, Battery               |
| H5052 | Temperature, Humidity, Battery               |
| H5071 | Temperature, Humidity, Battery               |
| H5072 | Temperature, Humidity, Battery               |
| H5074 | Temperature, Humidity, Battery               |
| H5075 | Temperature, Humidity, Battery               |
| H5100 | Temperature, Humidity, Battery               |
| H5101 | Temperature, Humidity, Battery               |
| H5102 | Temperature, Humidity, Battery               |
| H5103 | Temperature, Humidity, Battery               |
| H5104 | Temperature, Humidity, Battery               |
| H5105 | Temperature, Humidity, Battery               |
| H5106 | Temperature, Humidity, Battery, PM2.5        |
| H5108 | Temperature, Humidity, Battery               |
| H5110 | Temperature, Humidity, Battery               |
| H5112 | Temperature, Humidity, Battery (Dual Probe)  |
| H5174 | Temperature, Humidity, Battery               |
| H5177 | Temperature, Humidity, Battery               |
| H5178 | Temperature, Humidity, Battery (Dual Sensor) |
| H5179 | Temperature, Humidity, Battery               |

### Meat Thermometers

| Model | Probes | Alarm Events | Error Events |
| ----- | ------ | ------------ | ------------ |
| H5055 | Multi  | ❌           | ❌           |
| H5181 | 1      | Probe 1      | ✅           |
| H5182 | 2      | Probe 1, 2   | ✅           |
| H5183 | Multi  | ❌           | ❌           |
| H5184 | 4      | Probe 1, 2   | ✅           |
| H5185 | 1      | Probe 1      | ✅           |
| H5191 | 1      | Probe 1      | ✅           |
| H5198 | 2      | Probe 1, 2   | ✅           |

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
2. Extract and install the `esphome_govee.c4z` driver.
3. Use the "Search" tab to find "ESPHome Govee" and add it to your project.

<!-- #else -->

1. Download the latest `control4-esphome.zip` from
   [Github](https://github.com/finitelabs/control4-esphome/releases/latest).
2. Extract and install the `esphome_govee.c4z` driver.
3. Use the "Search" tab to find "ESPHome Govee" and add it to your project.

<!-- #endif -->

## Binding to ESPHome Proxy

1. Ensure the main ESPHome driver is connected and Bluetooth Proxy is ready.
2. In the main ESPHome driver properties, select "Refresh List" from the "Select
   Bluetooth Devices" dropdown.
3. Select your Govee device from the list. A connection binding will be
   automatically created.
4. Go to the "Connections" tab and bind the ESPHome Govee driver to the newly
   created Govee connection.

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

### Device Info

#### Name (read-only)

Displays the name of the bound Govee device.

#### Device Type (read-only)

Displays the detected Govee device type.

#### MAC Address (read-only)

Displays the MAC address of the bound Govee device.

#### Last Seen (read-only)

Displays the timestamp of the last received advertisement.

#### RSSI (read-only)

Displays the signal strength of the last received advertisement.

#### Last Received (read-only)

Displays a summary of the most recently received sensor data.

### Device Data

Properties shown depend on the connected device type:

#### Temperature/Humidity Sensors

| Property      | Unit  | Description                      |
| ------------- | ----- | -------------------------------- |
| Battery       | %     | Battery level                    |
| Temperature C | °C    | Current temperature (Celsius)    |
| Temperature F | °F    | Current temperature (Fahrenheit) |
| Humidity      | %     | Relative humidity                |
| PM2.5         | µg/m³ | Particulate matter (H5106 only)  |

#### Dual Probe/Sensor Models (H5178, H5112)

| Property      | Unit | Description                                 |
| ------------- | ---- | ------------------------------------------- |
| Sensor ID     | -    | Identifies which sensor (primary/secondary) |
| Temperature C | °C   | Sensor temperature (Celsius)                |
| Temperature F | °F   | Sensor temperature (Fahrenheit)             |
| Humidity      | %    | Relative humidity                           |
| Error         | -    | Sensor error status                         |

#### Meat Thermometers

| Property      | Unit | Description                          |
| ------------- | ---- | ------------------------------------ |
| Probe 1 C     | °C   | Probe 1 temperature (Celsius)        |
| Probe 1 F     | °F   | Probe 1 temperature (Fahrenheit)     |
| Probe 1 Alarm | °C   | Probe 1 target temperature threshold |
| Probe 2 C     | °C   | Probe 2 temperature (Celsius)        |
| Probe 2 F     | °F   | Probe 2 temperature (Fahrenheit)     |
| Probe 2 Alarm | °C   | Probe 2 target temperature threshold |
| Probe 3 C     | °C   | Probe 3 temperature (Celsius)        |
| Probe 3 F     | °F   | Probe 3 temperature (Fahrenheit)     |
| Probe 4 C     | °C   | Probe 4 temperature (Celsius)        |
| Probe 4 F     | °F   | Probe 4 temperature (Fahrenheit)     |
| Ambient C     | °C   | Ambient temperature (Celsius)        |
| Ambient F     | °F   | Ambient temperature (Fahrenheit)     |

> **Note:** Alarm events (`probe1_alarm_active`, etc.) fire when the probe
> temperature reaches or exceeds the alarm threshold temperature.

## Driver Actions

### Reset Driver

Resets the driver state and clears cached sensor values.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Programming</span>

## Events

The following events are available for meat thermometer models:

| Event                 | Description                        |
| --------------------- | ---------------------------------- |
| Probe 1 Alarm Active  | Probe 1 reached target temperature |
| Probe 1 Alarm Cleared | Probe 1 below target temperature   |
| Probe 2 Alarm Active  | Probe 2 reached target temperature |
| Probe 2 Alarm Cleared | Probe 2 below target temperature   |

> **Note:** Only Probe 1 and Probe 2 support alarm events. Probes 3 and 4
> provide temperature readings only.

The following events are available for sensors with error reporting:

| Event          | Description           |
| -------------- | --------------------- |
| Error Detected | Sensor error detected |
| Error Cleared  | Sensor error cleared  |

**Models with error event support:**

- Temperature/Humidity: H5074, H5075, H5100, H5101, H5102, H5104, H5108, H5112,
  H5177, H5178, H5179
- Meat Thermometers: H5181, H5182, H5184, H5185, H5191, H5198

> **Note:** Models H5051, H5052, H5071, H5072, H5103, H5105, H5106, H5110,
> H5174, H5055, and H5183 do not support error events.

## Variables

All sensor values are exposed as variables for programming:

### Common Variables

| Variable    | Type   | Description                     |
| ----------- | ------ | ------------------------------- |
| Device Type | STRING | Detected device model           |
| Last Seen   | STRING | Timestamp of last advertisement |
| MAC Address | STRING | Device MAC address              |
| Name        | STRING | Device name                     |
| RSSI        | NUMBER | Signal strength (dBm)           |

### Temperature/Humidity Sensor Variables

| Variable      | Type   | Description                      |
| ------------- | ------ | -------------------------------- |
| Battery       | NUMBER | Battery percentage (0-100)       |
| Temperature C | NUMBER | Temperature in Celsius           |
| Temperature F | NUMBER | Temperature in Fahrenheit        |
| Humidity      | NUMBER | Relative humidity percentage     |
| PM2.5         | NUMBER | Particulate matter µg/m³ (H5106) |
| Sensor ID     | STRING | Sensor identifier (H5178, H5112) |
| Error         | STRING | Error status ("Yes" or "No")     |

### Meat Thermometer Variables

| Variable      | Type   | Description                      |
| ------------- | ------ | -------------------------------- |
| Probe 1 C     | NUMBER | Probe 1 temperature (Celsius)    |
| Probe 1 F     | NUMBER | Probe 1 temperature (Fahrenheit) |
| Probe 1 Alarm | NUMBER | Probe 1 target threshold (°C)    |
| Probe 2 C     | NUMBER | Probe 2 temperature (Celsius)    |
| Probe 2 F     | NUMBER | Probe 2 temperature (Fahrenheit) |
| Probe 2 Alarm | NUMBER | Probe 2 target threshold (°C)    |
| Probe 3 C     | NUMBER | Probe 3 temperature (Celsius)    |
| Probe 3 F     | NUMBER | Probe 3 temperature (Fahrenheit) |
| Probe 4 C     | NUMBER | Probe 4 temperature (Celsius)    |
| Probe 4 F     | NUMBER | Probe 4 temperature (Fahrenheit) |
| Ambient C     | NUMBER | Ambient temperature (Celsius)    |
| Ambient F     | NUMBER | Ambient temperature (Fahrenheit) |

> **Note:** Variables are only created when the corresponding sensor data is
> received. Not all variables will be present for all device types.

## Connections

### ESPHome Govee (consumer)

Bind this connection to the Govee device binding exposed by the main ESPHome
driver after selecting the Govee device from the "Select Bluetooth Devices"
dropdown.

### Dynamic Sensor Bindings (provider)

The driver dynamically creates sensor bindings when temperature/humidity data is
received:

| Binding     | Class             | Description            |
| ----------- | ----------------- | ---------------------- |
| Temperature | TEMPERATURE_VALUE | Temperature in Celsius |
| Humidity    | HUMIDITY_VALUE    | Humidity percentage    |

These bindings can be connected to other Control4 devices that consume
temperature or humidity values (e.g., climate displays, thermostats).

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
Govee devices, you can contact us at
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
