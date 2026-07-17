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

    /// Sidebar badge for a task's AI panes: 🔴 needs permission, 🟢 running,
    /// 🟡 turn finished / waiting for the user. Only live panes count — a
    /// stale file from an exited claude never shows (and entries expire).
    /// Acknowledged entries (badge clicked) stay hidden until the state
    /// changes again.
    func aiBadge(_ slug: String) -> String? {
        let machine = sessions[slug]?.machine ?? store.machineState(slug)
        var states: Set<String> = []
        for pane in machine.panes where pane.kind == "ai" {
            guard let sid = pane.sessionID,
                  let entry = aiStatus[sid],
                  entry.state != "ended",
                  paneRuntime[pane.id]?.running == true,
                  Date().timeIntervalSince(entry.ts) < 24 * 3600,
                  (ackedAI[sid] ?? .distantPast) < entry.ts else { continue }
            states.insert(entry.state)
        }
        if states.contains("permission") { return "🔴" }
        if states.contains("running") { return "🟢" }
        if states.contains("waiting") { return "🟡" }
        return nil
    }

    /// Badge clicked: mark the task's CURRENT AI states as seen.
    func ackAIStatus(_ slug: String) {
        let machine = sessions[slug]?.machine ?? store.machineState(slug)
        for pane in machine.panes where pane.kind == "ai" {
            if let sid = pane.sessionID, let entry = aiStatus[sid] {
                ackedAI[sid] = entry.ts
            }
        }
    }

    // MARK: - Sidebar grouping（等你 / 進行中 / 等待外部 / 沉底 / 已完成）

    enum SidebarGroup { case needsYou, running, waitingExt, sunk, done }

    /// Items parked on external feedback sink after 3 days of silence.
    static let sinkAfter: TimeInterval = 72 * 3600

    private static let fmDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    /// The strongest unacked "ball is in your court" signal for a task:
    /// permission beats waiting; `since` = when the AI stopped (oldest such
    /// signal, so the needs-you queue is FIFO by how long you've been owed).
    func aiAttention(_ slug: String) -> (permission: Bool, since: Date)? {
        let machine = sessions[slug]?.machine ?? store.machineState(slug)
        var permission = false
        var oldest: Date?
        for pane in machine.panes where pane.kind == "ai" {
            guard let sid = pane.sessionID,
                  let entry = aiStatus[sid],
                  entry.state == "waiting" || entry.state == "permission",
                  paneRuntime[pane.id]?.running == true,
                  Date().timeIntervalSince(entry.ts) < 24 * 3600,
                  (ackedAI[sid] ?? .distantPast) < entry.ts else { continue }
            if entry.state == "permission" { permission = true }
            if oldest == nil || entry.ts < oldest! { oldest = entry.ts }
        }
        guard let oldest else { return nil }
        return (permission, oldest)
    }

    /// Newest hook signal across the task's AI sessions (acked or not) —
    /// "last activity" for the sink rule.
    private func lastAIActivity(_ slug: String) -> Date? {
        let machine = sessions[slug]?.machine ?? store.machineState(slug)
        return machine.panes.compactMap { $0.sessionID.flatMap { aiStatus[$0]?.ts } }.max()
    }

    func sidebarGroup(_ t: TaskNote) -> SidebarGroup {
        if t.status == "done" { return .done }
        if t.group == "waiting" {
            let since = t.waitingSince.flatMap { Self.fmDate.date(from: $0) } ?? Date()
            let last = max(lastAIActivity(t.id) ?? .distantPast, since)
            return Date().timeIntervalSince(last) > Self.sinkAfter ? .sunk : .waitingExt
        }
        return aiAttention(t.id) != nil ? .needsYou : .running
    }

    /// Toggle the manual "waiting on external feedback" park. Parked tasks
    /// keep their badges but never jump groups on AI signals — only you
    /// move them back.
    func setWaiting(_ slug: String, _ waiting: Bool) {
        func transform(_ text: String) -> String {
            if waiting {
                let stamped = TaskStore.setFrontmatterValue(text, key: "group", value: "waiting")
                return TaskStore.setFrontmatterValue(stamped, key: "waiting_since",
                                                     value: Self.fmDate.string(from: Date()))
            }
            let cleared = TaskStore.removeFrontmatterKey(text, key: "group")
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
            p.arguments = ["-lc", cmd + " 2>\(errPath)"]
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
        if app.store.read(slug) != noteText {
            app.store.write(slug, noteText)
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
