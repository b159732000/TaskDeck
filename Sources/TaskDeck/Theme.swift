import AppKit
import SwiftUI

/// Central design tokens. Dark-first, and translucent: every background
/// carries alpha so the behind-window blur (iTerm2-style glass) shows
/// through. The terminal keeps the highest opacity for readability.
enum Theme {
    static let windowBG = Color(hex: 0x0E1116).opacity(0.45)
    static let panelBG = Color(hex: 0x131820).opacity(0.52)
    static let paneHeaderBG = Color(hex: 0x1A202A).opacity(0.66)
    static let terminalBG = Color(hex: 0x14181F).opacity(0.74)
    static let border = Color(hex: 0x2A3341)
    static let accent = Color(hex: 0x5B9DFF)

    static let terminalBGNS = NSColor(hex: 0x14181F).withAlphaComponent(0.74)
    static let terminalFGNS = NSColor(hex: 0xC9CFD8)

    /// One-Dark-flavored 16-color ANSI palette (8-bit components).
    static let ansi: [(UInt8, UInt8, UInt8)] = [
        (0x1E, 0x22, 0x27), (0xE0, 0x6C, 0x75), (0x98, 0xC3, 0x79), (0xD1, 0x9A, 0x66),
        (0x61, 0xAF, 0xEF), (0xC6, 0x78, 0xDD), (0x56, 0xB6, 0xC2), (0xAB, 0xB2, 0xBF),
        (0x5C, 0x63, 0x70), (0xE8, 0x7D, 0x86), (0xA9, 0xD4, 0x8A), (0xE2, 0xAB, 0x77),
        (0x72, 0xC0, 0xFF), (0xD7, 0x89, 0xEE), (0x67, 0xC7, 0xD3), (0xFF, 0xFF, 0xFF),
    ]

}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
