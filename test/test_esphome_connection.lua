#!/usr/bin/env luajit
--- Test script for ESPHome client connection debugging
--- This script uses a shim layer to replace Control4-specific functions
--- allowing you to test ESPHome connectivity outside the Control4 environment

-- Load modules in the same order as driver.lua
require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

-- Load the ESPHome client and logging
local ESPHomeClient = require("esphome.client")
local log = require("lib.logging")

-- Enable verbose logging for debugging
log:setOutputPrintEnabled(true)
log:setLogLevel(6)  -- 6 = ULTRA (show raw protocol data)
log:setLogName("ESPHomeTest")

-- Configuration from environment variables or defaults
local CONFIG = {
  ip_address = os.getenv("ESPHOME_TEST_IP"),
  port = 6053,
  password = os.getenv("ESPHOME_TEST_PASSWORD"),
  encryption_key = os.getenv("ESPHOME_TEST_KEY"),
  use_openssl = false,
}

-- Ensure password and key are nil if empty strings
if CONFIG.password == "" then CONFIG.password = nil end
if CONFIG.encryption_key == "" then CONFIG.encryption_key = nil end

print("=" .. string.rep("=", 70))
print("ESPHome Connection Test")
print("=" .. string.rep("=", 70))
print()
print("Configuration:")
print("  IP Address:     " .. CONFIG.ip_address)
print("  Port:           " .. CONFIG.port)
print("  Password:       " .. (CONFIG.password and "***" or "(none)"))
print("  Encryption Key: " .. (CONFIG.encryption_key and "***" or "(none)"))
print("  Use OpenSSL:    " .. tostring(CONFIG.use_openssl))
print()

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

-- Connect to device
print("Connecting to ESPHome device...")
client:connect()
  :next(function()
    print("✓ Successfully connected and authenticated!")
    print()

    -- Get device information
    print("Fetching device information...")
    return client:getDeviceInfo()
  end, function(err)
    print("✗ Connection failed: " .. tostring(err))
    return nil
  end)
  :next(function(device_info)
    if not device_info then
      return nil
    end

    print("✓ Device Information:")
    print("  Name:              " .. (device_info.name or "N/A"))
    print("  Friendly Name:     " .. (device_info.friendly_name or "N/A"))
    print("  ESPHome Version:   " .. (device_info.esphome_version or "N/A"))
    print("  Compilation Time:  " .. (device_info.compilation_time or "N/A"))
    print("  Model:             " .. (device_info.model or "N/A"))
    print("  MAC Address:       " .. (device_info.mac_address or "N/A"))
    print()

    -- List entities
    print("Listing entities...")
    return client:listEntities()
  end, function(err)
    print("✗ Failed to get device info: " .. tostring(err))
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

    print("✓ Found " .. entity_count .. " entities:")
    print()

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
        local unique_id = entity.unique_id or "N/A"
        print(string.format("    - %s (key: %s, id: %s)", name, key, unique_id))
      end
      print()
    end

    -- Subscribe to state updates
    print("Subscribing to state updates...")
    return client:subscribeStates(function(message, schema)
      print(string.format("[STATE UPDATE] %s: %s",
        schema.name,
        JSON:encode(message)))
    end)
  end, function(err)
    print("✗ Failed to list entities: " .. tostring(err))
    return nil
  end)
  :next(function()
    print("✓ Subscribed to state updates")
    print()
    print("=" .. string.rep("=", 70))
    print("Connection test completed successfully!")
    print("Monitoring state updates... (Press Ctrl+C to exit)")
    print("=" .. string.rep("=", 70))
    print()
  end, function(err)
    if err then
      print("✗ Failed to subscribe to states: " .. tostring(err))
    end
  end)

runEventLoop()