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
    "PreToolUse": "running",
    "Stop": "waiting",
    "SessionEnd": "ended",
}.get(event)
if event == "Notification":
    msg = (payload.get("message") or "").lower()
    state = "permission" if "permission" in msg else "waiting"
if not state:
    sys.exit(0)

# PreToolUse fires on EVERY tool call — it exists to keep long turns visibly
# "running" past the 30-min freshness window. Skip the rewrite when the file
# is already a fresh "running" (<60s), so busy turns don't churn writes.
if event == "PreToolUse":
    try:
        out = f"{out_dir}/{sid}.json"
        if time.time() - os.stat(out).st_mtime < 60:
            with open(out) as f:
                if json.load(f).get("state") == "running":
                    sys.exit(0)
    except Exception:
        pass

# Atomic tmp+rename, NOT an in-place rewrite: the GUI watches the directory
# with kqueue, which only fires on create/delete/RENAME — truncating the
# existing file in place updates silently and the sidebar goes stale.
rec = {"session_id": sid, "state": state, "ts": time.time()}
# The pane (via taskdeckd) exports TASKDECK_TASK (slug — stale after rename)
# and TASKDECK_TASK_KEY (permanent note uuid — rename-proof); record both so
# the app can attribute this session to its task no matter how it started.
task = os.environ.get("TASKDECK_TASK")
if task:
    rec["task"] = task
task_key = os.environ.get("TASKDECK_TASK_KEY")
if task_key:
    rec["task_key"] = task_key
tmp = f"{out_dir}/.{sid}.json.tmp"
with open(tmp, "w") as f:
    json.dump(rec, f)
os.replace(tmp, f"{out_dir}/{sid}.json")
PY
exit 0
