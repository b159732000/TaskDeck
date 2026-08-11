import Foundation
import SwiftTerm
import TaskDeckCore

/// Transport-ready output from the daemon's canonical terminal emulator.
/// SwiftTerm DTOs stay behind this small boundary so socket routing never
/// needs to inspect or reinterpret terminal state.
struct EncodedSurfaceSnapshot {
    let epoch: String
    let revision: UInt64
    let bytes: [UInt8]
}

struct EncodedSurfacePatch {
    let epoch: String
    let baseRevision: UInt64
    let revision: UInt64
    let bytes: [UInt8]
}

enum EncodedSurfacePublication {
    case snapshot(EncodedSurfaceSnapshot)
    case patch(EncodedSurfacePatch)
}

/// Main-thread confinement belongs inside the implementation. Callers invoke
/// these methods only from `Server.queue`; an implementation may synchronously
/// hop to main, but callbacks from main must return with `Server.queue.async`
/// and must never synchronously enter the state queue.
protocol CanonicalSurfaceProviding: AnyObject {
    var synchronizedOutputActive: Bool { get }

    /// Full render state at the current revision. This does not parse replay
    /// bytes, does not disturb the shared publication baseline, and is safe to
    /// use as a subscriber-specific resynchronization boundary.
    func snapshot() throws -> EncodedSurfaceSnapshot

    /// The broadcast exporter is shared by the pane. When the first viewer
    /// arrives after a subscriber-free period, invalidate any old baseline so
    /// its first broadcast is a self-contained snapshot rather than a patch
    /// based on state the new viewer never received.
    func resetPublicationBaseline()

    /// Parse host bytes exactly once and optionally construct the next ordered
    /// surface publication. Nil means either no subscribers or DEC 2026 is
    /// withholding an incomplete frame.
    func feed(_ bytes: [UInt8], wantsPublication: Bool) throws
        -> EncodedSurfacePublication?

    /// Resize canonical render state. PTY ioctl remains owned by `Pane`.
    func resize(cols: Int, rows: Int, wantsPublication: Bool) throws
        -> EncodedSurfacePublication?

    /// Called after SwiftTerm's synchronized-output timeout fires outside a
    /// feed operation. Publishes all withheld mutations from the last baseline.
    func flushSynchronizedOutput(wantsPublication: Bool) throws
        -> EncodedSurfacePublication?
}

final class PendingSurfaceSnapshot {
    weak var connection: Conn?
    let request: WireMessage
    let registerSubscription: Bool

    init(connection: Conn, request: WireMessage, registerSubscription: Bool) {
        self.connection = connection
        self.request = request
        self.registerSubscription = registerSubscription
    }
}

/// SwiftTerm is the single VT parser for every new pane. The GUI receives its
/// native render DTO and never replays or parses PTY bytes on this path.
final class CanonicalTerminalSurface: CanonicalSurfaceProviding, TerminalDelegate {
    private unowned let pane: Pane
    private unowned let server: Server
    private var terminal: Terminal!
    private var exporter: Terminal.SurfaceExporter!
    private var revision: UInt64 = 0
    /// Delegate callbacks can happen synchronously inside feed/resize. The
    /// enclosing server operation publishes them, while a timeout callback
    /// occurring later needs to enqueue an independent flush.
    private var operationDepth = 0
    private let encoder = JSONEncoder()
    private var unsupportedSurfaceContent: String?

    init(pane: Pane) {
        self.pane = pane
        self.server = pane.server
        onMain {
            var options = TerminalOptions.default
            options.cols = max(2, pane.cols)
            options.rows = max(1, pane.rows)
            // The remote surface v1 intentionally does not transport images.
            // Do not advertise sixel support from this headless authority.
            options.enableSixelReported = false
            // Forced Kitty payloads can still arrive without capability
            // negotiation. Never retain their default 320 MiB-per-pane cache;
            // exporter/delegate guards below make the pane fall back to raw.
            options.kittyImageCacheLimitBytes = 0
            terminal = Terminal(delegate: self, options: options)
            exporter = terminal.makeSurfaceExporter()
        }
    }

    var synchronizedOutputActive: Bool {
        onMain { terminal.synchronizedOutputActive }
    }

    func snapshot() throws -> EncodedSurfaceSnapshot {
        let value = try onMain {
            try terminal.exportSurfaceSnapshot(revision: revision)
        }
        return EncodedSurfaceSnapshot(epoch: value.epoch.uuidString.lowercased(),
                                      revision: value.revision,
                                      bytes: [UInt8](try encoder.encode(value)))
    }

    func resetPublicationBaseline() {
        onMain { exporter.resetBaseline() }
    }

    func feed(_ bytes: [UInt8], wantsPublication: Bool) throws
        -> EncodedSurfacePublication? {
        let update = try onMain { () throws -> TerminalSurfaceUpdate? in
            operationDepth += 1
            defer { operationDepth -= 1 }
            let oldEpoch = terminal.remoteSurfaceEpoch
            terminal.feed(byteArray: bytes)
            if let unsupportedSurfaceContent {
                throw NSError(
                    domain: "taskdeckd.surface",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "native terminal surface does not support \(unsupportedSurfaceContent)"]
                )
            }
            advanceRevision(epochChanged: terminal.remoteSurfaceEpoch != oldEpoch)
            guard wantsPublication, !terminal.synchronizedOutputActive else { return nil }
            return try exportUpdateIfNeeded()
        }
        return try encode(update)
    }

    func resize(cols: Int, rows: Int, wantsPublication: Bool) throws
        -> EncodedSurfacePublication? {
        let update = try onMain { () throws -> TerminalSurfaceUpdate? in
            let current = terminal.getDims()
            guard current.cols != cols || current.rows != rows else { return nil }
            operationDepth += 1
            defer { operationDepth -= 1 }
            terminal.resize(cols: cols, rows: rows)
            advanceRevision(epochChanged: false)
            guard wantsPublication, !terminal.synchronizedOutputActive else { return nil }
            return try exportUpdateIfNeeded()
        }
        return try encode(update)
    }

    func flushSynchronizedOutput(wantsPublication: Bool) throws
        -> EncodedSurfacePublication? {
        let update = try onMain { () throws -> TerminalSurfaceUpdate? in
            guard wantsPublication, !terminal.synchronizedOutputActive else { return nil }
            return try exportUpdateIfNeeded()
        }
        return try encode(update)
    }

    private func advanceRevision(epochChanged: Bool) {
        if epochChanged || revision == UInt64.max {
            // Revisions are scoped to SwiftTerm's render epoch. A full reset
            // advances the payload epoch and the next update is a snapshot.
            exporter.resetBaseline()
            revision = 1
        } else {
            revision += 1
        }
    }

    private func exportUpdateIfNeeded() throws -> TerminalSurfaceUpdate? {
        guard exporter.baseRevision != revision else { return nil }
        return try exporter.exportUpdate(revision: revision)
    }

    private func encode(_ update: TerminalSurfaceUpdate?) throws
        -> EncodedSurfacePublication? {
        guard let update else { return nil }
        switch update {
        case .snapshot(let snapshot):
            return .snapshot(EncodedSurfaceSnapshot(
                epoch: snapshot.epoch.uuidString.lowercased(),
                revision: snapshot.revision,
                bytes: [UInt8](try encoder.encode(snapshot))
            ))
        case .patch(let patch):
            return .patch(EncodedSurfacePatch(
                epoch: patch.epoch.uuidString.lowercased(),
                baseRevision: patch.baseRevision,
                revision: patch.revision,
                bytes: [UInt8](try encoder.encode(patch))
            ))
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    // MARK: TerminalDelegate — host responses + semantic side effects

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard source === terminal else { return }
        let bytes = Array(data)
        server.queue.async { [weak pane] in pane?.writeBytes(bytes) }
    }

    func synchronizedOutputChanged(source: Terminal, active: Bool) {
        guard source === terminal, !active, operationDepth == 0 else { return }
        server.queue.async { [weak self, weak pane] in
            guard let self, let pane,
                  self.server.panes[pane.id] === pane else { return }
            self.server.canonicalSynchronizedOutputEnded(pane: pane, surface: self)
        }
    }

    func bell(source: Terminal) {
        emit(kind: TerminalSurfaceEventKind.bell)
    }

    func clipboardCopy(source: Terminal, content: Data) {
        let bytes = [UInt8](content)
        emit(kind: TerminalSurfaceEventKind.clipboardCopy) { $0.setData(bytes) }
    }

    func clipboardRead(source: Terminal) -> Data? {
        // A headless daemon must never expose a GUI clipboard to an untrusted
        // process. Copy requests are events; read requests are denied.
        nil
    }

    func setTerminalTitle(source: Terminal, title: String) {
        emit(kind: TerminalSurfaceEventKind.title) { $0.title = title }
    }

    func hostCurrentDirectoryUpdated(source: Terminal) {
        let cwd = source.hostCurrentDirectory
        emit(kind: TerminalSurfaceEventKind.cwd) { $0.cwd = cwd }
    }

    func notify(source: Terminal, title: String, body: String) {
        emit(kind: TerminalSurfaceEventKind.notification) {
            $0.title = title
            $0.message = body
        }
    }

    func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        emit(kind: TerminalSurfaceEventKind.progress) {
            $0.surfaceProgressState = report.state.rawValue
            $0.surfaceProgressValue = report.progress
        }
    }

    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {
        guard source === terminal else { return }
        // SwiftTerm routes non-rendering OSC 1337 shell-integration metadata
        // here (RemoteHost, CurrentDir, ShellIntegrationVersion, SetUserVar,
        // and File downloads). None of it changes the terminal grid, so it is
        // safe for the headless authority to ignore. Actual inline images take
        // SwiftTerm's createImage callback below and still force raw fallback;
        // treating every iTerm payload as an image disabled native surfaces as
        // soon as an ordinary zsh prompt started.
    }

    func createImageFromBitmap(
        source: Terminal,
        bytes: inout [UInt8],
        width: Int,
        height: Int
    ) {
        guard source === terminal else { return }
        unsupportedSurfaceContent = "terminal bitmap images"
    }

    func createImage(
        source: Terminal,
        data: Data,
        width: ImageSizeRequest,
        height: ImageSizeRequest,
        preserveAspectRatio: Bool
    ) {
        guard source === terminal else { return }
        unsupportedSurfaceContent = "terminal inline images"
    }

    private func emit(
        kind: String,
        _ populate: @escaping (inout WireMessage) -> Void = { _ in }
    ) {
        server.queue.async { [weak server, weak pane] in
            guard let server, let pane,
                  server.panes[pane.id] === pane else { return }
            server.broadcastSurfaceEvent(pane: pane, kind: kind, populate)
        }
    }
}
