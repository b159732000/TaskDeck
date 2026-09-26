import AppKit
import SwiftUI
import TaskDeckCore

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
        /// Base alpha of each layer at boost 0. The classic presets are true
        /// glass (22–37%). Night Lane keeps the WINDOW and TERMINAL at that
        /// glass (the iTerm2 feel the terminal work in 4e85a30 / 81dc529 /
        /// acd577e earned) and only raises the chrome — sidebar panel and
        /// pane headers — so type there stays legible over any wallpaper.
        /// The terminal's effective opacity is window × terminal stacked, so
        /// raising the window layer darkens every shell; keep both low.
        var alphas: (window: Double, panel: Double, header: Double, terminal: Double)
            = (0.22, 0.26, 0.33, 0.37)
    }

    /// Index of the factory default. Night Lane is appended (not inserted) so
    /// a preset index a user already saved keeps pointing at the same look.
    static let defaultPresetIndex = 5

    static let bgPresets: [BGPreset] = [
        .init(name: "石墨藍", window: 0x0E1116, panel: 0x131820,
              header: 0x1A202A, terminal: 0x14181F, border: 0x2A3341),
        .init(name: "純中性", window: 0x101012, panel: 0x151517,
              header: 0x1D1D20, terminal: 0x131315, border: 0x303036),
        .init(name: "暖岩", window: 0x141009, panel: 0x1A150E,
              header: 0x231C12, terminal: 0x18130C, border: 0x3B3222),
        .init(name: "松綠", window: 0x0C1410, panel: 0x101A15,
              header: 0x16231C, terminal: 0x101814, border: 0x28392F),
        .init(name: "暗紫", window: 0x120E1A, panel: 0x171221,
              header: 0x1F182B, terminal: 0x151021, border: 0x362B49),
        .init(name: "夜間車道（預設）", window: 0x0A0C11, panel: 0x10131A,
              header: 0x161A23, terminal: 0x14181F, border: 0x262C3A,
              alphas: (0.24, 0.70, 0.82, 0.37)),
    ]

    // Current appearance (mirrored from AppModel's persisted @Published
    // values; UserDefaults seeds the first read so launch is correct).
    static var bgPresetIndex: Int =
        UserDefaults.standard.object(forKey: "bgPresetIndex") as? Int ?? defaultPresetIndex
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

    static var windowBG: Color { bg(preset.window, preset.alphas.window) }
    static var panelBG: Color { bg(preset.panel, preset.alphas.panel) }
    static var paneHeaderBG: Color { bg(preset.header, preset.alphas.header) }
    static var terminalBG: Color { bg(preset.terminal, preset.alphas.terminal) }
    static var border: Color { bg(preset.border, 1.0) }
    /// One step above the panel: chips, dock, raised cards.
    static var raisedBG: Color { bg(preset.header, min(1, preset.alphas.header + 0.08)) }

    /// Accent presets（強調色：焦點框、主力徽章等）。
    static let accentPresets: [(name: String, hex: UInt32)] = [
        ("藍（預設）", 0x5B9DFF), ("紫", 0xB18CFF), ("綠", 0x7FCF8F),
        ("橘", 0xF0A35E), ("粉", 0xEF8FB9),
    ]
    static var accentHexCurrent: UInt32 =
        UserDefaults.standard.object(forKey: "accentHex") as? UInt32 ?? 0x5B9DFF
    static var accent: Color { Color(hex: accentHexCurrent) }

    /// Long-running local services (dev server / DB / watcher). Same green as
    /// the daemon dot: "something of yours is alive", not "something is wrong".
    static let serviceTint = Color(hex: 0x6EE7A0)

    // MARK: - Night Lane

    /// The only saturated colours in the UI: one per sidebar lane. Everything
    /// else is ink, so the eye lands on the lane that needs it (等你 first).
    enum Lane {
        static let you = Color(hex: 0xFF7A5C)     // 等你 — coral
        static let ai = Color(hex: 0x4FD1C5)      // AI 執行中 — teal
        static let idle = Color(hex: 0x8A94A6)    // 待開工 — slate
        static let read = Color(hex: 0xB8A7FF)    // 已讀 — lavender
        static let ext = Color(hex: 0xF5C451)     // 等待外部 — amber
        static let sunk = Color(hex: 0x5C6474)    // 半封存
        static let done = Color(hex: 0x3E4552)    // 已完成
    }

    static func laneColor(_ group: TaskGroup) -> Color {
        switch group {
        case .needsYou: return Lane.you
        case .aiRunning: return Lane.ai
        case .idle: return Lane.idle
        case .read: return Lane.read
        case .waitingExt: return Lane.ext
        case .semiArchived: return Lane.sunk
        case .done: return Lane.done
        }
    }

    /// Semantic colours are separate from the accent hue.
    static let good = Color(hex: 0x6EE7A0)
    static let warn = Color(hex: 0xF5C451)
    static let crit = Color(hex: 0xFF5C7A)
    /// Text ramp on the dark inks.
    static let text = Color(hex: 0xEDF0F6)
    static let text2 = Color(hex: 0xA6AEBE)
    static let text3 = Color(hex: 0x6E7789)
    static let text4 = Color(hex: 0x4B5364)

    enum Radius {
        static let xs: CGFloat = 6, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 22
    }

    /// Three voices: display (titles, lane counts), UI (everything else) and
    /// mono (timestamps, session ids, terminal-adjacent labels). Bundled
    /// variable fonts (Support/Fonts, registered via ATSApplicationFontsPath);
    /// each resolves once per size×weight and falls back to the system face
    /// when the family is missing, so a broken bundle never blanks the UI.
    enum Fonts {
        static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
            font(family: "Bricolage Grotesque", size: size, weight: weight, opticalSize: true,
                 fallback: .system(size: size, weight: weight, design: .rounded))
        }
        static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            font(family: "Instrument Sans", size: size, weight: weight, opticalSize: false,
                 fallback: .system(size: size, weight: weight))
        }
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            font(family: "JetBrains Mono", size: size, weight: weight, opticalSize: false,
                 fallback: .system(size: size, weight: weight, design: .monospaced))
        }

        /// Families that resolved at first use — surfaced by the snapshot
        /// sidecar so a missing bundle is visible without a screenshot.
        nonisolated(unsafe) static var resolved: [String: Bool] = [:]
        nonisolated(unsafe) private static var cache: [String: NSFont] = [:]

        private static func font(family: String, size: CGFloat, weight: Font.Weight,
                                 opticalSize: Bool, fallback: Font) -> Font {
            guard let ns = nsFont(family: family, size: size, weight: weight, opticalSize: opticalSize) else {
                resolved[family] = false
                return fallback
            }
            resolved[family] = true
            return Font(ns)
        }

        static func nsFont(family: String, size: CGFloat, weight: Font.Weight,
                           opticalSize: Bool) -> NSFont? {
            let key = "\(family)|\(size)|\(weight)"
            if let hit = cache[key] { return hit }
            guard let base = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont(name: family, size: size) else { return nil }
            // Variable fonts: drive the axes directly. 'wght' 100–900; 'opsz' in
            // points (Bricolage: 12–96) so small labels get the text cut and
            // titles get the tighter display cut.
            let wght = NSNumber(value: 0x77676874), opsz = NSNumber(value: 0x6F70737A)
            var variation: [NSNumber: NSNumber] = [wght: NSNumber(value: axisWeight(weight))]
            if opticalSize { variation[opsz] = NSNumber(value: Double(min(96, max(12, size)))) }
            let descriptor = base.fontDescriptor.addingAttributes([.variation: variation])
            let font = NSFont(descriptor: descriptor, size: size) ?? base
            cache[key] = font
            return font
        }

        private static func axisWeight(_ weight: Font.Weight) -> Double {
            switch weight {
            case .ultraLight: return 200
            case .thin: return 250
            case .light: return 300
            case .regular: return 400
            case .medium: return 500
            case .semibold: return 600
            case .bold: return 700
            case .heavy: return 800
            case .black: return 800
            default: return 400
            }
        }
    }

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
