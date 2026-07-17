import AppKit
import SwiftUI
import TaskDeckCore

// MARK: - Open / snapshot actions (per task)

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
            // Best-effort: remember the freshly created window for snapshots.
            // (Ids don't survive a Chrome restart; snapshot falls back to a
            // picker when this one is gone.)
            for _ in 0 ..< 5 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let now = await ChromeCDP.windowIDs(port: port)
                if let fresh = now.subtracting(before).first {
                    machine.chromeWindowID = fresh
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

    // MARK: Snapshot

    enum SnapshotOutcome {
        case written(Int)
        case pick([ChromeCDP.Window])
        case failed(String)
    }

    /// Read the debug Chrome's windows; auto-snapshot the task's remembered
    /// window, else hand back the window list for the picker sheet.
    func snapshotChrome() async -> SnapshotOutcome {
        let port = app.config.chromeDebugPort ?? 9222
        do {
            let windows = try await ChromeCDP.windows(port: port)
            guard !windows.isEmpty else { return .failed("debug Chrome 沒有開著的視窗") }
            if let known = machine.chromeWindowID,
               let win = windows.first(where: { $0.id == known }) {
                return .written(applySnapshot(win))
            }
            if windows.count == 1 { return .written(applySnapshot(windows[0])) }
            return .pick(windows)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "讀取分頁失敗")
        }
    }

    @discardableResult
    func applySnapshot(_ window: ChromeCDP.Window) -> Int {
        let entries = window.tabs.map { (title: $0.title, url: $0.url) }
        noteText = ResourceOps.setChromeSnapshot(noteText, entries: entries)
        machine.chromeWindowID = window.id
        return entries.count
    }
}

// MARK: - Header buttons + picker sheet

struct ResourceButtons: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession
    @State private var pickerWindows: [ChromeCDP.Window]?
    @State private var message: String?

    var body: some View {
        let count = session.resources.count
        HStack(spacing: 2) {
            Button {
                Task { message = await session.openResources() }
            } label: {
                Label(count > 0 ? "開資源 \(count)" : "開資源",
                      systemImage: "rectangle.stack.badge.play")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(count == 0)
            .help("開啟筆記 ## Resources 的連結：Chrome（debug profile 新視窗）、Safari、Slack")

            Button {
                Task {
                    switch await session.snapshotChrome() {
                    case .written(let n): message = "已快照 \(n) 個分頁進筆記"
                    case .pick(let wins): pickerWindows = wins
                    case .failed(let why): message = why
                    }
                }
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("把這個任務的 Chrome 視窗分頁快照回筆記（## Resources → ### Chrome）")
        }
        .sheet(isPresented: Binding(
            get: { pickerWindows != nil },
            set: { if !$0 { pickerWindows = nil } }
        )) {
            SnapshotPickerSheet(windows: pickerWindows ?? []) { win in
                if let win {
                    let n = session.applySnapshot(win)
                    message = "已快照 \(n) 個分頁進筆記"
                }
                pickerWindows = nil
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

/// Multiple debug-Chrome windows and none is remembered for this task:
/// the user points at the right one (previewed by its first tab titles).
struct SnapshotPickerSheet: View {
    let windows: [ChromeCDP.Window]
    let done: (ChromeCDP.Window?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("要快照哪個 Chrome 視窗？").font(.headline)
            Text("多個 debug Chrome 視窗同時開著（多任務並行）；選這個任務的那一個。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(windows) { win in
                Button {
                    done(win)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("視窗 \(win.id) — \(win.tabs.count) 個分頁")
                            .font(.system(size: 12, weight: .medium))
                        Text(win.tabs.prefix(3).map(\.title).joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.paneHeaderBG, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("取消") { done(nil) }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
