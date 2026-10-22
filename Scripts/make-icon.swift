// Draws the app icon into <dir>/AppIcon.iconset (run by build-app.sh, then iconutil).
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSGradient(colors: [NSColor(red: 1, green: 0.62, blue: 0.2, alpha: 1), NSColor(red: 0.98, green: 0.4, blue: 0.05, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: s * 0.19, yRadius: s * 0.19), angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
