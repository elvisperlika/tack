import AppKit

/// Clicking a checkbox glyph ticks it; every other click is an ordinary click. Also owns block
/// mode: Esc steps out of the text and selects the block the caret was in, ↑/↓ walk between
/// blocks, Enter drops back into one. A text view has no idea what a block is, so the selection
/// is drawn here rather than being a text selection.
final class MarkdownTextView: NSTextView {
    var onPress: (() -> Void)?

    /// The selected block's paragraph range, or nil while editing. Nil is the normal state.
    private var selectedBlock: NSRange?

    private static let blockHighlight = NSColor.black.withAlphaComponent(0.07)  // a light grey wash

    // MARK: - Block mode

    /// Esc from editing selects the caret's block; Esc again, a click or typing leaves the mode.
    /// `doCommand(by:)` rather than the delegate hook, so block mode sees keys before the
    /// markdown rules do — in this mode ↑/↓ and Enter mean something else entirely.
    override func doCommand(by selector: Selector) {
        guard !handleBlockCommand(selector) else { return }
        super.doCommand(by: selector)
    }

    private func handleBlockCommand(_ selector: Selector) -> Bool {
        let ns = string as NSString
        guard let block = selectedBlock else {
            guard selector == #selector(cancelOperation(_:)) else { return false }
            selectBlock(Blocks.range(in: ns, at: selectedRange().location))
            return true
        }
        switch selector {
        case #selector(moveUp(_:)), #selector(moveDown(_:)):
            let delta = selector == #selector(moveUp(_:)) ? -1 : 1
            if let next = Blocks.step(from: block, by: delta, in: ns) { selectBlock(next) }
        case #selector(insertNewline(_:)):
            editBlock(at: Blocks.contentEnd(block, in: ns))
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
            deleteBlock(block)
        case #selector(cancelOperation(_:)):
            editBlock(at: selectedRange().location)
        default: break  // every other key is inert while a block is selected
        }
        return true
    }

    /// Canc removes the selected block and stays in block mode, selecting the one above — or
    /// whatever slides up into its place, when it was the first. Deleting is a block gesture, so
    /// it shouldn't drop you back into the text. Through shouldChangeText, so ⌘Z brings it back.
    private func deleteBlock(_ block: NSRange) {
        guard let ts = textStorage else { return }
        let ns = string as NSString
        // Measured before the text moves: the block above keeps its location whatever happens
        // below it, and when there is no block above, what follows slides up to the start.
        let landing = Blocks.step(from: block, by: -1, in: ns)?.location ?? 0
        var range = block
        // The last block has no newline of its own, so it takes the one that separates it from the
        // block above — otherwise deleting it would leave an empty block behind.
        if range.location + range.length == ns.length, range.location > 0 {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
        ts.deleteCharacters(in: range)
        didChangeText()
        selectBlock(Blocks.range(in: string as NSString, at: landing))
    }

    private func selectBlock(_ range: NSRange) {
        selectedBlock = range
        scrollRangeToVisible(range)
        insertionPointColor = .clear  // the block is the selection now; a caret would be a second one
        needsDisplay = true
    }

    /// Back to editing, caret at `location`. Safe to call when no block is selected.
    func editBlock(at location: Int) {
        selectedBlock = nil
        insertionPointColor = MarkdownStyle.textColor
        setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
        needsDisplay = true
    }

    /// Typing with a block selected drops into it and appends, rather than doing nothing.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let block = selectedBlock {
            editBlock(at: Blocks.contentEnd(block, in: self.string as NSString))
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let rect = selectedBlock.flatMap(blockRect) {
            Self.blockHighlight.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }

    /// The selected block's wash: as tall as its lines (paragraph spacing excluded, so the gap
    /// between blocks stays a gap) and as wide as the note.
    private func blockRect(_ block: NSRange) -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let ns = string as NSString
        let safe = NSIntersectionRange(block, NSRange(location: 0, length: ns.length))
        var box = NSRect.zero
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)) {
            _, used, _, _, _ in
            box = box.isEmpty ? used : box.union(used)
        }
        if box.isEmpty { box = lm.extraLineFragmentUsedRect }  // the document's final empty block
        guard box.height > 0 else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: 2, y: box.minY + origin.y - 2, width: bounds.width - 4, height: box.height + 4)
    }

    // MARK: - Checkboxes

    override func mouseDown(with event: NSEvent) {
        onPress?()
        editBlock(at: selectedRange().location)  // a click is always editing
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard let ts = textStorage else { return }
        // A click on the attachment can resolve to either insertion side.
        for cand in [i, i - 1] where cand >= 0 && cand < ts.length {
            if let glyph = ListGlyph.at(ts, cand), glyph != .bullet {
                toggleCheckbox(at: cand, glyph: glyph)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at i: Int, glyph: ListGlyph) {
        guard let ts = textStorage else { return }
        let becomingDone = glyph == .todoOpen
        let replacement = (becomingDone ? ListGlyph.todoDone : .todoOpen)
            .symbol(attributes: MarkdownStyle.base)
        let box = NSRange(location: i, length: 1)
        // shouldChangeText/didChangeText registers the undo *and* posts the change notification.
        guard shouldChangeText(in: box, replacementString: replacement.string) else { return }
        ts.replaceCharacters(in: box, with: replacement)
        didChangeText()

        // Strike / un-strike the item's content to match the new state.
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: i, length: 0))
        let contentLen = line.length - ListGlyph.width - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0)
        guard contentLen > 0 else { return }
        let range = NSRange(location: line.location + ListGlyph.width, length: contentLen)
        if becomingDone {
            MarkdownDocument.strikeThrough(ts, range)
        } else {
            ts.removeAttribute(.strikethroughStyle, range: range)
            ts.addAttribute(.foregroundColor, value: MarkdownStyle.textColor, range: range)
        }
    }

    // ⌘B / ⌘I reach here through the responder chain from the invisible Edit menu (the text view
    // is first responder). Target-nil menu items find these on whatever text view is focused.
    @objc func toggleBold(_ sender: Any?) { MarkdownInput.toggle(.bold, self) }
    @objc func toggleItalic(_ sender: Any?) { MarkdownInput.toggle(.italic, self) }
}
