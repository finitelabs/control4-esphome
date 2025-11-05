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
  port = tonumber(os.getenv("ESPHOME_TEST_PORT")) or 6053,
  password = os.getenv("ESPHOME_TEST_PASSWORD"),
  encryption_key = os.getenv("ESPHOME_TEST_KEY"),
  scan_duration = tonumber(os.getenv("ESPHOME_TEST_SCAN_DURATION")) or 10,  -- seconds
  filter_mac = os.getenv("ESPHOME_TEST_BT_MAC"),  -- Optional: highlight specific MAC
}

-- Ensure empty strings become nil
if CONFIG.password == "" then CONFIG.password = nil end
if CONFIG.encryption_key == "" then CONFIG.encryption_key = nil end
if CONFIG.filter_mac == "" then CONFIG.filter_mac = nil end

print("=" .. string.rep("=", 70))
print("ESPHome Bluetooth Scan Test")
print("=" .. string.rep("=", 70))
print()
print("Configuration:")
print("  IP Address:     " .. (CONFIG.ip_address or "N/A"))
print("  Port:           " .. CONFIG.port)
print("  Scan Duration:  " .. CONFIG.scan_duration .. " seconds")
if CONFIG.filter_mac then
  print("  Target Device:  " .. CONFIG.filter_mac)
end
print()

if not CONFIG.ip_address then
  print("ERROR: ESPHOME_TEST_IP environment variable is required")
  os.exit(1)
end

-- Convert address to MAC string
-- Handles both numbers and {high, low} format
local function addressToMac(address)
  local high_32, low_32

  if type(address) == "table" then
    high_32 = address[1]
    low_32 = address[2]
  else
    -- Convert number to {high, low}
    low_32 = address % 0x100000000
    high_32 = math.floor(address / 0x100000000)
  end

  -- Extract 6 bytes from {high_32, low_32}
  local byte1 = math.floor(high_32 / 256) % 256
  local byte2 = high_32 % 256
  local byte3 = math.floor(low_32 / 0x1000000) % 256
  local byte4 = math.floor(low_32 / 0x10000) % 256
  local byte5 = math.floor(low_32 / 0x100) % 256
  local byte6 = low_32 % 256

  return string.format("%02X:%02X:%02X:%02X:%02X:%02X", byte1, byte2, byte3, byte4, byte5, byte6)
end

-- Helper to convert bytes to hex string
local function bytesToHex(data)
  if not data or #data == 0 then return "" end
  local hex = {}
  for i = 1, #data do
    table.insert(hex, string.format("%02X", string.byte(data, i)))
  end
  return table.concat(hex, " ")
end

-- Detect device type based on services and manufacturer data
-- Note: This is now mostly redundant since the client does this automatically,
-- but we keep it for backwards compatibility with the test output
local function detectDeviceType(message)
  -- Use the automatically detected device_type if available
  if message.device_type then
    return message.device_type
  end

  -- Fallback to manual detection for backwards compatibility
  -- Check manufacturer data
  if message.manufacturer_data and #message.manufacturer_data > 0 then
    for _, mfg in ipairs(message.manufacturer_data) do
      -- Switchbot uses company ID 0x0969
      if mfg.uuid == 0x0969 then
        return "SwitchBot"
      end
      -- Apple iBeacon uses 0x004C
      if mfg.uuid == 0x004C and mfg.data and #mfg.data >= 2 then
        local subtype = string.byte(mfg.data, 1)
        local sublen = string.byte(mfg.data, 2)
        if subtype == 0x02 and sublen == 0x15 then
          return "iBeacon"
        end
      end
      -- Xiaomi uses 0xFE95
      if mfg.uuid == 0xFE95 then
        return "Xiaomi/Mi"
      end
    end
  end

  -- Check service UUIDs (now they're objects with uuid field)
  if message.service_uuids and #message.service_uuids > 0 then
    for _, svc in ipairs(message.service_uuids) do
      local uuid = type(svc) == "table" and svc.uuid or svc
      -- Switchbot service UUID
      if uuid == "cba20d00-224d-11e6-9fb8-0002a5d5c51b" then
        return "SwitchBot"
      end
      -- Eddystone
      if uuid == "0000feaa-0000-1000-8000-00805f9b34fb" then
        return "Eddystone Beacon"
      end
    end
  end

  return nil
end

-- Track discovered devices
local discovered_devices = {}
local device_count = 0

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
      local is_target = CONFIG.filter_mac and (mac:upper() == CONFIG.filter_mac:upper())

      if not discovered_devices[mac] then
        device_count = device_count + 1

        local device_type = detectDeviceType(message)

        discovered_devices[mac] = {
          address = message.address,
          address_type = message.address_type,
          name = message.name or "(unknown)",
          rssi = message.rssi,
          first_seen = os.time(),
          last_seen = os.time(),
          device_type = device_type,
          adv_count = 1,
        }

        -- Highlight if this is the target device
        local prefix = is_target and "🎯 TARGET: " or "  📱 "

        print(string.format("%s%s", prefix, mac))
        print(string.format("     Name: %s", message.name or "(unnamed)"))

        if device_type then
          print(string.format("     Type: %s", device_type))
        end

        print(string.format("     RSSI: %d dBm", message.rssi or 0))
        print(string.format("     Addr Type: %s", message.address_type or 0))

        -- Display manufacturer and device type if detected
        if message.manufacturer then
          print(string.format("     Manufacturer: %s", message.manufacturer))
        end
        if message.device_type then
          local device_str = message.device_type
          if message.model then
            device_str = device_str .. " - " .. message.model
          end
          print(string.format("     Device Type: %s", device_str))
        end

        if message.manufacturer_data and #message.manufacturer_data > 0 then
          for _, mfg in ipairs(message.manufacturer_data) do
            local data_hex = bytesToHex(mfg.data or "")
            local mfg_info = string.format("0x%04X", mfg.uuid)
            if mfg.name then
              mfg_info = mfg_info .. " (" .. mfg.name .. ")"
            end
            print(string.format("     Mfg Data: %s [%s]", mfg_info, data_hex))
          end
        end

        if message.service_uuids and #message.service_uuids > 0 then
          print("     Services:")
          for _, svc in ipairs(message.service_uuids) do
            local svc_info = svc.uuid
            if svc.description then
              svc_info = svc_info .. " (" .. svc.description .. ")"
            end
            print(string.format("       - %s", svc_info))
          end
        end

        if message.service_data and #message.service_data > 0 then
          print("     Service Data:")
          for _, svc in ipairs(message.service_data) do
            local data_hex = bytesToHex(svc.data or "")
            local svc_info = svc.uuid
            if svc.description then
              svc_info = svc_info .. " (" .. svc.description .. ")"
            end
            print(string.format("       - %s: [%s]", svc_info, data_hex))
          end
        end

        print()
      else
        -- Update existing device
        local device = discovered_devices[mac]
        device.last_seen = os.time()
        device.adv_count = device.adv_count + 1

        -- Update RSSI if changed significantly
        if math.abs((message.rssi or 0) - (device.rssi or 0)) > 5 then
          device.rssi = message.rssi
          local prefix = is_target and "🎯 " or "  📶 "
          print(string.format("%s%s: RSSI updated to %d dBm", prefix, mac, message.rssi or 0))
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
  -- Process timers and socket I/O
  processEventLoop()
  sleep(0.01)  -- Small sleep to prevent CPU spinning
end

-- Print summary
print()
print("=" .. string.rep("=", 70))
print("Scan Complete")
print("=" .. string.rep("=", 70))
print(string.format("Discovered %d unique device(s)", device_count))
print()

if device_count == 0 then
  print("No devices found. Possible reasons:")
  print("  - No BLE devices are advertising nearby")
  print("  - Devices are already connected and not advertising")
  print("  - BLE interference or range issues")
  print()
else
  -- Count device types
  local type_counts = {}
  local total_advertisements = 0

  for mac, device in pairs(discovered_devices) do
    total_advertisements = total_advertisements + device.adv_count
    if device.device_type then
      type_counts[device.device_type] = (type_counts[device.device_type] or 0) + 1
    else
      type_counts["Unknown"] = (type_counts["Unknown"] or 0) + 1
    end
  end

  print("Device Types:")
  for device_type, count in pairs(type_counts) do
    print(string.format("  %s: %d", device_type, count))
  end
  print()

  print(string.format("Total advertisements received: %d", total_advertisements))
  print(string.format("Average advertisements per device: %.1f", total_advertisements / device_count))
  print()

  -- Check if target device was found
  if CONFIG.filter_mac then
    local target_found = false
    for mac, device in pairs(discovered_devices) do
      if mac:upper() == CONFIG.filter_mac:upper() then
        target_found = true
        print("🎯 Target Device Status:")
        print(string.format("   MAC:    %s", mac))
        print(string.format("   Name:   %s", device.name))
        if device.device_type then
          print(string.format("   Type:   %s", device.device_type))
        end
        print(string.format("   RSSI:   %d dBm", device.rssi or 0))
        print(string.format("   Advs:   %d", device.adv_count))
        print()
        break
      end
    end

    if not target_found then
      print("⚠️  Target device NOT found: " .. CONFIG.filter_mac)
      print("   Device may be:")
      print("   - Out of range")
      print("   - Already connected to another system")
      print("   - Powered off or in deep sleep")
      print()
    end
  end

  -- Show top 5 devices by RSSI (signal strength)
  print("Top Devices by Signal Strength:")
  local devices_by_rssi = {}
  for mac, device in pairs(discovered_devices) do
    table.insert(devices_by_rssi, {mac = mac, device = device})
  end
  table.sort(devices_by_rssi, function(a, b)
    return (a.device.rssi or -100) > (b.device.rssi or -100)
  end)

  for i = 1, math.min(5, #devices_by_rssi) do
    local mac = devices_by_rssi[i].mac
    local device = devices_by_rssi[i].device
    local type_str = device.device_type and (" (%s)"):format(device.device_type) or ""
    print(string.format("  %d. %s%s - %d dBm - %s",
      i, mac, type_str, device.rssi or 0, device.name))
  end
  print()
end

os.exit(0)
