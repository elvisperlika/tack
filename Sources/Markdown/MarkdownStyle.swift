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

    static var base: [NSAttributedString.Key: Any] { [.font: baseFont, .foregroundColor: textColor] }

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

    /// Dim the literal `- ` / `[ ]` of bullet and todo lines and strike ticked todos — the one bit
    /// of styling that isn't attribute-driven, reapplied after each edit. The rich buffer has no
    /// inline/heading markers, so `spans` here only ever matches bullets and todos.
    static func styleLists(_ ts: NSTextStorage) {
        for span in Markdown.spans(in: ts.string) {
            switch span.style {
            case .bullet:
                for m in span.markers { ts.addAttribute(.foregroundColor, value: dim, range: m) }
            case .todo(let done):
                for m in span.markers { ts.addAttribute(.foregroundColor, value: dim, range: m) }
                if done {
                    ts.addAttribute(
                        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                    ts.addAttribute(.foregroundColor, value: dim, range: span.content)
                } else {
                    ts.removeAttribute(.strikethroughStyle, range: span.content)
                }
            default: break  // inline/heading are attribute-driven, not literal markers
            }
        }
    }
}
