/// Conservative recovery for a full daemon replay whose initial terminal
/// modes have fallen out of the 512 KiB ring.
///
/// OpenTUI wraps draws in synchronized-output blocks. For a known mouse-aware
/// TUI, a full ring containing repeated draw blocks but no mouse-mode control
/// means the one-time setup was truncated. Starting at the first complete draw
/// block avoids feeding a partial CSI sequence into a fresh emulator, and the
/// local-only mouse prefix restores wheel reporting. Nothing is sent to the
/// child process.
public enum TerminalReplayRecovery {
    public static let daemonReplayCapacity = 512 * 1024

    public struct Plan: Equatable {
        public let startOffset: Int
        public let localPrefix: [UInt8]
        public let applicationPagingFallback: Bool

        public init(startOffset: Int = 0, localPrefix: [UInt8] = [],
                    applicationPagingFallback: Bool = false) {
            self.startOffset = startOffset
            self.localPrefix = localPrefix
            self.applicationPagingFallback = applicationPagingFallback
        }

        public func prepare(_ replay: [UInt8]) -> [UInt8] {
            let safeOffset = min(max(0, startOffset), replay.count)
            if safeOffset == 0, localPrefix.isEmpty { return replay }
            var result = localPrefix
            result.reserveCapacity(localPrefix.count + replay.count - safeOffset)
            result.append(contentsOf: replay[safeOffset...])
            return result
        }
    }

    private static let synchronizedOutputBegin = Array("\u{1b}[?2026h".utf8)
    // Button reporting + SGR coordinates. This is deliberately narrower than
    // reconstructing alternate-screen, cursor, or keyboard-protocol state.
    private static let localMousePrefix = Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)
    // 1006 selects SGR coordinate encoding but does not enable reporting by
    // itself. Only tracking modes are evidence that wheel events will flow.
    private static let mouseTrackingParameters: [[UInt8]] = [
        Array("9".utf8),
        Array("1000".utf8),
        Array("1002".utf8),
        Array("1003".utf8),
    ]

    /// `allowMouseModeRecovery` must come from pane metadata identifying a
    /// known mouse-aware TUI. The byte heuristic alone is intentionally not
    /// applied to ordinary shells or other AI clients.
    public static func plan(for replay: [UInt8], allowMouseModeRecovery: Bool) -> Plan {
        guard allowMouseModeRecovery,
              replay.count >= daemonReplayCapacity,
              !containsMouseModeControl(replay),
              occurrenceCount(of: synchronizedOutputBegin, in: replay, stoppingAt: 2) >= 2,
              let firstDraw = firstIndex(of: synchronizedOutputBegin, in: replay) else {
            return Plan()
        }
        return Plan(startOffset: firstDraw,
                    localPrefix: localMousePrefix,
                    applicationPagingFallback: true)
    }

    private static func firstIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        let lastStart = bytes.count - needle.count
        for start in 0 ... lastStart where matches(needle, in: bytes, at: start) {
            return start
        }
        return nil
    }

    private static func occurrenceCount(of needle: [UInt8], in bytes: [UInt8],
                                        stoppingAt limit: Int) -> Int {
        guard limit > 0, !needle.isEmpty, bytes.count >= needle.count else { return 0 }
        var count = 0
        var start = 0
        let lastStart = bytes.count - needle.count
        while start <= lastStart {
            if matches(needle, in: bytes, at: start) {
                count += 1
                if count >= limit { return count }
                start += needle.count
            } else {
                start += 1
            }
        }
        return count
    }

    private static func matches(_ needle: [UInt8], in bytes: [UInt8], at start: Int) -> Bool {
        for offset in needle.indices where bytes[start + offset] != needle[offset] {
            return false
        }
        return true
    }

    /// Detect DEC private-mode set/reset controls, including combined forms
    /// such as `CSI ? 1000 ; 1006 h`.
    private static func containsMouseModeControl(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 6 else { return false }
        var i = 0
        while i + 3 < bytes.count {
            guard bytes[i] == 0x1b, bytes[i + 1] == 0x5b, bytes[i + 2] == 0x3f else {
                i += 1
                continue
            }
            var parameterStart = i + 3
            var hasTrackingParameter = false
            var j = i + 3
            while j < bytes.count {
                let byte = bytes[j]
                if byte >= 0x30, byte <= 0x39 {
                    j += 1
                    continue
                } else if byte == 0x3b { // semicolon
                    hasTrackingParameter = hasTrackingParameter
                        || isMouseTrackingParameter(bytes, from: parameterStart, to: j)
                    parameterStart = j + 1
                } else {
                    hasTrackingParameter = hasTrackingParameter
                        || isMouseTrackingParameter(bytes, from: parameterStart, to: j)
                    if (byte == 0x68 || byte == 0x6c), hasTrackingParameter {
                        return true
                    }
                    break
                }
                j += 1
            }
            i = max(i + 1, j + 1)
        }
        return false
    }

    /// Bytewise comparison avoids parsing arbitrary terminal bytes into Int;
    /// a hostile or truncated CSI parameter can therefore never overflow.
    private static func isMouseTrackingParameter(_ bytes: [UInt8],
                                                 from rawStart: Int, to end: Int) -> Bool {
        guard rawStart < end else { return false }
        var start = rawStart
        while start + 1 < end, bytes[start] == 0x30 { start += 1 }
        for parameter in mouseTrackingParameters where parameter.count == end - start {
            var matches = true
            for offset in parameter.indices where bytes[start + offset] != parameter[offset] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }
}
