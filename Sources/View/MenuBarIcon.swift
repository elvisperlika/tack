import AppKit

/// The app icon's silhouette — rounded square with the dot and the two bars
/// punched out — drawn rather than shipped as an asset, so there's one less
/// file to keep in sync.
/// Template mode makes AppKit recolour it for light/dark and for menu highlight.
enum MenuBarIcon {
    static func image() -> NSImage {
        let side: CGFloat = 17
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22)
            // Shapes measured off public/icon.png, in fractions of the square,
            // y from the top. All three are 0.144 tall; the bars are pill-shaped.
            func punch(x0: CGFloat, x1: CGFloat, top: CGFloat) {
                let r = NSRect(
                    x: rect.minX + side * x0, y: rect.maxY - side * (top + 0.144),
                    width: side * (x1 - x0), height: side * 0.144)
                path.append(NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2))
            }
            punch(x0: 0.687, x1: 0.830, top: 0.170)  // dot (square → circle)
            punch(x0: 0.170, x1: 0.830, top: 0.428)
            punch(x0: 0.170, x1: 0.687, top: 0.686)
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
