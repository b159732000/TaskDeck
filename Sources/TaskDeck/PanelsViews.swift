import AppKit
import SwiftUI
import TaskDeckCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var renamingSlug: String?
    @State private var renameText = ""
    @State private var deletingSlug: String?
    @State private var hoveredSlug: String?
    @AppStorage("needsYouSectionExpanded") private var needsYouExpanded = true
    @AppStorage("aiRunningSectionExpanded") private var aiRunningExpanded = true
    @AppStorage("runningSectionExpanded") private var runningExpanded = true
    @AppStorage("readSectionExpanded") private var readExpanded = true
    @AppStorage("waitingSectionExpanded") private var waitingExpanded = true
    @AppStorage("doneSectionExpanded") private var doneExpanded = true
    @AppStorage("sunkSectionExpanded") private var sunkExpanded = false

    var body: some View {
        // 由上而下：等你（自動佇列）→ AI 執行中（訊號驅動）→ 待開工（預設
        // 家：新任務／手動作業／訊號過期，可拖曳排序）→ 已讀（看過待回）→ 等待外部
        //（手動）→ 半封存（>3 天沒動靜，預設折疊；滿 30 天自動歸入已完成）
        // → 已完成（封存）。規則見 AppModel.sidebarGroup / autoArchiveSweep。
        let groups = Dictionary(grouping: model.tasks, by: { model.sidebarGroup($0) })
        let needsYou = (groups[.needsYou] ?? []).sorted { a, b in
            let ia = model.aiAttention(a.id) ?? (false, .distantFuture)
            let ib = model.aiAttention(b.id) ?? (false, .distantFuture)
            if ia.permission != ib.permission { return ia.permission } // 🔴 first
            return ia.since < ib.since // owed longest on top
        }
        let aiRunning = groups[.aiRunning] ?? []
        let idle = groups[.idle] ?? []
        let read = (groups[.read] ?? []).sorted {
            (model.silence($0) ?? 0) < (model.silence($1) ?? 0) // 最近動的在上
        }
        let waiting = (groups[.waitingExt] ?? []).sorted {
            ($0.groupSince ?? "") > ($1.groupSince ?? "")
        }
        let semi = groups[.semiArchived] ?? []
        let done = groups[.done] ?? []

        // 不用 List 的 selection 系統：它的選取膠囊跟自畫常駐底是兩個
        // 形狀不同的圖層，焦點在側邊欄時必然疊成兩層色。選取全自管——
        // 點列設 model.selection，唯一的高亮圖層就是 listRowBackground。
        List {
            if !needsYou.isEmpty {
                Section(isExpanded: $needsYouExpanded) {
                    ForEach(needsYou) { row($0) }
                } header: {
                    Text("等你（\(needsYou.count)）")
                }
            }
            if !aiRunning.isEmpty {
                Section(isExpanded: $aiRunningExpanded) {
                    ForEach(aiRunning) { row($0) }
                } header: {
                    Text("AI 執行中（\(aiRunning.count)）")
                }
            }
            Section(isExpanded: $runningExpanded) {
                ForEach(idle) { row($0) }
                    .onMove { from, to in
                        model.moveRunningTasks(idle.map(\.id), from: from, to: to)
                    }
            } header: {
                Text("待開工（\(idle.count)）")
            }
            if !read.isEmpty {
                Section(isExpanded: $readExpanded) {
                    ForEach(read) { row($0) }
                } header: {
                    Text("已讀（看過待回，\(read.count)）")
                }
            }
            if !waiting.isEmpty {
                Section(isExpanded: $waitingExpanded) {
                    ForEach(waiting) { row($0) }
                } header: {
                    Text("等待外部（\(waiting.count)）")
                }
            }
            if !semi.isEmpty {
                Section(isExpanded: $sunkExpanded) {
                    ForEach(semi) { row($0) }
                } header: {
                    Text("半封存 >3 天（\(semi.count)）")
                }
            }
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
            // 點點＝「終端層」的生命跡象（有無活著的 PTY，含 shell/dev
            // server），與右側徽章（AI 對話狀態）是兩層互補資訊。
            Circle()
                .fill(model.taskHasLivePane(t.id) ? Color(hex: 0x8FCF7F) : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
                .help(model.taskHasLivePane(t.id)
                    ? "有終端在跑（shell／dev server／AI 都算）"
                    : "沒有運行中的終端")
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
        // (d) hover 才浮出狀態切換：以 overlay 疊在列的右端——不進版面流，
        // 列高列寬零變化。chips 常駐掛載、以 opacity/scale 做進出漸變：
        // 比 if 插入/移除的 transition 可靠（List 列裡移除過渡常直接跳失）。
        .overlay(alignment: .trailing) {
            if t.status == "active" {
                let hovered = hoveredSlug == t.id
                LifecycleChips(task: t)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .opacity(hovered ? 1 : 0)
                    .scaleEffect(hovered ? 1 : 0.92, anchor: .trailing)
                    .allowsHitTesting(hovered)
                    .animation(.easeInOut(duration: 0.17), value: hovered)
            }
        }
        .onHover { inside in
            if inside {
                hoveredSlug = t.id
            } else if hoveredSlug == t.id {
                hoveredSlug = nil
            }
        }
        // 高亮不看焦點：系統的選取高亮只在側邊欄有鍵盤焦點時飽和，焦點
        // 移去終端就變灰——自畫一層常駐選取底色（hover 給更淡的一階）。
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(model.selection == t.id
                    ? Theme.accent.opacity(0.16)
                    : (hoveredSlug == t.id ? Color.white.opacity(0.05) : .clear))
                .padding(.horizontal, 4)
                .animation(.easeInOut(duration: 0.17), value: hoveredSlug)
                .animation(.easeInOut(duration: 0.17), value: model.selection)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selection = t.id }
        .contextMenu {
            Button("複製 ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.id, forType: .string)
            }
            Button("重新命名…") {
                renameText = t.id
                renamingSlug = t.id
            }
            Button("在新視窗開啟") { openWindow(id: "task", value: t.id) }
            Button("在 Obsidian 開啟") { model.openInObsidian(t.id) }
            Button("在 Finder 顯示筆記") { model.revealNote(t.id) }
            Divider()
            if t.status == "active" {
                if t.group != nil {
                    Button("移回進行中") { model.setGroupFlag(t.id, nil) }
                }
                if t.group != "read" {
                    Button("標記已讀（看過，先不回）") { model.setGroupFlag(t.id, "read") }
                }
                if t.group != "waiting" {
                    Button("移到等待外部（同事 / review / CI）") { model.setGroupFlag(t.id, "waiting") }
                }
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

    private func primaryChipText(primary: String?, active: String?) -> String {
        switch (primary, active) {
        case let (p?, a?) where p != a: return "主力 \(p) · 現用 \(a)"
        case let (p?, _): return "主力 \(p)"
        case let (nil, a?): return "主力未定 · 現用 \(a)"
        default: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(slug)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                // 主力＝配額之家（手動指定）；現用＝最近有動靜的帳號（自動
                // 偵測、只顯示不改寫）。不一致時亮橘提醒，點 chip 一鍵接管。
                let primary = session.machine.primaryTeam
                let active = model.activeTeam(session.slug)
                if primary != nil || active != nil {
                    let mismatch = active != nil && primary != nil && active != primary
                    Menu {
                        if let active, mismatch {
                            Button("改立 \(active) 為主力") { session.setPrimaryTeam(active) }
                            Divider()
                        }
                        ForEach(model.config.teams) { t in
                            Button {
                                session.setPrimaryTeam(t.id)
                            } label: {
                                if t.id == primary {
                                    Label(t.label, systemImage: "checkmark")
                                } else {
                                    Text(t.label)
                                }
                            }
                        }
                    } label: {
                        Text(primaryChipText(primary: primary, active: active))
                            .font(.system(size: 10))
                            .foregroundStyle(mismatch ? Color.orange : Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((mismatch ? Color.orange : Theme.accent).opacity(0.14),
                                        in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("主力＝任務的配額之家（手動指定）；現用＝最近有動靜的帳號（自動偵測）。點擊可改主力。")
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
                // 視窗變窄時的擠壓優先序（James 260718）：先壓「筆記欄」到
                // 下限，盡量保住主終端格的寬度——搬去小螢幕時終端優先。
                let total = Double(geo.size.width)
                let notesMin = 140.0
                let terminalFloor = max(480.0, total * 0.45)
                let maxNotes = max(notesMin, total - terminalFloor)
                let clamped = min(max(notesMin, notesWidth), maxNotes)
                HStack(spacing: 0) {
                    TerminalGridView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 邊界與顯示 clamp 同一組，拖曳才會跟手（見 handle 註解）。
                    ColumnDividerHandle(width: $notesWidth, total: geo.size.width,
                                        minW: notesMin, maxW: maxNotes)
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
/// `minW`/`maxW` MUST match the display clamp of the panel being resized —
/// mismatched bounds let the stored value drift past the visible clamp and
/// the divider stops tracking the cursor (grows a gap the further you drag).
struct ColumnDividerHandle: View {
    @Binding var width: Double
    let total: CGFloat
    var sign: Double = -1
    var minW: Double = 120
    var maxW: Double? = nil
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
                // .global 座標是關鍵：手勢若用把手的區域座標，把手隨拖動
                // 位移、translation 原點跟著跑 → 左右震盪、游標越拉越偏。
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startWidth == nil { startWidth = width }
                        let next = (startWidth ?? width) + sign * Double(v.translation.width)
                        let upper = max(minW, maxW ?? (Double(total) - 168))
                        width = min(max(minW, next), upper)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// Icon-only lifecycle switches inlined on the SELECTED sidebar row —
/// same row height as every other row, so rapid top-down triage never
/// misclicks from layout shift.（危險動作留在右鍵選單。）
struct LifecycleChips: View {
    @EnvironmentObject var model: AppModel
    let task: TaskNote

    var body: some View {
        HStack(spacing: 2) {
            if task.group != nil {
                chip("play.fill", "回到進行中") { model.setGroupFlag(task.id, nil) }
            }
            if task.group != "read" {
                chip("eye", "標記已讀（看過，先不回）") { model.setGroupFlag(task.id, "read") }
            }
            if task.group != "waiting" {
                chip("hourglass", "移到等待外部（同事 / review / CI）") {
                    model.setGroupFlag(task.id, "waiting")
                }
            }
        }
    }

    private func chip(_ icon: String, _ help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .frame(width: 17, height: 17)
                .background(Theme.paneHeaderBG, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Theme.border, lineWidth: 0.5)
                    )
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
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("筆記")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // 筆記欄標頭統一用 HeaderIconButton 尺寸；「在 Finder 顯示」
                // 使用頻率低、撤出標頭（側邊欄右鍵選單仍有）。
                NewPaneMenu(labelStyle: .icon, side: true)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24, height: 18)
                    .help("在右欄開小終端（不佔主終端格的空間）")
                HeaderIconButton(icon: "arrow.up.forward.app",
                                 help: "在 Obsidian 開啟") {
                    model.openInObsidian(session.slug)
                }
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
            // TextEditor（NSTextView）會吞掉點擊，tap gesture 收不到——用
            // 「編輯器取得鍵盤焦點」當「筆記成為焦點區」的訊號最可靠。
            .focused($noteFocused)
            .onChange(of: noteFocused) { _, isFocused in
                if isFocused { session.focusZone = .notes }
            }

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
        // 筆記為焦點區時整欄外框高亮（與 terminal pane 的高亮互斥）。
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(session.focusZone == .notes ? Theme.accent.opacity(0.65) : Theme.border,
                        lineWidth: session.focusZone == .notes ? 1.5 : 1)
        )
        // 標頭等非編輯器區域的點擊仍走手勢補位。
        .simultaneousGesture(TapGesture().onEnded { session.focusZone = .notes })
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        // 不再自帶 windowBG：TaskDetailView 根部已鋪同款底——雙層疊加會讓
        // 筆記卡外圈比終端區外圈更深一階（James 抓到的色差）。
    }
}

/// Bottom of the notes column: the quota CLI's own table output, rendered
/// verbatim (ANSI colors and all). One shared fetcher app-wide — the tool
/// rate-limits, so tasks/windows must not fetch independently.
/// 統一的小標頭 icon 鈕：24×18 點擊面積＋常駐細框＋hover 填色。
/// 額度列（折疊/A±/重整）與筆記欄標頭共用，尺寸間距才會一致。
struct HeaderIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 18)
                .background(hovering ? AnyShapeStyle(Theme.paneHeaderBG) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.border, lineWidth: hovering ? 1 : 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct QuotaFooterView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("quotaExpanded") private var expanded = true
    /// 額度表的獨立縮放（疊在全局 uiScale 之上）：右欄變窄（小螢幕給主終端
    /// 讓位）時，把表縮小到塞得下。
    @AppStorage("quotaScale") private var quotaScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                HeaderIconButton(icon: expanded ? "chevron.down" : "chevron.right",
                                 help: expanded ? "收合額度表" : "展開額度表") {
                    expanded.toggle()
                }
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
                        .padding(.trailing, 3)
                }
                HeaderIconButton(icon: "textformat.size.smaller",
                                 help: "縮小額度表（獨立於全局縮放）") {
                    quotaScale = max(0.65, ((quotaScale - 0.05) * 100).rounded() / 100)
                }
                HeaderIconButton(icon: "textformat.size.larger",
                                 help: "放大額度表；目前 \(Int(quotaScale * 100))%") {
                    quotaScale = min(1.3, ((quotaScale + 0.05) * 100).rounded() / 100)
                }
                if model.quotaBusy {
                    ProgressView().controlSize(.mini)
                        .frame(width: 24, height: 18)
                } else {
                    HeaderIconButton(icon: "arrow.clockwise",
                                     help: "重新讀取（每 5 分鐘自動更新，全 app 共用一份）") {
                        model.refreshQuota()
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.paneHeaderBG)

            if expanded {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Text(AnsiRenderer.render(model.quotaText.isEmpty ? "（讀取中…）" : model.quotaText,
                                             size: 11 * model.uiScale * quotaScale))
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
        return CGFloat(min(lines, 12)) * 17 * CGFloat(model.uiScale * quotaScale) + 16
    }
}
