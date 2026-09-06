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

<img alt="ESPHome Lock" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or ESPHome.

<!-- #endif -->

This driver provides specialized support for ESPHome devices with lock entities,
allowing them to be controlled through the Control4 lock proxy.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
    - [Device Settings](#device-settings)
  - [Connections](#connections)
  - [Driver Actions](#driver-actions)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#17BCF2">System Requirements</span>

- Control4 OS 3.3+
- ESPHome driver configured and connected to an ESPHome device with lock
  entities

# <span style="color:#17BCF2">Features</span>

- Control4 Lock Proxy integration for native Control4 lock control
- Lock, unlock, and toggle commands with optional lock code support
- Open Latch action and programming command for latch-style locks that support
  the open action
- Real-time state synchronization with ESPHome device

# <span style="color:#17BCF2">Installer Setup</span>

Refer to the main ESPHome driver documentation for setup instructions. Once the
main driver is configured and connected to your ESPHome device, bind the ESPHome
Lock driver to the lock entity exposed by the main driver.

## Adding the Driver

1. In Composer Pro, add the ESPHome Lock driver.
1. Bind the `ESPHome Lock` connection to the lock entity exposed by the main
   ESPHome driver.
1. If the lock requires a code, set the `Lock Code` property under Device
   Settings.
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

### Device Settings

#### Lock Code

Code sent with lock and unlock commands. Leave blank if the device does not
require a code.

## Programming Variables

| Variable  | Type | Description                                          |
| --------- | ---- | ---------------------------------------------------- |
| Connected | BOOL | True while the driver is talking to the ESPHome lock |

Use `Connected` in Programming to react to the lock going offline, for example
to drive a custom Navigator element or send a notification. The Lock proxy has
no connection-status notification of its own, so this variable is the way to
surface it.

## Connections

### Lock (provider)

The Control4 Lock proxy connection. This is automatically managed by the driver
and provides the lock functionality to Control4.

### ESPHome Lock (consumer)

Bind this connection to the lock entity exposed by the main ESPHome driver.

## Driver Actions

### Open Latch

Opens the latch on locks that support the open action (`supports_open`). Also
available as a device-specific command in Composer programming, so the latch can
be opened from automation (for example, on a doorbell press). Uses the
configured **Lock Code** when one is set. Logs a warning and does nothing if the
connected lock does not support open, or if the lock entity has not been
discovered yet.

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
