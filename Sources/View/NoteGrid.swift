import AppKit

/// Every note Tack holds, laid out side by side — what a note shows when it grows into the
/// Tack dashboard. Only the contents: there is no window of its own, the note *is* the window.
///
/// Each cell is a real `NoteCard`, not a picture of one: the same glass, the same markdown, the
/// same hover pill. What a cell may change is exactly what a card owns — text, colour, face —
/// so browsing the grid can never move or resize a note on the window it belongs to.
final class NoteGrid: NSObject {
    /// The dashboard's top strip, which it is dragged by and the pill sits in.
    static let strip: CGFloat = 30

    /// The scrolling grid, to mount in whatever note is showing the dashboard — over the whole
    /// card, strip included.
    let view: FocusScrollView
    private let wrap = WrapView()
    private var cells: [NoteGridCell] = []
    /// The card last clicked: the one that scrolls its own text, and sits lifted off the rest.
    private weak var focused: NoteGridCell?
    private var placeholder: NSTextField?
    private let onError: (Error) -> Void

    /// An edit made in the dashboard, as it lands — for the floating note showing the same one.
    var onLiveEdit: ((String, Note) -> Void)?
    /// A cell brought the app its note lives on to the front.
    var onReveal: (() -> Void)?
    /// The notes in the grid — or their colours — may have changed: the dashboard repaints its
    /// background from `colors`.
    var onChange: (() -> Void)?

    /// The colours of the notes shown, as the dashboard's background uses them.
    var colors: [String] { Self.backdrop(cells.map(\.colorHex)) }

    /// Each colour once, in the order the notes are laid out, at most four — past that a
    /// gradient is mud. One colour still makes two stops, so a gradient always has a run.
    static func backdrop(_ hexes: [String]) -> [String] {
        var seen = Set<String>()
        let distinct = hexes.map { $0.uppercased() }.filter { seen.insert($0).inserted }
        let stops = Array(distinct.prefix(4))
        return stops.count == 1 ? stops + stops : stops
    }

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
        view = FocusScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        view.topBand = Self.strip  // cards scroll up under the strip the dashboard is dragged by
        view.bottomFade = 16
        view.autoresizingMask = [.width, .height]
        view.drawsBackground = false
        // No scroller to see: the wheel and the trackpad still scroll, like a note's own text.
        view.hasVerticalScroller = false
        wrap.frame = NSRect(origin: .zero, size: view.contentSize)
        wrap.autoresizingMask = [.width]  // the clip view owns the width; layout() sets the height
        view.documentView = wrap
        super.init()
        wrap.onPress = { [weak self] in self?.unfocus() }
    }

    /// Put down whichever card is lifted, and end its editing — a click anywhere off the cards.
    func unfocus() {
        focus(nil)
        wrap.window?.makeFirstResponder(nil)
    }

    func reload() {
        flush()  // a discarded cell's pending save must not land on top of what we're about to read
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        setPlaceholder(false)

        let stored: [StoredNote]
        do {
            stored = try StoredNote.all()
        } catch {
            onError(error)
            return
        }
        defer { onChange?() }
        guard !stored.isEmpty else {
            setPlaceholder(true)
            wrap.needsLayout = true
            return
        }
        stored.forEach { add(NoteGridCell(stored: $0)) }
        wrap.needsLayout = true
    }

    /// A note changed in its floating window while the dashboard is up. Keystrokes arrive here
    /// undebounced, so the cell keeps pace with the typing rather than with the disk.
    ///
    /// ponytail: text, colour and face follow; a resize doesn't — the cell keeps the size it was
    /// built at until the next reload. Reframing mid-type would reflow the whole grid under the
    /// cursor, which is worse than a stale size.
    func update(key: String, note: Note) {
        defer { onChange?() }
        if let cell = cells.first(where: { $0.key == key }) {
            guard !note.isDeletion else { return drop(cell) }
            cell.apply(note)
            return
        }
        // A note made after the dashboard was opened. Showing nothing would be a quiet lie.
        guard !note.isDeletion else { return }
        add(NoteGridCell(stored: StoredNote(key: key, note: note)))
        wrap.needsLayout = true
    }

    private func add(_ cell: NoteGridCell) {
        cell.onError = onError
        cell.onDelete = { [weak self] cell in self?.drop(cell) }
        cell.onLiveEdit = { [weak self] key, note in
            self?.onLiveEdit?(key, note)
            self?.onChange?()  // a colour picked on a card shows in the background at once
        }
        cell.onReveal = { [weak self] in self?.onReveal?() }
        cell.onPress = { [weak self, weak cell] in self?.focus(cell) }
        setPlaceholder(false)
        cells.append(cell)
        wrap.addSubview(cell)
    }

    /// Every note key the grid shows.
    var keys: [String] { cells.map(\.key) }

    /// A note changed on disk, outside Tack (nil: it was deleted there). The card shows it — or
    /// a new card appears, or the card goes — unless the user has an edit to it in flight, which
    /// wins when it lands (see Note.merge). An unchanged note leaves its card alone.
    func adoptFromDisk(key: String, note: Note?) {
        let cell = cells.first { $0.key == key }
        if let cell, cell.hasPendingEdit { return }
        guard let note else {
            if cell != nil { update(key: key, note: Note(text: "", dx: 0, dy: 0)) }
            return
        }
        if cell?.currentNote == note { return }
        update(key: key, note: note)
    }

    /// Lift `cell` and let it scroll its own text; whichever was lifted before settles back.
    private func focus(_ cell: NoteGridCell?) {
        guard cell !== focused else { return }
        focused?.setFocused(false)
        cell?.setFocused(true)
        focused = cell
    }

    /// Write out anything still sitting in a cell's debounce — on quit, and before a reload.
    /// Every cell is flushed even after one fails: a cell that can't save must not cost the
    /// others their edits.
    @discardableResult func flush() -> Bool {
        cells.map { $0.flush() }.allSatisfy { $0 }
    }

    private func drop(_ cell: NoteGridCell) {
        cells.removeAll { $0 === cell }
        cell.removeFromSuperview()
        setPlaceholder(cells.isEmpty)
        wrap.needsLayout = true
        onChange?()
    }

    /// Kept as a field rather than found by type: cells hold labels of their own, and picking the
    /// placeholder back out of `wrap.subviews` would be guesswork.
    private func setPlaceholder(_ visible: Bool) {
        if !visible {
            placeholder?.removeFromSuperview()
            placeholder = nil
            return
        }
        guard placeholder == nil else { return }
        let label = NSTextField(labelWithString: "No notes yet — add one from the menu bar.")
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        wrap.addSubview(label)
        placeholder = label
    }
}

/// Wraps its subviews left to right at whatever width the scroll view hands it, each at the size
/// it already has — the notes are ragged by design, so there is no grid to fit them to.
///
/// ponytail: every cell is built up front. Fine for the counts a person accumulates; if that ever
/// stops being true, draw unfocused cells as a plain tinted view and swap in a real card on click.
private final class WrapView: NSView {
    private static let gap: CGFloat = 16

    override var isFlipped: Bool { true }  // rows fill top-down, the way they're read

    /// A click between the cards.
    var onPress: () -> Void = {}

    override func mouseDown(with event: NSEvent) { onPress() }

    /// The cards that already have a place. A card arriving (a reload, a new note) is put down
    /// where it belongs; only one that already sat somewhere slides to its new spot — otherwise
    /// every card of a fresh grid would fly in from the corner.
    private let placed = NSHashTable<NSView>.weakObjects()

    override func layout() {
        super.layout()
        let gap = Self.gap
        var x = gap, y = gap, rowHeight: CGFloat = 0
        for sub in subviews {
            if x > gap, x + sub.frame.width > bounds.width - gap {
                x = gap
                y += rowHeight + gap
                rowHeight = 0
            }
            place(sub, at: NSPoint(x: x, y: y))
            x += sub.frame.width + gap
            rowHeight = max(rowHeight, sub.frame.height)
        }
        // At least as tall as what the scroll view shows: the empty space under the last row is
        // still the grid, and a click there has to reach it (to drop the focus) rather than
        // fall through to the card behind.
        let shown = enclosingScrollView.map { $0.contentSize.height - $0.contentInsets.top - $0.contentInsets.bottom } ?? 0
        let height = max(y + rowHeight + gap, shown)
        // Guarded: setFrameSize re-enters layout, and an unconditional set would never settle.
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }

    /// The window was resized, or a card came or went, and the rows broke differently: the
    /// cards that moved glide to their new places. During a live resize each layout pass picks
    /// the move up from wherever the card is, so they trail the window's edge and settle.
    private func place(_ sub: NSView, at origin: NSPoint) {
        guard placed.contains(sub) else {
            placed.add(sub)
            return sub.setFrameOrigin(origin)
        }
        guard sub.frame.origin != origin else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            sub.animator().setFrameOrigin(origin)
        }
    }
}

/// One note in the grid: where it lives, above a live card of it.
private final class NoteGridCell: NSView {
    private static let headerGap: CGFloat = 4

    private let card: NoteCard
    private var stored: StoredNote
    private let saver = Debouncer(delay: 0.5)  // one per cell: a shared one would cancel its peers

    var onError: (Error) -> Void = { _ in }
    var onDelete: (NoteGridCell) -> Void = { _ in }
    var onLiveEdit: (String, Note) -> Void = { _, _ in }
    var onReveal: () -> Void = {}
    var onPress: () -> Void = {}

    var key: String { stored.key }
    /// The colour the card shows now, previews aside — edits included before they are saved.
    var colorHex: String { card.styler.colorHex }

    init(stored: StoredNote) {
        self.stored = stored
        let size = Self.size(of: stored.note)
        card = NoteCard(size: size, blending: .withinWindow)
        let header = Self.header(for: stored.key, width: size.width - 4)
        super.init(
            frame: NSRect(
                x: 0, y: 0, width: size.width,
                height: size.height + header.frame.height + Self.headerGap))

        // Only the card in focus scrolls its own text; the others hand the wheel to the grid.
        card.editor.view.scrollsItself = false
        card.onPress = { [weak self] in self?.onPress() }
        wantsLayer = true
        card.view.frame = NSRect(origin: .zero, size: size)
        card.view.autoresizingMask = []  // cells don't resize; the note keeps the size it has
        addSubview(card.view)
        header.setFrameOrigin(NSPoint(x: 2, y: size.height + Self.headerGap))
        addSubview(header)
        card.load(stored.note)
        card.onEdit = { [weak self] in self?.scheduleSave() }
        card.onDelete = { [weak self] in self?.deleteConfirmed() }
        card.pill.revealIcon = Container.revealIcon(for: stored.key)
        card.pill.onReveal = { [weak self] in
            guard let self, Container.reveal(key: key) else { return }
            onReveal()
        }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // MARK: - Focus

    private static let liftScale: CGFloat = 1.03
    private static let liftDuration = 0.18

    /// The lifted card's shadow, on a layer of its own under the card. Cut out where the card is:
    /// the card is glass, and a shadow cast under it shows straight through and darkens it.
    private lazy var liftShadow: CALayer = {
        let shadow = CALayer()
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        shadow.shadowRadius = 14
        shadow.shadowOpacity = 0
        layer?.insertSublayer(shadow, at: 0)  // below the card
        return shadow
    }()

    /// Picked up or put down. Picked up, the card grows a touch about its own centre and casts a
    /// deeper shadow, as if lifted off the page — and it is the one card whose text scrolls.
    func setFocused(_ focused: Bool) {
        card.editor.view.scrollsItself = focused
        guard let layer else { return }
        let card = self.card.view.frame
        // The layer's anchor is its corner, so the scale is wrapped in a move to the card's
        // centre and back. The header rides along; only the card casts the shadow.
        var lift = CATransform3DMakeTranslation(card.midX, card.midY, 0)
        lift = CATransform3DScale(lift, Self.liftScale, Self.liftScale, 1)
        lift = CATransform3DTranslate(lift, -card.midX, -card.midY, 0)
        let outline = CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12, transform: nil)
        liftShadow.frame = bounds
        liftShadow.shadowPath = outline
        // Everything around the card, and nothing inside it (even-odd: the card is a hole).
        let around = CGMutablePath()
        around.addRect(bounds.insetBy(dx: -40, dy: -40))
        around.addPath(outline)
        let cutout = CAShapeLayer()
        cutout.path = around
        cutout.fillRule = .evenOdd
        liftShadow.mask = cutout
        layer.zPosition = focused ? 1 : 0  // over its neighbours, without reordering the grid

        let to: (transform: CATransform3D, opacity: Float) =
            focused ? (lift, 0.22) : (CATransform3DIdentity, 0)
        for (target, key, value) in [
            (layer, "transform", to.transform as Any), (liftShadow, "shadowOpacity", to.opacity as Any),
        ] {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = target.presentation()?.value(forKeyPath: key) ?? target.value(forKeyPath: key)
            move.toValue = value
            move.duration = Self.liftDuration
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.add(move, forKey: key)
        }
        layer.transform = to.transform
        liftShadow.shadowOpacity = to.opacity
    }

    /// The note at the size it was left at, floored by the same minimum a real note has.
    private static func size(of note: Note) -> NSSize {
        let fallback = NotePreferences.shared.defaultSize
        let floor = NotePreferences.shared.minSize
        let w = note.w.map { CGFloat($0) } ?? fallback.width
        let h = note.h.map { CGFloat($0) } ?? fallback.height
        return NSSize(width: max(w, floor.width), height: max(h, floor.height))
    }

    /// Which app, and which window, tab or folder inside it — wrapped over as many lines as the
    /// path needs, so none of it ends in an ellipsis. The full key stays the tooltip.
    private static func header(for key: String, width: CGFloat) -> NSTextField {
        let text = "\(Container.scopeName(for: key)) · \(Container.label(for: key))"
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = false
        label.toolTip = key
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping  // a URL has no spaces to break at
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: paragraph,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let height = label.cell?.cellSize(forBounds: bounds).height ?? 16
        label.frame = NSRect(x: 2, y: 0, width: width, height: ceil(height))
        return label
    }

    // MARK: - Saving

    /// The note as this card shows it now — what a save would write.
    var currentNote: Note { card.note(keeping: stored.note) }
    var hasPendingEdit: Bool { saver.isPending }

    private func scheduleSave() {
        let edited = currentNote  // placement comes back untouched
        onLiveEdit(stored.key, edited)  // the floating note keeps pace; the disk waits for a pause
        let stored = stored  // `stored.note` is what this card last read or wrote: the merge's "seen"
        saver.call { [weak self] in
            do {
                // Never over a newer file: see Note.merge.
                let toWrite = Note.merge(
                    mine: edited, seen: stored.note, disk: try StoredNote.load(key: stored.key))
                try stored.save(toWrite)
                self?.stored.note = toWrite
                if toWrite != edited {  // the file's words won: show them, here and on the window
                    self?.card.load(toWrite)
                    self?.onLiveEdit(stored.key, toWrite)
                }
                return true
            } catch {
                self?.onError(error)
                return false
            }
        }
    }

    @discardableResult func flush() -> Bool { saver.flush() }

    /// Adopt a version of this note that came from somewhere else — the floating window. Any
    /// pending save is dropped rather than merged: it is older than what just arrived, and one
    /// note can't be typed in two places at once.
    func apply(_ note: Note) {
        saver.cancel()
        stored.note = note
        card.load(note)
    }

    private func deleteConfirmed() {
        let deletion = card.deletion(keeping: stored.note)
        do {
            try stored.save(deletion)
        } catch {
            onError(error)
            return
        }
        saver.cancel()  // a stale delayed save must not recreate the note that just went
        onLiveEdit(stored.key, deletion)  // and its floating twin goes with it
        onDelete(self)
    }
}
