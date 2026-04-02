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

<img alt="ESPHome SereneScent" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4, ESPHome, or Homedics.

<!-- #endif -->

Integrate the Homedics SereneScent BLE diffuser into Control4 through an ESPHome
Bluetooth Proxy. This driver connects to the SereneScent via BLE GATT to control
power, diffuser intensity, and LED color.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
  - [Supported Devices](#supported-devices)
  - [Tested Devices](#tested-devices)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Adding the Driver](#adding-the-driver)
  - [Binding to ESPHome Proxy](#binding-to-esphome-proxy)
  - [Driver Properties](#driver-properties)
  - [Driver Actions](#driver-actions)
- [Programming](#programming)
  - [Commands](#commands)
  - [Variables](#variables)
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
- ESP32 device with `bluetooth_proxy` component (active connections mode)

# <span style="color:#17BCF2">Features</span>

- Power on/off and toggle control
- Diffuser intensity control (low, medium, high)
- LED color control (off, rotating, white, red, blue, violet, green, orange)
- Real-time device state feedback via GATT notifications
- Periodic status polling at a configurable interval
- Signal strength and last-seen monitoring

# <span style="color:#17BCF2">Compatibility</span>

## Supported Devices

| Device               | Control | Feedback |
| -------------------- | :-----: | :------: |
| Homedics SereneScent |   ✅    |    ✅    |

> **Note:** The SereneScent uses an active BLE GATT connection. Each command
> connects to the device, sends the command, and disconnects automatically. This
> consumes one active connection slot on the ESP32 Bluetooth proxy.

> **Important:** The Homedics SereneScent mobile app must be closed before using
> this driver. The app maintains an exclusive BLE connection to the device,
> which prevents the ESP32 proxy from connecting.

## Tested Devices

| Model    | Notes        |
| -------- | ------------ |
| ARMH-972 | Fully tested |

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
2. Extract and install the `esphome_serenescent.c4z` driver.
3. Use the "Search" tab to find "ESPHome SereneScent" and add it to your
   project.

<!-- #else -->

1. Download the latest `control4-esphome.zip` from
   [Github](https://github.com/finitelabs/control4-esphome/releases/latest).
2. Extract and install the `esphome_serenescent.c4z` driver.
3. Use the "Search" tab to find "ESPHome SereneScent" and add it to your
   project.

<!-- #endif -->

## Binding to ESPHome Proxy

1. Ensure the main ESPHome driver is connected and Bluetooth Proxy is ready.
2. In the main ESPHome driver properties, select "Refresh List" from the "Select
   Bluetooth Devices" dropdown.
3. Select your SereneScent device (displayed as
   `ARMH-XXXX - Homedics SereneScent [Active Connection]`) from the list. A
   connection binding will be automatically created.
4. Go to the "Connections" tab and bind the ESPHome SereneScent driver to the
   newly created SereneScent connection.

## Driver Properties

### Driver Settings

#### Driver Status (read-only)

Displays the current connection status of the driver. Possible values include
`Disconnected`, `Listening`, `Connected`, and error messages.

#### Driver Version (read-only)

Displays the installed driver version.

#### Log Level [ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra ]

Sets the logging level. Default is `3 - Info`.

#### Log Mode [ **_Off_** | Print | Log | Print and Log ]

Sets the logging mode. Default is `Off`. Active log modes expire automatically
after 3 hours.

#### Polling Interval [ 1 - 10, default: **_5_** ]

Sets how often (in minutes) the driver connects to query the device status.
Default is `5` minutes.

### Device State

#### Power (read-only)

Displays the current power state of the diffuser: `On` or `Off`.

#### Intensity (read-only)

Displays the current diffuser intensity: `low`, `medium`, or `high`.

#### Color (read-only)

Displays the current LED color: `off`, `rotating`, `white`, `red`, `blue`,
`violet`, `green`, or `orange`.

### Device Info

#### Device Name (read-only)

Displays the Bluetooth device name of the bound SereneScent device.

#### MAC Address (read-only)

Displays the Bluetooth MAC address of the bound SereneScent device.

#### RSSI (read-only)

Displays the signal strength of the last received BLE advertisement in dBm.

#### Last Seen (read-only)

Displays the timestamp of the last received BLE advertisement.

## Driver Actions

### Power On

Turns on the SereneScent diffuser.

### Power Off

Turns off the SereneScent diffuser.

### Toggle Power

Toggles the diffuser on or off based on its current state.

### Set Intensity

Sets the diffuser mist intensity.

**Parameters:**

- **Level** [ low | medium | high ] - The desired intensity level.

### Set Color

Sets the LED light color.

**Parameters:**

- **Color** [ off | rotating | white | red | blue | violet | green | orange ] -
  The desired LED color.

### Request Status

Requests an immediate status update from the diffuser. Connects via GATT,
queries the device state, then disconnects.

### Reset Driver

Resets the driver state and clears all cached values.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Programming</span>

## Commands

| Command              | Parameter | Values                                                                 | Description                         |
| -------------------- | --------- | ---------------------------------------------------------------------- | ----------------------------------- |
| Power On             |           |                                                                        | Turns on the diffuser               |
| Power Off            |           |                                                                        | Turns off the diffuser              |
| Toggle Power         |           |                                                                        | Toggles the diffuser on or off      |
| Set Intensity        | Level     | `low`, `medium`, `high`                                                | Sets the diffuser mist intensity    |
| Set Color            | Color     | `off`, `rotating`, `white`, `red`, `blue`, `violet`, `green`, `orange` | Sets the LED light color            |
| Request Status       |           |                                                                        | Requests an immediate status update |
| Set Polling Interval | Interval  | 1 - 10                                                                 | Sets the poll interval (minutes)    |

## Variables

| Variable    | Type   | Description                                |
| ----------- | ------ | ------------------------------------------ |
| Power       | STRING | Current power state: `On` or `Off`         |
| Intensity   | STRING | Current intensity: `low`, `medium`, `high` |
| Color       | STRING | Current LED color name                     |
| Device Name | STRING | Bluetooth device name                      |
| MAC Address | STRING | Device Bluetooth MAC address               |
| RSSI        | NUMBER | Signal strength in dBm                     |
| Last Seen   | STRING | Timestamp of last BLE advertisement        |

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
Homedics SereneScent devices, you can contact us at
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
