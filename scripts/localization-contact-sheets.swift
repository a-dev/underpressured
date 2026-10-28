import AppKit
let languages = ["es", "pt-BR", "de", "fr", "ar", "ja", "zh-Hans"]
let inputRoot = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/underpressured-phase3-screenshots"
let output = CommandLine.arguments.dropFirst().first ?? "/tmp/underpressured-phase3-contact-sheets"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for surface in ["empty", "preset", "general", "support", "processing", "results"] {
    let cellWidth = 560.0
    let cellHeight = surface == "preset" ? 580.0 : 430.0
    let canvasSize = NSSize(width: cellWidth * 3, height: cellHeight * 3)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvasSize.width), pixelsHigh: Int(canvasSize.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.windowBackgroundColor.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    for (index, language) in languages.enumerated() {
        let origin = NSPoint(x: Double(index % 3) * cellWidth, y: canvasSize.height - Double(index / 3 + 1) * cellHeight)
        (language + " — " + surface as NSString).draw(at: NSPoint(x: origin.x + 12, y: origin.y + cellHeight - 25), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
        let input = NSImage(contentsOfFile: "\(inputRoot)/\(language)/\(surface).png")!
        let scale = min((cellWidth - 16) / input.size.width, (cellHeight - 40) / input.size.height)
        input.draw(in: NSRect(x: origin.x + 8, y: origin.y + cellHeight - 32 - input.size.height * scale, width: input.size.width * scale, height: input.size.height * scale))
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: "\(output)/\(surface).png"))
}
