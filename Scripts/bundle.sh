#!/bin/zsh
# Build everything and assemble dist/TaskDeck.app (unsigned local dev bundle).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"

# Swift 6.4 made the Xcode-style build system the default. It compiles
# SwiftTerm's Metal shader, which needs Xcode's separately-downloaded Metal
# toolchain — absent on the CLT-only setups this project supports. Fall back to
# the native build system when that toolchain is missing (it ignores the
# shader, exactly as every build before Swift 6.4 did).
BUILD_ARGS=()
if ! xcrun metal --version > /dev/null 2>&1; then
  BUILD_ARGS+=(--build-system native)
fi
swift build -c "$CONFIG" "${BUILD_ARGS[@]}"

BIN=".build/$CONFIG"
APP="dist/JamesDesk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
[[ -f Support/AppIcon.icns ]] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/TaskDeck" "$APP/Contents/MacOS/TaskDeck"
cp "$BIN/taskdeckd" "$APP/Contents/MacOS/taskdeckd"
cp "$BIN/taskdeckctl" "$APP/Contents/MacOS/taskdeckctl"

codesign --force -s - "$APP/Contents/MacOS/taskdeckd" "$APP/Contents/MacOS/taskdeckctl" >/dev/null 2>&1
codesign --force -s - "$APP" >/dev/null 2>&1

echo "Built $APP ($CONFIG)"
