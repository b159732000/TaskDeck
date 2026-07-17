// Regenerate Support/AppIcon.icns:
//   swift Scripts/make-icon.swift <repo-root>
//   iconutil -c icns <repo-root>/Support/AppIcon.iconset -o <repo-root>/Support/AppIcon.icns
import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <repo-root>\n".data(using: .utf8)!)
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("Support/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px)
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGradient(starting: color(0x252E3E), ending: color(0x0E131B))!
        .draw(in: squircle, angle: -90)
    color(0x3D4A5F).setStroke()
    squircle.lineWidth = max(1, s * 0.006)
    squircle.stroke()

    // "❯" prompt + block cursor
    let font = NSFont(name: "Menlo-Bold", size: s * 0.44)
        ?? NSFont.monospacedSystemFont(ofSize: s * 0.44, weight: .bold)
    let str = NSAttributedString(string: "❯", attributes: [
        .font: font,
        .foregroundColor: color(0x5B9DFF),
    ])
    let strSize = str.size()
    let baseX = rect.minX + rect.width * 0.17
    let baseY = rect.midY - strSize.height / 2
    str.draw(at: NSPoint(x: baseX, y: baseY))

    let cursor = NSRect(x: baseX + strSize.width + s * 0.06,
                        y: rect.midY - strSize.height * 0.30,
                        width: s * 0.17, height: s * 0.075)
    color(0x8FCF7F).setFill()
    NSBezierPath(roundedRect: cursor, xRadius: s * 0.02, yRadius: s * 0.02).fill()

    return rep
}

let entries: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in entries {
    let rep = render(px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset written to \(iconset.path)")
