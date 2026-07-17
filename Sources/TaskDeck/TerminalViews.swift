import AppKit
import SwiftTerm
import SwiftUI
import TaskDeckCore

/// SwiftTerm view attached to a daemon-owned pane over the socket.
struct TerminalHostView: NSViewRepresentable {
    let paneID: String
    let client: DaemonClient

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        tv.nativeBackgroundColor = NSColor(calibratedRed: 0.086, green: 0.09, blue: 0.11, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedRed: 0.85, green: 0.86, blue: 0.87, alpha: 1)
        tv.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(tv: tv, client: client, paneID: paneID)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

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
                LayoutNodeView(node: layout, path: [])
            } else {
                VStack(spacing: 14) {
                    Text("這個任務還沒有終端")
                        .foregroundStyle(.secondary)
                    NewPaneMenu(labelStyle: .button)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
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
                let first = max(60, total * ratio - 3)
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

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .overlay(Rectangle().fill(Color(nsColor: .separatorColor)).frame(
                width: axis == "h" ? 1 : nil, height: axis == "v" ? 1 : nil))
            .frame(width: axis == "h" ? 6 : nil, height: axis == "v" ? 6 : nil)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
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

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                if let info {
                    TerminalHostView(paneID: info.id, client: model.client)
                        .id(info.id)
                } else {
                    notStarted
                }
                if let info, !info.running {
                    exitedBar(info)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(session.focusedSpecID == specID ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { session.focusedSpecID = specID }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(info == nil ? Color.secondary.opacity(0.35) : (info!.running ? Color.green : Color.red))
                .frame(width: 7, height: 7)
            Text(spec?.title ?? "?")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let team = spec?.team {
                Text(team)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
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
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var notStarted: some View {
        VStack(spacing: 10) {
            Text(spec?.kind == "ai" ? "AI session 未啟動" : "終端未啟動")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let cmd = spec?.startCommand {
                Text(cmd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
            Button {
                if let spec { session.restartPane(spec) }
            } label: {
                Label(spec?.sessionID != nil ? "啟動並續上對話" : "啟動", systemImage: "play.fill")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func exitedBar(_ info: PaneInfo) -> some View {
        HStack(spacing: 10) {
            Text("已結束（exit \(info.exitCode.map(String.init) ?? "?")）")
                .font(.system(size: 11))
            Button("重新啟動") { if let spec { session.restartPane(spec) } }
                .controlSize(.small)
            Button("關閉") { if let spec { session.closePane(spec) } }
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}
