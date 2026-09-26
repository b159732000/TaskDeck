import AppKit
import Foundation
import TaskDeckCore

/// Developer aid: renders every visible window to PNG on request.
///
///     touch "$HOME/Library/Application Support/TaskDeck/snapshots/request"
///
/// The snapshots directory is watched (kqueue, like the status directory);
/// the request file is consumed and the service writes
/// `<App Support>/TaskDeck/snapshots/<stamp>-<window>.png` plus a
/// `latest.json` sidecar (window frames, which bundled font families resolved,
/// the active background preset). Rendering happens in-process, so it needs no
/// Screen Recording permission, never changes focus, and can run while the
/// user keeps typing — which is what lets an AI session verify a UI change
/// end to end without interrupting the person using the app.
///
/// Terminal cells are Metal-backed and are not captured (they show the pane
/// background); everything else — sidebar, headers, notes, chips — is.
@MainActor
final class SnapshotService {
    static let shared = SnapshotService()
    static var directory: URL {
        let d = Paths.appSupport.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var requestFile: URL { directory.appendingPathComponent("request") }

    private var watcher: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func start() {
        guard watcher == nil else { return }
        fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.consumeRequest() }
        }
        source.activate()
        watcher = source
        consumeRequest() // a request left over from before launch
    }

    private func consumeRequest() {
        let request = Self.requestFile
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        try? FileManager.default.removeItem(at: request)
        // Let the current layout pass finish before drawing.
        DispatchQueue.main.async { [weak self] in self?.capture() }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd-HHmmss"
        return formatter
    }()

    @discardableResult
    func capture() -> URL? {
        let directory = Self.directory
        let stamp = Self.stampFormatter.string(from: Date())
        var windows: [[String: Any]] = []

        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0 else { continue }
            let name = Self.shortName(window)
            guard let image = render(view) else { continue }
            let file = directory.appendingPathComponent("\(stamp)-\(name).png")
            try? image.write(to: file)
            let frame = window.frame
            windows.append([
                "window": name,
                "file": file.lastPathComponent,
                "frame": [Int(frame.origin.x), Int(frame.origin.y), Int(frame.width), Int(frame.height)],
                "scale": window.backingScaleFactor,
                // List rows: count + visible count, so an empty sidebar in the
                // PNG can be told apart from a capture miss.
                "tables": Self.tables(in: view).map { table -> [String: Any] in
                    let visible = table.rows(in: table.visibleRect)
                    return ["rows": table.numberOfRows, "visible": visible.length,
                            "frame": [Int(table.frame.width), Int(table.frame.height)]]
                },
            ])
        }

        // Resolve the three families now so the sidecar reports them even before
        // any view has asked for a bundled font.
        for family in ["Bricolage Grotesque", "Instrument Sans", "JetBrains Mono"] {
            Theme.Fonts.resolved[family] =
                Theme.Fonts.nsFont(family: family, size: 13, weight: .regular, opticalSize: false) != nil
        }
        let sidecar: [String: Any] = [
            "at": stamp,
            "windows": windows,
            "fonts": Theme.Fonts.resolved,
            "preset": Theme.bgPresets[min(max(0, Theme.bgPresetIndex), Theme.bgPresets.count - 1)].name,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        let latest = directory.appendingPathComponent("latest.json")
        try? data.write(to: latest)
        try? data.write(to: directory.appendingPathComponent("\(stamp).json"))
        return latest
    }

    private static func tables(in root: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let table = view as? NSTableView { found.append(table) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// "main" for the app window, "task-<slug>" for a popout; the SwiftUI
    /// autosave names are unreadable type paths.
    private static func shortName(_ window: NSWindow) -> String {
        let auto = window.frameAutosaveName
        if auto.hasPrefix("JamesDesk.task.") { return "task-" + auto.dropFirst("JamesDesk.task.".count) }
        if auto.contains("AppWindow") || auto == "JamesDesk.main" || auto.isEmpty { return "main" }
        return auto.replacingOccurrences(of: "/", with: "_")
    }

    /// Rendered from the layer tree, not `cacheDisplay`: SwiftUI's List rows
    /// are layer-backed table cells that the drawRect path leaves blank. The
    /// behind-window blur lives in the compositor, so glass comes out
    /// transparent — composite over the window ink so the PNG reads the way
    /// the window does on a dark desktop.
    private func render(_ view: NSView) -> Data? {
        let bounds = view.bounds
        let scale = view.window?.backingScaleFactor ?? 2
        let pixels = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        canvas.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.current = context
        NSColor(hex: 0x0B0D12).setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        if let layer = view.layer {
            // CALayer.render draws in layer (points) coordinates, y-down.
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            layer.render(in: cg)
            cg.restoreGState()
        } else if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        }
        // SwiftUI List rows (NSTableView cells) do not come through the layer
        // render; draw each table on top through the drawRect path.
        for table in Self.tables(in: view) {
            guard let rep = table.bitmapImageRepForCachingDisplay(in: table.bounds) else { continue }
            // The table paints an opaque background through drawRect even
            // though the live list is glass; capture it clear.
            let background = table.backgroundColor
            let scrollDraws = table.enclosingScrollView?.drawsBackground ?? false
            table.backgroundColor = .clear
            table.enclosingScrollView?.drawsBackground = false
            table.cacheDisplay(in: table.bounds, to: rep)
            table.backgroundColor = background
            table.enclosingScrollView?.drawsBackground = scrollDraws
            let inWindow = table.convert(table.bounds, to: nil) // window coords, y-up
            rep.draw(in: inWindow)
        }
        context.flushGraphics()
        return canvas.representation(using: .png, properties: [:])
    }
}
