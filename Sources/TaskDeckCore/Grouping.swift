import Foundation

// Pure sidebar-grouping rules (260720 v3), extracted from AppModel so they can
// be locked down by selftests — this classifier had 3 regressions while it
// lived inline in a view-driven path. The IMPURE parts (resolving each
// session's live signal from hook status files / file mtimes, and the acked
// set) stay in AppModel, which builds the `[SessionSignal]` snapshot and calls
// `classify`. Everything here is a deterministic function of its inputs.

public enum TaskGroup: Hashable, Sendable {
    case needsYou, aiRunning, idle, read, waitingExt, semiArchived, done
}

/// One AI session's resolved signal at classification time. `ts` is when the
/// signal was stamped; `acked` = the user has already seen it (ackedAI >= ts).
/// Only signals still inside AppModel's signal window are passed in.
public struct SessionSignal: Sendable {
    public let state: String   // "running" / "waiting" / "permission" / "ended"
    public let ts: Date
    public let acked: Bool
    public init(state: String, ts: Date, acked: Bool) {
        self.state = state
        self.ts = ts
        self.acked = acked
    }
}

public enum GroupingRules {
    /// 已讀 / 等待外部 with this much silence sink into 半封存.
    public static let sinkAfter: TimeInterval = 72 * 3600
    /// A "running" signal older than this no longer counts as actively running.
    public static let runningFresh: TimeInterval = 1800
    /// States meaning the ball is in the user's court (an unreviewed ended
    /// session still owes a review — Stop's "waiting" is overwritten by
    /// SessionEnd's "ended" in the one-state-per-session file).
    public static let attentionStates: Set<String> = ["waiting", "permission", "ended"]

    public static func runningNow(_ signals: [SessionSignal], now: Date) -> Bool {
        signals.contains { $0.state == "running" && now.timeIntervalSince($0.ts) < runningFresh }
    }

    /// Strongest UNacked attention signal: permission beats waiting; `since` =
    /// oldest such signal (FIFO by how long you've been owed). nil = none.
    public static func attention(_ signals: [SessionSignal]) -> (permission: Bool, since: Date)? {
        var permission = false
        var oldest: Date?
        for s in signals where attentionStates.contains(s.state) && !s.acked {
            if s.state == "permission" { permission = true }
            if oldest == nil || s.ts < oldest! { oldest = s.ts }
        }
        guard let oldest else { return nil }
        return (permission, oldest)
    }

    /// An attention signal the user already acknowledged (= 已讀: seen, no reply yet).
    public static func hasAckedStop(_ signals: [SessionSignal]) -> Bool {
        signals.contains { attentionStates.contains($0.state) && $0.acked }
    }

    /// The v3 classifier. `quiet` = seconds since the task last showed life
    /// (max signal ts / group_since), used only for the sink threshold.
    ///
    ///   • running now → AI 執行中 (live fact, overrides all)
    ///   • group "waiting" (等待外部) → sticky; only a running session overrides
    ///   • a FRESH unacked stop → 等你 (resurfaces even a 已讀 task: a new turn is unseen)
    ///   • manual 等你 that outlived its signal → 等你
    ///   • group "read" / an acked stop → 已讀 (sinks to 半封存 when quiet)
    ///   • else → 待開工
    public static func classify(status: String, group: String?, quiet: TimeInterval,
                                signals: [SessionSignal], now: Date) -> TaskGroup {
        if status == "done" { return .done }
        if runningNow(signals, now: now) { return .aiRunning }
        if group == "waiting" { return quiet > sinkAfter ? .semiArchived : .waitingExt }
        if attention(signals) != nil { return .needsYou }
        if group == "needsyou" { return .needsYou }
        if group == "read" || hasAckedStop(signals) {
            return quiet > sinkAfter ? .semiArchived : .read
        }
        return .idle
    }
}
