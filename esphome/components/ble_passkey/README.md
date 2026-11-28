# Passkey Pairing add-on

An ESPHome external component that lets a Bluetooth proxy pair with devices
that show a 6-digit passkey and expect it typed in. Installer setup is in the
ESPHome driver's documentation; this file is the contract for driver code.

## Requirements

ESPHome 2026.11.0 or later, the ESP32 `esp-idf` framework and the ESP-IDF
toolchain, built on macOS or Linux. Those builds keep a device's keys when the
proxy encrypts an existing pairing; older releases, PlatformIO and Windows
builds can lose them, so the component refuses the configuration there. It also
requires `custom_services: true` under `api:`.

## Actions

- `ble_passkey_set(address, passkey)`: stores the passkey for the address
  (`AA:BB:CC:DD:EE:FF`). Setting an address already held replaces its passkey.
- `ble_passkey_clear(address)`: removes the passkey and any pairing for the
  address, held or not.

A proxy that lists both actions among its services has the add-on.

## Pairing flow

1. Call `ble_passkey_set`, then connect as usual. The driver never asks the
   proxy to pair.
2. When a held device connects unpaired, the component starts MITM encryption
   and answers the passkey request. A paired device gets plain encryption as
   soon as it connects, ahead of the service search.
3. On the first pairing the proxy reads services before encryption finishes, so
   it can miss characteristics the device shows only on an encrypted link. After
   the pairing succeeds, clear the proxy's cached services for the device,
   disconnect and connect again.

Pairings belong to the proxy that made them and survive restarts. Up to 8
addresses are held in flash.

## Failure modes

Both actions report success whatever happens; the proxy logs a warning when it
ignores one. Validate before calling:

- An address that is not six two-digit hex pairs separated by colons is
  ignored.
- A passkey that is not exactly 6 digits is ignored. Send it as text so leading
  zeros are kept.
- With 8 other addresses held, a new address is not stored.

## Effect on other devices

The stricter pairing settings (keyboard-only input, bonding with MITM) are set
only while the component encrypts a held device, one at a time, and restored on
completion, failure, disconnect, clear or after 30 seconds. A device with no
held passkey pairs as on a standard proxy; if it asks for a passkey anyway, the
component does not answer.

At the `VERY_VERBOSE` log level ESPHome prints action arguments, passkeys
included.
