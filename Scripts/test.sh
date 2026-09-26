#!/bin/sh
# Single test entry point: build + pure-function selftest + isolated-daemon
# integration tests. CLT toolchains have no XCTest, so both suites are plain
# executables. NEVER touches the production daemon/socket/log — itest spawns
# its own taskdeckd on a temp socket.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== swift build =="
# See Scripts/bundle.sh: without Xcode's Metal toolchain the default (Swift 6.4+)
# build system cannot compile SwiftTerm's shader.
BUILD_ARGS=""
if ! xcrun metal --version > /dev/null 2>&1; then
  BUILD_ARGS="--build-system native"
fi
# shellcheck disable=SC2086
swift build --package-path "$ROOT" $BUILD_ARGS

echo "== taskdeck-selftest (pure functions) =="
"$ROOT/.build/debug/taskdeck-selftest"

echo "== taskdeck-itest (isolated daemon integration) =="
"$ROOT/.build/debug/taskdeck-itest"

echo "== ALL TEST SUITES PASS =="
