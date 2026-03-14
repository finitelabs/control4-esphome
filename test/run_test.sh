#!/bin/bash
# Wrapper script to run ESPHome tests with proper environment
#
# Usage:
#   ./run_test.sh <test_file> [options]
#   ./run_test.sh <test_file> --ip <ip> [--password <pwd> | --key <encryption_key>] [--timeout <seconds>]
#
# Examples:
#   ./run_test.sh test_fatal_error.lua --ip 192.168.1.100
#   ./run_test.sh test_esphome_connection.lua --ip 192.168.1.100 --password MyPassword
#   ./run_test.sh test_esphome_connection.lua --ip 192.168.1.100 --key BASE64_ENCRYPTION_KEY --timeout 10

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
TEST_FILE=""
IP_ADDRESS=""
PASSWORD=""
ENCRYPTION_KEY=""
TIMEOUT=5

while [[ $# -gt 0 ]]; do
  case $1 in
    --ip)
      IP_ADDRESS="$2"
      shift 2
      ;;
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
      if [ -z "$TEST_FILE" ]; then
        TEST_FILE="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$TEST_FILE" ]; then
  echo "Error: test file is required"
  echo ""
  echo "Usage: $0 <test_file> [--ip <ip>] [--password <pwd> | --key <key>] [--timeout <seconds>]"
  echo ""
  echo "Examples:"
  echo "  $0 test_fatal_error.lua --ip 192.168.1.100"
  echo "  $0 test_esphome_connection.lua --ip 192.168.1.100 --password MyPassword"
  exit 1
fi

# Add luarocks paths first if available (sets LUA_PATH/LUA_CPATH)
if command -v luarocks &> /dev/null; then
  eval $(luarocks path --bin 2>/dev/null)
fi

# Prepend project source, vendor, and test shim paths
export LUA_PATH="${SCRIPT_DIR}/?.lua;${PROJECT_ROOT}/src/?.lua;${PROJECT_ROOT}/src/?/init.lua;${PROJECT_ROOT}/vendor/?.lua;${PROJECT_ROOT}/vendor/?/init.lua;${LUA_PATH:-}"

# Export config as environment variables for the Lua scripts
export ESPHOME_TEST_IP="$IP_ADDRESS"
export ESPHOME_TEST_PASSWORD="$PASSWORD"
export ESPHOME_TEST_KEY="$ENCRYPTION_KEY"

# Run the test with LuaJIT, loading the C4 shim before the test file
cd "$SCRIPT_DIR"
timeout ${TIMEOUT} luajit -e "io.stdout:setvbuf('no'); io.stderr:setvbuf('no'); require('c4_shim')" "$TEST_FILE"

EXIT_CODE=$?
if [ $EXIT_CODE -eq 124 ]; then
  echo ""
  echo "Test timed out after ${TIMEOUT} seconds"
fi

exit $EXIT_CODE