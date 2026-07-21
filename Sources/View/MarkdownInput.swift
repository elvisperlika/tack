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

    /// After an edit: if the caret line is `- `/`* ` (bullet) or `[]`/`[ ]`/`[x]` + space (todo),
    /// swap the prefix for its rendered glyph. `[]` rather than `- [ ]` is the trigger so it doesn't
    /// collide with the bullet rule firing first. Returns true if it changed the text.
    @discardableResult
    static func listRule(_ tv: NSTextView) -> Bool {
        guard let ts = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let prefixLen = sel.location - line.location
        guard (2...4).contains(prefixLen) else { return false }  // "- " .. "[ ] "
        let prefix = ns.substring(with: NSRange(location: line.location, length: prefixLen))

        let glyph: String
        if bulletPrefix.firstMatch(in: prefix, range: whole(prefix)) != nil {
            glyph = ListGlyph.bullet
        } else if let m = todoPrefix.firstMatch(in: prefix, range: whole(prefix)) {
            let inner = (prefix as NSString).substring(with: m.range(at: 1)).lowercased()
            glyph = inner == "x" ? ListGlyph.todoDone : ListGlyph.todoOpen
        } else {
            return false
        }

        let del = NSRange(location: line.location, length: prefixLen)
        guard tv.shouldChangeText(in: del, replacementString: glyph) else { return false }
        ts.replaceCharacters(in: del, with: NSAttributedString(string: glyph, attributes: MarkdownStyle.base))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: line.location + ListGlyph.width, length: 0))
        tv.typingAttributes = MarkdownStyle.base
        return true
    }

    /// Command interception for the text view delegate: Enter continues or exits a list (else starts
    /// a fresh body line); Backspace at a list/heading start turns it back into body. True if handled.
    static func handle(_ selector: Selector, _ tv: NSTextView) -> Bool {
        switch selector {
        case #selector(NSStandardKeyBindingResponding.insertNewline(_:)): return newline(tv)
        case #selector(NSStandardKeyBindingResponding.deleteBackward(_:)): return backspace(tv)
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
    private static let bulletPrefix = try! NSRegularExpression(pattern: "^([-*]) $")
    private static let todoPrefix = try! NSRegularExpression(pattern: "^\\[([ xX]?)\\] $")

    private static func whole(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    /// Enter inside a list item continues it (empty item exits the list); elsewhere it starts a
    /// fresh body line. Either way the new line is body — it never inherits a heading.
    private static func newline(_ tv: NSTextView) -> Bool {
        guard let ts = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: line)

        if let glyph = ListGlyph.leading(lineText) {
            let contentLen = line.length - ListGlyph.width - (lineText.hasSuffix("\n") ? 1 : 0)
            if contentLen <= 0 {  // empty item: Enter drops the marker and leaves a body line
                return replace(tv, NSRange(location: line.location, length: ListGlyph.width), "", caret: line.location)
            }
            // Continue the list; a todo continues as an open box, not a copy of a ticked one.
            let next = (glyph == ListGlyph.bullet) ? ListGlyph.bullet : ListGlyph.todoOpen
            return replace(tv, sel, "\n" + next, caret: sel.location + ("\n" + next as NSString).length)
        }
        return replace(tv, sel, "\n", caret: sel.location + 1)
    }

    /// Backspace at a list item's content start drops the marker; at a heading's start it un-headings.
    /// Anything else falls through to the text view's own deletion.
    private static func backspace(_ tv: NSTextView) -> Bool {
        guard let ts = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: line)

        if ListGlyph.leading(lineText) != nil, sel.location == line.location + ListGlyph.width {
            return replace(tv, NSRange(location: line.location, length: ListGlyph.width), "", caret: line.location)
        }
        if sel.location == line.location,
            let level = ts.attribute(.tackHeading, at: line.location, effectiveRange: nil) as? Int,
            level > 0
        {
            let contentLen = line.length - (lineText.hasSuffix("\n") ? 1 : 0)
            let range = NSRange(location: line.location, length: contentLen)
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return true }
            ts.setAttributes(MarkdownStyle.base, range: range)
            tv.didChangeText()
            tv.typingAttributes = MarkdownStyle.base
            return true
        }
        return false
    }

    /// Replace `range` with base-styled `text`, register undo, put the caret at `caret`, and reset
    /// typing to body — the shared spine of the Enter/Backspace list edits.
    @discardableResult
    private static func replace(_ tv: NSTextView, _ range: NSRange, _ text: String, caret: Int) -> Bool {
        guard let ts = tv.textStorage else { return false }
        guard tv.shouldChangeText(in: range, replacementString: text) else { return true }
        ts.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: MarkdownStyle.base))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: caret, length: 0))
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
