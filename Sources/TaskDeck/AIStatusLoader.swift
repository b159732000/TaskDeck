import Foundation
import TaskDeckCore

struct AIStatusEntry: Equatable, Sendable {
    let state: String
    let ts: Date
    /// Work the main turn left running at its stop, and the last sub-agent
    /// sign of life since (hook sessions only; see BackgroundHoldRules).
    var pending: PendingWork? = nil
    var heartbeat: Date? = nil

    init(state: String, ts: Date, pending: PendingWork? = nil, heartbeat: Date? = nil) {
        self.state = state
        self.ts = ts
        self.pending = pending
        self.heartbeat = heartbeat
    }

    init(_ record: AIStatusFileRecord) {
        self.init(state: record.state, ts: record.ts,
                  pending: record.pending, heartbeat: record.heartbeat)
    }
}

struct AIStatusSnapshot: Equatable, Sendable {
    let statusBySession: [String: AIStatusEntry]
    let sessionsByTask: [String: Set<String>]
    /// nil means this reload intentionally skipped task documents (a bursty
    /// hook event); a dictionary means the periodic/background validation ran.
    let taskSources: [String: TaskAISource]?
}

struct TaskAISourceRequest: Equatable, Sendable {
    let slug: String
    let noteURL: URL
    let machineURL: URL
}

struct TranscriptActivityRequest: Equatable, Sendable {
    let sid: String
    let jsonlURL: URL
}

struct TaskAISource: Equatable, Sendable {
    let text: String
    let machine: TaskMachineState
}

/// Serializes status-directory reads off the main actor. A failed directory
/// read returns nil so a transient file-system error never clears live badges.
actor AIStatusLoader {
    private struct TranscriptFileSignature: Equatable {
        let fileNumber: UInt64
        let size: UInt64
        let modified: Date?
    }

    private struct CachedTranscriptActivity {
        let signature: TranscriptFileSignature
        let timestamp: Date?
    }

    private var transcriptActivityCache: [String: CachedTranscriptActivity] = [:]

    func load(from directory: URL, keyToSlug: [String: String],
              taskSourceRequests: [TaskAISourceRequest]?,
              transcriptRequests: [TranscriptActivityRequest],
              now: Date, signalWindow: TimeInterval) -> AIStatusSnapshot? {
        // Same read as AppModel's synchronous pre-first-frame prime, so the
        // two can never disagree about what a status file means.
        guard let scan = AIStatusFiles.scan(directory: directory, keyToSlug: keyToSlug,
                                            now: now, signalWindow: signalWindow) else { return nil }
        // Deleting aged-out files belongs on this (background) pass only: it is
        // a write in the watched directory, and doing it before the first frame
        // would immediately re-trigger the reload it is supposed to feed.
        for file in scan.expired { try? FileManager.default.removeItem(at: file) }

        var statuses = scan.records.mapValues(AIStatusEntry.init)
        let byTask = scan.sessionsByTask

        // Hook status is authoritative. Older sessions have no hook file, so
        // derive their fallback from the JSONL event timestamp — never the
        // filesystem mtime, which can be touched without a conversation turn.
        var liveActivityPaths = Set<String>()
        for request in transcriptRequests where statuses[request.sid] == nil {
            let timestamp = transcriptEventTimestamp(
                for: request, livePaths: &liveActivityPaths
            )
            guard let signal = SessionDiscovery.transcriptSignal(
                eventTimestamp: timestamp,
                now: now,
                signalWindow: signalWindow,
                runningWindow: 600
            ) else { continue }
            statuses[request.sid] = AIStatusEntry(
                state: signal.state, ts: signal.timestamp
            )
        }
        transcriptActivityCache = transcriptActivityCache.filter {
            liveActivityPaths.contains($0.key)
        }

        let taskSources = taskSourceRequests.map { requests in
            loadTaskSources(requests)
        }
        return AIStatusSnapshot(
            statusBySession: statuses,
            sessionsByTask: byTask,
            taskSources: taskSources
        )
    }

    private func transcriptEventTimestamp(
        for request: TranscriptActivityRequest,
        livePaths: inout Set<String>
    ) -> Date? {
        let fm = FileManager.default
        let record = request.jsonlURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: record.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        livePaths.insert(record.path)

        guard let attributes = try? fm.attributesOfItem(atPath: record.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        let signature = TranscriptFileSignature(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: size.uint64Value,
            modified: attributes[.modificationDate] as? Date
        )
        if let cached = transcriptActivityCache[record.path],
           cached.signature == signature {
            return cached.timestamp
        }
        let timestamp = SessionDiscovery.transcriptEventTimestamp(record)
        transcriptActivityCache[record.path] = CachedTranscriptActivity(
            signature: signature, timestamp: timestamp
        )
        return timestamp
    }

    private func loadTaskSources(_ requests: [TaskAISourceRequest]) -> [String: TaskAISource] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        var sources: [String: TaskAISource] = [:]
        sources.reserveCapacity(requests.count)

        for request in requests {
            guard let noteData = try? Data(contentsOf: request.noteURL),
                  let text = String(data: noteData, encoding: .utf8),
                  !text.isEmpty else { continue }
            let machine: TaskMachineState
            if !fm.fileExists(atPath: request.machineURL.path) {
                machine = TaskMachineState()
            } else {
                guard let data = try? Data(contentsOf: request.machineURL),
                      let decoded = try? decoder.decode(TaskMachineState.self, from: data) else {
                    // A transient read or corrupt file must not replace a
                    // previously-good in-memory source with an empty model.
                    continue
                }
                machine = decoded
            }
            sources[request.slug] = TaskAISource(text: text, machine: machine)
        }
        return sources
    }
}
