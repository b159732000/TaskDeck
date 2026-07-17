import AppKit
import SwiftUI

/// Behind-window blur layer (iTerm2-style glass). Pair with
/// `TransparentWindow` so the NSWindow lets the desktop show through.
/// `state: .active` keeps the blur when the window loses focus — the
/// default (.followsWindowActiveState) collapses to a solid fill.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

/// Makes the hosting NSWindow non-opaque with a transparent titlebar.
/// SwiftUI re-asserts window properties at various points, so the settings
/// are re-applied on window key/main transitions instead of only once.
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var tokens: [NSObjectProtocol] = []

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
        }

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private func applyGlass() {
            guard let w = window else { return }
            // styleMask first: mutating it can rebuild the titlebar views.
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isOpaque = false
            w.backgroundColor = .clear
            hideTitlebarMaterial(w)
        }

        /// The titlebar container can carry its own NSVisualEffectView
        /// (solid when inactive); hide it — traffic lights are separate.
        private func hideTitlebarMaterial(_ w: NSWindow) {
            guard let frameView = w.contentView?.superview else { return }
            for view in frameView.subviews
            where String(describing: type(of: view)).contains("NSTitlebar") {
                for sub in Self.allSubviews(of: view) {
                    if let effect = sub as? NSVisualEffectView {
                        effect.isHidden = true
                    }
                }
            }
        }

        private static func allSubviews(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
        }
    }
}

extension View {
    /// Transparent window + behind-window blur, bottom of the view stack.
    func glassWindow() -> some View {
        background(VisualEffectBackground().ignoresSafeArea())
            .background(TransparentWindow())
    }
}
