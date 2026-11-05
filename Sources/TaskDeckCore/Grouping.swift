import Foundation

// Pure sidebar-grouping rules (260720 v3), extracted from AppModel so they can
// be locked down by selftests — this classifier had 3 regressions while it
// lived inline in a view-driven path. The IMPURE parts (resolving each
// session's live signal from hook status files / transcript events, and the acked
// set) stay in AppModel, which builds the `[SessionSignal]` snapshot and calls
// `classify`. Everything here is a deterministic function of its inputs.

public enum TaskGroup: Hashable, Sendable {
    case needsYou, aiRunning, longRunning, idle, read, waitingExt, semiArchived, done
}

/// What a task's AI is doing right now, as a 長期運行 row shows it: that lane
/// never moves a task, so a blocked or finished agent surfaces here instead.
public enum LiveState: Hashable, Sendable {
    case quiet, running, newOutput, permission
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
    /// Frontmatter `group` of the 長期運行 lane: tasks whose agents run for
    /// hours (sub-agents, loops), parked there by hand (James, 2026-11-05) so
    /// every turn they end stops landing in 等你.
    public static let longRunGroup = "longrun"

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

    /// Most actionable first: a session blocked on permission, then one
    /// running now, then output nobody has looked at (an unacked stop).
    public static func liveState(_ signals: [SessionSignal], now: Date) -> LiveState {
        let owed = attention(signals)
        if owed?.permission == true { return .permission }
        if runningNow(signals, now: now) { return .running }
        return owed == nil ? .quiet : .newOutput
    }

    /// The v3 classifier. `quiet` = seconds since the task last showed life
    /// (max signal ts / group_since), used only for the sink threshold.
    ///
    ///   • group "longrun" (長期運行) → stays put: only the user moves it in
    ///     or out; it never sinks, so it never auto-archives either
    ///   • running now → AI 執行中 (live fact, overrides all the rest)
    ///   • a FRESH unacked stop → 等你 (new AI output overrides manual waiting/read)
    ///   • group "waiting" (等待外部) → sticky while there is no new AI output
    ///   • manual 等你 that outlived its signal → 等你
    ///   • group "read" / an acked stop → 已讀 (sinks to 半封存 when quiet)
    ///   • else → 待開工
    public static func classify(status: String, group: String?, quiet: TimeInterval,
                                signals: [SessionSignal], now: Date) -> TaskGroup {
        if status == "done" { return .done }
        if group == longRunGroup { return .longRunning }
        if runningNow(signals, now: now) { return .aiRunning }
        if attention(signals) != nil { return .needsYou }
        if group == "waiting" { return quiet > sinkAfter ? .semiArchived : .waitingExt }
        if group == "needsyou" { return .needsYou }
        if group == "read" || hasAckedStop(signals) {
            return quiet > sinkAfter ? .semiArchived : .read
        }
        return .idle
    }
}

/// Keeps the persisted "seen" markers bounded without coupling them to hook
/// status files. Legacy sessions can be resolved from transcript events
/// alone, so deleting their acknowledgement merely because no hook row exists
/// makes the same fallback signal repeatedly surface as unread.
public enum AIStatusAcknowledgementRules {
    public static func prune(_ acknowledgements: [String: Date], now: Date,
                             signalWindow: TimeInterval) -> [String: Date] {
        acknowledgements.filter {
            now.timeIntervalSince($0.value) < signalWindow
        }
    }

    /// An acknowledged idle session that merely ENDS (terminal closed, daemon
    /// restarted) produced nothing new, so it stays acknowledged at its new
    /// stamp. Without this, one daemon restart re-stamps every session in the
    /// same second and every 已讀 task bounces back to 等你 at once.
    ///
    /// Only `ended` qualifies. A real new turn passes through "running" then
    /// "waiting", but two snapshots can miss the "running" of a fast turn — so
    /// carrying an ack across a waiting→waiting re-stamp could hide genuine
    /// output. (The installed hook keeps the old ts for both cases at the
    /// source; this is the in-app backstop for the snapshot boundary.)
    public static func carryingForward(_ acknowledgements: [String: Date],
                                       previous: [String: (state: String, ts: Date)],
                                       next: [String: (state: String, ts: Date)]) -> [String: Date] {
        var out = acknowledgements
        for (sid, new) in next where new.state == "ended" {
            guard let old = previous[sid],
                  GroupingRules.attentionStates.contains(old.state),
                  let acked = acknowledgements[sid],
                  acked >= old.ts, new.ts > acked else { continue }
            out[sid] = new.ts
        }
        return out
    }
}

/// Rising-edge rule for the high-visibility mainline-task alert. Keeping this
/// separate from grouping prevents periodic status reloads or merely tagging
/// an already-waiting task from replaying the alert.
public enum PriorityAlertRules {
    public static func shouldTrigger(isMainline: Bool, previous: TaskGroup,
                                     current: TaskGroup,
                                     isCurrentlyViewed: Bool) -> Bool {
        isMainline
            && previous == .aiRunning
            && current == .needsYou
            && !isCurrentlyViewed
    }
}
