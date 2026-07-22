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
        private var buffer = [UInt8]()

        public init() {}

        public func append(_ d: Data) { buffer.append(contentsOf: d) }

        public func next() -> WireMessage? {
            while buffer.count >= 4 {
                let len = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard len >= 0, len < 64 * 1024 * 1024 else { buffer.removeAll(); return nil }
                guard buffer.count >= 4 + len else { return nil }
                let body = Data(buffer[4 ..< 4 + len])
                buffer.removeSubrange(0 ..< 4 + len)
                if let m = try? JSONDecoder().decode(WireMessage.self, from: body) { return m }
                // Undecodable frame: skip it and keep parsing.
            }
            return nil
        }
    }
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
