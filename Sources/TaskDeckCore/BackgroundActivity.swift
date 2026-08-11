import Foundation

/// Reduces Claude Code's append-only transcript records into the set of
/// native background tasks that have started but not reached a terminal
/// notification. This is deliberately activity-only: it does not guess
/// whether a task blocks the user or should change the sidebar group.
public struct BackgroundTaskAccumulator: Sendable {
    public private(set) var activeTaskIDs: Set<String> = []

    public init() {}

    public mutating func consume(jsonLine: Data) {
        guard !jsonLine.isEmpty,
              let record = try? JSONDecoder().decode(TranscriptRecord.self, from: jsonLine) else {
            return
        }

        if let id = record.toolUseResult?.backgroundTaskID, !id.isEmpty {
            activeTaskIDs.insert(id)
        }

        // TaskStop results are structured differently from normal completion
        // notifications and carry no <status> tag.
        if let id = record.toolUseResult?.stoppedTaskID {
            activeTaskIDs.remove(id)
        }

        // Claude has emitted terminal notifications in three transcript shapes
        // across recent versions: a user message, a queue operation, and a
        // queued-command attachment. Reduce all of them, idempotently.
        for content in record.terminalNotificationContents {
            guard let id = Self.tag("task-id", in: content),
                  let status = Self.tag("status", in: content)?.lowercased(),
                  Self.terminalStatuses.contains(status) else { continue }
            activeTaskIDs.remove(id)
        }
    }

    public mutating func consume(jsonLine: String) {
        consume(jsonLine: Data(jsonLine.utf8))
    }

    private static let terminalStatuses: Set<String> = [
        "completed", "failed", "stopped", "killed",
    ]

    private static func tag(_ name: String, in text: String) -> String? {
        let open = "<\(name)>"
        let close = "</\(name)>"
        guard let start = text.range(of: open)?.upperBound,
              let end = text.range(of: close, range: start ..< text.endIndex)?.lowerBound,
              start < end else { return nil }
        let value = text[start ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private struct TranscriptRecord: Decodable {
        let type: String?
        let content: String?
        let toolUseResult: ToolUseResult?
        let origin: Origin?
        let message: Message?
        let attachment: Attachment?

        enum CodingKeys: String, CodingKey {
            case type, content, toolUseResult, origin, message, attachment
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            content = try? c.decode(String.self, forKey: .content)
            toolUseResult = try? c.decode(ToolUseResult.self, forKey: .toolUseResult)
            origin = try? c.decode(Origin.self, forKey: .origin)
            message = try? c.decode(Message.self, forKey: .message)
            attachment = try? c.decode(Attachment.self, forKey: .attachment)
        }

        var terminalNotificationContents: [String] {
            var values: [String] = []
            if type == "queue-operation",
               let content, content.contains("<task-notification>") {
                values.append(content)
            }
            if origin?.kind == "task-notification",
               let content = message?.stringContent {
                values.append(content)
            }
            if attachment?.commandMode == "task-notification",
               let prompt = attachment?.prompt {
                values.append(prompt)
            }
            return values
        }
    }

    private struct ToolUseResult: Decodable {
        let backgroundTaskID: String?
        let taskID: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case backgroundTaskID = "backgroundTaskId"
            case taskID = "task_id"
            case message
        }

        var stoppedTaskID: String? {
            guard let taskID, !taskID.isEmpty,
                  message?.lowercased().hasPrefix("successfully stopped task:") == true else {
                return nil
            }
            return taskID
        }
    }

    private struct Origin: Decodable {
        let kind: String?
    }

    private struct Message: Decodable {
        let stringContent: String?

        enum CodingKeys: String, CodingKey {
            case content
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stringContent = try? c.decode(String.self, forKey: .content)
        }
    }

    private struct Attachment: Decodable {
        let prompt: String?
        let commandMode: String?
    }
}

public enum BackgroundActivity {
    /// Convenience used by selftests and recovery paths. Runtime scanning is
    /// incremental so large transcripts are read only once.
    public static func activeTaskIDs(inJSONLines text: String) -> Set<String> {
        var accumulator = BackgroundTaskAccumulator()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            accumulator.consume(jsonLine: Data(line.utf8))
        }
        return accumulator.activeTaskIDs
    }
}
