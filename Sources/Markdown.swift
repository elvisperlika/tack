import Foundation

/// Finds the markdown in a note's raw text: what to style, and which punctuation to fade.
///
/// The buffer always holds literal markdown — `**milk**` keeps its asterisks — so this only ever
/// reports ranges and never rewrites the text. That's what keeps `Note.text` a plain String and
/// every pre-markdown note valid.
///
/// Pure, so `--selftest` can assert on it without a window.
///
/// ponytail: regexes, not a CommonMark parser. One level of nesting, no tables, no blockquotes,
/// no reference links. Reach for apple/swift-markdown only if a post-it ever needs real documents.
enum Markdown {
    enum Style: Equatable {
        case bold, italic, code, strike, bullet
        case heading(Int)
        case todo(done: Bool)
    }

    /// `content` gets the styling, `markers` get dimmed. They never overlap.
    struct Span: Equatable {
        var content: NSRange
        var markers: [NSRange]
        var style: Style
    }

    // MARK: - Patterns

    // Literal patterns: a bad one is a bug, not input.
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [])
        -> NSRegularExpression
    {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = re("^(#{1,3})[ ]+(.+)$", .anchorsMatchLines)
    private static let todo = re("^([ \t]*[-*][ ]+\\[([ xX])\\][ ]*)(.*)$", .anchorsMatchLines)
    /// The lookahead is what stops a todo line from also reading as a plain bullet.
    private static let bullet = re("^([ \t]*[-*][ ]+)(?!\\[[ xX]\\])(.+)$", .anchorsMatchLines)

    private static let code = re("`([^`\n]+)`")
    private static let bold = re("\\*\\*([^*\n]+)\\*\\*")
    private static let strike = re("~~([^~\n]+)~~")
    /// The lookarounds keep `*` inside `**bold**` from reading as italic, and leave snake_case alone.
    private static let italicStar = re("(?<!\\*)\\*([^*\n]+)\\*(?!\\*)")
    private static let italicUnderscore = re("(?<![\\w])_([^_\n]+)_(?![\\w])")

    // MARK: - Parse

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Span] = []

        // Line rules first: inline styling then composes on top, so bold inside a heading keeps
        // the heading's size instead of being flattened to body text.
        heading.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let hashes = m.range(at: 1)
            let content = m.range(at: 2)
            out.append(
                Span(
                    content: content,
                    markers: [NSRange(location: hashes.location, length: content.location - hashes.location)],
                    style: .heading(hashes.length)))
        }
        todo.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let done = ns.substring(with: m.range(at: 2)).lowercased() == "x"
            out.append(
                Span(content: m.range(at: 3), markers: [m.range(at: 1)], style: .todo(done: done)))
        }
        bullet.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            out.append(
                Span(content: m.range(at: 2), markers: [m.range(at: 1)], style: .bullet))
        }

        // Inline, first claim wins: code runs first so `**x**` inside it stays literal.
        let inline: [(NSRegularExpression, Style)] = [
            (code, .code), (bold, .bold), (strike, .strike),
            (italicStar, .italic), (italicUnderscore, .italic),
        ]
        var claimed: [NSRange] = []
        for (rx, style) in inline {
            rx.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m else { return }
                let whole = m.range
                guard !claimed.contains(where: { NSIntersectionRange($0, whole).length > 0 })
                else { return }
                claimed.append(whole)
                // Markers are whatever the match holds either side of the content, so the same
                // two lines serve one backtick and two asterisks alike.
                let content = m.range(at: 1)
                out.append(
                    Span(
                        content: content,
                        markers: [
                            NSRange(location: whole.location, length: content.location - whole.location),
                            NSRange(
                                location: content.upperBound,
                                length: whole.upperBound - content.upperBound),
                        ],
                        style: style))
            }
        }
        return out
    }

    /// The `[ ]` / `[x]` range under `index`, or nil if the click landed anywhere else.
    static func todoBox(in text: String, at index: Int) -> NSRange? {
        let ns = text as NSString
        var hit: NSRange?
        todo.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            let mark = m.range(at: 2)  // the char between the brackets
            let box = NSRange(location: mark.location - 1, length: 3)
            if NSLocationInRange(index, box) {
                hit = box
                stop.pointee = true
            }
        }
        return hit
    }
}
