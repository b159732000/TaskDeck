#!/bin/sh
# Claude Code hook → TaskDeck AI status badge.
# Registered (by install-ai-status-hooks.sh) for UserPromptSubmit / Stop /
# Notification / SessionEnd / PreToolUse, plus SessionStart (pane → session
# map only; prints nothing, so it adds no context to the conversation);
# reads the hook payload on stdin and writes
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

# Which session is THIS terminal running? taskdeckd tags every pane with
# TASKDECK_PANE (its spec id); Claude hands its environment to hooks. Kept
# in pane-sessions/<pane>.json — last session wins — for the pane menu's
# 記到 AI Session 紀錄. Rewritten only when the pane's session changes
# (SessionStart covers a fresh claude, /clear and /resume before any prompt),
# so busy PreToolUse traffic costs one small read. Never fatal.
pane = os.environ.get("TASKDECK_PANE") or ""
if pane and "/" not in pane and not pane.startswith("."):
    try:
        pane_dir = os.path.join(os.path.dirname(out_dir), "pane-sessions")
        os.makedirs(pane_dir, exist_ok=True)
        pane_out = os.path.join(pane_dir, pane + ".json")
        try:
            with open(pane_out) as f:
                pane_prev = json.load(f).get("session_id")
        except Exception:
            pane_prev = None
        if pane_prev != sid:
            config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or ""
            pane_tmp = os.path.join(pane_dir, "." + pane + ".json.tmp")
            with open(pane_tmp, "w") as f:
                json.dump({"session_id": sid, "config_dir": config_dir,
                           "ts": time.time(), "event": event}, f)
            os.replace(pane_tmp, pane_out)
    except Exception:
        pass

state = {
    "UserPromptSubmit": "running",
    "PreToolUse": "running",
    "Stop": "waiting",
    "SessionEnd": "ended",
}.get(event)
notification_type = None
if event == "Notification":
    msg = (payload.get("message") or "").lower()
    notification_type = payload.get("notification_type")
    permission = "permission" in msg or notification_type == "permission_prompt"
    state = "permission" if permission else "waiting"
if not state:
    sys.exit(0)

out = f"{out_dir}/{sid}.json"
try:
    with open(out) as f:
        existing = json.load(f)
except Exception:
    existing = {}
prev_state = existing.get("state")
prev_ts = existing.get("ts")

# PreToolUse fires on EVERY tool call — it exists to keep long turns visibly
# "running" past the 30-min freshness window. Skip the rewrite when the file
# is already a fresh "running" (<60s), so busy turns don't churn writes.
if event == "PreToolUse" and prev_state == "running":
    try:
        if time.time() - os.stat(out).st_mtime < 60:
            sys.exit(0)
    except Exception:
        pass

# `ts` means "when the AI last produced something you may need to look at".
# The GUI's 已讀 (acknowledged) mark is a comparison against it, so a rewrite
# that carries NO new output must keep the previous ts — a fresh stamp would
# silently re-open a review debt the user already paid. Two events do that:
#   • SessionEnd after an idle state: the terminal closed or taskdeckd died;
#     nothing new was said. (Every session ending in the same second after a
#     daemon restart used to flip every 已讀 task back to 等你 at once.) A
#     session killed while "running" was cut off mid-turn — that IS worth a
#     look, so it keeps getting a fresh stamp.
#   • Notification "waiting" (idle prompt) while already waiting: the same
#     idle period announced again. A permission prompt is new — fresh stamp.
ts = time.time()
if isinstance(prev_ts, (int, float)):
    if event == "SessionEnd" and prev_state in ("waiting", "permission", "ended"):
        ts = prev_ts
    elif event == "Notification" and state == "waiting" and prev_state in ("waiting", "ended"):
        ts = prev_ts

# Atomic tmp+rename, NOT an in-place rewrite: the GUI watches the directory
# with kqueue, which only fires on create/delete/RENAME — truncating the
# existing file in place updates silently and the sidebar goes stale.
rec = {"session_id": sid, "state": state, "ts": ts}
# Diagnostics only (the GUI ignores them): why a session ended, and which
# notification produced a waiting/permission state.
if event == "SessionEnd" and payload.get("reason"):
    rec["reason"] = payload["reason"]
if notification_type:
    rec["notification_type"] = notification_type
# The pane (via taskdeckd) exports TASKDECK_TASK (slug — stale after rename)
# and TASKDECK_TASK_KEY (permanent note uuid — rename-proof); record both so
# the app can attribute this session to its task no matter how it started.
task = os.environ.get("TASKDECK_TASK")
if task:
    rec["task"] = task
task_key = os.environ.get("TASKDECK_TASK_KEY")
if task_key:
    rec["task_key"] = task_key
# Claude includes the append-only conversation record in every hook payload.
# The GUI tails it off-main to count native background tasks without scraping
# terminal pixels or walking the pane's process tree.
transcript_path = payload.get("transcript_path")
if isinstance(transcript_path, str) and transcript_path:
    rec["transcript_path"] = transcript_path
tmp = f"{out_dir}/.{sid}.json.tmp"
with open(tmp, "w") as f:
    json.dump(rec, f)
os.replace(tmp, out)
PY
exit 0
