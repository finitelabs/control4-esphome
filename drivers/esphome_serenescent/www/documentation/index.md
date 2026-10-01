<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

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

______________________________________________________________________

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4, ESPHome, or Homedics.

<!-- #endif -->

This driver integrates a Homedics SereneScent BLE diffuser with Control4 through
an ESPHome Bluetooth proxy. It controls power, mist intensity and the light
color, reports the diffuser's state, and offers keypad button links and a power
relay.

<!-- #ifndef DRIVERCENTRAL -->

> This driver's BLE protocol implementation is based on the
> [reverse engineering work](https://github.com/john-k-mcdowell/Homedics-SereneScent/blob/main/docs/PROTOCOL.md)
> behind the
> [Homedics SereneScent Home Assistant integration](https://github.com/john-k-mcdowell/Homedics-SereneScent)
> by john-k-mcdowell.

<!-- #endif -->

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
  - [Supported Devices](#supported-devices)
  - [Tested Devices](#tested-devices)
- [How It Works](#how-it-works)
  - [Connection Cycle](#connection-cycle)
  - [Home and Schedule Modes](#home-and-schedule-modes)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
    - [Device State](#device-state)
    - [Device Info](#device-info)
  - [Driver Actions](#driver-actions)
  - [Programming Commands](#programming-commands)
  - [Programming Variables](#programming-variables)
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
- ESPHome driver configured with Bluetooth proxy capability, with active
  connections enabled
- Homedics SereneScent diffuser within BLE range of the ESPHome device

# <span style="color:#17BCF2">Features</span>

- Power on, off and toggle
- Mist intensity: low, medium or high
- Light color: off, rotating, white, red, blue, violet, green or orange
- State read back from the diffuser after every command and on a configurable
  polling interval
- Keypad button links for power and intensity, and a power relay connection
- Signal strength and last-seen reporting

# <span style="color:#17BCF2">Compatibility</span>

## Supported Devices

| Device               | Advertised Name         | Control | Feedback |
| -------------------- | ----------------------- | :-----: | :------: |
| Homedics SereneScent | `ARMH-xxx`, `ARPRP-xxx` |   ✅    |    ✅    |

The diffuser is recognized by its advertised Bluetooth name. It also advertises
the generic `0xFFF0` service, but so do many unrelated devices, so that alone
does not identify it.

## Tested Devices

| Model    | Notes            |
| -------- | ---------------- |
| ARMH-972 | Community tested |

If you try this driver on another model, and it works, let us know!

# <span style="color:#17BCF2">How It Works</span>

## Connection Cycle

The diffuser serves one Bluetooth client at a time and each connection holds one
of the ESP32's few connection slots, so the driver never stays connected. Each
command or poll runs one cycle:

1. Connect through the ESPHome proxy and subscribe to the diffuser's
   notifications.
1. Send each queued command and wait for the diffuser to acknowledge it.
1. Query the diffuser's status. The properties, variables and power relay are
   updated only from this reply, never from the command that was sent, so they
   always show what the diffuser reports.
1. Disconnect three seconds later and schedule the next poll. Commands that
   arrive during those three seconds reuse the connection; one that arrives
   while the proxy is still releasing it waits for that, up to three seconds.

Commands sent while a connection is being made are queued and sent in order, so
a scene that turns the diffuser on and sets a color does both. If a cycle fails,
the commands waiting in it are dropped and have to be sent again; the next poll
only reads the status.

The first status read happens as soon as the driver is bound when the diffuser
was selected in the ESPHome driver, or on the diffuser's first Bluetooth
advertisement when it was selected through the Bluetooth Coordinator. Polls
follow from there.

## Home and Schedule Modes

The diffuser runs either in HOME mode or in SCHEDULE mode, which follows a
schedule set in the Homedics app. It only accepts intensity and color changes in
HOME mode. When the last status reported SCHEDULE mode, the driver switches the
diffuser to HOME mode before sending a command, which ends the app's schedule.
Status requests and polls do not change the mode.

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
1. Extract and install the `esphome_serenescent.c4z` driver.
1. Close the Homedics app on every phone and tablet near the diffuser. While the
   app is connected, the ESPHome proxy cannot connect.
1. In the ESPHome driver, select your diffuser (listed as
   `<MAC> - ARMH-XXX - [Homedics SereneScent / Active Connection]`) in the
   **Select Bluetooth Devices** property. A connection is created for it.
1. Use the "Search" tab to find "ESPHome SereneScent" and add it to your
   project.
1. In the "Connections" tab, bind the ESPHome SereneScent connection to the
   diffuser's connection on the ESPHome driver.

<!-- #else -->

1. Download the latest `control4-esphome.zip` from
   [Github](https://github.com/finitelabs/control4-esphome/releases/latest).
1. Extract and install the `esphome_serenescent.c4z` driver.
1. Close the Homedics app on every phone and tablet near the diffuser. While the
   app is connected, the ESPHome proxy cannot connect.
1. In the ESPHome driver, select your diffuser (listed as
   `<MAC> - ARMH-XXX - [Homedics SereneScent / Active Connection]`) in the
   **Select Bluetooth Devices** property. A connection is created for it.
1. Use the "Search" tab to find "ESPHome SereneScent" and add it to your
   project.
1. In the "Connections" tab, bind the ESPHome SereneScent connection to the
   diffuser's connection on the ESPHome driver.

<!-- #endif -->

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current driver state. Common values:

- `Initializing` - Driver is starting up
- `Disconnected` - Not bound, or no advertisement received since the driver
  started or was reset
- `Waiting for data` - Bound, waiting for the first advertisement
- `Connecting` - A connection has been requested
- `Connected` - Connected and exchanging commands or status
- `Listening (next poll in Nm)` - Waiting for the next poll
- `Connection failed: <reason>`, `Connection timed out`,
  `No response from device`, `Disconnected: <reason>` or `Error: <message>` -
  The last cycle failed and its commands were dropped; the next poll reads the
  status again

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Logging automatically turns off after 3 hours to prevent
excessive log output. Default is `Off`.

#### Polling Interval \[ 1 - 10, default: **_5_** \]

How often, in minutes, the driver connects to read the diffuser's status.

### Device State

These show the diffuser's state as it last reported it, or `Unknown` until the
first status is read.

#### Power (read-only)

`On` or `Off`.

#### Intensity (read-only)

`low`, `medium` or `high`, or `Off` while the diffuser is off.

#### Color (read-only)

`off`, `rotating`, `white`, `red`, `blue`, `violet`, `green` or `orange`, or
`Off` while the diffuser is off.

### Device Info

#### Name (read-only)

The Bluetooth name of the diffuser.

#### MAC Address (read-only)

The Bluetooth MAC address of the diffuser.

#### RSSI (read-only)

The signal strength of the last BLE advertisement, in dBm.

#### Last Seen (read-only)

The time of the last advertisement or status reply from the diffuser.

## Driver Actions

### Power On

Turns the diffuser on.

### Power Off

Turns the diffuser off.

### Toggle Power

Turns the diffuser off if it is on, and on if it is off.

### Set Intensity

Sets the mist intensity.

**Parameters:**

- **Level** [ low | medium | high ] - The intensity to set.

### Set Color

Sets the light color.

**Parameters:**

- **Color** [ off | rotating | white | red | blue | violet | green | orange ] -
  The color to set.

### Request Status

Connects to the diffuser, reads its status, then disconnects.

### Reset Driver

Resets the driver state to defaults. Clears the diffuser's last known state and
the driver's variables. Settings such as the polling interval are kept.

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

## Programming Commands

These commands are available in Control4 programming under the device's command
list.

| Command              | Parameter | Values                                                                 | Description                         |
| -------------------- | --------- | ---------------------------------------------------------------------- | ----------------------------------- |
| Power On             |           |                                                                        | Turns the diffuser on               |
| Power Off            |           |                                                                        | Turns the diffuser off              |
| Toggle Power         |           |                                                                        | Toggles the diffuser on or off      |
| Set Intensity        | Level     | `low`, `medium`, `high`                                                | Sets the mist intensity             |
| Set Color            | Color     | `off`, `rotating`, `white`, `red`, `blue`, `violet`, `green`, `orange` | Sets the light color                |
| Request Status       |           |                                                                        | Reads the diffuser's status now     |
| Set Polling Interval | Interval  | 1 - 10                                                                 | Sets the polling interval (minutes) |

## Programming Variables

The driver exposes the following variables to Control4 programming. These mirror
the matching read-only properties and can be used in programming conditions and
event handlers.

| Variable    | Type   | Description                                                    |
| ----------- | ------ | -------------------------------------------------------------- |
| Connected   | BOOL   | True while the driver is connected or its last cycle succeeded |
| Power       | STRING | `On` or `Off`                                                  |
| Intensity   | STRING | `low`, `medium` or `high`, or `Off` while the diffuser is off  |
| Color       | STRING | The light color, or `Off` while the diffuser is off            |
| Name        | STRING | Bluetooth name of the diffuser                                 |
| MAC Address | STRING | Bluetooth MAC address of the diffuser                          |

## Connections

### ESPHome SereneScent (consumer)

The BLE connection to the diffuser via the ESPHome driver (binding 5002). Bind
this to the diffuser's connection on the ESPHome driver.

### Button Links (provider)

Bind a keypad button to any of these. A press and its click count as one tap,
and further presses on the same connection within half a second are ignored.

| Connection                   | Action                                |
| ---------------------------- | ------------------------------------- |
| On Button Link               | Turns the diffuser on                 |
| Off Button Link              | Turns the diffuser off                |
| Toggle Button Link           | Toggles the diffuser on or off        |
| Intensity Up Button Link     | Steps intensity up, stopping at high  |
| Intensity Down Button Link   | Steps intensity down, stopping at low |
| Low Intensity Button Link    | Sets intensity to `low`               |
| Medium Intensity Button Link | Sets intensity to `medium`            |
| High Intensity Button Link   | Sets intensity to `high`              |

### Power Relay (provider)

A `RELAY` connection for devices that switch a relay. `CLOSE` turns the diffuser
on, `OPEN` turns it off and `TOGGLE` toggles it. The relay reports `CLOSED` or
`OPENED` whenever a status read shows the power changed, and a newly bound
device is sent the last known state.

# <span style="color:#17BCF2">Troubleshooting</span>

**Driver Status shows "Connection failed" or "No response from device"** The
Homedics app or another Bluetooth client is probably connected to the diffuser.
It accepts one client at a time. Close the app on every nearby phone and tablet,
then send the command again; a command in a failed cycle is not retried.

**"Connection failed: No connection slots available"** Every connection slot on
the ESP32 is in use. The driver releases its slot after each cycle, so this
clears once another device's connection ends. See the ESPHome driver's
documentation on connection slots.

**The diffuser is not listed in Select Bluetooth Devices** Check that the
diffuser is powered and within range of the ESP32, and that its Bluetooth name
starts with `ARMH-` or `ARPRP-`. Then choose **Refresh List** in the property.

**Intensity or color commands do nothing** The diffuser may be off; intensity
and color changes do not turn it on. Turn it on first.

**A schedule set in the Homedics app stopped running** Sending a command from
Control4 switches the diffuser from SCHEDULE to HOME mode, which ends the app's
schedule. See [Home and Schedule Modes](#home-and-schedule-modes).

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
