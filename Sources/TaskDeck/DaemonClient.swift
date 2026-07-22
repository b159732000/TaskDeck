import Darwin
import Foundation
import TaskDeckCore

/// Async client for taskdeckd. Spawns the daemon on demand (it outlives the
/// app — that's the point: relaunching the GUI never kills terminals).
final class DaemonClient {
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "taskdeck.client")
    private var readSource: DispatchSourceRead?
    private let reader = FrameCodec.Reader()
    private var pending: [String: (WireMessage?) -> Void] = [:]
    private var paneHandlers: [String: [UUID: ([UInt8]) -> Void]] = [:]

    var onEvent: ((WireMessage) -> Void)?
    var onDisconnect: (() -> Void)?

    var isConnected: Bool { fd >= 0 }

    func connectOrSpawn() async -> Bool {
        if await withCheckedContinuation({ (cont: CheckedContinuation<Bool, Never>) in
            queue.async { cont.resume(returning: self.connectOnce()) }
        }) { return true }

        spawnDaemon()
        for _ in 0 ..< 25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                queue.async { cont.resume(returning: self.connectOnce()) }
            }
            if ok { return true }
        }
        return false
    }

    private func connectOnce() -> Bool {
        guard fd < 0 else { return true }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddrUn(Wire.socketPath())
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok {
            close(s)
            return false
        }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.readable() }
        src.activate()
        readSource = src
        var hello = WireMessage(type: "hello")
        hello.version = Wire.version
        sendRaw(hello)
        return true
    }

    private func spawnDaemon() {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var candidates = [exe.deletingLastPathComponent().appendingPathComponent("taskdeckd")]
        if let override = ProcessInfo.processInfo.environment["TASKDECK_DAEMON"] {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return
        }
        let p = Process()
        p.executableURL = url
        p.arguments = ["serve"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func readable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            reader.append(Data(buf[0 ..< n]))
            while let m = reader.next() { route(m) }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            teardown()
        }
    }

    private func teardown() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        let callbacks = pending
        pending.removeAll()
        for (_, cb) in callbacks { cb(nil) }
        onDisconnect?()
    }

    private func route(_ m: WireMessage) {
        if let id = m.id, let cb = pending.removeValue(forKey: id) {
            cb(m)
            return
        }
        if m.type == "output", let paneID = m.paneID, let bytes = m.dataBytes {
            if let handlers = paneHandlers[paneID], !handlers.isEmpty {
                let hs = Array(handlers.values)
                DispatchQueue.main.async { for h in hs { h(bytes) } }
            }
            return
        }
        onEvent?(m)
    }

    // MARK: - API

    func request(_ m: WireMessage, completion: @escaping (WireMessage?) -> Void) {
        queue.async {
            guard self.fd >= 0 else { completion(nil); return }
            var mm = m
            mm.id = UUID().uuidString
            self.pending[mm.id!] = completion
            self.sendRaw(mm)
        }
    }

    func fire(_ m: WireMessage) {
        queue.async { self.sendRaw(m) }
    }

    /// Subscribe to a pane's output. The daemon replies with a ring-buffer
    /// replay which is delivered through the same handler, then live output.
    func subscribe(paneID: String,
                   replaySize: ((_ cols: Int, _ rows: Int) -> Void)? = nil,
                   handler: @escaping ([UInt8]) -> Void) -> UUID {
        let token = UUID()
        queue.async {
            self.paneHandlers[paneID, default: [:]][token] = handler
            var m = WireMessage(type: "subscribe")
            m.paneID = paneID
            m.id = UUID().uuidString
            self.pending[m.id!] = { resp in
                let size: (Int, Int)? = {
                    if let c = resp?.cols, let r = resp?.rows { return (c, r) }
                    return nil
                }()
                if let bytes = resp?.dataBytes {
                    DispatchQueue.main.async {
                        if let size { replaySize?(size.0, size.1) } // size buffer before feeding
                        handler(bytes)
                    }
                }
            }
            self.sendRaw(m)
        }
        return token
    }

    func unsubscribe(paneID: String, token: UUID) {
        queue.async {
            self.paneHandlers[paneID]?.removeValue(forKey: token)
            if self.paneHandlers[paneID]?.isEmpty == true {
                self.paneHandlers.removeValue(forKey: paneID)
                var m = WireMessage(type: "unsubscribe")
                m.paneID = paneID
                self.sendRaw(m)
            }
        }
    }

    private func sendRaw(_ m: WireMessage) {
        guard fd >= 0 else { return }
        let d = FrameCodec.encode(m)
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n > 0 { off += n } else if errno == EINTR { continue } else { break }
            }
        }
    }
}
