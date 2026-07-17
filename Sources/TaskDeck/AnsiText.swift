import SwiftUI

/// Minimal ANSI SGR → AttributedString renderer, enough to reproduce CLI
/// table output (bold/dim, 16 colors, xterm-256) inside a SwiftUI Text.
/// Unknown sequences are dropped silently.
enum AnsiRenderer {
    static func render(_ text: String, size: CGFloat = 11) -> AttributedString {
        var result = AttributedString()
        var fg: SwiftUI.Color?
        var bold = false
        var dim = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var chunk = AttributedString(buffer)
            var color = fg ?? Color(hex: 0xC9CFD8)
            if dim { color = color.opacity(0.55) }
            chunk.foregroundColor = color
            chunk.font = .system(size: size, weight: bold ? .semibold : .regular, design: .monospaced)
            result += chunk
            buffer = ""
        }

        func apply(_ params: String) {
            let codes = params.split(separator: ";").compactMap { Int($0) }
            var i = 0
            let list = codes.isEmpty ? [0] : codes
            while i < list.count {
                let c = list[i]
                switch c {
                case 0: fg = nil; bold = false; dim = false
                case 1: bold = true
                case 2: dim = true
                case 22: bold = false; dim = false
                case 30 ... 37: fg = ansi16(c - 30)
                case 90 ... 97: fg = ansi16(c - 90 + 8)
                case 39: fg = nil
                case 38, 48: // extended color: "38;5;N" or "38;2;r;g;b"
                    if i + 1 < list.count, list[i + 1] == 5, i + 2 < list.count {
                        if c == 38 { fg = xterm256(list[i + 2]) }
                        i += 2
                    } else if i + 1 < list.count, list[i + 1] == 2, i + 4 < list.count {
                        if c == 38 {
                            fg = Color(.sRGB, red: Double(list[i + 2]) / 255,
                                       green: Double(list[i + 3]) / 255,
                                       blue: Double(list[i + 4]) / 255, opacity: 1)
                        }
                        i += 4
                    }
                default: break
                }
                i += 1
            }
        }

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\u{1b}" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "[" {
                    flush()
                    var j = text.index(after: next)
                    var params = ""
                    while j < text.endIndex, !text[j].isLetter {
                        params.append(text[j])
                        j = text.index(after: j)
                    }
                    if j < text.endIndex {
                        if text[j] == "m" { apply(params) }
                        i = text.index(after: j)
                    } else {
                        i = j
                    }
                    continue
                }
            }
            buffer.append(ch)
            i = text.index(after: i)
        }
        flush()
        return result
    }

    private static func ansi16(_ n: Int) -> SwiftUI.Color {
        let t = Theme.ansi[min(max(n, 0), 15)]
        return Color(.sRGB, red: Double(t.0) / 255, green: Double(t.1) / 255,
                     blue: Double(t.2) / 255, opacity: 1)
    }

    private static func xterm256(_ n: Int) -> SwiftUI.Color {
        if n < 16 { return ansi16(n) }
        if n < 232 {
            let v = n - 16
            let steps: [Double] = [0, 95, 135, 175, 215, 255]
            let r = steps[v / 36], g = steps[(v / 6) % 6], b = steps[v % 6]
            return Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
        }
        let gray = Double(8 + (n - 232) * 10) / 255
        return Color(.sRGB, red: gray, green: gray, blue: gray, opacity: 1)
    }
}
