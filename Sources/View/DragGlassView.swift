import AppKit

/// Drags the note itself instead of isMovableByWindowBackground: the clamp applies *before*
/// each move, so the note stops dead at the tracked window's border — AppKit's own drag moved
/// it out first and let the delegate snap it back, which flickered at the edge.
final class DragGlassView: NSVisualEffectView {
    var onDrag: ((NSPoint) -> Void)?  // proposed window origin, Cocoa coords
    var onPress: (() -> Void)?  // a click anywhere on the card: dismisses an open picker
    var contextMenu: (() -> NSMenu?)?  // right-click on the card: palette editing and pin level
    // nil unless a drag actually began on the glass. A mouseDragged with no grab is one that
    // bubbled up the responder chain — e.g. a checkbox click in the text view, whose mouseDown we
    // handled without consuming the gesture. Acting on it would drag the note with a stale offset,
    // so it's ignored: the glass only moves the note for drags it started itself.
    private var grab: NSPoint?

    override func mouseDown(with event: NSEvent) {
        onPress?()
        guard let origin = window?.frame.origin else { return }
        let mouse = NSEvent.mouseLocation
        grab = NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let mouse = NSEvent.mouseLocation
        onDrag?(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
    }

    override func mouseUp(with event: NSEvent) { grab = nil }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}
