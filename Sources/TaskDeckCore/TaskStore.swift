import Foundation

/// One task = one markdown note (human-facing, may live in a synced vault)
/// + one machine-local JSON (pane specs & layout, `Paths.machineStateDir`).
public struct TaskNote: Identifiable, Equatable {
    public var id: String // slug = filename without .md
    public var title: String
    public var status: String // "active" | "done"
    public var created: String?
    public var path: URL
    /// Manual lifecycle group from frontmatter: nil = normal flow,
    /// "waiting" = parked on external feedback (colleague / CI / review),
    /// "read" = seen, no reply needed yet.
    public var group: String?
    /// When the task entered its manual group (frontmatter `group_since`,
    /// "yyyy-MM-dd HH:mm"; legacy key `waiting_since` still read) — drives
    /// the >72h semi-archive and >30d auto-done buckets.
    public var groupSince: String?
    /// User-typed one-line status shown under the sidebar title (frontmatter
    /// `latest`), e.g. "07201822 等 QA". Free text, single line.
    public var statusLine: String? = nil
    /// Rename-proof identity (frontmatter `id`, a uuid stamped at creation).
    /// Panes/hooks tag sessions with this so attribution survives renames.
    public var permanentID: String? = nil
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
    /// nil = main terminal grid; "side" = small pane stacked in the notes
    /// column (kept out of the grid's split layout entirely).
    public var location: String?

    public init(id: String = UUID().uuidString, title: String, kind: String,
                team: String? = nil, sessionID: String? = nil, command: String? = nil,
                cwd: String? = nil, autoStart: Bool = false, extraArgs: String? = nil,
                location: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.team = team
        self.sessionID = sessionID
        self.command = command
        self.cwd = cwd
        self.autoStart = autoStart
        self.extraArgs = extraArgs
        self.location = location
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
    /// CDP window ids of the Chrome windows tied to this task (opened by
    /// "open resources" or picked at snapshot time) — snapshots preselect
    /// them and "close resource windows" targets exactly these. Best-effort:
    /// ids don't survive a Chrome restart; the picker is the fallback.
    /// (`chromeWindowID` is the pre-multi-select spelling, kept for decode
    /// compatibility.)
    public var chromeWindowID: Int?
    public var chromeWindowIDs: [Int]?

    public var rememberedChromeWindows: [Int] {
        chromeWindowIDs ?? chromeWindowID.map { [$0] } ?? []
    }

    public init() {
        panes = []
        layout = nil
        primaryTeam = nil
        chromeWindowID = nil
        chromeWindowIDs = nil
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
                                path: url,
                                group: fm["group"],
                                groupSince: fm["group_since"] ?? fm["waiting_since"],
                                statusLine: fm["latest"],
                                permanentID: fm["id"]))
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
        // Atomic: the note is the source of truth and lives in a synced vault —
        // a torn/half write here would be propagated to other machines. Better
        // to keep the last good file than emit a truncated one.
        do { try text.data(using: .utf8)?.write(to: noteURL(slug), options: .atomic) }
        catch { NSLog("TaskDeck: note write failed for \(slug): \(error)") }
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
        var text = template(title: final, created: df.string(from: Date()))
        // Permanent identity: slugs are unique (filesystem dedupe) but
        // change on rename; the frontmatter id survives everything.
        text = Self.setFrontmatterValue(text, key: "id", value: UUID().uuidString.lowercased())
        write(final, text)
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
        // If the note move fails (vault lock, permissions, sync race), do NOT
        // switch app state to a slug with no backing file — report failure.
        do { try FileManager.default.moveItem(at: noteURL(slug), to: noteURL(newSlug)) }
        catch { NSLog("TaskDeck: rename \(slug)→\(newSlug) failed: \(error)"); return nil }
        write(newSlug, text)
        let old = Paths.machineStateDir.appendingPathComponent(slug + ".json")
        let new = Paths.machineStateDir.appendingPathComponent(newSlug + ".json")
        try? FileManager.default.moveItem(at: old, to: new) // best-effort; regenerates if lost
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

    /// Remove a frontmatter key (line) entirely. No-op when absent.
    public static func removeFrontmatterKey(_ text: String, key: String) -> String {
        guard text.hasPrefix("---\n") else { return text }
        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key)): .*\n"
        if let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4) ..< text.endIndex),
           let line = text.range(of: pattern, options: .regularExpression,
                                 range: text.startIndex ..< close.upperBound) {
            var t = text
            t.removeSubrange(line)
            return t
        }
        return text
    }

    public static func setFrontmatterValue(_ text: String, key: String, value: String) -> String {
        // Only rewrite an existing key INSIDE the frontmatter block, never a
        // look-alike line in the free-text body (mirrors removeFrontmatterKey).
        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key)): .*$"
        if text.hasPrefix("---\n"),
           let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4) ..< text.endIndex),
           let r = text.range(of: pattern, options: .regularExpression,
                              range: text.startIndex ..< close.upperBound) {
            return text.replacingCharacters(in: r, with: "\(key): \(value)")
        }
        if text.hasPrefix("---\n") {
            return text.replacingOccurrences(of: "---\n", with: "---\n\(key): \(value)\n", range: text.startIndex ..< text.index(text.startIndex, offsetBy: 4))
        }
        return "---\n\(key): \(value)\n---\n\n" + text
    }

    // MARK: - Status line & history

    /// Timestamp for an auto-stamped status entry, matching James's manual
    /// habit "YYMMDDHHmm" (e.g. 2607221046). `now` injected for testability.
    public static func statusStamp(_ now: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyMMddHHmm"
        return df.string(from: now)
    }

    /// A status entry already carrying a leading timestamp token (8–14
    /// digits, like a manually typed "2607221046 …")? Then it's used as-is;
    /// otherwise the caller auto-prepends `statusStamp()`.
    public static func statusHasStamp(_ raw: String) -> Bool {
        raw.range(of: "^\\d{8,14}(\\s|$)", options: .regularExpression) != nil
    }

    /// The text of a status entry with any leading timestamp stripped — used
    /// to dedupe re-commits (same text, ignore the stamp).
    public static func statusText(_ entry: String) -> String {
        entry.replacingOccurrences(of: "^\\d{8,14}\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Prepend a status entry (newest on top) to the note's `## 狀態` log,
    /// creating the section in the structured top area (below the manifest,
    /// before free-form notes) when absent.
    public static func prependStatusLog(_ text: String, entry: String) -> String {
        let bullet = "- " + entry
        if let h = text.range(of: "(?mi)^##[ \\t]+狀態[ \\t]*$", options: .regularExpression) {
            let afterHeading = text.range(of: "\n", range: h.upperBound ..< text.endIndex)?.upperBound
                ?? text.endIndex
            var t = text
            t.insert(contentsOf: "\n" + bullet, at: afterHeading)
            return t
        }
        let anchor = ResourceOps.resourcesInsertionPoint(text)
        var t = text
        var block = "\n## 狀態\n\n\(bullet)\n"
        if anchor == t.startIndex {
            block.removeFirst()
        } else if t[t.index(before: anchor)] != "\n" {
            block = "\n" + block
        }
        t.insert(contentsOf: block, at: anchor)
        return t
    }

    /// Replace the first `- old` bullet in the `## 狀態` log with `- new` —
    /// used to edit a status in place (e.g. correcting its timestamp) instead
    /// of stacking a near-duplicate entry. Returns nil if `old` isn't a whole
    /// bullet line in the log (caller then falls back to prepending).
    public static func replaceStatusLogEntry(_ text: String, old: String, new: String) -> String? {
        guard let h = text.range(of: "(?mi)^##[ \\t]+狀態[ \\t]*$", options: .regularExpression) else {
            return nil
        }
        let start = h.upperBound
        let end = text.range(of: "(?m)^#{1,6}[ \\t]", options: .regularExpression,
                             range: start ..< text.endIndex)?.lowerBound ?? text.endIndex
        guard let r = text.range(of: "- " + old, range: start ..< end) else { return nil }
        // Whole-line match: preceded by a newline, followed by newline or EOF.
        guard r.lowerBound == text.startIndex || text[text.index(before: r.lowerBound)] == "\n",
              r.upperBound == text.endIndex || text[r.upperBound] == "\n" else { return nil }
        var t = text
        t.replaceSubrange(r, with: "- " + new)
        return t
    }

    /// All status entries from the `## 狀態` log, newest first (as stored).
    public static func statusHistory(_ text: String) -> [String] {
        guard let h = text.range(of: "(?mi)^##[ \\t]+狀態[ \\t]*$", options: .regularExpression) else {
            return []
        }
        let start = h.upperBound
        let end = text.range(of: "(?m)^#{1,6}[ \\t]", options: .regularExpression,
                             range: start ..< text.endIndex)?.lowerBound ?? text.endIndex
        return text[start ..< end]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
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

    /// The `- …` lines of the top session-manifest block (empty when the
    /// note has no block).
    public static func manifestLines(_ text: String) -> [String] {
        let anchor: String.Index
        if let h1 = text.range(of: "(?m)^# .*$", options: .regularExpression) {
            anchor = h1.upperBound
        } else if text.hasPrefix("---\n"), let close = text.range(of: "\n---\n") {
            anchor = close.upperBound
        } else {
            anchor = text.startIndex
        }
        guard let divider = text.range(of: "(?m)^---[ \\t]*$", options: .regularExpression,
                                       range: anchor ..< text.endIndex) else { return [] }
        return text[anchor ..< divider.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
    }

    /// Session-id loss guard: before the in-memory note overwrites disk,
    /// re-append any manifest line that exists on disk but is missing from
    /// memory (stale-cache overwrite, vault sync race, another instance…).
    /// Restored lines carry a "←自動保留" marker so the human can see what
    /// was rescued. Idempotent.
    public static func mergeManifestLines(disk: String, into memory: String) -> String {
        func normalize(_ s: String) -> String {
            s.replacingOccurrences(of: " ←自動保留", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        let have = Set(manifestLines(memory).map(normalize))
        var out = memory
        for line in manifestLines(disk) where !have.contains(normalize(line)) {
            out = appendSessionLine(out, line: normalize(line) + " ←自動保留")
        }
        return out
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
        do { try (try? enc.encode(s))?.write(to: url, options: .atomic) }
        catch { NSLog("TaskDeck: machine-state write failed for \(slug): \(error)") }
    }
}
