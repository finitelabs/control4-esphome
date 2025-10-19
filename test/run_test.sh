#!/bin/bash
# Wrapper script to run ESPHome tests with proper environment
#
# Usage:
#   ./run_test.sh <ip> [--password <pwd> | --key <encryption_key>] [--timeout <seconds>]
#
# Examples:
#   ./run_test.sh 192.168.2.44 --password U6j4sO7HG3RmU3
#   ./run_test.sh 192.168.2.43 --key ViJ/SSZtc/EWqDPb5Z/UHwCzjT5Hv3iU0VloagpXYnw=
#   ./run_test.sh 192.168.2.43 --key ViJ/SSZtc/EWqDPb5Z/UHwCzjT5Hv3iU0VloagpXYnw= --timeout 10

# Set up LuaRocks paths for local installation
eval $(luarocks path --bin)

# Parse arguments
IP_ADDRESS=""
PASSWORD=""
ENCRYPTION_KEY=""
TIMEOUT=5

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
  echo "Usage: $0 <ip> [--password <pwd> | --key <encryption_key>] [--timeout <seconds>]"
  echo ""
  echo "Examples:"
  echo "  $0 192.168.2.44 --password U6j4sO7HG3RmU3"
  echo "  $0 192.168.2.43 --key ViJ/SSZtc/EWqDPb5Z/UHwCzjT5Hv3iU0VloagpXYnw="
  exit 1
fi

# Set up Lua paths for local luarocks installation
export LUA_PATH="$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua;$LUA_PATH"
export LUA_CPATH="$HOME/.luarocks/lib/lua/5.1/?.so;$LUA_CPATH"

# Export config as environment variables for the Lua script
export ESPHOME_TEST_IP="$IP_ADDRESS"
export ESPHOME_TEST_PASSWORD="$PASSWORD"
export ESPHOME_TEST_KEY="$ENCRYPTION_KEY"

# Run the test with LuaJIT (which has luasocket installed)
# Use unbuffered output and timeout
timeout ${TIMEOUT} luajit -e "io.stdout:setvbuf('no'); io.stderr:setvbuf('no')" test_esphome_connection.lua

# Check exit code
EXIT_CODE=$?
if [ $EXIT_CODE -eq 124 ]; then
  echo ""
  echo "Test timed out after ${TIMEOUT} seconds"
fi

exit $EXIT_CODE