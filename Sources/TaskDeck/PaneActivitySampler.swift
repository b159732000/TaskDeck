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

    private var argvCache: [ProcessKey: [String]] = [:]

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

        var stillAlive: [ProcessKey: [String]] = [:]
        let activities = PaneActivityRules.classify(
            shells: shells,
            processes: table,
            aiCommands: aiCommands,
            now: now,
            argv: { pid in
                guard let key = keys[pid] else { return [] }
                if let cached = argvCache[key] {
                    stillAlive[key] = cached
                    return cached
                }
                let argv = ProcessTable.commandLine(pid)
                stillAlive[key] = argv
                return argv
            },
            residentBytes: { ProcessTable.residentBytes($0) }
        )
        argvCache = stillAlive // processes that exited drop out of the cache
        return activities
    }
}
