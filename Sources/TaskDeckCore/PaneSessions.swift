import Foundation

/// "Which AI session is this terminal running?" — the answer behind the
/// pane menu's 記到 AI Session 紀錄.
///
/// Every pane is spawned with `TASKDECK_PANE=<spec id>` in its environment.
/// Claude Code passes its environment on to hooks, so the status hook
/// (`Scripts/taskdeck-ai-status.sh`) knows which pane a session runs in and
/// writes `Paths.paneSessionsDir/<spec id>.json` whenever that pane's session
/// changes — including SessionStart, so a fresh `claude`, `/clear` or
/// `/resume` is picked up before the first prompt. Last session wins.
///
/// Panes spawned before this existed carry no tag: no file, and the caller
/// asks the user to pick instead of guessing.
public enum PaneSessionFiles {
    public struct Record: Equatable, Sendable {
        public let sid: String
        /// CLAUDE_CONFIG_DIR of the session (absolute; "" = the default
        /// ~/.claude). Identifies the account without a directory scan.
        public let configDir: String?
        public let ts: Date

        public init(sid: String, configDir: String?, ts: Date) {
            self.sid = sid
            self.configDir = configDir
            self.ts = ts
        }
    }

    private struct File: Decodable {
        let sessionID: String
        let configDir: String?
        let ts: Double?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case configDir = "config_dir"
            case ts
        }
    }

    /// nil when the pane never reported a session (or the file is unreadable).
    public static func read(directory: URL, paneID: String) -> Record? {
        guard !paneID.isEmpty, !paneID.contains("/") else { return nil }
        let url = directory.appendingPathComponent(paneID + ".json")
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data),
              !f.sessionID.isEmpty else { return nil }
        return Record(sid: f.sessionID.lowercased(), configDir: f.configDir,
                      ts: f.ts.map(Date.init(timeIntervalSince1970:)) ?? .distantPast)
    }

    /// Forget a closed pane's report.
    public static func remove(directory: URL, paneID: String) {
        guard !paneID.isEmpty, !paneID.contains("/") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(paneID + ".json"))
    }
}
