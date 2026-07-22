import Foundation

/// Minimal Chrome DevTools Protocol client — read-only, used to list the
/// debug-profile Chrome's windows/tabs for task snapshots. Tabs are OPENED
/// via the user's own launch command (`AppConfig.chromeCommand`), never CDP;
/// this client only ever reads.
enum ChromeCDP {
    struct Tab: Equatable {
        let targetID: String
        let title: String
        let url: String
    }

    struct Window: Identifiable, Equatable {
        let id: Int
        var tabs: [Tab]
    }

    enum CDPError: Error, LocalizedError {
        case unreachable
        case badResponse

        var errorDescription: String? {
            switch self {
            case .unreachable:
                return "連不上 Chrome 偵錯埠（debug Chrome 沒開，或 port 不對）"
            case .badResponse:
                return "Chrome 偵錯埠回應格式不符"
            }
        }
    }

    /// All normal-page windows on the debug port, tabs grouped per window.
    static func windows(port: Int) async throws -> [Window] {
        let wsURL = try await browserSocketURL(port: port)
        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: wsURL)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        let targets = try await call(ws, method: "Target.getTargets", params: [:])
        guard let infos = (targets["targetInfos"] as? [[String: Any]]) else {
            throw CDPError.badResponse
        }
        var grouped: [Int: [Tab]] = [:]
        for info in infos {
            guard (info["type"] as? String) == "page",
                  let targetID = info["targetId"] as? String,
                  let url = info["url"] as? String,
                  !url.hasPrefix("devtools://"),
                  !url.hasPrefix("chrome-extension://") else { continue }
            let win = try await call(ws, method: "Browser.getWindowForTarget",
                                     params: ["targetId": targetID])
            guard let windowID = win["windowId"] as? Int else { continue }
            grouped[windowID, default: []].append(
                Tab(targetID: targetID,
                    title: (info["title"] as? String) ?? url,
                    url: url))
        }
        return grouped.keys.sorted().map { Window(id: $0, tabs: grouped[$0]!) }
    }

    /// Just the window-id set — cheap before/after diff when opening tabs.
    static func windowIDs(port: Int) async -> Set<Int> {
        (try? await windows(port: port).map(\.id)).map(Set.init) ?? []
    }

    /// Bring one of the given windows to the front by activating its first
    /// tab (the REST endpoint raises the OS window too). Returns false when
    /// none of the ids exist anymore — caller falls back to just activating
    /// the app. Activation only; never opens/closes/navigates anything.
    static func activateWindow(port: Int, windowIDs: Set<Int>) async -> Bool {
        guard !windowIDs.isEmpty,
              let wins = try? await windows(port: port),
              let win = wins.first(where: { windowIDs.contains($0.id) }),
              let tab = win.tabs.first,
              let url = URL(string: "http://127.0.0.1:\(port)/json/activate/\(tab.targetID)")
        else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    /// Close every tab of the given windows (closing all tabs closes the
    /// window). The ONLY write this client performs — scoped to windows the
    /// task explicitly remembered, so "close resource windows" can't touch
    /// anything else. Returns the number of tabs closed.
    static func closeWindows(port: Int, windowIDs: Set<Int>) async throws -> Int {
        guard !windowIDs.isEmpty else { return 0 }
        let wsURL = try await browserSocketURL(port: port)
        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: wsURL)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        var closed = 0
        for window in try await windows(port: port) where windowIDs.contains(window.id) {
            for tab in window.tabs {
                _ = try await call(ws, method: "Target.closeTarget",
                                   params: ["targetId": tab.targetID])
                closed += 1
            }
        }
        return closed
    }

    // MARK: - Plumbing

    private static func browserSocketURL(port: Int) async throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else {
            throw CDPError.unreachable
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ws = obj["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: ws) else {
            throw CDPError.unreachable
        }
        return wsURL
    }

    // Locked: concurrent CDP operations (snapshot + open racing) incremented
    // this unsynchronized shared counter from different tasks.
    private static var nextID = 0
    private static let idLock = NSLock()

    /// One JSON-RPC round trip. Requests are sequential; CDP events (frames
    /// without our id) are skipped while waiting for the matching response.
    private static func call(_ ws: URLSessionWebSocketTask, method: String,
                             params: [String: Any]) async throws -> [String: Any] {
        let id: Int = {
            idLock.lock()
            defer { idLock.unlock() }
            nextID += 1
            return nextID
        }()
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.string(String(data: data, encoding: .utf8) ?? "{}"))

        for _ in 0 ..< 64 {
            let msg = try await receive(ws, timeout: 3)
            guard let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any] else {
                continue
            }
            if let mid = obj["id"] as? Int, mid == id {
                return (obj["result"] as? [String: Any]) ?? [:]
            }
            // else: async CDP event — ignore.
        }
        throw CDPError.badResponse
    }

    private static func receive(_ ws: URLSessionWebSocketTask,
                                timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                switch try await ws.receive() {
                case .string(let s): return Data(s.utf8)
                case .data(let d): return d
                @unknown default: return Data()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CDPError.unreachable
            }
            guard let first = try await group.next() else { throw CDPError.badResponse }
            group.cancelAll()
            return first
        }
    }
}
