// Self-checks for TaskDeckCore (no XCTest/swift-testing on CLT toolchains).
// Run: `swift run taskdeck-selftest` — prints one line per check, exits 1 on
// any failure.
import Foundation
import TaskDeckCore

var failures = 0

func check(_ name: String, _ cond: @autoclosure () -> Bool) {
    if cond() {
        print("ok   \(name)")
    } else {
        print("FAIL \(name)")
        failures += 1
    }
}

let note = """
---
status: active
---

# demo

- claude3 abc-123

---

隨手筆記，這行不該被動到。

## Resources

- https://staging.meshy.ai/workspace
- safari: [PRO-1](https://linear.app/meshy/issue/PRO-1)
- https://meshyai.slack.com/archives/C0123/p1712345678901234
- slack://channel?team=T1&id=C9

### Chrome

- [old tab](https://old.example.com)

## 其他段

- https://not-a-resource.example.com
"""

// MARK: parse — kinds, prefixes, subsection defaults, section bounds

let rs = ResourceOps.parse(note)
check("parse: count", rs.count == 5)
check("parse: bare url → chrome", rs.count > 0 && rs[0].kind == .chrome)
check("parse: explicit safari prefix", rs.count > 1 && rs[1].kind == .safari && rs[1].title == "PRO-1")
check("parse: *.slack.com inferred", rs.count > 2 && rs[2].kind == .slack)
check("parse: slack:// is a URL not a prefix",
      rs.count > 3 && rs[3].kind == .slack && rs[3].url == "slack://channel?team=T1&id=C9")
check("parse: ### Chrome subsection default", rs.count > 4 && rs[4].kind == .chrome)
check("parse: other sections ignored", !rs.contains { $0.url.contains("not-a-resource") })

// MARK: snapshot — replaces only the ### Chrome bullets

let out = ResourceOps.setChromeSnapshot(note, entries: [
    (title: "new [1]", url: "https://a.example.com"),
    (title: "b", url: "https://b.example.com"),
])
check("snapshot: old bullets replaced", !out.contains("old.example.com"))
check("snapshot: titles sanitized", out.contains("- [new (1)](https://a.example.com)"))
check("snapshot: freeform text untouched", out.contains("隨手筆記，這行不該被動到。"))
check("snapshot: hand-written resources untouched",
      out.contains("- safari: [PRO-1](https://linear.app/meshy/issue/PRO-1)"))
check("snapshot: later sections untouched",
      out.contains("## 其他段") && out.contains("not-a-resource.example.com"))
let again = ResourceOps.setChromeSnapshot(out, entries: [(title: "c", url: "https://c.example.com")])
check("snapshot: idempotent — one ### Chrome", again.components(separatedBy: "### Chrome").count == 2)
check("snapshot: re-snapshot replaces", !again.contains("a.example.com") && again.contains("c.example.com"))

// MARK: snapshot — Safari subsection is independent of Chrome's

let withSafari = ResourceOps.setSnapshot(again, subsection: "Safari", entries: [
    (title: "Linear", url: "https://linear.app/x"),
])
check("safari: own subsection", withSafari.contains("### Safari")
      && withSafari.contains("(https://linear.app/x)"))
check("safari: chrome bullets untouched", withSafari.contains("c.example.com"))
let safariAgain = ResourceOps.setSnapshot(withSafari, subsection: "Safari",
                                          entries: [(title: "y", url: "https://y.example.com")])
check("safari: re-snapshot replaces only safari",
      !safariAgain.contains("linear.app/x") && safariAgain.contains("c.example.com")
      && safariAgain.components(separatedBy: "### Safari").count == 2)
check("safari: parsed with safari kind",
      ResourceOps.parse(safariAgain).contains { $0.kind == .safari && $0.url == "https://y.example.com" })

// MARK: snapshot — creates section when missing

let bare = ResourceOps.setChromeSnapshot("# t\n\n就一行",
                                         entries: [(title: "x", url: "https://x.example.com")])
check("snapshot: creates ## Resources", bare.contains("## Resources") && bare.contains("### Chrome"))
check("snapshot: created section parses", ResourceOps.parse(bare).count == 1)

// MARK: edge — heading at EOF must not crash

check("edge: heading at EOF parses empty", ResourceOps.parse("# t\n\n## Resources").isEmpty)
_ = ResourceOps.setChromeSnapshot("# t\n\n## Resources",
                                  entries: [(title: "x", url: "https://x.example.com")])
check("edge: snapshot onto EOF heading survives", true)

// MARK: frontmatter — waiting-group round trip

let fmNote = "---\nstatus: active\ncreated: 2026-07-17 20:00\n---\n\n# t\n\n內文 group: waiting 這行不是 frontmatter"
let parked = TaskStore.setFrontmatterValue(
    TaskStore.setFrontmatterValue(fmNote, key: "group", value: "waiting"),
    key: "waiting_since", value: "2026-07-17 21:00")
check("fm: park sets group", TaskStore.frontmatter(parked)["group"] == "waiting")
check("fm: park sets since", TaskStore.frontmatter(parked)["waiting_since"] == "2026-07-17 21:00")
let unparked = TaskStore.removeFrontmatterKey(
    TaskStore.removeFrontmatterKey(parked, key: "group"), key: "waiting_since")
check("fm: unpark removes both",
      TaskStore.frontmatter(unparked)["group"] == nil
      && TaskStore.frontmatter(unparked)["waiting_since"] == nil)
check("fm: body text untouched", unparked.contains("內文 group: waiting 這行不是 frontmatter"))
check("fm: other keys survive", TaskStore.frontmatter(unparked)["created"] == "2026-07-17 20:00")
check("fm: remove absent key is no-op",
      TaskStore.removeFrontmatterKey(fmNote, key: "group") == fmNote)

// MARK: slack deep links

check("slack: permalink → deep link",
      ResourceOps.slackDeepLink("https://meshyai.slack.com/archives/C0123/p1712345678901234",
                                teamID: "T01PCQ9AS21")
          == "slack://channel?team=T01PCQ9AS21&id=C0123&thread_ts=1712345678.901234")
check("slack: query thread_ts wins",
      ResourceOps.slackDeepLink(
          "https://meshyai.slack.com/archives/C0123/p9999999999000000?thread_ts=1712345678.901234&cid=C0123",
          teamID: "T01PCQ9A S21".replacingOccurrences(of: " ", with: ""))
          == "slack://channel?team=T01PCQ9AS21&id=C0123&thread_ts=1712345678.901234")
check("slack: no team id → nil",
      ResourceOps.slackDeepLink("https://meshyai.slack.com/archives/C0123/p1712345678901234",
                                teamID: nil) == nil)
check("slack: non-permalink → nil",
      ResourceOps.slackDeepLink("https://example.com/x", teamID: "T1") == nil)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
