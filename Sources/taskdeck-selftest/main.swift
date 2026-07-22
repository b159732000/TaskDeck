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

/// True when `a` occurs before `b` in `s` (both must exist).
func ordered(_ s: String, _ a: String, _ b: String) -> Bool {
    guard let ra = s.range(of: a), let rb = s.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
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
check("snapshot: created section sits above free text", ordered(bare, "## Resources", "就一行"))

// MARK: top placement — new sections land under the manifest, above notes,
// closed by a --- rule so rewrites can't eat free text

let topNote = "---\nstatus: active\n---\n\n# demo\n\n- claude3 abc-123\n\n---\n\n自由筆記在下面。\n"
let topOut = ResourceOps.setChromeSnapshot(topNote, entries: [(title: "t", url: "https://t.example.com")])
check("top: manifest → resources → notes order",
      ordered(topOut, "- claude3 abc-123", "## Resources")
      && ordered(topOut, "## Resources", "自由筆記在下面。"))
check("top: block closed by --- before notes",
      (topOut.contains("---\n\n自由筆記在下面。") || topOut.contains("---\n自由筆記在下面。"))
      && ResourceOps.parse(topOut).count == 1)

let topNoisy = topOut.replacingOccurrences(
    of: "自由筆記在下面。",
    with: "自由筆記在下面。\n\n- https://free-note-link.example.com")
check("top: bullets below --- are not resources",
      !ResourceOps.parse(topNoisy).contains { $0.url.contains("free-note-link") })

let topAgain = ResourceOps.setChromeSnapshot(topNoisy, entries: [(title: "u", url: "https://u.example.com")])
check("top: re-snapshot replaces bullets only",
      !topAgain.contains("t.example.com") && topAgain.contains("u.example.com"))
check("top: re-snapshot keeps free notes",
      topAgain.contains("自由筆記在下面。") && topAgain.contains("free-note-link.example.com"))
check("top: still exactly one ### Chrome", topAgain.components(separatedBy: "### Chrome").count == 2)

let withSession = TaskStore.appendSessionLine(topOut, line: "- claude new-999")
check("top: session line joins manifest, not resources",
      ordered(withSession, "- claude new-999", "## Resources"))
check("top: manifest line count", TaskStore.manifestLines(withSession).count == 2)

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

// setFrontmatterValue must scope to frontmatter, never rewrite a body line
let bodyLookalike = "---\nstatus: active\n---\n\n# t\n\n正文 group: 設計討論 這行不能被動\n"
let setG = TaskStore.setFrontmatterValue(bodyLookalike, key: "group", value: "waiting")
check("fm-set: body look-alike line untouched", setG.contains("正文 group: 設計討論 這行不能被動"))
check("fm-set: key inserted into frontmatter", TaskStore.frontmatter(setG)["group"] == "waiting")
let setG2 = TaskStore.setFrontmatterValue(setG, key: "group", value: "read")
check("fm-set: update existing key stays in frontmatter", TaskStore.frontmatter(setG2)["group"] == "read")
check("fm-set: update didn't touch body", setG2.contains("正文 group: 設計討論 這行不能被動"))

// MARK: manifest merge-guard — stale flush must not drop session ids

let diskNote = "---\nstatus: active\n---\n\n# t\n\n- claude-eng old-123\n- claude3 keep-456\n\n---\n\n內文"
let staleMemory = "---\nstatus: active\n---\n\n# t\n\n- claude3 keep-456\n- claude-eng new-789\n\n---\n\n內文（多打了幾個字）"
let mergedNote = TaskStore.mergeManifestLines(disk: diskNote, into: staleMemory)
check("merge: rescued line restored w/ marker",
      mergedNote.contains("- claude-eng old-123 ←自動保留"))
check("merge: memory's new line kept", mergedNote.contains("- claude-eng new-789"))
check("merge: shared line not duplicated",
      mergedNote.components(separatedBy: "keep-456").count == 2)
check("merge: body edits preserved", mergedNote.contains("內文（多打了幾個字）"))
check("merge: idempotent",
      TaskStore.mergeManifestLines(disk: diskNote, into: mergedNote) == mergedNote)
check("merge: no manifest on disk is a no-op",
      TaskStore.mergeManifestLines(disk: "# t\n\n無 manifest", into: staleMemory) == staleMemory)

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

// MARK: status line — smart stamp, history log, dedupe

check("status: manual stamp detected", TaskStore.statusHasStamp("2607221046 等 QA"))
check("status: no stamp → not detected", !TaskStore.statusHasStamp("等 QA"))
check("status: strip stamp", TaskStore.statusText("2607221046 等 QA") == "等 QA")
check("status: strip no-op when no stamp", TaskStore.statusText("等 QA") == "等 QA")

let s0 = "---\nstatus: active\n---\n\n# t\n\n- claude x\n\n---\n\n## Resources\n\n### Chrome\n"
let s1 = TaskStore.prependStatusLog(s0, entry: "2607221046 第一則")
check("status: log section created", s1.contains("## 狀態") && s1.contains("- 2607221046 第一則"))
check("status: log sits above Resources", ordered(s1, "## 狀態", "## Resources"))
let s2 = TaskStore.prependStatusLog(s1, entry: "2607221100 第二則")
check("status: newest prepended on top",
      ordered(s2, "第二則", "第一則"))
check("status: history parses newest-first",
      TaskStore.statusHistory(s2) == ["2607221100 第二則", "2607221046 第一則"])
check("status: Resources still intact after log", ResourceOps.parse(s2).isEmpty == false || s2.contains("### Chrome"))

// MARK: status line — editing just the timestamp edits in place, no dup line
let s3 = TaskStore.replaceStatusLogEntry(s2, old: "2607221100 第二則", new: "2607221146 第二則")
check("status: replace edits the entry in place",
      s3 != nil && s3!.contains("- 2607221146 第二則") && !s3!.contains("- 2607221100 第二則"))
check("status: replace keeps entry count", TaskStore.statusHistory(s3 ?? s2).count == 2)
check("status: replace leaves the other entry", (s3 ?? "").contains("2607221046 第一則"))
check("status: replace absent entry → nil",
      TaskStore.replaceStatusLogEntry(s2, old: "9999999999 不存在", new: "x") == nil)

// MARK: grouping rules (260720 v3) — lock behavior before it moved out of AppModel

let gNow = Date()
func sig(_ state: String, agoSec: TimeInterval, acked: Bool) -> SessionSignal {
    SessionSignal(state: state, ts: gNow.addingTimeInterval(-agoSec), acked: acked)
}
func grp(status: String = "active", group: String? = nil, quiet: TimeInterval = 0,
         _ signals: [SessionSignal]) -> TaskGroup {
    GroupingRules.classify(status: status, group: group, quiet: quiet, signals: signals, now: gNow)
}
let sink = GroupingRules.sinkAfter

check("grp: done wins over everything",
      grp(status: "done", group: "needsyou", [sig("running", agoSec: 10, acked: false)]) == .done)
check("grp: fresh running → aiRunning (overrides manual group)",
      grp(group: "waiting", [sig("running", agoSec: 60, acked: false)]) == .aiRunning)
check("grp: STALE running (>30m) is not running",
      grp([sig("running", agoSec: 2000, acked: true)]) == .idle)
check("grp: waiting group is sticky vs fresh attention",
      grp(group: "waiting", [sig("waiting", agoSec: 30, acked: false)]) == .waitingExt)
check("grp: waiting group sinks when quiet",
      grp(group: "waiting", quiet: sink + 10, [sig("ended", agoSec: sink + 10, acked: true)]) == .semiArchived)
check("grp: FRESH unacked stop resurfaces a 已讀 task to 等你",
      grp(group: "read", [sig("waiting", agoSec: 30, acked: false)]) == .needsYou)
check("grp: 已讀 with only an ACKED stop stays 已讀",
      grp(group: "read", [sig("ended", agoSec: 300, acked: true)]) == .read)
check("grp: 已讀 sinks to 半封存 when quiet",
      grp(group: "read", quiet: sink + 10, [sig("ended", agoSec: sink + 10, acked: true)]) == .semiArchived)
check("grp: unparked + unacked waiting → 等你",
      grp([sig("waiting", agoSec: 30, acked: false)]) == .needsYou)
check("grp: unparked + acked stop → 已讀",
      grp([sig("waiting", agoSec: 30, acked: true)]) == .read)
check("grp: manual 等你 survives with no signal", grp(group: "needsyou", []) == .needsYou)
check("grp: nothing → 待開工", grp([]) == .idle)
check("attn: unacked permission beats waiting, since = oldest",
      {
          let a = GroupingRules.attention([
              sig("waiting", agoSec: 100, acked: false),
              sig("permission", agoSec: 50, acked: false),
          ])
          return a?.permission == true && a?.since == gNow.addingTimeInterval(-100)
      }())
check("attn: all acked → nil",
      GroupingRules.attention([sig("waiting", agoSec: 30, acked: true)]) == nil)

// MARK: snapshot — URLs containing parens survive the markdown round-trip

let parenOut = ResourceOps.setChromeSnapshot("# t\n", entries: [
    (title: "wiki", url: "https://en.wikipedia.org/wiki/Foo_(bar)"),
])
check("paren: raw ) escaped in link target", parenOut.contains("(https://en.wikipedia.org/wiki/Foo_%28bar%29)"))
let parenParsed = ResourceOps.parse(parenOut)
check("paren: parses back as one resource", parenParsed.count == 1
      && parenParsed[0].url == "https://en.wikipedia.org/wiki/Foo_%28bar%29")

// MARK: ByteQueue — FIFO semantics survive consume/compaction/trim

var bq = ByteQueue()
bq.append([1, 2, 3, 4, 5])
bq.consume(2)
check("bq: count after consume", bq.count == 3)
check("bq: logical indexing", bq[0] == 3 && bq[2] == 5)
check("bq: snapshot", bq.snapshot() == [3, 4, 5])
bq.append([6, 7])
check("bq: append after consume", bq.snapshot() == [3, 4, 5, 6, 7])
bq.trimFront(toCount: 2)
check("bq: trimFront keeps newest", bq.snapshot() == [6, 7])
bq.consume(99)
check("bq: over-consume empties", bq.isEmpty && bq.count == 0)
// Compaction path: push enough through to trigger the head reset.
var big = ByteQueue()
let chunk = [UInt8](repeating: 0xAB, count: 32 * 1024)
for _ in 0 ..< 8 { big.append(chunk) }
big.consume(6 * 32 * 1024 + 5)
check("bq: compaction keeps content", big.count == 2 * 32 * 1024 - 5 && big[0] == 0xAB)
big.append([0xCD])
check("bq: append after compaction", big.snapshot().last == 0xCD)
// Frame reader still parses across chunked appends (offset-based buffer).
let frMsg = { () -> WireMessage in var m = WireMessage(type: "ping"); m.id = "x"; return m }()
let frData = FrameCodec.encode(frMsg)
let fr = FrameCodec.Reader()
fr.append(frData.prefix(3))
check("bq-reader: partial frame → nil", fr.next() == nil)
fr.append(frData.dropFirst(3))
fr.append(frData) // second whole frame
check("bq-reader: first frame parses", fr.next()?.type == "ping")
check("bq-reader: second frame parses", fr.next()?.id == "x")
check("bq-reader: drained", fr.next() == nil)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
