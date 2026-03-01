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

<img alt="ESPHome Bluetooth Coordinator" src="./images/header.png" width="500"/>

---

# <span style="color:#17BCF2">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or ESPHome.

<!-- #endif -->

The ESPHome Bluetooth Coordinator aggregates multiple ESPHome Bluetooth proxies
to provide intelligent BLE device management across your home. This enables:

- **RSSI-based routing** - Commands are automatically routed to the proxy with
  the strongest signal for each device
- **Automatic failover** - Failed connections retry through alternate proxies
- **Room-level presence tracking** - Track which room BLE devices are in,
  similar to ESPresense or Room Assistant

## Architecture Overview

The following diagram shows how the drivers work together:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   BLE Proxy 1   │     │   BLE Proxy 2   │     │   BLE Proxy 3   │
│  (Living Room)  │     │    (Kitchen)    │     │   (Bedroom)     │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ ESPHome Driver  │     │ ESPHome Driver  │     │ ESPHome Driver  │
│   (Instance 1)  │     │   (Instance 2)  │     │   (Instance 3)  │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                                 ▼
                    ┌──────────────────────────┐
                    │  Bluetooth Coordinator   │
                    │  (RSSI routing, presence │
                    │   tracking, failover)    │
                    └────────────┬─────────────┘
                                 │
             ┌───────────────────┼───────────────────┐
             │                   │                   │
             ▼                   ▼                   ▼
     ┌────────────────┐ ┌─────────────────┐ ┌────────────────┐
     │ ESPHome BTHome │ │ESPHome SwitchBot│ │ ESPHome Govee  │
     │   Sub-driver   │ │   Sub-driver    │ │   Sub-driver   │
     └────────────────┘ └─────────────────┘ └────────────────┘
```

Each Bluetooth proxy connects to its own ESPHome driver instance. The Bluetooth
Coordinator aggregates all proxies and routes commands to the optimal proxy
based on signal strength. Sub-drivers handle protocol-specific communication
with BLE devices.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Driver Installation](#driver-installation)
  - [Coordinator Setup](#coordinator-setup)
- [Driver Properties](#driver-properties)
  <!-- #ifdef DRIVERCENTRAL -->
  - [Cloud Settings](#cloud-settings)
  <!-- #endif -->
  - [Driver Settings](#driver-settings)
  - [Coordinator Status](#coordinator-status)
  - [Device Settings](#device-settings)
  - [Presence Settings](#presence-settings)
- [Connections](#connections)
- [Driver Actions](#driver-actions)
  - [Reset Driver](#reset-driver)
- [Presence Tracking](#presence-tracking)
  - [How It Works](#how-it-works)
  - [Anti-Flapping Algorithm](#anti-flapping-algorithm)
  - [Unsupported Devices](#unsupported-devices)
  - [Events](#events)
  - [Variables](#variables)
  - [Contact Sensor Bindings](#contact-sensor-bindings)
- [Best Practices](#best-practices)
  - [Proxy Placement](#proxy-placement-for-presence-tracking)
  - [Tuning Anti-Flapping Settings](#understanding-the-anti-flapping-settings)
  - [Performance Considerations](#performance-considerations)
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
- One or more ESPHome devices with `bluetooth_proxy` component enabled
- ESPHome driver installed and connected for each proxy

# <span style="color:#17BCF2">Features</span>

- **Multi-proxy aggregation** - Combine BLE coverage from multiple ESP32 devices
- **Intelligent routing** - Automatically select the best proxy based on signal
  strength
- **Connection failover** - Retry failed operations through alternate proxies
- **Room presence detection** - Determine which room devices are in
- **Occupancy tracking** - Create automations based on room occupancy
- **Home/Away detection** - Track when devices arrive or leave

# <span style="color:#17BCF2">Installer Setup</span>

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

> If you already have the
> [DriverCentral Cloud driver](https://drivercentral.io/platforms/control4-drivers/utility/drivercentral-cloud-driver/)
> installed in your project you can continue to
> [Driver Installation](#driver-installation).

This driver relies on the DriverCentral Cloud driver to manage licensing and
automatic updates. If you are new to using DriverCentral you can refer to their
[Cloud Driver](https://help.drivercentral.io/407519-Cloud-Driver) documentation
for setting it up.

<!-- #endif -->

## Driver Installation

<!-- #ifdef DRIVERCENTRAL -->

1. Download the latest `control4-esphome.zip` from
   [DriverCentral](https://drivercentral.io/platforms/control4-drivers/utility/esphome).
2. Extract and install the `esphome_bluetooth_coordinator.c4z` driver.
3. Use the "Search" tab to find "ESPHome Bluetooth Coordinator" and add it to
   your project.

<!-- #else -->

1. Download the latest `control4-esphome.zip` from
   [Github](https://github.com/finitelabs/control4-esphome/releases/latest).
2. Extract and install the `esphome_bluetooth_coordinator.c4z` driver.
3. Use the "Search" tab to find "ESPHome Bluetooth Coordinator" and add it to
   your project.

<!-- #endif -->

## Coordinator Setup

> **Important:** Complete all ESPHome driver setup (steps 1-2) before adding the
> Bluetooth Coordinator. Each ESPHome driver must show "Connected" status before
> proceeding.

### Step 1: Set Up ESPHome Drivers

For each Bluetooth proxy in your home:

1. Use the "Search" tab to find "ESPHome" and add it to your project
2. Place the driver in the room where the physical proxy is located (this sets
   the default room for presence tracking)
3. Configure the driver properties:
   - Set the **IP Address** of the device
   - Set **Authentication Mode** and credentials if required
4. Wait for **Driver Status** to show "Connected"
5. Verify **Bluetooth Proxy Status** appears

Repeat the above steps for each proxy. You should have one ESPHome driver
instance per physical device.

### Step 2: Add the Bluetooth Coordinator

1. Use the "Search" tab to find "ESPHome Bluetooth Coordinator" and add it to
   your project
2. You only need **one** Coordinator instance regardless of how many proxies you
   have

### Step 3: Connect ESPHome Drivers to the Coordinator

1. Go to the **Connections** tab in Composer Pro
2. Select the **Bluetooth Coordinator** driver
3. For each ESPHome driver:
   - Find the ESPHome driver's "Bluetooth Coordinator" connection (under the
     ESPHome driver)
   - Bind it to the Coordinator's "Bluetooth Proxies" connection

<!-- TODO: Add screenshot showing the Connections tab binding process -->

### Step 4: Configure Room Assignments (Optional)

By default, each proxy uses the Control4 room where its ESPHome driver is placed
in the project. If you need to override this:

1. Select the **ESPHome driver**
2. Set the **Bluetooth Proxy Room** property to a different room name

> **Note:** The "Bluetooth Proxy Room" property only appears after the ESPHome
> driver is connected to the Coordinator.

### Step 5: Select BLE Devices (Optional)

1. Select the **Bluetooth Coordinator** driver
2. In the **Select Bluetooth Devices** dropdown, select "Refresh List" to scan
   for devices
3. Wait for scanning to complete (the dropdown shows "-- Scanning..." during the
   scan)
4. Select each BLE device you want to connect to from the dropdown
5. A connection binding is automatically created for each selected device

### Step 6: Add and Bind Sub-Drivers (Optional)

For each BLE device you selected:

1. Use the "Search" tab to find the appropriate sub-driver:
   - **ESPHome SwitchBot** - for SwitchBot devices
   - **ESPHome BTHome** - for Shelly BLU, BTHome sensors
   - **ESPHome Govee** - for Govee sensors
2. Add the sub-driver to your project
3. Go to the **Connections** tab and bind the sub-driver to the device
   connection created in Step 5

### Step 7: Configure Presence Tracking (Optional)

If you want room-level presence tracking:

1. Select the **Bluetooth Coordinator** driver
2. In the **Select Presence Devices** dropdown, select devices to track
3. Adjust presence settings as needed (see
   [Presence Settings](#presence-settings))

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Driver Properties</span>

<!-- #ifdef DRIVERCENTRAL -->

## Cloud Settings

#### Cloud Status (read-only)

Displays the current DriverCentral cloud connection and license status.

#### Automatic Updates [ Off | **_On_** ]

When enabled, the driver will automatically update to the latest version when
available. Default is `On`.

<!-- #endif -->

## Driver Settings

#### Driver Status (read-only)

Displays the current status of the coordinator.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level [ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra ]

Sets the logging level. Default is `3 - Info`.

#### Log Mode [ **_Off_** | Print | Log | Print and Log ]

Sets the logging mode. Default is `Off`.

## Coordinator Status

#### Connected Proxies (read-only)

Shows the number of ESPHome Bluetooth proxies currently connected.

#### Selected Devices (read-only)

Shows the number of BLE devices selected for tracking via the "Select Bluetooth
Devices" property.

## Device Settings

#### Select Bluetooth Devices

A dropdown list showing BLE devices discovered across all connected proxies.
Selecting a device:

- Creates a dynamic binding for the appropriate sub-driver (BTHome, SwitchBot,
  etc.)
- Enables RSSI-based routing for that device
- Tracks the device across all proxies

#### Scan Duration (seconds) [ 5 - 60, default: **_30_** ]

Sets the duration in seconds to scan for BLE devices when refreshing the device
list.

#### RSSI Freshness (seconds) [ 10 - 300, default: **_60_** ]

Sets how long RSSI readings remain valid for proxy selection. After this time,
stale readings are discarded.

## Presence Settings

#### Select Presence Devices

A dropdown list for selecting devices to track for presence/location. Any BLE
device can be tracked, including:

- Phones (if they broadcast BLE advertisements)
- Smartwatches
- Fitness trackers
- BLE beacons
- Any other device with a consistent MAC address

#### RSSI Smoothing Factor [ 0.1 - 0.5, default: **_0.2_** ]

Controls how quickly the RSSI tracking responds to signal changes.

- **Lower values (0.1)** - Smoother, slower response; better for stable tracking
- **Higher values (0.5)** - Faster response; may cause more room "flapping"

#### Room Change Hysteresis (dBm) [ 3 - 15, default: **_6_** ]

The signal improvement (in dBm) required before changing rooms. This prevents
bouncing between rooms when a device is near a boundary.

- **Higher values** - More stable, slower transitions
- **Lower values** - Faster transitions, may cause flapping

#### Room Change Dwell Time (seconds) [ 2 - 30, default: **_5_** ]

How long a new room must have the best signal before committing to the change.

- **Higher values** - More stable, ignores brief signal spikes
- **Lower values** - Faster room changes

#### Away Timeout (seconds) [ 30 - 600, default: **_120_** ]

How long without any signal before marking a device as "away" from home.

#### Minimum Room RSSI (dBm) [ -100 - -40, default: **_-100_** ]

Sets the global minimum signal strength (in dBm) required to assign a device to
a room. Devices with weaker signals will be considered "home" but not in any
specific room.

- **-100 (default)** - Disabled; any signal assigns a room
- **-75 (recommended)** - Medium threshold; device must be within ~6 meters of a
  proxy to be assigned to that room
- **-60** - Strict threshold; device must be within ~3 meters

**Use cases:**

- **Sparse proxy coverage**: When you only have proxies in a few rooms, set to
  `-75` so devices in unmonitored areas aren't incorrectly assigned to the
  nearest (but distant) proxy
- **Large open areas**: Prevent false room assignment when a device is far from
  any proxy but still detectable

**RSSI Reference:**

| RSSI        | Signal    | Typical Distance |
| ----------- | --------- | ---------------- |
| -40 to -60  | Strong    | < 3 meters       |
| -60 to -75  | Medium    | 3-6 meters       |
| -75 to -85  | Weak      | 6-10 meters      |
| -85 to -100 | Very Weak | 10+ meters       |

> **Note:** This only affects room assignment. Home/away status uses any signal
> regardless of strength. Individual proxies can override this value (see
> ESPHome driver "Minimum Room RSSI Override" property).

## Connections

### Bluetooth Proxies (provider)

The provider binding that all ESPHome Bluetooth proxy drivers connect to. Each
ESPHome driver instance with Bluetooth proxy capability binds to this connection
as a consumer, enabling the coordinator to aggregate signals and route commands
across all proxies.

### Dynamic Device Bindings (provider)

When BLE devices are selected via "Select Bluetooth Devices", the coordinator
dynamically creates provider bindings for each device. These bindings allow
sub-drivers (BTHome, SwitchBot, Govee, etc.) to connect and communicate with BLE
devices through the coordinator's RSSI-based routing.

### Dynamic Contact Sensor Bindings (provider)

The coordinator dynamically creates CONTACT_SENSOR bindings for presence
tracking integration. See [Contact Sensor Bindings](#contact-sensor-bindings)
for details.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Driver Actions</span>

#### Reset Driver

> ⚠️ This will clear all device selections, presence tracking configuration, and
> dynamic bindings.

Resets the coordinator to its initial state. Use this if you need to start fresh
or are experiencing issues.

**Parameters:**

- **Are You Sure?** [ **_No_** | Yes ] - Confirmation to reset the driver.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Presence Tracking</span>

## How It Works

1. **Signal Collection** - Each proxy reports the RSSI (signal strength) when it
   sees a tracked device's BLE advertisement
2. **Signal Smoothing** - RSSI values are smoothed using an exponential moving
   average to filter noise
3. **Room Determination** - The device is considered to be in the room of the
   proxy with the strongest smoothed signal
4. **Anti-Flapping** - Multiple safeguards prevent rapid room changes when
   devices are near room boundaries

## Anti-Flapping Algorithm

The presence tracker uses a multi-layer approach to prevent false room changes:

| Layer          | Purpose                    | How It Works                            |
| -------------- | -------------------------- | --------------------------------------- |
| RSSI Smoothing | Filter signal noise        | Exponential moving average on raw RSSI  |
| Hysteresis     | Prevent boundary flapping  | New room must be significantly stronger |
| Dwell Time     | Confirm sustained presence | New room must be "best" for N seconds   |
| Away Timeout   | Graceful departure         | No signal for N seconds = away          |

**Example scenario:** Device is in Kitchen (RSSI -55), walks toward Living Room:

1. Living Room proxy sees device at -58 → No change (not 6dB better than -55)
2. Device moves further, Living Room at -50 → Pending transition starts
3. 3 seconds later, still -50 → Still dwelling
4. 5 seconds later, still consistently better → **Transition to Living Room**

## Unsupported Devices

The following devices **cannot currently** be tracked for presence:

- **Apple devices** (iPhone, iPad, Apple Watch, AirPods) - These devices use
  randomized MAC addresses for privacy, making them unidentifiable via standard
  BLE scanning
- **Android devices with MAC randomization enabled** - Some newer Android
  devices also randomize their MAC address

> **Note:** Apple device support via IRK (Identity Resolving Key) enrollment is
> planned for a future release.

**Recommended alternatives for presence tracking:**

- Dedicated BLE beacons (iBeacon, Eddystone)
- Tile or similar Bluetooth trackers
- Fitness bands/smartwatches that don't randomize MAC
- Any BLE device with a consistent, static MAC address

## Events

The coordinator creates dynamic events for Control4 programming. Per-device and
per-room events are created automatically when devices are tracked and rooms are
discovered. Display names include a unique suffix (MAC address for devices, room
ID for rooms) to avoid conflicts.

### Per-Device Events

| Event                       | Description                                          |
| --------------------------- | ---------------------------------------------------- |
| [Device] [MAC] Home         | Fired when device arrives home (first advertisement) |
| [Device] [MAC] Away         | Fired when device leaves home (away timeout expired) |
| [Device] [MAC] Entered Room | Fired when device enters a room                      |
| [Device] [MAC] Left Room    | Fired when device leaves a room                      |

### Per-Room Events

| Event                    | Description                                    |
| ------------------------ | ---------------------------------------------- |
| [Room] [RoomID] Occupied | Fired when room goes from empty to occupied    |
| [Room] [RoomID] Empty    | Fired when last tracked device leaves the room |

### Generic Events

| Event                   | Description                                   |
| ----------------------- | --------------------------------------------- |
| Any Device Entered Room | Fired when any tracked device enters any room |
| Any Device Left Room    | Fired when any tracked device leaves any room |

> **Tip:** Use the "Last Presence" variables with generic events to determine
> which device and room triggered the event.

## Variables

Variable names for per-device and per-room variables include a unique suffix
(MAC address for devices, room ID for rooms) to avoid conflicts.

### Per-Device Variables

| Variable                         | Type   | Description                                                          |
| -------------------------------- | ------ | -------------------------------------------------------------------- |
| Presence [Device] [MAC] Room     | STRING | Current room name, "Home" (below RSSI threshold), or "Away"          |
| Presence [Device] [MAC] Distance | NUMBER | Estimated distance in meters                                         |
| Presence [Device] [MAC] RSSI     | NUMBER | Current signal strength in dBm (useful for tuning Minimum Room RSSI) |

### Per-Room Variables

| Variable                       | Type   | Description                          |
| ------------------------------ | ------ | ------------------------------------ |
| [Room] [RoomID] Occupied       | STRING | "true" or "false"                    |
| [Room] [RoomID] Occupant Count | NUMBER | Number of tracked devices in room    |
| [Room] [RoomID] Occupants      | STRING | Comma-separated list of device names |

### Last Event Context Variables

These are updated before generic events fire, allowing programming to identify
which device/room triggered the event:

| Variable                    | Type   | Description                  |
| --------------------------- | ------ | ---------------------------- |
| Last Presence Device MAC    | STRING | MAC address of device        |
| Last Presence Device Name   | STRING | Display name of device       |
| Last Presence Room          | STRING | Room name                    |
| Last Presence Previous Room | STRING | Previous room (or "Away")    |
| Last Presence Distance      | NUMBER | Estimated distance in meters |

## Contact Sensor Bindings

The coordinator creates dynamic CONTACT_SENSOR bindings for integration with
Control4's occupancy features. Binding names include a unique suffix (MAC
address for devices, room ID for rooms) to avoid conflicts.

### Room Occupancy Bindings

- **[Room] [RoomID] Occupied** - CLOSED when room has occupants, OPENED when
  empty

### Device Presence Bindings

- **[Device] [MAC] Present** - CLOSED when device is home, OPENED when away

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Best Practices</span>

## Proxy Placement for Presence Tracking

Effective presence tracking requires thoughtful proxy placement. Unlike simple
device control, presence detection relies on comparing signal strength across
multiple proxies to determine location.

### Placement Guidelines

| Guideline                      | Reason                                                 |
| ------------------------------ | ------------------------------------------------------ |
| **One proxy per tracked room** | Each room you want presence detection in needs a proxy |
| **Central placement**          | Maximizes signal strength from anywhere in the room    |
| **Chest height or higher**     | Reduces signal blockage from furniture                 |
| **Away from metal objects**    | Metal causes reflections and unstable RSSI             |

### What to Avoid

- **Proxies too close together** - If two proxies are in the same room or very
  close, they'll report similar RSSI values, making room detection unreliable
- **Behind large metal objects** - Refrigerators, filing cabinets, and metal
  shelving block and reflect signals unpredictably
- **Inside cabinets or enclosures** - Blocks signal and reduces range
- **Near WiFi routers** - RF interference degrades BLE reception

### Recommended Proxy Density

| Home Size                   | Recommended Proxies |
| --------------------------- | ------------------- |
| Small apartment             | 2-3                 |
| Typical 2-story home        | 4-6                 |
| Large home / concrete walls | 6+                  |

> **Tip:** More proxies generally improve accuracy, but proxies placed too close
> together (same room) can actually hurt presence detection by providing
> redundant, similar readings.

### Sparse Coverage Scenarios

If you only have proxies in some rooms (not every room), consider using the
**Minimum Room RSSI** setting to prevent false room assignments:

- Without this setting, a device in an unmonitored room (e.g., hallway,
  bathroom) will be assigned to whichever proxy has the strongest signal, even
  if that proxy is far away
- Set **Minimum Room RSSI** to `-75` so devices must be within reasonable range
  of a proxy to be assigned to that room
- Devices with weak signals will show as "Home" but not in any specific room

**Example:** You have proxies in Kitchen and Living Room, but not in the hallway
between them. Without a minimum RSSI threshold, a person standing in the hallway
might constantly flip between Kitchen and Living Room. With threshold set to
`-75`, they'd show as "Home" without a room assignment until they actually enter
a monitored room.

## Understanding the Anti-Flapping Settings

The presence tracking settings work together to prevent false room changes.
Here's how to tune them for your environment:

### RSSI Smoothing Factor (0.1 - 0.5)

Controls how quickly the system responds to signal changes.

- **Lower values (0.1-0.2)** - Smoother, more stable; ignores brief signal
  spikes; better for most homes
- **Higher values (0.3-0.5)** - Faster response; may cause flapping in
  environments with signal reflections

**When to increase:** If room changes feel sluggish or delayed.

**When to decrease:** If presence flaps between rooms when you're stationary.

### Room Change Hysteresis (3 - 15 dBm)

The signal improvement required before changing rooms. For example, if
hysteresis is 6 dBm and the current room shows -60 dBm, the new room must show
at least -54 dBm before a transition is considered.

- **Lower values (3-5)** - More sensitive; faster room transitions
- **Higher values (8-15)** - More stable; requires definitive signal difference

**When to increase:** Flapping between adjacent rooms, especially near doorways.

**When to decrease:** Room changes don't register even when moving
significantly.

### Room Change Dwell Time (2 - 30 seconds)

How long the new room must have the best signal before committing to the change.

- **Lower values (2-5)** - Faster room detection; may cause brief incorrect
  states
- **Higher values (10-30)** - Very stable; won't register quick pass-throughs

**When to increase:** Brief signal spikes cause incorrect room changes.

**When to decrease:** Entering a room takes too long to register.

### Recommended Starting Points

| Environment          | Smoothing | Hysteresis | Dwell Time |
| -------------------- | --------- | ---------- | ---------- |
| Open floor plan      | 0.2       | 8 dBm      | 5 sec      |
| Many small rooms     | 0.15      | 6 dBm      | 3 sec      |
| Concrete/brick walls | 0.2       | 5 dBm      | 4 sec      |
| Flapping issues      | 0.1       | 10 dBm     | 8 sec      |

## Performance Considerations

### Scaling Limits

Adding more proxies and presence devices increases processing load:

| Component           | Recommended Limit | Impact When Exceeded                      |
| ------------------- | ----------------- | ----------------------------------------- |
| Proxies             | 8-10              | Increased network traffic, slower updates |
| Presence devices    | 10-15             | Higher CPU usage, potential delays        |
| BLE devices (total) | 30-50             | Advertisement processing bottleneck       |

### Network Traffic

Each proxy forwards BLE advertisements to the coordinator. In busy environments:

- **Duplicate advertisements** - Multiple proxies seeing the same device each
  send updates
- **High-frequency advertisers** - Some devices advertise multiple times per
  second
- **Presence calculations** - Each advertisement triggers RSSI processing

**Mitigation:** The coordinator filters advertisements to only process devices
you've explicitly selected. Unselected devices are ignored.

<div style="page-break-after: always"></div>

# <span style="color:#17BCF2">Troubleshooting</span>

## Presence Flapping Between Rooms

**Symptoms:** Device rapidly switches between two or more rooms, or constantly
shows the wrong room.

**Common Causes:**

1. **Proxies too close together** - Two proxies reporting similar RSSI values
2. **Device near room boundary** - Signal strength is similar to multiple
   proxies
3. **Signal reflections** - Metal objects causing unpredictable RSSI
4. **Smoothing too aggressive** - System responding to noise

**Solutions:**

1. Increase **Room Change Hysteresis** to 8-12 dBm
2. Increase **Dwell Time** to 8-10 seconds
3. Decrease **RSSI Smoothing Factor** to 0.1
4. Relocate proxies further apart or reposition away from metal
5. Check that each room has a dedicated proxy

## Device Shows Wrong Room

**Symptoms:** Device consistently shows in the wrong room.

**Common Causes:**

1. **Proxy misconfigured** - Wrong room assignment in ESPHome driver
2. **Antenna differences** - One proxy has stronger/weaker antenna
3. **Environmental factors** - Walls, furniture affecting signal path

**Solutions:**

1. Verify "Bluetooth Proxy Room" is set correctly on each ESPHome driver
2. If one proxy consistently "wins," it may have a better antenna; consider
   relocating other proxies closer to their rooms
3. Add a proxy to the room where the device should be detected

## Device Shows "Away" When Home

**Symptoms:** Device intermittently or constantly shows as away despite being
home.

**Common Causes:**

1. **Device not advertising** - Bluetooth disabled or device in deep sleep
2. **Out of range** - No proxy close enough to receive signal
3. **Away Timeout too short** - Gaps in advertisements trigger away state

**Solutions:**

1. Verify device has Bluetooth enabled and is advertising
2. Add a proxy closer to where the device usually is
3. Increase **Away Timeout** to 180-300 seconds
4. Check that the device has a static MAC address (see Unsupported Devices)

## Slow Room Transitions

**Symptoms:** Moving between rooms takes too long to register.

**Solutions:**

1. Decrease **Dwell Time** to 2-3 seconds
2. Decrease **Room Change Hysteresis** to 4-5 dBm
3. Increase **RSSI Smoothing Factor** to 0.25-0.3

## High CPU or Network Usage

**Symptoms:** Control4 system slowdown, network congestion.

**Solutions:**

1. Reduce the number of tracked presence devices
2. Remove devices from "Select Bluetooth Devices" that don't need tracking
3. Consider using fewer proxies if you have more than 6-8

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

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
