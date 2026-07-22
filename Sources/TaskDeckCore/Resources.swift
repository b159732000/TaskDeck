import Foundation

/// One line in the task note's `## Resources` section: a URL the task's
/// workspace needs (test page, Linear issue, Slack thread…), tagged with the
/// app that should open it.
public struct TaskResource: Equatable {
    public enum Kind: String {
        case chrome, safari, slack
    }

    public var kind: Kind
    public var url: String
    public var title: String?

    public init(kind: Kind, url: String, title: String? = nil) {
        self.kind = kind
        self.url = url
        self.title = title
    }
}

/// Parsing / rewriting of the note's `## Resources` section.
///
/// The section is user-editable markdown; the app only ever rewrites the
/// bullet list under the `### Chrome` subsection (tab snapshots). Everything
/// else in the note — including hand-written resource lines — is preserved
/// verbatim (see CLAUDE.md note conventions).
///
/// Placement (since 260720): the block lives in the note's structured top
/// area — right below the session manifest's closing `---`, above the
/// free-form notes — and is itself closed by a `---` rule so rewrites can
/// never eat untitled free text below it. Legacy notes with the section
/// elsewhere still parse/rewrite in place (the one-time migration moves
/// them up).
///
/// Recognized bullet forms, anywhere inside `## Resources`:
///     - https://example.com
///     - [title](https://example.com)
///     - chrome: https://example.com     (explicit kind prefix wins)
///     - safari: [Linear](https://linear.app/...)
///     - slack: https://foo.slack.com/archives/C123/p456
/// Kind when no prefix: `slack://` or `*.slack.com` → slack;
/// `linear.app` → safari (James reads Linear in Safari); anything else →
/// chrome. A `### Safari` / `### Slack` / `### Chrome` subsection sets the
/// default kind for its bullets.
public enum ResourceOps {
    // MARK: - Section location

    /// Range of the `## Resources` section body (after the heading line, up
    /// to the next `## ` heading, a `---` rule — the block terminator that
    /// separates it from free-form notes — or end of note).
    static func sectionBodyRange(_ text: String) -> Range<String.Index>? {
        guard let heading = text.range(of: "(?mi)^##[ \\t]+resources[ \\t]*$",
                                       options: .regularExpression) else { return nil }
        // upperBound sits on the heading's newline (or endIndex at EOF).
        let start = heading.upperBound < text.endIndex
            ? text.index(after: heading.upperBound)
            : text.endIndex
        if let next = text.range(of: "(?m)^(?:##[ \\t]|---[ \\t]*$)", options: .regularExpression,
                                 range: start ..< text.endIndex) {
            return start ..< next.lowerBound
        }
        return start ..< text.endIndex
    }

    /// Where a fresh `## Resources` block goes: right below the session
    /// manifest's closing `---` (the note's structured top area), above the
    /// free-form notes. Falls back to just after the H1 (or the frontmatter)
    /// when the note has no manifest yet — `appendSessionLine` later inserts
    /// the manifest above it, keeping the order stable.
    static func resourcesInsertionPoint(_ t: String) -> String.Index {
        let anchor: String.Index
        if let h1 = t.range(of: "(?m)^# .*$", options: .regularExpression) {
            anchor = h1.upperBound
        } else if t.hasPrefix("---\n"), let close = t.range(of: "\n---\n") {
            anchor = close.upperBound
        } else {
            anchor = t.startIndex
        }
        if let divider = t.range(of: "(?m)^---[ \\t]*$\\n?", options: .regularExpression,
                                 range: anchor ..< t.endIndex) {
            // Same manifest-shape rule as TaskStore.appendSessionLine: only
            // trust the divider when everything above it is list/blank lines.
            let between = String(t[anchor ..< divider.lowerBound])
            let isManifest = between.split(separator: "\n", omittingEmptySubsequences: false)
                .allSatisfy {
                    let l = $0.trimmingCharacters(in: .whitespaces)
                    return l.isEmpty || l.hasPrefix("- ")
                }
            if isManifest { return divider.upperBound }
        }
        return anchor
    }

    // MARK: - Parse

    public static func parse(_ text: String) -> [TaskResource] {
        guard let body = sectionBodyRange(text) else { return [] }
        var out: [TaskResource] = []
        var subsectionKind: TaskResource.Kind?
        for rawLine in text[body].components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                let name = line.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased()
                subsectionKind = TaskResource.Kind(rawValue: name.components(separatedBy: " ").first ?? name)
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            var rest = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)

            var explicit: TaskResource.Kind?
            for kind in [TaskResource.Kind.chrome, .safari, .slack]
            where rest.lowercased().hasPrefix(kind.rawValue + ":")
                // Don't eat URL schemes: "slack://…" is a URL, "slack: …" is a prefix.
                && !rest.lowercased().hasPrefix(kind.rawValue + "://") {
                explicit = kind
                rest = String(rest.dropFirst(kind.rawValue.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                break
            }

            var title: String?
            var url = rest
            // Markdown link: [title](url)
            if let m = rest.range(of: "^\\[(.*?)\\]\\((.+?)\\)", options: .regularExpression) {
                let inner = String(rest[m])
                if let close = inner.firstIndex(of: "]") {
                    title = String(inner[inner.index(after: inner.startIndex) ..< close])
                    url = String(inner[inner.index(close, offsetBy: 2) ..< inner.index(before: inner.endIndex)])
                }
            }
            url = url.trimmingCharacters(in: .whitespaces)
            guard url.contains("://") else { continue }

            let kind = explicit ?? subsectionKind ?? inferKind(url)
            out.append(TaskResource(kind: kind, url: url,
                                    title: (title?.isEmpty ?? true) ? nil : title))
        }
        return out
    }

    static func inferKind(_ url: String) -> TaskResource.Kind {
        let lower = url.lowercased()
        if lower.hasPrefix("slack://") || lower.contains(".slack.com/") { return .slack }
        if lower.contains("linear.app/") { return .safari }
        return .chrome
    }

    // MARK: - Snapshot subsections

    /// Replace the bullet list under `### <subsection>` (e.g. Chrome,
    /// Safari) inside `## Resources` with `entries` (title, url). Creates
    /// the section / subsection when missing (inserted in the note's top
    /// area, closed by a `---` rule). Hand-written lines outside that
    /// subsection are never touched.
    public static func setSnapshot(_ text: String, subsection: String,
                                   entries: [(title: String, url: String)]) -> String {
        var t = text
        // Parens must be %-escaped inside a markdown link target — a raw ")"
        // in the URL ends the link early and the tail leaks as note text.
        func linkSafe(_ url: String) -> String {
            url.replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
        }
        let bullets = entries
            .map { "- [\(sanitizeTitle($0.title))](\(linkSafe($0.url)))" }
            .joined(separator: "\n")

        if sectionBodyRange(t) == nil {
            let insertion = resourcesInsertionPoint(t)
            var block = "\n## Resources\n\n### \(subsection)\n\n\(bullets)\n\n---\n"
            if insertion == t.startIndex {
                block.removeFirst()
            } else if t[t.index(before: insertion)] != "\n" {
                // e.g. anchored at the end of the H1 line — keep a blank line.
                block = "\n" + block
            }
            t.insert(contentsOf: block, at: insertion)
            return t
        }
        guard let body = sectionBodyRange(t) else { return t }

        // Find `### <subsection>` inside the section body.
        let pattern = "(?mi)^###[ \\t]+"
            + NSRegularExpression.escapedPattern(for: subsection) + "[ \\t]*$"
        if let sub = t.range(of: pattern, options: .regularExpression, range: body) {
            // Replace from after the subsection heading to the next heading
            // (### or ##) or the section end.
            let tail = sub.upperBound ..< body.upperBound
            let end = t.range(of: "(?m)^#{2,3}[ \\t]", options: .regularExpression, range: tail)?
                .lowerBound ?? body.upperBound
            t.replaceSubrange(sub.upperBound ..< end, with: "\n\n\(bullets)\n\n")
            return t
        }

        // Section exists, subsection doesn't: append at the section end.
        t.replaceSubrange(body.upperBound ..< body.upperBound,
                          with: "\n### \(subsection)\n\n\(bullets)\n\n")
        return t
    }

    public static func setChromeSnapshot(_ text: String,
                                         entries: [(title: String, url: String)]) -> String {
        setSnapshot(text, subsection: "Chrome", entries: entries)
    }

    private static func sanitizeTitle(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "tab" : cleaned
    }

    // MARK: - Slack permalink → deep link

    /// Convert a Slack https permalink into a `slack://` deep link that
    /// opens the conversation (and thread) directly in the app instead of a
    /// browser tab. Returns nil when the URL isn't a recognizable permalink
    /// (caller then opens the original URL as-is).
    ///
    ///     https://foo.slack.com/archives/C0123/p1712345678901234
    ///       → slack://channel?team=T…&id=C0123&thread_ts=1712345678.901234
    public static func slackDeepLink(_ url: String, teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty,
              let comps = URLComponents(string: url),
              let host = comps.host, host.hasSuffix(".slack.com") else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "archives" else { return nil }
        let channel = parts[1]
        var link = "slack://channel?team=\(teamID)&id=\(channel)"

        // Prefer an explicit thread_ts query (reply permalinks carry the
        // thread root there); else derive from the pXXXXXXXXXXXXXXXX part.
        let queryTs = comps.queryItems?.first(where: { $0.name == "thread_ts" })?.value
        var ts = queryTs
        if ts == nil, parts.count >= 3, parts[2].hasPrefix("p") {
            let digits = String(parts[2].dropFirst())
            if digits.count > 6, digits.allSatisfy(\.isNumber) {
                let idx = digits.index(digits.endIndex, offsetBy: -6)
                ts = digits[..<idx] + "." + digits[idx...]
            }
        }
        if let ts { link += "&thread_ts=\(ts)" }
        return link
    }
}
