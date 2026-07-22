#!/bin/sh
# Single test entry point: build + pure-function selftest + isolated-daemon
# integration tests. CLT toolchains have no XCTest, so both suites are plain
# executables. NEVER touches the production daemon/socket/log — itest spawns
# its own taskdeckd on a temp socket.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== swift build =="
swift build --package-path "$ROOT"

echo "== taskdeck-selftest (pure functions) =="
"$ROOT/.build/debug/taskdeck-selftest"

echo "== taskdeck-itest (isolated daemon integration) =="
"$ROOT/.build/debug/taskdeck-itest"

echo "== ALL TEST SUITES PASS =="
