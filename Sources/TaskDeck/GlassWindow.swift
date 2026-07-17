import AppKit
import SwiftUI

/// Behind-window blur layer (iTerm2-style glass). Pair with
/// `TransparentWindow` so the NSWindow lets the desktop show through.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Makes the hosting NSWindow non-opaque with a clear background.
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
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
