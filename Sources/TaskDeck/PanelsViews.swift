import AppKit
import SwiftUI
import TaskDeckCore

private struct SidebarSearchFocusActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var focusSidebarSearch: (() -> Void)? {
        get { self[SidebarSearchFocusActionKey.self] }
        set { self[SidebarSearchFocusActionKey.self] = newValue }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var renamingSlug: String?
    @State private var renameText = ""
    @State private var deletingSlug: String?
    @State private var statusSlug: String?
    @State private var statusText = ""
    @State private var hoveredSlug: String?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
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
        let visibleTasks = searchActive
            ? model.tasks.filter { TaskSearchRules.matchesTitle($0.title, query: searchText) }
            : model.tasks
        let groups = Dictionary(grouping: visibleTasks, by: { model.sidebarGroup($0) })
        // Every group sort ends in `a.id < b.id`: Swift's sort isn't stable, so
        // two rows with an equal primary key (e.g. two 已讀 tasks parked at the
        // same group_since) would otherwise swap places on every hover re-sort
        // — a jittering list. The id tiebreaker makes each a total order.
        let needsYou = (groups[.needsYou] ?? []).sorted { a, b in
            let ia = model.aiAttention(a.id) ?? (false, .distantFuture)
            let ib = model.aiAttention(b.id) ?? (false, .distantFuture)
            if ia.permission != ib.permission { return ia.permission } // 🔴 first
            if ia.since != ib.since { return ia.since < ib.since }      // owed longest on top
            return a.id < b.id
        }
        let aiRunning = groups[.aiRunning] ?? []
        let idle = groups[.idle] ?? []
        let read = (groups[.read] ?? []).sorted { a, b in
            // Sort by the cached instant, NOT silence(): silence() embeds a
            // fresh now() per call, so keys drifted between comparisons and
            // near-tied rows kept swapping on every hover re-sort.
            let la = model.lastActivity(a.id) ?? .distantPast
            let lb = model.lastActivity(b.id) ?? .distantPast
            if la != lb { return la > lb } // 最近動的在上
            return a.id < b.id
        }
        let waiting = (groups[.waitingExt] ?? []).sorted { a, b in
            let ga = a.groupSince ?? "", gb = b.groupSince ?? ""
            if ga != gb { return ga > gb }
            return a.id < b.id
        }
        let semi = groups[.semiArchived] ?? []
        let done = (groups[.done] ?? []).sorted(by: TaskSortRules.archivedNewestFirst)

        // 不用 List 的 selection 系統：它的選取膠囊跟自畫常駐底是兩個
        // 形狀不同的圖層，焦點在側邊欄時必然疊成兩層色。選取全自管——
        // 點列設 model.selection，唯一的高亮圖層就是 listRowBackground。
        List {
            if !needsYou.isEmpty {
                sidebarSection(isExpanded: $needsYouExpanded) {
                    ForEach(needsYou) { row($0, group: .needsYou) }
                } header: {
                    laneHeader(.needsYou, needsYou.count, owedText(needsYou))
                }
            }
            if !aiRunning.isEmpty {
                sidebarSection(isExpanded: $aiRunningExpanded) {
                    ForEach(aiRunning) { row($0, group: .aiRunning) }
                } header: {
                    laneHeader(.aiRunning, aiRunning.count, accountsText(aiRunning))
                }
            }
            if !idle.isEmpty || !searchActive {
                sidebarSection(isExpanded: $runningExpanded) {
                    if searchActive {
                        ForEach(idle) { row($0, group: .idle) }
                    } else {
                        ForEach(idle) { row($0, group: .idle) }
                            .onMove { from, to in
                                model.moveRunningTasks(idle.map(\.id), from: from, to: to)
                            }
                    }
                } header: {
                    laneHeader(.idle, idle.count, "")
                }
            }
            if !read.isEmpty {
                sidebarSection(isExpanded: $readExpanded) {
                    ForEach(read) { row($0, group: .read) }
                } header: {
                    laneHeader(.read, read.count, "看過待回")
                }
            }
            if !waiting.isEmpty {
                sidebarSection(isExpanded: $waitingExpanded) {
                    ForEach(waiting) { row($0, group: .waitingExt) }
                } header: {
                    laneHeader(.waitingExt, waiting.count, "同事 / CI")
                }
            }
            if !semi.isEmpty {
                sidebarSection(isExpanded: $sunkExpanded) {
                    ForEach(semi) { row($0, group: .semiArchived) }
                } header: {
                    laneHeader(.semiArchived, semi.count, ">3 天")
                }
            }
            if !done.isEmpty {
                sidebarSection(isExpanded: $doneExpanded) {
                    ForEach(done) { row($0, group: .done) }
                } header: {
                    laneHeader(.done, done.count, "")
                }
            }
            if searchActive && visibleTasks.isEmpty {
                searchEmptyState
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            searchHeader(resultCount: visibleTasks.count)
        }
        .safeAreaInset(edge: .bottom) {
            // A floating pill, not a strip: it is opaque enough to read over
            // rows scrolling beneath it, and the list keeps its glass.
            DockView()
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
        .focusedSceneValue(\.focusSidebarSearch) { searchFocused = true }
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
        .alert("最新狀態", isPresented: Binding(
            get: { statusSlug != nil },
            set: { if !$0 { statusSlug = nil } }
        )) {
            TextField("例：07201822 等 QA", text: $statusText)
            Button("確定") {
                if let slug = statusSlug { model.session(slug).setLatestStatus(statusText) }
                statusSlug = nil
            }
            Button("清除", role: .destructive) {
                if let slug = statusSlug { model.session(slug).setLatestStatus("") }
                statusSlug = nil
            }
            Button("取消", role: .cancel) { statusSlug = nil }
        } message: {
            Text("顯示在側欄任務名稱下方（存進筆記，跨機同步）")
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

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchActive: Bool { !normalizedSearchQuery.isEmpty }

    /// Search temporarily reveals every matching section without overwriting
    /// the user's persisted disclosure choices. Clearing the query restores
    /// the exact pre-search expansion state.
    ///
    /// The disclosure is our own: the sidebar List's built-in chevron pops in
    /// on hover, sits off the header's centre line, and shoves the subtitle
    /// left when it appears. Ours is always there (dim, rotates), the whole
    /// header toggles, and nothing moves.
    @ViewBuilder
    private func sidebarSection<Content: View, Header: View>(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) -> some View {
        Section {
            if searchActive || isExpanded.wrappedValue {
                content()
            }
        } header: {
            HStack(spacing: 8) {
                header()
                if !searchActive {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text4)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !searchActive else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
            }
            .help(searchActive ? "" : (isExpanded.wrappedValue ? "收合" : "展開"))
        }
    }

    /// Lane header: the count is the loudest element (display face, lane
    /// colour), the name reads as its label, and a short mono subtitle says
    /// what the lane means or how long the oldest item has waited.
    private func laneHeader(_ group: AppModel.SidebarGroup, _ count: Int, _ sub: String) -> some View {
        let quiet = group == .idle || group == .semiArchived || group == .done
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(count)")
                .font(Theme.Fonts.display(18, .heavy))
                .monospacedDigit()
            Text(Self.laneName(group))
                .font(Theme.Fonts.display(13, .bold))
            Spacer(minLength: 6)
            if !sub.isEmpty {
                Text(sub)
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(quiet ? Theme.text3 : Theme.laneColor(group))
        .padding(.vertical, 3)
        .textCase(nil)
    }

    static func laneName(_ group: AppModel.SidebarGroup) -> String {
        switch group {
        case .needsYou: return "等你"
        case .aiRunning: return "AI 執行中"
        case .idle: return "待開工"
        case .read: return "已讀"
        case .waitingExt: return "等待外部"
        case .semiArchived: return "半封存"
        case .done: return "已完成"
        }
    }

    /// "最久 2 天" — how long the oldest unanswered task has been waiting.
    /// Minutes at the finest: a lane header is not a stopwatch.
    private func owedText(_ tasks: [TaskNote]) -> String {
        guard let oldest = tasks.compactMap({ model.aiAttention($0.id)?.since }).min() else { return "" }
        let seconds = Date().timeIntervalSince(oldest)
        if seconds < 3600 { return "最久 \(max(1, Int(seconds / 60))) 分" }
        return "最久 " + activityDuration(seconds)
    }

    private func accountsText(_ tasks: [TaskNote]) -> String {
        let teams = Set(tasks.compactMap { model.activeTeam($0.id) })
        return teams.isEmpty ? "" : "\(teams.count) 帳號"
    }

    private func searchHeader(resultCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(searchFocused ? Theme.accent : .secondary)
                    .accessibilityHidden(true)

                TextField("搜尋任務", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.ui(12.5))
                    .focused($searchFocused)
                    .onExitCommand {
                        if !searchText.isEmpty {
                            searchText = ""
                        } else {
                            searchFocused = false
                        }
                    }
                    .accessibilityLabel("搜尋任務標題")

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜尋")
                    .accessibilityLabel("清除搜尋")
                } else if !searchFocused {
                    Text("⇧⌘F")
                        .font(Theme.Fonts.mono(9.5))
                        .foregroundStyle(Theme.text4)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .frame(height: 32)
            .background(Color.white.opacity(0.05), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(searchFocused ? Theme.accent.opacity(0.7) : Theme.border,
                            lineWidth: searchFocused ? 1.25 : 1)
            }

            if searchActive {
                Text("\(resultCount) 個結果")
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, searchActive ? 5 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SidebarChrome(edge: .top))
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text("找不到符合的標題")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("清除搜尋") {
                searchText = ""
                searchFocused = true
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Emphasize every exact match using the same comparison options as the
    /// filter, so Unicode-equivalent text can never be visible but unmarked.
    private func highlightedTitle(_ title: String) -> Text {
        let query = normalizedSearchQuery
        guard !query.isEmpty else { return Text(title) }

        var output = Text("")
        var cursor = title.startIndex
        while cursor < title.endIndex,
              let match = title.range(of: query, options: [.caseInsensitive],
                                      range: cursor ..< title.endIndex) {
            output = output + Text(String(title[cursor ..< match.lowerBound]))
            output = output + Text(String(title[match]))
                .bold()
                .foregroundColor(Theme.accent)
            cursor = match.upperBound
        }
        return output + Text(String(title[cursor...]))
    }

    /// Row background tint, all in the one accent hue: any selection is the
    /// brightest, then an unselected 等你 hint, then a faint hover. No second
    /// color — brightness alone ranks them.
    private func rowFill(selected: Bool, needsYou: Bool,
                         priorityAlert: Bool, hovered: Bool) -> Color {
        if priorityAlert { return Theme.Lane.you.opacity(selected ? 0.26 : 0.14) }
        if selected { return Theme.accent.opacity(0.17) }
        if needsYou { return Theme.Lane.you.opacity(0.07) }
        if hovered { return Color.white.opacity(0.045) }
        return .clear
    }

    /// The 3 pt colour rail on the leading edge: the lane's hue, only in the
    /// lanes that mean something is happening (等你 / AI / 已讀 / 等待外部).
    private func laneRail(_ group: AppModel.SidebarGroup) -> Color? {
        switch group {
        case .needsYou, .aiRunning, .read, .waitingExt: return Theme.laneColor(group)
        default: return nil
        }
    }

    // The section passes its group (it already knows it) so the row never
    // recomputes sidebarGroup — that ran per-row per-render and starved the
    // selection tint's repaint behind the detail-pane rebuild. The chips also
    // key off this DISPLAYED group, not the persisted frontmatter `group`: a
    // 已讀 task resurfaced to 等你 by a fresh AI turn must still offer 已讀.
    private func row(_ t: TaskNote, group: AppModel.SidebarGroup) -> some View {
        let needsYou = group == .needsYou
        let backgroundCount = model.backgroundTaskCount(t.id)
        let priorityAlert = model.hasPriorityAlert(t.id)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                highlightedTitle(t.title)
                    .font(Theme.Fonts.ui(13 * model.uiScale, .semibold))
                    .foregroundStyle(group == .semiArchived || group == .done ? Theme.text3 : Theme.text)
                    .lineLimit(searchActive ? 2 : 1)
                    .help(t.title)
                HStack(spacing: 5) {
                    if let created = t.created {
                        // "09-03": the year and time are in the note; the row
                        // has ~250 pt for five things.
                        Text(created.count >= 10 ? String(created.dropFirst(5).prefix(5)) : created)
                            .font(Theme.Fonts.mono(10 * model.uiScale))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .help(created)
                    }
                    if t.isMainline {
                        Image(systemName: "star.fill")
                        .font(Theme.Fonts.ui(9 * model.uiScale, .bold))
                        .foregroundStyle(Theme.Lane.you)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.Lane.you.opacity(0.16), in: Capsule())
                        .help(priorityAlert ? "主線 AI 已完成，正在等你查看" : "主線任務")
                    }
                    // 主 AI（主力 if set, else 現用）— cached, no per-render disk.
                    if let team = model.mainTeam(t.id) {
                        Text(QuotaGrid.shortAlias(team))
                            .help(team)
                            .font(Theme.Fonts.mono(9 * model.uiScale, .medium))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                    if backgroundCount > 0 {
                        Text("背景 \(backgroundCount)")
                            .font(Theme.Fonts.ui(9 * model.uiScale, .medium))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .help("Claude 背景工作仍在執行；不影響目前任務分組")
                    }
                    // 本機服務（dev server / DB / watcher）——這個任務有東西還開著。
                    let services = model.services(t.id)
                    if !services.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "play.fill")
                            Text("\(services.count)")
                        }
                        .font(Theme.Fonts.mono(9 * model.uiScale, .bold))
                        .foregroundStyle(Theme.good)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.good.opacity(0.14), in: Capsule())
                        .help(servicesHelp(services))
                    }
                }
                // User-typed latest status（詳情頁頂端可編輯；設定檔案 frontmatter latest）
                if let s = t.statusLine, !s.isEmpty {
                    Text(s)
                        .font(Theme.Fonts.ui(11 * model.uiScale))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .padding(.leading, 4)
        // (d) hover 才浮出狀態切換：以 overlay 疊在列的右端——不進版面流，
        // 列高列寬零變化。chips 常駐掛載、以 opacity/scale 做進出漸變：
        // 比 if 插入/移除的 transition 可靠（List 列裡移除過渡常直接跳失）。
        .overlay(alignment: .trailing) {
            // Search prioritizes the matched title; the hover capsule can cover
            // most of a 150 pt sidebar row. Lifecycle actions remain available
            // again as soon as the query is cleared (and in the context menu).
            if t.status == "active" && !searchActive {
                let hovered = hoveredSlug == t.id
                LifecycleChips(task: t, group: group)
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
        // 「等你」用同一主配色（accent）的深淺區分：未選一層淡底＋左側強調
        // 條，選中再加深，不引入額外色相。
        // Three channels, one job each: the FILL says selected / hovered /
        // 等你 hint, the RAIL says which lane, the OUTLINE says main-line
        // alert. Nothing doubles up — the old accent bar for 等你 and the
        // selection stroke both sat beside the rail as a second line.
        .listRowBackground(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(rowFill(selected: model.selection == t.id,
                                  needsYou: needsYou,
                                  priorityAlert: priorityAlert,
                                  hovered: hoveredSlug == t.id))
                if let rail = laneRail(group) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(rail)
                        .frame(width: 3)
                        .padding(.vertical, 8)
                        .padding(.leading, 3)
                }
                if priorityAlert {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.Lane.you.opacity(0.9), lineWidth: 1.25)
                        .shadow(color: Theme.Lane.you.opacity(0.6), radius: 6)
                }
            }
            .padding(.horizontal, 4)
            // Selection snaps (no cross-fade): the detail-pane rebuild can hog
            // the main thread right after a tap, and an animated tint would
            // visibly crawl behind it. Hover keeps a light fade.
            .animation(.easeInOut(duration: 0.15), value: hoveredSlug)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectTask(t.id) }
        .contextMenu {
            Button("複製 ID（永久 UUID）") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.session(t.id).permanentID(), forType: .string)
            }
            Button("複製任務名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.id, forType: .string)
            }
            Button("重新命名…") {
                renameText = t.id
                renamingSlug = t.id
            }
            Button("設定最新狀態…") {
                statusText = t.statusLine ?? ""
                statusSlug = t.id
            }
            Button {
                model.setMainline(t.id, !t.isMainline)
            } label: {
                Label(t.isMainline ? "取消主線" : "設為主線",
                      systemImage: t.isMainline ? "star.slash" : "star")
            }
            Button("在新視窗開啟") { openWindow(id: "task", value: t.id) }
            Button("在 Obsidian 開啟") { model.openInObsidian(t.id) }
            Button("在 Finder 顯示筆記") { model.revealNote(t.id) }
            Divider()
            if t.status == "active" {
                Menu("移動到") {
                    ForEach(AppModel.manualMoveTargets, id: \.label) { target in
                        Button {
                            model.setGroupFlag(t.id, target.value)
                        } label: {
                            if t.group == target.value {
                                Label(target.label, systemImage: "checkmark")
                            } else {
                                Text(target.label)
                            }
                        }
                    }
                }
                Button("收尾（關閉全部終端＋標記完成）", role: .destructive) { model.archiveTask(t.id) }
            } else {
                Button("重新啟用") { model.unarchiveTask(t.id) }
            }
            Button("徹底刪除…", role: .destructive) { deletingSlug = t.id }
        }
    }
}

/// A strip pinned over the scrolling task list (the search header, the bottom
/// bar). The sidebar is glass — `Theme.panelBG` is only ~26% opaque — so a
/// plain tint lets rows scrolling underneath show straight through the strip
/// and its text becomes unreadable. A material blurs what is behind into a
/// frosted band instead: legible, and still glass rather than a solid slab.
/// The tint on top keeps the strip in the same hue as the list; the hairline
/// marks where the list ends.
private struct SidebarChrome: ViewModifier {
    let edge: VerticalEdge

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .background(Theme.panelBG)
            .background(.regularMaterial)
            .overlay(alignment: edge == .top ? .bottom : .top) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
    }
}

/// "yarn dev（2 天）" lines for a badge tooltip.
func servicesHelp(_ services: [PaneActivity]) -> String {
    let lines = services.map { "· \($0.label)（\(activityDuration($0.runningFor))）" }
    return (["這個任務有本機服務還開著："] + lines).joined(separator: "\n")
}

/// Coarse on purpose: the question is "did I leave this running?", never the
/// exact second.
func activityDuration(_ seconds: TimeInterval) -> String {
    if seconds < 90 { return "\(Int(seconds)) 秒" }
    if seconds < 5400 { return "\(Int(seconds / 60)) 分" }
    if seconds < 172_800 { return "\(Int(seconds / 3600)) 小時" }
    return "\(Int(seconds / 86400)) 天"
}

func activityMemory(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024 ? String(format: "%.1fG", mb / 1024) : String(format: "%.0fM", mb)
}

/// The floating dock under the task list: what the terminals are running
/// (服務 / AI / 閒置 counts, memory of the pane process trees), the daemon
/// dot, and the new-task button. Counts are terminal facts, not AI-turn
/// facts — whether an AI owes a reply is the lane grouping above, which reads
/// the hook signals and can tell thinking from waiting.
struct DockView: View {
    @EnvironmentObject var model: AppModel

    /// Same persisted value ContentView sizes the sidebar with.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230

    var body: some View {
        let totals = model.activityTotals
        // The sidebar can be dragged down to 150 pt: shed the memory figure,
        // then the idle count. Decided from the persisted width, not with
        // ViewThatFits — inside a safeAreaInset that collapsed the inset to
        // zero height and left the + button floating over the list.
        row(totals, memory: sidebarWidth >= 235, idle: sidebarWidth >= 190)
        .lineLimit(1)
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Theme.raisedBG, in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .help(helpText(totals))
    }

    private func row(_ totals: AppModel.ActivityTotals, memory: Bool, idle: Bool) -> some View {
        HStack(spacing: 11) {
            dot(Theme.good, totals.service, "服務")
            dot(Theme.Lane.ai, totals.ai, "AI")
            if idle { dot(Theme.text4, totals.idle, "閒置") }
            if memory, totals.panes > 0 {
                Text(activityMemory(totals.residentBytes))
                    .font(Theme.Fonts.mono(10.5, .medium))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 4)
            daemon
            Button { model.newTask() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0A0C11))
                    .frame(width: 24, height: 24)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("新任務（⇧⌘N）")
        }
    }

    private func dot(_ tint: Color, _ count: Int, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(count > 0 ? tint : Theme.text4.opacity(0.6)).frame(width: 7, height: 7)
            Text("\(count)")
                .font(Theme.Fonts.mono(11, .medium))
                .foregroundStyle(count > 0 ? Theme.text2 : Theme.text3)
        }
        .accessibilityLabel("\(label) \(count)")
    }

    private var daemon: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.daemonOK
                    ? (model.daemonNote == nil ? Theme.good : Theme.warn)
                    : Theme.crit)
                .frame(width: 7, height: 7)
            if !model.daemonOK {
                Button("重連") { model.reconnectDaemon() }
                    .font(Theme.Fonts.ui(10.5, .semibold))
                    .buttonStyle(.borderless)
            }
        }
        .help(model.daemonOK
            ? (model.daemonNote ?? "taskdeckd 連線中（GUI 重開不影響終端）")
            : "daemon 未連線")
    }

    private func helpText(_ totals: AppModel.ActivityTotals) -> String {
        var lines = [
            "終端機在跑什麼（\(totals.panes) 個 pane）：",
            "· 服務 \(totals.service)（dev server / DB / watcher 等長跑指令）",
            "· AI \(totals.ai) 個 pane 開著 AI CLI",
            "· 閒置 \(totals.idle) 停在提示字元",
            "· 記憶體 \(activityMemory(totals.residentBytes))（所有 pane 的行程樹）",
            "",
            "AI 是不是正在跑 / 在等你，看上面的車道（那是 hook 訊號，比行程準）。",
        ]
        let services = model.serviceOverview()
        if !services.isEmpty {
            lines.append("")
            lines.append("服務：")
            lines += services.map {
                "· \($0.activity.label) — \($0.task)（\(activityDuration($0.activity.runningFor))）"
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// One-line "latest status" the user types (frontmatter `latest`), mirrored
/// under the sidebar title. Commits on Enter or when focus leaves.
struct StatusLineField: View {
    @EnvironmentObject var session: TaskSession
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var showHistory = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 9))
                .foregroundStyle(Theme.text4)
            TextField("最新狀態…（例：等 QA；不打時間會自動加）", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.ui(11.5))
                .foregroundStyle(Theme.text2)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { f in if !f { commit() } }
                .task(id: session.slug) { text = session.latestStatus }
            // History disclosure — the full ## 狀態 log, newest first.
            let history = session.statusHistory
            if !history.isEmpty {
                Button { showHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("狀態歷史（\(history.count)）")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("狀態歷史").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(history.enumerated()), id: \.offset) { _, e in
                                    Text(e).font(.system(size: 11.5, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                    }
                    .padding(12)
                    .frame(width: 360)
                }
            }
        }
    }

    /// Sync the field back to the (possibly re-stamped) stored value after a
    /// commit, so an auto-added timestamp shows and re-commits dedupe cleanly.
    private func commit() {
        session.setLatestStatus(text)
        text = session.latestStatus
    }
}

struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TaskSession
    let slug: String
    /// Global, persisted, shared by every task and window: the notes column
    /// keeps its width across task switches, app relaunches and new tasks.
    @AppStorage("notesColumnWidth") private var notesWidth: Double = 380

    /// 向右 only when the stage is wide enough for two readable columns;
    /// otherwise stack, which is what a 14" screen wants.
    private func updateSplitAxis(stage: CGSize) {
        session.preferredSplitAxis = stage.width >= 1200 || stage.height < 560 ? "h" : "v"
    }

    private func primaryChipText(primary: String?, active: String?) -> String {
        switch (primary, active) {
        case let (p?, a?) where p != a: return "主力 \(p) · 現用 \(a)"
        case let (p?, _): return "主力 \(p)"
        case let (nil, a?): return "主力未定 · 現用 \(a)"
        default: return "設定主力"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(slug)
                    .font(Theme.Fonts.display(22, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // 主力＝配額之家（手動指定）；現用＝最近有動靜的帳號（自動
                // 偵測、只顯示不改寫）。不一致時亮橘提醒，點 chip 一鍵接管。
                // Always shown so a shell-only task (no AI pane) can still be
                // given a 主力 by hand. Dim "設定主力" when nothing is set yet.
                let primary = session.machine.primaryTeam
                let active = model.activeTeam(session.slug)
                let unset = primary == nil && active == nil
                let mismatch = active != nil && primary != nil && active != primary
                let tint = mismatch ? Theme.warn : (unset ? Theme.text3 : Theme.accent)
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
                    if primary != nil {
                        Divider()
                        Button("清除主力") { session.setPrimaryTeam(nil) }
                    }
                } label: {
                    Text(primaryChipText(primary: primary, active: active))
                        .font(Theme.Fonts.mono(10, .medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.14), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("主力＝任務的配額之家（手動指定）；現用＝最近有動靜的帳號（自動偵測）。點擊可改主力。")
                // Where the task sits right now, and any service still running
                // in one of its panes — the two things a glance at the header
                // should answer without looking at the sidebar.
                if let task = model.tasks.first(where: { $0.id == slug }) {
                    let group = model.sidebarGroup(task)
                    Text(SidebarView.laneName(group))
                        .font(Theme.Fonts.ui(10, .semibold))
                        .foregroundStyle(Theme.laneColor(group))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.laneColor(group).opacity(0.14), in: Capsule())
                }
                ForEach(Array(model.services(slug).prefix(2).enumerated()), id: \.offset) { _, svc in
                    Text("▶ \(svc.label) · \(activityDuration(svc.runningFor))")
                        .font(Theme.Fonts.mono(10, .medium))
                        .foregroundStyle(Theme.good)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.good.opacity(0.14), in: Capsule())
                }
                Spacer()
                ResourceMenu()
                NewPaneMenu(labelStyle: .toolbar)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Editable one-line status — shows under the sidebar title too.
            StatusLineField()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

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
                        .onAppear { updateSplitAxis(stage: CGSize(width: total - clamped, height: Double(geo.size.height))) }
                        .onChange(of: geo.size) { _, size in
                            updateSplitAxis(stage: CGSize(width: Double(size.width) - clamped, height: Double(size.height)))
                        }
                    // 邊界與顯示 clamp 同一組，拖曳才會跟手（見 handle 註解）。
                    ColumnDividerHandle(width: $notesWidth, total: geo.size.width,
                                        minW: notesMin, maxW: maxNotes)
                    NotesColumn()
                        .frame(width: CGFloat(clamped))
                }
            }
        }
        .background(Theme.windowBG.ignoresSafeArea(edges: .top)) // titlebar seam
        .dismissPriorityAlertOnTaskInteraction(slug)
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
                Capsule()
                    .fill(hovering || startWidth != nil ? Theme.accent.opacity(0.8) : Theme.text4.opacity(0.5))
                    .frame(width: 3, height: 36)
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

/// Draggable divider between stacked sections of the notes column. The
/// section BELOW the handle grows when dragging up. A stored height of 0
/// means "natural"; the first drag starts from `fallback`. Double-click
/// restores the default.
struct RowDividerHandle: View {
    @Binding var height: Double
    var fallback: Double
    var minH: Double = 60
    var maxH: Double = 600
    var reset: () -> Void
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(
                Capsule()
                    .fill(hovering || start != nil ? Theme.accent.opacity(0.8) : Theme.text4.opacity(0.5))
                    .frame(width: 36, height: 3)
            )
            .frame(height: 10)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if start == nil { start = height > 0 ? height : fallback }
                        let next = (start ?? fallback) - Double(v.translation.height)
                        height = min(max(minH, next), maxH)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { reset() }
            .help("拖曳調整高度；雙擊回預設")
    }
}

/// Icon-only lifecycle switches inlined on the SELECTED sidebar row —
/// same row height as every other row, so rapid top-down triage never
/// misclicks from layout shift.（危險動作留在右鍵選單。）
struct LifecycleChips: View {
    @EnvironmentObject var model: AppModel
    let task: TaskNote
    /// The section the row is CURRENTLY shown in — chips hide the one matching
    /// it (not the persisted frontmatter `group`), so a 已讀 task resurfaced to
    /// 等你 still offers 已讀, and re-picking it re-acks the new AI turn.
    let group: AppModel.SidebarGroup

    var body: some View {
        HStack(spacing: 2) {
            // No 待開工 chip: 待開工 is the no-AI-activity default, not a place
            // you move to. Once a task has an AI signal it belongs in 等你/已讀,
            // so "回到待開工" was semantically empty (and bounced to 已讀).
            if group != .needsYou {
                chip("bell", "移到等你（我要 review）") { model.setGroupFlag(task.id, "needsyou") }
            }
            if group != .read {
                chip("eye", "標記已讀（看過，先不回）") { model.setGroupFlag(task.id, "read") }
            }
            if group != .waitingExt {
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
            // Sessions found in the note (started by hand / pasted / post-reboot)
            // that map to a real conversation — resume under the right account.
            let resumable = session.resumableSessions()
            if !resumable.isEmpty {
                Divider()
                ForEach(resumable, id: \.sid) { r in
                    Button("續上：\(r.team) · \(r.sid.prefix(8))") {
                        session.resumeSession(sid: r.sid, team: r.team)
                    }
                }
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
    /// Remembered section heights, global like the column width: the small
    /// terminals block and the quota block. 0 = the quota's natural height.
    @AppStorage("sidePanesHeight") private var sidePanesHeight: Double = 232
    @AppStorage("quotaContentHeight") private var quotaContentHeight: Double = 0
    @AppStorage("quotaExpanded") private var quotaExpanded = true

    /// The column is a fixed budget: header, editor (never below `editorMin`),
    /// the small-terminals block, the quota block, and a handle above each of
    /// the last two. The remembered heights are wishes; the block above gives
    /// way first, so growing the quota shrinks the terminals (which scroll
    /// their own scrollback) instead of covering them, and nothing is ever
    /// clipped off the bottom of the card.
    private struct Budget {
        static let header = 30.0, editorMin = 80.0, handle = 10.0, quotaHeader = 28.0
        static let paneMin = 60.0
        let side: Double      // height of the small-terminals block (0 = none)
        let sideMax: Double
        let quota: Double     // height of the quota content (0 = none)
        let quotaMax: Double
    }

    private func budget(total: Double, sideCount: Int, natural: Double) -> Budget {
        var free = total - Budget.header - Budget.editorMin
        let hasQuota = model.config.quotaCommand != nil
        var quotaMax = 0.0, quota = 0.0
        if hasQuota {
            free -= Budget.handle + Budget.quotaHeader
            if sideCount > 0 { free -= Budget.handle + Budget.paneMin }
            quotaMax = max(44, free)
            quota = quotaExpanded ? min(quotaContentHeight > 0 ? quotaContentHeight : natural, quotaMax) : 0
            free -= quota
            if sideCount > 0 { free += Budget.paneMin }
        }
        var sideMax = 0.0, side = 0.0
        if sideCount > 0 {
            if !hasQuota { free -= Budget.handle }
            sideMax = max(Budget.paneMin, free)
            side = min(sidePanesHeight, sideMax)
        }
        return Budget(side: side, sideMax: sideMax, quota: quota, quotaMax: quotaMax)
    }

    var body: some View {
        GeometryReader { geo in
        let sideIDs = session.sidePaneIDs
        let natural = QuotaGrid.naturalHeight(rows: max(3, model.quotaAccounts.count),
                                              scale: model.uiScale, compact: false)
        let b = budget(total: Double(geo.size.height), sideCount: sideIDs.count, natural: natural)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("筆記")
                    .font(Theme.Fonts.display(12, .semibold))
                    .foregroundStyle(Theme.text2)
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
            .background(Theme.headerStrip)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { session.focusZone = .notes })

            // NSTextView-backed: gives us ⌘B / ⌘I / ⌘⇧X markdown wrapping and a
            // reliable "became focus zone" signal (becomeFirstResponder).
            MarkdownNotesEditor(
                text: Binding(get: { session.noteText },
                              set: { session.noteText = $0 }),
                fontSize: 13 * model.uiScale,
                onFocus: { session.focusZone = .notes }
            )

            // Small side terminals: stacked under the notes, out of the main
            // grid so they never steal split space from the big panes.
            if !sideIDs.isEmpty {
                // Drag up for more room; double-click restores the default.
                // One terminal fills the block (down to 60 pt — no minimum
                // worth the name, the terminal scrolls its own history);
                // several keep 220 pt each and the block scrolls.
                RowDividerHandle(height: $sidePanesHeight, fallback: 232,
                                 minH: Budget.paneMin, maxH: b.sideMax) {
                    sidePanesHeight = 232
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sideIDs, id: \.self) { id in
                            PaneContainerView(specID: id)
                                .frame(height: sideIDs.count == 1 ? max(Budget.paneMin - 12, b.side - 12) : 220)
                        }
                    }
                    .padding(6)
                }
                .frame(height: CGFloat(b.side))
            }

            if model.config.quotaCommand != nil {
                RowDividerHandle(height: $quotaContentHeight, fallback: natural,
                                 minH: 44, maxH: b.quotaMax) {
                    quotaContentHeight = 0
                }
                QuotaFooterView(contentHeight: quotaExpanded ? b.quota : nil,
                                narrow: geo.size.width < 260)
            }
        }
        }
        .background(Theme.notesBG)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        // 筆記為焦點區時整欄外框高亮（與 terminal pane 的高亮互斥）。
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .stroke(session.focusZone == .notes ? Theme.accent.opacity(0.55) : Theme.border,
                        lineWidth: session.focusZone == .notes ? 1.5 : 1)
        )
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

/// The claude-quota table as a grid: one row per account, one cell per
/// window (5h / 週 / Fable / 點數) — the same information as the CLI table,
/// plus a bar per cell, colour at ≥70% / 100%, and the reset time of the
/// current 5h window (the locked window once the account is locked). Every
/// window's reset is in the row tooltip.
struct QuotaGrid: View {
    let accounts: [AppModel.QuotaAccount]
    let scale: Double
    /// Squeezed: no bars, half the row spacing — every number stays.
    var compact = false

    /// Height the grid wants (including its 8 pt paddings) for `rows`
    /// accounts, so the section can decide between full, compact and
    /// scrolling. Row: text ~13 pt + bar 5 pt + spacing.
    static func naturalHeight(rows: Int, scale: Double, compact: Bool) -> Double {
        let header = 14 * scale + (compact ? 3 : 6)
        let row = compact ? 13 * scale + 3 : 18 * scale + 6
        return 16 + header + Double(rows) * row
    }

    private static let columns: [(title: String, match: (String) -> Bool)] = [
        ("5h", { $0.lowercased().contains("5h") }),
        ("週", { $0.lowercased().hasPrefix("weekly all") || $0.lowercased() == "weekly" }),
        ("Fable", { $0.lowercased().contains("fable") || $0.lowercased().contains("model") }),
        ("點數", { $0.lowercased().contains("credit") }),
    ]

    var body: some View {
        // Fill the column when the grid's minimum fits; otherwise scroll
        // sideways rather than clip the reset column.
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: compact ? 3 : 6) {
            GridRow {
                Text("帳號").gridColumnAlignment(.leading)
                ForEach(Self.columns, id: \.title) { Text($0.title) }
                Color.clear.frame(width: 1)
                Text("重置").gridColumnAlignment(.trailing)
                    .help("目前 5h 窗口何時重置（每個窗口從第一則訊息起算 5 小時，所以會往後滾）；帳號被鎖住時改顯示解鎖時間。各窗口的重置都在列的提示裡。")
            }
            .font(Theme.Fonts.mono(9 * scale))
            .foregroundStyle(Theme.text4)
            ForEach(accounts) { account in
                let stale = account.staleSince != nil
                GridRow(alignment: .center) {
                    HStack(spacing: 3) {
                        Text(Self.shortAlias(account.alias))
                            .font(Theme.Fonts.mono(10.5 * scale, .medium))
                            .foregroundStyle(account.error == nil && !stale ? Theme.text2 : Theme.text4)
                        if stale {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 9 * scale, weight: .semibold))
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .help(account.alias)
                    ForEach(Self.columns, id: \.title) { column in
                        if let bucket = bucket(account, column.match) {
                            cell(bucket).opacity(stale ? 0.45 : 1)
                        } else {
                            Text("—").font(Theme.Fonts.mono(10 * scale)).foregroundStyle(Theme.text4)
                        }
                    }
                    // A hairline keeps the reset column from reading as part
                    // of the 點數 column, which is mostly "—".
                    Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
                    Text(resetText(account))
                    .font(Theme.Fonts.mono(9.5 * scale))
                    .foregroundStyle(resetBucket(account).map { tint($0.percent) } ?? Theme.text4)
                    .opacity(stale ? 0.45 : 1)
                    .gridColumnAlignment(.trailing)
                    .lineLimit(1)
                    .fixedSize() // "週四 08:00" must not truncate
                }
                .help(rowHelp(account))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bucket(_ account: AppModel.QuotaAccount,
                        _ match: (String) -> Bool) -> AppModel.QuotaBucket? {
        account.buckets.first { match($0.key) }?.value
    }

    private func cell(_ bucket: AppModel.QuotaBucket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(bucket.percent)%")
                .font(Theme.Fonts.mono(10.5 * scale, .medium))
                .foregroundStyle(tint(bucket.percent))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !compact {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(tint(bucket.percent))
                            .frame(width: max(0, geo.size.width * min(1, Double(bucket.percent) / 100)))
                    }
                }
                .frame(height: 3)
            }
        }
        // Flexible: the four window columns share whatever width the notes
        // column has, so the grid fills a wide column and squeezes to ~245 pt.
        .frame(minWidth: 30, maxWidth: .infinity, alignment: .leading)
    }

    private func tint(_ percent: Int) -> Color {
        percent >= 100 ? Theme.crit : (percent >= 70 ? Theme.warn : Theme.accent)
    }

    /// Which window the reset column talks about. Fixed by rule, not by
    /// whichever window happens to be fullest: that rule flipped between the
    /// 5h reset (tonight) and the weekly reset (next Friday) every time the
    /// percentages crossed, which read as the time changing at random.
    ///   1. a window at 100% with a reset date — the account is locked, show
    ///      when the LAST lock lifts (credits have no reset date; skipped);
    ///   2. else the 5h session window when the account has one — the window
    ///      that rolls soonest; idle (no window open) shows "—";
    ///   3. else (codex / opencode: one window only) the earliest reset.
    static func resetBucket(_ buckets: [String: AppModel.QuotaBucket]) -> AppModel.QuotaBucket? {
        let dated = buckets.values.filter { $0.resetsAt != nil }
        if let locked = dated.filter({ $0.percent >= 100 }).max(by: { $0.resetsAt! < $1.resetsAt! }) {
            return locked
        }
        if let session = buckets.first(where: { $0.key.lowercased().contains("5h") })?.value {
            return session.resetsAt == nil ? nil : session
        }
        return dated.min { $0.resetsAt! < $1.resetsAt! }
    }

    private func resetBucket(_ account: AppModel.QuotaAccount) -> AppModel.QuotaBucket? {
        Self.resetBucket(account.buckets)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let weekday: DateFormatter = {
        // "週一 08:00" — a bare 一 in a mono face reads as a dash.
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hant_TW"); f.dateFormat = "EEE HH:mm"; return f
    }()

    /// "claude-ext2" → "ext2": the column is narrow and every row is a claude
    /// account unless it says otherwise; the full alias is in the tooltip.
    static func shortAlias(_ alias: String) -> String {
        alias.hasPrefix("claude-") ? String(alias.dropFirst("claude-".count)) : alias
    }

    /// `resetBucket`'s reset, always with a day: 今 19:20 / 明 02:59 /
    /// 週四 08:00 / 下週六 16:00.
    private func resetText(_ account: AppModel.QuotaAccount) -> String {
        if account.error != nil { return "未登入" }
        guard let reset = resetBucket(account)?.resetsAt else { return "—" }
        return Self.dayLabel(reset)
    }

    /// 今 / 明 / 週X for the coming week; a reset a full week out shares
    /// today's weekday name, so it says 下週X instead of making you count.
    static func dayLabel(_ date: Date) -> String {
        // The usage API hands back "17:10:00.3" one call and "17:09:59.8" the
        // next; shown as HH:mm that wobbles between 01:09 and 01:10. Nearest
        // minute.
        let date = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return weekday.string(from: date)
        case 0: return "今 " + clock.string(from: date)
        case 1: return "明 " + clock.string(from: date)
        case 2 ... 6: return weekday.string(from: date)
        case 7 ... 13: return "下" + weekday.string(from: date)
        default:
            let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f.string(from: date)
        }
    }

    private func rowHelp(_ account: AppModel.QuotaAccount) -> String {
        if let error = account.error { return "\(account.alias)：\(error)" }
        var head = [account.alias]
        if let since = account.staleSince {
            head.append("⚠ 自 \(Self.dayLabel(since)) 起抓不到新資料，下面是舊數字"
                        + (account.note.map { "：\($0)" } ?? ""))
        }
        let lines = account.buckets.sorted { $0.key < $1.key }.map { name, bucket in
            "· \(name) \(bucket.percent)% · 重置 \(bucket.resetsAt.map(Self.dayLabel) ?? "—")"
        }
        return (head + lines).joined(separator: "\n")
    }
}

struct QuotaFooterView: View {
    @EnvironmentObject var model: AppModel
    /// nil = natural height. When the user drags the section shorter the grid
    /// degrades in two steps — first compact (bars off, tighter rows), then a
    /// vertical scroll — so no account ever drops off the bottom.
    var contentHeight: Double? = nil
    /// Notes column narrower than ~260 pt: drop the timestamp from the header.
    var narrow = false
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
                    .font(Theme.Fonts.display(12, .semibold))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .fixedSize()
                if model.quotaStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("上次更新失敗，顯示的是舊資料（stderr 在 /tmp/taskdeck-quota.err）")
                }
                Spacer(minLength: 4)
                if let t = model.quotaUpdatedAt, !narrow {
                    Text(t, style: .time)
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
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
                                     help: "強制重新抓取最新（略過快取）；每 5 分鐘也會自動更新"
                                         + (model.quotaUpdatedAt.map { "；上次 " + Self.clock.string(from: $0) } ?? "")) {
                        model.refreshQuota(force: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.headerStrip)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }

            if expanded {
                if !model.quotaAccounts.isEmpty {
                    let scale = model.uiScale * quotaScale
                    let rows = model.quotaAccounts.count
                    let full = QuotaGrid.naturalHeight(rows: rows, scale: scale, compact: false)
                    let compactH = QuotaGrid.naturalHeight(rows: rows, scale: scale, compact: true)
                    let height = contentHeight ?? full
                    let compact = height < full - 1
                    let grid = QuotaGrid(accounts: model.quotaAccounts, scale: scale, compact: compact)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    if height < compactH - 1 {
                        ScrollView(.vertical, showsIndicators: false) { grid }
                            .frame(height: height)
                    } else {
                        grid.frame(height: height, alignment: .top)
                    }
                } else {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Text(AnsiRenderer.render(model.quotaText.isEmpty ? "（讀取中…）" : model.quotaText,
                                                 size: 11 * model.uiScale * quotaScale))
                            .lineSpacing(2)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .frame(height: contentHeight.map { CGFloat($0) } ?? quotaHeight)
                }
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private var quotaHeight: CGFloat {
        let lines = max(3, model.quotaText.split(separator: "\n", omittingEmptySubsequences: false).count)
        return CGFloat(min(lines, 12)) * 17 * CGFloat(model.uiScale * quotaScale) + 16
    }
}
