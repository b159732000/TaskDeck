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
}

/// SwiftTerm view attached to a daemon-owned pane over the socket.
struct TerminalHostView: NSViewRepresentable {
    let paneID: String
    let client: DaemonClient
    let font: NSFont

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let tv = GlassTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        // ANSI palette: SwiftTerm's stock 16 colors, EXCEPT blue/brightBlue.
        // Stock blue is a near-invisible navy (3,0,178) on our dark glass —
        // Claude's progress bar renders in it. A fully custom palette shipped
        // briefly and regressed dim TUI text (dark slots became invisible),
        // so this is surgical: slots 4/12 remapped to the Theme blues, the
        // other 14 — including the dim-critical 0/8 — stay byte-identical to
        // SwiftTerm's `defaultInstalledColors`.
        tv.installColors(Theme.terminalAnsi.map {
            SwiftTerm.Color(red: UInt16($0.0) * 257,
                            green: UInt16($0.1) * 257,
                            blue: UInt16($0.2) * 257)
        })
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
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            var m = WireMessage(type: "input")
            m.paneID = paneID
            m.setData(Array(data))
            client?.fire(m)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 1, newRows > 1 else { return }
            var m = WireMessage(type: "resize")
            m.paneID = paneID
            m.cols = newCols
            m.rows = newRows
            client?.fire(m)
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
                DragGesture(minimumDistance: 1)
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
    private var focused: Bool { session.focusedSpecID == specID }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                if let info {
                    TerminalHostView(paneID: info.id, client: model.client, font: model.terminalFont)
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
        .onTapGesture { session.focusedSpecID = specID }
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
            if let team = spec?.team {
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
