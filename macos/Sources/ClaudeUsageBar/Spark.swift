import AppKit

/// The Claude spark: 12 rounded rays of uneven length, clockwise from 12 o'clock (as on Windows).
enum Spark {
    static let rayLength: [CGFloat] = [1.0, 0.74, 0.9, 0.8, 1.0, 0.72, 0.94, 0.78, 0.98, 0.76, 0.88, 0.82]

    /// Draws into the current graphics context; `flipped` for views whose y axis points down.
    static func draw(center: CGPoint, radius r: CGFloat, color: NSColor, flipped: Bool) {
        let path = NSBezierPath()
        path.lineWidth = r * 0.24
        path.lineCapStyle = .round
        let down: CGFloat = flipped ? 1 : -1 // clockwise from the top in both coordinate systems
        for (index, length) in rayLength.enumerated() {
            let angle = CGFloat(-90 + index * 30) * .pi / 180
            let r0 = r * 0.22, r1 = r * length
            path.move(to: CGPoint(x: center.x + cos(angle) * r0, y: center.y + down * sin(angle) * r0))
            path.line(to: CGPoint(x: center.x + cos(angle) * r1, y: center.y + down * sin(angle) * r1))
        }
        color.setStroke()
        path.stroke()
    }

    /// The spark as an image, for the popover header.
    static func image(size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(center: CGPoint(x: rect.midX, y: rect.midY), radius: size / 2 * 0.95, color: color, flipped: true)
            return true
        }
    }

    /// AppIcon.iconset for iconutil: the spark on a rounded light tile, in every size macOS asks for.
    static func renderIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let side = CGFloat(pixels)
                let tile = NSRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
                NSColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1).setFill()
                NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22).fill()
                draw(center: CGPoint(x: side / 2, y: side / 2), radius: tile.width * 0.36,
                     color: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1), flipped: false)
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: directory.appending(path: name))
            }
        }
    }
}
