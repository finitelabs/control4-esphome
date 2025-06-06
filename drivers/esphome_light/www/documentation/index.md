[copyright]: # "Copyright 2025 Finite Labs, LLC. All rights reserved."

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

<img alt="ESPHome" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or ESPHome.

This driver provides specialized support for ESPHome devices with light
entities, allowing them to be controlled through the Control4 light proxy.

# <span style="color:#17BCF2">Compatibility</span>

## Supported Color Modes

<div style="font-size: small">

| Mode                                                                       | Supported |
| -------------------------------------------------------------------------- | --------- |
| [Binary (On/Off)](https://esphome.io/components/light/binary)              | ✅        |
| [Brightness](https://esphome.io/components/light/monochromatic)            | ❌        |
| White                                                                      | ❌        |
| [Color Temperature](https://esphome.io/components/light/color_temperature) | ❌        |
| [Cold White + Warm White Light](https://esphome.io/components/light/cwww)  | ❌        |
| [RGB](https://esphome.io/components/light/rgb)                             | ❌        |
| [RGBW](https://esphome.io/components/light/rgbw)                           | ❌        |
| [RGBCT](https://esphome.io/components/light/rgbct)                         | ❌        |
| [RGBWW](https://esphome.io/components/light/rgbww)                         | ❌        |

</div>

# <span style="color:#17BCF2">Installer Setup</span>

Refer to the main ESPHome driver documentation for setup instructions. Once the
main driver is configured and connected to your ESPHome device, bind the ESPHome
Light driver to the light entity exposed by the main driver.

## Driver Setup

### Driver Properties

#### Driver Settings

##### Driver Status (read-only)

Displays the current status of the driver.

##### Driver Version (read-only)

Displays the current version of the driver.

##### Log Level [ Fatal | Error | Warning | **_Info_** | Debug | Trace | Ultra ]

Sets the logging level. Default is `Info`.

##### Log Mode [ **_Off_** | Print | Log | Print and Log ]

Sets the logging mode. Default is `Off`.

# <span style="color:#17BCF2">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2025 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC. For the latest information, please visit
https://github.com/finitelabs/control4-esphome

# <span style="color:#17BCF2">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-esphome/issues/new

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Changelog</span>

[//]: # "## v[Version] - YYY-MM-DD"
[//]: # "### Added"
[//]: # "- Added"
[//]: # "### Fixed"
[//]: # "- Fixed"
[//]: # "### Changed"
[//]: # "- Changed"
[//]: # "### Removed"
[//]: # "- Removed"

## v20250606 - 2025-06-06

### Added

- Initial Release
