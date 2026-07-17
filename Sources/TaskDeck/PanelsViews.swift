import AppKit
import SwiftUI
import TaskDeckCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var renamingSlug: String?
    @State private var renameText = ""
    @State private var deletingSlug: String?
    @AppStorage("doneSectionExpanded") private var doneExpanded = true

    var body: some View {
        List(selection: $model.selection) {
            Section("進行中") {
                ForEach(model.tasks.filter { $0.status == "active" }) { row($0) }
                    .onMove { from, to in model.moveActiveTasks(from: from, to: to) }
            }
            let done = model.tasks.filter { $0.status == "done" }
            if !done.isEmpty {
                Section(isExpanded: $doneExpanded) {
                    ForEach(done) { row($0) }
                } header: {
                    Text("已完成（\(done.count)）")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.newTask()
                } label: {
                    Label("新任務", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                Spacer()
                DaemonStatusView()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        // Tint + border run under the titlebar so the strip above the
        // sidebar matches the sidebar (see ContentView's root tint note).
        .background(Theme.panelBG.ignoresSafeArea(edges: .top))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
                .ignoresSafeArea(edges: .top)
        }
        .alert("重新命名任務", isPresented: Binding(
            get: { renamingSlug != nil },
            set: { if !$0 { renamingSlug = nil } }
        )) {
            TextField("名稱", text: $renameText)
            Button("確定") {
                if let slug = renamingSlug { model.renameTask(slug, to: renameText) }
                renamingSlug = nil
            }
            Button("取消", role: .cancel) { renamingSlug = nil }
        } message: {
            Text("同步改筆記檔名與標題")
        }
        .alert("徹底刪除任務", isPresented: Binding(
            get: { deletingSlug != nil },
            set: { if !$0 { deletingSlug = nil } }
        )) {
            Button("刪除", role: .destructive) {
                if let slug = deletingSlug { model.deleteTask(slug) }
                deletingSlug = nil
            }
            Button("取消", role: .cancel) { deletingSlug = nil }
        } message: {
            if let slug = deletingSlug {
                let n = model.livePaneCount(slug)
                Text((n > 0 ? "會關閉 \(n) 個運行中的終端。" : "")
                    + "版面設定將被刪除，筆記會移到「垃圾桶」（可救回）。此動作不可從 App 內復原。")
            }
        }
    }

    private func row(_ t: TaskNote) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.taskHasLivePane(t.id) ? Color(hex: 0x8FCF7F) : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title)
                    .font(.system(size: 12.5 * model.uiScale))
                    .lineLimit(1)
                if let created = t.created {
                    Text(created)
                        .font(.system(size: 9.5 * model.uiScale))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // AI state at a glance: 🟢 running, 🟡 waiting for the user,
            // 🔴 blocked on a permission prompt (hook-fed, live panes only).
            // Click = "已看過" — hides until the state changes again.
            if let badge = model.aiBadge(t.id) {
                Button { model.ackAIStatus(t.id) } label: {
                    Text(badge).font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .help("點一下＝已看過（狀態再變會重新亮起）")
            }
        }
        .padding(.vertical, 1)
        .tag(t.id)
        .contextMenu {
            Button("重新命名…") {
                renameText = t.id
                renamingSlug = t.id
            }
            Button("在新視窗開啟") { openWindow(id: "task", value: t.id) }
            Button("在 Obsidian 開啟") { model.openInObsidian(t.id) }
            Button("在 Finder 顯示筆記") { model.revealNote(t.id) }
            Divider()
            if t.status == "active" {
                Button("收尾（關閉全部終端＋標記完成）", role: .destructive) { model.archiveTask(t.id) }
            } else {
                Button("重新啟用") { model.unarchiveTask(t.id) }
            }
            Button("徹底刪除…", role: .destructive) { deletingSlug = t.id }
        }
    }
}

struct DaemonStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.daemonOK ? Color(hex: 0x8FCF7F) : Color(hex: 0xE8646E))
                .frame(width: 7, height: 7)
            if !model.daemonOK {
                Button("重連") { model.reconnectDaemon() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .help(model.daemonOK ? "taskdeckd 連線中（GUI 重開不影響終端）" : "daemon 未連線")
    }
}

struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession
    let slug: String
    /// Global, persisted, shared by every task and window: the notes column
    /// keeps its width across task switches, app relaunches and new tasks.
    @AppStorage("notesColumnWidth") private var notesWidth: Double = 380

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(slug)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let team = session.machine.primaryTeam {
                    Text("主力 \(team)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                Spacer()
                ResourceMenu()
                NewPaneMenu(labelStyle: .toolbar)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            Rectangle().fill(Theme.border).frame(height: 1)

            GeometryReader { geo in
                let clamped = min(max(120, notesWidth), max(120, Double(geo.size.width) - 168))
                HStack(spacing: 0) {
                    TerminalGridView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ColumnDividerHandle(width: $notesWidth, total: geo.size.width)
                    NotesColumn()
                        .frame(width: CGFloat(clamped))
                }
            }
        }
        .background(Theme.windowBG.ignoresSafeArea(edges: .top)) // titlebar seam
    }
}

/// Draggable divider between columns. `sign` says which side of the handle
/// the bound width belongs to: +1 = panel on the left grows when dragging
/// right (sidebar); -1 = panel on the right grows when dragging left (notes).
struct ColumnDividerHandle: View {
    @Binding var width: Double
    let total: CGFloat
    var sign: Double = -1
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(hovering || startWidth != nil ? Theme.accent.opacity(0.7) : Color.clear)
                    .frame(width: 2)
            )
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if startWidth == nil { startWidth = width }
                        let next = (startWidth ?? width) + sign * Double(v.translation.width)
                        width = min(max(120, next), max(120, Double(total) - 168))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

enum NewPaneMenuStyle { case toolbar, button, icon }

struct NewPaneMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession
    var labelStyle: NewPaneMenuStyle = .toolbar
    /// true = the pane lives in the notes column (small side terminal)
    /// instead of the main grid.
    var side = false
    @State private var showCommandSheet = false
    @State private var cmdTitle = ""
    @State private var cmdText = ""

    var body: some View {
        Menu {
            Button("Shell") { session.addShellPane(side: side) }
            Divider()
            ForEach(model.config.teams) { team in
                Button("AI · \(team.label)") { session.addAIPane(team: team, side: side) }
            }
            Divider()
            Button("指令（server / 腳本）…") { showCommandSheet = true }
        } label: {
            switch labelStyle {
            case .toolbar:
                Label("新終端", systemImage: "plus.rectangle.on.rectangle")
            case .button:
                Label("加一個終端", systemImage: "plus")
            case .icon:
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 11))
            }
        }
        .sheet(isPresented: $showCommandSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("新增指令終端").font(.headline)
                TextField("名稱（例：dev server）", text: $cmdTitle)
                TextField("指令（例：yarn dev）", text: $cmdText)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Spacer()
                    Button("取消") { showCommandSheet = false }
                    Button("建立") {
                        session.addCommandPane(title: cmdTitle, command: cmdText, side: side)
                        cmdTitle = ""
                        cmdText = ""
                        showCommandSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cmdText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }
}

struct NotesColumn: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("筆記")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                NewPaneMenu(labelStyle: .icon, side: true)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26)
                    .help("在右欄開小終端（不佔主終端格的空間）")
                Button {
                    model.openInObsidian(session.slug)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("在 Obsidian 開啟")
                Button {
                    model.revealNote(session.slug)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("在 Finder 顯示")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.paneHeaderBG)

            TextEditor(text: Binding(
                get: { session.noteText },
                set: { session.noteText = $0 }
            ))
            .font(.system(size: 13 * model.uiScale, design: .monospaced))
            .lineSpacing(2.5)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Small side terminals: stacked under the notes, out of the main
            // grid so they never steal split space from the big panes.
            let sideIDs = session.sidePaneIDs
            if !sideIDs.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sideIDs, id: \.self) { id in
                            PaneContainerView(specID: id)
                                .frame(height: 220)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: sideIDs.count == 1 ? 232 : 458)
            }

            if model.config.quotaCommand != nil {
                Rectangle().fill(Theme.border).frame(height: 1)
                QuotaFooterView()
            }
        }
        .background(Theme.panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .background(Theme.windowBG)
    }
}

/// Bottom of the notes column: the quota CLI's own table output, rendered
/// verbatim (ANSI colors and all). One shared fetcher app-wide — the tool
/// rate-limits, so tasks/windows must not fetch independently.
struct QuotaFooterView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("quotaExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(expanded ? "收合額度表" : "展開額度表")
                Text("AI 額度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if model.quotaStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("上次更新失敗，顯示的是舊資料（stderr 在 /tmp/taskdeck-quota.err）")
                }
                Spacer()
                if let t = model.quotaUpdatedAt {
                    Text(t, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.refreshQuota()
                } label: {
                    if model.quotaBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.borderless)
                .help("重新讀取（每 5 分鐘自動更新，全 app 共用一份）")
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.paneHeaderBG)

            if expanded {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Text(AnsiRenderer.render(model.quotaText.isEmpty ? "（讀取中…）" : model.quotaText,
                                             size: 11 * model.uiScale))
                        .lineSpacing(2)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(height: quotaHeight)
            }
        }
    }

    private var quotaHeight: CGFloat {
        let lines = max(3, model.quotaText.split(separator: "\n", omittingEmptySubsequences: false).count)
        return CGFloat(min(lines, 12)) * 17 * CGFloat(model.uiScale) + 16
    }
}
