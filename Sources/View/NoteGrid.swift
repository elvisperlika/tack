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
    private var placeholder: NSTextField?
    private let onError: (Error) -> Void

    /// An edit made in the dashboard, as it lands — for the floating note showing the same one.
    var onLiveEdit: ((String, Note) -> Void)?

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
        // Tack is an agent (`LSUIElement`), which has no Dock icon and can't properly own a
        // window. While this one is up it becomes an ordinary app — Dock icon, menu bar, ⌘Tab —
        // and goes back to being an agent when the window closes. Set before the window is
        // ordered in, or it comes up behind whatever was frontmost.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        cell.onLiveEdit = { [weak self] key, note in self?.onLiveEdit?(key, note) }
        setPlaceholder(false)
        cells.append(cell)
        wrap.addSubview(cell)
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

    /// Closing is not quitting: pending edits still have to reach disk, and Tack goes back to
    /// being a menu-bar agent rather than leaving a Dock icon behind with no window under it.
    func windowWillClose(_ notification: Notification) {
        flush()
        NSApp.setActivationPolicy(.accessory)
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
    private static let headerGap: CGFloat = 4

    private let card: NoteCard
    private var stored: StoredNote
    private let saver = Debouncer(delay: 0.5)  // one per cell: a shared one would cancel its peers

    var onError: (Error) -> Void = { _ in }
    var onDelete: (NoteGridCell) -> Void = { _ in }
    var onLiveEdit: (String, Note) -> Void = { _, _ in }

    var key: String { stored.key }

    init(stored: StoredNote) {
        self.stored = stored
        let size = Self.size(of: stored.note)
        card = NoteCard(size: size, blending: .withinWindow)
        let header = Self.header(for: stored.key, width: size.width - 4)
        super.init(
            frame: NSRect(
                x: 0, y: 0, width: size.width,
                height: size.height + header.frame.height + Self.headerGap))

        // ponytail: a note whose text overflows scrolls itself before the grid does — AppKit
        // only chains to the outer scroller once the inner one is at its end. Lives with it.
        card.view.frame = NSRect(origin: .zero, size: size)
        card.view.autoresizingMask = []  // cells don't resize; the note keeps the size it has
        addSubview(card.view)
        header.setFrameOrigin(NSPoint(x: 2, y: size.height + Self.headerGap))
        header.onOpen = { [key = stored.key] in Container.reveal(key: key) }
        addSubview(header)
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

    /// Which app, and which window, tab or folder inside it — wrapped over as many lines as the
    /// path needs, so none of it ends in an ellipsis. The full key stays the tooltip.
    private static func header(for key: String, width: CGFloat) -> PathLabel {
        let text = "\(Container.scopeName(for: key)) · \(Container.label(for: key))"
        let label = PathLabel(wrappingLabelWithString: text)
        label.isSelectable = false  // the whole line is one click target, not selectable text
        label.toolTip = key + "\n⌘-click to open it"
        label.attributedStringValue = PathLabel.styled(text, asLink: false)
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let height = label.cell?.cellSize(forBounds: bounds).height ?? 16
        label.frame = NSRect(x: 2, y: 0, width: width, height: ceil(height))
        return label
    }

    // MARK: - Saving

    private func scheduleSave() {
        let edited = card.note(keeping: stored.note)  // placement comes back untouched
        onLiveEdit(stored.key, edited)  // the floating note keeps pace; the disk waits for a pause
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

/// The header line, as a link: hold ⌘ over it and it turns blue and underlined, ⌘-click and the
/// app, tab or folder the note lives on comes forward.
///
/// ⌘ is watched with a local monitor rather than `flagsChanged`, which only reaches the first
/// responder — a label in a grid never is one. The monitor exists only while the mouse is
/// actually over this label, so at most one is installed at a time.
private final class PathLabel: NSTextField {
    var onOpen: () -> Void = {}

    private var monitor: Any?
    private var armed = false {
        didSet {
            guard armed != oldValue else { return }
            attributedStringValue = Self.styled(stringValue, asLink: armed)
            armed ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }

    static func styled(_ text: String, asLink: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping  // a URL has no spaces to break at
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: paragraph,
            .foregroundColor: asLink ? NSColor.linkColor : NSColor.secondaryLabelColor,
        ]
        if asLink { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: text, attributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        armed = event.modifierFlags.contains(.command)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.armed = event.modifierFlags.contains(.command)
            return event
        }
    }

    override func mouseExited(with event: NSEvent) {
        armed = false
        stopWatching()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.mouseDown(with: event) }
        onOpen()
    }

    /// The grid drops cells without the mouse ever leaving them — on a reload, or when a note is
    /// deleted out from under the pointer — so the monitor and the cursor are unwound here too.
    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if armed { NSCursor.pop() }
        stopWatching()
    }
}
