# TaskDeck

Task-centric terminal + notes workspace for AI coding on macOS.

One **task** = a set of terminals (your AI CLI session, dev servers, helper
scripts) + one markdown note (topic, scratch memos, the next prompt you plan
to send, AI session ids). TaskDeck keeps them paired — across app restarts,
display unplugs and reboots — instead of scattering them over macOS Spaces
and a notes app that can't talk to your terminals.

繁中簡介：一個任務＝一組 terminal＋一篇 markdown 筆記，永遠配對。GUI 重開不影響
terminal（PTY 由常駐 daemon 持有）；重開機後按宣告式設定隨點隨還原，AI 對話用
session id 續上。

## Architecture

```
TaskDeck.app (SwiftUI)  ──unix socket──▶  taskdeckd (owns every PTY)
        │                                       │
        ├── task notes: <tasksDir>/<slug>.md    └── ring-buffer scrollback,
        └── pane specs/layout:                      survives GUI relaunch
            ~/Library/Application Support/TaskDeck/tasks/<slug>.json
```

- **taskdeckd** is spawned on demand and outlives the app. Rebuilding /
  relaunching the GUI never kills your terminals.
- Terminal panes run interactive login zsh; declared commands (AI CLI,
  `yarn dev`, …) are typed into them, so your aliases work.
- AI panes (claude-family) pre-generate a session uuid, record it into the
  note, then start with `--session-id`. Restore = `-r <uuid> || --session-id
  <uuid>` — same line resumes or starts fresh, never hand-copy session ids.
- After a reboot nothing mass-respawns: the task list is instant (plain
  files), terminals restore lazily per task, opt-in `autoStart` per pane.

## Build & run

Requires macOS 14+ and Swift toolchain (Command Line Tools are enough).

```sh
Scripts/bundle.sh          # swift build + assemble dist/TaskDeck.app
open dist/TaskDeck.app
Scripts/dev.sh             # rebuild + relaunch GUI (daemon untouched)
```

Headless smoke test of the daemon:

```sh
dist/TaskDeck.app/Contents/MacOS/taskdeckctl ping
dist/TaskDeck.app/Contents/MacOS/taskdeckctl new demo --cmd 'echo hello'
dist/TaskDeck.app/Contents/MacOS/taskdeckctl tail <paneID> 2
```

## Configuration

`~/Library/Application Support/TaskDeck/config.json`:

```json
{
  "tasksDir": "~/path/to/your/notes/tasks",
  "defaultCwd": "~/code",
  "teams": [
    {"id": "claude", "label": "Claude", "kind": "claude"}
  ],
  "composeSection": "Next prompt",
  "sessionsSection": "AI sessions",
  "quotaCommand": "claude-quota"
}
```

- `tasksDir` — where task notes live. Point it at an Obsidian vault folder to
  get syncing/backup/editing for free.
- `teams` — one entry per AI CLI account/alias. `kind: "claude"` enables
  automatic session-id bookkeeping; anything else is started as-is.
- `quotaCommand` — optional CLI whose output is shown in the quota popover.
- Optional `template.md` next to the config: template for new task notes
  (`{title}` / `{created}` placeholders).

## Status

Early v0.1 — built in the open, expect sharp edges.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free to use, fork and modify for
noncommercial purposes. **Commercial use requires the author's permission**
(open an issue to ask).
