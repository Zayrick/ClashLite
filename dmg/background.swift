// 生成 DMG 窗口背景：swift background.swift <输出目录>
// 输出 background.png（1x）与 background@2x.png，布局需与 settings.py 保持一致

import AppKit

let size = NSSize(width: 640, height: 400)
// 图标中心（左上角为原点），与 settings.py 中 icon_locations 相同
let appCenter = NSPoint(x: 180, y: 190)
let applicationsCenter = NSPoint(x: 460, y: 190)

func render(scale: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // 翻转为左上角原点，方便与 Finder 坐标对应
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: size.height)
    transform.scaleX(by: 1, yBy: -1)
    transform.concat()

    let bounds = NSRect(origin: .zero, size: size)

    // 底色：自上而下的极浅渐变
    NSGradient(
        starting: NSColor(srgbRed: 0.992, green: 0.992, blue: 0.996, alpha: 1),
        ending: NSColor(srgbRed: 0.937, green: 0.937, blue: 0.953, alpha: 1)
    )!.draw(in: bounds, angle: 90)

    // 中间的箭头：虚线加箭头尖
    let arrowColor = NSColor(srgbRed: 0.68, green: 0.68, blue: 0.72, alpha: 1)
    arrowColor.setStroke()
    let startX = appCenter.x + 88
    let endX = applicationsCenter.x - 88
    let y = appCenter.y

    let line = NSBezierPath()
    line.move(to: NSPoint(x: startX, y: y))
    line.line(to: NSPoint(x: endX - 2, y: y))
    line.lineWidth = 2
    line.lineCapStyle = .round
    line.setLineDash([0.01, 8], count: 2, phase: 0)
    line.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: endX - 9, y: y - 9))
    head.line(to: NSPoint(x: endX, y: y))
    head.line(to: NSPoint(x: endX - 9, y: y + 9))
    head.lineWidth = 2
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(filePath: CommandLine.arguments.dropFirst().first ?? ".", directoryHint: .isDirectory)
try render(scale: 1, to: output.appending(path: "background.png"))
try render(scale: 2, to: output.appending(path: "background@2x.png"))
