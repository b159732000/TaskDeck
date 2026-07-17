#!/bin/zsh
# Dev loop: rebuild + reinstall + relaunch the GUI only.
# taskdeckd (and every live terminal session) is untouched — restarting the
# GUI is always safe.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/bundle.sh "${1:-debug}"

DEST="/Applications/TaskDeck.app"
if [[ ! -w "/Applications" ]]; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/TaskDeck.app"
fi
rm -rf "$DEST"
ditto dist/TaskDeck.app "$DEST"

# Graceful quit first: it runs the app's exit flush (pending note edits),
# unlike pkill's SIGTERM. Fall back to pkill only if the app hangs.
# (AppleScript resolves by CFBundleName — "JamesDesk" since the display
# rename; keep the old name as fallback for stale installs.)
if pgrep -x TaskDeck > /dev/null; then
  osascript -e 'tell application "JamesDesk" to quit' >/dev/null 2>&1 \
    || osascript -e 'tell application "TaskDeck" to quit' >/dev/null 2>&1 &
  for _ in {1..10}; do
    pgrep -x TaskDeck > /dev/null || break
    sleep 0.2
  done
  pkill -x TaskDeck 2>/dev/null || true
fi
sleep 0.2
open "$DEST"
echo "Relaunched $DEST"
