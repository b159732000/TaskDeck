# TaskDeck — AI 開發者說明

macOS 任務工作區 app：1 任務＝多個 terminal＋1 篇 markdown 筆記。SwiftUI GUI ↔ unix socket ↔ `taskdeckd`（持有全部 PTY）。這是 James 的個人開源專案（PolyForm NC），**不是 Meshy 公司 repo**。

## 最重要的安全規則

- **絕不擅自殺 `taskdeckd`**（`pkill taskdeckd`、`taskdeckctl shutdown`、重開機級操作）——它持有使用者所有活著的 terminal session，殺掉＝工作全沒。要重啟 daemon（例如協定改版）必須先跟 James 說明並取得同意、挑他方便的時機。
- **GUI 隨時可以重編譯重啟**：`Scripts/dev.sh`（rebuild ＋ `pkill -x TaskDeck` ＋ relaunch），session 全在 daemon 手上，安全。日常改功能一律走這條路。
- 協定（`Sources/TaskDeckCore/Wire.swift`）盡量**只加欄位不改語意**；破壞性變更要 bump `Wire.version`，並意味著一次 daemon 重啟（見上）。

## 建置

- 本機只有 Command Line Tools（無 Xcode）：用 `swift build` / `Scripts/bundle.sh`，**不要用 xcodebuild**。
- Swift 5 語言模式（tools-version 5.10）、macOS 14+、SwiftTerm 鎖 `1.x`。
- 打包＝`Scripts/bundle.sh` 組 `dist/TaskDeck.app`（ad-hoc 簽名）。

## 無頭測試

GUI 看不到的部分用 `taskdeckctl` 驗：

```sh
dist/TaskDeck.app/Contents/MacOS/taskdeckctl ping
dist/TaskDeck.app/Contents/MacOS/taskdeckctl new smoketest --cwd /tmp --cmd 'echo hello-$RANDOM'
dist/TaskDeck.app/Contents/MacOS/taskdeckctl tail <paneID> 2   # 應看到 echo 輸出
dist/TaskDeck.app/Contents/MacOS/taskdeckctl remove <paneID>   # 測完清掉自己開的 pane
```

只清理自己開的測試 pane；`list` 裡其他 pane 是使用者的，不要動。

## 資料位置（James 的機器）

- 設定：`~/Library/Application Support/TaskDeck/config.json`（**不進版控**；tasksDir 指向 Obsidian vault 的 `tasks/`，路徑含空格注意引號）
- 新任務筆記模板：同目錄 `template.md`
- 每機 pane/layout 狀態：同目錄 `tasks/<slug>.json`
- daemon log：同目錄 `daemon.log`
- 筆記本體在 vault（會走 GitHub 同步）；**絕不 commit 使用者設定或筆記到本 repo**

## 慣例

- 回覆與 UI 文案預設繁體中文；程式碼註解英文。
- AI pane 的 resume 機制（uuid 先寫筆記再 `--session-id` 啟動；`-r || --session-id` 單行兩用）源自 vault 筆記 `decision-260713-tsk-task-envelope` 的實測，改動前先讀它。
- 使用者的三個 Claude 帳號是 zsh alias（`claude` / `claude3` / `claude-eng`，差在 `CLAUDE_CONFIG_DIR`）；pane 是互動 login zsh，alias 展開可用，別改成直接 exec。
- **筆記是自由文本，不套模板欄位**（James 明確要求，2026-07-17）：唯一的結構是頂部 session manifest（H1 後的 `- <team> <uuid>` 清單＋`---` 分隔線，`TaskStore.appendSessionLine` 維護），其餘內容不要動、不要加預設段落。
- 設計 token 統一放 `Sources/TaskDeck/Theme.swift`（深色優先）；額度條吃 `claude-quota --json`（accounts × buckets schema）。
- `taskdeckctl attach`（Ctrl-] 離開）：raw-mode 鏡射 daemon pane，「在 iTerm2 開啟」靠它；兩邊共用同一 PTY，resize 後寫者為準。
