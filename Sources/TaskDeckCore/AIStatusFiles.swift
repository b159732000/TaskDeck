import Foundation

/// One AI session's hook-written state (`Paths.statusDir/<session>.json`).
public struct AIStatusFileRecord: Equatable, Sendable {
    public let state: String // "running" / "waiting" / "permission" / "ended"
    public let ts: Date
    /// Transcript of a session that has NOT ended (background-task counting
    /// follows it). nil for ended sessions and for hooks that wrote no path.
    public let transcriptPath: String?

    public init(state: String, ts: Date, transcriptPath: String?) {
        self.state = state
        self.ts = ts
        self.transcriptPath = transcriptPath
    }
}

public struct AIStatusDirectoryScan: Equatable, Sendable {
    /// sessionID → state. Only signals still inside the window.
    public let records: [String: AIStatusFileRecord]
    /// Reverse index of the hook's own task attribution (task_key → current
    /// slug, falling back to the slug the hook recorded).
    public let sessionsByTask: [String: Set<String>]
    /// Files whose signal aged out of the window. Deleting them is the
    /// caller's job: a write in this directory wakes the app's watcher, so the
    /// synchronous pre-first-frame read must leave the directory untouched.
    public let expired: [URL]

    public init(records: [String: AIStatusFileRecord],
                sessionsByTask: [String: Set<String>],
                expired: [URL]) {
        self.records = records
        self.sessionsByTask = sessionsByTask
        self.expired = expired
    }
}

/// Reading the hook status directory — the authoritative half of sidebar
/// grouping (`GroupingRules`). It lives here rather than inside the app's
/// loader actor because the same read has to happen twice: synchronously,
/// before the first frame (a signal-less first render put every 等你 task in
/// 待開工), and periodically off the main actor together with the expensive
/// transcript work.
public enum AIStatusFiles {
    private struct StatusFile: Decodable {
        let state: String
        let ts: Double?
        let task: String?
        let taskKey: String?
        let transcriptPath: String?

        enum CodingKeys: String, CodingKey {
            case state, ts, task
            case taskKey = "task_key"
            case transcriptPath = "transcript_path"
        }
    }

    /// nil = the directory itself could not be read (a transient error must
    /// never be mistaken for "no sessions"). Unreadable individual files are
    /// skipped: one corrupt row cannot blank the others.
    public static func scan(directory: URL, keyToSlug: [String: String],
                            now: Date, signalWindow: TimeInterval) -> AIStatusDirectoryScan? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        var records: [String: AIStatusFileRecord] = [:]
        var byTask: [String: Set<String>] = [:]
        var expired: [URL] = []
        let decoder = JSONDecoder()

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(StatusFile.self, from: data) else { continue }
            let sid = file.deletingPathExtension().lastPathComponent.lowercased()
            let timestamp = record.ts.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            if now.timeIntervalSince(timestamp) > signalWindow {
                expired.append(file)
                continue
            }
            var transcript: String?
            if record.state != "ended", let path = record.transcriptPath, !path.isEmpty {
                transcript = path
            }
            records[sid] = AIStatusFileRecord(state: record.state, ts: timestamp,
                                              transcriptPath: transcript)
            if let slug = slug(for: record.taskKey, task: record.task, keyToSlug: keyToSlug) {
                byTask[slug, default: []].insert(sid)
            }
        }
        return AIStatusDirectoryScan(records: records, sessionsByTask: byTask, expired: expired)
    }

    /// The permanent task key wins: the slug the hook recorded goes stale the
    /// moment the task is renamed, while `id` in the note's frontmatter does
    /// not. A key that matches no current task falls back to that slug so a
    /// session is not orphaned by an unrelated rename.
    public static func slug(for taskKey: String?, task: String?,
                            keyToSlug: [String: String]) -> String? {
        if let taskKey, let current = keyToSlug[taskKey] { return current }
        guard let task, !task.isEmpty else { return nil }
        return task
    }
}
