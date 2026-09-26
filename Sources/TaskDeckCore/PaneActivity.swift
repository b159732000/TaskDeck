import Foundation

/// What a pane's terminal is doing right now.
///
/// Deliberately NOT a statement about whether an AI is mid-turn: that is the
/// hook status files' job (`GroupingRules`), which can tell "thinking" from
/// "sitting at a prompt waiting for you". A process can only see that the CLI
/// is open. Keeping the two apart is what stops this from becoming a second,
/// worse answer to a question the sidebar already answers.
public enum PaneActivityKind: String, Equatable, Sendable {
    /// Nothing running: the shell itself owns the terminal.
    case idle
    /// An AI CLI is open in this pane.
    case ai
    /// A long-running command — dev server, database, watcher.
    case service
    /// A command that started moments ago; too early to call it a service.
    case command
}

public struct PaneActivity: Equatable, Sendable {
    public let kind: PaneActivityKind
    /// Human-readable command, e.g. "yarn dev" (empty when idle).
    public let label: String
    public let leaderPID: Int32
    public let runningFor: TimeInterval
    /// Resident memory of the pane's whole process tree, shell included.
    public let residentBytes: UInt64

    public init(kind: PaneActivityKind, label: String, leaderPID: Int32,
                runningFor: TimeInterval, residentBytes: UInt64) {
        self.kind = kind
        self.label = label
        self.leaderPID = leaderPID
        self.runningFor = runningFor
        self.residentBytes = residentBytes
    }
}

public enum PaneActivityRules {
    /// A foreground job older than this is treated as something that is meant
    /// to keep running, rather than a command you just typed.
    public static let serviceAfter: TimeInterval = 30

    /// Interpreters name themselves, not the tool: `yarn dev` shows up as
    /// `node …/bin/yarn dev`. The tool is the first non-flag argument.
    private static let runtimes: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl", "php",
        "java", "npx", "pnpx", "tsx", "ts-node",
    ]

    /// Collapse an argument vector into something readable in a 200 pt sidebar:
    /// the tool and, when it is short enough to be a subcommand, one more word.
    /// Paths, flags and session uuids are dropped — they are never the answer
    /// to "what is this pane running".
    public static func label(argv: [String], fallbackName: String = "") -> String {
        let tokens = argv.filter { !$0.isEmpty }
        guard let first = tokens.first else { return fallbackName }

        var head = basename(first)
        var rest = Array(tokens.dropFirst())
        if runtimes.contains(head),
           let toolIndex = rest.firstIndex(where: { !$0.hasPrefix("-") }) {
            head = basename(rest[toolIndex])
            rest = Array(rest[rest.index(after: toolIndex)...])
        }
        guard !head.isEmpty else { return fallbackName }
        guard let word = rest.first(where: { !$0.hasPrefix("-") }),
              word.count <= 12, !word.contains("/"), !isIdentifier(word),
              !word.allSatisfy(\.isNumber) else {
            return head
        }
        return "\(head) \(word)"
    }

    /// Classify every pane in one pass over a process-table snapshot.
    /// `argv` and `residentBytes` are injected so the rules stay testable
    /// against a synthetic table.
    public static func classify(shells: [Int32],
                                processes: [ProcessRecord],
                                aiCommands: Set<String>,
                                now: Date,
                                argv: (Int32) -> [String],
                                residentBytes: (Int32) -> UInt64) -> [Int32: PaneActivity] {
        var byPID: [Int32: ProcessRecord] = [:]
        var children: [Int32: [Int32]] = [:]
        var byGroup: [Int32: [ProcessRecord]] = [:]
        byPID.reserveCapacity(processes.count)
        for process in processes {
            byPID[process.pid] = process
            children[process.parent, default: []].append(process.pid)
            byGroup[process.group, default: []].append(process)
        }

        var out: [Int32: PaneActivity] = [:]
        for shell in shells {
            guard let record = byPID[shell] else { continue } // pane already gone
            var memory: UInt64 = 0
            var stack = [shell]
            while let pid = stack.popLast() {
                memory += residentBytes(pid)
                stack.append(contentsOf: children[pid] ?? [])
            }

            let foreground = record.terminalForegroundGroup
            let members = byGroup[foreground] ?? []
            // The group leader is the process whose pid IS the group id; fall
            // back to the oldest member when the leader has already exited.
            let leader = members.first { $0.pid == foreground }
                ?? members.min { $0.pid < $1.pid }
            guard foreground > 0, foreground != record.group, let leader,
                  leader.pid != shell else {
                out[shell] = PaneActivity(kind: .idle, label: "", leaderPID: 0,
                                          runningFor: 0, residentBytes: memory)
                continue
            }

            let text = label(argv: argv(leader.pid), fallbackName: leader.name)
            let age = max(0, now.timeIntervalSince(leader.started))
            let kind: PaneActivityKind
            if aiCommands.contains(text.split(separator: " ").first.map(String.init) ?? text) {
                kind = .ai
            } else {
                kind = age >= serviceAfter ? .service : .command
            }
            out[shell] = PaneActivity(kind: kind, label: text, leaderPID: leader.pid,
                                      runningFor: age, residentBytes: memory)
        }
        return out
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// uuids / hashes / long ids: never worth showing as the second word.
    private static func isIdentifier(_ word: String) -> Bool {
        word.count >= 8 && word.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}
