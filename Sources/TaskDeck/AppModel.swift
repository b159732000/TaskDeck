import AppKit
import Foundation
import SwiftUI
import TaskDeckCore

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [TaskNote] = []
    @Published var selection: String?
    /// specID → live pane info (across all tasks).
    @Published var paneRuntime: [String: PaneInfo] = [:]
    @Published var daemonOK = false
    /// Raw CLI table output (ANSI codes included) from `quotaCommand`.
    /// One shared fetcher for the whole app — the quota tool rate-limits,
    /// so per-task/per-window fetching would be wrong.
    @Published var quotaText = ""
    @Published var quotaUpdatedAt: Date?
    @Published var quotaBusy = false
    /// Last refresh failed; `quotaText` still shows the previous good table.
    @Published var quotaStale = false

    let config: AppConfig
    let store: TaskStore
    let client = DaemonClient()
    let hasITerm2 = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")

    /// App-wide content zoom (⌘+/⌘-/⌘0). Scales terminal/notes/quota text.
    @Published var uiScale: Double {
        didSet { UserDefaults.standard.set(uiScale, forKey: "uiScale") }
    }

    var terminalFont: NSFont { Self.resolveTerminalFont(config, scale: uiScale) }

    /// Manual sidebar ordering (drag to reorder); slugs, persisted per machine.
    @Published var taskOrder: [String] = []

    private var sessions: [String: TaskSession] = [:]
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var quotaTimer: Timer?
    private var statusTimer: Timer?

    /// AI session states from the Claude Code hook script
    /// (`Scripts/taskdeck-ai-status.sh` → `Paths.statusDir/<session>.json`):
    /// sessionID → (running | waiting | permission | ended, written-at).
    @Published var aiStatus: [String: (state: String, ts: Date)] = [:]
    /// "已看過"：sessionID → the status timestamp the user acknowledged by
    /// clicking the badge. Entries at or before this ts stop showing; the
    /// next state change (newer ts) lights the badge again.
    @Published var ackedAI: [String: Date] = [:] {
        didSet {
            let raw = ackedAI.mapValues { $0.timeIntervalSince1970 }
            UserDefaults.standard.set(raw, forKey: "ackedAI")
        }
    }

    private var statusWatcher: DispatchSourceFileSystemObject?
    private var statusFD: Int32 = -1

    init() {
        config = AppConfig.load()
        store = TaskStore(dir: config.tasksDirURL)
        let storedScale = UserDefaults.standard.double(forKey: "uiScale")
        uiScale = storedScale == 0 ? 1.0 : min(1.6, max(0.7, storedScale))
        taskOrder = (try? JSONDecoder().decode([String].self,
                                               from: Data(contentsOf: Self.orderFile))) ?? []
        if let raw = UserDefaults.standard.dictionary(forKey: "ackedAI") as? [String: Double] {
            ackedAI = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        rescan()

        client.onEvent = { [weak self] m in
            Task { @MainActor in self?.handleEvent(m) }
        }
        client.onDisconnect = { [weak self] in
            Task { @MainActor in self?.daemonOK = false }
        }

        Task { @MainActor in
            self.daemonOK = await self.client.connectOrSpawn()
            if self.daemonOK { self.refreshPaneList() }
            if self.selection == nil {
                self.selection = self.tasks.first(where: { $0.status == "active" })?.id
            }
            self.refreshQuota()
        }

        watchTasksDir()
        watchStatusDir()
        reloadAIStatus()

        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota() }
        }

        // Belt-and-suspenders for AI status: the dir watcher only fires on
        // create/delete/rename, and time-based grouping rules (running
        // freshness, sink thresholds) need periodic recomputation anyway.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadAIStatus() }
        }
    }

    /// Parsed `config.ansiColors` (16 × "#RRGGBB") or nil to keep defaults.
    var ansiPalette: [(UInt8, UInt8, UInt8)]? {
        guard let hexes = config.ansiColors, hexes.count == 16 else { return nil }
        var out: [(UInt8, UInt8, UInt8)] = []
        for h in hexes {
            let s = h.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            out.append((UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)))
        }
        return out
    }

    func zoomIn() { uiScale = min(1.6, ((uiScale + 0.1) * 10).rounded() / 10) }
    func zoomOut() { uiScale = max(0.7, ((uiScale - 0.1) * 10).rounded() / 10) }
    func zoomReset() { uiScale = 1.0 }

    /// Prompt glyphs (powerline / Nerd Font private-use area) have NO system
    /// font fallback — without a Nerd Font they render as "?". Probe the
    /// configured font, then common Nerd Fonts, then give up gracefully.
    static func resolveTerminalFont(_ config: AppConfig, scale: Double = 1.0) -> NSFont {
        let size = CGFloat(config.terminalFontSize ?? 13) * CGFloat(scale)
        var names: [String] = []
        if let f = config.terminalFont { names.append(f) }
        names += ["MesloLGS NF", "MesloLGS Nerd Font Mono", "JetBrainsMono Nerd Font Mono",
                  "Hack Nerd Font Mono", "FiraCode Nerd Font Mono"]
        for n in names {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func session(_ slug: String) -> TaskSession {
        if let s = sessions[slug] { return s }
        let s = TaskSession(slug: slug, app: self)
        sessions[slug] = s
        return s
    }

    private func handleEvent(_ m: WireMessage) {
        switch m.type {
        case "paneExited":
            if let info = m.panes?.first { paneRuntime[info.specID] = info }
        default:
            break
        }
    }

    func reconnectDaemon() {
        Task { @MainActor in
            self.daemonOK = await self.client.connectOrSpawn()
            if self.daemonOK { self.refreshPaneList() }
        }
    }

    func refreshPaneList() {
        client.request(WireMessage(type: "list")) { [weak self] resp in
            Task { @MainActor in
                guard let self, let panes = resp?.panes else { return }
                var map: [String: PaneInfo] = [:]
                for p in panes { map[p.specID] = p }
                self.paneRuntime = map
            }
        }
    }

    // MARK: - Tasks

    private static var orderFile: URL {
        Paths.appSupport.appendingPathComponent("taskorder.json")
    }

    func rescan() {
        var list = store.scan()
        // Merge manual order: unseen tasks go to the front, vanished ones drop.
        let current = Set(list.map(\.id))
        let known = Set(taskOrder)
        let newOnes = list.map(\.id).filter { !known.contains($0) }
        let merged = newOnes + taskOrder.filter { current.contains($0) }
        if merged != taskOrder {
            taskOrder = merged
            saveOrder()
        }
        let index = Dictionary(uniqueKeysWithValues: taskOrder.enumerated().map { ($1, $0) })
        list.sort { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
        tasks = list
        autoArchiveSweep()
    }

    private func saveOrder() {
        try? (try? JSONEncoder().encode(taskOrder))?.write(to: Self.orderFile)
    }

    func newTask() {
        let slug = store.create(named: nil)
        rescan()
        selection = slug
    }

    func renameTask(_ slug: String, to newName: String) {
        sessions[slug]?.flushAll()
        guard let newSlug = store.rename(slug, to: newName) else { return }
        if let s = sessions.removeValue(forKey: slug) {
            s.renamed(to: newSlug)
            sessions[newSlug] = s
        }
        rescan()
        if selection == slug { selection = newSlug }
    }

    func archiveTask(_ slug: String) {
        sessions[slug]?.flushAll()
        for info in paneRuntime.values where info.taskID == slug {
            var k = WireMessage(type: "remove")
            k.paneID = info.id
            client.fire(k)
        }
        paneRuntime = paneRuntime.filter { $0.value.taskID != slug }
        if let s = sessions[slug] {
            s.setNoteStatus("done")
        } else {
            store.write(slug, TaskStore.setFrontmatterValue(store.read(slug), key: "status", value: "done"))
        }
        rescan()
        if selection == slug {
            selection = tasks.first(where: { $0.status == "active" && $0.id != slug })?.id
        }
    }

    func unarchiveTask(_ slug: String) {
        if let s = sessions[slug] {
            s.setNoteStatus("active")
        } else {
            store.write(slug, TaskStore.setFrontmatterValue(store.read(slug), key: "status", value: "active"))
        }
        rescan()
    }

    /// Delete a task outright: close its terminals, drop the machine state,
    /// move the note to the system Trash (recoverable — the note may live in
    /// a synced vault). `done` stays the archive path; this is for tasks not
    /// worth keeping at all.
    func deleteTask(_ slug: String) {
        sessions[slug]?.flushAll()
        for info in paneRuntime.values where info.taskID == slug {
            var k = WireMessage(type: "remove")
            k.paneID = info.id
            client.fire(k)
        }
        paneRuntime = paneRuntime.filter { $0.value.taskID != slug }
        sessions.removeValue(forKey: slug)
        try? FileManager.default.removeItem(
            at: Paths.machineStateDir.appendingPathComponent(slug + ".json"))
        let note = store.noteURL(slug)
        do {
            try FileManager.default.trashItem(at: note, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: note)
        }
        taskOrder.removeAll { $0 == slug }
        saveOrder()
        rescan()
        if selection == slug {
            selection = tasks.first(where: { $0.status == "active" })?.id
        }
    }

    func taskHasLivePane(_ slug: String) -> Bool {
        paneRuntime.values.contains { $0.taskID == slug && $0.running }
    }

    /// How many live terminals the delete confirmation should warn about.
    func livePaneCount(_ slug: String) -> Int {
        paneRuntime.values.filter { $0.taskID == slug && $0.running }.count
    }

    // MARK: - AI status badges

    /// One AI session attributable to a task, wherever it was started.
    struct TaskAISession {
        let sid: String
        let team: String?
        let cwd: String?
    }

    /// All AI sessions of a task: app-created pane specs ∪ the note's manifest
    /// lines ∪ any live-signal session whose id appears ANYWHERE in the note.
    /// The last source is what catches sessions the app never registered —
    /// started by hand in a shell pane, resumed, or pasted from `/status`
    /// ("Session ID: <uuid>") below the manifest divider — as long as the id
    /// is written somewhere in the note. Deduped by session id.
    func taskAISessions(_ slug: String) -> [TaskAISession] {
        let machine = sessions[slug]?.machine ?? store.machineState(slug)
        var seen = Set<String>()
        var out: [TaskAISession] = []
        for pane in machine.panes where pane.kind == "ai" {
            guard let sid = pane.sessionID, seen.insert(sid).inserted else { continue }
            out.append(TaskAISession(sid: sid, team: pane.team, cwd: pane.cwd))
        }
        let text = sessions[slug]?.noteText ?? store.read(slug)
        for line in TaskStore.manifestLines(text) where line.hasPrefix("- ") {
            let parts = line.dropFirst(2).split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            let sid = parts[1]
            guard (32 ... 36).contains(sid.count),
                  sid.allSatisfy({ $0.isHexDigit || $0 == "-" }),
                  seen.insert(sid).inserted else { continue }
            out.append(TaskAISession(sid: sid, team: parts[0], cwd: nil))
        }
        // Any known session (hook status file) whose id is written anywhere in
        // the note belongs to this task, even outside the manifest. Team is
        // unknown here but a hook signal doesn't need it (only the mtime
        // fallback does), so these still drive running / 等你 grouping.
        for sid in aiStatus.keys where !seen.contains(sid) && text.contains(sid) {
            seen.insert(sid)
            out.append(TaskAISession(sid: sid, team: nil, cwd: nil))
        }
        return out
    }

    /// Sidebar badge for a task's AI sessions: 🔴 needs permission,
    /// 🟢 running, 🟡 output finished（等你看）— including sessions that
    /// already ended without being acknowledged. Acknowledged entries
    /// (badge clicked) stay hidden until the state changes again.
    func aiBadge(_ slug: String) -> String? {
        var states: Set<String> = []
        for s in taskAISessions(slug) {
            guard let entry = statusEntry(sid: s.sid, team: s.team, cwd: s.cwd),
                  (ackedAI[s.sid] ?? .distantPast) < entry.ts else { continue }
            states.insert(entry.state)
        }
        if states.contains("permission") { return "🔴" }
        if states.contains("running") { return "🟢" }
        if states.contains("waiting") || states.contains("ended") { return "🟡" }
        return nil
    }

    // MARK: - Accent theme

    /// Selected accent preset (hex); Theme.accent reads it through here so a
    /// change re-renders every observer.
    @Published var accentHex: Int = UserDefaults.standard.object(forKey: "accentHex") as? Int
        ?? 0x5B9DFF {
        didSet {
            UserDefaults.standard.set(accentHex, forKey: "accentHex")
            Theme.accentHexCurrent = UInt32(accentHex)
        }
    }

    /// Base-appearance knobs（外觀設定視窗）：bg 色相預設、不透明度、明暗。
    /// @Published so every Theme consumer re-renders on change; Theme reads
    /// the mirrored statics.
    @Published var bgPresetIndex: Int = UserDefaults.standard.object(forKey: "bgPresetIndex") as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(bgPresetIndex, forKey: "bgPresetIndex")
            Theme.bgPresetIndex = bgPresetIndex
        }
    }

    @Published var bgOpacityBoost: Double = UserDefaults.standard.object(forKey: "bgOpacityBoost") as? Double ?? 0 {
        didSet {
            UserDefaults.standard.set(bgOpacityBoost, forKey: "bgOpacityBoost")
            Theme.bgOpacityBoost = bgOpacityBoost
        }
    }

    @Published var bgBrightness: Double = UserDefaults.standard.object(forKey: "bgBrightness") as? Double ?? 0 {
        didSet {
            UserDefaults.standard.set(bgBrightness, forKey: "bgBrightness")
            Theme.bgBrightness = bgBrightness
        }
    }

    @Published var blurStyleIndex: Int = UserDefaults.standard.object(forKey: "blurStyleIndex") as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(blurStyleIndex, forKey: "blurStyleIndex")
            Theme.blurStyleIndex = blurStyleIndex
        }
    }

    /// Badge clicked: mark the task's CURRENT AI states as seen.
    func ackAIStatus(_ slug: String) {
        for s in taskAISessions(slug) {
            if let entry = statusEntry(sid: s.sid, team: s.team, cwd: s.cwd) {
                ackedAI[s.sid] = entry.ts
            }
        }
    }

    // MARK: - Sidebar grouping
    //（等你 / 進行中 / 已讀 / 等待外部 / 半封存 / 已完成）

    // aiRunning is signal-driven（AI 執行中）; idle is the default home —
    // new tasks, shell-only work, and expired signals（待開工）.
    enum SidebarGroup { case needsYou, aiRunning, idle, read, waitingExt, semiArchived, done }

    /// 已讀 / 等待外部 items with 3 days of silence sink into 半封存
    /// (folded); a month of silence there auto-archives into 已完成 with an
    /// annotation (`autoArchiveSweep`).
    static let sinkAfter: TimeInterval = 72 * 3600
    static let autoDoneAfter: TimeInterval = 30 * 24 * 3600

    private static let fmDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    /// States that mean the ball is in the user's court: output finished
    /// (waiting), needs permission, or the session ended without ever being
    /// acknowledged — an unreviewed ended session still owes a review
    /// (Stop's "waiting" gets overwritten by SessionEnd's "ended" in the
    /// one-state-per-session file, so excluding "ended" would drop the debt).
    private static let attentionStates: Set<String> = ["waiting", "permission", "ended"]
    /// Signals older than this stop steering the sidebar either way；the
    /// real clearing mechanism is the ack（已看過）, not time.
    private static let signalWindow: TimeInterval = 7 * 24 * 3600

    /// Effective AI state for a session: hook signal first; when a session
    /// predates the hooks (no status file), fall back to the conversation
    /// file's mtime — writes stop when the AI stops, so quiet ≥10 min ⇒
    /// "waiting", fresher ⇒ "running".
    private func statusEntry(sid: String, team: String?, cwd: String?) -> (state: String, ts: Date)? {
        if let entry = aiStatus[sid] {
            return Date().timeIntervalSince(entry.ts) < Self.signalWindow ? entry : nil
        }
        guard let team,
              let dir = config.teams.first(where: { $0.id == team })?.configDir else { return nil }
        let cwdPath = Paths.expand(cwd ?? config.defaultCwd)
        let projectSlug = cwdPath.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let file = URL(fileURLWithPath: Paths.expand(dir))
            .appendingPathComponent("projects/\(projectSlug)/\(sid).jsonl")
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < Self.signalWindow else { return nil }
        return Date().timeIntervalSince(mtime) < 600
            ? ("running", mtime)
            : ("waiting", mtime)
    }

    /// The strongest unacked "ball is in your court" signal for a task:
    /// permission beats waiting; `since` = when the AI stopped (oldest such
    /// signal, so the needs-you queue is FIFO by how long you've been owed).
    /// Sessions count wherever they live (pane spec or note manifest) and
    /// whether or not their pane still runs — finished output awaits review
    /// even after the process is gone.
    func aiAttention(_ slug: String) -> (permission: Bool, since: Date)? {
        var permission = false
        var oldest: Date?
        for s in taskAISessions(slug) {
            guard let entry = statusEntry(sid: s.sid, team: s.team, cwd: s.cwd),
                  Self.attentionStates.contains(entry.state),
                  (ackedAI[s.sid] ?? .distantPast) < entry.ts else { continue }
            if entry.state == "permission" { permission = true }
            if oldest == nil || entry.ts < oldest! { oldest = entry.ts }
        }
        guard let oldest else { return nil }
        return (permission, oldest)
    }

    /// Ground-truth account for a session: which team's CLAUDE_CONFIG_DIR
    /// actually holds its conversation record. Beats the manifest's recorded
    /// team, which is only a guess at creation and wrong whenever the session
    /// was started/switched to another account by hand (平滑著色: manifest
    /// said claude, the record lived in claude-team3). The record is stored
    /// per project cwd as either `<sid>.jsonl` (older) or a `<sid>` directory
    /// (this claude version) — match both. nil = unknown.
    func teamFromSessionFile(_ sid: String) -> String? {
        let fm = FileManager.default
        for team in config.teams {
            guard let dir = team.configDir else { continue }
            let projects = URL(fileURLWithPath: Paths.expand(dir)).appendingPathComponent("projects")
            guard let subs = try? fm.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: nil) else { continue }
            for sub in subs {
                if fm.fileExists(atPath: sub.appendingPathComponent("\(sid).jsonl").path)
                    || fm.fileExists(atPath: sub.appendingPathComponent(sid).path) {
                    return team.id
                }
            }
        }
        return nil
    }

    /// The account currently working on the task — "現用" in the header chip.
    /// The freshest-signal session's REAL account (resolved from its file
    /// location), falling back to the manifest team only when the file can't
    /// be found. Display-only: never rewrites primaryTeam (主力 is the manual
    /// quota home).
    func activeTeam(_ slug: String) -> String? {
        var best: (ts: Date, sid: String, team: String?)?
        for s in taskAISessions(slug) {
            guard let entry = statusEntry(sid: s.sid, team: s.team, cwd: s.cwd) else { continue }
            if best == nil || entry.ts > best!.ts { best = (entry.ts, s.sid, s.team) }
        }
        guard let best else { return nil }
        return teamFromSessionFile(best.sid) ?? best.team
    }

    /// Any session actively running right now (hook-fresh within 30 min —
    /// PreToolUse re-stamps the file on every tool call, so a live turn
    /// stays fresh). While the AI is visibly working the user is engaged:
    /// stale review debts from OLDER sessions must not pin the task in
    /// 等你 (the PRO-1268 round two lesson, 260720).
    private func aiRunningNow(_ slug: String) -> Bool {
        taskAISessions(slug).contains { s in
            guard let entry = statusEntry(sid: s.sid, team: s.team, cwd: s.cwd) else { return false }
            return entry.state == "running" && Date().timeIntervalSince(entry.ts) < 1800
        }
    }

    /// Newest signal across the task's AI sessions (acked or not) —
    /// "last activity" for the sink rule.
    private func lastAIActivity(_ slug: String) -> Date? {
        taskAISessions(slug)
            .compactMap { statusEntry(sid: $0.sid, team: $0.team, cwd: $0.cwd)?.ts }
            .max()
    }

    /// Does the task have an AI stop signal the user already acknowledged
    /// (= "已讀"：看過了、還沒給下一步)?
    private func hasAckedStop(_ slug: String) -> Bool {
        taskAISessions(slug).contains { s in
            guard let entry = statusEntry(sid: s.sid, team: s.team, cwd: s.cwd),
                  Self.attentionStates.contains(entry.state) else { return false }
            return (ackedAI[s.sid] ?? .distantPast) >= entry.ts
        }
    }

    /// Seconds since the task last showed any sign of life（hook 訊號 or
    /// entering its manual group）。nil = can't tell (treat as fresh).
    func silence(_ t: TaskNote) -> TimeInterval? {
        var candidates: [Date] = []
        if let ai = lastAIActivity(t.id) { candidates.append(ai) }
        if let s = t.groupSince.flatMap({ Self.fmDate.date(from: $0) }) { candidates.append(s) }
        guard let last = candidates.max() else { return nil }
        return Date().timeIntervalSince(last)
    }

    // Grouping model (260720 v2): THE MOST RECENT EVENT WINS. An AI signal and
    // a manual placement each carry a timestamp; whichever happened later
    // decides the group. So a fresh chat pulls a parked task back to AI 執行中
    // (AI event is newer), and manually moving a finished task to 等待外部
    // sticks (the click is newer than the old Stop). An actively-running
    // session is the one exception — it always wins (you can't park a task
    // whose AI is mid-turn; it re-stamps itself every tool call anyway).
    func sidebarGroup(_ t: TaskNote) -> SidebarGroup {
        if t.status == "done" { return .done }
        let quiet = silence(t) ?? 0

        if aiRunningNow(t.id) { return .aiRunning } // actively running always wins

        // Manual placement is authoritative when it's at least as recent as the
        // newest AI signal; otherwise the AI signal drives (finished→等你).
        let parkedAt = t.groupSince.flatMap { Self.fmDate.date(from: $0) }
        let lastAI = lastAIActivity(t.id)
        let manualWins = parkedAt != nil && (lastAI == nil || parkedAt! >= lastAI!)

        if !manualWins {
            let attention = aiAttention(t.id)
            if attention?.permission == true { return .needsYou } // 🔴 blocked on you
            if attention != nil { return .needsYou }              // finished, awaits review
        }

        // Manual placement (honored when it's the most recent event). 等你
        // can be set by hand too — it stays put (no time-sink) until AI acts.
        if t.group == "needsyou" { return .needsYou }
        if t.group == "waiting" {
            return quiet > Self.sinkAfter ? .semiArchived : .waitingExt
        }
        if t.group == "read" || hasAckedStop(t.id) {
            return quiet > Self.sinkAfter ? .semiArchived : .read
        }
        return .idle // new / no manual flag / expired signals
    }

    /// Manual move targets (frontmatter `group`): the value to store and the
    /// section it lands in. `nil` value = clear flag → 待開工. AI 執行中 and
    /// 半封存 are excluded (live/derived, not hand-settable).
    static let manualMoveTargets: [(label: String, value: String?, group: SidebarGroup)] = [
        ("待開工", nil, .idle),
        ("等你（我要 review）", "needsyou", .needsYou),
        ("已讀（看過先不回）", "read", .read),
        ("等待外部（同事 / review / CI）", "waiting", .waitingExt),
    ]

    /// Set / clear the manual lifecycle flag ("waiting" 等待外部、"read"
    /// 已讀、nil 移回待開工). `group_since` is stamped to now so the placement
    /// competes with AI signals by recency (see sidebarGroup): it wins until
    /// the AI next does something, which then pulls the task back.
    func setGroupFlag(_ slug: String, _ flag: String?) {
        func transform(_ text: String) -> String {
            if let flag {
                let stamped = TaskStore.setFrontmatterValue(text, key: "group", value: flag)
                return TaskStore.setFrontmatterValue(stamped, key: "group_since",
                                                     value: Self.fmDate.string(from: Date()))
            }
            var cleared = TaskStore.removeFrontmatterKey(text, key: "group")
            cleared = TaskStore.removeFrontmatterKey(cleared, key: "group_since")
            return TaskStore.removeFrontmatterKey(cleared, key: "waiting_since")
        }
        if let s = sessions[slug] {
            s.noteText = transform(s.noteText)
            s.flushNote()
        } else {
            store.write(slug, transform(store.read(slug)))
        }
        rescan()
    }

    /// 半封存超過一個月 → 自動歸入已完成，並在筆記留下可追溯的備註。
    /// Runs on every rescan; idempotent (done tasks are skipped, the
    /// annotation is stamped once via the auto_archived frontmatter key).
    private func autoArchiveSweep() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        for t in tasks where t.status == "active" {
            guard sidebarGroup(t) == .semiArchived,
                  let quiet = silence(t), quiet > Self.autoDoneAfter else { continue }
            var text = sessions[t.id]?.noteText ?? store.read(t.id)
            guard TaskStore.frontmatter(text)["auto_archived"] == nil else { continue }
            let stamp = df.string(from: Date())
            text = TaskStore.setFrontmatterValue(text, key: "status", value: "done")
            text = TaskStore.setFrontmatterValue(text, key: "auto_archived", value: stamp)
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n> 🗄 \(stamp) 系統自動封存：半封存超過 30 天無動靜，自動歸入「已完成」。\n"
            if let s = sessions[t.id] {
                s.noteText = text
                s.flushNote()
            } else {
                store.write(t.id, text)
            }
        }
    }

    /// Reorder within the 進行中 group（drag）：the moved slice is written
    /// back to the front of the global preference order; everything else
    /// keeps its relative position.
    func moveRunningTasks(_ running: [String], from: IndexSet, to: Int) {
        var slugs = running
        slugs.move(fromOffsets: from, toOffset: to)
        taskOrder = slugs + taskOrder.filter { !slugs.contains($0) }
        saveOrder()
        rescan()
    }

    private func watchStatusDir() {
        statusFD = open(Paths.statusDir.path, O_EVTONLY)
        guard statusFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: statusFD, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.reloadAIStatus() }
        src.activate()
        statusWatcher = src
    }

    private func reloadAIStatus() {
        var map: [String: (state: String, ts: Date)] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.statusDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let state = obj["state"] as? String else { continue }
            let ts = (obj["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            map[f.deletingPathExtension().lastPathComponent] = (state, ts)
        }
        aiStatus = map
    }

    func openInObsidian(_ slug: String) {
        let path = store.noteURL(slug).path
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "obsidian://open?path=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealNote(_ slug: String) {
        NSWorkspace.shared.activateFileViewerSelecting([store.noteURL(slug)])
    }

    /// Attach a live pane inside a fresh iTerm2 window via `taskdeckctl attach`.
    /// The pane stays daemon-owned; both views mirror the same PTY.
    func openPaneInITerm2(_ info: PaneInfo) {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let ctl = exe.deletingLastPathComponent().appendingPathComponent("taskdeckctl").path
        let script = """
        tell application "iTerm2"
            activate
            create window with default profile command "'\(ctl)' attach \(info.id)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func flushEverything() {
        for s in sessions.values { s.flushAll() }
    }

    private func watchTasksDir() {
        dirFD = open(store.dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.rescan() }
        src.activate()
        dirWatcher = src
    }

    // MARK: - Quota

    func refreshQuota() {
        guard let cmd = config.quotaCommand, !cmd.isEmpty, !quotaBusy else { return }
        quotaBusy = true
        Task.detached(priority: .utility) {
            let errPath = "/tmp/taskdeck-quota.err"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // GUI apps get launchd's minimal PATH (no ~/.local/bin, no
            // /opt/homebrew/bin — where user CLIs like claude-quota live);
            // `-l` alone doesn't help when PATH is set up in .zshrc.
            p.arguments = ["-lc",
                           "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:$PATH\"; "
                               + cmd + " 2>\(errPath)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            var out = ""
            var status: Int32 = -1
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                status = p.terminationStatus
                out = String(data: data, encoding: .utf8) ?? ""
            } catch {
                out = ""
            }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalStatus = status
            await MainActor.run { [weak self] in
                guard let self else { return }
                if text.isEmpty {
                    // Keep the last good table; only explain when we never had one.
                    self.quotaStale = true
                    if self.quotaText.isEmpty {
                        let err = (try? String(contentsOfFile: errPath, encoding: .utf8))?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .suffix(300)
                        self.quotaText = "額度讀取失敗（exit \(finalStatus)）"
                            + (err.map { "\n\(String($0))" } ?? "")
                    }
                } else {
                    self.quotaText = text
                    self.quotaStale = false
                }
                self.quotaUpdatedAt = Date()
                self.quotaBusy = false
            }
        }
    }
}

/// Per-task UI state: the in-memory note document, pane specs and layout.
/// Shared by every window showing the same task.
@MainActor
final class TaskSession: ObservableObject {
    private(set) var slug: String
    unowned let app: AppModel

    @Published var noteText: String {
        didSet { scheduleNoteSave() }
    }

    @Published var machine: TaskMachineState {
        didSet { scheduleMachineSave() }
    }

    @Published var focusedSpecID: String?

    /// Which zone owns the "active" border: a terminal pane or the notes
    /// column（側邊欄永遠不高亮、也不改變此狀態）。
    enum FocusZone { case terminal, notes }
    @Published var focusZone: FocusZone = .terminal

    private var noteTimer: Timer?
    private var machineTimer: Timer?

    init(slug: String, app: AppModel) {
        self.slug = slug
        self.app = app
        noteText = app.store.read(slug)
        machine = app.store.machineState(slug)
        autoStartPanes()
    }

    func renamed(to newSlug: String) {
        slug = newSlug
        if let r = noteText.range(of: "(?m)^# .*$", options: .regularExpression) {
            noteText = noteText.replacingCharacters(in: r, with: "# \(newSlug)")
        }
    }

    func setNoteStatus(_ status: String) {
        noteText = TaskStore.setFrontmatterValue(noteText, key: "status", value: status)
        flushNote()
    }

    // MARK: - Persistence

    private func scheduleNoteSave() {
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushNote() }
        }
    }

    func flushNote() {
        noteTimer?.invalidate()
        noteTimer = nil
        let disk = app.store.read(slug)
        // Never let a stale in-memory copy destroy session ids that are
        // already on disk (vault sync / second instance / crash races) —
        // James lost a claude-eng id to exactly this class of race.
        let merged = TaskStore.mergeManifestLines(disk: disk, into: noteText)
        if merged != noteText { noteText = merged }
        if disk != merged {
            app.store.write(slug, merged)
        }
    }

    private func scheduleMachineSave() {
        machineTimer?.invalidate()
        machineTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushMachine() }
        }
    }

    func flushMachine() {
        machineTimer?.invalidate()
        machineTimer = nil
        app.store.saveMachineState(slug, machine)
    }

    func flushAll() {
        flushNote()
        flushMachine()
    }

    // MARK: - Panes

    func spec(_ id: String) -> PaneSpec? {
        machine.panes.first { $0.id == id }
    }

    /// Small terminals living in the notes column (out of the grid layout).
    var sidePaneIDs: [String] {
        machine.panes.filter { $0.location == "side" }.map(\.id)
    }

    func addShellPane(side: Bool = false) {
        add(PaneSpec(title: "shell", kind: "shell"), side: side)
    }

    func addAIPane(team: TeamDef, side: Bool = false) {
        var spec = PaneSpec(title: team.id, kind: "ai", team: team.id, extraArgs: team.args)
        if team.kind == "claude" {
            let sid = UUID().uuidString.lowercased()
            spec.sessionID = sid
            noteText = TaskStore.appendSessionLine(noteText, line: "- \(team.id) \(sid)")
        }
        if machine.primaryTeam == nil { machine.primaryTeam = team.id }
        // （之後想換配額之家：點標頭的主力 chip 手動改，系統不自動改寫。）
        add(spec, side: side)
    }

    func addCommandPane(title: String, command: String, side: Bool = false) {
        add(PaneSpec(title: title.isEmpty ? command : title, kind: "command", command: command),
            side: side)
    }

    private func add(_ spec: PaneSpec, side: Bool = false) {
        var spec = spec
        if side { spec.location = "side" }
        machine.panes.append(spec)
        if !side {
            // Side panes never enter the grid's split tree.
            if let layout = machine.layout {
                if let f = focusedSpecID, LayoutOps.contains(layout, f) {
                    machine.layout = LayoutOps.insertSplit(layout, target: f, axis: "h", newPane: spec.id)
                } else {
                    machine.layout = .split(axis: "h", ratio: 0.5, a: layout, b: .pane(spec.id))
                }
            } else {
                machine.layout = .pane(spec.id)
            }
        }
        focusedSpecID = spec.id
        startPane(spec)
    }

    func splitPane(_ target: String, axis: String) {
        let spec = PaneSpec(title: "shell", kind: "shell")
        machine.panes.append(spec)
        if let layout = machine.layout {
            machine.layout = LayoutOps.insertSplit(layout, target: target, axis: axis, newPane: spec.id)
        } else {
            machine.layout = .pane(spec.id)
        }
        focusedSpecID = spec.id
        startPane(spec)
    }

    func startPane(_ spec: PaneSpec) {
        guard app.daemonOK else { return }
        var m = WireMessage(type: "newPane")
        m.taskID = slug
        m.specID = spec.id
        m.title = spec.title
        m.cwd = Paths.expand(spec.cwd ?? app.config.defaultCwd)
        m.shell = app.config.shell
        m.cols = 100
        m.rows = 28
        m.command = spec.startCommand
        app.client.request(m) { [weak self] resp in
            Task { @MainActor in
                guard let self else { return }
                if let info = resp?.panes?.first {
                    self.app.paneRuntime[info.specID] = info
                }
            }
        }
    }

    func restartPane(_ spec: PaneSpec) {
        if let info = app.paneRuntime[spec.id] {
            var k = WireMessage(type: "remove")
            k.paneID = info.id
            app.client.fire(k)
            app.paneRuntime.removeValue(forKey: spec.id)
        }
        startPane(spec)
    }

    func closePane(_ spec: PaneSpec) {
        if let info = app.paneRuntime[spec.id] {
            var k = WireMessage(type: "remove")
            k.paneID = info.id
            app.client.fire(k)
            app.paneRuntime.removeValue(forKey: spec.id)
        }
        machine.panes.removeAll { $0.id == spec.id }
        if let layout = machine.layout {
            machine.layout = LayoutOps.remove(layout, target: spec.id)
        }
        if focusedSpecID == spec.id { focusedSpecID = nil }
    }

    /// 手動接管主力（配額之家）；自動偵測只顯示「現用」、永不改寫這裡。
    /// nil 清除主力（回到「設定主力」）。
    func setPrimaryTeam(_ team: String?) {
        machine.primaryTeam = team
    }

    /// The task's permanent id (frontmatter `id`, rename-proof). Stamped at
    /// creation since 260720; older notes get one lazily on first use.
    func permanentID() -> String {
        if let id = TaskStore.frontmatter(noteText)["id"], !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        noteText = TaskStore.setFrontmatterValue(noteText, key: "id", value: id)
        flushNote()
        return id
    }

    func toggleAutoStart(_ spec: PaneSpec) {
        guard let i = machine.panes.firstIndex(where: { $0.id == spec.id }) else { return }
        machine.panes[i].autoStart.toggle()
    }

    private func autoStartPanes() {
        guard app.daemonOK else { return }
        for spec in machine.panes where spec.autoStart && app.paneRuntime[spec.id] == nil {
            startPane(spec)
        }
    }

    // MARK: - Layout

    func ratio(at path: [Bool]) -> Double {
        machine.layout.map { LayoutOps.ratio($0, at: path) } ?? 0.5
    }

    func setRatio(path: [Bool], ratio: Double) {
        guard let layout = machine.layout else { return }
        machine.layout = LayoutOps.setRatio(layout, at: path, to: ratio)
    }

}
