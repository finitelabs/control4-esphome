#!/usr/bin/env luajit
--- Test script for ESPHome Bluetooth Proxy functionality
--- This script tests Bluetooth device connection, service discovery,
--- and GATT operations through an ESPHome Bluetooth proxy.

-- Add parent directory to package path so we can require modules
package.path = package.path .. ";../src/?.lua;../src/?/init.lua;./?.lua"

-- Load the C4 shim layer first (this must come before any other requires)
require("c4_shim")

-- Now load modules in the same order as driver.lua
require("lib.utils")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")

-- Load the ESPHome client and logging
local ESPHomeClient = require("esphome.client")
local log = require("lib.logging")

-- Enable verbose logging for debugging
log:setOutputPrintEnabled(true)
log:setLogLevel(6)  -- 6 = ULTRA (show raw protocol data)
log:setLogName("BluetoothTest")

-- Configuration from environment variables or defaults
local CONFIG = {
  ip_address = os.getenv("ESPHOME_TEST_IP"),
  port = tonumber(os.getenv("ESPHOME_TEST_PORT")) or 6053,
  password = os.getenv("ESPHOME_TEST_PASSWORD"),
  encryption_key = os.getenv("ESPHOME_TEST_KEY"),
  use_openssl = false,
  bluetooth_mac = os.getenv("ESPHOME_TEST_BT_MAC"),  -- e.g., "AA:BB:CC:DD:EE:FF"
}

-- Ensure password and key are nil if empty strings
if CONFIG.password == "" then CONFIG.password = nil end
if CONFIG.encryption_key == "" then CONFIG.encryption_key = nil end
if CONFIG.bluetooth_mac == "" then CONFIG.bluetooth_mac = nil end

print("=" .. string.rep("=", 70))
print("ESPHome Bluetooth Proxy Test")
print("=" .. string.rep("=", 70))
print()
print("Configuration:")
print("  IP Address:     " .. (CONFIG.ip_address or "N/A"))
print("  Port:           " .. CONFIG.port)
print("  Password:       " .. (CONFIG.password and "***" or "(none)"))
print("  Encryption Key: " .. (CONFIG.encryption_key and "***" or "(none)"))
print("  Use OpenSSL:    " .. tostring(CONFIG.use_openssl))
print("  BT MAC Address: " .. (CONFIG.bluetooth_mac or "N/A"))
print()

-- Validate required config
if not CONFIG.ip_address then
  print("ERROR: ESPHOME_TEST_IP environment variable is required")
  os.exit(1)
end

if not CONFIG.bluetooth_mac then
  print("ERROR: ESPHOME_TEST_BT_MAC environment variable is required")
  print("  Example: export ESPHOME_TEST_BT_MAC=\"AA:BB:CC:DD:EE:FF\"")
  os.exit(1)
end

-- Convert MAC address to 48-bit number
local function macToAddress(mac)
  if not mac then
    return nil
  end

  -- Remove colons, spaces, and convert to uppercase
  mac = mac:gsub("[:%s]", ""):upper()

  -- Validate length
  if #mac ~= 12 then
    print("ERROR: Invalid MAC address length: " .. mac)
    return nil
  end

  -- Convert hex string to number
  local address = 0
  for i = 1, 12, 2 do
    local byte = tonumber(mac:sub(i, i + 1), 16)
    if not byte then
      print("ERROR: Invalid MAC address format: " .. mac)
      return nil
    end
    address = address * 256 + byte
  end

  return address
end

-- Convert address back to MAC string for display
local function addressToMac(address)
  local bytes = {}
  for i = 1, 6 do
    table.insert(bytes, 1, string.format("%02X", address % 256))
    address = math.floor(address / 256)
  end
  return table.concat(bytes, ":")
end

-- Convert Bluetooth MAC to number
local bt_address = macToAddress(CONFIG.bluetooth_mac)
if not bt_address then
  print("ERROR: Failed to parse Bluetooth MAC address")
  os.exit(1)
end

print("Bluetooth Address (decimal): " .. bt_address)
print("Bluetooth Address (hex):     0x" .. string.format("%012X", bt_address))
print()

-- Global state for tracking the test
local test_state = {
  connected_to_proxy = false,
  connected_to_ble = false,
  services_discovered = false,
  services = {},
  test_complete = false,
  test_success = false,
}

-- Create client instance
local client = ESPHomeClient:new()

-- Configure client
client:setConfig(
  CONFIG.ip_address,
  CONFIG.port,
  CONFIG.password,
  CONFIG.encryption_key,
  CONFIG.use_openssl
)

-- Connect to ESPHome device
print("Step 1: Connecting to ESPHome Bluetooth Proxy...")
client:connect()
  :next(function()
    print("✓ Connected to ESPHome device")
    test_state.connected_to_proxy = true
    print()

    -- Get device information
    print("Step 2: Fetching device information...")
    return client:getDeviceInfo()
  end, function(err)
    print("✗ Connection failed: " .. tostring(err))
    test_state.test_complete = true
    return nil
  end)
  :next(function(device_info)
    if not device_info then
      return nil
    end

    print("✓ Device Information:")
    print("  Name:              " .. (device_info.name or "N/A"))
    print("  ESPHome Version:   " .. (device_info.esphome_version or "N/A"))
    print("  Model:             " .. (device_info.model or "N/A"))
    if device_info.bluetooth_proxy_feature_flags then
      print("  BT Proxy Flags:    " .. device_info.bluetooth_proxy_feature_flags)
    end
    print()

    -- List entities to check for bluetooth_proxy
    print("Step 2a: Listing entities...")
    return client:listEntities()
  end, function(err)
    print("✗ Failed to get device info: " .. tostring(err))
    test_state.test_complete = true
    return nil
  end)
  :next(function(entities)
    if not entities then
      return nil
    end

    local entity_count = 0
    for _ in pairs(entities) do
      entity_count = entity_count + 1
    end

    print("✓ Found " .. entity_count .. " entities")

    -- Group entities by type
    local by_type = {}
    for key, entity in pairs(entities) do
      local entity_type = entity.entity_type or "unknown"
      if not by_type[entity_type] then
        by_type[entity_type] = {}
      end
      table.insert(by_type[entity_type], entity)
    end

    -- Display entities grouped by type
    for entity_type, entity_list in pairs(by_type) do
      print("  " .. entity_type:upper() .. " (" .. #entity_list .. "):")
      for _, entity in ipairs(entity_list) do
        local name = entity.name or entity.object_id or "unnamed"
        local key = entity.key or "N/A"
        print(string.format("    - %s (key: %s)", name, key))
      end
    end
    print()

    -- Connect to Bluetooth device
    print("Step 3: Connecting to Bluetooth device " .. CONFIG.bluetooth_mac .. "...")

    -- Set up connection callback
    local connection_promise = require("vendor.deferred").new()

    client:bluetoothDeviceConnect(
      bt_address,
      function(message, schema)
        print("✓ Received Bluetooth connection response:")
        print("  Connected: " .. tostring(message.connected))
        print("  MTU:       " .. tostring(message.mtu or "N/A"))
        print("  Error:     " .. tostring(message.error or "none"))
        print()

        if message.connected then
          test_state.connected_to_ble = true
          connection_promise:resolve(true)
        else
          connection_promise:reject("Connection failed: " .. tostring(message.error))
        end
      end,
      nil,  -- address_type (optional)
      true  -- withCache
    )

    return connection_promise
  end, function(err)
    print("✗ Failed to list entities: " .. tostring(err))
    test_state.test_complete = true
    return nil
  end)
  :next(function(success)
    if not success then
      return nil
    end

    -- Discover GATT services
    print("Step 4: Discovering GATT services...")

    local services_promise = require("vendor.deferred").new()
    local all_services = {}

    client:bluetoothGattGetServices(bt_address, function(services, done)
      if not done then
        -- Accumulate services
        for _, service in ipairs(services) do
          table.insert(all_services, service)
        end
        print("  Received " .. #services .. " services...")
      else
        -- Discovery complete
        print("✓ GATT service discovery complete!")
        print("  Total services: " .. #all_services)
        print()

        -- Display services
        for i, service in ipairs(all_services) do
          local uuid_str = "unknown"
          if service.uuid and #service.uuid >= 2 then
            uuid_str = string.format("%016X-%016X", service.uuid[1], service.uuid[2])
          end

          print(string.format("  Service %d: %s", i, uuid_str))
          print(string.format("    Handle: %d", service.handle or 0))

          if service.characteristics then
            print(string.format("    Characteristics: %d", #service.characteristics))
            for j, char in ipairs(service.characteristics) do
              local char_uuid = "unknown"
              if char.uuid and #char.uuid >= 2 then
                char_uuid = string.format("%016X-%016X", char.uuid[1], char.uuid[2])
              end
              print(string.format("      Characteristic %d: %s (handle: %d)", j, char_uuid, char.handle or 0))
            end
          end
          print()
        end

        test_state.services_discovered = true
        test_state.services = all_services
        services_promise:resolve(all_services)
      end
    end)

    return services_promise
  end, function(err)
    print("✗ Failed to connect to Bluetooth device: " .. tostring(err))
    test_state.test_complete = true
    return nil
  end)
  :next(function(services)
    if not services then
      return nil
    end

    print("=" .. string.rep("=", 70))
    print("Bluetooth Proxy Test Summary")
    print("=" .. string.rep("=", 70))
    print("  Connected to ESPHome:      " .. (test_state.connected_to_proxy and "✓" or "✗"))
    print("  Connected to BLE device:   " .. (test_state.connected_to_ble and "✓" or "✗"))
    print("  Services discovered:       " .. (test_state.services_discovered and "✓" or "✗"))
    print("  Total services found:      " .. #test_state.services)
    print()

    if test_state.connected_to_ble and test_state.services_discovered then
      print("✓ All tests passed!")
      test_state.test_success = true
    else
      print("✗ Some tests failed")
    end

    print()
    print("Test monitoring active... (Press Ctrl+C to exit)")
    print("=" .. string.rep("=", 70))
    print()

    test_state.test_complete = true
  end, function(err)
    if err then
      print("✗ Failed to discover services: " .. tostring(err))
    end
    test_state.test_complete = true
  end)

-- Main event loop
local running = true
local socket = require("socket")

-- Handle Ctrl+C gracefully
local function cleanup()
  print()
  print("Shutting down...")

  -- Disconnect from Bluetooth device if connected
  if test_state.connected_to_ble then
    print("Disconnecting from Bluetooth device...")
    client:bluetoothDeviceDisconnect(bt_address)
  end

  -- Disconnect from ESPHome
  client:disconnect()
  running = false
end

-- Set up signal handler (if available)
if pcall(require, "posix.signal") then
  local signal = require("posix.signal")
  signal.signal(signal.SIGINT, cleanup)
end

-- Main loop to process timers and keep connection alive
local loop_count = 0
local test_timeout = 30 -- 30 seconds timeout
local test_start_time = socket.gettime()

while running do
  -- Process timers
  C4:ProcessTimers()

  -- Process socket reads (if client exists and has a socket)
  if client and client._client and client._client.DoRead then
    client._client:DoRead()
  end

  -- Check for timeout
  if not test_state.test_complete then
    local elapsed = socket.gettime() - test_start_time
    if elapsed > test_timeout then
      print()
      print("✗ Test timed out after " .. test_timeout .. " seconds")
      test_state.test_complete = true
      running = false
    end
  end

  -- Exit after test completes (give it a couple seconds to settle)
  if test_state.test_complete then
    loop_count = loop_count + 1
    if loop_count > 200 then  -- ~2 seconds at 0.01s sleep
      running = false
    end
  end

  -- Small sleep to prevent CPU spinning
  socket.sleep(0.01)
end

cleanup()

-- Exit with appropriate code
if test_state.test_success then
  print("✓ Bluetooth proxy test completed successfully")
  os.exit(0)
else
  print("✗ Bluetooth proxy test failed")
  os.exit(1)
end
