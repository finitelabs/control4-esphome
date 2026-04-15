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

<img alt="ESPHome Yale" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4, ESPHome, or Yale.

<!-- #endif -->

This driver provides native Control4 lock proxy integration for Yale and August
smart locks via BLE through an ESPHome Bluetooth proxy. It enables lock/unlock
control, status monitoring, battery reporting, and door sense.

No cloud connection is required for day-to-day operation - the Yale/August cloud
is only used during initial setup to retrieve the offline key.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
  - [Supported Locks](#supported-locks)
- [How It Works](#how-it-works)
  - [Connection Modes](#connection-modes)
  - [Door Sense](#door-sense)
  - [Jam Detection](#jam-detection)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Adding the Driver](#adding-the-driver)
  - [Key Setup](#key-setup)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
    - [Authentication Settings](#authentication-settings)
    - [Yale Cloud Settings](#yale-cloud-settings)
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
- ESPHome driver configured with Bluetooth proxy capability
- Yale or August smart lock within BLE range of the ESPHome device
- Offline key from the Yale/August cloud account (obtained automatically via the
  driver or manually)

# <span style="color:#17BCF2">Features</span>

- Control4 Lock Proxy integration for native lock/unlock/toggle control
- Two connection modes: Persistent (always connected) or Poll
  (connect-query-disconnect)
- Battery level reporting
- Door sense (contact sensor) for models with DoorSense hardware - auto-detected
  and dynamically added
- Automatic offline key retrieval from the Yale/August cloud API
- Jam detection after lock/unlock operations

# <span style="color:#17BCF2">Compatibility</span>

This driver uses the same BLE protocol as the
[yalexs-ble](https://github.com/bdraco/yalexs-ble) library and should work with
any Yale or August smart lock that supports offline key authentication over
Bluetooth.

## Supported Locks

| Brand  | Model  | Name                                           |
| ------ | ------ | ---------------------------------------------- |
| Yale   | YRD216 | Assure Lock Keypad with Physical Key           |
| Yale   | YRL216 | Assure Door Lever Lock with Push Button Keypad |
| Yale   | YRD226 | Assure Lock Touchscreen Deadbolt               |
| Yale   | YRL226 | Assure Door Lever Lock Keypad                  |
| Yale   | YRD256 | Assure Lock Keypad                             |
| Yale   | YRD420 | Assure Lock 2                                  |
| Yale   | YRD450 | Assure Lock 2 Key Free                         |
| August | ASL-05 | WiFi Smart Lock (Gen 4)                        |
| August | ASL-03 | Smart Lock Pro (Gen 3)                         |
| August | ASL-02 | Smart Lock Pro (Gen 2)                         |

> **Note:** Other Yale/August locks using the same BLE protocol may also work.
> Yale Conexis (L1/L2) and Yale Smart Cabinet Lock have limited protocol support
> (lock/unlock only, no status updates).

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">How It Works</span>

## Connection Modes

The driver supports two connection modes, configured via the **Connection Mode**
property:

### Poll (default)

The driver connects to the lock on-demand, queries the full status chain (lock
state, door state, battery), then cleanly disconnects. After disconnecting, it
schedules the next poll based on the **Polling Interval** property.

The first poll is triggered automatically when the driver receives a BLE
advertisement from the lock. Subsequent polls follow the configured interval.
Lock/unlock commands also trigger an immediate connect-query-disconnect cycle.

Poll mode is recommended for most installations. It conserves lock battery and
does not hold the BLE connection, leaving it available for other clients (e.g.,
the Yale app or HomeKit).

### Persistent

The driver maintains a continuous BLE connection to the lock with a 20-second
keepalive poll. This provides the lowest latency for status updates but consumes
more battery and monopolizes the lock's single BLE connection slot.

If the connection drops, the driver automatically reconnects with exponential
backoff (5s, 10s, 20s, 40s, 80s) for up to 5 attempts. After 5 failures, it
falls back to listening and waits for the next BLE advertisement to retry.

> **Note:** Yale/August locks only support one active BLE connection at a time.
> In Persistent mode, the Yale app and HomeKit will be unable to connect to the
> lock while the driver holds the connection.

## Door Sense

If the lock has DoorSense hardware configured (a magnetic contact sensor that
detects whether the door is open or closed), the driver automatically detects
this from status responses and creates a dynamic Contact Sensor binding. The
**Door Status** property is shown only when DoorSense is detected.

If DoorSense is not configured on the lock, no contact sensor binding is created
and the Door Status property is hidden.

## Jam Detection

After a lock or unlock command, the driver re-queries lock status to confirm the
operation succeeded. If the lock reports a jam, the status is updated to `fault`
on the Control4 lock proxy.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Installer Setup</span>

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

After adding the driver, enter your DriverCentral credentials in the Cloud
Settings section to activate the license and enable automatic updates.

<!-- #endif -->

## Adding the Driver

1. Add the ESPHome driver and configure it with Bluetooth proxy enabled
2. The ESPHome driver will scan for nearby BLE devices - Yale/August locks
   appear as "Yale Lock" or similar
3. Add the ESPHome Yale driver from the Lock category
4. Bind the ESPHome Yale connection to the Yale Lock device exposed by the
   ESPHome driver

## Key Setup

The driver requires an **offline key** to authenticate with the lock. There are
two ways to obtain it:

### Automatic (recommended)

1. Enter your Yale/August email and password in the **Yale Cloud Settings**
   section
2. Run the **Request Verification Code** action - a code is sent to your email
3. Run the **Verify and Fetch Keys** action and enter the verification code
4. The driver automatically populates the **Offline Key** and **Key Slot**
   fields

### Manual

If you already have the offline key (e.g., from another integration):

1. Enter the 32-character hex string in the **Offline Key** field
2. Set the **Key Slot** (usually `1`)

Once the key is configured, the driver will connect to the lock on the next BLE
advertisement.

> **Note:** If the Yale cloud API reports that the key is "provisioned but not
> yet loaded," you need to operate the lock once from the Yale app to load the
> key onto the lock hardware, then retry key fetching.

<div style="page-break-after: always"></div>

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

Displays the current driver state. Common values:

- `Initializing` - Driver is starting up
- `Waiting for data` - Driver is up, waiting for the first BLE advertisement
- `Disconnected` - Not receiving BLE advertisements
- `Listening` - Receiving advertisements, not connected
- `Listening (next poll in Ns)` - Poll mode, waiting for next cycle
- `Connected` - Active BLE session (Persistent mode or mid-query)
- `Reconnecting (N/5)` - Persistent mode auto-reconnect with attempt count
- `Listening (reconnect failed)` - Persistent mode max retries exhausted
- `Error: <message>` - Configuration or connection error

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level [ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra ]

Sets the logging level. Default is `3 - Info`.

#### Log Mode [ **_Off_** | Print | Log | Print and Log ]

Sets the logging mode. Logging automatically turns off after 3 hours to prevent
excessive log output. Default is `Off`.

#### Connection Mode [ Persistent | **_Poll_** ]

Controls how the driver connects to the lock. See
[Connection Modes](#connection-modes) for details.

- **Poll** (default) - Connect on-demand, query status, disconnect. Best battery
  life. The lock's BLE connection remains available for other clients.
- **Persistent** - Maintain a continuous BLE connection with 20s keepalive.
  Lowest latency but higher battery drain and monopolizes the lock's BLE slot.

#### Polling Interval [ 15 - 300, default: **_60_** ]

How often (in seconds) to connect and query lock status in Poll mode. Only
visible when Connection Mode is set to `Poll`.

### Authentication Settings

#### Offline Key

The 32-character hex string offline key for your Yale/August lock. This is
populated automatically by the **Verify and Fetch Keys** action, or can be
entered manually.

#### Key Slot

The key slot index used during the BLE handshake. Default is `1`. This is
populated automatically by the **Verify and Fetch Keys** action.

### Yale Cloud Settings

These settings enable automatic retrieval of the offline key from the
Yale/August cloud API. They are only needed during initial setup - the driver
does not contact the cloud during normal operation.

#### Yale Email

Your Yale/August account email address.

#### Yale Password

Your Yale/August account password.

#### Yale Cloud Status (read-only)

Displays the status of the cloud key retrieval process. Shows progress through
session creation, verification code sending, lock enumeration, and key
extraction.

### Device Info

#### Name (read-only)

The BLE advertisement name of the lock.

#### MAC Address (read-only)

The Bluetooth MAC address of the lock.

#### RSSI (read-only)

The signal strength of the last BLE advertisement, in dBm.

#### Last Seen (read-only)

The timestamp of the last communication with the lock.

#### Battery (read-only)

The battery percentage of the lock. Updated each time the driver queries the
lock's status chain.

#### Lock Status (read-only)

The current lock status as reported by the lock (`locked`, `unlocked`, `fault`,
`unknown`). A `fault` status indicates the lock is jammed.

#### Door Status (read-only)

The current door status (`CLOSED`, `OPENED`) for models with DoorSense. This
property is only visible when DoorSense is detected on the lock.

## Driver Actions

### Request Verification Code

Initiates the Yale/August cloud authentication flow. Creates a session with the
cloud API and sends a verification code to the email address configured in
**Yale Email**. Enter your email and password before running this action.

After running this action, check your email for the verification code, then run
**Verify and Fetch Keys**.

### Verify and Fetch Keys

Validates the verification code and fetches the offline key from the Yale/August
cloud API.

**Parameters:**

- **Verification Code** - The code received via email after running **Request
  Verification Code**.

On success, the **Offline Key** and **Key Slot** properties are automatically
populated. The driver will connect to the lock on the next BLE advertisement.

### Request Status

Triggers an immediate status refresh from the lock. Queries lock state, door
sensor, and battery level. Useful as a Composer Pro action for quick manual
checks.

In both connection modes, this is also available as a programming command (see
[Programming Commands](#programming-commands) below).

### Reset Driver

Resets the driver state to defaults. Clears all persisted data, cached BLE
handles, and dynamic bindings. The offline key and other properties are
preserved.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

## Programming Commands

These commands are available in Control4 programming under the device's command
list.

### Request Status

Triggers an immediate status refresh from the lock. Queries lock state, door
sensor (if equipped), and battery level in a single status chain.

- **Persistent mode:** Executes immediately on the active connection instead of
  waiting for the next 20-second keepalive poll.
- **Poll mode:** Connects to the lock, runs the full status chain, then
  disconnects.

**Example use case:** Create a programming event "When front door contact sensor
opens, execute Request Status on Yale lock." This gives near-instant lock state
updates when the door is opened.

### Set Connection Mode

Changes the connection mode at runtime.

**Parameters:**

- **Mode** [ Persistent | Poll ] - The connection mode to switch to.

### Set Polling Interval

Changes the polling interval at runtime.

**Parameters:**

- **Interval** [ 15 - 300 ] - The polling interval in seconds.

## Programming Variables

The driver exposes the following variables to Control4 programming. These mirror
the matching read-only Device Info properties and can be used in programming
conditions and event handlers.

| Variable    | Type   | Description                        |
| ----------- | ------ | ---------------------------------- |
| Battery     | NUMBER | Lock battery level (0 - 100)       |
| Name        | STRING | Friendly name reported by the lock |
| MAC Address | STRING | Lock BLE MAC address               |

## Connections

### Lock (provider)

The Control4 Lock proxy connection (binding 5001). This is automatically managed
by the driver and provides lock/unlock/toggle functionality to Control4.

### ESPHome Yale (consumer)

The BLE connection to the lock via the ESPHome driver (binding 5002). Bind this
to the Yale Lock device exposed by the main ESPHome driver after scanning for
Bluetooth devices.

### Door (dynamic, provider)

A `CONTACT_SENSOR` proxy binding named **Door** that the driver adds at runtime
the first time DoorSense is detected on the lock (see
[Door Sense](#door-sense)). Bind this to a Contact Sensor in Composer Pro to
expose open/closed state to Control4 programming, room occupancy, and
notifications. The binding is not created on locks that do not report a
DoorSense configuration.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Troubleshooting</span>

**"Error: Offline key required"** The offline key has not been configured. Use
the Yale Cloud Settings to fetch it automatically or enter it manually in
Authentication Settings.

**"Key mismatch - re-fetch keys"** The offline key has been rotated (e.g., by
the Yale app or a firmware update). Use the Yale Cloud actions to fetch the new
key.

**"Offline key is provisioned but not yet loaded on the lock"** The key exists
in the Yale cloud but has not been loaded onto the lock hardware. Open the Yale
app and operate the lock once (lock or unlock), then retry the **Verify and
Fetch Keys** action.

**Lock shows as offline / Driver Status stuck on "Disconnected"** The ESPHome
Bluetooth proxy is not detecting the lock. Verify the lock is within BLE range
of the ESP32 device and that the ESPHome driver has Bluetooth proxy enabled.

**Persistent mode keeps reconnecting** Yale locks only support one BLE
connection. If the Yale app, HomeKit, or another client is connected, the driver
cannot connect. Switch to Poll mode or ensure no other clients are connected.

**Lock/unlock commands are slow** In Poll mode, commands require a full
connection cycle (connect, handshake, command, status, disconnect), which takes
several seconds. For faster response, switch to Persistent mode.

**Door Status not showing** The Door Status property and contact sensor binding
are only created when the lock has DoorSense hardware configured. Not all
Yale/August lock models include DoorSense. If your lock has DoorSense hardware
but Door Status is not appearing, verify that DoorSense is calibrated in the
Yale Access app first.

**Key stops working after using the Yale app** The Yale/August cloud may rotate
the offline key when the lock is operated from a mobile device. If this happens,
re-run the **Verify and Fetch Keys** action to retrieve the updated key.

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
Yale/August locks, you can contact us at
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
