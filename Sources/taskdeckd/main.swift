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
    /// Lifetime of the daemon-owned terminal surface. A restarted pane gets a
    /// new epoch even when it reuses the same persisted spec id.
    let paneEpoch = UUID().uuidString.lowercased()
    var resizeLease = ResizeLeaseState()
    /// The authoritative emulator is injected once during pane construction.
    /// If it encounters unsupported state or an export invariant fails, the
    /// pane disables native publication once and keeps legacy raw replay alive.
    var canonicalSurface: CanonicalSurfaceProviding?
    var pendingSurfaceSnapshots: [PendingSurfaceSnapshot] = []
    /// Parsing remains immediate, but render exports are coalesced to one
    /// publication per display frame. Without this, a scroll-heavy PTY read in
    /// ~1 KiB chunks produced dozens of near-viewport-sized patches and could
    /// amplify 100 KiB of host output past the socket high-water mark.
    private var surfacePublicationScheduled = false
    private static let surfacePublicationIntervalMS = 16
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
    private static let rawDrainBudget = 256 * 1024
    /// VT parsing is CPU work (and is serialized through main for SwiftTerm's
    /// DEC 2026 timer). Yield after a much smaller slice so one `yes` pane
    /// cannot delay input/ping/resize for every other pane.
    private static let canonicalDrainBudget = 16 * 1024
    unowned let server: Server

    static let ringCap = 512 * 1024

    init(taskID: String, specID: String, title: String, cwd: String, shell: String,
         cols: Int, rows: Int, server: Server) {
        self.taskID = taskID
        self.specID = specID
        self.title = title
        self.cwd = cwd
        self.shell = shell
        // SwiftTerm's parser has a two-column minimum. Keep the canonical grid,
        // PTY winsize, list metadata, and snapshots on one geometry.
        self.cols = max(2, min(cols, 1000))
        self.rows = max(1, min(rows, 1000))
        self.server = server
    }

    var infoStruct: PaneInfo {
        PaneInfo(id: id, taskID: taskID, specID: specID, title: title, cwd: cwd,
                 pid: pid, running: running, exitCode: exitCode, cols: cols, rows: rows)
    }

    func installCanonicalSurface() {
        precondition(canonicalSurface == nil)
        canonicalSurface = CanonicalTerminalSurface(pane: self)
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
        // The GUI/daemon may be relaunched by an AI tool or another terminal.
        // Its presentation policy and terminal identity belong to that outer
        // process, not to the new PTY. Leaking NO_COLOR made full-screen apps
        // such as Claude Code deliberately render monochrome even though this
        // pane advertises 256-color/truecolor support. Explicit per-pane env
        // below remains authoritative for users who intentionally opt out.
        let inheritedTerminalKeys = [
            "NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE",
            "NODE_DISABLE_COLORS", "CI", "COLORFGBG",
            "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
            "ITERM_SESSION_ID", "LC_TERMINAL", "LC_TERMINAL_VERSION",
            "TMUX", "TMUX_PANE", "STY", "WINDOW",
        ]
        for key in inheritedTerminalKeys { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "JamesDesk"
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
        let budget = canonicalSurface == nil
            ? Pane.rawDrainBudget
            : Pane.canonicalDrainBudget
        var buf = [UInt8](repeating: 0, count: min(65536, budget))
        var drained = 0
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 {
                let chunk = Array(buf[0 ..< n])
                if let surface = canonicalSurface {
                    do {
                        // Feed/query responses are never delayed. Only the
                        // replaceable render publication is coalesced.
                        _ = try surface.feed(chunk, wantsPublication: false)
                        scheduleSurfacePublicationIfNeeded()
                        if !surface.synchronizedOutputActive {
                            server.flushPendingSurfaceSnapshots(for: self)
                        }
                    } catch {
                        server.surfaceFailed(pane: self, error: error)
                    }
                }
                ring.append(chunk)
                ring.trimFront(toCount: Pane.ringCap)
                server.broadcastOutput(pane: self, bytes: chunk)
                drained += n
                if drained >= budget {
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
        self.cols = max(2, min(cols, 1000))
        self.rows = max(1, min(rows, 1000))
        if let surface = canonicalSurface {
            do {
                _ = try surface.resize(
                    cols: self.cols, rows: self.rows, wantsPublication: false)
                scheduleSurfacePublicationIfNeeded()
                if !surface.synchronizedOutputActive {
                    server.flushPendingSurfaceSnapshots(for: self)
                }
            } catch {
                server.surfaceFailed(pane: self, error: error)
            }
        }
        guard master >= 0 else { return }
        var ws = winsize(ws_row: Pane.dim(self.rows), ws_col: Pane.dim(self.cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ_VALUE, &ws)
    }

    private func scheduleSurfacePublicationIfNeeded() {
        guard !surfacePublicationScheduled,
              canonicalSurface != nil,
              server.hasSurfaceSubscribers(for: self) else { return }
        surfacePublicationScheduled = true
        server.queue.asyncAfter(
            deadline: .now() + .milliseconds(Self.surfacePublicationIntervalMS)
        ) { [weak self] in
            guard let self else { return }
            self.surfacePublicationScheduled = false
            guard self.server.panes[self.id] === self else { return }
            self.server.flushCanonicalSurfacePublication(for: self)
        }
    }

    func terminate(force: Bool) {
        guard pid > 0 else { return }
        _ = killpg(pid, force ? SIGKILL : SIGHUP)
    }
}

private struct SurfaceCursor: Equatable {
    let epoch: String
    let revision: UInt64
}

final class Conn {
    /// Process-local identity used as one half of resize-lease ownership. One
    /// socket can still host multiple surfaces, distinguished by client id.
    let identity = UUID().uuidString.lowercased()
    let fd: Int32
    let reader = FrameCodec.Reader()
    var subs = Set<String>()
    /// pane id -> view identities. Patches/events are sent once per connection,
    /// even when multiple windows on that connection display the same pane.
    var surfaceSubs: [String: Set<String>] = [:]
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
    /// Raised only while one explicitly bounded (>4 MiB) surface frame drains.
    /// This leaves room for control replies/events behind it without allowing
    /// an unbounded series of large render frames.
    private var outHighWater = Conn.highWater
    private var oversizedSurfaceFrameInFlight = false
    private var backlogWatchGeneration: UInt64 = 0
    private var backlogWatchScheduled = false
    private var lastWriteProgressMS: UInt64 = 0
    /// Last render boundary queued onto this connection, plus panes for which
    /// an intermediate patch was deliberately skipped. All state is confined
    /// to Server.queue.
    private var surfaceCursors: [String: SurfaceCursor] = [:]
    private var dirtySurfaceTargets: [String: SurfaceCursor] = [:]
    private var lastSurfaceCatchUpPaneID: String?
    private(set) var closed = false
    /// A subscriber this far behind isn't reading: disconnect it rather than
    /// buffer forever or drop mid-stream bytes. It can reconnect and get a
    /// fresh ring replay.
    static let highWater = 4 * 1024 * 1024
    /// A legitimate full terminal snapshot can be larger than the streaming
    /// backlog cap. Permit one bounded atomic surface frame without weakening
    /// the 4 MiB protection for raw-output or patch backlogs.
    static let maxSurfaceFrame = 64 * 1024 * 1024
    /// A native surface can replace skipped frames, so byte high-water alone
    /// no longer identifies a client that stopped reading. Drop only after the
    /// socket has made no write progress for a sustained interval.
    private static let writeStallTimeoutMS: UInt64 = 3_000
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
        surfaceCursors.removeAll()
        dirtySurfaceTargets.removeAll()
        lastSurfaceCatchUpPaneID = nil
        backlogWatchGeneration &+= 1
        backlogWatchScheduled = false
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

    var hasOutputBacklog: Bool { !outBuf.isEmpty }

    @discardableResult
    func sendSurfaceFrame(_ m: WireMessage) -> Bool {
        let encoded = FrameCodec.encode(m)
        guard encoded.count <= Conn.maxSurfaceFrame,
              outBuf.isEmpty,
              !oversizedSurfaceFrameInFlight else { return false }
        let oversized = encoded.count > Conn.highWater
        let accepted = sendEncoded(
            encoded,
            highWater: oversized ? encoded.count + Conn.highWater : Conn.highWater)
        if accepted, oversized, !outBuf.isEmpty {
            oversizedSurfaceFrameInFlight = true
        }
        return accepted
    }

    func addSurfaceSubscription(paneID: String, clientID: String) {
        subs.remove(paneID) // one pane never mixes raw and native state
        surfaceSubs[paneID, default: []].insert(clientID)
    }

    func removeSurfaceSubscription(paneID: String, clientID: String) {
        surfaceSubs[paneID]?.remove(clientID)
        if surfaceSubs[paneID]?.isEmpty == true {
            surfaceSubs.removeValue(forKey: paneID)
            clearSurfaceStream(paneID: paneID)
        }
    }

    func hasSurfaceSubscription(paneID: String) -> Bool {
        surfaceSubs[paneID]?.isEmpty == false
    }

    func beginSurfaceStream(paneID: String, epoch: String, revision: UInt64) {
        surfaceCursors[paneID] = SurfaceCursor(epoch: epoch, revision: revision)
    }

    func clearSurfaceStream(paneID: String) {
        surfaceCursors.removeValue(forKey: paneID)
        dirtySurfaceTargets.removeValue(forKey: paneID)
    }

    func markSurfaceDirty(paneID: String, epoch: String, revision: UInt64) {
        dirtySurfaceTargets[paneID] = SurfaceCursor(epoch: epoch, revision: revision)
    }

    func isSurfaceDirty(paneID: String) -> Bool {
        dirtySurfaceTargets[paneID] != nil
    }

    func nextDirtySurfacePaneID(where eligible: (String) -> Bool) -> String? {
        let ids = dirtySurfaceTargets.keys.filter(eligible).sorted()
        guard !ids.isEmpty else { return nil }
        let selected: String
        if let lastSurfaceCatchUpPaneID,
           let next = ids.first(where: { $0 > lastSurfaceCatchUpPaneID }) {
            selected = next
        } else {
            selected = ids[0]
        }
        lastSurfaceCatchUpPaneID = selected
        return selected
    }

    /// Queue one shared broadcast boundary if this connection can preserve
    /// exact stream continuity. A slow normal stream is disconnected at 4 MiB;
    /// while one admitted oversized snapshot drains, replaceable updates are
    /// skipped and healed later with one current snapshot.
    @discardableResult
    func sendSurfacePublication(
        _ data: Data,
        paneID: String,
        epoch: String,
        baseRevision: UInt64?,
        revision: UInt64
    ) -> Bool {
        let target = SurfaceCursor(epoch: epoch, revision: revision)
        guard !isSurfaceDirty(paneID: paneID) else {
            dirtySurfaceTargets[paneID] = target
            return false
        }
        if let baseRevision {
            guard surfaceCursors[paneID] == SurfaceCursor(
                epoch: epoch, revision: baseRevision) else {
                dirtySurfaceTargets[paneID] = target
                return false
            }
        }

        let oversized = data.count > Conn.highWater
        if oversizedSurfaceFrameInFlight || !outBuf.isEmpty {
            dirtySurfaceTargets[paneID] = target
            return false
        }

        let accepted = sendEncoded(
            data,
            highWater: oversized ? data.count + Conn.highWater : Conn.highWater)
        guard accepted else { return false }
        surfaceCursors[paneID] = target
        if oversized, !outBuf.isEmpty { oversizedSurfaceFrameInFlight = true }
        return true
    }

    /// A full catch-up snapshot is broadcast (no request id), so every token
    /// for this pane on the socket observes the same repaired boundary.
    @discardableResult
    func sendSurfaceCatchUp(
        _ message: WireMessage,
        paneID: String,
        epoch: String,
        revision: UInt64
    ) -> Bool {
        guard !closed, outBuf.isEmpty, isSurfaceDirty(paneID: paneID) else { return false }
        guard sendSurfaceFrame(message) else { return false }
        surfaceCursors[paneID] = SurfaceCursor(epoch: epoch, revision: revision)
        dirtySurfaceTargets.removeValue(forKey: paneID)
        return true
    }

    /// server.queue only. Fast path writes inline (non-blocking); leftovers
    /// are buffered whole — never a partial frame drop — and flushed by the
    /// write source when the socket drains.
    @discardableResult
    func sendEncoded(_ data: Data, highWater: Int = Conn.highWater) -> Bool {
        guard !closed else { return false }
        let effectiveHighWater = max(outHighWater, highWater)
        if outBuf.count + data.count > effectiveHighWater {
            dlog("conn fd=\(fd) output backlog over high-water; dropping subscriber")
            server.drop(self)
            return false
        }
        let wasEmpty = outBuf.isEmpty
        if wasEmpty {
            var off = 0
            data.withUnsafeBytes { raw in
                while off < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if n > 0 { off += n } else if errno == EINTR { continue } else { break }
                }
            }
            if off >= data.count { return true }
            outBuf.append(data.dropFirst(off))
        } else {
            outBuf.append(data)
        }
        outHighWater = effectiveHighWater
        if wasEmpty {
            lastWriteProgressMS = monotonicMS()
            scheduleBacklogWatchIfNeeded()
        }
        armWriteSource()
        return true
    }

    private func monotonicMS() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func scheduleBacklogWatchIfNeeded() {
        guard !backlogWatchScheduled, !outBuf.isEmpty, !closed else { return }
        backlogWatchScheduled = true
        backlogWatchGeneration &+= 1
        let generation = backlogWatchGeneration
        server.queue.asyncAfter(
            deadline: .now() + .milliseconds(Int(Self.writeStallTimeoutMS))
        ) { [weak self] in
            self?.checkBacklogWatch(generation: generation)
        }
    }

    private func checkBacklogWatch(generation: UInt64) {
        guard !closed, backlogWatchScheduled,
              backlogWatchGeneration == generation else { return }
        guard !outBuf.isEmpty else {
            backlogWatchScheduled = false
            return
        }
        let now = monotonicMS()
        let elapsed = now >= lastWriteProgressMS ? now - lastWriteProgressMS : 0
        if elapsed >= Self.writeStallTimeoutMS {
            dlog("conn fd=\(fd) made no write progress for \(elapsed)ms; dropping subscriber")
            server.drop(self)
            return
        }
        server.queue.asyncAfter(
            deadline: .now() + .milliseconds(
                Int(Self.writeStallTimeoutMS - elapsed))
        ) { [weak self] in
            self?.checkBacklogWatch(generation: generation)
        }
    }

    private func armWriteSource() {
        guard writeSource == nil, writeFD < 0, !closed, !outBuf.isEmpty else { return }
        // The write source gets its own dup so each source owns exactly one
        // fd copy and closes it in its cancel handler — no double-close races.
        let ownedFD = dup(fd)
        guard ownedFD >= 0 else { return }
        setCloseOnExec(ownedFD)
        writeFD = ownedFD
        let ws = DispatchSource.makeWriteSource(fileDescriptor: ownedFD, queue: server.queue)
        ws.setEventHandler { [weak self] in self?.flushOut() }
        ws.setCancelHandler { [weak self] in
            close(ownedFD)
            self?.writeSourceDidCancel(ownedFD)
        }
        ws.activate()
        writeSource = ws
    }

    private func writeSourceDidCancel(_ ownedFD: Int32) {
        if writeFD == ownedFD { writeFD = -1 }
        guard !closed else { return }
        if outBuf.isEmpty {
            // Yield one state-queue turn before snapshot generation so inbound
            // control traffic is never trapped behind a catch-up loop.
            server.queue.async { [weak self] in
                guard let self, !self.closed, self.outBuf.isEmpty else { return }
                self.server.connectionOutputDrained(self)
            }
        } else {
            armWriteSource()
        }
    }

    private func flushOut() {
        guard !closed else { return }
        while !outBuf.isEmpty {
            let n = outBuf.withUnsafeBytes { raw in
                Darwin.write(writeFD, raw.baseAddress, raw.count)
            }
            if n > 0 {
                outBuf.consume(n)
                lastWriteProgressMS = monotonicMS()
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return // still subscribed; fires again when writable
            } else {
                server.drop(self)
                return
            }
        }
        // Drained: disarm. The cancel handler owns close(writeFD) and schedules
        // catch-up only after that descriptor is closed, avoiding fd-reuse
        // races when a fresh burst immediately arms another source.
        outHighWater = Conn.highWater
        oversizedSurfaceFrameInFlight = false
        backlogWatchScheduled = false
        backlogWatchGeneration &+= 1
        writeSource?.cancel()
        writeSource = nil
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
    private static let resizeLeaseTTLMS: UInt64 = 15_000

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
        // A closed GUI must not retain resize authority until timeout. Tokens
        // are connection-scoped, so revoking these owners cannot affect another
        // window or a replacement connection.
        let ownerPrefix = c.identity + ":"
        for pane in panes.values {
            pane.pendingSurfaceSnapshots.removeAll { $0.connection === c }
            if let ownerID = pane.resizeLease.grant?.ownerID,
               ownerID.hasPrefix(ownerPrefix) {
                _ = pane.resizeLease.revoke(ownerID: ownerID)
            }
        }
        c.stop()
    }

    private func monotonicMS() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func resizeLeaseOwner(_ c: Conn, _ m: WireMessage) -> String? {
        guard let clientID = m.surfaceClientID, !clientID.isEmpty else { return nil }
        return "\(c.identity):\(clientID)"
    }

    private func fillResizeLease(_ m: inout WireMessage, pane: Pane,
                                 grant: ResizeLeaseState.Grant) {
        m.paneID = pane.id
        m.paneEpoch = pane.paneEpoch
        m.resizeLeaseToken = grant.token
        m.resizeLeaseGeneration = grant.generation
        m.resizeLeaseTTLMS = Self.resizeLeaseTTLMS
    }

    private func reply(_ c: Conn, to m: WireMessage, _ type: String, _ mutate: (inout WireMessage) -> Void = { _ in }) {
        var r = WireMessage(type: type)
        r.id = m.id
        mutate(&r)
        c.send(r)
    }

    func hasSurfaceSubscribers(for pane: Pane) -> Bool {
        conns.values.contains { $0.hasSurfaceSubscription(paneID: pane.id) }
    }

    private func surfaceClientID(_ m: WireMessage) -> String? {
        guard let clientID = m.surfaceClientID, !clientID.isEmpty else { return nil }
        return clientID
    }

    @discardableResult
    private func sendSurfaceSnapshot(
        pane: Pane,
        connection c: Conn,
        request: WireMessage,
        registerSubscription: Bool,
        allowDirtyStream: Bool = false
    ) -> Bool {
        guard !c.closed else { return false }
        guard let surface = pane.canonicalSurface else {
            reply(c, to: request, "error") {
                $0.message = "daemon-owned terminal surface unavailable"
            }
            return true
        }
        guard !c.hasOutputBacklog,
              allowDirtyStream || !c.isSurfaceDirty(paneID: pane.id) else { return false }
        do {
            let firstSurfaceSubscriber = !hasSurfaceSubscribers(for: pane)
            if firstSurfaceSubscriber { surface.resetPublicationBaseline() }
            let snapshot = try surface.snapshot()
            var response = WireMessage(type: "surfaceSnapshot")
            response.id = request.id
            response.paneID = pane.id
            response.paneEpoch = pane.paneEpoch
            response.surfaceVersion = Wire.remoteSurfaceVersion
            response.surfaceRevision = snapshot.revision
            response.setSurfaceSnapshot(snapshot.bytes)
            guard c.sendSurfaceFrame(response) else {
                surfaceFailed(
                    pane: pane,
                    error: NSError(
                        domain: "taskdeckd.surface",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "terminal surface snapshot exceeds 64 MiB"]
                    )
                )
                reply(c, to: request, "error") {
                    $0.message = "terminal surface snapshot is too large"
                }
                return true
            }
            if registerSubscription, !c.closed,
               let clientID = surfaceClientID(request) {
                c.addSurfaceSubscription(paneID: pane.id, clientID: clientID)
            }
            if c.hasSurfaceSubscription(paneID: pane.id) {
                c.beginSurfaceStream(
                    paneID: pane.id, epoch: snapshot.epoch, revision: snapshot.revision)
            }
            return true
        } catch {
            surfaceFailed(pane: pane, error: error)
            reply(c, to: request, "error") {
                $0.message = "terminal surface snapshot failed: \(error.localizedDescription)"
            }
            return true
        }
    }

    private func queueOrSendSurfaceSnapshot(
        pane: Pane,
        connection c: Conn,
        request: WireMessage,
        registerSubscription: Bool
    ) {
        guard let surface = pane.canonicalSurface else {
            _ = sendSurfaceSnapshot(pane: pane, connection: c, request: request,
                                    registerSubscription: registerSubscription)
            return
        }
        if surface.synchronizedOutputActive || c.hasOutputBacklog
            || c.isSurfaceDirty(paneID: pane.id) {
            pane.pendingSurfaceSnapshots.append(PendingSurfaceSnapshot(
                connection: c,
                request: request,
                registerSubscription: registerSubscription
            ))
        } else {
            // Align the shared broadcast baseline before issuing a targeted
            // boundary. Existing viewers receive that update first; a request
            // whose own socket becomes backlogged waits for its clean boundary.
            flushCanonicalSurfacePublication(for: pane)
            if c.hasOutputBacklog || c.isSurfaceDirty(paneID: pane.id)
                || !sendSurfaceSnapshot(
                    pane: pane, connection: c, request: request,
                    registerSubscription: registerSubscription) {
                pane.pendingSurfaceSnapshots.append(PendingSurfaceSnapshot(
                    connection: c,
                    request: request,
                    registerSubscription: registerSubscription
                ))
            }
        }
    }

    /// Completes subscriptions/resyncs only after DEC 2026 ends or SwiftTerm's
    /// one-second timeout releases it. All calls occur on the serial state
    /// queue, so the snapshot reply is ordered before every later patch.
    func flushPendingSurfaceSnapshots(for pane: Pane) {
        guard pane.canonicalSurface?.synchronizedOutputActive != true,
              !pane.pendingSurfaceSnapshots.isEmpty else { return }
        let pending = pane.pendingSurfaceSnapshots
        pane.pendingSurfaceSnapshots.removeAll(keepingCapacity: true)
        var remaining: [PendingSurfaceSnapshot] = []
        remaining.reserveCapacity(pending.count)
        for item in pending {
            guard let c = item.connection, !c.closed else { continue }
            guard !c.hasOutputBacklog,
                  sendSurfaceSnapshot(
                pane: pane,
                connection: c,
                request: item.request,
                registerSubscription: item.registerSubscription,
                // A request/response boundary must not starve behind an
                // endlessly renewed generic catch-up. Keep the dirty marker:
                // this targeted frame heals its token, then an unsolicited
                // snapshot repairs every other token on the same socket.
                allowDirtyStream: true
                  ) else {
                remaining.append(item)
                continue
            }
        }
        pane.pendingSurfaceSnapshots.append(contentsOf: remaining)
    }

    private func cancelPendingSurfaceSnapshots(
        pane: Pane,
        connection: Conn,
        clientID: String
    ) {
        pane.pendingSurfaceSnapshots.removeAll {
            $0.connection === connection && $0.request.surfaceClientID == clientID
        }
    }

    func surfaceFailed(pane: Pane, error: Error) {
        guard pane.canonicalSurface != nil else { return }
        dlog("pane \(pane.id) canonical surface failed: \(error)")

        if !pane.pendingSurfaceSnapshots.isEmpty {
            let pending = pane.pendingSurfaceSnapshots
            pane.pendingSurfaceSnapshots.removeAll()
            for item in pending {
                guard let c = item.connection, !c.closed else { continue }
                reply(c, to: item.request, "error") {
                    $0.message = "terminal surface failed: \(error.localizedDescription)"
                }
            }
        }

        var event = WireMessage(type: "surfaceError")
        event.paneID = pane.id
        event.paneEpoch = pane.paneEpoch
        event.message = error.localizedDescription
        let encoded = FrameCodec.encode(event)
        for c in Array(conns.values) where c.hasSurfaceSubscription(paneID: pane.id) {
            c.sendEncoded(encoded)
            c.surfaceSubs.removeValue(forKey: pane.id)
            c.clearSurfaceStream(paneID: pane.id)
        }
        // Export invariants do not heal on the next PTY chunk (unsupported
        // images are the common example). Disable once and leave raw replay
        // running so the GUI can explicitly fall back without log storms.
        pane.canonicalSurface = nil
    }

    func canonicalSynchronizedOutputEnded(
        pane: Pane,
        surface: CanonicalSurfaceProviding
    ) {
        guard pane.canonicalSurface === surface else { return }
        flushCanonicalSurfacePublication(for: pane)
        flushPendingSurfaceSnapshots(for: pane)
    }

    /// Export at most one update from the shared pane baseline. PTY parsing is
    /// immediate; callers are either the 16 ms coalescing tick, a snapshot
    /// boundary, or DEC 2026's explicit/timeout completion.
    func flushCanonicalSurfacePublication(for pane: Pane) {
        guard let surface = pane.canonicalSurface,
              !surface.synchronizedOutputActive else { return }
        do {
            if let publication = try surface.flushSynchronizedOutput(
                wantsPublication: hasSurfaceSubscribers(for: pane)
            ) {
                broadcastSurfacePublication(pane: pane, publication: publication)
            }
        } catch {
            surfaceFailed(pane: pane, error: error)
        }
    }

    /// Called only after a connection's buffered byte stream is completely
    /// drained. Repair one dirty pane per state-queue turn (round-robin by id),
    /// then retry request snapshots. This avoids a multi-pane snapshot herd.
    func connectionOutputDrained(_ c: Conn) {
        guard !c.closed, conns[ObjectIdentifier(c)] === c,
              !c.hasOutputBacklog else { return }

        // Explicit initial/resync replies have priority over replaceable
        // catch-up traffic. Otherwise sustained output can dirty the stream
        // again after every catch-up snapshot and starve the request forever.
        for pane in panes.values.sorted(by: { $0.id < $1.id })
        where pane.pendingSurfaceSnapshots.contains(where: { $0.connection === c }) {
            guard pane.canonicalSurface?.synchronizedOutputActive != true else { continue }
            flushPendingSurfaceSnapshots(for: pane)
            if !c.closed, !c.hasOutputBacklog {
                queue.async { [weak self, weak c] in
                    guard let self, let c else { return }
                    self.connectionOutputDrained(c)
                }
            }
            return
        }

        if let paneID = c.nextDirtySurfacePaneID(where: { paneID in
            guard let pane = self.panes[paneID] else { return true }
            return pane.canonicalSurface?.synchronizedOutputActive != true
        }) {
            guard let pane = panes[paneID],
                  c.hasSurfaceSubscription(paneID: paneID) else {
                c.clearSurfaceStream(paneID: paneID)
                queue.async { [weak self, weak c] in
                    guard let self, let c else { return }
                    self.connectionOutputDrained(c)
                }
                return
            }
            guard pane.canonicalSurface?.synchronizedOutputActive != true else { return }
            sendSurfaceCatchUp(pane: pane, connection: c)
            if !c.closed, !c.hasOutputBacklog {
                queue.async { [weak self, weak c] in
                    guard let self, let c else { return }
                    self.connectionOutputDrained(c)
                }
            }
            return
        }
    }

    private func sendSurfaceCatchUp(pane: Pane, connection c: Conn) {
        guard let surface = pane.canonicalSurface, !c.closed,
              !c.hasOutputBacklog, c.isSurfaceDirty(paneID: pane.id) else { return }
        do {
            let snapshot = try surface.snapshot()
            var message = WireMessage(type: "surfaceSnapshot")
            message.paneID = pane.id
            message.paneEpoch = pane.paneEpoch
            message.surfaceVersion = Wire.remoteSurfaceVersion
            message.surfaceRevision = snapshot.revision
            message.setSurfaceSnapshot(snapshot.bytes)
            let frameSize = FrameCodec.encode(message).count
            guard frameSize <= Conn.maxSurfaceFrame else {
                surfaceFailed(
                    pane: pane,
                    error: NSError(
                        domain: "taskdeckd.surface",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "terminal catch-up snapshot exceeds 64 MiB"]
                    )
                )
                return
            }
            _ = c.sendSurfaceCatchUp(
                message, paneID: pane.id,
                epoch: snapshot.epoch, revision: snapshot.revision)
        } catch {
            surfaceFailed(pane: pane, error: error)
        }
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
                pane.installCanonicalSurface()
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
            // Selecting the compatibility path for a pane tears down native
            // delivery on this connection; one viewer must never parse raw
            // bytes after accepting a canonical snapshot.
            c.surfaceSubs.removeValue(forKey: pid)
            c.clearSurfaceStream(paneID: pid)
            pane.pendingSurfaceSnapshots.removeAll { $0.connection === c }
            c.subs.insert(pid)
            reply(c, to: m, "replay") {
                $0.paneID = pid
                $0.setData(pane.ring.snapshot())
                $0.cols = pane.cols
                $0.rows = pane.rows
                // Available even on the raw compatibility path so a new client
                // can safely bind follow-up lease requests to this pane lifetime.
                $0.paneEpoch = pane.paneEpoch
            }

        case "unsubscribe":
            if let pid = m.paneID { c.subs.remove(pid) }

        case "subscribeSurface":
            guard let pid = m.paneID, let pane = panes[pid] else {
                reply(c, to: m, "error") { $0.message = "no such pane" }
                return
            }
            guard let requestedVersion = m.surfaceVersion,
                  requestedVersion >= Wire.remoteSurfaceVersion else {
                reply(c, to: m, "error") { $0.message = "unsupported terminal surface version" }
                return
            }
            guard surfaceClientID(m) != nil else {
                reply(c, to: m, "error") { $0.message = "missing surface client id" }
                return
            }
            queueOrSendSurfaceSnapshot(
                pane: pane,
                connection: c,
                request: m,
                registerSubscription: true
            )

        case "surfaceResync":
            guard let pid = m.paneID, let pane = panes[pid] else {
                reply(c, to: m, "error") { $0.message = "no such pane" }
                return
            }
            guard let clientID = surfaceClientID(m),
                  c.surfaceSubs[pid]?.contains(clientID) == true else {
                reply(c, to: m, "error") { $0.message = "surface is not subscribed" }
                return
            }
            queueOrSendSurfaceSnapshot(
                pane: pane,
                connection: c,
                request: m,
                registerSubscription: false
            )

        case "unsubscribeSurface":
            if let pid = m.paneID, let clientID = surfaceClientID(m) {
                c.removeSurfaceSubscription(paneID: pid, clientID: clientID)
                if let pane = panes[pid] {
                    cancelPendingSurfaceSnapshots(
                        pane: pane,
                        connection: c,
                        clientID: clientID
                    )
                }
            }
            if m.id != nil { reply(c, to: m, "ok") }

        case "acquireResizeLease":
            guard let pid = m.paneID, let pane = panes[pid] else {
                reply(c, to: m, "error") { $0.message = "no such pane" }
                return
            }
            guard m.paneEpoch == pane.paneEpoch else {
                reply(c, to: m, "error") { $0.message = "stale or missing pane epoch" }
                return
            }
            guard let ownerID = resizeLeaseOwner(c, m) else {
                reply(c, to: m, "error") { $0.message = "missing surface client id" }
                return
            }
            guard let grant = pane.resizeLease.acquire(
                ownerID: ownerID, nowMS: monotonicMS(), ttlMS: Self.resizeLeaseTTLMS
            ) else {
                reply(c, to: m, "resizeLeaseBusy") {
                    $0.paneID = pid
                    $0.paneEpoch = pane.paneEpoch
                    $0.resizeLeaseTTLMS = Self.resizeLeaseTTLMS
                }
                return
            }
            reply(c, to: m, "resizeLease") {
                self.fillResizeLease(&$0, pane: pane, grant: grant)
            }

        case "claimResizeLease":
            guard let pid = m.paneID, let pane = panes[pid] else {
                reply(c, to: m, "error") { $0.message = "no such pane" }
                return
            }
            guard m.paneEpoch == pane.paneEpoch else {
                reply(c, to: m, "error") { $0.message = "stale or missing pane epoch" }
                return
            }
            guard let ownerID = resizeLeaseOwner(c, m),
                  let grant = pane.resizeLease.claim(
                      ownerID: ownerID, nowMS: monotonicMS(), ttlMS: Self.resizeLeaseTTLMS
                  ) else {
                reply(c, to: m, "error") { $0.message = "missing surface client id" }
                return
            }
            reply(c, to: m, "resizeLease") {
                self.fillResizeLease(&$0, pane: pane, grant: grant)
            }

        case "renewResizeLease":
            guard let pid = m.paneID, let pane = panes[pid],
                  m.paneEpoch == pane.paneEpoch,
                  let ownerID = resizeLeaseOwner(c, m),
                  let token = m.resizeLeaseToken,
                  let generation = m.resizeLeaseGeneration,
                  let grant = pane.resizeLease.validateAndRenew(
                      ownerID: ownerID, token: token, generation: generation,
                      nowMS: monotonicMS(), ttlMS: Self.resizeLeaseTTLMS
                  ) else {
                reply(c, to: m, "error") { $0.message = "resize lease lost" }
                return
            }
            reply(c, to: m, "resizeLease") {
                self.fillResizeLease(&$0, pane: pane, grant: grant)
            }

        case "releaseResizeLease":
            guard let pid = m.paneID, let pane = panes[pid],
                  m.paneEpoch == pane.paneEpoch,
                  let ownerID = resizeLeaseOwner(c, m),
                  let token = m.resizeLeaseToken,
                  let generation = m.resizeLeaseGeneration,
                  pane.resizeLease.release(ownerID: ownerID, token: token,
                                           generation: generation) else {
                // Release is normally fire-and-forget during view teardown.
                // Do not emit an unsolicited error event for an already
                // expired/preempted lease.
                if m.id != nil {
                    reply(c, to: m, "error") { $0.message = "resize lease lost" }
                }
                return
            }
            if m.id != nil { reply(c, to: m, "ok") }

        case "surfaceResize":
            guard let pid = m.paneID, let pane = panes[pid],
                  m.paneEpoch == pane.paneEpoch,
                  let ownerID = resizeLeaseOwner(c, m),
                  let token = m.resizeLeaseToken,
                  let generation = m.resizeLeaseGeneration,
                  pane.resizeLease.validateAndRenew(
                      ownerID: ownerID, token: token, generation: generation,
                      nowMS: monotonicMS(), ttlMS: Self.resizeLeaseTTLMS
                  ) != nil else {
                // Resizes are normally fire-and-forget; only answer a caller
                // that supplied a request id, avoiding unsolicited error events.
                if m.id != nil {
                    reply(c, to: m, "error") { $0.message = "resize lease lost" }
                }
                return
            }
            if let cols = m.cols, let rows = m.rows {
                pane.resize(cols: cols, rows: rows)
            }
            if m.id != nil { reply(c, to: m, "ok") }

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
                for connection in conns.values {
                    connection.subs.remove(pid)
                    connection.surfaceSubs.removeValue(forKey: pid)
                    connection.clearSurfaceStream(paneID: pid)
                }
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
        for c in Array(conns.values)
        where c.subs.contains(pane.id) && !c.hasSurfaceSubscription(paneID: pane.id) {
            c.sendEncoded(encoded)
        }
    }

    func broadcastSurfacePublication(pane: Pane, publication: EncodedSurfacePublication) {
        guard hasSurfaceSubscribers(for: pane) else { return }
        var message: WireMessage
        let epoch: String
        let baseRevision: UInt64?
        let revision: UInt64
        switch publication {
        case .snapshot(let snapshot):
            message = WireMessage(type: "surfaceSnapshot")
            message.surfaceRevision = snapshot.revision
            message.setSurfaceSnapshot(snapshot.bytes)
            epoch = snapshot.epoch
            baseRevision = nil
            revision = snapshot.revision
        case .patch(let patch):
            message = WireMessage(type: "surfacePatch")
            message.surfaceBaseRevision = patch.baseRevision
            message.surfaceRevision = patch.revision
            message.setSurfacePatch(patch.bytes)
            epoch = patch.epoch
            baseRevision = patch.baseRevision
            revision = patch.revision
        }
        message.paneID = pane.id
        message.paneEpoch = pane.paneEpoch
        message.surfaceVersion = Wire.remoteSurfaceVersion
        let encoded = FrameCodec.encode(message)
        guard encoded.count <= Conn.maxSurfaceFrame else {
            surfaceFailed(
                pane: pane,
                error: NSError(
                    domain: "taskdeckd.surface",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "terminal surface update exceeds 64 MiB"]
                )
            )
            return
        }
        for c in Array(conns.values) where c.hasSurfaceSubscription(paneID: pane.id) {
            _ = c.sendSurfacePublication(
                encoded,
                paneID: pane.id,
                epoch: epoch,
                baseRevision: baseRevision,
                revision: revision
            )
            if !c.closed, !c.hasOutputBacklog, c.isSurfaceDirty(paneID: pane.id) {
                queue.async { [weak self, weak c] in
                    guard let self, let c else { return }
                    self.connectionOutputDrained(c)
                }
            }
        }
    }

    /// Semantic side effects are parsed only by the canonical terminal. Send
    /// one frame per socket, not one per view token, so opening two windows on
    /// the same GUI connection never doubles bells, clipboard writes, or OS
    /// notifications.
    func broadcastSurfaceEvent(
        pane: Pane,
        kind: String,
        _ populate: (inout WireMessage) -> Void = { _ in }
    ) {
        guard hasSurfaceSubscribers(for: pane) else { return }
        var message = WireMessage(type: "surfaceEvent")
        message.paneID = pane.id
        message.paneEpoch = pane.paneEpoch
        message.surfaceVersion = Wire.remoteSurfaceVersion
        message.surfaceEvent = kind
        populate(&message)
        let encoded = FrameCodec.encode(message)
        for c in Array(conns.values) where c.hasSurfaceSubscription(paneID: pane.id) {
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
