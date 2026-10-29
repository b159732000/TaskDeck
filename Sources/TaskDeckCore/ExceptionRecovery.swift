import Foundation

/// Whether the GUI restarts itself after AppKit swallowed an Objective-C
/// exception (the GUI's ExceptionRecovery has the why). Restarting is safe —
/// every terminal lives in taskdeckd — but an exception that comes back on
/// every launch must end in a stopped app, not a relaunch loop.
public enum ExceptionRecoveryRules {
    /// A GUI younger than this does not relaunch: whatever threw while it
    /// was starting up would throw again in the new copy.
    public static let minimumUptime: TimeInterval = 60
    /// At most one automatic relaunch within this window.
    public static let minimumInterval: TimeInterval = 10 * 60

    public static func shouldRelaunch(launchedAt: Date, lastRelaunch: Date?, now: Date) -> Bool {
        guard now.timeIntervalSince(launchedAt) >= minimumUptime else { return false }
        guard let lastRelaunch else { return true }
        return now.timeIntervalSince(lastRelaunch) >= minimumInterval
    }
}
