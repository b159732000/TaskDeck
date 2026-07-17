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
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                Spacer()
                DaemonStatusView()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
        HStack(spacing: 8) {
            Circle()
                .fill(model.taskHasLivePane(t.id) ? Color(hex: 0x8FCF7F) : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                if let created = t.created {
                    Text(created)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                TerminalGridView()
                    .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                NotesColumn()
                    .frame(minWidth: 160, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            QuotaBarView()
        }
        .background(Theme.windowBG)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NewPaneMenu(labelStyle: .toolbar)
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
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(2.5)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Theme.panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .background(Theme.windowBG)
    }
}

// MARK: - Quota bar

struct QuotaBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 16) {
            if let q = model.quota {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(q.accounts, id: \.alias) { acc in
                            QuotaChipView(account: acc)
                        }
                    }
                }
            } else {
                Text(model.quotaError ?? (model.quotaBusy ? "讀取額度中…" : "額度尚未讀取"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
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
            .help("重新讀取（每 5 分鐘也會自動更新）")
            Button {
                showDetail.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showDetail, arrowEdge: .top) {
                QuotaDetailView()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.panelBG)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

struct QuotaChipView: View {
    let account: QuotaAccount

    var body: some View {
        HStack(spacing: 8) {
            Text(account.alias)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(QuotaSnapshot.orderedBuckets(account), id: \.0) { key, bucket in
                HStack(spacing: 3) {
                    Text(QuotaSnapshot.bucketShortLabel[key] ?? key)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    MiniBarView(percent: bucket.percent)
                    Text(bucket.percent.map { "\(Int($0))%" } ?? "–")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.quotaColor(bucket.percent))
                }
                .help(Self.tooltip(key: key, bucket: bucket))
            }
        }
    }

    static func tooltip(key: String, bucket: QuotaBucket) -> String {
        var parts = [key]
        if let p = bucket.percent { parts.append("\(Int(p))% 已用") }
        if let d = bucket.detail { parts.append(d) }
        if let r = bucket.resets_at, let local = Self.localTime(r) { parts.append("重置 \(local)") }
        return parts.joined(separator: " · ")
    }

    static func localTime(_ iso: String) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? {
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: iso)
        }()
        guard let date else { return nil }
        let out = DateFormatter()
        out.dateFormat = "M/d HH:mm"
        return out.string(from: date)
    }
}

struct MiniBarView: View {
    let percent: Double?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.08))
            if let p = percent {
                Capsule()
                    .fill(Theme.quotaColor(p))
                    .frame(width: max(2, 26 * min(1, p / 100)))
            }
        }
        .frame(width: 26, height: 4)
    }
}

struct QuotaDetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 額度").font(.headline)
            if let q = model.quota {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(q.accounts, id: \.alias) { acc in
                        GridRow {
                            Text(acc.alias)
                                .font(.system(size: 12, weight: .semibold))
                                .gridColumnAlignment(.leading)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(QuotaSnapshot.orderedBuckets(acc), id: \.0) { key, b in
                                    HStack(spacing: 6) {
                                        Text(key)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 90, alignment: .leading)
                                        MiniBarView(percent: b.percent)
                                            .frame(width: 60)
                                        Text(b.percent.map { "\(Int($0))%" } ?? "–")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Theme.quotaColor(b.percent))
                                            .frame(width: 38, alignment: .trailing)
                                        if let d = b.detail {
                                            Text(d).font(.system(size: 10)).foregroundStyle(.tertiary)
                                        }
                                        if let r = b.resets_at, let local = QuotaChipView.localTime(r) {
                                            Text("→ \(local)").font(.system(size: 10)).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                        if acc.alias != q.accounts.last?.alias {
                            Divider()
                        }
                    }
                }
            } else {
                Text(model.quotaError ?? "尚未讀取")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 380)
    }
}
