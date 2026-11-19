import Foundation

/// Work a session left running when its main turn ended, as Claude itself
/// reports it: the Stop hook payload carries `background_tasks` (sub-agents,
/// workflows, background commands, monitors still running or pending) and
/// `session_crons` (CronCreate tasks and /loop wake-ups). The status hook
/// records the ones that bring the conversation back as `pending`.
///
/// It is the difference between "the AI stopped and it is your turn" and
/// "the AI stopped talking but will come back by itself" (James, 2026-11-19:
/// a task whose sub-agents were still writing landed in 等你, and the only
/// way out was 已讀, which says the opposite of what is going on).
public struct PendingWork: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case agent    // sub-agent, workflow, teammate, cloud session
        case shell    // background command
        case monitor  // monitor, MCP task
        case other
    }

    public struct Task: Equatable, Sendable {
        public let kind: Kind
        public let label: String
        public init(kind: Kind, label: String) {
            self.kind = kind
            self.label = label
        }
    }

    public struct Cron: Equatable, Sendable {
        public let schedule: String
        public let recurring: Bool
        public init(schedule: String, recurring: Bool) {
            self.schedule = schedule
            self.recurring = recurring
        }
    }

    public let tasks: [Task]
    public let crons: [Cron]

    public init(tasks: [Task], crons: [Cron]) {
        self.tasks = tasks
        self.crons = crons
    }

    public var isEmpty: Bool { tasks.isEmpty && crons.isEmpty }

    /// Claude reports a task's type by its display name ("subagent",
    /// "shell", …); the internal names are accepted too in case a version
    /// sends those instead.
    public static func kind(forType type: String) -> Kind {
        switch type {
        case "subagent", "local_agent", "workflow", "local_workflow",
             "teammate", "in_process_teammate", "cloud session", "remote_agent":
            return .agent
        case "shell", "local_bash", "code", "local_script":
            return .shell
        case "monitor", "monitor_mcp", "monitor_ws", "MCP task", "mcp_task":
            return .monitor
        default:
            return .other
        }
    }
}

/// When a stop with pending work stops being the AI's and becomes yours.
/// Pure and selftested; AppModel feeds it each session's hook record.
public enum BackgroundHoldRules {
    /// Effective state of a session whose turn ended with work pending. It
    /// counts like "running" for grouping (AI 執行中), never as attention.
    public static let state = "background"

    /// A sub-agent, workflow or background command with no sign of life for
    /// this long is presumed stuck, and the task returns to 等你. Sub-agents
    /// beat by calling tools (the hook records `sub_seen`); a background
    /// command has no beat, so this is also its plain time limit.
    public static let taskSilence: TimeInterval = 30 * 60
    /// How late a scheduled wake-up may be before it is presumed lost (the
    /// session died, or the wake-up was cancelled without a new turn).
    public static let cronGrace: TimeInterval = 10 * 60
    /// How far ahead a wake-up is searched for. Claude's recurring crons
    /// expire within days; a one-shot names a calendar minute, and one that
    /// is already past (overdue) would otherwise match next year.
    public static let cronHorizon: TimeInterval = 8 * 24 * 3600

    /// The earliest scheduled wake-up after the stop; nil = no crons, or
    /// none due within the horizon.
    public static func nextWake(after stoppedAt: Date, pending: PendingWork?,
                                calendar: Calendar = .current) -> Date? {
        (pending?.crons ?? []).compactMap {
            CronSchedule(parsing: $0.schedule)?
                .nextFire(after: stoppedAt, within: cronHorizon, calendar: calendar)
        }.min()
    }

    /// Until when a session that ended its turn at `stoppedAt` is still the
    /// AI's to finish. nil = nothing pending: the stop is yours as before.
    ///
    ///   • tasks pending, or a sub-agent beat after the stop → the latest
    ///     sign of life + `taskSilence`
    ///   • crons pending → the earliest wake-up + `cronGrace` (a cron that is
    ///     unparsable or overdue counts as due at the stop itself)
    ///   • both → whichever lasts longer: either one brings the AI back
    public static func holdUntil(stoppedAt: Date, pending: PendingWork?, heartbeat: Date?,
                                 calendar: Calendar = .current) -> Date? {
        var until: Date?
        let beat = heartbeat.flatMap { $0 > stoppedAt ? $0 : nil }
        if !(pending?.tasks.isEmpty ?? true) || beat != nil {
            until = max(stoppedAt, beat ?? stoppedAt).addingTimeInterval(taskSilence)
        }
        if let crons = pending?.crons, !crons.isEmpty {
            let wake = nextWake(after: stoppedAt, pending: pending, calendar: calendar) ?? stoppedAt
            let cronUntil = wake.addingTimeInterval(cronGrace)
            until = max(until ?? cronUntil, cronUntil)
        }
        return until
    }

    /// A session's signal as grouping sees it. A "waiting" stop with work
    /// still pending is "background" (keeping its stamp, so an unseen one
    /// still reads as new output) until the hold lapses; a lapsed hold is a
    /// fresh "waiting" debt stamped at the lapse, so having seen the earlier
    /// stop does not hide a task whose background work went silent.
    public static func effective(state: String, ts: Date, pending: PendingWork?,
                                 heartbeat: Date?, now: Date,
                                 calendar: Calendar = .current) -> (state: String, ts: Date) {
        guard state == "waiting",
              let until = holdUntil(stoppedAt: ts, pending: pending, heartbeat: heartbeat,
                                    calendar: calendar) else { return (state, ts) }
        return now < until ? (Self.state, ts) : ("waiting", until)
    }
}

/// What a task's held sessions are waiting on — the sidebar row's chips.
public struct BackgroundSummary: Equatable, Sendable {
    public private(set) var agents = 0
    public private(set) var shells = 0
    public private(set) var monitors = 0
    public private(set) var others = 0
    /// A sub-agent beat after a stop that listed no tasks (a hook older than
    /// the list, or a list that missed it): work is running, count unknown.
    public private(set) var unlisted = false
    /// Earliest scheduled wake-up, and whether any wake-up repeats.
    public private(set) var nextWake: Date?
    public private(set) var recurring = false
    /// What Claude said each task is doing (for the tooltip).
    public private(set) var labels: [String] = []

    public init() {}

    public var taskCount: Int { agents + shells + monitors + others }

    public mutating func add(pending: PendingWork?, heartbeat: Date?, stoppedAt: Date,
                             calendar: Calendar = .current) {
        for task in pending?.tasks ?? [] {
            switch task.kind {
            case .agent: agents += 1
            case .shell: shells += 1
            case .monitor: monitors += 1
            case .other: others += 1
            }
            if !task.label.isEmpty { labels.append(task.label) }
        }
        if pending?.tasks.isEmpty ?? true, let heartbeat, heartbeat > stoppedAt {
            unlisted = true
        }
        if let wake = BackgroundHoldRules.nextWake(after: stoppedAt, pending: pending,
                                                   calendar: calendar) {
            nextWake = min(nextWake ?? wake, wake)
        }
        if pending?.crons.contains(where: \.recurring) == true { recurring = true }
    }
}

/// Five-field cron (minute hour day-of-month month day-of-week) in local
/// time — the format of Claude's session crons. Supports `*`, lists, ranges
/// and steps; day-of-week runs 0–7 (0 and 7 are Sunday); when both day
/// fields are restricted, a day matching either one fires (Vixie cron).
public struct CronSchedule: Equatable, Sendable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let daysRestricted: Bool
    let weekdaysRestricted: Bool

    public init?(parsing text: String) {
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5,
              let minutes = Self.values(fields[0], 0, 59),
              let hours = Self.values(fields[1], 0, 23),
              let days = Self.values(fields[2], 1, 31),
              let months = Self.values(fields[3], 1, 12),
              var weekdays = Self.values(fields[4], 0, 7) else { return nil }
        if weekdays.remove(7) != nil { weekdays.insert(0) }
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = weekdays
        daysRestricted = !fields[2].hasPrefix("*")
        weekdaysRestricted = !fields[4].hasPrefix("*")
    }

    private static func values(_ field: String, _ low: Int, _ high: Int) -> Set<Int>? {
        var out = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            var range = Substring(part)
            var step = 1
            if let slash = range.firstIndex(of: "/") {
                guard let s = Int(range[range.index(after: slash)...]), s > 0 else { return nil }
                step = s
                range = range[..<slash]
            }
            var from = low
            var to = high
            if range == "*" {
                // whole range
            } else if let dash = range.firstIndex(of: "-") {
                guard let a = Int(range[..<dash]),
                      let b = Int(range[range.index(after: dash)...]) else { return nil }
                from = a
                to = b
            } else {
                guard let a = Int(range) else { return nil }
                from = a
                // "5/15" = from 5, every 15; a bare "5" is just 5.
                to = part.contains("/") ? high : a
            }
            guard low <= from, from <= to, to <= high else { return nil }
            out.formUnion(stride(from: from, through: to, by: step))
        }
        return out.isEmpty ? nil : out
    }

    private func dayMatches(day: Int, weekday: Int) -> Bool {
        switch (daysRestricted, weekdaysRestricted) {
        case (true, true): return days.contains(day) || weekdays.contains(weekday)
        case (true, false): return days.contains(day)
        case (false, true): return weekdays.contains(weekday)
        case (false, false): return true
        }
    }

    /// First minute strictly after `date` that the schedule fires, searching
    /// no further than `horizon`; nil = none in that window.
    public func nextFire(after date: Date, within horizon: TimeInterval,
                         calendar: Calendar = .current) -> Date? {
        let end = date.addingTimeInterval(horizon)
        guard let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start,
              var t = calendar.date(byAdding: .minute, value: 1, to: minuteStart) else { return nil }
        while t <= end {
            let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: t)
            guard let month = c.month, let day = c.day, let hour = c.hour,
                  let minute = c.minute, let weekday = c.weekday else { return nil }
            let unit: Calendar.Component
            if !months.contains(month) || !dayMatches(day: day, weekday: weekday - 1) {
                unit = .day
            } else if !hours.contains(hour) {
                unit = .hour
            } else if minutes.contains(minute) {
                return t
            } else {
                unit = .minute
            }
            // Jump to the start of the next day / hour / minute.
            guard let start = calendar.dateInterval(of: unit, for: t)?.start,
                  let next = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
            t = next
        }
        return nil
    }
}
