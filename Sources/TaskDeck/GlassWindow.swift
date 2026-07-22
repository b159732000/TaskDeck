import AppKit
import SwiftUI
import TaskDeckCore

/// Behind-window blur layer (iTerm2-style glass). Pair with
/// `TransparentWindow` so the NSWindow lets the desktop show through.
/// `state: .active` keeps the blur when the window loses focus — the
/// default (.followsWindowActiveState) collapses to a solid fill.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = Theme.blurMaterial
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
        // 模糊風格（外觀設定的三檔）：re-render 時同步 material。
        if nsView.material != Theme.blurMaterial {
            nsView.material = Theme.blurMaterial
        }
    }
}

/// Makes the hosting NSWindow non-opaque with a transparent titlebar.
/// SwiftUI re-asserts window properties at various points, so the settings
/// are re-applied on window key/main transitions instead of only once.
struct TransparentWindow: NSViewRepresentable {
    var autosaveName: String?

    func makeNSView(context: Context) -> NSView { Probe(autosaveName: autosaveName) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private let autosaveName: String?
        private var didRestoreFrame = false
        private var tokens: [NSObjectProtocol] = []

        init(autosaveName: String?) {
            self.autosaveName = autosaveName
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyGlass()
            DispatchQueue.main.async { [weak self] in self?.applyGlass() }

            guard let w = window, tokens.isEmpty else { return }
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
            ]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: w, queue: .main
                ) { [weak self] _ in
                    self?.applyGlass()
                })
            }
            // Scroll-edge backdrops get (re)created as content scrolls under
            // the titlebar. didUpdate fires near per-frame while terminals
            // stream, and the sweep walks the whole view tree — throttle it.
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: w, queue: .main
            ) { [weak self] _ in
                self?.throttledBackdropSweep()
            })
        }

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private func applyGlass() {
            guard let w = window else { return }
            // Frame memory: reopen where the window was last closed —
            // AppKit saves the frame to defaults on move/resize/close and
            // we re-apply it once at attach. Works the same whether the app
            // was quit by dev.sh or by hand（存的是 defaults，跟誰關的無關）.
            if !didRestoreFrame, let name = autosaveName {
                didRestoreFrame = true
                if w.setFrameAutosaveName(name) {
                    w.setFrameUsingName(name)
                }
            }
            // styleMask first: mutating it can rebuild the titlebar views.
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isOpaque = false
            w.backgroundColor = .clear
            hideTitlebarMaterial(w)
            hideScrollEdgeBackdrops()
            dumpFrameIfRequested(w)
        }

        private var lastSweep = Date.distantPast

        /// Rate-limited entry for the per-didUpdate sweep (≤5/s). applyGlass
        /// still calls the unthrottled sweep for immediate correctness on
        /// real chrome changes.
        private func throttledBackdropSweep() {
            let now = Date()
            guard now.timeIntervalSince(lastSweep) > 0.2 else { return }
            lastSweep = now
            hideScrollEdgeBackdrops()
        }

        /// macOS 26 adds opaque "BackdropView" scroll-edge layers where list
        /// content scrolls under the titlebar — the last opaque strip over
        /// the traffic-light row. Our chrome provides its own backgrounds,
        /// so hide them wherever they appear.
        private func hideScrollEdgeBackdrops() {
            guard let content = window?.contentView else { return }
            for v in Self.allSubviews(of: content)
            where !v.isHidden && String(describing: type(of: v)).contains("BackdropView") {
                v.isHidden = true
            }
        }

        /// The titlebar container can carry its own NSVisualEffectView
        /// (solid when inactive) AND — on macOS 26 — a
        /// `_NSTitlebarDecorationView` drawing the Liquid-Glass chrome that
        /// reads as a solid strip over our tinted glass. Hide both; the
        /// traffic-light buttons live in separate widget views and are
        /// untouched.
        private func hideTitlebarMaterial(_ w: NSWindow) {
            guard let frameView = w.contentView?.superview else { return }
            for view in frameView.subviews
            where String(describing: type(of: view)).contains("NSTitlebar") {
                for sub in Self.allSubviews(of: view) {
                    let cls = String(describing: type(of: sub))
                    if sub is NSVisualEffectView || cls.contains("Decoration") {
                        sub.isHidden = true
                    }
                }
            }
        }

        private static func allSubviews(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
        }

        /// Debug aid: `defaults write app.taskdeck.TaskDeck dumpFrame -bool true`
        /// then relaunch — writes the theme-frame view tree to
        /// App Support/framedump.txt so opaque titlebar layers can be found.
        func dumpFrameIfRequested(_ w: NSWindow) {
            guard UserDefaults.standard.bool(forKey: "dumpFrame"),
                  let frameView = w.contentView?.superview else { return }
            var lines: [String] = []
            func walk(_ v: NSView, _ depth: Int) {
                let cls = String(describing: type(of: v))
                var extra = " hidden=\(v.isHidden)"
                if let layer = v.layer {
                    extra += " layerBG=\(layer.backgroundColor == nil ? "nil" : "SET") layerOpaque=\(layer.isOpaque)"
                }
                if let effect = v as? NSVisualEffectView {
                    extra += " material=\(effect.material.rawValue) state=\(effect.state.rawValue)"
                }
                lines.append(String(repeating: "  ", count: depth)
                    + "\(cls) \(Int(v.frame.origin.x)),\(Int(v.frame.origin.y)) \(Int(v.frame.width))x\(Int(v.frame.height))"
                    + extra)
                v.subviews.forEach { walk($0, depth + 1) }
            }
            walk(frameView, 0)
            try? lines.joined(separator: "\n")
                .write(to: Paths.appSupport.appendingPathComponent("framedump.txt"),
                       atomically: true, encoding: .utf8)
        }
    }
}

extension View {
    /// Transparent window + behind-window blur, bottom of the view stack.
    /// `autosave` gives the window a frame-autosave identity so it reopens
    /// at its last position/size (per-task popouts get their own name).
    func glassWindow(autosave: String? = nil) -> some View {
        background(VisualEffectBackground().ignoresSafeArea())
            .background(TransparentWindow(autosaveName: autosave))
    }
}
