import Foundation

/// When the GUI tries taskdeckd again after losing its connection (AppModel's
/// scheduleDaemonReconnect has the why). The first try is quick — the usual
/// cause is the daemon dropping a GUI that stalled for a few seconds — but a
/// connection that keeps dropping must back off, not hammer the daemon with
/// full terminal replays.
public enum DaemonReconnectRules {
    /// Wait before automatic attempt n (0-based); the last value repeats.
    public static let delays: [TimeInterval] = [0.3, 1, 2, 4, 8, 15]
    /// A connection that stayed up this long was healthy: losing it starts
    /// over at the first delay instead of continuing the backoff.
    public static let healthyUptime: TimeInterval = 60

    public static func delay(attempt: Int) -> TimeInterval {
        delays[min(max(attempt, 0), delays.count - 1)]
    }

    /// The attempt to resume from when a connection is lost that had been
    /// ready for `uptime` seconds (nil: it never got ready).
    public static func attemptAfterDrop(previous: Int, uptime: TimeInterval?) -> Int {
        guard let uptime, uptime >= healthyUptime else { return previous }
        return 0
    }
}
