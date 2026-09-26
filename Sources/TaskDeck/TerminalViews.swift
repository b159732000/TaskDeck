import AppKit
import SwiftTerm
import SwiftUI
import TaskDeckCore

/// TerminalView that composites with alpha so the glass background shows
/// through. Stock SwiftTerm reports opaque AND paints its CALayer's
/// backgroundColor once at init (setupOptions) — setting
/// `nativeBackgroundColor` later never refreshes the layer, so we force it
/// clear ourselves. Default-background cells are already drawn transparent
/// upstream; only cells with explicit ANSI backgrounds stay solid.
final class GlassTerminalView: TerminalView {
    override var isOpaque: Bool { false }
    private var redrawObservers: [NSObjectProtocol] = []
    private var focusObservers: [NSObjectProtocol] = []
    private weak var observedKeyWindow: NSWindow?
    private var focusWasActive = false
    var onFocus: (() -> Void)?
    private var applicationPagingFallback = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
        // Accept dropped files (images, etc.) like iTerm2 — the path is typed
        // into the pane so claude (or any CLI) can read it.
        registerForDraggedTypes([.fileURL])
        updateKeyWindowObservation()
        Self.installShiftReturnMonitor()

        // After sleep-wake or an app relaunch the backing store can show a
        // stale/garbled frame until a manual resize forces a repaint. Force a
        // full redraw on wake / app-active / (re)attach instead — the emulator
        // grid is intact, only the pixels are stale, so no resize needed.
        guard window != nil, redrawObservers.isEmpty else { return }
        let redraw: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.forceRedraw() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        redrawObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: redraw))
        redrawObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: redraw))
        // Catch the replay-then-draw race right after attach.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.forceRedraw() }
    }

    deinit {
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        redrawObservers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    private func updateKeyWindowObservation() {
        guard observedKeyWindow !== window else { return }
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers.removeAll()
        focusWasActive = false
        observedKeyWindow = window
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification,
                     NSWindow.didUpdateNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                if notification.name == NSWindow.didResignKeyNotification {
                    self.focusWasActive = false
                } else {
                    self.reportFocusIfNeeded()
                }
            })
        }
    }

    private func reportFocusIfNeeded(explicit: Bool = false) {
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        defer { focusWasActive = active }
        guard active, explicit || !focusWasActive else { return }
        onFocus?()
    }

    private func forceRedraw() {
        guard window != nil else { return }
        needsDisplay = true
    }

    /// Shift+Return inserts a newline instead of submitting the prompt.
    ///
    /// This has to be a local key-down monitor. AppKit runs the key-equivalent
    /// phase only for ⌘/⌃-modified keys, so `performKeyEquivalent` never sees
    /// Shift+Return — verified by dispatch test: ⌘← and ⌃⇧↩ arrive there,
    /// plain ↩ and ⇧↩ go straight to `keyDown`. That is why the natural-text
    /// -editing keys below work while a Shift+Return branch there could not.
    /// SwiftTerm declares `keyDown` and `doCommand(by:)` as `public` rather
    /// than `open`, so neither can be overridden from this subclass either. A
    /// local monitor runs before window dispatch and is the one hook that
    /// reliably sees the key.
    ///
    /// Deliberately independent of the kitty keyboard protocol. Claude Code
    /// enables it once at startup (`CSI > 1 u`), and while SwiftTerm does
    /// encode Shift+Return as `CSI 13;2u` once those flags are set, this view's
    /// terminal only holds them if it actually observed that byte. A truncated
    /// replay or a daemon-owned surface that never restores the input modes
    /// silently drops it back to legacy mode, where Shift+Return is encoded as
    /// a bare CR and the prompt submits. Sending LF ourselves is correct in
    /// both modes.
    private static var shiftReturnMonitor: Any?

    static func installShiftReturnMonitor() {
        guard shiftReturnMonitor == nil else { return }
        shiftReturnMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard let view = event.window?.firstResponder as? GlassTerminalView,
                  // Never disturb an active IME composition.
                  !view.hasMarkedText() else { return event }
            let mods = event.modifierFlags.intersection(
                [.command, .shift, .option, .control])
            guard let sequence = TerminalInputEncoding.multilineShiftReturn(
                keyCode: event.keyCode,
                shift: mods.contains(.shift),
                command: mods.contains(.command),
                option: mods.contains(.option),
                control: mods.contains(.control)
            ) else { return event }
            view.send(sequence)
            return nil
        }
    }

    /// SwiftTerm's macOS mouseDown handles selection/mouse reporting but does
    /// not make the clicked view first responder. Without this, a pane can look
    /// selected while keyboard input still goes to notes or another terminal.
    override func mouseDown(with event: NSEvent) {
        if window?.makeFirstResponder(self) == true {
            // An explicit click should reclaim a lease even when the terminal
            // was already first responder and no window notification fires.
            reportFocusIfNeeded(explicit: true)
        }
        super.mouseDown(with: event)
    }

    /// Size the buffer to the width the replayed scrollback was produced at
    /// (the daemon's PTY size) BEFORE the view lays out to its own size.
    /// Otherwise, re-attaching on a task switch feeds the replay into a view
    /// still at its transient initial frame, so history re-wraps at the wrong
    /// column and looks garbled until a manual resize. Feeding at the true
    /// production width means the only reflow is the (usually small) step to
    /// the view's real width, done once on layout.
    func applyReplaySize(cols: Int, rows: Int) {
        guard cols > 1, rows > 1 else { return }
        terminal?.resize(cols: cols, rows: rows)
    }

    /// Apply one replay as an indivisible UI operation: size it at the PTY's
    /// production width, feed from a safe terminal-state boundary when a
    /// known OpenTUI replay was truncated, then reconcile to the NSView's
    /// current pixel size. Calling setFrameSize directly is intentional;
    /// TerminalView.resize() performs a soft reset that destroys TUI modes.
    func applyReplay(_ bytes: [UInt8], cols: Int?, rows: Int?,
                     allowMouseModeRecovery: Bool) -> (cols: Int, rows: Int) {
        if remoteSurfaceMode {
            // Native DTOs and raw VT replay are two complete representations,
            // never layers. Clear every absolute-row/view cache atomically
            // before the compatibility replay is parsed.
            resetRemoteSurfaceForRawTransport()
        }
        if let cols, let rows { applyReplaySize(cols: cols, rows: rows) }
        let plan = TerminalReplayRecovery.plan(
            for: bytes, allowMouseModeRecovery: allowMouseModeRecovery)
        applicationPagingFallback = plan.applicationPagingFallback
        let prepared = plan.prepare(bytes)
        if !prepared.isEmpty { feed(byteArray: prepared[...]) }
        setFrameSize(frame.size)
        forceRedraw()
        return terminal.getDims()
    }

    @discardableResult
    func applyRemoteSnapshot(_ snapshot: TerminalSurfaceSnapshot) throws
        -> TerminalSurfaceApplyResult {
        applicationPagingFallback = false
        let result = try applySurfaceSnapshot(snapshot)
        // Entering remote mode happens inside applySurfaceSnapshot. Re-run the
        // pixel-size calculation now so the delegate can request authority at
        // the view's real dimensions without locally reflowing the grid.
        setFrameSize(frame.size)
        forceRedraw()
        return result
    }

    @discardableResult
    func applyRemotePatch(_ patch: TerminalSurfacePatch) throws
        -> TerminalSurfaceApplyResult {
        applicationPagingFallback = false
        let result = try applySurfacePatch(patch)
        forceRedraw()
        return result
    }

    func applyRemoteProgress(state: Int, value: UInt8?) {
        _ = applyRemoteProgressReport(stateRawValue: state, progress: value)
    }

    // MARK: - File drag & drop → insert path(s)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDroppableFiles(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDroppableFiles(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty else { return false }
        // Space-joined, shell-escaped paths + a trailing space, exactly like
        // dropping a file into iTerm2; claude reads the path (images included).
        let text = urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " "
        if window?.makeFirstResponder(self) == true {
            reportFocusIfNeeded(explicit: true)
        }
        send(txt: text)
        return true
    }

    private func hasDroppableFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Backslash-escape characters the shell / prompt would otherwise split on
    /// (spaces, quotes, globs…), so a path with spaces arrives as one token.
    static func shellEscape(_ path: String) -> String {
        let special = Set(" \t\n\"'\\()[]{}$&;|<>*?!#`~")
        var out = ""
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Key interception for iTerm2 "natural text editing": ⌘← ^A, ⌘→ ^E,
    /// ⌘⌫ ^U. Only when this terminal is first responder — never steals keys
    /// from the notes editor.
    ///
    /// AppKit only runs the key-equivalent phase for ⌘/⌃-modified keys, so
    /// Shift+Return goes straight to `keyDown` and can never arrive here; it is
    /// handled by `installShiftReturnMonitor` instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if applicationPagingFallback, terminal.mouseMode != .off {
            // A full OpenTUI replay can lose the one-time alternate-screen and
            // kitty-keyboard setup. Send the legacy application sequences
            // directly instead of letting SwiftTerm scroll its empty local
            // normal buffer. Fn itself is intentionally absent from `mods`.
            if mods.isEmpty {
                let functionKey = event.charactersIgnoringModifiers?.unicodeScalars.first
                    .map { Int($0.value) }
                if event.keyCode == 116 || functionKey == NSPageUpFunctionKey {
                    send(EscapeSequences.cmdPageUp)
                    return true
                }
                if event.keyCode == 121 || functionKey == NSPageDownFunctionKey {
                    send(EscapeSequences.cmdPageDown)
                    return true
                }
            }
            // OpenCode's documented Ctrl+Option+B/F bindings are translated
            // to the same semantic Page Up/Down operation when the replay no
            // longer contains the negotiated kitty keyboard flags.
            if mods == [.control, .option],
               let key = event.charactersIgnoringModifiers?.lowercased() {
                if key == "b" { send(EscapeSequences.cmdPageUp); return true }
                if key == "f" { send(EscapeSequences.cmdPageDown); return true }
            }
        }
        if mods == .command {
            switch event.keyCode {
            case 123: send([0x01]); return true // ⌘←
            case 124: send([0x05]); return true // ⌘→
            case 51: send([0x15]); return true  // ⌘⌫
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// SwiftTerm view attached to a daemon-owned pane over the socket.
struct TerminalHostView: NSViewRepresentable {
    let paneID: String
    let client: DaemonClient
    let font: NSFont
    /// 16-color ANSI palette. Config `ansiColors` (e.g. the user's iTerm2
    /// palette, so both terminals render identically) with the surgical
    /// `Theme.terminalAnsi` as fallback.
    let palette: [(UInt8, UInt8, UInt8)]
    let allowMouseModeRecovery: Bool
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let tv = GlassTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        tv.installColors(palette.map {
            SwiftTerm.Color(red: UInt16($0.0) * 257,
                            green: UInt16($0.1) * 257,
                            blue: UInt16($0.2) * 257)
        })
        // Fork option: default-bg cells stay unpainted so the glass shows
        // through text rows, while the solid nativeBackgroundColor keeps
        // inverse-video (pasted-text standout) readable.
        tv.transparentBackground = true
        tv.nativeBackgroundColor = Theme.terminalBGNS
        tv.nativeForegroundColor = Theme.terminalFGNS
        tv.font = font
        tv.layer?.backgroundColor = NSColor.clear.cgColor
        tv.terminalDelegate = context.coordinator
        context.coordinator.updateOnFocus(onFocus)
        tv.onFocus = { [weak coordinator = context.coordinator] in
            coordinator?.didFocus()
        }
        context.coordinator.attach(tv: tv, client: client, paneID: paneID,
                                   allowMouseModeRecovery: allowMouseModeRecovery)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        if nsView.font.pointSize != font.pointSize || nsView.font.fontName != font.fontName {
            nsView.font = font
        }
        // Defensive: anything upstream re-stamping the layer with the solid
        // native background would silently kill the glass.
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.updateOnFocus(onFocus)
        (nsView as? GlassTerminalView)?.onFocus = { [weak coordinator = context.coordinator] in
            coordinator?.didFocus()
        }
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        (nsView as? GlassTerminalView)?.onFocus = nil
        nsView.terminalDelegate = nil
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private enum TransportMode: Equatable { case negotiating, surface, raw }

        private enum DecodedSurfaceUpdate {
            case snapshot(TerminalSurfaceSnapshot, TerminalSurfacePacket, UInt64)
            case patch(TerminalSurfacePatch, TerminalSurfacePacket)
        }

        private struct QueuedSurfaceUpdate {
            let update: DecodedSurfaceUpdate
            let acknowledge: () -> Void
        }

        private struct ResizeLease: Equatable {
            let token: String
            let generation: UInt64
            let ttlMS: UInt64
        }

        private weak var tv: TerminalView?
        private var client: DaemonClient?
        private var paneID = ""
        private var token: UUID?
        private var attachmentGeneration: UInt64 = 0
        private var transport: TransportMode = .negotiating
        private var presentationReady = false
        private var appOnFocus: (() -> Void)?

        // Native surface sequencing. All fields below are main-thread only;
        // decoding happens on DaemonClient's per-view serial delivery queue.
        private var paneEpoch: String?
        private var surfaceRevision: UInt64?
        private var awaitingSurfaceSnapshot = true
        private var surfaceResyncAttempts = 0
        /// Overflow generations are scoped to one DaemonClient subscription.
        /// A snapshot records which generations its socket position covers, so
        /// only a genuinely later drop forces another resync.
        private var lastSurfaceRecoveryGeneration: UInt64 = 0
        private var pendingSurfaceOverflowGeneration: UInt64?
        private var pendingSurfaceUpdates: [QueuedSurfaceUpdate] = []
        private var surfaceFlushScheduled = false
        private var pendingRemoteProgress: (state: Int, value: UInt8?, paneEpoch: String)?
        private static let pendingSurfaceUpdateCap = 128

        // Resize authority is separate from the render epoch. RIS/ED3 can
        // replace a surface snapshot without invalidating this pane lease.
        private var resizeLease: ResizeLease?
        private var resizeLeaseRequestSerial: UInt64 = 0
        private var resizeLeaseHeartbeat: Timer?
        private var wantsFocusedLease = false

        func updateOnFocus(_ handler: @escaping () -> Void) {
            appOnFocus = handler
        }

        func didFocus() {
            appOnFocus?()
            wantsFocusedLease = true
            if transport == .surface { requestResizeLease(claim: true) }
        }

        func attach(tv: TerminalView, client: DaemonClient, paneID: String,
                    allowMouseModeRecovery: Bool) {
            detach()
            attachmentGeneration &+= 1
            let generation = attachmentGeneration
            self.tv = tv
            self.client = client
            self.paneID = paneID
            transport = .negotiating
            presentationReady = false
            awaitingSurfaceSnapshot = true
            surfaceResyncAttempts = 0
            lastSurfaceRecoveryGeneration = 0
            pendingSurfaceOverflowGeneration = nil
            nudgeOnNextResize = true

            token = client.subscribePreferredSurface(
                paneID: paneID,
                surface: { [weak self, weak tv]
                           packet, coveredOverflowGeneration, acknowledge in
                    let decoded: Result<DecodedSurfaceUpdate, Error> = Result {
                        try Self.decodeSurface(
                            packet,
                            coveredOverflowGeneration: coveredOverflowGeneration)
                    }
                    DispatchQueue.main.async {
                        guard let self, let tv = tv as? GlassTerminalView,
                              self.attachmentGeneration == generation,
                              self.tv === tv else {
                            acknowledge()
                            return
                        }
                        switch decoded {
                        case .success(let update):
                            self.enqueueSurfaceUpdate(
                                update, acknowledge: acknowledge,
                                generation: generation)
                        case .failure(let error):
                            self.handleSurfaceDecodeFailure(
                                packet: packet, error: error, generation: generation)
                            acknowledge()
                        }
                    }
                },
                surfaceEvent: { [weak self, weak tv] message, acknowledge in
                    DispatchQueue.main.async {
                        defer { acknowledge() }
                        guard let self, let tv = tv as? GlassTerminalView,
                              self.attachmentGeneration == generation,
                              self.tv === tv,
                              self.transport != .raw,
                              let eventPaneEpoch = message.paneEpoch else { return }
                        if message.surfaceEvent == TerminalSurfaceEventKind.progress,
                           let state = message.surfaceProgressState {
                            if self.transport == .surface,
                               !self.awaitingSurfaceSnapshot,
                               eventPaneEpoch == self.paneEpoch {
                                tv.applyRemoteProgress(
                                    state: state, value: message.surfaceProgressValue)
                            } else {
                                // Snapshot and event share the delivery queue,
                                // but their main-thread blocks may straddle the
                                // scheduled surface flush. Keep the latest event
                                // until the snapshot boundary is actually applied.
                                self.pendingRemoteProgress = (
                                    state, message.surfaceProgressValue, eventPaneEpoch)
                            }
                        }
                    }
                },
                onSurfaceOverflow: { [weak self, weak tv] overflowGeneration in
                    DispatchQueue.main.async {
                        guard let self, let tv = tv as? GlassTerminalView,
                              self.attachmentGeneration == generation,
                              self.tv === tv,
                              self.transport != .raw else { return }
                        guard overflowGeneration > self.lastSurfaceRecoveryGeneration else {
                            return
                        }
                        self.pendingSurfaceOverflowGeneration = max(
                            self.pendingSurfaceOverflowGeneration ?? 0,
                            overflowGeneration)
                        if self.transport == .surface,
                           !self.awaitingSurfaceSnapshot {
                            self.requestSurfaceResync(
                                reason: "surface delivery backlog exceeded cap")
                        }
                    }
                },
                rawReplay: { [weak self, weak tv] bytes, cols, rows in
                    guard let self, let tv = tv as? GlassTerminalView,
                          self.attachmentGeneration == generation,
                          self.tv === tv else { return }
                    self.enterRawTransport(tv: tv, reason: nil)
                    let size = tv.applyReplay(
                        bytes, cols: cols, rows: rows,
                        allowMouseModeRecovery: allowMouseModeRecovery)
                    guard self.attachmentGeneration == generation else { return }
                    self.pendingSize = size
                    self.presentationReady = true
                    self.schedulePendingResize(generation: generation)
                },
                rawHandler: { [weak self, weak tv] bytes in
                    guard let self, let tv,
                          self.attachmentGeneration == generation,
                          self.tv === tv,
                          self.transport == .raw else { return }
                    tv.feed(byteArray: bytes[...])
                },
                onFallback: { [weak self, weak tv] reason in
                    guard let self, let tv = tv as? GlassTerminalView,
                          self.attachmentGeneration == generation,
                          self.tv === tv else { return }
                    self.enterRawTransport(tv: tv, reason: reason)
                })
        }

        func detach() {
            // The rows±1 redraw pair exists only in raw replay compatibility.
            // Native surfaces never locally resize or nudge the PTY.
            cancelPendingResizeRestore(restoringNow: transport == .raw)
            releaseResizeLease()
            attachmentGeneration &+= 1
            if let token, let client { client.unsubscribe(paneID: paneID, token: token) }
            token = nil
            resizeTimer?.invalidate()
            resizeTimer = nil
            pendingSize = nil
            presentationReady = false
            nudgeOnNextResize = true
            transport = .negotiating
            paneEpoch = nil
            surfaceRevision = nil
            awaitingSurfaceSnapshot = true
            surfaceResyncAttempts = 0
            lastSurfaceRecoveryGeneration = 0
            pendingSurfaceOverflowGeneration = nil
            discardPendingSurfaceUpdates()
            surfaceFlushScheduled = false
            pendingRemoteProgress = nil
            wantsFocusedLease = false
            tv = nil
            client = nil
            paneID = ""
        }

        // MARK: Native surface sequencing

        private static func decodeSurface(
            _ packet: TerminalSurfacePacket,
            coveredOverflowGeneration: UInt64
        ) throws
            -> DecodedSurfaceUpdate {
            let data = Data(packet.bytes)
            switch packet.kind {
            case .snapshot:
                let snapshot = try JSONDecoder().decode(TerminalSurfaceSnapshot.self, from: data)
                guard snapshot.formatVersion == TerminalSurfaceSnapshot.currentFormatVersion,
                      snapshot.revision == packet.revision else {
                    throw NSError(
                        domain: "TaskDeck.TerminalSurface", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "snapshot envelope/revision mismatch"])
                }
                return .snapshot(snapshot, packet, coveredOverflowGeneration)
            case .patch:
                let patch = try JSONDecoder().decode(TerminalSurfacePatch.self, from: data)
                guard patch.formatVersion == TerminalSurfaceSnapshot.currentFormatVersion,
                      patch.baseRevision == packet.baseRevision,
                      patch.revision == packet.revision else {
                    throw NSError(
                        domain: "TaskDeck.TerminalSurface", code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "patch envelope/revision mismatch"])
                }
                return .patch(patch, packet)
            }
        }

        private func enqueueSurfaceUpdate(_ update: DecodedSurfaceUpdate,
                                          acknowledge: @escaping () -> Void,
                                          generation: UInt64) {
            guard attachmentGeneration == generation, transport != .raw else {
                acknowledge()
                return
            }
            if pendingSurfaceUpdates.count >= Self.pendingSurfaceUpdateCap {
                if transport == .surface {
                    requestSurfaceResync(reason: "surface update queue exceeded cap")
                } else if let tv = tv as? GlassTerminalView {
                    failSurface(tv: tv, reason: "initial surface update queue exceeded cap")
                }
                acknowledge()
                return
            }
            pendingSurfaceUpdates.append(QueuedSurfaceUpdate(
                update: update, acknowledge: acknowledge))
            guard !surfaceFlushScheduled else { return }
            surfaceFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.flushSurfaceUpdates(generation: generation)
            }
        }

        private func flushSurfaceUpdates(generation: UInt64) {
            // detach() already acknowledged the old attachment's queued work.
            // A stale scheduled flush must not discard updates that belong to a
            // newer attachment reusing this Coordinator.
            guard attachmentGeneration == generation else { return }
            surfaceFlushScheduled = false
            let updates = pendingSurfaceUpdates
            pendingSurfaceUpdates.removeAll(keepingCapacity: true)
            for (index, queued) in updates.enumerated() {
                let shouldContinue = applySurfaceUpdate(
                    queued.update, generation: generation)
                queued.acknowledge()
                if !shouldContinue {
                    for remainder in updates.dropFirst(index + 1) {
                        remainder.acknowledge()
                    }
                    break
                }
            }
            if !pendingSurfaceUpdates.isEmpty, !surfaceFlushScheduled,
               transport != .raw {
                surfaceFlushScheduled = true
                DispatchQueue.main.async { [weak self] in
                    self?.flushSurfaceUpdates(generation: generation)
                }
            }
        }

        private func applySurfaceUpdate(_ update: DecodedSurfaceUpdate,
                                        generation: UInt64) -> Bool {
            guard attachmentGeneration == generation,
                  let tv = tv as? GlassTerminalView else { return false }
            do {
                switch update {
                case .snapshot(
                    let snapshot, let packet, let coveredOverflowGeneration
                ):
                    guard paneEpoch == nil || paneEpoch == packet.paneEpoch else {
                        failSurface(tv: tv, reason: "terminal pane lifetime changed")
                        return false
                    }
                    _ = try tv.applyRemoteSnapshot(snapshot)
                    paneEpoch = packet.paneEpoch
                    surfaceRevision = snapshot.revision
                    awaitingSurfaceSnapshot = false
                    surfaceResyncAttempts = 0
                    transport = .surface
                    presentationReady = true
                    lastSurfaceRecoveryGeneration = max(
                        lastSurfaceRecoveryGeneration,
                        coveredOverflowGeneration)
                    if let pending = pendingSurfaceOverflowGeneration,
                       pending <= coveredOverflowGeneration {
                        pendingSurfaceOverflowGeneration = nil
                    }
                    if let pending = pendingSurfaceOverflowGeneration,
                       pending > coveredOverflowGeneration {
                        // A later overflow happened after this snapshot reached
                        // the client. Do not accept the remainder of this batch;
                        // the next response snapshot is the authority boundary.
                        requestSurfaceResync(
                            reason: "surface delivery overflow after snapshot boundary")
                        return false
                    }
                    if let progress = pendingRemoteProgress,
                       progress.paneEpoch == packet.paneEpoch {
                        tv.applyRemoteProgress(
                            state: progress.state, value: progress.value)
                    }
                    pendingRemoteProgress = nil
                    requestResizeLease(claim: wantsFocusedLease)
                    return true

                case .patch(let patch, let packet):
                    guard transport == .surface, !awaitingSurfaceSnapshot else { return true }
                    guard paneEpoch == packet.paneEpoch,
                          surfaceRevision == patch.baseRevision else {
                        requestSurfaceResync(reason: "surface revision gap")
                        return false
                    }
                    _ = try tv.applyRemotePatch(patch)
                    surfaceRevision = patch.revision
                    return true
                }
            } catch {
                switch update {
                case .snapshot:
                    // Repeating an invalid initial/resync snapshot cannot heal
                    // it. Fall back atomically instead of looping forever.
                    failSurface(tv: tv, reason: "surface snapshot apply failed: \(error)")
                case .patch:
                    requestSurfaceResync(reason: "surface patch apply failed: \(error)")
                }
                return false
            }
        }

        private func handleSurfaceDecodeFailure(packet: TerminalSurfacePacket,
                                                error: Error,
                                                generation: UInt64) {
            guard attachmentGeneration == generation,
                  let tv = tv as? GlassTerminalView,
                  transport != .raw else { return }
            // Once a resync boundary is requested, every older patch is
            // superseded by the pending snapshot—including an undecodable one.
            // It must not turn a recoverable gap into a raw downgrade.
            if packet.kind == .patch, awaitingSurfaceSnapshot { return }
            if packet.kind == .patch, transport == .surface, !awaitingSurfaceSnapshot {
                requestSurfaceResync(reason: "surface patch decode failed: \(error)")
            } else {
                failSurface(tv: tv, reason: "surface snapshot decode failed: \(error)")
            }
        }

        private func requestSurfaceResync(reason: String) {
            guard transport == .surface, !awaitingSurfaceSnapshot,
                  let client, let token else { return }
            if surfaceResyncAttempts >= 2 {
                if let tv = tv as? GlassTerminalView {
                    failSurface(tv: tv, reason: "surface resync repeatedly failed: \(reason)")
                }
                return
            }
            surfaceResyncAttempts += 1
            awaitingSurfaceSnapshot = true
            discardPendingSurfaceUpdates()
            client.resyncSurface(paneID: paneID, token: token)
            NSLog("TaskDeck: requesting terminal surface resync pane=\(paneID): \(reason)")
        }

        private func enterRawTransport(tv: GlassTerminalView, reason: String?) {
            guard transport != .raw else { return }
            // Quiesce surface authority before reset. The reset can
            // synchronously report a size change through the delegate; in raw
            // mode with presentationReady=false that size is only remembered
            // until the replay boundary, never sent with the old lease.
            resizeTimer?.invalidate()
            resizeTimer = nil
            cancelPendingResizeRestore(restoringNow: false)
            presentationReady = false
            releaseResizeLease()
            transport = .raw
            if tv.remoteSurfaceMode { tv.resetRemoteSurfaceForRawTransport() }
            paneEpoch = nil
            surfaceRevision = nil
            awaitingSurfaceSnapshot = false
            lastSurfaceRecoveryGeneration = 0
            pendingSurfaceOverflowGeneration = nil
            discardPendingSurfaceUpdates()
            surfaceFlushScheduled = false
            pendingRemoteProgress = nil
            nudgeOnNextResize = true
            if let reason { NSLog("TaskDeck: pane \(paneID) using raw replay fallback: \(reason)") }
        }

        private func discardPendingSurfaceUpdates() {
            let updates = pendingSurfaceUpdates
            pendingSurfaceUpdates.removeAll(keepingCapacity: true)
            for queued in updates { queued.acknowledge() }
        }

        private func failSurface(tv: GlassTerminalView, reason: String) {
            guard transport != .raw else { return }
            // Release resize authority before the socket changes transport.
            enterRawTransport(tv: tv, reason: reason)
            client?.fallbackSurfaceToLegacy(paneID: paneID, reason: reason)
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard source === tv, !paneID.isEmpty else { return }
            var m = WireMessage(type: "input")
            m.paneID = paneID
            m.setData(Array(data))
            client?.fire(m)
        }

        private var resizeTimer: Timer?
        private var pendingSize: (cols: Int, rows: Int)?
        private var nudgeOnNextResize = true

        // Legacy compatibility for old daemons or panes whose native surface
        // explicitly falls back. Native surfaces never enter this replay/nudge
        // path; keep its lifecycle isolated so it can be retired separately.
        private struct PendingResizeRestore {
            let id: UUID
            let generation: UInt64
            let paneID: String
            let cols: Int
            let rows: Int
            let client: DaemonClient
        }
        private var resizeRestoreWorkItem: DispatchWorkItem?
        private var pendingResizeRestore: PendingResizeRestore?

        private static func resizeMessage(paneID: String, cols: Int, rows: Int) -> WireMessage {
            var m = WireMessage(type: "resize")
            m.paneID = paneID
            m.cols = cols
            m.rows = rows
            return m
        }

        private func schedulePendingResize(generation: UInt64) {
            guard presentationReady else { return }
            if transport == .surface {
                scheduleSurfaceResize(generation: generation)
                return
            }
            guard transport == .raw else { return }
            // A real layout change supersedes an attach-time restore. Finish
            // that pair immediately, then debounce the newly observed size.
            cancelPendingResizeRestore(restoringNow: true)
            resizeTimer?.invalidate()
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) {
                [weak self] _ in
                guard let self,
                      self.attachmentGeneration == generation,
                      self.presentationReady,
                      self.transport == .raw,
                      let size = self.pendingSize,
                      let client = self.client,
                      !self.paneID.isEmpty else { return }
                self.pendingSize = nil
                let paneID = self.paneID
                if self.nudgeOnNextResize {
                    self.nudgeOnNextResize = false
                    // The 70 ms observation window is intentional. A
                    // back-to-back rows-1/rows pair lets SIGWINCH coalesce;
                    // Claude can then read the already-restored dimensions,
                    // decide that nothing changed, and leave its sticky footer
                    // visually stale until selection or a manual resize.
                    let nudgeRows = size.rows > 2 ? size.rows - 1 : size.rows + 1
                    client.fire(Self.resizeMessage(
                        paneID: paneID, cols: size.cols, rows: nudgeRows))
                    self.scheduleResizeRestore(
                        generation: generation, paneID: paneID,
                        cols: size.cols, rows: size.rows, client: client)
                } else {
                    client.fire(Self.resizeMessage(
                        paneID: paneID, cols: size.cols, rows: size.rows))
                }
            }
        }

        private func scheduleSurfaceResize(generation: UInt64) {
            guard resizeLease != nil else { return }
            cancelPendingResizeRestore(restoringNow: false)
            resizeTimer?.invalidate()
            let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self,
                      self.attachmentGeneration == generation,
                      self.transport == .surface,
                      let size = self.pendingSize,
                      let client = self.client,
                      let paneEpoch = self.paneEpoch,
                      let surfaceClientID = self.surfaceClientID,
                      let lease = self.resizeLease else { return }
                // Keep the latest desired size after sending. If another view
                // preempts this lease and this view later regains focus, it
                // must be able to restore its geometry even though no new
                // NSView sizeChanged event occurred in between.
                var message = WireMessage(type: "surfaceResize")
                message.paneID = self.paneID
                message.paneEpoch = paneEpoch
                message.surfaceClientID = surfaceClientID
                message.resizeLeaseToken = lease.token
                message.resizeLeaseGeneration = lease.generation
                message.cols = size.cols
                message.rows = size.rows
                client.fire(message)
            }
            resizeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func scheduleResizeRestore(generation: UInt64, paneID: String,
                                           cols: Int, rows: Int, client: DaemonClient) {
            cancelPendingResizeRestore(restoringNow: true)
            let restore = PendingResizeRestore(
                id: UUID(), generation: generation, paneID: paneID,
                cols: cols, rows: rows, client: client)
            pendingResizeRestore = restore
            let restoreID = restore.id
            let workItem = DispatchWorkItem { [weak self] in
                self?.completePendingResizeRestore(id: restoreID)
            }
            resizeRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(70), execute: workItem)
        }

        private func completePendingResizeRestore(id: UUID) {
            guard let restore = pendingResizeRestore, restore.id == id else { return }
            resizeRestoreWorkItem = nil
            pendingResizeRestore = nil
            guard attachmentGeneration == restore.generation,
                  presentationReady,
                  transport == .raw,
                  paneID == restore.paneID,
                  client === restore.client,
                  tv != nil else { return }
            restore.client.fire(Self.resizeMessage(
                paneID: restore.paneID, cols: restore.cols, rows: restore.rows))
        }

        /// Cancel an obsolete delayed callback. When its temporary resize has
        /// already been sent, optionally enqueue the matching final size now;
        /// this preserves the PTY invariant without allowing the old callback
        /// to affect a later attachment of the same coordinator.
        private func cancelPendingResizeRestore(restoringNow: Bool) {
            resizeRestoreWorkItem?.cancel()
            resizeRestoreWorkItem = nil
            guard let restore = pendingResizeRestore else { return }
            pendingResizeRestore = nil
            guard restoringNow,
                  attachmentGeneration == restore.generation,
                  paneID == restore.paneID,
                  client === restore.client else { return }
            restore.client.fire(Self.resizeMessage(
                paneID: restore.paneID, cols: restore.cols, rows: restore.rows))
        }

        /// Debounced: live-resizing a split fires this per FRAME; forwarding
        /// each one SIGWINCHes the shell dozens of times and zsh/p10k
        /// redraws its prompt on every hit — the stacked duplicate prompt
        /// lines after a drag. Tell the PTY only the FINAL size (0.15s
        /// after the drag settles); the local view still reflows live.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard source === tv, newCols > 1, newRows > 1 else { return }
            pendingSize = (newCols, newRows)
            guard presentationReady else { return }
            schedulePendingResize(generation: attachmentGeneration)
        }

        // MARK: Resize lease

        private var surfaceClientID: String? {
            token?.uuidString.lowercased()
        }

        private func requestResizeLease(claim: Bool) {
            guard transport == .surface,
                  let client, let paneEpoch, let surfaceClientID else { return }
            if !claim, resizeLease != nil { return }
            resizeLeaseRequestSerial &+= 1
            let requestSerial = resizeLeaseRequestSerial
            let generation = attachmentGeneration
            var message = WireMessage(type: claim ? "claimResizeLease" : "acquireResizeLease")
            message.paneID = paneID
            message.paneEpoch = paneEpoch
            message.surfaceClientID = surfaceClientID
            client.request(message) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self,
                          self.attachmentGeneration == generation,
                          self.resizeLeaseRequestSerial == requestSerial,
                          self.transport == .surface,
                          self.paneEpoch == paneEpoch,
                          response?.type == "resizeLease",
                          let token = response?.resizeLeaseToken,
                          let leaseGeneration = response?.resizeLeaseGeneration,
                          let ttlMS = response?.resizeLeaseTTLMS else { return }
                    self.resizeLease = ResizeLease(
                        token: token, generation: leaseGeneration, ttlMS: ttlMS)
                    if claim { self.wantsFocusedLease = false }
                    self.startResizeLeaseHeartbeat(ttlMS: ttlMS)
                    self.schedulePendingResize(generation: generation)
                }
            }
        }

        private func startResizeLeaseHeartbeat(ttlMS: UInt64) {
            resizeLeaseHeartbeat?.invalidate()
            let interval = max(1.0, min(5.0, Double(ttlMS) / 3_000.0))
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.renewResizeLease()
            }
            resizeLeaseHeartbeat = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func renewResizeLease() {
            guard transport == .surface,
                  let lease = resizeLease,
                  let client, let paneEpoch, let surfaceClientID else { return }
            let generation = attachmentGeneration
            var message = WireMessage(type: "renewResizeLease")
            message.paneID = paneID
            message.paneEpoch = paneEpoch
            message.surfaceClientID = surfaceClientID
            message.resizeLeaseToken = lease.token
            message.resizeLeaseGeneration = lease.generation
            client.request(message) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self,
                          self.attachmentGeneration == generation,
                          self.transport == .surface,
                          self.resizeLease == lease else { return }
                    guard response?.type == "resizeLease",
                          let token = response?.resizeLeaseToken,
                          let leaseGeneration = response?.resizeLeaseGeneration,
                          let ttlMS = response?.resizeLeaseTTLMS else {
                        self.resizeLease = nil
                        self.resizeLeaseHeartbeat?.invalidate()
                        self.resizeLeaseHeartbeat = nil
                        if let tv = self.tv,
                           tv.window?.isKeyWindow == true,
                           tv.window?.firstResponder === tv {
                            self.wantsFocusedLease = true
                            self.requestResizeLease(claim: true)
                        }
                        return
                    }
                    self.resizeLease = ResizeLease(
                        token: token, generation: leaseGeneration, ttlMS: ttlMS)
                }
            }
        }

        private func releaseResizeLease() {
            resizeLeaseRequestSerial &+= 1 // invalidate acquire/claim completions
            resizeLeaseHeartbeat?.invalidate()
            resizeLeaseHeartbeat = nil
            guard let lease = resizeLease,
                  let client, let paneEpoch, let surfaceClientID,
                  !paneID.isEmpty else {
                resizeLease = nil
                return
            }
            resizeLease = nil
            var message = WireMessage(type: "releaseResizeLease")
            message.paneID = paneID
            message.paneEpoch = paneEpoch
            message.surfaceClientID = surfaceClientID
            message.resizeLeaseToken = lease.token
            message.resizeLeaseGeneration = lease.generation
            client.fire(message)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) { NSSound.beep() }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}

/// Recursive split-tree renderer with draggable dividers.
struct TerminalGridView: View {
    @EnvironmentObject var session: TaskSession
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let layout = session.machine.layout {
                // Trailing gutter comes from the 8pt divider handle, so the
                // grid↔notes gap matches every other 8pt margin.
                LayoutNodeView(node: layout, path: [])
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 34))
                        .foregroundStyle(.quaternary)
                    Text("這個任務還沒有終端")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    NewPaneMenu(labelStyle: .button)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct LayoutNodeView: View {
    @EnvironmentObject var session: TaskSession
    let node: LayoutNode
    let path: [Bool]

    var body: some View {
        switch node {
        case .pane(let specID):
            PaneContainerView(specID: specID)
        case .split(let axis, let ratio, let a, let b):
            GeometryReader { geo in
                let horizontal = axis == "h"
                let total = horizontal ? geo.size.width : geo.size.height
                let first = max(60, total * ratio - 4)
                if horizontal {
                    HStack(spacing: 0) {
                        LayoutNodeView(node: a, path: path + [false]).frame(width: first)
                        DividerHandle(axis: axis, path: path, total: total)
                        LayoutNodeView(node: b, path: path + [true]).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        LayoutNodeView(node: a, path: path + [false]).frame(height: first)
                        DividerHandle(axis: axis, path: path, total: total)
                        LayoutNodeView(node: b, path: path + [true]).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

private struct DividerHandle: View {
    @EnvironmentObject var session: TaskSession
    let axis: String
    let path: [Bool]
    let total: CGFloat
    @State private var startRatio: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(
                Capsule()
                    .fill(hovering || startRatio != nil ? Theme.accent.opacity(0.8) : Theme.text4.opacity(0.5))
                    .frame(width: axis == "h" ? 3 : 36, height: axis == "v" ? 3 : 36)
            )
            .frame(width: axis == "h" ? 10 : nil, height: axis == "v" ? 10 : nil)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h {
                    (axis == "h" ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // .global：同 ColumnDividerHandle——把手隨拖動位移時，區域
                // 座標的 translation 會震盪，分隔線跳動且不跟手。
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startRatio == nil { startRatio = session.ratio(at: path) }
                        guard total > 0 else { return }
                        let delta = Double((axis == "h" ? v.translation.width : v.translation.height) / total)
                        let next = min(0.9, max(0.1, (startRatio ?? 0.5) + delta))
                        session.setRatio(path: path, ratio: next)
                    }
                    .onEnded { _ in startRatio = nil }
            )
    }
}

/// Status dot with an optional slow expanding ring — the only ambient motion
/// in the app, reserved for "an AI CLI is open in this terminal".
private struct PulseDot: View {
    let color: SwiftUI.Color
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringOn = false

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle()
                    .stroke(color.opacity(ringOn ? 0 : 0.6), lineWidth: 1.5)
                    .frame(width: ringOn ? 17 : 7, height: ringOn ? 17 : 7)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 17, height: 17)
        .onAppear(perform: restart)
        .onChange(of: active) { _, _ in restart() }
    }

    private func restart() {
        ringOn = false
        guard active, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { ringOn = true }
    }
}

struct PaneContainerView: View {
    @EnvironmentObject var session: TaskSession
    @EnvironmentObject var model: AppModel
    let specID: String

    private var spec: PaneSpec? { session.spec(specID) }
    private var info: PaneInfo? { model.paneRuntime[specID] }
    /// 邊框高亮只屬於當前焦點區：點了筆記，terminal 的高亮就讓位。
    private var focused: Bool {
        session.focusedSpecID == specID && session.focusZone == .terminal
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                if let info {
                    TerminalHostView(paneID: info.id, client: model.client,
                                     font: model.terminalFont,
                                     palette: model.ansiPalette ?? Theme.terminalAnsi,
                                     allowMouseModeRecovery:
                                         spec?.team?.caseInsensitiveCompare("opencode") == .orderedSame,
                                     onFocus: {
                                         session.focusedSpecID = specID
                                         session.focusZone = .terminal
                                     })
                        .id("\(info.id):\(model.daemonConnectionGeneration)")
                        .padding(.leading, 6)
                        .padding(.top, 4)
                        .background(Theme.terminalBG)
                } else {
                    notStarted
                }
                if let info, !info.running {
                    exitedBar(info)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .stroke(focused ? Theme.accent.opacity(0.55) : Theme.border,
                        lineWidth: focused ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
        .padding(2)
        .contentShape(Rectangle())
        .onTapGesture {
            session.focusedSpecID = specID
            session.focusZone = .terminal
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            // Green = alive; teal + a slow ring = an AI CLI is open here;
            // red = the pane exited.
            let aiOpen = model.paneActivity[specID]?.kind == .ai
            PulseDot(color: info == nil ? Theme.text4
                        : (info!.running ? (aiOpen ? Theme.Lane.ai : Theme.good) : Theme.crit),
                     active: aiOpen && info?.running == true)
            Text(spec?.title ?? "?")
                .font(Theme.Fonts.ui(11 * model.uiScale, .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            if let sid = spec?.sessionID, spec?.kind == "ai" {
                Text(sid.prefix(8))
                    .font(Theme.Fonts.mono(9.5 * model.uiScale))
                    .foregroundStyle(Theme.text4)
                    .help(sid)
            }
            if let activity = model.paneActivity[specID], activity.kind == .service {
                Text("▶ \(activity.label) · \(activityDuration(activity.runningFor))")
                    .font(Theme.Fonts.mono(9.5 * model.uiScale, .semibold))
                    .foregroundStyle(Theme.good)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.good.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .help("這個終端在跑的長跑指令（dev server / DB / watcher）")
            }
            // Account badge, clickable. Prefer the session's real account
            // (file location) over the spec's recorded team, which drifts when
            // a different claude was run in the pane. The menu lets you correct
            // the account, or rebind the pane to the session it's ACTUALLY
            // running (fixes the task's group / 現用 / attribution).
            if let spec, spec.kind == "ai" {
                let shown = spec.sessionID.flatMap { model.teamFromSessionFile($0) } ?? spec.team ?? "?"
                Menu {
                    Section("這個終端的帳號") {
                        ForEach(model.config.teams.filter { $0.kind == "claude" }) { t in
                            Button {
                                session.rebindPane(specID: spec.id, team: t.id, sid: nil)
                            } label: {
                                if t.id == spec.team { Label(t.label, systemImage: "checkmark") }
                                else { Text(t.label) }
                            }
                        }
                    }
                    let recents = model.recentSessions(cwd: Paths.expand(spec.cwd ?? model.config.defaultCwd))
                    if !recents.isEmpty {
                        Section("重新綁定到實際 session（近期）") {
                            ForEach(recents, id: \.sid) { r in
                                Button {
                                    session.rebindPane(specID: spec.id, team: r.team, sid: r.sid)
                                } label: {
                                    let mark = r.sid == spec.sessionID ? "● " : ""
                                    Text("\(mark)\(r.team) · \(r.sid.prefix(8))")
                                }
                            }
                        }
                    }
                } label: {
                    Text(shown)
                        .font(Theme.Fonts.mono(9.5, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("點擊：改這個終端的帳號，或重新綁定到它實際在跑的 session")
            }
            if spec?.autoStart == true {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .help("開任務時自動啟動")
            }
            Spacer()
            Menu {
                if let spec {
                    // Side panes live outside the split tree — splitting one
                    // spawned an invisible pane parked in no layout.
                    if spec.location != "side" {
                        Button("向右分割") { session.splitPane(spec.id, axis: "h") }
                        Button("向下分割") { session.splitPane(spec.id, axis: "v") }
                        Divider()
                    }
                    if model.hasITerm2, let info, info.running {
                        Button("在 iTerm2 開啟（附掛）") { model.openPaneInITerm2(info) }
                        Divider()
                    }
                    Button("重新啟動") { session.restartPane(spec) }
                    Toggle("開任務時自動啟動", isOn: Binding(
                        get: { spec.autoStart },
                        set: { _ in session.toggleAutoStart(spec) }
                    ))
                    Divider()
                    Button("關閉", role: .destructive) { session.closePane(spec) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Theme.paneHeaderBG)
    }

    private var notStarted: some View {
        VStack(spacing: 12) {
            Text(spec?.kind == "ai" ? "AI session 未啟動" : "終端未啟動")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            if let cmd = spec?.startCommand {
                Text(cmd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
            }
            Button {
                if let spec { session.restartPane(spec) }
            } label: {
                Label(spec?.sessionID != nil ? "啟動並續上對話" : "啟動", systemImage: "play.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent.opacity(0.8))
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBG)
    }

    private func exitedBar(_ info: PaneInfo) -> some View {
        HStack(spacing: 10) {
            Text("已結束（exit \(info.exitCode.map(String.init) ?? "?")）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("重新啟動") { if let spec { session.restartPane(spec) } }
                .controlSize(.small)
            Button("關閉") { if let spec { session.closePane(spec) } }
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}
