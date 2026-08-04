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

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or ESPHome.

<!-- #endif -->

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

Enables or disables automatic driver updates via DriverCentral.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

## Connections

### Light (provider)

The Control4 Light proxy connection. This is automatically managed by the driver
and provides the light functionality to Control4.

### ESPHome Light (consumer)

Bind this connection to the light entity exposed by the main ESPHome driver.

### Button Links

The driver provides three button link connections for programming integration:

| Connection         | Description                        |
| ------------------ | ---------------------------------- |
| On Button Link     | Turns the light on when triggered  |
| Toggle Button Link | Toggles the light when triggered   |
| Off Button Link    | Turns the light off when triggered |

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
