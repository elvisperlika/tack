import AppKit

/// The app icon's silhouette — rounded square with the dot punched out — drawn
/// rather than shipped as an asset, so there's one less file to keep in sync.
/// Template mode makes AppKit recolour it for light/dark and for menu highlight.
enum MenuBarIcon {
    static func image() -> NSImage {
        let side: CGFloat = 17
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22)
            // Dot position/size taken from icon.png, in fractions of the square.
            let r = side * 0.097
            let c = NSPoint(x: rect.minX + side * 0.783, y: rect.maxY - side * 0.212)
            path.append(NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)))
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
