import AppKit

/// Paints `Markdown.spans` onto a text storage: content gets the styling, markers get faded.
/// Separate from both Markdown (which stays pure Foundation) and NoteWindow (so --selftest can
/// assert on the result without a window).
enum MarkdownStyle {
    static let baseFont = NSFont.systemFont(ofSize: 14)
    /// Matches the trash button's tint. Black at low alpha reads as "faded" against any palette
    /// colour, so markers don't need to track the note's background.
    static let dim = NSColor.black.withAlphaComponent(0.28)
    static let base: [NSAttributedString.Key: Any] = [
        .font: baseFont, .foregroundColor: NSColor.black,
    ]

    // ponytail: full reparse per keystroke; a post-it is a few hundred chars. Move to an
    // NSTextStorage delegate over the edited range only if a note ever gets long.
    static func apply(to ts: NSTextStorage) {
        ts.beginEditing()
        ts.setAttributes(base, range: NSRange(location: 0, length: ts.length))
        for span in Markdown.spans(in: ts.string) {
            apply(span.style, to: span.content, in: ts)
            for m in span.markers where m.length > 0 {
                ts.addAttribute(.foregroundColor, value: dim, range: m)
            }
        }
        ts.endEditing()
    }

    private static func apply(_ style: Markdown.Style, to range: NSRange, in ts: NSTextStorage) {
        guard range.length > 0 else { return }
        switch style {
        case .bold: addTrait(.boldFontMask, to: range, in: ts)
        case .italic: addTrait(.italicFontMask, to: range, in: ts)
        case .code:
            ts.addAttribute(
                .font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                range: range)
        case .strike:
            ts.addAttribute(
                .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .heading(let level):
            let sizes: [CGFloat] = [18, 16, 15]
            ts.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: sizes[min(max(level, 1), 3) - 1], weight: .bold),
                range: range)
        case .bullet:
            break  // the dimmed "- " is the whole effect
        case .todo(let done):
            guard done else { break }
            ts.addAttribute(
                .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            ts.addAttribute(.foregroundColor, value: dim, range: range)
        }
    }

    /// Compose the trait onto whatever font is already there, so bold inside a heading stays
    /// heading-sized instead of flattening to body text. Collect first: mutating .font while
    /// enumerating .font is asking for trouble.
    private static func addTrait(_ trait: NSFontTraitMask, to range: NSRange, in ts: NSTextStorage) {
        var runs: [(NSFont, NSRange)] = []
        ts.enumerateAttribute(.font, in: range) { value, r, _ in
            runs.append((value as? NSFont ?? baseFont, r))
        }
        for (font, r) in runs {
            ts.addAttribute(
                .font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: r)
        }
    }
}
