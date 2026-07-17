#!/bin/sh
# Claude Code hook → TaskDeck AI status badge.
# Registered (by install-ai-status-hooks.sh) for UserPromptSubmit / Stop /
# Notification / SessionEnd; reads the hook payload on stdin and writes
#   ~/Library/Application Support/TaskDeck/status/<session-id>.json
# which the GUI watches to light 🟢 (running) / 🟡 (waiting) / 🔴 (needs
# permission) on the task row. Exit 0 always — a status badge must never
# block or fail the AI session.
EVENT="$1"
DIR="$HOME/Library/Application Support/TaskDeck/status"
mkdir -p "$DIR" 2>/dev/null

# `python3 -` would take its PROGRAM from stdin — the payload must be
# captured first and handed over out-of-band.
TASKDECK_HOOK_PAYLOAD="$(cat)"
export TASKDECK_HOOK_PAYLOAD

/usr/bin/python3 - "$EVENT" "$DIR" <<'PY' 2>/dev/null
import json, os, sys, time

event, out_dir = sys.argv[1], sys.argv[2]
try:
    payload = json.loads(os.environ.get("TASKDECK_HOOK_PAYLOAD") or "{}")
except Exception:
    sys.exit(0)
sid = payload.get("session_id")
if not sid or "/" in sid:
    sys.exit(0)

state = {
    "UserPromptSubmit": "running",
    "Stop": "waiting",
    "SessionEnd": "ended",
}.get(event)
if event == "Notification":
    msg = (payload.get("message") or "").lower()
    state = "permission" if "permission" in msg else "waiting"
if not state:
    sys.exit(0)

with open(f"{out_dir}/{sid}.json", "w") as f:
    json.dump({"session_id": sid, "state": state, "ts": time.time()}, f)
PY
exit 0
