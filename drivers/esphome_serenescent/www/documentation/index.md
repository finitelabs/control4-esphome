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

Integrate a Homedics SereneScent BLE diffuser into Control4 through an ESPHome
Bluetooth Proxy. This driver connects to the SereneScent via BLE to control
power, diffuser intensity, and LED color.

<!-- #ifndef DRIVERCENTRAL -->

> This driver's BLE protocol implementation is based on the
> [reverse engineering work](https://github.com/john-k-mcdowell/Homedics-SereneScent/blob/development/docs/PROTOCOL.md)
> by [john-k-mcdowell](https://github.com/john-k-mcdowell/Homedics-SereneScent).

<!-- #endif -->

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
  - [Detecting Device Capabilities](#detecting-device-capabilities)
  - [Button Links & Relay](#button-links--relay)
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
- Diffuser intensity control (low, medium, high) — if supported by device
- LED color control (off, rotating, white, red, blue, violet, green, orange) —
  if supported by device
- Automatic capability detection with dynamic control bindings
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

## Detecting Device Capabilities

After binding the driver to the ESPHome proxy, you must run the **Detect
Capabilities** action to discover what features the device supports.

1. Go to the driver's **Actions** tab in Composer.
2. Run the **Detect Capabilities** action.
3. The driver connects to the device via BLE, queries its status, and determines
   which capabilities are supported (power, intensity, color).
4. The **Detected Capabilities** property displays the result (e.g., "Power,
   Intensity, Color").
5. Control bindings (button links and relay) are automatically created for the
   detected capabilities.

> **Note:** If the device is powered off during detection, the driver will
> briefly turn it on to read its capabilities, then restore the power-off state.

> **Tip:** Re-run the **Detect Capabilities** action anytime, for example after
> replacing the device with a different model.

## Button Links & Relay

The driver exposes control bindings that can be connected to keypad buttons and
relay devices in Control4. These bindings are created dynamically based on the
detected capabilities of the device.

> **Important:** Power bindings (On, Off, Toggle, and Power Relay) are always
> available. Intensity bindings only appear if the device supports intensity
> control. Run the **Detect Capabilities** action to discover and create the
> appropriate bindings.

### Button Links

**Always available:**

| Binding            | Action                  |
| ------------------ | ----------------------- |
| On Button Link     | Powers on the diffuser  |
| Off Button Link    | Powers off the diffuser |
| Toggle Button Link | Toggles diffuser power  |

**Capability-dependent (created after Detect Capabilities):**

| Binding                          | Requires  | Action                                      |
| -------------------------------- | :-------: | ------------------------------------------- |
| Intensity Up Button Link         | Intensity | Cycles intensity up (low → medium → high)   |
| Intensity Down Button Link       | Intensity | Cycles intensity down (high → medium → low) |
| Set Low Intensity Button Link    | Intensity | Sets intensity to `low`                     |
| Set Medium Intensity Button Link | Intensity | Sets intensity to `medium`                  |
| Set High Intensity Button Link   | Intensity | Sets intensity to `high`                    |

Connect a keypad button or button link source to any of these bindings in the
Connections tab. The corresponding action fires when the button is pressed.

### Power Relay

The `Power Relay` binding (class `RELAY`) reflects and controls the diffuser's
power state bidirectionally:

- Sending `CLOSE` (or binding a relay that closes) turns the diffuser on.
- Sending `OPEN` (or binding a relay that opens) turns the diffuser off.
- When the diffuser state changes via any control method, the relay binding
  automatically reflects the updated state to the connected device.

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

#### Detected Capabilities (read-only)

Displays the capabilities detected after running the **Detect Capabilities**
action. Shows "Not detected" until the action has been run. Example values:
`Power`, `Power, Intensity`, `Power, Intensity, Color`.

### Device State

#### Power (read-only)

Displays the current power state of the diffuser: `On` or `Off`. Shows `N/A`
before the device has been connected for the first time.

#### Intensity (read-only)

Displays the current diffuser intensity: `low`, `medium`, or `high`. Shows
`Undetected` before **Detect Capabilities** has been run, `N/A` if the device
does not support intensity control, and `Off` when the diffuser is powered off.

#### Color (read-only)

Displays the current LED color: `off`, `rotating`, `white`, `red`, `blue`,
`violet`, `green`, or `orange`. Shows `Undetected` before **Detect
Capabilities** has been run, `N/A` if the device does not support LED color
control, and `Off` when the diffuser is powered off.

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

> **Note:** Requires intensity capability to be detected. Run **Detect
> Capabilities** first. If the device does not support intensity control, this
> action has no effect.

**Parameters:**

- **Level** [ low | medium | high ] - The desired intensity level.

### Set Color

Sets the LED light color.

> **Note:** Requires color capability to be detected. Run **Detect
> Capabilities** first. If the device does not support LED color control, this
> action has no effect.

**Parameters:**

- **Color** [ off | rotating | white | red | blue | violet | green | orange ] -
  The desired LED color.

### Detect Capabilities

Connects to the device, queries its status, and determines which capabilities
are supported (power, intensity, color). Creates or removes control bindings
(button links and relay) based on the result. If the device is off, it will be
briefly powered on to read capabilities.

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

| Variable    | Type   | Description                                                                                      |
| ----------- | ------ | ------------------------------------------------------------------------------------------------ |
| Power       | STRING | Current power state: `On` or `Off`. `N/A` before first connection.                               |
| Intensity   | STRING | Current intensity: `low`, `medium`, `high`. `Undetected` before detection; `N/A` if unsupported; `Off` when powered off. |
| Color       | STRING | Current LED color name. `Undetected` before detection; `N/A` if unsupported; `Off` when powered off.                    |
| Device Name | STRING | Bluetooth device name                                                                            |
| MAC Address | STRING | Device Bluetooth MAC address                                                                     |
| RSSI        | NUMBER | Signal strength in dBm                                                                           |
| Last Seen   | STRING | Timestamp of last BLE advertisement                                                              |

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
