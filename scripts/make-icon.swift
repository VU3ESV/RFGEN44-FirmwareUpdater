// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background, inset like Apple's icon grid.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSGradient(colors: [
        NSColor(red: 0.05, green: 0.36, blue: 0.42, alpha: 1),
        NSColor(red: 0.02, green: 0.16, blue: 0.28, alpha: 1),
    ])!.draw(in: path, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Chip with a lightning bolt.
    let chip = symbol("cpu", pointSize: s * 0.42, weight: .regular, color: .white)
    let chipRect = NSRect(
        x: (s - chip.size.width) / 2, y: (s - chip.size.height) / 2 + s * 0.02,
        width: chip.size.width, height: chip.size.height
    )
    chip.draw(in: chipRect)

    let bolt = symbol("bolt.fill", pointSize: s * 0.2, weight: .bold, color: NSColor(red: 1, green: 0.78, blue: 0.2, alpha: 1))
    bolt.draw(in: NSRect(
        x: tile.maxX - bolt.size.width - s * 0.07, y: tile.minY + s * 0.07,
        width: bolt.size.width, height: bolt.size.height
    ))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: base * scale).write(to: output.appendingPathComponent(name))
    }
}
