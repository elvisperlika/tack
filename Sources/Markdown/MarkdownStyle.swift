import AppKit

extension NSAttributedString.Key {
    /// Semantic marks the rich buffer carries instead of literal markup. Appearance is derived
    /// from them (`MarkdownStyle.visual`); `MarkdownDocument.serialize` reads them back to markdown.
    static let tackInline = NSAttributedString.Key("tackInline")  // value: InlineStyle.rawValue (String)
    static let tackHeading = NSAttributedString.Key("tackHeading")  // value: Int (1...3)
}

/// The one place a semantic mark becomes a font/colour, so a mark looks the same however it was
/// produced — parsed from disk, typed via an input rule, or toggled with ⌘B. Bullets and todos are
/// the exception: they keep literal `- ` / `[ ]` text, dimmed here by `styleLists`.
enum MarkdownStyle {
    static let baseFont = NSFont.systemFont(ofSize: 14)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let textColor = NSColor.black
    /// Matches the trash button's tint. Black at low alpha reads as "faded" over any palette colour.
    static let dim = NSColor.black.withAlphaComponent(0.28)

    static var base: [NSAttributedString.Key: Any] { visual(inline: nil, heading: nil) }

    /// Blocks, Notion-style: a paragraph *is* a block, so it gets air around it instead of running
    /// together with its neighbours as lines of a page. A heading opens a section and takes more of
    /// it above than below, which is what visually binds it to the text under it.
    private static let bodyParagraph = paragraph(before: 0, after: 6)
    private static let headingParagraph = paragraph(before: 10, after: 4)

    private static func paragraph(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        return p
    }

    static func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [18, 16, 15]
        return NSFont.systemFont(ofSize: sizes[min(max(level, 1), 3) - 1], weight: .bold)
    }

    /// Font + strikethrough for a run carrying these marks. Composes: bold inside a heading stays
    /// heading-sized because the trait is converted onto the heading font, not set absolutely.
    static func visual(inline: InlineStyle?, heading: Int?) -> [NSAttributedString.Key: Any] {
        var font = heading.map(headingFont) ?? baseFont
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
        switch inline {
        case .bold: font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        case .italic: font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        case .code: font = codeFont
        case .strike: attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case .none: break
        }
        attrs[.font] = font
        // Per run, but TextKit reads it off the paragraph's first character — so a block's spacing
        // is its own even though its trailing newline carries the body style.
        attrs[.paragraphStyle] = heading == nil ? bodyParagraph : headingParagraph
        return attrs
    }

    /// Visual attributes plus the semantic marks themselves — what to write when creating or
    /// restyling a run, so the two never drift. Used by the input rules and typing attributes.
    static func attributes(inline: InlineStyle?, heading: Int?) -> [NSAttributedString.Key: Any] {
        var a = visual(inline: inline, heading: heading)
        if let inline { a[.tackInline] = inline.rawValue }
        if let heading { a[.tackHeading] = heading }
        return a
    }
}
