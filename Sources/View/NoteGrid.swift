import AppKit

/// Every note Tack holds, laid out side by side — the window behind "Open Tack".
///
/// Each cell is a real `NoteCard`, not a picture of one: the same glass, the same markdown, the
/// same hover pill. What a cell may change is exactly what a card owns — text, colour, face —
/// so browsing the grid can never move or resize a note on the window it belongs to.
final class NoteGrid: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let wrap = WrapView()
    private var cells: [NoteGridCell] = []
    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Tack"
        window.setFrameAutosaveName("tackMain")  // unchanged key: keeps the placeholder's frame
        window.center()
        window.isReleasedWhenClosed = false

        // The cards frost what is behind them *within* this window, so the window has to give
        // them something to frost — a clear background would blur straight through to the desktop.
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: window.frame.size))
        backdrop.material = .underWindowBackground
        backdrop.state = .followsWindowActiveState
        backdrop.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: backdrop.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        wrap.frame = NSRect(origin: .zero, size: scroll.contentSize)
        wrap.autoresizingMask = [.width]  // the clip view owns the width; layout() sets the height
        scroll.documentView = wrap
        backdrop.addSubview(scroll)
        window.contentView = backdrop
        super.init()
        window.delegate = self
    }

    /// Re-read both stores and rebuild. Cheap enough at the note counts involved.
    /// ponytail: no live sync with the floating note — reopening the grid is the refresh. Add an
    /// observer if the two ever sit side by side for long.
    func open() {
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        flush()  // a discarded cell's pending save must not land on top of what we're about to read
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        wrap.subviews.forEach { $0.removeFromSuperview() }

        let stored: [StoredNote]
        do {
            stored = try StoredNote.all()
        } catch {
            onError(error)
            return
        }
        guard !stored.isEmpty else {
            wrap.addSubview(Self.emptyLabel())
            wrap.needsLayout = true
            return
        }
        for note in stored {
            let cell = NoteGridCell(stored: note)
            cell.onError = onError
            cell.onDelete = { [weak self] cell in self?.drop(cell) }
            cells.append(cell)
            wrap.addSubview(cell)
        }
        wrap.needsLayout = true
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
        if cells.isEmpty { wrap.addSubview(Self.emptyLabel()) }
        wrap.needsLayout = true
    }

    private static func emptyLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "No notes yet — add one from the menu bar.")
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        return label
    }

    /// Closing is not quitting: pending edits still have to reach disk.
    func windowWillClose(_ notification: Notification) { flush() }
}

/// Wraps its subviews left to right at whatever width the scroll view hands it, each at the size
/// it already has — the notes are ragged by design, so there is no grid to fit them to.
///
/// ponytail: every cell is built up front. Fine for the counts a person accumulates; if that ever
/// stops being true, draw unfocused cells as a plain tinted view and swap in a real card on click.
private final class WrapView: NSView {
    private static let gap: CGFloat = 16

    override var isFlipped: Bool { true }  // rows fill top-down, the way they're read

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
            sub.setFrameOrigin(NSPoint(x: x, y: y))
            x += sub.frame.width + gap
            rowHeight = max(rowHeight, sub.frame.height)
        }
        let height = y + rowHeight + gap
        // Guarded: setFrameSize re-enters layout, and an unconditional set would never settle.
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }
}

/// One note in the grid: where it lives, above a live card of it.
private final class NoteGridCell: NSView {
    private static let headerHeight: CGFloat = 16
    private static let headerGap: CGFloat = 4

    private let card: NoteCard
    private let stored: StoredNote
    private let saver = Debouncer(delay: 0.5)  // one per cell: a shared one would cancel its peers

    var onError: (Error) -> Void = { _ in }
    var onDelete: (NoteGridCell) -> Void = { _ in }

    init(stored: StoredNote) {
        self.stored = stored
        let size = Self.size(of: stored.note)
        card = NoteCard(size: size, blending: .withinWindow)
        super.init(
            frame: NSRect(
                x: 0, y: 0, width: size.width,
                height: size.height + Self.headerHeight + Self.headerGap))

        // ponytail: a note whose text overflows scrolls itself before the grid does — AppKit
        // only chains to the outer scroller once the inner one is at its end. Lives with it.
        card.view.frame = NSRect(origin: .zero, size: size)
        card.view.autoresizingMask = []  // cells don't resize; the note keeps the size it has
        addSubview(card.view)
        addSubview(header())
        card.load(stored.note)
        card.onEdit = { [weak self] in self?.scheduleSave() }
        card.onDelete = { [weak self] in self?.deleteConfirmed() }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The note at the size it was left at, floored by the same minimum a real note has.
    private static func size(of note: Note) -> NSSize {
        let fallback = NotePreferences.shared.defaultSize
        let floor = NotePreferences.shared.minSize
        let w = note.w.map { CGFloat($0) } ?? fallback.width
        let h = note.h.map { CGFloat($0) } ?? fallback.height
        return NSSize(width: max(w, floor.width), height: max(h, floor.height))
    }

    /// Which app, and which window, tab or folder inside it. The full key is the tooltip: a URL
    /// is longer than any card is wide.
    private func header() -> NSTextField {
        let text = "\(Container.scopeName(for: stored.key)) · \(Container.label(for: stored.key))"
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = stored.key
        label.frame = NSRect(
            x: 2, y: bounds.height - Self.headerHeight, width: bounds.width - 4,
            height: Self.headerHeight)
        return label
    }

    // MARK: - Saving

    private func scheduleSave() {
        let edited = card.note(keeping: stored.note)  // placement comes back untouched
        let stored = stored
        saver.call { [weak self] in
            do {
                try stored.save(edited)
                return true
            } catch {
                self?.onError(error)
                return false
            }
        }
    }

    @discardableResult func flush() -> Bool { saver.flush() }

    private func deleteConfirmed() {
        do {
            try stored.save(card.deletion(keeping: stored.note))
        } catch {
            onError(error)
            return
        }
        saver.cancel()  // a stale delayed save must not recreate the note that just went
        onDelete(self)
    }
}
