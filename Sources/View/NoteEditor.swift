import AppKit

/// The note's text: the editing surface, the live markdown rules that run over it, and every
/// mutation of its buffer. Nothing outside this class writes to the text storage — a typeface
/// change comes back here as `reflow()` rather than reaching into the storage itself, so there
/// is only ever one owner of what the note says.
final class NoteEditor: NSObject, NSTextViewDelegate {
    /// The scroll view to mount in the note's card.
    let view: NSScrollView
    let textView: MarkdownTextView

    /// The buffer changed and is worth persisting.
    var onEdit: () -> Void = {}
    /// A click landed in the text — the pill's way out of an open picker.
    var onPress: () -> Void = {}

    private var reforming = false  // guards the input rules' own edits from re-entering textDidChange

    init(frame: NSRect) {
        view = NSScrollView(frame: frame)
        view.drawsBackground = false
        view.hasVerticalScroller = false
        view.autoresizingMask = [.width, .height]
        view.automaticallyAdjustsContentInsets = false

        textView = MarkdownTextView(frame: view.bounds)
        _ = textView.layoutManager  // block mode measures line fragments: take TextKit 1 now, not mid-draw
        textView.drawsBackground = false
        textView.font = MarkdownStyle.baseFont
        textView.textColor = .black
        textView.isRichText = true  // emphasis rides as attributes; markdown lives only on disk
        textView.isAutomaticTextReplacementEnabled = false  // no smart quotes/dashes mangling markdown
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.allowsUndo = true  // off by default — without it ⌘Z reaches an empty undo stack
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        view.documentView = textView

        super.init()
        textView.delegate = self
        textView.onPress = { [weak self] in self?.onPress() }
    }

    // MARK: - Contents

    /// The buffer serialized back to markdown — the editor has no markers in it, disk does.
    var markdown: String {
        textView.textStorage.map(MarkdownDocument.serialize) ?? textView.string
    }

    /// Nothing but whitespace, so deleting the note costs the user nothing.
    var isBlank: Bool {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Load markdown as rich text (markers consumed into attributes). Programmatic, so it fires
    /// no textDidChange — nothing to save, and no input rule should run on a load. The caller
    /// sets `MarkdownStyle.family` first: the parse bakes the fonts in.
    func load(_ text: String) {
        textView.editBlock(at: 0)  // the window is reused: never carry a block selection over
        textView.textStorage?.setAttributedString(MarkdownDocument.parse(text))
        textView.typingAttributes = MarkdownStyle.base
        MarkdownInput.syncTypingToBlock(textView)  // a note that opens on a heading types as one
    }

    /// Re-render the buffer in the current `MarkdownStyle.family`: markdown out, markdown back in.
    /// The round trip is the one `load` already does, and `--selftest` asserts it's lossless —
    /// mapping every run's font by hand would be the same result with more ways to get it wrong.
    ///
    /// `keepCaret` for a committed change, where the caret has to survive the swap; a hover
    /// preview leaves it out, having nothing to put back.
    func reflow(keepCaret: Bool = false) {
        let caret = textView.selectedRange().location
        guard let ts = textView.textStorage else { return }
        // No `textView.font =` here: that setter rewrites the font of *all* the text, wiping the
        // heading, bold and code runs the parse just laid down.
        ts.setAttributedString(MarkdownDocument.parse(MarkdownDocument.serialize(ts)))
        textView.typingAttributes = MarkdownStyle.base
        MarkdownInput.syncTypingToBlock(textView)
        if keepCaret { textView.editBlock(at: caret) }  // also drops any block selection, whose rect just moved
    }

    // MARK: - NSTextViewDelegate

    /// Run the markdown input rules, then keep bullet/todo styling fresh. `reforming` guards the
    /// rules' own edits (which post didChangeText) from re-entering and running the rules again.
    func textDidChange(_ notification: Notification) {
        if !reforming {
            reforming = true
            MarkdownInput.autoformat(textView)
            MarkdownInput.headingRule(textView)
            MarkdownInput.listRule(textView)
            reforming = false
        }
        onEdit()
    }

    /// Blocks keep their style wherever you type in them: on every caret move the block under it
    /// hands its heading level to the typing attributes.
    func textViewDidChangeSelection(_ notification: Notification) {
        MarkdownInput.syncTypingToBlock(textView)
    }

    /// Enter starts a body line; Backspace at a heading's start un-headings it. Everything else
    /// falls through to the text view's own handling.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        MarkdownInput.handle(selector, textView)
    }
}
