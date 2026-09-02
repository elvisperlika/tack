import AppKit

/// How the note looks: its palette colour and its typeface. Owns the two values the note
/// persists alongside its text, and paints the colour onto the tint view.
///
/// It touches neither the text buffer nor the pill's buttons — adopting a typeface here only
/// moves `MarkdownStyle.family`, and the assembler asks the editor to re-render. One writer per
/// surface: the editor owns the text, the pill owns its dots, this owns the tint.
///
/// Every setting comes in two halves, because the pickers preview live: `show`/`use` paint a
/// choice the user is only hovering, `commit` adopts it. Only a commit is worth persisting.
final class NoteStyler {
    private let tintView: NSView

    private(set) var colorHex = NotePreferences.shared.defaultColorHex
    private(set) var family = NoteFont.sans

    /// How much of the palette colour sits over the blur. The material underneath (.popover)
    /// is already milky, so anything much past ~0.35 buries the blur and the card reads as
    /// solid pastel — which is exactly what it shipped as at 0.6, and why this is low now.
    private static let tintAlpha: CGFloat = 0.35

    init(tintView: NSView) {
        self.tintView = tintView
        restoreColor()  // one source of truth for the default colour
    }

    /// Adopt a stored note's look. Moves `MarkdownStyle.family` too, so the caller's parse of
    /// that note's text bakes the right fonts in.
    func load(colorHex: String, family: NoteFont) {
        self.colorHex = colorHex
        commitFamily(family)
        restoreColor()
    }

    // MARK: - Colour

    /// Paint `color` over the glass without adopting it — the palette picker's live preview.
    func showColor(_ color: NSColor) {
        tintView.layer?.backgroundColor = color.withAlphaComponent(Self.tintAlpha).cgColor
    }

    /// Back to the colour the note actually has, dropping any preview over it.
    private func restoreColor() { showColor(Swatch.color(fromHex: colorHex)) }

    /// Keep `color` as the note's own, and show it.
    func commitColor(_ color: NSColor) {
        colorHex = Swatch.hex(from: color)
        showColor(color)
    }

    // MARK: - Typeface

    /// Render in `face` without adopting it — the font picker's live preview. Moves only the
    /// global that the parse reads; the caller re-renders the buffer through the editor.
    func useFamily(_ face: NoteFont) { MarkdownStyle.family = face }

    /// Keep `face` as the note's own.
    func commitFamily(_ face: NoteFont) {
        family = face
        useFamily(face)
    }
}
