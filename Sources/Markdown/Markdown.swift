import Foundation

/// Inline styles stored in the rich-text buffer and restored during serialization.
enum InlineStyle: String { case bold, italic, code, strike }

/// Rich-text replacements for markdown list markers. Each occupies two UTF-16 units.
enum ListGlyph {
    static let bullet = "\u{2022} "  // "• "
    static let todoOpen = "\u{2610} "  // "☐ "
    static let todoDone = "\u{2611} "  // "☑ "
    static let all = [bullet, todoOpen, todoDone]
    static let width = 2

    static func leading(_ line: String) -> String? { all.first { line.hasPrefix($0) } }
}

/// Finds semantic spans in markdown without modifying the input.
///
/// ponytail: regexes cover Tack's small markdown subset. Use a CommonMark parser only if notes
/// need deeper nesting, tables, blockquotes, or reference links.
enum Markdown {
    enum Style: Equatable {
        case inline(InlineStyle)
        case bullet
        case heading(Int)
        case todo(done: Bool)
    }

    /// The text to style and the surrounding syntax to remove during rich-text conversion.
    struct Span: Equatable {
        var content: NSRange
        var markers: [NSRange]
        var style: Style
    }

    // MARK: - Patterns

    // These are fixed program constants, so an invalid pattern is a programmer error.
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [])
        -> NSRegularExpression
    {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = re("^(#{1,3})[ ]+(.+)$", .anchorsMatchLines)
    private static let todo = re("^([ \t]*[-*][ ]+\\[([ xX])\\][ ]*)(.*)$", .anchorsMatchLines)
    // Exclude todo prefixes so a todo is not also reported as a bullet.
    private static let bullet = re("^([ \t]*[-*][ ]+)(?!\\[[ xX]\\])(.+)$", .anchorsMatchLines)

    private static let code = re("`([^`\n]+)`")
    private static let bold = re("\\*\\*([^*\n]+)\\*\\*")
    private static let strike = re("~~([^~\n]+)~~")
    // Ignore asterisks inside bold markers and underscores inside words.
    private static let italicStar = re("(?<!\\*)\\*([^*\n]+)\\*(?!\\*)")
    private static let italicUnderscore = re("(?<![\\w])_([^_\n]+)_(?![\\w])")

    // MARK: - Parse

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Span] = []

        // Report block styles first so later inline styles can compose with them.
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

        // First match wins. Code runs first so markdown-like text inside code stays literal.
        let inline: [(NSRegularExpression, InlineStyle)] = [
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
                // Derive both marker ranges from the match instead of delimiter-specific lengths.
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
                        style: .inline(style)))
            }
        }
        return out
    }

    /// Returns the inline expression ending at `caret`, for live formatting after its closing
    /// delimiter is typed.
    static func inlineClosingAt(_ caret: Int, in line: String) -> (range: NSRange, style: InlineStyle)? {
        for span in spans(in: line) {
            guard case .inline(let style) = span.style else { continue }
            let lo = (span.markers.map(\.location) + [span.content.location]).min()!
            let hi = (span.markers.map(\.upperBound) + [span.content.upperBound]).max()!
            if hi == caret { return (NSRange(location: lo, length: hi - lo), style) }
        }
        return nil
    }
}
