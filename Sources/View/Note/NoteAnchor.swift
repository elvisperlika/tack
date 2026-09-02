import AppKit

/// Keeps the note glued to the window it is pinned to. Owns the note's placement — the offset
/// (dx, dy) from the tracked window's top-left corner and the size the note wants — and is the
/// only thing that ever moves the note's frame.
///
/// `onChange` fires only for a *user* gesture (a drag, a resize), never for a reposition the
/// tracker asked for. That distinction is load-bearing: the tracker repositions at the display's
/// refresh rate, so saving on every one of those frames would reset the save debounce ~120 times
/// a second and the note would never actually persist while its window is being dragged.
final class NoteAnchor {
    private let window: NSWindow
    /// A user gesture changed where or how big the note is — worth persisting.
    var onChange: () -> Void = {}

    /// The tracked window, top-left screen coords. One value, because its origin and size only
    /// ever change together — three loose fields drifting apart was a bug waiting to happen.
    private var tracked = CGRect.zero
    private(set) var dx = 20.0
    private(set) var dy = 40.0
    /// The size the note wants to be. The shown size is this capped to the tracked window, so a
    /// note never spills outside the window it's pinned to — and restores when the window grows.
    private(set) var desired = NotePreferences.shared.defaultSize
    private var isProgrammaticMove = false

    init(window: NSWindow) { self.window = window }

    /// Place `note` against `bounds`: the position half of showing a note.
    func begin(note: Note, bounds: CGRect) {
        dx = note.dx
        dy = note.dy
        tracked = bounds
        desired = NSSize(
            width: note.w ?? NotePreferences.shared.defaultSize.width,
            height: note.h ?? NotePreferences.shared.defaultSize.height)
        applyPosition()  // sizes the note (capped to the tracked window) and positions it
    }

    /// The note's on-screen rect in top-left screen coords, for occlusion tests.
    func screenRectTopLeft() -> CGRect {
        let f = window.frame
        return CGRect(
            x: f.minX, y: Screens.primaryHeight() - f.maxY, width: f.width, height: f.height)
    }

    /// The tracked window moved or resized — keep the offset, reposition. No-op if unchanged.
    /// A resize re-clamps, so shrinking the window pulls the note back inside with it.
    func updateWindow(bounds: CGRect) {
        guard bounds != tracked else { return }
        tracked = bounds
        applyPosition()
    }

    /// Live drag from DragGlassView: turn the proposed origin into an offset, clamp, move.
    /// The clamp runs before the frame changes, so the note is blocked at the border instead
    /// of escaping and snapping back.
    func dragTo(origin: NSPoint) {
        (dx, dy) = Coord.offsets(
            noteMinX: Double(origin.x), noteCocoaMaxY: Double(origin.y + window.frame.height),
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            primaryHeight: Screens.primaryHeight())
        storeClamped()
        applyPosition()
        onChange()
    }

    func windowDidMove() { noteGeometryChanged(resized: false) }

    /// Dragging the top or left edge moves the note's top-left corner without moving the frame's
    /// origin, so windowDidMove never fires — a resize has to recompute the offset too, not just
    /// re-clamp, or those two edges would fight the user.
    func windowDidResize() { noteGeometryChanged(resized: true) }

    // MARK: - Internals

    /// Frame changes of our own must not read back as the user's: the window delegate fires
    /// either way, and this flag is what tells the two apart. A bracket rather than two bare
    /// assignments, so no early return can ever leave the flag stuck on.
    private func withProgrammaticMove(_ body: () -> Void) {
        isProgrammaticMove = true
        body()
        isProgrammaticMove = false
    }

    private func applyPosition() {
        let fit = Coord.fit(desired: desired, window: tracked.size)
        // Let the note shrink below its usual floor when the window is smaller than that floor,
        // and stop the user resizing it past the window — both keep the note inside the surface.
        window.minSize = Coord.fit(desired: NotePreferences.shared.minSize, window: tracked.size)
        window.maxSize = tracked.size
        // Display-only clamp: stored dx/dy keep the note's true spot, mirroring `desired` for
        // size. Writing the clamp back means one frame of tracking a bogus window rewrites
        // where the note lives for good. The user paths (drag, resize) clamp-and-store
        // themselves — there the border genuinely is the new position.
        let c = Coord.clamp(dx: dx, dy: dy, note: fit, window: tracked.size)
        let topLeft = Coord.cocoaTopLeft(
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            dx: c.dx, dy: c.dy, primaryHeight: Screens.primaryHeight())
        withProgrammaticMove {
            window.setFrame(
                NSRect(x: topLeft.x, y: topLeft.y - fit.height, width: fit.width, height: fit.height),
                display: true)
        }
    }

    /// Clamp the stored offset itself — only for user actions, where the border really is
    /// the note's new position. Programmatic tracking must never do this (see applyPosition).
    private func storeClamped() {
        let fit = Coord.fit(desired: desired, window: tracked.size)
        (dx, dy) = Coord.clamp(dx: dx, dy: dy, note: fit, window: tracked.size)
    }

    // User moved or resized the note (drags don't land here — DragGlassView feeds dragTo
    // directly): recompute the offset from the tracked window's top-left, hold it back inside,
    // then report the change.
    private func noteGeometryChanged(resized: Bool) {
        guard !isProgrammaticMove else { return }
        let f = window.frame
        (dx, dy) = Coord.offsets(
            noteMinX: Double(f.minX), noteCocoaMaxY: Double(f.maxY),
            finderLeft: Double(tracked.minX), finderTop: Double(tracked.minY),
            primaryHeight: Screens.primaryHeight())
        if resized {
            // A resize stops dead at the border, like a drag does: cut the edge the user pushed
            // past it, don't slide the note over — sliding is what made the note grow out of the
            // opposite side. What survives the cut is the size the note keeps (`desired`).
            let c = Coord.contain(dx: dx, dy: dy, note: f.size, window: tracked.size)
            (dx, dy) = (c.dx, c.dy)
            desired = c.size
        } else {
            storeClamped()
        }
        applyPosition()
        onChange()
    }
}
