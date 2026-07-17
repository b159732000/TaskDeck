import AppKit
import SwiftUI
import TaskDeckCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var renamingSlug: String?
    @State private var renameText = ""

    var body: some View {
        List(selection: $model.selection) {
            Section("進行中") {
                ForEach(model.tasks.filter { $0.status == "active" }) { row($0) }
            }
            let done = model.tasks.filter { $0.status == "done" }
            if !done.isEmpty {
                Section("已完成") {
                    ForEach(done) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.newTask()
                } label: {
                    Label("新任務", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                DaemonStatusView()
            }
            .padding(8)
            .background(.bar)
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
    }

    private func row(_ t: TaskNote) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.taskHasLivePane(t.id) ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(t.title)
                .lineLimit(1)
        }
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
        }
    }
}

struct DaemonStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.daemonOK ? Color.green : Color.red)
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

    var body: some View {
        HSplitView {
            TerminalGridView()
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            NotesColumn()
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 620)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NewPaneMenu(labelStyle: .toolbar)
                QuotaButton()
            }
        }
        .navigationTitle(slug)
        .navigationSubtitle(session.machine.primaryTeam.map { "主力：\($0)" } ?? "")
    }
}

enum NewPaneMenuStyle { case toolbar, button }

struct NewPaneMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession
    var labelStyle: NewPaneMenuStyle = .toolbar
    @State private var showCommandSheet = false
    @State private var cmdTitle = ""
    @State private var cmdText = ""

    var body: some View {
        Menu {
            Button("Shell") { session.addShellPane() }
            Divider()
            ForEach(model.config.teams) { team in
                Button("AI · \(team.label)") { session.addAIPane(team: team) }
            }
            Divider()
            Button("指令（server / 腳本）…") { showCommandSheet = true }
        } label: {
            if labelStyle == .toolbar {
                Label("新終端", systemImage: "plus.rectangle.on.rectangle")
            } else {
                Label("加一個終端", systemImage: "plus")
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
                        session.addCommandPane(title: cmdTitle, command: cmdText)
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

struct QuotaButton: View {
    @EnvironmentObject var model: AppModel
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
            if model.quotaOutput.isEmpty { model.refreshQuota() }
        } label: {
            Label("額度", systemImage: "gauge.with.needle")
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI 額度").font(.headline)
                    Spacer()
                    if let t = model.quotaUpdatedAt {
                        Text(t, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.refreshQuota()
                    } label: {
                        if model.quotaBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(model.quotaOutput.isEmpty ? "（尚未讀取）" : model.quotaOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 560, height: 240)
            }
            .padding(14)
        }
    }
}

struct NotesColumn: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("筆記")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.openInObsidian(session.slug)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("在 Obsidian 開啟")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            TextEditor(text: Binding(
                get: { session.noteText },
                set: { session.noteText = $0 }
            ))
            .font(.system(size: 12.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)

            Divider()
            ComposeBar()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ComposeBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession
    @State private var target: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.config.composeSection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.aiPanes.count > 1 {
                    Picker("", selection: $target) {
                        Text("自動").tag(String?.none)
                        ForEach(session.aiPanes) { p in
                            Text(p.title).tag(String?.some(p.id))
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 130)
                }
                Button {
                    session.sendCompose(to: target)
                } label: {
                    Label("送出", systemImage: "paperplane.fill")
                }
                .controlSize(.small)
                .disabled(session.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (target ?? session.defaultTargetSpecID()) == nil)
                .help("把草稿貼進 AI pane 並送出（bracketed paste + Enter）")
            }
            TextEditor(text: Binding(
                get: { session.composeText },
                set: { session.composeText = $0; session.composeChanged() }
            ))
            .font(.system(size: 12.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(height: 92)
            .overlay(alignment: .topLeading) {
                if session.composeText.isEmpty {
                    Text("下一輪要送給 AI 的話，寫在這裡（存進筆記，跨機同步）")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(10)
    }
}
