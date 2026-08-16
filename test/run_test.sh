#!/bin/bash
# Run a single test file under the C4 shim, the way `make test` runs the suite.
#
# Usage:
#   ./run_test.sh <test_file> [--timeout <seconds>]
#
# Example:
#   ./run_test.sh test_http_redact.lua

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_FILE=""
TIMEOUT=""

while [[ $# -gt 0 ]]; do
  case $1 in
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
  echo "Usage: $0 <test_file> [--timeout <seconds>]" >&2
  exit 1
fi

# Pick up luarocks-installed modules (e.g. luasocket) if present.
if command -v luarocks &>/dev/null; then
  eval "$(luarocks path --bin 2>/dev/null)"
fi

export LUA_PATH="${SCRIPT_DIR}/?.lua;${PROJECT_ROOT}/src/?.lua;${PROJECT_ROOT}/src/?/init.lua;${PROJECT_ROOT}/vendor/?.lua;${PROJECT_ROOT}/vendor/?/init.lua;${LUA_PATH:-}"

cd "$SCRIPT_DIR" || exit 1
PRELUDE="io.stdout:setvbuf('no'); io.stderr:setvbuf('no'); require('c4_shim')"

if [ -n "$TIMEOUT" ]; then
  timeout "$TIMEOUT" luajit -e "$PRELUDE" "$TEST_FILE"
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "" >&2
    echo "Test timed out after ${TIMEOUT} seconds" >&2
  fi
else
  luajit -e "$PRELUDE" "$TEST_FILE"
  EXIT_CODE=$?
fi

exit $EXIT_CODE
