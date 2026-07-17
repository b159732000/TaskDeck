import Foundation

/// One task = one markdown note (human-facing, may live in a synced vault)
/// + one machine-local JSON (pane specs & layout, `Paths.machineStateDir`).
public struct TaskNote: Identifiable, Equatable {
    public var id: String // slug = filename without .md
    public var title: String
    public var status: String // "active" | "done"
    public var created: String?
    public var path: URL
}

public struct PaneSpec: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var kind: String // "shell" | "ai" | "command"
    public var team: String?
    public var sessionID: String?
    public var command: String?
    public var cwd: String?
    public var autoStart: Bool
    /// Extra CLI args for AI sessions (copied from TeamDef at creation).
    public var extraArgs: String?

    public init(id: String = UUID().uuidString, title: String, kind: String,
                team: String? = nil, sessionID: String? = nil, command: String? = nil,
                cwd: String? = nil, autoStart: Bool = false, extraArgs: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.team = team
        self.sessionID = sessionID
        self.command = command
        self.cwd = cwd
        self.autoStart = autoStart
        self.extraArgs = extraArgs
    }

    /// The command typed into a fresh interactive zsh for this pane.
    /// For claude-family AI panes the same line both resumes an existing
    /// conversation and starts a new one with a pre-recorded session id
    /// (`-r` fails fast when the uuid doesn't exist yet).
    public var startCommand: String? {
        switch kind {
        case "ai":
            guard let team else { return nil }
            let base = [team, extraArgs].compactMap { $0 }.joined(separator: " ")
            if let sid = sessionID {
                return "\(base) -r \(sid) || \(base) --session-id \(sid)"
            }
            return base
        case "command":
            return command
        default:
            return nil
        }
    }
}

public indirect enum LayoutNode: Codable, Equatable {
    case pane(String) // specID
    case split(axis: String, ratio: Double, a: LayoutNode, b: LayoutNode) // axis: "h" side-by-side | "v" stacked
}

public enum LayoutOps {
    public static func contains(_ n: LayoutNode, _ id: String) -> Bool {
        switch n {
        case .pane(let p): return p == id
        case .split(_, _, let a, let b): return contains(a, id) || contains(b, id)
        }
    }

    public static func insertSplit(_ n: LayoutNode, target: String, axis: String, newPane: String) -> LayoutNode {
        switch n {
        case .pane(let p):
            return p == target ? .split(axis: axis, ratio: 0.5, a: n, b: .pane(newPane)) : n
        case .split(let ax, let r, let a, let b):
            return .split(axis: ax, ratio: r,
                          a: insertSplit(a, target: target, axis: axis, newPane: newPane),
                          b: insertSplit(b, target: target, axis: axis, newPane: newPane))
        }
    }

    public static func remove(_ n: LayoutNode, target: String) -> LayoutNode? {
        switch n {
        case .pane(let p):
            return p == target ? nil : n
        case .split(let ax, let r, let a, let b):
            let na = remove(a, target: target)
            let nb = remove(b, target: target)
            if let na, let nb { return .split(axis: ax, ratio: r, a: na, b: nb) }
            return na ?? nb
        }
    }

    public static func ratio(_ n: LayoutNode, at path: [Bool]) -> Double {
        guard case .split(_, let r, let a, let b) = n else { return 0.5 }
        if path.isEmpty { return r }
        return ratio(path[0] ? b : a, at: Array(path.dropFirst()))
    }

    public static func setRatio(_ n: LayoutNode, at path: [Bool], to newRatio: Double) -> LayoutNode {
        guard case .split(let ax, let r, let a, let b) = n else { return n }
        if path.isEmpty { return .split(axis: ax, ratio: newRatio, a: a, b: b) }
        if path[0] { return .split(axis: ax, ratio: r, a: a, b: setRatio(b, at: Array(path.dropFirst()), to: newRatio)) }
        return .split(axis: ax, ratio: r, a: setRatio(a, at: Array(path.dropFirst()), to: newRatio), b: b)
    }

    public static func paneIDs(_ n: LayoutNode) -> [String] {
        switch n {
        case .pane(let p): return [p]
        case .split(_, _, let a, let b): return paneIDs(a) + paneIDs(b)
        }
    }
}

public struct TaskMachineState: Codable, Equatable {
    public var panes: [PaneSpec]
    public var layout: LayoutNode?
    public var primaryTeam: String?

    public init() {
        panes = []
        layout = nil
        primaryTeam = nil
    }
}

public final class TaskStore {
    public let dir: URL

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Notes

    public func scan() -> [TaskNote] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [TaskNote] = []
        for url in items where url.pathExtension == "md" {
            let slug = url.deletingPathExtension().lastPathComponent
            if slug.uppercased() == "README" { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let fm = Self.frontmatter(text)
            out.append(TaskNote(id: slug,
                                title: Self.h1(text) ?? slug,
                                status: fm["status"] ?? "active",
                                created: fm["created"],
                                path: url))
        }
        out.sort { a, b in
            if a.status != b.status { return a.status == "active" }
            return (a.created ?? "") > (b.created ?? "")
        }
        return out
    }

    public func noteURL(_ slug: String) -> URL { dir.appendingPathComponent(slug + ".md") }

    public func read(_ slug: String) -> String {
        (try? String(contentsOf: noteURL(slug), encoding: .utf8)) ?? ""
    }

    public func write(_ slug: String, _ text: String) {
        try? text.data(using: .utf8)?.write(to: noteURL(slug))
    }

    public func create(named name: String?) -> String {
        var slug = sanitize(name ?? "")
        if slug.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "MMdd-HHmm"
            slug = "t-" + df.string(from: Date())
        }
        var final = slug
        var n = 2
        while FileManager.default.fileExists(atPath: noteURL(final).path) {
            final = "\(slug)-\(n)"
            n += 1
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        write(final, template(title: final, created: df.string(from: Date())))
        return final
    }

    public func rename(_ slug: String, to newNameRaw: String) -> String? {
        let newSlug = sanitize(newNameRaw)
        guard !newSlug.isEmpty, newSlug != slug else { return nil }
        guard !FileManager.default.fileExists(atPath: noteURL(newSlug).path) else { return nil }
        var text = read(slug)
        if let r = text.range(of: "(?m)^# .*$", options: .regularExpression) {
            text = text.replacingCharacters(in: r, with: "# \(newSlug)")
        }
        try? FileManager.default.moveItem(at: noteURL(slug), to: noteURL(newSlug))
        write(newSlug, text)
        let old = Paths.machineStateDir.appendingPathComponent(slug + ".json")
        let new = Paths.machineStateDir.appendingPathComponent(newSlug + ".json")
        try? FileManager.default.moveItem(at: old, to: new)
        return newSlug
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func template(title: String, created: String) -> String {
        if let t = try? String(contentsOf: Paths.templateFile, encoding: .utf8) {
            return t.replacingOccurrences(of: "{title}", with: title)
                .replacingOccurrences(of: "{created}", with: created)
        }
        return """
        ---
        status: active
        created: \(created)
        ---

        # \(title)

        """
    }

    // MARK: - Frontmatter & sections

    public static func frontmatter(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return out }
        for line in lines.dropFirst() {
            if line == "---" { break }
            if let i = line.firstIndex(of: ":") {
                let k = String(line[..<i]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                if out[k] == nil { out[k] = v }
            }
        }
        return out
    }

    public static func h1(_ text: String) -> String? {
        for line in text.components(separatedBy: "\n") where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func setFrontmatterValue(_ text: String, key: String, value: String) -> String {
        if let r = text.range(of: "(?m)^\(NSRegularExpression.escapedPattern(for: key)): .*$", options: .regularExpression) {
            return text.replacingCharacters(in: r, with: "\(key): \(value)")
        }
        if text.hasPrefix("---\n") {
            return text.replacingOccurrences(of: "---\n", with: "---\n\(key): \(value)\n", range: text.startIndex ..< text.index(text.startIndex, offsetBy: 4))
        }
        return "---\n\(key): \(value)\n---\n\n" + text
    }

    /// Record a session line in the note's top manifest block: right after
    /// the H1 (or frontmatter), a run of `- …` list lines closed by a `---`
    /// rule, with free-form notes below. Creates the block when absent:
    ///
    ///     # title
    ///
    ///     - claude3 6f0e…
    ///
    ///     ---
    public static func appendSessionLine(_ text: String, line: String) -> String {
        var t = text
        let anchor: String.Index
        if let h1 = t.range(of: "(?m)^# .*$", options: .regularExpression) {
            anchor = h1.upperBound
        } else if t.hasPrefix("---\n"), let close = t.range(of: "\n---\n") {
            anchor = close.upperBound
        } else {
            anchor = t.startIndex
        }
        if let divider = t.range(of: "(?m)^---[ \\t]*$", options: .regularExpression, range: anchor ..< t.endIndex) {
            let between = String(t[anchor ..< divider.lowerBound])
            let isManifest = between.split(separator: "\n", omittingEmptySubsequences: false)
                .allSatisfy {
                    let l = $0.trimmingCharacters(in: .whitespaces)
                    return l.isEmpty || l.hasPrefix("- ")
                }
            if isManifest {
                var lines = between.split(separator: "\n").map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                lines.append(line)
                t.replaceSubrange(anchor ..< divider.lowerBound,
                                  with: "\n\n" + lines.joined(separator: "\n") + "\n\n")
                return t
            }
        }
        t.insert(contentsOf: "\n\n\(line)\n\n---\n", at: anchor)
        return t
    }

    // MARK: - Machine state

    public func machineState(_ slug: String) -> TaskMachineState {
        let url = Paths.machineStateDir.appendingPathComponent(slug + ".json")
        if let d = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(TaskMachineState.self, from: d) {
            return s
        }
        return TaskMachineState()
    }

    public func saveMachineState(_ slug: String, _ s: TaskMachineState) {
        let url = Paths.machineStateDir.appendingPathComponent(slug + ".json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? enc.encode(s))?.write(to: url)
    }
}
