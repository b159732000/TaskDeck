import Foundation

/// Manual sort for the AI 額度 grid (James, 2026-11-26: 「ai quota 面板能否加個
/// 手動切排序方式包含所有欄位升降冪，另外，codex & aigw 不加入排序就永遠排最後」).
///
/// A click on a column header cycles that column: ascending → descending →
/// off (claude-quota's own order); a click on another column starts it at
/// ascending. Every column takes part: 帳號 / 5h / 週 / Fable / 點數 / 重置.
/// The keys are what the cells show — the GUI's QuotaGrid reads them with the
/// helpers its cells use — and a cell that shows "—" or 未登入 has none: it
/// sorts after every row that has a value, in both directions. Equal keys
/// keep claude-quota's order. Accounts that are not Claude (codex, aigw,
/// opencode …) never take part: they stay below every Claude row, in
/// claude-quota's order, whatever the sort.
public enum QuotaSortColumn: String, CaseIterable, Sendable {
    case account
    case fiveHour = "5h"
    case weekly
    case fable
    case credits
    case reset
}

public enum QuotaSortDirection: String, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

public struct QuotaSort: Equatable, Sendable {
    public var column: QuotaSortColumn
    public var direction: QuotaSortDirection

    public init(_ column: QuotaSortColumn, _ direction: QuotaSortDirection) {
        self.column = column
        self.direction = direction
    }

    /// The stored form, "<column>:<direction>" ("weekly:desc") — the GUI keeps
    /// one string under the `quotaSort` default. "" and anything it does not
    /// recognise mean claude-quota's own order.
    public init?(stored: String) {
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let column = QuotaSortColumn(rawValue: String(parts[0])),
              let direction = QuotaSortDirection(rawValue: String(parts[1])) else { return nil }
        self.init(column, direction)
    }

    public var stored: String { "\(column.rawValue):\(direction.rawValue)" }

    /// One header click: the sorted column goes ascending → descending → nil
    /// (claude-quota's order); any other column starts at ascending.
    public static func afterClick(on column: QuotaSortColumn, from current: QuotaSort?) -> QuotaSort? {
        guard let current, current.column == column else { return QuotaSort(column, .ascending) }
        return current.direction == .ascending ? QuotaSort(column, .descending) : nil
    }
}

/// A row's value in the sorted column.
public enum QuotaSortKey: Equatable, Sendable {
    /// Natural order (`localizedStandardCompare`): ext2 before ext10.
    case text(String)
    case number(Double)
    /// A reset time, compared to the minute. The usage API answers
    /// 09:00:00.138 one poll and 08:59:59.8 the next, so two windows that
    /// reset at the same minute must tie (and keep claude-quota's order)
    /// rather than swap places on every poll.
    case time(Date)
}

public struct QuotaSortRow: Equatable, Sendable {
    /// nil: the cell shows "—" or 未登入.
    public var key: QuotaSortKey?
    /// Not a Claude account: never sorted, kept below every Claude row.
    public var pinned: Bool

    public init(key: QuotaSortKey?, pinned: Bool) {
        self.key = key
        self.pinned = pinned
    }
}

public enum QuotaSortRules {
    /// codex, aigw, opencode — any account whose alias does not start with
    /// "claude" — stays out of the sort.
    public static func isPinned(alias: String) -> Bool {
        !alias.lowercased().hasPrefix("claude")
    }

    /// Indices into `rows` in display order: the Claude rows with a key,
    /// sorted (ties in their original order, both directions); then the
    /// Claude rows without one; then the pinned rows. With no sort, Claude
    /// rows and pinned rows each keep their original order.
    public static func order(_ rows: [QuotaSortRow], by sort: QuotaSort?) -> [Int] {
        let pinned = rows.indices.filter { rows[$0].pinned }
        let free = rows.indices.filter { !rows[$0].pinned }
        guard let sort else { return free + pinned }
        let keyed = free.compactMap { index in rows[index].key.map { (index, $0) } }
            .sorted { a, b in
                switch compare(a.1, b.1) {
                case .orderedAscending: return sort.direction == .ascending
                case .orderedDescending: return sort.direction == .descending
                case .orderedSame: return a.0 < b.0
                }
            }
            .map(\.0)
        let missing = free.filter { rows[$0].key == nil }
        return keyed + missing + pinned
    }

    static func compare(_ a: QuotaSortKey, _ b: QuotaSortKey) -> ComparisonResult {
        switch (a, b) {
        case let (.text(x), .text(y)):
            return x.localizedStandardCompare(y)
        case let (.number(x), .number(y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case let (.time(x), .time(y)):
            return compare(.number(minute(x)), .number(minute(y)))
        default:
            // One column never mixes kinds; this only keeps the order total.
            return rank(a) < rank(b) ? .orderedAscending
                : (rank(a) > rank(b) ? .orderedDescending : .orderedSame)
        }
    }

    private static func minute(_ date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate / 60).rounded()
    }

    private static func rank(_ key: QuotaSortKey) -> Int {
        switch key {
        case .number: return 0
        case .time: return 1
        case .text: return 2
        }
    }
}
