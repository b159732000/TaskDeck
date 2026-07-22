import AppKit
import SwiftTerm
import SwiftUI
import TaskDeckCore

/// TerminalView that composites with alpha so the glass background shows
/// through. Stock SwiftTerm reports opaque AND paints its CALayer's
/// backgroundColor once at init (setupOptions) — setting
/// `nativeBackgroundColor` later never refreshes the layer, so we force it
/// clear ourselves. Default-background cells are already drawn transparent
/// upstream; only cells with explicit ANSI backgrounds stay solid.
final class GlassTerminalView: TerminalView {
    override var isOpaque: Bool { false }
    private var redrawObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
        // Accept dropped files (images, etc.) like iTerm2 — the path is typed
        // into the pane so claude (or any CLI) can read it.
        registerForDraggedTypes([.fileURL])

        // After sleep-wake or an app relaunch the backing store can show a
        // stale/garbled frame until a manual resize forces a repaint. Force a
        // full redraw on wake / app-active / (re)attach instead — the emulator
        // grid is intact, only the pixels are stale, so no resize needed.
        guard window != nil, redrawObservers.isEmpty else { return }
        let redraw: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.forceRedraw() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        redrawObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: redraw))
        redrawObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: redraw))
        // Catch the replay-then-draw race right after attach.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.forceRedraw() }
    }

    deinit {
        redrawObservers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    private func forceRedraw() {
        guard window != nil else { return }
        needsDisplay = true
    }

    /// Size the buffer to the width the replayed scrollback was produced at
    /// (the daemon's PTY size) BEFORE the view lays out to its own size.
    /// Otherwise, re-attaching on a task switch feeds the replay into a view
    /// still at its transient initial frame, so history re-wraps at the wrong
    /// column and looks garbled until a manual resize. Feeding at the true
    /// production width means the only reflow is the (usually small) step to
    /// the view's real width, done once on layout.
    func applyReplaySize(cols: Int, rows: Int) {
        guard cols > 1, rows > 1 else { return }
        terminal?.resize(cols: cols, rows: rows)
    }

    // MARK: - File drag & drop → insert path(s)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDroppableFiles(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDroppableFiles(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty else { return false }
        // Space-joined, shell-escaped paths + a trailing space, exactly like
        // dropping a file into iTerm2; claude reads the path (images included).
        let text = urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " "
        window?.makeFirstResponder(self)
        send(txt: text)
        return true
    }

    private func hasDroppableFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Backslash-escape characters the shell / prompt would otherwise split on
    /// (spaces, quotes, globs…), so a path with spaces arrives as one token.
    static func shellEscape(_ path: String) -> String {
        let special = Set(" \t\n\"'\\()[]{}$&;|<>*?!#`~")
        var out = ""
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Key interception. TerminalView overrides `keyDown` as non-open so we
    /// can't subclass it; `performKeyEquivalent` (open on NSView, called
    /// before keyDown for the key window) is where we intercept.
    /// Only when this terminal is first responder — never steals keys from
    /// the notes editor.
    ///   • Shift+Return → newline, not submit. SwiftTerm sends a bare CR for
    ///     both plain and shifted Return (main Return isn't a kitty functional
    ///     key upstream), so Claude Code saw Shift+Enter as Enter and
    ///     submitted. Emit a distinct sequence: kitty CSI-u for Shift+Enter
    ///     when the app negotiated the kitty protocol, else ESC+CR
    ///     (meta-return) — both read as insert-newline.
    ///   • iTerm2 "natural text editing": ⌘← ^A, ⌘→ ^E, ⌘⌫ ^U.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 36, mods == .shift { // Shift+Return → newline
            // Send LF (Ctrl+J, 0x0a): Claude Code documents this as the
            // universal "insert newline" input, working regardless of the
            // kitty keyboard protocol. (The earlier kitty CSI-u / ESC+CR
            // branch regressed whenever kitty negotiation flipped.)
            send([0x0a])
            return true
        }
        if mods == .command {
            switch event.keyCode {
            case 123: send([0x01]); return true // ⌘←
            case 124: send([0x05]); return true // ⌘→
            case 51: send([0x15]); return true  // ⌘⌫
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// SwiftTerm view attached to a daemon-owned pane over the socket.
struct TerminalHostView: NSViewRepresentable {
    let paneID: String
    let client: DaemonClient
    let font: NSFont
    /// 16-color ANSI palette. Config `ansiColors` (e.g. the user's iTerm2
    /// palette, so both terminals render identically) with the surgical
    /// `Theme.terminalAnsi` as fallback.
    let palette: [(UInt8, UInt8, UInt8)]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let tv = GlassTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        tv.installColors(palette.map {
            SwiftTerm.Color(red: UInt16($0.0) * 257,
                            green: UInt16($0.1) * 257,
                            blue: UInt16($0.2) * 257)
        })
        // Fork option: default-bg cells stay unpainted so the glass shows
        // through text rows, while the solid nativeBackgroundColor keeps
        // inverse-video (pasted-text standout) readable.
        tv.transparentBackground = true
        tv.nativeBackgroundColor = Theme.terminalBGNS
        tv.nativeForegroundColor = Theme.terminalFGNS
        tv.font = font
        tv.layer?.backgroundColor = NSColor.clear.cgColor
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(tv: tv, client: client, paneID: paneID)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        if nsView.font.pointSize != font.pointSize || nsView.font.fontName != font.fontName {
            nsView.font = font
        }
        // Defensive: anything upstream re-stamping the layer with the solid
        // native background would silently kill the glass.
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var tv: TerminalView?
        private var client: DaemonClient?
        private var paneID = ""
        private var token: UUID?

        func attach(tv: TerminalView, client: DaemonClient, paneID: String) {
            self.tv = tv
            self.client = client
            self.paneID = paneID
            nudgeOnNextResize = true // force a SIGWINCH so the TUI redraws (see sizeChanged)
            token = client.subscribe(
                paneID: paneID,
                replaySize: { [weak tv] cols, rows in
                    (tv as? GlassTerminalView)?.applyReplaySize(cols: cols, rows: rows)
                },
                handler: { [weak tv] bytes in
                    tv?.feed(byteArray: bytes[...])
                })
        }

        func detach() {
            if let token, let client { client.unsubscribe(paneID: paneID, token: token) }
            token = nil
            resizeTimer?.invalidate()
            resizeTimer = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var m = WireMessage(type: "input")
            m.paneID = paneID
            m.setData(Array(data))
            client?.fire(m)
        }

        private var resizeTimer: Timer?
        private var pendingSize: (cols: Int, rows: Int)?
        private var nudgeOnNextResize = true

        private func sendResize(cols: Int, rows: Int) {
            var m = WireMessage(type: "resize")
            m.paneID = paneID
            m.cols = cols
            m.rows = rows
            client?.fire(m)
        }

        /// Debounced: live-resizing a split fires this per FRAME; forwarding
        /// each one SIGWINCHes the shell dozens of times and zsh/p10k
        /// redraws its prompt on every hit — the stacked duplicate prompt
        /// lines after a drag. Tell the PTY only the FINAL size (0.15s
        /// after the drag settles); the local view still reflows live.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 1, newRows > 1 else { return }
            pendingSize = (newCols, newRows)
            resizeTimer?.invalidate()
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self, let size = self.pendingSize else { return }
                self.pendingSize = nil
                if self.nudgeOnNextResize {
                    self.nudgeOnNextResize = false
                    // First resize after (re)attach: the PTY is often ALREADY
                    // this exact size, so a plain resize is a kernel no-op and
                    // sends NO SIGWINCH (TIOCSWINSZ only signals on a real
                    // change) — a running TUI (claude's sticky footer / scroll
                    // region) then never redraws and stays garbled until a
                    // manual resize. Force one genuine change to trigger it.
                    self.sendResize(cols: size.cols, rows: max(2, size.rows - 1))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                        self.sendResize(cols: size.cols, rows: size.rows)
                    }
                } else {
                    self.sendResize(cols: size.cols, rows: size.rows)
                }
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) { NSSound.beep() }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}

/// Recursive split-tree renderer with draggable dividers.
struct TerminalGridView: View {
    @EnvironmentObject var session: TaskSession
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let layout = session.machine.layout {
                // Trailing gutter comes from the 8pt divider handle, so the
                // grid↔notes gap matches every other 8pt margin.
                LayoutNodeView(node: layout, path: [])
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 34))
                        .foregroundStyle(.quaternary)
                    Text("這個任務還沒有終端")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    NewPaneMenu(labelStyle: .button)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct LayoutNodeView: View {
    @EnvironmentObject var session: TaskSession
    let node: LayoutNode
    let path: [Bool]

    var body: some View {
        switch node {
        case .pane(let specID):
            PaneContainerView(specID: specID)
        case .split(let axis, let ratio, let a, let b):
            GeometryReader { geo in
                let horizontal = axis == "h"
                let total = horizontal ? geo.size.width : geo.size.height
                let first = max(60, total * ratio - 4)
                if horizontal {
                    HStack(spacing: 0) {
                        LayoutNodeView(node: a, path: path + [false]).frame(width: first)
                        DividerHandle(axis: axis, path: path, total: total)
                        LayoutNodeView(node: b, path: path + [true]).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        LayoutNodeView(node: a, path: path + [false]).frame(height: first)
                        DividerHandle(axis: axis, path: path, total: total)
                        LayoutNodeView(node: b, path: path + [true]).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

private struct DividerHandle: View {
    @EnvironmentObject var session: TaskSession
    let axis: String
    let path: [Bool]
    let total: CGFloat
    @State private var startRatio: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(hovering || startRatio != nil ? Theme.accent.opacity(0.7) : Color.clear)
                    .frame(width: axis == "h" ? 2 : nil, height: axis == "v" ? 2 : nil)
            )
            .frame(width: axis == "h" ? 8 : nil, height: axis == "v" ? 8 : nil)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h {
                    (axis == "h" ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // .global：同 ColumnDividerHandle——把手隨拖動位移時，區域
                // 座標的 translation 會震盪，分隔線跳動且不跟手。
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startRatio == nil { startRatio = session.ratio(at: path) }
                        guard total > 0 else { return }
                        let delta = Double((axis == "h" ? v.translation.width : v.translation.height) / total)
                        let next = min(0.9, max(0.1, (startRatio ?? 0.5) + delta))
                        session.setRatio(path: path, ratio: next)
                    }
                    .onEnded { _ in startRatio = nil }
            )
    }
}

struct PaneContainerView: View {
    @EnvironmentObject var session: TaskSession
    @EnvironmentObject var model: AppModel
    let specID: String

    private var spec: PaneSpec? { session.spec(specID) }
    private var info: PaneInfo? { model.paneRuntime[specID] }
    /// 邊框高亮只屬於當前焦點區：點了筆記，terminal 的高亮就讓位。
    private var focused: Bool {
        session.focusedSpecID == specID && session.focusZone == .terminal
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                if let info {
                    TerminalHostView(paneID: info.id, client: model.client,
                                     font: model.terminalFont,
                                     palette: model.ansiPalette ?? Theme.terminalAnsi)
                        .id(info.id)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                        .background(Theme.terminalBG)
                } else {
                    notStarted
                }
                if let info, !info.running {
                    exitedBar(info)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(focused ? Theme.accent.opacity(0.65) : Theme.border,
                        lineWidth: focused ? 1.5 : 1)
        )
        .padding(1)
        .contentShape(Rectangle())
        .onTapGesture {
            session.focusedSpecID = specID
            session.focusZone = .terminal
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(info == nil ? Color.secondary.opacity(0.3)
                    : (info!.running ? Color(hex: 0x8FCF7F) : Color(hex: 0xE8646E)))
                .frame(width: 7, height: 7)
            Text(spec?.title ?? "?")
                .font(.system(size: 11 * model.uiScale, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Account badge, clickable. Prefer the session's real account
            // (file location) over the spec's recorded team, which drifts when
            // a different claude was run in the pane. The menu lets you correct
            // the account, or rebind the pane to the session it's ACTUALLY
            // running (fixes the task's group / 現用 / attribution).
            if let spec, spec.kind == "ai" {
                let shown = spec.sessionID.flatMap { model.teamFromSessionFile($0) } ?? spec.team ?? "?"
                Menu {
                    Section("這個終端的帳號") {
                        ForEach(model.config.teams.filter { $0.kind == "claude" }) { t in
                            Button {
                                session.rebindPane(specID: spec.id, team: t.id, sid: nil)
                            } label: {
                                if t.id == spec.team { Label(t.label, systemImage: "checkmark") }
                                else { Text(t.label) }
                            }
                        }
                    }
                    let recents = model.recentSessions(cwd: Paths.expand(spec.cwd ?? model.config.defaultCwd))
                    if !recents.isEmpty {
                        Section("重新綁定到實際 session（近期）") {
                            ForEach(recents, id: \.sid) { r in
                                Button {
                                    session.rebindPane(specID: spec.id, team: r.team, sid: r.sid)
                                } label: {
                                    let mark = r.sid == spec.sessionID ? "● " : ""
                                    Text("\(mark)\(r.team) · \(r.sid.prefix(8))")
                                }
                            }
                        }
                    }
                } label: {
                    Text(shown)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("點擊：改這個終端的帳號，或重新綁定到它實際在跑的 session")
            }
            if spec?.autoStart == true {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .help("開任務時自動啟動")
            }
            Spacer()
            Menu {
                if let spec {
                    Button("向右分割") { session.splitPane(spec.id, axis: "h") }
                    Button("向下分割") { session.splitPane(spec.id, axis: "v") }
                    Divider()
                    if model.hasITerm2, let info, info.running {
                        Button("在 iTerm2 開啟（附掛）") { model.openPaneInITerm2(info) }
                        Divider()
                    }
                    Button("重新啟動") { session.restartPane(spec) }
                    Toggle("開任務時自動啟動", isOn: Binding(
                        get: { spec.autoStart },
                        set: { _ in session.toggleAutoStart(spec) }
                    ))
                    Divider()
                    Button("關閉", role: .destructive) { session.closePane(spec) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Theme.paneHeaderBG)
    }

    private var notStarted: some View {
        VStack(spacing: 12) {
            Text(spec?.kind == "ai" ? "AI session 未啟動" : "終端未啟動")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            if let cmd = spec?.startCommand {
                Text(cmd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
            }
            Button {
                if let spec { session.restartPane(spec) }
            } label: {
                Label(spec?.sessionID != nil ? "啟動並續上對話" : "啟動", systemImage: "play.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent.opacity(0.8))
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBG)
    }

    private func exitedBar(_ info: PaneInfo) -> some View {
        HStack(spacing: 10) {
            Text("已結束（exit \(info.exitCode.map(String.init) ?? "?")）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("重新啟動") { if let spec { session.restartPane(spec) } }
                .controlSize(.small)
            Button("關閉") { if let spec { session.closePane(spec) } }
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}
