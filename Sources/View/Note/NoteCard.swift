import AppKit

/// The post-it itself, minus the window: the rounded glass card and the three parts that fill it
/// — what it says (`NoteEditor`), how it looks (`NoteStyler`), how you change either
/// (`NotePill`) — wired to each other. Whoever owns one supplies the rest: `NoteWindow` adds a
/// floating window and an anchor, the Tack window adds a cell in a scrolling grid.
///
/// It deliberately knows nothing about *where* a note sits or how big it is, which is what
/// `note(keeping:)` is for: the card writes only the three fields it actually owns, and the
/// owner's placement survives verbatim.
final class NoteCard: NSObject {
    /// The card. Mount it anywhere; the owner may add `onDrag` and `contextMenu` of its own.
    let view: DragGlassView
    let editor: NoteEditor  // the text, its markdown rules, and the only writer to it
    let styler: NoteStyler  // the note's colour and typeface, and the tint that shows one
    let pill: NotePill  // the control cluster in the card's top-right corner

    /// The text, colour or face changed and is worth persisting.
    var onEdit: () -> Void = {}
    /// The red dot, after the user has confirmed.
    var onDelete: () -> Void = {}

    private static let strip: CGFloat = 18  // top drag handle; the pill parks in its right corner
    private static let radius: CGFloat = 12

    /// Rounds the *material*. A .behindWindow blur is shaped by the window server from this
    /// mask's alpha, not by the layer, so `cornerRadius` alone leaves a square pane of frost
    /// (and a square shadow) around the rounded card. Stretchable, because the note resizes:
    /// the cap insets pin the corners and the 1pt middle takes the stretch.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// `blending` is the one thing a mount gets to choose: a floating note frosts the desktop
    /// behind it, a card inside a window has to frost that window instead or it punches straight
    /// through to the desktop.
    init(size: NSSize, blending: NSVisualEffectView.BlendingMode = .behindWindow) {
        let w = size.width
        let h = size.height

        // Rounded glass card: a blur of whatever sits behind the note, with the palette colour
        // as a sheer tint over it. The bare tint is the drag area.
        // ponytail: NSVisualEffectView is the glass this deployment target has — Apple's Liquid
        // Glass (NSGlassEffectView) is macOS 26+, and Tack targets 13. Material is taste.
        view = DragGlassView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.material = .popover
        view.blendingMode = blending
        view.state = .active  // stay frosted while the note isn't key, which is most of the time
        view.appearance = NSAppearance(named: .aqua)  // a light card with black text, even in dark mode
        view.maskImage = Self.roundedMask(radius: Self.radius)  // rounds the material — see above
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.radius  // rounds the tint and text on top of it
        view.layer?.masksToBounds = true

        // The palette colour lives here rather than on the glass: NSVisualEffectView owns its
        // own layer's drawing, so a tint of our own needs a view of its own. The styler is the
        // only thing that paints it, so it's the only thing that keeps it.
        let tint = NSView(frame: view.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        view.addSubview(tint)
        styler = NoteStyler(tintView: tint)

        // Editable text: the full card below the drag strip.
        // ponytail: no inset for the pill — closed it's a dot in a corner and the text is meant to
        // blur under it; reserving a line's worth of space for it on every note costs more.
        editor = NoteEditor(frame: NSRect(x: 4, y: 4, width: w - 8, height: h - Self.strip - 4))
        view.addSubview(editor.view)

        pill = NotePill(cardWidth: w, cardHeight: h, styler: styler)
        view.addSubview(pill.view)

        super.init()
        view.onPress = { [weak self] in self?.pill.close() }  // the picker's way out
        editor.onPress = { [weak self] in self?.pill.close() }
        editor.onEdit = { [weak self] in self?.onEdit() }
        pill.onFont = { [weak self] face, commit in self?.choose(family: face, commit: commit) }
        pill.onColor = { [weak self] color, commit in self?.choose(color: color, commit: commit) }
        pill.onDelete = { [weak self] in self?.deleteTapped() }
    }

    // MARK: - Contents

    /// Show `note`. Its look is adopted before the parse, which bakes the note's face in.
    func load(_ note: Note) {
        styler.load(
            colorHex: note.color ?? NotePreferences.shared.defaultColorHex,
            family: note.font.flatMap(NoteFont.init(rawValue:)) ?? .sans)
        editor.family = styler.family
        pill.reset()  // a reused card must never arrive already open
        editor.load(note.text)
    }

    /// The card's three fields written over `base`. Where the note sits and how big it is belongs
    /// to the owner, so it comes straight back out of `base` untouched.
    func note(keeping base: Note) -> Note {
        var note = base
        note.text = editor.markdown
        note.color = styler.colorHex
        note.font = styler.family.rawValue
        return note
    }

    /// An empty note deletes, app-wide — so the colour is all that's worth carrying over.
    func deletion(keeping base: Note) -> Note {
        Note(text: "", dx: base.dx, dy: base.dy, color: styler.colorHex)
    }

    func focus(in window: NSWindow?) { window?.makeFirstResponder(editor.textView) }

    // MARK: - Choosing a look

    /// What choosing a typeface means, whether the pill is previewing one under the cursor or
    /// the user has settled on it. Preview and commit share the exact same rendering path; only
    /// a commit adopts the face, so leaving a choice restores the note without ever scheduling a
    /// save. A commit also keeps the caret, which a preview has nothing to put back.
    func choose(family face: NoteFont, commit: Bool) {
        if commit { styler.commitFamily(face) } else { styler.useFamily(face) }
        editor.reflow(keepCaret: commit)
        guard commit else { return }
        editor.family = face  // the editor's own face, for everything it restyles from here on
        pill.refreshDots()
        onEdit()
    }

    /// The same, for a colour — from a swatch under the cursor, a swatch click, or live from the
    /// system colour panel behind the card's right-click menu.
    func choose(color: NSColor, commit: Bool) {
        if commit { styler.commitColor(color) } else { styler.showColor(color) }
        guard commit else { return }
        pill.refreshDots()
        onEdit()
    }

    // MARK: - Deleting

    /// A single click on the red dot is the whole delete gesture, so a note with text asks first.
    private func deleteTapped() {
        guard confirmDelete() else { return }
        onDelete()
    }

    private func confirmDelete() -> Bool {
        guard !editor.isBlank else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this note?"
        alert.informativeText = "Its text will be lost."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
