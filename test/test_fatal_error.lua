-- Quick test to verify fatal error propagation
package.path = "../src/?.lua;" .. package.path

require("c4_shim")
local ESPHomeClient = require("esphome.client")

local client = ESPHomeClient:new()
client:setConfig("192.168.2.194", 6053, "wrong_password", nil, false)

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

-- Keep alive
while true do
    C4:ProcessTimers()
end
