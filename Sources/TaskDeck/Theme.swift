import AppKit
import SwiftUI

/// Central design tokens. Dark-first, and translucent: every background
/// carries alpha so the behind-window blur (iTerm2-style glass) shows
/// through. The terminal keeps the highest opacity for readability.
///
/// The base look is user-tunable（選單「外觀」→ 外觀設定）: a bg-hue
/// preset, an opacity boost (0 = 現行玻璃感 → 1 = 不透明) and a
/// brightness nudge, all applied uniformly to the four bg layers.
enum Theme {
    struct BGPreset {
        let name: String
        let window: UInt32, panel: UInt32, header: UInt32, terminal: UInt32, border: UInt32
    }

    static let bgPresets: [BGPreset] = [
        .init(name: "石墨藍（預設）", window: 0x0E1116, panel: 0x131820,
              header: 0x1A202A, terminal: 0x14181F, border: 0x2A3341),
        .init(name: "純中性", window: 0x101012, panel: 0x151517,
              header: 0x1D1D20, terminal: 0x131315, border: 0x303036),
        .init(name: "暖岩", window: 0x141009, panel: 0x1A150E,
              header: 0x231C12, terminal: 0x18130C, border: 0x3B3222),
        .init(name: "松綠", window: 0x0C1410, panel: 0x101A15,
              header: 0x16231C, terminal: 0x101814, border: 0x28392F),
        .init(name: "暗紫", window: 0x120E1A, panel: 0x171221,
              header: 0x1F182B, terminal: 0x151021, border: 0x362B49),
    ]

    // Current appearance (mirrored from AppModel's persisted @Published
    // values; UserDefaults seeds the first read so launch is correct).
    static var bgPresetIndex: Int =
        UserDefaults.standard.object(forKey: "bgPresetIndex") as? Int ?? 0
    /// -1…+1，0＝出廠玻璃感（中性）。負向把四層 alpha 等比往 0 收（更透、
    /// 桌布更明顯），正向往 1 內插（更實心）。
    static var bgOpacityBoost: Double =
        UserDefaults.standard.object(forKey: "bgOpacityBoost") as? Double ?? 0
    static var bgBrightness: Double =
        UserDefaults.standard.object(forKey: "bgBrightness") as? Double ?? 0
    /// 模糊風格（NSVisualEffectView 的 material；macOS 不開放連續調半徑，
    /// 以三檔近似）。
    static var blurStyleIndex: Int =
        UserDefaults.standard.object(forKey: "blurStyleIndex") as? Int ?? 0
    static let blurStyles: [(name: String, material: NSVisualEffectView.Material)] = [
        ("標準（預設）", .underWindowBackground),
        ("柔和", .hudWindow),
        ("強", .fullScreenUI),
    ]
    static var blurMaterial: NSVisualEffectView.Material {
        blurStyles[min(max(0, blurStyleIndex), blurStyles.count - 1)].material
    }

    private static var preset: BGPreset {
        bgPresets[min(max(0, bgPresetIndex), bgPresets.count - 1)]
    }

    private static func bg(_ hex: UInt32, _ baseAlpha: Double) -> Color {
        let f = 1.0 + bgBrightness
        let boost = min(1, max(-1, bgOpacityBoost))
        let a = boost >= 0
            ? baseAlpha + (1 - baseAlpha) * boost // 中性 → 實心
            : baseAlpha * (1 + boost) // 中性 → 全透（只剩 blur）
        return Color(.sRGB,
                     red: min(1, Double((hex >> 16) & 0xFF) / 255 * f),
                     green: min(1, Double((hex >> 8) & 0xFF) / 255 * f),
                     blue: min(1, Double(hex & 0xFF) / 255 * f),
                     opacity: a)
    }

    static var windowBG: Color { bg(preset.window, 0.22) }
    static var panelBG: Color { bg(preset.panel, 0.26) }
    static var paneHeaderBG: Color { bg(preset.header, 0.33) }
    static var terminalBG: Color { bg(preset.terminal, 0.37) }
    static var border: Color { bg(preset.border, 1.0) }

    /// Accent presets（強調色：焦點框、主力徽章等）。
    static let accentPresets: [(name: String, hex: UInt32)] = [
        ("藍（預設）", 0x5B9DFF), ("紫", 0xB18CFF), ("綠", 0x7FCF8F),
        ("橘", 0xF0A35E), ("粉", 0xEF8FB9),
    ]
    static var accentHexCurrent: UInt32 =
        UserDefaults.standard.object(forKey: "accentHex") as? UInt32 ?? 0x5B9DFF
    static var accent: Color { Color(hex: accentHexCurrent) }

    /// Solid, alpha-1 value: SwiftTerm uses it for inverse-video math
    /// (zsh highlights pasted text with standout = fg/bg swap — a clear
    /// color here painted pasted text invisibly). Glass is unaffected:
    /// transparency comes from GlassTerminalView forcing the CALayer clear,
    /// which the nativeBackgroundColor setter never touches.
    static let terminalBGNS = NSColor(hex: 0x14181F)
    static let terminalFGNS = NSColor(hex: 0xDCDFE4)

    /// One-Dark-flavored 16-color ANSI palette (8-bit components).
    /// Used by `AnsiText` (quota table rendering), NOT the terminal.
    static let ansi: [(UInt8, UInt8, UInt8)] = [
        (0x1E, 0x22, 0x27), (0xE0, 0x6C, 0x75), (0x98, 0xC3, 0x79), (0xD1, 0x9A, 0x66),
        (0x61, 0xAF, 0xEF), (0xC6, 0x78, 0xDD), (0x56, 0xB6, 0xC2), (0xAB, 0xB2, 0xBF),
        (0x5C, 0x63, 0x70), (0xE8, 0x7D, 0x86), (0xA9, 0xD4, 0x8A), (0xE2, 0xAB, 0x77),
        (0x72, 0xC0, 0xFF), (0xD7, 0x89, 0xEE), (0x67, 0xC7, 0xD3), (0xFF, 0xFF, 0xFF),
    ]

    /// Terminal (SwiftTerm) ANSI palette: byte-identical mirror of
    /// SwiftTerm's stock `defaultInstalledColors` — its statics are
    /// internal, so overriding two slots means restating all 16 — with ONLY
    /// blue (4) and brightBlue (12) remapped to the light Theme blues
    /// (stock navy is unreadable on the dark glass; Claude's progress bar
    /// uses it). Slots 0/8 must stay stock: darkening them is what made the
    /// earlier fully-custom palette regress dim TUI text.
    static let terminalAnsi: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (153, 0, 1), (0, 166, 3), (153, 153, 0),
        (0x61, 0xAF, 0xEF), (178, 0, 178), (0, 165, 178), (191, 191, 191),
        (138, 137, 138), (229, 0, 1), (0, 216, 0), (229, 229, 0),
        (0x72, 0xC0, 0xFF), (229, 0, 229), (0, 229, 229), (229, 229, 229),
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
