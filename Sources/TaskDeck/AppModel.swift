import AppKit
import Foundation
import SwiftUI
import TaskDeckCore
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    private static let priorityAlertNotificationID = "taskdeck-mainline-ready"

    @Published var tasks: [TaskNote] = []
    @Published var selection: String?
    /// specID → live pane info (across all tasks).
    @Published var paneRuntime: [String: PaneInfo] = [:]
    @Published var daemonOK = false
    /// Successful socket generations. TerminalHostView keys include this so a
    /// reconnect dismantles stale subscription tokens and negotiates the new
    /// connection even when the daemon preserved the same pane IDs.
    @Published private(set) var daemonConnectionGeneration: UInt64 = 0
    /// Raw CLI table output (ANSI codes included) from `quotaCommand`.
    /// One shared fetcher for the whole app — the quota tool rate-limits,
    /// so per-task/per-window fetching would be wrong.
    @Published var quotaText = ""
    @Published var quotaUpdatedAt: Date?
    @Published var quotaBusy = false
    /// Last refresh failed; `quotaText` still shows the previous good table.
    @Published var quotaStale = false
    /// Rename-proof task keys whose mainline completion alert has not yet
    /// been explicitly viewed. Persisted so relaunch keeps the quiet reminder,
    /// but the transient pulse / notification is never replayed on launch.
    @Published private(set) var priorityAlertKeys =
        Set(UserDefaults.standard.stringArray(forKey: "priorityAlertTaskKeys") ?? []) {
        didSet {
            UserDefaults.standard.set(priorityAlertKeys.sorted(),
                                      forKey: "priorityAlertTaskKeys")
            clearPriorityAlertSystemNotification()
            updatePriorityAlertDockBadge()
        }
    }
    /// Monotonic edge token consumed by the FPS-style vignette.
    @Published private(set) var priorityAlertPulse = 0

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

    /// specID → what that pane's terminal is running right now (process-level,
    /// sampled every couple of seconds). Separate from AI status on purpose:
    /// this says "an AI CLI is open", the hook files say "the AI is thinking".
    @Published private(set) var paneActivity: [String: PaneActivity] = [:]
    /// slug → its long-running commands, longest first. Built with the sample
    /// (not in a view body): resolving pane → task can touch machine state, and
    /// the sidebar re-renders on every hover.
    @Published private(set) var servicesByTask: [String: [PaneActivity]] = [:]
    private let activitySampler = PaneActivitySampler()
    private var activityTimer: Timer?
    private var activitySampleInFlight = false

    private var sessions: [String: TaskSession] = [:]
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var quotaTimer: Timer?
    private var statusTimer: Timer?
    private var rescanTimer: Timer?

    /// AI session states from the Claude Code hook script
    /// (`Scripts/taskdeck-ai-status.sh` → `Paths.statusDir/<session>.json`):
    /// sessionID → (running | waiting | permission | ended, written-at).
    private var aiStatus: [String: AIStatusEntry] = [:]
    /// Reverse index of the hook's task attribution. Building it once per
    /// status load avoids scanning every status row once for every task.
    private var hookSessionsByTask: [String: Set<String>] = [:]
    /// Native Claude background tasks still active in each session. This is a
    /// secondary activity badge only; it never changes the sidebar group.
    private var backgroundTasksBySession: [String: Int] = [:]
    /// "已看過"：sessionID → the status timestamp the user acknowledged by
    /// clicking the badge. Entries at or before this ts stop showing; the
    /// next state change (newer ts) lights the badge again.
    private var ackedAI: [String: Date] = [:] {
        didSet {
            let raw = ackedAI.mapValues { $0.timeIntervalSince1970 }
            UserDefaults.standard.set(raw, forKey: "ackedAI")
        }
    }

    private var statusWatcher: DispatchSourceFileSystemObject?
    private var statusFD: Int32 = -1
    private let statusLoader = AIStatusLoader()
    private var statusReloadTask: Task<Void, Never>?
    private var statusReloadGeneration = 0
    /// True once the hook status directory has been read at least once (by the
    /// synchronous prime below or by an applied snapshot). Until then every
    /// task looks silent no matter how recently its AI ran, so nothing that
    /// judges silence may run.
    private var hasAIStatusPicture = false
    /// Prevent a cold launch's first status snapshot from being mistaken for a
    /// new completion. It may restore a persisted quiet reminder, never pulse.
    private var hasLoadedAIStatusSnapshot = false
    /// Stable-key snapshot used only for the alert edge. Unlike derivedCache
    /// (slug-keyed for the rest of the UI), this survives a rename that lands
    /// in the same refresh as AI completion.
    private var priorityAlertGroupCache: [String: SidebarGroup] = [:]

    init() {
        config = AppConfig.load()
        store = TaskStore(dir: config.tasksDirURL)
        if let e = AppConfig.lastLoadError { daemonNote = e } // surfaced in DaemonStatusView
        let storedScale = UserDefaults.standard.double(forKey: "uiScale")
        uiScale = storedScale == 0 ? 1.0 : min(1.6, max(0.7, storedScale))
        taskOrder = (try? JSONDecoder().decode([String].self,
                                               from: Data(contentsOf: Self.orderFile))) ?? []
        if let raw = UserDefaults.standard.dictionary(forKey: "ackedAI") as? [String: Double] {
            ackedAI = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        rescan()
        Task { @MainActor [weak self] in
            self?.clearPriorityAlertSystemNotification()
            self?.updatePriorityAlertDockBadge()
        }

        client.onEvent = { [weak self] m in
            Task { @MainActor in self?.handleEvent(m) }
        }
        client.onDisconnect = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Invalidate an in-flight hello/list transaction. Its nil
                // callbacks must never commit a ready generation after this
                // disconnect has already been observed.
                self.daemonEstablishSerial &+= 1
                self.daemonOK = false
                self.daemonReady = false
            }
        }

        Task { @MainActor in
            await self.establishDaemon()
            if self.selection == nil {
                self.selection = self.tasks.first(where: { $0.status == "active" })?.id
            }
            self.refreshQuota()
        }

        watchTasksDir()
        watchStatusDir()
        scheduleAIStatusReload(includeTaskSources: true)

        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota() }
        }

        // Belt-and-suspenders for AI status: the dir watcher only fires on
        // create/delete/rename, and time-based grouping rules (running
        // freshness, sink thresholds) need periodic recomputation anyway.
        // Also poll open notes for external (Obsidian) edits — a kqueue on the
        // tasks dir doesn't fire on a file's content change.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleAIStatusReload(includeTaskSources: true)
                self?.reloadOpenNotes()
            }
        }

        // Terminal activity is cheap to read (one process-table syscall, ~1 ms
        // for the whole machine) and changes on a human timescale, so a short
        // fixed interval beats trying to be clever about when to look.
        activityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleActivity() }
        }

        // Reload notes the instant the app regains focus (e.g. switching back
        // from Obsidian), so external edits feel live rather than ≤20s late.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadOpenNotes() }
        }
    }

    /// Re-read every open task's note from disk (picks up Obsidian/vault-sync
    /// edits: manually-added session ids, resources, notes).
    func reloadOpenNotes() {
        for s in sessions.values { s.reloadFromDiskIfChanged() }
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
            // Idempotence: apply only to the pane we CURRENTLY track for that
            // spec. After a restart, the old pane's exit event must not
            // overwrite the fresh runtime entry (which left an invisible live
            // pane); after closePane it must not resurrect a ghost entry.
            if let info = m.panes?.first, paneRuntime[info.specID]?.id == info.id {
                paneRuntime[info.specID] = info
            }
        case "surfaceEvent":
            handleTerminalSurfaceEvent(m)
        default:
            break
        }
    }

    /// Canonical terminal parsing happens once in taskdeckd, so semantic side
    /// effects must also happen once here. Per-view rendering callbacks would
    /// duplicate bells and OSC-52 clipboard writes when a pane is open in two
    /// windows.
    private func handleTerminalSurfaceEvent(_ message: WireMessage) {
        switch message.surfaceEvent {
        case TerminalSurfaceEventKind.bell:
            NSSound.beep()

        case TerminalSurfaceEventKind.clipboardCopy:
            guard let bytes = message.dataBytes,
                  let text = String(bytes: bytes, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

        case TerminalSurfaceEventKind.notification:
            // Shell OSC notifications never trigger a permission prompt. If
            // the user already authorized JamesDesk notifications (for the
            // mainline reminder), preserve the terminal notification too.
            NSApp?.requestUserAttention(.informationalRequest)
            let notificationTitle = message.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Terminal"
            let notificationBody = message.message ?? ""
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized
                        || settings.authorizationStatus == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = notificationTitle
                content.body = notificationBody
                UNUserNotificationCenter.current().add(UNNotificationRequest(
                    identifier: "taskdeck-terminal-\(UUID().uuidString)",
                    content: content,
                    trigger: nil)) { error in
                    if let error { NSLog("TaskDeck: terminal notification failed: \(error)") }
                }
            }

        default:
            // title/cwd are already carried in and applied from the surface
            // state. Progress is fanned out to each visible TerminalView.
            break
        }
    }

    /// Ordered startup handshake: connect → verify protocol version → apply
    /// the daemon's pane list → only then is `daemonReady` true and auto-start
    /// allowed. Auto-starting before reconciliation spawned duplicates of
    /// panes that were in fact alive in the daemon.
    @Published private(set) var daemonReady = false
    /// One-line connection warning surfaced in DaemonStatusView (e.g. protocol
    /// version drift after updating the GUI while an old daemon keeps running).
    @Published var daemonNote: String?
    private var readyCallbacks: [() -> Void] = []
    /// Main-actor transaction id. Reconnect clicks can overlap at await points;
    /// only the newest complete hello+list handshake may publish readiness.
    private var daemonEstablishSerial: UInt64 = 0

    func onDaemonReady(_ cb: @escaping () -> Void) {
        if daemonReady { cb() } else { readyCallbacks.append(cb) }
    }

    private func requestAsync(_ m: WireMessage) async -> WireMessage? {
        await withCheckedContinuation { cont in
            client.request(m) { cont.resume(returning: $0) }
        }
    }

    private func establishDaemon() async {
        daemonEstablishSerial &+= 1
        let establishSerial = daemonEstablishSerial
        daemonReady = false
        let connected = await client.connectOrSpawn()
        guard daemonEstablishSerial == establishSerial else { return }
        daemonOK = connected
        guard connected else {
            daemonNote = "無法連線 taskdeckd"
            return
        }

        var hello = WireMessage(type: "hello")
        hello.version = Wire.version
        let reply = await requestAsync(hello)
        guard daemonEstablishSerial == establishSerial else { return }
        guard let reply, reply.type == "hello", let daemonVersion = reply.version else {
            daemonOK = false
            daemonNote = reply == nil ? "daemon 未回應握手" : "daemon 握手格式無效"
            return
        }

        let healthyNote: String?
        if daemonVersion != Wire.version {
            // Additive protocol: keep working, but surface the drift — the
            // running daemon predates this GUI. Never auto-restart it.
            healthyNote = "daemon 協定 v\(daemonVersion) ≠ GUI v\(Wire.version)——功能可能受限，請擇時重啟 daemon"
            NSLog("TaskDeck: protocol version drift daemon=\(daemonVersion) gui=\(Wire.version)")
        } else {
            healthyNote = AppConfig.lastLoadError
        }

        let listReply = await requestAsync(WireMessage(type: "list"))
        guard daemonEstablishSerial == establishSerial else { return }
        guard let listReply, listReply.type == "panes",
              let panes = listReply.panes else {
            daemonOK = false
            daemonNote = listReply == nil
                ? "daemon 未回應 pane 清單"
                : "daemon pane 清單格式無效"
            return
        }

        var map: [String: PaneInfo] = [:]
        for pane in panes { map[pane.specID] = pane }
        paneRuntime = map
        daemonNote = healthyNote
        daemonOK = true
        daemonConnectionGeneration &+= 1
        daemonReady = true
        let cbs = readyCallbacks
        readyCallbacks.removeAll()
        for cb in cbs { cb() }
    }

    func reconnectDaemon() {
        Task { @MainActor in await self.establishDaemon() }
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
        taskAISessionBaseCache = taskAISessionBaseCache.filter { current.contains($0.key) }
        diskTaskSources = diskTaskSources.filter { current.contains($0.key) }
        let known = Set(taskOrder)
        let newOnes = list.map(\.id).filter { !known.contains($0) }
        let merged = newOnes + taskOrder.filter { current.contains($0) }
        if merged != taskOrder {
            taskOrder = merged
            saveOrder()
        }
        let index = Dictionary(uniqueKeysWithValues: taskOrder.enumerated().map { ($1, $0) })
        list.sort { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
        let tasksChanged = tasks != list
        if tasksChanged { tasks = list }
        primeAIStatusIfNeeded() // the FIRST frame must not render a signal-less sidebar
        refreshDerived() // sweep below must judge on FRESH derived state
        autoArchiveSweep()
        // A rename changes the task_key → current-slug mapping while an older
        // actor load may still be in flight. Bump the reload generation now.
        if tasksChanged, statusWatcher != nil {
            scheduleAIStatusReload(after: 0.1, includeTaskSources: true)
        }
    }

    private func saveOrder() {
        try? (try? JSONEncoder().encode(taskOrder))?.write(to: Self.orderFile, options: .atomic)
    }

    func newTask() {
        let slug = store.create(named: nil)
        rescan()
        selectTask(slug)
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

    /// Read-modify-write on a CLOSED task's note. Aborts when the note exists
    /// but the read failed — transforming "" and writing it back would clobber
    /// the real note with a near-empty file.
    private func mutateNoteOnDisk(_ slug: String, _ transform: (String) -> String) {
        let text = store.read(slug)
        if text.isEmpty, FileManager.default.fileExists(atPath: store.noteURL(slug).path) {
            NSLog("TaskDeck: note mutation skipped for \(slug) — read failed")
            return
        }
        store.write(slug, transform(text))
    }

    // MARK: - Mainline priority alerts

    private func priorityAlertKey(_ task: TaskNote) -> String {
        task.permanentID ?? task.id
    }

    private func taskForPriorityAlertKey(_ key: String) -> TaskNote? {
        tasks.first { priorityAlertKey($0) == key }
    }

    /// Pending alerts in the same stable order as the sidebar.
    var priorityAlertTasks: [TaskNote] {
        tasks.filter {
            $0.status == "active"
                && $0.isMainline
                && priorityAlertKeys.contains(priorityAlertKey($0))
        }
    }

    func hasPriorityAlert(_ slug: String) -> Bool {
        guard let task = tasks.first(where: {
            $0.id == slug && $0.status == "active" && $0.isMainline
        }) else { return false }
        return priorityAlertKeys.contains(priorityAlertKey(task))
    }

    /// Selecting a task dismisses only the high-priority visual reminder. It
    /// intentionally does NOT acknowledge the AI signal or move the task out
    /// of 等你; lifecycle state remains an explicit user decision.
    func selectTask(_ slug: String) {
        selection = slug
        dismissPriorityAlert(slug)
    }

    /// Banner action from either the main window or a task popout: switch the
    /// main workspace to the target and bring that window forward.
    func focusPriorityTask(_ slug: String) {
        selectTask(slug)
        guard let app = NSApp else { return }
        app.windows.first(where: { $0.frameAutosaveName == "JamesDesk.main" })?
            .makeKeyAndOrderFront(nil)
        app.activate()
    }

    func dismissPriorityAlert(_ slug: String) {
        guard let task = tasks.first(where: { $0.id == slug }) else { return }
        let key = priorityAlertKey(task)
        guard priorityAlertKeys.contains(key) else { return }
        priorityAlertKeys.remove(key)
    }

    /// `priority: main` lives in the note so the designation syncs across
    /// machines. Older notes also receive a permanent id here, making any
    /// pending reminder survive a later rename.
    func setMainline(_ slug: String, _ enabled: Bool) {
        func transform(_ text: String) -> String {
            var updated = text
            if enabled {
                if (TaskStore.frontmatter(updated)["id"] ?? "").isEmpty {
                    updated = TaskStore.setFrontmatterValue(
                        updated, key: "id", value: UUID().uuidString.lowercased()
                    )
                }
                return TaskStore.setFrontmatterValue(updated, key: "priority", value: "main")
            }
            return TaskStore.removeFrontmatterKey(updated, key: "priority")
        }
        if let session = sessions[slug] {
            session.noteText = transform(session.noteText)
            session.flushNote()
        } else {
            mutateNoteOnDisk(slug, transform)
        }
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
                granted, error in
                if let error {
                    NSLog("TaskDeck: notification authorization failed: \(error)")
                } else if !granted {
                    NSLog("TaskDeck: notifications not authorized; in-app mainline alert remains active")
                }
            }
        } else {
            dismissPriorityAlert(slug)
        }
        rescan()
    }

    private func updatePriorityAlertDockBadge() {
        guard NSApp != nil else { return }
        NSApp.dockTile.badgeLabel = priorityAlertKeys.isEmpty
            ? nil : String(priorityAlertKeys.count)
        NSApp.dockTile.display()
    }

    private func clearPriorityAlertSystemNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.priorityAlertNotificationID]
        )
        center.removeDeliveredNotifications(
            withIdentifiers: [Self.priorityAlertNotificationID]
        )
    }

    private func deliverPriorityAlertNotification() {
        let pending = priorityAlertTasks
        guard !pending.isEmpty, let app = NSApp else { return }
        app.requestUserAttention(.informationalRequest)

        let content = UNMutableNotificationContent()
        content.title = "★ 主線已就緒"
        if pending.count == 1, let task = pending.first {
            content.body = task.title
        } else {
            content.body = "\(pending.count) 個主線任務正在等你"
        }
        let request = UNNotificationRequest(
            identifier: Self.priorityAlertNotificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("TaskDeck: priority notification failed: \(error)") }
        }
    }

    func archiveTask(_ slug: String) {
        sessions[slug]?.flushAll()
        for info in paneRuntime.values where paneBelongs(info, to: slug) {
            var k = WireMessage(type: "remove")
            k.paneID = info.id
            client.fire(k)
        }
        paneRuntime = paneRuntime.filter { !paneBelongs($0.value, to: slug) }
        let stamp = Self.archiveDate.string(from: Date())
        func transform(_ text: String) -> String {
            TaskStore.markArchived(text, at: stamp)
        }
        if let s = sessions[slug] {
            s.noteText = transform(s.noteText)
            s.flushNote()
        } else {
            mutateNoteOnDisk(slug, transform)
        }
        rescan()
        if selection == slug {
            selection = tasks.first(where: { $0.status == "active" && $0.id != slug })?.id
        }
    }

    func unarchiveTask(_ slug: String) {
        func transform(_ text: String) -> String { TaskStore.markActive(text) }
        if let s = sessions[slug] {
            s.noteText = transform(s.noteText)
            s.flushNote()
        } else {
            mutateNoteOnDisk(slug, transform)
        }
        rescan()
    }

    /// Delete a task outright: close its terminals, drop the machine state,
    /// move the note to the system Trash (recoverable — the note may live in
    /// a synced vault). `done` stays the archive path; this is for tasks not
    /// worth keeping at all.
    func deleteTask(_ slug: String) {
        sessions[slug]?.flushAll()
        // Transaction order: trash the note FIRST. If trashing fails we abort
        // with everything intact — the old order killed the panes and deleted
        // the machine state before attempting the trash, so a failed trash
        // left a half-dead task (terminals gone, layout gone, note stranded).
        let note = store.noteURL(slug)
        if FileManager.default.fileExists(atPath: note.path) {
            do {
                try FileManager.default.trashItem(at: note, resultingItemURL: nil)
            } catch {
                NSLog("TaskDeck: trash \(slug) failed — delete aborted, nothing touched: \(error)")
                return
            }
        }
        // Note is safely in the Trash; now clean up the rest.
        for info in paneRuntime.values where paneBelongs(info, to: slug) {
            var k = WireMessage(type: "remove")
            k.paneID = info.id
            client.fire(k)
        }
        paneRuntime = paneRuntime.filter { !paneBelongs($0.value, to: slug) }
        // Tombstone before dropping our reference: a popout window may still
        // hold this TaskSession, and its timers must not resurrect the note.
        sessions[slug]?.markDeleted()
        sessions.removeValue(forKey: slug)
        try? FileManager.default.removeItem(
            at: Paths.machineStateDir.appendingPathComponent(slug + ".json"))
        taskOrder.removeAll { $0 == slug }
        saveOrder()
        rescan()
        if selection == slug {
            selection = tasks.first(where: { $0.status == "active" })?.id
        }
    }

    /// Does this runtime pane belong to the task? Primary match is the spec id
    /// recorded in the task's machine state — pane specs are task-scoped and
    /// rename-proof. The daemon-side PaneInfo.taskID is the slug AT SPAWN TIME
    /// and goes stale on rename (archive/delete then missed every live pane);
    /// it stays only as a fallback for panes created outside the app (ctl).
    private func paneBelongs(_ info: PaneInfo, to slug: String) -> Bool {
        if let s = sessions[slug] {
            if s.machine.panes.contains(where: { $0.id == info.specID }) { return true }
        } else if store.cachedMachineState(slug).panes.contains(where: { $0.id == info.specID }) {
            return true
        }
        return info.taskID == slug
    }

    func taskHasLivePane(_ slug: String) -> Bool {
        paneRuntime.values.contains { $0.running && paneBelongs($0, to: slug) }
    }

    /// How many live terminals the delete confirmation should warn about.
    func livePaneCount(_ slug: String) -> Int {
        paneRuntime.values.filter { $0.running && paneBelongs($0, to: slug) }.count
    }

    // MARK: - Terminal activity (what each pane is running)

    /// The binaries the AI teams actually run. Every claude-family alias execs
    /// the same `claude` binary (they differ only by CLAUDE_CONFIG_DIR), so the
    /// team id is not what shows up in the process table.
    private var aiCommandNames: Set<String> {
        Set(config.teams.map { $0.kind == "claude" ? "claude" : $0.id })
    }

    private func sampleActivity() {
        guard !activitySampleInFlight else { return } // never queue up samples
        let live = paneRuntime.values.filter { $0.running && $0.pid > 0 }
        guard !live.isEmpty else {
            if !paneActivity.isEmpty { paneActivity = [:] }
            if !servicesByTask.isEmpty { servicesByTask = [:] }
            return
        }
        // Two panes cannot share a pid; the uniquing keeps a stale duplicate
        // from trapping if the daemon list lags a respawn.
        let specByPID = Dictionary(live.map { ($0.pid, $0.specID) },
                                   uniquingKeysWith: { first, _ in first })
        let commands = aiCommandNames
        activitySampleInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let sampled = await activitySampler.sample(shells: Array(specByPID.keys),
                                                       aiCommands: commands, now: Date())
            activitySampleInFlight = false
            var next: [String: PaneActivity] = [:]
            next.reserveCapacity(sampled.count)
            for (pid, activity) in sampled {
                if let spec = specByPID[pid] { next[spec] = activity }
            }
            if next != paneActivity { paneActivity = next }

            var services: [String: [PaneActivity]] = [:]
            for info in live {
                guard let activity = next[info.specID], activity.kind == .service,
                      let slug = slug(forPane: info) else { continue }
                services[slug, default: []].append(activity)
            }
            for slug in services.keys {
                services[slug]?.sort { $0.runningFor > $1.runningFor }
            }
            if services != servicesByTask { servicesByTask = services }
        }
    }

    /// Which task owns this pane. The daemon's taskID is the slug at spawn time
    /// and covers everything that was not renamed since; the spec-based match
    /// behind `paneBelongs` covers the rest.
    private func slug(forPane info: PaneInfo) -> String? {
        if tasks.contains(where: { $0.id == info.taskID }) { return info.taskID }
        return tasks.first { paneBelongs(info, to: $0.id) }?.id
    }

    struct ActivityTotals: Equatable {
        var ai = 0
        var service = 0
        var idle = 0
        var command = 0
        var residentBytes: UInt64 = 0
        var panes: Int { ai + service + idle + command }
    }

    var activityTotals: ActivityTotals {
        var totals = ActivityTotals()
        for activity in paneActivity.values {
            switch activity.kind {
            case .ai: totals.ai += 1
            case .service: totals.service += 1
            case .idle: totals.idle += 1
            case .command: totals.command += 1
            }
            totals.residentBytes += activity.residentBytes
        }
        return totals
    }

    /// Long-running commands (dev server, DB, watcher) in this task's panes,
    /// longest-running first — the ones worth noticing you left behind.
    func services(_ slug: String) -> [PaneActivity] { servicesByTask[slug] ?? [] }

    /// Every service pane with the task it belongs to, for the summary tooltip.
    func serviceOverview() -> [(task: String, activity: PaneActivity)] {
        servicesByTask.flatMap { slug, activities in
            let title = tasks.first { $0.id == slug }?.title ?? slug
            return activities.map { (task: title, activity: $0) }
        }
        .sorted { $0.activity.runningFor > $1.activity.runningFor }
    }

    // MARK: - AI status badges

    /// One AI session attributable to a task, wherever it was started.
    struct TaskAISession {
        let sid: String
        let team: String?
        let cwd: String?
    }

    /// Sources independent of hook status, cached until the note or pane
    /// model actually changes. Periodic status refreshes therefore do not
    /// re-stat/re-parse every task document.
    private struct TaskAISessionBase {
        let text: String
        let machine: TaskMachineState
        let sessions: [TaskAISession]
        let seen: Set<String>
        let references: Set<String>
    }
    private var taskAISessionBaseCache: [String: TaskAISessionBase] = [:]
    /// Periodically revalidated off-main for closed tasks. Open tasks always
    /// use their TaskSession's newer in-memory note/machine values.
    private var diskTaskSources: [String: TaskAISource] = [:]

    /// All AI sessions of a task: app-created pane specs ∪ the note's manifest
    /// lines ∪ any live-signal session whose id appears ANYWHERE in the note.
    /// The last source is what catches sessions the app never registered —
    /// started by hand in a shell pane, resumed, or pasted from `/status`
    /// ("Session ID: <uuid>") below the manifest divider — as long as the id
    /// is written somewhere in the note. Deduped by session id.
    func taskAISessions(_ slug: String) -> [TaskAISession] {
        taskAISessions(slug, statusIDs: Set(aiStatus.keys))
    }

    private func taskAISessions(_ slug: String, statusIDs: Set<String>) -> [TaskAISession] {
        let diskSource = diskTaskSources[slug]
        let machine = sessions[slug]?.machine
            ?? diskSource?.machine
            ?? store.cachedMachineState(slug)
        let text = sessions[slug]?.noteText
            ?? diskSource?.text
            ?? store.cachedRead(slug)

        let base: TaskAISessionBase
        if let cached = taskAISessionBaseCache[slug],
           cached.text == text, cached.machine == machine {
            base = cached
        } else {
            var seen = Set<String>()
            var out: [TaskAISession] = []
            for pane in machine.panes where pane.kind == "ai" {
                guard let rawSID = pane.sessionID else { continue }
                let sid = rawSID.lowercased()
                guard seen.insert(sid).inserted else { continue }
                out.append(TaskAISession(sid: sid, team: pane.team, cwd: pane.cwd))
            }
            for line in TaskStore.manifestLines(text) where line.hasPrefix("- ") {
                let parts = line.dropFirst(2).split(separator: " ").map(String.init)
                guard parts.count >= 2 else { continue }
                let sid = parts[1]
                guard (32 ... 36).contains(sid.count),
                      sid.allSatisfy({ $0.isHexDigit || $0 == "-" }),
                      seen.insert(sid.lowercased()).inserted else { continue }
                out.append(TaskAISession(sid: sid.lowercased(), team: parts[0], cwd: nil))
            }
            base = TaskAISessionBase(
                text: text, machine: machine, sessions: out, seen: seen,
                references: SessionDiscovery.references(in: text)
            )
            taskAISessionBaseCache[slug] = base
        }
        var seen = base.seen
        var out = base.sessions
        // Any known session (hook status file) whose id is written anywhere in
        // the note belongs to this task, even outside the manifest. Team is
        // unknown here but a hook signal doesn't need it (only the mtime
        // fallback does), so these still drive running / 等你 grouping.
        let referencedStatusIDs = base.references.intersection(statusIDs)
        for sid in referencedStatusIDs.sorted() where seen.insert(sid).inserted {
            out.append(TaskAISession(sid: sid, team: nil, cwd: nil))
        }
        // Sessions the hook tagged with this task (pane's TASKDECK_TASK) —
        // auto-attributed no matter how they were started, even if never
        // recorded in the note or a pane spec.
        for sid in (hookSessionsByTask[slug] ?? []).sorted() where seen.insert(sid).inserted {
            out.append(TaskAISession(sid: sid, team: nil, cwd: nil))
        }
        return out
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
        var next = ackedAI
        for s in taskAISessions(slug) {
            if let entry = statusEntry(sid: s.sid) {
                next[s.sid] = entry.ts
            }
        }
        if next != ackedAI { ackedAI = next }
        refreshDerived() // ack changes grouping (等你 → 已讀)
    }

    // MARK: - Sidebar grouping
    //（等你 / 進行中 / 已讀 / 等待外部 / 半封存 / 已完成）

    // aiRunning is signal-driven（AI 執行中）; idle is the default home —
    // new tasks, shell-only work, and expired signals（待開工）.
    // The grouping enum + rules now live in TaskDeckCore (selftested); this
    // keeps every `AppModel.SidebarGroup` / `.needsYou` reference working.
    typealias SidebarGroup = TaskGroup

    /// 半封存 threshold (GroupingRules.sinkAfter) then auto-archive into 已完成
    /// after a month of further silence (`autoArchiveSweep`).
    static let autoDoneAfter: TimeInterval = 30 * 24 * 3600

    private static let fmDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()
    private static let archiveDate: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    /// Signals older than this stop steering the sidebar either way；the
    /// real clearing mechanism is the ack（已看過）, not time.
    private static let signalWindow: TimeInterval = 7 * 24 * 3600

    /// Effective AI state for a session. The background loader combines
    /// authoritative hook signals with legacy transcript-event fallbacks.
    private func statusEntry(sid: String, now: Date = Date()) -> (state: String, ts: Date)? {
        guard let entry = aiStatus[sid],
              now.timeIntervalSince(entry.ts) < Self.signalWindow else { return nil }
        return (entry.state, entry.ts)
    }

    private func transcriptActivityRequest(
        for session: TaskAISession
    ) -> TranscriptActivityRequest? {
        guard let team = session.team,
              let dir = config.teams.first(where: { $0.id == team })?.configDir else { return nil }
        let sid = session.sid.lowercased()
        let cwdPath = Paths.expand(session.cwd ?? config.defaultCwd)
        let projectSlug = cwdPath.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let proj = URL(fileURLWithPath: Paths.expand(dir)).appendingPathComponent("projects/\(projectSlug)")
        return TranscriptActivityRequest(
            sid: sid,
            jsonlURL: proj.appendingPathComponent("\(sid).jsonl")
        )
    }

    private struct ResolvedAISession {
        let session: TaskAISession
        let entry: (state: String, ts: Date)
    }

    private func resolve(_ taskSessions: [TaskAISession], now: Date) -> [ResolvedAISession] {
        taskSessions.compactMap { session in
            guard let entry = statusEntry(sid: session.sid, now: now) else { return nil }
            return ResolvedAISession(session: session, entry: entry)
        }
    }

    private func signals(from resolved: [ResolvedAISession]) -> [SessionSignal] {
        resolved.map { item in
            SessionSignal(state: item.entry.state, ts: item.entry.ts,
                          acked: (ackedAI[item.session.sid] ?? .distantPast) >= item.entry.ts)
        }
    }

    /// Impure snapshot feeding the pure GroupingRules: each of the task's AI
    /// sessions resolved to its live signal (state + ts, only within the signal
    /// window) plus whether the user has acked it. One gather, reused by the
    /// classifier / attention / running checks so they can't drift apart.
    /// Sessions count wherever they live (pane spec or note manifest) and
    /// whether or not their pane still runs — finished output awaits review.
    func sessionSignals(_ slug: String) -> [SessionSignal] {
        let now = Date()
        return signals(from: resolve(taskAISessions(slug), now: now))
    }

    /// Seconds since the task last showed life (newest signal / group_since),
    /// for the sink threshold — computed from an already-gathered snapshot.
    private func quietSeconds(_ t: TaskNote, signals: [SessionSignal]) -> TimeInterval {
        var candidates = signals.map(\.ts)
        if let s = t.groupSince.flatMap({ Self.fmDate.date(from: $0) }) { candidates.append(s) }
        guard let last = candidates.max() else { return 0 }
        return Date().timeIntervalSince(last)
    }

    /// The strongest unacked "ball is in your court" signal (permission beats
    /// waiting; `since` = oldest, FIFO by how long you've been owed).
    func aiAttention(_ slug: String) -> (permission: Bool, since: Date)? {
        if let d = derivedCache[slug] { return d.attention }
        return GroupingRules.attention(sessionSignals(slug)) // cold-cache fallback
    }

    // Per-task derived display values, recomputed OFF the render path (only in
    // rescan / status-snapshot apply / ackAIStatus). View bodies read this cache, so a
    // keystroke or a sidebar hover no longer re-runs the disk-touching gather
    // for every task. The 20s status reload is the freshness backstop.
    private struct Derived {
        let group: SidebarGroup
        let attention: (permission: Bool, since: Date)?
        let activeTeam: String?
        let mainTeam: String?          // 主力 (manual) ?? 現用 — the sidebar's "主 AI"
        let backgroundCount: Int       // informational only; never drives grouping
        let lastActivity: Date?        // for silence(); cached so the sidebar sort
                                       // (re-run on every hover) does zero disk I/O
    }
    private var derivedCache: [String: Derived] = [:]

    @discardableResult
    private func refreshDerived(allowPriorityAlertTriggers: Bool = true) -> Bool {
        let now = Date()
        let statusIDs = Set(aiStatus.keys)
        var cache: [String: Derived] = [:]
        cache.reserveCapacity(tasks.count)
        for t in tasks {
            let taskSessions = taskAISessions(t.id, statusIDs: statusIDs)
            let resolved = resolve(taskSessions, now: now)
            let taskSignals = signals(from: resolved)
            var when = taskSignals.map(\.ts)
            if let s = t.groupSince.flatMap({ Self.fmDate.date(from: $0) }) { when.append(s) }
            let lastActivity = when.max()
            let group = GroupingRules.classify(status: t.status, group: t.group,
                                               quiet: lastActivity.map { now.timeIntervalSince($0) } ?? 0,
                                               signals: taskSignals, now: now)
            let active = computeActiveTeam(resolved)
            let backgroundCount = taskSessions.reduce(into: 0) { count, session in
                count += backgroundTasksBySession[session.sid] ?? 0
            }
            cache[t.id] = Derived(group: group,
                                  attention: GroupingRules.attention(taskSignals),
                                  activeTeam: active,
                                  mainTeam: primaryTeam(t.id) ?? active,
                                  backgroundCount: backgroundCount,
                                  lastActivity: lastActivity)
        }
        reconcilePriorityAlerts(current: cache, allowTriggers: allowPriorityAlertTriggers)
        guard !Self.derivedCachesEqual(derivedCache, cache) else { return false }
        objectWillChange.send()
        derivedCache = cache
        return true
    }

    /// Keep pending reminders honest and detect only the real rising edge.
    /// Validation also clears the reminder when a task starts running again,
    /// is untagged, completed, deleted, or otherwise leaves 等你.
    private func reconcilePriorityAlerts(current: [String: Derived],
                                         allowTriggers: Bool) {
        var currentGroups: [String: SidebarGroup] = [:]
        for task in tasks {
            if let group = current[task.id]?.group {
                currentGroups[priorityAlertKey(task)] = group
            }
        }
        defer { priorityAlertGroupCache = currentGroups }
        guard hasLoadedAIStatusSnapshot else { return }

        var next = Set(priorityAlertKeys.filter { key in
            guard let task = taskForPriorityAlertKey(key),
                  task.isMainline,
                  currentGroups[key] == .needsYou else { return false }
            return true
        })
        var newlyTriggered: [TaskNote] = []
        if allowTriggers {
            for task in tasks {
                let key = priorityAlertKey(task)
                guard let oldGroup = priorityAlertGroupCache[key],
                      let newGroup = currentGroups[key],
                      current[task.id]?.attention != nil else { continue }
                if PriorityAlertRules.shouldTrigger(
                    isMainline: task.isMainline,
                    previous: oldGroup,
                    current: newGroup,
                    isCurrentlyViewed: isCurrentlyViewing(task)
                ), next.insert(key).inserted {
                    newlyTriggered.append(task)
                }
            }
        }

        if next != priorityAlertKeys { priorityAlertKeys = next }
        guard !newlyTriggered.isEmpty else { return }
        priorityAlertPulse &+= 1
        if !(NSApp?.isActive ?? false) {
            deliverPriorityAlertNotification()
        }
    }

    /// A selected slug is only truly "being viewed" when its actual window is
    /// key. This avoids suppressing alerts while the user works in a different
    /// task popout (and recognizes a popout already showing this same task).
    private func isCurrentlyViewing(_ task: TaskNote) -> Bool {
        guard let app = NSApp, app.isActive, let window = app.keyWindow else { return false }
        switch window.frameAutosaveName {
        case "JamesDesk.main":
            return selection == task.id
        case "JamesDesk.task.\(task.id)":
            return true
        default:
            return false
        }
    }

    private static func derivedCachesEqual(_ lhs: [String: Derived],
                                           _ rhs: [String: Derived]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (slug, a) in lhs {
            guard let b = rhs[slug],
                  a.group == b.group,
                  a.activeTeam == b.activeTeam,
                  a.mainTeam == b.mainTeam,
                  a.backgroundCount == b.backgroundCount,
                  a.lastActivity == b.lastActivity,
                  a.attention?.permission == b.attention?.permission,
                  a.attention?.since == b.attention?.since else { return false }
        }
        return true
    }

    /// Manually designated 主力 (quota home) from machine state; in-memory for
    /// the open task, else read off disk (only here, off the render path).
    private func primaryTeam(_ slug: String) -> String? {
        (sessions[slug]?.machine
            ?? diskTaskSources[slug]?.machine
            ?? store.cachedMachineState(slug)).primaryTeam
    }

    /// The task's "主 AI" for the sidebar: manual 主力 if set, else 現用.
    func mainTeam(_ slug: String) -> String? { derivedCache[slug]?.mainTeam }

    /// Informational count of Claude-native background tasks. It is orthogonal
    /// to ownership/attention, so "等你 · 背景 1" is a valid simultaneous state.
    func backgroundTaskCount(_ slug: String) -> Int {
        if let derived = derivedCache[slug] { return derived.backgroundCount }
        return taskAISessions(slug).reduce(into: 0) { count, session in
            count += backgroundTasksBySession[session.sid] ?? 0
        }
    }

    /// Cached last-activity instant — a STABLE sort key for the sidebar.
    /// (Sorting by silence() embedded a fresh now() in every comparison, so
    /// keys shifted between comparisons and near-tied rows swapped places on
    /// every hover re-sort.)
    func lastActivity(_ slug: String) -> Date? { derivedCache[slug]?.lastActivity }

    /// Ground-truth account for a session: which team's CLAUDE_CONFIG_DIR
    /// actually holds its conversation record. Beats the manifest's recorded
    /// team, which is only a guess at creation and wrong whenever the session
    /// was started/switched to another account by hand (平滑著色: manifest
    /// said claude, the record lived in claude-team3). The record is stored
    /// per project cwd as either `<sid>.jsonl` (older) or a `<sid>` directory
    /// (this claude version) — match both. nil = unknown.
    // Positive results live for the process (a conversation doesn't move
    // accounts); misses retry after a backoff. Crucially, lookup is cache-only
    // on the main actor: directory traversal happens in a detached task.
    private var teamFileCache: [String: (team: String?, at: Date)] = [:]
    private var pendingTeamFileLookups = Set<String>()
    private var queuedTeamFileLookups = Set<String>()
    private var teamFileLookupTask: Task<Void, Never>?
    private static let missingTeamRetry: TimeInterval = 5

    func teamFromSessionFile(_ sid: String) -> String? {
        cachedTeamsFromSessionFiles([sid])[sid.lowercased()]
    }

    /// Batch cache lookup used by the resume menu. Missing ids are resolved
    /// together in the background; this function never performs file I/O.
    func cachedTeamsFromSessionFiles(_ sessionIDs: [String]) -> [String: String] {
        let ids = Set(sessionIDs.map { $0.lowercased() })
        let now = Date()
        var found: [String: String] = [:]
        var missing = Set<String>()
        for sid in ids {
            if let cached = teamFileCache[sid] {
                if let team = cached.team {
                    found[sid] = team
                    continue
                }
                if now.timeIntervalSince(cached.at) < Self.missingTeamRetry { continue }
            }
            if !pendingTeamFileLookups.contains(sid) { missing.insert(sid) }
        }
        scheduleTeamFileLookup(missing)
        return found
    }

    private func scheduleTeamFileLookup(_ sessionIDs: Set<String>) {
        guard !sessionIDs.isEmpty else { return }
        pendingTeamFileLookups.formUnion(sessionIDs)
        queuedTeamFileLookups.formUnion(sessionIDs)
        beginTeamFileLookupIfNeeded()
    }

    /// Coalesce cache misses from all task rows / pane headers / resume menus
    /// into one directory traversal. A cold launch used to start one full
    /// 100+-project scan per visible session.
    private func beginTeamFileLookupIfNeeded() {
        guard teamFileLookupTask == nil, !queuedTeamFileLookups.isEmpty else { return }
        teamFileLookupTask = Task { [weak self] in
            // Let one SwiftUI update enqueue every visible session first.
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self else { return }
            let sessionIDs = queuedTeamFileLookups
            queuedTeamFileLookups.removeAll()
            let roots = sessionTeamRoots()
            let resolved = await Task.detached(priority: .utility) {
                SessionDiscovery.resolveTeams(sessionIDs: sessionIDs, roots: roots)
            }.value
            let stamp = Date()
            var gainedResult = false
            for sid in sessionIDs {
                let team = resolved[sid]
                if team != nil, teamFileCache[sid]?.team != team { gainedResult = true }
                teamFileCache[sid] = (team, stamp)
                pendingTeamFileLookups.remove(sid)
            }
            teamFileLookupTask = nil
            beginTeamFileLookupIfNeeded()
            // Active-team chips and resume rows may both depend on this cache.
            // Publish only when the derived active/main team really changed.
            // Resume-menu content is evaluated again when the menu opens, so
            // a same-team cache warm-up does not justify rebuilding the app.
            if gainedResult, !refreshDerived() {
                // No active/main-team field changed, but resume rows and pane
                // headers read this cache directly.
                objectWillChange.send()
            }
        }
    }

    private func sessionTeamRoots() -> [SessionDiscovery.TeamRoot] {
        config.teams.compactMap { team in
            guard let dir = team.configDir else { return nil }
            return SessionDiscovery.TeamRoot(
                team: team.id,
                projects: URL(fileURLWithPath: Paths.expand(dir)).appendingPathComponent("projects")
            )
        }
    }

    /// Recent conversations on disk for `cwd`, across every team account —
    /// (team, sid, modified). Powers the pane "rebind to the real session"
    /// picker when the app's recorded session drifted from what's running.
    private var recentCache: [String: (rows: [SessionDiscovery.RecentSession], at: Date)] = [:]
    private var pendingRecentLookups = Set<String>()

    func recentSessions(cwd: String, limit: Int = 10) -> [SessionDiscovery.RecentSession] {
        let ckey = "\(cwd)#\(limit)"
        if let cached = recentCache[ckey] {
            if Date().timeIntervalSince(cached.at) >= 10 {
                scheduleRecentLookup(cwd: cwd, limit: limit, cacheKey: ckey)
            }
            return cached.rows
        }
        scheduleRecentLookup(cwd: cwd, limit: limit, cacheKey: ckey)
        return []
    }

    private func scheduleRecentLookup(cwd: String, limit: Int, cacheKey: String) {
        guard pendingRecentLookups.insert(cacheKey).inserted else { return }
        let roots = sessionTeamRoots()
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) {
                SessionDiscovery.recentSessions(cwd: cwd, roots: roots, limit: limit)
            }.value
            guard let self else { return }
            let changed = recentCache[cacheKey]?.rows != rows
            if changed { objectWillChange.send() }
            recentCache[cacheKey] = (rows, Date())
            pendingRecentLookups.remove(cacheKey)
        }
    }

    /// The account currently working on the task — "現用" in the header chip.
    /// The freshest-signal session's REAL account (resolved from its file
    /// location), falling back to the manifest team only when the file can't
    /// be found. Display-only: never rewrites primaryTeam (主力 is the manual
    /// quota home).
    func activeTeam(_ slug: String) -> String? { derivedCache[slug]?.activeTeam }

    private func computeActiveTeam(_ resolved: [ResolvedAISession]) -> String? {
        var best: (ts: Date, sid: String, team: String?)?
        for item in resolved {
            let candidate = (item.entry.ts, item.session.sid, item.session.team)
            if best == nil || candidate.0 > best!.ts {
                best = candidate
            }
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
        GroupingRules.runningNow(sessionSignals(slug), now: Date())
    }

    /// Does the task have an AI stop signal the user already acknowledged
    /// (= "已讀"：看過了、還沒給下一步)?
    private func hasAckedStop(_ slug: String) -> Bool {
        GroupingRules.hasAckedStop(sessionSignals(slug))
    }

    /// Seconds since the task last showed any sign of life（hook 訊號 or
    /// entering its manual group）。nil = can't tell (treat as fresh).
    func silence(_ t: TaskNote) -> TimeInterval? {
        // Read the cached last-activity (recomputed off the render path) and
        // subtract now — cheap + always fresh. The sidebar's 已讀 sort calls
        // this per comparison on every hover; hitting disk here delayed the
        // hover highlight until the sort finished.
        if let d = derivedCache[t.id] { return d.lastActivity.map { Date().timeIntervalSince($0) } }
        var candidates = sessionSignals(t.id).map(\.ts) // cold-cache fallback
        if let s = t.groupSince.flatMap({ Self.fmDate.date(from: $0) }) { candidates.append(s) }
        return candidates.max().map { Date().timeIntervalSince($0) }
    }

    // Grouping model (260720 v3) now lives in TaskDeckCore.GroupingRules
    // (selftested); this gathers the live snapshot once and delegates.
    func sidebarGroup(_ t: TaskNote) -> SidebarGroup {
        if let d = derivedCache[t.id] { return d.group }
        // Cold-cache fallback (before the first refresh); refreshDerived caches it.
        let signals = sessionSignals(t.id)
        return GroupingRules.classify(status: t.status, group: t.group,
                                      quiet: quietSeconds(t, signals: signals),
                                      signals: signals, now: Date())
    }

    /// Manual move targets (frontmatter `group`): the value to store and the
    /// section it lands in. AI 執行中 / 半封存 are live/derived (not hand-set),
    /// and 待開工 is the no-activity default you fall into, not a target.
    static let manualMoveTargets: [(label: String, value: String?, group: SidebarGroup)] = [
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
            mutateNoteOnDisk(slug, transform)
        }
        // Marking 已讀/等待外部 acknowledges the current AI output, so it won't
        // immediately bounce back to 等你; only a genuinely newer turn will.
        // (等你/待開工 don't ack — they should keep showing pending signals.)
        if flag == "read" || flag == "waiting" { ackAIStatus(slug) }
        rescan()
    }

    /// 半封存超過一個月 → 自動歸入已完成，並在筆記留下可追溯的備註。
    /// Runs on every rescan; idempotent (done tasks are skipped, the
    /// annotation is stamped once via the auto_archived frontmatter key).
    private func autoArchiveSweep() {
        // Archiving rewrites the user's note and moves the task into 已完成, so
        // it must never judge on a signal-less view of the world: before the
        // status picture is loaded, a task parked months ago but worked on
        // yesterday looks like it has been silent the whole time.
        guard hasAIStatusPicture else { return }
        for t in tasks where t.status == "active" {
            guard sidebarGroup(t) == .semiArchived,
                  let quiet = silence(t), quiet > Self.autoDoneAfter else { continue }
            // A live terminal (dev server ticking along, shell mid-work) means
            // the task isn't abandoned even if no AI signal moved for a month.
            guard !taskHasLivePane(t.id) else { continue }
            var text = sessions[t.id]?.noteText ?? store.read(t.id)
            // Empty read of an existing note = failed read; writing the
            // archive annotation would clobber the note.
            if text.isEmpty, FileManager.default.fileExists(atPath: store.noteURL(t.id).path) { continue }
            guard TaskStore.frontmatter(text)["auto_archived"] == nil else { continue }
            let stamp = Self.archiveDate.string(from: Date())
            text = TaskStore.markArchived(text, at: stamp, automatic: true)
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
        setCloseOnExec(statusFD)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: statusFD, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            self?.scheduleAIStatusReload(after: 0.1, includeTaskSources: false)
        }
        src.activate()
        statusWatcher = src
    }

    /// task_key (permanent frontmatter uuid) → CURRENT slug. The slug the hook
    /// recorded goes stale on rename; the uuid does not. Duplicated ids (a note
    /// copied by hand) keep the first task rather than trapping.
    private func taskKeyToSlug() -> [String: String] {
        Dictionary(tasks.compactMap { task in task.permanentID.map { ($0, task.id) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Read the hook status files synchronously, once, before the first frame.
    ///
    /// Sidebar groups are signal-driven: with no status loaded, every task that
    /// owes the user a review falls back to its manual frontmatter flag, so 等你
    /// renders empty and its tasks sit in 待開工 / 已讀 / 等待外部 / 半封存. The
    /// loader that fills this in is async and can only resume once the main
    /// actor is free — at launch that is after the daemon handshake and the
    /// terminal restores, i.e. long enough to see and act on the wrong groups.
    /// The directory is a handful of small JSON files (all the expensive
    /// transcript work stays on the async pass), so reading it here costs a few
    /// ms and makes the first render already correct.
    private func primeAIStatusIfNeeded() {
        guard !hasAIStatusPicture else { return }
        // An unreadable directory is transient: claim no picture and let the
        // async loader (or the next rescan) establish it.
        guard let scan = AIStatusFiles.scan(directory: Paths.statusDir,
                                            keyToSlug: taskKeyToSlug(),
                                            now: Date(),
                                            signalWindow: Self.signalWindow) else { return }
        aiStatus = scan.records.mapValues { AIStatusEntry(state: $0.state, ts: $0.ts) }
        hookSessionsByTask = scan.sessionsByTask
        hasAIStatusPicture = true
    }

    private func scheduleAIStatusReload(after delay: TimeInterval = 0,
                                        includeTaskSources: Bool) {
        statusReloadGeneration &+= 1
        let generation = statusReloadGeneration
        statusReloadTask?.cancel()
        let keyToSlug = taskKeyToSlug()
        let loader = statusLoader
        let statusDirectory = Paths.statusDir
        let statusIDs = Set(aiStatus.keys)
        let transcriptRequests = tasks.flatMap { task in
            taskAISessions(task.id, statusIDs: statusIDs).compactMap {
                transcriptActivityRequest(for: $0)
            }
        }
        let sourceRequests: [TaskAISourceRequest]?
        if includeTaskSources {
            let machineDirectory = Paths.machineStateDir
            sourceRequests = tasks.map { task in
                TaskAISourceRequest(
                    slug: task.id,
                    noteURL: store.noteURL(task.id),
                    machineURL: machineDirectory.appendingPathComponent(task.id + ".json")
                )
            }
        } else {
            sourceRequests = nil
        }
        statusReloadTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let snapshot = await loader.load(
                from: statusDirectory, keyToSlug: keyToSlug,
                taskSourceRequests: sourceRequests,
                transcriptRequests: transcriptRequests,
                now: Date(), signalWindow: Self.signalWindow
            )
            guard let self, !Task.isCancelled,
                  generation == statusReloadGeneration else { return }
            guard let snapshot else {
                // Preserve the last known status on transient I/O failure, but
                // still advance purely time-based grouping thresholds.
                refreshDerived()
                return
            }
            applyAIStatus(snapshot)
        }
    }

    private func applyAIStatus(_ snapshot: AIStatusSnapshot) {
        // The first loaded snapshot establishes a baseline. It may validate a
        // persisted reminder, but must not replay a completion pulse merely
        // because the app was relaunched after that completion.
        let allowPriorityAlertTriggers = hasLoadedAIStatusSnapshot
        hasLoadedAIStatusSnapshot = true
        hasAIStatusPicture = true
        // A session that ends without a new turn (pane closed, daemon
        // restarted) re-stamps its status file; an acknowledgement made
        // against the earlier stamp must survive that, or every 已讀 task in
        // the app flips back to 等你 in one go. Compared against the PREVIOUS
        // snapshot, so it must run before aiStatus is replaced.
        let carried = AIStatusAcknowledgementRules.carryingForward(
            ackedAI,
            previous: aiStatus.mapValues { (state: $0.state, ts: $0.ts) },
            next: snapshot.statusBySession.mapValues { (state: $0.state, ts: $0.ts) }
        )
        if carried != ackedAI { ackedAI = carried }
        if aiStatus != snapshot.statusBySession {
            aiStatus = snapshot.statusBySession
        }
        if hookSessionsByTask != snapshot.sessionsByTask {
            hookSessionsByTask = snapshot.sessionsByTask
        }
        if backgroundTasksBySession != snapshot.backgroundTasksBySession {
            backgroundTasksBySession = snapshot.backgroundTasksBySession
        }
        if let loadedSources = snapshot.taskSources {
            // Merge instead of replacing: a transient read/decode failure for
            // one file intentionally omits that row, preserving its last good
            // source until a later validation succeeds.
            let currentSlugs = Set(tasks.map(\.id))
            var nextSources = diskTaskSources.filter { currentSlugs.contains($0.key) }
            for (slug, source) in loadedSources where currentSlugs.contains(slug) {
                nextSources[slug] = source
            }
            if nextSources != diskTaskSources { diskTaskSources = nextSources }
        }
        // Bound the persisted dictionary by the same signal window used for
        // grouping. Do not prune by hook-file presence: legacy sessions use a
        // transcript-event fallback, and their acknowledgement must survive
        // periodic hook snapshots that naturally contain no row for them.
        let nextAcked = AIStatusAcknowledgementRules.prune(
            ackedAI, now: Date(), signalWindow: Self.signalWindow
        )
        if nextAcked != ackedAI { ackedAI = nextAcked }
        refreshDerived(allowPriorityAlertTriggers: allowPriorityAlertTriggers)
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
        setCloseOnExec(dirFD)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRescan() }
        src.activate()
        dirWatcher = src
    }

    private func scheduleRescan() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.rescanTimer = nil
                self?.rescan()
            }
        }
    }

    // MARK: - Quota

    /// `force` = a manual refresh: bypass the quota tool's cache so the button
    /// actually re-fetches. Auto refreshes (timer / launch) keep the
    /// configured `--max-age` so they share the cache and don't hit the API
    /// rate limit. Appending `--max-age 0` wins over any configured value.
    func refreshQuota(force: Bool = false) {
        guard var cmd = config.quotaCommand, !cmd.isEmpty, !quotaBusy else { return }
        if force { cmd += " --max-age 0" }
        quotaBusy = true
        Task.detached(priority: .utility) {
            // Unique per invocation: a fixed /tmp path collided across
            // instances and could serve another run's stale error text.
            let errPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("taskdeck-quota-\(UUID().uuidString).err").path
            defer { try? FileManager.default.removeItem(atPath: errPath) }
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
                // Watchdog: a hung quota CLI must not pin quotaBusy=true forever
                // (which would block every later refresh until the GUI restarts).
                let watchdog = Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                watchdog.cancel()
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
        didSet { if !suppressSave { scheduleNoteSave() } }
    }
    /// True while applying an external (on-disk) note change, so the reload
    /// doesn't schedule a save-back.
    private var suppressSave = false

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
    /// The note content we last synced with disk (loaded, saved, or reloaded).
    /// Lets flushNote detect a concurrent external edit: disk ≠ base = someone
    /// (Obsidian, vault sync) wrote since we last looked.
    private var baseText: String
    /// Tombstone: the task was deleted while this session object may still be
    /// referenced (popout window, timers). All saves become no-ops so a stray
    /// flush can't resurrect the trashed note.
    private(set) var deleted = false
    /// The initial disk read failed on an EXISTING file (permissions, vault
    /// lock, encoding). Saving would overwrite the real note with emptiness —
    /// suppress all note saves until a later reload succeeds.
    private var noteLoadFailed = false

    init(slug: String, app: AppModel) {
        self.slug = slug
        self.app = app
        let loaded = app.store.read(slug)
        if loaded.isEmpty,
           FileManager.default.fileExists(atPath: app.store.noteURL(slug).path) {
            // Existing note but empty read = failed read until proven otherwise.
            noteLoadFailed = true
            NSLog("TaskDeck: note read failed for \(slug); saves suppressed until a reload succeeds")
        }
        noteText = loaded
        baseText = loaded
        machine = app.store.machineState(slug)
        autoStartPanes()
    }

    func markDeleted() { deleted = true }

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
        guard !deleted, !noteLoadFailed else { return } // tombstone / failed load
        let disk = app.store.read(slug)
        // Never let a stale in-memory copy destroy session ids that are
        // already on disk (vault sync / second instance / crash races) —
        // James lost a claude-eng id to exactly this class of race.
        let merged = TaskStore.mergeManifestLines(disk: disk, into: noteText)
        if merged != noteText { noteText = merged }
        // Concurrent-edit guard: disk moved since our last sync AND we hold
        // local edits. The manifest merge above rescues session ids, but the
        // external BODY edit would be silently overwritten — keep a recovery
        // copy in the vault (visible in Obsidian, not scanned as a task).
        if !disk.isEmpty, disk != baseText, disk != merged {
            app.store.writeConflictCopy(slug, disk)
        }
        if disk != merged {
            app.store.write(slug, merged)
        }
        baseText = merged
    }

    /// User-typed one-line status (frontmatter `latest`), shown under the
    /// sidebar title. Free text; empty clears it.
    var latestStatus: String { TaskStore.frontmatter(noteText)["latest"] ?? "" }

    /// Full status history (newest first) from the note's `## 狀態` log.
    var statusHistory: [String] { TaskStore.statusHistory(noteText) }

    /// Record a status update. Smart timestamp: if the text already starts
    /// with a manual stamp (e.g. "2607221046 …") it's kept as-is; otherwise
    /// `statusStamp()` is prepended. Updates the sidebar `latest` and prepends
    /// a history line to `## 狀態`. Empty clears `latest` (history untouched).
    /// Re-committing the same text (blur/re-open) is a no-op, so no dup logs.
    func setLatestStatus(_ s: String) {
        let raw = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let cur = TaskStore.frontmatter(noteText)["latest"] ?? ""
        if raw.isEmpty {
            guard !cur.isEmpty else { return }
            noteText = TaskStore.removeFrontmatterKey(noteText, key: "latest")
            flushNote(); app.rescan()
            return
        }
        // No-op only when the WHOLE entry (stamp included) is unchanged, so a
        // blur/re-open re-commit doesn't re-log — but editing just the stamp
        // (39→46) still goes through, which comparing stamp-stripped text wrongly blocked.
        guard raw != cur else { return }
        let entry = TaskStore.statusHasStamp(raw) ? raw : TaskStore.statusStamp() + " " + raw
        guard entry != cur else { return }
        noteText = TaskStore.setFrontmatterValue(noteText, key: "latest", value: entry)
        // Same message, only the stamp/wording changed → edit that log line in
        // place (no duplicate). A genuinely new message prepends a fresh line.
        if !cur.isEmpty, TaskStore.statusText(entry) == TaskStore.statusText(cur),
           let edited = TaskStore.replaceStatusLogEntry(noteText, old: cur, new: entry) {
            noteText = edited
        } else {
            noteText = TaskStore.prependStatusLog(noteText, entry: entry)
        }
        flushNote()
        app.rescan() // refresh the sidebar row immediately
    }

    /// Pick up edits made to the note OUTSIDE the app (Obsidian, vault sync):
    /// manually-added session ids, resource links, notes. Skipped when an
    /// in-app edit is pending so we never clobber unsaved typing; the reload
    /// itself doesn't schedule a save-back. Re-deriving noteText refreshes
    /// grouping / 現用 / the 續上 list, since taskAISessions reads it.
    func reloadFromDiskIfChanged() {
        guard !deleted else { return }
        guard noteTimer == nil else { return } // pending in-app edit wins
        let disk = app.store.read(slug)
        guard !disk.isEmpty else { return }
        noteLoadFailed = false // a successful read lifts the failed-load latch
        guard disk != noteText else { baseText = disk; return }
        suppressSave = true
        noteText = disk
        suppressSave = false
        baseText = disk
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
        guard !deleted else { return }
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

    /// Session ids written anywhere in the note that map to a real on-disk
    /// conversation but aren't already an open pane — i.e. sessions the app
    /// didn't create (started by hand in a shell, pasted from `/status`,
    /// left over after a reboot). Each carries the account resolved from its
    /// file location, so resuming uses the right claude. Lets the user get
    /// back into a task's conversation the app was never told about.
    func resumableSessions() -> [(sid: String, team: String)] {
        let openSids = Set(machine.panes.compactMap { $0.sessionID })
        let ids = SessionDiscovery.resumableReferences(
            in: noteText, openSessionIDs: openSids
        )
        let teams = app.cachedTeamsFromSessionFiles(ids)
        return ids.compactMap { sid in teams[sid].map { (sid, $0) } }
    }

    /// Open a pane that resumes an existing session under its real account
    /// (`<team> -r <sid>` succeeds because the conversation exists).
    func resumeSession(sid: String, team: String) {
        let args = app.config.teams.first(where: { $0.id == team })?.args
        add(PaneSpec(title: team, kind: "ai", team: team, sessionID: sid, extraArgs: args))
    }

    /// Point an AI pane's spec at the account/session it's ACTUALLY running,
    /// when it drifted from what the app pre-generated (user ran a different
    /// claude by hand, resumed another session, etc.). Fixes attribution so
    /// the task's group / 現用 / badge reflect reality — without restarting
    /// the live pane. Also records the id in the note manifest so it survives
    /// reboots. `sid` nil = just correct the account label.
    func rebindPane(specID: String, team: String, sid: String?) {
        guard let i = machine.panes.firstIndex(where: { $0.id == specID }) else { return }
        machine.panes[i].team = team
        machine.panes[i].extraArgs = app.config.teams.first(where: { $0.id == team })?.args
        if let sid, !sid.isEmpty {
            machine.panes[i].sessionID = sid
            if !TaskStore.manifestLines(noteText).contains(where: { $0.contains(sid) }) {
                noteText = TaskStore.appendSessionLine(noteText, line: "- \(team) \(sid)")
            }
        }
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
        // Persist BEFORE spawning: the note manifest (AI session id) and the
        // machine spec used to sit in 0.8s/0.5s save debounces while the pane
        // started immediately — a GUI crash in that window left a live
        // conversation no note or spec knew about.
        flushAll()
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

    /// Spec IDs with an in-flight newPane request — a second click / a racing
    /// auto-start must coalesce instead of spawning a duplicate.
    private var pendingCreate: Set<String> = []

    func startPane(_ spec: PaneSpec) {
        guard app.daemonReady else { return } // wait for hello + reconciliation
        guard !pendingCreate.contains(spec.id) else { return }
        if app.paneRuntime[spec.id]?.running == true { return } // already live
        pendingCreate.insert(spec.id)
        var m = WireMessage(type: "newPane")
        m.taskID = slug
        m.specID = spec.id
        m.title = spec.title
        m.cwd = Paths.expand(spec.cwd ?? app.config.defaultCwd)
        m.shell = app.config.shell
        m.cols = 100
        m.rows = 28
        m.command = spec.startCommand
        // Rename-proof attribution: TASKDECK_TASK (slug) goes stale when the
        // task is renamed; the permanent frontmatter uuid doesn't. The status
        // hook records both; the GUI prefers the key when resolving.
        m.env = ["TASKDECK_TASK_KEY": permanentID()]
        app.client.request(m) { [weak self] resp in
            Task { @MainActor in
                guard let self else { return }
                self.pendingCreate.remove(spec.id)
                guard let info = resp?.panes?.first else { return }
                // Closed/deleted while the request was in flight → the fresh
                // pane has no home; remove it instead of leaving an invisible
                // live terminal in the daemon.
                guard self.machine.panes.contains(where: { $0.id == spec.id }) else {
                    var k = WireMessage(type: "remove")
                    k.paneID = info.id
                    self.app.client.fire(k)
                    return
                }
                self.app.paneRuntime[info.specID] = info
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
        // Gate on full reconciliation (hello + list applied): auto-starting
        // against an empty paneRuntime duplicated panes that were actually
        // alive in the daemon. If not ready yet, run once it is.
        guard app.daemonReady else {
            app.onDaemonReady { [weak self] in self?.autoStartPanes() }
            return
        }
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
