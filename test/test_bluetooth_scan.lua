#!/usr/bin/env luajit
--- Test script for ESPHome Bluetooth Proxy scanning
--- This script tests BLE advertisement scanning to see what devices are visible

-- Add parent directory to package path
package.path = package.path .. ";../src/?.lua;../src/?/init.lua;./?.lua"

-- Load the C4 shim layer first
require("c4_shim")

-- Load modules
require("lib.utils")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")

local ESPHomeClient = require("esphome.client")
local log = require("lib.logging")

-- Enable verbose logging
log:setOutputPrintEnabled(true)
log:setLogLevel(6)  -- ULTRA
log:setLogName("BluetoothScan")

-- Configuration
local CONFIG = {
  ip_address = os.getenv("ESPHOME_TEST_IP"),
  port = 6053,
  password = os.getenv("ESPHOME_TEST_PASSWORD"),
  encryption_key = os.getenv("ESPHOME_TEST_KEY"),
  scan_duration = 10,  -- seconds
}

-- Ensure empty strings become nil
if CONFIG.password == "" then CONFIG.password = nil end
if CONFIG.encryption_key == "" then CONFIG.encryption_key = nil end

print("=" .. string.rep("=", 70))
print("ESPHome Bluetooth Scan Test")
print("=" .. string.rep("=", 70))
print()
print("Configuration:")
print("  IP Address:     " .. (CONFIG.ip_address or "N/A"))
print("  Port:           " .. CONFIG.port)
print("  Scan Duration:  " .. CONFIG.scan_duration .. " seconds")
print()

if not CONFIG.ip_address then
  print("ERROR: ESPHOME_TEST_IP environment variable is required")
  os.exit(1)
end

-- Convert address to MAC string
local function addressToMac(address)
  local bytes = {}
  for i = 1, 6 do
    table.insert(bytes, 1, string.format("%02X", address % 256))
    address = math.floor(address / 256)
  end
  return table.concat(bytes, ":")
end

-- Track discovered devices
local discovered_devices = {}

-- Create and configure client
local client = ESPHomeClient:new()
client:setConfig(CONFIG.ip_address, CONFIG.port, CONFIG.password, CONFIG.encryption_key, false)

print("Connecting to ESPHome Bluetooth Proxy...")
client:connect()
  :next(function()
    print("✓ Connected to ESPHome device")
    return client:getDeviceInfo()
  end)
  :next(function(device_info)
    print("✓ Device: " .. (device_info.name or "unknown"))
    local bt_flags = device_info.bluetooth_proxy_feature_flags or 0
    print("  Bluetooth Proxy Flags: " .. bt_flags)

    if bt_flags == 0 then
      print()
      print("ERROR: Device does not support Bluetooth proxy")
      os.exit(1)
    end

    print()
    print("Starting BLE advertisement scan for " .. CONFIG.scan_duration .. " seconds...")
    print()

    -- Subscribe to BLE advertisements
    return client:subscribeBluetoothLEAdvertisements(function(message)
      local mac = addressToMac(message.address)

      if not discovered_devices[mac] then
        discovered_devices[mac] = {
          address = message.address,
          address_type = message.address_type,
          name = message.name or "(unknown)",
          rssi = message.rssi,
          first_seen = os.time(),
        }

        print(string.format("  📱 %s", mac))
        print(string.format("     Name: %s", message.name or "(unnamed)"))
        print(string.format("     RSSI: %d dBm", message.rssi or 0))
        print(string.format("     Address (decimal): %s", tostring(message.address)))

        if message.manufacturer_data and #message.manufacturer_data > 0 then
          for _, mfg in ipairs(message.manufacturer_data) do
            print(string.format("     Manufacturer: 0x%04X (%d bytes)", mfg.uuid, #(mfg.data or "")))
          end
        end

        if message.service_uuids and #message.service_uuids > 0 then
          print("     Services:")
          for _, uuid in ipairs(message.service_uuids) do
            print(string.format("       - %s", uuid))
          end
        end
        print()
      else
        -- Update RSSI if changed significantly
        local device = discovered_devices[mac]
        if math.abs((message.rssi or 0) - (device.rssi or 0)) > 5 then
          device.rssi = message.rssi
          print(string.format("  📶 %s: RSSI updated to %d dBm", mac, message.rssi or 0))
        end
      end
    end)
  end)
  :next(function()
    -- Wait for scan duration
    print("Scan started successfully")
    print("Listening for advertisements...")
    print()
  end, function(err)
    print("✗ Error: " .. tostring(err))
    os.exit(1)
  end)

-- Wait for scan duration
local start_time = os.time()
while os.time() - start_time < CONFIG.scan_duration do
  -- Keep the event loop running
  sleep(0.1)
end

-- Print summary
print()
print("=" .. string.rep("=", 70))
print("Scan Complete")
print("=" .. string.rep("=", 70))
print(string.format("Discovered %d unique device(s)", table.maxn(discovered_devices)))
print()

if table.maxn(discovered_devices) == 0 then
  print("No devices found. Possible reasons:")
  print("  - No BLE devices are advertising nearby")
  print("  - Devices are already connected and not advertising")
  print("  - BLE interference or range issues")
end

os.exit(0)
