#!/bin/zsh
# Register the TaskDeck AI-status hook in one or more Claude Code config
# dirs (multi-account setups pass several), additively: existing hooks —
# e.g. AgentBoard's Stop hook — are preserved; re-running is a no-op.
#
#   Scripts/install-ai-status-hooks.sh ~/.claude ~/.claude-team3 ~/.claude-eng
#
# The hook script itself is copied to App Support so registrations don't
# depend on where this repo lives. Each settings.json is backed up first.
# Running Claude sessions keep their startup hook snapshot — badges start
# working for sessions launched afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

SUPPORT="$HOME/Library/Application Support/TaskDeck"
mkdir -p "$SUPPORT"
cp Scripts/taskdeck-ai-status.sh "$SUPPORT/taskdeck-ai-status.sh"
chmod +x "$SUPPORT/taskdeck-ai-status.sh"
HOOK="$SUPPORT/taskdeck-ai-status.sh"

for DIR in "$@"; do
  SETTINGS="$DIR/settings.json"
  if [[ ! -f "$SETTINGS" ]]; then
    echo "skip: $SETTINGS not found"
    continue
  fi
  cp "$SETTINGS" "$SETTINGS.bak-taskdeck-$(date +%y%m%d%H%M%S)"
  /usr/bin/python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, sys

path, hook = sys.argv[1], sys.argv[2]
with open(path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
changed = False
for event in ["UserPromptSubmit", "Stop", "Notification", "SessionEnd"]:
    groups = hooks.setdefault(event, [])
    already = any(
        "taskdeck-ai-status" in (h.get("command") or "")
        for g in groups for h in g.get("hooks", [])
    )
    if already:
        continue
    groups.append({"hooks": [{
        "type": "command",
        "command": f'"{hook}" {event}',
    }]})
    changed = True

if changed:
    with open(path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
print(("updated: " if changed else "already installed: ") + path)
PY
done
