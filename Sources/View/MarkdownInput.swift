import AppKit

/// Live "type markdown, get formatting" rules for the rich note editor. Every mutation goes
/// through shouldChangeText/didChangeText so undo and the change notification fire. Stateless —
/// the text view is the state.
enum MarkdownInput {

    /// After an edit: if an inline pattern just closed at the caret, consume its markers and style
    /// the content. Returns true if it changed the text.
    @discardableResult
    static func autoformat(_ tv: NSTextView) -> Bool {
        guard let ts = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0, sel.location > 0 else { return false }
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let caretInLine = sel.location - line.location

        guard let hit = Markdown.inlineClosingAt(caretInLine, in: ns.substring(with: line))
        else { return false }
        let matchAbs = NSRange(location: line.location + hit.range.location, length: hit.range.length)
        let delim = (hit.style == .bold || hit.style == .strike) ? 2 : 1
        let contentAbs = NSRange(location: matchAbs.location + delim, length: matchAbs.length - 2 * delim)
        guard contentAbs.length > 0 else { return false }
        let content = ns.substring(with: contentAbs)

        guard tv.shouldChangeText(in: matchAbs, replacementString: content) else { return false }
        let attrs = MarkdownStyle.attributes(inline: hit.style, heading: headingLevel(ts, at: matchAbs.location))
        ts.replaceCharacters(in: matchAbs, with: NSAttributedString(string: content, attributes: attrs))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: matchAbs.location + (content as NSString).length, length: 0))
        return true
    }

    /// After an edit: if the caret line is exactly `#`..`###` + space, turn it into a heading —
    /// consume the prefix, mark the (possibly empty) line. Returns true if it changed the text.
    @discardableResult
    static func headingRule(_ tv: NSTextView) -> Bool {
        guard let ts = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let prefixLen = sel.location - line.location
        guard (2...4).contains(prefixLen) else { return false }  // "# " .. "### "
        let prefix = ns.substring(with: NSRange(location: line.location, length: prefixLen))
        guard let m = headingPrefix.firstMatch(
            in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length))
        else { return false }
        let level = m.range(at: 1).length

        let del = NSRange(location: line.location, length: prefixLen)
        guard tv.shouldChangeText(in: del, replacementString: "") else { return false }
        ts.deleteCharacters(in: del)
        tv.didChangeText()

        let ns2 = ts.string as NSString
        let lineNow = ns2.lineRange(for: NSRange(location: line.location, length: 0))
        let contentLen = lineNow.length - (ns2.substring(with: lineNow).hasSuffix("\n") ? 1 : 0)
        if contentLen > 0 {
            ts.setAttributes(
                MarkdownStyle.attributes(inline: nil, heading: level),
                range: NSRange(location: lineNow.location, length: contentLen))
        }
        tv.typingAttributes = MarkdownStyle.attributes(inline: nil, heading: level)
        tv.setSelectedRange(NSRange(location: line.location, length: 0))
        return true
    }

    /// Command interception for the text view delegate: Enter starts a fresh body line; Backspace
    /// at a heading's start turns it back into body text. Returns true when handled.
    static func handle(_ selector: Selector, _ tv: NSTextView) -> Bool {
        switch selector {
        case Selector(("insertNewline:")): return newline(tv)
        case Selector(("deleteBackward:")): return backspaceUnheading(tv)
        default: return false
        }
    }

    /// ⌘B / ⌘I: toggle an inline style on the selection, or on the next-typed text if none.
    static func toggle(_ style: InlineStyle, _ tv: NSTextView) {
        guard let ts = tv.textStorage else { return }
        let sel = tv.selectedRange()
        if sel.length == 0 {
            let cur = (tv.typingAttributes[.tackInline] as? String).flatMap(InlineStyle.init)
            let next: InlineStyle? = (cur == style) ? nil : style
            tv.typingAttributes = MarkdownStyle.attributes(
                inline: next, heading: tv.typingAttributes[.tackHeading] as? Int)
            return
        }
        guard tv.shouldChangeText(in: sel, replacementString: nil) else { return }
        let next: InlineStyle? = wholeSelectionHas(ts, sel, style) ? nil : style
        ts.beginEditing()
        // Per heading-run, so a heading keeps its level while its inline style toggles.
        ts.enumerateAttribute(.tackHeading, in: sel) { value, r, _ in
            ts.setAttributes(MarkdownStyle.attributes(inline: next, heading: value as? Int), range: r)
        }
        ts.endEditing()
        tv.didChangeText()
    }

    // MARK: - helpers

    private static let headingPrefix = try! NSRegularExpression(pattern: "^(#{1,3}) $")

    private static func newline(_ tv: NSTextView) -> Bool {
        guard let ts = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard tv.shouldChangeText(in: sel, replacementString: "\n") else { return true }
        ts.replaceCharacters(in: sel, with: NSAttributedString(string: "\n", attributes: MarkdownStyle.base))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        tv.typingAttributes = MarkdownStyle.base  // a fresh line is body, never inherits a heading
        return true
    }

    private static func backspaceUnheading(_ tv: NSTextView) -> Bool {
        guard let ts = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        guard sel.location == line.location,  // caret at the very start of the line
            let level = ts.attribute(.tackHeading, at: line.location, effectiveRange: nil) as? Int,
            level > 0
        else { return false }
        let contentLen = line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0)
        let range = NSRange(location: line.location, length: contentLen)
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return true }
        ts.setAttributes(MarkdownStyle.base, range: range)
        tv.didChangeText()
        tv.typingAttributes = MarkdownStyle.base
        return true
    }

    private static func headingLevel(_ ts: NSTextStorage, at loc: Int) -> Int? {
        guard loc < ts.length else { return nil }
        return ts.attribute(.tackHeading, at: loc, effectiveRange: nil) as? Int
    }

    private static func wholeSelectionHas(_ ts: NSTextStorage, _ range: NSRange, _ style: InlineStyle) -> Bool {
        var all = true
        ts.enumerateAttribute(.tackInline, in: range) { value, _, stop in
            if (value as? String) != style.rawValue {
                all = false
                stop.pointee = true
            }
        }
        return all
    }
}
