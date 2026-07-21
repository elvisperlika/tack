import AppKit

/// The storage boundary. On disk a note is markdown; in the editor it is rich text with no
/// markdown markup: inline/heading markers become attributes, and list markers become rendered
/// `•` / `☐` / `☑` glyphs (`ListGlyph`). `parse` strips markup out, `serialize` puts it back.
///
/// Pure — no window — so `--selftest` asserts `serialize(parse(md)) == md` over a corpus.
enum MarkdownDocument {

    // MARK: - Markdown -> attributed (load)

    static func parse(_ markdown: String) -> NSAttributedString {
        let s = NSTextStorage(string: markdown, attributes: MarkdownStyle.base)
        // Each markdown marker becomes a replacement: "" removes it (inline/heading), or a list
        // glyph takes its place. Applied after the semantic marks are set, so content rides along.
        var edits: [(NSRange, String)] = []

        for span in Markdown.spans(in: markdown) {
            switch span.style {
            case .bold, .italic, .code, .strike:
                s.addAttribute(.tackInline, value: inlineRaw(span.style), range: span.content)
                for m in span.markers { edits.append((m, "")) }
            case .heading(let level):
                s.addAttribute(.tackHeading, value: level, range: span.content)
                for m in span.markers { edits.append((m, "")) }
            case .bullet:
                if let m = span.markers.first { edits.append((m, ListGlyph.bullet)) }
            case .todo(let done):
                if let m = span.markers.first {
                    edits.append((m, done ? ListGlyph.todoDone : ListGlyph.todoOpen))
                }
                if done { strikeThrough(s, span.content) }
            }
        }

        // Descending, so replacing a later marker never shifts an earlier one still to be edited.
        for (r, rep) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            s.replaceCharacters(in: r, with: NSAttributedString(string: rep, attributes: MarkdownStyle.base))
        }

        // Derive appearance from the marks now on the (edited) string. Collect first: mutating
        // attributes while enumerating them is asking for trouble.
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

    /// Strike + dim a ticked todo's content. Public so the click-to-toggle can reuse it.
    static func strikeThrough(_ ts: NSTextStorage, _ range: NSRange) {
        ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        ts.addAttribute(.foregroundColor, value: MarkdownStyle.dim, range: range)
    }

    // MARK: - Attributed -> markdown (save)

    static func serialize(_ attr: NSAttributedString) -> String {
        // components(separatedBy:) keeps empty lines and any trailing newline, so joining back is
        // lossless — line ranges are tracked by hand alongside.
        let lines = attr.string.components(separatedBy: "\n")
        var offset = 0
        var out: [String] = []
        for line in lines {
            let len = (line as NSString).length
            out.append(serializeLine(attr, range: NSRange(location: offset, length: len)))
            offset += len + 1  // + the '\n' that components() dropped
        }
        return out.joined(separator: "\n")
    }

    private static let listMarkdown: [(glyph: String, markdown: String)] = [
        (ListGlyph.bullet, "- "), (ListGlyph.todoOpen, "- [ ] "), (ListGlyph.todoDone, "- [x] "),
    ]

    private static func serializeLine(_ attr: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let ns = attr.string as NSString
        let lineText = ns.substring(with: range)

        // A line is a list item, a heading, or body — pick the prefix and the content range.
        var prefix = ""
        var content = range
        if let (glyph, markdown) = listMarkdown.first(where: { lineText.hasPrefix($0.glyph) }) {
            prefix = markdown
            _ = glyph
            content = NSRange(location: range.location + ListGlyph.width, length: range.length - ListGlyph.width)
        } else if let level = attr.attribute(.tackHeading, at: range.location, effectiveRange: nil) as? Int {
            prefix = String(repeating: "#", count: level) + " "
        }

        // Re-wrap inline runs; the list glyph and any plain text carry no .tackInline, so they pass
        // through — except the glyph, which is excluded from `content` above.
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

    private static func inlineRaw(_ style: Markdown.Style) -> String {
        switch style {
        case .bold: return InlineStyle.bold.rawValue
        case .italic: return InlineStyle.italic.rawValue
        case .code: return InlineStyle.code.rawValue
        case .strike: return InlineStyle.strike.rawValue
        default: return InlineStyle.bold.rawValue  // unreachable: callers pass inline styles only
        }
    }
}
