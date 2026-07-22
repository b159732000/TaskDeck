// Integration tests against an ISOLATED taskdeckd on a temp socket.
// Run: `swift run taskdeck-itest` (or via Scripts/test.sh).
//
// Safety: never touches the production daemon/socket/log. The daemon under
// test is spawned with TASKDECK_SOCKET + --log pointing into a private temp
// dir (under /tmp because sun_path is limited to ~104 bytes), and is shut
// down (then SIGKILLed) on exit. A global watchdog bounds the whole run.
import Darwin
import Foundation
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
    $0.command = "printf 'itest-marker-%s\\n' ok"
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
var reaped = false
for _ in 0 ..< 40 { // up to 4s
    if defunctChildren(of: daemon.processIdentifier) == 0,
       liveChildren(of: daemon.processIdentifier) <= 1 { // marker pane's sh may linger
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
