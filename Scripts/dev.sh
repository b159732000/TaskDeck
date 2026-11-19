#!/bin/zsh
# Dev loop: rebuild + reinstall + relaunch the GUI only.
# taskdeckd (and every live terminal session) is untouched — restarting the
# GUI is always safe.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/bundle.sh "${1:-debug}"

DEST="/Applications/JamesDesk.app"
if [[ ! -w "/Applications" ]]; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/JamesDesk.app"
fi
rm -rf "$DEST"
ditto dist/JamesDesk.app "$DEST"

# The running GUI, found with ps — NOT pgrep/pkill: on macOS 27 they skip a
# process whose executable was replaced on disk, which is exactly the old
# GUI right after the ditto above. (2026-11-19: dev.sh then quit nothing,
# `open` just raised the old window, and it still printed "Relaunched".)
gui_pids() {
  ps -axo pid=,comm= | awk '{ pid = $1; $1 = ""; sub(/^ +/, "")
                              n = split($0, part, "/"); if (part[n] == "TaskDeck") print pid }'
}
OLD_PIDS=($(gui_pids))

# Graceful quit first: it runs the app's exit flush (pending note edits),
# unlike a plain SIGTERM. Fall back to kill only if the app hangs.
# (AppleScript resolves by CFBundleName — "JamesDesk" since the display
# rename; keep the old name as fallback for stale installs.)
if (( ${#OLD_PIDS} )); then
  osascript -e 'tell application "JamesDesk" to quit' >/dev/null 2>&1 \
    || osascript -e 'tell application "TaskDeck" to quit' >/dev/null 2>&1 &
  for _ in {1..10}; do
    alive=0
    for p in $OLD_PIDS; do kill -0 "$p" 2>/dev/null && alive=1; done
    (( alive )) || break
    sleep 0.2
  done
  for p in $OLD_PIDS; do kill "$p" 2>/dev/null || true; done
fi
sleep 0.2
# TASKDECK_OPEN_BACKGROUND=1 relaunches without taking focus — for unattended
# installs while the user is typing in another app.
if [[ "${TASKDECK_OPEN_BACKGROUND:-}" == 1 ]]; then
  open -g "$DEST"
else
  open "$DEST"
fi
# Say so only once a NEW GUI process runs: `open` on a still-running app
# just raises it, and the build would silently not be live.
for _ in {1..25}; do
  for p in $(gui_pids); do
    if (( ${OLD_PIDS[(Ie)$p]} == 0 )); then
      echo "Relaunched $DEST (pid $p)"
      exit 0
    fi
  done
  sleep 0.2
done
echo "WARNING: no new JamesDesk process after relaunch — the new build is NOT running (old pid(s): ${OLD_PIDS[*]:-none})" >&2
exit 1
