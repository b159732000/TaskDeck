import AppKit
import Foundation
import SwiftUI
import TaskDeckCore

struct QuotaBucket: Codable {
    var percent: Double?
    var resets_at: String?
    var detail: String?
}

struct QuotaAccount: Codable {
    var alias: String
    var buckets: [String: QuotaBucket]
}

struct QuotaSnapshot: Codable {
    var fetched_at: String?
    var accounts: [QuotaAccount]

    /// Preferred display order for buckets inside a chip.
    static let bucketOrder = ["5h session", "weekly all", "weekly Fable", "credits"]
    static let bucketShortLabel: [String: String] = [
        "5h session": "5h",
        "weekly all": "週",
        "weekly Fable": "F",
        "credits": "$",
    ]

    static func orderedBuckets(_ account: QuotaAccount) -> [(String, QuotaBucket)] {
        var out: [(String, QuotaBucket)] = []
        for key in bucketOrder {
            if let b = account.buckets[key] { out.append((key, b)) }
        }
        for (key, b) in account.buckets.sorted(by: { $0.key < $1.key }) where !bucketOrder.contains(key) {
            out.append((key, b))
        }
        return out
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [TaskNote] = []
    @Published var selection: String?
    /// specID → live pane info (across all tasks).
    @Published var paneRuntime: [String: PaneInfo] = [:]
    @Published var daemonOK = false
    @Published var quota: QuotaSnapshot?
    @Published var quotaError: String?
    @Published var quotaUpdatedAt: Date?
    @Published var quotaBusy = false

    let config: AppConfig
    let store: TaskStore
    let client = DaemonClient()
    let hasITerm2 = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")

    private var sessions: [String: TaskSession] = [:]
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var quotaTimer: Timer?

    init() {
        config = AppConfig.load()
        store = TaskStore(dir: config.tasksDirURL)
        tasks = store.scan()

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

        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota() }
        }
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

    func rescan() {
        tasks = store.scan()
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

    func taskHasLivePane(_ slug: String) -> Bool {
        paneRuntime.values.contains { $0.taskID == slug && $0.running }
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
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd + " --json 2>/dev/null"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var snapshot: QuotaSnapshot?
            var errText: String?
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
            } catch {
                errText = "額度讀取失敗（\(cmd) --json）"
            }
            let s = snapshot
            let e = errText
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let s { self.quota = s; self.quotaError = nil } else { self.quotaError = e }
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

    func addShellPane() {
        add(PaneSpec(title: "shell", kind: "shell"))
    }

    func addAIPane(team: TeamDef) {
        var spec = PaneSpec(title: team.id, kind: "ai", team: team.id)
        if team.kind == "claude" {
            let sid = UUID().uuidString.lowercased()
            spec.sessionID = sid
            noteText = TaskStore.appendSessionLine(noteText, line: "- \(team.id) \(sid)")
        }
        if machine.primaryTeam == nil { machine.primaryTeam = team.id }
        add(spec)
    }

    func addCommandPane(title: String, command: String) {
        add(PaneSpec(title: title.isEmpty ? command : title, kind: "command", command: command))
    }

    private func add(_ spec: PaneSpec) {
        machine.panes.append(spec)
        if let layout = machine.layout {
            if let f = focusedSpecID, LayoutOps.contains(layout, f) {
                machine.layout = LayoutOps.insertSplit(layout, target: f, axis: "h", newPane: spec.id)
            } else {
                machine.layout = .split(axis: "h", ratio: 0.5, a: layout, b: .pane(spec.id))
            }
        } else {
            machine.layout = .pane(spec.id)
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
