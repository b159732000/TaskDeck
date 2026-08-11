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

func multilineShiftReturn(
    _ keyCode: UInt16,
    shift: Bool = false,
    command: Bool = false,
    option: Bool = false,
    control: Bool = false
) -> [UInt8]? {
    TerminalInputEncoding.multilineShiftReturn(
        keyCode: keyCode,
        shift: shift,
        command: command,
        option: option,
        control: control
    )
}

check("terminal input: main Shift+Return stays distinct from submit",
      multilineShiftReturn(36, shift: true) == [0x1b, 0x0d])
check("terminal input: keypad Shift+Enter uses the same mapping",
      multilineShiftReturn(76, shift: true) == [0x1b, 0x0d])
check("terminal input: plain Return remains on SwiftTerm's normal path",
      multilineShiftReturn(36) == nil)
check("terminal input: modified Shift+Return is not stolen",
      multilineShiftReturn(36, shift: true, option: true) == nil
      && multilineShiftReturn(36, shift: true, command: true) == nil
      && multilineShiftReturn(36, shift: true, control: true) == nil)

/// True when `a` occurs before `b` in `s` (both must exist).
func ordered(_ s: String, _ a: String, _ b: String) -> Bool {
    guard let ra = s.range(of: a), let rb = s.range(of: b) else { return false }
    return ra.lowerBound < rb.lowerBound
}

// MARK: remote terminal surface — additive wire carrier + resize lease

var surfaceWire = WireMessage(type: "replay")
surfaceWire.surfaceVersion = Wire.remoteSurfaceVersion
surfaceWire.surfaceClientID = "view-a"
surfaceWire.paneEpoch = "epoch-a"
surfaceWire.surfaceRevision = 7
surfaceWire.setSurfaceSnapshot([0x00, 0x1b, 0xff])
let surfaceReader = FrameCodec.Reader()
surfaceReader.append(FrameCodec.encode(surfaceWire))
let decodedSurfaceWire = surfaceReader.next()
check("surface wire: opaque snapshot round-trips",
      decodedSurfaceWire?.surfaceSnapshotBytes == [0x00, 0x1b, 0xff])
check("surface wire: pane epoch + revision round-trip",
      decodedSurfaceWire?.surfaceVersion == Wire.remoteSurfaceVersion
      && decodedSurfaceWire?.paneEpoch == "epoch-a"
      && decodedSurfaceWire?.surfaceRevision == 7)

let legacyWireJSON = Data(#"{"type":"replay","data":"eA==","futureField":true}"#.utf8)
let legacyWire = try? JSONDecoder().decode(WireMessage.self, from: legacyWireJSON)
check("surface wire: legacy frame decodes with no capability",
      legacyWire?.dataBytes == [0x78]
      && legacyWire?.surfaceVersion == nil
      && legacyWire?.surfaceSnapshot == nil)

var lease = ResizeLeaseState()
let firstLease = lease.acquire(ownerID: "conn-a:view-a", nowMS: 100, ttlMS: 50,
                               token: "token-a")
check("resize lease: first owner acquires",
      firstLease?.token == "token-a"
      && firstLease?.generation == 1
      && firstLease?.expiresAtMS == 150)
check("resize lease: competing live owner is denied",
      lease.acquire(ownerID: "conn-b:view-b", nowMS: 120, ttlMS: 50,
                    token: "token-b") == nil)
let renewedLease = lease.acquire(ownerID: "conn-a:view-a", nowMS: 130, ttlMS: 50,
                                 token: "must-not-replace")
check("resize lease: same owner renews credential",
      renewedLease?.token == "token-a"
      && renewedLease?.generation == 1
      && renewedLease?.expiresAtMS == 180)
check("resize lease: valid resize renews",
      lease.validateAndRenew(ownerID: "conn-a:view-a", token: "token-a",
                             generation: 1, nowMS: 150, ttlMS: 50)?.expiresAtMS == 200)
check("resize lease: wrong token cannot resize",
      lease.validateAndRenew(ownerID: "conn-a:view-a", token: "stale",
                             generation: 1, nowMS: 160, ttlMS: 50) == nil)
let secondLease = lease.acquire(ownerID: "conn-b:view-b", nowMS: 200, ttlMS: 40,
                                token: "token-b")
check("resize lease: expiry permits new generation",
      secondLease?.token == "token-b" && secondLease?.generation == 2)
check("resize lease: expired owner's credential stays stale",
      !lease.isOwned(by: "conn-a:view-a", token: "token-a", generation: 1, at: 201))
check("resize lease: stale release cannot revoke new owner",
      !lease.release(ownerID: "conn-a:view-a", token: "token-a", generation: 1)
      && lease.isOwned(by: "conn-b:view-b", token: "token-b", generation: 2, at: 201))
check("resize lease: connection teardown revokes owner",
      lease.revoke(ownerID: "conn-b:view-b") && lease.grant == nil)

var claimedLease = ResizeLeaseState()
_ = claimedLease.acquire(ownerID: "conn-a:view-a", nowMS: 10, ttlMS: 100,
                         token: "old-token")
let claimedGrant = claimedLease.claim(ownerID: "conn-b:view-b", nowMS: 20, ttlMS: 100,
                                      token: "focus-token")
check("resize lease: focused viewer preempts immediately",
      claimedGrant?.ownerID == "conn-b:view-b"
      && claimedGrant?.token == "focus-token"
      && claimedGrant?.generation == 2)
check("resize lease: claim invalidates old in-flight resize",
      !claimedLease.isOwned(by: "conn-a:view-a", token: "old-token", generation: 1, at: 21))
let sameClaim = claimedLease.claim(ownerID: "conn-b:view-b", nowMS: 30, ttlMS: 100,
                                   token: "must-not-replace")
check("resize lease: repeated focus keeps credential stable",
      sameClaim?.token == "focus-token" && sameClaim?.generation == 2)

// MARK: terminal attach — replay/live barrier is per view

var replayBuffer = ReplayFirstOutputBuffer()
check("terminal replay: pre-response live is dropped as snapshot overlap",
      !replayBuffer.appendLive(Array("duplicate".utf8)) && replayBuffer.drain().isEmpty)
check("terminal replay: response opens applying phase",
      replayBuffer.receivedReplayResponse()
      && replayBuffer.phase == .applyingReplay)
check("terminal replay: post-snapshot live waits for UI replay",
      !replayBuffer.appendLive(Array("after-snapshot".utf8))
      && replayBuffer.drain().isEmpty)
check("terminal replay: applying replay releases newer bytes",
      replayBuffer.replayApplied()
      && replayBuffer.drain() == Array("after-snapshot".utf8))
check("terminal replay: live output is immediately deliverable",
      replayBuffer.appendLive(Array("live".utf8))
      && replayBuffer.drain() == Array("live".utf8))

var emptyReplayBuffer = ReplayFirstOutputBuffer()
_ = emptyReplayBuffer.receivedReplayResponse()
check("terminal replay: empty replay still unlocks subscription",
      !emptyReplayBuffer.replayApplied()
      && emptyReplayBuffer.phase == .live
      && emptyReplayBuffer.appendLive([0x78]))

var cancelledReplayBuffer = ReplayFirstOutputBuffer()
_ = cancelledReplayBuffer.receivedReplayResponse()
_ = cancelledReplayBuffer.appendLive([0x6f, 0x6c, 0x64])
cancelledReplayBuffer.cancel()
check("terminal replay: cancelled generation drops late output",
      cancelledReplayBuffer.phase == .cancelled
      && !cancelledReplayBuffer.replayApplied()
      && !cancelledReplayBuffer.appendLive([0x6e, 0x65, 0x77])
      && cancelledReplayBuffer.drain().isEmpty)

// MARK: terminal attach — conservative truncated OpenTUI recovery

let syncBegin = Array("\u{1b}[?2026h".utf8)
var truncatedTUIReplay = Array("29;6H".utf8) // ring begins inside a lost CSI
truncatedTUIReplay.append(contentsOf: syncBegin)
truncatedTUIReplay.append(contentsOf: Array("first draw\u{1b}[?2026l".utf8))
truncatedTUIReplay.append(contentsOf: syncBegin)
truncatedTUIReplay.append(contentsOf: Array("second draw\u{1b}[?2026l".utf8))
truncatedTUIReplay.append(contentsOf: repeatElement(
    0x20, count: TerminalReplayRecovery.daemonReplayCapacity - truncatedTUIReplay.count))
let recoveryPlan = TerminalReplayRecovery.plan(
    for: truncatedTUIReplay, allowMouseModeRecovery: true)
let recoveredReplay = recoveryPlan.prepare(truncatedTUIReplay)
let expectedMousePrefix = Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)
check("terminal recovery: full repeated OpenTUI replay is recognized",
      recoveryPlan.applicationPagingFallback)
check("terminal recovery: partial leading CSI is discarded",
      recoveryPlan.startOffset == 5)
check("terminal recovery: local mouse state precedes first complete draw",
      recoveredReplay.starts(with: expectedMousePrefix + syncBegin))
check("terminal recovery: pane metadata is required",
      TerminalReplayRecovery.plan(
          for: truncatedTUIReplay, allowMouseModeRecovery: false) == .init())

var completeTUIReplay = truncatedTUIReplay
let mouseSetup = Array("\u{1b}[?1000;1006h".utf8)
completeTUIReplay.replaceSubrange(0 ..< 5, with: mouseSetup)
check("terminal recovery: existing combined mouse setup is never overridden",
      TerminalReplayRecovery.plan(
          for: completeTUIReplay, allowMouseModeRecovery: true) == .init())
var encodingOnlyTUIReplay = truncatedTUIReplay
let mouseEncodingOnly = Array("\u{1b}[?1006h".utf8)
encodingOnlyTUIReplay.replaceSubrange(0 ..< 5, with: mouseEncodingOnly)
check("terminal recovery: 1006 encoding alone does not imply mouse tracking",
      TerminalReplayRecovery.plan(
          for: encodingOnlyTUIReplay,
          allowMouseModeRecovery: true).applicationPagingFallback)
var hostileParameterReplay = truncatedTUIReplay
let oversizedParameter = Array(
    ("\u{1b}[?" + String(repeating: "9", count: 1024) + "h").utf8)
hostileParameterReplay.replaceSubrange(0 ..< 5, with: oversizedParameter)
check("terminal recovery: oversized CSI parameter cannot overflow parser",
      TerminalReplayRecovery.plan(
          for: hostileParameterReplay,
          allowMouseModeRecovery: true).applicationPagingFallback)
check("terminal recovery: non-full replay is left untouched",
      TerminalReplayRecovery.plan(
          for: Array(truncatedTUIReplay.prefix(4096)),
          allowMouseModeRecovery: true) == .init())

// MARK: title search — contiguous literal substring, title only

let searchTitle = "Keycap PRO-1816- [FE-GL] PRO-1280 keycap键帽生成器"

check("search: empty query matches",
      TaskSearchRules.matchesTitle(searchTitle, query: ""))
check("search: whitespace-only query matches",
      TaskSearchRules.matchesTitle(searchTitle, query: " \n\t "))
check("search: trims query edges",
      TaskSearchRules.matchesTitle(searchTitle, query: "  PRO-1816  "))
check("search: contiguous substring matches",
      TaskSearchRules.matchesTitle(searchTitle, query: "PRO-1816"))
check("search: ASCII case-insensitive",
      TaskSearchRules.matchesTitle(searchTitle, query: "keyCAP"))
check("search: Chinese substring matches",
      TaskSearchRules.matchesTitle(searchTitle, query: "键帽生成"))
check("search: no fuzzy token matching",
      !TaskSearchRules.matchesTitle(searchTitle, query: "Keycap PRO-1280"))
check("search: internal punctuation remains significant",
      !TaskSearchRules.matchesTitle(searchTitle, query: "PRO-1816 [FE-GL]"))
check("search: reordered text does not match",
      !TaskSearchRules.matchesTitle(searchTitle, query: "PRO-1280 PRO-1816"))
check("search: brackets are ordinary text",
      TaskSearchRules.matchesTitle(searchTitle, query: "[FE-GL]"))
check("search: regex wildcard is not evaluated",
      !TaskSearchRules.matchesTitle("plain title", query: ".*"))
check("search: regex anchor is not evaluated",
      !TaskSearchRules.matchesTitle("plain title", query: "^plain"))

let decomposedCafe = "Cafe" + String(UnicodeScalar(0x0301)!)
check("search: canonically equivalent Unicode matches",
      TaskSearchRules.matchesTitle("Café review", query: decomposedCafe))
check("search: accent is not discarded",
      !TaskSearchRules.matchesTitle("Café review", query: "cafe"))
check("search: no simplified/traditional conversion",
      !TaskSearchRules.matchesTitle("鍵帽生成器", query: "键帽"))
check("search: no width conversion",
      !TaskSearchRules.matchesTitle("ＰＲＯ task", query: "pro"))
check("search: grapheme cluster matches",
      TaskSearchRules.matchesTitle("Family 👨‍👩‍👧‍👦 task", query: "👨‍👩‍👧‍👦"))

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

let mainlined = TaskStore.setFrontmatterValue(bodyLookalike, key: "priority", value: "main")
check("fm-priority: mainline marker stored", TaskStore.frontmatter(mainlined)["priority"] == "main")
let unmainlined = TaskStore.removeFrontmatterKey(mainlined, key: "priority")
check("fm-priority: marker removal keeps body",
      TaskStore.frontmatter(unmainlined)["priority"] == nil
      && unmainlined.contains("正文 group: 設計討論 這行不能被動"))

// MARK: archive ordering — completion time, never creation time

let archiveTemp = FileManager.default.temporaryDirectory
    .appendingPathComponent("taskdeck-archive-sort-\(UUID().uuidString)")
let archiveStore = TaskStore(dir: archiveTemp)
func archiveNote(created: String, archiveKey: String? = nil,
                 archiveValue: String? = nil) -> String {
    var rows = ["---", "status: done", "created: \(created)"]
    if let archiveKey, let archiveValue { rows.append("\(archiveKey): \(archiveValue)") }
    rows += ["---", "", "# archived"]
    return rows.joined(separator: "\n")
}
archiveStore.write("created-new-archived-old", archiveNote(
    created: "2026-07-30 10:00",
    archiveKey: "archived_at", archiveValue: "2026-07-20 10:00:00"
))
archiveStore.write("created-old-archived-new", archiveNote(
    created: "2026-07-01 10:00",
    archiveKey: "archived_at", archiveValue: "2026-07-30 10:00:00"
))
archiveStore.write("auto-archive-compat", archiveNote(
    created: "2026-07-29 10:00",
    archiveKey: "auto_archived", archiveValue: "2026-07-25 10:00"
))
archiveStore.write("legacy-mtime", archiveNote(created: "2026-07-28 10:00"))
let archiveTestDF = DateFormatter()
archiveTestDF.locale = Locale(identifier: "en_US_POSIX")
archiveTestDF.dateFormat = "yyyy-MM-dd HH:mm:ss"
let legacyMtime = archiveTestDF.date(from: "2026-07-28 10:00:00")!
try? FileManager.default.setAttributes(
    [.modificationDate: legacyMtime],
    ofItemAtPath: archiveStore.noteURL("legacy-mtime").path
)
let archivedRows = archiveStore.scan()
let archiveOrder = archivedRows.sorted(by: TaskSortRules.archivedNewestFirst).map(\.id)
check("archive-sort: newest archive wins despite older creation",
      archiveOrder.first == "created-old-archived-new")
check("archive-sort: exact, legacy mtime, auto fallback, old exact",
      archiveOrder == [
          "created-old-archived-new",
          "legacy-mtime",
          "auto-archive-compat",
          "created-new-archived-old",
      ])
check("archive-sort: auto_archived compatibility parsed",
      archivedRows.first(where: { $0.id == "auto-archive-compat" })?.archivedAt != nil)
check("archive-sort: legacy done falls back to file mtime",
      abs((archivedRows.first(where: { $0.id == "legacy-mtime" })?.archivedAt
           ?? .distantPast).timeIntervalSince(legacyMtime)) < 1)
try? FileManager.default.removeItem(at: archiveTemp)

let autoParked = """
---
status: active
group: waiting
group_since: 2026-06-01 10:00
---

# auto lifecycle

正文 auto_archived: 只是文字，不能被動
"""
let firstAutoArchive = TaskStore.markArchived(
    autoParked, at: "2026-07-01 10:00:00", automatic: true
)
check("archive-lifecycle: automatic archive writes canonical + source marker",
      TaskStore.frontmatter(firstAutoArchive)["archived_at"] == "2026-07-01 10:00:00"
      && TaskStore.frontmatter(firstAutoArchive)["auto_archived"] == "2026-07-01 10:00:00")
let reactivatedAuto = TaskStore.markActive(firstAutoArchive)
check("archive-lifecycle: reactivating auto archive clears stale archive + parking",
      TaskStore.frontmatter(reactivatedAuto)["status"] == "active"
      && TaskStore.frontmatter(reactivatedAuto)["archived_at"] == nil
      && TaskStore.frontmatter(reactivatedAuto)["auto_archived"] == nil
      && TaskStore.frontmatter(reactivatedAuto)["group"] == nil
      && TaskStore.frontmatter(reactivatedAuto)["group_since"] == nil)
check("archive-lifecycle: reactivation leaves free-form body untouched",
      reactivatedAuto.contains("正文 auto_archived: 只是文字，不能被動"))
let secondAutoArchive = TaskStore.markArchived(
    reactivatedAuto, at: "2026-07-30 12:00:00", automatic: true
)
check("archive-lifecycle: reactivated task can auto-archive again",
      TaskStore.frontmatter(secondAutoArchive)["archived_at"] == "2026-07-30 12:00:00"
      && TaskStore.frontmatter(secondAutoArchive)["auto_archived"] == "2026-07-30 12:00:00")
let manualAfterAuto = TaskStore.markArchived(
    firstAutoArchive, at: "2026-07-30 13:00:00"
)
check("archive-lifecycle: manual archive clears stale automatic marker",
      TaskStore.frontmatter(manualAfterAuto)["archived_at"] == "2026-07-30 13:00:00"
      && TaskStore.frontmatter(manualAfterAuto)["auto_archived"] == nil)

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

// MARK: session discovery — one note scan + batched off-main directory lookup

let uuidA = "11111111-2222-3333-4444-555555555555"
let uuidB = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
let discoveryNote = """
---
id: \(uuidA)
---

# sessions

Body UUID: \(uuidB)
Duplicate uppercase: \(uuidB.uppercased())
OpenCode: ses_01jz9abc123
Malformed: 1111-2222 and ses_
"""
check("sessions: references are deduped + canonical",
      SessionDiscovery.references(in: discoveryNote)
          == [uuidA, uuidB, "ses_01jz9abc123"])
check("sessions: resumable excludes permanent + open",
      SessionDiscovery.resumableReferences(
          in: discoveryNote, openSessionIDs: ["ses_01jz9abc123"]
      ) == [uuidB])

let discoveryTemp = FileManager.default.temporaryDirectory
    .appendingPathComponent("taskdeck-session-discovery-\(UUID().uuidString)")
let teamAProjects = discoveryTemp.appendingPathComponent("team-a/projects")
let teamBProjects = discoveryTemp.appendingPathComponent("team-b/projects")
let projectA = teamAProjects.appendingPathComponent("project-a")
let projectB = teamBProjects.appendingPathComponent("project-b")
try? FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(
    at: projectB.appendingPathComponent(uuidB), withIntermediateDirectories: true
)
try? FileManager.default.createDirectory(
    at: projectB.appendingPathComponent(uuidA), withIntermediateDirectories: true
)
try? Data("{}".utf8).write(to: projectA.appendingPathComponent("\(uuidA).jsonl"))
let discoveredTeams = SessionDiscovery.resolveTeams(
    sessionIDs: [uuidA, uuidB, "ffffffff-ffff-ffff-ffff-ffffffffffff"],
    roots: [
        .init(team: "team-a", projects: teamAProjects),
        .init(team: "team-b", projects: teamBProjects),
    ]
)
check("sessions: batch resolver finds jsonl + preserves team priority",
      discoveredTeams[uuidA] == "team-a")
check("sessions: batch resolver finds directory record", discoveredTeams[uuidB] == "team-b")
check("sessions: unresolved id omitted", discoveredTeams.count == 2)

// A transcript's filesystem mtime can move without any new conversation
// event. Status fallback must use the latest top-level JSONL timestamp.
let transcriptURL = projectA.appendingPathComponent("legacy-status.jsonl")
let embeddedTimestamp = "2026-07-23T05:11:48.151Z"
let eventLine = #"{"type":"system","subtype":"turn_duration","timestamp":"\#(embeddedTimestamp)"}"#
let nestedFakeTimestamp = #"{"type":"metadata","payload":{"timestamp":"2099-01-01T00:00:00.000Z"}}"#
let largeUntimestampedMetadata = try! JSONSerialization.data(withJSONObject: [
    "type": "metadata",
    "payload": String(repeating: "x", count: 70_000),
])
var transcriptData = Data(eventLine.utf8)
transcriptData.append(Data("\n".utf8))
transcriptData.append(Data(nestedFakeTimestamp.utf8))
transcriptData.append(Data("\n".utf8))
transcriptData.append(largeUntimestampedMetadata)
transcriptData.append(Data("\n{not-json\n".utf8))
try? transcriptData.write(to: transcriptURL)
let touchedAt = Date(timeIntervalSince1970: 1_785_387_600)
try? FileManager.default.setAttributes(
    [.modificationDate: touchedAt], ofItemAtPath: transcriptURL.path
)
let timestampParser = ISO8601DateFormatter()
timestampParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let expectedEventAt = timestampParser.date(from: embeddedTimestamp)!
let parsedEventAt = SessionDiscovery.transcriptEventTimestamp(transcriptURL)
check("transcript status: embedded event beats a touched filesystem mtime",
      parsedEventAt.map { abs($0.timeIntervalSince(expectedEventAt)) < 0.001 } == true)
check("transcript status: nested timestamp is not an event",
      parsedEventAt.map { abs($0.timeIntervalSince(expectedEventAt)) < 0.001 } == true)
check("transcript status: reverse scan crosses large timestamp-free tail",
      parsedEventAt != nil)
let fallbackNow = expectedEventAt.addingTimeInterval(8 * 24 * 3600)
check("transcript status: expired embedded event yields no signal",
      SessionDiscovery.transcriptSignal(
          eventTimestamp: parsedEventAt, now: fallbackNow,
          signalWindow: 7 * 24 * 3600, runningWindow: 600
      ) == nil)
check("transcript status: genuinely recent event is running",
      SessionDiscovery.transcriptSignal(
          eventTimestamp: fallbackNow.addingTimeInterval(-60), now: fallbackNow,
          signalWindow: 7 * 24 * 3600, runningWindow: 600
      )?.state == "running")
check("transcript status: quiet recent event is waiting",
      SessionDiscovery.transcriptSignal(
          eventTimestamp: fallbackNow.addingTimeInterval(-1200), now: fallbackNow,
          signalWindow: 7 * 24 * 3600, runningWindow: 600
      )?.state == "waiting")

let sidecarURL = projectA.appendingPathComponent("sidecar-only")
let subagentsURL = sidecarURL.appendingPathComponent("subagents")
try? FileManager.default.createDirectory(at: subagentsURL, withIntermediateDirectories: true)
try? Data(eventLine.utf8).write(to: subagentsURL.appendingPathComponent("agent-a.jsonl"))
check("transcript status: auxiliary sidecar cannot drive task grouping",
      SessionDiscovery.transcriptEventTimestamp(sidecarURL) == nil)
try? FileManager.default.removeItem(at: discoveryTemp)

// MARK: Claude native background-task transcript lifecycle

let bgStartA = #"{"toolUseResult":{"backgroundTaskId":"bg-a"}}"#
let bgStartB = #"{"toolUseResult":{"backgroundTaskId":"bg-b"}}"#
let bgCompleteA = #"{"origin":{"kind":"task-notification"},"message":{"content":"<task-notification><task-id>bg-a</task-id><status>completed</status></task-notification>"}}"#
let bgFailedB = #"{"origin":{"kind":"task-notification"},"message":{"content":"<task-notification><task-id>bg-b</task-id><status>failed</status></task-notification>"}}"#
var bgAccumulator = BackgroundTaskAccumulator()
bgAccumulator.consume(jsonLine: bgStartA)
bgAccumulator.consume(jsonLine: bgStartB)
check("background: two native starts are active",
      bgAccumulator.activeTaskIDs == ["bg-a", "bg-b"])
bgAccumulator.consume(jsonLine: bgCompleteA)
bgAccumulator.consume(jsonLine: bgCompleteA) // duplicate notifications are idempotent
check("background: terminal notification removes + dedupes",
      bgAccumulator.activeTaskIDs == ["bg-b"])
bgAccumulator.consume(jsonLine: "{not json")
check("background: malformed transcript row is ignored",
      bgAccumulator.activeTaskIDs == ["bg-b"])
bgAccumulator.consume(jsonLine: bgFailedB)
check("background: failed is terminal", bgAccumulator.activeTaskIDs.isEmpty)
check("background: static JSONL reducer handles stopped",
      BackgroundActivity.activeTaskIDs(inJSONLines: [
          bgStartA,
          #"{"origin":{"kind":"task-notification"},"message":{"content":"<task-notification><task-id>bg-a</task-id><status>stopped</status></task-notification>"}}"#,
      ].joined(separator: "\n")).isEmpty)
check("background: queue-operation completion is terminal",
      BackgroundActivity.activeTaskIDs(inJSONLines: [
          bgStartA,
          #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification><task-id>bg-a</task-id><status>completed</status></task-notification>"}"#,
      ].joined(separator: "\n")).isEmpty)
check("background: queued-command attachment completion is terminal",
      BackgroundActivity.activeTaskIDs(inJSONLines: [
          bgStartA,
          #"{"type":"attachment","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification><task-id>bg-a</task-id><status>failed</status></task-notification>"}}"#,
      ].joined(separator: "\n")).isEmpty)
check("background: TaskStop result is terminal",
      BackgroundActivity.activeTaskIDs(inJSONLines: [
          bgStartA,
          #"{"toolUseResult":{"message":"Successfully stopped task: bg-a (command)","task_id":"bg-a","task_type":"local_bash"}}"#,
      ].joined(separator: "\n")).isEmpty)
check("background: killed notification is terminal",
      BackgroundActivity.activeTaskIDs(inJSONLines: [
          bgStartA,
          #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification><task-id>bg-a</task-id><status>killed</status></task-notification>"}"#,
      ].joined(separator: "\n")).isEmpty)
check("background: pasted notification XML is not treated as lifecycle",
      BackgroundActivity.activeTaskIDs(inJSONLines: [
          bgStartA,
          #"{"type":"user","message":{"content":"Example: <task-notification><task-id>bg-a</task-id><status>completed</status></task-notification>"}}"#,
      ].joined(separator: "\n")) == ["bg-a"])

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
check("grp: waiting → fresh unacked AI stop → 等你",
      grp(group: "waiting", [sig("waiting", agoSec: 30, acked: false)]) == .needsYou)
check("grp: waiting remains sticky after current stop is acknowledged",
      grp(group: "waiting", [sig("waiting", agoSec: 30, acked: true)]) == .waitingExt)
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

// MARK: acknowledgement retention — transcript-only fallback sessions

let ackWindow: TimeInterval = 7 * 24 * 3600
let fallbackSID = "transcript-only"
let expiredSID = "expired"
let fallbackTS = gNow.addingTimeInterval(-1800)
let retainedAcks = AIStatusAcknowledgementRules.prune(
    [
        fallbackSID: fallbackTS,
        expiredSID: gNow.addingTimeInterval(-ackWindow - 1),
    ],
    now: gNow,
    signalWindow: ackWindow
)
check("ack: transcript fallback survives hook-less refresh",
      retainedAcks[fallbackSID] == fallbackTS)
check("ack: entries older than signal window are pruned",
      retainedAcks[expiredSID] == nil)
check("ack: retained fallback keeps manual 已讀 stable",
      grp(group: "read", [
          SessionSignal(
              state: "waiting",
              ts: fallbackTS,
              acked: (retainedAcks[fallbackSID] ?? .distantPast) >= fallbackTS
          ),
      ]) == .read)
let genuinelyNewTS = fallbackTS.addingTimeInterval(60)
check("ack: genuinely newer AI signal resurfaces to 等你",
      grp(group: "read", [
          SessionSignal(
              state: "waiting",
              ts: genuinelyNewTS,
              acked: (retainedAcks[fallbackSID] ?? .distantPast) >= genuinelyNewTS
          ),
      ]) == .needsYou)

// MARK: priority alert — only the unseen mainline AI-running → needs-you edge

check("priority-alert: mainline AI completion triggers",
      PriorityAlertRules.shouldTrigger(
          isMainline: true, previous: .aiRunning, current: .needsYou,
          isCurrentlyViewed: false))
check("priority-alert: non-mainline completion stays quiet",
      !PriorityAlertRules.shouldTrigger(
          isMainline: false, previous: .aiRunning, current: .needsYou,
          isCurrentlyViewed: false))
check("priority-alert: needs-you reload does not replay",
      !PriorityAlertRules.shouldTrigger(
          isMainline: true, previous: .needsYou, current: .needsYou,
          isCurrentlyViewed: false))
check("priority-alert: tagging an already-waiting task does not trigger",
      !PriorityAlertRules.shouldTrigger(
          isMainline: true, previous: .needsYou, current: .needsYou,
          isCurrentlyViewed: false))
check("priority-alert: currently viewed completion stays quiet",
      !PriorityAlertRules.shouldTrigger(
          isMainline: true, previous: .aiRunning, current: .needsYou,
          isCurrentlyViewed: true))

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
