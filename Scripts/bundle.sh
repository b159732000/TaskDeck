#!/bin/zsh
# Build everything and assemble dist/TaskDeck.app (unsigned local dev bundle).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG"
APP="dist/TaskDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/TaskDeck" "$APP/Contents/MacOS/TaskDeck"
cp "$BIN/taskdeckd" "$APP/Contents/MacOS/taskdeckd"
cp "$BIN/taskdeckctl" "$APP/Contents/MacOS/taskdeckctl"

codesign --force -s - "$APP/Contents/MacOS/taskdeckd" "$APP/Contents/MacOS/taskdeckctl" >/dev/null 2>&1
codesign --force -s - "$APP" >/dev/null 2>&1

echo "Built $APP ($CONFIG)"
