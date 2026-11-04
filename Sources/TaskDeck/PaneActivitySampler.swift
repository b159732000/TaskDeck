import Foundation
import TaskDeckCore

/// Reads the process table off the main actor and turns it into one
/// `PaneActivity` per pane.
///
/// A pid's argument vector never changes, so it is cached between samples —
/// that is the only part of a sample that costs more than microseconds. The key
/// carries the start time because the kernel recycles pids.
actor PaneActivitySampler {
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startedAt: Int64
    }

    /// What one arguments read yields that a sample needs. The environment
    /// comes from the same kernel read as argv, and only the one variable is
    /// kept: whole environments of every foreground process add up.
    private struct Arguments {
        let argv: [String]
        let claudeConfigDir: String?
    }

    private var argumentsCache: [ProcessKey: Arguments] = [:]

    func sample(shells: [Int32], aiCommands: Set<String>,
                now: Date = Date()) -> [Int32: PaneActivity] {
        let table = ProcessTable.snapshot()
        guard !table.isEmpty else { return [:] }

        var keys: [Int32: ProcessKey] = [:]
        keys.reserveCapacity(table.count)
        for process in table {
            keys[process.pid] = ProcessKey(
                pid: process.pid,
                startedAt: Int64(process.started.timeIntervalSince1970)
            )
        }

        var stillAlive: [ProcessKey: Arguments] = [:]
        func arguments(_ pid: Int32) -> Arguments? {
            guard let key = keys[pid] else { return nil }
            if let cached = argumentsCache[key] ?? stillAlive[key] {
                stillAlive[key] = cached
                return cached
            }
            let read = ProcessTable.arguments(pid)
            let entry = Arguments(argv: read.argv,
                                  claudeConfigDir: read.environmentValue("CLAUDE_CONFIG_DIR"))
            stillAlive[key] = entry
            return entry
        }

        var activities = PaneActivityRules.classify(
            shells: shells,
            processes: table,
            aiCommands: aiCommands,
            now: now,
            argv: { arguments($0)?.argv ?? [] },
            residentBytes: { ProcessTable.residentBytes($0) }
        )
        for (shell, activity) in activities
        where activity.kind == .ai && activity.label.split(separator: " ").first == "claude" {
            // An unreadable process (gone / not ours) says nothing about its
            // account; a readable one without the variable is the default.
            guard let read = arguments(activity.leaderPID), !read.argv.isEmpty else { continue }
            activities[shell]?.claudeConfigDir = read.claudeConfigDir ?? AccountRules.defaultConfigDir
        }
        argumentsCache = stillAlive // processes that exited drop out of the cache
        return activities
    }
}
