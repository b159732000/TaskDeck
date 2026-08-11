import Foundation

/// Pure state machine for exclusive PTY resize ownership.
///
/// Multiple terminal surfaces may observe one daemon-owned pane, but only the
/// foreground surface should control its PTY dimensions. Time is injected as
/// monotonic milliseconds so the daemon can use `DispatchTime` and tests stay
/// deterministic.
public struct ResizeLeaseState: Equatable {
    public struct Grant: Equatable {
        public let ownerID: String
        public let token: String
        public let generation: UInt64
        public let expiresAtMS: UInt64

        public init(ownerID: String, token: String, generation: UInt64,
                    expiresAtMS: UInt64) {
            self.ownerID = ownerID
            self.token = token
            self.generation = generation
            self.expiresAtMS = expiresAtMS
        }
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var grant: Grant?

    public init() {}

    /// Grants an unowned/expired lease, or renews the current owner's lease.
    /// A competing owner never steals a live lease.
    @discardableResult
    public mutating func acquire(ownerID: String, nowMS: UInt64, ttlMS: UInt64,
                                 token newToken: String = UUID().uuidString) -> Grant? {
        guard !ownerID.isEmpty, ttlMS > 0 else { return nil }
        if let current = liveGrant(at: nowMS) {
            guard current.ownerID == ownerID else { return nil }
            let renewed = Grant(ownerID: ownerID, token: current.token,
                                generation: current.generation,
                                expiresAtMS: addingClamped(nowMS, ttlMS))
            grant = renewed
            return renewed
        }

        generation &+= 1
        let next = Grant(ownerID: ownerID, token: newToken, generation: generation,
                         expiresAtMS: addingClamped(nowMS, ttlMS))
        grant = next
        return next
    }

    /// Foreground ownership transfer. Unlike `acquire`, this intentionally
    /// preempts a live competing owner. A focus change must take effect now,
    /// not after the old viewer's TTL; generation + a fresh token invalidate
    /// every in-flight resize from the previous owner.
    @discardableResult
    public mutating func claim(ownerID: String, nowMS: UInt64, ttlMS: UInt64,
                               token newToken: String = UUID().uuidString) -> Grant? {
        guard !ownerID.isEmpty, ttlMS > 0 else { return nil }
        if let current = liveGrant(at: nowMS), current.ownerID == ownerID {
            let renewed = Grant(ownerID: ownerID, token: current.token,
                                generation: current.generation,
                                expiresAtMS: addingClamped(nowMS, ttlMS))
            grant = renewed
            return renewed
        }
        generation &+= 1
        let next = Grant(ownerID: ownerID, token: newToken, generation: generation,
                         expiresAtMS: addingClamped(nowMS, ttlMS))
        grant = next
        return next
    }

    /// Validates and renews a credential. Call this for every accepted resize
    /// and heartbeat so a focused surface retains ownership while active.
    @discardableResult
    public mutating func validateAndRenew(ownerID: String, token: String,
                                          generation: UInt64, nowMS: UInt64,
                                          ttlMS: UInt64) -> Grant? {
        guard ttlMS > 0, let current = liveGrant(at: nowMS),
              current.ownerID == ownerID,
              current.token == token,
              current.generation == generation else { return nil }
        let renewed = Grant(ownerID: ownerID, token: token, generation: generation,
                            expiresAtMS: addingClamped(nowMS, ttlMS))
        grant = renewed
        return renewed
    }

    /// Releases exactly the active credential. Stale releases are harmless.
    @discardableResult
    public mutating func release(ownerID: String, token: String,
                                 generation: UInt64) -> Bool {
        guard let current = grant,
              current.ownerID == ownerID,
              current.token == token,
              current.generation == generation else { return false }
        grant = nil
        return true
    }

    /// Connection teardown path: revoke ownership without requiring a token.
    @discardableResult
    public mutating func revoke(ownerID: String) -> Bool {
        guard grant?.ownerID == ownerID else { return false }
        grant = nil
        return true
    }

    public func isOwned(by ownerID: String, token: String, generation: UInt64,
                        at nowMS: UInt64) -> Bool {
        guard let current = grant, current.expiresAtMS > nowMS else { return false }
        return current.ownerID == ownerID
            && current.token == token
            && current.generation == generation
    }

    private mutating func liveGrant(at nowMS: UInt64) -> Grant? {
        guard let current = grant else { return nil }
        guard current.expiresAtMS > nowMS else {
            grant = nil
            return nil
        }
        return current
    }

    private func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
