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

<img alt="ESPHome Light" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#17BCF2">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or ESPHome.

This driver provides specialized support for ESPHome devices with light
entities, allowing them to be controlled through the Control4 light proxy.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
  - [Supported Color Modes](#supported-color-modes)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
  - [Connections](#connections)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#17BCF2">System Requirements</span>

- Control4 OS 3.3+
- ESPHome driver configured and connected to an ESPHome device with light
  entities

# <span style="color:#17BCF2">Features</span>

- Control4 Light Proxy integration for native Control4 lighting control
- On/Off, dimming, color, and color-temperature control across every ESPHome
  light type
- Smooth ramps via ESPHome's transition feature, with click and hold ramp rates
  configurable per driver
- "Default On" preset and "Previous Level" on-mode handling
- **Max On Level** and **Min On Level**
- Hold-to-dim button control on virtual buttons and the On/Off/Toggle button
  link bindings
- Advanced Lighting Scenes participation: dim and color steps, ramp/stop, and
  flash mode
- Real-time state synchronization with the ESPHome device

# <span style="color:#17BCF2">Compatibility</span>

The driver detects each ESPHome light's capabilities at runtime and exposes the
appropriate Composer controls automatically. Binary, dimmable, white,
color-temperature, and full-color lights are all supported.

## Supported Color Modes

<div style="font-size: small">

| Mode                                                                       | Supported |
| -------------------------------------------------------------------------- | --------- |
| [Binary (On/Off)](https://esphome.io/components/light/binary)              | ✅        |
| [Brightness](https://esphome.io/components/light/monochromatic)            | ✅        |
| White                                                                      | ✅        |
| [Color Temperature](https://esphome.io/components/light/color_temperature) | ✅        |
| [Cold White + Warm White Light](https://esphome.io/components/light/cwww)  | ✅        |
| [RGB](https://esphome.io/components/light/rgb)                             | ✅        |
| [RGBW](https://esphome.io/components/light/rgbw)                           | ✅        |
| [RGBCT](https://esphome.io/components/light/rgbct)                         | ✅        |
| [RGBWW](https://esphome.io/components/light/rgbww)                         | ✅        |

</div>

> **Note:** Control4 sets a light to a color or to a color temperature, never
> both. A color picked close to a white, such as the On Color a new light is
> given, lights the light's white where it has one and is shown as the color
> that was picked. A color temperature outside the light's range lights the
> nearer end of it, and Control4 shows that end. On a light built with `color_interlock`, a fade between a
> color and a white goes dark for a moment half way, because ESPHome changes
> between its color and white modes through off.

# <span style="color:#17BCF2">Installer Setup</span>

Refer to the main ESPHome driver documentation for setup instructions. Once the
main driver is configured and connected to your ESPHome device, bind the ESPHome
Light driver to the light entity exposed by the main driver.

## Adding the Driver

1. In Composer Pro, add the ESPHome Light driver to your project.
1. Bind the `ESPHome Light` connection to the matching light entity exposed by
   the main ESPHome driver.
1. The driver will automatically synchronize its state once bound.

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral. Changing it on
any ESPHome driver or sub-driver changes it on all of them.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver. It reads _Disconnected_, and the
proxy is offline, while the ESPHome device is offline or the **ESPHome Light**
connection is removed. A light whose device drops off the network shows off, as
do keypad buttons linked to it, since it has most likely lost power. When the
connection is removed, or the ESPHome driver reconnects to apply a log setting,
the light keeps the level it had. Bound to a different light, it shows offline
until that light reports.

The light ignores commands while its device is offline or its **ESPHome Light**
connection is removed, so a command sent meanwhile changes nothing in Control4
and runs no light programming. Once the device reports again, the light shows
its level and color. After a controller restart, a driver update or a
reconnect, the light reports its level and color as it finds them, even when
they have not changed. A command for the level or color the light already shows
runs no Brightness Changed, Level Change or Color Changed programming.

<!-- #ifdef DRIVERCENTRAL -->

It also reads _Disconnected_ while the ESPHome driver has no active
DriverCentral license. The light keeps the level it had and ignores commands, so
no off or on programming runs, and shows the level the device reports once a
license is active again.

<!-- #endif -->

#### Driver Version (read-only)

Displays the current version of the driver.

<!-- #ifdef DRIVERCENTRAL -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug \]

Sets the logging level. Default is `3 - Info`. While a Support Code has
Composer's Lua tab open, it also offers `5 - Trace` and `6 - Ultra`.

<!-- #else -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

<!-- #endif -->

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

<!-- #ifdef DRIVERCENTRAL -->

#### Support Code

Leave it blank unless Finite Labs support gives you a code: for an hour, it
opens Composer's Lua tab to this driver and adds `5 - Trace` and `6 - Ultra` to
Log Level.

#### Cloud Monitoring \[ Disabled | **_Enabled_** \]

When Enabled, the driver sends Finite Labs a short report once an hour, and a
report of each error it hits, at most 10 a minute. We use them to find and fix
problems in the driver. Set it to Disabled to send nothing.

A report holds the controller's MAC address and OS version, the driver's name,
version, device ID and DriverCentral license status, how much memory the driver
uses, and the sizes of its largest internal tables. An error report also holds
the error message and where in the driver it happened. Before a message is sent,
anything in it that looks like a password, token, key, network address or email
address is removed.

The Diagnostics Snapshot action prints a report in the Lua output, and sends it
only while Cloud Monitoring is Enabled.

<!-- #endif -->

## Programming Variables

| Variable  | Type | Description                                           |
| --------- | ---- | ----------------------------------------------------- |
| Connected | BOOL | True while the driver is talking to the ESPHome light |

Use `Connected` in Programming to react to the device going offline, for example
to drive a custom Navigator element or send a notification. The driver also
reports its connection state to the Light proxy, so Navigator marks the device
unavailable on its own.

## Connections

### Light (provider)

The Control4 Light proxy connection. This is automatically managed by the driver
and provides the light functionality to Control4.

> **Note:** With **Color On Mode** set to Dim-To-Warm, a color set while the
> light is on, from a Navigator, programming, a color preset or an Advanced
> Lighting Scene, stays when the light is dimmed or brightened. A scene step
> that sets the level and the color together is the exception, and the light
> follows Dim-To-Warm from the next level change. The light follows Dim-To-Warm
> again the next time it turns on, and from its first level
> change after a controller restart or a driver update.

> **Note:** A color set while the light is off is the color it next turns on in,
> over its **Color On Mode**, whether it is turned on from a Navigator,
> programming or an Advanced Lighting Scene. Control4 shows it as the light's
> color at once. With Dim-To-Warm it then stays when the light is dimmed or
> brightened, until the light turns off. A controller restart, a driver update
> or a change to the light's connection before it turns on returns it to its
> Color On Mode.

> **Note:** A ramp that Control4 stops part way stops where the light has got
> to.

### ESPHome Light (consumer)

Bind this connection to the light entity exposed by the main ESPHome driver.

### Button Links

The driver provides three button link connections for programming integration:

| Connection         | Description                        |
| ------------------ | ---------------------------------- |
| On Button Link     | Turns the light on when triggered  |
| Toggle Button Link | Toggles the light when triggered   |
| Off Button Link    | Turns the light off when triggered |

A keypad button bound to a button link shows whether the light is on, in that
button's colors, set in Composer under the light's **Button and Button
Connection Status LED Colors** (Top for On, Bottom for Off, Toggle for Toggle).
It shows its on color while the light is on and its off color while it is off.
With the project's default colors, the On and Toggle buttons are lit while the
light is on, and the Off button while it is off. A newly bound button is told
the light's state and colors at once, and a color change reaches it right away.

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
ESPHome, you can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-esphome/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<!-- #embed-changelog -->
