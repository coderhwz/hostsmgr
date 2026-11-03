import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.68, blue: 0.57, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.34, blue: 0.35, alpha: 1))!.draw(in: shape, angle: -65)
    let nodes = [NSPoint(x: 300, y: 512), NSPoint(x: 700, y: 710), NSPoint(x: 700, y: 314)]
    let lines = NSBezierPath()
    lines.move(to: nodes[1]); lines.line(to: nodes[0]); lines.line(to: nodes[2])
    lines.lineWidth = 34; lines.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.65).setStroke(); lines.stroke()
    for (index, node) in nodes.enumerated() {
        let radius: CGFloat = index == 0 ? 86 : 68
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2)).fill()
        NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.48, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: node.x - 25, y: node.y - 25, width: 50, height: 50)).fill()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name)) }
}
