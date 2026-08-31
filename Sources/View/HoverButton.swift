import AppKit

/// A button that reports pointer entry and exit even while Tack is not the active app.
class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The control pill, which is a bare glass dot until the cursor reaches it. `.activeAlways`
/// because Tack is an agent: the note is almost never in the active app, and the default
/// `.activeInKeyWindow` would only track after a click. `.inVisibleRect` re-fits the area to
/// the bounds for free, which matters because those bounds are exactly what hovering changes.
final class HoverPill: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One face in the font picker. Its image widens from "T" to "Tack" on hover.
final class FontChoiceButton: HoverButton {
    var face = NoteFont.sans
    var narrow = NSImage()
    var wide = NSImage()
    var expanded = false { didSet { image = expanded ? wide : narrow } }
    var width: CGFloat { (expanded ? wide : narrow).size.width }
}

/// A palette swatch button that carries its hex value.
final class ColorSwatchButton: HoverButton {
    var hex = ""
}
