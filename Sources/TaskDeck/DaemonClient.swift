import Darwin
import Foundation
import TaskDeckCore

/// Opaque SwiftTerm-native update delivered in socket order. Decoding stays
/// outside the transport so DaemonClient does not make the terminal DTO part
/// of TaskDeckCore's wire protocol.
struct TerminalSurfacePacket {
    enum Kind: Equatable { case snapshot, patch }

    let kind: Kind
    let bytes: [UInt8]
    let paneEpoch: String
    let revision: UInt64
    let baseRevision: UInt64?
}

/// Async client for taskdeckd. Spawns the daemon on demand (it outlives the
/// app — that's the point: relaunching the GUI never kills terminals).
final class DaemonClient {
    private final class PaneSubscription {
        let handler: ([UInt8]) -> Void
        var output = ReplayFirstOutputBuffer()

        init(handler: @escaping ([UInt8]) -> Void) {
            self.handler = handler
        }
    }

    /// One delivery queue per view preserves snapshot/patch order while JSON
    /// decoding happens away from the main thread. Raw callbacks are retained
    /// here so every viewer of a pane can fall back together: taskdeckd
    /// deliberately forbids mixing native-state and raw parsing for one pane
    /// on the same socket.
    private final class SurfaceSubscription {
        let clientID: String
        let deliveryQueue: DispatchQueue
        /// The generation is the newest delivery-overflow generation covered
        /// by this packet's socket position. It is meaningful for snapshots:
        /// the view can distinguish a drop healed by this authority boundary
        /// from another drop that happened after the snapshot was received.
        let surfaceHandler: (TerminalSurfacePacket, UInt64, @escaping () -> Void) -> Void
        let surfaceEventHandler: (WireMessage, @escaping () -> Void) -> Void
        let overflowHandler: (UInt64) -> Void
        let rawReplay: (_ bytes: [UInt8], _ cols: Int?, _ rows: Int?) -> Void
        let rawHandler: ([UInt8]) -> Void
        let fallbackHandler: (String) -> Void
        var resyncPending = false
        var pendingRequestIDs = Set<String>()
        /// Client-queue confined. Each accepted delivery remains here until the
        /// main thread has applied or deliberately discarded it. IDs make the
        /// acknowledgement idempotent; the byte total bounds large DTOs in
        /// addition to the count bound.
        private var outstandingDeliveries: [UInt64: Int] = [:]
        private var outstandingDeliveryBytes = 0
        private var nextDeliveryID: UInt64 = 0
        private var overflowOpen = false
        private var overflowGeneration: UInt64 = 0
        static let deliveryCap = 128
        static let deliveryByteCap = 16 * 1024 * 1024

        init(token: UUID,
             surfaceHandler: @escaping (TerminalSurfacePacket, UInt64,
                                         @escaping () -> Void) -> Void,
             surfaceEventHandler: @escaping (WireMessage, @escaping () -> Void) -> Void,
             overflowHandler: @escaping (UInt64) -> Void,
             rawReplay: @escaping (_ bytes: [UInt8], _ cols: Int?, _ rows: Int?) -> Void,
             rawHandler: @escaping ([UInt8]) -> Void,
             fallbackHandler: @escaping (String) -> Void) {
            clientID = token.uuidString.lowercased()
            deliveryQueue = DispatchQueue(
                label: "taskdeck.surface.\(token.uuidString.lowercased())",
                qos: .userInteractive)
            self.surfaceHandler = surfaceHandler
            self.surfaceEventHandler = surfaceEventHandler
            self.overflowHandler = overflowHandler
            self.rawReplay = rawReplay
            self.rawHandler = rawHandler
            self.fallbackHandler = fallbackHandler
        }

        /// Called on DaemonClient.queue. Only request-response snapshots are
        /// priority deliveries. Unsolicited full snapshots remain bounded: a
        /// PTY can emit repeated resets, so treating every snapshot as priority
        /// would make the delivery queue unbounded again.
        func deliver(_ packet: TerminalSurfacePacket,
                     priority: Bool = false,
                     clientQueue: DispatchQueue) {
            guard let deliveryID = reserveDelivery(
                byteCost: packet.bytes.count, priority: priority
            ) else {
                signalOverflowIfNeeded()
                return
            }
            let coveredOverflowGeneration = overflowGeneration
            if packet.kind == .snapshot {
                // This full state supersedes every dropped socket delivery that
                // preceded it. A later drop must create a fresh notification,
                // even if older UI acknowledgements have not drained yet.
                overflowOpen = false
            }
            deliveryQueue.async { [weak self, surfaceHandler] in
                guard let self else { return }
                surfaceHandler(packet, coveredOverflowGeneration) { [weak self] in
                    clientQueue.async { self?.acknowledgeDelivery(deliveryID) }
                }
            }
        }

        /// Called on DaemonClient.queue. View-local progress is expendable once
        /// the screen-update cap is reached; socket-wide side effects are routed
        /// separately through AppModel and are never lost here.
        func deliver(event: WireMessage, clientQueue: DispatchQueue) {
            guard let deliveryID = reserveDelivery(
                byteCost: Self.deliveryCost(of: event), priority: false
            ) else {
                signalOverflowIfNeeded()
                return
            }
            deliveryQueue.async { [weak self, surfaceEventHandler] in
                guard let self else { return }
                surfaceEventHandler(event) { [weak self] in
                    clientQueue.async { self?.acknowledgeDelivery(deliveryID) }
                }
            }
        }

        private func reserveDelivery(byteCost: Int, priority: Bool) -> UInt64? {
            let cost = max(1, byteCost)
            let fitsCount = outstandingDeliveries.count < Self.deliveryCap
            let fitsBytes = cost <= Self.deliveryByteCap
                && outstandingDeliveryBytes <= Self.deliveryByteCap - cost
            guard priority || (fitsCount && fitsBytes) else { return nil }

            repeat { nextDeliveryID &+= 1 }
            while outstandingDeliveries[nextDeliveryID] != nil
            let deliveryID = nextDeliveryID
            outstandingDeliveries[deliveryID] = cost
            let (sum, overflow) = outstandingDeliveryBytes.addingReportingOverflow(cost)
            outstandingDeliveryBytes = overflow ? Int.max : sum
            return deliveryID
        }

        private static func deliveryCost(of event: WireMessage) -> Int {
            // Events are normally tiny, but OSC-52 clipboard payloads are not.
            // Count the retained strings plus a small object/closure allowance.
            var result = 512
            for value in [event.data, event.title, event.cwd, event.message].compactMap({ $0 }) {
                let (sum, overflow) = result.addingReportingOverflow(value.utf8.count)
                result = overflow ? Int.max : sum
            }
            return result
        }

        private func signalOverflowIfNeeded() {
            guard !overflowOpen else { return }
            overflowOpen = true
            overflowGeneration &+= 1
            let generation = overflowGeneration
            deliveryQueue.async { [overflowHandler] in overflowHandler(generation) }
        }

        private func acknowledgeDelivery(_ deliveryID: UInt64) {
            guard let cost = outstandingDeliveries.removeValue(forKey: deliveryID) else {
                return
            }
            outstandingDeliveryBytes = max(0, outstandingDeliveryBytes - cost)
        }

        var paneEpoch: String?
    }

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "taskdeck.client")
    private var readSource: DispatchSourceRead?
    // Fresh per connection: a half-received frame from a dropped connection
    // must not desync parsing of the next one.
    private var reader = FrameCodec.Reader()
    private var pending: [String: (WireMessage?) -> Void] = [:]
    private var paneSubscriptions: [String: [UUID: PaneSubscription]] = [:]
    private var surfaceSubscriptions: [String: [UUID: SurfaceSubscription]] = [:]

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
        setCloseOnExec(s) // don't leak into Process children (quota, osascript)
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
        reader = FrameCodec.Reader() // never inherit a previous connection's half-frame
        outFlushScheduled = false
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.readable() }
        src.activate()
        readSource = src
        // Handshake (hello + version check) is driven by AppModel as a real
        // request so drift is detected, not fired blind from here.
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
        for subscriptions in paneSubscriptions.values {
            for subscription in subscriptions.values { subscription.output.cancel() }
        }
        paneSubscriptions.removeAll()
        surfaceSubscriptions.removeAll()
        outFlushScheduled = false
        onDisconnect?()
    }

    // Output frames are coalesced per subscription and delivered at most once
    // per main-loop pass. Per-token queues are essential: a newly attached
    // view must receive its replay before any live output, and must never
    // inherit bytes pending for a view that was just dismantled.
    private var outFlushScheduled = false

    private func route(_ m: WireMessage) {
        if let id = m.id, let cb = pending.removeValue(forKey: id) {
            cb(m)
            return
        }
        if m.type == "surfaceSnapshot" || m.type == "surfacePatch" {
            guard let paneID = m.paneID,
                  let packet = surfacePacket(from: m) else {
                if let paneID = m.paneID {
                    fallbackSurfacePaneToLegacy(
                        paneID: paneID,
                        reason: "daemon 回傳的 terminal surface 格式不完整")
                }
                return
            }
            guard let subscriptions = surfaceSubscriptions[paneID],
                  !subscriptions.isEmpty else { return }
            for subscription in subscriptions.values {
                // A resync snapshot is a request response (and is routed by
                // `pending`). Ignore older broadcasts until that boundary.
                guard !subscription.resyncPending else { continue }
                // Another viewer on this socket may already be active. Its
                // patches can precede this token's initial snapshot response;
                // that snapshot includes them, so the waiting token drops them.
                guard subscription.paneEpoch != nil else { continue }
                guard subscription.paneEpoch == packet.paneEpoch else {
                    fallbackSurfacePaneToLegacy(
                        paneID: paneID,
                        reason: "terminal pane lifetime 已改變")
                    return
                }
                subscription.deliver(packet, clientQueue: queue)
            }
            return
        }
        if m.type == "surfaceError", let paneID = m.paneID {
            fallbackSurfacePaneToLegacy(
                paneID: paneID,
                reason: m.message ?? "daemon terminal surface 失敗")
            return
        }
        if m.type == "surfaceEvent" {
            guard let paneID = m.paneID,
                  let paneEpoch = m.paneEpoch,
                  let subscriptions = surfaceSubscriptions[paneID] else { return }
            let matching = subscriptions.values.filter { $0.paneEpoch == paneEpoch }
            guard !matching.isEmpty else { return }
            for subscription in matching { subscription.deliver(event: m, clientQueue: queue) }
            // Side effects (bell/clipboard/notification) are intentionally
            // handled once per socket by AppModel, not once per terminal view.
            onEvent?(m)
            return
        }
        if m.type == "output", let paneID = m.paneID, let bytes = m.dataBytes {
            guard let subscriptions = paneSubscriptions[paneID], !subscriptions.isEmpty else {
                return
            }
            var hasDeliverableOutput = false
            for subscription in subscriptions.values {
                hasDeliverableOutput = subscription.output.appendLive(bytes) || hasDeliverableOutput
            }
            if hasDeliverableOutput { scheduleOutputFlush() }
            return
        }
        onEvent?(m)
    }

    /// Client queue only.
    private func scheduleOutputFlush() {
        guard !outFlushScheduled else { return }
        outFlushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushOutputs() }
    }

    /// Main thread: hand each ready view its accumulated bytes in one feed.
    private func flushOutputs() {
        let batch: [(handler: ([UInt8]) -> Void, bytes: [UInt8])] = queue.sync {
            defer { outFlushScheduled = false }
            var result: [(handler: ([UInt8]) -> Void, bytes: [UInt8])] = []
            for subscriptions in paneSubscriptions.values {
                for subscription in subscriptions.values {
                    let bytes = subscription.output.drain()
                    if !bytes.isEmpty {
                        result.append((subscription.handler, bytes))
                    }
                }
            }
            return result
        }
        for entry in batch {
            entry.handler(entry.bytes)
        }
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
    /// replay. The per-token barrier guarantees replay is fully applied on the
    /// main thread before live output reaches this view.
    func subscribe(paneID: String,
                   replay: @escaping (_ bytes: [UInt8], _ cols: Int?, _ rows: Int?) -> Void,
                   handler: @escaping ([UInt8]) -> Void) -> UUID {
        let token = UUID()
        let subscription = PaneSubscription(handler: handler)
        queue.async {
            if self.surfaceSubscriptions[paneID]?.isEmpty == false {
                // A raw consumer is a connection-wide mode decision for this
                // pane. Move every native viewer first so the daemon cannot
                // silently remove their subscription underneath them.
                self.fallbackSurfacePaneToLegacy(
                    paneID: paneID,
                    reason: "another viewer requested raw terminal transport")
            }
            self.beginRawSubscription(
                paneID: paneID, token: token, subscription: subscription,
                replay: replay)
        }
        return token
    }

    /// Prefer daemon-owned native terminal state. An old daemon (or a pane
    /// whose state contains an unsupported payload) transparently falls back
    /// to the proven replay/live barrier.
    func subscribePreferredSurface(
        paneID: String,
        surface: @escaping (TerminalSurfacePacket, UInt64,
                            @escaping () -> Void) -> Void,
        surfaceEvent: @escaping (WireMessage, @escaping () -> Void) -> Void = { _, done in done() },
        onSurfaceOverflow: @escaping (UInt64) -> Void = { _ in },
        rawReplay: @escaping (_ bytes: [UInt8], _ cols: Int?, _ rows: Int?) -> Void,
        rawHandler: @escaping ([UInt8]) -> Void,
        onFallback: @escaping (String) -> Void = { _ in }
    ) -> UUID {
        let token = UUID()
        let subscription = SurfaceSubscription(
            token: token,
            surfaceHandler: surface,
            surfaceEventHandler: surfaceEvent,
            overflowHandler: onSurfaceOverflow,
            rawReplay: rawReplay,
            rawHandler: rawHandler,
            fallbackHandler: onFallback)
        queue.async {
            // Pane transport is sticky while any raw viewer is attached. A
            // later view must not negotiate surface: taskdeckd would remove
            // this connection's raw subscription and strand existing views.
            if self.paneSubscriptions[paneID]?.isEmpty == false {
                DispatchQueue.main.async {
                    subscription.fallbackHandler(
                        "pane already uses raw terminal transport")
                }
                let raw = PaneSubscription(handler: subscription.rawHandler)
                self.beginRawSubscription(
                    paneID: paneID, token: token, subscription: raw,
                    replay: subscription.rawReplay)
                return
            }
            self.surfaceSubscriptions[paneID, default: [:]][token] = subscription
            var request = WireMessage(type: "subscribeSurface")
            request.paneID = paneID
            request.surfaceVersion = Wire.remoteSurfaceVersion
            request.surfaceClientID = subscription.clientID
            let requestID = UUID().uuidString
            request.id = requestID
            subscription.pendingRequestIDs.insert(requestID)
            self.pending[requestID] = { response in
                subscription.pendingRequestIDs.remove(requestID)
                guard self.surfaceSubscriptions[paneID]?[token] === subscription else { return }
                // A dropped socket is not a protocol downgrade. There is no
                // live fd on which to start raw fallback; teardown clears the
                // token and AppModel reports the disconnect instead.
                guard let response else { return }
                guard response.type == "surfaceSnapshot",
                      let packet = self.surfacePacket(from: response),
                      packet.kind == .snapshot else {
                    self.fallbackSurfacePaneToLegacy(
                        paneID: paneID,
                        reason: response.message ?? "daemon 不支援 native terminal surface")
                    return
                }
                subscription.paneEpoch = packet.paneEpoch
                subscription.deliver(
                    packet, priority: true, clientQueue: self.queue)
            }
            self.sendRaw(request)
        }
        return token
    }

    /// Request a fresh authority snapshot after a patch revision/epoch/apply
    /// mismatch. While it is pending, older broadcast deltas are discarded;
    /// socket ordering guarantees later deltas follow the response snapshot.
    func resyncSurface(paneID: String, token: UUID) {
        queue.async {
            guard let subscription = self.surfaceSubscriptions[paneID]?[token],
                  !subscription.resyncPending else { return }
            subscription.resyncPending = true
            var request = WireMessage(type: "surfaceResync")
            request.paneID = paneID
            request.surfaceVersion = Wire.remoteSurfaceVersion
            request.surfaceClientID = subscription.clientID
            let requestID = UUID().uuidString
            request.id = requestID
            subscription.pendingRequestIDs.insert(requestID)
            self.pending[requestID] = { response in
                subscription.pendingRequestIDs.remove(requestID)
                guard self.surfaceSubscriptions[paneID]?[token] === subscription else { return }
                guard let response else { return }
                guard response.type == "surfaceSnapshot",
                      let packet = self.surfacePacket(from: response),
                      packet.kind == .snapshot else {
                    self.fallbackSurfacePaneToLegacy(
                        paneID: paneID,
                        reason: response.message ?? "terminal surface 無法重新同步")
                    return
                }
                guard subscription.paneEpoch == packet.paneEpoch else {
                    self.fallbackSurfacePaneToLegacy(
                        paneID: paneID,
                        reason: "terminal pane lifetime 已改變")
                    return
                }
                subscription.resyncPending = false
                subscription.deliver(
                    packet, priority: true, clientQueue: self.queue)
            }
            self.sendRaw(request)
        }
    }

    /// A native DTO can be syntactically valid on the wire yet be rejected by
    /// SwiftTerm's atomic invariant checks. Because raw/native cannot coexist
    /// per pane/socket, one rejection moves every viewer to legacy together.
    func fallbackSurfaceToLegacy(paneID: String, reason: String) {
        queue.async {
            self.fallbackSurfacePaneToLegacy(paneID: paneID, reason: reason)
        }
    }

    func unsubscribe(paneID: String, token: UUID) {
        queue.async {
            if let surface = self.surfaceSubscriptions[paneID]?.removeValue(forKey: token) {
                for requestID in surface.pendingRequestIDs {
                    self.pending.removeValue(forKey: requestID)
                }
                surface.pendingRequestIDs.removeAll()
                var m = WireMessage(type: "unsubscribeSurface")
                m.paneID = paneID
                m.surfaceClientID = surface.clientID
                self.sendRaw(m)
                if self.surfaceSubscriptions[paneID]?.isEmpty == true {
                    self.surfaceSubscriptions.removeValue(forKey: paneID)
                }
                return
            }
            self.paneSubscriptions[paneID]?[token]?.output.cancel()
            self.paneSubscriptions[paneID]?.removeValue(forKey: token)
            if self.paneSubscriptions[paneID]?.isEmpty == true {
                self.paneSubscriptions.removeValue(forKey: paneID)
                var m = WireMessage(type: "unsubscribe")
                m.paneID = paneID
                self.sendRaw(m)
            }
        }
    }

    // MARK: - Subscription internals (client queue only)

    private func beginRawSubscription(
        paneID: String,
        token: UUID,
        subscription: PaneSubscription,
        replay: @escaping (_ bytes: [UInt8], _ cols: Int?, _ rows: Int?) -> Void
    ) {
        paneSubscriptions[paneID, default: [:]][token] = subscription
        var m = WireMessage(type: "subscribe")
        m.paneID = paneID
        m.id = UUID().uuidString
        pending[m.id!] = { resp in
            guard let current = self.paneSubscriptions[paneID]?[token],
                  current === subscription else { return }
            guard resp?.type == "replay", subscription.output.receivedReplayResponse() else {
                subscription.output.cancel()
                self.paneSubscriptions[paneID]?.removeValue(forKey: token)
                if self.paneSubscriptions[paneID]?.isEmpty == true {
                    self.paneSubscriptions.removeValue(forKey: paneID)
                }
                return
            }
            let bytes = resp?.dataBytes ?? []
            let cols = resp?.cols
            let rows = resp?.rows
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let isActive = self.queue.sync {
                    self.paneSubscriptions[paneID]?[token] === subscription
                }
                guard isActive else { return }
                replay(bytes, cols, rows)
                self.queue.async {
                    guard self.paneSubscriptions[paneID]?[token] === subscription else { return }
                    if subscription.output.replayApplied() {
                        self.scheduleOutputFlush()
                    }
                }
            }
        }
        sendRaw(m)
    }

    private func fallbackSurfacePaneToLegacy(paneID: String, reason: String) {
        guard let subscriptions = surfaceSubscriptions.removeValue(forKey: paneID),
              !subscriptions.isEmpty else { return }

        // Explicit removals keep daemon-side per-view bookkeeping bounded.
        // The following raw subscribe is also an authoritative mode switch for
        // the whole pane on this connection.
        for surface in subscriptions.values {
            for requestID in surface.pendingRequestIDs {
                pending.removeValue(forKey: requestID)
            }
            surface.pendingRequestIDs.removeAll()
            var unsubscribe = WireMessage(type: "unsubscribeSurface")
            unsubscribe.paneID = paneID
            unsubscribe.surfaceClientID = surface.clientID
            sendRaw(unsubscribe)
        }
        for (token, surface) in subscriptions {
            DispatchQueue.main.async { surface.fallbackHandler(reason) }
            let raw = PaneSubscription(handler: surface.rawHandler)
            beginRawSubscription(
                paneID: paneID, token: token, subscription: raw,
                replay: surface.rawReplay)
        }
    }

    private func surfacePacket(from message: WireMessage) -> TerminalSurfacePacket? {
        guard message.surfaceVersion == Wire.remoteSurfaceVersion,
              let paneEpoch = message.paneEpoch, !paneEpoch.isEmpty,
              let revision = message.surfaceRevision else { return nil }
        switch message.type {
        case "surfaceSnapshot":
            guard let bytes = message.surfaceSnapshotBytes else { return nil }
            return TerminalSurfacePacket(
                kind: .snapshot, bytes: bytes, paneEpoch: paneEpoch,
                revision: revision, baseRevision: nil)
        case "surfacePatch":
            guard let bytes = message.surfacePatchBytes,
                  let baseRevision = message.surfaceBaseRevision else { return nil }
            return TerminalSurfacePacket(
                kind: .patch, bytes: bytes, paneEpoch: paneEpoch,
                revision: revision, baseRevision: baseRevision)
        default:
            return nil
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
