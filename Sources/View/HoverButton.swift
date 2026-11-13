import AppKit

/// A button that reports pointer entry and exit even while Tack is not the active app, and
/// swells under the cursor — every dot in the pill does, so each one reads as pressable.
class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    /// How much it swells: plenty for an 18pt dot, too much for anything wider.
    var hoverScale: CGFloat = 1.2

    // Layer-backed from the start: a layer made on the first hover misses that hover's animation.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        wantsLayer = true
    }

    private var swollen = false

    private func swell(_ inside: Bool) {
        swollen = inside
        guard let layer else { return }
        // Scaled about the centre: AppKit pins a view layer's anchor to its bottom-left corner,
        // so a bare scale grew the dot up and to the right. Shift, scale, shift back instead.
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var target = CATransform3DIdentity
        if inside {
            target = CATransform3DTranslate(target, c.x, c.y, 0)
            target = CATransform3DScale(target, hoverScale, hoverScale, 1)
            target = CATransform3DTranslate(target, -c.x, -c.y, 0)
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? layer.transform
        animation.toValue = target
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "hoverScale")
        layer.transform = target
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        // A rebuilt area drops the exit of one the cursor already left: unswell if it's gone.
        if swollen, let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            swell(false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        swell(true)
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        swell(false)
        onHover?(false)
    }
    // A dot hidden mid-hover gets no exit event; shown again it must not come back swollen.
    override func viewDidHide() {
        super.viewDidHide()
        layer?.removeAnimation(forKey: "hoverScale")
        layer?.transform = CATransform3DIdentity
        swollen = false
    }
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

/// One face in the font picker, wearing its own "T".
final class FontChoiceButton: HoverButton {
    var face = NoteFont.sans
}

/// A palette swatch button that carries its hex value.
final class ColorSwatchButton: HoverButton {
    var hex = ""
}
