import AppKit

/// The storage boundary. On disk a note is markdown; in the editor it is rich text with no
/// inline/heading markers. `parse` strips those markers into attributes; `serialize` puts them
/// back. Bullets and todos keep their literal `- ` / `[ ]` (Phase 1), so they round-trip as text.
///
/// Pure — no window — so `--selftest` asserts `serialize(parse(md)) == md` over a corpus.
enum MarkdownDocument {

    // MARK: - Markdown -> attributed (load)

    static func parse(_ markdown: String) -> NSAttributedString {
        let s = NSTextStorage(string: markdown, attributes: MarkdownStyle.base)
        var deletions: [NSRange] = []  // inline + heading markers, removed after marks are placed

        for span in Markdown.spans(in: markdown) {
            switch span.style {
            case .bold, .italic, .code, .strike:
                s.addAttribute(.tackInline, value: inlineRaw(span.style), range: span.content)
                deletions.append(contentsOf: span.markers)
            case .heading(let level):
                s.addAttribute(.tackHeading, value: level, range: span.content)
                deletions.append(contentsOf: span.markers)
            case .bullet, .todo:
                break  // literal markers; styled by the visual pass below via styleLists
            }
        }

        // Descending, so removing a later marker never shifts an earlier one still to be removed.
        for r in deletions.sorted(by: { $0.location > $1.location }) { s.deleteCharacters(in: r) }

        // Derive appearance from the marks now on the (shortened) string. Collect first: mutating
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

        // Bullets/todos are still literal text: dim their markers, strike ticked ones.
        MarkdownStyle.styleLists(s)
        return s
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

    private static func serializeLine(_ attr: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let prefix = (attr.attribute(.tackHeading, at: range.location, effectiveRange: nil) as? Int)
            .map { String(repeating: "#", count: $0) + " " } ?? ""

        // Re-wrap inline runs; literal bullet/todo text carries no .tackInline, so it passes through.
        var body = ""
        let ns = attr.string as NSString
        attr.enumerateAttribute(.tackInline, in: range) { value, r, _ in
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
