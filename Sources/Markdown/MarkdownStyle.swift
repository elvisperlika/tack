import AppKit

extension NSAttributedString.Key {
    /// Semantic marks retained after markdown syntax is removed from the editor buffer.
    static let tackInline = NSAttributedString.Key("tackInline")  // value: InlineStyle.rawValue (String)
    static let tackHeading = NSAttributedString.Key("tackHeading")  // value: Int (1...3)
    static let tackList = NSAttributedString.Key("tackList")  // value: ListGlyph.rawValue (String)
}

extension ListGlyph {
    private static let markerSize: CGFloat = 14

    static func at(_ text: NSAttributedString, _ index: Int) -> ListGlyph? {
        guard index >= 0, index < text.length else { return nil }
        return (text.attribute(.tackList, at: index, effectiveRange: nil) as? String)
            .flatMap(ListGlyph.init)
    }

    func marker(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: symbol(attributes: attributes))
        value.append(NSAttributedString(string: " ", attributes: attributes))
        return value
    }

    func symbol(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let image = markerImage()
        image.accessibilityDescription = accessibilityLabel
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -2, width: Self.markerSize, height: Self.markerSize)

        let value = NSMutableAttributedString(attachment: attachment)
        value.addAttributes(attributes, range: NSRange(location: 0, length: value.length))
        value.addAttribute(.tackList, value: rawValue, range: NSRange(location: 0, length: value.length))
        return value
    }

    private var accessibilityLabel: String {
        switch self {
        case .bullet: return "Bullet"
        case .todoOpen: return "Unchecked"
        case .todoDone: return "Checked"
        }
    }

    private func markerImage() -> NSImage {
        NSImage(size: NSSize(width: Self.markerSize, height: Self.markerSize), flipped: false) { rect in
            switch self {
            case .bullet:
                NSColor.black.withAlphaComponent(0.68).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 4.75, dy: 4.75)).fill()
            case .todoOpen:
                let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1.3, dy: 1.3), xRadius: 2.4, yRadius: 2.4)
                box.lineWidth = 1.3
                NSColor.black.withAlphaComponent(0.48).setStroke()
                box.stroke()
            case .todoDone:
                let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2.6, yRadius: 2.6)
                NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 1).setFill()
                box.fill()

                let check = NSBezierPath()
                check.move(to: NSPoint(x: 3.6, y: 7.1))
                check.line(to: NSPoint(x: 5.9, y: 4.9))
                check.line(to: NSPoint(x: 10.4, y: 9.4))
                check.lineWidth = 1.55
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            }
            return true
        }
    }
}

/// The note typefaces; code spans always use `mono`.
enum NoteFont: String, CaseIterable {
    case sans, serif, mono

    func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .sans: return system
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            // Request the system serif without hard-coding its font name.
            guard let d = system.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size)
            else { return system }
            return f
        }
    }

    func dotImage(size: CGFloat, borderWidth: CGFloat = 1) -> NSImage {
        capsule(height: size, text: "T", width: size, borderWidth: borderWidth)
    }

    func wordImage(height: CGFloat, borderWidth: CGFloat = 1) -> NSImage {
        capsule(height: height, text: "Tack", borderWidth: borderWidth)
    }

    /// Uses the text width unless a fixed width is supplied for a circular button.
    private func capsule(
        height: CGFloat, text: String, width: CGFloat? = nil, borderWidth: CGFloat
    ) -> NSImage {
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
        path.lineWidth = borderWidth
        path.stroke()
        label.draw(at: NSPoint(x: (width - box.width) / 2, y: (height - box.height) / 2))
        img.unlockFocus()
        return img
    }
}

/// Maps semantic markdown attributes to their AppKit appearance.
enum MarkdownStyle {
    /// Global because Tack reuses one note window and sets the family before parsing its text.
    static var family = NoteFont.sans

    static var baseFont: NSFont { family.font(ofSize: 14) }
    static var codeFont: NSFont { NoteFont.mono.font(ofSize: 13) }
    static let textColor = NSColor.black
    static let dim = NSColor.black.withAlphaComponent(0.28)

    static var base: [NSAttributedString.Key: Any] { visual(inline: nil, heading: nil) }

    // Headings use more space above than below to group them with the following paragraph.
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

    /// Applies inline traits to the selected block font, preserving heading size.
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
        // TextKit reads paragraph style from the paragraph's first character.
        attrs[.paragraphStyle] = heading == nil ? bodyParagraph : headingParagraph
        return attrs
    }

    /// Returns both display attributes and the semantic attributes needed for serialization.
    static func attributes(inline: InlineStyle?, heading: Int?) -> [NSAttributedString.Key: Any] {
        var a = visual(inline: inline, heading: heading)
        if let inline { a[.tackInline] = inline.rawValue }
        if let heading { a[.tackHeading] = heading }
        return a
    }
}
