/// Per-view output barrier used while a terminal replay is being attached.
///
/// A pane can have more than one view. While a new view waits for its replay,
/// the shared daemon subscription may already be streaming output for an
/// older view. Bytes seen before the new replay response are also present in
/// that response's snapshot, so they must be dropped for the new view. Bytes
/// seen after the response are newer than the snapshot and must be held until
/// the replay has been applied on the UI thread.
public struct ReplayFirstOutputBuffer {
    public enum Phase: Equatable {
        case waitingForReplayResponse
        case applyingReplay
        case live
        case cancelled
    }

    public private(set) var phase: Phase = .waitingForReplayResponse
    private var duringReplay: [UInt8] = []
    private var deliverable: [UInt8] = []

    public init() {}

    /// Advances the socket-ordered barrier as soon as the replay response is
    /// decoded, before its bytes are dispatched to the UI thread.
    @discardableResult
    public mutating func receivedReplayResponse() -> Bool {
        guard phase == .waitingForReplayResponse else { return false }
        phase = .applyingReplay
        return true
    }

    /// Adds live output received from the daemon. The return value says
    /// whether a UI delivery can now be scheduled.
    @discardableResult
    public mutating func appendLive(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        switch phase {
        case .waitingForReplayResponse:
            // The later snapshot includes these bytes. Buffering would render
            // them twice when another view already subscribed to this pane.
            return false
        case .applyingReplay:
            duringReplay.append(contentsOf: bytes)
            return false
        case .live:
            deliverable.append(contentsOf: bytes)
            return true
        case .cancelled:
            return false
        }
    }

    /// Called only after replay feed/layout has completed on the UI thread.
    @discardableResult
    public mutating func replayApplied() -> Bool {
        guard phase == .applyingReplay else { return false }
        phase = .live
        if !duringReplay.isEmpty {
            deliverable.append(contentsOf: duringReplay)
            duringReplay.removeAll(keepingCapacity: true)
        }
        return !deliverable.isEmpty
    }

    public var hasDeliverableOutput: Bool {
        phase == .live && !deliverable.isEmpty
    }

    public mutating func drain() -> [UInt8] {
        guard phase == .live, !deliverable.isEmpty else { return [] }
        let bytes = deliverable
        deliverable.removeAll(keepingCapacity: true)
        return bytes
    }

    public mutating func cancel() {
        phase = .cancelled
        duringReplay.removeAll()
        deliverable.removeAll()
    }
}
