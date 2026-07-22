import Darwin
import Foundation

/// Wire protocol between the GUI / ctl clients and taskdeckd.
/// Frames: 4-byte big-endian length + JSON body (`WireMessage`).
/// Binary payloads (terminal I/O) travel base64-encoded in `data`.
public enum Wire {
    /// Bump on breaking protocol changes. Keep changes additive whenever possible:
    /// a daemon restart kills every live terminal session the user has.
    public static let version = 1

    /// Production socket lives in App Support. Tests inject TASKDECK_SOCKET
    /// (or `taskdeckd/ctl --socket`) to run an ISOLATED daemon on a temp
    /// socket without ever touching the real one — required because a daemon
    /// restart kills every live terminal.
    public static func socketPath() -> String {
        if let env = ProcessInfo.processInfo.environment["TASKDECK_SOCKET"], !env.isEmpty {
            return env
        }
        return Paths.appSupport.appendingPathComponent("daemon.sock").path
    }
}

public struct PaneInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var taskID: String
    public var specID: String
    public var title: String
    public var cwd: String
    public var pid: Int32
    public var running: Bool
    public var exitCode: Int32?
    public var cols: Int
    public var rows: Int

    public init(id: String, taskID: String, specID: String, title: String, cwd: String,
                pid: Int32, running: Bool, exitCode: Int32?, cols: Int, rows: Int) {
        self.id = id
        self.taskID = taskID
        self.specID = specID
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.running = running
        self.exitCode = exitCode
        self.cols = cols
        self.rows = rows
    }
}

public struct WireMessage: Codable {
    public var type: String
    public var id: String?
    public var version: Int?
    public var paneID: String?
    public var taskID: String?
    public var specID: String?
    public var title: String?
    public var cwd: String?
    public var command: String?
    public var shell: String?
    public var env: [String: String]?
    public var data: String?
    public var cols: Int?
    public var rows: Int?
    public var message: String?
    public var exitCode: Int32?
    public var panes: [PaneInfo]?

    public init(type: String) { self.type = type }

    public var dataBytes: [UInt8]? {
        guard let d = data, let dec = Data(base64Encoded: d) else { return nil }
        return [UInt8](dec)
    }

    public mutating func setData(_ bytes: [UInt8]) {
        data = Data(bytes).base64EncodedString()
    }
}

/// Growable FIFO byte buffer with an amortized-O(1) head: `consume` advances
/// an offset and the storage is compacted only occasionally. Replaces the
/// `Array.removeFirst(n)` pattern (an O(count) memmove per chunk) in the hot
/// paths: pane ring buffers, pending PTY writes, per-connection output
/// queues and the frame reader.
public struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    public init() {}

    public var count: Int { storage.count - head }
    public var isEmpty: Bool { head >= storage.count }

    public mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        storage.append(contentsOf: bytes)
    }

    /// Drop `n` bytes from the front (amortized O(1)).
    public mutating func consume(_ n: Int) {
        head = min(storage.count, head + n)
        // Compact once the dead prefix dominates — keeps memory bounded
        // without paying a memmove per consume.
        if head > 64 * 1024, head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// Keep only the newest `n` bytes (ring-buffer trim).
    public mutating func trimFront(toCount n: Int) {
        if count > n { consume(count - n) }
    }

    public mutating func removeAll() {
        storage.removeAll()
        head = 0
    }

    /// Contiguous view of the unconsumed bytes.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try storage.withUnsafeBytes { raw in
            try body(UnsafeRawBufferPointer(rebasing: raw[head...]))
        }
    }

    public func snapshot() -> [UInt8] { Array(storage[head...]) }

    /// Byte at logical index (0 = oldest unconsumed).
    public subscript(_ i: Int) -> UInt8 { storage[head + i] }
}

public enum FrameCodec {
    public static func encode(_ m: WireMessage) -> Data {
        let body = (try? JSONEncoder().encode(m)) ?? Data()
        var out = Data(capacity: body.count + 4)
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Incremental frame parser. Feed raw socket bytes with `append`, pull
    /// complete messages with `next()`.
    public final class Reader {
        private var buffer = ByteQueue()

        public init() {}

        public func append(_ d: Data) { buffer.append(d) }

        public func next() -> WireMessage? {
            while buffer.count >= 4 {
                let len = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard len >= 0, len < 64 * 1024 * 1024 else { buffer.removeAll(); return nil }
                guard buffer.count >= 4 + len else { return nil }
                let body = buffer.withUnsafeBytes { raw in Data(raw[4 ..< 4 + len]) }
                buffer.consume(4 + len)
                if let m = try? JSONDecoder().decode(WireMessage.self, from: body) { return m }
                // Undecodable frame: skip it and keep parsing.
            }
            return nil
        }
    }
}

/// Mark a descriptor close-on-exec. Every long-lived fd in the daemon (log,
/// lock, listener, client conns, PTY masters) and the GUI (daemon socket,
/// kqueue watchers) must carry this: panes are spawned via forkpty→execve and
/// GUI helpers via Process, so an unmarked fd leaks into every child — pane N
/// inheriting the previous N−1 PTY masters kept EOFs from ever arriving and
/// grew per-child fd tables quadratically.
public func setCloseOnExec(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFD)
    if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
}

public func sockaddrUn(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        bytes.withUnsafeBytes { src in
            dst.copyBytes(from: src.prefix(dst.count - 1))
        }
    }
    return addr
}

/// Minimal synchronous client, used by taskdeckctl and tests.
public final class BlockingConn {
    public let fd: Int32
    private let reader = FrameCodec.Reader()
    private let sendLock = NSLock()

    public init?(path: String = Wire.socketPath()) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setCloseOnExec(fd)
        var addr = sockaddrUn(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { close(fd); return nil }
    }

    deinit { if fd >= 0 { close(fd) } }

    public func send(_ m: WireMessage) {
        let d = FrameCodec.encode(m)
        sendLock.lock()
        defer { sendLock.unlock() }
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n > 0 { off += n } else if errno == EINTR { continue } else { break }
            }
        }
    }

    /// Blocking read of the next frame. Returns nil on EOF or socket timeout.
    public func recv() -> WireMessage? {
        if let m = reader.next() { return m }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            reader.append(Data(buf[0 ..< n]))
            if let m = reader.next() { return m }
        }
    }

    public func request(_ m: WireMessage) -> WireMessage? {
        var mm = m
        mm.id = UUID().uuidString
        send(mm)
        while let r = recv() {
            if r.id == mm.id { return r }
        }
        return nil
    }
}
