import AppKit

/// Converts between stored markdown and the editor's attributed text.
/// Syntax becomes semantic attributes or list glyphs during parsing and is restored on save.
enum MarkdownDocument {

    // MARK: - Markdown -> attributed (load)

    static func parse(_ markdown: String) -> NSAttributedString {
        let s = NSTextStorage(string: markdown, attributes: MarkdownStyle.base)
        // Record replacements after applying attributes because changing text shifts later ranges.
        var edits: [(NSRange, NSAttributedString)] = []

        for span in Markdown.spans(in: markdown) {
            switch span.style {
            case .inline(let style):
                s.addAttribute(.tackInline, value: style.rawValue, range: span.content)
                for m in span.markers { edits.append((m, NSAttributedString())) }
            case .heading(let level):
                s.addAttribute(.tackHeading, value: level, range: span.content)
                for m in span.markers { edits.append((m, NSAttributedString())) }
            case .bullet:
                if let m = span.markers.first {
                    edits.append((m, ListGlyph.bullet.marker(attributes: MarkdownStyle.base)))
                }
            case .todo(let done):
                if let m = span.markers.first {
                    let glyph = done ? ListGlyph.todoDone : ListGlyph.todoOpen
                    edits.append((m, glyph.marker(attributes: MarkdownStyle.base)))
                }
                if done { strikeThrough(s, span.content) }
            }
        }

        // Apply from the end so each replacement leaves earlier ranges valid.
        for (r, rep) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            s.replaceCharacters(in: r, with: rep)
        }

        // Collect runs before mutating attributes; TextKit enumeration is not mutation-safe.
        var runs: [(NSRange, InlineStyle?, Int?)] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            let inline = (attrs[.tackInline] as? String).flatMap(InlineStyle.init)
            let heading = attrs[.tackHeading] as? Int
            if inline != nil || heading != nil { runs.append((range, inline, heading)) }
        }
        for (range, inline, heading) in runs {
            s.addAttributes(MarkdownStyle.visual(inline: inline, heading: heading), range: range)
        }
        return s
    }

    /// Shared by initial parsing and interactive checkbox toggling.
    static func strikeThrough(_ ts: NSTextStorage, _ range: NSRange) {
        ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        ts.addAttribute(.foregroundColor, value: MarkdownStyle.dim, range: range)
    }

    // MARK: - Attributed -> markdown (save)

    static func serialize(_ attr: NSAttributedString) -> String {
        // components(separatedBy:) preserves empty lines and a trailing newline when rejoined.
        let lines = attr.string.components(separatedBy: "\n")
        var offset = 0
        var out: [String] = []
        for line in lines {
            let len = (line as NSString).length
            out.append(serializeLine(attr, range: NSRange(location: offset, length: len)))
            offset += len + 1  // account for the removed newline
        }
        return out.joined(separator: "\n")
    }

    private static func serializeLine(_ attr: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let ns = attr.string as NSString

        var prefix = ""
        var content = range
        if let glyph = ListGlyph.at(attr, range.location) {
            prefix = glyph.markdown
            content = NSRange(location: range.location + ListGlyph.width, length: range.length - ListGlyph.width)
        } else if let level = attr.attribute(.tackHeading, at: range.location, effectiveRange: nil) as? Int {
            prefix = String(repeating: "#", count: level) + " "
        }

        // Re-wrap marked runs; unmarked text passes through unchanged.
        var body = ""
        attr.enumerateAttribute(.tackInline, in: content) { value, r, _ in
            let text = ns.substring(with: r)
            if let raw = value as? String, let style = InlineStyle(rawValue: raw) {
                body += wrap(text, style)
            } else {
                body += text
            }
        }
        return prefix + body
    }

    private static func wrap(_ text: String, _ style: InlineStyle) -> String {
        switch style {
        case .bold: return "**\(text)**"
        case .italic: return "*\(text)*"
        case .code: return "`\(text)`"
        case .strike: return "~~\(text)~~"
        }
    }
}
