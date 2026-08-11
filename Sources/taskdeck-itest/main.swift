// Integration tests against an ISOLATED taskdeckd on a temp socket.
// Run: `swift run taskdeck-itest` (or via Scripts/test.sh).
//
// Safety: never touches the production daemon/socket/log. The daemon under
// test is spawned with TASKDECK_SOCKET + --log pointing into a private temp
// dir (under /tmp because sun_path is limited to ~104 bytes), and is shut
// down (then SIGKILLed) on exit. A global watchdog bounds the whole run.
import Darwin
import Foundation
import SwiftTerm
import TaskDeckCore

// A test client writes to daemon sockets that may close under it (that's the
// point of several scenarios) — without this the whole suite dies silently
// with exit 141 and, because piped stdout is block-buffered, zero output.
signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0) // line-buffered progress even if we crash

var failures = 0
func check(_ name: String, _ cond: @autoclosure () -> Bool) {
    if cond() { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

// ---- environment -----------------------------------------------------------

let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent()
let daemonBin = binDir.appendingPathComponent("taskdeckd").path
guard FileManager.default.isExecutableFile(atPath: daemonBin) else {
    print("FAIL taskdeckd binary not found next to itest (build first): \(daemonBin)")
    exit(1)
}

// Short root: sockaddr_un.sun_path caps the socket path around 104 bytes.
let tmpRoot = "/tmp/td-itest-\(getpid())"
try? FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
let sockPath = tmpRoot + "/d.sock"
let logPath = tmpRoot + "/d.log"
let workDir = tmpRoot + "/work"
try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

var daemons: [Process] = []

func cleanup() {
    for p in daemons where p.isRunning { p.terminate() }
    usleep(200_000)
    for p in daemons where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    // Fixed short prefix, never derived from $HOME.
    if tmpRoot.hasPrefix("/tmp/td-itest-") {
        try? FileManager.default.removeItem(atPath: tmpRoot)
    }
}

// Whole-run watchdog: a wedged daemon or a blocking recv must not hang the suite.
DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
    print("FAIL itest watchdog fired (90s) — aborting")
    cleanup()
    exit(3)
}

func spawnDaemon(socket: String, log: String) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: daemonBin)
    p.arguments = ["--socket", socket, "--log", log]
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "TASKDECK_SOCKET") // flags are authoritative here
    // Deliberately imitate a dev relaunch from a monochrome outer terminal.
    // New panes must not inherit presentation policy or terminal identity
    // from the process that happened to launch JamesDesk.
    env["TERM"] = "dumb"
    env["COLORTERM"] = ""
    env["NO_COLOR"] = "1"
    env["FORCE_COLOR"] = "1"
    env["CLICOLOR"] = "0"
    env["CLICOLOR_FORCE"] = "1"
    env["NODE_DISABLE_COLORS"] = "1"
    env["CI"] = "true"
    env["COLORFGBG"] = "15;0"
    env["TERM_PROGRAM"] = "OuterTerminal"
    env["TERM_PROGRAM_VERSION"] = "99"
    env["TERM_SESSION_ID"] = "outer-session"
    env["ITERM_SESSION_ID"] = "outer-iterm-session"
    env["LC_TERMINAL"] = "OuterTerminal"
    env["LC_TERMINAL_VERSION"] = "99"
    env["TMUX"] = "/tmp/outer-tmux,1,0"
    env["TMUX_PANE"] = "%1"
    env["STY"] = "outer-screen"
    env["WINDOW"] = "1"
    p.environment = env
    try? p.run()
    daemons.append(p)
    return p
}

func connect(_ path: String, within seconds: Double) -> BlockingConn? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let c = BlockingConn(path: path) { return c }
        usleep(50_000)
    }
    return nil
}

@discardableResult
func req(_ conn: BlockingConn, _ type: String, _ mutate: (inout WireMessage) -> Void = { _ in }) -> WireMessage? {
    var m = WireMessage(type: type)
    mutate(&m)
    return conn.request(m)
}

func readable(_ conn: BlockingConn, within milliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: conn.fd, events: Int16(POLLIN), revents: 0)
    while true {
        let result = poll(&descriptor, 1, milliseconds)
        if result >= 0 { return result > 0 && descriptor.revents & Int16(POLLIN) != 0 }
        if errno != EINTR { return false }
    }
}

func recv(_ conn: BlockingConn, within milliseconds: Int32) -> WireMessage? {
    readable(conn, within: milliseconds) ? conn.recv() : nil
}

func surfaceSnapshot(_ message: WireMessage?) -> TerminalSurfaceSnapshot? {
    guard let bytes = message?.surfaceSnapshotBytes else { return nil }
    return try? JSONDecoder().decode(TerminalSurfaceSnapshot.self, from: Data(bytes))
}

func surfacePatch(_ message: WireMessage?) -> TerminalSurfacePatch? {
    guard let bytes = message?.surfacePatchBytes else { return nil }
    return try? JSONDecoder().decode(TerminalSurfacePatch.self, from: Data(bytes))
}

final class ITestTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Cross-thread observations for a continuously draining native-surface
/// subscriber. The reader owns its SwiftTerm viewer; the control thread only
/// samples these scalar results while it keeps pinging the daemon.
final class SurfaceFloodObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _finished = false
    private var _dropped = false
    private var _continuity = true
    private var _markerSeen = false
    private var _sawRawOutput = false
    private var _publicationCount = 0
    private var _wireBytes = 0
    private var _largestFrame = 0

    func record(frameBytes: Int, publication: Bool = false,
                rawOutput: Bool = false) {
        lock.lock()
        _wireBytes += frameBytes
        _largestFrame = max(_largestFrame, frameBytes)
        if publication { _publicationCount += 1 }
        if rawOutput { _sawRawOutput = true }
        lock.unlock()
    }

    func markContinuityFailure() {
        lock.lock(); _continuity = false; lock.unlock()
    }

    func markMarkerSeen() {
        lock.lock(); _markerSeen = true; lock.unlock()
    }

    func finish(dropped: Bool) {
        lock.lock()
        _dropped = dropped
        _finished = true
        lock.unlock()
    }

    var finished: Bool {
        lock.lock(); defer { lock.unlock() }
        return _finished
    }

    func snapshot() -> (finished: Bool, dropped: Bool, continuity: Bool,
                        markerSeen: Bool, sawRawOutput: Bool,
                        publicationCount: Int, wireBytes: Int,
                        largestFrame: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_finished, _dropped, _continuity, _markerSeen, _sawRawOutput,
                _publicationCount, _wireBytes, _largestFrame)
    }
}

func visibleText(_ terminal: Terminal) -> String {
    let dimensions = terminal.getDims()
    var result = ""
    for row in 0..<dimensions.rows {
        for column in 0..<dimensions.cols {
            guard let character = terminal.getCharacter(col: column, row: row),
                  character != Character("\0") else {
                result.append(" ")
                continue
            }
            result.append(character)
        }
        result.append("\n")
    }
    return result
}

func attributes(of marker: String, in terminal: Terminal) -> [Attribute] {
    let dimensions = terminal.getDims()
    var matches: [Attribute] = []
    for row in 0..<dimensions.rows {
        var line = ""
        for column in 0..<dimensions.cols {
            let character = terminal.getCharacter(col: column, row: row) ?? Character("\0")
            line.append(character == Character("\0") ? " " : character)
        }
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let range = line.range(of: marker, range: searchStart..<line.endIndex) {
            let column = line.distance(from: line.startIndex, to: range.lowerBound)
            if let attribute = terminal.getCharData(col: column, row: row)?.attribute {
                matches.append(attribute)
            }
            searchStart = range.upperBound
        }
    }
    return matches
}

/// Children of `pid` that are dead-but-unreaped: macOS `ps` shows them with a
/// parenthesised comm like "(zsh)".
func defunctChildren(of pid: Int32) -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "ppid=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    return out.split(separator: "\n").filter {
        let cols = $0.split(separator: " ", maxSplits: 1)
        return cols.count == 2 && cols[0] == "\(pid)" && cols[1].hasPrefix("(")
    }.count
}

func liveChildren(of pid: Int32) -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "ppid=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    return out.split(separator: "\n").filter {
        let cols = $0.split(separator: " ", maxSplits: 1)
        return cols.count == 2 && cols[0] == "\(pid)" && !cols[1].hasPrefix("(")
    }.count
}

// ---- boot -------------------------------------------------------------------

let daemon = spawnDaemon(socket: sockPath, log: logPath)
guard let conn = connect(sockPath, within: 5) else {
    print("FAIL isolated daemon did not come up on \(sockPath)")
    cleanup()
    exit(1)
}
check("boot: isolated daemon accepts connections", true)
check("boot: production socket untouched", sockPath != Wire.socketPath() || ProcessInfo.processInfo.environment["TASKDECK_SOCKET"] == nil)

check("ping → pong", req(conn, "ping")?.type == "pong")

let hello = req(conn, "hello") { $0.version = Wire.version }
check("hello: replies with protocol version", hello?.type == "hello" && hello?.version == Wire.version)

// ---- pane lifecycle ----------------------------------------------------------

// Spawn a pane running a plain sh (fast, no user rc), have it print a marker.
var newReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "spec-1"
    $0.title = "t"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "printf 'TASKDECK-ENV:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\\n' "
        + "\"$TERM\" \"$COLORTERM\" \"$TERM_PROGRAM\" "
        + "\"${NO_COLOR-unset}\" \"${FORCE_COLOR-unset}\" "
        + "\"${CLICOLOR-unset}\" \"${CLICOLOR_FORCE-unset}\" "
        + "\"${NODE_DISABLE_COLORS-unset}\" \"${CI-unset}\" "
        + "\"${COLORFGBG-unset}\" \"${TERM_PROGRAM_VERSION-unset}\" "
        + "\"${LC_TERMINAL-unset}\" \"${TERM_SESSION_ID-unset}\" "
        + "\"${ITERM_SESSION_ID-unset}\" \"${LC_TERMINAL_VERSION-unset}\" "
        + "\"${TMUX-unset}\" "
        + "\"${TMUX_PANE-unset}\" \"${STY-unset}\" \"${WINDOW-unset}\"; "
        + "printf 'itest-marker-%s\\n' ok"
}
let paneID = newReply?.paneID ?? ""
check("newPane: ok + paneID", newReply?.type == "ok" && !paneID.isEmpty)

// Subscribe on a second connection and collect replay + live output.
func collectOutput(paneID: String, until marker: String, within seconds: Double) -> Bool {
    guard let c2 = BlockingConn(path: sockPath) else { return false }
    var sub = WireMessage(type: "subscribe")
    sub.paneID = paneID
    sub.id = UUID().uuidString
    c2.send(sub)
    var acc = [UInt8]()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard let m = c2.recv() else { return false }
        if let b = m.dataBytes { acc.append(contentsOf: b) }
        if let s = String(bytes: acc, encoding: .utf8), s.contains(marker) { return true }
    }
    return false
}
check("pane output: marker seen via replay/stream",
      collectOutput(paneID: paneID, until: "itest-marker-ok", within: 6))

if let envConn = BlockingConn(path: sockPath) {
    var sub = WireMessage(type: "subscribe")
    sub.paneID = paneID
    let replay = envConn.request(sub)
    let text = replay?.dataBytes.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    let isolatedValues = Array(repeating: "unset", count: 16).joined(separator: ":")
    check("pane env: launcher terminal policy and identity are isolated",
          text.contains(
            "TASKDECK-ENV:xterm-256color:truecolor:JamesDesk:"
            + isolatedValues))
} else {
    check("pane env: launcher terminal policy and identity are isolated", false)
}

// Sanitization removes only inherited launcher policy. A pane declaration is
// an explicit user choice and is applied afterwards, including for a key that
// would otherwise be scrubbed.
let explicitEnvPane = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "explicit-terminal-env"
    $0.title = "explicit-terminal-env"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.env = ["NO_COLOR": "explicit", "TERM_PROGRAM": "ConfiguredTerminal"]
    $0.command = "printf 'EXPLICIT-ENV:%s:%s\\n' \"$NO_COLOR\" \"$TERM_PROGRAM\"; "
        + "printf 'EXPLICIT-ENV-%s\\n' DONE"
}
let explicitEnvPaneID = explicitEnvPane?.paneID ?? ""
check("pane env: explicit override pane created",
      explicitEnvPane?.type == "ok" && !explicitEnvPaneID.isEmpty)
check("pane env: explicit override output reached daemon",
      collectOutput(paneID: explicitEnvPaneID,
                    until: "EXPLICIT-ENV-DONE", within: 6))
if let explicitConn = BlockingConn(path: sockPath) {
    var sub = WireMessage(type: "subscribe")
    sub.paneID = explicitEnvPaneID
    let replay = explicitConn.request(sub)
    let text = replay?.dataBytes.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    check("pane env: explicit per-pane policy wins after isolation",
          text.contains("EXPLICIT-ENV:explicit:ConfiguredTerminal"))
} else {
    check("pane env: explicit per-pane policy wins after isolation", false)
}
if !explicitEnvPaneID.isEmpty {
    _ = req(conn, "remove") { $0.paneID = explicitEnvPaneID }
}

// The application maps Shift+Enter to LF (Claude Code's Ctrl+J newline input).
// Verify the wire and PTY path preserve that byte without translating it to CR.
let shiftReturnPane = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "shift-return-input"
    $0.title = "shift-return-input"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "stty raw -echo; hex=$(dd bs=1 count=1 2>/dev/null "
        + "| hexdump -ve '1/1 \"%02x\"'); stty sane; "
        + "printf '\\r\\nSHIFT-RETURN:%s\\r\\n' \"$hex\""
}
let shiftReturnPaneID = shiftReturnPane?.paneID ?? ""
check("terminal input: controlled PTY pane created",
      shiftReturnPane?.type == "ok" && !shiftReturnPaneID.isEmpty)
usleep(400_000)
var shiftReturnInput = WireMessage(type: "input")
shiftReturnInput.paneID = shiftReturnPaneID
shiftReturnInput.setData([0x0a])
conn.send(shiftReturnInput)
check("terminal input: Shift+Return LF survives socket and PTY unchanged",
      collectOutput(paneID: shiftReturnPaneID,
                    until: "SHIFT-RETURN:0a", within: 6))
if !shiftReturnPaneID.isEmpty {
    _ = req(conn, "remove") { $0.paneID = shiftReturnPaneID }
}

// ---- canonical terminal surface -------------------------------------------

// Negotiation failure is explicit and does not poison the connection: a new
// GUI can immediately fall back to the unchanged raw subscribe/replay path.
if let fallbackConn = BlockingConn(path: sockPath) {
    var unsupported = WireMessage(type: "subscribeSurface")
    unsupported.paneID = paneID
    unsupported.surfaceClientID = "fallback-view"
    unsupported.surfaceVersion = 0
    let unsupportedReply = fallbackConn.request(unsupported)
    check("surface fallback: unsupported version is explicit",
          unsupportedReply?.type == "error")
    var legacy = WireMessage(type: "subscribe")
    legacy.paneID = paneID
    let legacyReply = fallbackConn.request(legacy)
    check("surface fallback: same connection can use raw replay",
          legacyReply?.type == "replay" && legacyReply?.dataBytes != nil)
} else {
    check("surface fallback: test client connects", false)
}

// Surface v1 intentionally carries text/cell state only. A forced graphics
// protocol must never appear to negotiate successfully while silently losing
// the image: disable canonical export for that pane and preserve raw replay.
let imagePaneReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-image-fallback"
    $0.title = "surface-image-fallback"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "sleep 0.2; printf '\\033]1337;File=inline=1:iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=\\a'; printf '\\nIMAGE-FALLBACK-%s\\n' READY"
}
let imagePaneID = imagePaneReply?.paneID ?? ""
check("surface image fallback: pane created",
      imagePaneReply?.type == "ok" && !imagePaneID.isEmpty)
check("surface image fallback: graphics sequence parsed",
      collectOutput(paneID: imagePaneID,
                    until: "IMAGE-FALLBACK-READY", within: 6))
if let imageConn = BlockingConn(path: sockPath) {
    var native = WireMessage(type: "subscribeSurface")
    native.paneID = imagePaneID
    native.surfaceClientID = "image-fallback-view"
    native.surfaceVersion = Wire.remoteSurfaceVersion
    let nativeReply = imageConn.request(native)
    check("surface image fallback: native negotiation fails explicitly",
          nativeReply?.type == "error")

    var raw = WireMessage(type: "subscribe")
    raw.paneID = imagePaneID
    let rawReply = imageConn.request(raw)
    let rawText = rawReply?.dataBytes.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    check("surface image fallback: same socket retains raw replay",
          rawReply?.type == "replay" && rawText.contains("IMAGE-FALLBACK-READY"))
} else {
    check("surface image fallback: test client connects", false)
}
if !imagePaneID.isEmpty { _ = req(conn, "remove") { $0.paneID = imagePaneID } }

let surfacePaneReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-basic"
    $0.title = "surface-basic"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    // zsh/iTerm shell integration emits these OSC 1337 metadata records at
    // every prompt. They carry no rendered content and must not be mistaken
    // for an inline image. Keep a colored marker beside them so this catches
    // both an accidental raw downgrade and attribute loss across the native
    // snapshot wire boundary.
    $0.command = "printf '\\033]1337;RemoteHost=test@host\\a"
        + "\\033]1337;CurrentDir=/tmp\\a"
        + "\\033]1337;ShellIntegrationVersion=1;shell=sh\\a"
        + "\\033[38;5;196mSURFACE-COLOR\\033[0m\\nSURFACE-PRE\\n'"
}
let surfacePaneID = surfacePaneReply?.paneID ?? ""
check("surface: controlled pane created",
      surfacePaneReply?.type == "ok" && !surfacePaneID.isEmpty)
check("surface: pre-snapshot output reached daemon",
      collectOutput(paneID: surfacePaneID, until: "SURFACE-PRE", within: 6))

if let surfaceConn = BlockingConn(path: sockPath) {
    var subscribe = WireMessage(type: "subscribeSurface")
    subscribe.paneID = surfacePaneID
    subscribe.surfaceClientID = "surface-view"
    subscribe.surfaceVersion = Wire.remoteSurfaceVersion
    let firstMessage = surfaceConn.request(subscribe)
    let firstSnapshot = surfaceSnapshot(firstMessage)
    check("surface: subscribe returns native snapshot",
          firstMessage?.type == "surfaceSnapshot"
          && firstMessage?.surfaceVersion == Wire.remoteSurfaceVersion
          && firstMessage?.surfaceRevision == firstSnapshot?.revision
          && firstMessage?.data == nil
          && firstMessage?.paneEpoch?.isEmpty == false)

    let viewerDelegate = ITestTerminalDelegate()
    let viewer = Terminal(delegate: viewerDelegate)
    var applySucceeded = false
    if let firstSnapshot {
        applySucceeded = (try? viewer.applySurfaceSnapshot(firstSnapshot)) != nil
    }
    check("surface: SwiftTerm applies daemon snapshot", applySucceeded)
    check("surface: snapshot contains pre-attach terminal state",
          visibleText(viewer).contains("SURFACE-PRE"))
    check("surface: shell metadata stays native and preserves ANSI color",
          attributes(of: "SURFACE-COLOR", in: viewer).contains {
              $0.fg == .ansi256(code: 196)
          })
    check("surface: authority does not overwrite the viewer palette",
          firstSnapshot?.state.ansiPaletteOverride == nil
          && firstSnapshot?.state.foregroundColorOverride == nil
          && firstSnapshot?.state.backgroundColorOverride == nil)

    var liveInput = WireMessage(type: "input")
    liveInput.paneID = surfacePaneID
    liveInput.setData(Array(
        ("printf '\\033]1337;RemoteHost=live@host\\a"
         + "\\033]1337;CurrentDir=/tmp/live\\a"
         + "\\033]1337;ShellIntegrationVersion=2;shell=sh\\a"
         + "\\033[38;2;17;34;51m"
         + "\\123\\125\\122\\106\\101\\103\\105\\055\\114\\111\\126\\105"
         + "\\033[0m\\n'\n").utf8))
    conn.send(liveInput)

    var liveApplied = false
    var continuityOK = true
    var sawRawOutput = false
    let liveDeadline = Date().addingTimeInterval(6)
    while Date() < liveDeadline, let message = recv(surfaceConn, within: 500) {
        if message.type == "output" { sawRawOutput = true }
        do {
            if let patch = surfacePatch(message) {
                continuityOK = continuityOK
                    && patch.epoch == viewer.appliedRemoteSurfaceEpoch
                    && patch.baseRevision == viewer.appliedRemoteSurfaceRevision
                    && message.surfaceBaseRevision == patch.baseRevision
                    && message.surfaceRevision == patch.revision
                try viewer.applySurfacePatch(patch)
            } else if let snapshot = surfaceSnapshot(message) {
                try viewer.applySurfaceSnapshot(snapshot)
            }
        } catch {
            continuityOK = false
        }
        if visibleText(viewer).contains("SURFACE-LIVE") {
            liveApplied = true
            break
        }
    }
    check("surface: ordered patch applies to exact snapshot baseline",
          liveApplied && continuityOK)
    check("surface: live shell metadata keeps true color native",
          attributes(of: "SURFACE-LIVE", in: viewer).contains {
              $0.fg == .trueColor(red: 17, green: 34, blue: 51)
          })
    check("surface: native subscriber never receives raw output", !sawRawOutput)

    var patchInput = WireMessage(type: "input")
    patchInput.paneID = surfacePaneID
    patchInput.setData(Array(
        ("printf '\\033[3;38;5;196;48;5;22m"
         + "\\120\\101\\124\\103\\110\\055\\103\\117\\114\\117\\122"
         + "\\033[0m\\n'\n").utf8))
    conn.send(patchInput)

    var coloredPatchApplied = false
    var coloredUpdateWasPatch = false
    let patchDeadline = Date().addingTimeInterval(6)
    while Date() < patchDeadline, let message = recv(surfaceConn, within: 500) {
        do {
            if let patch = surfacePatch(message) {
                coloredUpdateWasPatch = true
                continuityOK = continuityOK
                    && patch.epoch == viewer.appliedRemoteSurfaceEpoch
                    && patch.baseRevision == viewer.appliedRemoteSurfaceRevision
                try viewer.applySurfacePatch(patch)
            } else if let snapshot = surfaceSnapshot(message) {
                try viewer.applySurfaceSnapshot(snapshot)
            }
        } catch {
            continuityOK = false
        }
        coloredPatchApplied = attributes(of: "PATCH-COLOR", in: viewer).contains {
            $0.fg == .ansi256(code: 196)
                && $0.bg == .ansi256(code: 22)
                && $0.style.contains(.italic)
        }
        if coloredPatchApplied { break }
    }
    check("surface: ANSI foreground/background/style survive a real patch",
          coloredPatchApplied && coloredUpdateWasPatch && continuityOK)

    var resync = WireMessage(type: "surfaceResync")
    resync.paneID = surfacePaneID
    resync.surfaceClientID = "surface-view"
    resync.surfaceVersion = Wire.remoteSurfaceVersion
    let resyncReply = surfaceConn.request(resync)
    let resyncSnapshot = surfaceSnapshot(resyncReply)
    check("surface: explicit resync returns a full current snapshot",
          resyncReply?.type == "surfaceSnapshot"
          && resyncSnapshot?.revision == resyncReply?.surfaceRevision
          && resyncSnapshot.map { (try? viewer.applySurfaceSnapshot($0)) != nil } == true
          && visibleText(viewer).contains("SURFACE-LIVE"))

    // Render epoch is allowed to reset on RIS, but paneEpoch/resize ownership
    // describe the still-live PTY and must remain valid.
    let paneEpoch = firstMessage?.paneEpoch ?? ""
    var acquire = WireMessage(type: "acquireResizeLease")
    acquire.paneID = surfacePaneID
    acquire.paneEpoch = paneEpoch
    acquire.surfaceClientID = "surface-view"
    let lease = surfaceConn.request(acquire)
    let oldRenderEpoch = viewer.appliedRemoteSurfaceEpoch

    var resetInput = WireMessage(type: "input")
    resetInput.paneID = surfacePaneID
    resetInput.setData(Array("printf '\\033cRIS-DONE\\n'\n".utf8))
    conn.send(resetInput)

    var resetSnapshot: TerminalSurfaceSnapshot?
    var resetReceiveTimeout = timeval(tv_sec: 6, tv_usec: 0)
    _ = setsockopt(
        surfaceConn.fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &resetReceiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    let resetDeadline = Date().addingTimeInterval(6)
    var resetWireRevision: UInt64?
    while Date() < resetDeadline, let message = surfaceConn.recv() {
        if let snapshot = surfaceSnapshot(message), snapshot.epoch != oldRenderEpoch {
            resetSnapshot = snapshot
            resetWireRevision = message.surfaceRevision
            break
        }
    }
    check("surface: RIS advances render epoch and forces snapshot",
          resetSnapshot != nil
          && resetSnapshot?.epoch != oldRenderEpoch
          && (resetSnapshot?.revision ?? 0) > 0
          && resetWireRevision == resetSnapshot?.revision)

    var leasedResize = WireMessage(type: "surfaceResize")
    leasedResize.paneID = surfacePaneID
    leasedResize.paneEpoch = paneEpoch
    leasedResize.surfaceClientID = "surface-view"
    leasedResize.resizeLeaseToken = lease?.resizeLeaseToken
    leasedResize.resizeLeaseGeneration = lease?.resizeLeaseGeneration
    leasedResize.cols = 77
    leasedResize.rows = 21
    check("surface: RIS does not invalidate pane resize lease",
          surfaceConn.request(leasedResize)?.type == "ok")
    let resizedAfterRIS = req(conn, "list")?.panes?.first { $0.id == surfacePaneID }
    check("surface: post-RIS leased dimensions applied",
          resizedAfterRIS?.cols == 77 && resizedAfterRIS?.rows == 21)

    var release = WireMessage(type: "releaseResizeLease")
    release.paneID = surfacePaneID
    release.paneEpoch = paneEpoch
    release.surfaceClientID = "surface-view"
    release.resizeLeaseToken = lease?.resizeLeaseToken
    release.resizeLeaseGeneration = lease?.resizeLeaseGeneration
    check("surface: resize lease releases after RIS",
          surfaceConn.request(release)?.type == "ok")
} else {
    check("surface: test client connects", false)
}
if !surfacePaneID.isEmpty { _ = req(conn, "remove") { $0.paneID = surfacePaneID } }

// A subscriber must never receive a half-rendered DEC 2026 frame. Explicit
// end releases it; a missing end is bounded by SwiftTerm's one-second timer.
let syncPaneReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-sync-explicit"
    $0.title = "surface-sync-explicit"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "printf '\\033[?2026hSYNC-PART'; sleep 0.5; printf 'IAL\\033[?2026lSYNC-END\\n'"
}
let syncPaneID = syncPaneReply?.paneID ?? ""
check("surface sync: explicit-end pane created", !syncPaneID.isEmpty)
check("surface sync: partial bytes reached raw compatibility ring",
      collectOutput(paneID: syncPaneID, until: "SYNC-PART", within: 6))
if let syncConn = BlockingConn(path: sockPath) {
    var subscribe = WireMessage(type: "subscribeSurface")
    subscribe.id = UUID().uuidString
    subscribe.paneID = syncPaneID
    subscribe.surfaceClientID = "sync-explicit-view"
    subscribe.surfaceVersion = Wire.remoteSurfaceVersion
    let started = Date()
    syncConn.send(subscribe)
    check("surface sync: no half-frame snapshot while DEC 2026 active",
          !readable(syncConn, within: 150))
    var explicitReceive = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(
        syncConn.fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &explicitReceive,
        socklen_t(MemoryLayout<timeval>.size)
    )
    var reply: WireMessage?
    let replyDeadline = Date().addingTimeInterval(2)
    while Date() < replyDeadline, let message = syncConn.recv() {
        if message.id == subscribe.id {
            reply = message
            break
        }
    }
    let snapshot = surfaceSnapshot(reply)
    let elapsed = Date().timeIntervalSince(started)
    let text = snapshot.map {
        $0.normalBuffer.lines.flatMap(\.runs).map(\.text).joined()
    } ?? ""
    check("surface sync: explicit end releases one complete snapshot",
          reply?.type == "surfaceSnapshot"
          && elapsed >= 0.15
          && text.contains("SYNC-PARTIAL")
          && text.contains("SYNC-END")
          && snapshot?.state.inputModes.synchronizedOutput == false)
} else {
    check("surface sync: explicit-end subscriber connects", false)
}
if !syncPaneID.isEmpty { _ = req(conn, "remove") { $0.paneID = syncPaneID } }

let timeoutPaneReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-sync-timeout"
    $0.title = "surface-sync-timeout"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "printf 'TIMEOUT-READY\\n'; read go; printf '\\033[?2026hTIMEOUT-PART-0'; sleep 0.2; printf -- '-1'; sleep 0.2; printf -- '-2'; sleep 0.9; printf -- '-LATE\\n'"
}
let timeoutPaneID = timeoutPaneReply?.paneID ?? ""
check("surface sync: timeout pane created", !timeoutPaneID.isEmpty)
var timeoutFrameBegan = false
if let rawObserver = BlockingConn(path: sockPath) {
    var rawSubscribe = WireMessage(type: "subscribe")
    rawSubscribe.paneID = timeoutPaneID
    let rawReplay = rawObserver.request(rawSubscribe)
    var rawBytes = rawReplay?.dataBytes ?? []
    var readySeen = String(bytes: rawBytes, encoding: .utf8)?.contains("TIMEOUT-READY") == true
    let readyDeadline = Date().addingTimeInterval(5)
    while !readySeen, Date() < readyDeadline {
        guard let message = recv(rawObserver, within: 200) else { continue }
        if let bytes = message.dataBytes { rawBytes.append(contentsOf: bytes) }
        readySeen = String(bytes: rawBytes, encoding: .utf8)?.contains("TIMEOUT-READY") == true
    }
    var begin = WireMessage(type: "input")
    begin.paneID = timeoutPaneID
    begin.setData(Array("go\n".utf8))
    conn.send(begin)
    let beginDeadline = Date().addingTimeInterval(3)
    while Date() < beginDeadline {
        guard let message = recv(rawObserver, within: 200) else { continue }
        if let bytes = message.dataBytes { rawBytes.append(contentsOf: bytes) }
        if String(bytes: rawBytes, encoding: .utf8)?.contains("TIMEOUT-PART-0") == true {
            timeoutFrameBegan = true
            break
        }
    }
}
check("surface sync: timeout frame began", timeoutFrameBegan)
if let timeoutConn = BlockingConn(path: sockPath) {
    var subscribe = WireMessage(type: "subscribeSurface")
    subscribe.id = UUID().uuidString
    subscribe.paneID = timeoutPaneID
    subscribe.surfaceClientID = "sync-timeout-view"
    subscribe.surfaceVersion = Wire.remoteSurfaceVersion
    let started = Date()
    timeoutConn.send(subscribe)
    check("surface sync: timeout path also withholds early snapshot",
          !readable(timeoutConn, within: 150))
    // Other panes may exit while this request is pending, and those socket-wide
    // events can legally precede the response. Consume until this request id;
    // direct recv also drains frames already buffered inside FrameCodec.Reader.
    var timeoutReceive = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(
        timeoutConn.fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeoutReceive,
        socklen_t(MemoryLayout<timeval>.size)
    )
    var reply: WireMessage?
    let replyDeadline = Date().addingTimeInterval(2)
    while Date() < replyDeadline, let message = timeoutConn.recv() {
        if message.id == subscribe.id {
            reply = message
            break
        }
    }
    let snapshot = surfaceSnapshot(reply)
    let elapsed = Date().timeIntervalSince(started)
    let snapshotText = snapshot.map {
        $0.normalBuffer.lines.flatMap(\.runs).map(\.text).joined()
    } ?? ""
    check("surface sync: one-second safety timeout releases accumulated frame",
          reply?.type == "surfaceSnapshot"
          && elapsed >= 0.5 && elapsed < 1.7
          && snapshotText.contains("TIMEOUT-PART-0-1-2")
          && snapshot?.state.inputModes.synchronizedOutput == false)

    let timeoutViewerDelegate = ITestTerminalDelegate()
    let timeoutViewer = Terminal(delegate: timeoutViewerDelegate)
    var timeoutContinuity = false
    if let snapshot, (try? timeoutViewer.applySurfaceSnapshot(snapshot)) != nil {
        let deadline = Date().addingTimeInterval(3)
        var liveReceive = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(
            timeoutConn.fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &liveReceive,
            socklen_t(MemoryLayout<timeval>.size)
        )
        while Date() < deadline, let message = timeoutConn.recv() {
            do {
                if let patch = surfacePatch(message) {
                    guard patch.baseRevision == timeoutViewer.appliedRemoteSurfaceRevision else {
                        throw NSError(domain: "itest", code: 1)
                    }
                    try timeoutViewer.applySurfacePatch(patch)
                } else if let replacement = surfaceSnapshot(message) {
                    try timeoutViewer.applySurfaceSnapshot(replacement)
                }
            } catch {
                break
            }
            if visibleText(timeoutViewer).contains("TIMEOUT-PART-0-1-2-LATE") {
                timeoutContinuity = true
                break
            }
        }
    }
    check("surface sync: output concurrent with timeout keeps patch continuity",
          timeoutContinuity)
} else {
    check("surface sync: timeout subscriber connects", false)
}
if !timeoutPaneID.isEmpty { _ = req(conn, "remove") { $0.paneID = timeoutPaneID } }

// The canonical parser is active even with zero viewers, so terminal queries
// cannot deadlock waiting for a GUI parser that may not exist.
let queryPaneReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-query-responder"
    $0.title = "surface-query-responder"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "old=$(stty -g); stty raw -echo min 0 time 20; printf '\\033[5n'; response=$(dd bs=1 count=4 2>/dev/null); stty \"$old\"; [ \"$response\" = \"$(printf '\\033[0n')\" ] && printf 'QUERY-OK\\n' || printf 'QUERY-BAD\\n'"
}
let queryPaneID = queryPaneReply?.paneID ?? ""
check("surface query: pane created with no viewer", !queryPaneID.isEmpty)
check("surface query: daemon parser answers host status request",
      collectOutput(paneID: queryPaneID, until: "QUERY-OK", within: 6))
if !queryPaneID.isEmpty { _ = req(conn, "remove") { $0.paneID = queryPaneID } }

// Semantic side effects are emitted once per connection even when that
// connection owns two views of the same pane; the raw compatibility socket
// receives only bytes.
let eventPaneReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-events"
    $0.title = "surface-events"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "printf 'EVENT-READY\\n'"
}
let eventPaneID = eventPaneReply?.paneID ?? ""
check("surface events: pane created", !eventPaneID.isEmpty)
check("surface events: pane ready",
      collectOutput(paneID: eventPaneID, until: "EVENT-READY", within: 6))
if let eventConn = BlockingConn(path: sockPath),
   let eventLegacyConn = BlockingConn(path: sockPath) {
    for clientID in ["event-view-a", "event-view-b"] {
        var subscribe = WireMessage(type: "subscribeSurface")
        subscribe.paneID = eventPaneID
        subscribe.surfaceClientID = clientID
        subscribe.surfaceVersion = Wire.remoteSurfaceVersion
        check("surface events: \(clientID) subscribed",
              eventConn.request(subscribe)?.type == "surfaceSnapshot")
    }
    var legacySubscribe = WireMessage(type: "subscribe")
    legacySubscribe.paneID = eventPaneID
    _ = eventLegacyConn.request(legacySubscribe)

    var trigger = WireMessage(type: "input")
    trigger.paneID = eventPaneID
    trigger.setData(Array("printf '\\a\\033]52;c;dGVzdA==\\a\\033]0;EVENT-TITLE\\a\\033]7;file:///tmp\\a\\033]777;notify;EVENT-N;EVENT-B\\a\\033]9;4;1;42\\aEVENT-DONE\\n'\n".utf8))
    conn.send(trigger)

    var eventCounts: [String: Int] = [:]
    var clipboard = ""
    let expectedEvents = Set([
        TerminalSurfaceEventKind.bell,
        TerminalSurfaceEventKind.clipboardCopy,
        TerminalSurfaceEventKind.title,
        TerminalSurfaceEventKind.cwd,
        TerminalSurfaceEventKind.notification,
        TerminalSurfaceEventKind.progress,
    ])
    let eventDeadline = Date().addingTimeInterval(6)
    while Date() < eventDeadline {
        guard let message = recv(eventConn, within: 500) else { continue }
        if message.type == "surfaceEvent", let kind = message.surfaceEvent {
            eventCounts[kind, default: 0] += 1
            if kind == TerminalSurfaceEventKind.clipboardCopy,
               let bytes = message.dataBytes {
                clipboard = String(bytes: bytes, encoding: .utf8) ?? ""
            }
        }
        if expectedEvents.allSatisfy({ eventCounts[$0] == 1 }) { break }
    }
    // Give an accidental per-view duplicate a chance to arrive.
    while let message = recv(eventConn, within: 200) {
        if message.type == "surfaceEvent", let kind = message.surfaceEvent {
            eventCounts[kind, default: 0] += 1
        }
    }
    check("surface events: six semantic kinds delivered once per socket",
          expectedEvents.allSatisfy { eventCounts[$0] == 1 })
    check("surface events: OSC 52 payload decoded once", clipboard == "test")

    var legacyBytes: [UInt8] = []
    var legacySawSemanticEvent = false
    let legacyDeadline = Date().addingTimeInterval(4)
    while Date() < legacyDeadline {
        guard let message = recv(eventLegacyConn, within: 500) else { continue }
        if message.type == "surfaceEvent" { legacySawSemanticEvent = true }
        if let bytes = message.dataBytes { legacyBytes.append(contentsOf: bytes) }
        if String(bytes: legacyBytes, encoding: .utf8)?.contains("EVENT-DONE") == true { break }
    }
    let legacyText = String(bytes: legacyBytes, encoding: .utf8) ?? "<non-utf8>"
    check("surface events: legacy viewer gets raw bytes only",
          !legacySawSemanticEvent
          && legacyText.contains("EVENT-DONE"))

    var unsubscribeA = WireMessage(type: "unsubscribeSurface")
    unsubscribeA.paneID = eventPaneID
    unsubscribeA.surfaceClientID = "event-view-a"
    check("surface events: removing one token keeps connection subscribed",
          eventConn.request(unsubscribeA)?.type == "ok")
    var remainingResync = WireMessage(type: "surfaceResync")
    remainingResync.paneID = eventPaneID
    remainingResync.surfaceClientID = "event-view-b"
    remainingResync.surfaceVersion = Wire.remoteSurfaceVersion
    check("surface events: remaining token stays subscribed",
          eventConn.request(remainingResync)?.type == "surfaceSnapshot")

    var unsubscribeB = WireMessage(type: "unsubscribeSurface")
    unsubscribeB.paneID = eventPaneID
    unsubscribeB.surfaceClientID = "event-view-b"
    check("surface events: last token detaches",
          eventConn.request(unsubscribeB)?.type == "ok")
    var thirdBell = WireMessage(type: "input")
    thirdBell.paneID = eventPaneID
    thirdBell.setData(Array("printf '\\aEVENT-THIRD\\n'\n".utf8))
    conn.send(thirdBell)
    var detachedRelevantMessage: WireMessage?
    let detachedDeadline = Date().addingTimeInterval(0.5)
    while Date() < detachedDeadline {
        guard let message = recv(eventConn, within: 100) else { continue }
        if message.paneID == eventPaneID,
           message.type == "surfaceEvent"
            || message.type == "surfacePatch"
            || message.type == "surfaceSnapshot" {
            detachedRelevantMessage = message
            break
        }
    }
    check("surface events: detached connection receives no patch or event",
          detachedRelevantMessage == nil)
} else {
    check("surface events: test clients connect", false)
}
if !eventPaneID.isEmpty { _ = req(conn, "remove") { $0.paneID = eventPaneID } }

// Additive resize lease: old `resize` remains compatible, while remote-surface
// clients can elect exactly one view to control the shared PTY dimensions.
let leaseOwnerConn = BlockingConn(path: sockPath)
let leaseContenderConn = BlockingConn(path: sockPath)
if let ownerConn = leaseOwnerConn, let contenderConn = leaseContenderConn {
    var sub = WireMessage(type: "subscribe")
    sub.paneID = paneID
    sub.id = UUID().uuidString
    ownerConn.send(sub)
    let replay = ownerConn.recv()
    let epoch = replay?.paneEpoch ?? ""
    check("resize lease: replay exposes pane epoch", !epoch.isEmpty)

    var acquire = WireMessage(type: "acquireResizeLease")
    acquire.paneID = paneID
    acquire.paneEpoch = epoch
    acquire.surfaceClientID = "owner-view"
    let grant = ownerConn.request(acquire)
    let token = grant?.resizeLeaseToken ?? ""
    let generation = grant?.resizeLeaseGeneration ?? 0
    check("resize lease: first surface granted",
          grant?.type == "resizeLease" && !token.isEmpty && generation > 0)

    var compete = WireMessage(type: "acquireResizeLease")
    compete.paneID = paneID
    compete.paneEpoch = epoch
    compete.surfaceClientID = "contender-view"
    check("resize lease: competing surface cannot steal",
          contenderConn.request(compete)?.type == "resizeLeaseBusy")

    var resize = WireMessage(type: "surfaceResize")
    resize.paneID = paneID
    resize.paneEpoch = epoch
    resize.surfaceClientID = "owner-view"
    resize.resizeLeaseToken = token
    resize.resizeLeaseGeneration = generation
    resize.cols = 73
    resize.rows = 19
    check("resize lease: owner resize accepted",
          ownerConn.request(resize)?.type == "ok")
    let resized = req(conn, "list")?.panes?.first { $0.id == paneID }
    check("resize lease: accepted dimensions applied",
          resized?.cols == 73 && resized?.rows == 19)

    resize.resizeLeaseToken = "stale-token"
    resize.cols = 64
    check("resize lease: stale credential rejected",
          ownerConn.request(resize)?.type == "error")
    let unchanged = req(conn, "list")?.panes?.first { $0.id == paneID }
    check("resize lease: rejected resize leaves dimensions unchanged",
          unchanged?.cols == 73 && unchanged?.rows == 19)

    var claim = compete
    claim.type = "claimResizeLease"
    let focusGrant = contenderConn.request(claim)
    check("resize lease: focused surface preempts immediately",
          focusGrant?.type == "resizeLease"
          && focusGrant?.resizeLeaseGeneration != generation)

    resize.resizeLeaseToken = token
    resize.resizeLeaseGeneration = generation
    check("resize lease: preempted owner is invalid immediately",
          ownerConn.request(resize)?.type == "error")

    var reclaim = acquire
    reclaim.type = "claimResizeLease"
    let reclaimed = ownerConn.request(reclaim)
    var ownerRelease = WireMessage(type: "releaseResizeLease")
    ownerRelease.paneID = paneID
    ownerRelease.paneEpoch = epoch
    ownerRelease.surfaceClientID = "owner-view"
    ownerRelease.resizeLeaseToken = reclaimed?.resizeLeaseToken
    ownerRelease.resizeLeaseGeneration = reclaimed?.resizeLeaseGeneration
    check("resize lease: refocused owner can reclaim + release",
          reclaimed?.type == "resizeLease"
          && ownerConn.request(ownerRelease)?.type == "ok")

    let takeover = contenderConn.request(compete)
    check("resize lease: released ownership is immediately available",
          takeover?.type == "resizeLease")

    if let takeoverToken = takeover?.resizeLeaseToken,
       let takeoverGeneration = takeover?.resizeLeaseGeneration {
        var release = WireMessage(type: "releaseResizeLease")
        release.paneID = paneID
        release.paneEpoch = epoch
        release.surfaceClientID = "contender-view"
        release.resizeLeaseToken = takeoverToken
        release.resizeLeaseGeneration = takeoverGeneration
        check("resize lease: owner can release", contenderConn.request(release)?.type == "ok")
    } else {
        check("resize lease: owner can release", false)
    }
} else {
    check("resize lease: test clients connect", false)
}

// The GUI's replay/live barrier relies on the daemon's socket ordering: the
// subscribe response contains the snapshot, and only later frames may contain
// output produced after that snapshot.
let orderPane = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "replay-order"
    $0.title = "replay-order"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "printf 'ORDER-PRE\\n'; read line; printf 'ORDER-LIVE\\n'"
}
let orderPaneID = orderPane?.paneID ?? ""
check("replay order: controlled pane created",
      orderPane?.type == "ok" && !orderPaneID.isEmpty)
check("replay order: pre-snapshot marker reached ring",
      collectOutput(paneID: orderPaneID, until: "ORDER-PRE", within: 6))
if let orderConn = BlockingConn(path: sockPath) {
    var sub = WireMessage(type: "subscribe")
    sub.paneID = orderPaneID
    sub.id = UUID().uuidString
    orderConn.send(sub)
    let replay = orderConn.recv()
    let replayText = replay?.dataBytes.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    check("replay order: replay response is first and contains snapshot",
          replay?.type == "replay" && replay?.id == sub.id && replayText.contains("ORDER-PRE"))

    fire("input") {
        $0.paneID = orderPaneID
        $0.setData(Array("continue\n".utf8))
    }
    var liveBytes: [UInt8] = []
    let orderDeadline = Date().addingTimeInterval(6)
    while Date() < orderDeadline {
        guard let message = orderConn.recv() else { break }
        if message.type == "output", let bytes = message.dataBytes {
            liveBytes.append(contentsOf: bytes)
        }
        if String(bytes: liveBytes, encoding: .utf8)?.contains("ORDER-LIVE") == true { break }
    }
    check("replay order: post-snapshot output arrives as later live frame",
          String(bytes: liveBytes, encoding: .utf8)?.contains("ORDER-LIVE") == true)
} else {
    check("replay order: subscriber connects", false)
}
if !orderPaneID.isEmpty { _ = req(conn, "remove") { $0.paneID = orderPaneID } }

// Hostile resize must not crash the daemon (UInt16 trap guard). resize is
// fire-and-forget (no reply), so send raw and verify liveness via ping.
func fire(_ type: String, _ mutate: (inout WireMessage) -> Void) {
    var m = WireMessage(type: type)
    mutate(&m)
    conn.send(m)
}
fire("resize") { $0.paneID = paneID; $0.cols = -1; $0.rows = -1 }
check("resize -1/-1: daemon survives (clamped)", req(conn, "ping")?.type == "pong")
fire("resize") { $0.paneID = paneID; $0.cols = 99999; $0.rows = 99999 }
check("resize 99999: daemon survives (clamped)", req(conn, "ping")?.type == "pong")

// ---- fd hygiene (FD_CLOEXEC) ---------------------------------------------
// Each pane child lists its own /dev/fd. Without close-on-exec on daemon fds,
// pane N inherits the log fd, lock fd, listener, conns and the previous N−1
// PTY masters — so the count GROWS with pane index. With the fix it's flat.

func fdCount(specID: String, marker: String) -> Int? {
    let r = req(conn, "newPane") {
        $0.taskID = "itest"
        $0.specID = specID
        $0.title = "fd"
        $0.cwd = workDir
        $0.shell = "/bin/sh"
        $0.cols = 80
        $0.rows = 24
        $0.command = "echo \(marker)-begin; ls /dev/fd; echo \(marker)-end"
    }
    guard let pid = r?.paneID, r?.type == "ok" else { return nil }
    guard let c2 = BlockingConn(path: sockPath) else { return nil }
    var sub = WireMessage(type: "subscribe")
    sub.paneID = pid
    sub.id = UUID().uuidString
    c2.send(sub)
    var acc = [UInt8]()
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        guard let m = c2.recv() else { break }
        if let b = m.dataBytes { acc.append(contentsOf: b) }
        guard let s = String(bytes: acc, encoding: .utf8) else { continue }
        if let begin = s.range(of: "\(marker)-begin"), let end = s.range(of: "\(marker)-end") {
            let body = s[begin.upperBound ..< end.lowerBound]
            // Count numeric fd entries (ls output; ignore prompt noise).
            let n = body.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" || $0 == "\r" })
                .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.count
            return n
        }
    }
    return nil
}

let fdA = fdCount(specID: "fd-A", marker: "fdchk1")
let fdB = fdCount(specID: "fd-B", marker: "fdchk2")
check("cloexec: pane sees its own fds only (≤5)", (fdA ?? 99) <= 5)
check("cloexec: fd count does not grow with pane index", fdA != nil && fdB != nil && fdB! <= fdA!)

// newPane is idempotent on (taskID, specID): a duplicate request (GUI racing
// its own reconciliation, double-click) adopts the live pane instead of
// spawning an invisible twin.
let dupA = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "dup-spec"
    $0.title = "dup"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "sleep 120"
}
let dupB = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "dup-spec"
    $0.title = "dup"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "sleep 120"
}
check("newPane dedupe: same (task,spec) adopts the live pane",
      dupA?.type == "ok" && dupB?.type == "ok"
      && dupA?.paneID != nil && dupA?.paneID == dupB?.paneID)
let dupList = req(conn, "list")
check("newPane dedupe: exactly one pane for the spec",
      dupList?.panes?.filter { $0.specID == "dup-spec" }.count == 1)
if let dupID = dupA?.paneID { _ = req(conn, "remove") { $0.paneID = dupID } }

// Invalid cwd must be rejected before fork, not silently run in /.
let badCwd = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "bad-cwd"
    $0.title = "x"
    $0.cwd = tmpRoot + "/definitely-missing"
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
}
check("newPane: invalid cwd → error reply", badCwd?.type == "error")

// Long-lived pane, then remove: child must be reaped (no defunct) and gone.
newReply = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "spec-2"
    $0.title = "sleeper"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "sleep 300"
}
let sleeper = newReply?.paneID ?? ""
check("newPane sleeper: ok", newReply?.type == "ok" && !sleeper.isEmpty)
usleep(600_000)
_ = req(conn, "remove") { $0.paneID = sleeper }
// SIGHUP → child exits; childExited reaps + closes fd (dying-dict fix).
// Other idle pane shells (marker/fd panes) stay alive by design; the leak
// signal is a DEFUNCT child lingering unreaped.
var reaped = false
for _ in 0 ..< 40 { // up to 4s
    if defunctChildren(of: daemon.processIdentifier) == 0 {
        reaped = true
        break
    }
    usleep(100_000)
}
check("remove: child reaped, no defunct left", reaped)
check("remove: daemon healthy after reap", req(conn, "ping")?.type == "pong")

// list should no longer contain the removed pane.
let list = req(conn, "list")
check("list: removed pane absent", list?.panes?.contains { $0.id == sleeper } == false)

// ---- backpressure -------------------------------------------------------------
// A subscriber that stops reading must not balloon the daemon (bounded outBuf,
// over-high-water disconnect), and a firehose pane must not starve control
// traffic on other connections (drain budget).

let flood = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "flood"
    $0.title = "flood"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "yes taskdeck-flood-line | head -c 20000000; echo FLOOD-DONE"
}
let floodID = flood?.paneID ?? ""
check("flood: pane created", flood?.type == "ok" && !floodID.isEmpty)

// Stalled subscriber: subscribes, then never reads.
let stalled = BlockingConn(path: sockPath)
if let stalled {
    var sub = WireMessage(type: "subscribe")
    sub.paneID = floodID
    sub.id = UUID().uuidString
    stalled.send(sub)
}
check("flood: stalled subscriber attached", stalled != nil)

// While the flood runs, the control connection must stay responsive.
var maxPingMs = 0.0
var pings = 0
let floodDeadline = Date().addingTimeInterval(6)
while Date() < floodDeadline {
    let t0 = Date()
    guard req(conn, "ping")?.type == "pong" else { break }
    maxPingMs = max(maxPingMs, Date().timeIntervalSince(t0) * 1000)
    pings += 1
    usleep(200_000)
}
check("flood: control pings kept flowing (\(pings)x, max \(Int(maxPingMs))ms)",
      pings >= 20 && maxPingMs < 2000)

// Daemon memory must stay bounded (20MB flood vs 4MiB high-water).
func rssKB(_ pid: Int32) -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "rss=", "-p", "\(pid)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Int(String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
}
let rss = rssKB(daemon.processIdentifier)
check("flood: daemon RSS bounded (\(rss / 1024)MB)", rss > 0 && rss < 300_000)

// The stalled subscriber should have been dropped once its backlog crossed
// the high-water mark — its next request sees EOF after the buffered frames.
if let stalled {
    var p = WireMessage(type: "ping")
    p.id = UUID().uuidString
    stalled.send(p)
    let dropped = stalled.request(WireMessage(type: "ping")) == nil
    check("flood: stalled subscriber was disconnected", dropped)
}
check("flood: daemon healthy after flood", req(conn, "ping")?.type == "pong")
_ = req(conn, "remove") { $0.paneID = floodID }

// ---- native-surface backpressure --------------------------------------------

// A large initial native snapshot must remain a usable ordering boundary: the
// same socket can apply later publications and still carry control replies.
let largeSurfacePane = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-large-snapshot"
    $0.title = "surface-large-snapshot"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 300
    $0.rows = 100
    // Split completion markers across printf's format and argument so the
    // shell's echoed command line cannot satisfy the readiness assertions.
    $0.command = "yes taskdeck-large-snapshot-line | head -c 500000; printf '\\nLARGE-SNAPSHOT-%s\\n' READY; read go; printf 'LARGE-SNAPSHOT-%s\\n' LIVE; sleep 2"
}
let largeSurfacePaneID = largeSurfacePane?.paneID ?? ""
check("surface large snapshot: pane created",
      largeSurfacePane?.type == "ok" && !largeSurfacePaneID.isEmpty)
check("surface large snapshot: scrollback filled before subscribe",
      collectOutput(paneID: largeSurfacePaneID,
                    until: "LARGE-SNAPSHOT-READY", within: 8))

if let largeSurfaceConn = BlockingConn(path: sockPath) {
    var subscribe = WireMessage(type: "subscribeSurface")
    subscribe.paneID = largeSurfacePaneID
    subscribe.surfaceClientID = "large-snapshot-view"
    subscribe.surfaceVersion = Wire.remoteSurfaceVersion
    let initialReply = largeSurfaceConn.request(subscribe)
    let initialSnapshot = surfaceSnapshot(initialReply)
    let initialFrameBytes = initialReply.map { FrameCodec.encode($0).count } ?? 0
    check("surface large snapshot: native frame is large but bounded (\(initialFrameBytes / 1024)KiB)",
          initialReply?.type == "surfaceSnapshot"
          && initialFrameBytes > 512 * 1024
          && initialFrameBytes < 8 * 1024 * 1024)

    let viewer = Terminal(delegate: ITestTerminalDelegate())
    var continuityOK = false
    if let initialSnapshot,
       (try? viewer.applySurfaceSnapshot(initialSnapshot)) != nil {
        continuityOK = visibleText(viewer).contains("LARGE-SNAPSHOT-READY")
    }

    var release = WireMessage(type: "input")
    release.paneID = largeSurfacePaneID
    release.setData(Array("go\n".utf8))
    conn.send(release)

    var markerSeen = false
    var sawRawOutput = false
    let liveDeadline = Date().addingTimeInterval(8)
    while Date() < liveDeadline, !markerSeen {
        guard let message = recv(largeSurfaceConn, within: 500) else { continue }
        if message.type == "output" { sawRawOutput = true }
        do {
            if let patch = surfacePatch(message) {
                continuityOK = continuityOK
                    && patch.epoch == viewer.appliedRemoteSurfaceEpoch
                    && patch.baseRevision == viewer.appliedRemoteSurfaceRevision
                    && message.surfaceBaseRevision == patch.baseRevision
                    && message.surfaceRevision == patch.revision
                try viewer.applySurfacePatch(patch)
            } else if let replacement = surfaceSnapshot(message) {
                try viewer.applySurfaceSnapshot(replacement)
            }
        } catch {
            continuityOK = false
        }
        markerSeen = visibleText(viewer).contains("LARGE-SNAPSHOT-LIVE")
    }
    check("surface large snapshot: later publications apply continuously",
          continuityOK && markerSeen && !sawRawOutput)
    check("surface large snapshot: socket remains usable for control",
          largeSurfaceConn.request(WireMessage(type: "ping"))?.type == "pong")
} else {
    check("surface large snapshot: subscriber connects", false)
}
if !largeSurfacePaneID.isEmpty {
    _ = req(conn, "remove") { $0.paneID = largeSurfacePaneID }
}

// Continuously draining subscribers must survive a host flood. Besides exact
// revision continuity, bound transport amplification so a future per-read
// publication regression cannot quietly turn a small PTY stream into tens of
// megabytes of JSON and disconnect the shared GUI/control socket.
let nativeFloodInputBytes = 2_000_000
let nativeFloodPane = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-reading-flood"
    $0.title = "surface-reading-flood"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "sleep 0.6; yes taskdeck-native-flood-line | head -c \(nativeFloodInputBytes); printf '\\nNATIVE-FLOOD-%s\\n' DONE; sleep 2"
}
let nativeFloodPaneID = nativeFloodPane?.paneID ?? ""
check("surface reading flood: pane created",
      nativeFloodPane?.type == "ok" && !nativeFloodPaneID.isEmpty)

if let nativeFloodConn = BlockingConn(path: sockPath) {
    var subscribe = WireMessage(type: "subscribeSurface")
    subscribe.paneID = nativeFloodPaneID
    subscribe.surfaceClientID = "reading-flood-view"
    subscribe.surfaceVersion = Wire.remoteSurfaceVersion
    let initialReply = nativeFloodConn.request(subscribe)
    let initialSnapshot = surfaceSnapshot(initialReply)
    check("surface reading flood: initial snapshot received", initialSnapshot != nil)

    // `BlockingConn.recv()` can already hold another decoded frame internally,
    // so polling the fd before every call would introduce artificial stalls.
    // A receive timeout still bounds a daemon that stops publishing entirely.
    var receiveTimeout = timeval(tv_sec: 9, tv_usec: 0)
    _ = setsockopt(
        nativeFloodConn.fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &receiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)
    )

    let observation = SurfaceFloodObservation()
    if let initialReply {
        observation.record(frameBytes: FrameCodec.encode(initialReply).count,
                           publication: initialSnapshot != nil,
                           rawOutput: initialReply.type == "output")
    }
    let readerDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        defer { readerDone.signal() }
        let viewer = Terminal(delegate: ITestTerminalDelegate())
        guard let initialSnapshot,
              (try? viewer.applySurfaceSnapshot(initialSnapshot)) != nil else {
            observation.markContinuityFailure()
            observation.finish(dropped: false)
            return
        }

        var dropped = false
        while !observation.snapshot().markerSeen {
            guard let message = nativeFloodConn.recv() else {
                dropped = true
                break
            }
            let isPublication = message.type == "surfacePatch"
                || message.type == "surfaceSnapshot"
            observation.record(
                frameBytes: FrameCodec.encode(message).count,
                publication: isPublication,
                rawOutput: message.type == "output"
            )
            do {
                if let patch = surfacePatch(message) {
                    guard patch.epoch == viewer.appliedRemoteSurfaceEpoch,
                          patch.baseRevision == viewer.appliedRemoteSurfaceRevision,
                          message.surfaceBaseRevision == patch.baseRevision,
                          message.surfaceRevision == patch.revision else {
                        throw NSError(domain: "taskdeck-itest.surface-flood", code: 1)
                    }
                    try viewer.applySurfacePatch(patch)
                } else if let replacement = surfaceSnapshot(message) {
                    try viewer.applySurfaceSnapshot(replacement)
                }
            } catch {
                observation.markContinuityFailure()
            }
            if visibleText(viewer).contains("NATIVE-FLOOD-DONE") {
                observation.markMarkerSeen()
            }
        }
        observation.finish(dropped: dropped)
    }

    var nativeFloodMaxPingMs = 0.0
    var nativeFloodPings = 0
    let controlDeadline = Date().addingTimeInterval(9)
    while Date() < controlDeadline,
          !observation.finished || nativeFloodPings < 12 {
        let started = Date()
        guard req(conn, "ping")?.type == "pong" else { break }
        nativeFloodMaxPingMs = max(
            nativeFloodMaxPingMs,
            Date().timeIntervalSince(started) * 1000
        )
        nativeFloodPings += 1
        usleep(100_000)
    }

    let readerJoined = readerDone.wait(timeout: .now() + 2) == .success
    let result = observation.snapshot()
    check("surface reading flood: reader completed without disconnect",
          readerJoined && result.finished && !result.dropped)
    check("surface reading flood: ordered publications reach final marker",
          result.continuity && result.markerSeen
          && result.publicationCount > 1 && !result.sawRawOutput)
    let wireByteLimit = nativeFloodInputBytes * 12 + 1024 * 1024
    check("surface reading flood: wire amplification bounded (\(result.wireBytes / 1024)KiB / \(nativeFloodInputBytes / 1024)KiB)",
          result.wireBytes > 0 && result.wireBytes <= wireByteLimit)
    check("surface reading flood: individual frame bounded (\(result.largestFrame / 1024)KiB)",
          result.largestFrame > 0 && result.largestFrame <= 2 * 1024 * 1024)
    check("surface reading flood: independent control stays responsive (\(nativeFloodPings)x, max \(Int(nativeFloodMaxPingMs))ms)",
          nativeFloodPings >= 12 && nativeFloodMaxPingMs < 2000)
    if readerJoined {
        check("surface reading flood: subscriber remains usable after flood",
              nativeFloodConn.request(WireMessage(type: "ping"))?.type == "pong")
    } else {
        check("surface reading flood: subscriber remains usable after flood", false)
    }
} else {
    check("surface reading flood: subscriber connects", false)
}
if !nativeFloodPaneID.isEmpty {
    _ = req(conn, "remove") { $0.paneID = nativeFloodPaneID }
}

// A resync request is an authority boundary, not another replaceable render
// update. If the subscriber was briefly backlogged while output stays busy,
// dirty catch-up snapshots must not repeatedly jump ahead of the request and
// starve its id-bearing response forever. Mirror the GUI: ignore unsolicited
// publications while resync is pending, then resume exact revision checks from
// the response snapshot.
let resyncFloodPane = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-resync-flood"
    $0.title = "surface-resync-flood"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "sleep 0.6; (while :; do yes taskdeck-resync-flood-line | head -c 65536; done) & flood=$!; read stop; kill \"$flood\" 2>/dev/null; wait \"$flood\" 2>/dev/null; printf '\\nRESYNC-FLOOD-DONE\\n'; sleep 2"
}
let resyncFloodPaneID = resyncFloodPane?.paneID ?? ""
check("surface resync flood: pane created",
      resyncFloodPane?.type == "ok" && !resyncFloodPaneID.isEmpty)

if let resyncFloodConn = BlockingConn(path: sockPath) {
    // Make a short pause in reads reliably create daemon-side output backlog.
    var receiveBuffer: Int32 = 8 * 1024
    _ = setsockopt(
        resyncFloodConn.fd,
        SOL_SOCKET,
        SO_RCVBUF,
        &receiveBuffer,
        socklen_t(MemoryLayout<Int32>.size)
    )

    var subscribe = WireMessage(type: "subscribeSurface")
    subscribe.paneID = resyncFloodPaneID
    subscribe.surfaceClientID = "resync-flood-view"
    subscribe.surfaceVersion = Wire.remoteSurfaceVersion
    let initialReply = resyncFloodConn.request(subscribe)
    let initialSnapshot = surfaceSnapshot(initialReply)
    check("surface resync flood: initial snapshot received", initialSnapshot != nil)

    let viewer = Terminal(delegate: ITestTerminalDelegate())
    var continuityOK = initialSnapshot.map {
        (try? viewer.applySurfaceSnapshot($0)) != nil
    } == true

    // Let the infinite writer fill this deliberately tiny receive window, then
    // request resync on the same full-duplex socket before reads resume.
    usleep(1_300_000)
    var resync = WireMessage(type: "surfaceResync")
    let resyncID = UUID().uuidString
    resync.id = resyncID
    resync.paneID = resyncFloodPaneID
    resync.surfaceClientID = "resync-flood-view"
    resync.surfaceVersion = Wire.remoteSurfaceVersion
    resyncFloodConn.send(resync)

    let independentPingOK = req(conn, "ping")?.type == "pong"
    var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
    _ = setsockopt(
        resyncFloodConn.fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &receiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)
    )

    var responseSeen = false
    var responseDuringFlood = false
    var sawRawOutput = false
    let responseDeadline = Date().addingTimeInterval(5)
    while Date() < responseDeadline, !responseSeen {
        guard let message = resyncFloodConn.recv() else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            break
        }
        if message.type == "output" { sawRawOutput = true }
        // The GUI discards broadcasts while resyncPending. Only this exact
        // request response establishes the new authority boundary.
        guard message.id == resyncID else { continue }
        responseSeen = true
        responseDuringFlood = true
        guard message.type == "surfaceSnapshot",
              let snapshot = surfaceSnapshot(message),
              message.surfaceRevision == snapshot.revision else {
            continuityOK = false
            continue
        }
        do {
            try viewer.applySurfaceSnapshot(snapshot)
        } catch {
            continuityOK = false
        }
    }

    // Bound the regression even on a broken daemon, and provide a marker whose
    // post-response publications must remain continuous and visible.
    var stopFlood = WireMessage(type: "input")
    stopFlood.paneID = resyncFloodPaneID
    stopFlood.setData(Array("stop\n".utf8))
    conn.send(stopFlood)

    var markerSeen = false
    let markerDeadline = Date().addingTimeInterval(8)
    while Date() < markerDeadline, !markerSeen {
        guard let message = resyncFloodConn.recv() else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            break
        }
        if message.type == "output" { sawRawOutput = true }
        do {
            if message.id == resyncID {
                responseSeen = true
                guard message.type == "surfaceSnapshot",
                      let snapshot = surfaceSnapshot(message),
                      message.surfaceRevision == snapshot.revision else {
                    continuityOK = false
                    continue
                }
                try viewer.applySurfaceSnapshot(snapshot)
            } else if responseSeen, let patch = surfacePatch(message) {
                continuityOK = continuityOK
                    && patch.epoch == viewer.appliedRemoteSurfaceEpoch
                    && patch.baseRevision == viewer.appliedRemoteSurfaceRevision
                    && message.surfaceBaseRevision == patch.baseRevision
                    && message.surfaceRevision == patch.revision
                try viewer.applySurfacePatch(patch)
            } else if responseSeen, let replacement = surfaceSnapshot(message) {
                try viewer.applySurfaceSnapshot(replacement)
            }
        } catch {
            continuityOK = false
        }
        markerSeen = responseSeen
            && visibleText(viewer).contains("RESYNC-FLOOD-DONE")
    }

    check("surface resync flood: request snapshot is not starved by catch-up",
          responseDuringFlood)
    check("surface resync flood: response restores continuous state through marker",
          responseSeen && continuityOK && markerSeen && !sawRawOutput)
    check("surface resync flood: independent control stays responsive",
          independentPingOK)
    check("surface resync flood: subscriber socket remains usable",
          resyncFloodConn.request(WireMessage(type: "ping"))?.type == "pong")
} else {
    check("surface resync flood: subscriber connects", false)
}
if !resyncFloodPaneID.isEmpty {
    _ = req(conn, "remove") { $0.paneID = resyncFloodPaneID }
}

// Coalescing protects an active reader, but must not remove the hard bounded
// backlog for a client that stops draining after its bootstrap snapshot.
let nativeStallPane = req(conn, "newPane") {
    $0.taskID = "itest"
    $0.specID = "surface-stalled-flood"
    $0.title = "surface-stalled-flood"
    $0.cwd = workDir
    $0.shell = "/bin/sh"
    $0.cols = 80
    $0.rows = 24
    $0.command = "sleep 0.5; i=0; while [ \"$i\" -lt 160 ]; do yes native-stall-line | head -c 65536; i=$((i + 1)); sleep 0.02; done; printf '\\nNATIVE-STALL-DONE\\n'; sleep 2"
}
let nativeStallPaneID = nativeStallPane?.paneID ?? ""
check("surface stalled flood: pane created",
      nativeStallPane?.type == "ok" && !nativeStallPaneID.isEmpty)

let nativeStalledConn = BlockingConn(path: sockPath)
if let nativeStalledConn {
    var subscribe = WireMessage(type: "subscribeSurface")
    subscribe.paneID = nativeStallPaneID
    subscribe.surfaceClientID = "stalled-flood-view"
    subscribe.surfaceVersion = Wire.remoteSurfaceVersion
    check("surface stalled flood: bootstrap snapshot received",
          surfaceSnapshot(nativeStalledConn.request(subscribe)) != nil)
}
check("surface stalled flood: subscriber attached", nativeStalledConn != nil)

var nativeStallMaxPingMs = 0.0
var nativeStallPings = 0
let nativeStallDeadline = Date().addingTimeInterval(7)
while Date() < nativeStallDeadline {
    let started = Date()
    guard req(conn, "ping")?.type == "pong" else { break }
    nativeStallMaxPingMs = max(
        nativeStallMaxPingMs,
        Date().timeIntervalSince(started) * 1000
    )
    nativeStallPings += 1
    usleep(200_000)
}
check("surface stalled flood: independent control stays responsive (\(nativeStallPings)x, max \(Int(nativeStallMaxPingMs))ms)",
      nativeStallPings >= 25 && nativeStallMaxPingMs < 2000)

if let nativeStalledConn {
    let dropped = nativeStalledConn.request(WireMessage(type: "ping")) == nil
    check("surface stalled flood: stalled subscriber was disconnected", dropped)
}
let nativeStallRSS = rssKB(daemon.processIdentifier)
check("surface stalled flood: daemon RSS bounded (\(nativeStallRSS / 1024)MB)",
      nativeStallRSS > 0 && nativeStallRSS < 300_000)
check("surface stalled flood: daemon remains healthy",
      req(conn, "ping")?.type == "pong")
if !nativeStallPaneID.isEmpty {
    _ = req(conn, "remove") { $0.paneID = nativeStallPaneID }
}

// ---- singleton ---------------------------------------------------------------

let second = spawnDaemon(socket: sockPath, log: tmpRoot + "/d2.log")
var secondExited = false
for _ in 0 ..< 30 { // up to 3s
    if !second.isRunning { secondExited = true; break }
    usleep(100_000)
}
check("singleton: second daemon on same socket exits", secondExited)
check("singleton: exit code 2", !second.isRunning && second.terminationStatus == 2)
check("singleton: first daemon still serving", req(conn, "ping")?.type == "pong")

// ---- teardown ----------------------------------------------------------------

_ = req(conn, "shutdown")
usleep(300_000)
cleanup()
print(failures == 0 ? "\nALL ITEST PASS" : "\n\(failures) ITEST FAILURE(S)")
exit(failures == 0 ? 0 : 1)
