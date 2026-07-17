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
}

enum Screens {
    // ponytail: single-display assumption; refine for multi-monitor if needed
    static func primaryHeight() -> Double {
        Double(
            (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main)?.frame
                .height ?? 0)
    }
}
