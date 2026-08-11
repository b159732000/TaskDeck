import Foundation

/// Pure task-search semantics shared by the sidebar and selftests.
public enum TaskSearchRules {
    /// Exact title search means one contiguous, non-fuzzy substring. Regex
    /// metacharacters remain ordinary text; only letter case is ignored.
    public static func matchesTitle(_ title: String, query rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.range(of: query, options: [.caseInsensitive]) != nil
    }
}
