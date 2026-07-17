# TaskDeck — guide for AI coding agents

macOS task workspace: 1 task = terminals + 1 markdown note. SwiftUI GUI ↔
unix socket ↔ `taskdeckd` (owns every PTY). Public, source-available repo
(PolyForm NC 1.0.0).

@CLAUDE.local.md

## Safety rules (non-negotiable)

- **Never kill `taskdeckd`** (`pkill taskdeckd`, `taskdeckctl shutdown`) on
  your own — it holds every live terminal session the user has. Daemon
  restarts (e.g. protocol changes) must be explicitly approved by the user
  and timed with them.
- **The GUI may be rebuilt/relaunched freely**: `Scripts/dev.sh` (build →
  install → `pkill -x TaskDeck` → relaunch). Sessions live in the daemon;
  this is always safe and is the normal dev loop.
- Protocol (`Sources/TaskDeckCore/Wire.swift`): additive changes only where
  possible; breaking changes bump `Wire.version` and imply a coordinated
  daemon restart.
- **No secrets in the repo — ever.** No API keys, tokens, or personal
  machine config. User config lives in
  `~/Library/Application Support/TaskDeck/` (never commit it). Personal,
  machine-specific notes for agents belong in `CLAUDE.local.md`
  (gitignored), not in this file.

## Build & test

- Swift Package Manager only: `swift build` / `Scripts/bundle.sh`. Do not
  use `xcodebuild` (Command Line Tools setups have no Xcode).
- Swift 5 language mode (tools-version 5.10), macOS 14+, SwiftTerm pinned
  to `1.x`.
- Headless verification via `taskdeckctl` against the running daemon:
  `ping` / `new <task> --cwd /tmp --cmd 'echo hi'` / `tail <paneID> 2` /
  `remove <paneID>`. Clean up panes you created; every other pane in
  `list` belongs to the user — do not touch.

## Conventions

- Code comments in English. Design tokens live in
  `Sources/TaskDeck/Theme.swift` (dark-first).
- **Task notes are free-form user documents.** The only structure the app
  (or you) may maintain is the top session-manifest block: a `- <team>
  <session-id>` list right after the H1, closed by a `---` rule
  (`TaskStore.appendSessionLine`). Never add template sections or reformat
  the rest of a note.
- AI pane resume: uuid is written to the note first, then the session
  starts with `--session-id`; restart uses `-r <uuid> || --session-id
  <uuid>` (single line, resumes or creates). `TeamDef.args` are captured
  into the pane spec at creation so restores start identically.
- `taskdeckctl attach` (Ctrl-] detaches) mirrors a daemon pane onto a real
  tty; the "open in iTerm2" menu item builds on it. Both views share one
  PTY; on resize, last writer wins.
