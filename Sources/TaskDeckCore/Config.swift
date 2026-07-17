import Foundation

public enum Paths {
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Per-machine task state (pane specs, layout). Task notes live in the
    /// user-configured tasksDir and may sync across machines; this must not.
    public static var machineStateDir: URL {
        let d = appSupport.appendingPathComponent("tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    public static var templateFile: URL { appSupport.appendingPathComponent("template.md") }
    public static var daemonLog: URL { appSupport.appendingPathComponent("daemon.log") }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

public struct TeamDef: Codable, Identifiable, Equatable {
    /// Shell command or alias typed into the pane, e.g. "claude3".
    public var id: String
    public var label: String
    /// "claude": supports `--session-id <uuid>` / `-r <uuid>` resume.
    /// "other": started as-is, no automatic session bookkeeping.
    public var kind: String
    /// Extra CLI args appended at session start, e.g.
    /// "--dangerously-skip-permissions". Captured into the pane spec at
    /// creation time so restores behave identically.
    public var args: String?

    public init(id: String, label: String, kind: String, args: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.args = args
    }
}

public struct AppConfig: Codable, Equatable {
    public var tasksDir: String
    public var defaultCwd: String
    public var teams: [TeamDef]
    public var quotaCommand: String?
    /// Login shell spawned in every pane (interactive, so user aliases and
    /// rc files load). Anything with `-il` semantics works: zsh/bash/fish.
    public var shell: String
    /// Terminal font name. When unset, installed Nerd Fonts are probed
    /// (MesloLGS NF first — powerline/PUA prompt glyphs need one), falling
    /// back to the system monospaced font.
    public var terminalFont: String?
    public var terminalFontSize: Double?

    public init(tasksDir: String, defaultCwd: String, teams: [TeamDef],
                quotaCommand: String?, shell: String = "/bin/zsh",
                terminalFont: String? = nil, terminalFontSize: Double? = nil) {
        self.tasksDir = tasksDir
        self.defaultCwd = defaultCwd
        self.teams = teams
        self.quotaCommand = quotaCommand
        self.shell = shell
        self.terminalFont = terminalFont
        self.terminalFontSize = terminalFontSize
    }

    public static let fallback = AppConfig(
        tasksDir: "~/Documents/TaskDeck/tasks",
        defaultCwd: "~",
        teams: [TeamDef(id: "claude", label: "Claude", kind: "claude")],
        quotaCommand: nil
    )

    enum CodingKeys: String, CodingKey {
        case tasksDir, defaultCwd, teams, quotaCommand, shell, terminalFont, terminalFontSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fb = AppConfig.fallback
        tasksDir = try c.decodeIfPresent(String.self, forKey: .tasksDir) ?? fb.tasksDir
        defaultCwd = try c.decodeIfPresent(String.self, forKey: .defaultCwd) ?? fb.defaultCwd
        teams = try c.decodeIfPresent([TeamDef].self, forKey: .teams) ?? fb.teams
        quotaCommand = try c.decodeIfPresent(String.self, forKey: .quotaCommand)
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? fb.shell
        terminalFont = try c.decodeIfPresent(String.self, forKey: .terminalFont)
        terminalFontSize = try c.decodeIfPresent(Double.self, forKey: .terminalFontSize)
    }

    public static func load() -> AppConfig {
        if let d = try? Data(contentsOf: Paths.configFile),
           let c = try? JSONDecoder().decode(AppConfig.self, from: d) {
            return c
        }
        let c = AppConfig.fallback
        try? c.save()
        return c
    }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Paths.configFile)
    }

    public var tasksDirURL: URL { URL(fileURLWithPath: Paths.expand(tasksDir)) }
    public var defaultCwdExpanded: String { Paths.expand(defaultCwd) }
}
