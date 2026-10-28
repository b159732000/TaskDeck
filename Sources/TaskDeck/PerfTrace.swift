import AppKit
import Combine
import ObjectiveC
import QuartzCore
import TaskDeckCore

/// Opt-in render diagnostics for "the window feels sticky" reports:
///
///     defaults write app.taskdeck.TaskDeck perfTrace -bool true   # then relaunch
///
/// Every 5 s appends a block to App Support/perftrace.log with
/// - main-thread lag: how late a block queued every 100 ms actually ran —
///   what a click or keystroke waits behind;
/// - how many SwiftUI drawing layers (RenderBox `RBLayer`) re-rendered, and
///   the busiest ones (size, the view hosting them, origin in the window).
///   Each such re-render can block on the window server retiring an earlier
///   frame (`RB::SharedSurfaceGroup::wait_for_allocations`), so this count is
///   what pinned the main thread;
/// - how often AppModel notified its observers, and from where.
///
/// Off by default; when off nothing is installed.
@MainActor
enum PerfTrace {
    private final class WeakLayer {
        weak var layer: CALayer?
        init(_ layer: CALayer) { self.layer = layer }
    }

    private static var installed = false
    private static var redraws: [ObjectIdentifier: (layer: WeakLayer, count: Int)] = [:]
    private static var notifications = 0
    private static var notifiers: [String: Int] = [:]
    private static var lags: [Double] = []
    private static var subscription: AnyCancellable?
    private static var timer: Timer?

    static func startIfEnabled(model: AppModel) {
        guard !installed, UserDefaults.standard.bool(forKey: "perfTrace") else { return }
        installed = true
        countDrawingLayerRedraws()
        subscription = model.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                notifications += 1
                notifiers[notifyingSite(), default: 0] += 1
            }
        }
        let probeQueue = DispatchQueue(label: "taskdeck.perftrace.lag")
        probeQueue.async { probeMainThreadLag(on: probeQueue) }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { flush() }
        }
        append("== perfTrace started (pid \(ProcessInfo.processInfo.processIdentifier)) ==\n")
    }

    /// Wrap `-[RBLayer display]` — only if RBLayer implements it itself, so
    /// CALayer's own `display` is never touched.
    private static func countDrawingLayerRedraws() {
        guard let cls = NSClassFromString("RBLayer") else {
            return append("perfTrace: no RBLayer class; redraw counts unavailable\n")
        }
        let selector = #selector(CALayer.display)
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return }
        defer { free(methods) }
        guard let method = (0..<Int(count)).map({ methods[$0] })
            .first(where: { method_getName($0) == selector }) else {
            return append("perfTrace: RBLayer has no own -display; redraw counts unavailable\n")
        }
        typealias Display = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Display.self)
        let replacement: @convention(block) (AnyObject) -> Void = { object in
            if Thread.isMainThread, let layer = object as? CALayer {
                MainActor.assumeIsolated {
                    let id = ObjectIdentifier(layer)
                    if let entry = redraws[id] {
                        redraws[id] = (entry.layer, entry.count + 1)
                    } else {
                        redraws[id] = (WeakLayer(layer), 1)
                    }
                }
            }
            original(object, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Queue a block on the main thread every 100 ms and record how late it
    /// ran. Scheduled from a background queue so the probe itself never
    /// waits on the thread it measures.
    private nonisolated static func probeMainThreadLag(on queue: DispatchQueue) {
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async {
            let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
            MainActor.assumeIsolated { lags.append(lag) }
            queue.asyncAfter(deadline: .now() + 0.1) { probeMainThreadLag(on: queue) }
        }
    }

    /// The first two TaskDeck frames under the notification — for a
    /// @Published write that is the property setter and its caller.
    private static func notifyingSite() -> String {
        let frames = Thread.callStackSymbols.dropFirst(2).compactMap { line -> String? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[1] == "TaskDeck" else { return nil }
            let symbol = String(fields[3])
            return symbol.contains("PerfTrace") ? nil : symbol
        }
        return frames.prefix(2).joined(separator: " ← ")
    }

    private static func flush() {
        let total = redraws.values.reduce(0) { $0 + $1.count }
        let sorted = lags.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let worst = sorted.last ?? 0
        let over100 = sorted.filter { $0 > 100 }.count
        var lines = [
            "[\(Date().formatted(date: .omitted, time: .standard))] "
                + "lag p50 \(Int(p50)) ms, max \(Int(worst)) ms, >100 ms \(over100)/\(sorted.count) | "
                + "drawing-layer redraws \(total) over \(redraws.count) layers | "
                + "model notifications \(notifications)",
        ]
        for entry in redraws.values.sorted(by: { $0.count > $1.count }).prefix(12) {
            lines.append("  \(entry.count)×  \(describe(entry.layer.layer))")
        }
        for (site, n) in notifiers.sorted(by: { $0.value > $1.value }).prefix(8) {
            lines.append("  notify \(n)×  \(site)")
        }
        append(lines.joined(separator: "\n") + "\n")
        redraws.removeAll()
        notifications = 0
        notifiers.removeAll()
        lags.removeAll()
    }

    private static func describe(_ layer: CALayer?) -> String {
        guard let layer else { return "(released)" }
        var root = layer
        while let parent = root.superlayer { root = parent }
        let frame = layer.convert(layer.bounds, to: root)
        var host = "?"
        var current: CALayer? = layer
        while let candidate = current {
            if let view = candidate.delegate as? NSView {
                host = String(String(describing: type(of: view)).prefix(110))
                break
            }
            current = candidate.superlayer
        }
        return "\(type(of: layer)) \(Int(layer.bounds.width))×\(Int(layer.bounds.height)) "
            + "at (\(Int(frame.minX)), \(Int(frame.minY))) of \(Int(root.bounds.width))×\(Int(root.bounds.height)) in \(host)"
    }

    private static func append(_ text: String) {
        let url = Paths.appSupport.appendingPathComponent("perftrace.log")
        guard let data = text.data(using: .utf8) else { return }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attributes[.size] as? Int ?? 0) > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
