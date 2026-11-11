import AppKit

/// "RRGGBB" hex <-> NSColor, kept pure so it can be asserted in --selftest.
enum Swatch {
    static let defaultHex = "FFFFFF"  // Notion white

    static func color(fromHex hex: String) -> NSColor {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return color(fromHex: defaultHex) }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded()))
    }

    /// A rounded swatch of the colour, for menu items and the note's colour dot
    /// (`radius: size / 2` makes it a circle).
    static func image(
        hex: String, size: CGFloat = 16, radius: CGFloat = 3, borderWidth: CGFloat = 1
    ) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let path = NSBezierPath(
            roundedRect: NSRect(x: 1, y: 1, width: size - 2, height: size - 2), xRadius: radius,
            yRadius: radius)
        color(fromHex: hex).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.lineWidth = borderWidth
        path.stroke()
        img.unlockFocus()
        return img
    }
}

extension NSImage {
    /// The part of the image that is actually drawn, in points. Text and SF Symbols carry
    /// padding for baselines and descenders, so centring their box leaves the glyph off-centre:
    /// a "T" sat high in its dot. Measured from the pixels at 4×, so it holds for any glyph.
    var inkBounds: NSRect {
        let scale: CGFloat = 4
        let w = Int((size.width * scale).rounded(.up))
        let h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let pixels = rep.bitmapData
        else { return NSRect(origin: .zero, size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        var left = w, right = -1, top = h, bottom = -1  // in pixel rows, top-down
        for row in 0..<h {
            for col in 0..<w where pixels[row * rep.bytesPerRow + col * 4 + 3] > 0 {
                left = min(left, col)
                right = max(right, col)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        guard right >= 0 else { return NSRect(origin: .zero, size: size) }  // nothing drawn
        return NSRect(
            x: CGFloat(left) / scale, y: CGFloat(h - bottom - 1) / scale,
            width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    /// Draw so the visible glyph, not its box, sits in the middle of `rect`.
    func drawInkCentered(in rect: NSRect) {
        let ink = inkBounds
        draw(in: NSRect(
            x: rect.midX - ink.midX, y: rect.midY - ink.midY, width: size.width, height: size.height))
    }
}
