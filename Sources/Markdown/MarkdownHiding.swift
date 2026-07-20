import AppKit

/// Collapses marker ranges to zero-width glyphs, so `**bold**` lays out as bold while the text
/// buffer keeps its literal asterisks. The set of hidden ranges is recomputed on every edit and
/// caret move (`NoteWindow.refreshHiddenMarkers`) from `Markdown.hiddenMarkers`; every other glyph
/// is left exactly as the layout manager generated it.
///
/// This is the whole reason the text view runs on a TextKit 1 stack: `shouldGenerateGlyphs` is an
/// `NSLayoutManager` hook, and it's the standard way to hide characters without touching the buffer.
final class MarkerHider: NSObject, NSLayoutManagerDelegate {
    var hidden: [NSRange] = []

    // ponytail: linear scan per glyph — a post-it is a few hundred chars. Sort + binary search
    // only if a note ever gets long.
    private func isHidden(_ charIndex: Int) -> Bool {
        hidden.contains { NSLocationInRange(charIndex, $0) }
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        var newProps = [NSLayoutManager.GlyphProperty](
            UnsafeBufferPointer(start: props, count: glyphRange.length))
        for i in 0..<glyphRange.length where isHidden(charIndexes[i]) {
            newProps[i] = .null  // a .null glyph lays out with zero advancement, i.e. hidden
        }
        newProps.withUnsafeBufferPointer { buf in
            layoutManager.setGlyphs(
                glyphs, properties: buf.baseAddress!, characterIndexes: charIndexes,
                font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }
}
