import Foundation

/// Pure/file-system helpers for discovering AI sessions referenced by notes.
///
/// These operations can touch many Claude project directories, so callers
/// should run the file-system methods away from the main actor.
public enum SessionDiscovery {
    public struct TeamRoot: Equatable, Sendable {
        public let team: String
        public let projects: URL

        public init(team: String, projects: URL) {
            self.team = team
            self.projects = projects
        }
    }

    public struct RecentSession: Equatable, Sendable {
        public let team: String
        public let sid: String
        public let at: Date

        public init(team: String, sid: String, at: Date) {
            self.team = team
            self.sid = sid
            self.at = at
        }
    }

    public struct TranscriptSignal: Equatable, Sendable {
        public let state: String
        public let timestamp: Date

        public init(state: String, timestamp: Date) {
            self.state = state
            self.timestamp = timestamp
        }
    }

    // Claude uses UUIDs; OpenCode currently uses `ses_...`. Keeping one
    // compiled expression makes note discovery O(note bytes), instead of
    // searching the whole note once for every status file.
    private static let sessionReferenceRE = try! NSRegularExpression(
        pattern: "(?i)(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|ses_[0-9a-z]+)"
    )

    public static func references(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return Set(sessionReferenceRE.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r]).lowercased()
        })
    }

    /// Note references that are neither the task's permanent id nor already
    /// represented by an open pane.
    public static func resumableReferences(in text: String,
                                           openSessionIDs: Set<String>) -> [String] {
        let permanentID = TaskStore.frontmatter(text)["id"]?.lowercased()
        let open = Set(openSessionIDs.map { $0.lowercased() })
        return references(in: text)
            .filter { $0 != permanentID && !open.contains($0) }
            .sorted()
    }

    /// Resolve many session ids in one directory pass. Team order is
    /// significant: if corrupt/duplicated records exist, the first configured
    /// team wins, matching the old per-id search.
    public static func resolveTeams(sessionIDs: Set<String>,
                                    roots: [TeamRoot]) -> [String: String] {
        var unresolved = Set(sessionIDs.map { $0.lowercased() })
        var found: [String: String] = [:]
        let fm = FileManager.default

        for root in roots where !unresolved.isEmpty {
            guard let projects = try? fm.contentsOfDirectory(
                at: root.projects, includingPropertiesForKeys: nil
            ) else { continue }

            for project in projects where !unresolved.isEmpty {
                guard let records = try? fm.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }
                for record in records {
                    let values = try? record.resourceValues(forKeys: [.isDirectoryKey])
                    let sid: String?
                    if values?.isDirectory == true {
                        sid = record.lastPathComponent.lowercased()
                    } else if record.pathExtension == "jsonl" {
                        sid = record.deletingPathExtension().lastPathComponent.lowercased()
                    } else {
                        sid = nil
                    }
                    guard let sid, unresolved.remove(sid) != nil else { continue }
                    found[sid] = root.team
                }
            }
        }
        return found
    }

    /// Recent conversation records for one cwd, collapsed by session id.
    public static func recentSessions(cwd: String, roots: [TeamRoot],
                                      limit: Int) -> [RecentSession] {
        let projectSlug = Paths.expand(cwd)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let fm = FileManager.default
        var best: [String: RecentSession] = [:]

        for root in roots {
            let project = root.projects.appendingPathComponent(projectSlug)
            guard let records = try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            ) else { continue }
            for record in records {
                let values = try? record.resourceValues(
                    forKeys: [.contentModificationDateKey, .isDirectoryKey]
                )
                let isDirectory = values?.isDirectory ?? false
                guard record.pathExtension == "jsonl" || isDirectory else { continue }
                let sid = record.pathExtension == "jsonl"
                    ? record.deletingPathExtension().lastPathComponent
                    : record.lastPathComponent
                let modified = isDirectory
                    ? (transcriptMtime(record) ?? .distantPast)
                    : (values?.contentModificationDate ?? .distantPast)
                if let current = best[sid], current.at >= modified { continue }
                best[sid] = RecentSession(team: root.team, sid: sid, at: modified)
            }
        }

        return best.values.sorted {
            if $0.at != $1.at { return $0.at > $1.at }
            if $0.team != $1.team { return $0.team < $1.team }
            return $0.sid < $1.sid
        }.prefix(max(0, limit)).map { $0 }
    }

    /// A directory record's own mtime misses appends to files inside it.
    public static func transcriptMtime(_ url: URL) -> Date? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let own = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard isDirectory.boolValue else { return own }
        let children = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let newestChild = children.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
        return [own, newestChild].compactMap { $0 }.max()
    }

    /// Latest real event time recorded inside a Claude JSONL transcript.
    ///
    /// Filesystem mtimes are not conversation activity: Claude and unrelated
    /// indexers can touch an old transcript without appending a turn. Read from
    /// the tail because JSONL is chronological; progressively widen only when
    /// trailing metadata rows (which often have no timestamp) require it.
    public static func transcriptEventTimestamp(_ url: URL) -> Date? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        // `<sid>/` is an auxiliary sidecar (subagents/tool-results), not a
        // main-conversation transcript. Its activity must remain informational
        // and must not steer the task's ownership group.
        guard !isDirectory.boolValue, url.pathExtension == "jsonl" else { return nil }
        return lastJSONLEventTimestamp(url)
    }

    /// Legacy sessions without hook status derive a short-lived signal from
    /// their embedded event time. Keeping this pure makes the age boundaries
    /// independently testable.
    public static func transcriptSignal(eventTimestamp: Date?, now: Date,
                                        signalWindow: TimeInterval,
                                        runningWindow: TimeInterval) -> TranscriptSignal? {
        guard let timestamp = eventTimestamp,
              now.timeIntervalSince(timestamp) < signalWindow else { return nil }
        let state = now.timeIntervalSince(timestamp) < runningWindow ? "running" : "waiting"
        return TranscriptSignal(state: state, timestamp: timestamp)
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func lastJSONLEventTimestamp(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber else { return nil }
        let size = sizeNumber.uint64Value
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var window: UInt64 = min(size, 64 * 1024)
        while window > 0 {
            let start = size - window
            do {
                try handle.seek(toOffset: start)
                var data = try handle.readToEnd() ?? Data()
                if start > 0 {
                    guard let newline = data.firstIndex(of: 0x0A) else {
                        window = window >= size / 2 ? size : window * 2
                        continue
                    }
                    data.removeSubrange(data.startIndex ... newline)
                }
                for line in data.split(separator: 0x0A).reversed() {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                          let record = object as? [String: Any],
                          let raw = record["timestamp"] else { continue }
                    if let text = raw as? String,
                       let timestamp = fractionalISO8601.date(from: text)
                            ?? plainISO8601.date(from: text) {
                        return timestamp
                    }
                    if let seconds = raw as? NSNumber {
                        return Date(timeIntervalSince1970: seconds.doubleValue)
                    }
                }
            } catch {
                return nil
            }
            if start == 0 { return nil }
            window = window >= size / 2 ? size : window * 2
        }
        return nil
    }
}
