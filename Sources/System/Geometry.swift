import AppKit

/// Coordinate math, kept pure so it can be asserted in --selftest.
enum Coord {
    /// AppleScript top-left screen point of the note -> Cocoa point for `setFrameTopLeftPoint`.
    static func cocoaTopLeft(
        finderLeft: Double, finderTop: Double, dx: Double, dy: Double, primaryHeight: Double
    ) -> NSPoint {
        NSPoint(x: finderLeft + dx, y: primaryHeight - (finderTop + dy))
    }

    /// Inverse of `cocoaTopLeft`: the (dx, dy) offset a note at this Cocoa frame has from the
    /// tracked window's top-left. Kept next to its partner and round-trip-asserted in --selftest,
    /// so the two flips can't drift apart.
    static func offsets(
        noteMinX: Double, noteCocoaMaxY: Double, finderLeft: Double, finderTop: Double,
        primaryHeight: Double
    ) -> (dx: Double, dy: Double) {
        (noteMinX - finderLeft, (primaryHeight - noteCocoaMaxY) - finderTop)
    }

    /// The note's on-screen size: never wider or taller than the window it sits inside. Growing
    /// the window back lets the note grow toward `desired` again — the desired size is remembered
    /// separately, so a note squeezed into a small window is not permanently shrunk.
    static func fit(desired: CGSize, window: CGSize) -> CGSize {
        CGSize(width: min(desired.width, window.width), height: min(desired.height, window.height))
    }

    /// Holds the note inside the tracked window: the offset is clamped so the note's whole
    /// rect stays within the window. A window smaller than the note pins it to the top-left.
    static func clamp(dx: Double, dy: Double, note: CGSize, window: CGSize) -> (
        dx: Double, dy: Double
    ) {
        (
            min(max(0, dx), max(0, Double(window.width - note.width))),
            min(max(0, dy), max(0, Double(window.height - note.height)))
        )
    }

    /// Where a new note starts: centred in the window it's pinned to, as the offset of its
    /// top-left corner. Fitted first, so a note capped by a small window is still centred.
    static func center(note: CGSize, window: CGSize) -> (dx: Double, dy: Double) {
        let size = fit(desired: note, window: window)
        return (Double(window.width - size.width) / 2, Double(window.height - size.height) / 2)
    }

    /// A *user resize*, held inside the window: whichever edge ran past a border is cut back to
    /// it, leaving the opposite edge where it is. `clamp` can't do this job — it slides the whole
    /// note over, so pushing one edge into the border grew the note out of the other side.
    static func contain(dx: Double, dy: Double, note: CGSize, window: CGSize) -> (
        dx: Double, dy: Double, size: CGSize
    ) {
        let x = min(max(0, dx), Double(window.width))
        let y = min(max(0, dy), Double(window.height))
        return (
            x, y,
            CGSize(
                width: max(0, min(dx + Double(note.width), Double(window.width)) - x),
                height: max(0, min(dy + Double(note.height), Double(window.height)) - y))
        )
    }
}

enum Screens {
    // ponytail: single-display assumption; refine for multi-monitor if needed
    static func primaryHeight() -> Double {
        Double(
            (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?.frame
                .height ?? 0)
    }
}
