# TaskDeck

Task-centric terminal + notes workspace for AI coding on macOS.

One **task** = a set of terminals (your AI CLI session, dev servers, helper
scripts) + one markdown note (topic, scratch memos, AI session ids).
TaskDeck keeps them paired — across app restarts, display unplugs and
reboots — instead of scattering them over macOS Spaces and a notes app that
can't talk to your terminals.

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
- Panes run your **interactive login shell** (configurable, default
  `/bin/zsh`), so your rc files and aliases load — that's what makes
  alias-based multi-account setups work (see below).
- AI panes (`kind: "claude"` teams) pre-generate a session uuid, record it
  at the top of the note (a `- <team> <uuid>` list closed by a `---` rule;
  everything below is free-form), then start with `--session-id`. Restore
  runs `-r <uuid> || --session-id <uuid>` — the same line resumes or starts
  fresh; you never hand-copy session ids.
- After a reboot nothing mass-respawns: the task list is instant (plain
  files), terminals restore lazily per task, opt-in `autoStart` per pane.
- Any pane can be mirrored into a real terminal (`taskdeckctl attach`,
  Ctrl-] detaches) — the "open in iTerm2" menu item is built on this.

## Build & run

Requires macOS 14+ and a Swift toolchain (Command Line Tools are enough —
no Xcode needed).

```sh
Scripts/bundle.sh    # swift build + assemble dist/TaskDeck.app
Scripts/dev.sh       # bundle + install to /Applications + relaunch GUI
                     # (the daemon and your sessions are never touched)
```

Headless smoke test of the daemon:

```sh
CTL="/Applications/TaskDeck.app/Contents/MacOS/taskdeckctl"
"$CTL" ping
"$CTL" new demo --cmd 'echo hello'
"$CTL" tail <paneID> 2
"$CTL" attach <paneID>    # interactive mirror; Ctrl-] detaches
```

## Configuration reference

Everything user-specific lives **outside the repo** in
`~/Library/Application Support/TaskDeck/`:

| File | Purpose |
|---|---|
| `config.json` | main config (created with defaults on first launch) |
| `template.md` | optional template for new task notes (`{title}` / `{created}` placeholders) |
| `tasks/<slug>.json` | per-machine pane specs & layout (managed by the app) |
| `daemon.log` | daemon log |

`config.json` fields:

| Field | Default | Meaning |
|---|---|---|
| `tasksDir` | `~/Documents/TaskDeck/tasks` | where task notes (`<slug>.md`) live. Point it at a folder inside an Obsidian vault to get sync/backup/editing for free. |
| `defaultCwd` | `~` | working directory for new panes |
| `shell` | `/bin/zsh` | login shell for every pane (spawned `-il`); zsh/bash/fish all work |
| `terminalFont` | auto | terminal font name. Unset: installed Nerd Fonts are probed (MesloLGS NF first), then the system mono font. Powerline/PUA prompt glyphs **require** a Nerd Font — there is no system fallback for private-use glyphs. |
| `terminalFontSize` | 13 | terminal font size |
| `teams` | one `claude` entry | one entry per AI CLI account — see below |
| `quotaCommand` | none | CLI printing the quota JSON for the bottom bar — see below |

Each `teams[]` entry:

| Field | Meaning |
|---|---|
| `id` | the command typed into the pane — a binary on PATH **or a shell alias/function** (panes are interactive shells, so aliases resolve) |
| `label` | display name in the "new terminal" menu |
| `kind` | `"claude"` = Claude Code CLI semantics (`--session-id` / `-r` bookkeeping, auto-recorded into the note). `"other"` = started as-is, no session bookkeeping. |
| `args` | optional extra CLI args appended at session start, e.g. `"--dangerously-skip-permissions"`. Captured into the pane spec at creation, so restores start identically. |

### Example: multiple accounts of the same CLI

Run several Claude Code accounts side by side by giving each a config dir
via a shell alias (in your `~/.zshrc`):

```sh
alias claude2='CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude'
```

```json
{
  "teams": [
    { "id": "claude",  "label": "Claude (personal)", "kind": "claude" },
    { "id": "claude2", "label": "Claude (work)",     "kind": "claude",
      "args": "--dangerously-skip-permissions" }
  ]
}
```

Each team gets its own session-id bookkeeping; when one account hits its
quota, start a pane on another team in the same task and keep going.
(Sessions don't transfer across accounts — the note carries the context.)

### Quota bar contract

`quotaCommand` can be any executable that prints this JSON shape (add
`--json` handling yourself if you wrap an existing tool):

```json
{
  "accounts": [
    {
      "alias": "claude",
      "buckets": {
        "5h session": { "percent": 50, "resets_at": "2026-07-17T12:39:59Z" },
        "weekly all": { "percent": 32, "resets_at": null, "detail": "optional text" }
      }
    }
  ]
}
```

`percent` drives the mini bars (color-coded at 60/85), `resets_at`
(ISO 8601) and `detail` show in tooltips and the ⓘ popover. The bar runs
`<quotaCommand> --json` via your login shell every 5 minutes. Omit
`quotaCommand` to hide the bar's content entirely.

## Data & privacy

- TaskDeck talks to nothing but your local daemon and the CLIs you
  configure. No telemetry, no network calls of its own.
- **No secrets belong in this repo** — credentials, tokens and personal
  machine config stay in `~/Library/Application Support/TaskDeck/` and your
  own shell environment. PRs adding keys or personal config will be
  rejected.

## Forking / hacking guide

| Where | What |
|---|---|
| `Sources/TaskDeckCore/Wire.swift` | socket protocol (length-prefixed JSON frames). Keep changes additive; bump `Wire.version` on breaking changes — a daemon restart kills live sessions. |
| `Sources/TaskDeckCore/TaskStore.swift` | notes scan/frontmatter, session manifest block, pane specs & layout tree |
| `Sources/taskdeckd/` | the PTY daemon (forkpty, ring buffers, subscriptions) |
| `Sources/taskdeckctl/` | headless client (`list/new/type/tail/attach/...`) — also the best way to test daemon changes |
| `Sources/TaskDeck/` | SwiftUI app; design tokens in `Theme.swift` |

Ground rules that keep the tool trustworthy (see `CLAUDE.md`, which AI
coding agents pick up automatically):

- Never kill `taskdeckd` casually — it holds the user's live terminals.
  GUI relaunches are always safe; that separation is the core design.
- Notes are the user's free-form documents: the only structure the app may
  touch is the top session-manifest block.

## Status

Early v0.1 — built in the open, expect sharp edges.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free to use, fork and modify
for noncommercial purposes. **Commercial use requires the author's
permission** (open an issue to ask).
