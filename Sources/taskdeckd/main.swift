import Darwin
import Foundation
import TaskDeckCore

// taskdeckd — owns every PTY so the GUI can be rebuilt/relaunched freely
// without killing the user's terminals. State here is runtime-only; pane
// *declarations* live in the app's per-task machine state.

// _IOW('t', 103, struct winsize) — the TIOCSWINSZ macro doesn't import into Swift.
private let TIOCSWINSZ_VALUE: UInt = 0x8008_7467

// Opened by main AFTER flag parsing (tests pass --log so an isolated daemon
// never appends to the production log).
private var logFile: UnsafeMutablePointer<FILE>?

func initLog(path: String) {
    logFile = fopen(path, "a")
    if let f = logFile { setCloseOnExec(fileno(f)) }
}

func dlog(_ s: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(s)\n"
    if let f = logFile {
        fputs(line, f)
        fflush(f)
    }
}

final class Pane {
    let id = UUID().uuidString
    let taskID: String
    let specID: String
    var title: String
    let cwd: String
    let shell: String
    var cols: Int
    var rows: Int
    var pid: pid_t = -1
    var master: Int32 = -1
    var running = false
    var exitCode: Int32?
    private(set) var ring = ByteQueue()
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    // Output that couldn't be written yet (PTY buffer full). Flushed by an
    // event-driven write source — never by spinning, which would wedge the
    // shared state queue (see writeBytes).
    private var pendingWrite = ByteQueue()
    private var writeSource: DispatchSourceWrite?
    private static let pendingCap = 4 * 1024 * 1024
    // One drain pass stops after this many bytes and reschedules itself, so a
    // firehose pane can't monopolize the shared state queue (input/resize for
    // quiet panes stays responsive).
    private static let drainBudget = 256 * 1024
    unowned let server: Server

    static let ringCap = 512 * 1024

    init(taskID: String, specID: String, title: String, cwd: String, shell: String,
         cols: Int, rows: Int, server: Server) {
        self.taskID = taskID
        self.specID = specID
        self.title = title
        self.cwd = cwd
        self.shell = shell
        self.cols = cols
        self.rows = rows
        self.server = server
    }

    var infoStruct: PaneInfo {
        PaneInfo(id: id, taskID: taskID, specID: specID, title: title, cwd: cwd,
                 pid: pid, running: running, exitCode: exitCode, cols: cols, rows: rows)
    }

    /// Clamp a terminal dimension into a sane range. `UInt16(v)` traps on a
    /// negative or >65535 Int, so an unvalidated cols/rows from a client (e.g.
    /// `taskdeckctl resize p -1 -1`, or a malformed frame) could crash the
    /// daemon that owns every terminal. Clamp at the syscall boundary instead.
    static func dim(_ v: Int) -> UInt16 { UInt16(max(1, min(v, 1000))) }

    func spawn(extraEnv: [String: String]) throws {
        var ws = winsize(ws_row: Pane.dim(rows), ws_col: Pane.dim(cols), ws_xpixel: 0, ws_ypixel: 0)

        var env = ProcessInfo.processInfo.environment
        // A pane must be a fresh login terminal, not inherit the environment
        // of whatever launched the app. When JamesDesk is started from inside
        // a Claude Code session (e.g. a dev relaunch), that session injects
        // CLAUDE_* vars — notably CLAUDE_CONFIG_DIR, which PINS the account —
        // and they would leak into every pane, so plain `claude` (and the
        // account aliases) resolve the wrong config dir. Strip them; the
        // login shell re-establishes anything the user actually wants.
        for key in env.keys where key.hasPrefix("CLAUDE") || key == "CLAUDECODE" {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TASKDECK"] = "1"
        // Tag the pane with its task so the AI-status hook can record which
        // task a session belongs to — attributes ANY session started here
        // (auto-resume, manual, account switch), not just what the app
        // launched. Fixes the recurring "app tracks the wrong session" group.
        if !taskID.isEmpty { env["TASKDECK_TASK"] = taskID }
        for (k, v) in extraEnv { env[k] = v }

        // Everything the child touches must be prepared before fork.
        let argStrings: [String] = [shell, "-il"]
        var cArgs: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        let cCwd = strdup(cwd)
        defer {
            cArgs.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
            free(cCwd)
        }

        var m: Int32 = 0
        let child = forkpty(&m, nil, nil, &ws)
        if child < 0 {
            throw NSError(domain: "taskdeckd", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "forkpty failed errno=\(errno)"])
        }
        if child == 0 {
            // cwd is validated server-side before spawn; if it vanished in the
            // gap, fail loudly (visible exit) instead of silently running in /.
            if let c = cCwd, chdir(c) != 0 { _exit(126) }
            execve(cArgs[0], cArgs, cEnv)
            _exit(127)
        }

        pid = child
        master = m
        running = true
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        // Without this, every LATER pane's child inherits this master: EOF
        // never arrives (someone always holds the master) and fd tables grow
        // quadratically across panes.
        setCloseOnExec(master)

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: server.queue)
        rs.setEventHandler { [weak self] in self?.drain() }
        rs.activate()
        readSource = rs

        let ps = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: server.queue)
        ps.setEventHandler { [weak self] in self?.childExited() }
        ps.activate()
        procSource = ps
    }

    func typeCommand(_ command: String) {
        writeBytes(Array((command + "\n").utf8))
    }

    // Non-blocking write. Historically this spun with usleep on EAGAIN — but
    // it runs on the shared serial state queue, and the read/drain that would
    // empty the PTY is queued behind it, so a full PTY buffer (child stopped
    // reading) deadlocked the entire daemon. Now: write what we can, buffer
    // the rest, and let an event-driven write source flush it when the fd is
    // writable again. Never blocks the queue.
    func writeBytes(_ bytes: [UInt8]) {
        guard master >= 0 else { return }
        if !pendingWrite.isEmpty {
            appendPending(bytes[...]) // keep byte order behind what's queued
            return
        }
        var slice = bytes[...]
        while !slice.isEmpty {
            let n = slice.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                slice = slice.dropFirst(n)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                appendPending(slice)
                startWriteSource()
                return
            } else {
                return // hard error (e.g. pane closed)
            }
        }
    }

    private func appendPending(_ slice: ArraySlice<UInt8>) {
        pendingWrite.append(slice)
        if pendingWrite.count > Pane.pendingCap {
            // Child isn't draining; cap the backlog rather than grow forever.
            pendingWrite.trimFront(toCount: Pane.pendingCap)
            dlog("pane \(id) write backlog capped (child not reading?)")
        }
    }

    private func startWriteSource() {
        guard writeSource == nil, master >= 0 else { return }
        let ws = DispatchSource.makeWriteSource(fileDescriptor: master, queue: server.queue)
        ws.setEventHandler { [weak self] in self?.flushPending() }
        ws.activate()
        writeSource = ws
    }

    private func flushPending() {
        while !pendingWrite.isEmpty {
            let n = pendingWrite.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                pendingWrite.consume(n)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return // stay subscribed; fire again when writable
            } else {
                pendingWrite.removeAll()
                break
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var drained = 0
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 {
                let chunk = Array(buf[0 ..< n])
                ring.append(chunk)
                ring.trimFront(toCount: Pane.ringCap)
                server.broadcastOutput(pane: self, bytes: chunk)
                drained += n
                if drained >= Pane.drainBudget {
                    // Yield the shared state queue; continue in a fresh block
                    // so other panes' input/resize aren't starved by one
                    // firehose (`yes`, huge build logs).
                    server.queue.async { [weak self] in self?.drain() }
                    return
                }
            } else if n == 0 {
                closeMaster()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                closeMaster()
                return
            }
        }
    }

    private func closeMaster() {
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        pendingWrite.removeAll()
        if master >= 0 {
            close(master)
            master = -1
        }
    }

    private func childExited() {
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        running = false
        exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        procSource?.cancel()
        procSource = nil
        server.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.drain()
            self.closeMaster()
            self.server.dying.removeValue(forKey: self.id) // release the retained ref
        }
        server.broadcastPaneExited(self)
        dlog("pane \(id) (\(title)) exited code=\(exitCode ?? -1)")
    }

    /// Idempotent teardown for a pane removed after it already exited: reap any
    /// unwaited child and close the master fd / sources. Safe to call twice.
    func disposeIfNeeded() {
        procSource?.cancel()
        procSource = nil
        if pid > 0 { var s: Int32 = 0; waitpid(pid, &s, WNOHANG) }
        closeMaster()
    }

    func resize(cols: Int, rows: Int) {
        self.cols = max(1, min(cols, 1000))
        self.rows = max(1, min(rows, 1000))
        guard master >= 0 else { return }
        var ws = winsize(ws_row: Pane.dim(self.rows), ws_col: Pane.dim(self.cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ_VALUE, &ws)
    }

    func terminate(force: Bool) {
        guard pid > 0 else { return }
        _ = killpg(pid, force ? SIGKILL : SIGHUP)
    }
}

final class Conn {
    let fd: Int32
    let reader = FrameCodec.Reader()
    var subs = Set<String>()
    private var readSource: DispatchSourceRead?
    // Outbound: buffered on the server's state queue and drained by an
    // event-driven write source. The old design did BLOCKING writes on a
    // per-conn queue, which (a) buffered without bound for a reader that
    // stopped draining (yes/cat-bigfile → daemon RSS blowup), (b) on EAGAIN
    // dropped the REST of a frame, permanently desyncing the length-prefixed
    // stream, and (c) raced close(fd) on another queue — after fd recycling
    // the tail bytes could land in an unrelated fd (even a PTY).
    private var outBuf = ByteQueue()
    private var writeSource: DispatchSourceWrite?
    private var writeFD: Int32 = -1 // dup(fd); the write source owns this copy
    private(set) var closed = false
    /// A subscriber this far behind isn't reading: disconnect it rather than
    /// buffer forever or drop mid-stream bytes. It can reconnect and get a
    /// fresh ring replay.
    static let highWater = 4 * 1024 * 1024
    unowned let server: Server

    init(fd: Int32, server: Server) {
        self.fd = fd
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.readable() }
        rs.setCancelHandler { [fd] in close(fd) }
        rs.activate()
        readSource = rs
    }

    /// Full teardown; server.queue only.
    func stop() {
        guard !closed else { return }
        closed = true
        outBuf.removeAll()
        readSource?.cancel() // its cancel handler closes fd
        readSource = nil
        writeSource?.cancel() // its cancel handler closes writeFD
        writeSource = nil
    }

    private func readable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            reader.append(Data(buf[0 ..< n]))
            while let m = reader.next() { server.handle(m, from: self) }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            server.drop(self)
        }
    }

    func send(_ m: WireMessage) { sendEncoded(FrameCodec.encode(m)) }

    /// server.queue only. Fast path writes inline (non-blocking); leftovers
    /// are buffered whole — never a partial frame drop — and flushed by the
    /// write source when the socket drains.
    func sendEncoded(_ data: Data) {
        guard !closed else { return }
        if outBuf.count + data.count > Conn.highWater {
            dlog("conn fd=\(fd) output backlog over high-water; dropping subscriber")
            server.drop(self)
            return
        }
        if outBuf.isEmpty {
            var off = 0
            data.withUnsafeBytes { raw in
                while off < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if n > 0 { off += n } else if errno == EINTR { continue } else { break }
                }
            }
            if off >= data.count { return }
            outBuf.append(data.dropFirst(off))
        } else {
            outBuf.append(data)
        }
        armWriteSource()
    }

    private func armWriteSource() {
        guard writeSource == nil, !closed else { return }
        // The write source gets its own dup so each source owns exactly one
        // fd copy and closes it in its cancel handler — no double-close races.
        if writeFD < 0 {
            writeFD = dup(fd)
            guard writeFD >= 0 else { return }
            setCloseOnExec(writeFD)
        }
        let ws = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: server.queue)
        ws.setEventHandler { [weak self] in self?.flushOut() }
        ws.setCancelHandler { [writeFD] in close(writeFD) }
        ws.activate()
        writeSource = ws
    }

    private func flushOut() {
        guard !closed else { return }
        while !outBuf.isEmpty {
            let n = outBuf.withUnsafeBytes { raw in
                Darwin.write(writeFD, raw.baseAddress, raw.count)
            }
            if n > 0 {
                outBuf.consume(n)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return // still subscribed; fires again when writable
            } else {
                server.drop(self)
                return
            }
        }
        // Drained: disarm (cancel closes writeFD; next burst dups again).
        writeSource?.cancel()
        writeSource = nil
        writeFD = -1
    }
}

final class Server {
    let queue = DispatchQueue(label: "taskdeckd.state")
    var panes: [String: Pane] = [:]
    // Panes removed while still running are held here (strong ref) until their
    // child exits and is reaped — otherwise `remove` dropped the only reference,
    // the Pane deallocated, its [weak self] source handlers stopped, and
    // childExited() never ran: no waitpid (zombie), no close(master) (leaked
    // PTY fd), and the 2s SIGKILL escalation saw a nil pane (orphan process).
    var dying: [String: Pane] = [:]
    var conns: [ObjectIdentifier: Conn] = [:]
    private var listenFD: Int32 = -1
    private var singletonLockFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    func start() {
        let path = Wire.socketPath()

        // Singleton guard: an exclusive flock on <socket>.lock. The old
        // "probe-connect, then unlink+bind" had a TOCTOU hole — two daemons
        // starting together could both probe-fail, then the later bind wins
        // and the earlier one keeps orphaned PTYs on an unreachable socket.
        // flock is atomic, auto-released on process death (stale lock files
        // are harmless), and per-socket so isolated test daemons don't
        // contend with production.
        let lockFD = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { dlog("cannot open lock file errno=\(errno)"); exit(1) }
        setCloseOnExec(lockFD)
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            dlog("another taskdeckd is already running (lock held); exiting")
            exit(2)
        }
        singletonLockFD = lockFD // held for the daemon's lifetime
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { dlog("socket() failed"); exit(1) }
        setCloseOnExec(listenFD)
        var addr = sockaddrUn(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(listenFD, 64) == 0 else { dlog("bind/listen failed errno=\(errno)"); exit(1) }
        chmod(path, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.activate()
        acceptSource = src
        dlog("taskdeckd listening at \(path) pid=\(getpid()) protocol=\(Wire.version)")
    }

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        setCloseOnExec(fd)
        let c = Conn(fd: fd, server: self)
        conns[ObjectIdentifier(c)] = c
        c.start(on: queue)
    }

    func drop(_ c: Conn) {
        conns.removeValue(forKey: ObjectIdentifier(c))
        c.stop()
    }

    private func reply(_ c: Conn, to m: WireMessage, _ type: String, _ mutate: (inout WireMessage) -> Void = { _ in }) {
        var r = WireMessage(type: type)
        r.id = m.id
        mutate(&r)
        c.send(r)
    }

    func handle(_ m: WireMessage, from c: Conn) {
        switch m.type {
        case "hello":
            reply(c, to: m, "hello") { $0.version = Wire.version }

        case "ping":
            reply(c, to: m, "pong")

        case "list":
            reply(c, to: m, "panes") { $0.panes = panes.values.map(\.infoStruct) }

        case "newPane":
            // Validate cwd BEFORE forking: silently spawning in / while the UI
            // shows the requested cwd misdirects every command the user types.
            let cwd = m.cwd ?? NSHomeDirectory()
            var cwdIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &cwdIsDir),
                  cwdIsDir.boolValue else {
                reply(c, to: m, "error") { $0.message = "cwd is not a directory: \(cwd)" }
                return
            }
            // Idempotence on (taskID, specID): a GUI relaunch racing its own
            // reconciliation (or a double-click) must adopt the live pane, not
            // spawn an invisible duplicate. A restart flow removes the old
            // pane first, so it never matches here.
            if let sid = m.specID,
               let existing = panes.values.first(where: {
                   $0.specID == sid && $0.taskID == (m.taskID ?? "") && $0.running
               }) {
                dlog("newPane dedupe: adopting live pane \(existing.id) for spec \(sid)")
                reply(c, to: m, "ok") {
                    $0.paneID = existing.id
                    $0.panes = [existing.infoStruct]
                }
                return
            }
            let pane = Pane(taskID: m.taskID ?? "", specID: m.specID ?? UUID().uuidString,
                            title: m.title ?? "terminal", cwd: cwd,
                            shell: m.shell ?? "/bin/zsh",
                            cols: m.cols ?? 100, rows: m.rows ?? 28, server: self)
            do {
                try pane.spawn(extraEnv: m.env ?? [:])
                panes[pane.id] = pane
                if let cmd = m.command, !cmd.isEmpty {
                    // Give zsh a beat to come up; input is buffered by the tty anyway.
                    queue.asyncAfter(deadline: .now() + 0.25) { [weak pane] in pane?.typeCommand(cmd) }
                }
                dlog("newPane \(pane.id) task=\(pane.taskID) title=\(pane.title) cwd=\(pane.cwd)")
                reply(c, to: m, "ok") {
                    $0.paneID = pane.id
                    $0.panes = [pane.infoStruct]
                }
            } catch {
                reply(c, to: m, "error") { $0.message = "\(error.localizedDescription)" }
            }

        case "subscribe":
            guard let pid = m.paneID, let pane = panes[pid] else {
                reply(c, to: m, "error") { $0.message = "no such pane" }
                return
            }
            c.subs.insert(pid)
            reply(c, to: m, "replay") {
                $0.paneID = pid
                $0.setData(pane.ring.snapshot())
                $0.cols = pane.cols
                $0.rows = pane.rows
            }

        case "unsubscribe":
            if let pid = m.paneID { c.subs.remove(pid) }

        case "input":
            if let pid = m.paneID, let pane = panes[pid], let bytes = m.dataBytes {
                pane.writeBytes(bytes)
            }

        case "resize":
            if let pid = m.paneID, let pane = panes[pid], let cols = m.cols, let rows = m.rows {
                pane.resize(cols: cols, rows: rows)
            }

        case "kill":
            if let pid = m.paneID, let pane = panes[pid] {
                pane.terminate(force: false)
                queue.asyncAfter(deadline: .now() + 2.0) { [weak pane] in
                    if let p = pane, p.running { p.terminate(force: true) }
                }
            }
            reply(c, to: m, "ok")

        case "remove":
            if let pid = m.paneID, let pane = panes.removeValue(forKey: pid) {
                if pane.running {
                    dying[pid] = pane // retain until childExited reaps + closes fd
                    pane.terminate(force: false)
                    queue.asyncAfter(deadline: .now() + 2.0) { [weak pane] in
                        if let p = pane, p.running { p.terminate(force: true) }
                    }
                } else {
                    pane.disposeIfNeeded() // already exited: ensure fd/sources closed
                }
            }
            reply(c, to: m, "ok")

        case "shutdown":
            dlog("shutdown requested")
            reply(c, to: m, "ok")
            queue.asyncAfter(deadline: .now() + 0.2) { exit(0) }

        default:
            reply(c, to: m, "error") { $0.message = "unknown type \(m.type)" }
        }
    }

    func broadcastOutput(pane: Pane, bytes: [UInt8]) {
        guard !conns.isEmpty else { return }
        var m = WireMessage(type: "output")
        m.paneID = pane.id
        m.setData(bytes)
        // Encode once, share across subscribers; snapshot the conns because a
        // send can drop an over-backlog subscriber mid-iteration.
        let encoded = FrameCodec.encode(m)
        for c in Array(conns.values) where c.subs.contains(pane.id) {
            c.sendEncoded(encoded)
        }
    }

    func broadcastPaneExited(_ pane: Pane) {
        var m = WireMessage(type: "paneExited")
        m.paneID = pane.id
        m.exitCode = pane.exitCode
        m.panes = [pane.infoStruct]
        let encoded = FrameCodec.encode(m)
        for c in Array(conns.values) { c.sendEncoded(encoded) }
    }
}

// MARK: - main

// Isolation flags for tests: `--socket <path>` (also honored via the
// TASKDECK_SOCKET env by Wire.socketPath()) and `--log <path>`. Production
// runs with no flags and keeps the App Support socket/log.
let dArgs = CommandLine.arguments
func dFlag(_ name: String) -> String? {
    guard let i = dArgs.firstIndex(of: name), i + 1 < dArgs.count else { return nil }
    return dArgs[i + 1]
}
if let sock = dFlag("--socket") { setenv("TASKDECK_SOCKET", sock, 1) }
initLog(path: dFlag("--log") ?? Paths.daemonLog.path)

setsid() // detach from whoever spawned us (usually the GUI); best-effort
signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

let server = Server()
server.queue.async { server.start() }
dispatchMain()
