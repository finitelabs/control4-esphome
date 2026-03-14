-- Quick test to verify fatal error propagation
require("lib.utils")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local ESPHomeClient = require("esphome.client")

-- Configuration from environment variables
local ip = os.getenv("ESPHOME_TEST_IP")
if not ip or ip == "" then
  print("Error: --ip is required")
  os.exit(1)
end

local client = ESPHomeClient:new()
client:setConfig(ip, 6053, "wrong_password", nil, false)

print("\n=== Testing Fatal Error Propagation ===\n")

client:connect():next(function()
  print("✓ Connection established (auth request sent)")

  -- Small delay to let AuthenticationResponse arrive
  C4:SetTimer(100, function()
    print("\nNow trying to send DeviceInfoRequest (should fail with 'Invalid password')...\n")

    client:getDeviceInfo():next(function(info)
      print("✗ UNEXPECTED: DeviceInfo succeeded:", info)
      os.exit(1)
    end, function(err)
      print("✓ DeviceInfo correctly rejected with:", err)
      if err == "Invalid password" then
        print("✓ Fatal error propagation working correctly!")
        client:disconnect()
        os.exit(0)
      else
        print("✗ Wrong error message!")
        client:disconnect()
        os.exit(1)
      end
    end)
  end)
end, function(err)
  print("✗ Connection failed:", err)
  os.exit(1)
end)

runEventLoop()