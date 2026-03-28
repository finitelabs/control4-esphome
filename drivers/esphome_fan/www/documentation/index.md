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

<img alt="ESPHome Fan" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or ESPHome.

<!-- #endif -->

This driver provides specialized support for ESPHome devices with fan entities,
allowing them to be controlled through the Control4 fan proxy with
%%FAN_SPEED_COUNT%% discrete speed levels.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
  - [Variants](#variants)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
  - [Driver Commands](#driver-commands)
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
- ESPHome driver configured and connected to an ESPHome device with fan entities

# <span style="color:#17BCF2">Features</span>

- Control4 Fan Proxy integration for native Control4 fan control
- On/Off and speed control with %%FAN_SPEED_COUNT%% discrete speed levels
<!-- #ifdef FAN_CAN_REVERSE -->
- Direction control (forward/reverse)
<!-- #endif -->
- Oscillation control via programming command
- Button Link connections for programming integration
- Real-time state synchronization with ESPHome device

# <span style="color:#17BCF2">Compatibility</span>

## Variants

The ESPHome Fan driver is available in multiple variants, each supporting a
different number of discrete speed levels. Choose the variant that matches your
fan's `speed_count` in its ESPHome configuration:

| Variant             | Speed Levels | Reversible | Speed Names                                |
| ------------------- | :----------: | :--------: | ------------------------------------------ |
| 1 Speed             |      1       |     No     | On (on/off only)                           |
| 2 Speed             |      2       |     No     | Low, High                                  |
| 3 Speed             |      3       |     No     | Low, Medium, High                          |
| 4 Speed             |      4       |     No     | Low, Medium Low, Medium High, High         |
| 5 Speed             |      5       |     No     | Low, Low Medium, Medium, Medium High, High |
| 6 Speed             |      6       |     No     | 1, 2, 3, 4, 5, 6                           |
| 1 Speed, Reversible |      1       |    Yes     | On (on/off only)                           |
| 2 Speed, Reversible |      2       |    Yes     | Low, High                                  |
| 3 Speed, Reversible |      3       |    Yes     | Low, Medium, High                          |
| 4 Speed, Reversible |      4       |    Yes     | Low, Medium Low, Medium High, High         |
| 5 Speed, Reversible |      5       |    Yes     | Low, Low Medium, Medium, Medium High, High |
| 6 Speed, Reversible |      6       |    Yes     | 1, 2, 3, 4, 5, 6                           |

The main ESPHome driver automatically creates a binding based on the fan's
reported speed count and direction support, ensuring only the matching variant
can be bound.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Installer Setup</span>

Refer to the main ESPHome driver documentation for setup instructions. Once the
main driver is configured and connected to your ESPHome device, bind the ESPHome
Fan driver to the fan entity exposed by the main driver.

## Adding the Driver

1. In Composer Pro, add the ESPHome Fan driver matching your fan's speed count
   and direction support.
2. Bind the `ESPHome Fan` connection to the matching fan entity exposed by the
   main ESPHome driver.
3. The driver will automatically synchronize its state once bound.

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

## Driver Commands

### Oscillate

Sets the fan oscillation on or off. Available in Composer Pro programming.

**Parameters:**

- **Oscillation** [ **_True_** | False ] - Whether the fan should oscillate.

## Connections

### Fan (provider)

The Control4 Fan proxy connection. This is automatically managed by the driver
and provides the fan functionality to Control4.

### ESPHome Fan (consumer)

Bind this connection to the fan entity exposed by the main ESPHome driver.

### Button Links

The driver provides button link connections for programming integration:

<!-- #ifdef FAN_CAN_REVERSE -->

| Connection                   | Description                          |
| ---------------------------- | ------------------------------------ |
| On Button Link               | Turns the fan on when triggered      |
| Off Button Link              | Turns the fan off when triggered     |
| Toggle Button Link           | Toggles the fan when triggered       |
| Speed Up Button Link         | Increases fan speed when triggered   |
| Speed Down Button Link       | Decreases fan speed when triggered   |
| Toggle Direction Button Link | Toggles fan direction when triggered |

<!-- #else -->

| Connection             | Description                        |
| ---------------------- | ---------------------------------- |
| On Button Link         | Turns the fan on when triggered    |
| Off Button Link        | Turns the fan off when triggered   |
| Toggle Button Link     | Toggles the fan when triggered     |
| Speed Up Button Link   | Increases fan speed when triggered |
| Speed Down Button Link | Decreases fan speed when triggered |

<!-- #endif -->

<div style="page-break-after: always"></div>

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#17BCF2">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright &copy; 2026 Finite Labs LLC

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

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
