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
    /// Measured height of the dock pill (with its outer padding); the list
    /// keeps that much bottom margin so the last row can scroll clear of it.
    @State private var dockHeight: CGFloat = 50
    @AppStorage("pinnedSectionExpanded") private var pinnedExpanded = true
    @AppStorage("needsYouSectionExpanded") private var needsYouExpanded = true
    @AppStorage("aiRunningSectionExpanded") private var aiRunningExpanded = true
    @AppStorage("longRunSectionExpanded") private var longRunExpanded = true
    @AppStorage("runningSectionExpanded") private var runningExpanded = true
    @AppStorage("readSectionExpanded") private var readExpanded = true
    @AppStorage("waitingSectionExpanded") private var waitingExpanded = true
    @AppStorage("doneSectionExpanded") private var doneExpanded = true
    @AppStorage("sunkSectionExpanded") private var sunkExpanded = false

    var body: some View {
        // 由上而下：置頂（手動釘的常駐任務沒事時的家：AI 在跑／在等你時照常
        // 去下面的區，看過或沒動靜回到這；不下沉、不自動封存，可拖曳排序）→
        // 等你（自動佇列）→ AI 執行中（訊號驅動）→ 長期運行（手動
        // 放進去的長跑 agent，訊號不搬動它，可拖曳排序）→ 待開工（預設家：新任務
        //／手動作業／訊號過期，可拖曳排序）→ 已讀（看過待回）→ 等待外部（手動）
        // → 半封存（>3 天沒動靜，預設折疊；滿 30 天自動歸入已完成）→ 已完成
        //（封存）。規則見 AppModel.sidebarGroup / autoArchiveSweep。
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
        let pinned = groups[.pinned] ?? []
        // Pinned tasks the AI currently has out of the shelf (running, or
        // owing you a reply below) — the header says so, so the shelf never
        // looks like it lost a task.
        let pinnedAway = visibleTasks.filter {
            $0.isPinned && $0.status == "active" && model.sidebarGroup($0) != .pinned
        }.count
        let aiRunning = groups[.aiRunning] ?? []
        let longRun = groups[.longRunning] ?? []
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
        // Which lanes show, top to bottom — the one source for the `if`s
        // below and for which header is first (that one sits flush under the
        // search field).
        // 待開工 stays as a drop target even when empty, except in search.
        let laneShown: [(AppModel.SidebarGroup, Bool)] = [
            (.pinned, !pinned.isEmpty), (.needsYou, !needsYou.isEmpty),
            (.aiRunning, !aiRunning.isEmpty), (.longRunning, !longRun.isEmpty),
            (.idle, !idle.isEmpty || !searchActive), (.read, !read.isEmpty),
            (.waitingExt, !waiting.isEmpty), (.semiArchived, !semi.isEmpty),
            (.done, !done.isEmpty),
        ]
        let shownLanes = laneShown.filter(\.1).map(\.0)
        let firstLane = shownLanes.first

        // 不用 List 的 selection 系統：它的選取膠囊跟自畫常駐底是兩個
        // 形狀不同的圖層，焦點在側邊欄時必然疊成兩層色。選取全自管——
        // 點列設 model.selection，唯一的高亮圖層就是 listRowBackground。
        List {
            if shownLanes.contains(.pinned) {
                sidebarSection(isExpanded: $pinnedExpanded, first: firstLane == .pinned) {
                    if searchActive {
                        ForEach(pinned) { row($0, group: .pinned) }
                    } else {
                        ForEach(pinned) { row($0, group: .pinned) }
                            .onMove { from, to in
                                model.moveLaneTasks(pinned.map(\.id), from: from, to: to)
                            }
                    }
                } header: {
                    laneHeader(.pinned, pinned.count,
                               pinnedAway > 0 ? "另 \(pinnedAway) 個在下方" : "不封存")
                }
            }
            if shownLanes.contains(.needsYou) {
                sidebarSection(isExpanded: $needsYouExpanded, first: firstLane == .needsYou) {
                    ForEach(needsYou) { row($0, group: .needsYou) }
                } header: {
                    // Ticks on its own: the sidebar no longer re-renders every
                    // 2 s for the activity sample, which kept this fresh by
                    // accident.
                    TimelineView(.everyMinute) { context in
                        laneHeader(.needsYou, needsYou.count, owedText(needsYou, now: context.date))
                    }
                }
            }
            if shownLanes.contains(.aiRunning) {
                sidebarSection(isExpanded: $aiRunningExpanded, first: firstLane == .aiRunning) {
                    ForEach(aiRunning) { row($0, group: .aiRunning) }
                } header: {
                    laneHeader(.aiRunning, aiRunning.count, accountsText(aiRunning))
                }
            }
            if shownLanes.contains(.longRunning) {
                sidebarSection(isExpanded: $longRunExpanded, first: firstLane == .longRunning) {
                    if searchActive {
                        ForEach(longRun) { row($0, group: .longRunning) }
                    } else {
                        ForEach(longRun) { row($0, group: .longRunning) }
                            .onMove { from, to in
                                model.moveLaneTasks(longRun.map(\.id), from: from, to: to)
                            }
                    }
                } header: {
                    let summary = longRunSummary(longRun)
                    laneHeader(.longRunning, longRun.count, summary.text, subTint: summary.tint)
                }
            }
            if shownLanes.contains(.idle) {
                sidebarSection(isExpanded: $runningExpanded, first: firstLane == .idle) {
                    if searchActive {
                        ForEach(idle) { row($0, group: .idle) }
                    } else {
                        ForEach(idle) { row($0, group: .idle) }
                            .onMove { from, to in
                                model.moveLaneTasks(idle.map(\.id), from: from, to: to)
                            }
                    }
                } header: {
                    laneHeader(.idle, idle.count, "")
                }
            }
            if shownLanes.contains(.read) {
                sidebarSection(isExpanded: $readExpanded, first: firstLane == .read) {
                    ForEach(read) { row($0, group: .read) }
                } header: {
                    laneHeader(.read, read.count, "看過待回")
                }
            }
            if shownLanes.contains(.waitingExt) {
                sidebarSection(isExpanded: $waitingExpanded, first: firstLane == .waitingExt) {
                    ForEach(waiting) { row($0, group: .waitingExt) }
                } header: {
                    laneHeader(.waitingExt, waiting.count, "同事 / CI")
                }
            }
            if shownLanes.contains(.semiArchived) {
                sidebarSection(isExpanded: $sunkExpanded, first: firstLane == .semiArchived) {
                    ForEach(semi) { row($0, group: .semiArchived) }
                } header: {
                    laneHeader(.semiArchived, semi.count, ">3 天")
                }
            }
            if shownLanes.contains(.done) {
                sidebarSection(isExpanded: $doneExpanded, first: firstLane == .done) {
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
        // −4: lane headers are plain rows now (see sidebarSection), and a
        // plain row is at least 32 pt (defaultMinListRowHeight does not reach
        // the sidebar List — measured) where the old Section header was 28.
        // The first header pads itself to 32 and the list starts 4 pt
        // higher, which lands it, and the rows under it, exactly where the
        // Section header had them.
        .safeAreaInset(edge: .top, spacing: -Self.firstHeaderLift) {
            searchHeader(resultCount: visibleTasks.count)
        }
        // A floating pill, not a strip: it is opaque enough to read over
        // rows scrolling beneath it, and the list keeps its glass. It is an
        // overlay over a bottom safe-area padding, NOT safeAreaInset(.bottom):
        // on the AppKit-backed List the inset host lays its content out
        // against geometry the scroll view reports late, and twice now the
        // + glyph's layer ended up parked at the centre of the list while the
        // button itself stayed in the dock (the empty circle still made a
        // task; the stray glyph did nothing). An overlay is placed from the
        // List's own frame, which never collapses. The padding alone gives
        // the scroll view its bottom content inset, so the last row still
        // scrolls clear of the pill (contentMargins does not reach this
        // List — measured: the inset stays 0). Order matters: the padding
        // goes INSIDE the overlay, or the pill itself gets lifted by it.
        .safeAreaPadding(.bottom, dockHeight)
        .overlay(alignment: .bottom) {
            DockView()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
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
    ///
    /// The header is an ordinary row, NOT a `Section` header. A Section
    /// header is an NSOutlineView group row, and AppKit keeps every group
    /// row's index in a set (`NSTableBannerRowData`) that it shifts on each
    /// row insert. Four times (10-26, 10-29, 10-30, 11-17) that set held an
    /// index at NSNotFound − 1, and the next row a lane gained threw
    /// NSRangeException out of `shiftBannerRowIndexesStartingAtIndex:by:`.
    /// Thrown from SwiftUI's update flush it froze the window; thrown from
    /// layout (11-17 13:42) AppKit killed the GUI outright. With no group
    /// rows the set stays empty — measured offscreen: [0, 3, 5] with
    /// Sections, [] with header rows, through the same inserts/moves — so
    /// there is nothing left to overflow. (Turning off floating headers does
    /// not help: SwiftUI's sidebar already has floatsGroupRows == false and
    /// the set is kept regardless.)
    @ViewBuilder
    private func sidebarSection<Content: View, Header: View>(
        isExpanded: Binding<Bool>,
        first: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) -> some View {
        // Group, not a container: the List flattens it, so the header and
        // each task stay separate rows.
        Group {
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
            // Where the Section header sat (measured offscreen at 230 pt:
            // header x 14…228, plain row 16…214). Horizontally listRowInsets
            // ADD to the plain row's inset (zero = unchanged), so padding
            // moves it; vertically zero drops the plain row's 4 pt above and
            // below, which a header never had.
            .padding(.leading, -2)
            .padding(.trailing, -14)
            // The first lane sits flush under the search field, as its
            // Section header did (see firstHeaderLift); the rest get the
            // section break's air.
            .padding(.top, first ? Self.firstHeaderLift : 13)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
            .accessibilityAddTraits(.isHeader)
            if searchActive || isExpanded.wrappedValue {
                content()
            }
        }
    }

    /// A plain sidebar row's 32 pt floor minus the 28 pt Section header it
    /// replaced (see the List's top safeAreaInset).
    private static let firstHeaderLift: CGFloat = 4

    /// Lane header: the count is the loudest element (display face, lane
    /// colour), the name reads as its label, and a short mono subtitle says
    /// what the lane means or how long the oldest item has waited.
    private func laneHeader(_ group: AppModel.SidebarGroup, _ count: Int, _ sub: String,
                            subTint: Color = Theme.text3) -> some View {
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
                    .foregroundStyle(subTint)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(quiet ? Theme.text3 : Theme.laneColor(group))
        .padding(.vertical, 3)
        .textCase(nil)
    }

    static func laneName(_ group: AppModel.SidebarGroup) -> String {
        switch group {
        case .pinned: return "置頂"
        case .needsYou: return "等你"
        case .aiRunning: return "AI 執行中"
        case .longRunning: return "長期運行"
        case .idle: return "待開工"
        case .read: return "已讀"
        case .waitingExt: return "等待外部"
        case .semiArchived: return "半封存"
        case .done: return "已完成"
        }
    }

    /// "最久 2 天" — how long the oldest unanswered task has been waiting.
    /// Minutes at the finest: a lane header is not a stopwatch.
    private func owedText(_ tasks: [TaskNote], now: Date) -> String {
        guard let oldest = tasks.compactMap({ model.aiAttention($0.id)?.since }).min() else { return "" }
        let seconds = now.timeIntervalSince(oldest)
        if seconds < 3600 { return "最久 \(max(1, Int(seconds / 60))) 分" }
        return "最久 " + activityDuration(seconds)
    }

    private func accountsText(_ tasks: [TaskNote]) -> String {
        let teams = Set(tasks.compactMap { model.taskTeam($0.id) })
        return teams.isEmpty ? "" : "\(teams.count) 帳號"
    }

    /// 長期運行 header: the most pressing live state in the lane, so a
    /// blocked or finished agent still shows with the section collapsed.
    private func longRunSummary(_ tasks: [TaskNote]) -> (text: String, tint: Color) {
        let states = tasks.map { model.liveState($0.id) }
        func count(_ state: LiveState) -> Int { states.filter { $0 == state }.count }
        if count(.permission) > 0 { return ("\(count(.permission)) 要授權", Theme.crit) }
        if count(.newOutput) > 0 { return ("\(count(.newOutput)) 有新輸出", Theme.Lane.you) }
        if count(.running) > 0 { return ("\(count(.running)) 在跑", Theme.text3) }
        return ("sub-agent", Theme.text3)
    }

    /// The live state a 長期運行 row carries — the lane never moves a task,
    /// so this is where a blocked or finished agent shows. nil = quiet.
    private func liveBadge(_ state: LiveState) -> (text: String, tint: Color, help: String)? {
        switch state {
        case .permission: return ("要授權", Theme.crit, "有終端停在權限確認，等你處理")
        case .newOutput: return ("新輸出", Theme.Lane.you, "AI 停下來了，有你還沒看的輸出（點開任務就算看過）")
        case .running: return ("在跑", Theme.Lane.ai, "AI 正在跑（主對話，或它留下的背景工作）")
        case .quiet: return nil
        }
    }

    /// Tooltip of a held row's 背景 chip: what is still running, and why the
    /// task is in AI 執行中 rather than 等你.
    static func backgroundHelp(_ s: BackgroundSummary) -> String {
        var kinds: [String] = []
        if s.agents > 0 { kinds.append("sub-agent \(s.agents)") }
        if s.shells > 0 { kinds.append("背景指令 \(s.shells)") }
        if s.monitors > 0 { kinds.append("監看 \(s.monitors)") }
        if s.others > 0 { kinds.append("其他 \(s.others)") }
        var lines = [kinds.isEmpty
            ? "主對話這一輪說完了，sub-agent 還在動；跑完 AI 會自己回來"
            : "主對話這一輪說完了，背景還在跑（\(kinds.joined(separator: "、"))）；跑完 AI 會自己回來"]
        lines += s.labels.prefix(6).map { "· \($0)" }
        return lines.joined(separator: "\n")
    }

    private static let wakeTimeToday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let wakeTimeOtherDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    /// "13:50" for a wake-up today, "11-20 09:00" for another day.
    static func wakeText(_ date: Date, now: Date = Date()) -> String {
        (Calendar.current.isDate(date, inSameDayAs: now) ? wakeTimeToday : wakeTimeOtherDay)
            .string(from: date)
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
    /// lanes that mean something is happening or matters (置頂 / 等你 / AI /
    /// 長期運行 / 已讀 / 等待外部).
    private func laneRail(_ group: AppModel.SidebarGroup) -> Color? {
        switch group {
        case .pinned, .needsYou, .aiRunning, .longRunning, .read, .waitingExt:
            return Theme.laneColor(group)
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
        let background = model.backgroundSummary(t.id)
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
                    if group == .longRunning, let badge = liveBadge(model.liveState(t.id)) {
                        Text(badge.text)
                            .font(Theme.Fonts.ui(9 * model.uiScale, .semibold))
                            .foregroundStyle(badge.tint)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(badge.tint.opacity(0.14), in: Capsule())
                            .help(badge.help)
                    } else if model.hasUnseenBackgroundOutput(t.id) {
                        // The stop that left background work running said
                        // something: the task stays in AI 執行中, the mark
                        // says there is output to read (viewing clears it).
                        Text("新輸出")
                            .font(Theme.Fonts.ui(9 * model.uiScale, .semibold))
                            .foregroundStyle(Theme.Lane.you)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.Lane.you.opacity(0.14), in: Capsule())
                            .help("AI 這一輪說完了，但留了背景工作在跑、之後會自己回來；它說的話你還沒看（點開任務就算看過）")
                    }
                    // A pinned task the AI has out of the shelf: the pin says
                    // it goes back to 置頂 once it is seen.
                    if t.isPinned && t.status == "active" && group != .pinned {
                        Image(systemName: "pin.fill")
                            .font(Theme.Fonts.ui(9 * model.uiScale, .bold))
                            .foregroundStyle(Theme.Lane.pin)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.Lane.pin.opacity(0.14), in: Capsule())
                            .help("置頂任務：AI 跑完、你看過後回到置頂")
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
                    // The account set by hand — cached, no per-render disk.
                    if let team = model.taskTeam(t.id) {
                        Text(QuotaGrid.shortAlias(team))
                            .help("\(team)（右鍵 → 帳號 可改）")
                            .font(Theme.Fonts.mono(9 * model.uiScale, .medium))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                    // What a stop left running — why the task is in AI 執行中
                    // although the conversation itself has stopped.
                    if let background, background.taskCount > 0 || background.unlisted {
                        Text(background.taskCount > 0 ? "背景 \(background.taskCount)" : "背景")
                            .font(Theme.Fonts.ui(9 * model.uiScale, .medium))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .help(Self.backgroundHelp(background))
                    }
                    if let wake = background?.nextWake {
                        Text("⏰ \(Self.wakeText(wake))")
                            .font(Theme.Fonts.mono(9 * model.uiScale, .medium))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.06), in: Capsule())
                            .help(background?.recurring == true
                                  ? "AI 排了循環喚醒，下一次在這個時間；到時它會自己回來"
                                  : "AI 排了定時喚醒，到時它會自己回來")
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
            // visibly crawl behind it. Hover keeps a light fade — keyed on
            // THIS row's hover state, so moving the pointer animates the two
            // rows it left and entered, not every visible row.
            .animation(.easeInOut(duration: 0.15), value: hoveredSlug == t.id)
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
            if t.isPinned {
                Button { model.setPinned(t.id, false) } label: {
                    Label("取消置頂", systemImage: "pin.slash")
                }
            } else if t.status == "active" {
                Button { model.setPinned(t.id, true) } label: {
                    Label("置頂（常駐、不封存）", systemImage: "pin")
                }
            }
            Menu("帳號：\(model.taskTeam(t.id) ?? "未設定")") {
                TaskAccountMenuItems(model: model, slug: t.id)
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
                    if t.group == GroupingRules.longRunGroup {
                        Divider()
                        Button("移出長期運行（交回自動分組）") { model.setGroupFlag(t.id, nil) }
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

/// The choices for which account a task uses (sidebar context menu, header
/// chip): ✓ marks the one set by hand, 「正在跑」 what the AI CLIs in its
/// terminals actually run right now — so fixing a stale pick is one click.
struct TaskAccountMenuItems: View {
    let model: AppModel
    let slug: String
    // Read at init, not in `body`: with only `model` and `slug` as inputs
    // SwiftUI may keep a stale body, and the checkmark would lag the pick.
    let chosen: String?
    let running: Set<String>

    init(model: AppModel, slug: String) {
        self.model = model
        self.slug = slug
        chosen = model.taskTeam(slug)
        running = model.runningTeams(slug)
    }

    var body: some View {
        ForEach(model.config.teams) { team in
            Button {
                model.setTaskTeam(slug, team.id)
            } label: {
                accountMenuLabel(team, chosen: team.id == chosen, running: running.contains(team.id))
            }
        }
        if chosen != nil {
            Divider()
            Button("清除") { model.setTaskTeam(slug, nil) }
        }
    }
}

/// One row of an account menu (task or pane).
@ViewBuilder
func accountMenuLabel(_ team: TeamDef, chosen: Bool, running: Bool) -> some View {
    let title = running ? "\(team.label) · 正在跑" : team.label
    if chosen {
        Label(title, systemImage: "checkmark")
    } else {
        Text(title)
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
        // ViewThatFits — back when the dock lived in a safeAreaInset, that
        // collapsed the inset to zero height and left the + floating over
        // the list.
        // While disconnected, 重連 takes the memory figure's room.
        row(totals, memory: sidebarWidth >= 235 && model.daemonOK, idle: sidebarWidth >= 190)
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
                    // SwiftUI draws the glyph (a shape layer) and the circle
                    // (a plain layer) as two independently positioned
                    // siblings, which is how the + could drift away from its
                    // circle. Rasterising the label fuses them into one
                    // layer: they now move together or not at all.
                    .drawingGroup()
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
                    .fixedSize() // squeezed, it wrapped into 重 over 連
            }
        }
        .help(model.daemonOK
            ? (model.daemonNote ?? "taskdeckd 連線中（GUI 重開不影響終端）")
            : "daemon 未連線，每隔幾秒自動重試；按「重連」立刻重試")
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(slug)
                    .font(Theme.Fonts.display(22, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Which Claude account the task uses — set by hand, never
                // guessed (see AppModel.taskTeam). Always shown so a
                // shell-only task can be given one too; dim when unset.
                let team = model.taskTeam(slug)
                let tint = team == nil ? Theme.text3 : Theme.accent
                Menu {
                    TaskAccountMenuItems(model: model, slug: slug)
                } label: {
                    Text(team ?? "設定帳號")
                        .font(Theme.Fonts.mono(10, .medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.14), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("這個任務用的 Claude 帳號：自己設定，系統不會自動改。選單裡標「正在跑」的，是終端裡實際開著的帳號。")
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
            // On the shelf, 已讀 / 等待外部 would change nothing you can see:
            // a pinned task rests on 置頂 whichever of the two it is.
            if group != .read && group != .pinned {
                chip("eye", task.isPinned ? "標記已讀（看過，回到置頂）" : "標記已讀（看過，先不回）") {
                    model.setGroupFlag(task.id, "read")
                }
            }
            if group != .waitingExt && group != .pinned {
                chip("hourglass", "移到等待外部（同事 / review / CI）") {
                    model.setGroupFlag(task.id, "waiting")
                }
            }
            // 長期運行 is the one lane nothing pulls a task out of, so its
            // rows get the way back: clear the flag, automatic grouping
            // places the task again.
            if group == .longRunning {
                chip("arrow.uturn.backward", "移出長期運行（交回自動分組）") {
                    model.setGroupFlag(task.id, nil)
                }
            } else {
                chip("infinity", "移到長期運行（sub-agent 長時間跑，放著不會被搬走）") {
                    model.setGroupFlag(task.id, GroupingRules.longRunGroup)
                }
            }
            if task.isPinned {
                chip("pin.slash", "取消置頂（交回一般分組）") { model.setPinned(task.id, false) }
            } else {
                chip("pin", "置頂（常駐、不封存；AI 在跑或等你時照常去下面的區）") {
                    model.setPinned(task.id, true)
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
            .simultaneousGesture(TapGesture().onEnded { session.focus(.notes) })

            // NSTextView-backed: gives us ⌘B / ⌘I / ⌘⇧X markdown wrapping and a
            // reliable "became focus zone" signal (becomeFirstResponder).
            MarkdownNotesEditor(
                text: Binding(get: { session.noteText },
                              set: { session.noteText = $0 }),
                fontSize: 13 * model.uiScale,
                onFocus: { session.focus(.notes) }
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
/// plus a bar per cell, colour at ≥70% / 100%, a countdown beside the 5h
/// usage and the weekly window's reset time. Every window's reset is in
/// the row tooltip.
///
/// Rows come in claude-quota's order until a header is clicked: each
/// header sorts by its column, ascending → descending → back to that order
/// (QuotaSort in TaskDeckCore has the rules; the choice persists under the
/// `quotaSort` default). A column sorts by exactly what its cells show —
/// `sortKey` reads it with the cells' own helpers — and a "—" / 未登入 cell
/// sorts last either way. codex, aigw and any other non-Claude account stay
/// at the bottom in claude-quota's order whatever the sort.
struct QuotaGrid: View {
    let accounts: [AppModel.QuotaAccount]
    let scale: Double
    /// Squeezed: no bars, half the row spacing — every number stays.
    var compact = false
    /// QuotaSort's stored form; "" (or anything unreadable) = claude-quota's order.
    @AppStorage("quotaSort") private var sortStored = ""

    /// Height the grid wants (including its 8 pt paddings) for `rows`
    /// accounts, so the section can decide between full, compact and
    /// scrolling. Row: text ~13 pt + bar 5 pt + spacing.
    static func naturalHeight(rows: Int, scale: Double, compact: Bool) -> Double {
        let header = 14 * scale + (compact ? 3 : 6)
        let row = compact ? 13 * scale + 3 : 18 * scale + 6
        return 16 + header + Double(rows) * row
    }

    /// Widest the grid gets, in points at scale 1. The three window columns
    /// are flexible, so on a wide notes column (a 5K desk) the bars stretched
    /// into long ribbons that read as more than they are. 460 pt is the
    /// ~470 pt column the table was tuned on plus a little; past that the
    /// extra column width stays blank on the right. (James 261008.)
    static let maxWidth: Double = 460
    private static let columnSpacing: CGFloat = 6

    private static let columns: [(title: String, sort: QuotaSortColumn, match: (String) -> Bool)] = [
        ("5h", .fiveHour, { $0.lowercased().contains("5h") }),
        ("週", .weekly, { $0.lowercased().hasPrefix("weekly all") || $0.lowercased() == "weekly" }),
        ("Fable", .fable, { $0.lowercased().contains("fable") || $0.lowercased().contains("model") }),
        ("點數", .credits, { $0.lowercased().contains("credit") }),
    ]

    /// The header row, left to right: a title per column, and the hairline
    /// column between 點數 and 重置.
    private enum HeaderSlot: Hashable {
        case column(QuotaSortColumn)
        case hairline
    }

    private static let headerSlots: [(slot: HeaderSlot, title: String)] =
        [(.column(.account), "帳號")] + columns.map { (.column($0.sort), $0.title) }
            + [(.hairline, ""), (.column(.reset), "重置")]

    /// Where the Grid put each header-row cell, for the clickable headers
    /// laid over them.
    private struct HeaderAnchors: PreferenceKey {
        static let defaultValue: [HeaderSlot: Anchor<CGRect>] = [:]
        static func reduce(value: inout [HeaderSlot: Anchor<CGRect>],
                           nextValue: () -> [HeaderSlot: Anchor<CGRect>]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private var sort: QuotaSort? { QuotaSort(stored: sortStored) }

    var body: some View {
        // The 5h countdown is derived from the reset time at render; tick
        // once a minute so it does not sit still between quota polls.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            // Sorted once here, with the same `now` the cells render with,
            // and shared by both copies ViewThatFits lays out.
            let rows = sorted(now: context.date)
            // Fill the column when the grid's minimum fits; otherwise scroll
            // sideways rather than clip the reset column — with the trailing
            // edge faded, so a half glyph reads as "more this way", not as a
            // layout bug.
            ViewThatFits(in: .horizontal) {
                grid(rows, now: context.date)
                ScrollView(.horizontal, showsIndicators: false) {
                    grid(rows, now: context.date).padding(.trailing, 14)
                }
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 14)
                    }
                )
            }
        }
    }

    private func grid(_ rows: [AppModel.QuotaAccount], now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Self.columnSpacing, verticalSpacing: compact ? 3 : 6) {
            // The titles as plain, hidden text, so the Grid sizes every
            // column exactly as it did before headers sorted. The clickable
            // headers are drawn over them (`headers`): a header that fills
            // its cell, or carries an arrow, inside the Grid moves the
            // columns — measured 2026-11-26, 1–5 pt at various widths, and
            // gridCellUnsizedAxes does not stop it.
            GridRow {
                headerTitle("帳號", .column(.account)).gridColumnAlignment(.leading)
                ForEach(Self.columns, id: \.title) { column in
                    headerTitle(column.title, .column(column.sort))
                }
                Color.clear.frame(width: 1)
                    .anchorPreference(key: HeaderAnchors.self, value: .bounds) { [.hairline: $0] }
                headerTitle("重置", .column(.reset)).gridColumnAlignment(.trailing)
            }
            .font(Theme.Fonts.mono(9 * scale))
            ForEach(rows) { account in
                // One missed poll (a 429) keeps numbers under five minutes
                // old; badge only what has stayed unreachable — a dead token.
                // Badge only: the row keeps its colours (James's call — the
                // numbers are still the last real ones, not lesser ones).
                let stale = account.staleSince.map { now.timeIntervalSince($0) > 15 * 60 } ?? false
                GridRow(alignment: .center) {
                    HStack(spacing: 3) {
                        Text(Self.shortAlias(account.alias))
                            .font(Theme.Fonts.mono(10.5 * scale, .medium))
                            .foregroundStyle(account.error == nil ? Theme.text2 : Theme.text4)
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
                        if let bucket = Self.bucket(account, column.match) {
                            let countdown = column.title == "5h"
                                ? bucket.resetsAt.flatMap { Self.remaining(until: $0, now: now) } : nil
                            cell(bucket, note: countdown, narrow: column.title == "點數")
                        } else {
                            Text("—").font(Theme.Fonts.mono(10 * scale)).foregroundStyle(Theme.text4)
                        }
                    }
                    // A hairline keeps the reset column from reading as part
                    // of the 點數 column, which is mostly "—".
                    Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
                    resetCell(account, now: now)
                }
                .help(rowHelp(account))
            }
        }
        .overlayPreferenceValue(HeaderAnchors.self) { anchors in
            GeometryReader { proxy in
                headers(anchors.mapValues { proxy[$0] })
            }
            .font(Theme.Fonts.mono(9 * scale))
        }
        // Capped, then left-aligned in whatever the column offers: a wider
        // notes column leaves blank space on the right instead of longer
        // bars. Narrower than the grid's minimum still falls through to the
        // sideways scroll above.
        .frame(maxWidth: Self.maxWidth * scale, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerTitle(_ title: String, _ slot: HeaderSlot) -> some View {
        Text(title)
            .hidden()
            .anchorPreference(key: HeaderAnchors.self, value: .bounds) { [slot: $0] }
    }

    /// The clickable headers, each over its hidden title. A cell runs from
    /// its title's leading edge to where the next column starts (less the
    /// spacing); 重置, right-aligned, from past the hairline to its title's
    /// trailing edge. Every cell is the height of the header row.
    @ViewBuilder
    private func headers(_ frames: [HeaderSlot: CGRect]) -> some View {
        let slots = Self.headerSlots
        let top = frames.values.map(\.minY).min() ?? 0
        let bottom = frames.values.map(\.maxY).max() ?? 0
        let sort = self.sort
        ForEach(slots.indices, id: \.self) { index in
            if case let .column(column) = slots[index].slot, let title = frames[slots[index].slot],
               let start = column == .reset ? frames[.hairline].map({ $0.maxX + Self.columnSpacing }) : title.minX,
               let end = column == .reset ? title.maxX
                   : frames[slots[index + 1].slot].map({ $0.minX - Self.columnSpacing }),
               end > start {
                QuotaHeaderCell(title: slots[index].title,
                                direction: sort?.column == column ? sort?.direction : nil,
                                help: Self.headerHelp(column),
                                titleFrame: title,
                                cellFrame: CGRect(x: start, y: top, width: end - start, height: bottom - top),
                                trailing: column == .reset) {
                    sortStored = QuotaSort.afterClick(on: column, from: sort)?.stored ?? ""
                }
            }
        }
    }

    /// Every header's tooltip ends with how sorting works; 5h and 重置 keep
    /// their explanations in front of it.
    private static func headerHelp(_ column: QuotaSortColumn) -> String {
        var note: String?
        var detail = ""
        switch column {
        case .account:
            detail = "（依顯示的名稱，ext2 在 ext10 前）"
        case .fiveHour:
            note = "5h 窗口用量；旁邊的時間 = 這個窗口還有多久重置。窗口從你的第一則訊息起算 5 小時，到期後下一則訊息才開新窗口，所以重置時間會一段一段往後跳。"
        case .reset:
            note = "長窗口還有多久重置。週 = 週額度（週 / Fable 共用同一個窗口；opencode 的週預算也是）、月 = 月額度（codex 的點數）。確切的日期時間在列的提示裡；5h 窗口的倒數在 5h 那格。"
            detail = "（升冪 = 最快重置的在前）"
        case .weekly, .fable, .credits:
            break
        }
        let hint = "點標題排序：升冪 → 降冪 → 原始順序\(detail)；沒有值的（—、未登入）排在有值的後面，codex、aigw 等非 Claude 帳號固定在最後"
        return note.map { $0 + "\n\n" + hint } ?? hint
    }

    /// `accounts` in the chosen order (QuotaSortRules.order). Unsorted, the
    /// non-Claude accounts still sit below the Claude ones — claude-quota
    /// already lists them last, so that order is unchanged.
    private func sorted(now: Date) -> [AppModel.QuotaAccount] {
        let sort = self.sort
        let rows = accounts.map { account in
            QuotaSortRow(key: sort.flatMap { Self.sortKey(account, $0.column, now: now) },
                         pinned: QuotaSortRules.isPinned(alias: account.alias))
        }
        return QuotaSortRules.order(rows, by: sort).map { accounts[$0] }
    }

    /// The value `column` sorts by: what its cell shows, read with the cell's
    /// own helpers so the order cannot drift from the display. nil where the
    /// cell shows "—" or 未登入.
    private static func sortKey(_ account: AppModel.QuotaAccount, _ column: QuotaSortColumn,
                                now: Date) -> QuotaSortKey? {
        switch column {
        case .account:
            return .text(shortAlias(account.alias))
        case .reset:
            return resetCountdown(account, now: now).map { .time($0.resetsAt) }
        case .fiveHour, .weekly, .fable, .credits:
            return columns.first { $0.sort == column }
                .flatMap { bucket(account, $0.match) }
                .map { .number(Double($0.percent)) }
        }
    }

    private static func bucket(_ account: AppModel.QuotaAccount,
                               _ match: (String) -> Bool) -> AppModel.QuotaBucket? {
        account.buckets.first { match($0.key) }?.value
    }

    /// `note` rides after the percentage: the 5h cell's "3h36m" until the
    /// window resets, so no separate column is spent on it. `narrow` caps
    /// the column (點數: mostly "—", rarely what you look at) so the three
    /// windows that matter get the width.
    private func cell(_ bucket: AppModel.QuotaBucket, note: String? = nil,
                      narrow: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("\(bucket.percent)%")
                    .font(Theme.Fonts.mono(10.5 * scale, .medium))
                    .foregroundStyle(tint(bucket.percent))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let note {
                    Text(note)
                        .font(Theme.Fonts.mono(8.5 * scale))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
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
        // Flexible: the window columns share whatever width the notes
        // column has, so the grid fills a wide column and squeezes to ~245 pt.
        .frame(minWidth: 30, maxWidth: narrow ? 44 * scale : .infinity, alignment: .leading)
    }

    private func tint(_ percent: Int) -> Color {
        percent >= 100 ? Theme.crit : (percent >= 70 ? Theme.warn : Theme.accent)
    }

    /// "5d19h" / "3h36m" / "12m" until `until`; nil once it has passed (the
    /// next poll brings the new window). Two units at most, no seconds: the
    /// grid ticks by the minute.
    static func remaining(until: Date, now: Date) -> String? {
        let seconds = until.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        // Two digits on the small unit: "2h00m", not "2h0m" (reads as a typo).
        if minutes >= 24 * 60 {
            return String(format: "%dd%02dh", minutes / (24 * 60), minutes % (24 * 60) / 60)
        }
        return minutes >= 60 ? String(format: "%dh%02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }

    /// The long window: the earliest-resetting one that is not the 5h
    /// session, with the unit it counts in. 週 and Fable share a reset, so
    /// the fuller of the two speaks for it (its colour is what turns the
    /// cell red when Fable is spent). Not every account's long window is a
    /// week: codex's 點數 is a monthly spend limit, opencode's is a weekly
    /// budget — the unit says which, instead of a header that lies for one.
    static func longWindow(_ buckets: [String: AppModel.QuotaBucket])
        -> (bucket: AppModel.QuotaBucket, unit: String)? {
        buckets
            .filter { !$0.key.lowercased().contains("5h") && $0.value.resetsAt != nil }
            .min { a, b in
                a.value.resetsAt! != b.value.resetsAt!
                    ? a.value.resetsAt! < b.value.resetsAt! : a.value.percent > b.value.percent
            }
            .map { ($0.value, $0.key.lowercased().contains("credit") ? "月" : "週") }
    }

    /// What the 重置 cell counts down: the long window's unit, its reset and
    /// the time left. nil where the cell shows 未登入, or "—" (no long window,
    /// or its reset has passed and the next poll brings the new one). The
    /// 重置 sort key reads the same value.
    static func resetCountdown(_ account: AppModel.QuotaAccount, now: Date)
        -> (unit: String, resetsAt: Date, text: String)? {
        guard account.error == nil, let window = longWindow(account.buckets),
              let resetsAt = window.bucket.resetsAt,
              let text = remaining(until: resetsAt, now: now) else { return nil }
        return (window.unit, resetsAt, text)
    }

    /// "週 5d19h" / "月 4d10h": time left, not a weekday — it answers the
    /// question directly — and the unit names the window. Under it, how far
    /// through the window we are (a week, or the calendar month for 點數).
    /// Both in neutral grey: neither is a usage signal. The exact day and
    /// time stay in the row tooltip.
    private func resetCell(_ account: AppModel.QuotaAccount, now: Date) -> some View {
        let window = Self.longWindow(account.buckets)
        let countdown = Self.resetCountdown(account, now: now)
        let elapsed = window.flatMap { w in
            w.bucket.resetsAt.flatMap { Self.windowElapsed(unit: w.unit, resetsAt: $0, now: now) }
        }
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 3) {
                if account.error != nil {
                    Text("未登入")
                } else if let countdown {
                    // No usage tint here: the time left says nothing about
                    // trouble on its own (lots of time + high usage is the
                    // worrying case), so the colour only misled.
                    Text(countdown.unit).foregroundStyle(Theme.text4)
                    Text(countdown.text).foregroundStyle(Theme.text2).monospacedDigit()
                } else {
                    Text("—")
                }
            }
            .font(Theme.Fonts.mono(9.5 * scale))
            .foregroundStyle(Theme.text4)
            .lineLimit(1)
            .fixedSize()
            if !compact, let elapsed {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Color.white.opacity(0.32))
                            .frame(width: max(0, geo.size.width * elapsed))
                    }
                }
                .frame(height: 3)
                .help(String(format: "這個%@窗口已過 %.0f%%", window?.unit ?? "", elapsed * 100))
            }
        }
        .frame(minWidth: 30, maxWidth: 72 * scale, alignment: .trailing)
        .gridColumnAlignment(.trailing)
    }

    /// Fraction of the window already behind us: a week back from the reset
    /// for 週, a calendar month back for 月 (codex's spend limit resets on
    /// the 1st, so the month's own length is the window).
    static func windowElapsed(unit: String, resetsAt: Date, now: Date) -> Double? {
        let calendar = Calendar.current
        let start = unit == "月"
            ? calendar.date(byAdding: .month, value: -1, to: resetsAt)
            : calendar.date(byAdding: .day, value: -7, to: resetsAt)
        guard let start, resetsAt > start else { return nil }
        return min(1, max(0, now.timeIntervalSince(start) / resetsAt.timeIntervalSince(start)))
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

/// A QuotaGrid column header, laid over the Grid on top of its hidden title
/// (`QuotaGrid.headers`), so nothing here takes part in the Grid's sizing.
/// A click sorts by the column (the cycle is QuotaSort.afterClick); the
/// whole cell is the hit area; it brightens on hover so it reads as
/// clickable, and the sorted column stays brighter with ▴ / ▾ for its
/// direction. Its own hover state: a hover redraws this header, not the grid.
struct QuotaHeaderCell: View {
    let title: String
    /// nil: not the sorted column.
    let direction: QuotaSortDirection?
    let help: String
    /// Where the Grid put the hidden title, and the whole header cell around
    /// it, in the overlay's space.
    let titleFrame: CGRect
    let cellFrame: CGRect
    /// The right-aligned 重置 column: its arrow goes before the title.
    var trailing = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Color.clear
                .frame(width: cellFrame.width, height: cellFrame.height)
                .contentShape(Rectangle())
                .overlay(alignment: .topLeading) {
                    label
                        .frame(width: titleFrame.width, height: titleFrame.height,
                               alignment: trailing ? .topTrailing : .topLeading)
                        .offset(x: titleFrame.minX - cellFrame.minX, y: titleFrame.minY - cellFrame.minY)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(direction != nil
                         ? (hovering ? Theme.text : Theme.text2)
                         : (hovering ? Theme.text2 : Theme.text4))
        .onHover { hovering = $0 }
        .help(help)
        .position(x: cellFrame.midX, y: cellFrame.midY)
    }

    /// The title exactly where the Grid put it, and beside it the arrow,
    /// which takes no width, so the sorted column's header never widens its
    /// column. The arrow hangs off a zero-size anchor at the title's edge (an
    /// overlay aligns by frame edges, not by an alignment guide set on its
    /// content); the glyph's own side bearing is the gap, which centres it
    /// in the column spacing where a title fills its column (Fable, scrolled
    /// layout). Both triangles are in JetBrains Mono, the header's face.
    private var label: some View {
        Text(title)
            .lineLimit(1)
            .fixedSize()
            .overlay(alignment: trailing ? .leading : .trailing) {
                if let direction {
                    Color.clear.frame(width: 0, height: 0)
                        .overlay(alignment: trailing ? .trailing : .leading) {
                            Text(direction == .ascending ? "▴" : "▾").fixedSize()
                        }
                }
            }
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
