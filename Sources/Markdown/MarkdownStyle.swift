import AppKit

extension NSAttributedString.Key {
    /// Semantic marks the rich buffer carries instead of literal markup. Appearance is derived
    /// from them (`MarkdownStyle.visual`); `MarkdownDocument.serialize` reads them back to markdown.
    static let tackInline = NSAttributedString.Key("tackInline")  // value: InlineStyle.rawValue (String)
    static let tackHeading = NSAttributedString.Key("tackHeading")  // value: Int (1...3)
}

/// The three typefaces Notion offers, and Tack with them. Per note, picked from the note's font
/// dot; `mono` is also what code spans wear whatever the note is set to.
enum NoteFont: String, CaseIterable {
    case sans, serif, mono

    func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .sans: return system
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            // The system serif (New York), asked for by design rather than by name.
            guard let d = system.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size)
            else { return system }
            return f
        }
    }

    /// The note's font dot: a "T" set in this face, on the same circle the other dots are.
    func dotImage(size: CGFloat) -> NSImage { capsule(height: size, text: "T", width: size) }

    /// The same capsule, opened out to spell "Tack" — the dot's letter is already the word's
    /// first, so hovering a face finishes it rather than replacing it. Wide enough for the word,
    /// at the same point size, so the T doesn't change gauge on the way out.
    func wordImage(height: CGFloat) -> NSImage { capsule(height: height, text: "Tack") }

    /// A pill of `text` in this face, white enough to read on the note's glass. `width` is what
    /// the word needs unless the caller pins it — the dot pins it to `height`, so one letter is a
    /// circle rather than a stubby capsule the padding would round up to.
    private func capsule(height: CGFloat, text: String, width: CGFloat? = nil) -> NSImage {
        let label = NSAttributedString(
            string: text,
            attributes: [
                .font: font(ofSize: height - 5), .foregroundColor: NSColor.black.withAlphaComponent(0.65),
            ])
        let box = label.size()
        let width = width ?? max(height, (box.width + height * 0.7).rounded())
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        let rect = NSRect(x: 1, y: 1, width: width - 2, height: height - 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.white.withAlphaComponent(0.75).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.stroke()
        label.draw(at: NSPoint(x: (width - box.width) / 2, y: (height - box.height) / 2))
        img.unlockFocus()
        return img
    }
}

/// The one place a semantic mark becomes a font/colour, so a mark looks the same however it was
/// produced — parsed from disk, typed via an input rule, or toggled with ⌘B. Bullets and todos are
/// the exception: they keep literal `- ` / `[ ]` text, dimmed here by `styleLists`.
enum MarkdownStyle {
    /// The typeface the shown note is set in. Global because one note shows at a time: the window
    /// is reused, and `NoteWindow.show` sets this before parsing the text that will wear it.
    static var family = NoteFont.sans

    static var baseFont: NSFont { family.font(ofSize: 14) }
    static var codeFont: NSFont { NoteFont.mono.font(ofSize: 13) }  // code is mono in every family
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
        return family.font(ofSize: sizes[min(max(level, 1), 3) - 1], weight: .bold)
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
