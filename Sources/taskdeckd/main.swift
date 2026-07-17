import Darwin
import Foundation
import TaskDeckCore

// taskdeckd — owns every PTY so the GUI can be rebuilt/relaunched freely
// without killing the user's terminals. State here is runtime-only; pane
// *declarations* live in the app's per-task machine state.

// _IOW('t', 103, struct winsize) — the TIOCSWINSZ macro doesn't import into Swift.
private let TIOCSWINSZ_VALUE: UInt = 0x8008_7467

private let logFile: UnsafeMutablePointer<FILE>? = fopen(Paths.daemonLog.path, "a")

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
    var cols: Int
    var rows: Int
    var pid: pid_t = -1
    var master: Int32 = -1
    var running = false
    var exitCode: Int32?
    private(set) var ring = [UInt8]()
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    unowned let server: Server

    static let ringCap = 512 * 1024

    init(taskID: String, specID: String, title: String, cwd: String, cols: Int, rows: Int, server: Server) {
        self.taskID = taskID
        self.specID = specID
        self.title = title
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.server = server
    }

    var infoStruct: PaneInfo {
        PaneInfo(id: id, taskID: taskID, specID: specID, title: title, cwd: cwd,
                 pid: pid, running: running, exitCode: exitCode, cols: cols, rows: rows)
    }

    func spawn(extraEnv: [String: String]) throws {
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TASKDECK"] = "1"
        for (k, v) in extraEnv { env[k] = v }

        // Everything the child touches must be prepared before fork.
        let argStrings: [String] = ["/bin/zsh", "-il"]
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
            if let c = cCwd, chdir(c) != 0 { _ = chdir("/") }
            execve("/bin/zsh", cArgs, cEnv)
            _exit(127)
        }

        pid = child
        master = m
        running = true
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

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

    func writeBytes(_ bytes: [UInt8]) {
        guard master >= 0 else { return }
        var slice = bytes[...]
        while !slice.isEmpty {
            let n = slice.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                slice = slice.dropFirst(n)
            } else if errno == EAGAIN || errno == EINTR {
                usleep(2000)
            } else {
                break
            }
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 {
                let chunk = Array(buf[0 ..< n])
                ring.append(contentsOf: chunk)
                if ring.count > Pane.ringCap { ring.removeFirst(ring.count - Pane.ringCap) }
                server.broadcastOutput(pane: self, bytes: chunk)
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
        }
        server.broadcastPaneExited(self)
        dlog("pane \(id) (\(title)) exited code=\(exitCode ?? -1)")
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard master >= 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
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
    var alive = true
    private let writeQ: DispatchQueue
    private var readSource: DispatchSourceRead?
    unowned let server: Server

    init(fd: Int32, server: Server) {
        self.fd = fd
        self.server = server
        writeQ = DispatchQueue(label: "taskdeckd.conn.write.\(fd)")
    }

    func start(on queue: DispatchQueue) {
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.readable() }
        rs.setCancelHandler { [fd] in close(fd) }
        rs.activate()
        readSource = rs
    }

    func stop() {
        alive = false
        readSource?.cancel()
        readSource = nil
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

    func send(_ m: WireMessage) {
        guard alive else { return }
        let data = FrameCodec.encode(m)
        writeQ.async { [weak self] in
            guard let self, self.alive else { return }
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(self.fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if n > 0 { off += n } else if errno == EINTR { continue } else { return }
                }
            }
        }
    }
}

final class Server {
    let queue = DispatchQueue(label: "taskdeckd.state")
    var panes: [String: Pane] = [:]
    var conns: [ObjectIdentifier: Conn] = [:]
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    func start() {
        let path = Wire.socketPath()

        // Singleton guard: if another daemon answers on the socket, bail out.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        var probeAddr = sockaddrUn(path)
        let alreadyRunning = withUnsafePointer(to: &probeAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        close(probe)
        if alreadyRunning {
            dlog("another taskdeckd is already running; exiting")
            exit(2)
        }
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { dlog("socket() failed"); exit(1) }
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
            let pane = Pane(taskID: m.taskID ?? "", specID: m.specID ?? UUID().uuidString,
                            title: m.title ?? "terminal", cwd: m.cwd ?? NSHomeDirectory(),
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
                $0.setData(pane.ring)
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
                    pane.terminate(force: false)
                    queue.asyncAfter(deadline: .now() + 2.0) { [weak pane] in
                        if let p = pane, p.running { p.terminate(force: true) }
                    }
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
        for c in conns.values where c.subs.contains(pane.id) { c.send(m) }
    }

    func broadcastPaneExited(_ pane: Pane) {
        var m = WireMessage(type: "paneExited")
        m.paneID = pane.id
        m.exitCode = pane.exitCode
        m.panes = [pane.infoStruct]
        for c in conns.values { c.send(m) }
    }
}

// MARK: - main

setsid() // detach from whoever spawned us (usually the GUI); best-effort
signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

let server = Server()
server.queue.async { server.start() }
dispatchMain()
