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

<img alt="ESPHome Climate" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or ESPHome.

<!-- #endif -->

This driver provides specialized support for ESPHome devices with climate and
water heater entities, allowing them to be controlled through the Control4
thermostat proxy.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
    - [Remote Sensor Properties](#remote-sensor-properties)
  - [Connections](#connections)
- [Remote Temperature Sensor](#remote-temperature-sensor)
  - [ESPHome Configuration](#esphome-configuration)
- [Water Heater Support](#water-heater-support)

<!-- #ifdef DRIVERCENTRAL -->

- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#17BCF2">System Requirements</span>

- Control4 OS 3.3+
- ESPHome driver configured and connected to an ESPHome device with a climate or
  water heater entity

# <span style="color:#17BCF2">Features</span>

- Control4 ThermostatV2 proxy integration for native thermostat control
- HVAC mode control (Off, Heat, Cool, Auto, Fan Only, Dry)
- Dual setpoint (heat/cool) and single setpoint mode support
- Fan mode control (standard and custom ESPHome fan modes)
- Humidity monitoring and setpoint control
- Water heater entity support with operating mode selection via extras
- Remote temperature sensor support via ESPHome user-defined services
- Dynamic capability reporting based on ESPHome device features
- Temperature values communicated in Celsius - the C4 proxy handles display
  conversion to the project's configured scale

# <span style="color:#17BCF2">Compatibility</span>

This driver works with any ESPHome device that exposes a `climate` or
`water_heater` entity. Tested configurations include:

- **ESPHome `thermostat` platform** - Full-featured climate control with
  heat/cool/auto modes, dual setpoints, fan modes, and humidity
- **ESPHome `bang_bang` platform** - Simple on/off climate control
- **ESPHome `water_heater` platform** - Water heater control with operating
  modes (Eco Mode, Electric, Performance, Heat Pump, High Demand, Gas)

Compatible third-party ESPHome components:

- **[esphome-mitsubishiheatpump](https://github.com/geoffdavis/esphome-mitsubishiheatpump)**
  \- Mitsubishi mini-split heat pumps via CN105 connector
- **[MitsubishiCN105ESPHome](https://github.com/echavet/MitsubishiCN105ESPHome)**
  \- Alternative Mitsubishi CN105 component
- **[esphome-econet](https://github.com/esphome-econet/esphome-econet)** -
  Rheem/Ruud EcoNet water heaters and HVAC systems

# <span style="color:#17BCF2">Installer Setup</span>

Refer to the main ESPHome driver documentation for initial setup. Once the main
driver is configured and connected to your ESPHome device, bind the ESPHome
Climate driver to the climate or water heater entity exposed by the main driver.

## Adding the Driver

1. In Composer Pro, add the ESPHome Climate driver to your project.
1. Bind the `ESPHome Climate` connection to the climate or water heater entity
   exposed by the main ESPHome driver.
1. The driver will automatically synchronize its state and capabilities once
   bound.

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

Displays the current connection status.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`. Automatically reverts to `Off` after 3
hours to prevent excessive logging.

### Remote Sensor Properties

These properties become visible when the ESPHome device exposes user-defined
services. They are used to configure the
[Remote Temperature Sensor](#remote-temperature-sensor) feature.

#### Remote Temperature Service \[ **_(Select)_** | *discovered services...* \]

The ESPHome user-defined service that accepts a remote temperature reading. This
service must accept a `float` parameter named `temperature` (in Celsius).
Selecting a service creates a **Remote Temperature Sensor** binding on the
driver for connecting an external Control4 temperature sensor.

Set to `(Select)` to disable the remote sensor feature and remove the binding.

#### Internal Temperature Service \[ **_None_** | *discovered services...* \]

The ESPHome user-defined service to call when reverting to the device's internal
temperature sensor. This service should take no parameters. Called when the
remote sensor is disabled via the thermostat UI.

Leave as `None` if your ESPHome device automatically reverts to its internal
sensor when remote temperature updates stop (most devices have a configurable
timeout for this).

## Connections

### Thermostat (provider)

The Control4 ThermostatV2 proxy connection. Automatically managed by the driver.

### ESPHome Climate (consumer)

Bind this to the climate or water heater entity exposed by the main ESPHome
driver.

### Remote Temperature Sensor (consumer, dynamic)

A `TEMPERATURE_VALUE` input connection that appears when you select a **Remote
Temperature Service** in the driver properties. Bind any Control4 temperature
sensor to this connection to feed external temperature readings to the ESPHome
device.

### Temperature (provider)

Outputs the climate device's current temperature reading to other Control4
drivers via a `TEMPERATURE_VALUE` connection. Sends both Celsius and Fahrenheit
values.

### Humidity (provider)

Outputs the climate device's current humidity reading to other Control4 drivers
via a `HUMIDITY_VALUE` connection.

# <span style="color:#17BCF2">Remote Temperature Sensor</span>

The remote temperature sensor feature allows a Control4 temperature sensor
(e.g., a room sensor, an outdoor weather station) to override the climate
device's built-in temperature reading. This is useful for devices like
Mitsubishi mini-splits where the built-in sensor is located near the unit rather
than in the living space.

This feature relies on **user-defined services** in the ESPHome device's YAML
configuration. The driver discovers these services automatically and exposes
them as configurable properties.

## ESPHome Configuration

Your ESPHome device YAML must define at least one API service for receiving
remote temperature readings. An optional second service can be defined for
reverting to the internal sensor.

**Example for Mitsubishi mini-split
([MitsubishiCN105ESPHome](https://github.com/echavet/MitsubishiCN105ESPHome)):**

```yaml
api:
  services:
    - service: set_remote_temperature
      variables:
        temperature: float
      then:
        - lambda: |-
            id(my_climate).set_remote_temperature(temperature);

    - service: use_internal_temperature
      then:
        - lambda: |-
            id(my_climate).set_remote_temperature(0);
```

**Example for ESPHome `thermostat` platform:**

```yaml
api:
  services:
    - service: set_remote_temperature
      variables:
        temperature: float
      then:
        - lambda: |-
            id(room_temp_override).publish_state(temperature);

    - service: use_internal_temperature
      then:
        - lambda: |-
            id(room_temp_override).publish_state(NAN);
```

Service requirements:

- **Remote temperature service** (required): Must accept a `float` parameter
  named `temperature` (in Celsius). The driver calls this each time a new
  reading arrives from the bound Control4 sensor.
- **Internal temperature service** (optional): Takes no parameters. The driver
  calls this when the remote sensor is disabled. If your device automatically
  reverts when remote updates stop, you can leave the **Internal Temperature
  Service** property set to `None`.

> **Note:** The service names are not fixed. You can name them anything. The
> driver discovers all user-defined services during connection and populates the
> property dropdowns so you can select the correct ones.

Once the **Remote Temperature Service** is selected and a Control4 temperature
sensor is bound to the **Remote Temperature Sensor** connection, toggle **Use
Remote Temperature Sensor** in the thermostat UI (Navigator or the C4 app) to
begin forwarding readings. Disabling the toggle calls the **Internal Temperature
Service** (if configured) so the device reverts to its built-in sensor.

# <span style="color:#17BCF2">Water Heater Support</span>

ESPHome water heater entities are supported as single-setpoint thermostat
devices. The driver automatically detects water heater entities and configures
the thermostat proxy accordingly:

- **HVAC modes**: Off and Heat
- **Single setpoint**: One target temperature (no separate heat/cool setpoints)
- **Operating modes**: Water heater modes (Eco Mode, Electric, Performance, Heat
  Pump, High Demand, Gas) are exposed via the thermostat's **Extras** section in
  the Control4 UI
- **Temperature ranges and resolution**: Set dynamically from the ESPHome
  device's configuration

When switching the thermostat from Off to Heat, the driver restores the last
selected water heater operating mode.

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
