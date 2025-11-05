#!/bin/bash
# Wrapper script to run ESPHome tests with proper environment
#
# Usage:
#   ./run_test.sh [test_file] <ip> [--password <pwd> | --key <encryption_key>] [--bluetooth-mac <mac>] [--timeout <seconds>]
#
# Arguments:
#   test_file              Optional test file to run (defaults to test_esphome_connection.lua)
#                          Available tests:
#                            - test_esphome_connection.lua  (default)
#                            - test_bluetooth_proxy.lua     (requires --bluetooth-mac)
#                            - test_fatal_error.lua
#
# Examples:
#   ./run_test.sh 192.168.2.44 --password U6j4sO7HG3RmU3
#   ./run_test.sh test_bluetooth_proxy.lua 192.168.2.43 --key ViJ/SSZtc/EWqDPb5Z/UHwCzjT5Hv3iU0VloagpXYnw= --bluetooth-mac AA:BB:CC:DD:EE:FF
#   ./run_test.sh test_fatal_error.lua 192.168.2.44 --password wrong_password

# Set up LuaRocks paths for local installation
eval $(luarocks path --bin)

# Parse arguments
TEST_FILE="test_esphome_connection.lua"  # default
IP_ADDRESS=""
PASSWORD=""
ENCRYPTION_KEY=""
BLUETOOTH_MAC=""
TIMEOUT=30

# First argument could be test file or IP
if [[ $# -gt 0 ]]; then
  # Check if first argument looks like a test file
  if [[ "$1" == test_*.lua ]] || [[ "$1" == *.lua ]]; then
    TEST_FILE="$1"
    shift
  fi
fi

# Parse remaining arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --password)
      PASSWORD="$2"
      shift 2
      ;;
    --key)
      ENCRYPTION_KEY="$2"
      shift 2
      ;;
    --bluetooth-mac)
      BLUETOOTH_MAC="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    *)
      if [ -z "$IP_ADDRESS" ]; then
        IP_ADDRESS="$1"
      fi
      shift
      ;;
  esac
done

# Validate IP address is provided
if [ -z "$IP_ADDRESS" ]; then
  echo "Error: IP address is required"
  echo ""
  echo "Usage: $0 [test_file] <ip> [--password <pwd> | --key <encryption_key>] [--bluetooth-mac <mac>] [--timeout <seconds>]"
  echo ""
  echo "Available tests:"
  echo "  - test_esphome_connection.lua (default) - Test basic ESPHome connection"
  echo "  - test_bluetooth_proxy.lua              - Test Bluetooth proxy (requires --bluetooth-mac)"
  echo "  - test_fatal_error.lua                  - Test error handling"
  echo ""
  echo "Examples:"
  echo "  $0 192.168.2.44 --password U6j4sO7HG3RmU3"
  echo "  $0 test_bluetooth_proxy.lua 192.168.2.43 --key KEY --bluetooth-mac AA:BB:CC:DD:EE:FF"
  exit 1
fi

# Validate test file exists
if [ ! -f "$TEST_FILE" ]; then
  echo "Error: Test file not found: $TEST_FILE"
  echo ""
  echo "Available test files:"
  ls -1 test_*.lua 2>/dev/null | sed 's/^/  - /'
  exit 1
fi

# Validate Bluetooth MAC if running Bluetooth test
if [[ "$TEST_FILE" == *"bluetooth"* ]] && [ -z "$BLUETOOTH_MAC" ]; then
  echo "Error: --bluetooth-mac is required for Bluetooth tests"
  echo ""
  echo "Example:"
  echo "  $0 $TEST_FILE $IP_ADDRESS --bluetooth-mac AA:BB:CC:DD:EE:FF"
  exit 1
fi

# Set up Lua paths for local luarocks installation
export LUA_PATH="$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua;$LUA_PATH"
export LUA_CPATH="$HOME/.luarocks/lib/lua/5.1/?.so;$LUA_CPATH"

# Export config as environment variables for the Lua script
export ESPHOME_TEST_IP="$IP_ADDRESS"
export ESPHOME_TEST_PASSWORD="$PASSWORD"
export ESPHOME_TEST_KEY="$ENCRYPTION_KEY"
export ESPHOME_TEST_BT_MAC="$BLUETOOTH_MAC"

echo "Running test: $TEST_FILE"
echo "============================================================"
echo ""

# Run the test with LuaJIT (which has luasocket installed)
# Use unbuffered output and timeout
timeout ${TIMEOUT} luajit -e "io.stdout:setvbuf('no'); io.stderr:setvbuf('no')" "$TEST_FILE"

# Check exit code
EXIT_CODE=$?
if [ $EXIT_CODE -eq 124 ]; then
  echo ""
  echo "Test timed out after ${TIMEOUT} seconds"
fi

exit $EXIT_CODE
