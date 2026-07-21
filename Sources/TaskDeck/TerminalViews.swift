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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Shift+Return → newline, not submit. SwiftTerm sends a bare CR for both
    /// plain and shifted Return (main Return isn't a kitty functional key
    /// upstream), so Claude Code can't tell them apart and Shift+Enter
    /// submits. Emit a distinct sequence: the kitty CSI-u encoding for
    /// Shift+Enter when the app enabled the kitty keyboard protocol, else
    /// ESC+CR (meta-return), which Claude reads as insert-newline.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, // kVK_Return (main Return)
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift {
            if terminal?.keyboardEnhancementFlags.isEmpty == false {
                send(txt: "\u{1b}[13;2u")
            } else {
                send([0x1b, 0x0d])
            }
            return
        }
        super.keyDown(with: event)
    }

    /// iTerm2 "natural text editing" essentials, sent as readline control
    /// bytes: ⌘← beginning-of-line (^A), ⌘→ end-of-line (^E), ⌘⌫ kill to
    /// line start (^U). Only when this terminal is the first responder —
    /// never steals ⌘← from the notes editor — and only bare ⌘ (⌘⇧ etc.
    /// pass through untouched).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        case 123: send([0x01]); return true // ⌘←
        case 124: send([0x05]); return true // ⌘→
        case 51: send([0x15]); return true  // ⌘⌫
        default: return super.performKeyEquivalent(with: event)
        }
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
            token = client.subscribe(paneID: paneID) { [weak tv] bytes in
                tv?.feed(byteArray: bytes[...])
            }
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
                var m = WireMessage(type: "resize")
                m.paneID = self.paneID
                m.cols = size.cols
                m.rows = size.rows
                self.client?.fire(m)
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
            // Prefer the session's real account (file location) over the
            // spec's recorded team, which can be stale if a different claude
            // was run in the pane.
            if let spec, spec.kind == "ai",
               let team = spec.sessionID.flatMap({ model.teamFromSessionFile($0) }) ?? spec.team {
                Text(team)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
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
