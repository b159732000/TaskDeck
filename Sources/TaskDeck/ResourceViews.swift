import AppKit
import SwiftUI
import TaskDeckCore

// MARK: - Feature-usage tally（James 想觀察哪些功能真的有在用）

/// Appends {action: {count, last}} to App Support/usage.json. Read it later
/// to decide whether a feature (e.g. 關閉資源視窗) earns its keep.
enum UsageLog {
    static func bump(_ action: String) {
        let url = Paths.appSupport.appendingPathComponent("usage.json")
        var dict = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)))
            as? [String: [String: Double]] ?? [:]
        var entry = dict[action] ?? [:]
        entry["count"] = (entry["count"] ?? 0) + 1
        entry["last"] = Date().timeIntervalSince1970
        dict[action] = entry
        if let data = try? JSONSerialization.data(withJSONObject: dict,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

// MARK: - Safari (AppleScript, read-only)

/// Safari windows/tabs via AppleScript — Slack has no such surface, so Slack
/// resources stay hand-written permalinks (opened as deep links). First use
/// triggers macOS's "control Safari" automation prompt.
enum SafariScript {
    struct Window: Identifiable, Equatable {
        let id: Int
        var tabs: [(title: String, url: String)]

        static func == (a: Window, b: Window) -> Bool {
            a.id == b.id && a.tabs.map(\.url) == b.tabs.map(\.url)
        }
    }

    /// Raise the Safari window containing a tab that matches one of the
    /// task's Safari resource URLs (prefix match either way — live URLs grow
    /// query strings). Returns false when Safari isn't running or nothing
    /// matches; the caller then just activates Safari.
    static func bringToFront(matching urls: [String]) -> Bool {
        guard !urls.isEmpty,
              !NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.Safari").isEmpty else { return false }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let items = urls.map { "\"" + esc($0) + "\"" }.joined(separator: ", ")
        let script = """
        set targets to {\(items)}
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t as string
                    repeat with tgt in targets
                        set tgtStr to tgt as string
                        if (u starts with tgtStr) or (tgtStr starts with u) then
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return "HIT"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "MISS"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").contains("HIT")
    }

    static func windows() -> [Window] {
        // `tell app "Safari"` would LAUNCH Safari when it isn't running.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Safari")
        guard !running.isEmpty else { return [] }

        let script = """
        set out to ""
        tell application "Safari"
            repeat with w in windows
                set out to out & "WINDOW " & (id of w) & linefeed
                repeat with t in tabs of w
                    set out to out & (URL of t) & tab & (name of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var out: [Window] = []
        for line in (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "\n") {
            if line.hasPrefix("WINDOW ") {
                out.append(Window(id: Int(line.dropFirst(7)) ?? (out.count + 1), tabs: []))
            } else if !out.isEmpty, let tab = line.firstIndex(of: "\t") {
                let url = String(line[..<tab]).trimmingCharacters(in: .whitespaces)
                guard url.contains("://") else { continue }
                out[out.count - 1].tabs.append(
                    (title: String(line[line.index(after: tab)...]), url: url))
            }
        }
        return out.filter { !$0.tabs.isEmpty }
    }
}

/// The debug-profile Chrome's app process (matched by its debug port, so the
/// user's daily Chrome is never touched). Runs pgrep off the main thread.
private func devChromeApp(port: Int) async -> NSRunningApplication? {
    let pids: [pid_t] = await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "remote-debugging-port=\(port)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }.value
    // Helpers share the command line; the browser process is the one that is
    // an actual app (bundle com.google.Chrome).
    for pid in pids {
        if let app = NSRunningApplication(processIdentifier: pid),
           app.bundleIdentifier == "com.google.Chrome" {
            return app
        }
    }
    return nil
}

// MARK: - Open / snapshot / close actions (per task)

extension TaskSession {
    var resources: [TaskResource] { ResourceOps.parse(noteText) }

    /// Open every resource in the note's `## Resources` section:
    /// Chrome URLs through the user's debug-profile launch command (one new
    /// window per task), Safari URLs via AppleScript (one new window),
    /// Slack permalinks as app deep links. Returns a user-facing error
    /// message, or nil on success.
    func openResources() async -> String? {
        let items = resources
        guard !items.isEmpty else { return "筆記沒有 ## Resources 區塊（或沒有可開的連結）" }

        for r in items where r.kind == .slack {
            let link = ResourceOps.slackDeepLink(r.url, teamID: app.config.slackTeamID) ?? r.url
            if let u = URL(string: link) { NSWorkspace.shared.open(u) }
        }

        let safariURLs = items.filter { $0.kind == .safari }.map(\.url)
        if !safariURLs.isEmpty { openInSafari(safariURLs) }

        let chromeURLs = items.filter { $0.kind == .chrome }.map(\.url)
        if !chromeURLs.isEmpty {
            let port = app.config.chromeDebugPort ?? 9222
            let before = await ChromeCDP.windowIDs(port: port)
            openInChrome(chromeURLs)
            // Best-effort: remember the freshly created window so snapshots
            // preselect it and "close resource windows" can target it.
            for _ in 0 ..< 5 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let now = await ChromeCDP.windowIDs(port: port)
                if let fresh = now.subtracting(before).first {
                    var ids = machine.rememberedChromeWindows
                    ids.removeAll { !now.contains($0) } // drop dead ids
                    ids.append(fresh)
                    machine.chromeWindowIDs = ids
                    break
                }
            }
        }
        return nil
    }

    private func openInChrome(_ urls: [String]) {
        let base = app.config.chromeCommand ?? "open -na \"Google Chrome\" --args"
        let quoted = urls.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = base + " --new-window " + quoted.joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func openInSafari(_ urls: [String]) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var lines = [
            "tell application \"Safari\"",
            "activate",
            "make new document with properties {URL:\"\(esc(urls[0]))\"}",
        ]
        for u in urls.dropFirst() {
            lines.append("tell front window to make new tab with properties {URL:\"\(esc(u))\"}")
        }
        lines.append("end tell")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = lines.flatMap { ["-e", $0] }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Snapshot (multi-window, Chrome + Safari)

    struct SnapshotTargets {
        var chrome: [ChromeCDP.Window]
        var safari: [SafariScript.Window]
        var note: String?
    }

    /// Everything the snapshot picker can offer. Chrome unreachable is not
    /// fatal (Safari may still be snapshotted) — it degrades to a note.
    func snapshotTargets() async -> SnapshotTargets {
        let port = app.config.chromeDebugPort ?? 9222
        var chrome: [ChromeCDP.Window] = []
        var note: String?
        do {
            chrome = try await ChromeCDP.windows(port: port)
            // Opportunistic hygiene: drop remembered window ids that no
            // longer exist（手關視窗、Chrome 重啟）——「關閉資源視窗」的
            // enabled 狀態與現實保持一致。
            let live = Set(chrome.map(\.id))
            let remembered = machine.rememberedChromeWindows.filter(live.contains)
            if remembered != machine.rememberedChromeWindows {
                machine.chromeWindowIDs = remembered
                machine.chromeWindowID = nil
            }
        } catch {
            note = "Chrome 偵錯埠沒回應（debug Chrome 沒開？）——只能快照 Safari"
        }
        let safari = await Task.detached { SafariScript.windows() }.value
        return SnapshotTargets(chrome: chrome, safari: safari, note: note)
    }

    /// Write the picked windows into the note: Chrome selections into
    /// `### Chrome`, Safari selections into `### Safari`. A kind with no
    /// selection keeps its existing bullets untouched. Chrome picks are
    /// remembered for next time (and for "close resource windows").
    @discardableResult
    func applySnapshot(chrome: [ChromeCDP.Window], safari: [SafariScript.Window]) -> Int {
        var wrote = 0
        if !chrome.isEmpty {
            let entries = chrome.flatMap { $0.tabs.map { (title: $0.title, url: $0.url) } }
            noteText = ResourceOps.setSnapshot(noteText, subsection: "Chrome", entries: entries)
            machine.chromeWindowIDs = chrome.map(\.id)
            wrote += entries.count
        }
        if !safari.isEmpty {
            let entries = safari.flatMap(\.tabs)
            noteText = ResourceOps.setSnapshot(noteText, subsection: "Safari", entries: entries)
            wrote += entries.count
        }
        return wrote
    }

    // MARK: Bring to front（切到視窗所在的桌面）

    /// Raise the task's Chrome resource window. macOS then switches to the
    /// Space it lives on（系統設定「切換至 App 時切換空間」，預設開啟）。
    /// Returns a user-facing note, or nil on a clean raise.
    func bringChromeToFront() async -> String? {
        let port = app.config.chromeDebugPort ?? 9222
        let ids = Set(machine.rememberedChromeWindows)
        let raised = await ChromeCDP.activateWindow(port: port, windowIDs: ids)
        guard let chrome = await devChromeApp(port: port) else {
            return "debug Chrome 沒在跑——先用「開啟全部資源」拉起來"
        }
        chrome.activate()
        if raised { return nil }
        return ids.isEmpty
            ? "任務還沒記住 Chrome 視窗（開資源或快照一次即可）——已喚起 debug Chrome"
            : "記住的視窗已不存在（Chrome 重啟過？）——已喚起 debug Chrome；快照一次可重新對號"
    }

    /// Raise the Safari window holding one of the task's Safari resources.
    func bringSafariToFront() async -> String? {
        let urls = resources.filter { $0.kind == .safari }.map(\.url)
        let hit = await Task.detached { SafariScript.bringToFront(matching: urls) }.value
        if hit { return nil }
        guard let safari = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Safari").first else {
            return "Safari 沒在跑"
        }
        safari.activate()
        return urls.isEmpty
            ? "筆記沒有 Safari 資源——已喚起 Safari"
            : "沒有分頁符合任務的 Safari 資源——已喚起 Safari"
    }

    /// Jump to the task's Slack conversations (deep links activate Slack and
    /// switch Spaces on their own).
    func jumpToSlack() -> String? {
        let slack = resources.filter { $0.kind == .slack }
        guard !slack.isEmpty else { return "筆記沒有 Slack 資源" }
        for r in slack {
            let link = ResourceOps.slackDeepLink(r.url, teamID: app.config.slackTeamID) ?? r.url
            if let u = URL(string: link) { NSWorkspace.shared.open(u) }
        }
        return nil
    }

    /// Close the Chrome windows this task remembered (opened via "open
    /// resources" or picked at snapshot). Tracked windows only — never a
    /// guess. Safari windows aren't tracked; closing them stays manual.
    func closeChromeResources() async -> String {
        let ids = Set(machine.rememberedChromeWindows)
        guard !ids.isEmpty else { return "這個任務沒有記住的 Chrome 資源視窗" }
        let port = app.config.chromeDebugPort ?? 9222
        do {
            let n = try await ChromeCDP.closeWindows(port: port, windowIDs: ids)
            machine.chromeWindowIDs = []
            machine.chromeWindowID = nil
            return n > 0 ? "已關閉 \(n) 個分頁（任務的 Chrome 資源視窗）"
                : "記住的視窗已不存在（可能 Chrome 重啟過）——記錄已清除"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "關閉失敗"
        }
    }
}

// MARK: - The single "資源" menu (open / snapshot / close in one group)

struct ResourceMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession
    @State private var picker: TaskSession.SnapshotTargets?
    @State private var message: String?

    var body: some View {
        let count = session.resources.count
        Menu {
            Button("開啟全部資源（\(count) 條連結）") {
                UsageLog.bump("resources.open")
                Task { message = await session.openResources() }
            }
            .disabled(count == 0)
            Button("快照分頁到筆記…") {
                UsageLog.bump("resources.snapshot")
                Task {
                    let t = await session.snapshotTargets()
                    if t.chrome.isEmpty && t.safari.isEmpty {
                        message = t.note ?? "沒有可快照的視窗"
                    } else {
                        picker = t
                    }
                }
            }
            Divider()
            let kinds = Set(session.resources.map(\.kind))
            Button("帶到最前：Chrome 視窗") {
                UsageLog.bump("resources.frontChrome")
                Task { message = await session.bringChromeToFront() }
            }
            .disabled(!kinds.contains(.chrome) && session.machine.rememberedChromeWindows.isEmpty)
            Button("帶到最前：Safari 視窗") {
                UsageLog.bump("resources.frontSafari")
                Task { message = await session.bringSafariToFront() }
            }
            .disabled(!kinds.contains(.safari))
            Button("跳到 Slack 對話") {
                UsageLog.bump("resources.frontSlack")
                message = session.jumpToSlack()
            }
            .disabled(!kinds.contains(.slack))
            Divider()
            Button("關閉 Chrome 資源視窗", role: .destructive) {
                UsageLog.bump("resources.closeWindows")
                Task { message = await session.closeChromeResources() }
            }
            .disabled(session.machine.rememberedChromeWindows.isEmpty)
        } label: {
            Label(count > 0 ? "資源 \(count)" : "資源",
                  systemImage: "rectangle.stack")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("任務資源：開啟（Chrome/Safari/Slack）、快照分頁回筆記、關閉任務的 Chrome 視窗")
        .sheet(isPresented: Binding(
            get: { picker != nil },
            set: { if !$0 { picker = nil } }
        )) {
            if let t = picker {
                SnapshotPickerSheet(
                    targets: t,
                    preselectedChrome: Set(session.machine.rememberedChromeWindows)
                ) { chrome, safari in
                    if !chrome.isEmpty || !safari.isEmpty {
                        let n = session.applySnapshot(chrome: chrome, safari: safari)
                        message = "已快照 \(n) 個分頁進筆記"
                    }
                    picker = nil
                }
            }
        }
        .alert("資源", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

/// Multi-select window picker: check the windows (Chrome and/or Safari)
/// that belong to this task; their tabs land in the note's ### Chrome /
/// ### Safari subsections. Unchecked kinds keep their existing bullets.
struct SnapshotPickerSheet: View {
    let targets: TaskSession.SnapshotTargets
    let preselectedChrome: Set<Int>
    let done: (_ chrome: [ChromeCDP.Window], _ safari: [SafariScript.Window]) -> Void

    @State private var chromeOn: Set<Int> = []
    @State private var safariOn: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快照哪些視窗？").font(.headline)
            Text("勾選屬於這個任務的視窗（可多選）；沒勾的種類不會動到筆記裡既有的清單。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let note = targets.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !targets.chrome.isEmpty {
                        Text("CHROME（debug profile）")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(targets.chrome) { win in
                            windowRow(on: chromeOn.contains(win.id),
                                      title: "視窗 \(win.id) — \(win.tabs.count) 個分頁",
                                      preview: win.tabs.prefix(3).map(\.title)
                                          .joined(separator: " · ")) {
                                toggle(&chromeOn, win.id)
                            }
                        }
                    }
                    if !targets.safari.isEmpty {
                        Text("SAFARI")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, targets.chrome.isEmpty ? 0 : 6)
                        ForEach(targets.safari) { win in
                            windowRow(on: safariOn.contains(win.id),
                                      title: "視窗 — \(win.tabs.count) 個分頁",
                                      preview: win.tabs.prefix(3).map(\.title)
                                          .joined(separator: " · ")) {
                                toggle(&safariOn, win.id)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("取消") { done([], []) }
                Button("快照勾選的視窗") {
                    done(targets.chrome.filter { chromeOn.contains($0.id) },
                         targets.safari.filter { safariOn.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chromeOn.isEmpty && safariOn.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            chromeOn = preselectedChrome
                .intersection(Set(targets.chrome.map(\.id)))
            if chromeOn.isEmpty, targets.chrome.count == 1 {
                chromeOn = [targets.chrome[0].id]
            }
        }
    }

    private func toggle(_ set: inout Set<Int>, _ id: Int) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func windowRow(on: Bool, title: String, preview: String,
                           tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Theme.accent : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(preview)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(8)
            .background(Theme.paneHeaderBG, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
